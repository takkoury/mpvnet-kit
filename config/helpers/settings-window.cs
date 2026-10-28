using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;
using System.Diagnostics;
using System.Threading.Tasks;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Markup;
using System.Windows.Threading;
using System.Windows.Interop;

// Drafts belong to the editor; persistence, preview ownership and application
// belong to Lua. This model contains no WPF objects or filesystem writes.
public sealed class SettingsDraft
{
    public sealed class Field
    {
        public string Id, Page, Label, SearchTerms, Text, BaselineText, Status, ApplyError, Source;
        public object Default, Saved, Effective;
        public bool Override, BaselineOverride, CanCancel;
        public double Min, Max, SliderMin, SliderMax, Step;
        public bool Dirty { get { return Text != BaselineText || Override != BaselineOverride; } }
    }
    public readonly Dictionary<string, Field> Fields = new Dictionary<string, Field>();
    public readonly Dictionary<string, string> Revisions = new Dictionary<string, string>();
    public static readonly string[] Pages = { "subtitles", "controlbar", "paths" };
    public static readonly string[] PageNames = { "字幕", "控制栏", "输出与组件" };
    public static string PageName(string page) { int i = Array.IndexOf(Pages, page); return i < 0 ? page : PageNames[i]; }
    public static string Text(object value) { return value == null ? "" : Convert.ToString(value, CultureInfo.InvariantCulture); }
    public static string Str(Dictionary<string, object> data, string key) { object v; return data.TryGetValue(key, out v) ? Text(v) : ""; }
    public static bool Flag(Dictionary<string, object> data, string key) { object v; return data.TryGetValue(key, out v) && v is bool && (bool)v; }
    public static object Value(Dictionary<string, object> data, string key) { object v; data.TryGetValue(key, out v); return v; }
    public bool Dirty(string page) { return Fields.Values.Any(f => f.Page == page && f.Dirty); }
    public string[] DirtyPages() { return Pages.Where(Dirty).ToArray(); }
    public void Adopt(Dictionary<string, object> state, string committedPage, string submittedRevision = null)
    {
        var dirty = Pages.ToDictionary(p => p, p => Dirty(p));
        object raw;
        if (!state.TryGetValue("fields", out raw) || !(raw is object[])) return;
        foreach (var item in (object[])raw)
        {
            var row = UserPreferencesStorage.Object(item);
            string id = Str(row, "id"), page = Str(row, "page");
            if (!Pages.Contains(page)) continue;
            Field f; bool fresh = !Fields.TryGetValue(id, out f);
            if (fresh) { f = new Field { Id = id, Page = page }; Fields.Add(id, f); }
            f.Label = Str(row, "label"); f.SearchTerms = Str(row, "search_terms"); f.Default = Value(row, "default");
            f.Saved = Value(row, "saved"); f.Effective = Value(row, "effective");
            f.Status = Str(row, "status"); f.ApplyError = Str(row, "apply_error"); f.Source = Str(row, "default_source");
            f.CanCancel = Flag(row, "can_cancel");
            f.Min = row.ContainsKey("min") ? Convert.ToDouble(row["min"], CultureInfo.InvariantCulture) : 0;
            f.Max = row.ContainsKey("max") ? Convert.ToDouble(row["max"], CultureInfo.InvariantCulture) : 0;
            f.SliderMin = row.ContainsKey("slider_min") ? Convert.ToDouble(row["slider_min"], CultureInfo.InvariantCulture) : 0.5;
            f.SliderMax = row.ContainsKey("slider_max") ? Convert.ToDouble(row["slider_max"], CultureInfo.InvariantCulture) : 2;
            f.Step = row.ContainsKey("step") ? Convert.ToDouble(row["step"], CultureInfo.InvariantCulture) : 0.05;
            if (fresh || !dirty[page] || committedPage == page)
            {
                f.Text = f.BaselineText = Text(f.Saved);
                f.Override = f.BaselineOverride = Flag(row, "has_override");
            }
        }
        foreach (string page in Pages)
        {
            string revision = Str(state, page == "paths" ? "paths_revision" : "revision");
            if (!dirty[page] || committedPage == page || !Revisions.ContainsKey(page)) Revisions[page] = revision;
            else if (committedPage != null && committedPage != "paths" && page != "paths" &&
                     Str(state, "save_revision") == revision && Revisions[page] == submittedRevision) Revisions[page] = revision;
        }
    }
    public void Edit(string id, string text) { Field f = Fields[id]; f.Text = text; f.Override = f.Page != "paths" || text.Length > 0; }
    public void Reset(string page)
    {
        foreach (var f in Fields.Values.Where(x => x.Page == page)) { f.Text = Text(f.Default); f.Override = false; }
    }
    public void Revert(string page, Dictionary<string, object> state)
    {
        foreach (var f in Fields.Values.Where(x => x.Page == page)) { f.Text = f.BaselineText; f.Override = f.BaselineOverride; }
        Adopt(state, page);
    }
    public bool TryValue(Field f, out object value)
    {
        value = null;
        if (f.Page == "paths") { value = f.Text; return f.Text.IndexOfAny(new[] { '\r', '\n', '\0' }) < 0; }
        if (!f.Override) return true;
        double number;
        if (!Double.TryParse(f.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out number) ||
            Double.IsNaN(number) || Double.IsInfinity(number) || number < f.Min || number > f.Max) return false;
        value = number; return true;
    }
    public Dictionary<string, object> Values(string page)
    {
        var result = new Dictionary<string, object>();
        foreach (var f in Fields.Values.Where(x => x.Page == page))
        {
            object value;
            if (!TryValue(f, out value)) throw new InvalidDataException(f.Label + "的值无效。");
            result[f.Id] = value;
        }
        return result;
    }
}

