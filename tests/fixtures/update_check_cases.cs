using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;

public sealed class FixtureUpdateTransport : IUpdateTransport
{
    public int Calls;
    public bool Fail, Hold;
    public volatile bool Cancelled;
    public string Directory;
    public string Fetch(CancellationToken cancellation)
    {
        Calls++;
        if (Directory != null) File.AppendAllText(Path.Combine(Directory, "network.log"), "fetch\n");
        if (Hold) {
            try {
                File.WriteAllText(Path.Combine(Directory, "entered"), "1");
                var watch = Stopwatch.StartNew();
                while (!File.Exists(Path.Combine(Directory, "release"))) {
                    cancellation.ThrowIfCancellationRequested();
                    if (watch.ElapsedMilliseconds > 15000) throw new IOException("fixture timeout");
                    Thread.Sleep(20);
                }
            } catch (OperationCanceledException) { Cancelled = true; throw; }
        }
        if (Fail) throw new IOException("fixture failure");
        return UpdateCases.Release("0.6.0");
    }
}

public static class UpdateCases
{
    public static string Release(string version)
    {
        return "{\"tag_name\":\"v" + version + "\",\"draft\":false,\"prerelease\":false,\"html_url\":\"" +
            UpdateChecker.ReleasesUrl + "/tag/v" + version + "\"}";
    }
    static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    static void Receipt(string directory, string version)
    {
        File.WriteAllText(Path.Combine(directory, ".mpvnet-kit-install.json"), UpdateData.Json().Serialize(new Dictionary<string, object> {
            { "schema", 1 }, { "owner", "mpvnet-kit" }, { "kind", "receipt" }, { "target", directory }, { "packageVersion", version } }));
    }
    public static IDictionary<string, object> Run(string name, string directory)
    {
        var output = new Dictionary<string, object>();
        var transport = new FixtureUpdateTransport();
        DateTime now = new DateTime(2026, 11, 9, 12, 0, 0, DateTimeKind.Utc);
        if (name == "versions") {
            Require(KitVersion.Stable("0.10.0").CompareTo(KitVersion.Stable("0.9.99")) > 0, "numeric comparison");
            Require(KitVersion.Stable("999999999999999999999999.0.0").CompareTo(KitVersion.Stable("2.0.0")) > 0, "overflow safe comparison");
            foreach (string text in new [] { "v0.5.0", "00.5.0", "0.5", "0.5.0-preview", "0.5.0\n", "-1.0.0", "0.5.0/evil" })
                Require(KitVersion.Stable(text) == null, "accepted invalid stable version");
            Require(KitVersion.Development("0.5.0-m3.5-preview") && KitVersion.Development("0.5.0+local"), "development version");
            Require(UpdateChecker.ParseRelease(Release("0.6.0")) == "0.6.0", "valid official response");
            var invalid = new List<string> { "{}", "[]", "null", Release("0.6.0-rc1"), Release("00.6.0"),
                Release("0.6.0").Replace("\"draft\":false", "\"draft\":true"),
                Release("0.6.0").Replace("\"prerelease\":false", "\"prerelease\":true"),
                Release("0.6.0").Replace("github.com/takkoury", "github.com/attacker"),
                Release("0.6.0").Replace("https:", "http:"), Release("0.6.0").Replace("tag/v0.6.0", "tag/v0.7.0"),
                new string(' ', GitHubUpdateTransport.ResponseLimit + 1) };
            foreach (string text in invalid) {
                bool rejected = false;
                try { UpdateChecker.ParseRelease(text); }
                catch (IOException) { rejected = true; } catch (ArgumentException) { rejected = true; } catch (InvalidOperationException) { rejected = true; } catch (InvalidDataException) { rejected = true; }
                Require(rejected, "accepted invalid official release");
            }
        } else if (name == "receipt") {
            Receipt(directory, "0.5.0"); var checker = new UpdateChecker(directory, transport, () => now);
            Require(checker.CurrentVersion == "0.5.0", "receipt without backup chain");
            Receipt(directory, "0.5.0-m3.5-preview");
            Require(checker.Check(false, () => false, CancellationToken.None).Status == "development" && transport.Calls == 0, "development automatic request");
            Require(checker.Check(true, () => true, CancellationToken.None).Status == "development" && transport.Calls == 0, "development manual request");
            string path = Path.Combine(directory, ".mpvnet-kit-install.json");
            File.WriteAllText(path, File.ReadAllText(path).Replace("mpvnet-kit", "another-owner"));
            Require(checker.ReadInstalledVersion() == "", "receipt owner");
            Receipt(directory, "0.5.0"); var data = UpdateData.Read(path, 1048576); data["target"] = Path.GetTempPath();
            File.WriteAllText(path, UpdateData.Json().Serialize(data)); Require(checker.ReadInstalledVersion() == "", "receipt target");
            File.Delete(path); File.WriteAllText(Path.Combine(directory, "manifest.json"), "{\"version\":\"9.9.9\"}");
            Require(checker.Check(true, () => true, CancellationToken.None).Status == "uninstalled" && transport.Calls == 0, "manifest fallback");
        } else if (name == "throttle") {
            Receipt(directory, "0.5.0"); transport.Fail = true; var checker = new UpdateChecker(directory, transport, () => now);
            Require(checker.Check(false, () => false, CancellationToken.None).Status == "failed", "network failure");
            transport.Fail = false; now = now.AddHours(23);
            Require(checker.Check(false, () => false, CancellationToken.None).Status == "failed" && transport.Calls == 1, "failure cache daily throttle");
            now = now.AddHours(1);
            Require(checker.Check(false, () => false, CancellationToken.None).Available && transport.Calls == 2, "24 hour expiry");
            Require(checker.Check(true, () => true, CancellationToken.None).Available && transport.Calls == 3, "manual daily bypass");
            transport.Fail = true;
            Require(checker.Check(true, () => true, CancellationToken.None).Status == "failed", "failed retry clears old success");
            Require(checker.Check(false, () => false, CancellationToken.None).Status == "failed" && transport.Calls == 4, "failed cache must not claim current");
            Require(Directory.GetFiles(directory, "*.tmp").Length == 0, "atomic save cleanup");
        } else if (name == "preferences") {
            Receipt(directory, "0.5.0"); var checker = new UpdateChecker(directory, transport, () => now);
            Require(checker.AutoEnabled(), "missing preference default");
            string path = Path.Combine(directory, "mpvnet-user.json");
            foreach (string document in new [] { "{", "{}", "[]", "{\"schema\":1,\"settings\":null}",
                "{\"schema\":1,\"settings\":{\"updates.auto-check\":false}}", "{\"schema\":1,\"settings\":{\"updates.auto-check\":\"true\"}}" }) {
                File.WriteAllText(path, document); Require(!checker.AutoEnabled(), "invalid/disabled preference");
                Require(checker.Check(false, () => false, CancellationToken.None).Status == "disabled" && transport.Calls == 0, "disabled automatic network");
            }
            File.WriteAllText(path, "{\"schema\":1,\"settings\":{\"updates.auto-check\":true}}");
            Require(checker.AutoEnabled() && checker.Check(false, () => false, CancellationToken.None).Available, "enabled preference");
            File.WriteAllText(path, "{\"schema\":1,\"settings\":{\"updates.auto-check\":false}}");
            int shows = 0; Require(!checker.TryNotify("0.6.0", () => { shows++; return true; }, CancellationToken.None) && shows == 0, "preference rechecked before show");
            Require(checker.Check(true, () => true, CancellationToken.None).Available, "manual ignores automatic preference");
        } else if (name == "notification") {
            Receipt(directory, "0.5.0"); var checker = new UpdateChecker(directory, transport, () => now);
            checker.Check(false, () => false, CancellationToken.None); int shows = 0;
            Require(!checker.TryNotify("0.6.0", () => { shows++; return false; }, CancellationToken.None), "failed show");
            Require(checker.TryNotify("0.6.0", () => { shows++; return true; }, CancellationToken.None), "successful show");
            Require(!checker.TryNotify("0.6.0", () => { shows++; return true; }, CancellationToken.None) && shows == 2, "duplicate notification");
            using (var cancelled = new CancellationTokenSource()) { cancelled.Cancel();
                Require(!checker.TryNotify("0.7.0", () => { shows++; return true; }, cancelled.Token) && shows == 2, "cancelled notification"); }
        } else if (name == "hold-check" || name == "join-check" || name == "auto-check") {
            transport.Directory = directory; transport.Hold = name == "hold-check";
            var checker = new UpdateChecker(directory, transport, () => now);
            UpdateResult value = checker.Check(name == "join-check", () => name == "join-check", CancellationToken.None);
            output["status"] = value.Status; output["calls"] = transport.Calls;
        } else if (name == "notify") {
            var checker = new UpdateChecker(directory, transport, () => now);
            output["shown"] = checker.TryNotify("0.6.0", () => { File.AppendAllText(Path.Combine(directory, "notifications.log"), "show\n"); return true; }, CancellationToken.None);
        } else if (name == "window") {
            using (var window = new UpdateWindow(Process.GetCurrentProcess(), true, true, null)) {
                window.Present(new UpdateResult { Status = "available", CurrentVersion = "0.5.0", LatestVersion = "0.6.0" }, true);
                foreach (var field in window.Snapshot()) output[field.Key] = field.Value;
                Require(!window.ShowResult(), "NoShow must not show");
                window.Recall(); Require(!(bool)window.Snapshot()["handle_created"], "NoShow recall creates handle");
            }
        } else if (name == "parent-exit") {
            Receipt(directory, "0.5.0"); transport.Directory = directory; transport.Hold = true;
            var checker = new UpdateChecker(directory, transport, () => now);
            using (var parent = Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -Command Start-Sleep -Milliseconds 900") {
                UseShellExecute = false, CreateNoWindow = true })) {
                var request = new UpdateRequest { ParentPid = parent.Id, Token = "fixture", ConfigDirectory = directory,
                    Automatic = true, ActivationPath = Path.Combine(directory, "request.activate") };
                File.WriteAllText(request.ActivationPath, "0"); var watch = Stopwatch.StartNew();
                using (var host = new UpdateHost(request, parent, checker)) {
                    host.Run();
                    Require(watch.ElapsedMilliseconds < 5000 && host.Result == null, "parent exit must stop pending operation");
                    Require(SpinWait.SpinUntil(() => transport.Cancelled, 1000), "parent exit must cancel transport");
                }
                Require(File.Exists(request.ActivationPath), "host must not delete Lua-owned activation file");
                Require(!File.Exists(Path.Combine(directory, "notifications.log")), "late notification after parent exit");
            }
        } else if (name == "corrupt-state") {
            Receipt(directory, "0.5.0"); File.WriteAllText(Path.Combine(directory, ".mpvnet-kit-update.json"), "{invalid");
            var checker = new UpdateChecker(directory, transport, () => now);
            Require(checker.Check(false, () => false, CancellationToken.None).Status == "failed" && transport.Calls == 0, "corrupt state automatic fail closed");
            Require(checker.Check(true, () => true, CancellationToken.None).Available && transport.Calls == 1, "explicit recovery");
        } else throw new ArgumentException("unknown fixture case");
        output["ok"] = true; return output;
    }
}
