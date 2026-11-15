using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

// Presents the player's request. The Lua owner decides when to cancel, restore or enable.
public sealed class UpscaleTaskWindow : Window
{
    const string StateProperty = "user-data/mpvnet/enhancement/upscale";
    const int WindowStyleIndex = -16, WindowExtendedStyleIndex = -20;
    const uint OwnerWindowCommand = 4;
    const uint ChildWindowStyle = 0x40000000, ToolWindowStyle = 0x00000080,
        NoActivateStyle = 0x08000000, TopmostStyle = 0x00000008;
    readonly Action<string> send;
    readonly TextBlock heading, description, stage, elapsed;
    readonly ProgressBar progress;
    readonly Button secondary, primary;
    readonly Expander failureDetails;
    readonly TextBox failureDetailsText;
    string phase, secondaryAction, primaryAction;
    bool actionSent, closingFromPlayer;

    UpscaleTaskWindow(Action<string> sendAction)
    {
        send = sendAction;
        Title = "画面增强";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Microsoft YaHei UI");
        FontSize = 14;
        Background = Brush("#1B1B1B");
        Foreground = Brush("#F2F2F2");
        Resources.Add(typeof(Button), ButtonStyle());

        var body = new StackPanel { Margin = new Thickness(24, 22, 24, 18) };
        heading = Line("", "#F2F2F2"); heading.FontSize = 18; heading.FontWeight = FontWeights.SemiBold;
        description = Line("", "#BFBFBF", 12);
        stage = Line("", "#F2F2F2", 14);
        elapsed = Line("", "#BFBFBF", 8);
        AutomationProperties.SetLiveSetting(stage, AutomationLiveSetting.Polite);
        progress = new ProgressBar { Height = 4, Margin = new Thickness(0, 8, 0, 0),
            Foreground = Brush("#1287BB"), Background = Brush("#303030") };
        AutomationProperties.SetName(progress, "画面准备进度");
        body.Children.Add(heading); body.Children.Add(description); body.Children.Add(stage);
        body.Children.Add(progress); body.Children.Add(elapsed);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 20, 0, 0) };
        secondary = new Button(); secondary.Click += delegate { Request(secondaryAction); };
        primary = new Button { Background = Brush("#0D6F9D"), BorderBrush = Brush("#1287BB"), Margin = new Thickness(8, 0, 0, 0) };
        primary.Click += delegate { Request(primaryAction); };
        actions.Children.Add(secondary); actions.Children.Add(primary); body.Children.Add(actions);

        failureDetailsText = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            Background = Brush("#242424"), Foreground = Brush("#F2F2F2"), BorderBrush = Brush("#555555"),
            Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(8), MaxHeight = 128,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetName(failureDetailsText, "画面增强失败详情");
        failureDetails = new Expander { Header = "查看详情", Content = failureDetailsText,
            Foreground = Brush("#F2F2F2"), Margin = new Thickness(0, 12, 0, 0), Visibility = Visibility.Collapsed };
        body.Children.Add(failureDetails);
        Content = body;

        PreviewKeyDown += delegate(object sender, KeyEventArgs eventArgs) {
            if (eventArgs.Key == Key.Escape) { eventArgs.Handled = true; Request(secondaryAction); }
        };
        Closing += delegate(object sender, CancelEventArgs eventArgs) {
            if (!closingFromPlayer) { eventArgs.Cancel = true; Request(secondaryAction); }
        };
        SourceInitialized += delegate {
            var handle = new WindowInteropHelper(this).Handle;
            int dark = 1;
            try { DwmSetWindowAttribute(handle, 20, ref dark, 4); }
            catch (EntryPointNotFoundException) { }
        };
        Loaded += delegate { secondary.Focus(); };
    }

    public static int Run(Dictionary<string, object> request)
    {
        string token = Text(request, "dialog_token"), pipeName = Text(request, "pipe");
        if (pipeName.StartsWith(@"\\.\pipe\", StringComparison.OrdinalIgnoreCase)) pipeName = pipeName.Substring(9);
        object pid;
        if (token.Length == 0 || token.Length > 256 || pipeName.Length == 0 || pipeName.Length > 256 ||
            pipeName.IndexOfAny(new[] { '\\', '/', ':', '\r', '\n', '\0' }) >= 0 ||
            !request.TryGetValue("parent_pid", out pid) || !(pid is int) || (int)pid <= 0)
            throw new InvalidDataException("画面准备窗口连接无效。");

        using (var parent = Process.GetProcessById((int)pid))
        using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous))
        {
            if (parent.HasExited) return 0;
            pipe.Connect(5000);
            using (var reader = new StreamReader(pipe, new UTF8Encoding(false, true)))
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true })
            {
                var json = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024, RecursionLimit = 20 };
                var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
                UpscaleTaskWindow window = null;
                Action stop = delegate {
                    timer.Stop();
                    window.closingFromPlayer = true;
                    window.Close();
                    application.Shutdown();
                };
                window = new UpscaleTaskWindow(action => {
                    try { writer.WriteLine(json.Serialize(new { command = new[] {
                        "script-message-to", "enhancement_controls", "upscale-dialog-action", token, action } })); }
                    catch (IOException) { application.Dispatcher.BeginInvoke(stop); }
                });

                writer.WriteLine(json.Serialize(new { command = new object[] { "observe_property", 1, StateProperty } }));
                var next = reader.ReadLineAsync();
                bool receivedState = false, shown = false;
                timer.Tick += delegate {
                    try {
                        if (parent.HasExited) { stop(); return; }
                        int count = 0;
                        while (next.IsCompleted && count++ < 32)
                        {
                            string line = next.GetAwaiter().GetResult();
                            if (line == null) { stop(); return; }
                            var message = json.DeserializeObject(line) as Dictionary<string, object>;
                            string eventName = Text(message, "event");
                            if (eventName == "shutdown") { stop(); return; }
                            if (eventName == "property-change" && Text(message, "name") == StateProperty)
                            {
                                object value;
                                message.TryGetValue("data", out value);
                                var state = value as Dictionary<string, object>;
                                if (Text(state, "dialog_token") != token || !Flag(state, "dialog_visible") || !window.Present(state))
                                { stop(); return; }
                                receivedState = true;
                            }
                            next = reader.ReadLineAsync();
                        }
                        // Consume all queued state before the first Show to avoid a retired window flashing.
                        if (receivedState && !next.IsCompleted && !shown) shown = window.ShowFor((uint)parent.Id);
                    } catch (IOException) { stop(); }
                      catch (InvalidOperationException) { stop(); }
                      catch (Win32Exception) { stop(); }
                      catch (ArgumentException) { stop(); }
                };
                timer.Start();
                return application.Run();
            }
        }
    }

    bool Present(Dictionary<string, object> state)
    {
        string nextPhase = Text(state, "phase");
        string requested = Text(state, "requested");
        string model = Text(state, "requested_label");
        if (model.Length == 0) model = requested.Length > 0 ? requested : "此方案";
        bool preparing = nextPhase == "preparing" || nextPhase == "loading" || nextPhase == "checking";
        if (!preparing && nextPhase != "missing" && nextPhase != "failed") return false;

        bool phaseChanged = phase != nextPhase;
        if (phaseChanged) { phase = nextPhase; actionSent = false; }
        if (nextPhase == "missing")
        {
            heading.Text = "需要超分组件";
            description.Text = model + " 需要先准备组件。";
            SetActions("暂不准备", "dismiss", "前往组件", "components");
        }
        else if (nextPhase == "failed")
        {
            heading.Text = "画面增强未启用";
            description.Text = Text(state, "error_text");
            SetActions("知道了", "dismiss", "重试", "retry");
        }
        else
        {
            heading.Text = "正在准备画面增强";
            description.Text = model;
            SetActions("取消准备", "cancel", null, null);
        }
        PresentFailureDetails(state, nextPhase == "failed", model, requested);
        stage.Visibility = preparing ? Visibility.Visible : Visibility.Collapsed;
        string taskStage = Text(state, "stage");
        string stageText = taskStage.Length == 0 ? "准备中…" : taskStage;
        if (stage.Text != stageText)
        {
            stage.Text = stageText;
            var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.FromElement(stage);
            if (preparing && peer != null) peer.RaiseAutomationEvent(System.Windows.Automation.Peers.AutomationEvents.LiveRegionChanged);
        }
        double seconds;
        elapsed.Text = Double.TryParse(Text(state, "elapsed"), NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) &&
            seconds >= 0 && seconds <= 86400 ? "已用时 " + TimeSpan.FromSeconds(seconds).ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture) : "";
        elapsed.Visibility = preparing && elapsed.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        progress.Visibility = preparing && SystemParameters.ClientAreaAnimation ? Visibility.Visible : Visibility.Collapsed;
        progress.IsIndeterminate = progress.Visibility == Visibility.Visible;
        if (phaseChanged && IsActive) secondary.Focus();
        return true;
    }

    void PresentFailureDetails(Dictionary<string, object> state, bool failed, string model, string requested)
    {
        string reason = Text(state, "error_reason");
        if (!failed || String.IsNullOrWhiteSpace(reason))
        {
            failureDetails.IsExpanded = false;
            failureDetails.Visibility = Visibility.Collapsed;
            return;
        }

        var lines = new List<string>();
        if (requested.Length > 0)
            lines.Add("方案  " + model);
        lines.Add("错误代码  " + reason);
        object value;
        var component = state.TryGetValue("component", out value) ? value as Dictionary<string, object> : null;
        string source = Text(component, "source_summary");
        if (source.Length > 0) lines.Add("组件来源  " + source);
        string details = String.Join(Environment.NewLine, lines);
        if (failureDetailsText.Text != details) failureDetailsText.Text = details;
        failureDetails.Visibility = Visibility.Visible;
    }

    bool ShowFor(uint parentPid)
    {
        IntPtr owner = FindPlayerOwner(parentPid);
        if (owner == IntPtr.Zero) return false;
        var interop = new WindowInteropHelper(this) { Owner = owner };
        var handle = interop.EnsureHandle();
        uint pid;
        if (GetWindow(handle, OwnerWindowCommand) != owner ||
            GetWindowThreadProcessId(owner, out pid) == 0 || pid != parentPid) return false;
        // Match the player's native band once. Windows owns later owner z-order changes.
        bool ownerTopmost = (GetWindowStyle(owner, WindowExtendedStyleIndex) & TopmostStyle) != 0;
        bool windowTopmost = (GetWindowStyle(handle, WindowExtendedStyleIndex) & TopmostStyle) != 0;
        if (ownerTopmost != windowTopmost)
            SetWindowPos(handle, new IntPtr(ownerTopmost ? -1 : -2), 0, 0, 0, 0, 0x213); // NOMOVE | NOSIZE | NOACTIVATE | NOOWNERZORDER
        Show();
        return true;
    }

    static IntPtr FindPlayerOwner(uint parentPid)
    {
        // As in settings, transient menu and indicator windows must not own this window.
        IntPtr selected = IntPtr.Zero;
        long largest = 0;
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            uint pid;
            NativeRect bounds;
            if (GetWindowThreadProcessId(window, out pid) == 0 || pid != parentPid ||
                !IsWindowVisible(window) || GetWindow(window, OwnerWindowCommand) != IntPtr.Zero ||
                !GetWindowRect(window, out bounds)) return true;
            long area = OwnerWindowArea(GetWindowStyle(window, WindowStyleIndex),
                GetWindowStyle(window, WindowExtendedStyleIndex), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top);
            if (area > largest) { selected = window; largest = area; }
            return true;
        }, IntPtr.Zero);
        return selected;
    }

    static long OwnerWindowArea(uint style, uint extendedStyle, int width, int height)
    {
        if ((style & ChildWindowStyle) != 0 || (extendedStyle & (ToolWindowStyle | NoActivateStyle)) != 0)
            return 0;
        return width > 0 && height > 0 ? (long)width * height : 0;
    }

    void SetActions(string secondaryText, string back, string primaryText, string next)
    {
        secondaryAction = back; secondary.Content = secondaryText;
        primaryAction = next; primary.Content = primaryText;
        primary.Visibility = next == null ? Visibility.Collapsed : Visibility.Visible;
        primary.IsEnabled = secondary.IsEnabled = !actionSent;
    }

    void Request(string action)
    {
        if (action == null || actionSent || closingFromPlayer) return;
        actionSent = true;
        primary.IsEnabled = secondary.IsEnabled = false;
        send(action);
    }

    static string Text(Dictionary<string, object> data, string key)
    {
        object value;
        return data != null && data.TryGetValue(key, out value) ? Convert.ToString(value, CultureInfo.InvariantCulture) : "";
    }

    static bool Flag(Dictionary<string, object> data, string key)
    {
        object value;
        return data != null && data.TryGetValue(key, out value) && value is bool && (bool)value;
    }

    static Brush Brush(string value) { return (Brush)new BrushConverter().ConvertFromString(value); }

    static TextBlock Line(string value, string colour, double top = 0)
    {
        return new TextBlock { Text = value, Foreground = Brush(colour), TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, top, 0, 0) };
    }

    static Style ButtonStyle()
    {
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(14, 8, 14, 8)));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Brush("#F2F2F2")));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brush("#242424")));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Brush("#555555")));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        var border = new FrameworkElementFactory(typeof(Border), "border");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
        border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Brush("#353535"), "border"));
        template.Triggers.Add(hover);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, Brush("#1287BB"), "border"));
        focus.Setters.Add(new Setter(Border.BorderThicknessProperty, new Thickness(2), "border"));
        template.Triggers.Add(focus);
        var pressed = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty, Brush("#1287BB"), "border"));
        template.Triggers.Add(pressed);
        var disabled = new Trigger { Property = IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(OpacityProperty, 0.5));
        template.Triggers.Add(disabled);
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        return style;
    }

    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    delegate bool WindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern uint GetWindowStyle(IntPtr window, int index);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
