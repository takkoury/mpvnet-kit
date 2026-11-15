using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

public sealed partial class SettingsEditor
{
    static readonly Dictionary<string, object> EmptyUpscale = new Dictionary<string, object>();
    Dictionary<string, object> upscaleState = EmptyUpscale;
    StackPanel upscaleComponents;
    TextBlock upscaleComponentStatus, upscaleComponentMessage, upscaleComponentStage, upscaleComponentSource, upscaleVcLink;
    Button prepareUpscaleComponents, cancelUpscaleComponents, enableRequestedUpscale;
    ProgressBar upscaleComponentProgress;
    bool observingUpscale;

    Dictionary<string, object> ComponentState
    {
        get { return SettingsDraft.Value(upscaleState, "component") as Dictionary<string, object> ?? EmptyUpscale; }
    }

    FrameworkElement UpscaleComponentsPanel()
    {
        if (upscaleComponents != null) return upscaleComponents;
        upscaleComponents = new StackPanel { Margin = new Thickness(0, 0, 0, 20) };
        var section = new StackPanel();
        upscaleComponents.Children.Add(new Border { Child = section, Padding = new Thickness(16),
            BorderBrush = Brush("#383838"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4) });

        var row = new DockPanel { LastChildFill = true };
        section.Children.Add(row);
        var actions = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(actions, Dock.Right); row.Children.Add(actions);
        prepareUpscaleComponents = UpscaleButton("准备组件…", "准备组件", ConfirmUpscaleComponents, true);
        enableRequestedUpscale = UpscaleButton("启用刚才的方案", "启用刚才的方案", delegate { Action("upscale-action", "enable-requested"); }, true);
        actions.Children.Add(prepareUpscaleComponents);
        actions.Children.Add(enableRequestedUpscale);
        var title = new StackPanel { Margin = new Thickness(0, 0, 14, 0) };
        row.Children.Add(title);
        title.Children.Add(new TextBlock { Text = "动画超分组件", FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        upscaleComponentStatus = UpscaleText("", new Thickness(0, 4, 0, 0));
        title.Children.Add(upscaleComponentStatus);

        upscaleComponentStage = UpscaleText("", new Thickness(0, 12, 0, 0));
        section.Children.Add(upscaleComponentStage);
        upscaleComponentProgress = new ProgressBar { Height = 4, Margin = new Thickness(0, 8, 0, 0),
            Foreground = Brush("#1287BB"), Background = Brush("#303030") };
        AutomationProperties.SetName(upscaleComponentProgress, "组件准备进度");
        section.Children.Add(upscaleComponentProgress);
        cancelUpscaleComponents = UpscaleButton("取消准备", "取消组件准备", delegate { Action("upscale-action", "cancel-install"); });
        cancelUpscaleComponents.HorizontalAlignment = HorizontalAlignment.Right;
        cancelUpscaleComponents.Margin = new Thickness(0, 10, 0, 0);
        section.Children.Add(cancelUpscaleComponents);
        upscaleComponentMessage = UpscaleText("", new Thickness(0, 12, 0, 0));
        AutomationProperties.SetLiveSetting(upscaleComponentMessage, AutomationLiveSetting.Polite);
        section.Children.Add(upscaleComponentMessage);
        upscaleVcLink = UpscaleTermsLink("获取 Microsoft Visual C++ 运行库（x64）",
            "https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist");
        section.Children.Add(upscaleVcLink);

        var details = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        details.Children.Add(UpscaleText("包含 Real-CUGAN Pro、Real-ESRGAN 动画模型。", new Thickness(0, 0, 0, 4)));
        upscaleComponentSource = UpscaleText("", new Thickness(0, 0, 0, 6));
        details.Children.Add(upscaleComponentSource);
        AddUpscaleTerms(details);
        section.Children.Add(new Expander { Header = "版本与来源", Foreground = Brush("#F2F2F2"),
            Margin = new Thickness(0, 12, 0, 0), Content = details });
        RefreshUpscaleComponents();
        return upscaleComponents;
    }

    void UpscaleState(Dictionary<string, object> state)
    {
        upscaleState = state ?? EmptyUpscale;
        RefreshUpscaleComponents();
    }

    void ProbeUpscaleComponents()
    {
        if (SessionEnded) return;
        if (!observingUpscale)
        {
            observingUpscale = true;
            Send(new object[] { "observe_property", 3, "user-data/mpvnet/enhancement/upscale" });
        }
        Action("upscale-action", "probe");
    }

    void RefreshUpscaleComponents()
    {
        if (upscaleComponents == null) return;
        var component = ComponentState;
        string phase = SettingsDraft.Str(component, "phase");
        bool ready = phase == "ready" && SettingsDraft.Flag(component, "ready");
        bool installing = phase == "installing";
        bool unavailable = phase == "missing" || phase == "failed";
        string requested = SettingsDraft.Str(upscaleState, "requested");
        upscaleComponentStatus.Text = ready ? "组件已就绪" : installing ? "正在准备组件" :
            phase == "failed" ? "组件准备失败" : unavailable ? "组件未准备" : "正在检查组件…";
        prepareUpscaleComponents.Visibility = unavailable ? Visibility.Visible : Visibility.Collapsed;
        prepareUpscaleComponents.IsEnabled = !SessionEnded && CanPrepareUpscale(component);
        prepareUpscaleComponents.Content = phase == "failed" ? "重试准备…" : "准备组件…";
        bool awaitingExplicitEnable = SettingsDraft.Str(upscaleState, "phase") == "missing" && (requested == "CUGAN" || requested == "ESRGAN");
        enableRequestedUpscale.Visibility = ready && awaitingExplicitEnable ? Visibility.Visible : Visibility.Collapsed;
        enableRequestedUpscale.IsEnabled = !SessionEnded && SettingsDraft.Flag(component, "can_install");
        cancelUpscaleComponents.Visibility = installing ? Visibility.Visible : Visibility.Collapsed;
        cancelUpscaleComponents.IsEnabled = !SessionEnded;
        upscaleComponentStage.Visibility = installing ? Visibility.Visible : Visibility.Collapsed;
        string stage = SettingsDraft.Str(component, "stage");
        string elapsed = UpscaleElapsed(component);
        upscaleComponentStage.Text = (stage.Length == 0 ? "正在获取组件…" : stage) + (elapsed.Length > 0 ? "  ·  " + elapsed : "");
        upscaleComponentProgress.Visibility = installing && SystemParameters.ClientAreaAnimation ? Visibility.Visible : Visibility.Collapsed;
        upscaleComponentProgress.IsIndeterminate = upscaleComponentProgress.Visibility == Visibility.Visible;
        string message = SettingsDraft.Str(component, "error_text");
        if (message.Length == 0 && ready && enableRequestedUpscale.Visibility == Visibility.Visible)
            message = "由你选择何时启用画面增强。";
        if (upscaleComponentMessage.Text != message)
        {
            upscaleComponentMessage.Text = message;
            upscaleComponentMessage.Visibility = message.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.FromElement(upscaleComponentMessage);
            if (message.Length > 0 && peer != null)
                peer.RaiseAutomationEvent(System.Windows.Automation.Peers.AutomationEvents.LiveRegionChanged);
        }
        else if (message.Length == 0) upscaleComponentMessage.Visibility = Visibility.Collapsed;
        upscaleVcLink.Visibility = SettingsDraft.Str(component, "error_reason") == "crt_missing" ? Visibility.Visible : Visibility.Collapsed;
        upscaleComponentSource.Text = SettingsDraft.Str(component, "source_summary");
        upscaleComponentSource.Visibility = upscaleComponentSource.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    static bool CanPrepareUpscale(Dictionary<string, object> component)
    {
        string phase = SettingsDraft.Str(component, "phase");
        long bytes;
        return (phase == "missing" || phase == "failed") && SettingsDraft.Flag(component, "can_install") &&
            SettingsDraft.Str(component, "bundle_root").Length > 0 &&
            Int64.TryParse(SettingsDraft.Str(component, "download_bytes"), NumberStyles.None, CultureInfo.InvariantCulture, out bytes) && bytes > 0;
    }

    void ConfirmUpscaleComponents()
    {
        var component = ComponentState;
        if (SessionEnded || !CanPrepareUpscale(component)) return;
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "准备动画超分组件", FontSize = 18, FontWeight = FontWeights.SemiBold });
        var summary = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        summary.Children.Add(UpscaleText("为 Real-CUGAN 和 Real-ESRGAN 准备共用的运行组件。完成后由你选择何时启用。", new Thickness(0, 0, 0, 12)));
        summary.Children.Add(UpscaleText("下载量 " + SizeLabel(component, "download_bytes"), new Thickness(0, 0, 0, 4)));
        string expanded = SizeLabel(component, "expanded_bytes");
        if (expanded.Length > 0) summary.Children.Add(UpscaleText("展开后占用 " + expanded, new Thickness(0, 0, 0, 4)));
        summary.Children.Add(UpscaleText("位置  " + SettingsDraft.Str(component, "bundle_root"), new Thickness(0, 0, 0, 4)));
        string source = SettingsDraft.Str(component, "source_summary");
        if (source.Length > 0) summary.Children.Add(UpscaleText("来源  " + source, new Thickness(0, 0, 0, 4)));
        summary.Children.Add(UpscaleText("开始前请查阅上游组件使用条款。选择开始准备，即确认按适用条款获取和使用组件。", new Thickness(0, 8, 0, 4)));
        AddUpscaleTerms(summary);
        panel.Children.Add(new ScrollViewer { Content = summary, MaxHeight = 274,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0) };
        var cancel = UpscaleButton("取消", "取消组件确认", CloseOverlay);
        cancel.Margin = new Thickness(0, 0, 8, 0);
        actions.Children.Add(cancel);
        actions.Children.Add(UpscaleButton("开始准备", "开始准备", delegate {
            CloseOverlay();
            if (!SessionEnded && CanPrepareUpscale(ComponentState)) Action("upscale-action", "install");
        }, true));
        panel.Children.Add(actions);
        ShowOverlay(panel, cancel);
    }

    static string SizeLabel(Dictionary<string, object> state, string field)
    {
        long bytes;
        return Int64.TryParse(SettingsDraft.Str(state, field), NumberStyles.None, CultureInfo.InvariantCulture, out bytes) && bytes > 0
            ? String.Format(CultureInfo.InvariantCulture, "{0:#,##0} B（{1:0.00} GiB）", bytes, bytes / 1073741824.0) : "";
    }

    static string UpscaleElapsed(Dictionary<string, object> state)
    {
        double seconds;
        return Double.TryParse(SettingsDraft.Str(state, "elapsed"), NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) &&
            seconds >= 0 && seconds <= 86400 ? "已用时 " + TimeSpan.FromSeconds(seconds).ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture) : "";
    }

