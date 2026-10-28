using System;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;

// Presentation-only controls. Values still enter SettingsDraft and the existing
// save/preview protocol; pickers never write configuration files themselves.
public sealed partial class SettingsEditor
{
    Grid rootPanel, bodyPanel;
    Border footerPanel, overlay;
    FrameworkElement overlayReturn;
    readonly Dictionary<string, StackPanel> languageLists = new Dictionary<string, StackPanel>();
    SettingsShortcutsPanel shortcuts;
    Canvas subtitleExample;
    TextBlock subtitleSample;
    bool overlayOpen;
    static readonly string[][] Languages = {
        new[]{"zh,zho,chi", "中文"}, new[]{"ja,jpn", "日语"}, new[]{"en,eng", "英语"},
        new[]{"ko,kor", "韩语"}, new[]{"fr,fra,fre", "法语"}, new[]{"de,deu,ger", "德语"},
        new[]{"es,spa", "西班牙语"}, new[]{"it,ita", "意大利语"}, new[]{"ru,rus", "俄语"},
        new[]{"pt,por", "葡萄牙语"}, new[]{"ar,ara", "阿拉伯语"}, new[]{"th,tha", "泰语"}
    };
    // Adjacent aliases form one language row, preserving their original spelling
    // and order when moving/removing a language. Unknown codes remain intact.
    internal static string LanguageName(string value)
    {
        string first = value.Split(',')[0];
        var known = Languages.FirstOrDefault(x => x[0].Split(',').Contains(first));
        if (known != null) return known[1];
        try { return CultureInfo.GetCultureInfo(first).DisplayName; } catch { return first; }
    }
    internal static List<string> LanguageGroups(string value)
    {
        var groups = new List<string>();
        foreach (string code in value.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0)) {
            if (groups.Count > 0 && LanguageName(groups.Last()) == LanguageName(code)) groups[groups.Count - 1] += "," + code;
            else groups.Add(code);
        }
        return groups;
    }
    FrameworkElement LanguageControl(SettingsDraft.Field field, out Control input)
    {
        var panel = new StackPanel(); var rows = new StackPanel(); panel.Children.Add(rows); languageLists[field.Id] = rows;
        var add = Button("＋ 添加语言", delegate { LanguagePicker(field); });
        add.Background = Brushes.Transparent; add.BorderThickness = new Thickness(0); add.FontSize = 12;
        add.HorizontalAlignment = HorizontalAlignment.Left; add.Margin = new Thickness(0, 4, 0, 0); panel.Children.Add(add);
        input = add; RefreshLanguages(field); return panel;
    }
    void RefreshLanguages(SettingsDraft.Field field)
    {
        StackPanel panel; if (!languageLists.TryGetValue(field.Id, out panel)) return;
        if ((string)panel.Tag == field.Text) return; panel.Tag = field.Text;
        panel.Children.Clear(); var values = LanguageGroups(field.Text);
        if (values.Count == 0) panel.Children.Add(new TextBlock { Text = field.Id == "alang" ? "使用视频的默认音轨" : "不指定优先语言", Foreground = Brush("#ABABAB"), Margin = new Thickness(10) });
        for (int i = 0; i < values.Count; ++i) {
            int index = i; var row = new DockPanel { LastChildFill = true, Background = Brush("#202020"), Margin = new Thickness(0, 0, 0, 1), MinHeight = 34 };
            var controls = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(controls, Dock.Right); row.Children.Add(controls);
            foreach (int move in new[] { -1, 1, 0 }) {
                int direction = move;
                var button = Button(move == -1 ? "↑" : move == 1 ? "↓" : "×", delegate {
                    var next = LanguageGroups(field.Text);
                    if (direction == 0) next.RemoveAt(index); else { string v = next[index]; next.RemoveAt(index); next.Insert(index + direction, v); }
                    EditField(field, String.Join(",", next)); RefreshLanguages(field);
                });
                button.Width = 28; button.Height = 30; button.Padding = new Thickness(0); button.Margin = new Thickness(0); button.Background = Brushes.Transparent; button.BorderThickness = new Thickness(0);
                button.IsEnabled = move == 0 || (move < 0 ? i > 0 : i < values.Count - 1);
                string name = (move == -1 ? "上移" : move == 1 ? "下移" : "移除") + LanguageName(values[i]); button.ToolTip = name;
                System.Windows.Automation.AutomationProperties.SetName(button, name); controls.Children.Add(button);
            }
            row.Children.Add(new TextBlock { Text = (i + 1) + "    " + LanguageName(values[i]), Margin = new Thickness(10, 7, 0, 7), VerticalAlignment = VerticalAlignment.Center }); panel.Children.Add(row);
        }
    }
    void LanguagePicker(SettingsDraft.Field field)
    {
        var all = Languages.Select(x => new KeyValuePair<string,string>(x[0],x[1])).ToList();
        foreach (var culture in CultureInfo.GetCultures(CultureTypes.NeutralCultures).Where(c => c.Name.Length == 2))
            if (!all.Any(x => x.Key.Split(',').Contains(culture.Name))) all.Add(new KeyValuePair<string,string>(culture.Name,culture.DisplayName));
        string[] present = LanguageGroups(field.Text).Select(LanguageName).ToArray();
        ShowPicker("添加语言", "搜索语言", all.Where(x => !present.Contains(x.Value)), false, value => {
            EditField(field, field.Text.Length == 0 ? value : field.Text + "," + value); RefreshLanguages(field);
        });
    }
    static string FontLabel(string value)
    {
        if (String.IsNullOrEmpty(value) || value == "sans-serif") return "默认字体";
        try { var family = new FontFamily(value); var key = System.Windows.Markup.XmlLanguage.GetLanguage("zh-cn"); return family.FamilyNames.ContainsKey(key) ? family.FamilyNames[key] : family.Source; }
        catch { return value; }
    }
    void FontPicker(SettingsDraft.Field field)
    {
        var fonts = new List<KeyValuePair<string,string>> { new KeyValuePair<string,string>("sans-serif", "默认字体") };
        fonts.AddRange(Fonts.SystemFontFamilies.Select(f => new KeyValuePair<string,string>(f.Source, FontLabel(f.Source))).OrderBy(f => f.Value, StringComparer.CurrentCultureIgnoreCase));
        ShowPicker("选择字幕字体", "搜索本机字体", fonts, true, value => { EditField(field, value); SyncInputs(); });
    }
    void ShowPicker(string title, string placeholder, IEnumerable<KeyValuePair<string,string>> choices, bool fontPreview, Action<string> selected)
    {
        var panel = new StackPanel(); panel.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 16) });
        var box = new TextBox { Height = 36, Tag = placeholder, Style = (Style)FindResource("SearchBox"), Margin = new Thickness(0, 0, 0, 10) };
        System.Windows.Automation.AutomationProperties.SetName(box, placeholder); panel.Children.Add(box);
        var list = new ListBox { Height = 280, Background = Brushes.Transparent, BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled); panel.Children.Add(list);
        var items = choices.ToArray();
        Action fill = delegate {
            list.Items.Clear(); string query = box.Text.Trim();
            foreach (var pair in items.Where(x => Matches(x.Key + " " + x.Value, query))) {
                var item = pair; var line = new Grid(); line.ColumnDefinitions.Add(new ColumnDefinition()); line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                line.Children.Add(new TextBlock { Text = item.Value, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
                if (fontPreview) { var sample = new TextBlock { Text = "字 Aa", FontSize = 17, Margin = new Thickness(16, 0, 0, 0), FontFamily = new FontFamily(item.Key == "sans-serif" ? "Microsoft YaHei UI" : item.Key) }; Grid.SetColumn(sample, 1); line.Children.Add(sample); }
                var choice = Button("", delegate { CloseOverlay(); selected(item.Key); }); choice.Content = line; choice.HorizontalContentAlignment = HorizontalAlignment.Stretch; choice.Background = Brushes.Transparent; choice.BorderThickness = new Thickness(0); choice.Margin = new Thickness(0); choice.Padding = new Thickness(10, 8, 10, 8);
                System.Windows.Automation.AutomationProperties.SetName(choice, item.Value); list.Items.Add(choice);
            }
            if (list.Items.Count == 0) list.Items.Add(new TextBlock { Text = "没有匹配项", Margin = new Thickness(12) });
        };
        box.TextChanged += delegate { fill(); }; box.PreviewKeyDown += delegate(object sender, KeyEventArgs e) { if ((e.Key == Key.Down || e.Key == Key.Enter) && list.Items.Count > 0 && list.Items[0] is Button) { var first = (Button)list.Items[0]; first.Focus(); if (e.Key == Key.Enter) first.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); e.Handled = true; } };
        var close = Button("返回设置", CloseOverlay); close.HorizontalAlignment = HorizontalAlignment.Right; close.Margin = new Thickness(0, 12, 0, 0); panel.Children.Add(close);
        fill(); ShowOverlay(panel, box);
    }
    void ShowOverlay(FrameworkElement panel, FrameworkElement focus)
    {
        if (overlayOpen) CloseOverlay(); overlayReturn = Keyboard.FocusedElement as FrameworkElement;
        overlay = new Border { Background = new SolidColorBrush(Color.FromArgb(160,0,0,0)) }; Grid.SetColumnSpan(overlay, 2);
        var dialog = new Border { Width = 440, MaxHeight = Math.Max(300, (ActualHeight > 0 ? ActualHeight : Height) - 80), Padding = new Thickness(24), CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1), BorderBrush = Brush("#484848"), Background = Brush("#1B1B1B"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = panel };
        KeyboardNavigation.SetTabNavigation(dialog, KeyboardNavigationMode.Cycle); overlay.Child = dialog;
        bodyPanel.IsEnabled = false; overlayOpen = true; rootPanel.Children.Add(overlay); playerPreview.Hide(); EndDisplay();
        overlay.PreviewKeyDown += delegate(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) { CloseOverlay(); e.Handled = true; } };
        Dispatcher.BeginInvoke(new Action(delegate { if (overlayOpen) focus.Focus(); }));
    }
    void CloseOverlay()
    {
        if (!overlayOpen) return; rootPanel.Children.Remove(overlay); overlayOpen = false; bodyPanel.IsEnabled = true;
        if (overlayReturn != null && overlayReturn.IsVisible) overlayReturn.Focus(); selectingPage = true; UpdatePlayerPreview(); selectingPage = false; Refresh();
    }
    void Confirm(string title, string message, Action accept)
    {
        var panel = new StackPanel(); panel.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 14, 0, 22), TextWrapping = TextWrapping.Wrap, Foreground = Brush("#BCBCBC") });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right }; panel.Children.Add(actions);
        var back = Button("返回设置", CloseOverlay); back.Background = Brush("#1287BB"); actions.Children.Add(back);
        actions.Children.Add(Button(title.StartsWith("放弃") ? "放弃修改并关闭" : "恢复默认", delegate { CloseOverlay(); accept(); })); ShowOverlay(panel, back);
    }
    void UpdateSubtitleExample()
    {
        if (subtitleSample == null) return; SettingsDraft.Field f; double scale = 1, position = 100;
        if (model.Fields.TryGetValue("sub-scale", out f)) Double.TryParse(f.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out scale);
        if (model.Fields.TryGetValue("sub-pos", out f)) Double.TryParse(f.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out position);
        if (Double.IsNaN(scale) || Double.IsInfinity(scale)) scale = 1;
        if (Double.IsNaN(position) || Double.IsInfinity(position)) position = 100;
        string font = model.Fields.TryGetValue("sub-font", out f) ? f.Text : "sans-serif";
        try { subtitleSample.FontFamily = new FontFamily(font == "sans-serif" || font.Length == 0 ? "Microsoft YaHei UI" : font); } catch { subtitleSample.FontFamily = FontFamily; }
        subtitleSample.FontSize = Math.Max(1, Math.Min(220, 22 * scale)); subtitleSample.Width = Math.Max(0, subtitleExample.ActualWidth - 32);
        subtitleSample.Measure(new Size(subtitleSample.Width, Double.PositiveInfinity));
        Canvas.SetLeft(subtitleSample, 16); Canvas.SetTop(subtitleSample, 8 + Math.Max(0, subtitleExample.ActualHeight - subtitleSample.DesiredSize.Height - 16) * Math.Max(0, Math.Min(100, position)) / 100);
    }
    FrameworkElement SubtitleExample()
    {
        subtitleExample = new Canvas { Background = Brush("#24282B"), Height = 134, ClipToBounds = true, Margin = new Thickness(0, 0, 0, 12) };
        subtitleSample = new TextBlock { Text = "这一刻，让画面慢下来。", TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.White };
        subtitleSample.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Colors.Black, BlurRadius = 3, ShadowDepth = 1, Opacity = 1 }; subtitleExample.Children.Add(subtitleSample);
        subtitleExample.SizeChanged += delegate { UpdateSubtitleExample(); }; UpdateSubtitleExample(); return subtitleExample;
    }
    object NavigationContent(string id, bool dirty)
    {
        string[] glyphs = { "\uE8D2", "\uE767", "\uE737", "\uE713", "\uE7F4", "\uE8B7", "\uE765", "\uE713" };
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(new TextBlock { Text = glyphs[Array.IndexOf(SettingsDraft.Pages,id)], FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Width = 24, VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = SettingsDraft.PageName(id) + (dirty ? " •" : ""), VerticalAlignment = VerticalAlignment.Center }); return panel;
    }
    Button SearchResult(string name, string category, Action action)
    {
        var button = Button("", action); button.Tag = name + " · " + category;
        var text = new StackPanel(); text.Children.Add(new TextBlock { Text = name });
        text.Children.Add(new TextBlock { Text = category, FontSize = 12, Foreground = Brush("#ABABAB"), Margin = new Thickness(0,4,0,0) });
        button.Content = text; button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Background = Brushes.Transparent; button.BorderBrush = Brush("#303030"); button.BorderThickness = new Thickness(0,0,0,1); button.Padding = new Thickness(4,14,4,14); button.Margin = new Thickness(0);
        return button;
    }
    static IEnumerable<T> VisualChildren<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); ++i) {
            var child = VisualTreeHelper.GetChild(root, i); if (child is T) yield return (T)child;
            foreach (var nested in VisualChildren<T>(child)) yield return nested;
        }
    }
    sealed class DialogOwner : System.Windows.Forms.IWin32Window { public IntPtr Handle { get; set; } }
    void BrowsePath(SettingsDraft.Field field)
    {
        string selected = null;
        if (field.Id == "capture_root") {
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog { Description = "选择截图与片段保存目录", SelectedPath = field.Text, ShowNewFolderButton = true })
                if (dialog.ShowDialog(new DialogOwner { Handle = new WindowInteropHelper(this).Handle }) == System.Windows.Forms.DialogResult.OK) selected = dialog.SelectedPath;
        } else {
            var dialog = new Microsoft.Win32.OpenFileDialog { Title = "选择" + field.Label, Filter = "程序文件 (*.exe)|*.exe", CheckFileExists = true, Multiselect = false };
            if (dialog.ShowDialog(this) == true) selected = dialog.FileName;
        }
        if (selected != null) { EditField(field, selected); SyncInputs(); }
    }
}
