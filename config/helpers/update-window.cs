using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;

// Modeless, player-owned presentation only. The host owns checking and lifetime;
// this window never pauses the player and opens only validated official URLs.
public sealed class UpdateWindow : Window, IDisposable
{
    readonly Process parent;
    readonly bool noShow;
    readonly TextBlock heading, description;
    readonly Button primary, close;
    readonly Action retry;
    UpdateResult result;
    IntPtr playerOwner;
    bool closed;
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    delegate bool OwnerCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(OwnerCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern uint GetWindowStyle(IntPtr window, int index);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    static Brush Color(string value) { return (Brush)new BrushConverter().ConvertFromString(value); }
    public bool HasShown { get; private set; }
    public UpdateWindow(Process parent, bool noShow, bool automatic, Action retry)
    {
        if (parent == null) throw new ArgumentNullException("parent");
        this.parent = parent; this.noShow = noShow; this.retry = retry;
        Title = "检查 mpvnet-kit 更新"; Width = 380; MinWidth = 320;
        SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None; ShowInTaskbar = false; Topmost = false;
        ShowActivated = !automatic; WindowStartupLocation = WindowStartupLocation.Manual;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14;
        Foreground = Color("#E5E5E5"); Background = Color("#151515");
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 36,
            ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0), UseAeroCaptionButtons = false });
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var caption = new DockPanel { LastChildFill = true, Background = Color("#1C1C1C") };
        var captionClose = ActionButton("\uE8BB", "关闭更新窗口", true);
        captionClose.FontFamily = new FontFamily("Segoe MDL2 Assets");
        captionClose.Width = 44; captionClose.Height = 36; captionClose.FontSize = 10;
        captionClose.Click += delegate { Close(); };
        WindowChrome.SetIsHitTestVisibleInChrome(captionClose, true);
        DockPanel.SetDock(captionClose, Dock.Right); caption.Children.Add(captionClose);
        caption.Children.Add(new TextBlock { Text = "mpvnet-kit 更新", FontSize = 12,
            Foreground = Color("#D5D5D5"), Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        root.Children.Add(caption);
        var body = new StackPanel { Margin = new Thickness(24, 24, 24, 22) };
        heading = new TextBlock { Text = "正在检查更新…", FontSize = 18,
            FontWeight = FontWeights.Medium, Foreground = Color("#F2F2F2"), TextWrapping = TextWrapping.Wrap };
        description = new TextBlock { Margin = new Thickness(0, 12, 0, 0), FontSize = 13,
            Foreground = Color("#BFBFBF"), TextWrapping = TextWrapping.Wrap };
        body.Children.Add(heading); body.Children.Add(description); Grid.SetRow(body, 1); root.Children.Add(body);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(24, 12, 24, 14) };
        primary = ActionButton("查看新版", "查看新版", false, true); primary.Visibility = Visibility.Collapsed;
        primary.Click += PrimaryClick;
        close = ActionButton(automatic ? "稍后" : "关闭", "关闭更新窗口", false); close.Click += delegate { Close(); };
        close.Margin = new Thickness(0, 0, 10, 0);
        footer.Children.Add(close); footer.Children.Add(primary);
        var border = new Border { Child = footer, BorderBrush = Color("#292929"), BorderThickness = new Thickness(0, 1, 0, 0) };
        Grid.SetRow(border, 2); root.Children.Add(border); Content = root;
        PreviewKeyDown += delegate(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) { e.Handled = true; Close(); } };
        SourceInitialized += delegate { AttachOwner(); Position(); };
        Loaded += delegate { HasShown = IsVisible; Position(); };
        Closed += delegate { closed = true; };
    }
    Button ActionButton(string text, string name, bool caption, bool emphasized = false)
    {
        var frame = new FrameworkElementFactory(typeof(Border)); frame.Name = "frame";
        frame.SetValue(Border.BackgroundProperty, caption ? Brushes.Transparent : Color(emphasized ? "#386CB4" : "#252525"));
        frame.SetValue(Border.BorderBrushProperty, Color(caption ? "#1C1C1C" : emphasized ? "#386CB4" : "#414141"));
        frame.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        frame.SetValue(Border.CornerRadiusProperty, new CornerRadius(caption ? 0 : 3));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center); frame.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = frame };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Color(caption ? "#8F2633" : emphasized ? "#477DC3" : "#303030"), "frame")); template.Triggers.Add(hover);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, Color("#1287BB"), "frame")); template.Triggers.Add(focus);
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty, Color(caption ? "#B53242" : emphasized ? "#2E5B98" : "#414141"), "frame")); template.Triggers.Add(pressed);
        var button = new Button { Content = text, Template = template, Foreground = Color("#E5E5E5"),
            MinWidth = caption ? 0 : 88, Height = 32, Padding = new Thickness(16, 0, 16, 0) };
        AutomationProperties.SetName(button, name); return button;
    }
    public void Checking(string current)
    {
        result = null; heading.Text = "正在检查更新…";
        description.Text = current.Length > 0 ? "当前版本 " + current : "正在读取当前版本";
        primary.Visibility = Visibility.Collapsed;
    }
    public void Present(UpdateResult value, bool automatic)
    {
        result = value; primary.Visibility = Visibility.Collapsed; close.Content = automatic ? "稍后" : "关闭";
        description.Text = value.CurrentVersion.Length > 0 ? "当前版本 " + value.CurrentVersion : "";
        if (value.Available) {
            heading.Text = "发现新版本 " + value.LatestVersion; primary.Content = "查看新版"; primary.Visibility = Visibility.Visible;
        } else if (value.Status == "current") heading.Text = "当前已是最新版本";
        else if (value.Status == "ahead") { heading.Text = "当前版本高于最新正式版"; description.Text += "\n最新正式版 " + value.LatestVersion; }
        else if (value.Status == "development") {
            heading.Text = "当前为开发版本"; description.Text += "\n开发版本不与正式版比较，可前往官方发行页查看。";
            primary.Content = "查看正式版"; primary.Visibility = Visibility.Visible;
        } else {
            heading.Text = value.Status == "uninstalled" ? "无法读取当前版本" : "暂时无法检查更新";
            description.Text = value.Status == "uninstalled" ? "请确认此配置目录已通过完整安装包安装 mpvnet-kit。" : "请检查网络连接，稍后重试。";
            primary.Content = "重试"; primary.Visibility = Visibility.Visible;
        }
        AutomationProperties.SetName(primary, (string)primary.Content);
    }
    void PrimaryClick(object sender, RoutedEventArgs args)
    {
        if (result == null) return;
        if (result.Available || result.Status == "development") {
            string url = result.Available ? UpdateChecker.ReleaseUrl(result.LatestVersion) : UpdateChecker.ReleasesUrl;
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Win32Exception) { description.Text = "未能打开浏览器，请稍后重试。"; }
            catch (InvalidOperationException) { description.Text = "未能打开浏览器，请稍后重试。"; }
        } else if (retry != null) retry();
    }
    bool ParentAlive() { try { return !parent.HasExited; } catch (InvalidOperationException) { return false; } catch (Win32Exception) { return false; } }
    void AttachOwner()
    {
        if (closed || noShow || !ParentAlive()) return;
        var interop = new WindowInteropHelper(this); if (interop.Handle == IntPtr.Zero) return;
        try {
            uint pid;
            if (playerOwner == IntPtr.Zero || GetWindow(interop.Handle, 4) != playerOwner ||
                GetWindowThreadProcessId(playerOwner, out pid) == 0 || pid != (uint)parent.Id) {
                IntPtr selected = IntPtr.Zero; long largestArea = 0;
                // MainWindowHandle can identify a transient menu or indicator.
                // Match the accepted settings-window rule for the actual player.
                EnumWindows(delegate(IntPtr handle, IntPtr data) {
                    uint candidatePid; NativeRect bounds;
                    if (GetWindowThreadProcessId(handle, out candidatePid) == 0 || candidatePid != (uint)parent.Id ||
                        !IsWindowVisible(handle) || GetWindow(handle, 4) != IntPtr.Zero ||
                        (GetWindowStyle(handle, -16) & 0x40000000) != 0 ||
                        (GetWindowStyle(handle, -20) & 0x08000080) != 0 || !GetWindowRect(handle, out bounds)) return true;
                    long area = (long)Math.Max(0, bounds.Right - bounds.Left) * Math.Max(0, bounds.Bottom - bounds.Top);
                    if (area > largestArea) { largestArea = area; selected = handle; }
                    return true;
                }, IntPtr.Zero);
                if (selected == IntPtr.Zero) return;
                interop.Owner = selected;
                if (GetWindow(interop.Handle, 4) != selected) return;
                playerOwner = selected;
            }
            // Match this owner's native band once at show/recall. Never change
            // the managed Topmost property or activate/raise the player itself.
            bool ownerTopmost = (GetWindowStyle(playerOwner, -20) & 8) != 0;
            bool windowTopmost = (GetWindowStyle(interop.Handle, -20) & 8) != 0;
            if (ownerTopmost != windowTopmost)
                SetWindowPos(interop.Handle, new IntPtr(ownerTopmost ? -1 : -2), 0, 0, 0, 0, 0x213);
        } catch (InvalidOperationException) { } catch (Win32Exception) { } catch (ArgumentException) { }
    }
    void Position()
    {
        if (closed || noShow) return;
        Rect work = SystemParameters.WorkArea, area = work;
        if (playerOwner != IntPtr.Zero) {
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) }; NativeRect bounds;
            var source = PresentationSource.FromVisual(this) as HwndSource;
            Matrix transform = source != null && source.CompositionTarget != null ? source.CompositionTarget.TransformFromDevice : Matrix.Identity;
            if (GetMonitorInfo(MonitorFromWindow(playerOwner, 2), ref info)) {
                work = new Rect(transform.Transform(new Point(info.Work.Left, info.Work.Top)), transform.Transform(new Point(info.Work.Right, info.Work.Bottom)));
                area = work;
            }
            if (GetWindowRect(playerOwner, out bounds)) area = new Rect(transform.Transform(new Point(bounds.Left, bounds.Top)), transform.Transform(new Point(bounds.Right, bounds.Bottom)));
        }
        MaxHeight = Math.Max(120, work.Height - 32); Width = Math.Min(Width, Math.Max(120, work.Width - 32)); MinWidth = Math.Min(MinWidth, Width);
        Measure(new Size(Width, MaxHeight)); double height = Math.Min(MaxHeight, ActualHeight > 0 ? ActualHeight : DesiredSize.Height);
        Left = Math.Max(work.Left + 16, Math.Min(area.Left + (area.Width - Width) / 2, work.Right - Width - 16));
        Top = Math.Max(work.Top + 16, Math.Min(area.Top + (area.Height - height) / 2, work.Bottom - height - 16));
    }
    public bool ShowResult()
    {
        if (noShow || closed || !ParentAlive()) return false;
        Show(); AttachOwner(); UpdateLayout(); HasShown = IsVisible && new WindowInteropHelper(this).Handle != IntPtr.Zero;
        return HasShown;
    }
    public void Recall()
    {
        if (noShow || closed || !ParentAlive()) return;
        ShowActivated = true;
        if (!IsVisible) ShowResult();
        AttachOwner();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }
    public IDictionary<string, object> Snapshot()
    {
        return new Dictionary<string, object> { { "heading", heading.Text }, { "description", description.Text },
            { "primary", primary.Visibility == Visibility.Visible ? primary.Content : "" }, { "close", close.Content },
            { "handle_created", new WindowInteropHelper(this).Handle != IntPtr.Zero }, { "has_shown", HasShown },
            { "show_in_taskbar", ShowInTaskbar }, { "topmost", Topmost }, { "show_activated", ShowActivated },
            { "owner_attached", playerOwner != IntPtr.Zero }, { "resize_mode", ResizeMode.ToString() } };
    }
    public void Dispose() { if (!closed) Close(); }
}
