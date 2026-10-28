"""Compile the actual caption partial and inspect WPF controls offscreen."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF assemblies')
class SettingsChrome(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        stub = r'''
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
public sealed partial class SettingsEditor : Window {
    readonly bool validation, noShow;
    readonly Process parent = Process.GetCurrentProcess();
    Grid rootPanel = new Grid(), bodyPanel = new Grid();
    int closeAttempts;
    static SolidColorBrush Brush(string color) { return (SolidColorBrush)new BrushConverter().ConvertFromString(color); }
    public SettingsEditor(bool validate, bool hidden) {
        validation = validate; noShow = hidden;
        Width = 1040; Height = 780; Content = rootPanel;
        rootPanel.Children.Add(bodyPanel);
        Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e) { closeAttempts++; e.Cancel = true; };
        ConfigureChrome(); ConfigureChrome();
    }
    public Dictionary<string, object> Probe() {
        AttachPlayerOwner(); AttachPlayerOwner();
        rootPanel.Measure(new Size(1040, 780)); rootPanel.Arrange(new Rect(0, 0, 1040, 780)); rootPanel.UpdateLayout();
        var caption = rootPanel.Children.OfType<DockPanel>().Single();
        var actions = caption.Children.OfType<StackPanel>().Single();
        var buttons = actions.Children.OfType<Button>().ToArray();
        foreach (var button in buttons) button.ApplyTemplate();
        var chrome = WindowChrome.GetWindowChrome(this);
        var result = new Dictionary<string,object> {
            {"shown", IsVisible}, {"native_handle", new WindowInteropHelper(this).Handle.ToInt64()},
            {"owner", new WindowInteropHelper(this).Owner.ToInt64()}, {"taskbar", ShowInTaskbar},
            {"style", WindowStyle.ToString()}, {"transparent", AllowsTransparency}, {"topmost", Topmost},
            {"resize", ResizeMode.ToString()}, {"caption_height", chrome.CaptionHeight},
            {"resize_border", chrome.ResizeBorderThickness.Left}, {"glass", chrome.GlassFrameThickness.Left},
            {"aero_buttons", chrome.UseAeroCaptionButtons}, {"row_count", rootPanel.RowDefinitions.Count},
            {"body_row", Grid.GetRow(bodyPanel)}, {"body_top", bodyPanel.TranslatePoint(new Point(), rootPanel).Y},
            {"caption_background", ((SolidColorBrush)caption.Background).Color.ToString()},
            {"title", caption.Children.OfType<TextBlock>().Single().Text},
            {"title_size", caption.Children.OfType<TextBlock>().Single().FontSize},
            {"button_names", buttons.Select(b => System.Windows.Automation.AutomationProperties.GetName(b)).ToArray()},
            {"button_widths", buttons.Select(b => b.ActualWidth).ToArray()},
            {"button_heights", buttons.Select(b => b.ActualHeight).ToArray()},
            {"button_hit_test", buttons.All(WindowChrome.GetIsHitTestVisibleInChrome)},
            {"keyboard_focus_triggers", buttons.All(b => b.Template.Triggers.OfType<Trigger>().Any(t => t.Property == IsKeyboardFocusedProperty))}
        };
        buttons[0].RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); UpdateCaptionState();
        result["maximized"] = WindowState == WindowState.Maximized;
        result["maximize_name"] = System.Windows.Automation.AutomationProperties.GetName(buttons[0]);
        buttons[0].RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); UpdateCaptionState();
        result["restored"] = WindowState == WindowState.Normal;
        result["restore_name"] = System.Windows.Automation.AutomationProperties.GetName(buttons[0]);
        buttons[1].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        result["close_attempts"] = closeAttempts;
        result["final_native_handle"] = new WindowInteropHelper(this).Handle.ToInt64();
        return result;
    }
}
'''
        script = r'''
param([string]$SourcePath, [string]$StubPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$references = @('System.Core', 'System.Xaml', [Windows.Window].Assembly.Location,
    [Windows.Media.Brushes].Assembly.Location, [Windows.Threading.Dispatcher].Assembly.Location)
Add-Type -Path @($SourcePath, $StubPath) -ReferencedAssemblies $references
$result = @{}
foreach ($flags in @(@($true,$true), @($true,$false), @($false,$true), @($false,$false))) {
    $window = New-Object SettingsEditor($flags[0], $flags[1])
    $result["$($flags[0])-$($flags[1])"] = $window.Probe()
}
$result | ConvertTo-Json -Depth 5 -Compress
'''
        with tempfile.TemporaryDirectory(prefix='mpvnet-settings-chrome-') as temp:
            probe = Path(temp) / 'probe.ps1'
            source = Path(temp) / 'stub.cs'
            probe.write_text(script, encoding='utf-8')
            source.write_text(stub, encoding='utf-8')
            result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', str(probe), '-SourcePath', str(ROOT / 'config/helpers/settings-chrome.cs'),
                '-StubPath', str(source)], capture_output=True, timeout=30)
        if result.returncode or result.stderr:
            raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
        cls.probes = json.loads(result.stdout.decode('utf-8-sig'))

    def test_window_policy_and_chrome_geometry(self):
        for name, data in self.probes.items():
            with self.subTest(mode=name):
                self.assertFalse(data['taskbar'])
                self.assertEqual(data['style'], 'None')
                self.assertFalse(data['transparent'])
                self.assertFalse(data['topmost'])
                self.assertEqual(data['resize'], 'CanResize')
                self.assertEqual(data['caption_height'], 36)
                self.assertEqual(data['resize_border'], 6)
                self.assertEqual(data['glass'], 0)
                self.assertFalse(data['aero_buttons'])
                self.assertEqual(data['row_count'], 2)
                self.assertEqual(data['body_row'], 1)
                self.assertEqual(data['body_top'], 36)

    def test_caption_labels_buttons_and_focus(self):
        data = self.probes['True-True']
        self.assertEqual(data['caption_background'], '#FF151515')
        self.assertEqual(data['title'], '设置')
        self.assertEqual(data['title_size'], 12)
        self.assertEqual(data['button_names'], ['最大化', '关闭设置'])
        self.assertEqual(data['button_widths'], [44, 44])
        self.assertEqual(data['button_heights'], [36, 36])
        self.assertTrue(data['button_hit_test'])
        self.assertTrue(data['keyboard_focus_triggers'])

    def test_caption_actions_preserve_close_guard(self):
        data = self.probes['True-True']
        self.assertTrue(data['maximized'])
        self.assertEqual(data['maximize_name'], '还原')
        self.assertTrue(data['restored'])
        self.assertEqual(data['restore_name'], '最大化')
        self.assertEqual(data['close_attempts'], 1)

    def test_validation_and_unshown_construction_create_no_native_window(self):
        for name, data in self.probes.items():
            with self.subTest(mode=name):
                self.assertFalse(data['shown'])
                self.assertEqual(data['native_handle'], 0)
                self.assertEqual(data['final_native_handle'], 0)
                self.assertEqual(data['owner'], 0)


if __name__ == '__main__':
    unittest.main()
