using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

internal static class Program
{
    private const string PayloadName = "mpvnet-kit.payload.zip";
    private const string InstallerScript = "tools/installer.ps1";
    private const string Title = "mpv.net 安装器";

    [STAThread]
    private static int Main(string[] args)
    {
        bool extract = args.Length != 0;
        if (extract && (args.Length != 2 || args[0] != "--extract"))
        {
            ReportError("用法：安装程序.exe --extract <尚不存在的本地绝对目录>", true);
            return 2;
        }

        StagedPackage staging = null;
        try
        {
            string destination = extract ? args[1] : Path.Combine(Path.GetTempPath(), "mpvnet-kit-" + Guid.NewGuid().ToString("N"));
            using (var payload = OpenVerifiedPayload())
            using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
            using (staging = new StagedPackage(destination))
            {
                if (archive.GetEntry(InstallerScript) == null || archive.GetEntry("manifest.json") == null)
                    throw new InvalidDataException("内置安装包缺少所需文件，请重新取得完整安装程序。");

                staging.Create();
                staging.Expand(archive);
                if (extract)
                    return 0;

                int exitCode = RunInstaller(staging.Root);
                if (exitCode == 0)
                    staging.CleanUp();
                else
                    ReportError("安装窗口异常退出（退出代码 " + exitCode + "）。" + RetainedPath(staging), false);
                return exitCode;
            }
        }
        catch (Exception error)
        {
            ReportError(error.Message + RetainedPath(staging), extract);
            return 1;
        }
    }