// Keep the small visual track, but accept pointer input across the whole row.
// Keyboard commands and range automation remain the standard WPF Slider's.
public sealed class SettingsSlider : Slider
{
    bool dragging;
    double grabOffset, lastX;
    public event Action PointerReleased;
    internal Track ValueTrack { get { ApplyTemplate(); return Template.FindName("PART_Track", this) as Track; } }
    internal double GrabOffset(Point point, out bool overThumb)
    {
        Track track = ValueTrack;
        Rect thumb = track.Thumb.TransformToAncestor(track).TransformBounds(new Rect(track.Thumb.RenderSize));
        // The thumb's horizontal band is also forgiving above and below it.
        overThumb = point.X >= thumb.Left && point.X <= thumb.Right;
        return overThumb ? point.X - (thumb.Left + thumb.Width / 2) : 0;
    }
    internal void SetPointerPosition(Point point, double offset)
    {
        if (!IsEnabled) return;
        Track track = ValueTrack;
        if (track == null || track.ActualWidth <= 0) return;
        double value = track.ValueFromPoint(new Point(point.X - offset, track.ActualHeight / 2));
        if (Double.IsNaN(value) || Double.IsInfinity(value)) return;
        if (IsSnapToTickEnabled && TickFrequency > 0)
            value = Minimum + Math.Round((value - Minimum) / TickFrequency, MidpointRounding.AwayFromZero) * TickFrequency;
        SetCurrentValue(ValueProperty, Math.Max(Minimum, Math.Min(Maximum, value)));
    }
    protected override void OnPreviewMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        Track track = ValueTrack;
        if (!IsEnabled || track == null) { base.OnPreviewMouseLeftButtonDown(e); return; }
        Focus();
        Point point = e.GetPosition(track); bool overThumb;
        grabOffset = GrabOffset(point, out overThumb); lastX = point.X;
        dragging = CaptureMouse();
        if (!overThumb) SetPointerPosition(point, grabOffset);
        e.Handled = true;
    }
    protected override void OnPreviewMouseMove(MouseEventArgs e)
    {
        if (!dragging || e.LeftButton != MouseButtonState.Pressed) { base.OnPreviewMouseMove(e); return; }
        Point point = e.GetPosition(ValueTrack);
        if (point.X != lastX) { SetPointerPosition(point, grabOffset); lastX = point.X; }
        e.Handled = true;
    }
    protected override void OnPreviewMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!dragging) { base.OnPreviewMouseLeftButtonUp(e); return; }
        Point point = e.GetPosition(ValueTrack);
        if (point.X != lastX) SetPointerPosition(point, grabOffset);
        dragging = false; ReleaseMouseCapture();
        if (PointerReleased != null) PointerReleased();
        e.Handled = true;
    }
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        dragging = false; base.OnLostMouseCapture(e);
    }
}

