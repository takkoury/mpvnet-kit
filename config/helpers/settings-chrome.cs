using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;

// Window presentation and native ownership only. Close still enters the editor's
// Closing guard; WindowChrome retains Windows caption and resize behavior.
public sealed partial class SettingsEditor
{
    const int WindowStyleIndex = -16, WindowExtendedStyleIndex = -20;
    const uint OwnerWindowCommand = 4;
    const uint ChildWindowStyle = 0x40000000, ToolWindowStyle = 0x00000080, NoActivateStyle = 0x08000000, TopmostStyle = 0x00000008;
    [StructLayout(LayoutKind.Sequential)] struct OwnerWindowRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct OwnerWindowPoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct OwnerMonitorInfo {
        public int Size; public OwnerWindowRect Monitor, Work; public uint Flags;
    }
    delegate bool OwnerWindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(OwnerWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern uint GetWindowStyle(IntPtr window, int index);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out OwnerWindowRect rect);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out OwnerWindowPoint point);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(OwnerWindowPoint point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref OwnerMonitorInfo info);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
    bool chromeConfigured;
    IntPtr playerOwner;
    DateTime lastOwnerAttempt = DateTime.MinValue;
    Button maximizeCaption;

    void ConfigureChrome()
    {
        if (chromeConfigured) return;
        chromeConfigured = true;
        ShowInTaskbar = false;
        WindowStyle = WindowStyle.None;
        WindowChrome.SetWindowChrome(this, new WindowChrome {
            CaptionHeight = 36, ResizeBorderThickness = new Thickness(6),
            GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(0),
            UseAeroCaptionButtons = false
        });
        rootPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        rootPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(bodyPanel, 1);
        var caption = new DockPanel { LastChildFill = true, Background = Brush("#151515") };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(actions, Dock.Right); caption.Children.Add(actions);
        maximizeCaption = CaptionButton("\uE922", "最大化", false, delegate {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        });
        actions.Children.Add(maximizeCaption);
        actions.Children.Add(CaptionButton("\uE8BB", "关闭设置", true, Close));
        caption.Children.Add(new TextBlock { Text = "设置", FontSize = 12,
            Foreground = Brush("#D5D5D5"), Margin = new Thickness(16, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center });
        rootPanel.Children.Add(caption);
        StateChanged += delegate { UpdateCaptionState(); };
        UpdateCaptionState();
    }

    Button CaptionButton(string glyph, string name, bool close, Action action)
    {
        var border = new FrameworkElementFactory(typeof(Border)); border.Name = "captionBorder";
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        border.SetValue(Border.BorderBrushProperty, Brushes.Transparent);
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Brush(close ? "#8F2633" : "#303030"), "captionBorder"));
        template.Triggers.Add(hover);
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty, Brush(close ? "#B53242" : "#414141"), "captionBorder"));
        template.Triggers.Add(pressed);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, Brush("#1287BB"), "captionBorder"));
        template.Triggers.Add(focus);
        var button = new Button { Content = glyph, Width = 44, Height = 36, Padding = new Thickness(0),
            Margin = new Thickness(0), FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 10,
            Foreground = Brush("#E5E5E5"), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Template = template, ToolTip = name };
        WindowChrome.SetIsHitTestVisibleInChrome(button, true);
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        button.Click += delegate { action(); };
        return button;
    }

    void UpdateCaptionState()
    {
        bool maximized = WindowState == WindowState.Maximized;
        maximizeCaption.Content = maximized ? "\uE923" : "\uE922";
        string name = maximized ? "还原" : "最大化";
        maximizeCaption.ToolTip = name;
        System.Windows.Automation.AutomationProperties.SetName(maximizeCaption, name);
    }

    void AttachPlayerOwner(bool immediate = false)
    {
        // Handle is only read, never EnsureHandle: validation and hidden probes
        // must remain free of native windows and player-side effects.
        if (validation || noShow) return;
        var interop = new WindowInteropHelper(this);
        if (interop.Handle == IntPtr.Zero) return;
        uint ownerPid;
        if (playerOwner != IntPtr.Zero && GetWindow(interop.Handle, OwnerWindowCommand) == playerOwner &&
            GetWindowThreadProcessId(playerOwner, out ownerPid) != 0 && ownerPid == (uint)parent.Id)
        {
            if (immediate) MatchPlayerWindowBand(interop.Handle);
            return;
        }
        DateTime now = DateTime.UtcNow;
        if (!immediate && now - lastOwnerAttempt < TimeSpan.FromSeconds(1)) return;
        lastOwnerAttempt = now;
        try {
            if (parent.HasExited) return;
            uint parentPid = (uint)parent.Id;
            IntPtr candidate = FindPlayerOwner(parentPid);
            uint pid;
            if (candidate == IntPtr.Zero || GetWindowThreadProcessId(candidate, out pid) == 0 || pid != parentPid) return;
            interop.Owner = candidate;
            if (GetWindow(interop.Handle, OwnerWindowCommand) == candidate)
            {
                playerOwner = candidate;
                MatchPlayerWindowBand(interop.Handle);
            }
        } catch (InvalidOperationException) { }
          catch (System.ComponentModel.Win32Exception) { }
          catch (ArgumentException) { }
    }

    void MatchPlayerWindowBand(IntPtr handle)
    {
        // A precreated HWND keeps its old band when an owner is assigned later.
        // Match this owner only; do not change WPF Topmost or activate/raise the owner.
        bool ownerTopmost = (GetWindowStyle(playerOwner, WindowExtendedStyleIndex) & TopmostStyle) != 0;
        bool windowTopmost = (GetWindowStyle(handle, WindowExtendedStyleIndex) & TopmostStyle) != 0;
        if (ownerTopmost != windowTopmost)
            SetWindowPos(handle, new IntPtr(ownerTopmost ? -1 : -2), 0, 0, 0, 0, 0x213); // NOMOVE | NOSIZE | NOACTIVATE | NOOWNERZORDER
    }

    void PositionPreparedWindow()
    {
        if (validation || noShow || WindowStartupLocation != WindowStartupLocation.CenterScreen) return;
        IntPtr handle = new WindowInteropHelper(this).Handle;
        OwnerWindowRect bounds; OwnerWindowPoint cursor;
        if (handle == IntPtr.Zero || !GetWindowRect(handle, out bounds) || !GetCursorPos(out cursor)) return;
        var monitor = new OwnerMonitorInfo { Size = Marshal.SizeOf(typeof(OwnerMonitorInfo)) };
        if (!GetMonitorInfo(MonitorFromPoint(cursor, 2), ref monitor)) return;
        OwnerWindowRect target = CenterOnWorkArea(bounds, monitor.Work);
        // Binding the owner before Show is required for the correct topmost band.
        // Preserve CenterScreen's cursor-monitor placement using one native coordinate space.
        WindowStartupLocation = WindowStartupLocation.Manual;
        if (!SetWindowPos(handle, IntPtr.Zero, target.Left, target.Top, 0, 0, 0x15)) // NOSIZE | NOZORDER | NOACTIVATE
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
    }

    static OwnerWindowRect CenterOnWorkArea(OwnerWindowRect bounds, OwnerWindowRect work)
    {
        int width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
        int left = work.Left + (work.Right - work.Left - width) / 2;
        int top = work.Top + (work.Bottom - work.Top - height) / 2;
        return new OwnerWindowRect { Left = left, Top = top, Right = left + width, Bottom = top + height };
    }

    static IntPtr FindPlayerOwner(uint parentPid)
    {
        // The player can also host visible input indicators and other auxiliary windows.
        IntPtr selected = IntPtr.Zero;
        long largestArea = 0;
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            uint pid;
            if (GetWindowThreadProcessId(window, out pid) == 0 || pid != parentPid ||
                !IsWindowVisible(window) || GetWindow(window, OwnerWindowCommand) != IntPtr.Zero) return true;
            OwnerWindowRect bounds;
            if (!GetWindowRect(window, out bounds)) return true;
            long area = OwnerWindowArea(GetWindowStyle(window, WindowStyleIndex),
                GetWindowStyle(window, WindowExtendedStyleIndex), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top);
            if (area > largestArea) {
                selected = window;
                largestArea = area;
            }
            return true;
        }, IntPtr.Zero);
        return selected;
    }

    static long OwnerWindowArea(uint style, uint extendedStyle, int width, int height)
    {
        if ((style & ChildWindowStyle) != 0 || (extendedStyle & (ToolWindowStyle | NoActivateStyle)) != 0)
            return 0;
        return width > 0 && height > 0 ? (long)width * height : 0;
    }
}
