using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal sealed class UpscaleFailure : Exception
{
    public UpscaleFailure(string reason) : base(reason) {}
}

internal static class UpscaleData
{
    public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    public static JavaScriptSerializer Json() => new JavaScriptSerializer { MaxJsonLength = 1024 * 1024, RecursionLimit = 20 };

    public static byte[] Read(string path, int limit)
    {
        RejectLinks(path);
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            if (stream.Length > limit) throw new InvalidDataException();
            using (var output = new MemoryStream((int)stream.Length)) {
                stream.CopyTo(output);
                if (output.Length > limit) throw new InvalidDataException();
                return output.ToArray();
            }
        }
    }

    public static Dictionary<string, object> Parse(byte[] data)
    {
        int start = data.Length >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf ? 3 : 0;
        return Parse(Utf8.GetString(data, start, data.Length - start));
    }

    public static Dictionary<string, object> Parse(string text)
    {
        var value = Json().DeserializeObject(text) as Dictionary<string, object>;
        if (value == null) throw new InvalidDataException();
        return value;
    }

    public static string Text(Dictionary<string, object> value, string name)
    {
        object field;
        return value.TryGetValue(name, out field) ? field as string : null;
    }

    public static long Number(Dictionary<string, object> value, string name)
    {
        object field;
        if (!value.TryGetValue(name, out field) || (!(field is int) && !(field is long))) throw new InvalidDataException();
        return Convert.ToInt64(field, CultureInfo.InvariantCulture);
    }

    public static bool Flag(Dictionary<string, object> value, string name)
    {
        object field;
        return value.TryGetValue(name, out field) && field is bool && (bool)field;
    }

    public static string Hex(byte[] data) => BitConverter.ToString(data).Replace("-", "").ToLowerInvariant();
    public static bool IsHash(string value) => value != null && value.Length == 64 &&
        value.All(character => character >= '0' && character <= '9' || character >= 'a' && character <= 'f');
    public static string Hash(byte[] data) { using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(data)); }

    public static string Full(string path)
    {
        if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || path.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\.\", StringComparison.Ordinal)) throw new InvalidDataException();
        string full = Path.GetFullPath(path);
        return full.Length > Path.GetPathRoot(full).Length ? full.TrimEnd('\\', '/') : full;
    }

    public static bool SamePath(string left, string right) => String.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    public static string Relative(string root, string path)
    {
        if (String.IsNullOrEmpty(path)) throw new InvalidDataException();
        foreach (string part in path.Split('/')) {
            if (part.Length == 0 || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                part.EndsWith(".") || part.EndsWith(" ")) throw new InvalidDataException();
            string device = part.Split('.')[0].ToUpperInvariant();
            if (device == "CON" || device == "PRN" || device == "AUX" || device == "NUL" ||
                device.Length == 4 && (device.StartsWith("COM") || device.StartsWith("LPT")) &&
                Char.IsDigit(device[3])) throw new InvalidDataException();
        }
        return Path.Combine(root, path.Replace('/', '\\'));
    }

    public static void RejectLinks(string path)
    {
        for (string current = path; !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current)) {
            try {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new UpscaleFailure("bundle_conflict");
            } catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    public static void DeleteOwnedStage(string path)
    {
        try {
            RejectLinks(path);
            if (Directory.Exists(path)) Directory.Delete(path, true);
        } catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (UpscaleFailure) { }
    }

    public static void AtomicJson(string path, Dictionary<string, object> value)
    {
        RejectLinks(path);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".part";
        bool created = false;
        try {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                created = true;
                var bytes = Utf8.GetBytes(Json().Serialize(value) + "\n");
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            for (int attempt = 0; ; attempt++) {
                try {
                    if (File.Exists(path)) File.Replace(temporary, path, null);
                    else File.Move(temporary, path);
                    break;
                } catch (IOException error) when (attempt < 4 &&
                    ((error.HResult & 0xffff) == 32 || (error.HResult & 0xffff) == 33)) {
                    // Lua briefly reads the progress file without FILE_SHARE_DELETE.
                    // Only retry that concrete sharing race, not permission/disk errors.
                    Thread.Sleep(25);
                }
            }
        } finally {
            if (created && File.Exists(temporary)) File.Delete(temporary);
        }
    }
}

