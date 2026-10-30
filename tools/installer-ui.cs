using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Presentation only. The PowerShell installer owns maintenance plans and work.
public class KitInstallerButton : Button
{
    bool primary, subtle, hover, pressed, keyboardPressed;
    public bool Primary { get { return primary; } set { primary = value; Invalidate(); } }
    public bool Subtle { get { return subtle; } set { subtle = value; Invalidate(); } }

    public KitInstallerButton()
    {
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        BackColor = Color.FromArgb(36, 36, 36); ForeColor = Color.FromArgb(242, 242, 242);
        UseVisualStyleBackColor = false;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; pressed = false; Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressed = e.Button == MouseButtons.Left; Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); pressed = false; Invalidate(); }
    protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); if (!Capture) pressed = false; Invalidate(); }
    protected override void OnKeyDown(KeyEventArgs e) { keyboardPressed = e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter; base.OnKeyDown(e); Invalidate(); }
    protected override void OnKeyUp(KeyEventArgs e) { keyboardPressed = false; base.OnKeyUp(e); Invalidate(); }
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); keyboardPressed = false; Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); pressed = keyboardPressed = false; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        float scale = e.Graphics.DpiX / 96f;
        Color parentColor = Parent == null ? Color.FromArgb(21, 21, 21) : Parent.BackColor;
        bool understated = subtle && !primary;
        e.Graphics.Clear(parentColor);
        Color fill = primary ? Color.FromArgb(18, 135, 187) : understated ? parentColor : BackColor;
        if (Enabled && (pressed || keyboardPressed)) fill = primary ? Color.FromArgb(13, 111, 157) : Color.FromArgb(64, 64, 64);
        else if (Enabled && hover && !primary) fill = Color.FromArgb(53, 53, 53);
        if (!Enabled) fill = understated ? parentColor : Color.FromArgb(35, 35, 35);
        float inset = Math.Max(1, scale);
        var rect = new RectangleF(inset / 2, inset / 2, Math.Max(1, Width - inset - 1), Math.Max(1, Height - inset - 1));
        float radius = Math.Min(3 * scale, Math.Min(rect.Width, rect.Height) / 2);
        using (var path = Rounded(rect, radius)) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var brush = new SolidBrush(fill)) e.Graphics.FillPath(brush, path);
            if (!understated || Enabled && Focused)
                using (var pen = new Pen(Enabled && Focused ? (primary ? Color.FromArgb(242, 242, 242) : Color.FromArgb(18, 135, 187)) : Enabled && primary && hover ? Color.FromArgb(171, 171, 171) : Color.FromArgb(85, 85, 85), Enabled && Focused ? 2 * inset : inset))
                    e.Graphics.DrawPath(pen, path);
        }
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;
        flags |= TextAlign == ContentAlignment.MiddleLeft ? TextFormatFlags.Left : TextAlign == ContentAlignment.MiddleRight ? TextFormatFlags.Right : TextFormatFlags.HorizontalCenter;
        if (!UseMnemonic) flags |= TextFormatFlags.NoPrefix;
        else if (!ShowKeyboardCues) flags |= TextFormatFlags.HidePrefix;
        Rectangle text = Rectangle.Inflate(ClientRectangle, -(int)Math.Ceiling(8 * scale), 0);
        TextRenderer.DrawText(e.Graphics, Text, Font, text, Enabled ? ForeColor : Color.FromArgb(136, 136, 136), flags);
    }
    static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        var path = new GraphicsPath(); float diameter = Math.Max(1, radius * 2);
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90); path.CloseFigure(); return path;
    }
}

