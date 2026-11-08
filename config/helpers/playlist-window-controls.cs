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
// Dismiss before native hit testing can act on rows that move when filtering
// ends. Own-window messages only: never intercept another application's input.
public sealed class PlaylistSearchDismiss : IMessageFilter, IDisposable {
    readonly Form form;
    readonly Control editor;
    int swallowedUp, swallowedDouble;
    public bool Active;
    public event Action Dismiss;
    public PlaylistSearchDismiss(Form owner, Control input) {
        form=owner;editor=input;Application.AddMessageFilter(this);
    }
    public bool PreFilterMessage(ref Message message) {
        Control target=Control.FromChildHandle(message.HWnd);
        if(target==null || (target!=form && !form.Contains(target)))return false;
        int kind=message.Msg;
        if(swallowedUp!=0 && kind==swallowedUp) { swallowedUp=0;return true; }
        if(swallowedDouble!=0 && kind==swallowedDouble) { swallowedUp=kind-1;swallowedDouble=0;return true; }
        bool down=kind==0x201 || kind==0x204 || kind==0x207 ||
            kind==0xA1 || kind==0xA4 || kind==0xA7;
        if(!down)return false;
        swallowedUp=0;swallowedDouble=0;
        if(!Active || target==editor || editor.Contains(target))return false;
        swallowedUp=kind+1;swallowedDouble=kind+2;
        if(Dismiss!=null)Dismiss();
        return true;
    }
    public void Dispose() { Application.RemoveMessageFilter(this); }
}
public sealed class PlaylistKeys : IMessageFilter, IDisposable {
    readonly PlaylistForm form;
    readonly System.Collections.Generic.Dictionary<int,string> held = new System.Collections.Generic.Dictionary<int,string>();
    readonly System.Collections.Generic.HashSet<string> allowed = new System.Collections.Generic.HashSet<string>(new string[]{
        "d","Space","Left","Right","Shift+Left","Shift+Right","Ctrl+Left","Ctrl+Right",",",".","Ctrl+r","Ctrl+[","Ctrl+]","Ctrl+BS","s","Alt+s","PGUP","PGDWN","Alt+Left","Alt+Right","Alt+BS","Ctrl+Shift+s","Ctrl+c","m","M","l","Ctrl+Shift+l","Home","End","Enter","Ctrl+t","Ctrl+0","Ctrl+i","Ctrl+m","Tab","Alt+o","`","Ctrl+Shift+c","Ctrl+Shift+v","p"});
    readonly System.Collections.Generic.HashSet<string> opening = new System.Collections.Generic.HashSet<string>(new string[]{"Ctrl+i","Ctrl+m","Alt+s","Tab","`","Ctrl+Shift+s"});
    public bool SearchActive;
    public bool MenuActive;
    readonly System.Collections.Generic.HashSet<int> menuHandoff = new System.Collections.Generic.HashSet<int>();
    public event Action<string,string> Transmit;
    public PlaylistKeys(PlaylistForm window) { form=window;Application.AddMessageFilter(this); }
    public static string Canonical(int vk, Keys modifiers) {
        return ShortcutKeyNames.FromVirtualKey(vk, (modifiers & Keys.Control)!=0,
            (modifiers & Keys.Alt)!=0, (modifiers & Keys.Shift)!=0);
    }
    public static bool IsCaptionActivation(Control target, int vk, Keys modifiers) {
        return target is PlaylistCloseButton && modifiers==Keys.None && (vk==32 || vk==13);
    }
    public static bool IsContextInvocation(int vk, Keys modifiers) {
        return (vk==93 && modifiers==Keys.None) || (vk==121 && modifiers==Keys.Shift);
    }
    public void UpdateBindings(string[] keys, string[] uiKeys) {
        keys=keys ?? new string[0];uiKeys=uiKeys ?? new string[0];
        if(allowed.SetEquals(keys) && opening.SetEquals(uiKeys))return;
        ReleaseAll();allowed.Clear();opening.Clear();
        allowed.UnionWith(keys);opening.UnionWith(uiKeys);
    }
    void Send(string phase,string key) { if(Transmit!=null)Transmit(phase,key); }
    public void ReleaseAll() { held.Clear();Send("release",""); }
    public void EndMenu() {
        MenuActive=false;
        menuHandoff.UnionWith(new int[]{13,27,32,37,38,39,40,35,36,33,34,9,93,121,46,70});
    }
    public bool FilterMenuKey(int message,int vk,long flags) {
        if(!menuHandoff.Contains(vk))return false;
        bool down=message==0x100 || message==0x104,up=message==0x101 || message==0x105;
        if(up) { menuHandoff.Remove(vk);return true; }
        if(down) {
            if((flags & 0x40000000L)!=0)return true;
            menuHandoff.Remove(vk);
        }
        return false;
    }
    public bool PreFilterMessage(ref Message message) {
        if(!form.ContainsFocus || MenuActive)return false;
        bool down=message.Msg==0x100 || message.Msg==0x104,up=message.Msg==0x101 || message.Msg==0x105;
        if(!down && !up)return false;
        int vk=message.WParam.ToInt32();
        if(FilterMenuKey(message.Msg,vk,message.LParam.ToInt64()))return true;
        if(SearchActive)return false;
        if(IsContextInvocation(vk,Control.ModifierKeys))return false;
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
