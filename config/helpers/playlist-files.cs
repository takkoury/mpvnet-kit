using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace KitPlaylistInput
{
    // One isolated core per request. The host's already-loaded DLL determines
    // compatibility; a request cannot select or substitute an arbitrary library.
    public sealed class PlaylistReader : IDisposable
    {
        IntPtr library, core;
        readonly string codepage;
        readonly string libraryPath;
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Create();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Initialize(IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SetOption(IntPtr handle, IntPtr name, IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Command(IntPtr handle, IntPtr arguments);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetString(IntPtr handle, IntPtr name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Free(IntPtr address);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Destroy(IntPtr handle);
        Create create;
        Initialize initialize;
        SetOption setOption;
        Command command;
        GetString getString;
        Free free;
        Destroy destroy;
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
        static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);

        public PlaylistReader(string absoluteLibraryPath, string metadataCodepage = "")
        {
            libraryPath = absoluteLibraryPath;
            codepage = metadataCodepage ?? "";
        }

        public static PlaylistReader ForParent(int parentPid, string metadataCodepage)
        {
            try
            {
                using (var parent = Process.GetProcessById(parentPid))
                    foreach (ProcessModule module in parent.Modules)
                        if (String.Equals(Path.GetFileName(module.FileName), "libmpv-2.dll", StringComparison.OrdinalIgnoreCase))
                            return new PlaylistReader(module.FileName, metadataCodepage);
            }
            catch { }
            throw new InputFailure("playlist_core_unavailable");
        }

        T Bind<T>(string name) where T : class
        {
            IntPtr address = GetProcAddress(library, name);
            if (address == IntPtr.Zero) throw new InputFailure("playlist_core_unavailable");
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }

        static IntPtr Utf8(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
            IntPtr address = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, address, bytes.Length);
            return address;
        }

        void Option(string name, string value)
        {
            IntPtr key = Utf8(name), text = Utf8(value);
            try { if (setOption(core, key, text) < 0) throw new InputFailure("playlist_core_unavailable"); }
            finally { Marshal.FreeHGlobal(key); Marshal.FreeHGlobal(text); }
        }

        void EnsureCore()
        {
            if (core != IntPtr.Zero) return;
            try
            {
                if (!InputProcessor.IsFullyQualified(libraryPath)) throw new InputFailure("playlist_core_unavailable");
                // Dependencies resolve beside this precise host library or in
                // Windows' default safe directories, never the request's cwd.
                library = LoadLibraryExW(libraryPath, IntPtr.Zero, 0x100U | 0x1000U);
                if (library == IntPtr.Zero) throw new InputFailure("playlist_core_unavailable");
                create = Bind<Create>("mpv_create"); initialize = Bind<Initialize>("mpv_initialize");
                setOption = Bind<SetOption>("mpv_set_option_string"); command = Bind<Command>("mpv_command");
                getString = Bind<GetString>("mpv_get_property_string"); free = Bind<Free>("mpv_free");
                destroy = Bind<Destroy>("mpv_terminate_destroy");
                core = create();
                if (core == IntPtr.Zero) throw new InputFailure("playlist_core_unavailable");
                Option("config", "no"); Option("load-scripts", "no"); Option("terminal", "no");
                Option("idle", "yes"); Option("pause", "yes"); Option("vo", "null"); Option("ao", "null");
                if (codepage.Length != 0) Option("metadata-codepage", codepage);
                if (initialize(core) < 0) throw new InputFailure("playlist_core_unavailable");
            }
            catch (InputFailure) { Dispose(); throw; }
            catch { Dispose(); throw new InputFailure("playlist_core_unavailable"); }
        }

        void Run(params string[] values)
        {
            var strings = new List<IntPtr>();
            IntPtr array = Marshal.AllocHGlobal((values.Length + 1) * IntPtr.Size);
            try
            {
                for (int i = 0; i < values.Length; i++)
                {
                    IntPtr value = Utf8(values[i]); strings.Add(value);
                    Marshal.WriteIntPtr(array, i * IntPtr.Size, value);
                }
                Marshal.WriteIntPtr(array, values.Length * IntPtr.Size, IntPtr.Zero);
                if (command(core, array) < 0) throw new InputFailure("playlist_read_failed");
            }
            finally
            {
                foreach (IntPtr value in strings) Marshal.FreeHGlobal(value);
                Marshal.FreeHGlobal(array);
            }
        }

        string Property(string name)
        {
            IntPtr key = Utf8(name), result = IntPtr.Zero;
            try
            {
                result = getString(core, key);
                if (result == IntPtr.Zero) return "";
                int count = 0;
                while (Marshal.ReadByte(result, count) != 0)
                {
                    if (++count > InputProcessor.MaxResponseBytes) throw new InputFailure("input_too_large");
                }
                byte[] bytes = new byte[count];
                Marshal.Copy(result, bytes, 0, count);
                return new UTF8Encoding(false, true).GetString(bytes);
            }
            finally { if (result != IntPtr.Zero) free(result); Marshal.FreeHGlobal(key); }
        }

        static bool Hls(byte[] bytes)
        {
            string text;
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
                text = Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            else if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
                text = Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
            else text = Encoding.UTF8.GetString(bytes);
            using (var lines = new StringReader(text))
            {
                string line;
                while ((line = lines.ReadLine()) != null)
                    if (line.TrimStart('\uFEFF', ' ', '\t').StartsWith("#EXT-X-", StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        public static string SingleLineTitle(string value)
        {
            if (String.IsNullOrEmpty(value)) return "";
            var result = new StringBuilder(value.Length);
            foreach (char character in value) result.Append(Char.IsControl(character) ? ' ' : character);
            return result.ToString();
        }

        public List<InputEntry> Read(string path)
        {
            try
            {
                // Keep the exact bytes stable while libmpv opens the source.
                using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if (source.Length > InputProcessor.MaxBytes) throw new InputFailure("input_too_large");
                    byte[] bytes = new byte[(int)source.Length];
                    int offset = 0, count;
                    while (offset < bytes.Length && (count = source.Read(bytes, offset, bytes.Length - offset)) > 0) offset += count;
                    if (offset != bytes.Length) throw new InputFailure("playlist_read_failed");
                    if (Hls(bytes))
                    {
                        var hls = InputProcessor.Normalize(path, Path.GetDirectoryName(path));
                        hls.kind = "native"; hls.from_playlist = true;
                        return new List<InputEntry> { hls };
                    }
                    EnsureCore();
                    // playlist-clear preserves the selected entry even when
                    // idle. stop releases that selection before the next list.
                    Run("stop");
                    Run("playlist-clear");
                    // append parses the list without starting playback or
                    // recursively opening any referenced list or network URL.
                    Run("loadlist", path, "append");
                    int length;
                    if (!Int32.TryParse(Property("playlist-count"), out length) || length < 0) throw new InputFailure("playlist_read_failed");
                    if (length > InputProcessor.MaxItems) throw new InputFailure("input_too_large");
                    var result = new List<InputEntry>();
                    int outputBytes = 0;
                    for (int i = 0; i < length; i++)
                    {
                        var entry = InputProcessor.Normalize(Property("playlist/" + i + "/filename"), Path.GetDirectoryName(path));
                        if (entry == null) throw new InputFailure("playlist_read_failed");
                        if (entry.kind != "native")
                        {
                            string extension = Path.GetExtension(entry.path).TrimStart('.').ToLowerInvariant();
                            entry.kind = extension == "m3u" || extension == "m3u8" || extension == "pls" || extension == "xspf" ||
                                extension == "iso" || extension == "avs" || extension == "lnk" ? "native" : "media";
                        }
                        entry.from_playlist = true;
                        entry.title = SingleLineTitle(Property("playlist/" + i + "/title"));
                        outputBytes += Encoding.UTF8.GetByteCount(entry.path) + Encoding.UTF8.GetByteCount(entry.title);
                        if (outputBytes > InputProcessor.MaxBytes) throw new InputFailure("input_too_large");
                        result.Add(entry);
                    }
                    return result;
                }
            }
            catch (InputFailure) { throw; }
            catch { throw new InputFailure("playlist_read_failed"); }
        }

        public void Dispose()
        {
            if (core != IntPtr.Zero) { destroy(core); core = IntPtr.Zero; }
            if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
        }
    }

    public sealed class SaveEntry
    {
        public string path;
        public string title;
    }

    public static class PlaylistStorage
    {
        static string Target(string value)
        {
            if (!InputProcessor.Clean(value, InputProcessor.MaxPathLength) || !InputProcessor.IsFullyQualified(value))
                throw new InputFailure("invalid_request");
            var entry = InputProcessor.Normalize(value, Path.GetPathRoot(value));
            if (entry == null || entry.kind == "native" || !Path.GetExtension(entry.path).Equals(".m3u8", StringComparison.OrdinalIgnoreCase))
                throw new InputFailure("invalid_target");
            return entry.path;
        }

        public static void ParseSaveRequest(InputRequest request, Dictionary<string, object> data)
        {
            object target, exists, hash, entries;
            if (!data.TryGetValue("target_path", out target) || !(target is string) ||
                !data.TryGetValue("target_exists", out exists) || !(exists is bool) ||
                !data.TryGetValue("target_sha256", out hash) || !(hash is string) ||
                !data.TryGetValue("save_entries", out entries)) throw new InputFailure("invalid_request");
            request.TargetPath = Target((string)target);
            request.TargetExists = (bool)exists; request.TargetSha256 = (string)hash;
            if (request.TargetExists ? !Regex.IsMatch(request.TargetSha256, "^[a-fA-F0-9]{64}$") : request.TargetSha256 != "")
                throw new InputFailure("invalid_request");
            var array = entries as IList;
            if (array == null || array.Count == 0 || array.Count > InputProcessor.MaxItems) throw new InputFailure("invalid_request");
            request.SaveEntries = new List<SaveEntry>();
            foreach (object value in array)
            {
                var entry = value as Dictionary<string, object>;
                object path, title;
                if (entry == null || !entry.TryGetValue("path", out path) || !(path is string) ||
                    !InputProcessor.Clean((string)path, InputProcessor.MaxPathLength)) throw new InputFailure("invalid_request");
                title = entry.TryGetValue("title", out title) ? title : "";
                if (!(title is string) || ((string)title).Length > InputProcessor.MaxPathLength) throw new InputFailure("invalid_request");
                request.SaveEntries.Add(new SaveEntry { path = (string)path, title = PlaylistReader.SingleLineTitle((string)title) });
            }
        }

        static string Hash(FileStream stream)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        static bool Snapshot(string path, out string hash)
        {
            hash = "";
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                    hash = Hash(stream);
                return true;
            }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }
        }

        public static void TakeSnapshot(string target, InputResponse response)
        {
            try
            {
                response.target_path = Target(target);
                response.target_exists = Snapshot(response.target_path, out response.target_sha256);
            }
            catch (InputFailure) { throw; }
            catch { throw new InputFailure("save_failed"); }
        }

        static byte[] Content(InputRequest request)
        {
            string directory = Path.GetDirectoryName(request.TargetPath).TrimEnd('\\') + "\\";
            var text = new StringBuilder("#EXTM3U\n");
            foreach (var saved in request.SaveEntries)
            {
                var entry = InputProcessor.Normalize(saved.path, request.WorkingDirectory);
                if (entry == null) throw new InputFailure("invalid_request");
                string path = entry.path;
                if (entry.kind != "native" && path.StartsWith(directory, StringComparison.OrdinalIgnoreCase))
                {
                    path = path.Substring(directory.Length);
                    // A literal leading # is an M3U comment without this local
                    // path prefix. Percent signs stay literal, never URI-escaped.
                    if (path.StartsWith("#", StringComparison.Ordinal)) path = ".\\" + path;
                }
                if (saved.title.Length != 0) text.Append("#EXTINF:-1,").Append(saved.title).Append('\n');
                text.Append(path).Append('\n');
                if (text.Length > InputProcessor.MaxBytes) throw new InputFailure("input_too_large");
            }
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(text.ToString());
            if (bytes.Length > InputProcessor.MaxBytes) throw new InputFailure("input_too_large");
            return bytes;
        }

        public static InputResponse Save(InputRequest request, Action ensureParent = null)
        {
            string temporary = null;
            try
            {
                byte[] bytes = Content(request);
                string candidate = Path.Combine(Path.GetDirectoryName(request.TargetPath), ".mpvnet-playlist-" + Guid.NewGuid().ToString("N") + ".tmp");
                using (var stream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    temporary = candidate;
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                // Serialize this application's writers across player instances;
                // recheck only after acquiring the target's short commit lock.
                string identity;
                using (var sha = SHA256.Create())
                    identity = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(request.TargetPath.ToLowerInvariant()))).Replace("-", "");
                using (var mutex = new Mutex(false, @"Local\mpvnet-kit-playlist-" + identity))
                {
                    bool acquired = false;
                    try
                    {
                        try { acquired = mutex.WaitOne(5000); }
                        catch (AbandonedMutexException) { acquired = true; }
                        if (!acquired) throw new InputFailure("target_busy");
                        string currentHash;
                        bool exists = Snapshot(request.TargetPath, out currentHash);
                        if (exists != request.TargetExists || !String.Equals(currentHash, request.TargetSha256, StringComparison.OrdinalIgnoreCase))
                            throw new InputFailure("target_changed");
                        // External writers do not share this mutex. This final
                        // snapshot is optimistic; Windows ReplaceFile has no
                        // content-based compare-and-swap operation.
                        if (ensureParent != null) ensureParent();
                        if (exists) File.Replace(temporary, request.TargetPath, null);
                        else
                        {
                            try { File.Move(temporary, request.TargetPath); }
                            catch (IOException) { if (File.Exists(request.TargetPath)) throw new InputFailure("target_changed"); throw; }
                        }
                    }
                    finally { if (acquired) mutex.ReleaseMutex(); }
                }
                temporary = null;
                return new InputResponse { request_id = request.RequestId, saved = true, target_path = request.TargetPath };
            }
            catch (InputFailure) { throw; }
            catch { throw new InputFailure("save_failed"); }
            finally
            {
                if (temporary != null)
                    try { File.Delete(temporary); } catch { }
            }
        }
    }
}