// Keep the native Edit control for selection, clipboard and keyboard behavior.
// Only the vertical scrollbar is drawn here; scrolling still uses Edit messages.
public sealed class KitInstallerTextBox : TextBox
{
    [StructLayout(LayoutKind.Sequential)] struct FormattingRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr GetFormattingRect(IntPtr window, int message, IntPtr wparam, ref FormattingRect rect);
    readonly ScrollStrip strip;
    ScrollBars logicalBars;
    bool syncing;
    int wheelCarry;
    public new ScrollBars ScrollBars {
        get { return logicalBars; }
        set {
            if (value != System.Windows.Forms.ScrollBars.None && value != System.Windows.Forms.ScrollBars.Vertical)
                throw new ArgumentOutOfRangeException("value", "安装器文本框仅使用纵向滚动条。");
            logicalBars = value; base.ScrollBars = System.Windows.Forms.ScrollBars.None; SyncScroll();
        }
    }
    public int FirstVisibleLine { get { return IsHandleCreated ? SendMessage(Handle, 0xCE, IntPtr.Zero, IntPtr.Zero).ToInt32() : 0; } }
    public int TotalLines { get { return IsHandleCreated ? Math.Max(1, SendMessage(Handle, 0xBA, IntPtr.Zero, IntPtr.Zero).ToInt32()) : 1; } }
    public int PageLines {
        get {
            int height = ClientSize.Height, lineHeight = Math.Max(1, Font.Height);
            if (IsHandleCreated) {
                var rect = new FormattingRect(); GetFormattingRect(Handle, 0xB2, IntPtr.Zero, ref rect);
                height = Math.Max(0, rect.Bottom - rect.Top);
                // Font.Height can differ from Edit's integer row height at
                // system-aware 150% DPI. Measure adjacent native visual rows,
                // including wrapped rows, rather than round font metrics.
                int line = Math.Min(FirstVisibleLine, Math.Max(0, TotalLines - 2));
                int first = GetFirstCharIndexFromLine(line), next = GetFirstCharIndexFromLine(line + 1);
                if (first >= 0 && next >= 0) {
                    int actual = GetPositionFromCharIndex(next).Y - GetPositionFromCharIndex(first).Y;
                    if (actual > 0) lineHeight = actual;
                }
            }
            return Math.Max(1, height / lineHeight);
        }
    }
    public KitInstallerTextBox()
    {
        base.ScrollBars = System.Windows.Forms.ScrollBars.None;
        strip = new ScrollStrip(this); Controls.Add(strip);
    }
    protected override CreateParams CreateParams {
        get { var value = base.CreateParams; value.Style = (value.Style & ~0x00300000) | 0x02000000; return value; }
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); SyncScroll(); }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); SyncScroll(); }
    protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); SyncScroll(); }
    protected override void OnResize(EventArgs e) { base.OnResize(e); SyncScroll(); }
    protected override void OnBackColorChanged(EventArgs e) { base.OnBackColorChanged(e); if (strip != null) strip.BackColor = BackColor; }
    public void ScrollToLine(int line)
    {
        if (!IsHandleCreated || !Multiline) return;
        int target = Math.Max(0, Math.Min(line, Math.Max(0, TotalLines - PageLines)));
        SendMessage(Handle, 0xB6, IntPtr.Zero, new IntPtr(target - FirstVisibleLine)); SyncScroll();
    }
    void Wheel(int delta)
    {
        wheelCarry += delta; int steps = wheelCarry / 120; wheelCarry %= 120;
        int lines = SystemInformation.MouseWheelScrollLines;
        if (steps != 0 && lines != 0) ScrollToLine(FirstVisibleLine - steps * (lines < 0 ? PageLines : lines));
    }
    void SyncScroll()
    {
        if (syncing || strip == null || IsDisposed || !IsHandleCreated) return;
        syncing = true;
        try {
            int width = Math.Max(8, (int)Math.Round(10 * DeviceDpi / 96.0));
            bool vertical = Multiline && logicalBars == System.Windows.Forms.ScrollBars.Vertical;
            strip.SetBounds(Math.Max(0, ClientSize.Width - width), 0, width, ClientSize.Height);
            // Reserve the strip even when all text fits, avoiding wrap oscillation.
            int margin = vertical ? width + Math.Max(2, (int)Math.Round(3 * DeviceDpi / 96.0)) : 2;
            SendMessage(Handle, 0xD3, new IntPtr(2), new IntPtr(margin << 16));
            strip.Sync(TotalLines, PageLines, FirstVisibleLine);
            strip.Visible = vertical && TotalLines > PageLines;
            strip.BringToFront();
        } finally { syncing = false; }
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x20A && Multiline && logicalBars == System.Windows.Forms.ScrollBars.Vertical) {
            Wheel((short)(m.WParam.ToInt64() >> 16)); m.Result = IntPtr.Zero; return;
        }
        base.WndProc(ref m);
        if (m.Msg == 0x100 || m.Msg == 0x101 || m.Msg == 0x200 || m.Msg == 0x202 || m.Msg == 0x113 ||
            m.Msg == 0x115 || m.Msg == 0xB6 || m.Msg == 0xB7 || m.Msg == 0xC || m.Msg == 0xC2 || m.Msg == 0x30)
            SyncScroll();
    }
    sealed class ScrollStrip : Control
    {
        readonly KitInstallerTextBox editor;
        int count, page, first, dragOffset;
        Rectangle thumb;
        bool hover, dragging;
        public ScrollStrip(KitInstallerTextBox editor)
        {
            this.editor = editor; TabStop = false; BackColor = editor.BackColor;
            AccessibleName = "垂直滚动条"; AccessibleRole = AccessibleRole.ScrollBar;
            SetStyle(ControlStyles.Selectable, false);
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        public void Sync(int count, int page, int first)
        {
            if (this.count == count && this.page == page && this.first == first) return;
            this.count = count; this.page = page; this.first = first; LayoutThumb(); Invalidate();
        }
        void LayoutThumb()
        {
            if (count <= page || Height < 1) { thumb = Rectangle.Empty; return; }
            int pad = Math.Max(1, (int)Math.Round(2 * DeviceDpi / 96.0));
            int track = Math.Max(1, Height - pad * 2);
            int height = Math.Min(track, Math.Max((int)Math.Round(24 * DeviceDpi / 96.0), (int)Math.Round(track * page / (double)count)));
            int top = pad + (int)Math.Round((track - height) * Math.Min(first, count - page) / (double)(count - page));
            int width = Math.Min(Width, Math.Max(4, (int)Math.Round(6 * DeviceDpi / 96.0)));
            thumb = new Rectangle((Width - width) / 2, top, width, height);
        }
        protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutThumb(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(editor.BackColor); if (thumb.IsEmpty) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = new GraphicsPath()) {
                float diameter = Math.Min(thumb.Width, thumb.Height);
                path.AddArc(thumb.Left, thumb.Top, diameter, diameter, 180, 180);
                path.AddArc(thumb.Left, thumb.Bottom - diameter, diameter, diameter, 0, 180); path.CloseFigure();
                using (var brush = new SolidBrush(dragging ? Color.FromArgb(18, 135, 187) : hover ? Color.FromArgb(153, 153, 153) : Color.FromArgb(112, 112, 112))) e.Graphics.FillPath(brush, path);
            }
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e); if (e.Button != MouseButtons.Left || thumb.IsEmpty) return;
            if (thumb.Contains(e.Location)) { dragging = true; dragOffset = e.Y - thumb.Top; Capture = true; Invalidate(); }
            else editor.ScrollToLine(first + (e.Y < thumb.Top ? -page : page));
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) {
                int pad = Math.Max(1, (int)Math.Round(2 * DeviceDpi / 96.0));
                int track = Math.Max(1, Height - pad * 2 - thumb.Height);
                int offset = Math.Max(0, Math.Min(track, e.Y - dragOffset - pad));
                editor.ScrollToLine((int)Math.Round(offset * Math.Max(0, count - page) / (double)track));
            } else { bool next = thumb.Contains(e.Location); if (hover != next) { hover = next; Invalidate(); } }
        }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); dragging = false; Capture = false; Invalidate(); }
        protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); if (!Capture) dragging = false; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; Invalidate(); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); if (!Visible) { dragging = false; Capture = false; } }
        protected override void OnMouseWheel(MouseEventArgs e) {
            base.OnMouseWheel(e);
            var handled = e as HandledMouseEventArgs; if (handled != null) handled.Handled = true;
            editor.Wheel(e.Delta);
        }
    }
}

