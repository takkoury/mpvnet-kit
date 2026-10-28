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
using System.Windows.Media.Imaging;

// Drafts belong to the editor; persistence, preview ownership and application
// belong to Lua. This model contains no WPF objects or filesystem writes.
public sealed class SettingsDraft
{
    public sealed class Field
    {
        public string Id, Page, Label, SearchTerms, Text, BaselineText, Status, ApplyError, Source, Kind, Display, Timing, Section;
        public object[] Choices = new object[0];
        public double DisplayScale { get { return Display == "percent" ? 100 : 1; } }
        public bool Previewable { get { return Timing == "preview"; } }
        public object Default, Saved, Effective;
        public bool Override, BaselineOverride, CanCancel;
        public double Min, Max, SliderMin, SliderMax, Step;
        public bool Dirty { get { return Text != BaselineText || Override != BaselineOverride; } }
    }
    public readonly Dictionary<string, Field> Fields = new Dictionary<string, Field>();
    public readonly Dictionary<string, string> Revisions = new Dictionary<string, string>();
    readonly Dictionary<string, string> observedRevisions = new Dictionary<string, string>();
    public static readonly string[] Pages = { "subtitles", "audio", "window", "controlbar", "decoding", "paths", "shortcuts", "advanced" };
    public static readonly string[] PageNames = { "字幕", "声音与音轨", "窗口", "控制栏", "解码", "输出与组件", "快捷键", "高级" };
    public static string PageName(string page) { int i = Array.IndexOf(Pages, page); return i < 0 ? page : PageNames[i]; }
    public static string Text(object value) { return value == null ? "" : value is bool ? ((bool)value ? "true" : "false") : Convert.ToString(value, CultureInfo.InvariantCulture); }
    public static string Str(Dictionary<string, object> data, string key) { object v; return data.TryGetValue(key, out v) ? Text(v) : ""; }
    public static bool Flag(Dictionary<string, object> data, string key) { object v; return data.TryGetValue(key, out v) && v is bool && (bool)v; }
    public static object Value(Dictionary<string, object> data, string key) { object v; data.TryGetValue(key, out v); return v; }
    public bool Dirty(string page) { return Fields.Values.Any(f => f.Page == page && f.Dirty); }
    public string[] DirtyPages() { return Pages.Where(Dirty).ToArray(); }
    public void Adopt(Dictionary<string, object> state, string committedPage, string submittedRevision = null)
    {
        var dirty = Pages.ToDictionary(p => p, p => Dirty(p));
        var unchanged = Pages.ToDictionary(p => p, p => true);
        object raw;
        if (!state.TryGetValue("fields", out raw) || !(raw is object[])) return;
        foreach (var item in (object[])raw)
        {
            var row = UserPreferencesStorage.Object(item);
            string id = Str(row, "id"), page = Str(row, "page");
            if (!Pages.Contains(page)) continue;
            Field f; bool fresh = !Fields.TryGetValue(id, out f);
            if (fresh) { f = new Field { Id = id, Page = page }; Fields.Add(id, f); }
            unchanged[page] &= !fresh && f.BaselineText == Text(Value(row, "saved")) && f.BaselineOverride == Flag(row, "has_override");
            f.Label = Str(row, "label"); f.SearchTerms = Str(row, "search_terms"); f.Default = Value(row, "default");
            f.Saved = Value(row, "saved"); f.Effective = Value(row, "effective");
            f.Status = Str(row, "status"); f.ApplyError = Str(row, "apply_error"); f.Source = Str(row, "default_source");
            f.CanCancel = Flag(row, "can_cancel");
            f.Kind = Str(row, "kind"); if (f.Kind.Length == 0) f.Kind = page == "paths" ? "string" : "number";
            f.Display = Str(row, "display"); if (f.Display.Length == 0 && f.Kind == "number") f.Display = "percent";
            f.Timing = Str(row, "timing"); if (f.Timing.Length == 0) f.Timing = page == "paths" ? "restart" : "preview";
            f.Section = Str(row, "section"); f.Choices = Value(row, "choices") as object[] ?? new object[0];
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
            string previous;
            bool safeRebase = unchanged[page] && observedRevisions.TryGetValue(page, out previous) && Revisions.ContainsKey(page) && Revisions[page] == previous && Str(state,page == "paths" ? "paths_error" : "error").Length == 0;
            if (!dirty[page] || committedPage == page || !Revisions.ContainsKey(page) || safeRebase) Revisions[page] = revision;
            else if (committedPage != null && committedPage != "paths" && page != "paths" &&
                     Str(state, "save_revision") == revision && Revisions[page] == submittedRevision) Revisions[page] = revision;
            observedRevisions[page] = revision;
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
        if (f.Kind == "boolean") { bool flag; if (!Boolean.TryParse(f.Text, out flag)) return false; value = flag; return true; }
        if (f.Kind == "string") { value = f.Text; return Encoding.UTF8.GetByteCount(f.Text) <= 512 && !f.Text.Any(c => c < 32 || c == 127); }
        if (f.Kind == "choice") { value = f.Text; return f.Choices.Any(c => Text(Value(UserPreferencesStorage.Object(c), "value")) == f.Text); }
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

public sealed partial class SettingsEditor : Window
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
    readonly Dictionary<string, Grid> settingRows = new Dictionary<string, Grid>();
    readonly Dictionary<string, Button> actionButtons = new Dictionary<string, Button>();
    Grid mainShell; ScrollViewer resultScroll;
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
        KeyDown += delegate(object sender, KeyEventArgs e) {
            if (overlayOpen) return;
            if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { if (page == "shortcuts" && search.Text.Length == 0) shortcuts.FocusSearch(); else { search.Focus(); search.SelectAll(); } e.Handled = true; }
            else if (e.Key == Key.Escape) { if (search.Text.Length > 0) search.Clear(); else Close(); e.Handled = true; }
        };
        timer.Interval = TimeSpan.FromMilliseconds(100); timer.Tick += Tick;
        if (!validation)
        {
            pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous); pipe.Connect(5000);
            reader = new StreamReader(pipe, new UTF8Encoding(false, true));
            writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }; read = reader.ReadLineAsync();
            Send(new object[] { "observe_property", 1, "user-data/mpvnet/settings" });
            Send(new object[] { "observe_property", 2, "user-data/mpvnet/shortcuts" });
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
        Title = "设置 · mpvnet-kit"; Width = 1040; Height = 780; MinWidth = 760; MinHeight = 600;
        Icon = new DrawingImage(new GeometryDrawing(Brush("#1287BB"), null, Geometry.Parse("M 2 1 L 15 9 L 2 17 Z")));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14; Background = Brush("#151515"); Foreground = Brushes.White;
        Resources = (ResourceDictionary)XamlReader.Parse(@"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
<Style TargetType='Button'><Setter Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='border' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='3' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='border' Property='Background' Value='#353535'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='border' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='border' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='border' Property='Background' Value='#1287bb'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='Label'><Setter Property='Foreground' Value='#F2F2F2'/></Style>
<Style TargetType='Slider'><Setter Property='Height' Value='40'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Slider'><Border x:Name='focus' Background='Transparent' BorderBrush='Transparent' BorderThickness='1' Padding='4' CornerRadius='3'><Track x:Name='PART_Track' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' Orientation='Horizontal'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static Slider.DecreaseLarge}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='#1287bb' Height='4' CornerRadius='2'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb Width='16' Height='16'><Thumb.Template><ControlTemplate TargetType='Thumb'><Ellipse Fill='#1287bb' Stroke='White' StrokeThickness='1'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static Slider.IncreaseLarge}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='#555555' Height='4' CornerRadius='2'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Border><ControlTemplate.Triggers><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='focus' Property='BorderBrush' Value='#1287bb'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='TextBox'><Setter Property='VerticalContentAlignment' Value='Center'/><Setter Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='CaretBrush' Value='#F2F2F2'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='Padding' Value='8'/><Style.Triggers><Trigger Property='IsKeyboardFocused' Value='True'><Setter Property='BorderBrush' Value='#1287bb'/></Trigger></Style.Triggers></Style>

<Style TargetType='TextBlock'><Setter Property='Foreground' Value='#F2F2F2'/></Style>
<Style TargetType='ToolTip'><Setter Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='Padding' Value='10'/></Style>
<Style TargetType='ContextMenu'><Setter Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='BorderBrush' Value='#555555'/></Style>
<Style TargetType='ComboBoxItem'><Setter Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='Padding' Value='10,7'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ComboBoxItem'><Border x:Name='row' Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsHighlighted' Value='True'><Setter TargetName='row' Property='Background' Value='#353535'/></Trigger><Trigger Property='IsSelected' Value='True'><Setter TargetName='row' Property='Background' Value='#1287bb'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='ComboBox'><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='Background' Value='#242424'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='HorizontalContentAlignment' Value='Left'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ComboBox'><Grid><ToggleButton x:Name='toggle' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' Focusable='False' IsChecked='{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}' ClickMode='Press'><ToggleButton.Template><ControlTemplate TargetType='ToggleButton'><Border x:Name='outline' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='3'><Path Data='M 0 0 L 4 4 L 8 0' Stroke='#ABABAB' StrokeThickness='1.5' HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,12,0'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='outline' Property='Background' Value='#303030'/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template></ToggleButton><ContentPresenter Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}' IsHitTestVisible='False' HorizontalAlignment='Left' VerticalAlignment='Center' Margin='10,0,30,0'/><Popup x:Name='PART_Popup' IsOpen='{TemplateBinding IsDropDownOpen}' Placement='Bottom' AllowsTransparency='True' Focusable='False'><Border Background='#242424' BorderBrush='#555555' BorderThickness='1' MinWidth='{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}' MaxHeight='300'><ScrollViewer CanContentScroll='True'><ItemsPresenter KeyboardNavigation.DirectionalNavigation='Contained'/></ScrollViewer></Border></Popup></Grid><ControlTemplate.Triggers><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='toggle' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='toggle' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='ScrollBar'><Setter Property='Width' Value='10'/><Setter Property='Background' Value='#151515'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Track x:Name='PART_Track' IsDirectionReversed='True' Orientation='Vertical' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' ViewportSize='{TemplateBinding ViewportSize}'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageUpCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType='Thumb'><Border Background='#555555' CornerRadius='3' Margin='2'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageDownCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='SearchBox' TargetType='TextBox' BasedOn='{StaticResource {x:Type TextBox}}'><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='TextBox'><Border x:Name='outline' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='3'><Grid><ScrollViewer x:Name='PART_ContentHost' Margin='0'/><TextBlock x:Name='watermark' Text='{TemplateBinding Tag}' Foreground='#ABABAB' Margin='{TemplateBinding Padding}' VerticalAlignment='Center' IsHitTestVisible='False' Visibility='Collapsed'/></Grid></Border><ControlTemplate.Triggers><Trigger Property='Text' Value=''><Setter TargetName='watermark' Property='Visibility' Value='Visible'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='outline' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='outline' Property='BorderThickness' Value='2'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='SettingsSwitch' TargetType='CheckBox'><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='CheckBox'><Grid Width='42' Height='28' Background='Transparent' HorizontalAlignment='Left'><Border x:Name='track' Height='22' CornerRadius='11' Background='#454545' BorderBrush='#777' BorderThickness='1'/><Ellipse x:Name='knob' Width='14' Height='14' Fill='#F2F2F2' HorizontalAlignment='Left' Margin='4,0,0,0'/></Grid><ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='track' Property='Background' Value='#1287BB'/><Setter TargetName='knob' Property='HorizontalAlignment' Value='Right'/><Setter TargetName='knob' Property='Margin' Value='0,0,4,0'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='track' Property='BorderBrush' Value='#1287BB'/><Setter TargetName='track' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
</ResourceDictionary>");
        rootPanel = new Grid { Background = Background }; Content = rootPanel;
        bodyPanel = new Grid(); rootPanel.Children.Add(bodyPanel);
        bodyPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(196) }); bodyPanel.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = new Border { Background = Brush("#111111"), Padding = new Thickness(12, 18, 12, 20), BorderBrush = Brush("#282828"), BorderThickness = new Thickness(0,0,1,0) }; bodyPanel.Children.Add(sidebar);
        var nav = new StackPanel(); sidebar.Child = nav;
        var searchRow = new Grid { Margin = new Thickness(0, 0, 0, 18) };
        search = new TextBox { Height = 36, FontSize = 12, Padding = new Thickness(32, 6, 8, 6), Tag = "搜索全部设置", Style = (Style)FindResource("SearchBox") };
        System.Windows.Automation.AutomationProperties.SetName(search, "搜索全部设置"); searchRow.Children.Add(search);
        var magnifier = new System.Windows.Shapes.Path { Data = Geometry.Parse("M 7 1 A 6 6 0 1 0 7 13 A 6 6 0 1 0 7 1 M 11 11 L 16 16"), Stroke = Brush("#ABABAB"), StrokeThickness = 1.6, Width = 16, Height = 16, Stretch = Stretch.Uniform, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10,0,0,0) }; searchRow.Children.Add(magnifier); nav.Children.Add(searchRow);
        foreach (string id in SettingsDraft.Pages) {
            string selected = id; var b = Button(SettingsDraft.PageName(id), delegate { search.Clear(); SelectPage(selected); });
            b.HorizontalContentAlignment = HorizontalAlignment.Left; b.Height = 38; b.Padding = new Thickness(12, 0, 6, 0);
            b.Margin = new Thickness(0, 0, 0, 4); b.BorderThickness = new Thickness(2, 0, 0, 0); b.Background = Brushes.Transparent;
            nav.Children.Add(b); categories[id] = b;
        }
        var shell = new Grid { Margin = new Thickness(30, 24, 30, 0) }; mainShell = shell; Grid.SetColumn(shell, 1); bodyPanel.Children.Add(shell);
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); shell.RowDefinitions.Add(new RowDefinition()); shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        heading = new TextBlock { FontSize = 22, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,0,0,18) }; shell.Children.Add(heading);
        results = new StackPanel(); resultScroll = new ScrollViewer { Content = results, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Visibility = Visibility.Collapsed }; Grid.SetRow(resultScroll,1); shell.Children.Add(resultScroll);
        var main = new Grid(); previewLayout = main; Grid.SetRow(main, 1); shell.Children.Add(main);
        main.ColumnDefinitions.Add(new ColumnDefinition()); main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); main.RowDefinitions.Add(new RowDefinition());
        previewPane = new Grid { Margin = new Thickness(0,0,0,16) }; previewPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); previewPane.RowDefinitions.Add(new RowDefinition());
        previewTitle = new TextBlock { Text = "控制栏预览", Foreground = Brush("#ABABAB"), FontSize = 12, Margin = new Thickness(0,0,0,8) }; previewPane.Children.Add(previewTitle);
        previewMode = Button("完整画面", TogglePreviewMode); // retained for geometry validation, not part of normal editing
        previewArea = new Border { Height = 150, Background = Brushes.Black, ClipToBounds = true };
        previewMessage = new TextBlock { Text = "正在连接播放器画面…", Foreground = Brush("#ABABAB"), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(16) };
        previewArea.Child = previewMessage; Grid.SetRow(previewArea,1); previewPane.Children.Add(previewArea); main.Children.Add(previewPane);
        content = new StackPanel(); settingsScroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetRow(settingsScroll,1); main.Children.Add(settingsScroll);
        shortcuts = new SettingsShortcutsPanel(Send, delegate { if (save != null) Refresh(); }, Confirm);
        Grid.SetRow(shortcuts,1); shell.Children.Add(shortcuts); shortcuts.Visibility = Visibility.Collapsed;
        footerPanel = new Border { BorderBrush = Brush("#2E2E2E"), BorderThickness = new Thickness(0,1,0,0), Padding = new Thickness(0,12,0,16), Margin = new Thickness(0,12,0,0), Background = Background }; Grid.SetRow(footerPanel,2); shell.Children.Add(footerPanel);
        var footer = new StackPanel(); footerPanel.Child = footer;
        notice = new TextBlock { Text = "正在连接播放器…", TextWrapping = TextWrapping.Wrap, Foreground = Brush("#ABABAB"), Margin = new Thickness(0,0,0,8) }; footer.Children.Add(notice);
        var actions = new DockPanel(); footer.Children.Add(actions);
        reset = Button("恢复本页默认", Reset); reset.Background = Brushes.Transparent; reset.BorderThickness = new Thickness(0); reset.Foreground = Brush("#ABABAB"); reset.Padding = new Thickness(0,8,8,8); DockPanel.SetDock(reset,Dock.Left); actions.Children.Add(reset);
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right }; actions.Children.Add(right);
        undo = Button("撤销", Revert); save = Button("保存本页", Save); undo.Background = Brushes.Transparent; undo.BorderThickness = new Thickness(0); save.Background = Brush("#0D6F9D"); save.BorderBrush = Brush("#1287BB"); save.Margin = new Thickness(0); right.Children.Add(undo); right.Children.Add(save);
        search.TextChanged += delegate { shortcuts.CancelCapture(); Search(); };
        search.PreviewKeyDown += delegate(object sender, KeyEventArgs e) { if (e.Key == Key.Down || e.Key == Key.Return) { var first = results.Children.OfType<Button>().FirstOrDefault(); if (first != null) { first.Focus(); if (e.Key == Key.Return) first.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); e.Handled = true; } } };
        SizeChanged += delegate { ArrangePreview(); UpdateSubtitleExample(); UpdatePlayerPreview(); }; main.SizeChanged += delegate { ArrangePreview(); UpdatePlayerPreview(); }; StateChanged += delegate { UpdatePlayerPreview(); };
        SelectPage(page); Refresh();
    }
    void SelectPage(string id)
    {
        if (page != id && displayRequested) EndDisplay();
        if (page != id) fullPreview = false;
        if (!SettingsDraft.Pages.Contains(id)) return;
        if (shortcuts != null) shortcuts.CancelCapture();
        page = id; languageLists.Clear(); subtitleExample = null; subtitleSample = null; editors.Clear(); settingRows.Clear(); scaleValues.Clear(); actionButtons.Clear(); content.Children.Clear(); heading.Text = SettingsDraft.PageName(page);
        previewPane.Visibility = page == "controlbar" ? Visibility.Visible : Visibility.Collapsed;
        previewLayout.Visibility = page == "shortcuts" ? Visibility.Collapsed : Visibility.Visible;
        shortcuts.Visibility = page == "shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        ArrangePreview();
        if (page == "subtitles" && model.Fields.Values.Where(f => f.Page == page).All(f => f.Section.Length == 0)) content.Children.Add(SubtitleExample());
        string section = null;
        foreach (var f in model.Fields.Values.Where(x => x.Page == page).GroupBy(x => x.Section).SelectMany(group => group))
        {
            var field = f;
            if (f.Section.Length > 0 && f.Section != section) {
                content.Children.Add(new TextBlock { Text = f.Section, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = Brush("#ABABAB"), Margin = new Thickness(0, section == null ? 4 : 24, 0, 8) }); section = f.Section;
                if (page == "subtitles" && (f.Section == "外观" || f.Section == "字幕外观")) content.Children.Add(SubtitleExample());
            }
            var row = new Grid { MinHeight = 48, Margin = new Thickness(0, 0, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(page == "paths" ? 154 : 136) }); row.ColumnDefinitions.Add(new ColumnDefinition());
            var title = new Label { Content = f.Label, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) }; row.Children.Add(title);
            Control input; FrameworkElement control;
            if (f.Id == "slang" || f.Id == "alang") { control = LanguageControl(field, out input); }
            else if (f.Id == "sub-font") { var font = Button(FontLabel(f.Text), delegate { FontPicker(field); }); font.HorizontalContentAlignment = HorizontalAlignment.Left; font.Margin = new Thickness(0); control = input = font; }
            else if (f.Kind == "boolean") {
                var toggle = new CheckBox { Content = "", IsChecked = f.Text == "true", VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(8,0,0,0) };
                toggle.Style = (Style)FindResource("SettingsSwitch"); toggle.Checked += delegate { if (!syncing) EditField(field,"true",true); }; toggle.Unchecked += delegate { if (!syncing) EditField(field,"false",true); }; control = input = toggle;
            }
            else if (f.Kind == "choice") {
                var choice = new ComboBox { MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center };
                choice.Items.Add(new ComboBoxItem { Content = "沿用播放器", Tag = null });
                if (f.Kind == "boolean") { choice.Items.Add(new ComboBoxItem { Content = "开启", Tag = "true" }); choice.Items.Add(new ComboBoxItem { Content = "关闭", Tag = "false" }); }
                else foreach (var c in f.Choices) { var option = UserPreferencesStorage.Object(c); choice.Items.Add(new ComboBoxItem { Content = SettingsDraft.Str(option, "label"), Tag = SettingsDraft.Text(SettingsDraft.Value(option, "value")) }); }
                // A currently inherited advanced value remains untouched until an explicit selection.
                SelectChoice(choice, field);
                choice.SelectionChanged += delegate { if (!syncing && choice.SelectedItem is ComboBoxItem) { var selected = (ComboBoxItem)choice.SelectedItem; if (selected.Tag == null) Inherit(field); else EditField(field, (string)selected.Tag, true); } };
                input = choice; control = choice;
            }
            else if (f.Kind == "number") {
                double scale = f.DisplayScale;
                var slider = new SettingsSlider { Style = (Style)FindResource(typeof(Slider)), Minimum = f.SliderMin * scale, Maximum = f.SliderMax * scale,
                    SmallChange = f.Step * scale, LargeChange = f.Step * scale, TickFrequency = f.Step * scale, IsSnapToTickEnabled = true, IsMoveToPointEnabled = true };
                SetSlider(slider, field);
                slider.ValueChanged += delegate { if (!syncing) EditField(field, (slider.Value / field.DisplayScale).ToString("G15", CultureInfo.InvariantCulture)); };
                slider.PointerReleased += delegate { if (!syncing) ReleaseSlider(field, slider); };
                slider.PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
                    if (e.Key == Key.Space || e.Key == Key.Return) { Preview(field); e.Handled = true; return; }
                    if (e.Key == Key.Home || e.Key == Key.End) { slider.Value = e.Key == Key.Home ? slider.Minimum : slider.Maximum; EditField(field, (slider.Value / field.DisplayScale).ToString("G15", CultureInfo.InvariantCulture), !field.Previewable); e.Handled = true; }
                };
                var numeric = new Grid(); numeric.ColumnDefinitions.Add(new ColumnDefinition()); numeric.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(62) }); numeric.Children.Add(slider);
                var value = new TextBlock { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
                Grid.SetColumn(value, 1); numeric.Children.Add(value); scaleValues.Add(f.Id, value); input = slider; control = numeric;
            }
            else {
                var text = new TextBox { Text = f.Text, MaxLength = f.Page == "paths" ? 2048 : 512, MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center };
                text.TextChanged += delegate { if (!syncing) EditField(field, text.Text); }; input = text; control = text;
                if (f.Page == "paths") { var pathRow = new Grid(); pathRow.ColumnDefinitions.Add(new ColumnDefinition()); pathRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); text.Tag = f.Id == "capture_root" ? "默认：图片文件夹中的 Capture" : "自动检测"; text.Style = (Style)FindResource("SearchBox"); pathRow.Children.Add(text); var browse = Button("浏览…", delegate { BrowsePath(field); }); browse.Margin = new Thickness(8,0,0,0); Grid.SetColumn(browse,1); pathRow.Children.Add(browse); control = pathRow; }
            }
            if (f.Id == "slang" || f.Id == "alang") { title.VerticalAlignment = VerticalAlignment.Top; title.Margin = new Thickness(0,8,12,0); }
            if (page != "paths") row.ColumnDefinitions[1].MaxWidth = 430;
            control.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(control, 1); row.Children.Add(control); content.Children.Add(row); settingRows[field.Id] = row;
            title.Target = input; input.ToolTip = FieldDetails(field);
            var menu = new ContextMenu(); var inherit = new MenuItem { Header = "沿用播放器" }; inherit.Click += delegate { Inherit(field); }; menu.Items.Add(inherit); if (f.Id != "sub-visibility") input.ContextMenu = menu;
            System.Windows.Automation.AutomationProperties.SetName(input, f.Label); System.Windows.Automation.AutomationProperties.SetAutomationId(input, "Setting_" + f.Id); editors.Add(f.Id, input);
        }
        if (page == "advanced") { AddAction("编辑 mpv.conf", "edit.mpv.conf"); AddAction("编辑 input.conf", "edit.input.conf"); AddAction("编辑 modernz.conf", "edit.modernz.conf"); AddAction("打开配置目录", "open.config-folder"); }
        selectingPage = true;
        Refresh();
        UpdatePlayerPreview();
        selectingPage = false;
    }
    bool AppearancePage { get { return page == "controlbar"; } }
    void AddAction(string label, string id)
    {
        var b = Button(label, delegate { Action("open-action", id); }); b.HorizontalAlignment = HorizontalAlignment.Left; b.MinWidth = 220; b.Margin = new Thickness(0, 0, 0, 12); content.Children.Add(b); actionButtons[id] = b;
    }
    static string TimingLabel(string timing)
    {
        switch (timing) { case "preview": return "当前媒体预览"; case "next-media": return "下一媒体生效"; case "startup": return "新实例启动时生效"; case "first-media": return "新实例首次播放前生效"; case "restart": return "重启播放器生效"; case "next-task": return "新任务生效"; default: return timing; }
    }
    static string FieldDetails(SettingsDraft.Field f)
    {
        string guidance = "";
        return guidance + TimingLabel(f.Timing) + "\n默认来源：" + f.Source + "\n已保存：" + DetailValue(f, f.Saved) + "\n当前有效：" + DetailValue(f, f.Effective) + "\n默认：" + DetailValue(f, f.Default) + (f.Id == "sub-visibility" ? "" : "\n右键可沿用播放器设置");
    }
    static string DetailValue(SettingsDraft.Field f, object value)
    {
        if (f.Kind == "number") return DisplayField(f, value);
        if (f.Kind == "boolean" && value is bool) return (bool)value ? "开启" : "关闭";
        if (f.Kind == "choice") foreach (var raw in f.Choices) { var choice = UserPreferencesStorage.Object(raw); if (SettingsDraft.Text(SettingsDraft.Value(choice, "value")) == SettingsDraft.Text(value)) return SettingsDraft.Str(choice, "label"); }
        return Display(value);
    }
    void Inherit(SettingsDraft.Field f)
    {
        if (saving) return; f.Text = SettingsDraft.Text(f.Default); f.Override = false; localError = ""; SyncInputs(); if (f.Previewable) Preview(f); Refresh();
    }
    static void SelectChoice(ComboBox combo, SettingsDraft.Field f)
    {
        combo.SelectedIndex = 0;
        if (f.Override) foreach (ComboBoxItem item in combo.Items) if (item.Tag != null && (string)item.Tag == f.Text) { combo.SelectedItem = item; break; }
    }
    void EditField(SettingsDraft.Field field, string text) { EditField(field, text, false); }
    void EditField(SettingsDraft.Field field, string text, bool forceOverride)
    {
        if (saving) return;
        if (field.Text == text && (!forceOverride || field.Override)) return;
        model.Edit(field.Id, text); localError = "";
        object value;
        if (field.Previewable && model.TryValue(field, out value)) Preview(field);
        UpdateSubtitleExample(); Refresh();
    }
    void ReleaseSlider(SettingsDraft.Field field, Slider slider)
    {
        string value = (slider.Value / field.DisplayScale).ToString("G15", CultureInfo.InvariantCulture);
        // Startup values have an explicit inherit/override distinction even when
        // the chosen number equals the current inherited value.
        if (field.Text == value && !field.Override && !field.Previewable) EditField(field, value, true);
        else if (field.Text == value) Preview(field);
        else EditField(field, value);
    }
    static void SetSlider(Slider slider, SettingsDraft.Field field)
    {
        double value;
        if (Double.TryParse(field.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !Double.IsNaN(value) && !Double.IsInfinity(value))
            slider.Value = Math.Max(slider.Minimum, Math.Min(slider.Maximum, value * field.DisplayScale));
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
        previewLayout.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
        previewLayout.ColumnDefinitions[1].Width = new GridLength(0);
        previewLayout.RowDefinitions[0].Height = GridLength.Auto; previewLayout.RowDefinitions[1].Height = new GridLength(1, GridUnitType.Star);
        Grid.SetColumn(previewPane, 0); Grid.SetRow(settingsScroll, 1); previewPane.Margin = new Thickness(0,0,0,16); previewArea.Height = 150;
    }

    static readonly string[][] ActionCatalog = {
        new[] { "编辑 mpv.conf", "edit.mpv.conf", "advanced" }, new[] { "编辑 input.conf", "edit.input.conf", "advanced" }, new[] { "编辑 modernz.conf", "edit.modernz.conf", "advanced" }, new[] { "打开配置目录", "open.config-folder", "advanced" }
    };
    static bool Matches(string haystack, string query) { return query.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).All(word => haystack.IndexOf(word, StringComparison.OrdinalIgnoreCase) >= 0); }
    void Search()
    {
        results.Children.Clear(); string query = search.Text.Trim(); resultScroll.Visibility = query.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        bool searching = query.Length > 0;
        heading.Text = searching ? "搜索结果" : SettingsDraft.PageName(page);
        previewLayout.Visibility = !searching && page != "shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        shortcuts.Visibility = !searching && page == "shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        footerPanel.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
        if (searching) { EndDisplay(); playerPreview.Hide(); }
        if (!searching) { Refresh(); selectingPage = true; UpdatePlayerPreview(); selectingPage = false; return; }
        foreach (var f in model.Fields.Values.Where(f => Matches(f.Label + " " + f.Id + " " + f.SearchTerms + " " + SettingsDraft.PageName(f.Page), query)))
        {
            var field = f;
            var b = SearchResult(f.Label, SettingsDraft.PageName(f.Page), delegate {
                search.Clear(); SelectPage(field.Page); Control input; if (editors.TryGetValue(field.Id, out input)) { input.BringIntoView(); input.Focus(); var pathInput = input as TextBox; if (pathInput != null) pathInput.SelectAll(); }
            }); b.Margin = new Thickness(0, 0, 0, 8); results.Children.Add(b);
        }
        foreach (var item in ActionCatalog.Where(a => Matches(a[0] + " " + a[1] + " " + SettingsDraft.PageName(a[2]), query))) {
            string[] action = item; var button = SearchResult(action[0], SettingsDraft.PageName(action[2]), delegate { search.Clear(); SelectPage(action[2]); actionButtons[action[1]].BringIntoView(); actionButtons[action[1]].Focus(); }); button.Margin = new Thickness(0, 0, 0, 8); results.Children.Add(button);
        }
        foreach (var match in shortcuts.Search(query)) { var target = match; var button = SearchResult(target.Label, "快捷键 / " + target.Group, delegate { search.Clear(); SelectPage("shortcuts"); shortcuts.Locate(target.Id); }); button.HorizontalContentAlignment = HorizontalAlignment.Left; button.Margin = new Thickness(0,0,0,8); results.Children.Add(button); }
        Refresh();
        if (results.Children.Count == 0) results.Children.Add(new TextBlock { Text = "没有匹配的设置", Margin = new Thickness(0, 0, 0, 16) });
    }
    void Preview(SettingsDraft.Field f)
    {
        if (saving || disconnected || !f.Previewable) return;
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
        bool enabled = AppearancePage && !disconnected && !overlayOpen && search.Text.Trim().Length == 0;
        object position = SettingsDraft.Value(latest, "preview_subtitle_position");
        string message = playerPreview.Update(this, previewArea, parent, enabled, fullPreview ? "full" : page,
            position == null ? 100 : Convert.ToDouble(position, CultureInfo.InvariantCulture));
        bool available = enabled && playerPreview.Visible;
        previewMessage.Text = message;
        previewMessage.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        DisplayAvailability(available);
    }
    void Reset() { if (saving || shortcuts.Saving) return; if (page == "shortcuts") { shortcuts.Reset(); return; } model.Reset(page); SyncInputs(); foreach (var f in model.Fields.Values.Where(x => x.Page == page && x.Previewable)) Preview(f); Refresh(); }
    void Revert() { if (saving || shortcuts.Saving) return; if (page == "shortcuts") { shortcuts.Revert(); return; } Action("cancel", page); model.Revert(page, latest); localError = ""; SyncInputs(); Refresh(); }
    void Save()
    {
        if (!save.IsEnabled) return;
        if (page == "shortcuts") { shortcuts.Save(); return; }
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
            else if (item.Value is ComboBox) SelectChoice((ComboBox)item.Value, model.Fields[item.Key]);
            else if (item.Value is Slider) SetSlider((Slider)item.Value, model.Fields[item.Key]);
            else if (item.Value is CheckBox) ((CheckBox)item.Value).IsChecked = model.Fields[item.Key].Text == "true";
            else if (item.Key == "sub-font") ((Button)item.Value).Content = FontLabel(model.Fields[item.Key].Text);
            else if (languageLists.ContainsKey(item.Key)) RefreshLanguages(model.Fields[item.Key]);
            item.Value.ToolTip = FieldDetails(model.Fields[item.Key]);
        }
        syncing = false; UpdateSubtitleExample();
    }
    void Refresh()
    {
        foreach (var item in categories) { item.Value.Content = NavigationContent(item.Key, item.Key == "shortcuts" ? shortcuts.Dirty : model.Dirty(item.Key)); item.Value.BorderBrush = item.Key == page && search.Text.Trim().Length == 0 ? Brush("#1287bb") : Brushes.Transparent; item.Value.Background = item.Key == page && search.Text.Trim().Length == 0 ? Brush("#242424") : Brushes.Transparent; item.Value.Foreground = Brush(item.Key == page ? "#F2F2F2" : "#ABABAB"); }
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
        string actionError = SettingsDraft.Str(latest, "action_error"); if (actionError.Length > 0) noticeText += "\n" + actionError;
        foreach (var f in model.Fields.Values.Where(f => f.Page == page && f.Kind == "string" && f.Page != "paths" && f.Dirty)) {
            object value; if (!model.TryValue(f, out value)) noticeText += "\n" + f.Label + "：最多 512 字节，不能包含控制字符。";
        }
        notice.Text = noticeText.Trim();
        notice.Visibility = notice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        bool valid = model.Fields.Values.Where(f => f.Page == page).All(f => { object v; return model.TryValue(f, out v); });
        save.IsEnabled = !saving && !disconnected && model.Dirty(page) && !stale && error.Length == 0 && valid;
        undo.IsEnabled = !saving && !disconnected && (model.Dirty(page) || stale || model.Fields.Values.Any(f => f.Page == page && (f.Status == "preview" || f.CanCancel)));
        reset.IsEnabled = !saving && !disconnected && model.Fields.Values.Any(f => f.Page == page) && error.Length == 0; reset.Visibility = page == "advanced" || page == "shortcuts" ? Visibility.Collapsed : Visibility.Visible;
        if (page == "shortcuts") { notice.Text = disconnected ? localError : shortcuts.Notice; notice.Visibility = notice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed; save.IsEnabled = !saving && !disconnected && shortcuts.CanSave; undo.IsEnabled = !saving && !disconnected && !shortcuts.Saving; reset.Visibility = Visibility.Visible; reset.IsEnabled = !saving && !disconnected && !shortcuts.Saving; }
        else if (shortcuts.Saving) { save.IsEnabled = undo.IsEnabled = reset.IsEnabled = false; }
        footerPanel.Visibility = search.Text.Trim().Length > 0 || page == "advanced" ? Visibility.Collapsed : Visibility.Visible;
        content.IsEnabled = !saving && !shortcuts.Saving; shortcuts.IsEnabled = !saving && !disconnected;
    }
    static string DisplayField(SettingsDraft.Field field, object value)
    {
        if (field.Page != "paths") {
            double number;
            if (Double.TryParse(SettingsDraft.Text(value), NumberStyles.Float, CultureInfo.InvariantCulture, out number))
                return (number * field.DisplayScale).ToString("0.##", CultureInfo.InvariantCulture) + ((field.Display == "percent" || field.Display == "position") ? "%" : field.Display == "seconds" ? " 秒" : "");
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
            shortcuts.Tick();
            if (disconnected) return;
            UpdatePlayerPreview();
            int count = 0;
            while (read != null && read.IsCompleted && count++ < 64)
            {
                if (read.IsFaulted || read.Result == null) { Disconnect(); return; }
                var message = UserPreferencesStorage.Object(json.DeserializeObject(read.Result));
                string eventName = SettingsDraft.Str(message, "event"); object data = SettingsDraft.Value(message, "data");
                if (eventName == "property-change" && SettingsDraft.Str(message, "name") == "user-data/mpvnet/settings" && data is Dictionary<string, object>) State((Dictionary<string, object>)data);
                else if (eventName == "property-change" && SettingsDraft.Str(message, "name") == "user-data/mpvnet/shortcuts" && data is Dictionary<string, object>) { shortcuts.Adopt((Dictionary<string,object>)data); if (search.Text.Trim().Length > 0) Search(); }
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
    string[] DirtyPages() { return model.DirtyPages().Concat(shortcuts.Dirty ? new[]{"shortcuts"} : new string[0]).Distinct().ToArray(); }
    void OnClosing(object sender, CancelEventArgs e)
    {
        if (!forceClose && (saving || shortcuts.Saving)) { e.Cancel = true; return; }
        if (!forceClose && !validation && DirtyPages().Length > 0) { e.Cancel = true; if (!overlayOpen) Confirm("放弃未保存的修改？", "以下分类的修改尚未保存：\n" + String.Join("、", DirtyPages().Select(SettingsDraft.PageName)), delegate { forceClose = true; Close(); }); return; }
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
    public void RenderValidation(string path)
    {
        if (!validation || !noShow) throw new InvalidOperationException("仅离屏验证可生成图片。");
        string absolute = Path.GetFullPath(path), tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!absolute.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) || Path.GetExtension(absolute).ToLowerInvariant() != ".png") throw new InvalidDataException("离屏图片必须位于临时夹具目录。");
        var visual = LayoutForValidation();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth), (int)Math.Ceiling(visual.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(visual);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using (var output = new FileStream(absolute, FileMode.CreateNew, FileAccess.Write)) encoder.Save(output);
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
            else if (op == "choose") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); if (editors[id] is ComboBox) ((ComboBox)editors[id]).SelectedIndex = Convert.ToInt32(step["index"]); else ((CheckBox)editors[id]).IsChecked = Convert.ToInt32(step["index"]) == 1; }
            else if (op == "inherit") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); Inherit(model.Fields[id]); }
            else if (op == "action") { string id = SettingsDraft.Str(step, "id"); actionButtons[id].RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); }
            else if (op == "locate") { int index = Convert.ToInt32(step["index"]); results.Children.OfType<Button>().ElementAt(index).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); }
            else if (op == "full-preview") TogglePreviewMode();
            else if (op == "search") search.Text = SettingsDraft.Str(step, "text");
            else if (op == "shortcuts-state") shortcuts.Adopt(UserPreferencesStorage.Object(step["state"]));
            else if (op == "font-picker") FontPicker(model.Fields["sub-font"]);
            else if (op == "picker-query") VisualChildren<TextBox>(overlay).Single().Text = SettingsDraft.Str(step,"text");
            else if (op == "invoke-control") {
                LayoutForValidation(); string name = SettingsDraft.Str(step,"name");
                VisualChildren<Button>(rootPanel).First(b => System.Windows.Automation.AutomationProperties.GetName(b) == name).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            }
            else if (op == "close-overlay") CloseOverlay();
            else if (op == "state") State(UserPreferencesStorage.Object(step["state"]));
            else if (op == "save") Save(); else if (op == "reset") Reset(); else if (op == "undo") Revert();
            else if (op == "disconnect") Disconnect();
            else if (op == "display-available") DisplayAvailability(SettingsDraft.Flag(step, "value"));
            else if (op == "preview") Preview(model.Fields[SettingsDraft.Str(step, "id")]);
        }
        // NoShow deliberately has no native Window presentation source; measure
        // its actual content tree rather than assume Window is a visual ancestor.
        var layoutRoot = LayoutForValidation();
        search.ApplyTemplate(); var searchViewport = search.Template.FindName("PART_ContentHost", search) as FrameworkElement;
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
        string renderPath = SettingsDraft.Str(request, "validation_render_path");
        if (renderPath.Length > 0) RenderValidation(renderPath);
        return new { ok = true, shown = IsVisible, page = page, pages = SettingsDraft.Pages,
            search_viewport_height = searchViewport.ActualHeight, overlay_open = overlayOpen,
            body_enabled = bodyPanel.IsEnabled, subtitle_sample = subtitleSample == null ? "" : subtitleSample.Text,
            ordinary_content_visible = previewLayout.Visibility == Visibility.Visible,
            embedded_shortcuts_visible = shortcuts.Visibility == Visibility.Visible,
            picker_items = overlayOpen ? VisualChildren<Button>(overlay).Select(b => System.Windows.Automation.AutomationProperties.GetName(b)).Where(n => n.Length > 0).ToArray() : new string[0],
            action_ids = actionButtons.Keys.ToArray(),
            row_alignment = settingRows.Values.All(r => {
                var control = (FrameworkElement)r.Children[1]; var bounds = control.TransformToAncestor(r).TransformBounds(new Rect(control.RenderSize));
                return Math.Abs(bounds.Left - (page == "paths" ? 154 : 136)) < 1 && bounds.Width >= 100 && bounds.Right <= r.ActualWidth + 1;
            }), dirty_pages = DirtyPages(),
            drafts = model.Fields.ToDictionary(x => x.Key, x => new { text = x.Value.Text, overridden = x.Value.Override }),
            revisions = model.Revisions, can_save = save.IsEnabled, saving = saving, notice = notice.Text,
            preview_visible = subtitleExample != null || previewPane.Visibility == Visibility.Visible, display_requested = displayRequested,
            full_preview = fullPreview, scale_labels = scaleValues.ToDictionary(x => x.Key, x => x.Value.Text),
            editor_types = editors.ToDictionary(x => x.Key, x => x.Value.GetType().Name),
            field_details = editors.ToDictionary(x => x.Key, x => (string)x.Value.ToolTip),
            valid_fields = model.Fields.ToDictionary(x => x.Key, x => { object value; return model.TryValue(x.Value, out value); }),
            slider_hits = hits,
            layout_valid = saveBounds.Bottom <= layoutRoot.ActualHeight && saveBounds.Right <= layoutRoot.ActualWidth &&
                (!AppearancePage || previewBounds.Bottom < saveBounds.Top && previewBounds.Right <= layoutRoot.ActualWidth),
            preview_column = Grid.GetColumn(previewPane),
            preview_fit = SettingsPreview.Fit(new Rect(0, 0, 600, 300), 1920, 1080).ToString(CultureInfo.InvariantCulture),
            search_results = results.Children.OfType<Button>().Select(b => (string)(b.Tag ?? b.Content)).ToArray(), sent = sent };
    }
}
