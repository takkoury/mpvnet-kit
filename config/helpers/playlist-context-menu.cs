using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

// Only presentation and window-local input live here. All queue mutations use
// the existing controller, with the ID captured when the context was opened.
public sealed class PlaylistContextMenu : ContextMenuStrip
{
    readonly PlaylistForm form;
    readonly ListView list;
    readonly PlaylistKeys keys;
    readonly ContextWindow hook;
    readonly PlaylistMenuRenderer menuRenderer;
    Font menuFont;
    readonly Dictionary<string, ToolStripMenuItem> commands = new Dictionary<string, ToolStripMenuItem>();
    readonly ToolStripSeparator rowSeparator;
    readonly ToolStripMenuItem order;
    protected override Padding DefaultPadding { get { return new Padding(menuRenderer == null ? 5 : menuRenderer.Pixels(5)); } }
    public override Size GetPreferredSize(Size constraint) { return menuRenderer == null ? base.GetPreferredSize(constraint) : menuRenderer.MeasureMenu(this); }
    public string TargetId { get; private set; }
    public event EventHandler Prepare;
    public event Action<string, string> InvokeAction;

    public PlaylistContextMenu(PlaylistForm window, ListView view, PlaylistKeys keyboard)
    {
        form = window; list = view; keys = keyboard; TargetId = "";
        menuRenderer = new PlaylistMenuRenderer();
        Renderer = menuRenderer;
        BackColor = PlaylistMenuRenderer.Background;
        ForeColor = PlaylistMenuRenderer.Text;
        AccessibleName = "播放列表菜单";
        ShowImageMargin = false;
        Padding = new Padding(5);
        SizeChanged += delegate { PlaylistMenuRenderer.RoundWindow(this, menuRenderer.Scale); };
        Add(Items, "播放此项", "play");
        Add(Items, "从队列移除", "remove").ShortcutKeyDisplayString = "Delete";
        rowSeparator = new ToolStripSeparator(); Items.Add(rowSeparator);
        var open = Group("打开");
        Add(open.DropDownItems, "文件…", "open-files");
        Add(open.DropDownItems, "文件夹…", "open-folder");
        Add(open.DropDownItems, "剪贴板中的文件或网址", "open-clipboard");
        var append = Group("追加");
        Add(append.DropDownItems, "文件…", "append-files");
        Add(append.DropDownItems, "文件夹…", "append-folder");
        Add(append.DropDownItems, "剪贴板中的文件或网址", "append-clipboard");
        Add(Items, "保存播放列表…", "save-playlist");
        Items.Add(new ToolStripSeparator());
        Add(Items, "搜索播放列表…", "search").ShortcutKeyDisplayString = "Ctrl+F";
        Add(Items, "定位当前播放项", "locate");
        order = Group("播放顺序");
        Add(order.DropDownItems, "上一个文件", "previous");
        Add(order.DropDownItems, "下一个文件", "next");
        Add(order.DropDownItems, "跳到列表首项", "first");
        Add(order.DropDownItems, "跳到列表末项", "last");
        order.DropDownItems.Add(new ToolStripSeparator());
        Add(order.DropDownItems, "打乱播放列表", "shuffle");
        hook = new ContextWindow(this);
        list.HandleCreated += OnListHandleCreated;
        list.HandleDestroyed += OnListHandleDestroyed;
        list.KeyDown += OnListKeyDown;
        form.LocationChanged += OwnerMoved;
        form.SizeChanged += OwnerMoved;
        if (list.IsHandleCreated) hook.AssignHandle(list.Handle);
        ApplyMenuStyle();
    }

    ToolStripMenuItem Add(ToolStripItemCollection items, string text, string action)
    {
        var item = new PlaylistMenuItem(text, menuRenderer) { Name = action, ForeColor = PlaylistMenuRenderer.Text };
        item.Click += delegate { Execute(action); };
        commands.Add(action, item); items.Add(item);
        return item;
    }

    ToolStripMenuItem Group(string text)
    {
        var item = new PlaylistMenuItem(text, menuRenderer) { ForeColor = PlaylistMenuRenderer.Text };
        var dropdown = new PlaylistMenuDropDown(menuRenderer) { Renderer = Renderer, ShowImageMargin = false,
            BackColor = BackColor, ForeColor = ForeColor, Font = Font, Padding = new Padding(5) };
        dropdown.SizeChanged += delegate { PlaylistMenuRenderer.RoundWindow(dropdown, menuRenderer.Scale); };
        item.DropDown = dropdown; Items.Add(item);
        return item;
    }