public sealed class SettingsEditor : Window
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int n);
    readonly SettingsDraft model = new SettingsDraft();
    readonly JavaScriptSerializer json = UserPreferencesStorage.Json();
    readonly bool validation, noShow;
    readonly string token;
    readonly Process parent;
    readonly DispatcherTimer timer = new DispatcherTimer();
    readonly SettingsPreview playerPreview = new SettingsPreview();
    readonly List<object> sent = new List<object>();
    readonly Dictionary<string, Control> editors = new Dictionary<string, Control>();
    readonly Dictionary<string, TextBlock> scaleValues = new Dictionary<string, TextBlock>();
    readonly Dictionary<string, Button> categories = new Dictionary<string, Button>();
    Dictionary<string, object> latest = new Dictionary<string, object>();
    NamedPipeClientStream pipe; StreamReader reader; StreamWriter writer; Task<string> read;
    TextBox search; StackPanel content, results; TextBlock notice, heading; Button save, undo, reset;
    Grid previewPane, previewLayout; ScrollViewer settingsScroll; Border previewArea; TextBlock previewMessage, previewTitle; Button previewMode;
    bool fullPreview;
    string page = "subtitles", pendingPage, pendingRevision, localError = "";
    int pendingSerial, serial, sequence;
    bool syncing, saving, forceClose, finished, disconnected;
    bool displayRequested, displayAvailable, selectingPage;
    DateTime lastDisplayRenew;
    DateTime saveStarted;
    static SolidColorBrush Brush(string value) { return (SolidColorBrush)new BrushConverter().ConvertFromString(value); }
    public SettingsEditor(Dictionary<string, object> request, bool validate, bool hidden)
    {
        validation = validate; noShow = hidden;
        UserPreferencesStorage.Schema(request);
        token = UserPreferencesStorage.String(request, "token");
        if (token.Length < 1 || token.Length > 256 || token.Any(Char.IsControl) || SettingsDraft.Str(request, "script") != "user_settings")
            throw new InvalidDataException("设置窗口连接无效。");
        object pid = SettingsDraft.Value(request, "parent_pid");
        if (!(pid is int) || (int)pid <= 0) throw new InvalidDataException("播放器进程无效。");
        parent = Process.GetProcessById((int)pid);
        if (parent.HasExited) throw new InvalidDataException("播放器已退出。");
        string pipeName = UserPreferencesStorage.String(request, "pipe");
        if (pipeName.StartsWith(@"\\.\pipe\", StringComparison.Ordinal)) pipeName = pipeName.Substring(9);
        if (pipeName.Length < 1 || pipeName.Length > 256 || pipeName.IndexOfAny(new[] { '\\', '/', ':', '\r', '\n', '\0' }) >= 0)
            throw new InvalidDataException("播放器连接无效。");
        Build();
        Closing += OnClosing;
        Closed += delegate { Finish(); if (!validation && Application.Current != null) Application.Current.Shutdown(); };
        SourceInitialized += delegate {
            try { int dark = 1; DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, 20, ref dark, 4); } catch { }
        };
        PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
            if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { search.Focus(); search.SelectAll(); e.Handled = true; }
            else if (e.Key == Key.Escape) { if (search.Text.Length > 0) search.Clear(); else Close(); e.Handled = true; }
        };
        timer.Interval = TimeSpan.FromMilliseconds(100); timer.Tick += Tick;
        if (!validation)
        {
            pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous); pipe.Connect(5000);
            reader = new StreamReader(pipe, new UTF8Encoding(false, true));
            writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }; read = reader.ReadLineAsync();
            Send(new object[] { "observe_property", 1, "user-data/mpvnet/settings" });
            Send(new object[] { "enable_event", "client-message" });
            Action("editor-ready"); timer.Start();
        }
    }
    Button Button(string label, Action action)
    {
        var b = new Button { Content = label, Padding = new Thickness(14, 8, 14, 8), Margin = new Thickness(0, 0, 8, 0) };
        b.Click += delegate { action(); }; return b;
    }
    void Build()
    {
        Title = "设置 · mpvnet-kit"; Width = 1100; Height = 720; MinWidth = 760; MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14; Background = Brush("#111111"); Foreground = Brushes.White;
        Resources = (ResourceDictionary)XamlReader.Parse(@"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
<Style TargetType='Button'><Setter Property='Background' Value='#262626'/><Setter Property='Foreground' Value='White'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='border' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='3' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='border' Property='Background' Value='#353535'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='border' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='border' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='border' Property='Background' Value='#1287bb'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='Label'><Setter Property='Foreground' Value='White'/></Style>
<Style TargetType='Slider'><Setter Property='Height' Value='40'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Slider'><Border x:Name='focus' Background='Transparent' BorderBrush='Transparent' BorderThickness='1' Padding='4' CornerRadius='3'><Track x:Name='PART_Track' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' Orientation='Horizontal'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static Slider.DecreaseLarge}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='#1287bb' Height='4' CornerRadius='2'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb Width='16' Height='16'><Thumb.Template><ControlTemplate TargetType='Thumb'><Ellipse Fill='#1287bb' Stroke='White' StrokeThickness='1'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static Slider.IncreaseLarge}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='#555555' Height='4' CornerRadius='2'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Border><ControlTemplate.Triggers><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='focus' Property='BorderBrush' Value='#1287bb'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='TextBox'><Setter Property='Background' Value='#1b1b1b'/><Setter Property='Foreground' Value='White'/><Setter Property='CaretBrush' Value='White'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='Padding' Value='8'/><Style.Triggers><Trigger Property='IsKeyboardFocused' Value='True'><Setter Property='BorderBrush' Value='#1287bb'/></Trigger></Style.Triggers></Style>
</ResourceDictionary>");
        var root = new Grid { Margin = new Thickness(24) }; Content = root;
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition()); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var top = new StackPanel(); root.Children.Add(top);
        top.Children.Add(new TextBlock { Text = "设置", FontSize = 26, Margin = new Thickness(0, 0, 0, 12) });
        search = new TextBox { ToolTip = "搜索设置（Ctrl+F）", Margin = new Thickness(0, 0, 0, 16) };
        top.Children.Add(new Label { Content = "搜索设置", Target = search, Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 6) });
        System.Windows.Automation.AutomationProperties.SetName(search, "搜索设置");
        search.TextChanged += delegate { Search(); }; top.Children.Add(search);
        var body = new Grid(); Grid.SetRow(body, 1); root.Children.Add(body);
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) }); body.ColumnDefinitions.Add(new ColumnDefinition());
        var nav = new StackPanel(); body.Children.Add(nav);
        foreach (string id in SettingsDraft.Pages)
        {
            string selected = id; var b = Button(SettingsDraft.PageName(id), delegate { SelectPage(selected); });
            b.HorizontalContentAlignment = HorizontalAlignment.Left; b.Margin = new Thickness(0, 0, 16, 8); nav.Children.Add(b); categories[id] = b;
        }
        var main = new Grid(); Grid.SetColumn(main, 1); body.Children.Add(main);
        previewLayout = main;
        main.ColumnDefinitions.Add(new ColumnDefinition()); main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); main.RowDefinitions.Add(new RowDefinition());
        previewPane = new Grid { Margin = new Thickness(0, 0, 0, 16), VerticalAlignment = VerticalAlignment.Top };
        previewPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); previewPane.RowDefinitions.Add(new RowDefinition());
        var previewHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        previewMode = Button("完整画面", TogglePreviewMode); previewMode.Padding = new Thickness(8, 4, 8, 4); previewMode.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(previewMode, Dock.Right); previewHeader.Children.Add(previewMode);
        previewTitle = new TextBlock { Foreground = Brush("#bcbcbc"), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        previewHeader.Children.Add(previewTitle); previewPane.Children.Add(previewHeader);
        previewArea = new Border { Height = 230, Background = Brushes.Black, ClipToBounds = true };
        previewMessage = new TextBlock { Text = "正在连接播放器画面…", Foreground = Brush("#bcbcbc"), TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(16) };
        previewArea.Child = previewMessage; Grid.SetRow(previewArea, 1); previewPane.Children.Add(previewArea); main.Children.Add(previewPane);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        settingsScroll = scroll;
        Grid.SetRow(scroll, 1); main.Children.Add(scroll);
        SizeChanged += delegate { ArrangePreview(); UpdatePlayerPreview(); };
        main.SizeChanged += delegate { ArrangePreview(); UpdatePlayerPreview(); };
        StateChanged += delegate { UpdatePlayerPreview(); };
        var panel = new StackPanel(); scroll.Content = panel;
        results = new StackPanel(); panel.Children.Add(results);
        heading = new TextBlock { FontSize = 20, Margin = new Thickness(0, 0, 0, 16) }; panel.Children.Add(heading);
        content = new StackPanel(); panel.Children.Add(content);
        var footer = new StackPanel { Margin = new Thickness(0, 16, 0, 0) }; Grid.SetRow(footer, 2); root.Children.Add(footer);
        notice = new TextBlock { Text = "正在连接播放器…", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) }; footer.Children.Add(notice);
        var actions = new WrapPanel(); footer.Children.Add(actions);
        undo = Button("撤销本页修改", Revert); reset = Button("恢复本页默认", Reset); save = Button("保存本页", Save);
        save.Background = Brush("#1287bb"); actions.Children.Add(undo); actions.Children.Add(reset); actions.Children.Add(save);
        SelectPage(page); Refresh();
    }
    void SelectPage(string id)
    {
        if (page != id && displayRequested) EndDisplay();
        if (page != id) fullPreview = false;
        page = id; editors.Clear(); scaleValues.Clear(); content.Children.Clear(); heading.Text = SettingsDraft.PageName(page);
        previewPane.Visibility = page == "paths" ? Visibility.Collapsed : Visibility.Visible;
        ArrangePreview();
        foreach (var f in model.Fields.Values.Where(x => x.Page == page))
        {
            var field = f;
            var title = new Label { Content = f.Label, Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 8) }; content.Children.Add(title);
            Control input;
            if (f.Page == "paths")
            {
                var pathInput = new TextBox { Text = f.Text, MaxLength = 2048, Margin = new Thickness(0, 0, 0, 8) };
                pathInput.TextChanged += delegate { if (!syncing) EditField(field, pathInput.Text); };
                input = pathInput; content.Children.Add(input);
            }
            else
            {
                var slider = new SettingsSlider { Style = (Style)FindResource(typeof(Slider)), Minimum = f.SliderMin * 100, Maximum = f.SliderMax * 100,
                    SmallChange = f.Step * 100, LargeChange = f.Step * 100, TickFrequency = f.Step * 100,
                    IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, Margin = new Thickness(0, 0, 0, 4) };
                SetSlider(slider, field);
                slider.ValueChanged += delegate { if (!syncing) EditField(field, (slider.Value / 100).ToString("G15", CultureInfo.InvariantCulture)); };
                // An out-of-range retained value can sit beyond a clamped thumb.
                // An explicit click or Home/End must still be able to choose the endpoint.
                slider.PointerReleased += delegate { if (!syncing) ReleaseSlider(field, slider); };
                slider.PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
                    if (e.Key == Key.Space || e.Key == Key.Return) { Preview(field); e.Handled = true; return; }
                    if (e.Key == Key.Home || e.Key == Key.End) {
                        slider.Value = e.Key == Key.Home ? slider.Minimum : slider.Maximum;
                        EditField(field, (slider.Value / 100).ToString("G15", CultureInfo.InvariantCulture)); e.Handled = true;
                    }
                };
                input = slider; content.Children.Add(slider);
                var percentage = new TextBlock { Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap };
                scaleValues.Add(f.Id, percentage); content.Children.Add(percentage);
            }
            title.Target = input; System.Windows.Automation.AutomationProperties.SetName(input, f.Label);
            System.Windows.Automation.AutomationProperties.SetAutomationId(input, "Setting_" + f.Id);
            editors.Add(f.Id, input);
        }
        selectingPage = true;
        Refresh();
        UpdatePlayerPreview();
        selectingPage = false;
    }
    void EditField(SettingsDraft.Field field, string text)
    {
        if (saving) return;
        if (field.Text == text) return;
        model.Edit(field.Id, text); localError = "";
        object value;
        if (field.Page != "paths" && model.TryValue(field, out value)) Preview(field);
        Refresh();
    }
    void ReleaseSlider(SettingsDraft.Field field, Slider slider)
    {
        string value = (slider.Value / 100).ToString("G15", CultureInfo.InvariantCulture);
        if (field.Text == value) Preview(field);
        else EditField(field, value);
    }
    static void SetSlider(Slider slider, SettingsDraft.Field field)
    {
        double value;
        if (Double.TryParse(field.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !Double.IsNaN(value) && !Double.IsInfinity(value))
            slider.Value = Math.Max(slider.Minimum, Math.Min(slider.Maximum, value * 100));
    }
    void TogglePreviewMode()
    {
        fullPreview = !fullPreview; ArrangePreview(); UpdatePlayerPreview();
    }
    void ArrangePreview()
    {
        if (previewLayout == null || settingsScroll == null) return;
        previewTitle.Text = fullPreview ? "完整画面" : page == "controlbar" ? "控制栏局部预览" : "字幕区域预览";
        previewMode.Content = fullPreview ? "局部预览" : "完整画面";
        bool wide = (ActualWidth > 0 ? ActualWidth : Width) >= 1000 && page != "paths";
        previewLayout.ColumnDefinitions[0].Width = wide ? new GridLength(280) : new GridLength(1, GridUnitType.Star);
        previewLayout.ColumnDefinitions[1].Width = wide ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        previewLayout.RowDefinitions[0].Height = wide ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        previewLayout.RowDefinitions[1].Height = wide ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetColumn(previewPane, wide ? 1 : 0); Grid.SetRow(settingsScroll, wide ? 0 : 1);
        previewPane.Margin = wide ? new Thickness(20, 0, 0, 0) : new Thickness(0, 0, 0, 16);
        double windowWidth = ActualWidth > 0 ? ActualWidth : Width;
        double fraction = fullPreview ? 1 : page == "controlbar" ? 0.35 : 0.45;
        double desired = wide ? Math.Max(100, Math.Min(380, (windowWidth - 510) * 9 / 16 * fraction)) : Math.Max(100, Math.Min(260, ActualHeight * 0.3 * fraction));
        if (previewLayout.ActualHeight > 0) desired = Math.Min(desired, Math.Max(80, previewLayout.ActualHeight - (wide ? 36 : 150)));
        previewArea.Height = desired;
    }
    void Search()
    {
        results.Children.Clear(); string query = search.Text.Trim();
        if (query.Length == 0) return;
        foreach (var f in model.Fields.Values.Where(f => (f.Label + " " + f.Id + " " + f.SearchTerms + " " + SettingsDraft.PageName(f.Page)).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0))
        {
            var field = f;
            var b = Button(f.Label + " · " + SettingsDraft.PageName(f.Page), delegate {
                SelectPage(field.Page); Control input; if (editors.TryGetValue(field.Id, out input)) { input.BringIntoView(); input.Focus(); var pathInput = input as TextBox; if (pathInput != null) pathInput.SelectAll(); }
            }); b.Margin = new Thickness(0, 0, 0, 8); results.Children.Add(b);
        }
        if (results.Children.Count == 0) results.Children.Add(new TextBlock { Text = "没有匹配的设置", Margin = new Thickness(0, 0, 0, 16) });
    }
    void Preview(SettingsDraft.Field f)
    {
        if (saving || disconnected) return;
        object value;
        if (!model.TryValue(f, out value)) { localError = f.Label + "请输入 " + f.Min + " 至 " + f.Max + " 的数值。"; Refresh(); return; }
        if (f.Page == "controlbar") BeginDisplay();
        Action("preview", f.Id, json.Serialize(value));
    }
    void BeginDisplay()
    {
        if (disconnected || (!validation && !displayAvailable)) return;
        Action("preview-display", "controlbar"); displayRequested = true; lastDisplayRenew = DateTime.UtcNow;
    }
    void EndDisplay()
    {
        if (displayRequested) { try { Action("preview-display", "none"); } catch { } }
        displayRequested = false;
    }
    void DisplayAvailability(bool available)
    {
        bool becameAvailable = available && !displayAvailable;
        displayAvailable = available;
        if (!available || page != "controlbar") EndDisplay();
        else if (becameAvailable || selectingPage && !displayRequested) BeginDisplay();
        else if (displayRequested && (DateTime.UtcNow - lastDisplayRenew).TotalSeconds >= 1)
        { Action("preview-display", "renew"); lastDisplayRenew = DateTime.UtcNow; }
    }
    void UpdatePlayerPreview()
    {
        if (previewArea == null || validation) return;
        bool enabled = page != "paths" && !disconnected;
        object position = SettingsDraft.Value(latest, "preview_subtitle_position");
        string message = playerPreview.Update(this, previewArea, parent, enabled, fullPreview ? "full" : page,
            position == null ? 100 : Convert.ToDouble(position, CultureInfo.InvariantCulture));
        bool available = enabled && playerPreview.Visible;
        previewMessage.Text = message;
        previewMessage.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        DisplayAvailability(available);
    }
    void Reset() { if (saving) return; model.Reset(page); SyncInputs(); foreach (var f in model.Fields.Values.Where(x => x.Page == page && page != "paths")) Preview(f); Refresh(); }
    void Revert() { if (saving) return; Action("cancel", page); model.Revert(page, latest); localError = ""; SyncInputs(); Refresh(); }
    void Save()
    {
        if (!save.IsEnabled) return;
        Dictionary<string, object> values;
        try { values = model.Values(page); } catch (Exception e) { localError = e.Message; Refresh(); return; }
        saving = true; pendingPage = page; pendingRevision = model.Revisions[page]; pendingSerial = serial; saveStarted = DateTime.UtcNow; localError = "";
        Action("save", pendingRevision, page, json.Serialize(values)); Refresh();
    }
    void SyncInputs()
    {
        syncing = true;
        foreach (var item in editors) {
            var text = item.Value as TextBox;
            if (text != null) text.Text = model.Fields[item.Key].Text;
            else SetSlider((Slider)item.Value, model.Fields[item.Key]);
        }
        syncing = false;
    }
    void Refresh()
    {
        foreach (var item in categories) { item.Value.Content = SettingsDraft.PageName(item.Key) + (model.Dirty(item.Key) ? " *" : ""); item.Value.BorderBrush = Brush(item.Key == page ? "#1287bb" : "#555555"); }
        foreach (var item in scaleValues)
        {
            var f = model.Fields[item.Key];
            item.Value.Text = DisplayField(f, f.Text);
        }
        string error = SettingsDraft.Str(latest, page == "paths" ? "paths_error" : "error");
        string revision = SettingsDraft.Str(latest, page == "paths" ? "paths_revision" : "revision");
        string baseline; bool stale = model.Revisions.TryGetValue(page, out baseline) && baseline != revision;
        string noticeText = localError.Length > 0 ? localError : error.Length > 0 ? error :
            stale && model.Dirty(page) ? "配置已被其他窗口修改。草稿已保留；撤销本页修改可载入最新值。" :
            saving ? "正在保存…" : "";
        if (!saving && localError.Length == 0 && SettingsDraft.Str(latest, "save_page") == page && serial > 0)
        {
            string saveError = SettingsDraft.Str(latest, "save_error");
            if (saveError.Length > 0) noticeText += "\n" + saveError;
            else if (SettingsDraft.Flag(latest, "save_ok") && !model.Dirty(page) && noticeText.Length == 0) noticeText = "已保存。";
        }
        foreach (var f in model.Fields.Values.Where(f => f.Page == page && f.ApplyError.Length > 0))
            noticeText += "\n" + f.Label + "：" + f.ApplyError;
        string previewError = SettingsDraft.Str(latest, "preview_error"); if (previewError.Length > 0) noticeText += "\n" + previewError;
        notice.Text = noticeText.Trim();
        notice.Visibility = notice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        bool valid = model.Fields.Values.Where(f => f.Page == page).All(f => { object v; return model.TryValue(f, out v); });
        save.IsEnabled = !saving && !disconnected && model.Dirty(page) && !stale && error.Length == 0 && valid;
        undo.IsEnabled = !saving && !disconnected && (model.Dirty(page) || stale || model.Fields.Values.Any(f => f.Page == page && (f.Status == "preview" || f.CanCancel)));
        reset.IsEnabled = !saving && !disconnected && model.Fields.Count > 0 && error.Length == 0;
        content.IsEnabled = !saving;
    }
    static string DisplayField(SettingsDraft.Field field, object value)
    {
        if (field.Page != "paths") {
            double number;
            if (Double.TryParse(SettingsDraft.Text(value), NumberStyles.Float, CultureInfo.InvariantCulture, out number))
                return (number * 100).ToString("0.##", CultureInfo.InvariantCulture) + "%";
            return "暂不可用";
        }
        return Display(value);
    }
    static string Display(object value)
    {
        if (value is double || value is float || value is decimal)
            return Convert.ToDouble(value, CultureInfo.InvariantCulture).ToString("G6", CultureInfo.InvariantCulture);
        string s = SettingsDraft.Text(value); return s.Length == 0 ? "沿用默认" : s;
    }
    public void State(Dictionary<string, object> state)
    {
        if (SettingsDraft.Str(state, "editor_token") != token) return;
        int nextSerial = Convert.ToInt32(SettingsDraft.Value(state, "save_serial") ?? 0);
        string committed = null;
        if (saving && nextSerial > pendingSerial && SettingsDraft.Str(state, "save_page") == pendingPage)
        {
            if (SettingsDraft.Flag(state, "save_ok"))
            {
                string revision = SettingsDraft.Str(state, pendingPage == "paths" ? "paths_revision" : "revision");
                if (SettingsDraft.Str(state, "save_revision") == revision && revision.Length > 0) committed = pendingPage;
                else localError = "文件已保存，但随后又发生变化或未能重新载入。草稿已保留，请核对最新配置。";
            }
            saving = false;
        }
        bool first = model.Fields.Count == 0;
        latest = state; serial = nextSerial; model.Adopt(state, committed, pendingRevision);
        if (first) { SelectPage(page); Search(); } else { SyncInputs(); Refresh(); }
    }
    void Send(object[] command)
    {
        sent.Add(command);
        if (!validation)
        {
            try { writer.WriteLine(json.Serialize(new { command = command, request_id = ++sequence })); }
            catch { Disconnect(); }
        }
    }
    void Action(string operation, params string[] args)
    {
        if (disconnected) return;
        var command = new List<object> { "script-message-to", "user_settings", operation, token }; command.AddRange(args); Send(command.ToArray());
    }
    void Disconnect()
    {
        disconnected = true;
        EndDisplay(); playerPreview.Hide(); displayAvailable = false;
        localError = "播放器连接中断，草稿已保留。请核对保存结果后关闭并重新打开设置。";
        saving = false; Refresh();
    }
    void Tick(object sender, EventArgs e)
    {
        try
        {
            if (parent.HasExited) { forceClose = true; Close(); return; }
            if (disconnected) return;
            UpdatePlayerPreview();
            int count = 0;
            while (read != null && read.IsCompleted && count++ < 64)
            {
                if (read.IsFaulted || read.Result == null) { Disconnect(); return; }
                var message = UserPreferencesStorage.Object(json.DeserializeObject(read.Result));
                string eventName = SettingsDraft.Str(message, "event"); object data = SettingsDraft.Value(message, "data");
                if (eventName == "property-change" && SettingsDraft.Str(message, "name") == "user-data/mpvnet/settings" && data is Dictionary<string, object>) State((Dictionary<string, object>)data);
                else if (eventName == "shutdown") { forceClose = true; Close(); return; }
                else if (eventName == "client-message")
                {
                    object[] args = SettingsDraft.Value(message, "args") as object[];
                    if (args != null && args.Length >= 2 && args[1] as string == token)
                    {
                        if (args[0] as string == "mpvnet-settings-close") { forceClose = true; Close(); return; }
                        if (args[0] as string == "mpvnet-settings-show" && !noShow) { if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
                    }
                }
                read = reader.ReadLineAsync();
            }
            if (saving && (DateTime.UtcNow - saveStarted).TotalSeconds > 20)
            { localError = "保存结果尚未返回，请等待；关闭播放器前先确认配置。"; Refresh(); }
        }
        catch { Disconnect(); }
    }
    bool ConfirmDiscard()
    {
        string[] pages = model.DirtyPages(); if (pages.Length == 0) return true;
        var dialog = new Window { Title = "关闭设置", Owner = this, Width = 470, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Background, Foreground = Foreground, FontFamily = FontFamily, FontSize = FontSize, Resources = Resources };
        var panel = new StackPanel { Margin = new Thickness(24) }; dialog.Content = panel;
        panel.Children.Add(new TextBlock { Text = "以下分类有未保存修改：\n" + String.Join("、", pages.Select(SettingsDraft.PageName)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 20) });
        var actions = new WrapPanel(); panel.Children.Add(actions);
        var back = Button("返回设置", delegate { dialog.DialogResult = false; }); back.IsCancel = true; back.IsDefault = true;
        actions.Children.Add(back); actions.Children.Add(Button("放弃修改并关闭", delegate { dialog.DialogResult = true; }));
        return dialog.ShowDialog() == true;
    }
    void OnClosing(object sender, CancelEventArgs e)
    {
        if (!forceClose && saving) { e.Cancel = true; return; }
        if (!forceClose && !validation && !ConfirmDiscard()) { e.Cancel = true; return; }
        EndDisplay(); playerPreview.Hide();
        try { Action("editor-close"); } catch { }
    }
    public void Finish() { if (finished) return; finished = true; timer.Stop(); playerPreview.Dispose(); if (pipe != null) pipe.Dispose(); parent.Dispose(); }
    public void Run() { if (noShow) new Application().Run(); else new Application().Run(this); }
    // Exercises the same draft and control event paths, without player/filesystem IO.
    FrameworkElement LayoutForValidation()
    {
        var root = (FrameworkElement)Content;
        root.Measure(new Size(Width - 48, Height - 80));
        root.Arrange(new Rect(0, 0, Width - 48, Height - 80)); root.UpdateLayout();
        return root;
    }
    public object Validate(Dictionary<string, object> request)
    {
        if (request.ContainsKey("validation_width")) Width = Convert.ToDouble(request["validation_width"]);
        if (request.ContainsKey("validation_height")) Height = Convert.ToDouble(request["validation_height"]);
        State(UserPreferencesStorage.Object(request["validation_state"]));
        object steps;
        if (request.TryGetValue("validation_steps", out steps)) foreach (var entry in (object[])steps)
        {
            var step = UserPreferencesStorage.Object(entry); string op = SettingsDraft.Str(step, "op");
            if (op == "page") SelectPage(SettingsDraft.Str(step, "page"));
            else if (op == "edit") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); EditField(model.Fields[id], SettingsDraft.Str(step, "text")); SyncInputs(); }
            else if (op == "slide") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); ((Slider)editors[id]).Value = Convert.ToDouble(step["percent"], CultureInfo.InvariantCulture); }
            else if (op == "slide-release") { string id = SettingsDraft.Str(step, "id"); ReleaseSlider(model.Fields[id], (Slider)editors[id]); }
            else if (op == "small-step") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); Slider.IncreaseSmall.Execute(null, editors[id]); }
            else if (op == "pointer-position") {
                string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); LayoutForValidation();
                var slider = (SettingsSlider)editors[id]; var track = slider.ValueTrack;
                slider.SetPointerPosition(new Point(Convert.ToDouble(step["x"]) * track.ActualWidth, Convert.ToDouble(step["y"])), 0);
            }
            else if (op == "full-preview") TogglePreviewMode();
            else if (op == "search") search.Text = SettingsDraft.Str(step, "text");
            else if (op == "state") State(UserPreferencesStorage.Object(step["state"]));
            else if (op == "save") Save(); else if (op == "reset") Reset(); else if (op == "undo") Revert();
            else if (op == "disconnect") Disconnect();
            else if (op == "display-available") DisplayAvailability(SettingsDraft.Flag(step, "value"));
            else if (op == "preview") Preview(model.Fields[SettingsDraft.Str(step, "id")]);
        }
        // NoShow deliberately has no native Window presentation source; measure
        // its actual content tree rather than assume Window is a visual ancestor.
        var layoutRoot = LayoutForValidation();
        var previewBounds = previewArea.TransformToAncestor(layoutRoot).TransformBounds(new Rect(previewArea.RenderSize));
        var saveBounds = save.TransformToAncestor(layoutRoot).TransformBounds(new Rect(save.RenderSize));
        var hits = new Dictionary<string, object>();
        foreach (var pair in editors.Where(pair => pair.Value is SettingsSlider)) {
            var slider = (SettingsSlider)pair.Value; var track = slider.ValueTrack;
            bool all = true;
            foreach (double x in new[] { 0.1, 0.5, 0.9 }) foreach (double y in new[] { 1.0, slider.ActualHeight / 2, slider.ActualHeight - 1 }) {
                var point = new Point(slider.ActualWidth * x, y);
                // NoShow has IsVisible=false, so InputHitTest rejects everything.
                // Check the actual rendered hit geometry without pretending this
                // is physical input dispatch into a visible native window.
                all &= VisualTreeHelper.HitTest(slider, point) != null;
            }
            Rect thumb = track.Thumb.TransformToAncestor(track).TransformBounds(new Rect(track.Thumb.RenderSize));
            bool grabbed; double offset = slider.GrabOffset(new Point(thumb.Left + thumb.Width / 2 + 5, -5), out grabbed);
            hits[pair.Key] = new { height = slider.ActualHeight, full_row = all, offset = offset, grabbed = grabbed };
        }
        return new { ok = true, shown = IsVisible, page = page, dirty_pages = model.DirtyPages(),
            drafts = model.Fields.ToDictionary(x => x.Key, x => new { text = x.Value.Text, overridden = x.Value.Override }),
            revisions = model.Revisions, can_save = save.IsEnabled, saving = saving, notice = notice.Text,
            preview_visible = previewPane.Visibility == Visibility.Visible, display_requested = displayRequested,
            full_preview = fullPreview, scale_labels = scaleValues.ToDictionary(x => x.Key, x => x.Value.Text),
            editor_types = editors.ToDictionary(x => x.Key, x => x.Value.GetType().Name),
            slider_hits = hits,
            layout_valid = saveBounds.Bottom <= layoutRoot.ActualHeight && saveBounds.Right <= layoutRoot.ActualWidth &&
                (page == "paths" || previewBounds.Bottom < saveBounds.Top && previewBounds.Right <= layoutRoot.ActualWidth),
            preview_column = Grid.GetColumn(previewPane),
            preview_fit = SettingsPreview.Fit(new Rect(0, 0, 600, 300), 1920, 1080).ToString(CultureInfo.InvariantCulture),
            search_results = results.Children.OfType<Button>().Select(b => (string)b.Content).ToArray(), sent = sent };
    }
}