    TextBlock UpscaleText(string value, Thickness margin)
    {
        return new TextBlock { Text = value, Margin = margin, Foreground = Brush("#BFBFBF"), TextWrapping = TextWrapping.Wrap };
    }

    Button UpscaleButton(string label, string name, Action action, bool primary = false)
    {
        var button = Button(label, action);
        button.Margin = new Thickness(0);
        AutomationProperties.SetName(button, name);
        if (primary) { button.Background = Brush("#0D6F9D"); button.BorderBrush = Brush("#1287BB"); }
        return button;
    }

    TextBlock UpscaleTermsLink(string label, string url)
    {
        var block = UpscaleText("", new Thickness(0, 2, 0, 2));
        var link = new Hyperlink(new Run(label)) { Foreground = Brush("#83D2F5") };
        link.Click += delegate {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (System.ComponentModel.Win32Exception) { link.ToolTip = url; }
            catch (InvalidOperationException) { link.ToolTip = url; }
        };
        block.Inlines.Add(link);
        return block;
    }

    void AddUpscaleTerms(Panel panel)
    {
        panel.Children.Add(UpscaleTermsLink("NVIDIA TensorRT SDK 使用条款", "https://docs.nvidia.com/deeplearning/tensorrt/10.x.x/reference/sla.html"));
        panel.Children.Add(UpscaleTermsLink("NVIDIA CUDA 使用条款", "https://docs.nvidia.com/cuda/archive/13.2.0/eula/index.html"));
    }
}