    // Mirror MenuStyles.xaml in physical pixels at the owner's current DPI.
    // Keep WinForms input/ownership; loading a second UI runtime would undo the
    // first-open improvement. Geometry and painting are local to this adapter.
    void ApplyMenuStyle()
    {
        uint dpi = PlaylistNative.GetDpiForWindow(form.Handle);
        menuRenderer.Scale = (dpi == 0 ? 96 : dpi) / 96f;
        Font previous = null;
        if (menuFont == null || Math.Abs(menuFont.Size - 13 * menuRenderer.Scale) > 0.01f)
        {
            previous = menuFont;
            menuFont = new Font("Microsoft YaHei UI", 13 * menuRenderer.Scale, FontStyle.Regular, GraphicsUnit.Pixel);
        }
        StyleMenu(this);
        if (previous != null) previous.Dispose();
    }

    void StyleMenu(ToolStripDropDown menu)
    {
        menu.SuspendLayout();
        menu.Font = menuFont;
        menu.Padding = new Padding(menuRenderer.Pixels(5));
        int width = menuRenderer.Pixels(160);
        foreach (ToolStripItem item in menu.Items)
            if (item is ToolStripMenuItem) width = Math.Max(width, item.GetPreferredSize(Size.Empty).Width);
        foreach (ToolStripItem item in menu.Items)
        {
            item.Margin = Padding.Empty;
            item.AutoSize = false;
            item.Size = new Size(width, menuRenderer.Pixels(item is ToolStripSeparator ? 11 : 32));
            var group = item as ToolStripMenuItem;
            if (group != null && group.HasDropDownItems) StyleMenu(group.DropDown);
        }
        menu.ResumeLayout(true);
        PlaylistMenuRenderer.RoundWindow(menu, menuRenderer.Scale);
    }

    public void SetHint(string action, string text)
    {
        ToolStripMenuItem item;
        if (commands.TryGetValue(action, out item) && action != "search" && action != "remove")
            item.ShortcutKeyDisplayString = text ?? "";
    }

    public void SetState(int total, bool hasCurrent, bool targetExists)
    {
        if (Visible && TargetId.Length != 0 && !targetExists) Close();
        bool row = TargetId.Length != 0 && targetExists;
        commands["play"].Visible = row; commands["remove"].Visible = row; rowSeparator.Visible = row;
        commands["save-playlist"].Enabled = total > 0;
        commands["locate"].Enabled = hasCurrent;
        order.Enabled = total > 0;
        foreach (string action in new[] { "previous", "next", "first", "last" }) commands[action].Enabled = total > 0;
        commands["shuffle"].Enabled = total > 1;
    }

    // Also usable by hidden control fixtures: preparing a context does not Show.
    public void PrepareTarget(string id)
    {
        TargetId = id ?? "";
        if (Prepare != null) Prepare(this, EventArgs.Empty);
    }

    public void ShowMouse(Point location)
    {
        menuRenderer.KeyboardNavigation = false;
        var item = list.GetItemAt(location.X, location.Y);
        if (item != null) { item.Selected = true; item.Focused = true; list.Focus(); }
        PrepareTarget(item == null ? "" : item.Name);
        Show(list, location);
    }

    public void ShowKeyboard()
    {
        menuRenderer.KeyboardNavigation = true;
        if (Visible) return;
        var item = list.SelectedItems.Count == 1 ? list.SelectedItems[0] : null;
        PrepareTarget(item == null ? "" : item.Name);
        var location = item == null ? new Point(12, 12) : new Point(item.Bounds.Left + 24, item.Bounds.Bottom);
        location.Y = Math.Min(Math.Max(0, location.Y), list.ClientSize.Height);
        Show(list, location);
    }

    public void Execute(string action)
    {
        ToolStripMenuItem item;
        if (!commands.TryGetValue(action, out item) || !item.Enabled ||
            ((action == "play" || action == "remove") && !item.Available)) return;
        string id = action == "play" || action == "remove" ? TargetId : "";
        Close(ToolStripDropDownCloseReason.ItemClicked);
        keys.ReleaseAll();
        if (action == "open-files" || action == "open-folder" || action == "open-clipboard" ||
            action == "append-files" || action == "append-folder" || action == "append-clipboard" || action == "save-playlist")
        {
            if (form.Follower != null && form.Follower.Parent != IntPtr.Zero)
                PlaylistNative.SetForegroundWindow(form.Follower.Parent);
        }
        if (InvokeAction != null) InvokeAction(action, id);
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        menuRenderer.KeyboardNavigation = true;
        return base.ProcessCmdKey(ref message, keyData);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        menuRenderer.KeyboardNavigation = false;
        base.OnMouseMove(e);
    }

