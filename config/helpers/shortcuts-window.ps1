param(
    [ValidateSet('Editor', 'Save')][string]$Operation = 'Editor',
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [switch]$ValidateOnly,
    [switch]$NoShow
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
$editor = $null
$exitCode = 0
try {
    Add-Type -AssemblyName System.Web.Extensions
    $storageSource = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class ShortcutStorage
{
    public const int Limit = 262144;
    public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    public static JavaScriptSerializer Json()
    {
        return new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 64 };
    }
    public static Dictionary<string, object> Object(object value)
    {
        var result = value as Dictionary<string, object>;
        if (result == null) throw new InvalidDataException("需要 JSON 对象。");
        return result;
    }
    public static string String(Dictionary<string, object> data, string name)
    {
        object value;
        if (!data.TryGetValue(name, out value) || !(value is string))
            throw new InvalidDataException("缺少有效的 " + name + "。");
        return (string)value;
    }
    public static void Schema(Dictionary<string, object> data)
    {
        object schema;
        if (!data.TryGetValue("schema", out schema) || !(schema is int) || (int)schema != 1)
            throw new InvalidDataException("配置版本无法识别；未覆盖原配置。");
    }
    public static string Absolute(string path)
    {
        if (System.String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) ||
            path.StartsWith(@"\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0)
            throw new InvalidDataException("需要本地绝对路径。");
        return Path.GetFullPath(path);
    }
    public static void NoLinks(string path)
    {
        string current = path;
        while (!System.String.IsNullOrEmpty(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("配置路径不能经过链接或重解析点。");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            current = Path.GetDirectoryName(current);
        }
    }
    public static Dictionary<string, object> Request(string path)
    {
        path = Absolute(path);
        string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("请求文件必须位于临时目录。");
        NoLinks(path);
        if (!File.Exists(path) || new FileInfo(path).Length > 1048576)
            throw new InvalidDataException("请求文件不存在或过大。");
        var request = Object(Json().DeserializeObject(Utf8.GetString(File.ReadAllBytes(path)).TrimStart('\uFEFF')));
        Schema(request);
        return request;
    }
    static string Target(Dictionary<string, object> request)
    {
        string path = Absolute(String(request, "settings_path"));
        if (!System.String.Equals(Path.GetFileName(path), "mpvnet-user.json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("只允许保存 mpvnet-user.json。");
        if (!Directory.Exists(Path.GetDirectoryName(path)) || Directory.Exists(path))
            throw new InvalidDataException("配置目录不存在或目标不是文件。");
        NoLinks(path);
        return path;
    }
    static string ReadExisting(string path)
    {
        if (new FileInfo(path).Length > Limit) throw new InvalidDataException("原配置超过 256 KiB；未覆盖原配置。");
        string text = Utf8.GetString(File.ReadAllBytes(path));
        var document = Object(Json().DeserializeObject(text.TrimStart('\uFEFF')));
        Schema(document);
        object shortcuts;
        if (document.TryGetValue("shortcuts", out shortcuts) && !(shortcuts is Dictionary<string, object>))
            throw new InvalidDataException("原快捷键配置损坏；未覆盖原配置。");
        return text;
    }
    static bool Matches(string path, bool expectedExists, string expectedText)
    {
        if (File.Exists(path) != expectedExists) return false;
        return !expectedExists || System.String.Equals(ReadExisting(path), expectedText, StringComparison.Ordinal);
    }
    static string MutexName(string path)
    {
        using (var hash = SHA256.Create())
            return @"Local\MpvnetUserSettings-" + BitConverter.ToString(hash.ComputeHash(Utf8.GetBytes(path.ToUpperInvariant()))).Replace("-", "");
    }
    public static string Error(Exception error)
    {
        if (error is InvalidDataException) return error.Message;
        if (error is DecoderFallbackException) return "原配置不是有效的 UTF-8 文本；未覆盖原配置。";
        if (error is UnauthorizedAccessException) return "没有保存配置的权限，请检查文件权限后重试。";
        if (error is IOException) return "无法保存配置，请检查文件是否被其他程序占用后重试。";
        return "配置内容无效或嵌套过深；未覆盖原配置。";
    }
    public static object Save(Dictionary<string, object> request)
    {
        string temporary = null;
        bool entered = false;
        Mutex mutex = null;
        try
        {
            Schema(request);
            string path = Target(request);
            object exists;
            if (!request.TryGetValue("expected_exists", out exists) || !(exists is bool))
                throw new InvalidDataException("缺少原配置存在状态。");
            string expected = String(request, "expected_text");
            if (Utf8.GetByteCount(expected) > Limit) throw new InvalidDataException("原配置超过 256 KiB。");
            string documentText = String(request, "document_text").TrimStart('\uFEFF');
            byte[] bytes = Utf8.GetBytes(documentText);
            if (bytes.Length > Limit) throw new InvalidDataException("配置超过 256 KiB。");
            // Parse only to validate the envelope. Re-serialization would change
            // unknown high precision numbers and Microsoft JSON date strings.
            var document = Object(Json().DeserializeObject(documentText));
            Schema(document);
            object shortcuts;
            if (!document.TryGetValue("shortcuts", out shortcuts) || !(shortcuts is Dictionary<string, object>))
                throw new InvalidDataException("快捷键必须是 JSON 对象。");
            mutex = new Mutex(false, MutexName(path));
            try { entered = mutex.WaitOne(10000); } catch (AbandonedMutexException) { entered = true; }
            if (!entered) throw new IOException("配置正在保存，请稍后重试。");
            Target(request);
            if (!Matches(path, (bool)exists, expected)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            temporary = Path.Combine(Path.GetDirectoryName(path), ".mpvnet-user-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            Target(request);
            NoLinks(temporary);
            if (!Matches(path, (bool)exists, expected)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            if ((bool)exists) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
            temporary = null;
            return new { ok = true, error = "", conflict = false };
        }
        catch (Exception error) { return new { ok = false, error = Error(error), conflict = false }; }
        finally
        {
            if (temporary != null)
            {
                try { NoLinks(temporary); if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            }
            if (entered) mutex.ReleaseMutex();
            if (mutex != null) mutex.Dispose();
        }
    }
}
'@
    if ($Operation -eq 'Save') {
        Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition $storageSource
        $request = [ShortcutStorage]::Request($RequestPath)
        $result = [ShortcutStorage]::Save($request)
        $outputWriter.WriteLine([ShortcutStorage]::Json().Serialize($result))
        if (-not $result.ok) { $exitCode = 1 }
    } else {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $keySource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shortcut-key-names.cs'), $utf8)
        $references = @('System.Web.Extensions', 'System.Xaml',
            'System.Core',
            [Windows.Window].Assembly.Location, [Windows.Media.Brushes].Assembly.Location,
            [Windows.Threading.Dispatcher].Assembly.Location)
        $source = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Linq;
using System.Diagnostics;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Threading;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Windows.Threading;
using System.Windows.Interop;

public sealed class ShortcutEditor : Window
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h,int a,ref int v,int n);
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern uint ExtractIconEx(string f,int i,IntPtr[] l,IntPtr[] s,uint n);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    static readonly string[] Groups={"播放与定位","循环与标记","字幕与弹幕","音频","画面","截图与片段","窗口与界面","文件","工具与设置"};
    static readonly string[] FilterIds={"all","bound","unbound","modified"};
    static readonly string[] FilterLabels={"全部","已绑定","未绑定","已修改"};
    public sealed class ActionRow : INotifyPropertyChanged
    {
        public ShortcutEditor Owner;
        public string Id { get;set; } public string Group { get;set; } public string Label { get;set; }
        public string DefaultText { get;set; } public string CurrentText { get;set; } public string[] Defaults;
        string[] Keys { get { string[] keys;return Owner.draft.TryGetValue(Id,out keys)?keys:new string[0]; } }
        public bool IsModified { get { return !Keys.SequenceEqual(Defaults); } }
        public bool IsExpanded { get { return Owner.expandedId==Id; } }
        public bool CanEdit { get { return !Owner.saving; } }
        public bool CanRestore { get { return CanEdit&&IsModified; } }
        public bool IsUnbound { get { return Keys.Length==0; } }
        public bool RecordingOne { get { return Owner.captureId==Id&&Owner.capture==0; } }
        public bool RecordingTwo { get { return Owner.captureId==Id&&Owner.capture==1; } }
        public Visibility ModifiedVisibility { get { return IsModified?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility DetailVisibility { get { return IsExpanded?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility OneVisibility { get { return Keys.Length>0?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility TwoVisibility { get { return Keys.Length>1?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility SecondKeyVisibility { get { return Keys.Length>1||RecordingTwo?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility AddVisibility { get { return Keys.Length==1&&!RecordingTwo?Visibility.Visible:Visibility.Collapsed; } }
        public Visibility RecordingVisibility { get { return Owner.captureId==Id?Visibility.Visible:Visibility.Collapsed; } }
        public string[] DefaultDisplayKeys { get { return Defaults.Select(DisplayKey).ToArray(); } }
        public Visibility NoDefaultVisibility { get { return Defaults.Length==0?Visibility.Visible:Visibility.Collapsed; } }
        public string KeyOneText { get { return RecordingOne?"请按组合键…":Keys.Length>0?DisplayKey(Keys[0]):"+ 录入"; } }
        public string KeyTwoText { get { return RecordingTwo?"请按组合键…":Keys.Length>1?DisplayKey(Keys[1]):"+"; } }
        public string KeyOneName { get { return Label+"，按键 1，"+(Keys.Length>0?Keys[0]:"未绑定"); } }
        public string KeyTwoName { get { return Label+"，按键 2，"+(Keys.Length>1?Keys[1]:"添加第二个按键"); } }
        public string KeyOneId { get { return "Key_"+Id+"_0"; } } public string KeyTwoId { get { return "Key_"+Id+"_1"; } }
        public string DetailId { get { return "Detail_"+Id; } } public string ExpandId { get { return "Expand_"+Id; } }
        public string DetailName { get { return (IsExpanded?"收起":"展开")+Label+"的说明与默认键位"; } }
        public string DetailButtonText { get { return IsExpanded?"收起":"详情"; } }
        public string RemoveOneId { get { return "Remove_"+Id+"_0"; } } public string RemoveTwoId { get { return "Remove_"+Id+"_1"; } }
        public string ConflictId { get { return "Conflict_"+Id; } }
        public string ResetId { get { return "Reset_"+Id; } } public string ResetName { get { return "恢复"+Label+"的默认键位"; } }
        public string RemoveOneText { get { return Keys.Length>0?"移除 "+DisplayKey(Keys[0]):""; } }
        public string RemoveTwoText { get { return Keys.Length>1?"移除 "+DisplayKey(Keys[1]):""; } }
        public string RemoveOneName { get { return Label+"，"+RemoveOneText; } } public string RemoveTwoName { get { return Label+"，"+RemoveTwoText; } }
        public string Description { get { return Describe(Id); } }
        public string ConflictText { get { return Owner.RowConflict(Id); } }
        public Visibility ConflictVisibility { get { return ConflictText.Length>0?Visibility.Visible:Visibility.Collapsed; } }
        public event PropertyChangedEventHandler PropertyChanged;
        public void Notify() { if(PropertyChanged!=null) PropertyChanged(this,new PropertyChangedEventArgs("")); }
    }
    readonly Dictionary<string,object> request;
    readonly JavaScriptSerializer json=new JavaScriptSerializer { MaxJsonLength=1048576,RecursionLimit=64 };
    readonly Process parent; readonly string token;
    readonly List<ActionRow> rows=new List<ActionRow>(),visibleRows=new List<ActionRow>();
    readonly Dictionary<string,string[]> draft=new Dictionary<string,string[]>(StringComparer.Ordinal),baseline=new Dictionary<string,string[]>(StringComparer.Ordinal);
    readonly List<object> sent=new List<object>();
    readonly Dictionary<string,Button> categoryButtons=new Dictionary<string,Button>(),filterButtons=new Dictionary<string,Button>();
    readonly DispatcherTimer timer=new DispatcherTimer();
    Dictionary<string,object> latest;
    Grid root; ListBox actionList; StackPanel categoryPanel,filterPanel; TextBox search;
    TextBlock status,catalogCount,resultCount,unsavedSummary,searchPlaceholder; Border emptyState;
    Button restoreAll,reload,save,discard,clearSearch;
    NamedPipeClientStream pipe; StreamReader reader; StreamWriter writer; Task<string> read;
    string revision="",localError="",localNotice="",iconSource="fallback",category="all",activeFilter="all",expandedId="",captureId="";
    bool stale,saving,forceClose,validation,noShow; bool? validationResponse;
    int capture=-1,saveSerial=-1,pendingSerial=-1,sequence,discardChecks,resetConfirmations,focusRequest;
    DateTime saveStarted;
    public ShortcutEditor(Dictionary<string, object> input, bool validate, bool hidden)
    {
        request = input; validation = validate; noShow = hidden;
        ShortcutStorage.Schema(input);
        token = ShortcutStorage.String(input, "token");
        if (token.Length < 1 || token.Length > 256 || token.Any(Char.IsControl)) throw new InvalidDataException("无效的窗口连接。");
        if (ShortcutStorage.String(input, "script") != "user_shortcuts") throw new InvalidDataException("无效的快捷键入口。");
        object pid;
        if (!input.TryGetValue("parent_pid", out pid) || !(pid is int) || (int)pid <= 0) throw new InvalidDataException("播放器进程无效。");
        parent = Process.GetProcessById((int)pid);
        if (parent.HasExited) throw new InvalidDataException("播放器已退出。");
        string settings = ShortcutStorage.Absolute(ShortcutStorage.String(input, "settings_path"));
        if (!String.Equals(Path.GetFileName(settings), "mpvnet-user.json", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("配置文件名无效。");
        string pipeName = ShortcutStorage.String(input, "pipe");
        if (pipeName.StartsWith(@"\\.\pipe\", StringComparison.Ordinal)) pipeName = pipeName.Substring(9);
        if (pipeName.Length < 1 || pipeName.Length > 256 || pipeName.IndexOfAny(new[] { '\\', '/', ':', '\r', '\n', '\0' }) >= 0)
            throw new InvalidDataException("播放器连接无效。");
        Build();
        SetPlayerIcon();
        Closing += OnClosing;
        Closed += delegate { Finish(); };
        SourceInitialized += delegate {
            try {
                IntPtr handle = new WindowInteropHelper(this).Handle;
                int dark = 1, caption = 0x111111;
                if (DwmSetWindowAttribute(handle, 20, ref dark, 4) != 0) DwmSetWindowAttribute(handle, 19, ref dark, 4);
                DwmSetWindowAttribute(handle, 35, ref caption, 4);
            } catch { }
        };
        PreviewKeyDown += OnKey;
        PreviewGotKeyboardFocus += OnFocusChanging;
        timer.Interval = TimeSpan.FromMilliseconds(100);
        timer.Tick += Tick;
        if (!validation)
        {
            pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            pipe.Connect(5000);
            reader = new StreamReader(pipe, new UTF8Encoding(false, true));
            writer = new StreamWriter(pipe, new UTF8Encoding(false)); writer.AutoFlush = true;
            read = reader.ReadLineAsync();
            Send(new object[] { "observe_property", 1, "user-data/mpvnet/shortcuts" });
            Send(new object[] { "enable_event", "client-message" });
            Send(new object[] { "script-message-to", "user_shortcuts", "editor-ready", token });
            timer.Start();
        }
    }
    static string Text(Dictionary<string, object> data, string name)
    {
        object value; return data.TryGetValue(name, out value) && value is string ? (string)value : "";
    }
    static bool Flag(Dictionary<string, object> data, string name)
    {
        object value; return data.TryGetValue(name, out value) && value is bool && (bool)value;
    }
    static int Number(Dictionary<string, object> data, string name, int fallback)
    {
        object value; return data.TryGetValue(name, out value) && value is int ? (int)value : fallback;
    }
    static string[] Keys(object value)
    {
        var values = value as object[];
        if (values == null || values.Length > 2 || values.Any(x => !(x is string) || !ShortcutKeyNames.IsCanonical((string)x)))
            throw new InvalidDataException("快捷键格式无效，请重新载入。");
        return values.Cast<string>().ToArray();
    }
    static string ShowKeys(string[] keys) { return keys.Length == 0 ? "未绑定" : String.Join("  /  ", keys); }
    static string StateError(Dictionary<string, object> state)
    {
        string error = Text(state, "error");
        return error.Length > 0 && Flag(state, "repairable")
            ? "配置存在冲突；当前仍使用上一组有效快捷键。修改冲突项或恢复默认后保存。" : error;
    }
    bool ReadOnly { get { return latest != null && Text(latest, "error").Length > 0 && !Flag(latest, "repairable"); } }
    bool Dirty { get { return draft.Count != baseline.Count || draft.Any(x => !baseline.ContainsKey(x.Key) || !x.Value.SequenceEqual(baseline[x.Key])); } }

    void SetPlayerIcon()
    {
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromRgb(34,34,34)), new Pen(Brushes.White, 1), new RectangleGeometry(new Rect(1,3,14,10), 1, 1)));
        drawing.Children.Add(new GeometryDrawing(null, new Pen(Brushes.White, 1), Geometry.Parse("M3,6 L5,6 M7,6 L9,6 M11,6 L13,6 M3,8 L5,8 M7,8 L9,8 M11,8 L13,8 M4,10 L12,10")));
        var fallback = new DrawingImage(drawing); fallback.Freeze(); Icon = fallback;
        var large = new IntPtr[1]; var small = new IntPtr[1];
        try
        {
            // Only inspect the already verified parent player process. A request
            // never supplies an icon path or a second executable to inspect.
            string name = parent.ProcessName;
            if (!String.Equals(name, "mpvnet", StringComparison.OrdinalIgnoreCase) && !String.Equals(name, "mpv", StringComparison.OrdinalIgnoreCase)) return;
            string executable = parent.MainModule.FileName;
            if (!String.Equals(Path.GetFileNameWithoutExtension(executable), name, StringComparison.OrdinalIgnoreCase)) return;
            if (ExtractIconEx(executable, 0, large, small, 1) == 0) return;
            IntPtr handle = small[0] != IntPtr.Zero ? small[0] : large[0];
            if (handle == IntPtr.Zero) return;
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(handle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(32,32));
            bitmap.Freeze(); Icon = bitmap; iconSource = "parent-player";
        }
        catch { }
        finally
        {
            if (large[0] != IntPtr.Zero) DestroyIcon(large[0]);
            if (small[0] != IntPtr.Zero && small[0] != large[0]) DestroyIcon(small[0]);
        }
    }
    static int GroupRank(string group) { int rank=Array.IndexOf(Groups,group);return rank<0?Groups.Length:rank; }
    static string DisplayKey(string value)
    {
        if(value=="Space")return "空格";
        if(value.EndsWith("+Space",StringComparison.Ordinal))value=value.Substring(0,value.Length-5)+"空格";
        return value.Replace("Left","←").Replace("Right","→").Replace("PGUP","PageUp").Replace("PGDWN","PageDown");
    }
    static string Describe(string id)
    {
        switch(id)
        {
            case "playback.pause":return "切换播放与暂停。";
            case "subtitle.toggle":return "显示或隐藏普通字幕；弹幕由单独的动作控制。";
            case "playlist.toggle":return "显示或隐藏播放列表侧窗。";
            case "audio.mute":return "切换静音状态。";
            default:return "点击键帽录入组合键。最多可绑定两个按键；恢复此项会使用默认键位。";
        }
    }
    int DirtyCount { get { return rows.Count(x=>baseline.ContainsKey(x.Id)&&!draft[x.Id].SequenceEqual(baseline[x.Id])); } }
    int ModifiedCount { get { return rows.Count(x=>!draft[x.Id].SequenceEqual(x.Defaults)); } }
    ActionRow Find(string id) { return rows.FirstOrDefault(x=>x.Id==id); }
    bool InView(string id) { return visibleRows.Any(x=>x.Id==id); }
    void FocusControl(Control control)
    {
        if(control==null)return;
        if(control==search)focusRequest++;
        if(captureId.Length>0&&!IsCaptureTarget(control)){CancelCapture();RefreshEditor();}
        FocusManager.SetFocusedElement(root,control);
        if(!validation&&IsVisible)control.Focus();
    }
    void Build()
    {
        const string xaml=@"<Grid x:Name='Root' xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' FocusManager.IsFocusScope='True'>
<Grid.Resources>
<Style TargetType='Button'><Setter Property='MinHeight' Value='32'/><Setter Property='Padding' Value='10,4'/><Setter Property='Foreground' Value='#F0F1F2'/><Setter Property='Background' Value='#202328'/><Setter Property='BorderBrush' Value='#3C4248'/><Setter Property='BorderThickness' Value='1'/><Setter Property='HorizontalContentAlignment' Value='Center'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='Body' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='4' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Body' Property='BorderBrush' Value='#1287BB'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='Body' Property='BorderBrush' Value='#80C7E7'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='Body' Property='Background' Value='#243540'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Foreground' Value='#888888'/><Setter TargetName='Body' Property='Opacity' Value='0.55'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='Link' TargetType='Button' BasedOn='{StaticResource {x:Type Button}}'><Setter Property='Background' Value='Transparent'/><Setter Property='BorderBrush' Value='Transparent'/><Setter Property='Foreground' Value='#7CBAD7'/><Setter Property='FontSize' Value='12'/><Setter Property='Padding' Value='4,3'/></Style>
<Style x:Key='Keycap' TargetType='Button' BasedOn='{StaticResource {x:Type Button}}'><Setter Property='MinHeight' Value='29'/><Setter Property='VerticalAlignment' Value='Center'/><Setter Property='MinWidth' Value='38'/><Setter Property='MaxWidth' Value='148'/><Setter Property='Padding' Value='8,3'/><Setter Property='FontSize' Value='12'/><Setter Property='Background' Value='#25282D'/><Setter Property='BorderBrush' Value='#42474E'/></Style>
 <Style TargetType='ScrollBar'><Setter Property='Width' Value='14'/><Setter Property='Background' Value='#222222'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Track x:Name='PART_Track' Orientation='Vertical' IsDirectionReversed='True' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' ViewportSize='{TemplateBinding ViewportSize}' Value='{Binding Value,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}'><Track.DecreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageUpCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb MinHeight='24' Background='#707070'><Thumb.Template><ControlTemplate TargetType='Thumb'><Border x:Name='ThumbBody' Background='{TemplateBinding Background}' Margin='3,2' CornerRadius='4'/><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='ThumbBody' Property='Background' Value='#888888'/></Trigger><Trigger Property='IsDragging' Value='True'><Setter TargetName='ThumbBody' Property='Background' Value='#1287bb'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageDownCommand}' Focusable='False'><RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
<DataTemplate x:Key='ActionTemplate'><Border BorderBrush='#222326' BorderThickness='0,0,0,1' Margin='8,0'><Border x:Name='RowBody' Background='Transparent' BorderBrush='Transparent' BorderThickness='2,0,0,0' CornerRadius='4' Padding='6,0'><StackPanel>
<Grid MinHeight='45'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='74'/></Grid.ColumnDefinitions>
<Button Tag='detail' Style='{StaticResource Link}' Foreground='#F0F1F2' HorizontalContentAlignment='Stretch' Margin='0,4,8,4' AutomationProperties.AutomationId='{Binding DetailId}' AutomationProperties.Name='{Binding DetailName}' ToolTip='{Binding Label}'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><TextBlock Text='{Binding Label}' TextTrimming='CharacterEllipsis' VerticalAlignment='Center' FontSize='13'/><Ellipse Grid.Column='1' Width='5' Height='5' Fill='#54B1DA' Margin='8,0,2,0' Visibility='{Binding ModifiedVisibility}' VerticalAlignment='Center' ToolTip='与默认键位不同'/></Grid></Button>
<TextBlock x:Name='RecordingHint' Grid.Column='1' Text='Esc 取消' Foreground='#92969B' FontSize='11' VerticalAlignment='Center' Margin='6,0,10,0' IsHitTestVisible='False' Visibility='{Binding RecordingVisibility}'/>
<Button Grid.Column='2' Tag='key0' x:Name='KeyOne' Style='{StaticResource Keycap}' Margin='0,0,6,0' IsEnabled='{Binding CanEdit}' AutomationProperties.AutomationId='{Binding KeyOneId}' AutomationProperties.Name='{Binding KeyOneName}' ToolTip='{Binding KeyOneName}'><TextBlock Text='{Binding KeyOneText}' TextTrimming='CharacterEllipsis'/></Button>
<Button Grid.Column='3' Tag='key1' x:Name='KeyTwo' Style='{StaticResource Keycap}' Margin='0,0,6,0' IsEnabled='{Binding CanEdit}' Visibility='{Binding SecondKeyVisibility}' AutomationProperties.AutomationId='{Binding KeyTwoId}' AutomationProperties.Name='{Binding KeyTwoName}' ToolTip='{Binding KeyTwoName}'><TextBlock Text='{Binding KeyTwoText}' TextTrimming='CharacterEllipsis'/></Button>
<Button Grid.Column='4' Tag='key1' Style='{StaticResource Link}' Background='Transparent' BorderBrush='#383D44' Foreground='#92969B' MinHeight='28' VerticalAlignment='Center' Padding='7,3' Margin='0,0,6,0' IsEnabled='{Binding CanEdit}' Visibility='{Binding AddVisibility}' AutomationProperties.AutomationId='{Binding KeyTwoId}' AutomationProperties.Name='{Binding KeyTwoName}' ToolTip='添加第二个按键'><StackPanel Orientation='Horizontal'><Path Data='M1,5 L9,5 M5,1 L5,9' Stroke='{Binding Foreground,RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1.3' StrokeStartLineCap='Round' StrokeEndLineCap='Round' Width='10' Height='10' VerticalAlignment='Center' Margin='0,0,5,0'/><TextBlock Text='添加' FontSize='11' VerticalAlignment='Center'/></StackPanel></Button>
<Border Grid.Column='5' BorderBrush='#30353A' BorderThickness='1,0,0,0' Margin='6,8,0,8' Padding='6,0,0,0'><Button Tag='detail' Style='{StaticResource Link}' Foreground='#92969B' MinHeight='28' VerticalAlignment='Center' Padding='4,3' AutomationProperties.AutomationId='{Binding ExpandId}' AutomationProperties.Name='{Binding DetailName}' ToolTip='{Binding DetailName}'><StackPanel Orientation='Horizontal'><TextBlock Text='{Binding DetailButtonText}' FontSize='11' VerticalAlignment='Center'/><Path x:Name='DetailChevron' Data='M2,4 L6,8 L10,4' Stroke='{Binding Foreground,RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1.4' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round' Width='12' Height='12' VerticalAlignment='Center' Margin='5,0,0,0'/></StackPanel></Button></Border>
</Grid>
<StackPanel Visibility='{Binding DetailVisibility}' Margin='4,0,4,12'><TextBlock Text='{Binding Description}' Foreground='#A3ADB7' FontSize='12' TextWrapping='Wrap' Margin='0,2,0,9'/>
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
<WrapPanel VerticalAlignment='Top' Margin='0,0,12,0'><TextBlock Text='默认键位' Foreground='#92969B' FontSize='11' VerticalAlignment='Center' Margin='0,0,8,0'/><ItemsControl x:Name='DefaultKeycaps' ItemsSource='{Binding DefaultDisplayKeys}' MaxWidth='210' HorizontalAlignment='Left'><ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel><ItemsControl.ItemTemplate><DataTemplate><Border Background='#21262B' BorderBrush='#3B4249' BorderThickness='1' CornerRadius='4' MinHeight='29' Padding='7,2' Margin='0,0,6,0'><TextBlock Text='{Binding}' Foreground='#C0C8CF' FontSize='12' VerticalAlignment='Center'/></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl><TextBlock Text='未绑定' Visibility='{Binding NoDefaultVisibility}' Foreground='#92969B' FontSize='12' VerticalAlignment='Center'/></WrapPanel>
<WrapPanel Grid.Column='1' MaxWidth='280' HorizontalAlignment='Right' VerticalAlignment='Top'>
<Button Tag='conflict' Style='{StaticResource Link}' Content='查看占用动作' Visibility='{Binding ConflictVisibility}' Margin='0,0,6,4' AutomationProperties.AutomationId='{Binding ConflictId}' AutomationProperties.Name='查看占用动作'/>
<Button Tag='restore' Style='{StaticResource Link}' Content='恢复此项' Visibility='{Binding ModifiedVisibility}' IsEnabled='{Binding CanRestore}' BorderBrush='#3C4248' Foreground='#B0BBC4' Padding='8,3' MinHeight='29' Margin='0,0,6,4' AutomationProperties.AutomationId='{Binding ResetId}' AutomationProperties.Name='{Binding ResetName}'/>
<Button Tag='remove0' Style='{StaticResource Link}' Content='{Binding RemoveOneText}' Visibility='{Binding OneVisibility}' IsEnabled='{Binding CanEdit}' BorderBrush='#3C4248' Foreground='#B0BBC4' Padding='8,3' MinHeight='29' Margin='0,0,6,4' AutomationProperties.AutomationId='{Binding RemoveOneId}' AutomationProperties.Name='{Binding RemoveOneName}'/>
<Button Tag='remove1' Style='{StaticResource Link}' Content='{Binding RemoveTwoText}' Visibility='{Binding TwoVisibility}' IsEnabled='{Binding CanEdit}' BorderBrush='#3C4248' Foreground='#B0BBC4' Padding='8,3' MinHeight='29' Margin='0,0,0,4' AutomationProperties.AutomationId='{Binding RemoveTwoId}' AutomationProperties.Name='{Binding RemoveTwoName}'/>
</WrapPanel></Grid><TextBlock Text='{Binding ConflictText}' Foreground='#FFBB99' FontSize='12' TextWrapping='Wrap' Margin='0,5,0,0' Visibility='{Binding ConflictVisibility}'/></StackPanel>
</StackPanel></Border></Border><DataTemplate.Triggers><DataTrigger Binding='{Binding IsUnbound}' Value='True'><Setter TargetName='KeyOne' Property='Background' Value='Transparent'/><Setter TargetName='KeyOne' Property='BorderBrush' Value='#383D44'/><Setter TargetName='KeyOne' Property='Foreground' Value='#92969B'/></DataTrigger><DataTrigger Binding='{Binding IsExpanded}' Value='True'><Setter TargetName='DetailChevron' Property='RenderTransform'><Setter.Value><RotateTransform Angle='180' CenterX='6' CenterY='6'/></Setter.Value></Setter><Setter TargetName='RowBody' Property='Background' Value='#181E22'/><Setter TargetName='RowBody' Property='BorderBrush' Value='#1287BB'/></DataTrigger><DataTrigger Binding='{Binding RecordingOne}' Value='True'><Setter TargetName='KeyOne' Property='Background' Value='#123C50'/><Setter TargetName='KeyOne' Property='BorderBrush' Value='#1287BB'/><Setter TargetName='KeyOne' Property='Foreground' Value='#B4E8FF'/></DataTrigger><DataTrigger Binding='{Binding RecordingTwo}' Value='True'><Setter TargetName='KeyTwo' Property='Background' Value='#123C50'/><Setter TargetName='KeyTwo' Property='BorderBrush' Value='#1287BB'/></DataTrigger></DataTemplate.Triggers></DataTemplate>
</Grid.Resources>
<Grid.RowDefinitions><RowDefinition Height='74'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
<Grid Margin='22,0'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><StackPanel Orientation='Horizontal' VerticalAlignment='Center'><TextBlock Text='用户快捷键' FontSize='22' FontWeight='SemiBold'/><TextBlock x:Name='CatalogCount' Foreground='#92969B' FontSize='12' Margin='12,7,0,0'/></StackPanel><Border Grid.Column='1' BorderBrush='#3A3C40' BorderThickness='1' Background='#1E1F21' CornerRadius='4' Width='320' Height='36' VerticalAlignment='Center'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='30'/><ColumnDefinition Width='*'/><ColumnDefinition Width='28'/></Grid.ColumnDefinitions><Viewbox x:Name='SearchIcon' Width='18' Height='18' VerticalAlignment='Center' HorizontalAlignment='Center'><Canvas Width='24' Height='24'><Ellipse Width='14' Height='14' Canvas.Left='3' Canvas.Top='3' Stroke='#92969B' StrokeThickness='1.7'/><Line X1='15.1' Y1='15.1' X2='21' Y2='21' Stroke='#92969B' StrokeThickness='1.7' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/></Canvas></Viewbox><TextBox x:Name='Search' Grid.Column='1' AutomationProperties.AutomationId='Search' AutomationProperties.Name='搜索功能或按键' Background='Transparent' Foreground='#F0F1F2' BorderThickness='0' Padding='4,7' CaretBrush='White' FontSize='13'/><TextBlock x:Name='SearchPlaceholder' Grid.Column='1' Text='搜索功能或按键…' IsHitTestVisible='False' Foreground='#81868C' Margin='4,0' VerticalAlignment='Center' FontSize='13'/><Button x:Name='ClearSearch' Grid.Column='2' Style='{StaticResource Link}' Content='×' Padding='2' AutomationProperties.AutomationId='ClearSearch' AutomationProperties.Name='清除搜索' Visibility='Collapsed'/></Grid></Border></Grid>
<Grid Grid.Row='1'><Grid.ColumnDefinitions><ColumnDefinition Width='176'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions><Border BorderBrush='#2D2D2D' BorderThickness='0,1,1,0'><DockPanel Margin='8,10,8,8'><Button x:Name='ResetAll' DockPanel.Dock='Bottom' Style='{StaticResource Link}' Content='恢复全部默认键位' HorizontalContentAlignment='Left' Foreground='#92969B' FontSize='12' Margin='2,12,0,0' AutomationProperties.AutomationId='ResetAll' AutomationProperties.Name='恢复全部默认键位'/><ScrollViewer x:Name='CategoryScroll' VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled' Focusable='False'><StackPanel x:Name='Categories'/></ScrollViewer></DockPanel></Border><Grid Grid.Column='1'><Grid.RowDefinitions><RowDefinition Height='49'/><RowDefinition Height='*'/></Grid.RowDefinitions><Border BorderBrush='#2D2D2D' BorderThickness='0,1,0,1'><Grid Margin='14,0'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><StackPanel x:Name='Filters' Orientation='Horizontal' VerticalAlignment='Center'/><TextBlock x:Name='ResultCount' Grid.Column='1' Foreground='#81868C' FontSize='12' VerticalAlignment='Center'/></Grid></Border><Grid Grid.Row='1'>
<ListBox x:Name='Actions' KeyboardNavigation.TabNavigation='Continue' BorderThickness='0' Background='#111111' Foreground='#F0F1F2' ItemTemplate='{StaticResource ActionTemplate}' ScrollViewer.HorizontalScrollBarVisibility='Disabled' ScrollViewer.VerticalScrollBarVisibility='Auto' ScrollViewer.CanContentScroll='True' VirtualizingPanel.IsVirtualizing='True' VirtualizingPanel.IsVirtualizingWhenGrouping='True' VirtualizingPanel.VirtualizationMode='Recycling' AutomationProperties.AutomationId='Actions' AutomationProperties.Name='快捷键操作列表'><ListBox.ItemContainerStyle><Style TargetType='ListBoxItem'><Setter Property='Padding' Value='0'/><Setter Property='Margin' Value='0'/><Setter Property='HorizontalContentAlignment' Value='Stretch'/><Setter Property='IsTabStop' Value='False'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ListBoxItem'><ContentPresenter HorizontalAlignment='Stretch'/></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle><ListBox.GroupStyle><GroupStyle><GroupStyle.HeaderTemplate><DataTemplate><Border Background='#111111' BorderBrush='#232426' BorderThickness='0,0,0,1' Padding='18,8,12,7'><StackPanel Orientation='Horizontal'><TextBlock Text='{Binding Name}' Foreground='#92969B' FontSize='12'/><TextBlock Text='{Binding ItemCount}' Foreground='#747A81' Margin='9,0,0,0' FontSize='11'/></StackPanel></Border></DataTemplate></GroupStyle.HeaderTemplate></GroupStyle></ListBox.GroupStyle></ListBox>
<Border x:Name='EmptyState' Visibility='Collapsed' Background='#111111' Padding='30'><StackPanel VerticalAlignment='Center' HorizontalAlignment='Center'><TextBlock Text='没有找到匹配的操作' FontSize='15' Foreground='#E1E7EB' HorizontalAlignment='Center'/><TextBlock Text='试试其他关键词、分类或筛选条件。' Foreground='#92969B' FontSize='12' Margin='0,8,0,0' TextWrapping='Wrap' TextAlignment='Center'/></StackPanel></Border>
</Grid></Grid></Grid>
<Border Grid.Row='2' BorderBrush='#33363A' BorderThickness='0,1,0,0' Background='#151617' Padding='20,12'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><StackPanel Margin='0,0,20,0' VerticalAlignment='Center'><StackPanel Orientation='Horizontal'><TextBlock x:Name='UnsavedSummary' Foreground='#71BCDF' FontSize='13' FontWeight='SemiBold' Visibility='Collapsed' Margin='0,0,10,3'/><Button x:Name='Reload' Style='{StaticResource Link}' Content='重新载入' AutomationProperties.AutomationId='Reload' AutomationProperties.Name='重新载入并丢弃未保存更改' ToolTip='重新载入最新快捷键；未保存的修改会在确认后丢弃。' Visibility='Collapsed' MinHeight='24' Padding='2,0'/></StackPanel><TextBlock x:Name='Status' Foreground='#92969B' FontSize='12' TextWrapping='Wrap' AutomationProperties.LiveSetting='Polite'/></StackPanel><StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'><Button x:Name='Discard' Content='撤销未保存更改' Margin='0,0,8,0' AutomationProperties.AutomationId='Discard' AutomationProperties.Name='撤销未保存更改'/><Button x:Name='Save' Content='保存并应用' Background='#1287BB' BorderBrush='#1996CD' MinWidth='98' AutomationProperties.AutomationId='Save' AutomationProperties.Name='保存并应用快捷键'/></StackPanel></Grid></Border>
</Grid>";
        Title="快捷键";Width=960;Height=680;MinWidth=760;MinHeight=540;
        Background=new SolidColorBrush(Color.FromRgb(17,17,17));Foreground=Brushes.White;
        FontFamily=new FontFamily("Microsoft YaHei UI");FontSize=13;UseLayoutRounding=true;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        root=(Grid)XamlReader.Parse(xaml);Content=root;
        actionList=(ListBox)root.FindName("Actions");search=(TextBox)root.FindName("Search");
        categoryPanel=(StackPanel)root.FindName("Categories");filterPanel=(StackPanel)root.FindName("Filters");
        status=(TextBlock)root.FindName("Status");catalogCount=(TextBlock)root.FindName("CatalogCount");resultCount=(TextBlock)root.FindName("ResultCount");
        unsavedSummary=(TextBlock)root.FindName("UnsavedSummary");searchPlaceholder=(TextBlock)root.FindName("SearchPlaceholder");emptyState=(Border)root.FindName("EmptyState");
        restoreAll=(Button)root.FindName("ResetAll");reload=(Button)root.FindName("Reload");save=(Button)root.FindName("Save");discard=(Button)root.FindName("Discard");clearSearch=(Button)root.FindName("ClearSearch");
        AddCategory("all","全部功能");categoryPanel.Children.Add(new TextBlock{Text="功能分类",Foreground=new SolidColorBrush(Color.FromRgb(116,122,129)),FontSize=11,Margin=new Thickness(10,15,0,7)});
        foreach(string group in Groups)AddCategory(group,group);
        for(int i=0;i<FilterIds.Length;i++){string id=FilterIds[i];var button=new Button{Content=FilterLabels[i],Margin=new Thickness(0,0,4,0),Padding=new Thickness(10,4,10,4),Background=Brushes.Transparent,BorderBrush=Brushes.Transparent,FontSize=12};System.Windows.Automation.AutomationProperties.SetAutomationId(button,"Filter"+id);System.Windows.Automation.AutomationProperties.SetName(button,FilterLabels[i]+"快捷键");button.Click+=delegate{SetFilter(id);};filterButtons[id]=button;filterPanel.Children.Add(button);}
        search.TextChanged+=delegate{CancelCapture();RefreshRows();};clearSearch.Click+=delegate{search.Text="";FocusControl(search);};
        actionList.AddHandler(Button.ClickEvent,new RoutedEventHandler(RowClick),true);
        restoreAll.Click+=delegate{RestoreAll();};reload.Click+=delegate{Reload();};discard.Click+=delegate{UndoDraft();};save.Click+=delegate{Save();};
        RefreshRows();
    }
    void AddCategory(string id,string label)
    {
        var button=new Button{Background=Brushes.Transparent,BorderBrush=Brushes.Transparent,HorizontalContentAlignment=HorizontalAlignment.Stretch,Padding=new Thickness(8,6,8,6),Margin=new Thickness(0,0,0,3),MinHeight=36};
        var content=new Grid();content.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(18)});content.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});content.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
        var symbol=new System.Windows.Shapes.Path{Stroke=new SolidColorBrush(Color.FromRgb(146,150,155)),StrokeThickness=1.2,Width=14,Height=14,Stretch=Stretch.Uniform,VerticalAlignment=VerticalAlignment.Center,Data=Geometry.Parse(CategoryGeometry(id))};content.Children.Add(symbol);
        var text=new TextBlock{Text=label,Margin=new Thickness(7,0,4,0),VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=12};Grid.SetColumn(text,1);content.Children.Add(text);
        var count=new TextBlock{Name="Count",Foreground=new SolidColorBrush(Color.FromRgb(129,134,140)),FontSize=11,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(count,2);content.Children.Add(count);
        button.Content=content;button.ToolTip=label;System.Windows.Automation.AutomationProperties.SetAutomationId(button,"Category"+id);System.Windows.Automation.AutomationProperties.SetName(button,label);
        button.Click+=delegate{SetCategory(id);};categoryButtons[id]=button;categoryPanel.Children.Add(button);
    }
    static string CategoryGeometry(string group)
    {
        switch(group){
            case "播放与定位":return "M4,2 L13,8 L4,14 Z";
            case "循环与标记":return "M3,4 L13,4 L10,1 M13,12 L3,12 L6,15";
            case "字幕与弹幕":return "M1,3 L15,3 L15,13 L1,13 Z M4,7 L7,7 M9,7 L12,7 M4,10 L12,10";
            case "音频":return "M1,6 L4,6 L8,2 L8,14 L4,10 L1,10 Z M11,4 Q15,8 11,12";
            case "画面":return "M1,2 L15,2 L15,13 L1,13 Z M4,16 L12,16 M8,13 L8,16 M3,10 L6,6 L9,9 L12,5";
            case "截图与片段":return "M1,5 L4,5 L5,2 L11,2 L12,5 L15,5 L15,14 L1,14 Z M5,9 A3,3 0 1 1 11,9 A3,3 0 1 1 5,9";
            case "窗口与界面":return "M1,2 L15,2 L15,14 L1,14 Z M1,6 L15,6";
            case "文件":return "M1,3 L6,3 L8,5 L15,5 L15,14 L1,14 Z";
            case "工具与设置":return "M19.021,9.092 L19.460,10.550 L21.816,10.092 L21.816,13.908 L19.460,13.450 L19.021,14.908 L19.021,14.908 L18.301,16.250 L20.290,17.592 L17.592,20.290 L16.250,18.301 L14.908,19.021 L14.908,19.021 L13.450,19.460 L13.908,21.816 L10.092,21.816 L10.550,19.460 L9.092,19.021 L9.092,19.021 L7.750,18.301 L6.408,20.290 L3.710,17.592 L5.699,16.250 L4.979,14.908 L4.979,14.908 L4.540,13.450 L2.184,13.908 L2.184,10.092 L4.540,10.550 L4.979,9.092 L4.979,9.092 L5.699,7.750 L3.710,6.408 L6.408,3.710 L7.750,5.699 L9.092,4.979 L9.092,4.979 L10.550,4.540 L10.092,2.184 L13.908,2.184 L13.450,4.540 L14.908,4.979 L14.908,4.979 L16.250,5.699 L17.592,3.710 L20.290,6.408 L18.301,7.750 L19.021,9.092 Z M15.3,12 A3.3,3.3 0 1 1 8.7,12 A3.3,3.3 0 1 1 15.3,12 Z";
            default:return "M1,1 L6,1 L6,6 L1,6 Z M10,1 L15,1 L15,6 L10,6 Z M1,10 L6,10 L6,15 L1,15 Z M10,10 L15,10 L15,15 L10,15 Z";
        }
    }
    void SetCategory(string value)
    {
        if(saving||!categoryButtons.ContainsKey(value))return;
        CancelCapture();category=value;RefreshRows();FocusControl(categoryButtons[value]);
    }
    void SetFilter(string value)
    {
        if(saving||!filterButtons.ContainsKey(value))return;
        CancelCapture();activeFilter=value;RefreshRows();FocusControl(filterButtons[value]);
    }
    void CancelCapture()
    {
        focusRequest++;string old=captureId;captureId="";capture=-1;var row=Find(old);if(row!=null)row.Notify();
    }
    bool IsCaptureTarget(DependencyObject target)
    {
        return target!=null&&System.Windows.Automation.AutomationProperties.GetAutomationId(target)=="Key_"+captureId+"_"+capture;
    }
    void OnFocusChanging(object sender,KeyboardFocusChangedEventArgs e)
    {
        var target=e.NewFocus as DependencyObject;
        if(target==search)focusRequest++;
        if(captureId.Length>0&&!IsCaptureTarget(target)){CancelCapture();localError="";RefreshEditor();}
    }
    void RefreshRows()
    {
        string needle=search.Text.Trim();visibleRows.Clear();
        foreach(var row in rows){
            row.CurrentText=ShowKeys(draft[row.Id]);
            bool filter=activeFilter=="bound"?draft[row.Id].Length>0:activeFilter=="unbound"?draft[row.Id].Length==0:activeFilter=="modified"?row.IsModified:true;
            string haystack=row.Label+" "+row.Group+" "+row.DefaultText+" "+row.CurrentText+" "+String.Join(" ",row.DefaultDisplayKeys)+" "+String.Join(" ",draft[row.Id].Select(DisplayKey));
            if((category=="all"||row.Group==category)&&filter&&(needle.Length==0||haystack.IndexOf(needle,StringComparison.OrdinalIgnoreCase)>=0))visibleRows.Add(row);
        }
        visibleRows.Sort((a,b)=>{int rank=GroupRank(a.Group).CompareTo(GroupRank(b.Group));return rank!=0?rank:rows.IndexOf(a).CompareTo(rows.IndexOf(b));});
        if(captureId.Length>0&&!InView(captureId))CancelCapture();
        if(expandedId.Length>0&&!InView(expandedId))expandedId="";
        actionList.ItemsSource=visibleRows.ToArray();
        CollectionViewSource.GetDefaultView(actionList.ItemsSource).GroupDescriptions.Add(new PropertyGroupDescription("Group"));
        emptyState.Visibility=visibleRows.Count==0?Visibility.Visible:Visibility.Collapsed;
        resultCount.Text=visibleRows.Count+" 项";catalogCount.Text=rows.Count+" 项操作";
        searchPlaceholder.Visibility=search.Text.Length==0?Visibility.Visible:Visibility.Collapsed;
        clearSearch.Visibility=search.Text.Length>0?Visibility.Visible:Visibility.Collapsed;
        RefreshEditor();
    }
    string RowConflict(string id)
    {
        if(!draft.ContainsKey(id))return "";
        foreach(string key in draft[id]){
            var other=rows.FirstOrDefault(x=>x.Id!=id&&draft[x.Id].Contains(key));
            if(other!=null)return key+" 同时用于“"+other.Label+"”。请修改其中一项后保存。";
            if(draft[id].Count(x=>x==key)>1)return key+" 在此操作中重复。请移除一个按键后保存。";
        }
        return "";
    }
    string Conflict()
    {
        foreach(var row in rows){string text=RowConflict(row.Id);if(text.Length>0)return "“"+row.Label+"”："+text;}return "";
    }
    void RefreshEditor()
    {
        foreach(var row in rows)row.Notify();
        foreach(var pair in categoryButtons){
            bool active=category==pair.Key;var button=pair.Value;
            button.IsEnabled=!saving;button.Background=active?new SolidColorBrush(Color.FromRgb(20,43,53)):Brushes.Transparent;
            button.Foreground=active?Brushes.White:new SolidColorBrush(Color.FromRgb(185,188,193));
            button.BorderBrush=active?new SolidColorBrush(Color.FromRgb(18,135,187)):Brushes.Transparent;
            ((TextBlock)((Grid)button.Content).Children[2]).Text=(pair.Key=="all"?rows.Count:rows.Count(x=>x.Group==pair.Key)).ToString();
        }
        foreach(var pair in filterButtons){pair.Value.IsEnabled=!saving;pair.Value.Background=activeFilter==pair.Key?new SolidColorBrush(Color.FromRgb(36,53,64)):Brushes.Transparent;pair.Value.Foreground=activeFilter==pair.Key?Brushes.White:new SolidColorBrush(Color.FromRgb(157,162,168));}
        search.IsEnabled=!saving;clearSearch.IsEnabled=!saving;
        string conflict=Conflict(),stateError=latest==null?"":StateError(latest);
        status.Text=saving?"正在保存并应用…":stale?"其他播放器已更新快捷键。重新载入会在确认后丢弃未保存的更改。":localError.Length>0?localError:stateError.Length>0?stateError:conflict.Length>0?conflict:captureId.Length>0?"按下新组合键，Esc 取消录入。":localNotice.Length>0?localNotice:Dirty?"修改保留在此窗口，保存后会立即应用。":"键位与当前保存状态一致。";
        status.Foreground=!saving&&(localError.Length>0||stateError.Length>0||conflict.Length>0||stale)?new SolidColorBrush(Color.FromRgb(255,187,153)):new SolidColorBrush(Color.FromRgb(146,150,155));
        unsavedSummary.Text=DirtyCount+" 项未保存";unsavedSummary.Visibility=Dirty?Visibility.Visible:Visibility.Collapsed;
        save.Content=Dirty?"保存 "+DirtyCount+" 项":"保存并应用";
        save.IsEnabled=latest!=null&&Dirty&&!saving&&!stale&&!ReadOnly&&conflict.Length==0;
        discard.IsEnabled=Dirty&&!saving;reload.IsEnabled=latest!=null&&!saving;
        reload.Visibility=stale||ReadOnly||stateError.Length>0||localError.Length>0?Visibility.Visible:Visibility.Collapsed;
        restoreAll.IsEnabled=latest!=null&&!saving;
    }
    void RowClick(object sender,RoutedEventArgs e)
    {
        var button=e.OriginalSource as Button ?? e.Source as Button;if(button==null||!button.IsEnabled)return;
        var row=button.DataContext as ActionRow;if(row==null||!InView(row.Id))return;
        string action=button.Tag as string;
        if(action=="detail"){Expand(row.Id);e.Handled=true;return;}
        if(saving)return;
        if(action=="key0"||action=="key1")BeginCapture(row.Id,action=="key0"?0:1);
        else if(action=="remove0"||action=="remove1")ChangeKey(row.Id,action=="remove0"?0:1,null);
        else if(action=="restore")Restore(row.Id);
        else if(action=="conflict")LocateConflict(row.Id);
        e.Handled=true;
    }
    void Expand(string id)
    {
        if(!InView(id))return;CancelCapture();expandedId=expandedId==id?"":id;RefreshEditor();
    }
    void BeginCapture(string id,int index)
    {
        if(saving||!InView(id)||index<0||index>1||(index==1&&draft[id].Length==0))return;
        CancelCapture();captureId=id;capture=index;expandedId=id;localError="";localNotice="";RefreshEditor();FocusRowKey(id,index);
    }
    void FocusRowKey(string id,int index)
    {
        int ticket=++focusRequest;
        Action focus=delegate{if(ticket!=focusRequest||!InView(id))return;var button=Descendants<Button>(actionList).FirstOrDefault(x=>System.Windows.Automation.AutomationProperties.GetAutomationId(x)=="Key_"+id+"_"+index&&x.Visibility==Visibility.Visible);if(button!=null)FocusControl(button);};
        if(validation){LayoutValidation();focus();}else Dispatcher.BeginInvoke(DispatcherPriority.Loaded,focus);
    }
    void ChangeKey(string id,int index,string key)
    {
        if(saving||!InView(id)||!draft.ContainsKey(id))return;
        if(index<0||index>1||(key!=null&&!ShortcutKeyNames.IsCanonical(key))){localError="此按键无法使用，请重新录入。";RefreshEditor();return;}
        var keys=draft[id].ToList();
        if(index<keys.Count){if(key==null)keys.RemoveAt(index);else keys[index]=key;}else if(key!=null&&keys.Count<2)keys.Add(key);
        draft[id]=keys.ToArray();CancelCapture();localError="";localNotice="";RefreshRows();
        if(InView(id))FocusRowKey(id,Math.Min(index,Math.Max(0,draft[id].Length-1)));else FocusControl(filterButtons[activeFilter]);
    }
    void Restore(string id)
    {
        var row=Find(id);if(row==null||saving||!InView(id))return;
        draft[id]=row.Defaults.ToArray();CancelCapture();localError="";localNotice="";RefreshRows();
    }
    void LocateConflict(string id)
    {
        if(!draft.ContainsKey(id))return;
        var other=rows.FirstOrDefault(x=>x.Id!=id&&draft[x.Id].Any(key=>draft[id].Contains(key)));
        if(other==null)return;
        CancelCapture();category="all";activeFilter="all";search.Text="";expandedId=other.Id;RefreshRows();
        actionList.ScrollIntoView(other);FocusRowKey(other.Id,0);
    }
    bool Ask(string text,bool reset)
    {
        if(reset)resetConfirmations++;else discardChecks++;
        if(validation){bool answer=validationResponse.HasValue&&validationResponse.Value;validationResponse=null;return answer;}
        return MessageBox.Show(this,text,"快捷键",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)==MessageBoxResult.Yes;
    }
    void RestoreAll()
    {
        if(saving||latest==null||!Ask("要恢复全部默认键位吗？\n\n修改会先保留在草稿中，点击保存后才会应用。",true))return;
        CancelCapture();foreach(var row in rows)draft[row.Id]=row.Defaults.ToArray();localError="";localNotice="已将默认键位放入草稿；保存后应用。";RefreshRows();
    }
    void UndoDraft()
    {
        if(saving||!Dirty)return;
        CancelCapture();foreach(var pair in baseline)draft[pair.Key]=pair.Value.ToArray();localError="";localNotice="已撤销未保存的更改。";RefreshRows();
    }
    bool ConfirmDiscard(){if(saving)return false;return !Dirty||Ask("修改还没有保存。要丢弃这些修改吗？",false);}
    void Reload()
    {
        if(saving||latest==null||(Dirty&&!Ask("重新载入会丢弃未保存的更改。要继续吗？",false)))return;
        Adopt(latest);localNotice="已重新载入。";RefreshEditor();FocusControl(search);
    }
    void AcceptCapture(int vk,bool ctrl,bool alt,bool shift,bool windows)
    {
        if(captureId.Length==0||!InView(captureId)||saving){CancelCapture();return;}
        if(vk==27){CancelCapture();localError="";RefreshEditor();return;}
        if(vk==16||vk==17||vk==18||vk==160||vk==161||vk==162||vk==163||vk==164||vk==165)return;
        string name=windows?null:ShortcutKeyNames.FromVirtualKey(vk,ctrl,alt,shift);
        if(name==null){localError="此按键保留给窗口操作，请选择其他组合键。";RefreshEditor();return;}
        string id=captureId;int index=capture;ChangeKey(id,index,name);
    }
    void OnKey(object sender,KeyEventArgs e)
    {
        Key key=e.Key==Key.System?e.SystemKey:e.Key;
        if(captureId.Length>0){e.Handled=true;AcceptCapture(KeyInterop.VirtualKeyFromKey(key),(Keyboard.Modifiers&ModifierKeys.Control)!=0,(Keyboard.Modifiers&ModifierKeys.Alt)!=0,(Keyboard.Modifiers&ModifierKeys.Shift)!=0,(Keyboard.Modifiers&ModifierKeys.Windows)!=0);return;}
        if(key==Key.Escape){e.Handled=true;if(expandedId.Length>0){expandedId="";RefreshEditor();}else Close();}
        else if((Keyboard.Modifiers&ModifierKeys.Control)!=0&&(Keyboard.Modifiers&(ModifierKeys.Alt|ModifierKeys.Shift))==0&&key==Key.F){e.Handled=true;FocusControl(search);search.SelectAll();}
    }
    void LayoutValidation()
    {
        int width=Number(request,"validation_width",960),height=Number(request,"validation_height",680);
        root.Measure(new Size(width,height));root.Arrange(new Rect(0,0,width,height));root.UpdateLayout();
    }
    Button ControlById(string id)
    {
        LayoutValidation();return Descendants<Button>(root).FirstOrDefault(x=>System.Windows.Automation.AutomationProperties.GetAutomationId(x)==id&&VisibleInRoot(x));
    }
    bool Invoke(string id)
    {
        var button=ControlById(id);if(button==null||!button.IsEnabled)return false;
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent,button));LayoutValidation();return true;
    }
    public void State(Dictionary<string, object> state)
    {
        if (Text(state, "editor_token") != token || Number(state, "schema", -1) != 1) return;
        latest = state;
        int serial = Number(state, "save_serial", 0);
        bool completed = saving && serial > pendingSerial && !Flag(state, "saving");
        if (completed)
        {
            saving = false;
            string error = Text(state, "save_error");
            if (error.Length == 0) { Adopt(state); localNotice = "已保存并应用。"; }
            else { localError = error; if (Text(state, "revision") != revision) stale = true; }
        }
        else if (revision.Length == 0 || (!Dirty && !saving)) Adopt(state);
        else if (Text(state, "revision") != revision && !saving) stale = true;
        saveSerial = serial;
        if (!saving && Text(state, "error").Length > 0 && !(completed && Text(state, "save_error").Length > 0))
            localError = StateError(state);
        RefreshEditor();
    }
    void Adopt(Dictionary<string, object> state)
    {
        object raw; var updated = new List<ActionRow>();
        if (!state.TryGetValue("actions", out raw) || !(raw is object[])) throw new InvalidDataException("快捷键列表无效，请重新载入。");
        object editable;
        if (Flag(state, "repairable") && state.TryGetValue("editable_actions", out editable) && editable is object[])
            raw = editable;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var next = new Dictionary<string, string[]>();
        foreach (object value in (object[])raw)
        {
            var entry = ShortcutStorage.Object(value);
            string id = ShortcutStorage.String(entry, "id");
            if (id.Length == 0 || !ids.Add(id)) throw new InvalidDataException("快捷键操作重复，请重新载入。");
            object defaults, current;
            if (!entry.TryGetValue("default_keys", out defaults) || !entry.TryGetValue("keys", out current)) throw new InvalidDataException("快捷键列表不完整。");
            string[] defaultKeys = Keys(defaults), currentKeys = Keys(current);
            updated.Add(new ActionRow { Owner = this, Id = id, Group = Text(entry, "group"), Label = Text(entry, "label"), Defaults = defaultKeys, DefaultText = ShowKeys(defaultKeys), CurrentText = ShowKeys(currentKeys) });
            next[id] = currentKeys;
        }
        if(captureId.Length>0)FocusControl(search);
        CancelCapture();
        rows.Clear(); rows.AddRange(updated); draft.Clear(); baseline.Clear();
        foreach (var pair in next) { draft[pair.Key] = pair.Value.ToArray(); baseline[pair.Key] = pair.Value.ToArray(); }
        revision = Text(state, "revision"); stale = false; capture = -1; localNotice = ""; localError = StateError(state); RefreshRows();
    }
    void Save()
    {
        if (saving || stale || latest == null || ReadOnly || !Dirty || Conflict().Length > 0) return;
        var overrides = new Dictionary<string, object>();
        foreach (var row in rows) if (!draft[row.Id].SequenceEqual(row.Defaults)) overrides[row.Id] = draft[row.Id];
        CancelCapture(); saving = true; pendingSerial = saveSerial; saveStarted = DateTime.UtcNow; localError = ""; localNotice = "";
        Send(new object[] { "script-message-to", "user_shortcuts", "save", token, revision, json.Serialize(overrides) }); RefreshEditor();
    }
    void Send(object[] command)
    {
        sent.Add(command);
        if (!validation) writer.WriteLine(json.Serialize(new { command = command, request_id = ++sequence }));
    }
    void Tick(object sender, EventArgs e)
    {
        try
        {
            if (parent.HasExited) { forceClose = true; Close(); return; }
            int received = 0;
            while (read != null && read.IsCompleted && received++ < 64)
            {
                if (read.IsFaulted || read.Result == null) { forceClose = true; Close(); return; }
                var message = ShortcutStorage.Object(json.DeserializeObject(read.Result));
                string eventName = Text(message, "event");
                object data;
                if (eventName == "property-change" && Text(message, "name") == "user-data/mpvnet/shortcuts" && message.TryGetValue("data", out data) && data is Dictionary<string, object>) State((Dictionary<string, object>)data);
                else if (eventName == "client-message" && message.TryGetValue("args", out data) && data is object[])
                {
                    var args = (object[])data;
                    if (args.Length >= 2 && args[0] as string == "mpvnet-shortcuts-close" && args[1] as string == token) { forceClose = true; Close(); return; }
                    if (args.Length >= 2 && args[0] as string == "mpvnet-shortcuts-show" && args[1] as string == token && !noShow)
                    { if (!IsVisible) Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
                }
                else if (eventName == "shutdown") { forceClose = true; Close(); return; }
                read = reader.ReadLineAsync();
            }
            if (saving && DateTime.UtcNow.Subtract(saveStarted).TotalSeconds > 15)
            { saving = false; localError = "保存未收到完成结果。请重新载入以确认当前设置。"; stale = true; RefreshEditor(); }
        }
        catch (Exception) { localError = "播放器连接已中断，请关闭此窗口后重新打开。"; forceClose = true; Close(); }
    }
    void OnClosing(object sender, CancelEventArgs e)
    {
        if (!forceClose && saving) { e.Cancel = true; RefreshEditor(); return; }
        if (!forceClose && !ConfirmDiscard()) { e.Cancel = true; return; }
        if (!validation) { try { Send(new object[] { "script-message-to", "user_shortcuts", "editor-close", token }); } catch { } }
        if (Application.Current != null) Dispatcher.BeginInvoke(new Action(delegate { Application.Current.Shutdown(); }));
    }
    public void Finish()
    {
        timer.Stop();
        if (pipe != null) { pipe.Dispose(); pipe = null; }
        if (parent != null) parent.Dispose();
    }
    public void Run()
    {
        if (noShow) { new Application().Run(); }
        else { new Application().Run(this); }
    }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(root, i);
            if (child is T) yield return (T)child;
            foreach (T nested in Descendants<T>(child)) yield return nested;
        }
    }
    bool VisibleInRoot(DependencyObject element)
    {
        while(element!=null&&element!=root){
            var ui=element as UIElement;if(ui!=null&&ui.Visibility!=Visibility.Visible)return false;
            element=VisualTreeHelper.GetParent(element);
        }return true;
    }
    public object Validate()
    {
        object sample;if(request.TryGetValue("validation_state",out sample))State(ShortcutStorage.Object(sample));LayoutValidation();
        var closeAttempts=new List<bool>();var clicks=new List<object>();object steps;
        if(request.TryGetValue("validation_steps",out steps)&&steps is object[]){
            foreach(object step in (object[])steps){
                var item=ShortcutStorage.Object(step);string action=Text(item,"action");
                if(action=="state")State(ShortcutStorage.Object(item["state"]));
                else if(action=="search"){search.Text=Text(item,"value");FocusControl(search);}
                else if(action=="focus-search")FocusControl(search);
                else if(action=="category")Invoke("Category"+Text(item,"value"));
                else if(action=="filter")Invoke("Filter"+Text(item,"value"));
                else if(action=="select"){string id=Text(item,"id");if(InView(id)){expandedId=id;actionList.ScrollIntoView(Find(id));RefreshEditor();LayoutValidation();}}
                else if(action=="key")ChangeKey(Text(item,"id").Length>0?Text(item,"id"):expandedId,Number(item,"index",0),Text(item,"key"));
                else if(action=="clear")ChangeKey(Text(item,"id").Length>0?Text(item,"id"):expandedId,Number(item,"index",0),null);
                else if(action=="capture")BeginCapture(Text(item,"id"),Number(item,"index",0));
                else if(action=="virtual-key")AcceptCapture(Number(item,"vk",0),Flag(item,"ctrl"),Flag(item,"alt"),Flag(item,"shift"),Flag(item,"windows"));
                else if(action=="restore-all"){validationResponse=Flag(item,"confirm");Invoke("ResetAll");}
                else if(action=="undo")Invoke("Discard");
                else if(action=="reload"){validationResponse=Flag(item,"confirm");Reload();}
                else if(action=="save")Invoke("Save");
                else if(action=="click"){validationResponse=Flag(item,"confirm");string id=Text(item,"id");clicks.Add(new{id=id,invoked=Invoke(id)});}
                else if(action=="close-attempt"){var args=new CancelEventArgs();OnClosing(this,args);closeAttempts.Add(args.Cancel);}
                LayoutValidation();
            }
        }
        bool bounds=true;var controlBounds=new Dictionary<string,object>();
        foreach(FrameworkElement control in new FrameworkElement[]{search,(FrameworkElement)root.FindName("CategoryScroll"),filterPanel,actionList,status,discard,save}){
            Point p=control.TranslatePoint(new Point(0,0),root);
            bool inside=p.X>=0&&p.Y>=0&&p.X+control.ActualWidth<=root.ActualWidth+1&&p.Y+control.ActualHeight<=root.ActualHeight+1;
            bounds&=inside&&control.ActualWidth>0&&control.ActualHeight>0;
            controlBounds[control.Name]=new{x=p.X,y=p.Y,width=control.ActualWidth,height=control.ActualHeight};
        }
        var controls=Descendants<Button>(actionList).Where(x=>VisibleInRoot(x)).Select(x=>new{
            id=System.Windows.Automation.AutomationProperties.GetAutomationId(x),name=System.Windows.Automation.AutomationProperties.GetName(x),
            enabled=x.IsEnabled,tooltip=x.ToolTip as string,text=x.Content is TextBlock?((TextBlock)x.Content).Text:x.Content as string,
            height=x.ActualHeight,vertical_alignment=x.VerticalAlignment.ToString(),background=x.Background.ToString(),foreground=x.Foreground.ToString(),border=x.BorderBrush.ToString()}).ToArray();
        bool rowBounds=true;
        foreach(var button in Descendants<Button>(actionList).Where(x=>VisibleInRoot(x)&&x.ActualWidth>0)){
            Point p=button.TranslatePoint(new Point(0,0),actionList);rowBounds&=p.X>=-1&&p.X+button.ActualWidth<=actionList.ActualWidth+1;
        }
        var focused=FocusManager.GetFocusedElement(root) as DependencyObject;
        var scrollStyle=(Style)root.FindResource(typeof(ScrollBar));
        var bar=new ScrollBar{Style=scrollStyle,Orientation=Orientation.Vertical,Minimum=0,Maximum=100,ViewportSize=10,LargeChange=10,Value=20,Height=120};
        bar.ApplyTemplate();bar.Measure(new Size(14,120));bar.Arrange(new Rect(0,0,14,120));bar.UpdateLayout();
        var track=(Track)bar.Template.FindName("PART_Track",bar);double beforePage=bar.Value;
        ScrollBar.PageDownCommand.Execute(null,bar);double afterPage=bar.Value;ScrollBar.PageUpCommand.Execute(null,bar);double restoredPage=bar.Value;
        double beforeDrag=bar.Value;track.Thumb.RaiseEvent(new DragStartedEventArgs(0,0){RoutedEvent=Thumb.DragStartedEvent});
        track.Thumb.RaiseEvent(new DragDeltaEventArgs(0,10){RoutedEvent=Thumb.DragDeltaEvent});track.Thumb.RaiseEvent(new DragCompletedEventArgs(0,10,false){RoutedEvent=Thumb.DragCompletedEvent});
        var listBars=Descendants<ScrollBar>(actionList).Where(x=>x.Orientation==Orientation.Vertical).ToArray();
        var result=new Dictionary<string,object>();
        result["ok"]=true;result["shown"]=IsVisible;result["bounds_valid"]=bounds;result["bounds"]=controlBounds;result["row_controls_fit"]=rowBounds;
        result["rows"]=rows.Select(x=>new{id=x.Id,label=x.Label,defaults=x.Defaults,keys=draft[x.Id],modified=x.IsModified}).ToArray();
        result["default_keycaps"]=Descendants<ItemsControl>(actionList).Where(x=>x.Name=="DefaultKeycaps"&&VisibleInRoot(x)).Select(x=>new{id=((ActionRow)x.DataContext).Id,texts=x.Items.Cast<string>().ToArray()}).ToArray();
        result["recording_hints"]=Descendants<TextBlock>(actionList).Where(x=>x.Name=="RecordingHint"&&VisibleInRoot(x)).Select(x=>new{id=((ActionRow)x.DataContext).Id,text=x.Text,y=x.TranslatePoint(new Point(0,0),actionList).Y,height=x.ActualHeight}).ToArray();
        result["row_heights"]=Descendants<Border>(actionList).Where(x=>x.Name=="RowBody"&&VisibleInRoot(x)).ToDictionary(x=>((ActionRow)x.DataContext).Id,x=>x.ActualHeight);

        result["visible_order"]=visibleRows.Select(x=>x.Id).ToArray();result["visible_rows"]=visibleRows.Count;
        result["dirty"]=Dirty;result["dirty_count"]=DirtyCount;result["modified_count"]=ModifiedCount;result["can_save"]=save.IsEnabled;result["save_label"]=save.Content;
        result["stale"]=stale;result["saving"]=saving;result["status"]=status.Text;result["status_color"]=status.Foreground.ToString();result["commands"]=sent.ToArray();result["revision"]=revision;
        result["close_enabled"]=!saving;result["close_attempts"]=closeAttempts.ToArray();result["discard_checks"]=discardChecks;result["reset_confirmations"]=resetConfirmations;
        result["categories"]=categoryButtons.ToDictionary(x=>x.Key,x=>x.Key=="all"?rows.Count:rows.Count(row=>row.Group==x.Key));result["category"]=category;result["filter"]=activeFilter;
        result["capture_id"]=captureId;result["capture_index"]=capture;result["expanded_id"]=expandedId;result["empty_visible"]=emptyState.Visibility==Visibility.Visible;
        result["focus_id"]=focused==null?"":System.Windows.Automation.AutomationProperties.GetAutomationId(focused);
        result["reload_visible"]=reload.Visibility==Visibility.Visible;result["controls"]=controls;result["clicks"]=clicks.ToArray();
        result["tab_navigation"]=KeyboardNavigation.GetTabNavigation(actionList).ToString();
        result["has_icon"]=Icon!=null;result["icon_source"]=iconSource;result["font"]=FontFamily.Source;
        result["window_size"]=new{width=Width,height=Height,min_width=MinWidth,min_height=MinHeight};
        result["labels"]=new[]{Title,"用户快捷键","全部功能","已绑定","未绑定","已修改","恢复此项","恢复全部默认键位","撤销未保存更改","保存并应用"};
        result["scrollbar"]=new{background=bar.Background.ToString(),width=bar.Width,thumb=track.Thumb!=null,page_up=track.DecreaseRepeatButton.Command==ScrollBar.PageUpCommand,page_down=track.IncreaseRepeatButton.Command==ScrollBar.PageDownCommand,page_changed=afterPage>beforePage,page_restored=restoredPage==beforePage,thumb_changed=bar.Value>beforeDrag,list_uses_style=listBars.Length>0&&listBars.All(x=>x.Style==scrollStyle)};
        object keyCases;if(request.TryGetValue("validation_key_cases",out keyCases)&&keyCases is object[])
            result["key_names"]=((object[])keyCases).Select(value=>{var item=ShortcutStorage.Object(value);return ShortcutKeyNames.FromVirtualKey(Number(item,"vk",0),Flag(item,"ctrl"),Flag(item,"alt"),Flag(item,"shift"));}).ToArray();
        return result;
    }
}
'@
        $storageBody = $storageSource -replace '(?m)^using [^;]+;\r?\n', ''
        Add-Type -ReferencedAssemblies $references -TypeDefinition ($source + "`n" + $keySource + "`n" + $storageBody)
        $request = [ShortcutStorage]::Request($RequestPath)
        $editor = New-Object ShortcutEditor($request, [bool]$ValidateOnly, [bool]$NoShow)
        if ($ValidateOnly) { $result = $editor.Validate() }
        else { $editor.Run(); $result = @{ok = $true} }
        $outputWriter.WriteLine([ShortcutStorage]::Json().Serialize($result))
    }
} catch {
    $message = $_.Exception.Message
    if ($_.Exception.InnerException) { $message = $_.Exception.InnerException.Message }
    $outputWriter.WriteLine((@{ok = $false; error = $message; conflict = $false} | ConvertTo-Json -Compress))
    $exitCode = 1
} finally {
    if ($editor) { $editor.Finish() }
    $outputWriter.Dispose()
}
exit $exitCode
