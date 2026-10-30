using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

// MediaInfo report acquisition only; the UI owns grouping and presentation.
// Complete=0 preserves the original mpv.net dialog's default report scope.
public static class MediaInfoData
{
    static readonly string[] Keys = { "duration", "size", "container", "resolution", "fps", "aspect",
        "video_codec", "bit_depth", "dynamic_range", "total_bitrate", "audio", "subtitle" };
    static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    static object Value(IDictionary<string, object> data, string key) {
        object value; return data != null && data.TryGetValue(key, out value) ? value : null;
    }
    static string Text(object value) {
        if (value == null || value is bool || value is IDictionary || value is Array) return "";
        return Convert.ToString(value, Invariant).Trim();
    }
    static string Str(IDictionary<string, object> data, string key) { return Text(Value(data, key)); }
    static double Number(IDictionary<string, object> data, string key) {
        double value;
        return Double.TryParse(Str(data, key), NumberStyles.Float, Invariant, out value) &&
            !Double.IsInfinity(value) && !Double.IsNaN(value) && value > 0 ? value : 0;
    }
    static string F(double value) { return value.ToString("0.###", Invariant); }
    static string Join(List<string> values) { return String.Join(" · ", values.ToArray()); }
    static void Add(List<string> values, string value) { if (!String.IsNullOrWhiteSpace(value)) values.Add(value); }
    static string Time(double seconds) {
        if (seconds <= 0 || seconds >= TimeSpan.MaxValue.TotalSeconds) return "";
        var duration = TimeSpan.FromSeconds(seconds);
        return ((long)duration.TotalHours).ToString("00", Invariant) + ":" + duration.Minutes.ToString("00", Invariant) +
            ":" + duration.Seconds.ToString("00", Invariant);
    }
    static string Size(double bytes) {
        if (bytes <= 0) return "";
        return bytes >= 1073741824 ? F(bytes / 1073741824) + " GiB" :
            bytes >= 1048576 ? F(bytes / 1048576) + " MiB" : bytes >= 1024 ? F(bytes / 1024) + " KiB" : F(bytes) + " B";
    }
    static string Bitrate(double bits) { return bits <= 0 ? "" : bits >= 1000000 ? F(bits / 1000000) + " Mb/s" : F(bits / 1000) + " kb/s"; }
    static string WithOthers(string main, int count, bool audio) {
        return main + (count > 1 ? "（另有 " + (count - 1).ToString(Invariant) + " 条" + (audio ? "音轨" : "字幕") + "）" : "");
    }
    static string TrackSummary(List<IDictionary<string, object>> tracks, bool audio, IDictionary<string, object> properties)
    {
        if (tracks.Count == 0) return "";
        var chosen = tracks[0];
        foreach (var track in tracks) if (Value(track, "selected") is bool && (bool)Value(track, "selected")) { chosen = track; break; }
        var parts = new List<string>(); string codec = Str(chosen, "codec");
        bool current = (Value(chosen, "selected") is bool && (bool)Value(chosen, "selected")) || tracks.Count == 1;
        if (audio && codec.Length == 0 && current) codec = Str(properties, "audio_codec");
        Add(parts, codec); Add(parts, Str(chosen, "lang"));
        if (audio) {
            string channels = Str(chosen, "audio-channels"); double rate = Number(chosen, "demux-samplerate");
            if (current && channels.Length == 0) channels = Str(properties, "channels");
            if (current && rate == 0) rate = Number(properties, "sample_rate");
            if (channels.Length > 0) Add(parts, channels + " 声道"); if (rate > 0) Add(parts, F(rate / 1000) + " kHz");
        }
        return WithOthers(parts.Count == 0 ? (audio ? "音轨" : "字幕轨") : Join(parts), tracks.Count, audio);
    }