internal sealed class UpscaleRequest : IDisposable
{
    readonly CancellationTokenSource cancellation = new CancellationTokenSource();
    readonly Process parent;
    readonly Timer monitor;
    public readonly string Id, Operation, ConfigRoot, ProgressPath, Model;
    public readonly int Width, Height;
    public CancellationToken Token => cancellation.Token;

    public UpscaleRequest(string path, Dictionary<string, object> data)
    {
        if (UpscaleData.Number(data, "schema") != 1) throw new UpscaleFailure("invalid_request");
        Id = UpscaleData.Text(data, "request_id");
        if (String.IsNullOrEmpty(Id) || Id.Length > 100 ||
            Id.Any(letter => !Char.IsLetterOrDigit(letter) && letter != '-' && letter != '_')) throw new UpscaleFailure("invalid_request");
        Operation = UpscaleData.Text(data, "operation");
        if (Operation != "probe" && Operation != "install" && Operation != "prepare") throw new UpscaleFailure("invalid_request");
        ConfigRoot = UpscaleData.Full(UpscaleData.Text(data, "config_root"));
        string helperFolder = UpscaleData.Full(AppDomain.CurrentDomain.BaseDirectory);
        if (!UpscaleData.SamePath(helperFolder, Path.Combine(ConfigRoot, "helpers"))) throw new UpscaleFailure("invalid_request");
        ProgressPath = UpscaleData.Full(UpscaleData.Text(data, "progress_path"));
        if (!UpscaleData.SamePath(ProgressPath, path + ".status.json")) throw new UpscaleFailure("invalid_request");
        UpscaleData.RejectLinks(ProgressPath);
        if (Operation == "prepare") {
            Model = UpscaleData.Text(data, "model");
            long width = UpscaleData.Number(data, "width"), height = UpscaleData.Number(data, "height");
            if ((Model != "CUGAN" && Model != "ESRGAN") || width < 16 || width > 854 || height < 16 || height > 480)
                throw new UpscaleFailure("unsupported_input");
            Width = (int)width;
            Height = (int)height;
        }
        long pid = UpscaleData.Number(data, "parent_pid");
        if (pid <= 0 || pid > Int32.MaxValue || pid == Process.GetCurrentProcess().Id) throw new UpscaleFailure("invalid_request");
        parent = Process.GetProcessById((int)pid);
        try {
            if (parent.HasExited || File.Exists(path + ".cancel")) throw new UpscaleFailure("cancelled");
            monitor = new Timer(_ => {
                try {
                    if (parent.HasExited || File.Exists(path + ".cancel")) cancellation.Cancel();
                } catch (InvalidOperationException) { }
                catch (Win32Exception) { cancellation.Cancel(); }
            }, null, 100, 100);
        } catch {
            parent.Dispose();
            throw;
        }
    }

    public void Progress(string phase, Dictionary<string, object> data = null)
    {
        Token.ThrowIfCancellationRequested();
        var status = data == null ? new Dictionary<string, object>() : new Dictionary<string, object>(data);
        status["schema"] = 1;
        status["request_id"] = Id;
        status["phase"] = phase;
        try { UpscaleData.AtomicJson(ProgressPath, status); }
        catch (IOException) { } // The UI may briefly hold the previous status open.
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        using (var stopped = new ManualResetEvent(false)) {
            monitor.Dispose(stopped);
            stopped.WaitOne();
        }
        cancellation.Dispose();
        parent.Dispose();
    }
}

internal sealed class UpscaleDevice
{
    public readonly int Id;
    public readonly string Uuid, Driver;

    UpscaleDevice(int id, string uuid, string driver) { Id = id; Uuid = uuid; Driver = driver; }

