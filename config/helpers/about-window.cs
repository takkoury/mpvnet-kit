using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;

// Read-only presentation for one player instance. The launcher owns the Process
// object and activation file; this window neither writes settings nor opens URLs.
public sealed class AboutWindow : Window, IDisposable
{
    const string Unavailable = "未能读取";
    const string CopyrightText = "Copyright (C) 2000-2024 mpv.net/mpv/mplayer";
    const string LicenseText = "GPL v2 License";
    readonly Process parent;
    readonly bool noShow;
    readonly string activationPath;
    readonly Dictionary<string, string> fields = new Dictionary<string, string>();
    readonly Expander details;
    DispatcherTimer timer;
    bool closed, disposed, running, initiallyPositioned;
    IntPtr playerOwner;
    public long LastSeenSerial { get; private set; }

    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo {
        public int Size; public NativeRect Monitor, Work; public uint Flags;
    }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    static Brush Color(string value) { return (Brush)new BrushConverter().ConvertFromString(value); }
    static string Input(IDictionary<string, object> data, string key) {
        object value; return data.TryGetValue(key, out value) && value is string ? ((string)value).Trim() : "";
    }
    static string Known(string value) { return String.IsNullOrWhiteSpace(value) ? Unavailable : value; }

    public AboutWindow(IDictionary<string, object> data, Process parent, bool noShow)
    {
        if (data == null || parent == null) throw new ArgumentNullException(data == null ? "data" : "parent");
        object schema, pid;
        if (!data.TryGetValue("schema", out schema) || !(schema is int) || (int)schema != 1 ||
            Input(data, "token").Length == 0 || !data.TryGetValue("parent_pid", out pid) ||
            !(pid is int) || (int)pid <= 0 || (int)pid != parent.Id)
            throw new ArgumentException("关于窗口请求无效。");
        activationPath = Input(data, "activation_path");
        if (activationPath.Length == 0 || !Path.IsPathRooted(activationPath))
            throw new ArgumentException("关于窗口唤回路径无效。");
        this.parent = parent; this.noShow = noShow;
        LoadInformation(data);

        Title = "关于 mpv.net"; Width = 480; MinWidth = 360;
        SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None; ShowInTaskbar = false; Topmost = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14;
        Foreground = Color("#E5E5E5"); Background = Color("#151515");
        ConfigureReadingStyles();
        WindowChrome.SetWindowChrome(this, new WindowChrome {
            CaptionHeight = 36, ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(0), UseAeroCaptionButtons = false
        });

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var caption = new DockPanel { LastChildFill = true, Background = Color("#1C1C1C") };
        var closeCaption = ActionButton("\uE8BB", "关闭关于窗口", true);
        closeCaption.FontFamily = new FontFamily("Segoe MDL2 Assets");
        closeCaption.Width = 44; closeCaption.Height = 36; closeCaption.FontSize = 10;
        WindowChrome.SetIsHitTestVisibleInChrome(closeCaption, true);
        DockPanel.SetDock(closeCaption, Dock.Right); caption.Children.Add(closeCaption);
        caption.Children.Add(new TextBlock { Text = "关于", FontSize = 12,
            Foreground = Color("#D5D5D5"), Margin = new Thickness(16, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center });
        root.Children.Add(caption);

        var body = new StackPanel { Margin = new Thickness(28, 22, 28, 12) };
        body.Children.Add(Selectable("mpv.net", 28, "#F2F2F2"));
        var host = Selectable("版本 " + fields["host_version"], 14, "#BFBFBF");
        host.Margin = new Thickness(0, 4, 0, 22); body.Children.Add(host);
        body.Children.Add(VersionRow("mpv", fields["mpv_version"]));
        body.Children.Add(VersionRow("FFmpeg", fields["ffmpeg_version"]));
        body.Children.Add(VersionRow("MediaInfo", fields["mediainfo_version"]));
        details = new Expander { Header = "许可与文件日期", IsExpanded = false,
            Margin = new Thickness(0, 18, 0, 2), Foreground = Color("#BFBFBF") };
        details.Content = Selectable(CopyrightText + "\n" + LicenseText +
            "\n\n文件最后修改日期\nmpv.net：" + fields["host_modified"] +
            "\nlibmpv-2.dll：" + fields["mpv_modified"] +
            "\nMediaInfo.dll：" + fields["mediainfo_modified"], 12, "#BFBFBF");
        body.Children.Add(details);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, CanContentScroll = false };
        Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var footer = new DockPanel { LastChildFill = false, Margin = new Thickness(28, 8, 28, 22) };
        var close = ActionButton("关闭", "关闭关于窗口", false);
        close.MinWidth = 88; close.Height = 34; close.Padding = new Thickness(16, 0, 16, 0);
        DockPanel.SetDock(close, Dock.Right); footer.Children.Add(close);
        Grid.SetRow(footer, 2); root.Children.Add(footer); Content = root;

        PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
            if (e.Key == Key.Escape) { e.Handled = true; Close(); }
        };
        SourceInitialized += delegate { AttachOwner(); SetInitialPosition(); };
        Loaded += delegate {
            SetInitialPosition(); initiallyPositioned = true;
            if (!running || closed || disposed || noShow) return;
            // Do not confirm activation requests before the first visible load.
            // A close before this point reports only Run's initial serial.
            Tick();
            if (!closed && !disposed && timer != null) timer.Start();
        };
        SizeChanged += delegate(object sender, SizeChangedEventArgs args) {
            if (initiallyPositioned && args.HeightChanged) KeepBottomVisible();
        };
        Closed += delegate { closed = true; StopTimer(); };
    }

    void ConfigureReadingStyles()
    {
        // Retain the settings window's quiet, narrow dark scrollbar. Details
        // use a text disclosure, with a small underline only for keyboard focus.
        const string xaml = @"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
<Style x:Key='AboutDetailsToggle' TargetType='ToggleButton'>
 <Setter Property='FocusVisualStyle' Value='{x:Null}'/><Setter Property='Foreground' Value='#BFBFBF'/>
 <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ToggleButton'>
  <Border Background='Transparent' Padding='0,5,0,5'>
   <StackPanel Orientation='Horizontal'>
    <Path x:Name='arrow' Data='M 0,0 L 4,4 L 0,8' Stroke='#A6A6A6' StrokeThickness='1.2' StrokeStartLineCap='Round' StrokeEndLineCap='Round' Width='8' Height='8' Stretch='None' Margin='0,0,8,0' VerticalAlignment='Center'/>
    <Border x:Name='focus' BorderBrush='Transparent' BorderThickness='0,0,0,1' Padding='0,1,0,2'><ContentPresenter Content='{TemplateBinding Content}' RecognizesAccessKey='True' VerticalAlignment='Center'/></Border>
   </StackPanel>
  </Border>
  <ControlTemplate.Triggers>
   <Trigger Property='IsChecked' Value='True'><Setter TargetName='arrow' Property='Data' Value='M 0,0 L 4,4 L 8,0'/></Trigger>
   <Trigger Property='IsMouseOver' Value='True'><Setter Property='Foreground' Value='#E5E5E5'/></Trigger>
   <Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='focus' Property='BorderBrush' Value='#777777'/></Trigger>
  </ControlTemplate.Triggers>
 </ControlTemplate></Setter.Value></Setter>
</Style>
<Style TargetType='Expander'>
 <Setter Property='Focusable' Value='False'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Expander'>
  <StackPanel>
   <ToggleButton Style='{StaticResource AboutDetailsToggle}' Content='{TemplateBinding Header}' HorizontalAlignment='Left' IsChecked='{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}'/>
   <ContentPresenter x:Name='detailsContent' Visibility='Collapsed' ContentSource='Content' Margin='0,10,0,0'/>
  </StackPanel>
  <ControlTemplate.Triggers><Trigger Property='IsExpanded' Value='True'><Setter TargetName='detailsContent' Property='Visibility' Value='Visible'/></Trigger></ControlTemplate.Triggers>
 </ControlTemplate></Setter.Value></Setter>
</Style>
<Style TargetType='ScrollBar'><Setter Property='Width' Value='10'/><Setter Property='Background' Value='#151515'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Track x:Name='PART_Track' IsDirectionReversed='True' Orientation='Vertical' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' ViewportSize='{TemplateBinding ViewportSize}'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageUpCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType='Thumb'><Border Background='#555555' CornerRadius='3' Width='6' HorizontalAlignment='Center'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageDownCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
</ResourceDictionary>";
        Resources = (ResourceDictionary)XamlReader.Parse(xaml);
    }

    TextBox Selectable(string text, double size, string foreground)
    {
        var box = new TextBox { Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            Background = Brushes.Transparent, Foreground = Color(foreground), FontSize = size,
            SelectionBrush = Color("#1287BB"), VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetName(box, text); return box;
    }

    FrameworkElement VersionRow(string label, string value)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(92) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Selectable(label, 14, "#A6A6A6"));
        var text = Selectable(value, 14, "#E5E5E5"); Grid.SetColumn(text, 1); row.Children.Add(text);
        return row;
    }

    Button ActionButton(string text, string name, bool caption)
    {
        var border = new FrameworkElementFactory(typeof(Border)); border.Name = "frame";
        border.SetValue(Border.BackgroundProperty, caption ? Brushes.Transparent : Color("#252525"));
        border.SetValue(Border.BorderBrushProperty, Color(caption ? "#1C1C1C" : "#414141"));
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(caption ? 0 : 3));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center); border.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Color(caption ? "#8F2633" : "#303030"), "frame"));
        template.Triggers.Add(hover);
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty, Color(caption ? "#B53242" : "#414141"), "frame"));
        template.Triggers.Add(pressed);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, Color("#1287BB"), "frame"));
        template.Triggers.Add(focus);
        var button = new Button { Content = text, Template = template, Foreground = Color("#E5E5E5"),
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = name };
        AutomationProperties.SetName(button, name); button.Click += delegate { Close(); }; return button;
    }

    void LoadInformation(IDictionary<string, object> data)
    {
        string executable = "";
        try { executable = parent.MainModule.FileName; }
        catch (InvalidOperationException) { } catch (Win32Exception) { } catch (NotSupportedException) { }
        string directory = executable.Length == 0 ? "" : Path.GetDirectoryName(executable);
        string mpv = directory.Length == 0 ? "" : Path.Combine(directory, "libmpv-2.dll");
        string mediaInfo = directory.Length == 0 ? "" : Path.Combine(directory, "MediaInfo.dll");
        string hostVersion = Input(data, "host_version");
        if (hostVersion.Length == 0 && executable.Length > 0) {
            try { hostVersion = AssemblyName.GetAssemblyName(executable).Version.ToString(); }
            catch (IOException) { } catch (UnauthorizedAccessException) { } catch (BadImageFormatException) { }
            catch (System.Security.SecurityException) { }
        }
        fields["host_version"] = Known(hostVersion);
        fields["mpv_version"] = Known(Input(data, "mpv_version"));
        fields["ffmpeg_version"] = Known(Input(data, "ffmpeg_version"));
        string mediaInfoVersion = "";
        try { if (File.Exists(mediaInfo)) mediaInfoVersion = FileVersionInfo.GetVersionInfo(mediaInfo).FileVersion; }
        catch (IOException) { } catch (UnauthorizedAccessException) { } catch (Win32Exception) { }
        fields["mediainfo_version"] = Known(mediaInfoVersion);
        fields["host_modified"] = Modified(executable);
        fields["mpv_modified"] = Modified(mpv);
        fields["mediainfo_modified"] = Modified(mediaInfo);
    }

    static string Modified(string path)
    {
        try { if (File.Exists(path)) return File.GetLastWriteTime(path).ToShortDateString(); }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
        return Unavailable;
    }

    bool ParentAlive()
    {
        try { return !parent.HasExited; }
        catch (InvalidOperationException) { return false; } catch (Win32Exception) { return false; }
    }

    long ReadSerial()
    {
        try {
            using (var file = new FileStream(activationPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (file.Length == 0 || file.Length > 32) return 0;
                var bytes = new byte[33]; int count = file.Read(bytes, 0, bytes.Length);
                if (count == 0 || count > 32) return 0;
                string text = Encoding.ASCII.GetString(bytes, 0, count).Trim();
                if (text.Length == 0) return 0;
                for (int i = 0; i < text.Length; i++) if (text[i] < '0' || text[i] > '9') return 0;
                long serial; return Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out serial) ? serial : 0;
            }
        } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return 0;
    }

    public void Tick()
    {
        if (closed || disposed || noShow || !running) return;
        if (!ParentAlive()) { Close(); return; }
        AttachOwner();
        long serial = ReadSerial();
        if (serial <= LastSeenSerial) return;
        LastSeenSerial = serial;
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    void AttachOwner()
    {
        if (closed || noShow || playerOwner != IntPtr.Zero || !ParentAlive()) return;
        var interop = new WindowInteropHelper(this);
        if (interop.Handle == IntPtr.Zero) return;
        try {
            parent.Refresh(); IntPtr candidate = parent.MainWindowHandle; uint pid;
            if (candidate == IntPtr.Zero || GetWindowThreadProcessId(candidate, out pid) == 0 || pid != (uint)parent.Id) return;
            interop.Owner = candidate; playerOwner = candidate;
        } catch (InvalidOperationException) { } catch (Win32Exception) { } catch (ArgumentException) { }
    }

    void SetInitialPosition()
    {
        if (noShow || closed) return;
        Rect work = SystemParameters.WorkArea, area = work;
        if (playerOwner != IntPtr.Zero) {
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            NativeRect bounds;
            var source = PresentationSource.FromVisual(this) as HwndSource;
            Matrix transform = source != null && source.CompositionTarget != null ? source.CompositionTarget.TransformFromDevice : Matrix.Identity;
            if (GetMonitorInfo(MonitorFromWindow(playerOwner, 2), ref info)) {
                Point a = transform.Transform(new Point(info.Work.Left, info.Work.Top));
                Point b = transform.Transform(new Point(info.Work.Right, info.Work.Bottom));
                work = new Rect(a, b); area = work;
            }
            if (GetWindowRect(playerOwner, out bounds)) {
                Point a = transform.Transform(new Point(bounds.Left, bounds.Top));
                Point b = transform.Transform(new Point(bounds.Right, bounds.Bottom));
                area = new Rect(a, b);
            }
        }
        MaxHeight = Math.Max(120, work.Height - 32);
        double width = Math.Min(Width, Math.Max(120, work.Width - 32));
        MinWidth = Math.Min(MinWidth, width); Width = width;
        Measure(new Size(width, MaxHeight));
        double height = Math.Min(MaxHeight, ActualHeight > 0 ? ActualHeight : DesiredSize.Height);
        Left = Math.Max(work.Left + 16, Math.Min(area.Left + (area.Width - width) / 2, work.Right - width - 16));
        Top = Math.Max(work.Top + 16, Math.Min(area.Top + (area.Height - height) / 2, work.Bottom - height - 16));
    }

    void KeepBottomVisible()
    {
        if (noShow || closed || !IsLoaded) return;
        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
        var source = PresentationSource.FromVisual(this) as HwndSource;
        if (!GetMonitorInfo(MonitorFromWindow(handle, 2), ref info) || source == null || source.CompositionTarget == null) return;
        Matrix transform = source.CompositionTarget.TransformFromDevice;
        Point a = transform.Transform(new Point(info.Work.Left, info.Work.Top));
        Point b = transform.Transform(new Point(info.Work.Right, info.Work.Bottom));
        MaxHeight = Math.Max(120, b.Y - a.Y - 32);
        // Preserve the user's position on collapse and while there is room.
        // Growing content only moves upward enough to keep the footer visible.
        if (Top + ActualHeight > b.Y - 16)
            Top = Math.Max(a.Y + 16, b.Y - ActualHeight - 16);
    }

    public void Run()
    {
        if (disposed) throw new ObjectDisposedException("AboutWindow");
        if (noShow || closed || running || !ParentAlive()) return;
        LastSeenSerial = Math.Max(LastSeenSerial, ReadSerial()); running = true;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += TimerTick;
        // WPF modal processing concerns windows on this helper's UI thread.
        // The owner is an external HWND; never disable the player via EnableWindow.
        try { ShowDialog(); } finally { running = false; StopTimer(); }
    }

    void TimerTick(object sender, EventArgs args) { Tick(); }
    void StopTimer() { if (timer != null) { timer.Stop(); timer.Tick -= TimerTick; timer = null; } }

    public IDictionary<string, object> Snapshot()
    {
        var result = new Dictionary<string, object>();
        foreach (var pair in fields) result[pair.Key] = pair.Value;
        result["copyright"] = CopyrightText; result["license"] = LicenseText;
        result["text"] = "mpv.net\n版本 " + fields["host_version"] + "\nmpv " + fields["mpv_version"] +
            "\nFFmpeg " + fields["ffmpeg_version"] + "\nMediaInfo " + fields["mediainfo_version"] +
            "\n" + CopyrightText + "\n" + LicenseText + "\n文件最后修改日期\nmpv.net：" + fields["host_modified"] +
            "\nlibmpv-2.dll：" + fields["mpv_modified"] + "\nMediaInfo.dll：" + fields["mediainfo_modified"];
        result["handle_created"] = new WindowInteropHelper(this).Handle != IntPtr.Zero;
        result["timer_running"] = timer != null && timer.IsEnabled;
        result["closed"] = closed; result["last_seen_serial"] = LastSeenSerial;
        result["show_in_taskbar"] = ShowInTaskbar; result["topmost"] = Topmost;
        result["resize_mode"] = ResizeMode.ToString(); result["owner_attached"] = playerOwner != IntPtr.Zero;
        result["details_expanded"] = details.IsExpanded;
        return result;
    }

    public void Dispose() { if (disposed) return; disposed = true; StopTimer(); }
}
