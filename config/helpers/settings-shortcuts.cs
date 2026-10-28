using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;

public sealed class ShortcutSearchResult
{
    public string Id, Label, Group;
}

// Only presentation, capture and drafts live here. The host owns IPC/lifetime;
// user_shortcuts remains the authority for validation, persistence and apply.
public sealed class SettingsShortcutsPanel : Grid
{
    static readonly string[] Groups = { "播放与定位", "循环与标记", "字幕与弹幕", "音频", "画面", "截图与片段", "窗口与界面", "文件", "工具与设置" };
    static readonly string[] FilterIds = { "all", "bound", "unbound", "modified" };
    static readonly string[] FilterLabels = { "全部", "已绑定", "未绑定", "已修改" };
    readonly Action<object[]> send;
    readonly Action changed;
    readonly Action<string, string, Action> confirm;
    readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 64 };
    readonly List<ActionRow> rows = new List<ActionRow>(), visibleRows = new List<ActionRow>();
    readonly Dictionary<string, string[]> draft = new Dictionary<string, string[]>(StringComparer.Ordinal), baseline = new Dictionary<string, string[]>(StringComparer.Ordinal);
    readonly Dictionary<string, Button> filters = new Dictionary<string, Button>();
    Dictionary<string, string[]> submitted;
    Dictionary<string, object> latest;
    Grid body;
    TextBox search;
    ComboBox categories;
    ListBox actions;
    TextBlock count, placeholder, recordingHint;
    Border empty;
    Button clearSearch;
    string token = "", revision = "", category = "all", filter = "all", expandedId = "", captureId = "", localError = "", localNotice = "";
    int capture = -1, saveSerial = -1, pendingSerial = -1, focusRequest;
    bool saving, stale, invalid, refreshing;
    DateTime saveStarted;

    public SettingsShortcutsPanel(Action<object[]> send, Action changed, Action<string, string, Action> confirm)
    {
        if (send == null || changed == null || confirm == null) throw new ArgumentNullException("Settings shortcuts callbacks");
        this.send = send; this.changed = changed; this.confirm = confirm;
        Build();
        PreviewKeyDown += OnKey;
        PreviewGotKeyboardFocus += delegate(object sender, KeyboardFocusChangedEventArgs e) {
            if (captureId.Length > 0 && !IsCaptureTarget(e.NewFocus as DependencyObject)) { CancelCaptureCore(); localError = ""; Refresh(); }
        };
        LostKeyboardFocus += delegate(object sender, KeyboardFocusChangedEventArgs e) {
            var next = e.NewFocus as DependencyObject;
            if (captureId.Length > 0 && (next == null || !IsAncestorOf(next))) CancelCapture();
        };
        IsVisibleChanged += delegate { if (!IsVisible) CancelCapture(); };
        IsEnabledChanged += delegate { if (!IsEnabled) CancelCapture(); Refresh(); };
        SizeChanged += delegate { foreach (var row in rows) row.Notify(); };
    }

    public bool Dirty { get { return draft.Count != baseline.Count || draft.Any(p => !baseline.ContainsKey(p.Key) || !p.Value.SequenceEqual(baseline[p.Key])); } }
    public bool Saving { get { return saving; } }
    bool ReadOnly { get { return invalid || Flag(latest, "read_only") || (latest != null && Text(latest, "error").Length > 0 && !Flag(latest, "repairable")); } }
    bool Editable { get { return IsEnabled && latest != null && !saving && !stale && !ReadOnly; } }
    public bool CanSave { get { return Editable && !Flag(latest, "saving") && Dirty && Conflict().Length == 0; } }
    public string Notice { get {
        if (saving) return "正在保存并应用…";
        if (localError.Length > 0) return localError;
        if (stale) return "其他播放器已更新快捷键，草稿已保留。撤销可载入最新键位。";
        string error = latest == null ? "" : StateError(latest);
        if (error.Length > 0) return error;
        string conflict = Conflict();
        if (conflict.Length > 0) return conflict;
        return localNotice;
    } }

    static string Text(Dictionary<string, object> data, string key) { object value; return data != null && data.TryGetValue(key, out value) && value is string ? (string)value : ""; }
    static bool Flag(Dictionary<string, object> data, string key) { object value; return data != null && data.TryGetValue(key, out value) && value is bool && (bool)value; }
    static int Number(Dictionary<string, object> data, string key, int fallback) { object value; return data.TryGetValue(key, out value) && value is int ? (int)value : fallback; }
    static string[] Keys(object value)
    {
        var values = value as object[];
        if (values == null || values.Length > 2 || values.Any(x => !(x is string) || !ShortcutKeyNames.IsCanonical((string)x)))
            throw new InvalidDataException("快捷键格式无效，请重新载入。");
        return values.Cast<string>().ToArray();
    }
    static string StateError(Dictionary<string, object> state)
    {
        string error = Text(state, "error");
        return error.Length > 0 && Flag(state, "repairable") ? "配置存在冲突；当前仍使用上一组有效快捷键。修改冲突项或恢复默认后保存。" : error;
    }
    static int GroupRank(string group) { int index = Array.IndexOf(Groups, group); return index < 0 ? Groups.Length : index; }
    static string DisplayKey(string value)
    {
        if (value == "Space") return "空格";
        if (value.EndsWith("+Space", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 5) + "空格";
        return value.Replace("Left", "←").Replace("Right", "→").Replace("PGUP", "PageUp").Replace("PGDWN", "PageDown");
    }
    ActionRow Find(string id) { return rows.FirstOrDefault(x => x.Id == id); }
    bool InView(string id) { return visibleRows.Any(x => x.Id == id); }
    string Haystack(ActionRow row) { return row.Label + " " + row.Group + " 快捷键 " + String.Join(" ", row.Defaults.Concat(draft[row.Id])) + " " + String.Join(" ", row.Defaults.Concat(draft[row.Id]).Select(DisplayKey)); }
    bool Matches(ActionRow row, string query) { return query.Split((char[])null, StringSplitOptions.RemoveEmptyEntries).All(term => Haystack(row).IndexOf(term, StringComparison.OrdinalIgnoreCase) >= 0); }
    public IEnumerable<ShortcutSearchResult> Search(string query)
    {
        return rows.Where(row => Matches(row, query ?? "")).OrderBy(row => GroupRank(row.Group))
            .Select(row => new ShortcutSearchResult { Id = row.Id, Label = row.Label, Group = row.Group }).ToArray();
    }

    public sealed class ActionRow : INotifyPropertyChanged
    {
        public SettingsShortcutsPanel Owner;
        public string Id { get; set; } public string Label { get; set; } public string Group { get; set; }
        public string[] Defaults;
        string[] Keys { get { return Owner.draft[Id]; } }
        public bool Compact { get { return Owner.ActualWidth > 0 && Owner.ActualWidth < 550; } }
        public bool Modified { get { return !Keys.SequenceEqual(Defaults); } }
        public bool Expanded { get { return Owner.expandedId == Id; } }
        public bool CanEdit { get { return Owner.Editable; } }
        public bool RecordingOne { get { return Owner.captureId == Id && Owner.capture == 0; } }
        public bool RecordingTwo { get { return Owner.captureId == Id && Owner.capture == 1; } }
        public string KeyOne { get { return RecordingOne ? "请按组合键…" : Keys.Length > 0 ? DisplayKey(Keys[0]) : "添加按键"; } }
        public string KeyTwo { get { return RecordingTwo ? "请按组合键…" : Keys.Length > 1 ? DisplayKey(Keys[1]) : "添加"; } }
        public Visibility SecondVisibility { get { return Keys.Length > 0 ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility DetailVisibility { get { return Expanded ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility ModifiedVisibility { get { return Modified ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility GroupVisibility { get { return Owner.category == "all" ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility RemoveOneVisibility { get { return Keys.Length > 0 ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility RemoveTwoVisibility { get { return Keys.Length > 1 ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility NoDefaultVisibility { get { return Defaults.Length == 0 ? Visibility.Visible : Visibility.Collapsed; } }
        public string[] DefaultDisplayKeys { get { return Defaults.Select(DisplayKey).ToArray(); } }
        public string Conflict { get { return Owner.RowConflict(Id); } }
        public Visibility ConflictVisibility { get { return Conflict.Length > 0 ? Visibility.Visible : Visibility.Collapsed; } }
        public string KeyOneId { get { return "ShortcutKey_" + Id + "_0"; } }
        public string KeyTwoId { get { return "ShortcutKey_" + Id + "_1"; } }
        public string KeyOneName { get { return Label + "，按键 1，" + (Keys.Length > 0 ? DisplayKey(Keys[0]) : "未绑定"); } }
        public string KeyTwoName { get { return Label + "，按键 2，" + (Keys.Length > 1 ? DisplayKey(Keys[1]) : "添加第二个按键"); } }
        public string DetailId { get { return "ShortcutDetail_" + Id; } }
        public string DetailName { get { return (Expanded ? "收起" : "展开") + Label + "的默认键位与操作"; } }
        public string RestoreId { get { return "ShortcutRestore_" + Id; } }
        public string ConflictId { get { return "ShortcutConflict_" + Id; } }
        public string RemoveOneId { get { return "ShortcutRemove_" + Id + "_0"; } }
        public string RemoveTwoId { get { return "ShortcutRemove_" + Id + "_1"; } }
        public string RemoveOneText { get { return "移除 " + (Keys.Length > 0 ? DisplayKey(Keys[0]) : ""); } }
        public string RemoveTwoText { get { return "移除 " + (Keys.Length > 1 ? DisplayKey(Keys[1]) : ""); } }
        public event PropertyChangedEventHandler PropertyChanged;
        public void Notify() { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("")); }
    }

    void Build()
    {
        const string markup = @"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Background='Transparent'>
<Grid.Resources>
<Style x:Key='ShortcutButton' TargetType='Button'><Setter Property='MinHeight' Value='30'/><Setter Property='Padding' Value='9,4'/><Setter Property='Foreground' Value='#F2F2F2'/><Setter Property='Background' Value='#242424'/><Setter Property='BorderBrush' Value='#454545'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='Body' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='4' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Body' Property='BorderBrush' Value='#1287bb'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='Body' Property='BorderBrush' Value='#1287bb'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='Body' Property='Background' Value='#23343B'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='ShortcutLink' TargetType='Button' BasedOn='{StaticResource ShortcutButton}'><Setter Property='Background' Value='Transparent'/><Setter Property='BorderBrush' Value='Transparent'/><Setter Property='Foreground' Value='#ABABAB'/><Setter Property='FontSize' Value='12'/></Style>
<Style x:Key='ShortcutKeycap' TargetType='Button' BasedOn='{StaticResource ShortcutButton}'><Setter Property='MinWidth' Value='42'/><Setter Property='MaxWidth' Value='154'/><Setter Property='FontSize' Value='12'/><Setter Property='Padding' Value='10,4'/></Style>
<DataTemplate x:Key='ShortcutRow'><Border BorderBrush='#303030' BorderThickness='0,0,0,1' Padding='2,10' Margin='0,0,8,0'><StackPanel>
<Grid><Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='30'/></Grid.ColumnDefinitions>
<StackPanel Margin='0,2,12,2' VerticalAlignment='Center'><TextBlock Text='{Binding Label}' Foreground='#F2F2F2' FontSize='13' TextTrimming='CharacterEllipsis' ToolTip='{Binding Label}'/><TextBlock Text='{Binding Group}' Foreground='#ABABAB' FontSize='11' Margin='0,4,0,0' Visibility='{Binding GroupVisibility}'/></StackPanel>
<WrapPanel x:Name='Keys' Grid.Column='1' VerticalAlignment='Center' MaxWidth='326'><Button x:Name='KeyOne' Tag='key0' Style='{StaticResource ShortcutKeycap}' Margin='0,2,6,2' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding KeyOneId}' AutomationProperties.Name='{Binding KeyOneName}' ToolTip='{Binding KeyOneName}'><TextBlock Text='{Binding KeyOne}' TextTrimming='CharacterEllipsis'/></Button><Button x:Name='KeyTwo' Tag='key1' Style='{StaticResource ShortcutKeycap}' Margin='0,2,6,2' Visibility='{Binding SecondVisibility}' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding KeyTwoId}' AutomationProperties.Name='{Binding KeyTwoName}' ToolTip='{Binding KeyTwoName}'><TextBlock Text='{Binding KeyTwo}' TextTrimming='CharacterEllipsis'/></Button></WrapPanel>
<Button Grid.Column='2' Tag='detail' Style='{StaticResource ShortcutLink}' Padding='5' Width='30' VerticalAlignment='Center' AutomationProperties.AutomationId='{Binding DetailId}' AutomationProperties.Name='{Binding DetailName}' ToolTip='{Binding DetailName}'><Path x:Name='Chevron' Data='M2,4 L6,8 L10,4' Stroke='#ABABAB' StrokeThickness='1.4' Width='12' Height='12'/></Button>
</Grid>
<Button Tag='conflict' Style='{StaticResource ShortcutLink}' HorizontalAlignment='Left' HorizontalContentAlignment='Left' Padding='0,4' Visibility='{Binding ConflictVisibility}' AutomationProperties.AutomationId='{Binding ConflictId}' AutomationProperties.Name='查看占用动作'><TextBlock Text='{Binding Conflict}' Foreground='#E6B450' TextWrapping='Wrap' MaxWidth='500'/></Button>
<WrapPanel Visibility='{Binding DetailVisibility}' Margin='0,10,0,1'><TextBlock Text='默认' Foreground='#ABABAB' FontSize='12' VerticalAlignment='Center' Margin='0,0,10,5'/><ItemsControl x:Name='DefaultKeycaps' ItemsSource='{Binding DefaultDisplayKeys}' Margin='0,0,6,5'><ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel><ItemsControl.ItemTemplate><DataTemplate><Border Background='#202020' BorderBrush='#454545' BorderThickness='1' CornerRadius='3' Padding='8,4' Margin='0,0,6,0'><TextBlock Text='{Binding}' Foreground='#ABABAB' FontSize='12'/></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl><TextBlock Text='未绑定' Foreground='#ABABAB' FontSize='12' VerticalAlignment='Center' Margin='0,0,12,5' Visibility='{Binding NoDefaultVisibility}'/><Button Tag='remove0' Style='{StaticResource ShortcutLink}' Content='{Binding RemoveOneText}' Visibility='{Binding RemoveOneVisibility}' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding RemoveOneId}' Margin='0,0,6,5'/><Button Tag='remove1' Style='{StaticResource ShortcutLink}' Content='{Binding RemoveTwoText}' Visibility='{Binding RemoveTwoVisibility}' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding RemoveTwoId}' Margin='0,0,6,5'/><Button Tag='restore' Style='{StaticResource ShortcutLink}' Content='恢复默认' Visibility='{Binding ModifiedVisibility}' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding RestoreId}' Margin='0,0,6,5'/></WrapPanel>
</StackPanel></Border><DataTemplate.Triggers><DataTrigger Binding='{Binding Compact}' Value='True'><Setter TargetName='Keys' Property='Grid.Column' Value='0'/><Setter TargetName='Keys' Property='Grid.Row' Value='1'/><Setter TargetName='Keys' Property='Grid.ColumnSpan' Value='3'/><Setter TargetName='Keys' Property='Margin' Value='0,6,0,0'/></DataTrigger><DataTrigger Binding='{Binding Expanded}' Value='True'><Setter TargetName='Chevron' Property='RenderTransform'><Setter.Value><RotateTransform Angle='180' CenterX='6' CenterY='6'/></Setter.Value></Setter></DataTrigger><DataTrigger Binding='{Binding RecordingOne}' Value='True'><Setter TargetName='KeyOne' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='KeyOne' Property='Background' Value='#173442'/></DataTrigger><DataTrigger Binding='{Binding RecordingTwo}' Value='True'><Setter TargetName='KeyTwo' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='KeyTwo' Property='Background' Value='#173442'/></DataTrigger></DataTemplate.Triggers></DataTemplate>
</Grid.Resources>
<Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/></Grid.RowDefinitions>
<Grid Margin='0,0,0,12'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><Border Background='#242424' BorderBrush='#454545' BorderThickness='1' CornerRadius='4' MaxWidth='320' Height='36' HorizontalAlignment='Left' Width='280'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='32'/><ColumnDefinition Width='*'/><ColumnDefinition Width='30'/></Grid.ColumnDefinitions><Viewbox Width='16' Height='16' VerticalAlignment='Center'><Canvas Width='24' Height='24'><Ellipse Canvas.Left='3' Canvas.Top='3' Width='14' Height='14' Stroke='#ABABAB' StrokeThickness='1.7'/><Line X1='15' Y1='15' X2='21' Y2='21' Stroke='#ABABAB' StrokeThickness='1.7' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/></Canvas></Viewbox><TextBox x:Name='ShortcutSearch' Grid.Column='1' Background='Transparent' Foreground='#F2F2F2' CaretBrush='#F2F2F2' BorderThickness='0' Padding='0' VerticalContentAlignment='Center' FontSize='13' AutomationProperties.AutomationId='ShortcutSearch' AutomationProperties.Name='搜索快捷键'><TextBox.Template><ControlTemplate TargetType='TextBox'><ScrollViewer x:Name='PART_ContentHost' VerticalAlignment='Center' Margin='0'/></ControlTemplate></TextBox.Template></TextBox><TextBlock x:Name='Placeholder' Grid.Column='1' Text='搜索快捷键' Foreground='#ABABAB' FontSize='13' VerticalAlignment='Center' IsHitTestVisible='False'/><Button x:Name='ClearSearch' Grid.Column='2' Style='{StaticResource ShortcutLink}' Padding='5' Visibility='Collapsed' AutomationProperties.AutomationId='ShortcutClearSearch' AutomationProperties.Name='清空快捷键搜索'><Path Data='M2,2 L10,10 M10,2 L2,10' Width='12' Height='12' Stroke='#ABABAB' StrokeThickness='1.4'/></Button></Grid></Border><TextBlock x:Name='ResultCount' Grid.Column='1' Foreground='#ABABAB' FontSize='12' VerticalAlignment='Center' Margin='12,0,8,0' AutomationProperties.LiveSetting='Polite'/></Grid>
<WrapPanel Grid.Row='1' Margin='0,0,0,10'><ComboBox x:Name='Categories' MinWidth='148' Height='32' Margin='0,0,14,6' AutomationProperties.AutomationId='ShortcutCategories' AutomationProperties.Name='快捷键功能分类'/><StackPanel x:Name='Filters' Orientation='Horizontal' Margin='0,0,0,6' VerticalAlignment='Center'/></WrapPanel>
<TextBlock x:Name='RecordingHint' Grid.Row='2' Text='按下新组合键，Esc 取消录入' Foreground='#ABABAB' FontSize='12' Margin='0,0,0,10' Visibility='Collapsed'/>
<Grid Grid.Row='3'><ListBox x:Name='Actions' BorderThickness='0' Background='Transparent' ItemTemplate='{StaticResource ShortcutRow}' ScrollViewer.HorizontalScrollBarVisibility='Disabled' ScrollViewer.VerticalScrollBarVisibility='Auto' VirtualizingPanel.IsVirtualizing='True' VirtualizingPanel.VirtualizationMode='Recycling' KeyboardNavigation.TabNavigation='Continue' AutomationProperties.AutomationId='ShortcutActions' AutomationProperties.Name='快捷键操作列表'><ListBox.ItemContainerStyle><Style TargetType='ListBoxItem'><Setter Property='Padding' Value='0'/><Setter Property='Margin' Value='0'/><Setter Property='HorizontalContentAlignment' Value='Stretch'/><Setter Property='IsTabStop' Value='False'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ListBoxItem'><ContentPresenter HorizontalAlignment='Stretch'/></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle></ListBox><Border x:Name='Empty' Padding='20,40' VerticalAlignment='Top' Visibility='Collapsed'><TextBlock Text='没有符合条件的快捷键' Foreground='#ABABAB' TextAlignment='Center' FontSize='13'/></Border></Grid>
</Grid>";
        body = (Grid)XamlReader.Parse(markup); Children.Add(body);
        search = (TextBox)body.FindName("ShortcutSearch"); categories = (ComboBox)body.FindName("Categories");
        actions = (ListBox)body.FindName("Actions"); count = (TextBlock)body.FindName("ResultCount");
        placeholder = (TextBlock)body.FindName("Placeholder"); empty = (Border)body.FindName("Empty");
        recordingHint = (TextBlock)body.FindName("RecordingHint"); clearSearch = (Button)body.FindName("ClearSearch");
        var filterPanel = (StackPanel)body.FindName("Filters");
        categories.Items.Add("全部分类"); foreach (string group in Groups) categories.Items.Add(group); categories.SelectedIndex = 0;
        categories.SelectionChanged += delegate { if (refreshing) return; CancelCaptureCore(); category = categories.SelectedIndex <= 0 ? "all" : Convert.ToString(categories.SelectedItem); RefreshRows(); };
        for (int i = 0; i < FilterIds.Length; i++) {
            string id = FilterIds[i]; var button = new Button { Content = FilterLabels[i], Tag = id, Margin = new Thickness(0,0,4,0), Style = (Style)body.Resources["ShortcutLink"] };
            System.Windows.Automation.AutomationProperties.SetAutomationId(button, "ShortcutFilter_" + id);
            button.Click += delegate { CancelCaptureCore(); filter = id; RefreshRows(); }; filters.Add(id, button); filterPanel.Children.Add(button);
        }
        search.TextChanged += delegate { CancelCaptureCore(); RefreshRows(); };
        clearSearch.Click += delegate { search.Text = ""; FocusSearch(); };
        actions.AddHandler(Button.ClickEvent, new RoutedEventHandler(RowClick), true);
    }

    void RefreshRows()
    {
        visibleRows.Clear();
        foreach (var row in rows) {
            int length = draft[row.Id].Length;
            bool matchesFilter = filter == "bound" ? length > 0 : filter == "unbound" ? length == 0 : filter == "modified" ? row.Modified : true;
            if ((category == "all" || category == row.Group) && matchesFilter && Matches(row, search.Text)) visibleRows.Add(row);
        }
        visibleRows.Sort((a, b) => { int order = GroupRank(a.Group).CompareTo(GroupRank(b.Group)); return order != 0 ? order : rows.IndexOf(a).CompareTo(rows.IndexOf(b)); });
        if (captureId.Length > 0 && !InView(captureId)) CancelCaptureCore();
        if (!InView(expandedId)) expandedId = "";
        actions.ItemsSource = visibleRows.ToArray();
        empty.Visibility = visibleRows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        count.Text = visibleRows.Count + " 项";
        placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        clearSearch.Visibility = search.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Refresh();
    }
    void Refresh()
    {
        foreach (var row in rows) row.Notify();
        foreach (var pair in filters) { pair.Value.Background = pair.Key == filter ? Brush("#173442") : Brushes.Transparent; pair.Value.Foreground = pair.Key == filter ? Brushes.White : Brush("#ABABAB"); }
        recordingHint.Visibility = captureId.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        changed();
    }
    static Brush Brush(string color) { return (Brush)new BrushConverter().ConvertFromString(color); }
    string RowConflict(string id)
    {
        if (!draft.ContainsKey(id)) return "";
        foreach (string key in draft[id]) {
            var other = rows.FirstOrDefault(row => row.Id != id && draft[row.Id].Contains(key));
            if (other != null) return DisplayKey(key) + " 也用于“" + other.Label + "”，查看占用动作";
            if (draft[id].Count(x => x == key) > 1) return DisplayKey(key) + " 在此操作中重复，请移除一个按键";
        }
        return "";
    }
    string Conflict() { foreach (var row in rows) { string error = RowConflict(row.Id); if (error.Length > 0) return "“" + row.Label + "”：" + error; } return ""; }
    void RowClick(object sender, RoutedEventArgs e)
    {
        var button = e.OriginalSource as Button ?? e.Source as Button;
        var row = button == null ? null : button.DataContext as ActionRow;
        if (row == null || !button.IsEnabled || !InView(row.Id)) return;
        string op = button.Tag as string;
        if (op == "detail") { CancelCaptureCore(); expandedId = expandedId == row.Id ? "" : row.Id; Refresh(); }
        else if (op == "conflict") LocateConflict(row.Id);
        else if (op == "key0" || op == "key1") BeginCapture(row.Id, op == "key0" ? 0 : 1);
        else if (op == "remove0" || op == "remove1") ChangeKey(row.Id, op == "remove0" ? 0 : 1, null);
        else if (op == "restore") Restore(row.Id);
        e.Handled = true;
    }
    void BeginCapture(string id, int index)
    {
        if (!Editable || !InView(id) || index < 0 || index > 1 || (index == 1 && draft[id].Length == 0)) return;
        CancelCaptureCore(); captureId = id; capture = index; localError = ""; localNotice = ""; Refresh(); FocusRowKey(id, index);
    }
    public void CancelCapture() { if (captureId.Length == 0) return; CancelCaptureCore(); Refresh(); }
    void CancelCaptureCore() { focusRequest++; if (captureId.Length > 0) localError = ""; captureId = ""; capture = -1; }
    bool IsCaptureTarget(DependencyObject control) { return control != null && System.Windows.Automation.AutomationProperties.GetAutomationId(control) == "ShortcutKey_" + captureId + "_" + capture; }
    void ChangeKey(string id, int index, string key)
    {
        if (!Editable || !InView(id) || !draft.ContainsKey(id)) return;
        if (index < 0 || index > 1 || (key != null && !ShortcutKeyNames.IsCanonical(key))) { localError = "此按键无法使用，请重新录入。"; Refresh(); return; }
        var keys = draft[id].ToList();
        if (index < keys.Count) { if (key == null) keys.RemoveAt(index); else keys[index] = key; }
        else if (key != null && keys.Count < 2) keys.Add(key);
        draft[id] = keys.ToArray(); CancelCaptureCore(); localError = ""; localNotice = ""; RefreshRows();
        if (InView(id)) FocusRowKey(id, Math.Min(index, Math.Max(0, draft[id].Length - 1))); else FocusSearch();
    }
    void Restore(string id)
    {
        var row = Find(id); if (row == null || !Editable || !InView(id)) return;
        draft[id] = row.Defaults.ToArray(); CancelCaptureCore(); localError = ""; localNotice = ""; RefreshRows();
    }
    void LocateConflict(string id)
    {
        if (!draft.ContainsKey(id)) return;
        var other = rows.FirstOrDefault(row => row.Id != id && draft[row.Id].Any(key => draft[id].Contains(key)));
        if (other != null) Locate(other.Id);
    }
    public void Locate(string id)
    {
        var row = Find(id); if (row == null) return;
        CancelCaptureCore(); refreshing = true; categories.SelectedIndex = 0; category = "all"; filter = "all"; search.Text = ""; refreshing = false;
        expandedId = id; RefreshRows(); actions.ScrollIntoView(row); FocusRowKey(id, 0);
    }
    public void FocusSearch() { CancelCaptureCore(); search.Focus(); search.SelectAll(); Refresh(); }
    void FocusRowKey(string id, int index)
    {
        int ticket = ++focusRequest;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(delegate {
            if (ticket != focusRequest || !InView(id)) return;
            actions.UpdateLayout();
            var button = Descendants<Button>(actions).FirstOrDefault(x => System.Windows.Automation.AutomationProperties.GetAutomationId(x) == "ShortcutKey_" + id + "_" + index && x.Visibility == Visibility.Visible);
            if (button != null) { button.BringIntoView(); button.Focus(); }
        }));
    }
    void AcceptCapture(int vk, bool ctrl, bool alt, bool shift, bool windows)
    {
        if (captureId.Length == 0 || !InView(captureId) || !Editable) { CancelCapture(); return; }
        if (vk == 27) { localError = ""; CancelCapture(); return; }
        if (vk == 16 || vk == 17 || vk == 18 || (vk >= 160 && vk <= 165)) return;
        string key = windows ? null : ShortcutKeyNames.FromVirtualKey(vk, ctrl, alt, shift);
        if (key == null) { localError = "此按键保留给窗口操作，请选择其他组合键。"; Refresh(); return; }
        ChangeKey(captureId, capture, key);
    }
    void OnKey(object sender, KeyEventArgs e)
    {
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (captureId.Length > 0) {
            // A stale queued focus request must never turn search typing into a binding.
            if (e.OriginalSource is TextBoxBase || Keyboard.FocusedElement is TextBoxBase) CancelCapture();
            else { e.Handled = true; var mods = Keyboard.Modifiers; AcceptCapture(KeyInterop.VirtualKeyFromKey(key), (mods & ModifierKeys.Control) != 0, (mods & ModifierKeys.Alt) != 0, (mods & ModifierKeys.Shift) != 0, (mods & ModifierKeys.Windows) != 0); return; }
        }
        if (key == Key.Escape) {
            if (search.Text.Length > 0) { search.Text = ""; FocusSearch(); e.Handled = true; }
            else if (expandedId.Length > 0) { expandedId = ""; Refresh(); e.Handled = true; }
        }
        else if (key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; FocusSearch(); }
    }

    List<ActionRow> ParseRows(Dictionary<string, object> state, out Dictionary<string, string[]> next)
    {
        object raw;
        if (!state.TryGetValue("actions", out raw) || !(raw is object[])) throw new InvalidDataException("快捷键列表无效，请重新载入。");
        object editable;
        if (Flag(state, "repairable") && state.TryGetValue("editable_actions", out editable) && editable is object[]) raw = editable;
        var updated = new List<ActionRow>(); next = new Dictionary<string, string[]>(StringComparer.Ordinal);
        foreach (object item in (object[])raw) {
            var entry = item as Dictionary<string, object>;
            string id = Text(entry, "id");
            if (entry == null || id.Length == 0 || next.ContainsKey(id)) throw new InvalidDataException("快捷键操作重复或无效，请重新载入。");
            object defaults, current;
            if (!entry.TryGetValue("default_keys", out defaults) || !entry.TryGetValue("keys", out current)) throw new InvalidDataException("快捷键列表不完整。");
            var row = new ActionRow { Owner = this, Id = id, Label = Text(entry, "label"), Group = Text(entry, "group"), Defaults = Keys(defaults) };
            next.Add(id, Keys(current)); updated.Add(row);
        }
        return updated;
    }
    void Load(Dictionary<string, object> state, List<ActionRow> updated, Dictionary<string, string[]> next)
    {
        CancelCaptureCore(); rows.Clear(); rows.AddRange(updated); draft.Clear(); baseline.Clear();
        foreach (var pair in next) { draft[pair.Key] = pair.Value.ToArray(); baseline[pair.Key] = pair.Value.ToArray(); }
        latest = state; revision = Text(state, "revision"); stale = false; invalid = false; localError = ""; localNotice = ""; RefreshRows();
    }
    bool CanRebase(Dictionary<string, object> state, List<ActionRow> updated, Dictionary<string, string[]> next)
    {
        if (stale || Text(state, "error").Length > 0 || Flag(state, "read_only") || next.Count != baseline.Count || updated.Count != rows.Count) return false;
        if (!next.All(pair => baseline.ContainsKey(pair.Key) && pair.Value.SequenceEqual(baseline[pair.Key]))) return false;
        return updated.All(row => { var previous = Find(row.Id); return previous != null && previous.Label == row.Label && previous.Group == row.Group && previous.Defaults.SequenceEqual(row.Defaults); });
    }
    public void Adopt(Dictionary<string, object> state)
    {
        if (state == null || Number(state, "schema", -1) != 1) return;
        string incomingToken = Text(state, "editor_token");
        if (incomingToken.Length == 0 || incomingToken.Length > 256 || incomingToken.Any(Char.IsControl) || (token.Length > 0 && token != incomingToken)) return;
        // Remember malformed current state too: Revert must not clear the safety
        // lock by silently reloading an older, previously valid publication.
        token = incomingToken; latest = state;
        try {
            Dictionary<string, string[]> next; var updated = ParseRows(state, out next);
            invalid = false;
            int serial = Number(state, "save_serial", 0);
            bool completed = saving && serial > pendingSerial && !Flag(state, "saving");
            if (completed) {
                saving = false;
                string error = Text(state, "save_error");
                if (error.Length > 0) { localError = error; if (Text(state, "revision") != revision) stale = true; }
                else if (submitted != null && submitted.Count == next.Count && submitted.All(p => next.ContainsKey(p.Key) && p.Value.SequenceEqual(next[p.Key]))) { Load(state, updated, next); localNotice = "已保存并应用。"; }
                else { stale = true; localError = "保存完成后键位又发生变化，草稿已保留。撤销可载入最新键位。"; }
                submitted = null;
            }
            else if (revision.Length == 0 || (!Dirty && !saving)) Load(state, updated, next);
            else if (Text(state, "revision") != revision && !saving) {
                // Another settings page can change the shared document revision
                // without changing this domain. Rebase only an identical saved
                // shortcut map/catalog; actual key edits retain conflict safety.
                if (CanRebase(state, updated, next)) revision = Text(state, "revision");
                else { stale = true; CancelCaptureCore(); }
            }
            saveSerial = serial;
            Refresh();
        }
        catch (InvalidDataException error) { invalid = true; CancelCaptureCore(); localError = error.Message; Refresh(); }
    }
    public void Save()
    {
        if (!CanSave) return;
        var overrides = new Dictionary<string, object>();
        foreach (var row in rows) if (!draft[row.Id].SequenceEqual(row.Defaults)) overrides[row.Id] = draft[row.Id];
        submitted = draft.ToDictionary(p => p.Key, p => p.Value.ToArray(), StringComparer.Ordinal);
        CancelCaptureCore(); saving = true; pendingSerial = saveSerial; saveStarted = DateTime.UtcNow; localError = ""; localNotice = "";
        try { send(new object[] { "script-message-to", "user_shortcuts", "save", token, revision, json.Serialize(overrides) }); }
        catch (Exception error) { saving = false; stale = true; submitted = null; localError = "保存请求未送达，草稿已保留：" + error.Message; }
        Refresh();
    }
    public void Revert()
    {
        if (saving || latest == null) return;
        if (stale || invalid) {
            try { Dictionary<string, string[]> next; var updated = ParseRows(latest, out next); Load(latest, updated, next); }
            catch (InvalidDataException error) { invalid = true; localError = error.Message; Refresh(); return; }
        }
        else { CancelCaptureCore(); foreach (var pair in baseline) draft[pair.Key] = pair.Value.ToArray(); localError = ""; RefreshRows(); }
        localNotice = "已撤销未保存的更改。"; Refresh();
    }
    public void Reset()
    {
        if (!Editable) return;
        CancelCapture(); string expectedRevision = revision; bool applied = false;
        confirm("恢复本页默认按键？", "所有快捷键将恢复为默认值，保存后生效。", delegate {
            if (applied || !Editable || revision != expectedRevision) return;
            applied = true; CancelCaptureCore(); foreach (var row in rows) draft[row.Id] = row.Defaults.ToArray();
            localError = ""; localNotice = "已将默认键位放入草稿；保存后应用。"; RefreshRows();
        });
    }
    public void Tick()
    {
        if (saving && DateTime.UtcNow.Subtract(saveStarted).TotalSeconds > 15) {
            saving = false; stale = true; submitted = null; localError = "保存未收到完成结果，草稿已保留。撤销可重新载入并确认当前键位。"; Refresh();
        }
    }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = VisualTreeHelper.GetChild(root, i); if (child is T) yield return (T)child;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }
}
