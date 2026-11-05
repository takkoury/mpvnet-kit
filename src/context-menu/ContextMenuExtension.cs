using System;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using MpvNet;
using MpvNet.Windows.WinForms;
using Forms = System.Windows.Forms;

namespace KitContextMenu;

public sealed class ContextMenuExtension : IExtension
{
    private const string SupportedHost = "7.1.2.0+96afc62165b5a1df186fc79c58813f37061ace9a";
    private const string StatusProperty = "user-data/mpvnet/context-menu";
    private ContextMenu? _root;
    private MenuPresentation? _presentation;
    private MainForm? _main;
    private bool _preparedForOpening;

    public ContextMenuExtension()
    {
        // The host loads extensions on a worker after building the menu on its UI thread.
        if (Application.Current?.Dispatcher is { HasShutdownStarted: false } dispatcher)
            dispatcher.BeginInvoke(DispatcherPriority.Normal, (Action)Attach);
    }

    private void Attach()
    {
        try
        {
            var version = typeof(MainForm).Assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (version != SupportedHost)
            {
                Report("unsupported", "host-version");
                return;
            }

            var main = MainForm.Instance;
            if (main is null || main.IsDisposed)
            {
                Report("failed", "host-window");
                return;
            }

            var bindings = Global.App.InputConf.GetBindings().menuBindings
                .Where(binding => binding.IsMenu)
                .Select(binding => (Path: MenuPresentation.SplitPath(binding.Comment), binding.Command))
                .ToArray();
            var root = MenuPresentation.FindRoot(title => main.FindMenuItem(title),
                bindings.SelectMany(binding => binding.Path.Take(1)));
            if (root is null)
            {
                Report("failed", "menu-root");
                return;
            }

            var radioGroups = new[]
            {
                main.FindMenuItem(Global._("Track"), "Track"),
                main.FindMenuItem(Global._("Audio Device"), "Audio Device")
            };
            var presentation = new MenuPresentation(root, bindings, radioGroups.OfType<MenuItem>());
            _root = root;
            _presentation = presentation;
            _main = main;
            presentation.Apply(ScrollHeight(root));
            root.Opened += OnOpened;
            main.Disposed += OnDisposed;
            GuiCommand.Current.ShowMenu += OnShowMenu;
            Report("ready", "host-menu", root.Items.Count);
        }
        catch (Exception)
        {
            UseNativeMenu("menu-style");
        }
    }

    private void OnShowMenu()
    {
        if (_root is not { } root || root.Dispatcher.HasShutdownStarted)
            return;

        // The host's ShowMenu handler posts the actual opening to its WinForms queue.
        if (root.Dispatcher.CheckAccess())
            RefreshBeforeOpening();
        else
            root.Dispatcher.BeginInvoke(DispatcherPriority.Send, (Action)RefreshBeforeOpening);
    }

    private void RefreshBeforeOpening()
    {
        Refresh();
        _preparedForOpening = _root is not null;
    }

    private void OnOpened(object sender, RoutedEventArgs args)
    {
        if (!_preparedForOpening)
            Refresh();
        _preparedForOpening = false;
    }

    private void Refresh()
    {
        if (_root is not { } root)
            return;

        try
        {
            _presentation?.Refresh(Global.Player.GetPropertyString, ScrollHeight(root));
        }
        catch (Exception)
        {
            UseNativeMenu("menu-refresh");
        }
    }

    private void OnDisposed(object? sender, EventArgs args) => Detach();

    private void Detach()
    {
        GuiCommand.Current.ShowMenu -= OnShowMenu;
        if (_root is { } root)
            root.Opened -= OnOpened;
        if (_main is { } main)
            main.Disposed -= OnDisposed;
        var presentation = _presentation;
        _root = null;
        _main = null;
        _presentation = null;
        presentation?.Dispose();
    }

    private void UseNativeMenu(string reason)
    {
        Detach();
        Report("failed", reason);
    }

    private static void Report(string status, string source, int rootCount = 0)
    {
        try
        {
            if (Global.Player.Handle != IntPtr.Zero)
            {
                Global.Player.SetPropertyInt(StatusProperty + "/schema", 1);
                Global.Player.SetPropertyString(StatusProperty + "/style_version", "1");
                Global.Player.SetPropertyString(StatusProperty + "/source", source);
                Global.Player.SetPropertyInt(StatusProperty + "/root_count", rootCount);
                Global.Player.SetPropertyString(StatusProperty + "/status", status);
            }
        }
        catch (Exception)
        {
            // Diagnostics must not affect playback or extension loading.
        }
        if (status != "ready")
            Terminal.WriteError($"右键菜单样式未启用（{source}），继续使用播放器原菜单。", "mpvnet-kit");
    }

    private static double ScrollHeight(ContextMenu root)
    {
        var cursor = Forms.Cursor.Position;
        double dpi = VisualTreeHelper.GetDpi(root).PixelsPerInchY;
        var monitor = MonitorFromPoint(cursor, 2);
        if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out _, out uint monitorDpi) == 0 && monitorDpi != 0)
            dpi = monitorDpi;
        var workArea = Forms.Screen.FromPoint(cursor).WorkingArea;
        return Math.Max(32, workArea.Height * 96d / dpi - 32);
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(System.Drawing.Point point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
}