    protected override void OnOpening(CancelEventArgs e)
    {
        ApplyMenuStyle();
        base.OnOpening(e);
        if (!e.Cancel)
        {
            keys.ReleaseAll(); keys.MenuActive = true;
            commands["remove"].ShortcutKeys = Keys.Delete;
            commands["search"].ShortcutKeys = Keys.Control | Keys.F;
        }
    }

    protected override void OnClosed(ToolStripDropDownClosedEventArgs e)
    {
        commands["remove"].ShortcutKeys = Keys.None;
        commands["search"].ShortcutKeys = Keys.None;
        keys.EndMenu();
        base.OnClosed(e);
    }

    void OnListKeyDown(object sender, KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Apps && e.Modifiers == Keys.None || e.KeyCode == Keys.F10 && e.Modifiers == Keys.Shift)
        { ShowKeyboard(); e.SuppressKeyPress = true; e.Handled = true; }
    }
    void OnListHandleCreated(object sender, EventArgs e) { hook.AssignHandle(list.Handle); }
    void OnListHandleDestroyed(object sender, EventArgs e) { hook.ReleaseHandle(); }
    void OwnerMoved(object sender, EventArgs e) { if (Visible) Close(); }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            keys.MenuActive = false;
            list.HandleCreated -= OnListHandleCreated; list.HandleDestroyed -= OnListHandleDestroyed; list.KeyDown -= OnListKeyDown;
            form.LocationChanged -= OwnerMoved; form.SizeChanged -= OwnerMoved;
            hook.ReleaseHandle();
        }
        base.Dispose(disposing);
        if (disposing && menuFont != null) { menuFont.Dispose(); menuFont = null; }
    }

    sealed class ContextWindow : NativeWindow
    {
        readonly PlaylistContextMenu menu;
        public ContextWindow(PlaylistContextMenu value) { menu = value; }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x7B) // WM_CONTEXTMENU distinguishes keyboard from screen coordinates.
            {
                long point = message.LParam.ToInt64();
                if (point == -1) menu.ShowKeyboard();
                else menu.ShowMouse(menu.list.PointToClient(new Point((short)(point & 0xFFFF), (short)((point >> 16) & 0xFFFF))));
                message.Result = IntPtr.Zero; return;
            }
            base.WndProc(ref message);
        }
    }
}

public sealed class PlaylistMenuDropDown : ToolStripDropDownMenu
{
    readonly PlaylistMenuRenderer renderer;
    public PlaylistMenuDropDown(PlaylistMenuRenderer value) { renderer = value; }
    public override Size GetPreferredSize(Size constraint) { return renderer == null ? base.GetPreferredSize(constraint) : renderer.MeasureMenu(this); }
    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        renderer.KeyboardNavigation = true;
        return base.ProcessCmdKey(ref message, keyData);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        renderer.KeyboardNavigation = false;
        base.OnMouseMove(e);
    }
    protected override Padding DefaultPadding { get { return new Padding(renderer == null ? 5 : renderer.Pixels(5)); } }
}

// ToolStrip's default layout reserves an icon gutter and uses system row sizes.
// Measure our text columns here, then paint them with the same spacing as WPF.
public sealed class PlaylistMenuItem : ToolStripMenuItem
{
    readonly PlaylistMenuRenderer renderer;
    public PlaylistMenuItem(string text, PlaylistMenuRenderer value) : base(text) { renderer = value; }
    public override Size GetPreferredSize(Size constraint)
    {
        int width = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding).Width;
        using (var hintFont = new Font(Font.FontFamily, 12 * renderer.Scale, FontStyle.Regular, GraphicsUnit.Pixel))
            if (!String.IsNullOrEmpty(ShortcutKeyDisplayString))
                width += renderer.Pixels(19) + TextRenderer.MeasureText(ShortcutKeyDisplayString, hintFont,
                    Size.Empty, TextFormatFlags.NoPadding).Width;
        return new Size(width + renderer.Pixels(HasDropDownItems ? 60 : 42), renderer.Pixels(32));
    }
}

