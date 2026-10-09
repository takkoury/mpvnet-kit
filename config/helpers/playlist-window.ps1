param(
    [string]$PayloadPath = '',
    [int]$WaitPid = 0,
    [switch]$NoShow,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
if ($WaitPid -gt 0) {
    try {
        $waitProcess = [Diagnostics.Process]::GetProcessById($WaitPid)
        [void]$waitProcess.WaitForExit(2500)
        $waitProcess.Dispose()
    } catch {}
    $outputWriter.WriteLine('{"ok":true}')
    $outputWriter.Dispose()
    exit 0
}

$phase = 'input'
$parentProcess = $null
$pipe = $null
$form = $null
$timer = $null
$context = $null
$script:exiting = $false
$script:desiredVisible = $false
[object[]]$script:playlist = @()
$script:playlistPosition = -1
$script:fullscreen = $false
$script:dragging = $false
$script:renderDirty = $false
$script:rendering = $false
$script:dropTargetId = ''
$script:dropAfter = $false
$script:lastSignature = ''
$script:requestId = 0
$script:receivedPlaylist = $false
$script:sentReady = $false
$script:searching = $false
$script:hoverId = ''
$follower = $null
$tip = $null
$keyFilter = $null
$scroll = $null
$script:validationActions = New-Object 'Collections.Generic.List[object]'

function Send-Command([object[]]$command) {
    $script:requestId++
    $writer.WriteLine((@{command = $command; request_id = $script:requestId} | ConvertTo-Json -Compress -Depth 8))
}

function Send-Action([string]$action, [string]$id = '', [string]$target = '', [string]$side = '') {
    if ($ValidateOnly) {
        $script:validationActions.Add(@{action = $action; id = $id; target = $target; side = $side})
        return
    }
    Send-Command @('script-message-to', [string]$payload.script, 'action', [string]$payload.token, $action, $id, $target, $side)
}

function Safe-Label($entry) {
    $value = if ($entry.title) { [string]$entry.title } else { [string]$entry.filename }
    if ($value -match '^[\w+.-]+://') {
        $value = ($value -split '[?#]', 2)[0].TrimEnd('/')
        try {
            $uri = New-Object Uri($value)
            $value = [Uri]::UnescapeDataString(($uri.AbsolutePath.TrimEnd('/') -split '/')[-1])
            if (-not $value) { $value = $uri.Host }
        } catch { $value = ($value -split '/')[-1] }
    } elseif (-not $entry.title) {
        $value = ($value -split '[/\\]')[-1]
    }
    $value = [regex]::Replace($value, '[\x00-\x1f]', ' ').Trim()
    if (-not $value) { $value = 'Media' }
    return $value
}

function Render-Queue {
    if ($script:dragging) { $script:renderDirty = $true; return }
    $needle = if ($script:searching) { $filter.Text.Trim() } else { '' }
    $rows = New-Object 'Collections.Generic.List[object]'
    for ($i = 0; $i -lt $script:playlist.Count; $i++) {
        $entry = $script:playlist[$i]
        $label = Safe-Label $entry
        if (-not $needle -or $label.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $rows.Add(@{id = [string]$entry.id; index = $i; label = $label; entry = $entry})
        }
    }
    $rowsById = @{}
    foreach ($row in $rows) { $rowsById[$row.id] = $row }
    $signature = (@($rows | ForEach-Object { $_.id + ':' + $_.label }) -join "`n")
    $counter.Text = if ($script:playlist.Count -eq 0) { '0 / 0' } elseif ($script:searching) { '{0} / {1}' -f $rows.Count, $script:playlist.Count } else { '{0:00} / {1:00}' -f ([Math]::Max(0, $script:playlistPosition + 1)), $script:playlist.Count }
    $script:rendering = $true
    try {
        if ($signature -ne $script:lastSignature) {
            $selected = @($list.SelectedItems | ForEach-Object { [string]$_.Tag.id })
            $topId = if ($list.TopItem) { [string]$list.TopItem.Tag.id } else { '' }
            $list.BeginUpdate()
            try {
                $list.Items.Clear()
                foreach ($row in $rows) {
                    $item = New-Object Windows.Forms.ListViewItem('')
                    [void]$item.SubItems.Add($row.label)
                    $item.Tag = $row
                    [void]$list.Items.Add($item)
                    if ($selected -contains $row.id) { $item.Selected = $true }
                }
                $newTop = @($list.Items | Where-Object { $_.Tag.id -eq $topId })
                if ($newTop.Count) { $list.TopItem = $newTop[0] }
            } finally { $list.EndUpdate() }
            $script:lastSignature = $signature
        }
        # Current changes are repainted without rebuilding or scrolling the view.
        foreach ($item in $list.Items) {
            if ($rowsById.ContainsKey([string]$item.Tag.id)) { $item.Tag = $rowsById[[string]$item.Tag.id] }
        }
        $list.FitTitleColumn()
        $list.Invalidate()
    } finally { $script:rendering = $false; $script:renderDirty = $false }
}

function Invalidate-HoverRow([string]$id) {
    if (-not $id) { return }
    foreach ($row in $list.Items) {
        if ([string]$row.Tag.id -eq $id) { $list.Invalidate($row.Bounds); return }
    }
}

function Hide-Window {
    $script:desiredVisible = $false
    if ($keyFilter) { $keyFilter.ReleaseAll() }
    if ($tip) { $tip.Hide() }
    if ($follower) { $follower.UpdatePolicy($false, $script:fullscreen) }
    $form.Hide()
    if (-not $ValidateOnly -and -not $script:exiting) {
        Send-Command @('script-message-to', [string]$payload.script, 'window-hidden', [string]$payload.token)
    }
}

function Set-SearchMode([bool]$enabled) {
    if ($keyFilter) { $keyFilter.ReleaseAll(); $keyFilter.SearchActive = $enabled }
    $script:searching = $enabled
    $filter.Visible = $enabled
    $counter.Dock = if ($enabled) { 'Right' } else { 'Fill' }
    $counter.TextAlign = if ($enabled) { 'MiddleRight' } else { 'MiddleCenter' }
    $counter.ForeColor = if ($enabled) { [Drawing.Color]::FromArgb(18, 135, 187) } else { [Drawing.Color]::FromArgb(155, 163, 177) }
    if ($enabled) { $counter.Width = 90; [void]$filter.Focus() }
    else { $filter.Text = ''; [void]$list.Focus() }
    Render-Queue
}

function Tooltip-Text($entry) {
    $name = [string]$entry.filename
    if ($name -match '^[\w+.-]+://') { return (Safe-Label $entry) + [Environment]::NewLine + $name }
    try {
        if (-not [IO.Path]::IsPathRooted($name) -and $payload.working_directory) { $name = Join-Path ([string]$payload.working_directory) $name }
        return [IO.Path]::GetFullPath($name)
    } catch { return $name }
}

function Clear-DropMarker {
    $script:dropTargetId = ''
    $list.InsertionMark.Index = -1
    $list.Invalidate()
}

function Exit-Window {
    $script:exiting = $true
    if ($keyFilter) { $keyFilter.ReleaseAll() }
    # A GUI owner may be synchronously waiting for mpv shutdown. Detach this
    # helper's own window before disposal to avoid cross-process owner messages.
    if ($form -and $form.IsHandleCreated) {
        [void][PlaylistNative]::SetWindowLongPtr($form.Handle, -8, [IntPtr]::Zero)
    }
    if ($tip) { $tip.Hide() }
    if ($context) { $context.ExitThread() }
}

try {
    if (-not [IO.Path]::IsPathRooted($PayloadPath)) { throw 'payload' }
    $fullPath = [IO.Path]::GetFullPath($PayloadPath)
    if ([IO.Path]::GetDirectoryName($fullPath).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($fullPath) -notmatch '^mpvnet-playlist-[\d-]+\.json$') { throw 'payload' }
    $payload = [IO.File]::ReadAllText($fullPath, $utf8) | ConvertFrom-Json
    [IO.File]::Delete($fullPath)
    if ([string]$payload.token -notmatch '^[\d-]+$' -or [string]$payload.script -notmatch '^[\w-]+$') { throw 'identity' }
    if (-not $ValidateOnly) {
        $parentProcess = [Diagnostics.Process]::GetProcessById([int]$payload.parent_pid)
        if ($parentProcess.HasExited) { exit 0 }
    }
    $script:desiredVisible = [bool]$payload.visible
    $phase = 'window'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;
public class PlaylistForm : Form {
    public PlaylistFollower Follower;
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x214 && Follower != null) {
            PlaylistNative.Rect bounds = (PlaylistNative.Rect)Marshal.PtrToStructure(m.LParam, typeof(PlaylistNative.Rect));
            Follower.RememberWidth(bounds.Right - bounds.Left);
            bounds = Follower.GetBounds();
            Marshal.StructureToPtr(bounds, m.LParam, false); m.Result = new IntPtr(1); return;
        }
        base.WndProc(ref m);
        if (m.Msg == 0x84) {
            int hit = m.Result.ToInt32();
            if (hit == 13 || hit == 16) m.Result = new IntPtr(10);
            else if (hit == 14 || hit == 17) m.Result = new IntPtr(11);
            else if (hit == 12 || hit == 15 || hit == 2) m.Result = new IntPtr(1);
        }
    }
}
public class PlaylistOwner : IWin32Window {
    public IntPtr Handle { get; private set; }
    public PlaylistOwner(IntPtr handle) { Handle = handle; }
}
public sealed class PlaylistList : ListView {
    [StructLayout(LayoutKind.Sequential)] struct NativeStyles { public uint OldStyle, NewStyle; }
    bool fitting, fitPosted;
    int wheelCarry;
    public event Action ViewportChanged;
    public PlaylistList() { DoubleBuffered = true; }
    protected override void OnHandleCreated(EventArgs args) {
        base.OnHandleCreated(args);
        PlaylistNative.SendMessage(Handle,0x1036,new IntPtr(0x10000),new IntPtr(0x10000));
        if (SmallImageList != null) {
            uint dpi=PlaylistNative.GetDpiForWindow(Handle);if(dpi==0)dpi=96;
            SmallImageList.ImageSize=new Size(1,(int)Math.Round(32*dpi/96.0));
        }
    }
    public void FitTitleColumn() {
        if (fitting || !IsHandleCreated || Columns.Count < 2) return;
        fitting = true;
        try {
            PlaylistNative.Rect client;
            if ((PlaylistNative.GetWindowLongPtr(Handle,-16).ToInt64() & 0x200000) != 0)
                PlaylistNative.ShowScrollBar(Handle,1,false);
            if (!PlaylistNative.GetClientRect(Handle,out client)) return;
            int width = client.Right-client.Left;
            int titleWidth=Math.Max(80,width-Columns[0].Width-6);
            if (Columns[1].Width != titleWidth) Columns[1].Width=titleWidth;
            // Updating a column can recreate both native bars. Reconcile after
            // that update, with the full client width already used for fitting.
            if (Columns[0].Width+Columns[1].Width <= width &&
                (PlaylistNative.GetWindowLongPtr(Handle,-16).ToInt64() & 0x300000) != 0)
                PlaylistNative.ShowScrollBar(Handle,3,false);
        } finally { fitting = false; }
        if (ViewportChanged != null) ViewportChanged();
    }
    void ScheduleViewport() {
        if (fitting || fitPosted || !IsHandleCreated || IsDisposed) return;
        fitPosted = true;
        // Finish the native resize before reconciling common-control extents.
        BeginInvoke(new Action(delegate { fitPosted=false; if (!IsDisposed) FitTitleColumn(); }));
    }
    protected override void OnResize(EventArgs args) { base.OnResize(args); ScheduleViewport(); }
    protected override void WndProc(ref Message message) {
        // This borderless list uses its own scrollbar. Internal common-control
        // updates can bypass STYLECHANGING; reserve no native nonclient bar area.
        if (message.Msg==0x83) { message.Result=IntPtr.Zero;return; }
        if (message.Msg==0x7C && message.WParam.ToInt64()==-16 && message.LParam!=IntPtr.Zero) {
            base.WndProc(ref message);
            NativeStyles styles=(NativeStyles)Marshal.PtrToStructure(message.LParam,typeof(NativeStyles));
            styles.NewStyle &= ~0x300000u;
            Marshal.StructureToPtr(styles,message.LParam,false);
            return;
        }
        // A hidden native bar must not determine whether the list accepts wheel
        // input. Handle it once through the same documented scroll command.
        if (message.Msg==0x20A) {
            WheelScroll((short)(message.WParam.ToInt64() >> 16));
            message.Result=IntPtr.Zero;return;
        }
        base.WndProc(ref message);
        if (message.Msg==0x7D && message.WParam.ToInt64()==-16 && message.LParam!=IntPtr.Zero) {
            NativeStyles styles=(NativeStyles)Marshal.PtrToStructure(message.LParam,typeof(NativeStyles));
            if ((styles.NewStyle & ~styles.OldStyle & 0x300000u)!=0) ScheduleViewport();
        }
        if (message.Msg==0x115 || message.Msg==0x100 || message.Msg==0x101 || message.Msg==0x1014 || message.Msg==0x1013)
            ScheduleViewport();
    }
    public int TopIndex { get { return Items.Count==0 || !IsHandleCreated ? 0 : PlaylistNative.SendMessage(Handle,0x1027,IntPtr.Zero,IntPtr.Zero).ToInt32(); } }
    public int RowHeight { get { return Items.Count==0 ? 1 : Math.Max(1,Items[0].Bounds.Height); } }
    public int PageRows {
        get { PlaylistNative.Rect rect; return PlaylistNative.GetClientRect(Handle,out rect) ? Math.Max(1,(rect.Bottom-rect.Top)/RowHeight) : 1; }
    }
    public void ScrollToRow(int desired) {
        if (Items.Count==0 || !IsHandleCreated) return;
        int target=Math.Max(0,Math.Min(desired,Math.Max(0,Items.Count-PageRows)));
        PlaylistNative.SendMessage(Handle,0x1014,IntPtr.Zero,new IntPtr((target-TopIndex)*RowHeight));
        ScheduleViewport();
    }
    public void WheelScroll(int delta) {
        wheelCarry+=delta;int steps=wheelCarry/120;wheelCarry%=120;
        int lines=SystemInformation.MouseWheelScrollLines;
        if(steps!=0 && lines!=0)ScrollToRow(TopIndex-steps*(lines<0?PageRows:lines));
    }
}
public sealed class PlaylistScroll : Control {
    readonly PlaylistList list;
    bool syncing, dragging, hover;
    int count, page, top, dragOffset;
    Rectangle thumb;
    public PlaylistScroll(PlaylistList view) {
        list=view;Width=8;Dock=DockStyle.Right;TabStop=false;BackColor=Color.FromArgb(17,17,17);
        SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);
        SetStyle(ControlStyles.Selectable,false);
        list.ViewportChanged+=SyncViewport;
    }
    public void SyncViewport() {
        if(syncing || IsDisposed || list==null || !list.IsHandleCreated)return;
        syncing=true;
        try {
            uint dpi=PlaylistNative.GetDpiForWindow(list.Handle);if(dpi==0)dpi=96;
            int width=(int)Math.Round(8*dpi/96.0);if(Width!=width)Width=width;
            int nextCount=list.Items.Count,nextPage=list.PageRows,nextTop=list.TopIndex;
            Rectangle next=Rectangle.Empty;
            if(nextCount>nextPage && Height>0) {
                int pad=Math.Max(1,(int)Math.Round(dpi/96.0)),track=Math.Max(1,Height-pad*2);
                int size=Math.Min(track,Math.Max((int)Math.Round(24*dpi/96.0),(int)Math.Round(track*nextPage/(double)nextCount)));
                int y=pad+(int)Math.Round((track-size)*Math.Min(nextTop,nextCount-nextPage)/(double)(nextCount-nextPage));
                next=new Rectangle(pad,y,Math.Max(1,Width-pad*2),size);
            }
            if(thumb!=next || count!=nextCount || page!=nextPage || top!=nextTop) {
                thumb=next;count=nextCount;page=nextPage;top=nextTop;Invalidate();
            }
        } finally {syncing=false;}
    }
    protected override void OnSizeChanged(EventArgs args) { base.OnSizeChanged(args);SyncViewport(); }
    protected override void OnPaint(PaintEventArgs args) {
        base.OnPaint(args);if(thumb.IsEmpty)return;
        args.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        Color color=dragging?Color.FromArgb(18,135,187):hover?Color.FromArgb(138,146,156):Color.FromArgb(107,114,124);
        float radius=Math.Min(thumb.Width,thumb.Height)/2f,diameter=radius*2;
        using(var path=new System.Drawing.Drawing2D.GraphicsPath()) {
            path.AddArc(thumb.Left,thumb.Top,diameter,diameter,180,90);
            path.AddArc(thumb.Right-diameter,thumb.Top,diameter,diameter,270,90);
            path.AddArc(thumb.Right-diameter,thumb.Bottom-diameter,diameter,diameter,0,90);
            path.AddArc(thumb.Left,thumb.Bottom-diameter,diameter,diameter,90,90);path.CloseFigure();
            using(Brush brush=new SolidBrush(color))args.Graphics.FillPath(brush,path);
        }
    }
    protected override void OnMouseDown(MouseEventArgs args) {
        base.OnMouseDown(args);if(args.Button!=MouseButtons.Left || thumb.IsEmpty)return;
        if(thumb.Contains(args.Location)){dragging=true;dragOffset=args.Y-thumb.Top;Capture=true;Invalidate();}
        else list.ScrollToRow(top+(args.Y<thumb.Top?-page:page));
    }
    protected override void OnMouseMove(MouseEventArgs args) {
        base.OnMouseMove(args);
        if(dragging) {
            int track=Math.Max(1,Height-2*Math.Max(1,(Width-thumb.Width)/2)-thumb.Height);
            int offset=Math.Max(0,Math.Min(track,args.Y-dragOffset-(Width-thumb.Width)/2));
            list.ScrollToRow((int)Math.Round(offset*(count-page)/(double)track));
        } else {bool next=thumb.Contains(args.Location);if(hover!=next){hover=next;Invalidate();}}
    }
    protected override void OnMouseUp(MouseEventArgs args) {base.OnMouseUp(args);if(dragging){dragging=false;Capture=false;Invalidate();}}
    protected override void OnMouseCaptureChanged(EventArgs args) {base.OnMouseCaptureChanged(args);if(dragging && !Capture){dragging=false;Invalidate();}}
    protected override void OnMouseLeave(EventArgs args) {base.OnMouseLeave(args);if(hover){hover=false;Invalidate();}}
    protected override void OnVisibleChanged(EventArgs args) {base.OnVisibleChanged(args);if(!Visible){dragging=false;Capture=false;}}
    protected override void OnMouseWheel(MouseEventArgs args) {
        base.OnMouseWheel(args);
        HandledMouseEventArgs handled=args as HandledMouseEventArgs;if(handled!=null)handled.Handled=true;
        list.WheelScroll(args.Delta);
    }
    protected override void Dispose(bool disposing) {if(disposing)list.ViewportChanged-=SyncViewport;base.Dispose(disposing);}
}
public sealed class PlaylistFooter : Panel {
    public TextBox Editor;
    protected override void OnLayout(LayoutEventArgs args) {
        base.OnLayout(args);
        if (Editor != null) {
            int needed=Editor.PreferredHeight+Padding.Vertical+2;
            if (Height < needed) Height=needed;
        }
    }
}
public static class PlaylistNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback cb, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ShowScrollBar(IntPtr hwnd, int bar, bool show);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static bool BelongsTo(IntPtr hwnd, uint pid) { uint actual; GetWindowThreadProcessId(hwnd,out actual);return actual==pid; }
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static IntPtr FindParent(uint pid, IntPtr preferred) {
        uint preferredPid;
        if (preferred != IntPtr.Zero && IsWindowVisible(preferred) && GetWindow(preferred, 4) == IntPtr.Zero) {
            GetWindowThreadProcessId(preferred, out preferredPid);
            if (preferredPid == pid) return preferred;
        }
        IntPtr result = IntPtr.Zero; long area = -1;
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            if (owner == pid && IsWindowVisible(hwnd) && GetWindow(hwnd, 4) == IntPtr.Zero) {
                Rect rect; if (GetWindowRect(hwnd, out rect)) {
                    long current = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
                    if (current > area) { area = current; result = hwnd; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
public sealed class PlaylistFollower : IDisposable {
    readonly PlaylistForm form; readonly uint pid;
    delegate void WinEvent(IntPtr hook, uint kind, IntPtr hwnd, int obj, int child, uint thread, uint time);
    readonly WinEvent callback; readonly System.Collections.Generic.List<IntPtr> hooks = new System.Collections.Generic.List<IntPtr>();
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent cb, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    bool posted, disposed, wanted, fullscreen;
    public IntPtr Parent { get; private set; }
    public double UserWidth { get; private set; }
    bool discover;
    public PlaylistFollower(PlaylistForm window, uint process) {
        form = window; pid = process; UserWidth = 340; callback = OnEvent; form.Follower = this;
        foreach (uint[] range in new uint[][] {new uint[]{0x800B,0x800B}, new uint[]{0x16,0x17}, new uint[]{0x8000,0x8003}}) {
            IntPtr hook = SetWinEventHook(range[0],range[1],IntPtr.Zero,callback,pid,0,0);
            if (hook == IntPtr.Zero) { Dispose(); throw new InvalidOperationException("event-hook"); }
            hooks.Add(hook);
        }
        RefreshParent(IntPtr.Zero);
    }
    void OnEvent(IntPtr hook, uint kind, IntPtr hwnd, int obj, int child, uint thread, uint time) {
        if (disposed || obj != 0 || child != 0) return;
        if (hwnd != Parent && IsWindow(Parent)) return;
        if (!IsWindow(Parent) || kind == 0x8001) discover = true;
        Schedule();
    }
    void Schedule() {
        if (posted || disposed || form.IsDisposed) return;
        posted = true;
        form.BeginInvoke(new Action(delegate { posted = false; if (!disposed) { if (discover) { discover=false;RefreshParent(IntPtr.Zero); } else Follow(); } }));
    }
    public void RefreshParent(IntPtr preferred) {
        if (disposed) return;
        IntPtr found = PlaylistNative.FindParent(pid,preferred);
        if (found != IntPtr.Zero && found != Parent) { Parent = found; PlaylistNative.SetWindowLongPtr(form.Handle,-8,Parent); }
        Follow();
    }
    public void UpdatePolicy(bool show, bool full) { if(wanted==show && fullscreen==full)return;wanted = show; fullscreen = full; Follow(); }
    uint Dpi { get { uint dpi = PlaylistNative.GetDpiForWindow(Parent); return dpi == 0 ? 96 : dpi; } }
    public void RememberWidth(int pixels) { UserWidth = Math.Max(220,pixels * 96.0 / Dpi); }
    public static PlaylistNative.Rect Layout(PlaylistNative.Rect parent, PlaylistNative.Rect area, int width, bool overlay) {
        PlaylistNative.Rect result = new PlaylistNative.Rect();
        width = Math.Min(width,area.Right-area.Left);
        result.Left = overlay || parent.Right + width > area.Right ? area.Right-width : parent.Right;
        result.Top = parent.Top; result.Right = result.Left+width; result.Bottom = parent.Bottom;
        return result;
    }
    public PlaylistNative.Rect GetBounds() {
        PlaylistNative.Rect parent; PlaylistNative.GetWindowRect(Parent,out parent);
        Screen screen = Screen.FromHandle(Parent); Rectangle area = fullscreen ? screen.Bounds : screen.WorkingArea;
        PlaylistNative.Rect nativeArea = new PlaylistNative.Rect();
        nativeArea.Left=area.Left;nativeArea.Top=area.Top;nativeArea.Right=area.Right;nativeArea.Bottom=area.Bottom;
        return Layout(parent,nativeArea,(int)Math.Round(UserWidth*Dpi/96.0),fullscreen || PlaylistNative.IsZoomed(Parent));
    }
    public void Follow() {
        if (disposed || !IsWindow(Parent)) return;
        if (!wanted || PlaylistNative.IsIconic(Parent) || !PlaylistNative.IsWindowVisible(Parent)) { if (form.Visible) form.Hide(); return; }
        PlaylistNative.Rect target = GetBounds();
        bool targetTopmost=(PlaylistNative.GetWindowLongPtr(Parent,-20).ToInt64() & 8) != 0;
        bool currentTopmost=(PlaylistNative.GetWindowLongPtr(form.Handle,-20).ToInt64() & 8) != 0;
        // Form.TopMost's setter can activate even when its value is unchanged.
        // Synchronize only the native z-order, keeping focus with the player.
        if (currentTopmost != targetTopmost)
            PlaylistNative.SetWindowPos(form.Handle,new IntPtr(targetTopmost ? -1 : -2),0,0,0,0,0x13);
        if (form.Left != target.Left || form.Top != target.Top || form.Width != target.Right-target.Left || form.Height != target.Bottom-target.Top)
            PlaylistNative.SetWindowPos(form.Handle,IntPtr.Zero,target.Left,target.Top,target.Right-target.Left,target.Bottom-target.Top,0x14);
        if (!form.Visible) {
            form.Show(new PlaylistOwner(Parent));
        }
    }
    public void Dispose() { if (disposed) return; disposed=true; foreach (IntPtr hook in hooks) UnhookWinEvent(hook); hooks.Clear(); form.Follower=null; }
}
public sealed class PlaylistKeys : IMessageFilter, IDisposable {
    readonly PlaylistForm form;
    readonly System.Collections.Generic.Dictionary<int,string> held = new System.Collections.Generic.Dictionary<int,string>();
    readonly System.Collections.Generic.HashSet<string> allowed = new System.Collections.Generic.HashSet<string>(new string[]{
        "d","Space","Left","Right","Shift+Left","Shift+Right","Ctrl+Left","Ctrl+Right",",",".","Ctrl+r","Ctrl+[","Ctrl+]","Ctrl+BS","s","Alt+s","PGUP","PGDWN","Alt+Left","Alt+Right","Alt+BS","Ctrl+Shift+s","Ctrl+c","m","M","l","Ctrl+Shift+l","Home","End","Enter","Ctrl+t","Ctrl+0","Ctrl+i","Ctrl+m","Tab","Alt+o","`","Ctrl+Shift+c","Ctrl+Shift+v","p"});
    readonly System.Collections.Generic.HashSet<string> opening = new System.Collections.Generic.HashSet<string>(new string[]{"Ctrl+i","Ctrl+m","Alt+s","Tab","`","Ctrl+Shift+s"});
    public bool SearchActive;
    public event Action<string,string> Transmit;
    public PlaylistKeys(PlaylistForm window) { form=window;Application.AddMessageFilter(this); }
    public static string Canonical(int vk, Keys modifiers) {
        bool ctrl=(modifiers & Keys.Control)!=0,alt=(modifiers & Keys.Alt)!=0,shift=(modifiers & Keys.Shift)!=0;
        string key=null;
        if(vk>=65 && vk<=90) key=((char)(!ctrl && !alt && shift ? vk : vk+32)).ToString();
        else switch(vk) {case 32:key="Space";break;case 37:key="Left";break;case 39:key="Right";break;case 8:key="BS";break;case 33:key="PGUP";break;case 34:key="PGDWN";break;case 36:key="Home";break;case 35:key="End";break;case 13:key="Enter";break;case 9:key="Tab";break;case 48:key="0";break;case 188:key=",";break;case 190:key=".";break;case 219:key="[";break;case 221:key="]";break;case 192:key="`";break;}
        if(key==null)return null;
        return (ctrl?"Ctrl+":"")+(alt?"Alt+":"")+(shift && (ctrl || alt || vk<65 || vk>90)?"Shift+":"")+key;
    }
    void Send(string phase,string key) { if(Transmit!=null)Transmit(phase,key); }
    public void ReleaseAll() { held.Clear();Send("release",""); }
    public bool PreFilterMessage(ref Message message) {
        if(!form.ContainsFocus || SearchActive)return false;
        bool down=message.Msg==0x100 || message.Msg==0x104,up=message.Msg==0x101 || message.Msg==0x105;
        if(!down && !up)return false;
        int vk=message.WParam.ToInt32();
        string key;
        if(up) { if(!held.TryGetValue(vk,out key))return false;held.Remove(vk);Send("up",key);return true; }
        if(held.ContainsKey(vk))return true;
        key=Canonical(vk,Control.ModifierKeys);
        if(key==null || !allowed.Contains(key))return false;
        if(opening.Contains(key)) {
            ReleaseAll(); if(form.Follower!=null)PlaylistNative.SetForegroundWindow(form.Follower.Parent);Send("press",key);
        } else {held.Add(vk,key);Send("down",key);}
        return true;
    }
    public void Dispose() { ReleaseAll();Application.RemoveMessageFilter(this); }
}
public sealed class PlaylistTip : Form {
    string content = "";
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { CreateParams p=base.CreateParams;p.ExStyle|=0x08000080;return p; } }
    protected override void WndProc(ref Message message) { if(message.Msg==0x84){message.Result=new IntPtr(-1);return;}base.WndProc(ref message); }
    public PlaylistTip(Font font) { FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;Font=font;BackColor=Color.FromArgb(17,17,17);DoubleBuffered=true; }
    public static Size Measure(string text, Font font, int dpi) {
        float scale=dpi/96f;int pad=(int)Math.Round(10*scale);int max=(int)Math.Round(400*scale);
        using(Bitmap bitmap=new Bitmap(1,1)) { bitmap.SetResolution(dpi,dpi);using(Graphics g=Graphics.FromImage(bitmap)) {
            SizeF measured=g.MeasureString(text,font,max-pad*2,StringFormat.GenericDefault);
            return new Size(Math.Min(max,(int)Math.Ceiling(measured.Width)+pad*2),(int)Math.Ceiling(measured.Height)+pad*2);
        }}
    }
    public void ShowContent(string text, Control anchor, Point location) {
        content=text;int dpi=(int)PlaylistNative.GetDpiForWindow(anchor.Handle);if(dpi<=0)dpi=96;
        Size=Measure(text,Font,dpi);Point point=anchor.PointToScreen(location);Rectangle area=Screen.FromPoint(point).WorkingArea;
        int top=point.Y+Height>area.Bottom ? point.Y-Height-40 : point.Y;
        Location=new Point(Math.Max(area.Left,Math.Min(point.X,area.Right-Width)),Math.Max(area.Top,Math.Min(top,area.Bottom-Height)));
        if(!Visible) Show(anchor.FindForm());Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e) {
        using(Pen pen=new Pen(Color.FromArgb(48,48,48)))e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);
        int pad=(int)Math.Round(10*e.Graphics.DpiX/96f);
        using(Brush brush=new SolidBrush(Color.FromArgb(225,229,234)))e.Graphics.DrawString(content,Font,brush,new RectangleF(pad,pad,Width-pad*2,Height-pad*2),StringFormat.GenericDefault);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing
    # One DPI coordinate system for native rectangles, Screen and Form bounds.
    try { [void][PlaylistNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch {}
    [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
    [Windows.Forms.Application]::add_ThreadException({
        param($sender, $errorArgs)
        # WinForms otherwise opens a modal error dialog, blocking hide and exit.
        $script:sessionFailed = $true
        $script:sessionErrorClass = $errorArgs.Exception.GetType().Name
        $script:sessionErrorLine = 0
        for ($failure = $errorArgs.Exception; $failure; $failure = $failure.InnerException) {
            if ($failure.ErrorRecord -and $failure.ErrorRecord.InvocationInfo.ScriptLineNumber) {
                $script:sessionErrorClass = $failure.GetType().Name
                $script:sessionErrorLine = [int]$failure.ErrorRecord.InvocationInfo.ScriptLineNumber
            }
        }
        $baseFailure = $errorArgs.Exception.GetBaseException()
        if (-not $script:sessionErrorLine) {
            $script:sessionErrorMember = $baseFailure.TargetSite.Name
            $script:sessionErrorType = $baseFailure.TargetSite.DeclaringType.FullName
        }
        $script:sessionErrorCallers = New-Object 'Collections.Generic.List[string]'
        $managedTrace = New-Object Diagnostics.StackTrace($baseFailure)
        foreach ($frame in $managedTrace.GetFrames()) {
            $method = $frame.GetMethod()
            $typeName = if ($method.DeclaringType) { $method.DeclaringType.FullName } else { '' }
            if ($typeName.StartsWith('System.Windows.Forms.') -or $typeName.StartsWith('System.Drawing.')) {
                $script:sessionErrorCallers.Add($typeName + '.' + $method.Name)
                if ($script:sessionErrorCallers.Count -ge 12) { break }
            }
        }
        if ($baseFailure -is [ArgumentException] -and $baseFailure.ParamName -match '^[A-Za-z_][A-Za-z0-9_]{0,79}$') {
            $script:sessionErrorParameter = $baseFailure.ParamName
        }
        Exit-Window
    })
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object PlaylistForm
    $form.Text = ''
    $form.ShowInTaskbar = $false
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowIcon = $true
    $iconBitmap = New-Object Drawing.Bitmap(16, 16)
    $iconGraphics = [Drawing.Graphics]::FromImage($iconBitmap)
    $iconPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(18,135,187), 1.5)
    try { $iconGraphics.DrawRectangle($iconPen, 2,2,8,8); $iconGraphics.DrawRectangle($iconPen, 6,6,8,8); $nativeIcon = $iconBitmap.GetHicon(); $sidebarIcon = [Drawing.Icon]::FromHandle($nativeIcon).Clone(); $form.Icon = $sidebarIcon }
    finally { $iconPen.Dispose(); $iconGraphics.Dispose(); $iconBitmap.Dispose(); if ($nativeIcon) { [void][PlaylistNative]::DestroyIcon($nativeIcon) } }

    $form.StartPosition = 'Manual'
    $form.ClientSize = New-Object Drawing.Size(340, 420)
    $form.BackColor = [Drawing.Color]::FromArgb(17, 17, 17)
    $form.ForeColor = [Drawing.Color]::FromArgb(230, 232, 237)
    $mainFont = New-Object Drawing.Font('Segoe UI', 9)
    $form.Font = $mainFont
    $form.KeyPreview = $true
    $form.AutoScaleMode = 'Dpi'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $filter = New-Object Windows.Forms.TextBox
    $footer = New-Object PlaylistFooter
    $footer.Editor = $filter
    $footer.Dock = 'Bottom'
    $footer.Height = 34
    $footer.Padding = New-Object Windows.Forms.Padding(8, 5, 8, 5)
    $footer.BackColor = [Drawing.Color]::FromArgb(13, 13, 13)
    $filter.Dock = 'Fill'
    $filter.Visible = $false
    $filter.BackColor = [Drawing.Color]::FromArgb(27, 27, 27)
    $filter.ForeColor = $form.ForeColor
    $filter.BorderStyle = 'FixedSingle'
    $counter = New-Object Windows.Forms.Label
    $counter.Dock = 'Fill'
    $counter.TextAlign = 'MiddleCenter'
    $counter.ForeColor = [Drawing.Color]::FromArgb(155, 163, 177)
    $list = New-Object PlaylistList
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.ShowItemToolTips = $false
    $list.HeaderStyle = 'None'
    $list.BorderStyle = 'None'
    $list.BackColor = $form.BackColor
    $list.ForeColor = $form.ForeColor
    $list.AllowDrop = $true
    $form.AllowDrop = $true
    $list.OwnerDraw = $true
    [void]$list.Columns.Add('', 12)
    [void]$list.Columns.Add('Title', 270)
    $rowImages = New-Object Windows.Forms.ImageList
    $rowImages.ImageSize = New-Object Drawing.Size(1, 32)
    $rowBitmap = New-Object Drawing.Bitmap(1, 32)
    $rowImages.Images.Add($rowBitmap)
    $list.SmallImageList = $rowImages
    $scroll = New-Object PlaylistScroll($list)
    $form.Controls.Add($list)
    $form.Controls.Add($scroll)
    $footer.Controls.Add($filter)
    $footer.Controls.Add($counter)
    $form.Controls.Add($footer)
    $tip = New-Object PlaylistTip($form.Font)
    $keyFilter = New-Object PlaylistKeys($form)
    $keyFilter.add_Transmit({
        param($keyPhase, $keyName)
        if (-not $ValidateOnly -and $writer -and -not $script:exiting) { Send-Command @('script-message-to', [string]$payload.script, 'key', [string]$payload.token, $keyPhase, $keyName) }
    })
    $form.Add_VisibleChanged({ if (-not $form.Visible) { if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Hide() } } })
    $form.Add_Deactivate({ if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Hide() } })
    $list.Add_DrawColumnHeader({ param($sender, $eventArgs) $eventArgs.DrawDefault = $true })
    $list.Add_DrawSubItem({
        param($sender, $eventArgs)
        $selected = $eventArgs.Item.Selected
        $current = $eventArgs.Item.Tag.index -eq $script:playlistPosition
        $bg = if ($current) { [Drawing.Color]::FromArgb(12, 32, 42) } elseif ($selected) { [Drawing.Color]::FromArgb(38, 38, 38) } elseif ($eventArgs.Item.Tag.id -eq $script:hoverId) { [Drawing.Color]::FromArgb(27, 27, 27) } else { $form.BackColor }
        $fg = if ($current) { [Drawing.Color]::FromArgb(18, 135, 187) } else { $form.ForeColor }
        $brush = New-Object Drawing.SolidBrush($bg)
        try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
        if ($current -and $eventArgs.ColumnIndex -eq 0) {
            $bar = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(18, 135, 187))
            try { $eventArgs.Graphics.FillRectangle($bar, $eventArgs.Bounds.Left, $eventArgs.Bounds.Top + 3, 3, [Math]::Max(1, $eventArgs.Bounds.Height - 6)) } finally { $bar.Dispose() }
        }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $eventArgs.SubItem.Text, $form.Font,
            $eventArgs.Bounds, $fg, ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
        if ($eventArgs.Item.Tag.id -eq $script:dropTargetId) {
            # Native InsertionMark is unreliable in Details view; draw the same cue.
            $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(18, 135, 187), 2)
            $y = if ($script:dropAfter) { $eventArgs.Bounds.Bottom - 1 } else { $eventArgs.Bounds.Top }
            try { $eventArgs.Graphics.DrawLine($pen, $eventArgs.Bounds.Left, $y, $eventArgs.Bounds.Right, $y) }
            finally { $pen.Dispose() }
        }
    })
    $filter.Add_TextChanged({ Render-Queue })
    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'F') {
            Set-SearchMode $true; $filter.SelectAll(); $eventArgs.SuppressKeyPress = $true
        } elseif ($script:searching -and -not $eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'Escape') {
            Set-SearchMode $false; $eventArgs.SuppressKeyPress = $true
        }
    })
    $list.Add_KeyDown({
        param($sender, $eventArgs)
        if (-not $eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'Delete' -and $list.SelectedItems.Count -eq 1) {
            Send-Action 'remove' ([string]$list.SelectedItems[0].Tag.id)
            $eventArgs.SuppressKeyPress = $true
        }
    })
    $list.Add_MouseMove({
        param($sender, $eventArgs)
        $item = $list.GetItemAt($eventArgs.X, $eventArgs.Y)
        $id = if ($item) { [string]$item.Tag.id } else { '' }
        if ($script:hoverId -ne $id) {
            $oldHoverId = $script:hoverId; $script:hoverId = $id
            Invalidate-HoverRow $oldHoverId; Invalidate-HoverRow $id
            if ($item) { $tip.ShowContent((Tooltip-Text $item.Tag.entry), $list, (New-Object Drawing.Point(($eventArgs.X + 18), ($eventArgs.Y + 20)))) }
            else { $tip.Hide() }
        }
    })
    $list.Add_MouseLeave({ $oldHoverId = $script:hoverId; $script:hoverId = ''; Invalidate-HoverRow $oldHoverId; $tip.Hide() })
    $list.Add_DoubleClick({
        if ($list.SelectedItems.Count -eq 1) { Send-Action 'play' ([string]$list.SelectedItems[0].Tag.id) }
    })
    $list.Add_ItemDrag({
        param($sender, $eventArgs)
        if ($script:rendering) { return }
        $script:dragging = $true
        try {
            $data = New-Object Windows.Forms.DataObject
            $data.SetData('mpvnet-playlist-entry', [string]$eventArgs.Item.Tag.id)
            [void]$list.DoDragDrop($data, [Windows.Forms.DragDropEffects]::Move)
        } finally { $script:dragging = $false; Clear-DropMarker; if ($script:renderDirty) { Render-Queue } }
    })
    $dragOver = {
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
            Clear-DropMarker
        } elseif ($eventArgs.Data.GetDataPresent('mpvnet-playlist-entry')) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Move
            $point = $list.PointToClient((New-Object Drawing.Point($eventArgs.X, $eventArgs.Y)))
            $target = $list.GetItemAt($point.X, $point.Y)
            $after = $false
            if ($target) { $after = $point.Y -ge ($target.Bounds.Top + $target.Bounds.Height / 2) }
            elseif ($list.Items.Count) { $target = $list.Items[$list.Items.Count - 1]; $after = $true }
            if ($target) {
                $script:dropTargetId = [string]$target.Tag.id
                $script:dropAfter = $after
                $list.InsertionMark.Index = $target.Index
                $list.InsertionMark.AppearsAfterItem = $after
                $list.Invalidate()
            }
        } else { $eventArgs.Effect = [Windows.Forms.DragDropEffects]::None }
    }
    $drop = {
        param($sender, $eventArgs)
        Clear-DropMarker
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $files = @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop) | Where-Object { [IO.File]::Exists([string]$_) })
            if ($files.Count) { Send-Action 'append' (ConvertTo-Json -InputObject $files -Compress) }
        } elseif ($eventArgs.Data.GetDataPresent('mpvnet-playlist-entry') -and $list.Items.Count) {
            $point = $list.PointToClient((New-Object Drawing.Point($eventArgs.X, $eventArgs.Y)))
            $target = $list.GetItemAt($point.X, $point.Y)
            $side = 'before'
            if ($target) {
                if ($point.Y -ge ($target.Bounds.Top + $target.Bounds.Height / 2)) { $side = 'after' }
            } else { $target = $list.Items[$list.Items.Count - 1]; $side = 'after' }
            Send-Action 'move' ([string]$eventArgs.Data.GetData('mpvnet-playlist-entry')) ([string]$target.Tag.id) $side
        }
    }
    $list.Add_DragEnter($dragOver); $list.Add_DragOver($dragOver); $list.Add_DragDrop($drop)
    $form.Add_DragEnter($dragOver); $form.Add_DragOver($dragOver); $form.Add_DragDrop($drop)
    $list.Add_DragLeave({ Clear-DropMarker }); $form.Add_DragLeave({ Clear-DropMarker })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:exiting) { $eventArgs.Cancel = $true; Hide-Window }
    })
    [void]$form.Handle
    try { $dark = 1; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4) } catch {}
    try { $caption = 0x111111; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 35, [ref]$caption, 4) } catch {}

    if ($ValidateOnly) {
        $script:playlist = @(if ($null -ne $payload.playlist) { $payload.playlist })
        $script:playlistPosition = [int]$payload.position
        if ($payload.filter) { Set-SearchMode $true; $filter.Text = [string]$payload.filter }
        Render-Queue
        $form.PerformLayout()
        [void]$list.Handle
        $rows = @($list.Items | ForEach-Object { @{id = $_.Tag.id; index = $_.Tag.index; label = $_.SubItems[1].Text; current = $_.Tag.index -eq $script:playlistPosition} })
        foreach ($item in $list.Items) { if ([string]$item.Tag.id -eq [string]$payload.selected_id) { $item.Selected = $true } }
        if ($payload.hover_id) { $script:hoverId = [string]$payload.hover_id }
        $normalCount = $counter.Text
        $beforeBounds = $list.Bounds
        Set-SearchMode $true
        $searchBoundsStable = $list.Bounds -eq $beforeBounds
        Set-SearchMode $false
        $restoredBoundsStable = $list.Bounds -eq $beforeBounds
        $parentRect = New-Object PlaylistNative+Rect
        $parentRect.Left = 120; $parentRect.Top = -180; $parentRect.Right = 700; $parentRect.Bottom = 900
        $areaRect = New-Object PlaylistNative+Rect
        $areaRect.Left = 0; $areaRect.Top = 0; $areaRect.Right = 1000; $areaRect.Bottom = 800
        $layout = [PlaylistFollower]::Layout($parentRect, $areaRect, 400, $false)
        $tipText = if ($script:playlist.Count) { Tooltip-Text $script:playlist[0] } else { '' }
        $tipSize = [PlaylistTip]::Measure($tipText, $mainFont, 96)
        $painted = $false
        if ($payload.paint_path) {
            $paintPath = [IO.Path]::GetFullPath([string]$payload.paint_path)
            if (-not $paintPath.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'paint-path' }
            $canvas = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
            try {
                $form.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(0,0,$canvas.Width,$canvas.Height)))
                $list.DrawToBitmap($canvas, $list.Bounds)
                $footer.DrawToBitmap($canvas, $footer.Bounds)
                $counter.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($footer.Left + $counter.Left),($footer.Top + $counter.Top),$counter.Width,$counter.Height)))
                $canvas.Save($paintPath, [Drawing.Imaging.ImageFormat]::Png)
                $painted = $true
            } finally { $canvas.Dispose() }
        }
        $outputWriter.WriteLine((@{ok = $true; rows = $rows; count = $normalCount; shown = $form.Visible;
            footer_bounds_stable = $searchBoundsStable -and $restoredBoundsStable; caption_empty = $form.Text -eq '';
            no_minmax = -not $form.MinimizeBox -and -not $form.MaximizeBox;
            layout_top = $layout.Top; layout_height = $layout.Bottom-$layout.Top; layout_right = $layout.Right;
            tooltip_width = $tipSize.Width; tooltip_height = $tipSize.Height; painted = $painted} | ConvertTo-Json -Compress -Depth 8))
        exit 0
    }
    $phase = 'ipc'
    $pipeName = [string]$payload.pipe
    if ($pipeName.StartsWith('\\.\pipe\')) { $pipeName = $pipeName.Substring(9) }
    if (-not $pipeName) { throw 'pipe' }
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $pipe.Connect(10000)
    $reader = New-Object IO.StreamReader($pipe, $utf8)
    $writer = New-Object IO.StreamWriter($pipe, $utf8)
    $writer.AutoFlush = $true
    $readTask = $reader.ReadLineAsync()
    Send-Command @('observe_property', 1, 'playlist')
    Send-Command @('observe_property', 2, 'playlist-pos')
    Send-Command @('observe_property', 3, 'fullscreen')
    Send-Command @('observe_property', 4, 'user-data/mpvnet/playlist-window')
    Send-Command @('enable_event', 'client-message')
    $phase = 'session'
    $context = New-Object Windows.Forms.ApplicationContext
    $script:lastParent = [IntPtr]::Zero
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $script:lastLifeCheck = [Environment]::TickCount
    $follower = if ($NoShow) { $null } else { New-Object PlaylistFollower($form, [uint32]$payload.parent_pid) }
    $timer.Add_Tick({
        try {
            if ($parentProcess.HasExited) { Exit-Window; return }
            $updates = 0
            while ($readTask.IsCompleted -and $updates -lt 64) {
                if ($readTask.IsFaulted -or $null -eq $readTask.Result) { Exit-Window; return }
                $playlistEvent = $readTask.Result | ConvertFrom-Json
                if ($playlistEvent.event -eq 'property-change') {
                    switch ($playlistEvent.name) {
                        'playlist' {
                            $script:playlist = @(if ($null -ne $playlistEvent.data) { $playlistEvent.data })
                            Render-Queue
                            $script:receivedPlaylist = $true
                        }
                        'playlist-pos' { $script:playlistPosition = [int]$playlistEvent.data; Render-Queue }
                        'fullscreen' { $script:fullscreen = [bool]$playlistEvent.data }
                        'user-data/mpvnet/playlist-window' {
                            if ($playlistEvent.data.token -eq $payload.token) { $script:desiredVisible = [bool]$playlistEvent.data.visible }
                        }
                    }
                } elseif ($playlistEvent.event -eq 'client-message' -and $playlistEvent.args.Count -ge 2 -and
                    $playlistEvent.args[0] -eq 'mpvnet-playlist-close' -and $playlistEvent.args[1] -eq $payload.token) {
                    Exit-Window; return
                } elseif ($playlistEvent.event -eq 'shutdown') { Exit-Window; return }
                $script:readTask = $reader.ReadLineAsync()
                $updates++
            }
            if ($script:receivedPlaylist -and -not $script:sentReady) {
                $script:sentReady = $true
                Send-Command @('script-message-to', [string]$payload.script, 'helper-ready', [string]$payload.token, [string]$PID)
            }
            if ($NoShow) { return }
            $follower.UpdatePolicy($script:desiredVisible, $script:fullscreen)
            if ([Environment]::TickCount - $script:lastLifeCheck -ge 1000) {
                $script:lastLifeCheck = [Environment]::TickCount
                $parentProcess.Refresh()
                $follower.RefreshParent($parentProcess.MainWindowHandle)
            }
        } catch {
            $script:sessionFailed = $true
            $script:sessionErrorClass = $_.Exception.GetType().Name
            $script:sessionErrorLine = [int]$_.InvocationInfo.ScriptLineNumber
            Exit-Window
        }
    })
    $script:readTask = $readTask
    $timer.Start()
    [Windows.Forms.Application]::Run($context)
    if ($script:sessionFailed) { throw 'session' }
    $outputWriter.WriteLine('{"ok":true}')
} catch {
    $errorClass = if ($script:sessionErrorClass) { $script:sessionErrorClass } else { $_.Exception.GetType().Name }
    $errorLine = if ($script:sessionFailed) { [int]$script:sessionErrorLine } else { [int]$_.InvocationInfo.ScriptLineNumber }
    $outputWriter.WriteLine((@{ok = $false; phase = $phase; error_class = $errorClass; error_line = $errorLine;
        error_member = $script:sessionErrorMember; error_type = $script:sessionErrorType;
        error_parameter = $script:sessionErrorParameter; error_callers = @($script:sessionErrorCallers)} | ConvertTo-Json -Compress))
    exit 1
} finally {
    $script:exiting = $true
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($keyFilter) { $keyFilter.Dispose() }
    if ($follower) { $follower.Dispose() }
    if ($tip) { $tip.Dispose() }
    if ($scroll) { $scroll.Dispose() }
    if ($pipe) { $pipe.Dispose() }
    if ($form) { $form.Dispose() }
    if ($sidebarIcon) { $sidebarIcon.Dispose() }
    if ($mainFont) { $mainFont.Dispose() }
    if ($rowImages) { $rowImages.Dispose() }
    if ($rowBitmap) { $rowBitmap.Dispose() }
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($context) { $context.Dispose() }
    $outputWriter.Dispose()
}
