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
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
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

    void AttachPlayerOwner()
    {
        // Handle is only read, never EnsureHandle: validation and hidden probes
        // must remain free of native windows and player-side effects.
        if (validation || noShow || playerOwner != IntPtr.Zero) return;
        var interop = new WindowInteropHelper(this);
        if (interop.Handle == IntPtr.Zero) return;
        DateTime now = DateTime.UtcNow;
        if (now - lastOwnerAttempt < TimeSpan.FromSeconds(1)) return;
        lastOwnerAttempt = now;
        try {
            if (parent.HasExited) return;
            parent.Refresh();
            IntPtr candidate = parent.MainWindowHandle;
            if (candidate == IntPtr.Zero) return;
            uint pid;
            if (GetWindowThreadProcessId(candidate, out pid) == 0 || pid != (uint)parent.Id) return;
            interop.Owner = candidate;
            playerOwner = candidate;
        } catch (InvalidOperationException) { }
          catch (System.ComponentModel.Win32Exception) { }
          catch (ArgumentException) { }
    }
}
