using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace KitPlaylistInput
{
    public sealed class InputRequest
    {
        public string RequestId;
        public int ParentPid;
        public string Operation;
        public string Mode;
        public string WorkingDirectory;
        public string[] Paths;
        public string[] VideoExtensions;
        public string[] AudioExtensions;
        public string[] SubtitleExtensions;
        public string[] ExistingPaths;
    }

    public sealed class InputEntry
    {
        public string path;
        public string kind;
        public string key;
    }

    public sealed class InputResponse
    {
        public int schema = 1;
        public string request_id = "";
        public string status = "ok";
        public List<InputEntry> entries = new List<InputEntry>();
        public bool single_media;
        public int skipped;
        public int duplicates;
        public string error_code = "";
    }

    public sealed class InputFailure : Exception
    {
        public readonly string Code;
        public InputFailure(string code) { Code = code; }
    }

    // Only this boundary touches Windows UI/clipboard. Tests inject a source;
    // the production executable has no test command or clipboard write path.
    public interface IInputSource
    {
        string[] SelectFiles(InputRequest request);
        string[] ReadClipboard();
    }

    public static class InputProcessor
    {
        public const int MaxBytes = 2 * 1024 * 1024;
        public const int MaxItems = 10000;
        public const int MaxPathLength = 32767;

        static bool Clean(string value, int limit)
        {
            if (value == null || value.Length == 0 || value.Length > limit) return false;
            foreach (char c in value) if (char.IsControl(c)) return false;
            return true;
        }

        static string StringField(Dictionary<string, object> data, string name)
        {
            object value;
            if (!data.TryGetValue(name, out value) || !(value is string)) throw new InputFailure("invalid_request");
            return (string)value;
        }

        static int IntegerField(Dictionary<string, object> data, string name)
        {
            object value;
            if (!data.TryGetValue(name, out value) || !(value is int)) throw new InputFailure("invalid_request");
            return (int)value;
        }

        static string[] ArrayField(Dictionary<string, object> data, string name, bool optional = false)
        {
            object value;
            if (!data.TryGetValue(name, out value))
            {
                if (optional) return new string[0];
                throw new InputFailure("invalid_request");
            }
            var array = value as IList;
            if (array == null || array.Count > MaxItems) throw new InputFailure("invalid_request");
            var result = new string[array.Count];
            for (int i = 0; i < array.Count; i++)
            {
                result[i] = array[i] as string;
                if (!Clean(result[i], MaxPathLength)) throw new InputFailure("invalid_request");
            }
            return result;
        }

        public static InputRequest ParseRequest(string text)
        {
            try
            {
                if (text == null || Encoding.UTF8.GetByteCount(text) > MaxBytes) throw new InputFailure("invalid_request");
                var serializer = new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 16 };
                var data = serializer.DeserializeObject(text) as Dictionary<string, object>;
                if (data == null || IntegerField(data, "schema") != 1) throw new InputFailure("invalid_request");
                var request = new InputRequest {
                    RequestId = StringField(data, "request_id"), ParentPid = IntegerField(data, "parent_pid"),
                    Operation = StringField(data, "operation"), Mode = StringField(data, "mode"),
                    WorkingDirectory = StringField(data, "working_directory"),
                    VideoExtensions = ArrayField(data, "video_exts"), AudioExtensions = ArrayField(data, "audio_exts"),
                    SubtitleExtensions = ArrayField(data, "subtitle_exts"),
                    ExistingPaths = ArrayField(data, "existing_paths"), Paths = ArrayField(data, "paths", true)
                };
                if (!Clean(request.RequestId, 128) || request.ParentPid <= 0 ||
                    (request.Operation != "files" && request.Operation != "clipboard" && request.Operation != "paths") ||
                    (request.Mode != "open" && request.Mode != "append") ||
                    !Clean(request.WorkingDirectory, MaxPathLength) || !IsFullyQualified(request.WorkingDirectory))
                    throw new InputFailure("invalid_request");
                request.WorkingDirectory = Path.GetFullPath(request.WorkingDirectory);
                if (request.Operation == "paths" && !data.ContainsKey("paths")) throw new InputFailure("invalid_request");
                Extensions(request.VideoExtensions, request.AudioExtensions, request.SubtitleExtensions);
                return request;
            }
            catch (InputFailure) { throw; }
            catch { throw new InputFailure("invalid_request"); }
        }

        static HashSet<string> Extensions(params string[][] groups)
        {
            var extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string[] values in groups)
                foreach (string value in values)
                {
                    string extension = value.TrimStart('.');
                    if (!Regex.IsMatch(extension, "^[a-zA-Z0-9_+-]{1,32}$")) throw new InputFailure("invalid_request");
                    extensions.Add(extension);
                }
            return extensions;
        }

        static bool IsFullyQualified(string value)
        {
            return value.StartsWith(@"\\", StringComparison.Ordinal) ||
                (value.Length >= 3 && char.IsLetter(value[0]) && value[1] == ':' && (value[2] == '\\' || value[2] == '/'));
        }

        // Keys describe Windows path identity, without opening media or resolving
        // links. A queue entry may no longer exist and must still deduplicate.
        public static InputEntry Normalize(string input, string directory)
        {
            if (!Clean(input, MaxPathLength)) return null;
            string value = input.Trim();
            if (value.Length >= 2 && value[0] == '"' && value[value.Length - 1] == '"') value = value.Substring(1, value.Length - 2);
            if (!Clean(value, MaxPathLength)) return null;
            try
            {
                Uri uri;
                bool drive = value.Length >= 2 && char.IsLetter(value[0]) && value[1] == ':';
                if (!drive && Uri.TryCreate(value, UriKind.Absolute, out uri) &&
                    (!uri.IsUnc || value.StartsWith("file:", StringComparison.OrdinalIgnoreCase)))
                {
                    if (!uri.IsFile) return new InputEntry { path = value, key = value, kind = "native" };
                    value = uri.LocalPath;
                }
                value = value.Replace('/', '\\');
                if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) value = @"\\" + value.Substring(8);
                else if (value.StartsWith(@"\\?\", StringComparison.Ordinal)) value = value.Substring(4);
                if (value.StartsWith(@"\\.\", StringComparison.Ordinal) ||
                    (value.Length >= 2 && value[1] == ':' && !IsFullyQualified(value))) return null;
                if (value.StartsWith(@"\", StringComparison.Ordinal) && !value.StartsWith(@"\\", StringComparison.Ordinal))
                    value = Path.GetPathRoot(directory).TrimEnd('\\') + value;
                string full = Path.GetFullPath(Path.Combine(directory, value));
                if (full.Length > MaxPathLength || full.IndexOf(':', 2) >= 0) return null;
                return new InputEntry { path = full, key = full.ToLowerInvariant(), kind = "" };
            }
            catch { return null; }
        }

        public static string[] ParseClipboardText(string text)
        {
            if (text == null) return new string[0];
            if (Encoding.UTF8.GetByteCount(text) > MaxBytes) throw new InputFailure("input_unavailable");
            var lines = new List<string>();
            using (var reader = new StringReader(text))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    if (lines.Count == MaxItems) throw new InputFailure("input_unavailable");
                    lines.Add(line.Trim());
                }
            }
            return lines.ToArray();
        }

        public static InputResponse Process(InputRequest request, IInputSource source)
        {
            var response = new InputResponse { request_id = request.RequestId };
            string[] inputs = request.Operation == "files" ? source.SelectFiles(request) :
                request.Operation == "clipboard" ? source.ReadClipboard() : request.Paths;
            if (inputs == null) { response.status = "cancelled"; return response; }
            if (inputs.Length > MaxItems) throw new InputFailure("input_unavailable");
            var extensions = Extensions(request.VideoExtensions, request.AudioExtensions);
            var subtitles = Extensions(request.SubtitleExtensions);
            // Local keys are already case-folded. URL paths remain case-sensitive.
            var seen = new HashSet<string>(StringComparer.Ordinal);
            if (request.Mode == "append")
                foreach (string path in request.ExistingPaths)
                {
                    var existing = Normalize(path, request.WorkingDirectory);
                    if (existing != null) seen.Add(existing.key);
                }
            foreach (string path in inputs)
            {
                var entry = Normalize(path, request.WorkingDirectory);
                if (entry == null) { response.skipped++; continue; }
                if (entry.kind != "native")
                {
                    if (!File.Exists(entry.path)) { response.skipped++; continue; }
                    string extension = Path.GetExtension(entry.path).TrimStart('.');
                    // These formats need mpv.net's private LoadFiles preprocessing.
                    // Reject the whole request before Lua can replace its queue.
                    if (extension.Equals("iso", StringComparison.OrdinalIgnoreCase) ||
                        extension.Equals("avs", StringComparison.OrdinalIgnoreCase) || extension.Equals("lnk", StringComparison.OrdinalIgnoreCase))
                    {
                        if (request.Operation != "paths") throw new InputFailure("native_entry_required");
                        response.skipped++;
                        continue;
                    }
                    bool playlist = extension.Equals("m3u", StringComparison.OrdinalIgnoreCase) ||
                        extension.Equals("m3u8", StringComparison.OrdinalIgnoreCase) || extension.Equals("pls", StringComparison.OrdinalIgnoreCase);
                    entry.kind = playlist ? "native" : subtitles.Contains(extension) ? "subtitle" : extensions.Contains(extension) ? "media" : "native";
                }
                if (request.Operation == "paths" && entry.kind != "media") { response.skipped++; continue; }
                if (!seen.Add(entry.key)) { response.duplicates++; continue; }
                response.entries.Add(entry);
            }
            response.single_media = request.Mode == "open" && inputs.Length == 1 &&
                response.entries.Count == 1 && response.entries[0].kind == "media";
            return response;
        }
    }

    sealed class WindowOwner : IWin32Window
    {
        public IntPtr Handle { get; private set; }
        public WindowOwner(IntPtr handle) { Handle = handle; }
    }

    sealed class WindowsInputSource : IInputSource
    {
        readonly Process parent;
        public WindowsInputSource(Process process) { parent = process; }
        delegate bool EnumWindowCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback, IntPtr parameter);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);

        IntPtr ParentWindow()
        {
            IntPtr found = IntPtr.Zero;
            long largest = -1;
            EnumWindows(delegate(IntPtr window, IntPtr parameter) {
                uint pid;
                GetWindowThreadProcessId(window, out pid);
                if (pid != parent.Id || !IsWindowVisible(window) || GetWindow(window, 4) != IntPtr.Zero) return true;
                // Match the playlist follower's main-window rules. mpv.net's
                // WinForms class name is generated, and menus can be ownerless.
                uint style = unchecked((uint)GetWindowLong(window, -16));
                uint extended = unchecked((uint)GetWindowLong(window, -20));
                if ((style & 0x40000000U) != 0 || (extended & (0x80U | 0x08000000U)) != 0) return true;
                Rect rect;
                if (GetWindowRect(window, out rect))
                {
                    long area = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
                    if (area > largest) { largest = area; found = window; }
                }
                return true;
            }, IntPtr.Zero);
            if (found == IntPtr.Zero) throw new InputFailure("parent_unavailable");
            return found;
        }

        public string[] SelectFiles(InputRequest request)
        {
            IntPtr owner = ParentWindow();
            using (var dialog = new OpenFileDialog())
            {
                dialog.Title = request.Mode == "append" ? "追加文件" : "打开文件";
                dialog.Filter = "所有文件 (*.*)|*.*";
                dialog.Multiselect = true;
                dialog.CheckFileExists = true;
                dialog.CheckPathExists = true;
                dialog.RestoreDirectory = true;
                dialog.DereferenceLinks = false;
                dialog.InitialDirectory = request.WorkingDirectory;
                return dialog.ShowDialog(new WindowOwner(owner)) == DialogResult.OK ? dialog.FileNames : null;
            }
        }

        public string[] ReadClipboard()
        {
            try
            {
                if (Clipboard.ContainsFileDropList())
                {
                    var files = Clipboard.GetFileDropList();
                    if (files.Count > InputProcessor.MaxItems) throw new InputFailure("input_unavailable");
                    var result = new string[files.Count];
                    files.CopyTo(result, 0);
                    return result;
                }
                return Clipboard.ContainsText() ? InputProcessor.ParseClipboardText(Clipboard.GetText()) : new string[0];
            }
            catch (InputFailure) { throw; }
            catch { throw new InputFailure("input_unavailable"); }
        }
    }

    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            // Setting OutputEncoding calls console APIs, which fail for winexe.
            // Open the inherited pipe directly; mpv captures it without a console.
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
            var response = new InputResponse();
            try
            {
                if (args.Length != 2 || args[0] != "-RequestPath") throw new InputFailure("invalid_arguments");
                string text;
                using (var stream = new FileStream(args[1], FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if (stream.Length > InputProcessor.MaxBytes) throw new InputFailure("invalid_request");
                    using (var bytes = new MemoryStream())
                    {
                        var buffer = new byte[8192];
                        int count;
                        while ((count = stream.Read(buffer, 0, Math.Min(buffer.Length, InputProcessor.MaxBytes + 1 - (int)bytes.Length))) > 0)
                        {
                            bytes.Write(buffer, 0, count);
                            if (bytes.Length > InputProcessor.MaxBytes) throw new InputFailure("invalid_request");
                        }
                        var data = bytes.ToArray();
                        int start = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
                        try { text = new UTF8Encoding(false, true).GetString(data, start, data.Length - start); }
                        catch { throw new InputFailure("invalid_request"); }
                    }
                }
                var request = InputProcessor.ParseRequest(text);
                response.request_id = request.RequestId;
                Application.EnableVisualStyles();
                response = Execute(request, null);
            }
            catch (InputFailure failure) { response.status = "error"; response.error_code = failure.Code; }
            catch { response.status = "error"; response.error_code = "internal_error"; }
            Console.Out.WriteLine(new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }.Serialize(response));
            return response.status == "error" ? 1 : 0;
        }

        public static InputResponse Execute(InputRequest request, IInputSource source)
        {
            using (var parent = FindParent(request.ParentPid))
            {
                // Observe exit even while the native dialog pumps messages.
                // Terminate only this single-request helper, never the player.
                parent.Exited += delegate { Environment.Exit(0); };
                parent.EnableRaisingEvents = true;
                if (parent.HasExited) throw new InputFailure("parent_unavailable");
                return InputProcessor.Process(request, source ?? new WindowsInputSource(parent));
            }
        }

        static Process FindParent(int pid)
        {
            try
            {
                if (pid == Process.GetCurrentProcess().Id) throw new InputFailure("parent_unavailable");
                return Process.GetProcessById(pid);
            }
            catch { throw new InputFailure("parent_unavailable"); }
        }
    }
}
