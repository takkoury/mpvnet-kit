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
    if (-not $value) { $value = '未命名媒体' }
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
    $counter.Enabled = $script:playlistPosition -ge 0 -and $script:playlistPosition -lt $script:playlist.Count
    $list.EmptyText = if ($script:playlist.Count -eq 0) { '播放列表为空' } elseif ($rows.Count -eq 0) { '没有匹配的项目' } else { '' }
    $list.AccessibleDescription = $list.EmptyText
    $script:rendering = $true
    try {
        if ($signature -ne $script:lastSignature) {
            if ($tip) { $tip.Cancel() }
            $selected = @($list.SelectedItems | ForEach-Object { [string]$_.Tag.id })
            $topId = if ($list.TopItem) { [string]$list.TopItem.Tag.id } else { '' }
            $list.BeginUpdate()
            try {
                $list.Items.Clear()
                foreach ($row in $rows) {
                    $item = New-Object Windows.Forms.ListViewItem(('{0:00}' -f ($row.index + 1)))
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
            $number = '{0:00}' -f ($item.Tag.index + 1)
            if ($item.Text -ne $number) { $item.Text = $number }
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
    if ($tip) { $tip.Cancel() }
    if ($follower) { $follower.UpdatePolicy($false, $script:fullscreen) }
    $form.Hide()
    if (-not $ValidateOnly -and -not $script:exiting) {
        Send-Command @('script-message-to', [string]$payload.script, 'window-hidden', [string]$payload.token)
    }
}

function Set-SearchMode([bool]$enabled, [bool]$focusControl = $true) {
    if ($tip) { $tip.Cancel() }
    if ($keyFilter) { $keyFilter.ReleaseAll(); $keyFilter.SearchActive = $enabled }
    $script:searching = $enabled
    $filter.Visible = $enabled
    $footer.Searching = $enabled
    $searchButton.Active = $enabled
    $searchButton.AccessibleName = if ($enabled) { '关闭搜索（Esc）' } else { '搜索播放列表（Ctrl+F）' }
    $searchButton.Invalidate()
    $counter.ForeColor = if ($enabled) { [PlaylistStyle]::Accent } else { [PlaylistStyle]::Muted }
    if ($enabled) { if ($focusControl) { [void]$filter.Focus() } }
    else { $filter.Text = ''; if ($focusControl) { [void]$list.Focus() } }
    Render-Queue
    $footer.PerformLayout()
}

function Locate-Entry([string]$id) {
    # The player resolves its current ID when requested. A changed/removed ID
    # must never fall back to a cached position or a filtered row index.
    if (-not $id -or -not @($script:playlist | Where-Object { [string]$_.id -eq $id }).Count) { return }
    $hadFocus = $form.ContainsFocus
    Set-SearchMode $false $hadFocus
    foreach ($item in $list.Items) {
        $item.Selected = [string]$item.Tag.id -eq $id
        if ($item.Selected) {
            $item.Focused = $true
            $item.EnsureVisible()
        }
    }
    $list.FitTitleColumn()
    $list.Invalidate()
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
    if ($tip) { $tip.Cancel() }
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
    Add-Type -TypeDefinition (@'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;
// Presentation tokens follow the accepted settings window. Queue identity,
// IPC and follower geometry remain owned by the existing controller.
public static class PlaylistStyle {
    public static readonly Color Background = ColorTranslator.FromHtml("#111111");
    public static readonly Color Chrome = ColorTranslator.FromHtml("#171717");
    public static readonly Color Divider = ColorTranslator.FromHtml("#2B2B2B");
    public static readonly Color Text = ColorTranslator.FromHtml("#DEDFE0");
    public static readonly Color Number = ColorTranslator.FromHtml("#919CA2");
    public static readonly Color Muted = ColorTranslator.FromHtml("#ABABAB");
    public static readonly Color Surface = ColorTranslator.FromHtml("#242424");
    public static readonly Color Hover = ColorTranslator.FromHtml("#1B1B1B");
    public static readonly Color Selected = ColorTranslator.FromHtml("#343434");
    public static readonly Color Current = ColorTranslator.FromHtml("#111F25");
    public static readonly Color Accent = ColorTranslator.FromHtml("#1287BB");
    public const string Locate = "定位当前播放项";
    public static Color RowBackground(bool current, bool selected, bool hover) {
        return current ? Current : hover ? Hover : Background;
    }
}
public class PlaylistCloseButton : Button {
    public bool SearchIcon, Active;
    bool hover, pressed;
    public PlaylistCloseButton() {
        Text=""; AccessibleName="关闭播放列表"; Width=44; Height=32;
        FlatStyle=FlatStyle.Flat; FlatAppearance.BorderSize=0;
        TabStop=true; SetStyle(ControlStyles.ResizeRedraw,true);
    }
    protected override void OnMouseEnter(EventArgs e) {base.OnMouseEnter(e);hover=true;Invalidate();}
    protected override void OnMouseLeave(EventArgs e) {base.OnMouseLeave(e);hover=false;pressed=false;Invalidate();}
    protected override void OnMouseDown(MouseEventArgs e) {base.OnMouseDown(e);pressed=e.Button==MouseButtons.Left;Invalidate();}
    protected override void OnMouseUp(MouseEventArgs e) {base.OnMouseUp(e);pressed=false;Invalidate();}
    protected override void OnGotFocus(EventArgs e) {base.OnGotFocus(e);Invalidate();}
    protected override void OnLostFocus(EventArgs e) {base.OnLostFocus(e);Invalidate();}
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(pressed ? (SearchIcon ? PlaylistStyle.Selected : ColorTranslator.FromHtml("#B53242")) : hover ? (SearchIcon ? PlaylistStyle.Hover : ColorTranslator.FromHtml("#8F2633")) : BackColor);
        float scale=e.Graphics.DpiX/96f, half=5*scale;
        e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using(var pen=new Pen(Active ? PlaylistStyle.Accent : PlaylistStyle.Text,Math.Max(1,scale))) {
            if(SearchIcon) {
                float x=Width/2f-1.5f*scale,y=Height/2f-1.5f*scale,r=4.5f*scale;
                e.Graphics.DrawEllipse(pen,x-r,y-r,2*r,2*r);
                e.Graphics.DrawLine(pen,x+3.2f*scale,y+3.2f*scale,x+7*scale,y+7*scale);
            } else {
                e.Graphics.DrawLine(pen,Width/2f-half,Height/2f-half,Width/2f+half,Height/2f+half);
                e.Graphics.DrawLine(pen,Width/2f+half,Height/2f-half,Width/2f-half,Height/2f+half);
            }
        }
        if(Focused) using(var pen=new Pen(PlaylistStyle.Accent,Math.Max(1,scale)))
            e.Graphics.DrawRectangle(pen,1,1,Math.Max(1,Width-3),Math.Max(1,Height-3));
    }
}
public sealed class PlaylistCounterButton : Button {
    bool hover, pressed;
    protected override void OnMouseEnter(EventArgs e) {base.OnMouseEnter(e);hover=true;Invalidate();}
    protected override void OnMouseLeave(EventArgs e) {base.OnMouseLeave(e);hover=false;pressed=false;Invalidate();}
    protected override void OnMouseDown(MouseEventArgs e) {base.OnMouseDown(e);pressed=e.Button==MouseButtons.Left;Invalidate();}
    protected override void OnMouseUp(MouseEventArgs e) {base.OnMouseUp(e);pressed=false;Invalidate();}
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(BackColor);
        if(Enabled && (pressed || hover)) {
            float radius=4*e.Graphics.DpiX/96f,diameter=Math.Min(Math.Min(Width,Height),radius*2);
            using(var path=new System.Drawing.Drawing2D.GraphicsPath()) {
                path.AddArc(0,0,diameter,diameter,180,90);
                path.AddArc(Width-diameter,0,diameter,diameter,270,90);
                path.AddArc(Width-diameter,Height-diameter,diameter,diameter,0,90);
                path.AddArc(0,Height-diameter,diameter,diameter,90,90);path.CloseFigure();
                e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using(var brush=new SolidBrush(pressed ? PlaylistStyle.Selected : PlaylistStyle.Surface))e.Graphics.FillPath(brush,path);
            }
        }
        var flags=TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix;
        flags |= TextAlign==ContentAlignment.MiddleRight ? TextFormatFlags.Right : TextFormatFlags.HorizontalCenter;
        TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Enabled ? ForeColor : Color.FromArgb(136,136,136),flags);
    }
}
public class PlaylistForm : Form {
    public PlaylistFollower Follower;
    bool squareCorners;
    void ApplyCornerPreference() {
        if(!IsHandleCreated)return;
        // Standard Windows rounding, not the small popup radius. A custom
        // client frame needs this opt-in; unsupported systems retain the frame.
        int preference=squareCorners ? 1 : 2; // DONOTROUND / ROUND
        try { PlaylistNative.DwmSetWindowAttribute(Handle,33,ref preference,4); }
        catch(DllNotFoundException) { } catch(EntryPointNotFoundException) { }
    }
    public void SetSquareCorners(bool square) {
        if(squareCorners==square)return;
        squareCorners=square;ApplyCornerPreference();
    }
    public Panel CaptionPanel, FooterPanel;
    public Label CaptionLabel;
    public Button CloseButton;
    public void ApplyPresentationDpi() {
        if (!IsHandleCreated) return;
        uint dpi=PlaylistNative.GetDpiForWindow(Handle); if(dpi==0)dpi=96;
        float scale=dpi/96f;
        if(CaptionPanel!=null) {
            CaptionPanel.Height=(int)Math.Round(32*scale);
            CaptionPanel.Padding=new Padding(0,0,0,Math.Max(1,(int)Math.Round(scale)));
        }
        if(FooterPanel!=null) {
            FooterPanel.Height=(int)Math.Round(32*scale);
            FooterPanel.Padding=new Padding((int)Math.Round(8*scale),(int)Math.Round(3*scale),(int)Math.Round(8*scale),(int)Math.Round(3*scale));
        }
        if(CloseButton!=null)CloseButton.Width=(int)Math.Round(44*scale);
        if(CaptionLabel!=null)CaptionLabel.Padding=new Padding((int)Math.Round(16*scale),0,0,0);
    }
    protected override void OnHandleCreated(EventArgs e) {base.OnHandleCreated(e);ApplyPresentationDpi();ApplyCornerPreference();}
    // Keep the resizing style, but let the client paint the whole frame.
    // Otherwise DWM leaves a system-colored strip above the custom caption.
    protected override CreateParams CreateParams {
        get { var value=base.CreateParams; value.Style &= ~0x00C00000; return value; }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void WndProc(ref Message m) {
        // The client owns every pixel of this frame. DefWindowProc otherwise
        // draws a classic caption/border on activation, over the custom chrome.
        // WM_ACTIVATE still follows the normal Form path below.
        if (m.Msg == 0x85) { m.Result=IntPtr.Zero;return; } // WM_NCPAINT
        if (m.Msg == 0x86) { m.Result=new IntPtr(1);return; } // WM_NCACTIVATE
        if (m.Msg == 0x83 && m.WParam != IntPtr.Zero) { m.Result=IntPtr.Zero;return; }
        if (m.Msg == 0x84) {
            PlaylistNative.Rect bounds; PlaylistNative.GetWindowRect(Handle,out bounds);
            int x=(short)(m.LParam.ToInt64() & 0xffff);
            uint dpi=PlaylistNative.GetDpiForWindow(Handle);if(dpi==0)dpi=96;
            int edge=Math.Max(1,(int)Math.Round(4*dpi/96.0));
            m.Result=new IntPtr(x<bounds.Left+edge ? 10 : x>=bounds.Right-edge ? 11 : 1);
            return;
        }
        if (m.Msg == 0x214 && Follower != null) {
            PlaylistNative.Rect bounds = (PlaylistNative.Rect)Marshal.PtrToStructure(m.LParam, typeof(PlaylistNative.Rect));
            Follower.RememberWidth(bounds.Right - bounds.Left);
            bounds = Follower.GetBounds();
            Marshal.StructureToPtr(bounds, m.LParam, false); m.Result = new IntPtr(1); return;
        }
        base.WndProc(ref m);
        if (m.Msg == 0x2E0) ApplyPresentationDpi();
        if (m.Msg == 0x31E) ApplyCornerPreference();
        if ((m.Msg == 0x2E0 || m.Msg == 0x31E) && Follower != null) Follower.RefreshFrame();
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
    public string EmptyText = "";
    public bool KeyboardFocusCue { get; private set; }
    public event Action ViewportChanged;
    public event Action ViewportInput;
    public PlaylistList() { DoubleBuffered = true; }
    protected override void OnGotFocus(EventArgs e) {base.OnGotFocus(e);KeyboardFocusCue=true;Invalidate();}
    protected override void OnLostFocus(EventArgs e) {base.OnLostFocus(e);KeyboardFocusCue=false;Invalidate();}
    protected override void OnMouseDown(MouseEventArgs e) {base.OnMouseDown(e);KeyboardFocusCue=false;Invalidate();}
    protected override void OnKeyDown(KeyEventArgs e) {base.OnKeyDown(e);KeyboardFocusCue=true;Invalidate();}
    protected override void OnHandleCreated(EventArgs args) {
        base.OnHandleCreated(args);
        PlaylistNative.SendMessage(Handle,0x1036,new IntPtr(0x10000),new IntPtr(0x10000));
        if (SmallImageList != null) {
            uint dpi=PlaylistNative.GetDpiForWindow(Handle);if(dpi==0)dpi=96;
            SmallImageList.ImageSize=new Size(1,(int)Math.Round(34*dpi/96.0));
            if(Columns.Count>0)Columns[0].Width=(int)Math.Round(44*dpi/96.0);
        }
        // Initial rendering can precede handle creation. Resolve the native
        // viewport/DPI now so the first search does not resize the list.
        FitTitleColumn();
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
        // Native wheel/scroll handling below intentionally bypasses WinForms'
        // MouseWheel event. Cancel pending hover content on this actual path.
        if(message.Msg==0x20A || message.Msg==0x115 || message.Msg==0x1014 || message.Msg==0x1013)
            if(ViewportInput!=null)ViewportInput();
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
        if (Items.Count==0 && !String.IsNullOrEmpty(EmptyText) &&
            (message.Msg==0xF || message.Msg==0x318)) {
            using(Graphics graphics=message.Msg==0x318 ? Graphics.FromHdc(message.WParam) : Graphics.FromHwnd(Handle))
                TextRenderer.DrawText(graphics,EmptyText,Font,ClientRectangle,PlaylistStyle.Muted,
                    TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
        }
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
        list=view;Width=8;Dock=DockStyle.Right;TabStop=false;BackColor=PlaylistStyle.Background;
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
        Color color=dragging?PlaylistStyle.Accent:hover?Color.FromArgb(153,153,153):Color.FromArgb(112,112,112);
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
public class PlaylistBar : Panel {
    public bool SeparatorAtTop;
    public PlaylistBar() {DoubleBuffered=true;SetStyle(ControlStyles.ResizeRedraw,true);}
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        int line=Math.Max(1,(int)Math.Round(e.Graphics.DpiY/96f));
        using(var brush=new SolidBrush(PlaylistStyle.Divider))
            e.Graphics.FillRectangle(brush,0,SeparatorAtTop ? 0 : Height-line,Width,line);
    }
}
public sealed class PlaylistFooter : PlaylistBar {
    public PlaylistFooter() {SeparatorAtTop=true;}
    public TextBox Editor;
    public Button Counter, Search;
    public bool Searching;
    protected override void OnLayout(LayoutEventArgs args) {
        base.OnLayout(args);
        if (Editor != null) {
            int needed=Editor.PreferredHeight+Padding.Vertical+2;
            if (Height < needed) Height=needed;
        }
        if(Counter!=null) {
            float scale=DeviceDpi/96f;
            int gap=(int)Math.Round(8*scale);
            int editorLeft=Padding.Left,searchLeft=ClientSize.Width-Padding.Right;
            if(Search!=null) {
                int searchWidth=(int)Math.Round(32*scale);
                searchLeft-=searchWidth;
                Search.SetBounds(searchLeft,Padding.Top,searchWidth,Math.Max(1,ClientSize.Height-Padding.Vertical));
            }
            int width=Math.Min(Math.Max(1,ClientSize.Width-Padding.Horizontal),TextRenderer.MeasureText(Counter.Text,Counter.Font).Width+(int)Math.Round(20*scale));
            int x=Searching ? searchLeft-gap-width : (ClientSize.Width-width)/2;
            Counter.SetBounds(x,Padding.Top,width,Math.Max(1,ClientSize.Height-Padding.Vertical));
            if(Editor!=null) Editor.SetBounds(editorLeft,(ClientSize.Height-Editor.PreferredHeight)/2,Math.Max(1,x-editorLeft-gap),Editor.PreferredHeight);
        }
    }
}
public static class PlaylistNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback cb, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
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
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("dwmapi.dll", EntryPoint="DwmGetWindowAttribute")] public static extern int ReadDwmInteger(IntPtr hwnd, int attr, out int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out Rect value, int size);
    public static Rect VisibleBounds(Rect outer, Rect frame, bool available) {
        return available && frame.Right > frame.Left && frame.Bottom > frame.Top ? frame : outer;
    }
    public static Rect GetVisibleBounds(IntPtr hwnd, out Rect outer) {
        GetWindowRect(hwnd,out outer);
        Rect frame = new Rect(); bool available = false;
        try { available = DwmGetWindowAttribute(hwnd,9,out frame,Marshal.SizeOf(typeof(Rect))) == 0; }
        catch (DllNotFoundException) {} catch (EntryPointNotFoundException) {}
        return VisibleBounds(outer,frame,available);
    }
    public static IntPtr FindParent(uint pid, IntPtr preferred) {
        if (IsPlayerWindow(preferred,pid) && IsWindowVisible(preferred)) return preferred;
        IntPtr result = IntPtr.Zero; long area = -1;
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            if (IsPlayerWindow(hwnd,pid) && IsWindowVisible(hwnd)) {
                Rect rect; if (GetWindowRect(hwnd, out rect)) {
                    long current = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
                    if (current > area) { area = current; result = hwnd; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static bool IsPlayerWindow(IntPtr hwnd, uint pid) {
        if (hwnd==IntPtr.Zero || !IsWindow(hwnd) || !BelongsTo(hwnd,pid) || GetWindow(hwnd,4)!=IntPtr.Zero) return false;
        long style=GetWindowLongPtr(hwnd,-16).ToInt64(), extended=GetWindowLongPtr(hwnd,-20).ToInt64();
        // Menus can be visible, ownerless windows in the player's process.
        // Do not reject WS_POPUP itself: borderless/fullscreen players use it too.
        return (style & 0x40000000L)==0 && (extended & (0x80L | 0x08000000L))==0;
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
    public void RefreshFrame() { Schedule(); }
    public void RefreshParent(IntPtr preferred) {
        if (disposed) return;
        // Process.MainWindowHandle may temporarily identify a menu. Keep the
        // confirmed player through menu, hide and minimize events; rediscover on destruction.
        IntPtr found = PlaylistNative.IsPlayerWindow(Parent,pid) ? Parent : PlaylistNative.FindParent(pid,preferred);
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
    public static PlaylistNative.Rect FrameLayout(PlaylistNative.Rect parent, PlaylistNative.Rect area,
        PlaylistNative.Rect outer, PlaylistNative.Rect visible, int width, bool overlay) {
        // Keep the remembered outer width; align the visible edges on both windows.
        int left = Math.Max(0,visible.Left-outer.Left), top = Math.Max(0,visible.Top-outer.Top);
        int right = Math.Max(0,outer.Right-visible.Right), bottom = Math.Max(0,outer.Bottom-visible.Bottom);
        PlaylistNative.Rect result = Layout(parent,area,Math.Max(1,width-left-right),overlay);
        result.Left-=left;result.Top-=top;result.Right+=right;result.Bottom+=bottom;
        return result;
    }
    public PlaylistNative.Rect GetBounds() {
        PlaylistNative.Rect parentOuter, sideOuter;
        PlaylistNative.Rect parent = PlaylistNative.GetVisibleBounds(Parent,out parentOuter);
        PlaylistNative.Rect side = PlaylistNative.GetVisibleBounds(form.Handle,out sideOuter);
        Screen screen = Screen.FromHandle(Parent); Rectangle area = fullscreen ? screen.Bounds : screen.WorkingArea;
        PlaylistNative.Rect nativeArea = new PlaylistNative.Rect();
        nativeArea.Left=area.Left;nativeArea.Top=area.Top;nativeArea.Right=area.Right;nativeArea.Bottom=area.Bottom;
        return FrameLayout(parent,nativeArea,sideOuter,side,(int)Math.Round(UserWidth*Dpi/96.0),fullscreen || PlaylistNative.IsZoomed(Parent));
    }
    public void Follow() {
        if (disposed || !IsWindow(Parent)) return;
        if (!wanted || PlaylistNative.IsIconic(Parent) || !PlaylistNative.IsWindowVisible(Parent)) { if (form.Visible) form.Hide(); return; }
        form.SetSquareCorners(fullscreen || PlaylistNative.IsZoomed(Parent));
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
            // A newly shown/moved window can acquire its DWM frame and monitor DPI now.
            Schedule();
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
        return ShortcutKeyNames.FromVirtualKey(vk, (modifiers & Keys.Control)!=0,
            (modifiers & Keys.Alt)!=0, (modifiers & Keys.Shift)!=0);
    }
    public static bool IsCaptionActivation(Control target, int vk, Keys modifiers) {
        return target is PlaylistCloseButton && modifiers==Keys.None && (vk==32 || vk==13);
    }
    public void UpdateBindings(string[] keys, string[] uiKeys) {
        keys=keys ?? new string[0];uiKeys=uiKeys ?? new string[0];
        if(allowed.SetEquals(keys) && opening.SetEquals(uiKeys))return;
        ReleaseAll();allowed.Clear();opening.Clear();
        allowed.UnionWith(keys);opening.UnionWith(uiKeys);
    }
    void Send(string phase,string key) { if(Transmit!=null)Transmit(phase,key); }
    public void ReleaseAll() { held.Clear();Send("release",""); }
    public bool PreFilterMessage(ref Message message) {
        if(!form.ContainsFocus || SearchActive)return false;
        bool down=message.Msg==0x100 || message.Msg==0x104,up=message.Msg==0x101 || message.Msg==0x105;
        if(!down && !up)return false;
        int vk=message.WParam.ToInt32();
        if(IsCaptionActivation(Control.FromHandle(message.HWnd),vk,Control.ModifierKeys)) {
            if(held.Count>0)ReleaseAll();
            return false;
        }
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
// A dwell is tied to both the item and a stable pointer position. Expiration
// does not rearm until the pointer moves or enters a different target.
public sealed class PlaylistHover {
    public string Key { get; private set; }
    public Point Pointer { get; private set; }
    public long Due { get; private set; }
    long expires;
    public int State { get; private set; } // 0 idle, 1 waiting, 2 shown, 3 expired
    public bool Move(string key, Point point, long now, int tolerance) {
        if(State!=0 && Key==key && Math.Abs(point.X-Pointer.X)<=tolerance && Math.Abs(point.Y-Pointer.Y)<=tolerance)return false;
        Key=key;Pointer=point;Due=now+550;State=1;return true;
    }
    public int Advance(long now) {
        if(State==1 && now>=Due){State=2;expires=now+5000;}
        else if(State==2 && now>=expires)State=3;
        return State;
    }
    public void Cancel(){State=0;Key=null;}
}
public sealed class PlaylistTip : Form {
    string content = "";
    readonly Timer dwell=new Timer();
    readonly System.Diagnostics.Stopwatch clock=System.Diagnostics.Stopwatch.StartNew();
    readonly PlaylistHover hover=new PlaylistHover();
    Control anchor;
    bool above;
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { CreateParams p=base.CreateParams;p.ExStyle|=0x08000080;return p; } }
    protected override void WndProc(ref Message message) { if(message.Msg==0x84){message.Result=new IntPtr(-1);return;}base.WndProc(ref message); }
    public PlaylistTip(Font font) {
        FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;Font=font;BackColor=PlaylistStyle.Surface;DoubleBuffered=true;
        dwell.Interval=50;dwell.Tick+=Tick;
    }
    public void Cancel(){dwell.Stop();hover.Cancel();anchor=null;Hide();}
    public void Schedule(string text, Control target, Point point, bool preferAbove) {
        if(target==null || target.IsDisposed || String.IsNullOrEmpty(text)){Cancel();return;}
        int dpi=(int)PlaylistNative.GetDpiForWindow(target.Handle);if(dpi<=0)dpi=96;
        Point screen=target.PointToScreen(point);
        string key=target.Handle.ToString()+":"+text;
        if(!hover.Move(key,screen,clock.ElapsedMilliseconds,Math.Max(1,(int)Math.Round(4*dpi/96.0))))return;
        Hide();content=text;anchor=target;above=preferAbove;dwell.Start();
    }
    void Tick(object sender,EventArgs args) {
        if(anchor==null || anchor.IsDisposed || !anchor.Visible || !anchor.Enabled || !anchor.ClientRectangle.Contains(anchor.PointToClient(Cursor.Position))) {Cancel();return;}
        int state=hover.Advance(clock.ElapsedMilliseconds);
        if(state==2 && !Visible)ShowContent(content,anchor,hover.Pointer,above);
        else if(state==3){Hide();dwell.Stop();}
    }
    public static Point Place(Point pointer,Size size,Rectangle area,int dpi,bool above) {
        int gap=(int)Math.Round(16*dpi/96.0),offset=(int)Math.Round(12*dpi/96.0);
        int y=above ? pointer.Y-gap-size.Height : pointer.Y+gap;
        if(above && y<area.Top)y=pointer.Y+gap;
        else if(!above && y+size.Height>area.Bottom)y=pointer.Y-gap-size.Height;
        return new Point(Math.Max(area.Left,Math.Min(pointer.X+offset,area.Right-size.Width)),
            Math.Max(area.Top,Math.Min(y,area.Bottom-size.Height)));
    }
    public static Size Measure(string text, Font font, int dpi) {
        float scale=dpi/96f;int pad=(int)Math.Round(10*scale);int max=(int)Math.Round(400*scale);
        using(Bitmap bitmap=new Bitmap(1,1)) { bitmap.SetResolution(dpi,dpi);using(Graphics g=Graphics.FromImage(bitmap)) {
            SizeF measured=g.MeasureString(text,font,max-pad*2,StringFormat.GenericDefault);
            return new Size(Math.Min(max,(int)Math.Ceiling(measured.Width)+pad*2),(int)Math.Ceiling(measured.Height)+pad*2);
        }}
    }
    void ShowContent(string text, Control anchor, Point point, bool above) {
        content=text;int dpi=(int)PlaylistNative.GetDpiForWindow(anchor.Handle);if(dpi<=0)dpi=96;
        Rectangle area=Screen.FromPoint(point).WorkingArea;
        Size measured=Measure(text,Font,dpi);Size=new Size(Math.Min(area.Width,measured.Width),Math.Min(area.Height,measured.Height));
        Location=Place(point,Size,area,dpi,above);
        if(!Visible) Show(anchor.FindForm());Invalidate();
    }
    protected override void Dispose(bool disposing) {if(disposing){dwell.Stop();dwell.Dispose();}base.Dispose(disposing);}
    protected override void OnPaint(PaintEventArgs e) {
        using(Pen pen=new Pen(Color.FromArgb(48,48,48)))e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);
        int pad=(int)Math.Round(10*e.Graphics.DpiX/96f);
        using(Brush brush=new SolidBrush(PlaylistStyle.Text))e.Graphics.DrawString(content,Font,brush,new RectangleF(pad,pad,Width-pad*2,Height-pad*2),StringFormat.GenericDefault);
    }
}
'@ + "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shortcut-key-names.cs'), $utf8)) -ReferencedAssemblies System.Windows.Forms,System.Drawing
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
    $form.ShowIcon = $false

    $form.StartPosition = 'Manual'
    $form.ClientSize = New-Object Drawing.Size(340, 420)
    if ($ValidateOnly -and $payload.client_width) { $form.ClientSize = New-Object Drawing.Size(([Math]::Max(220,[int]$payload.client_width)),420) }
    $form.BackColor = [PlaylistStyle]::Background
    $form.ForeColor = [PlaylistStyle]::Text
    $mainFont = New-Object Drawing.Font('Microsoft YaHei UI', 9.75)
    $currentFont = New-Object Drawing.Font($mainFont, [Drawing.FontStyle]::Bold)
    $numberFont = New-Object Drawing.Font('Microsoft YaHei UI', 8.25)
    $form.Font = $mainFont
    $form.KeyPreview = $true
    $form.AutoScaleMode = 'Dpi'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $caption = New-Object PlaylistBar
    $caption.Dock = 'Top'
    $caption.Height = 32
    $caption.BackColor = [PlaylistStyle]::Chrome
    $captionLabel = New-Object Windows.Forms.Label
    $captionLabel.Text = '播放列表'
    $captionLabel.Dock = 'Fill'
    $captionLabel.Padding = New-Object Windows.Forms.Padding(16, 0, 0, 0)
    $captionLabel.TextAlign = 'MiddleLeft'
    $captionLabel.ForeColor = [PlaylistStyle]::Muted
    $captionFont = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $captionLabel.Font = $captionFont
    $closeButton = New-Object PlaylistCloseButton
    $closeButton.BackColor = [PlaylistStyle]::Chrome
    $closeButton.Dock = 'Right'
    $closeButton.Add_Click({ $form.Close() })
    $searchButton = New-Object PlaylistCloseButton
    $searchButton.BackColor = [PlaylistStyle]::Chrome
    $searchButton.SearchIcon = $true
    $searchButton.AccessibleName = '搜索播放列表（Ctrl+F）'
    $searchButton.Dock = 'None'
    $searchButton.Width = 36
    $searchButton.Add_Click({ Set-SearchMode (-not $script:searching); if ($script:searching) { $filter.SelectAll() } })
    $caption.Controls.Add($captionLabel)
    $caption.Controls.Add($closeButton)
    $form.CaptionPanel = $caption
    $form.CaptionLabel = $captionLabel
    $form.CloseButton = $closeButton
    $filter = New-Object Windows.Forms.TextBox
    $footer = New-Object PlaylistFooter
    $footer.Editor = $filter
    $footer.Search = $searchButton
    $footer.Dock = 'Bottom'
    $footer.Height = 32
    $footer.Padding = New-Object Windows.Forms.Padding(8, 3, 8, 3)
    $footer.BackColor = [PlaylistStyle]::Chrome
    $footer.Font = $captionFont
    $form.FooterPanel = $footer
    $filter.Dock = 'None'
    $filter.Visible = $false
    $filter.BackColor = [PlaylistStyle]::Hover
    $filter.ForeColor = $form.ForeColor
    $filter.BorderStyle = 'FixedSingle'
    $filter.AccessibleName = '搜索播放列表'
    $counter = New-Object PlaylistCounterButton
    $counter.Dock = 'None'
    $counter.TextAlign = 'MiddleCenter'
    $counter.ForeColor = [PlaylistStyle]::Muted
    $counter.BackColor = $footer.BackColor
    $counter.FlatStyle = 'Flat'
    $counter.FlatAppearance.BorderSize = 0
    $counter.FlatAppearance.MouseOverBackColor = [PlaylistStyle]::Hover
    $counter.FlatAppearance.MouseDownBackColor = [PlaylistStyle]::Selected
    $counter.Cursor = [Windows.Forms.Cursors]::Hand
    $counter.AccessibleName = [PlaylistStyle]::Locate
    $counter.TabStop = $false
    $footer.Counter = $counter
    $counter.Add_TextChanged({ $footer.PerformLayout() })
    $list = New-Object PlaylistList
    $list.AccessibleName = '播放列表'
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
    [void]$list.Columns.Add('', 44)
    [void]$list.Columns.Add('Title', 270)
    $rowImages = New-Object Windows.Forms.ImageList
    $rowImages.ImageSize = New-Object Drawing.Size(1, 34)
    $rowBitmap = New-Object Drawing.Bitmap(1, 34)
    $rowImages.Images.Add($rowBitmap)
    $list.SmallImageList = $rowImages
    $scroll = New-Object PlaylistScroll($list)
    $form.Controls.Add($list)
    $form.Controls.Add($scroll)
    $footer.Controls.Add($filter)
    $footer.Controls.Add($counter)
    $footer.Controls.Add($searchButton)
    $form.Controls.Add($footer)
    $form.Controls.Add($caption)
    $tip = New-Object PlaylistTip($form.Font)
    $keyFilter = New-Object PlaylistKeys($form)
    $keyFilter.add_Transmit({
        param($keyPhase, $keyName)
        if (-not $ValidateOnly -and $writer -and -not $script:exiting) { Send-Command @('script-message-to', [string]$payload.script, 'key', [string]$payload.token, $keyPhase, $keyName) }
    })
    $form.Add_VisibleChanged({ if (-not $form.Visible) { if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Cancel() } } })
    $form.Add_Deactivate({ if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Cancel() } })
    $counter.Add_Click({ $tip.Cancel(); Send-Action 'locate' })
    $counter.Add_MouseMove({ param($sender,$eventArgs) if ($counter.Enabled) { $tip.Schedule([PlaylistStyle]::Locate,$counter,$eventArgs.Location,$true) } })
    $counter.Add_MouseLeave({ $tip.Cancel() })
    $searchButton.Add_MouseMove({ param($sender,$eventArgs) $tip.Schedule($searchButton.AccessibleName,$searchButton,$eventArgs.Location,$true) })
    $searchButton.Add_MouseLeave({ $tip.Cancel() })
    $form.Add_LocationChanged({ if ($tip) { $tip.Cancel() } })
    $form.Add_Resize({ if ($tip) { $tip.Cancel() } })
    $list.add_ViewportInput({ if ($tip) { $tip.Cancel() } })
    $list.Add_MouseDown({ $tip.Cancel() })
    $list.Add_KeyDown({ $tip.Cancel() })
    $list.Add_DrawColumnHeader({ param($sender, $eventArgs) $eventArgs.DrawDefault = $true })
    $list.Add_DrawSubItem({
        param($sender, $eventArgs)
        $selected = $eventArgs.Item.Selected
        $current = $eventArgs.Item.Tag.index -eq $script:playlistPosition
        $bg = [PlaylistStyle]::RowBackground($current, $selected, ($eventArgs.Item.Tag.id -eq $script:hoverId))
        $fg = if ($eventArgs.ColumnIndex -eq 0) { [PlaylistStyle]::Number } elseif ($current) { [PlaylistStyle]::Accent } else { $form.ForeColor }
        $font = if ($eventArgs.ColumnIndex -eq 0) { $numberFont } elseif ($current) { $currentFont } else { $mainFont }
        $scale = $eventArgs.Graphics.DpiX / 96.0
        $brush = New-Object Drawing.SolidBrush($bg)
        try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
        if ($current -and $eventArgs.ColumnIndex -eq 0) {
            $bar = New-Object Drawing.SolidBrush([PlaylistStyle]::Accent)
            try { $eventArgs.Graphics.FillRectangle($bar, $eventArgs.Bounds.Left, [single]($eventArgs.Bounds.Top + 8*$scale), [single](3*$scale), [single][Math]::Max(1, $eventArgs.Bounds.Height - 16*$scale)) } finally { $bar.Dispose() }
        }
        $textBounds = $eventArgs.Bounds
        if ($eventArgs.ColumnIndex -eq 0) { $textBounds.X += [int](12*$scale); $textBounds.Width = [int](24*$scale) }
        else { $textBounds.Width = [Math]::Max(1,$textBounds.Width-[int](12*$scale)) }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $eventArgs.SubItem.Text, $font,
            $textBounds, $fg, ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix -bor [Windows.Forms.TextFormatFlags]::NoPadding))
        # Selection is a thin blue outline, independent from the current fill.
        # Keyboard navigation strengthens the outline; mouse focus does not.
        if ($eventArgs.ColumnIndex -eq 1 -and ($selected -or ($list.Focused -and $list.KeyboardFocusCue -and $eventArgs.Item.Focused))) {
            $focused = $list.Focused -and $list.KeyboardFocusCue -and $eventArgs.Item.Focused
            $weight = if ($focused) { 2 } else { 1 }
            $pen = New-Object Drawing.Pen([PlaylistStyle]::Accent, [single][Math]::Max(1, $scale*$weight))
            $bounds = $eventArgs.Item.Bounds
            $inset = [int][Math]::Ceiling($scale*$weight/2)
            try { $eventArgs.Graphics.DrawRectangle($pen, $bounds.Left+$inset, $bounds.Top+$inset,
                [Math]::Max(1, [Math]::Min($bounds.Width, $list.ClientSize.Width)-2*$inset-1), [Math]::Max(1,$bounds.Height-2*$inset-1)) }
            finally { $pen.Dispose() }
        }
        if ($eventArgs.Item.Tag.id -eq $script:dropTargetId) {
            # Native InsertionMark is unreliable in Details view; draw the same cue.
            $pen = New-Object Drawing.Pen([PlaylistStyle]::Accent, [single](2*$scale))
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
        }
        if ($item -and -not $script:dragging) { $tip.Schedule((Tooltip-Text $item.Tag.entry),$list,$eventArgs.Location,$false) }
        else { $tip.Cancel() }
    })
    $list.Add_MouseLeave({ $oldHoverId = $script:hoverId; $script:hoverId = ''; Invalidate-HoverRow $oldHoverId; $tip.Cancel() })
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
    $form.ApplyPresentationDpi()
    try { $dark = 1; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4) } catch {}
    try { $borderColor = -2; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 34, [ref]$borderColor, 4) } catch {}

    if ($ValidateOnly) {
        $foregroundBefore = [PlaylistNative]::GetForegroundWindow()
        $script:playlist = @(if ($null -ne $payload.playlist) { $payload.playlist })
        $script:playlistPosition = [int]$payload.position
        if ($payload.filter) { Set-SearchMode $true; $filter.Text = [string]$payload.filter }
        Render-Queue
        $form.PerformLayout()
        [void]$list.Handle
        [Windows.Forms.Application]::DoEvents()
        Render-Queue
        $rows = @($list.Items | ForEach-Object { @{id = $_.Tag.id; index = $_.Tag.index; number = $_.Text; label = $_.SubItems[1].Text; current = $_.Tag.index -eq $script:playlistPosition} })
        foreach ($item in $list.Items) { if ([string]$item.Tag.id -eq [string]$payload.selected_id) { $item.Selected = $true } }
        if ($payload.hover_id) { $script:hoverId = [string]$payload.hover_id }
        $normalCount = $counter.Text
        $beforeBounds = $list.Bounds
        $beforeFooterBounds = $footer.Bounds
        $initialSearch = $script:searching
        $initialFilter = $filter.Text
        Set-SearchMode $true
        $searchBounds = $list.Bounds
        $searchFooterBounds = $footer.Bounds
        $searchBoundsStable = $list.Bounds -eq $beforeBounds
        Set-SearchMode $false
        $restoredBounds = $list.Bounds
        $restoredFooterBounds = $footer.Bounds
        $restoredBoundsStable = $list.Bounds -eq $beforeBounds
        if ($initialSearch) { Set-SearchMode $true; $filter.Text = $initialFilter }
        $searchProbe = @{}
        if ($payload.search_probe) {
            Set-SearchMode $false
            $searchClick = $searchButton.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$searchClick.Invoke($searchButton,@([EventArgs]::Empty))
            $searchProbe.opened = $script:searching -and $searchButton.Active -and $footer.Searching
            $searchProbe.controls_separate = $filter.Right -le $counter.Left -and $counter.Right -le $searchButton.Left
            $filter.Text = 'one'
            $searchProbe.filtered = $list.Items.Count
            [void]$searchClick.Invoke($searchButton,@([EventArgs]::Empty))
            $searchProbe.closed = -not $script:searching -and -not $searchButton.Active -and $filter.Text -eq ''
            $searchProbe.rows_restored = $list.Items.Count
        }
        if ($payload.click_counter -and $counter.Enabled) {
            $clickMethod = $counter.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$clickMethod.Invoke($counter, @([EventArgs]::Empty))
        }
        if ($null -ne $payload.PSObject.Properties['locate_id']) { Locate-Entry ([string]$payload.locate_id) }
        $located = @($list.SelectedItems | ForEach-Object { [string]$_.Tag.id })
        $selectedVisible = $list.SelectedItems.Count -eq 1 -and $list.SelectedItems[0].Bounds.Top -ge 0 -and
            $list.SelectedItems[0].Bounds.Bottom -le $list.ClientSize.Height
        $parentRect = New-Object PlaylistNative+Rect
        $parentRect.Left = 120; $parentRect.Top = -180; $parentRect.Right = 700; $parentRect.Bottom = 900
        $areaRect = New-Object PlaylistNative+Rect
        $areaRect.Left = 0; $areaRect.Top = 0; $areaRect.Right = 1000; $areaRect.Bottom = 800
        $layout = [PlaylistFollower]::Layout($parentRect, $areaRect, 400, $false)
        $tipText = if ($script:playlist.Count) { Tooltip-Text $script:playlist[0] } else { '' }
        $tipSize = [PlaylistTip]::Measure($tipText, $mainFont, 96)
        $painted = $false
        $paintSamples = @{}
        $outlineSamples = @{}
        $counterSamples = @{}
        if ($payload.counter_hover) {
            $hoverMethod = $counter.GetType().GetMethod('OnMouseEnter',[Reflection.BindingFlags]'Instance,NonPublic')
            [void]$hoverMethod.Invoke($counter,@([EventArgs]::Empty))
            $counterCanvas = New-Object Drawing.Bitmap($counter.Width,$counter.Height)
            try {
                $counter.DrawToBitmap($counterCanvas,(New-Object Drawing.Rectangle(0,0,$counter.Width,$counter.Height)))
                $counterSamples.corner = $counterCanvas.GetPixel(0,0).ToArgb()
                $counterSamples.edge = $counterCanvas.GetPixel([int]($counter.Width/2),1).ToArgb()
                $counterSamples.background = $counter.BackColor.ToArgb()
            } finally { $counterCanvas.Dispose() }
        }
        if ($payload.paint_path) {
            $paintPath = [IO.Path]::GetFullPath([string]$payload.paint_path)
            if (-not $paintPath.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'paint-path' }
            $canvas = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
            try {
                $form.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(0,0,$canvas.Width,$canvas.Height)))
                $list.DrawToBitmap($canvas, $list.Bounds)
                $scroll.DrawToBitmap($canvas, $scroll.Bounds)
                $footer.DrawToBitmap($canvas, $footer.Bounds)
                $counter.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($footer.Left + $counter.Left),($footer.Top + $counter.Top),$counter.Width,$counter.Height)))
                if ($script:searching) { $filter.DrawToBitmap($canvas,(New-Object Drawing.Rectangle(($footer.Left+$filter.Left),($footer.Top+$filter.Top),$filter.Width,$filter.Height))) }
                $caption.DrawToBitmap($canvas, $caption.Bounds)
                $captionLabel.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($caption.Left + $captionLabel.Left),($caption.Top + $captionLabel.Top),$captionLabel.Width,$captionLabel.Height)))
                $closeButton.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($caption.Left + $closeButton.Left),($caption.Top + $closeButton.Top),$closeButton.Width,$closeButton.Height)))
                $searchButton.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($footer.Left + $searchButton.Left),($footer.Top + $searchButton.Top),$searchButton.Width,$searchButton.Height)))
                foreach ($item in $list.Items) {
                    $point = New-Object Drawing.Point(($list.Left + $list.Width - 20), ($list.Top + $item.Bounds.Top + [int]($item.Bounds.Height / 2)))
                    if ($point.Y -ge $list.Top -and $point.Y -lt $list.Bottom) {
                        $paintSamples[[string]$item.Tag.id] = $canvas.GetPixel($point.X,$point.Y).ToArgb()
                        $edgeY = $list.Top + $item.Bounds.Top + [int][Math]::Ceiling($canvas.HorizontalResolution/96.0/2)
                        $outlineSamples[[string]$item.Tag.id] = $canvas.GetPixel(($list.Left+$list.Columns[0].Width+10),$edgeY).ToArgb()
                    }
                }
                $canvas.Save($paintPath, [Drawing.Imaging.ImageFormat]::Png)
                $painted = $true
            } finally { $canvas.Dispose() }
        }
        $windowStyle = [PlaylistNative]::GetWindowLongPtr($form.Handle,-16).ToInt64()
        $closeHidden = $null
        if ($payload.click_close) {
            $closeClick = $closeButton.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$closeClick.Invoke($closeButton, @([EventArgs]::Empty))
            $closeHidden = -not $script:desiredVisible -and -not $form.Visible -and -not $form.IsDisposed
        }
        $outputWriter.WriteLine((@{ok = $true; rows = $rows; count = $normalCount; shown = $form.Visible;
            presentation = @{native_caption = ($windowStyle -band 0xC00000) -ne 0; sizing_frame = ($windowStyle -band 0x40000) -ne 0;
                title = $captionLabel.Text; close_name = $closeButton.AccessibleName; close_hides = $closeHidden;
                title_above_list = $caption.Bottom -le $list.Top; empty_text = $list.EmptyText; font = $form.Font.Name;
                row_backgrounds = $paintSamples; row_outlines = $outlineSamples; counter_hover = $counterSamples;
                current_bold = $currentFont.Bold; row_columns = $list.Columns.Count;
                caption_height = $caption.Height; client_width = $form.ClientSize.Width;
                caption_bounds = $caption.Bounds.ToString(); title_bounds = $captionLabel.Bounds.ToString(); close_bounds = $closeButton.Bounds.ToString();
                search_name = $searchButton.AccessibleName; search_not_overlapping = $counter.Right -le $searchButton.Left;
                search_in_footer = $searchButton.Parent -eq $footer; search_bounds = $searchButton.Bounds.ToString();
                search_field_width = $filter.Width; search_controls_separate = -not $script:searching -or ($filter.Right -le $counter.Left -and $counter.Right -le $searchButton.Left);
                search_toggle = $searchProbe; counter_width = $counter.Width; footer_width = $footer.ClientSize.Width};
            footer_bounds_stable = $searchBoundsStable -and $restoredBoundsStable -and $beforeFooterBounds -eq $searchFooterBounds -and $beforeFooterBounds -eq $restoredFooterBounds;
            layout_bounds = @{normal = $beforeBounds.ToString(); search = $searchBounds.ToString(); restored = $restoredBounds.ToString();
                footer_normal = $beforeFooterBounds.ToString(); footer_search = $searchFooterBounds.ToString(); footer_restored = $restoredFooterBounds.ToString()};
            locate = @{selected_ids = $located; selected_visible = $selectedVisible; top_index = $list.TopIndex;
                focused_id = if ($list.FocusedItem) { [string]$list.FocusedItem.Tag.id } else { '' };
                searching = $script:searching; filter = $filter.Text; counter_enabled = $counter.Enabled;
                counter_name = $counter.AccessibleName; counter_hand = $counter.Cursor -eq [Windows.Forms.Cursors]::Hand;
                focus_preserved = [PlaylistNative]::GetForegroundWindow() -eq $foregroundBefore};
            actions = $script:validationActions.ToArray(); caption_empty = $form.Text -eq '';
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
    Send-Command @('observe_property', 5, 'user-data/mpvnet/shortcuts')
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
                if ($readTask.IsFaulted -or $null -eq $readTask.Result) {
                    if ($parentProcess.HasExited) { Exit-Window; return }
                    throw 'ipc-disconnected'
                }
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
                        'user-data/mpvnet/shortcuts' {
                            if ($null -ne $playlistEvent.data -and $playlistEvent.data.schema -eq 1 -and
                                $null -ne $playlistEvent.data.forward_keys -and $null -ne $playlistEvent.data.opening_keys) {
                                $keyFilter.UpdateBindings([string[]]@($playlistEvent.data.forward_keys), [string[]]@($playlistEvent.data.opening_keys))
                            }
                        }
                        'user-data/mpvnet/playlist-window' {
                            if ($playlistEvent.data.token -eq $payload.token) { $script:desiredVisible = [bool]$playlistEvent.data.visible }
                        }
                    }
                } elseif ($playlistEvent.event -eq 'client-message' -and $playlistEvent.args.Count -ge 3 -and
                    $playlistEvent.args[0] -eq 'mpvnet-playlist-locate' -and $playlistEvent.args[1] -eq $payload.token) {
                    Locate-Entry ([string]$playlistEvent.args[2])
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
    if ($mainFont) { $mainFont.Dispose() }
    if ($currentFont) { $currentFont.Dispose() }
    if ($numberFont) { $numberFont.Dispose() }
    if ($captionFont) { $captionFont.Dispose() }
    if ($rowImages) { $rowImages.Dispose() }
    if ($rowBitmap) { $rowBitmap.Dispose() }
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($context) { $context.Dispose() }
    $outputWriter.Dispose()
}