    private static Stream OpenVerifiedPayload()
    {
        var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadName);
        if (stream == null)
            throw new InvalidDataException("找不到内置安装包，请重新取得完整安装程序。");
        try
        {
            using (var sha = SHA256.Create())
            {
                string actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
                if (!string.Equals(actual, InstallerPayload.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("内置安装包校验失败，请重新取得完整安装程序。");
            }
            stream.Position = 0;
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    private static int RunInstaller(string root)
    {
        string script = Path.Combine(root, InstallerScript.Replace('/', '\\'));
        // Windows file paths never contain quotes. The script path is one native argument.
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var installer = Process.Start(start))
        {
            installer.WaitForExit();
            return installer.ExitCode;
        }
    }

    private static string RetainedPath(StagedPackage staging)
    {
        return staging != null && staging.Created ? "\r\n\r\n解包目录已保留。\r\n" + staging.Root : "";
    }

    private static void ReportError(string message, bool commandLine)
    {
        if (commandLine && !NativeFiles.HasStandardError())
            NativeFiles.AttachConsole(uint.MaxValue); // Attach only to the caller's existing console.
        if (NativeFiles.HasStandardError())
        {
            Console.Error.WriteLine(message);
            return;
        }
        MessageBox.Show(message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}

internal sealed class StagedPackage : IDisposable
{
    private static readonly char[] InvalidName = Path.GetInvalidFileNameChars();
    private static readonly HashSet<string> Devices = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³"
    };

    private readonly List<SafeFileHandle> ancestors = new List<SafeFileHandle>();
    private readonly HashSet<string> directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private readonly List<OwnedEntry> entries = new List<OwnedEntry>();
    public string Root { get; }
    public bool Created { get; private set; }

    public StagedPackage(string path)
    {
        path = path.Replace('/', '\\').TrimEnd('\\');
        if (path.Length < 4 || path[1] != ':' || path[2] != '\\' ||
            !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')))
            throw new ArgumentException("解包位置必须是本地绝对目录，例如 D:\\下载\\mpvnet-kit。");
        foreach (string part in path.Substring(3).Split('\\'))
            CheckName(part);
        Root = Path.GetFullPath(path);
    }

    public void Create()
    {
        var parents = new Stack<string>();
        for (var path = Directory.GetParent(Root); path != null; path = path.Parent)
            parents.Push(path.FullName);
        foreach (string path in parents)
            ancestors.Add(NativeFiles.OpenPlain(path, directory: true));
        CreateDirectory(Root);
    }

    public void Expand(ZipArchive archive)
    {
        var buffer = new byte[128 * 1024];
        foreach (var entry in archive.Entries)
        {
            int unixType = (entry.ExternalAttributes >> 16) & 0xf000;
            if ((entry.ExternalAttributes & 0x410) != 0 || (unixType != 0 && unixType != 0x8000))
                throw new InvalidDataException("内置安装包包含非常规文件。\r\n" + entry.FullName);

            string[] parts = entry.FullName.Split('/');
            foreach (string part in parts)
                CheckName(part);
            string directory = Root;
            for (int index = 0; index < parts.Length - 1; index++)
            {
                directory = Path.Combine(directory, parts[index]);
                if (!directories.Contains(directory))
                    CreateDirectory(directory);
            }
            string path = Path.Combine(directory, parts[parts.Length - 1]);
            using (var sha = SHA256.Create())
            {
                NativeFiles.EntryInfo identity;
                using (var input = entry.Open())
                using (var file = NativeFiles.CreateRegularFile(path))
                {
                    identity = NativeFiles.Info(file.SafeFileHandle);
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        sha.TransformBlock(buffer, 0, count, buffer, 0);
                        file.Write(buffer, 0, count);
                    }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    if (file.Length != entry.Length)
                        throw new InvalidDataException("内置文件解包长度不符。\r\n" + entry.FullName);
                }
                // Hold a read-only handle until the installer closes. Recheck bytes after acquiring it.
                AddEntry(path, false, identity, sha.Hash);
            }
        }
    }

    private static void CheckName(string name)
    {
        string device = name.Split('.')[0].TrimEnd(' ');
        if (name.Length == 0 || name.EndsWith(".", StringComparison.Ordinal) || name.EndsWith(" ", StringComparison.Ordinal) ||
            name.IndexOfAny(InvalidName) >= 0 || Devices.Contains(device))
            throw new InvalidDataException("解包路径含有 Windows 不支持的名称。\r\n" + name);
    }

    private void CreateDirectory(string path)
    {
        // Win32 returns an error if anything already occupies this name.
        if (!NativeFiles.CreateDirectory(path, IntPtr.Zero))
            throw new IOException("无法创建全新目录。请确认父目录存在且目标尚不存在。\r\n" + path, new Win32Exception());
        if (path == Root)
            Created = true;
        AddEntry(path, true, null, null);
        directories.Add(path);
    }

    private void AddEntry(string path, bool directory, NativeFiles.EntryInfo? written, byte[] hash)
    {
        var handle = NativeFiles.OpenPlain(path, directory);
        try
        {
            var identity = NativeFiles.Info(handle);
            if (written.HasValue && (!identity.SameAs(written.Value) || identity.Links != 1 || !MatchesHash(handle, hash)))
                throw new IOException("解包文件在写入后发生变化。\r\n" + path);
            entries.Add(new OwnedEntry { Path = path, IsDirectory = directory, Identity = identity, Hash = hash, Lock = handle });
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static bool MatchesHash(SafeFileHandle handle, byte[] hash)
    {
        // FileStream owns its handle. Keep the directory/file lock in the caller's handle.
        using (var stream = new FileStream(new SafeFileHandle(handle.DangerousGetHandle(), false), FileAccess.Read))
        using (var sha = SHA256.Create())
            return hash.SequenceEqual(sha.ComputeHash(stream));
    }

    public void CleanUp()
    {
        // Children precede parents. Removal by verified handle avoids deleting a replacement
        // at the same path, and Windows refuses to remove a directory with leftover contents.
        for (int index = entries.Count - 1; index >= 0; index--)
        {
            OwnedEntry entry = entries[index];
            entry.Lock.Dispose();
            try
            {
                using (var handle = NativeFiles.OpenPlain(entry.Path, entry.IsDirectory, delete: true))
                {
                    var identity = NativeFiles.Info(handle);
                    if (identity.SameAs(entry.Identity) && (entry.IsDirectory ||
                        (identity.Links == 1 && identity.SameWriteTime(entry.Identity) && MatchesHash(handle, entry.Hash))))
                        NativeFiles.TryRemove(handle);
                }
            }
            catch (IOException)
            {
                // Disappeared, replaced, accessed, or inaccessible entries are left alone.
            }
        }
    }

    public void Dispose()
    {
        for (int index = entries.Count - 1; index >= 0; index--)
            entries[index].Lock.Dispose();
        for (int index = ancestors.Count - 1; index >= 0; index--)
            ancestors[index].Dispose();
    }

    private sealed class OwnedEntry
    {
        public string Path;
        public bool IsDirectory;
        public NativeFiles.EntryInfo Identity;
        public byte[] Hash;
        public SafeFileHandle Lock;
    }
}

internal static class NativeFiles
{
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint ListDirectory = 0x00000001;
    private const uint Delete = 0x00010000;
    private const uint CreateNew = 1;
    private const uint OpenExisting = 3;
    private const uint OpenReparsePoint = 0x00200000;
    private const uint BackupSemantics = 0x02000000;
    private const uint FileDispositionInfo = 4;

    public static SafeFileHandle OpenPlain(string path, bool directory, bool delete = false)
    {
        // Attribute-only access would not enforce directory sharing. Listing access locks out
        // renames while sharing writes so independent operations can still use the ancestors.
        uint access = (directory ? ListDirectory : GenericRead) | (delete ? Delete : 0);
        var share = directory ? FileShare.ReadWrite : FileShare.Read;
        var handle = CreateFile(path, access, share, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
        try
        {
            if (handle.IsInvalid)
                throw new IOException("目录或文件无法访问。\r\n" + path, new Win32Exception());
            FileAttributes attributes = Info(handle).Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint);
            if (attributes != (directory ? FileAttributes.Directory : 0))
                throw new IOException("解包路径不得包含文件链接、目录链接或联接点。\r\n" + path);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public static FileStream CreateRegularFile(string path)
    {
        var handle = CreateFile(path, GenericWrite, FileShare.None, IntPtr.Zero, CreateNew, OpenReparsePoint, IntPtr.Zero);
        try
        {
            if (handle.IsInvalid)
                throw new IOException("无法创建全新解包文件。\r\n" + path, new Win32Exception());
            return new FileStream(handle, FileAccess.Write);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public static EntryInfo Info(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out EntryInfo info))
            throw new IOException("无法识别解包文件或目录。", new Win32Exception());
        return info;
    }

    public static void TryRemove(SafeFileHandle handle)
    {
        byte delete = 1;
        SetFileInformationByHandle(handle, FileDispositionInfo, ref delete, 1);
    }

    public static bool HasStandardError()
    {
        return GetFileType(GetStdHandle(-12)) != 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct EntryInfo
    {
        public FileAttributes Attributes;
        public uint CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;

        public bool SameAs(EntryInfo other)
        {
            return Volume == other.Volume && IndexHigh == other.IndexHigh && IndexLow == other.IndexLow &&
                CreationLow == other.CreationLow && CreationHigh == other.CreationHigh;
        }

        public bool SameWriteTime(EntryInfo other)
        {
            return WriteLow == other.WriteLow && WriteHigh == other.WriteHigh;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectory(string path, IntPtr security);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, FileShare share, IntPtr security,
        uint mode, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out EntryInfo info);

    [DllImport("kernel32.dll")]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, uint type, ref byte value, uint size);

    [DllImport("kernel32.dll")]
    public static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int kind);

    [DllImport("kernel32.dll")]
    private static extern uint GetFileType(IntPtr handle);
}