public class KitInstallerForm : Form
{
    [StructLayout(LayoutKind.Sequential)] struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MinMaxInfo {
        public NativePoint Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize;
    }
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wparam, IntPtr lparam);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int length);

    readonly float scale;
    readonly Font uiFont, captionFont;
    readonly Panel caption;
    readonly Label captionText;
    readonly CaptionButton minimize, maximize, close;
    bool arranging;
    public Panel ContentHost;

    public KitInstallerForm(float scale)
    {
        this.scale = scale > 0 && !Single.IsInfinity(scale) && !Single.IsNaN(scale) ? scale : 1;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.FromArgb(21, 21, 21); ForeColor = Color.FromArgb(242, 242, 242);
        uiFont = new Font("Microsoft YaHei UI", 10.5f); Font = uiFont;
        captionFont = new Font("Microsoft YaHei UI", 9);
        ShowInTaskbar = true; ShowIcon = false; FormBorderStyle = FormBorderStyle.Sizable;
        StartPosition = FormStartPosition.CenterScreen;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        ContentHost = new Panel { Dock = DockStyle.Fill, BackColor = BackColor, Margin = Padding.Empty };
        caption = new Panel { Dock = DockStyle.Top, Height = Pixels(36), BackColor = BackColor };
        captionText = new Label { TextAlign = ContentAlignment.MiddleLeft, Font = captionFont,
            Padding = new Padding(Pixels(16), 0, 0, 0), ForeColor = Color.FromArgb(213, 213, 213), AutoEllipsis = true };
        minimize = new CaptionButton(this.scale, "\uE921", "最小化", false);
        maximize = new CaptionButton(this.scale, "\uE922", "最大化", false);
        close = new CaptionButton(this.scale, "\uE8BB", "关闭", true);
        minimize.Click += delegate { WindowState = FormWindowState.Minimized; };
        maximize.Click += delegate { ToggleMaximize(); };
        close.Click += delegate { Close(); };
        caption.Controls.Add(captionText); caption.Controls.Add(minimize); caption.Controls.Add(maximize); caption.Controls.Add(close);
        caption.SizeChanged += delegate { UpdateCaption(); };
        caption.MouseDown += DragCaption; captionText.MouseDown += DragCaption;
        caption.MouseDoubleClick += CaptionDoubleClick; captionText.MouseDoubleClick += CaptionDoubleClick;
        Controls.Add(ContentHost); Controls.Add(caption);
        ClientSize = new Size(Pixels(800), Pixels(750));
    }
    int Pixels(int value) { return Math.Max(1, (int)Math.Round(value * scale)); }
    void ToggleMaximize() { if (MaximizeBox) WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; }
    void DragCaption(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || e.Clicks != 1 || !IsHandleCreated) return;
        ReleaseCapture(); SendMessage(Handle, 0xA1, new IntPtr(2), IntPtr.Zero);
    }
    void CaptionDoubleClick(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ToggleMaximize(); }
    void UpdateCaption()
    {
        if (caption == null || arranging) return;
        arranging = true;
        try {
            minimize.Visible = MinimizeBox; maximize.Visible = MaximizeBox; close.Visible = ControlBox;
            maximize.Glyph = WindowState == FormWindowState.Maximized ? "\uE923" : "\uE922";
            maximize.AccessibleName = WindowState == FormWindowState.Maximized ? "还原" : "最大化";
            maximize.Invalidate(); captionText.Text = Text;
            int right=caption.ClientSize.Width;
            foreach(var button in new[] { close, maximize, minimize }) {
                bool present=button==close ? ControlBox : button==maximize ? MaximizeBox : MinimizeBox;
                if(!present)continue;
                right-=Pixels(44);button.SetBounds(right,0,Pixels(44),caption.ClientSize.Height);
            }
            captionText.SetBounds(0,0,Math.Max(0,right),caption.ClientSize.Height);
        } finally { arranging = false; }
    }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); UpdateCaption(); }
    protected override void OnLayout(LayoutEventArgs e) { base.OnLayout(e); UpdateCaption(); }
    protected override void OnResize(EventArgs e) { base.OnResize(e); UpdateCaption(); }
    protected override void SetClientSizeCore(int x, int y)
    {
        base.SetClientSizeCore(x, y);
        // WinForms still calculates a standard sizing/caption allowance from
        // FormBorderStyle. Our NCCALCSIZE client occupies the entire window.
        if (IsHandleCreated && (Width != x || Height != y)) Size = new Size(x, y);
    }
    protected override void CreateHandle()
    {
        Size requestedClient = ClientSize;
        base.CreateHandle();
        if (requestedClient.Width > 0 && requestedClient.Height > 0 && ClientSize != requestedClient) Size = requestedClient;
    }
    protected override CreateParams CreateParams { get { var value = base.CreateParams; value.Style &= ~0x00C00000; return value; } }
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e); UpdateCaption(); ApplyFrame();
    }
    void ApplyFrame()
    {
        if (!IsHandleCreated) return;
        try {
            int dark = 1, border = -2, corner = 2;
            DwmSetWindowAttribute(Handle, 20, ref dark, 4);
            DwmSetWindowAttribute(Handle, 34, ref border, 4);
            DwmSetWindowAttribute(Handle, 33, ref corner, 4);
        } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x85) { m.Result = IntPtr.Zero; return; }
        if (m.Msg == 0x86) { m.Result = new IntPtr(1); return; }
        if (m.Msg == 0x83 && m.WParam != IntPtr.Zero) { m.Result = IntPtr.Zero; return; }
        if (m.Msg == 0x84) {
            NativeRect rect;
            if (WindowState != FormWindowState.Maximized && FormBorderStyle == FormBorderStyle.Sizable && GetWindowRect(Handle, out rect)) {
                int x = (short)(m.LParam.ToInt64() & 0xffff), y = (short)((m.LParam.ToInt64() >> 16) & 0xffff), edge = Pixels(5);
                bool left = x < rect.Left + edge, right = x >= rect.Right - edge, top = y < rect.Top + edge, bottom = y >= rect.Bottom - edge;
                int hit = top ? (left ? 13 : right ? 14 : 12) : bottom ? (left ? 16 : right ? 17 : 15) : left ? 10 : right ? 11 : 1;
                m.Result = new IntPtr(hit); return;
            }
            m.Result = new IntPtr(1); return;
        }
        base.WndProc(ref m);
        if (m.Msg == 0x24 && m.LParam != IntPtr.Zero) {
            var info = (MinMaxInfo)Marshal.PtrToStructure(m.LParam, typeof(MinMaxInfo));
            Screen screen = Screen.FromHandle(Handle); Rectangle area = screen.WorkingArea, bounds = screen.Bounds;
            info.MaxPosition.X = area.Left - bounds.Left; info.MaxPosition.Y = area.Top - bounds.Top;
            info.MaxSize.X = area.Width; info.MaxSize.Y = area.Height;
            Marshal.StructureToPtr(info, m.LParam, false);
        }
        if (m.Msg == 0x31E) ApplyFrame();
    }
    protected override void Dispose(bool disposing) { base.Dispose(disposing); if (disposing) { if(uiFont != null)uiFont.Dispose(); if(captionFont != null)captionFont.Dispose(); } }

    sealed class CaptionButton : Button
    {
        readonly Font symbolFont; readonly bool close;
        bool hover, pressed;
        public string Glyph;
        public CaptionButton(float scale, string glyph, string name, bool close)
        {
            this.close = close; Glyph = glyph; AccessibleName = name; Text = "";
            Width = Math.Max(1, (int)Math.Round(44 * scale)); Dock = DockStyle.None;
            symbolFont = new Font("Segoe MDL2 Assets", 9); TabStop = true; FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = pressed = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressed = e.Button == MouseButtons.Left; Invalidate(); }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); pressed = false; Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(pressed ? (close ? Color.FromArgb(181, 50, 66) : Color.FromArgb(65, 65, 65)) : hover ? (close ? Color.FromArgb(143, 38, 51) : Color.FromArgb(48, 48, 48)) : Parent.BackColor);
            TextRenderer.DrawText(e.Graphics, Glyph, symbolFont, ClientRectangle, Color.FromArgb(229, 229, 229), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            if (Focused) using (var pen = new Pen(Color.FromArgb(18, 135, 187), 2)) e.Graphics.DrawRectangle(pen, 1, 1, Math.Max(1, Width - 3), Math.Max(1, Height - 3));
        }
        protected override void Dispose(bool disposing) { base.Dispose(disposing); if (disposing) symbolFont.Dispose(); }
    }
}

