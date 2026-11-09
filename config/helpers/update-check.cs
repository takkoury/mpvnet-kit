using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// Update checks never inspect the package manifest or backup chain. The installed
// receipt identifies the current package; this separate state owns only cadence,
// the last official response and automatic notification history.
public static class UpdateData
{
    public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    public static Dictionary<string, object> Object(object value)
    {
        var data = value as Dictionary<string, object>;
        if (data == null) throw new InvalidDataException("更新数据无效。");
        return data;
    }
    public static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = 262144, RecursionLimit = 24 }; }
    public static string Text(IDictionary<string, object> data, string name)
    {
        object value; return data.TryGetValue(name, out value) && value is string ? (string)value : "";
    }
    public static bool Schema(IDictionary<string, object> data)
    {
        object value; return data.TryGetValue("schema", out value) && value is int && (int)value == 1;
    }
    public static string Absolute(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\.\", StringComparison.Ordinal)) throw new InvalidDataException("更新路径无效。");
        string inputRoot = Path.GetPathRoot(path);
        if (inputRoot == "\\" || (inputRoot.Length == 2 && inputRoot[1] == ':'))
            throw new InvalidDataException("更新路径必须完整。");
        string full = Path.GetFullPath(path);
        // A canonical directory makes every instance share one mutex, including
        // callers using different case or a trailing separator. Links are rejected.
        NoLinks(full);
        string root = Path.GetPathRoot(full);
        return full.Length > root.Length ? full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) : full;
    }
    public static void NoLinks(string path)
    {
        for (string part = path; !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part)) {
            if ((File.Exists(part) || Directory.Exists(part)) && (File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("更新路径不能包含链接。");
        }
    }
    public static Dictionary<string, object> Read(string path, int limit)
    {
        NoLinks(path);
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            if (file.Length == 0 || file.Length > limit) throw new InvalidDataException("更新数据大小无效。");
            var bytes = new byte[limit + 1]; int count = 0, read;
            while (count < bytes.Length && (read = file.Read(bytes, count, bytes.Length - count)) > 0) count += read;
            if (count > limit) throw new InvalidDataException("更新数据过大。");
            return Object(Json().DeserializeObject(Utf8.GetString(bytes, 0, count).TrimStart('\uFEFF')));
        }
    }
}