    public static IDictionary<string, object> Read(IDictionary<string, object> request, Process parent)
    {
        var overview = new Dictionary<string, string>(); foreach (string key in Keys) overview[key] = "";
        var result = new Dictionary<string, object> { { "title", "" }, { "summary", "" }, { "overview", overview },
            { "report", "" }, { "error", "" }, { "kind", "empty" } };
        object schema = Value(request, "schema"), pid = Value(request, "parent_pid");
        if (request == null || parent == null || !(schema is int) || (int)schema != 1 ||
            !(pid is int) || (int)pid != parent.Id || Str(request, "token").Length == 0) {
            result["error"] = "媒体信息请求无效。"; return result;
        }
        string title = Str(request, "title");
        if (title.Contains("://")) title = "网络媒体";
        title = title.Replace("\r", " ").Replace("\n", " ").Replace("\0", "");
        result["title"] = title;
        if (!(Value(request, "has_media") is bool) || !(bool)Value(request, "has_media")) return result;
        var properties = Value(request, "properties") as IDictionary<string, object> ?? new Dictionary<string, object>();
        var tracks = Value(properties, "tracks") as IList;
        bool hasVideo = Number(properties, "width") > 0 || Number(properties, "height") > 0 || Str(properties, "video_format").Length > 0;
        bool hasAudio = Str(properties, "audio_codec").Length > 0;
        var audios = new List<IDictionary<string, object>>(); var subtitles = new List<IDictionary<string, object>>();
        if (tracks != null) foreach (object item in tracks) {
            var track = item as IDictionary<string, object>; if (track == null) continue;
            string type = Str(track, "type");
            if (type == "video") hasVideo = true;
            if (type == "audio") {
                hasAudio = true; audios.Add(track);
            }
            if (type == "sub") subtitles.Add(track);
        }
        string localPath = Str(request, "local_path");
        result["kind"] = !hasVideo && hasAudio ? "audio" : localPath.Length > 0 ? "local" : "network";
        overview["duration"] = Time(Number(properties, "duration"));
        overview["size"] = Size(Number(properties, "file_size"));
        overview["container"] = Str(properties, "container");
        double width = Number(properties, "width"), height = Number(properties, "height"), fps = Number(properties, "fps");
        if (width > 0 && height > 0) overview["resolution"] = F(width) + " × " + F(height);
        if (fps > 0) overview["fps"] = F(fps) + " fps";
        double aspect = Number(properties, "aspect");
        if (aspect > 0) overview["aspect"] = F(aspect) + ":1";
        overview["video_codec"] = Str(properties, "video_format");
        double depth = Number(properties, "bit_depth"); if (depth > 0) overview["bit_depth"] = F(depth) + " bit";
        string gamma = Str(properties, "gamma");
        if (gamma.Equals("pq", StringComparison.OrdinalIgnoreCase)) overview["dynamic_range"] = "PQ";
        else if (gamma.Equals("hlg", StringComparison.OrdinalIgnoreCase)) overview["dynamic_range"] = "HLG";
        overview["total_bitrate"] = Bitrate(Number(properties, "total_bitrate"));
        if (audios.Count > 0) overview["audio"] = TrackSummary(audios, true, properties);
        else if (tracks != null) overview["audio"] = "未发现音轨";
        else {
            var parts = new List<string>(); Add(parts, Str(properties, "audio_codec"));
            double rate = Number(properties, "sample_rate"), channels = Number(properties, "channels");
            if (channels > 0) Add(parts, F(channels) + " 声道"); if (rate > 0) Add(parts, F(rate / 1000) + " kHz");
            overview["audio"] = Join(parts);
        }
        overview["subtitle"] = TrackSummary(subtitles, false, properties);
        if (subtitles.Count == 0 && tracks != null) overview["subtitle"] = "未发现字幕";

        if (localPath.Length == 0) result["error"] = "网络媒体未取得完整文件报告。";
        else {
            try {
                if (!LocalFile(localPath)) throw new IOException("not-local");
                if (parent.HasExited) throw new InvalidOperationException("parent-exited");
                string executable = parent.MainModule.FileName;
                string library = Path.Combine(Path.GetDirectoryName(executable), "MediaInfo.dll");
                if (!LocalFile(library)) throw new IOException("library-missing");
                if (title.Length == 0) result["title"] = Path.GetFileName(localPath);
                using (var info = new Native(library, localPath)) {
                    result["report"] = info.Report();
                    if (((string)result["report"]).Length == 0) result["error"] = "未能取得完整文件报告。";
                    else {
                        FillNative(overview, info);
                        if (info.Count(1) > 0) result["kind"] = "local";
                        else if (info.Count(2) > 0) result["kind"] = "audio";
                    }
                }
                if (overview["size"].Length == 0) overview["size"] = Size(new FileInfo(localPath).Length);
            } catch (Exception error) {
                if (!(error is IOException || error is UnauthorizedAccessException || error is Win32Exception ||
                    error is InvalidOperationException || error is ArgumentException || error is DllNotFoundException ||
                    error is BadImageFormatException || error is EntryPointNotFoundException || error is System.Security.SecurityException)) throw;
                result["error"] = "未能读取完整文件报告，请检查媒体文件和播放器目录中的 MediaInfo.dll。";
            }
        }
        var summary = new List<string>(); Add(summary, overview["duration"]); Add(summary, overview["resolution"]);
        Add(summary, overview["video_codec"]); Add(summary, overview["audio"]);
        result["summary"] = Join(summary); return result;
    }

    // File-system media, including shares and links, retain the original host's
    // read capability. URLs and named pipes never reach MediaInfo_Open.
    static bool FileSystemPath(string path)
    {
        string windows = path.Replace('/', '\\');
        if (path.IndexOf("://", StringComparison.Ordinal) >= 0 || !Path.IsPathRooted(path) ||
            windows.StartsWith(@"\\.\pipe", StringComparison.OrdinalIgnoreCase) ||
            windows.StartsWith(@"\\?\pipe", StringComparison.OrdinalIgnoreCase)) return false;
        return true;
    }
    static bool LocalFile(string path) { return FileSystemPath(path) && File.Exists(path); }

