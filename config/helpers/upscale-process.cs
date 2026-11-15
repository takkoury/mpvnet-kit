using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

internal static class UpscaleProcess
{
    const uint CreateSuspended = 4, CreateNoWindow = 0x08000000, UseStdHandles = 0x100;
    const uint KillOnJobClose = 0x2000, Infinite = 0xffffffff;

    public static uint Run(string command, IEnumerable<string> args, string directory,
        CancellationToken cancellation, Action<Stream> consume)
    {
        cancellation.ThrowIfCancellationRequested();
        var job = CreateJobObject(IntPtr.Zero, null);
        using (job) {
            Require(!job.IsInvalid);
            var limits = new JobLimits();
            limits.Basic.LimitFlags = KillOnJobClose;
            Require(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JobLimits))));
            var security = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), InheritHandle = true };
            SafeFileHandle reader, writer;
            Require(CreatePipe(out reader, out writer, ref security, 0));
            using (reader)
            using (writer)
            using (var nul = CreateFile("NUL", 0xc0000000, 3, ref security, 3, 0, IntPtr.Zero)) {
                Require(!nul.IsInvalid);
                Require(SetHandleInformation(reader, 1, 0));
                var startup = new StartupInfo {
                    Size = Marshal.SizeOf(typeof(StartupInfo)), Flags = UseStdHandles,
                    StandardInput = nul.DangerousGetHandle(), StandardOutput = writer.DangerousGetHandle(),
                    StandardError = nul.DangerousGetHandle(),
                };
                var commandLine = new StringBuilder(Quote(command));
                foreach (string arg in args) commandLine.Append(' ').Append(Quote(arg));
                ProcessInfo child;
                Require(CreateProcess(command, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    CreateSuspended | CreateNoWindow, IntPtr.Zero, directory, ref startup, out child));
                using (var process = new SafeFileHandle(child.Process, true))
                using (var thread = new SafeFileHandle(child.Thread, true)) {
                    writer.Dispose();
                    nul.Dispose();
                    // No child can spawn an unowned descendant before assignment.
                    if (!AssignProcessToJobObject(job, process)) {
                        int error = Marshal.GetLastWin32Error();
                        TerminateProcess(process, 1);
                        throw new Win32Exception(error);
                    }
                    using (cancellation.Register(() => TerminateJobObject(job, 1))) {
                        cancellation.ThrowIfCancellationRequested();
                        Require(ResumeThread(thread) != uint.MaxValue);
                        using (var output = new FileStream(reader, FileAccess.Read)) consume(output);
                        Require(WaitForSingleObject(process, Infinite) == 0);
                        cancellation.ThrowIfCancellationRequested();
                        uint exitCode;
                        Require(GetExitCodeProcess(process, out exitCode));
                        return exitCode;
                    }
                }
            }
        }
    }

    static void Require(bool success)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    static string Quote(string value)
    {
        var quoted = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in value) {
            if (c == '\\') { backslashes++; continue; }
            quoted.Append('\\', c == '"' ? backslashes * 2 + 1 : backslashes).Append(c);
            backslashes = 0;
        }
        return quoted.Append('\\', backslashes * 2).Append('"').ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle; }
    [StructLayout(LayoutKind.Sequential)]
    struct BasicJobLimits {
        public long ProcessTimeLimit, JobTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    struct JobLimits {
        public BasicJobLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute;
        public uint Flags;
        public short ShowWindow, ReservedCount;
        public IntPtr ReservedBytes, StandardInput, StandardOutput, StandardError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle reader, out SafeFileHandle writer, ref SecurityAttributes security, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, ref SecurityAttributes security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(SafeFileHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(SafeFileHandle process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(SafeFileHandle handle, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(SafeFileHandle process, out uint exitCode);
}