public sealed class UpdateRequest
{
    public string Token, ConfigDirectory, ActivationPath;
    public int ParentPid;
    public bool Automatic;
    public static UpdateRequest Load(string requestPath)
    {
        string path = UpdateData.Absolute(requestPath);
        var data = UpdateData.Read(path, 16384); object pid, automatic;
        string token = UpdateData.Text(data, "token"), activation = UpdateData.Text(data, "activation_path");
        if (!UpdateData.Schema(data) || !Regex.IsMatch(token, @"\A[A-Za-z0-9_.:-]{1,128}\z") ||
            !data.TryGetValue("parent_pid", out pid) || !(pid is int) || (int)pid <= 0 ||
            !data.TryGetValue("automatic", out automatic) || !(automatic is bool) ||
            !String.Equals(activation, requestPath + ".activate", StringComparison.Ordinal) ||
            !String.Equals(UpdateData.Absolute(activation), path + ".activate", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("更新检查请求无效。");
        string config = UpdateData.Absolute(UpdateData.Text(data, "config_directory"));
        if (!Directory.Exists(config)) throw new InvalidDataException("更新检查配置目录不存在。");
        return new UpdateRequest { Token = token, ParentPid = (int)pid, Automatic = (bool)automatic,
            ConfigDirectory = config, ActivationPath = activation };
    }
    public long ReadSerial()
    {
        try {
            UpdateData.NoLinks(ActivationPath);
            using (var file = new FileStream(ActivationPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (file.Length == 0 || file.Length > 32) return 0;
                var bytes = new byte[33]; int count = file.Read(bytes, 0, bytes.Length);
                string value = Encoding.ASCII.GetString(bytes, 0, count).Trim(); long serial;
                return Regex.IsMatch(value, @"\A[0-9]{1,19}\z") && Int64.TryParse(value, NumberStyles.None,
                    CultureInfo.InvariantCulture, out serial) ? serial : 0;
            }
        } catch (IOException) { } catch (UnauthorizedAccessException) { } catch (InvalidDataException) { }
        return 0;
    }
}

public sealed class KitVersion : IComparable<KitVersion>
{
    readonly string[] parts;
    public string Value { get; private set; }
    KitVersion(string value) { Value = value; parts = value.Split('.'); }
    public static KitVersion Stable(string text)
    {
        return text != null && text.Length <= 96 && Regex.IsMatch(text, @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z")
            ? new KitVersion(text) : null;
    }
    public static bool Development(string text)
    {
        return text != null && text.Length <= 160 && Regex.IsMatch(text,
            @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)[-+][0-9A-Za-z][0-9A-Za-z.+-]*\z");
    }
    public int CompareTo(KitVersion other)
    {
        if (other == null) return 1;
        for (int i = 0; i < 3; i++) {
            int order = parts[i].Length.CompareTo(other.parts[i].Length);
            if (order == 0) order = String.CompareOrdinal(parts[i], other.parts[i]);
            if (order != 0) return order;
        }
        return 0;
    }
}

public sealed class UpdateResult
{
    public string Status, CurrentVersion = "", LatestVersion = "", Error = "";
    public bool Available { get { return Status == "available"; } }
    public static UpdateResult Failure(string current, string message)
    { return new UpdateResult { Status = "failed", CurrentVersion = current, Error = message }; }
}

public interface IUpdateTransport { string Fetch(CancellationToken cancellation); }

public sealed class GitHubUpdateTransport : IUpdateTransport
{
    public const string Endpoint = "https://api.github.com/repos/takkoury/mpvnet-kit/releases/latest";
    public const int ResponseLimit = 262144;
    public string Fetch(CancellationToken cancellation) { return FetchAsync(cancellation).GetAwaiter().GetResult(); }
    async Task<string> FetchAsync(CancellationToken cancellation)
    {
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        var request = (HttpWebRequest)WebRequest.Create(Endpoint);
        request.Method = "GET"; request.UserAgent = "mpvnet-kit-update/1";
        request.Accept = "application/vnd.github+json"; request.AllowAutoRedirect = false;
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Timeout = 10000; request.ReadWriteTimeout = 10000;
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation)) {
            timeout.CancelAfter(10000);
            using (timeout.Token.Register(request.Abort)) {
                try {
                    using (var response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false)) {
                        if (response.StatusCode != HttpStatusCode.OK || response.ContentLength > ResponseLimit)
                            throw new InvalidDataException("官方发行信息无效。");
                        using (var input = response.GetResponseStream())
                        using (var output = new MemoryStream()) {
                            var buffer = new byte[8192]; int count;
                            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) > 0) {
                                if (output.Length + count > ResponseLimit) throw new InvalidDataException("官方发行信息过大。");
                                output.Write(buffer, 0, count);
                            }
                            return UpdateData.Utf8.GetString(output.ToArray());
                        }
                    }
                } catch (OperationCanceledException) {
                    cancellation.ThrowIfCancellationRequested();
                    throw new IOException("检查更新超时，请稍后重试。");
                } catch (WebException) {
                    cancellation.ThrowIfCancellationRequested();
                    throw new IOException("暂时无法连接官方发行服务，请稍后重试。");
                }
            }
        }
    }
}

sealed class UpdateState
{
    public long AttemptedUtc;
    public string LatestVersion = "", Outcome = "";
    public readonly HashSet<string> Notified = new HashSet<string>(StringComparer.Ordinal);
}