public sealed class KitInstallerConfirmation : KitInstallerForm
{
    readonly float factor;
    readonly string messageContents, detailsContents, detailsTitle;
    readonly Panel body;
    bool detailsExpanded;
    public KitInstallerButton ConfirmButton, CancelAction, DetailsButton;
    public TextBox MessageText, DetailsText;
    public bool DetailsExpanded { get { return detailsExpanded; } }
    public KitInstallerConfirmation(float scale, string message, string caption, string confirmLabel)
        : this(scale, message, caption, confirmLabel, "", "") { }
    public KitInstallerConfirmation(float scale, string summary, string caption, string confirmLabel, string detailsTitle, string details) : base(scale)
    {
        factor = scale > 0 && !Single.IsInfinity(scale) && !Single.IsNaN(scale) ? scale : 1;
        messageContents = NormalizeLines(summary);
        detailsContents = NormalizeLines(details);
        this.detailsTitle = String.IsNullOrEmpty(detailsTitle) ? "查看详情" : detailsTitle;
        Text = caption ?? "确认操作"; MinimizeBox = false; MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedDialog; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        FitWorkingArea(Screen.FromPoint(Cursor.Position).WorkingArea);
        int pad = (int)Math.Round(24 * factor), gap = (int)Math.Round(8 * factor);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = (int)Math.Round(68 * factor),
            FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(pad, (int)Math.Round(12 * factor), pad, (int)Math.Round(16 * factor)), BackColor = BackColor };
        ConfirmButton = new KitInstallerButton { Text = confirmLabel ?? "继续", Primary = true,
            Width = (int)Math.Round(132 * factor), Height = (int)Math.Round(36 * factor), Margin = Padding.Empty,
            DialogResult = DialogResult.OK, AccessibleName = confirmLabel ?? "继续", TabIndex = 1 };
        CancelAction = new KitInstallerButton { Text = "取消", Width = (int)Math.Round(104 * factor), Height = (int)Math.Round(36 * factor),
            Margin = new Padding(0, 0, gap, 0), DialogResult = DialogResult.Cancel, AccessibleName = "取消", TabIndex = 0 };
        actions.Controls.Add(ConfirmButton); actions.Controls.Add(CancelAction);
        actions.SizeChanged += delegate {
            int usable = Math.Max(2, actions.ClientSize.Width - actions.Padding.Horizontal - gap);
            CancelAction.Width = Math.Min((int)Math.Round(104 * factor), Math.Max(1, usable / 2));
            ConfirmButton.Width = Math.Min((int)Math.Round(132 * factor), Math.Max(1, usable - CancelAction.Width));
        };
        body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(pad, (int)Math.Round(16 * factor), pad, gap), BackColor = BackColor };
        MessageText = new KitInstallerTextBox { Multiline = true, ReadOnly = true, WordWrap = true, ScrollBars = ScrollBars.Vertical,
            BorderStyle = BorderStyle.None, Text = messageContents, BackColor = BackColor,
            ForeColor = ForeColor, AccessibleName = "操作确认内容", ShortcutsEnabled = true, TabIndex = 0 };
        DetailsButton = new KitInstallerButton { Text = this.detailsTitle, AccessibleName = this.detailsTitle,
            Subtle = true, Visible = detailsContents.Length > 0, Margin = Padding.Empty, TabIndex = 1 };
        DetailsText = new KitInstallerTextBox { Multiline = true, ReadOnly = true, WordWrap = true, ScrollBars = ScrollBars.Vertical,
            BorderStyle = BorderStyle.None, Text = detailsContents, BackColor = BackColor, Visible = false,
            ForeColor = Color.FromArgb(190, 190, 190), AccessibleName = this.detailsTitle, ShortcutsEnabled = true, TabIndex = 2 };
        DetailsButton.Click += delegate { ToggleDetails(); };
        body.Controls.Add(MessageText); body.Controls.Add(DetailsButton); body.Controls.Add(DetailsText);
        body.SizeChanged += delegate { LayoutBody(); };
        ContentHost.Controls.Add(body); ContentHost.Controls.Add(actions);
        AcceptButton = CancelAction; CancelButton = CancelAction; ActiveControl = CancelAction;
        LayoutBody();
    }
    static string NormalizeLines(string text) { return (text ?? "").Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", Environment.NewLine); }
    int MeasureContent(string text, int width)
    {
        return TextRenderer.MeasureText(text, Font, new Size(Math.Max(1, width), Int32.MaxValue),
            TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPadding).Height;
    }
    void ToggleDetails()
    {
        if (detailsContents.Length == 0) return;
        detailsExpanded = !detailsExpanded;
        DetailsText.Visible = detailsExpanded;
        DetailsButton.Text = detailsExpanded ? "收起详情" : detailsTitle;
        DetailsButton.AccessibleName = DetailsButton.Text;
        Rectangle area = Screen.FromControl(Owner ?? this).WorkingArea;
        FitWorkingArea(area); LayoutBody();
        Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
    }
    void LayoutBody()
    {
        if (body == null || MessageText == null || DetailsText == null || DetailsButton == null) return;
        int width = Math.Max(1, body.ClientSize.Width - body.Padding.Horizontal);
        int available = Math.Max(1, body.ClientSize.Height - body.Padding.Vertical);
        int toggleHeight = detailsContents.Length > 0 ? (int)Math.Round(32 * factor) : 0;
        int gap = detailsContents.Length > 0 ? (int)Math.Round(8 * factor) : 0;
        int textSpace = Math.Max(1, available - toggleHeight - gap);
        int summaryHeight = textSpace;
        if (detailsExpanded) {
            int natural = MeasureContent(messageContents, width - (int)Math.Round(14 * factor)) + (int)Math.Round(8 * factor);
            summaryHeight = Math.Max(1, Math.Min(natural, (int)Math.Round(textSpace * 0.55)));
        }
        MessageText.SetBounds(body.Padding.Left, body.Padding.Top, width, summaryHeight);
        int y = MessageText.Bottom + gap;
        int toggleWidth = Math.Min(width, TextRenderer.MeasureText(DetailsButton.Text, DetailsButton.Font).Width + (int)Math.Round(20 * factor));
        DetailsButton.SetBounds(body.Padding.Left + width - toggleWidth, y, toggleWidth, toggleHeight);
        int detailsTop = y + toggleHeight;
        DetailsText.SetBounds(body.Padding.Left, detailsTop, width, Math.Max(1, body.ClientSize.Height - body.Padding.Bottom - detailsTop));
    }
    void FitWorkingArea(Rectangle area)
    {
        int width = Math.Max(1, Math.Min((int)Math.Round(600 * factor), area.Width - (int)Math.Round(24 * factor)));
        int textWidth = Math.Max(1, width - (int)Math.Round(62 * factor));
        int wantedHeight = MeasureContent(messageContents, textWidth) + (int)Math.Round(136 * factor);
        if (detailsContents.Length > 0) wantedHeight += (int)Math.Round(40 * factor);
        if (detailsExpanded) wantedHeight += Math.Min(MeasureContent(detailsContents, textWidth), (int)Math.Round(240 * factor));
        wantedHeight = Math.Max((int)Math.Round(220 * factor), wantedHeight);
        int height = Math.Max(1, Math.Min(wantedHeight, Math.Min((int)Math.Round(560 * factor), area.Height - (int)Math.Round(24 * factor))));
        MinimumSize = Size.Empty; ClientSize = new Size(width, height);
        MinimumSize = new Size(Math.Min(width, (int)Math.Round(320 * factor)), Math.Min(height, (int)Math.Round(220 * factor)));
    }
    protected override void OnLoad(EventArgs e)
    {
        // ShowDialog(owner) can target a different monitor from the pointer.
        Rectangle area = Screen.FromControl(Owner ?? this).WorkingArea;
        FitWorkingArea(area);
        if (Owner != null) {
            StartPosition = FormStartPosition.Manual;
            Location = new Point(Math.Max(area.Left, Math.Min(Owner.Left + (Owner.Width - Width) / 2, area.Right - Width)),
                Math.Max(area.Top, Math.Min(Owner.Top + (Owner.Height - Height) / 2, area.Bottom - Height)));
        }
        base.OnLoad(e);
    }
    protected override void OnShown(EventArgs e) { base.OnShown(e); ActiveControl = CancelAction; CancelAction.Focus(); }
    protected override void OnFormClosing(FormClosingEventArgs e) { if (DialogResult == DialogResult.None) DialogResult = DialogResult.Cancel; base.OnFormClosing(e); }
}
