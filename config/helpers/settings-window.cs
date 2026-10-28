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
        public string Id, Page, Label, Text, BaselineText, Status, ApplyError, Source;
        public object Default, Saved, Effective;
        public bool Override, BaselineOverride, CanCancel;
        public double Min, Max;
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
            f.Label = Str(row, "label"); f.Default = Value(row, "default");
            f.Saved = Value(row, "saved"); f.Effective = Value(row, "effective");
            f.Status = Str(row, "status"); f.ApplyError = Str(row, "apply_error"); f.Source = Str(row, "default_source");
            f.CanCancel = Flag(row, "can_cancel");
            f.Min = row.ContainsKey("min") ? Convert.ToDouble(row["min"], CultureInfo.InvariantCulture) : 0;
            f.Max = row.ContainsKey("max") ? Convert.ToDouble(row["max"], CultureInfo.InvariantCulture) : 0;
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

public sealed class SettingsEditor : Window
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int n);
    readonly SettingsDraft model = new SettingsDraft();
    readonly JavaScriptSerializer json = UserPreferencesStorage.Json();
    readonly bool validation, noShow;
    readonly string token;
    readonly Process parent;
    readonly DispatcherTimer timer = new DispatcherTimer();
    readonly List<object> sent = new List<object>();
    readonly Dictionary<string, TextBox> editors = new Dictionary<string, TextBox>();
    readonly Dictionary<string, TextBlock> descriptions = new Dictionary<string, TextBlock>();
    readonly Dictionary<string, Button> categories = new Dictionary<string, Button>();
    Dictionary<string, object> latest = new Dictionary<string, object>();
    NamedPipeClientStream pipe; StreamReader reader; StreamWriter writer; Task<string> read;
    TextBox search; StackPanel content, results; TextBlock notice, heading; Button save, undo, reset;
    string page = "subtitles", pendingPage, pendingRevision, localError = "";
    int pendingSerial, serial, sequence;
    bool syncing, saving, forceClose, finished, disconnected;
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
        Title = "设置 · mpvnet-kit"; Width = 900; Height = 650; MinWidth = 760; MinHeight = 540;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14; Background = Brush("#111111"); Foreground = Brushes.White;
        Resources = (ResourceDictionary)XamlReader.Parse(@"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
<Style TargetType='Button'><Setter Property='Background' Value='#262626'/><Setter Property='Foreground' Value='White'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='border' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='3' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='border' Property='Background' Value='#353535'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='border' Property='BorderBrush' Value='#1287bb'/><Setter TargetName='border' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='border' Property='Background' Value='#1287bb'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
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
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1); body.Children.Add(scroll);
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
        page = id; editors.Clear(); descriptions.Clear(); content.Children.Clear(); heading.Text = SettingsDraft.PageName(page);
        foreach (var f in model.Fields.Values.Where(x => x.Page == page))
        {
            var field = f;
            var title = new Label { Content = f.Label, Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 8) }; content.Children.Add(title);
            var input = new TextBox { Text = f.Text, MaxLength = f.Page == "paths" ? 2048 : 16, Margin = new Thickness(0, 0, 0, 8) };
            title.Target = input; System.Windows.Automation.AutomationProperties.SetName(input, f.Label);
            System.Windows.Automation.AutomationProperties.SetAutomationId(input, "Setting_" + f.Id);
            editors.Add(f.Id, input); content.Children.Add(input);
            var detail = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Brush("#bcbcbc"), Margin = new Thickness(0, 0, 0, 8) };
            descriptions.Add(f.Id, detail); content.Children.Add(detail);
            if (f.Page != "paths")
            {
                var preview = Button("预览", delegate { Preview(field); }); preview.HorizontalAlignment = HorizontalAlignment.Left;
                preview.Margin = new Thickness(0, 0, 0, 20); content.Children.Add(preview);
            }
            input.TextChanged += delegate {
                if (!syncing)
                {
                    model.Edit(field.Id, input.Text); localError = "";
                    object value;
                    if (field.Page != "paths" && model.TryValue(field, out value)) Preview(field);
                    Refresh();
                }
            };
        }
        Refresh();
    }
    void Search()
    {
        results.Children.Clear(); string query = search.Text.Trim();
        if (query.Length == 0) return;
        foreach (var f in model.Fields.Values.Where(f => (f.Label + " " + f.Id + " " + SettingsDraft.PageName(f.Page)).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0))
        {
            var field = f;
            var b = Button(f.Label + " · " + SettingsDraft.PageName(f.Page), delegate {
                SelectPage(field.Page); TextBox input; if (editors.TryGetValue(field.Id, out input)) { input.BringIntoView(); input.Focus(); input.SelectAll(); }
            }); b.Margin = new Thickness(0, 0, 0, 8); results.Children.Add(b);
        }
        if (results.Children.Count == 0) results.Children.Add(new TextBlock { Text = "没有匹配的设置", Margin = new Thickness(0, 0, 0, 16) });
    }
    void Preview(SettingsDraft.Field f)
    {
        if (saving || disconnected) return;
        object value;
        if (!model.TryValue(f, out value)) { localError = f.Label + "请输入 " + f.Min + " 至 " + f.Max + " 的数值。"; Refresh(); return; }
        Action("preview", f.Id, json.Serialize(value));
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
    void SyncInputs() { syncing = true; foreach (var item in editors) item.Value.Text = model.Fields[item.Key].Text; syncing = false; }
    static string Status(string value)
    {
        switch (value) { case "preview": return "正在预览，仅此播放器"; case "pending-media": return "下一媒体生效";
            case "pending-restart": return "重启播放器后生效"; case "apply-failed": return "应用失败"; case "effective": return "已生效"; default: return "等待播放器状态"; }
    }
    void Refresh()
    {
        foreach (var item in categories) { item.Value.Content = SettingsDraft.PageName(item.Key) + (model.Dirty(item.Key) ? " *" : ""); item.Value.BorderBrush = Brush(item.Key == page ? "#1287bb" : "#555555"); }
        foreach (var item in descriptions)
        {
            var f = model.Fields[item.Key];
            item.Value.Text = "已保存：" + Display(f.Saved) + "    当前：" + Display(f.Effective) + "\n" + Status(f.Status) +
                (f.Override ? "" : " · 沿用默认") + (f.ApplyError.Length > 0 ? "\n" + f.ApplyError : "") +
                (f.Page == "paths" ? "\n留空沿用默认路径。" : "\n默认：" + Display(f.Default) + "（" + f.Source + "）");
        }
        string error = SettingsDraft.Str(latest, page == "paths" ? "paths_error" : "error");
        string revision = SettingsDraft.Str(latest, page == "paths" ? "paths_revision" : "revision");
        string baseline; bool stale = model.Revisions.TryGetValue(page, out baseline) && baseline != revision;
        string noticeText = localError.Length > 0 ? localError : error.Length > 0 ? error :
            stale && model.Dirty(page) ? "配置已被其他窗口修改。草稿已保留；撤销本页修改可载入最新值。" :
            saving ? "正在保存，请稍候…" : model.Dirty(page) ? "本页有未保存修改。" : "本页没有未保存修改。";
        if (!saving && localError.Length == 0 && SettingsDraft.Str(latest, "save_page") == page && serial > 0)
        {
            string saveError = SettingsDraft.Str(latest, "save_error");
            if (saveError.Length > 0) noticeText += "\n" + saveError;
            else if (SettingsDraft.Flag(latest, "save_ok")) noticeText += "\n已保存。生效情况见各项说明。";
        }
        string previewError = SettingsDraft.Str(latest, "preview_error"); if (previewError.Length > 0) noticeText += "\n" + previewError;
        notice.Text = noticeText;
        bool valid = model.Fields.Values.Where(f => f.Page == page).All(f => { object v; return model.TryValue(f, out v); });
        save.IsEnabled = !saving && !disconnected && model.Dirty(page) && !stale && error.Length == 0 && valid;
        undo.IsEnabled = !saving && !disconnected && (model.Dirty(page) || stale || model.Fields.Values.Any(f => f.Page == page && (f.Status == "preview" || f.CanCancel)));
        reset.IsEnabled = !saving && !disconnected && model.Fields.Count > 0 && error.Length == 0;
        content.IsEnabled = !saving;
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
        if (!validation) writer.WriteLine(json.Serialize(new { command = command, request_id = ++sequence }));
    }
    void Action(string operation, params string[] args)
    {
        if (disconnected) return;
        var command = new List<object> { "script-message-to", "user_settings", operation, token }; command.AddRange(args); Send(command.ToArray());
    }
    void Disconnect()
    {
        disconnected = true;
        localError = "播放器连接中断，草稿已保留。请核对保存结果后关闭并重新打开设置。";
        saving = false; Refresh();
    }
    void Tick(object sender, EventArgs e)
    {
        try
        {
            if (parent.HasExited) { forceClose = true; Close(); return; }
            if (disconnected) return;
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
        try { Action("editor-close"); } catch { }
    }
    public void Finish() { if (finished) return; finished = true; timer.Stop(); if (pipe != null) pipe.Dispose(); parent.Dispose(); }
    public void Run() { if (noShow) new Application().Run(); else new Application().Run(this); }
    // Exercises the same draft and control event paths, without player/filesystem IO.
    public object Validate(Dictionary<string, object> request)
    {
        State(UserPreferencesStorage.Object(request["validation_state"]));
        object steps;
        if (request.TryGetValue("validation_steps", out steps)) foreach (var entry in (object[])steps)
        {
            var step = UserPreferencesStorage.Object(entry); string op = SettingsDraft.Str(step, "op");
            if (op == "page") SelectPage(SettingsDraft.Str(step, "page"));
            else if (op == "edit") { string id = SettingsDraft.Str(step, "id"); SelectPage(model.Fields[id].Page); editors[id].Text = SettingsDraft.Str(step, "text"); }
            else if (op == "search") search.Text = SettingsDraft.Str(step, "text");
            else if (op == "state") State(UserPreferencesStorage.Object(step["state"]));
            else if (op == "save") Save(); else if (op == "reset") Reset(); else if (op == "undo") Revert();
            else if (op == "disconnect") Disconnect();
            else if (op == "preview") Preview(model.Fields[SettingsDraft.Str(step, "id")]);
        }
        Measure(new Size(Width, Height)); Arrange(new Rect(0, 0, Width, Height)); UpdateLayout();
        return new { ok = true, shown = IsVisible, page = page, dirty_pages = model.DirtyPages(),
            drafts = model.Fields.ToDictionary(x => x.Key, x => new { text = x.Value.Text, overridden = x.Value.Override }),
            revisions = model.Revisions, can_save = save.IsEnabled, saving = saving, notice = notice.Text,
            search_results = results.Children.OfType<Button>().Select(b => (string)b.Content).ToArray(), sent = sent };
    }
}