    public static UpscaleDevice Detect()
    {
        SystemInfo hardware;
        GetNativeSystemInfo(out hardware);
        if (!Environment.Is64BitProcess || hardware.Architecture != 9)
            throw new UpscaleFailure("unsupported_architecture");
        string system = Environment.SystemDirectory;
        foreach (string name in new[] { "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll" })
            if (!File.Exists(Path.Combine(system, name)) ||
                FileVersionInfo.GetVersionInfo(Path.Combine(system, name)).FileMajorPart != 14)
                throw new UpscaleFailure("crt_missing");

        try {
            int version, count;
            if (Init(0) != 0 || DriverVersion(out version) != 0 || Count(out count) != 0 || count < 1)
                throw new UpscaleFailure("gpu_unavailable");
            if (version < 13000) throw new UpscaleFailure("driver_unsupported");
            var actual = FileVersionInfo.GetVersionInfo(Path.Combine(system, "nvcuda.dll"));
            string driver = String.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}",
                actual.FileMajorPart, actual.FileMinorPart, actual.FileBuildPart, actual.FilePrivatePart);
            for (int index = 0; index < count; index++) {
                int device, major, minor;
                if (GetDevice(out device, index) != 0 || Attribute(out major, 75, device) != 0 ||
                    Attribute(out minor, 76, device) != 0 || major * 10 + minor < 75) continue;
                var uuid = new byte[16];
                if (UuidOf(uuid, device) == 0) return new UpscaleDevice(index, UpscaleData.Hex(uuid), driver);
            }
            throw new UpscaleFailure("gpu_unsupported");
        } catch (DllNotFoundException) { throw new UpscaleFailure("gpu_unavailable"); }
        catch (EntryPointNotFoundException) { throw new UpscaleFailure("gpu_unavailable"); }
        catch (BadImageFormatException) { throw new UpscaleFailure("gpu_unavailable"); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SystemInfo {
        public ushort Architecture, Reserved;
        public uint PageSize;
        public IntPtr MinimumAddress, MaximumAddress;
        public UIntPtr ActiveProcessorMask;
        public uint ProcessorCount, ProcessorType, AllocationGranularity;
        public ushort ProcessorLevel, ProcessorRevision;
    }

    [DllImport("kernel32.dll")]
    static extern void GetNativeSystemInfo(out SystemInfo info);
    [DllImport("nvcuda.dll", EntryPoint = "cuInit"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int Init(uint flags);
    [DllImport("nvcuda.dll", EntryPoint = "cuDriverGetVersion"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int DriverVersion(out int version);
    [DllImport("nvcuda.dll", EntryPoint = "cuDeviceGetCount"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int Count(out int count);
    [DllImport("nvcuda.dll", EntryPoint = "cuDeviceGet"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int GetDevice(out int device, int ordinal);
    [DllImport("nvcuda.dll", EntryPoint = "cuDeviceGetAttribute"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int Attribute(out int version, int attribute, int device);
    [DllImport("nvcuda.dll", EntryPoint = "cuDeviceGetUuid"), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern int UuidOf([Out] byte[] uuid, int device);
}

internal static class UpscaleProgram
{
    static readonly string[] PreparationReasons = {
        "cache_busy", "cache_invalid", "compile_failed", "prepare_failed", "cancelled"
    };

    [STAThread] public static int Main(string[] args)
    {
        var result = new Dictionary<string, object> { ["schema"] = 1, ["request_id"] = "",
            ["phase"] = "failed", ["ok"] = false };
        try {
            if (args.Length != 2 || args[0] != "-RequestPath") throw new UpscaleFailure("invalid_request");
            string path = UpscaleData.Full(args[1]);
            var data = UpscaleData.Parse(UpscaleData.Read(path, 32 * 1024));
            result["request_id"] = UpscaleData.Text(data, "request_id") ?? "";
            if (UpscaleData.Text(data, "operation") == "window") {
                if (UpscaleData.Number(data, "schema") != 1) throw new UpscaleFailure("invalid_request");
                return UpscaleTaskWindow.Run(data);
            }
            using (var request = new UpscaleRequest(path, data)) {
                var components = new UpscaleComponents(request);
                result["download_bytes"] = components.DownloadBytes;
                result["expanded_bytes"] = components.ExpandedBytes;
                result["bundle_root"] = components.BundleRoot;
                result["bundle_id"] = components.BundleId;
                result["manifest_sha256"] = components.ManifestHash;
                result["component_ready"] = components.IsReady(false);
                var device = UpscaleDevice.Detect();
                result["device_id"] = device.Id;
                result["gpu_uuid"] = device.Uuid;
                result["driver"] = device.Driver;
                if (request.Operation == "probe") result["phase"] = "probed";
                else {
                    using (components.AcquireLock()) {
                        if (request.Operation == "install") components.Install();
                        else Prepare(request, components, device, result);
                    }
                    result["component_ready"] = true;
                    result["phase"] = "ready";
                }
                result["ok"] = true;
            }
        } catch (UpscaleFailure error) { result["error_reason"] = error.Message; }
        catch (OperationCanceledException) { result["error_reason"] = "cancelled"; }
        catch (PathTooLongException) { result["error_reason"] = "component_path_too_long"; }
        catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
            error is ArgumentException || error is InvalidOperationException || error is InvalidDataException || error is Win32Exception ||
            error is NotSupportedException || error is TimeoutException || error is System.Security.SecurityException) {
            result["error_reason"] = "component_io_failed";
        }

        try {
            using (var writer = new StreamWriter(Console.OpenStandardOutput(), UpscaleData.Utf8))
                writer.WriteLine(UpscaleData.Json().Serialize(result));
        } catch (IOException) { return 1; }
        return UpscaleData.Flag(result, "ok") ? 0 : 1;
    }

    static void Prepare(UpscaleRequest request, UpscaleComponents components, UpscaleDevice device,
        Dictionary<string, object> result)
    {
        request.Progress("verifying");
        if (!components.IsReady(true)) throw new UpscaleFailure(components.HasReceipt ? "bundle_integrity" : "components_missing");
        string stage = components.CreateStage();
        try {
            string script = Path.Combine(request.ConfigRoot, "upscale", "prepare.py");
            UpscaleData.RejectLinks(script);
            string dataPath = Path.Combine(stage, "prepare.json");
            UpscaleData.AtomicJson(dataPath, new Dictionary<string, object> {
                ["model"] = request.Model, ["width"] = request.Width, ["height"] = request.Height,
                ["bundle_root"] = components.BundleRoot, ["cache_root"] = components.CacheRoot,
                ["staging_root"] = stage, ["bundle_id"] = components.BundleId,
                ["manifest_sha256"] = components.ManifestHash, ["gpu_uuid"] = device.Uuid,
                ["driver"] = device.Driver, ["device_id"] = device.Id,
            });
            UpscaleData.RejectLinks(components.CacheRoot);
            Dictionary<string, object> last = null;
            string python = Path.Combine(components.BundleRoot, "runtime", "python.exe");
            uint exitCode = UpscaleProcess.Run(python, new[] { "-B", script, dataPath }, Path.GetDirectoryName(python),
                request.Token, output => {
                    using (var reader = new StreamReader(output, UpscaleData.Utf8)) {
                        string line;
                        while ((line = reader.ReadLine()) != null) {
                            request.Token.ThrowIfCancellationRequested();
                            if (line.Length > 8192) throw new UpscaleFailure("prepare_failed");
                            var stageData = UpscaleData.Parse(line);
                            string phase = UpscaleData.Text(stageData, "phase");
                            if (phase == "ready" || phase == "failed") last = stageData;
                            else if (phase == "converting" || phase == "compiling" || phase == "checking")
                                request.Progress(phase);
                            else throw new UpscaleFailure("prepare_failed");
                        }
                    }
                });
            if (last == null || exitCode != 0 || UpscaleData.Text(last, "phase") != "ready" || !UpscaleData.Flag(last, "ok")) {
                string reason = last == null ? null : UpscaleData.Text(last, "error_reason");
                throw new UpscaleFailure(PreparationReasons.Contains(reason) ? reason : "prepare_failed");
            }
            string key = UpscaleData.Text(last, "cache_key");
            if (!UpscaleData.IsHash(key)) throw new UpscaleFailure("prepare_failed");
            string engine = Path.Combine(components.CacheRoot, key, "model.engine");
            UpscaleData.RejectLinks(engine);
            if (!UpscaleData.SamePath(engine, UpscaleData.Text(last, "engine_path")) || !File.Exists(engine))
                throw new UpscaleFailure("prepare_failed");
            int paddedWidth = request.Model == "CUGAN" ? (request.Width + 3) / 4 * 4 : request.Width;
            int paddedHeight = request.Model == "CUGAN" ? (request.Height + 3) / 4 * 4 : request.Height;
            if (UpscaleData.Number(last, "padded_width") != paddedWidth || UpscaleData.Number(last, "padded_height") != paddedHeight)
                throw new UpscaleFailure("prepare_failed");
            result["engine_path"] = engine;
            result["cache_key"] = key;
            result["cache_hit"] = UpscaleData.Flag(last, "cache_hit");
            result["padded_width"] = paddedWidth;
            result["padded_height"] = paddedHeight;
        } finally { UpscaleData.DeleteOwnedStage(stage); }
    }
}