    static void Prefer(Dictionary<string, string> overview, string key, string value) { if (value.Length > 0) overview[key] = value; }
    static void FillNative(Dictionary<string, string> overview, Native info)
    {
        Prefer(overview, "duration", info.Get(0, 0, "Duration/String3"));
        Prefer(overview, "size", info.Get(0, 0, "FileSize/String"));
        Prefer(overview, "container", info.Get(0, 0, "Format"));
        Prefer(overview, "total_bitrate", info.Get(0, 0, "OverallBitRate/String"));
        string width = info.Get(1, 0, "Width"), height = info.Get(1, 0, "Height");
        if (width.Length > 0 && height.Length > 0) overview["resolution"] = width + " × " + height;
        Prefer(overview, "fps", info.Get(1, 0, "FrameRate/String"));
        Prefer(overview, "aspect", info.Get(1, 0, "DisplayAspectRatio/String"));
        Prefer(overview, "video_codec", info.Get(1, 0, "Format"));
        Prefer(overview, "bit_depth", info.Get(1, 0, "BitDepth/String"));
        Prefer(overview, "dynamic_range", info.Get(1, 0, "HDR_Format/String"));
        int audioCount = info.Count(2), subtitleCount = info.Count(3);
        if (audioCount > 0 && overview["audio"].Length == 0) {
            var parts = new List<string>(); Add(parts, info.Get(2, 0, "Format")); Add(parts, info.Get(2, 0, "Language/String"));
            Add(parts, info.Get(2, 0, "Channel(s)/String")); Add(parts, info.Get(2, 0, "SamplingRate/String"));
            overview["audio"] = WithOthers(parts.Count == 0 ? "音轨" : Join(parts), audioCount, true);
        }
        else if (audioCount == 0 && overview["audio"].Length == 0) overview["audio"] = "未发现音轨";
        // The player's current track list can include external streams absent
        // from the file report; keep those descriptions when they are available.
        if (subtitleCount > 0 && overview["subtitle"].Length == 0) {
            var parts = new List<string>(); Add(parts, info.Get(3, 0, "Format")); Add(parts, info.Get(3, 0, "Language/String"));
            overview["subtitle"] = WithOthers(parts.Count == 0 ? "字幕轨" : Join(parts), subtitleCount, false);
        }
        else if (subtitleCount == 0 && overview["subtitle"].Length == 0) overview["subtitle"] = "未发现字幕";
    }

    sealed class Native : IDisposable
    {
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate IntPtr NewDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)] delegate UIntPtr OpenDelegate(IntPtr handle, string path);
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)] delegate IntPtr OptionDelegate(IntPtr handle, string name, string value);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate IntPtr InformDelegate(IntPtr handle, UIntPtr reserved);
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)] delegate IntPtr GetDelegate(IntPtr handle, int kind, UIntPtr stream, string name, int info, int search);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate UIntPtr CountDelegate(IntPtr handle, int kind, UIntPtr stream);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void ReleaseDelegate(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr library, string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr library);
        IntPtr library, handle;
        ReleaseDelegate close, delete;
        OptionDelegate option; InformDelegate inform; GetDelegate get; CountDelegate count;
        T Export<T>(string name) where T : class {
            IntPtr address = GetProcAddress(library, "MediaInfo_" + name);
            if (address == IntPtr.Zero) throw new EntryPointNotFoundException(name);
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        public Native(string path, string media)
        {
            // Absolute library and its local/system dependencies only. Do not
            // mutate the process-wide DLL search directory or environment.
            library = LoadLibraryEx(path, IntPtr.Zero, 0x100 | 0x800);
            if (library == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                close = Export<ReleaseDelegate>("Close"); delete = Export<ReleaseDelegate>("Delete");
                option = Export<OptionDelegate>("Option"); inform = Export<InformDelegate>("Inform");
                get = Export<GetDelegate>("Get"); count = Export<CountDelegate>("Count_Get");
                handle = Export<NewDelegate>("New")();
                if (handle == IntPtr.Zero || Export<OpenDelegate>("Open")(handle, media).ToUInt64() == 0) throw new IOException("media-open");
            } catch { Dispose(); throw; }
        }
        public string Report() {
            option(handle, "Language", ""); option(handle, "Complete", "0");
            return Marshal.PtrToStringUni(inform(handle, UIntPtr.Zero)) ?? "";
        }
        public string Get(int kind, int stream, string name) { return Marshal.PtrToStringUni(get(handle, kind, new UIntPtr(checked((uint)stream)), name, 1, 0)) ?? ""; }
        public int Count(int kind) {
            // MediaInfo's npos is size_t(-1), including all upper bits on x64.
            UIntPtr npos = UIntPtr.Size == 8 ? new UIntPtr(UInt64.MaxValue) : new UIntPtr(UInt32.MaxValue);
            return checked((int)count(handle, kind, npos).ToUInt64());
        }
        public void Dispose() {
            if (handle != IntPtr.Zero) { close(handle); delete(handle); handle = IntPtr.Zero; }
            if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
        }
    }
}
