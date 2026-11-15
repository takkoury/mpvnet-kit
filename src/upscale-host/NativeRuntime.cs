using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace KitUpscaleHost;

internal sealed class HostFailure(string reason, string module = "", int win32Error = 0) : Exception(reason)
{
    internal string Reason { get; } = reason;
    internal string Module { get; } = module;
    internal int Win32Error { get; } = win32Error;
}

internal sealed class NativeRuntime
{
    private const uint LoadLibrarySearchDllLoadDir = 0x100;
    private const uint LoadLibrarySearchSystem32 = 0x800;
    private const int VapourSynthScriptApi4 = 4 << 16;
    private static readonly Dictionary<string, string> ExpectedModules = RuntimeBundle.NativeLoadOrder
        .Append(RuntimeBundle.PythonModule).Concat(RuntimeBundle.VapourSynthFilters)
        .ToDictionary(path => Path.GetFileName(path), StringComparer.OrdinalIgnoreCase);
    private readonly List<IntPtr> _references = [];
    private readonly Dictionary<string, string> _loadedPaths = new(StringComparer.OrdinalIgnoreCase);
    private string? _bundleRoot;
    private bool _initialized;
    private HostFailure? _loadFailure;

    internal IReadOnlyDictionary<string, string> LoadedPaths => _loadedPaths;

    internal void Load(string configRoot, string bundleId)
    {
        if (_bundleRoot != null)
        {
            var requestedRoot = RuntimeBundle.Resolve(configRoot, "components/ai-upscale/bundles/" + bundleId);
            if (!PathEquals(_bundleRoot, requestedRoot))
                throw new HostFailure("runtime-in-use");
            if (_loadFailure != null)
                throw _loadFailure;
            if (!_initialized)
                throw new HostFailure("runtime-load");
            CheckModules(_bundleRoot, true);
            return;
        }

        var root = RuntimeBundle.Verify(configRoot, bundleId);
        CheckModules(root, false);
        try
        {
            foreach (var relative in RuntimeBundle.NativeLoadOrder)
            {
                var path = RuntimeBundle.Resolve(root, relative);
                var name = Path.GetFileName(path);
                var module = LoadLibraryExW(path, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchSystem32);
                if (module == IntPtr.Zero)
                    throw new HostFailure("runtime-load", name, Marshal.GetLastPInvokeError());

                // Keep our loader references for the process lifetime. VSScript and libmpv cache native state.
                _references.Add(module);
                _bundleRoot = root;
                CheckModules(root, true);
            }

            // R79 initializes with Py_InitializeEx. Set the equivalent of -B on our pinned Python
            // before that call so importing the wheel leaves the verified bundle unchanged.
            var bytecodeFlag = GetProcAddress(_references[0], "Py_DontWriteBytecodeFlag");
            if (bytecodeFlag == IntPtr.Zero)
                throw new HostFailure("python-isolation", "python312.dll");
            Marshal.WriteInt32(bytecodeFlag, 1);

            var lookup = GetProcAddress(_references[^1], "getVSScriptAPI");
            if (lookup == IntPtr.Zero ||
                Marshal.GetDelegateForFunctionPointer<GetVSScriptApi>(lookup)(VapourSynthScriptApi4) == IntPtr.Zero)
                throw new HostFailure("vsscript-api", "vsscript.dll");

            CheckModules(root, true);
            foreach (var relative in RuntimeBundle.NativeLoadOrder.Append(RuntimeBundle.PythonModule))
            {
                var name = Path.GetFileName(relative);
                if (!_loadedPaths.ContainsKey(name))
                    throw new HostFailure("runtime-path", name);
            }
            _initialized = true;
        }
        catch (HostFailure failure) when (_bundleRoot != null)
        {
            _loadFailure = failure;
            throw;
        }
    }

    private void CheckModules(string root, bool owned)
    {
        using var process = Process.GetCurrentProcess();
        foreach (var module in process.Modules.Cast<ProcessModule>())
        {
            var name = module.ModuleName;
            bool python = Regex.IsMatch(name, @"\Apython[0-9]*t?(_d)?\.dll\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            bool vapourSynth = Regex.IsMatch(name, @"\A(vsscript.*\.dll|(?:lib)?vapoursynth.*\.(?:dll|pyd))\z",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (!python && !vapourSynth)
                continue;

            if (!owned || !ExpectedModules.TryGetValue(name, out var relative) ||
                !PathEquals(RuntimeBundle.Resolve(root, relative), module.FileName))
                throw new HostFailure(python ? "python-conflict" : "vapoursynth-conflict", name);
            _loadedPaths[name] = module.FileName;
        }
    }

    private static bool PathEquals(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr GetVSScriptApi(int version);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);
}