public sealed class UpdateChecker
{
    public const string ReleasesUrl = "https://github.com/takkoury/mpvnet-kit/releases";
    readonly string config, statePath, mutexName;
    readonly IUpdateTransport transport;
    readonly Func<DateTime> utcNow;
    public string CurrentVersion { get; private set; }
    public string MutexName { get { return mutexName; } }
    public UpdateChecker(string directory) : this(directory, new GitHubUpdateTransport(), () => DateTime.UtcNow) { }
    // Test injection is limited to the managed API; production accepts no URL,
    // cache path, test response, environment override or transport argument.
    public UpdateChecker(string directory, IUpdateTransport transport, Func<DateTime> utcNow)
    {
        config = UpdateData.Absolute(directory);
        if (!Directory.Exists(config) || transport == null || utcNow == null) throw new ArgumentException("更新检查参数无效。");
        this.transport = transport; this.utcNow = utcNow;
        statePath = Path.Combine(config, ".mpvnet-kit-update.json");
        using (var hash = SHA256.Create()) mutexName = @"Local\mpvnet-kit-update-" +
            BitConverter.ToString(hash.ComputeHash(UpdateData.Utf8.GetBytes(config.ToUpperInvariant()))).Replace("-", "");
        CurrentVersion = ReadInstalledVersion();
    }
    public string ReadInstalledVersion()
    {
        try {
            var receipt = UpdateData.Read(Path.Combine(config, ".mpvnet-kit-install.json"), 1048576);
            string version = UpdateData.Text(receipt, "packageVersion");
            if (!UpdateData.Schema(receipt) || UpdateData.Text(receipt, "owner") != "mpvnet-kit" ||
                UpdateData.Text(receipt, "kind") != "receipt" || !String.Equals(config,
                UpdateData.Absolute(UpdateData.Text(receipt, "target")), StringComparison.OrdinalIgnoreCase) ||
                (KitVersion.Stable(version) == null && !KitVersion.Development(version))) return "";
            return version;
        } catch (IOException) { } catch (UnauthorizedAccessException) { } catch (ArgumentException) { } catch (InvalidDataException) { } catch (NotSupportedException) { }
        return "";
    }
    public bool AutoEnabled()
    {
        string path = Path.Combine(config, "mpvnet-user.json");
        if (!File.Exists(path)) return !Directory.Exists(path);
        try {
            var data = UpdateData.Read(path, 262144); object settings, value;
            if (!UpdateData.Schema(data)) return false;
            if (!data.TryGetValue("settings", out settings)) return true;
            var fields = settings as Dictionary<string, object>;
            if (fields == null) return false;
            if (!fields.TryGetValue("updates.auto-check", out value)) return true;
            return value is bool && (bool)value;
        } catch (IOException) { } catch (UnauthorizedAccessException) { } catch (ArgumentException) { } catch (InvalidDataException) { }
        return false;
    }
    public static string ReleaseUrl(string version)
    {
        if (KitVersion.Stable(version) == null) throw new ArgumentException("正式版本号无效。");
        return ReleasesUrl + "/tag/v" + version;
    }
    public static string ParseRelease(string response)
    {
        if (response == null || UpdateData.Utf8.GetByteCount(response) > GitHubUpdateTransport.ResponseLimit)
            throw new InvalidDataException("官方发行信息大小无效。");
        var data = UpdateData.Object(UpdateData.Json().DeserializeObject(response)); object draft, prerelease;
        string tag = UpdateData.Text(data, "tag_name"), version = tag.StartsWith("v", StringComparison.Ordinal) ? tag.Substring(1) : "";
        if (KitVersion.Stable(version) == null || !data.TryGetValue("draft", out draft) || !(draft is bool) || (bool)draft ||
            !data.TryGetValue("prerelease", out prerelease) || !(prerelease is bool) || (bool)prerelease ||
            UpdateData.Text(data, "html_url") != ReleaseUrl(version)) throw new InvalidDataException("官方发行信息无效。");
        return version;
    }
    UpdateState ReadState()
    {
        if (!File.Exists(statePath)) {
            if (Directory.Exists(statePath)) throw new InvalidDataException("更新状态无效。");
            return new UpdateState();
        }
        var data = UpdateData.Read(statePath, 65536); object attempted, notified;
        var state = new UpdateState { LatestVersion = UpdateData.Text(data, "latest_version"), Outcome = UpdateData.Text(data, "outcome") };
        if (!UpdateData.Schema(data) || UpdateData.Text(data, "owner") != "mpvnet-kit" ||
            UpdateData.Text(data, "kind") != "update-state" || !String.Equals(UpdateData.Text(data, "target"), config, StringComparison.OrdinalIgnoreCase) ||
            !data.TryGetValue("attempted_utc_ticks", out attempted) || !(attempted is string) ||
            !Int64.TryParse((string)attempted, NumberStyles.None, CultureInfo.InvariantCulture, out state.AttemptedUtc) ||
            state.AttemptedUtc < 0 || state.AttemptedUtc > DateTime.MaxValue.Ticks ||
            (state.Outcome != "success" && state.Outcome != "failed" && state.Outcome != "pending") ||
            (state.Outcome == "success" ? KitVersion.Stable(state.LatestVersion) == null : state.LatestVersion.Length != 0) ||
            !data.TryGetValue("notified_versions", out notified) || !(notified is object[]))
            throw new InvalidDataException("更新状态无效。");
        foreach (object item in (object[])notified) {
            var version = item as string;
            if (KitVersion.Stable(version) == null) throw new InvalidDataException("更新通知状态无效。");
            state.Notified.Add(version);
        }
        return state;
    }
    void SaveState(UpdateState state)
    {
        UpdateData.NoLinks(statePath);
        var versions = new List<string>(state.Notified); versions.Sort(StringComparer.Ordinal);
        var data = new Dictionary<string, object> { { "schema", 1 }, { "owner", "mpvnet-kit" }, { "kind", "update-state" },
            { "target", config }, { "attempted_utc_ticks", state.AttemptedUtc.ToString(CultureInfo.InvariantCulture) },
            { "outcome", state.Outcome }, { "latest_version", state.LatestVersion }, { "notified_versions", versions } };
        byte[] bytes = UpdateData.Utf8.GetBytes(UpdateData.Json().Serialize(data));
        if (bytes.Length > 65536) throw new InvalidDataException("更新状态过大。");
        string temporary = statePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                file.Write(bytes, 0, bytes.Length); file.Flush(true);
            }
            UpdateData.NoLinks(statePath);
            if (File.Exists(statePath)) File.Replace(temporary, statePath, null); else File.Move(temporary, statePath);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    static bool Take(Mutex mutex, int milliseconds)
    { try { return mutex.WaitOne(milliseconds); } catch (AbandonedMutexException) { return true; } }
    UpdateResult Result(UpdateState state)
    {
        if (state.Outcome != "success") return UpdateResult.Failure(CurrentVersion, "暂时无法完成检查，请重试。");
        return new UpdateResult { CurrentVersion = CurrentVersion, LatestVersion = state.LatestVersion,
            Status = KitVersion.Stable(state.LatestVersion).CompareTo(KitVersion.Stable(CurrentVersion)) > 0 ? "available" :
                KitVersion.Stable(state.LatestVersion).CompareTo(KitVersion.Stable(CurrentVersion)) == 0 ? "current" : "ahead" };
    }
    public UpdateResult Check(bool manual, Func<bool> manualRequested, CancellationToken cancellation)
    {
        CurrentVersion = ReadInstalledVersion();
        if (CurrentVersion.Length == 0) return new UpdateResult { Status = "uninstalled" };
        if (KitVersion.Development(CurrentVersion)) return new UpdateResult { Status = "development", CurrentVersion = CurrentVersion };
        if (!manual && !manualRequested() && !AutoEnabled()) return new UpdateResult { Status = "disabled", CurrentVersion = CurrentVersion };
        // A distinct check gate distinguishes a joined network operation from a
        // brief notification claim. A manual check must not reuse old cache only
        // because another instance happened to be presenting that cache.
        using (var checkGate = new Mutex(false, mutexName + "-check"))
        using (var mutex = new Mutex(false, mutexName)) {
            bool gateOwned = Take(checkGate, 0), joined = !gateOwned, owned = false;
            try {
                // Keep mutex ownership on this worker thread. The transport may
                // use async I/O internally but never resumes this lock elsewhere.
                while (!gateOwned) { cancellation.ThrowIfCancellationRequested(); gateOwned = Take(checkGate, 100); }
                while (!owned) { cancellation.ThrowIfCancellationRequested(); owned = Take(mutex, 100); }
                cancellation.ThrowIfCancellationRequested();
                UpdateState state;
                try { state = ReadState(); }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ArgumentException || error is InvalidDataException) {
                    if (!manual && !manualRequested()) return UpdateResult.Failure(CurrentVersion, "更新状态无法读取。");
                    state = new UpdateState();
                }
                long now = utcNow().ToUniversalTime().Ticks;
                bool recent = state.AttemptedUtc > 0 && now - state.AttemptedUtc < TimeSpan.TicksPerDay;
                // Explicit checks bypass the daily throttle. A caller that joins
                // an in-flight request consumes that request's completed result.
                if ((joined && state.AttemptedUtc > 0) || (!manual && !manualRequested() && recent)) return Result(state);
                state.AttemptedUtc = now; state.Outcome = "pending"; state.LatestVersion = ""; SaveState(state);
                try {
                    state.LatestVersion = ParseRelease(transport.Fetch(cancellation)); state.Outcome = "success";
                } catch (OperationCanceledException) { throw; }
                catch (Exception error) when (error is IOException || error is WebException || error is ArgumentException || error is InvalidOperationException || error is InvalidDataException) {
                    state.LatestVersion = ""; state.Outcome = "failed";
                }
                cancellation.ThrowIfCancellationRequested(); SaveState(state); return Result(state);
            } finally { if (owned) mutex.ReleaseMutex(); if (gateOwned) checkGate.ReleaseMutex(); }
        }
    }
    public bool TryNotify(string version, Func<bool> show, CancellationToken cancellation)
    {
        if (KitVersion.Stable(version) == null || show == null || cancellation.IsCancellationRequested) return false;
        using (var mutex = new Mutex(false, mutexName)) {
            // The UI must remain responsive if another instance is checking.
            if (!Take(mutex, 0)) return false;
            try {
                cancellation.ThrowIfCancellationRequested();
                if (!AutoEnabled()) return false;
                var state = ReadState();
                string installed = ReadInstalledVersion(); var current = KitVersion.Stable(installed);
                if (current == null || KitVersion.Stable(version).CompareTo(current) <= 0 || state.Outcome != "success" ||
                    state.LatestVersion != version || state.Notified.Contains(version)) return false;
                if (!show()) return false;
                state.Notified.Add(version); SaveState(state); return true;
            } finally { mutex.ReleaseMutex(); }
        }
    }
}
