using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;

// One immutable media snapshot. The launcher owns the parent Process and files.
public sealed class MediaInfoView : Window, IDisposable
{
    readonly Process parent;
    readonly bool noShow;
    readonly string activationPath, rawReport, kind, mediaError;
    readonly Dictionary<string, string> overview = new Dictionary<string, string>();
    readonly List<ReportLine> lines = new List<ReportLine>();
    readonly List<int> visibleLines = new List<int>();
    readonly List<int> highlightedLines = new List<int>();
    readonly List<string> segmentValues = new List<string>();
    readonly Dictionary<TextBox, int[]> priorSelections = new Dictionary<TextBox, int[]>();
    readonly Grid root, pages, detailPage;
    readonly StackPanel overviewContent, reportContent;
    readonly ScrollViewer overviewScroll, reportScroll;
    readonly Button overviewTab, detailTab, copy, confirm;
    readonly TextBox search;
    readonly TextBlock matchCount, feedback, reportNotice;
    readonly FrameworkElement searchRow;
    DispatcherTimer timer;
    IntPtr playerOwner;
    bool running, closed, disposed, reportBuilt;
    string page = "overview", overviewText = "", overviewCopy = "";
    public long LastSeenSerial { get; private set; }

    sealed class ReportLine {
        public int Index; public string Type, Raw, Key, Value;
        public Border View; public readonly List<TextBox> Boxes = new List<TextBox>();
    }
    sealed class ReadingTextBox : TextBox
    {
        string findQuery = "";
        public string FindQuery { set { findQuery = value; InvalidateVisual(); } }
        public void RefreshSearch() { if (findQuery.Length > 0) InvalidateVisual(); }
        public ReadingTextBox() { SizeChanged += delegate { RefreshSearch(); }; }
        protected override void OnRender(DrawingContext drawing)
        {
            base.OnRender(drawing);
            if (findQuery.Length == 0) return;
            Rect visible = new Rect(RenderSize);
            for (DependencyObject ancestor = VisualTreeHelper.GetParent(this); ancestor != null; ancestor = VisualTreeHelper.GetParent(ancestor)) {
                var scroll = ancestor as ScrollViewer;
                if (scroll != null) {
                    visible.Intersect(new Rect(scroll.TranslatePoint(new Point(),this),new Size(scroll.ActualWidth,scroll.ActualHeight)));
                    break;
                }
            }
            if (visible.IsEmpty) return;
            int next = 0, match;
            // Native WPF selection adorners may be absent on an inactive or
            // unshown window. Draw the same search cue behind its text while
            // retaining the real TextBox's selection and clipboard behavior.
            while ((match = Text.IndexOf(findQuery,next,StringComparison.OrdinalIgnoreCase)) >= 0) {
                for (int i = match; i < match + findQuery.Length; i++) {
                    Rect first = GetRectFromCharacterIndex(i,false), last = GetRectFromCharacterIndex(i,true);
                    if (!first.IsEmpty && !last.IsEmpty && first.Height > 0) {
                        var mark = new Rect(first.X,first.Y,Math.Max(2,last.X-first.X),first.Height);
                        if (visible.IntersectsWith(mark)) drawing.DrawRectangle(Tone("#174354"),null,mark);
                    }
                }
                next = match + findQuery.Length;
            }
        }
    }
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo {
        public int Size; public NativeRect Monitor, Work; public uint Flags;
    }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    static Brush Tone(string value) { return (Brush)new BrushConverter().ConvertFromString(value); }
    static string Input(IDictionary<string, object> data, string key) {
        object value; return data.TryGetValue(key, out value) && value is string ? (string)value : "";
    }
    string Fact(string key) { string value; return overview.TryGetValue(key, out value) ? value : ""; }

