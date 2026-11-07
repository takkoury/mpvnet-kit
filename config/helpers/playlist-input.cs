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
        public string[] ImageExtensions;
        public string[] ExistingPaths;
        public string MetadataCodepage;
        public string SuggestedPath;
        public string TargetPath;
        public bool TargetExists;
        public string TargetSha256;
        public List<SaveEntry> SaveEntries;
    }

    public sealed class InputEntry
    {
        public string path;
        public string kind;
        public string key;
        public bool from_playlist;
        public string title = "";
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
        public int unreadable_directories;
        public bool had_playlist;
        public int missing_files;
        public bool saved;
        public string target_path = "";
        public bool target_exists;
        public string target_sha256 = "";
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
        string SelectFolder(InputRequest request);
        string SelectSavePath(InputRequest request);
        string[] ReadClipboard();
    }

    public interface IDirectoryScanner
    {
        IEnumerable<string> EnumerateEntries(string directory);
    }

    sealed class DirectoryScanner : IDirectoryScanner
    {
        public IEnumerable<string> EnumerateEntries(string directory)
        {
            return Directory.EnumerateFileSystemEntries(directory, "*", SearchOption.TopDirectoryOnly);
        }
    }

    public static class InputProcessor
    {
        public const int MaxBytes = 2 * 1024 * 1024;
        public const int MaxItems = 10000;
        public const int MaxPathLength = 32767;
        public const int MaxScannedItems = 100000;
        public const int MaxResponseBytes = 4 * 1024 * 1024;

        internal static bool Clean(string value, int limit)
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
                    ImageExtensions = ArrayField(data, "image_exts", true),
                    ExistingPaths = ArrayField(data, "existing_paths"), Paths = ArrayField(data, "paths", true)
                };
                request.MetadataCodepage = data.ContainsKey("metadata_codepage") ? StringField(data, "metadata_codepage") : "";
                request.SuggestedPath = data.ContainsKey("suggested_path") ? StringField(data, "suggested_path") : "";
                bool save = request.Operation == "save" || request.Operation == "save-dialog";
                if (!Clean(request.RequestId, 128) || request.ParentPid <= 0 ||
                    (!save && request.Operation != "files" && request.Operation != "clipboard" && request.Operation != "paths" && request.Operation != "folder") ||
                    (save ? request.Mode != "save" : request.Mode != "open" && request.Mode != "append") ||
                    (request.MetadataCodepage.Length != 0 && !Clean(request.MetadataCodepage, 128)) ||
                    (request.SuggestedPath.Length != 0 && !Clean(request.SuggestedPath, MaxPathLength)) ||
                    !Clean(request.WorkingDirectory, MaxPathLength) || !IsFullyQualified(request.WorkingDirectory))
                    throw new InputFailure("invalid_request");
                request.WorkingDirectory = Path.GetFullPath(request.WorkingDirectory);
                if (request.Operation == "paths" && !data.ContainsKey("paths")) throw new InputFailure("invalid_request");
                Extensions(request.VideoExtensions, request.AudioExtensions, request.SubtitleExtensions, request.ImageExtensions);
                if (request.Operation == "save") PlaylistStorage.ParseSaveRequest(request, data);
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

        internal static bool IsFullyQualified(string value)
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

        sealed class InputBudget
        {
            int items, bytes, scanned;
            public void Add(string path)
            {
                if (++items > MaxItems || (bytes += Encoding.UTF8.GetByteCount(path ?? "")) > MaxBytes)
                    throw new InputFailure("input_too_large");
            }
            public void Scan()
            {
                if (++scanned > MaxScannedItems) throw new InputFailure("input_too_large");
            }
        }

        static bool HostFormat(string extension)
        {
            return extension.Equals("iso", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals("avs", StringComparison.OrdinalIgnoreCase) || extension.Equals("lnk", StringComparison.OrdinalIgnoreCase);
        }

        static bool PlaylistFormat(string extension)
        {
            return extension.Equals("m3u", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals("m3u8", StringComparison.OrdinalIgnoreCase) || extension.Equals("pls", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals("xspf", StringComparison.OrdinalIgnoreCase);
        }

        static bool FolderMedia(string extension, HashSet<string> extensions, HashSet<string> subtitles, HashSet<string> images)
        {
            return extensions.Contains(extension) && !subtitles.Contains(extension) && !images.Contains(extension) &&
                !HostFormat(extension) && !PlaylistFormat(extension);
        }

        static bool Digit(char value) { return value >= '0' && value <= '9'; }

        static int CompareFileNames(string left, string right)
        {
            string a = Path.GetFileName(left), b = Path.GetFileName(right);
            int i = 0, j = 0;
            while (i < a.Length && j < b.Length)
            {
                if (Digit(a[i]) && Digit(b[j]))
                {
                    int endA = i, endB = j;
                    while (endA < a.Length && Digit(a[endA])) endA++;
                    while (endB < b.Length && Digit(b[endB])) endB++;
                    while (i < endA && a[i] == '0') i++;
                    while (j < endB && b[j] == '0') j++;
                    int lengths = (endA - i).CompareTo(endB - j);
                    if (lengths != 0) return lengths;
                    while (i < endA)
                    {
                        int digits = a[i++].CompareTo(b[j++]);
                        if (digits != 0) return digits;
                    }
                    i = endA; j = endB;
                }
                else
                {
                    int letters = char.ToUpperInvariant(a[i++]).CompareTo(char.ToUpperInvariant(b[j++]));
                    if (letters != 0) return letters;
                }
            }
            int remaining = (a.Length - i).CompareTo(b.Length - j);
            return remaining != 0 ? remaining : StringComparer.Ordinal.Compare(a, b);
        }

        static List<InputEntry> ReadDirectory(string directory, InputRequest request, IDirectoryScanner scanner,
            InputBudget budget, InputResponse response, HashSet<string> extensions, HashSet<string> subtitles, HashSet<string> images)
        {
            var entries = new List<InputEntry>();
            try
            {
                foreach (string path in scanner.EnumerateEntries(directory))
                {
                    budget.Scan();
                    string extension = Path.GetExtension(path).TrimStart('.');
                    if (!FolderMedia(extension, extensions, subtitles, images)) continue;
                    try
                    {
                        FileAttributes attributes = File.GetAttributes(path);
                        if ((attributes & FileAttributes.Directory) != 0) continue;
                    }
                    catch (IOException) { response.skipped++; continue; }
                    catch (UnauthorizedAccessException) { response.skipped++; continue; }
                    var entry = Normalize(path, request.WorkingDirectory);
                    if (entry == null) { response.skipped++; continue; }
                    budget.Add(entry.path);
                    entry.kind = "media";
                    entries.Add(entry);
                }
            }
            catch (IOException) { response.unreadable_directories++; return new List<InputEntry>(); }
            catch (UnauthorizedAccessException) { response.unreadable_directories++; return new List<InputEntry>(); }
            // No partially enumerated directory is committed when access fails.
            entries.Sort(delegate(InputEntry a, InputEntry b) { return CompareFileNames(a.path, b.path); });
            return entries;
        }

        static void AddEntry(InputEntry entry, HashSet<string> seen, InputResponse response)
        {
            if (!seen.Add(entry.key)) { response.duplicates++; return; }
            response.entries.Add(entry);
        }

        public static InputResponse Process(InputRequest request, IInputSource source, IDirectoryScanner scanner = null,
            Func<PlaylistReader> createReader = null, Action ensureParent = null)
        {
            var response = new InputResponse { request_id = request.RequestId };
            if (request.Operation == "save-dialog")
            {
                string target = source.SelectSavePath(request);
                if (target == null) { response.status = "cancelled"; return response; }
                PlaylistStorage.TakeSnapshot(target, response);
                return response;
            }
            if (request.Operation == "save") return PlaylistStorage.Save(request, ensureParent);
            string[] inputs;
            if (request.Operation == "folder")
            {
                string folder = source.SelectFolder(request);
                inputs = folder == null ? null : new[] { folder };
            }
            else inputs = request.Operation == "files" ? source.SelectFiles(request) :
                request.Operation == "clipboard" ? source.ReadClipboard() : request.Paths;
            if (inputs == null) { response.status = "cancelled"; return response; }
            if (inputs.Length > MaxItems) throw new InputFailure("input_too_large");
            scanner = scanner ?? new DirectoryScanner();
            var budget = new InputBudget();
            bool usedDirectory = false;
            var extensions = Extensions(request.VideoExtensions, request.AudioExtensions);
            var subtitles = Extensions(request.SubtitleExtensions);
            var images = Extensions(request.ImageExtensions);
            // Local keys are already case-folded. URL paths remain case-sensitive.
            var seen = new HashSet<string>(StringComparer.Ordinal);
            if (request.Mode == "append")
                foreach (string path in request.ExistingPaths)
                {
                    var existing = Normalize(path, request.WorkingDirectory);
                    if (existing != null) seen.Add(existing.key);
                }
            PlaylistReader reader = null;
            try
            {
                foreach (string path in inputs)
                {
                    var entry = Normalize(path, request.WorkingDirectory);
                    if (entry == null) { budget.Add(path); response.skipped++; continue; }
                    if (entry.kind != "native")
                    {
                        if (Directory.Exists(entry.path))
                        {
                            usedDirectory = true;
                            foreach (var media in ReadDirectory(entry.path, request, scanner, budget, response, extensions, subtitles, images))
                            {
                                if (!File.Exists(media.path)) { response.skipped++; continue; }
                                AddEntry(media, seen, response);
                            }
                            continue;
                        }
                        if (request.Operation == "folder")
                        {
                            budget.Add(entry.path);
                            response.unreadable_directories++;
                            continue;
                        }
                        if (!File.Exists(entry.path)) { budget.Add(entry.path); response.skipped++; continue; }
                        string extension = Path.GetExtension(entry.path).TrimStart('.');
                        if (extension.Equals("m3u", StringComparison.OrdinalIgnoreCase) || extension.Equals("m3u8", StringComparison.OrdinalIgnoreCase))
                        {
                            response.had_playlist = true;
                            if (reader == null) reader = createReader == null ? PlaylistReader.ForParent(request.ParentPid, request.MetadataCodepage) : createReader();
                            foreach (var listed in reader.Read(entry.path))
                            {
                                budget.Add(listed.path);
                                var local = Normalize(listed.path, request.WorkingDirectory);
                                if (local != null && local.kind != "native" && !File.Exists(listed.path)) { response.missing_files++; continue; }
                                // Explicit lists preserve every occurrence, including
                                // items already queued. Later ordinary inputs dedupe.
                                seen.Add(listed.key);
                                response.entries.Add(listed);
                            }
                            continue;
                        }
                        budget.Add(entry.path);
                        // These formats need mpv.net's private LoadFiles preprocessing.
                        // Reject the whole request before Lua can replace its queue.
                        if (HostFormat(extension))
                        {
                            if (request.Operation != "paths") throw new InputFailure("native_entry_required");
                            response.skipped++;
                            continue;
                        }
                        entry.kind = PlaylistFormat(extension) ? "native" : subtitles.Contains(extension) ? "subtitle" : extensions.Contains(extension) ? "media" : "native";
                    }
                    else budget.Add(entry.path);
                    if (request.Operation == "paths" && entry.kind != "media") { response.skipped++; continue; }
                    AddEntry(entry, seen, response);
                }
            }
            finally { if (reader != null) reader.Dispose(); }
            response.single_media = !usedDirectory && !response.had_playlist && request.Operation != "folder" && request.Mode == "open" && inputs.Length == 1 &&
                response.entries.Count == 1 && response.entries[0].kind == "media";
            string json = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }.Serialize(response);
            if (Encoding.UTF8.GetByteCount(json) > MaxResponseBytes) throw new InputFailure("input_too_large");
            return response;
        }
    }

    sealed class WindowOwner : IWin32Window
    {
        public IntPtr Handle { get; private set; }
        public WindowOwner(IntPtr handle) { Handle = handle; }
    }

    // The system Common Item Dialog supplies the modern folder UI. Keep the
    // complete IFileDialog vtable order, including members not used here.
    static class FolderPicker
    {
        internal const uint FolderOptions = 0x20U | 0x40U | 0x800U | 0x8U;
        [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr filters);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem folder);
            void SetFolder(IShellItem folder);
            void GetFolder(out IShellItem folder);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName(out IntPtr name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item);
            void AddPlace(IShellItem item, uint placement);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            void Close(int result);
            void SetClientGuid(ref Guid guid);
            void ClearClientData();
            void SetFilter(IntPtr filter);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint format, out IntPtr name);
            void GetAttributes(uint mask, out uint attributes);
            void Compare(IShellItem item, uint hint, out int result);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem item);

        internal static IFileDialog Create()
        {
            var type = Type.GetTypeFromCLSID(new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7"), true);
            var dialog = (IFileDialog)Activator.CreateInstance(type);
            try
            {
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions((options | FolderOptions) & ~0x200U); // One directory, never multiselect.
                return dialog;
            }
            catch { Marshal.FinalReleaseComObject(dialog); throw; }
        }

        internal static string Select(InputRequest request, IntPtr owner)
        {
            IFileDialog dialog = null;
            IShellItem initial = null, result = null;
            IntPtr name = IntPtr.Zero;
            try
            {
                dialog = Create();
                dialog.SetTitle(request.Mode == "append" ? "追加文件夹" : "打开文件夹");
                if (Directory.Exists(request.WorkingDirectory))
                {
                    Guid iid = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(request.WorkingDirectory, IntPtr.Zero, ref iid, out initial);
                    dialog.SetFolder(initial);
                }
                int status = dialog.Show(owner);
                if (status == unchecked((int)0x800704C7)) return null; // ERROR_CANCELLED.
                Marshal.ThrowExceptionForHR(status);
                dialog.GetResult(out result);
                result.GetDisplayName(0x80058000U, out name); // SIGDN_FILESYSPATH.
                return Marshal.PtrToStringUni(name);
            }
            catch { throw new InputFailure("input_unavailable"); }
            finally
            {
                if (name != IntPtr.Zero) Marshal.FreeCoTaskMem(name);
                if (result != null) Marshal.FinalReleaseComObject(result);
                if (initial != null) Marshal.FinalReleaseComObject(initial);
                if (dialog != null) Marshal.FinalReleaseComObject(dialog);
            }
        }
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

        public string SelectFolder(InputRequest request)
        {
            return FolderPicker.Select(request, ParentWindow());
        }

        public string SelectSavePath(InputRequest request)
        {
            using (var dialog = new SaveFileDialog())
            {
                dialog.Title = "保存播放列表";
                dialog.Filter = "UTF-8 播放列表 (*.m3u8)|*.m3u8";
                dialog.DefaultExt = "m3u8";
                dialog.AddExtension = true;
                dialog.OverwritePrompt = true;
                dialog.CheckPathExists = true;
                dialog.RestoreDirectory = true;
                dialog.InitialDirectory = request.WorkingDirectory;
                dialog.FileName = "播放列表.m3u8";
                if (request.SuggestedPath.Length != 0)
                {
                    var suggested = InputProcessor.Normalize(request.SuggestedPath, request.WorkingDirectory);
                    if (suggested != null && suggested.kind != "native")
                    {
                        dialog.InitialDirectory = Path.GetDirectoryName(suggested.path);
                        dialog.FileName = Path.GetFileName(suggested.path);
                    }
                }
                return dialog.ShowDialog(new WindowOwner(ParentWindow())) == DialogResult.OK ? dialog.FileName : null;
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
            if (args.Length == 3 && args[2] == "-DetachedSave")
                return args[0] == "-RequestPath" ? DetachedSave(args[1]) : 1;
            // Setting OutputEncoding calls console APIs, which fail for winexe.
            // Open the inherited pipe directly; mpv captures it without a console.
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
            var response = new InputResponse();
            try
            {
                if (args.Length != 2 || args[0] != "-RequestPath") throw new InputFailure("invalid_arguments");
                string text = ReadRequestText(args[1]);
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
                return ExecuteForParent(request, source, parent, null);
        }

        static InputResponse ExecuteForParent(InputRequest request, IInputSource source, Process parent, string cancellation)
        {
            // Dialog/input workers exit immediately. A detached writer instead
            // reaches its commit check and finally cleanup after parent exit.
            bool saving = request.Operation == "save";
            parent.Exited += delegate { if (!saving) Environment.Exit(0); };
            parent.EnableRaisingEvents = true;
            if (parent.HasExited) throw new InputFailure("parent_unavailable");
            return InputProcessor.Process(request, source ?? new WindowsInputSource(parent), null, null,
                delegate {
                    if (parent.HasExited || (cancellation != null && File.Exists(cancellation)))
                        throw new InputFailure("parent_unavailable");
                });
        }

        static string ReadRequestText(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
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
                    try { return new UTF8Encoding(false, true).GetString(data, start, data.Length - start); }
                    catch { throw new InputFailure("invalid_request"); }
                }
            }
        }

        static void DeleteOwned(string path)
        {
            if (path != null) try { File.Delete(path); } catch { }
        }

        static bool MayPublish(Process parent, string cancellation)
        {
            try { return parent != null && !parent.HasExited && !File.Exists(cancellation); }
            catch { return false; }
        }

        static int DetachedSave(string inputPath)
        {
            // The result/cancel names derive only from the command's own request
            // path. No field in JSON can direct result writes or cleanup.
            if (!InputProcessor.Clean(inputPath, InputProcessor.MaxPathLength - 48) || !InputProcessor.IsFullyQualified(inputPath)) return 1;
            string requestPath;
            try { requestPath = Path.GetFullPath(inputPath); }
            catch { return 1; }
            string resultPath = requestPath + ".result", cancellation = requestPath + ".cancel", temporary = null;
            bool published = false, ownedRequest = false;
            Process parent = null;
            var response = new InputResponse();
            try
            {
                try
                {
                    string text = ReadRequestText(requestPath);
                    // Read only a valid top-level identity before validating the
                    // remaining schema, so an invalid save still gets its own
                    // matching error receipt without ever touching its target.
                    var identity = new JavaScriptSerializer { MaxJsonLength = InputProcessor.MaxBytes, RecursionLimit = 16 }
                        .DeserializeObject(text) as Dictionary<string, object>;
                    object id, pid;
                    if (identity == null || !identity.TryGetValue("request_id", out id) || !(id is string) ||
                        !Regex.IsMatch((string)id, @"\A[A-Za-z0-9_-]{1,128}\z") ||
                        !identity.TryGetValue("parent_pid", out pid) || !(pid is int) || (int)pid <= 0 ||
                        !String.Equals(Path.GetFileName(requestPath), "mpvnet-input-" + (string)id + ".json", StringComparison.Ordinal))
                        throw new InputFailure("invalid_request");
                    ownedRequest = true;
                    response.request_id = (string)id;
                    parent = FindParent((int)pid);
                    var request = InputProcessor.ParseRequest(text);
                    if (request.Operation != "save") throw new InputFailure("invalid_request");
                    response = ExecuteForParent(request, null, parent, cancellation);
                }
                catch (InputFailure failure) { response.status = "error"; response.error_code = failure.Code; }
                catch { response.status = "error"; response.error_code = "internal_error"; }
                if (!MayPublish(parent, cancellation)) return 1;
                byte[] data = new UTF8Encoding(false).GetBytes(new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }.Serialize(response));
                string candidate = Path.Combine(Path.GetDirectoryName(requestPath), ".mpvnet-result-" + Guid.NewGuid().ToString("N") + ".tmp");
                using (var stream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    temporary = candidate;
                    stream.Write(data, 0, data.Length);
                    stream.Flush(true);
                }
                if (!MayPublish(parent, cancellation)) return 1;
                // Move never overwrites an existing unknown result. Publishing
                // failure cannot roll back an already committed playlist file.
                File.Move(temporary, resultPath);
                temporary = null;
                published = true;
                return response.status == "error" ? 1 : 0;
            }
            catch { return 1; }
            finally
            {
                DeleteOwned(temporary);
                if (published && !MayPublish(parent, cancellation)) DeleteOwned(resultPath);
                if (ownedRequest)
                {
                    DeleteOwned(requestPath);
                    DeleteOwned(cancellation);
                }
                if (parent != null) parent.Dispose();
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
