using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

public sealed class UpdateHost : IDisposable
{
    readonly UpdateRequest request;
    readonly Process parent;
    readonly UpdateChecker checker;
    readonly Application app;
    readonly CancellationTokenSource cancellation = new CancellationTokenSource();
    readonly DispatcherTimer timer;
    UpdateWindow window;
    volatile bool manual;
    bool checking, stopped;
    public long LastSeenSerial { get; private set; }
    public UpdateResult Result { get; private set; }
    public UpdateHost(UpdateRequest request, Process parent) : this(request, parent, new UpdateChecker(request.ConfigDirectory)) { }
    public UpdateHost(UpdateRequest request, Process parent, UpdateChecker checker)
    {
        if (request == null || parent == null || checker == null) throw new ArgumentNullException("request");
        this.request = request; this.parent = parent; this.checker = checker;
        app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        manual = !request.Automatic;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        timer.Tick += Tick;
    }
    bool ParentAlive() { try { return !parent.HasExited; } catch (InvalidOperationException) { return false; } catch (Win32Exception) { return false; } }
    void EnsureWindow()
    {
        if (window != null || stopped || !ParentAlive()) return;
        window = new UpdateWindow(parent, false, !manual, StartCheck);
        window.Closed += delegate { Stop(); };
    }
    void ObserveSerial(bool activate)
    {
        long serial = request.ReadSerial();
        if (serial <= LastSeenSerial) return;
        LastSeenSerial = serial; manual = true;
        EnsureWindow();
        if (window == null) return;
        if (Result != null) window.Present(Result, false); else window.Checking(checker.CurrentVersion);
        if (activate) window.Recall();
    }
    void Tick(object sender, EventArgs args)
    {
        if (stopped) return;
        if (!ParentAlive()) { Stop(); return; }
        ObserveSerial(true);
    }
    async void StartCheck()
    {
        if (checking || stopped || !ParentAlive()) return;
        checking = true; Result = null;
        if (manual) { EnsureWindow(); if (window != null) { window.Checking(checker.CurrentVersion); window.ShowResult(); } }
        try {
            UpdateResult value = await Task.Run(() => checker.Check(manual, () => manual, cancellation.Token));
            if (stopped || !ParentAlive()) { Stop(); return; }
            // A click arriving at completion still promotes this same process.
            ObserveSerial(true);
            if (manual && value.Status == "disabled")
                value = await Task.Run(() => checker.Check(true, () => true, cancellation.Token));
            if (stopped || !ParentAlive()) { Stop(); return; }
            Result = value;
            if (manual) {
                EnsureWindow(); if (window != null) { window.Present(value, false); window.ShowResult(); }
            } else if (value.Available) {
                EnsureWindow();
                if (window != null) {
                    window.Present(value, true);
                    bool shown = checker.TryNotify(value.LatestVersion, () => ParentAlive() && !stopped && window.ShowResult(), cancellation.Token);
                    if (!shown) Stop();
                } else Stop();
            } else Stop();
        } catch (OperationCanceledException) { Stop(); }
        catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ArgumentException || error is InvalidOperationException || error is InvalidDataException) {
            if (stopped || !ParentAlive()) { Stop(); return; }
            ObserveSerial(true);
            Result = UpdateResult.Failure(checker.CurrentVersion, "暂时无法完成检查，请重试。");
            if (manual) { EnsureWindow(); if (window != null) { window.Present(Result, false); window.ShowResult(); } }
            else Stop();
        } finally { checking = false; }
    }
    void Stop()
    {
        if (stopped) return;
        stopped = true; cancellation.Cancel(); timer.Stop();
        if (window != null && window.IsVisible) window.Close();
        app.Shutdown();
    }
    public void Run()
    {
        if (!ParentAlive()) return;
        ObserveSerial(false);
        timer.Start(); app.Dispatcher.BeginInvoke(new Action(StartCheck)); app.Run();
    }
    public void Dispose()
    {
        Stop(); timer.Tick -= Tick;
        if (window != null) window.Dispose();
        // A cancelled worker is a background thread. No completion can publish a
        // window after Stop; Lua owns and removes both request/session files.
        cancellation.Dispose();
    }
}

public static class UpdateProgram
{
    [STAThread] public static int Main(string[] args)
    {
        using (var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true }) {
            Process parent = null;
            try {
                string requestPath = ""; bool noShow = false;
                for (int i = 0; i < args.Length; i++) {
                    if (args[i] == "-RequestPath" && requestPath.Length == 0 && i + 1 < args.Length) requestPath = args[++i];
                    else if (args[i] == "-NoShow" || args[i] == "-ValidateOnly") noShow = true;
                    else throw new ArgumentException("更新检查参数无效。");
                }
                var request = UpdateRequest.Load(requestPath);
                parent = Process.GetProcessById(request.ParentPid);
                if (parent.HasExited) throw new InvalidOperationException("播放器已退出。");
                if (noShow) {
                    var checker = new UpdateChecker(request.ConfigDirectory);
                    using (var window = new UpdateWindow(parent, true, request.Automatic, null)) {
                        window.Checking(checker.CurrentVersion);
                        var data = new Dictionary<string, object>(window.Snapshot());
                        data["ok"] = true; data["last_seen_serial"] = request.ReadSerial(); data["status"] = "validated";
                        data["latest_version"] = ""; data["available"] = false;
                        writer.WriteLine(UpdateData.Json().Serialize(data)); return 0;
                    }
                }
                using (var host = new UpdateHost(request, parent)) {
                    host.Run(); var result = host.Result;
                    writer.WriteLine(UpdateData.Json().Serialize(new Dictionary<string, object> { { "ok", true },
                        { "last_seen_serial", host.LastSeenSerial }, { "status", result == null ? "closed" : result.Status },
                        { "latest_version", result == null ? "" : result.LatestVersion }, { "available", result != null && result.Available } }));
                }
                return 0;
            } catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ArgumentException || error is InvalidDataException ||
                error is InvalidOperationException || error is Win32Exception || error is NotSupportedException || error is System.Security.SecurityException) {
                writer.WriteLine("{\"ok\":false,\"error\":\"更新检查暂时无法启动，请重试。\"}"); return 1;
            } finally { if (parent != null) parent.Dispose(); }
        }
    }
}