    public MediaInfoView(IDictionary<string, object> request, IDictionary<string, object> media, Process parent, bool noShow)
    {
        if (request == null || media == null || parent == null) throw new ArgumentNullException("媒体窗口请求");
        object schema, pid;
        string token = Input(request, "token");
        if (!request.TryGetValue("schema", out schema) || !(schema is int) || (int)schema != 1 ||
            !request.TryGetValue("parent_pid", out pid) || !(pid is int) || (int)pid != parent.Id ||
            token.Length == 0 || token.Length > 256 || Regex.IsMatch(token, @"\p{Cc}"))
            throw new ArgumentException("媒体信息窗口请求无效。");
        activationPath = Input(request, "activation_path");
        if (activationPath.Length == 0 || !Path.IsPathRooted(activationPath)) throw new ArgumentException("媒体信息唤回路径无效。");
        this.parent = parent; this.noShow = noShow;
        rawReport = Input(media, "report"); kind = Input(media, "kind"); mediaError = Input(media, "error");
        if (kind != "local" && kind != "network" && kind != "audio" && kind != "empty")
            throw new ArgumentException("媒体信息类型无效。");
        object values;
        if (media.TryGetValue("overview", out values) && values is IDictionary) {
            foreach (DictionaryEntry item in (IDictionary)values)
                if (item.Key is string && item.Value is string) overview[(string)item.Key] = (string)item.Value;
        }
        ParseReport();
        Title = "媒体信息"; Width = 740; Height = 620; MinWidth = 360; MinHeight = 300;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize;
        ShowInTaskbar = false; Topmost = false; WindowStartupLocation = WindowStartupLocation.Manual;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14;
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        Foreground = Tone("#E5E5E5"); Background = Tone("#151515");
        ReadingStyles();
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 36,
            ResizeBorderThickness = new Thickness(5), GlassFrameThickness = new Thickness(0), UseAeroCaptionButtons = false });
        root = new Grid { Background = Background };
        foreach (double height in new double[] { 36, -1, 44, 0, -1 })
            root.RowDefinitions.Add(new RowDefinition { Height = height < 0 ? GridLength.Auto : height == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(height) });
        var caption = new DockPanel { Background = Tone("#1C1C1C") };
        var close = Button("\uE8BB", "关闭媒体信息", Close, false, true);
        close.FontFamily = new FontFamily("Segoe MDL2 Assets"); close.FontSize = 10; close.Width = 44; close.Height = 36;
        WindowChrome.SetIsHitTestVisibleInChrome(close, true); DockPanel.SetDock(close, Dock.Right); caption.Children.Add(close);
        caption.Children.Add(new TextBlock { Text = "媒体信息", FontSize = 12, Foreground = Tone("#BBBBBB"), Margin = new Thickness(16,0,0,0), VerticalAlignment = VerticalAlignment.Center });
        root.Children.Add(caption);
        var identity = new StackPanel { Margin = new Thickness(28,20,28,14) };
        string title = Input(media, "title");
        if (String.IsNullOrWhiteSpace(title)) title = kind == "empty" ? "尚未打开媒体" : "未命名媒体";
        var titleBox = Selectable(title, 19, "#F2F2F2"); titleBox.FontWeight = FontWeights.SemiBold;
        titleBox.MaxHeight = 64; titleBox.VerticalScrollBarVisibility = ScrollBarVisibility.Auto; identity.Children.Add(titleBox);
        var metadata = new List<string>();
        if (kind == "network") metadata.Add("网络媒体");
        foreach (string key in new[] { "container", "duration", "size" }) if (!String.IsNullOrWhiteSpace(Fact(key))) metadata.Add(Fact(key));
        identity.Children.Add(Segments(metadata.ToArray(), 12, "#AAAAAA"));
        Grid.SetRow(identity, 1); root.Children.Add(identity);
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(28,0,28,0) };
        overviewTab = TabButton("概览", "overview");
        detailTab = TabButton("详情", "details");
        overviewTab.Margin = new Thickness(0,0,8,0);
        tabs.Children.Add(overviewTab); tabs.Children.Add(detailTab);
        var tabRegion = new Border { Child = tabs, BorderBrush = Tone("#303030"), BorderThickness = new Thickness(0,0,0,1) };
        Grid.SetRow(tabRegion, 2); root.Children.Add(tabRegion);
        pages = new Grid { Margin = new Thickness(28,20,28,22) };
        overviewContent = new StackPanel(); BuildOverview();
        overviewCopy = title + "\n" + String.Join(" | ", metadata.ToArray()) + "\n" + overviewText;
        overviewScroll = Scroll(overviewContent); pages.Children.Add(overviewScroll);
        detailPage = new Grid(); detailPage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detailPage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detailPage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var find = new Grid { Margin = new Thickness(0,0,0,14) };
        find.ColumnDefinitions.Add(new ColumnDefinition()); find.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var field = new Grid();
        search = new TextBox { Padding = new Thickness(34,8,10,8), BorderThickness = new Thickness(1), BorderBrush = Tone("#444444"),
            Background = Tone("#202020"), Foreground = Tone("#E5E5E5"), CaretBrush = Tone("#E5E5E5"), FontSize = 13,
            Height = 36, VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(search, "DetailsSearch"); AutomationProperties.SetName(search, "查找详情"); field.Children.Add(search);
        var placeholder = new TextBlock { Text = "查找详情", Foreground = Tone("#999999"), Margin = new Thickness(35,0,10,0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        field.Children.Add(placeholder);
        var magnifier = new System.Windows.Shapes.Path { Data = Geometry.Parse("M 10.5,4 A 6.5,6.5 0 1 0 10.5,17 A 6.5,6.5 0 1 0 10.5,4 M 15.5,15.5 L 21,21"),
            Width = 18, Height = 18, Stretch = Stretch.Uniform, Stroke = Tone("#999999"), StrokeThickness = 1.6,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(11,0,0,0), IsHitTestVisible = false };
        field.Children.Add(magnifier); find.Children.Add(field);
        matchCount = new TextBlock { Foreground = Tone("#999999"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10,0,0,0) };
        Grid.SetColumn(matchCount, 1); find.Children.Add(matchCount); searchRow = find; detailPage.Children.Add(find);
        reportNotice = new TextBlock { Foreground = Tone("#AAAAAA"), FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,0,0,12) };
        Grid.SetRow(reportNotice, 1); detailPage.Children.Add(reportNotice);
        reportContent = new StackPanel(); reportScroll = Scroll(reportContent); Grid.SetRow(reportScroll, 2); detailPage.Children.Add(reportScroll);
        reportScroll.ScrollChanged += delegate {
            foreach (ReportLine line in lines) foreach (TextBox box in line.Boxes) ((ReadingTextBox)box).RefreshSearch();
        };
        pages.Children.Add(detailPage); Grid.SetRow(pages, 3); root.Children.Add(pages);
        var footer = new Grid { Margin = new Thickness(28,12,28,14) };
        footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        feedback = new TextBlock { FontSize = 12, Foreground = Tone("#AAAAAA"), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap }; footer.Children.Add(feedback);
        copy = Button("复制信息", "复制当前页媒体信息", CopyReport, false, false); copy.Padding = new Thickness(12,6,12,6); copy.Margin = new Thickness(8,0,10,0);
        Grid.SetColumn(copy, 1); footer.Children.Add(copy);
        confirm = Button("确认", "确认", Close, true, false); confirm.MinWidth = 88; confirm.Height = 34; confirm.IsDefault = true; confirm.Padding = new Thickness(16,0,16,0);
        Grid.SetColumn(confirm, 2); footer.Children.Add(confirm);
        var footerRegion = new Border { Child = footer, BorderBrush = Tone("#292929"), BorderThickness = new Thickness(0,1,0,0) };
        Grid.SetRow(footerRegion, 4); root.Children.Add(footerRegion); Content = root;
        Action updatePlaceholder = delegate { placeholder.Visibility = search.Text.Length == 0 && !search.IsKeyboardFocusWithin ? Visibility.Visible : Visibility.Collapsed; };
        search.TextChanged += delegate { updatePlaceholder(); RenderReport(); };
        search.IsKeyboardFocusWithinChanged += delegate { updatePlaceholder(); };
        overviewTab.PreviewKeyDown += TabKey; detailTab.PreviewKeyDown += TabKey;
        PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
            if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { SelectPage("details"); search.Focus(); search.SelectAll(); e.Handled = true; }
            else if (e.Key == Key.Escape) { e.Handled = true; if (page == "details" && search.Text.Length > 0) search.Clear(); else Close(); }
        };
        SourceInitialized += delegate { AttachOwner(); PositionWindow(); };
        Loaded += delegate {
            if (noShow || !running || disposed || closed) return;
            PositionWindow(); timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            timer.Tick += TimerTick; Tick(); if (!closed && !disposed && timer != null) timer.Start();
        };
        Closed += delegate { closed = true; StopTimer(); };
        RenderReport(); SelectPage("overview");
    }

    void ReadingStyles()
    {
        Resources = (ResourceDictionary)XamlReader.Parse(@"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
<Style TargetType='TextBox'><Setter Property='FocusVisualStyle' Value='{x:Null}'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='TextBox'><Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='3'><ScrollViewer x:Name='PART_ContentHost'/></Border></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property='IsKeyboardFocused' Value='True'><Setter Property='BorderBrush' Value='#1287BB'/></Trigger></Style.Triggers></Style>
<Style TargetType='ScrollBar'><Setter Property='Width' Value='10'/><Setter Property='Background' Value='#151515'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Track x:Name='PART_Track' IsDirectionReversed='True' Orientation='Vertical' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' ViewportSize='{TemplateBinding ViewportSize}'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageUpCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType='Thumb'><Border Background='#555555' CornerRadius='3' Width='6' HorizontalAlignment='Center'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageDownCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
</ResourceDictionary>");
    }
    Button TabButton(string text, string target)
    {
        var template = (ControlTemplate)XamlReader.Parse(@"<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='Button'>
<Grid Background='Transparent'><Border x:Name='surface' Background='Transparent' Margin='0,3,0,5' CornerRadius='3'/><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' Margin='14,0,14,2'/><Border x:Name='indicator' Background='Transparent' Height='2' Width='24' VerticalAlignment='Bottom' HorizontalAlignment='Center'/></Grid>
<ControlTemplate.Triggers>
<Trigger Property='IsMouseOver' Value='True'><Setter TargetName='surface' Property='Background' Value='#222222'/><Setter Property='Foreground' Value='#EEEEEE'/></Trigger>
<Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='surface' Property='Background' Value='#242424'/><Setter Property='Foreground' Value='#F2F2F2'/></Trigger>
<Trigger Property='IsPressed' Value='True'><Setter TargetName='surface' Property='Background' Value='#303030'/></Trigger>
<Trigger Property='Tag' Value='selected'><Setter TargetName='indicator' Property='Background' Value='#1287BB'/></Trigger>
</ControlTemplate.Triggers></ControlTemplate>");
        var tab = new Button { Content = text, MinWidth = 72, Height = 43, Template = template,
            FocusVisualStyle = null, BorderThickness = new Thickness(0), Background = Brushes.Transparent };
        AutomationProperties.SetName(tab, text);
        tab.Click += delegate { SelectPage(target); };
        return tab;
    }
    Button Button(string text, string name, Action action, bool primary, bool caption)
    {
        var factory = new FrameworkElementFactory(typeof(Border)); factory.Name = "frame";
        factory.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        factory.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        factory.SetBinding(Border.BorderThicknessProperty, new System.Windows.Data.Binding("BorderThickness") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        factory.SetBinding(Border.PaddingProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        factory.SetValue(Border.CornerRadiusProperty, new CornerRadius(caption ? 0 : 3));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center); presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center); factory.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = factory };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Tone(caption ? "#8F2633" : primary ? "#1287BB" : "#292929"), "frame")); template.Triggers.Add(hover);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, Tone(primary ? "#E5E5E5" : "#1287BB"), "frame"));
        focus.Setters.Add(new Setter(Border.BorderThicknessProperty, new Thickness(1), "frame")); template.Triggers.Add(focus);
        var disabled = new Trigger { Property = IsEnabledProperty, Value = false }; disabled.Setters.Add(new Setter(OpacityProperty, 0.45)); template.Triggers.Add(disabled);
        var button = new Button { Content = text, Template = template, Background = primary ? Tone("#1287BB") : Brushes.Transparent,
            Foreground = Tone(primary ? "#FFFFFF" : "#AAAAAA"), BorderBrush = Brushes.Transparent, BorderThickness = new Thickness(0), FocusVisualStyle = null };
        AutomationProperties.SetName(button, name); button.Click += delegate { action(); }; return button;
    }
    TextBox Selectable(string text, double size, string tone)
    {
        return new ReadingTextBox { Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true,
            BorderThickness = new Thickness(0), Padding = new Thickness(0), Background = Brushes.Transparent, Foreground = Tone(tone), FontSize = size,
            SelectionBrush = Tone("#1287BB"), IsInactiveSelectionHighlightEnabled = true,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
    static ScrollViewer Scroll(object content) { return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, CanContentScroll = false }; }
    FrameworkElement Segments(string[] values, double size, string tone)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0,3,0,0) }; bool first = true;
        foreach (string value in values) {
            if (String.IsNullOrWhiteSpace(value)) continue;
            foreach (string segment in Regex.Split(value, @"\s*·\s*")) {
                if (!first) wrap.Children.Add(new Border { Width = 1, Height = 12, Background = Tone("#666666"), Margin = new Thickness(12,3,12,0), VerticalAlignment = VerticalAlignment.Center });
                wrap.Children.Add(Selectable(segment, size, tone)); segmentValues.Add(segment); first = false;
            }
        }
        return wrap;
    }
    void BuildOverview()
    {
        if (kind == "empty") { overviewContent.Children.Add(Empty("没有可显示的信息", "打开视频或音频后再查看。")); overviewText = "没有可显示的信息\n打开视频或音频后再查看。"; return; }
        bool video = false;
        foreach (string key in new[] { "resolution", "fps", "aspect", "video_codec", "bit_depth", "dynamic_range", "total_bitrate" }) video |= !String.IsNullOrWhiteSpace(Fact(key));
        if (kind != "audio" && video) {
            overviewContent.Children.Add(Heading("视频")); FactRow("画面", new[] { Fact("resolution"), Fact("fps"), Fact("aspect") });
            FactRow("编码", new[] { Fact("video_codec"), Fact("bit_depth"), Fact("dynamic_range") });
            if (Fact("total_bitrate").Length > 0) FactRow("总码率", new[] { Fact("total_bitrate") });
            overviewContent.Children.Add(new Border { Height = 1, Background = Tone("#292929"), Margin = new Thickness(0,20,0,20) });
        }
        overviewContent.Children.Add(Heading(kind == "audio" ? "音频" : "音轨与字幕")); FactRow("音频", new[] { Fact("audio") });
        if (kind != "audio") FactRow("字幕", new[] { Fact("subtitle") });
        if (kind == "network" || mediaError == "网络媒体未取得完整文件报告。") { overviewContent.Children.Add(new TextBlock { Text = "网络媒体仅显示当前可取得的信息。", Foreground = Tone("#999999"), FontSize = 12, Margin = new Thickness(0,18,0,0), TextWrapping = TextWrapping.Wrap }); overviewText += "网络媒体仅显示当前可取得的信息。\n"; }
    }
    TextBlock Heading(string text) { return new TextBlock { Text = text, FontSize = 13, Foreground = Tone("#DDDDDD"), Margin = new Thickness(0,0,0,10) }; }
    void FactRow(string label, string[] values)
    {
        var actual = new List<string>(); foreach (string value in values) if (!String.IsNullOrWhiteSpace(value)) actual.Add(value);
        if (actual.Count == 0) actual.Add("未能取得");
        var row = new Grid { Margin = new Thickness(0,0,0,9) }; row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(92) }); row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(new TextBlock { Text = label, Foreground = Tone("#999999"), Margin = new Thickness(0,3,0,0) });
        var segments = Segments(actual.ToArray(), 14, "#E5E5E5"); Grid.SetColumn(segments, 1); row.Children.Add(segments); overviewContent.Children.Add(row);
        overviewText += label + "：" + String.Join(" | ", actual.ToArray()) + "\n";
    }
    FrameworkElement Empty(string title, string explanation)
    {
        var panel = new StackPanel { Margin = new Thickness(8,54,8,20), HorizontalAlignment = HorizontalAlignment.Stretch };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 16, TextAlignment = TextAlignment.Center, Foreground = Tone("#DDDDDD") });
        panel.Children.Add(new TextBlock { Text = explanation, FontSize = 13, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = Tone("#AAAAAA"), Margin = new Thickness(0,8,0,0) }); return panel;
    }
    void ParseReport()
    {
        if (rawReport.Length == 0) return;
        string[] source = Regex.Split(rawReport, "\r\n|\n|\r");
        for (int i = 0; i < source.Length; i++) {
            string raw = source[i], type = "raw", key = "", value = "";
            Match field = Regex.Match(raw, @"^(.+?)(?:\s+:\s*|:\s+|：\s*)(.*)$");
            if (String.IsNullOrWhiteSpace(raw)) type = "blank";
            else if (field.Success) { type = "field"; key = field.Groups[1].Value.Trim(); value = field.Groups[2].Value; }
            else if (Regex.IsMatch(raw.Trim(), @"^(General|Video|Audio|Text|Menu|Image|Other|常规|视频|音频|字幕|菜单|其他)(?:\s*#?\d+)?$", RegexOptions.IgnoreCase)) type = "group";
            lines.Add(new ReportLine { Index = i, Raw = raw, Type = type, Key = key, Value = value });
        }
    }
    void RenderReport()
    {
        if (reportContent == null) return;
        if (!reportBuilt) BuildReport();
        string query = search.Text.Trim(); int matches = 0; Border firstMatch = null;
        highlightedLines.Clear();
        foreach (ReportLine line in lines) {
            line.View.Background = Brushes.Transparent;
            bool boxHighlighted = false;
            foreach (TextBox box in line.Boxes) {
                ((ReadingTextBox)box).FindQuery = query;
                if (query.Length > 0 && !priorSelections.ContainsKey(box)) priorSelections[box] = new[] { box.SelectionStart, box.SelectionLength };
                int at = query.Length == 0 ? -1 : box.Text.IndexOf(query, StringComparison.OrdinalIgnoreCase);
                if (at >= 0) { box.SelectionBrush = Tone("#174354"); box.Select(at, query.Length); boxHighlighted = true; }
                else if (priorSelections.ContainsKey(box)) { int[] previous = priorSelections[box]; box.Select(previous[0], previous[1]); box.SelectionBrush = Tone("#1287BB"); }
            }
            if (query.Length == 0) continue;
            int position = 0, match;
            while ((match = line.Raw.IndexOf(query, position, StringComparison.OrdinalIgnoreCase)) >= 0) { matches++; position = match + query.Length; }
            if (line.Raw.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0) {
                highlightedLines.Add(line.Index); if (firstMatch == null) firstMatch = line.View;
                // Group headings and matches spanning the original delimiter
                // retain their full row, with a background cue instead.
                if (!boxHighlighted) line.View.Background = Tone("#174354");
            }
        }
        if (query.Length == 0) { priorSelections.Clear(); reportScroll.ScrollToTop(); }
        else if (firstMatch != null) firstMatch.BringIntoView();
        matchCount.Text = query.Length == 0 ? "" : matches.ToString(CultureInfo.InvariantCulture) + " 处";
    }
    void BuildReport()
    {
        reportBuilt = true; reportContent.Children.Clear(); visibleLines.Clear();
        foreach (ReportLine line in lines) {
            visibleLines.Add(line.Index); FrameworkElement content;
            if (line.Type == "blank") content = new Border { Height = 8 };
            else if (line.Type == "group") {
                var heading = Heading(line.Raw); heading.Margin = new Thickness(0,visibleLines.Count == 1 ? 0 : 16,0,8);
                content = new Border { Child = heading, BorderBrush = Tone("#303030"), BorderThickness = new Thickness(0,visibleLines.Count == 1 ? 0 : 1,0,0), Padding = new Thickness(0,visibleLines.Count == 1 ? 0 : 4,0,0) };
            } else if (line.Type == "field") {
                var row = new Grid { Margin = new Thickness(0,3,0,3) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.38, GridUnitType.Star), MinWidth = 94 });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.62, GridUnitType.Star) });
                var key = Selectable(line.Key, 12, "#AAAAAA"); var value = Selectable(line.Value, 12, "#E5E5E5");
                line.Boxes.Add(key); line.Boxes.Add(value); row.Children.Add(key);
                value.Margin = new Thickness(20,0,0,0); Grid.SetColumn(value, 1); row.Children.Add(value); content = row;
            } else { var text = Selectable(line.Raw, 12, "#AAAAAA"); line.Boxes.Add(text); content = text; }
            line.View = new Border { Child = content }; reportContent.Children.Add(line.View);
        }
        bool networkUnavailable = rawReport.Length == 0 && ((kind == "network" && mediaError.Length == 0) || mediaError == "网络媒体未取得完整文件报告。");
        if (rawReport.Length == 0) {
            string title = kind == "empty" ? "没有可显示的信息" : networkUnavailable ? "未取得完整文件报告" : "未能读取完整详情";
            string explanation = kind == "empty" ? "打开媒体后再查看。" : networkUnavailable ? "网络媒体仅显示当前可取得的信息；文件大小与封装写入信息未能取得。" : "当前可取得的信息仍在概览中。";
            reportContent.Children.Add(Empty(title, explanation));
        }
        reportNotice.Text = mediaError.Length > 0 && !networkUnavailable ? "详情读取失败：" + mediaError : "";
        reportNotice.Visibility = reportNotice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        searchRow.Visibility = rawReport.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    void SelectPage(string target)
    {
        if (target != "overview" && target != "details") return; page = target;
        copy.IsEnabled = CopySource().Length > 0;
        overviewScroll.Visibility = page == "overview" ? Visibility.Visible : Visibility.Collapsed;
        detailPage.Visibility = page == "details" ? Visibility.Visible : Visibility.Collapsed;
        foreach (Button tab in new[] { overviewTab, detailTab }) {
            bool selected = tab == (page == "overview" ? overviewTab : detailTab);
            tab.Tag = selected ? "selected" : "";
            tab.Foreground = Tone(selected ? "#EEEEEE" : "#AAAAAA");
        }
    }
    void TabKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Left && e.Key != Key.Right) return;
        SelectPage(page == "overview" ? "details" : "overview"); (page == "overview" ? overviewTab : detailTab).Focus(); e.Handled = true;
    }
    void CopyReport()
    {
        string source = CopySource(); if (source.Length == 0) return;
        if (noShow) { feedback.Text = "验证模式未写入剪贴板。"; return; }
        try { Clipboard.SetText(source); feedback.Text = page == "overview" ? "已复制概览。" : "已复制原始详情。"; }
        catch (ExternalException) { feedback.Text = "未能复制，请重试。"; }
    }
    string CopySource() { return kind == "empty" ? "" : page == "overview" ? overviewCopy : rawReport; }

    bool ParentAlive() { try { return !parent.HasExited; } catch (InvalidOperationException) { return false; } catch (Win32Exception) { return false; } }
    long ReadSerial()
    {
        try {
            using (var file = new FileStream(activationPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (file.Length == 0 || file.Length > 32) return 0; var bytes = new byte[33]; int count = file.Read(bytes,0,bytes.Length);
                if (count == 0 || count > 32) return 0;
                string text = Encoding.ASCII.GetString(bytes,0,count).Trim();
                if (!Regex.IsMatch(text, "^[0-9]+$")) return 0;
                long serial; return Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out serial) ? serial : 0;
            }
        } catch (IOException) { } catch (UnauthorizedAccessException) { } return 0;
    }
    public void Tick()
    {
        if (noShow || closed || disposed || !running) return;
        if (!ParentAlive()) { Close(); return; } AttachOwner(); long serial = ReadSerial();
        if (serial <= LastSeenSerial) return; LastSeenSerial = serial;
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate();
    }
    void AttachOwner()
    {
        if (noShow || closed || playerOwner != IntPtr.Zero || !ParentAlive()) return;
        var interop = new WindowInteropHelper(this); if (interop.Handle == IntPtr.Zero) return;
        try {
            parent.Refresh(); IntPtr candidate = parent.MainWindowHandle; uint pid;
            if (candidate == IntPtr.Zero || GetWindowThreadProcessId(candidate,out pid) == 0 || pid != (uint)parent.Id) return;
            interop.Owner = candidate; playerOwner = candidate;
        } catch (InvalidOperationException) { } catch (Win32Exception) { } catch (ArgumentException) { }
    }
    void PositionWindow()
    {
        if (noShow || closed) return;
        Rect work = SystemParameters.WorkArea, area = work;
        var source = PresentationSource.FromVisual(this) as HwndSource;
        Matrix transform = source != null && source.CompositionTarget != null ? source.CompositionTarget.TransformFromDevice : Matrix.Identity;
        if (playerOwner != IntPtr.Zero) {
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) }; NativeRect rect;
            if (GetMonitorInfo(MonitorFromWindow(playerOwner,2),ref info)) work = new Rect(transform.Transform(new Point(info.Work.Left,info.Work.Top)),transform.Transform(new Point(info.Work.Right,info.Work.Bottom)));
            area = work;
            if (GetWindowRect(playerOwner,out rect)) area = new Rect(transform.Transform(new Point(rect.Left,rect.Top)),transform.Transform(new Point(rect.Right,rect.Bottom)));
        }
        double width = Math.Min(Width, Math.Max(120,work.Width - 32)), height = Math.Min(Height, Math.Max(120,work.Height - 32));
        MinWidth = Math.Min(MinWidth,width); MinHeight = Math.Min(MinHeight,height); MaxWidth = Math.Max(120,work.Width - 32); MaxHeight = Math.Max(120,work.Height - 32);
        Width = width; Height = height;
        Left = Math.Max(work.Left + 16, Math.Min(area.Left + (area.Width-width)/2,work.Right-width-16));
        Top = Math.Max(work.Top + 16, Math.Min(area.Top + (area.Height-height)/2,work.Bottom-height-16));
    }
    public void Run()
    {
        if (disposed) throw new ObjectDisposedException("MediaInfoView");
        if (noShow || closed || running || !ParentAlive()) return;
        LastSeenSerial = Math.Max(LastSeenSerial,ReadSerial()); running = true;
        try { ShowDialog(); } finally { running = false; StopTimer(); }
    }
    void TimerTick(object sender, EventArgs e) { Tick(); }
    void StopTimer() { if (timer != null) { timer.Stop(); timer.Tick -= TimerTick; timer = null; } }
    public IDictionary<string, object> Snapshot()
    {
        double width = ActualWidth > 0 ? ActualWidth : Width, height = ActualHeight > 0 ? ActualHeight : Height;
        root.Measure(new Size(width,height)); root.Arrange(new Rect(0,0,width,height)); root.UpdateLayout();
        var parsed = new List<object>(); var visible = new List<object>();
        foreach (ReportLine line in lines) {
            var selections = new List<string>(); foreach (TextBox box in line.Boxes) if (box.SelectionLength > 0) selections.Add(box.SelectedText);
            var row = new Dictionary<string,object> { {"index",line.Index},{"type",line.Type},{"raw",line.Raw},{"key",line.Key},{"value",line.Value},{"selected_text",selections} }; parsed.Add(row);
            if (visibleLines.Contains(line.Index)) visible.Add(row);
        }
        Point confirmAt = confirm.TranslatePoint(new Point(),root), copyAt = copy.TranslatePoint(new Point(),root);
        return new Dictionary<string, object> {
            {"kind",kind},{"report",rawReport},{"parsed_rows",parsed},{"visible_rows",visible},{"overview",overview},{"overview_text",overviewText},
            {"page",page},{"query",search.Text},{"match_count",matchCount.Text},{"error",mediaError},{"notice",reportNotice.Text},
            {"copy_enabled",copy.IsEnabled},{"copy_source",CopySource()},{"segment_values",segmentValues},{"highlighted_rows",highlightedLines},
            {"report_offset",reportScroll.VerticalOffset},{"handle_created",new WindowInteropHelper(this).Handle != IntPtr.Zero},
            {"timer_created",timer != null},{"timer_running",timer != null && timer.IsEnabled},{"last_seen_serial",LastSeenSerial},
            {"closed",closed},{"shown",IsVisible},{"show_in_taskbar",ShowInTaskbar},{"topmost",Topmost},{"owner_attached",playerOwner != IntPtr.Zero},
            {"width",width},{"height",height},{"content_height",pages.ActualHeight},{"report_viewport",reportScroll.ViewportHeight},
            {"footer_fits",copyAt.X >= 0 && copyAt.X + copy.ActualWidth <= confirmAt.X && confirmAt.X + confirm.ActualWidth <= width && confirmAt.Y + confirm.ActualHeight <= height},
            {"confirm_background",confirm.Background.ToString()}
        };
    }
    public void Dispose() { if (disposed) return; disposed = true; StopTimer(); }
}