public sealed class PlaylistMenuRenderer : ToolStripProfessionalRenderer
{
    // Visual source of truth: src/context-menu/MenuStyles.xaml.
    public static readonly Color Background = Color.FromArgb(21, 21, 21);
    public static readonly Color Text = Color.FromArgb(229, 229, 229);
    static readonly Color Hover = Color.FromArgb(37, 37, 37);
    static readonly Color Expanded = Color.FromArgb(21, 43, 53);
    static readonly Color Border = Color.FromArgb(59, 59, 59);
    static readonly Color Separator = Color.FromArgb(53, 53, 53);
    static readonly Color Disabled = Color.FromArgb(136, 136, 136);
    public float Scale = 1;
    public bool KeyboardNavigation;
    public int Pixels(float value) { return Math.Max(1, (int)Math.Round(value * Scale)); }
    public PlaylistMenuRenderer() { RoundedEdges = false; }
    public Size MeasureMenu(ToolStrip menu)
    {
        int width = Pixels(160), height = Pixels(10);
        foreach (ToolStripItem item in menu.Items)
        {
            if (!item.Available) continue;
            if (item is ToolStripMenuItem) width = Math.Max(width, item.GetPreferredSize(Size.Empty).Width);
            height += Pixels(item is ToolStripSeparator ? 11 : 32);
        }
        return new Size(width, height);
    }

    static GraphicsPath Rounded(RectangleF bounds, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure(); return path;
    }
    public static void RoundWindow(ToolStripDropDown menu, float scale)
    {
        if (menu.Width < 2 || menu.Height < 2) return;
        using (var path = Rounded(new RectangleF(0, 0, menu.Width, menu.Height), 6 * scale))
        {
            Region previous = menu.Region;
            menu.Region = new Region(path);
            if (previous != null) previous.Dispose();
        }
    }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    { e.Graphics.Clear(Background); }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        var item = e.Item as ToolStripMenuItem;
        bool expanded = item != null && item.HasDropDownItems && item.DropDown.Visible;
        if (!e.Item.Enabled || (!e.Item.Selected && !expanded)) return;
        var state = e.Graphics.Save(); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Rounded(new RectangleF(5 * Scale, Scale / 2, e.Item.Width - 10 * Scale, e.Item.Height - Scale), 3 * Scale))
        {
            using (var brush = new SolidBrush(expanded ? Expanded : Hover)) e.Graphics.FillPath(brush, path);
            if (e.Item.Selected && KeyboardNavigation)
                using (var pen = new Pen(Color.FromArgb(119, 119, 119), Scale)) e.Graphics.DrawPath(pen, path);
        }
        e.Graphics.Restore(state);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        var item = e.Item as ToolStripMenuItem;
        if (item == null || e.Text != item.Text) return; // draw both columns once
        var flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
        int left = Pixels(16), right = e.Item.Width - Pixels(item.HasDropDownItems ? 34 : 16);
        string hint = item.ShortcutKeyDisplayString;
        if (!String.IsNullOrEmpty(hint))
        {
            using (var font = new Font(e.TextFont.FontFamily, 12 * Scale, FontStyle.Regular, GraphicsUnit.Pixel))
            {
                int width = TextRenderer.MeasureText(hint, font, Size.Empty, TextFormatFlags.NoPadding).Width;
                TextRenderer.DrawText(e.Graphics, hint, font, new Rectangle(right - width, 0, width, item.Height),
                    item.Enabled ? Color.FromArgb(170, 170, 170) : Color.FromArgb(119, 119, 119), flags);
                right -= width + Pixels(19);
            }
        }
        TextRenderer.DrawText(e.Graphics, item.Text, e.TextFont,
            new Rectangle(left, 0, Math.Max(1, right - left), item.Height), item.Enabled ? Text : Disabled,
            flags | TextFormatFlags.EndEllipsis);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        float x = e.Item.Width - 22 * Scale, y = e.Item.Height / 2f;
        var state = e.Graphics.Save(); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var pen = new Pen(e.Item.Enabled ? Text : Disabled, 1.3f * Scale))
        {
            pen.StartCap = pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
            e.Graphics.DrawLines(pen, new[] { new PointF(x, y - 4 * Scale), new PointF(x + 4 * Scale, y), new PointF(x, y + 4 * Scale) });
        }
        e.Graphics.Restore(state);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    { using (var pen = new Pen(Separator, Scale)) e.Graphics.DrawLine(pen, Pixels(11), e.Item.Height / 2f, e.Item.Width - Pixels(11), e.Item.Height / 2f); }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        var state = e.Graphics.Save(); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Rounded(new RectangleF(Scale / 2, Scale / 2, e.ToolStrip.Width - Scale, e.ToolStrip.Height - Scale), 6 * Scale))
        using (var pen = new Pen(Border, Scale)) e.Graphics.DrawPath(pen, path);
        e.Graphics.Restore(state);
    }
}
