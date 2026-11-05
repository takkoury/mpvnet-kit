using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace KitContextMenu;

internal sealed class MenuPresentation : IDisposable
{
    private const string ScrollHeightKey = "KitMenuScrollHeight";
    private const string ShortcutProperty = "user-data/mpvnet/shortcuts";
    private readonly ContextMenu _root;
    private readonly object? _hostLocalStyle;
    private readonly BindingBase? _hostStyleBinding;
    private readonly ItemCollection[] _radioGroups;
    private readonly StaticItem[] _items;
    private readonly MenuItem[] _markColumns;
    private ResourceDictionary? _styles;

    private sealed record Indicator(string Property, Func<string, bool> IsMarked, bool Radio = false);
    private sealed record StaticItem(MenuItem Item, string Command, string HostGesture, Indicator? Indicator);

    internal MenuPresentation(ContextMenu root, IEnumerable<(string[] Path, string Command)> bindings,
        IEnumerable<MenuItem> radioGroups)
    {
        _root = root;
        _hostLocalStyle = root.ReadLocalValue(FrameworkElement.StyleProperty);
        _hostStyleBinding = BindingOperations.GetBindingBase(root, FrameworkElement.StyleProperty);
        _radioGroups = radioGroups.Where(item => FindOwner(item) == root).Distinct()
            .Select(item => item.Items).ToArray();

        // The host can create duplicate names. Only decorate a command with a unique item path.
        _items = bindings.Select(binding => (Item: FindItem(root, binding.Path), binding.Command))
            .Where(entry => entry.Item is not null)
            .GroupBy(entry => entry.Item!)
            .Where(group => group.Count() == 1)
            .Select(group => new StaticItem(group.Key, group.Single().Command, group.Key.InputGestureText,
                IndicatorFor(group.Single().Command)))
            .ToArray();
        _markColumns = _items.Where(entry => entry.Indicator is not null)
            .Select(entry => ItemsControl.ItemsControlFromItemContainer(entry.Item))
            .OfType<ItemsControl>().Distinct()
            .SelectMany(parent => parent.Items.OfType<MenuItem>()).Distinct().ToArray();
    }

    internal static string[] SplitPath(string path) =>
        path.Split(new[] { " > ", " | " }, StringSplitOptions.RemoveEmptyEntries);

    internal static ContextMenu? FindRoot(Func<string, MenuItem?> find, IEnumerable<string> titles)
    {
        ContextMenu? root = null;
        foreach (string title in titles.Distinct(StringComparer.Ordinal))
        {
            if (string.IsNullOrWhiteSpace(title) || title == "-" || find(title) is not { } item)
                continue;
            if (FindOwner(item) is not { } candidate)
                continue;
            if (root is not null && root != candidate)
                return null;
            root = candidate;
        }
        return root;
    }

    private static ContextMenu? FindOwner(MenuItem item)
    {
        ItemsControl? current = item;
        while (current is MenuItem container)
            current = ItemsControl.ItemsControlFromItemContainer(container);
        return current as ContextMenu;
    }

    private static MenuItem? FindItem(ContextMenu root, string[] path)
    {
        ItemsControl current = root;
        foreach (string title in path)
        {
            var matches = current.Items.OfType<MenuItem>()
                .Where(item => string.Equals(item.Header as string, title, StringComparison.Ordinal))
                .Take(2).ToArray();
            if (matches.Length != 1)
                return null;
            current = matches[0];
        }
        return current as MenuItem;
    }

    internal void Apply(double scrollHeight)
    {
        // WPF does not expose a local dynamic resource's key through the property API.
        if (_hostStyleBinding is null && _hostLocalStyle is not null and not Style &&
            _hostLocalStyle != DependencyProperty.UnsetValue)
            throw new InvalidOperationException("The existing menu style source cannot be restored.");

        // A compiled dictionary keeps the attached-property types local to this DLL.
        string assembly = typeof(MenuPresentation).Assembly.GetName().Name!;
        var styles = (ResourceDictionary)Application.LoadComponent(
            new Uri($"/{assembly};component/MenuStyles.xaml", UriKind.Relative));
        var chrome = (Style)styles["MenuChrome"];
        foreach (var style in styles.Values.OfType<Style>())
            style.Seal();
        styles[ScrollHeightKey] = scrollHeight;

        _styles = styles;
        _root.Resources.MergedDictionaries.Add(styles);
        // The popup changes resource ancestry on open, invalidating an implicit style.
        _root.Style = chrome;

        foreach (var item in _markColumns)
            MenuMarks.SetShowMark(item, true);
        foreach (var entry in _items)
        {
            if (entry.Indicator is { Radio: true })
                MenuMarks.SetIsRadio(entry.Item, true);
            if (entry.Command == "ignore")
                SetGesture(entry.Item, "");
        }
        foreach (var group in _radioGroups)
        {
            MarkRadioItems(group);
            ((INotifyCollectionChanged)group).CollectionChanged += OnRadioItemsChanged;
        }
        _root.ApplyTemplate();
    }

    internal void Refresh(Func<string, string> readProperty, double scrollHeight)
    {
        if (_styles is not { } styles)
            return;

        if (!Equals(styles[ScrollHeightKey], scrollHeight))
            styles[ScrollHeightKey] = scrollHeight;
        var shortcuts = ReadShortcuts(readProperty(ShortcutProperty));
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in _items)
        {
            string gesture = entry.Command == "ignore" ? "" : entry.HostGesture;
            if (shortcuts.TryGetValue(ShortcutCommand(entry.Command), out string? current))
                gesture = current;
            SetGesture(entry.Item, gesture);

            if (entry.Indicator is not { } indicator)
                continue;
            if (!values.TryGetValue(indicator.Property, out string? value))
                values[indicator.Property] = value = readProperty(indicator.Property);
            MenuMarks.SetIsMarked(entry.Item, indicator.IsMarked(value));
        }
    }

    private static void SetGesture(MenuItem item, string text)
    {
        if (item.InputGestureText != text)
            item.SetCurrentValue(MenuItem.InputGestureTextProperty, text);
    }

    private static string ShortcutCommand(string command) => command switch
    {
        "script-binding playback_feedback/toggle-pause" or "script-message-to mpvnet play-pause" or
            "cycle pause" => "script-binding playback_feedback/space",
        _ => command
    };

    internal static Dictionary<string, string> ReadShortcuts(string json)
    {
        var shortcuts = new Dictionary<string, string>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(json))
            return shortcuts;

        try
        {
            using var doc = JsonDocument.Parse(json);
            var state = doc.RootElement;
            if (state.ValueKind != JsonValueKind.Object ||
                !state.TryGetProperty("schema", out var schema) || schema.ValueKind != JsonValueKind.Number ||
                !schema.TryGetInt32(out int version) || version != 1 ||
                !state.TryGetProperty("actions", out var actions) || actions.ValueKind != JsonValueKind.Array)
                return shortcuts;

            // actions holds the last successfully applied map, including after a failed edit.
            foreach (var entry in actions.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object ||
                    !entry.TryGetProperty("command", out var command) || command.ValueKind != JsonValueKind.String ||
                    command.GetString() is not { Length: > 0 } name || name == "ignore" ||
                    !entry.TryGetProperty("keys", out var keys) || keys.ValueKind != JsonValueKind.Array)
                    continue;
                var keyNames = keys.EnumerateArray().ToArray();
                if (keyNames.All(key => key.ValueKind == JsonValueKind.String &&
                        key.GetString() is { Length: > 0 } value && value != "_"))
                    shortcuts.TryAdd(name, string.Join(", ", keyNames.Select(key => key.GetString())));
            }
        }
        catch (JsonException)
        {
            // An unavailable or unreadable publication leaves the original gestures in use.
        }
        return shortcuts;
    }

    private static Indicator Flag(string property) => new(property, value => value is "yes" or "true");
    private static Indicator Choice(string property, string choice) => new(property, value => value == choice, true);
    private static Indicator Speed(double speed) => new("speed", value =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double current) && current == speed, true);

    private static Indicator? IndicatorFor(string command) => command switch
    {
        "script-binding playback_feedback/toggle-pause" or "script-binding playback_feedback/space" or
            "script-message-to mpvnet play-pause" or "cycle pause" => Flag("pause"),
        "script-binding playback_feedback/fullscreen" or "cycle fullscreen" => Flag("fullscreen"),
        "script-binding playback_feedback/ontop" or "cycle ontop" or "osd-msg cycle ontop" => Flag("ontop"),
        "cycle mute" or "no-osd cycle mute" => Flag("mute"),
        "cycle border" => Flag("border"),
        "cycle deinterlace" => Flag("deinterlace"),
        "script-binding subtitle_controls/toggle" or "cycle sub-visibility" => Flag("sub-visibility"),
        "script-binding playlist_controls/toggle" => Flag("user-data/mpvnet/playlist-window/visible"),
        "cycle-values sub-ass-override force no" => new("sub-ass-override", value => value == "force"),
        "script-binding playback_feedback/file-loop" or "cycle-values loop-file inf no" or
            "osd-msg cycle-values loop-file inf no" => new("loop-file", value => value == "inf" ||
                long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out long count) && count > 0),
        "script-message-to playback_feedback set-speed 0.5" => Speed(0.5),
        "script-message-to playback_feedback set-speed 0.75" => Speed(0.75),
        "script-binding playback_feedback/speed-reset" => Speed(1),
        "script-message-to playback_feedback set-speed 1.25" => Speed(1.25),
        "script-message-to playback_feedback set-speed 1.5" => Speed(1.5),
        "script-message-to playback_feedback set-speed 2" => Speed(2),
        "script-message-to enhancement_controls set-preset OFF" => Choice("user-data/mpvnet/enhancement/applied", "OFF"),
        "script-message-to enhancement_controls set-preset QUALITY" => Choice("user-data/mpvnet/enhancement/applied", "QUALITY"),
        "script-message-to enhancement_controls set-preset SMOOTH" => Choice("user-data/mpvnet/enhancement/applied", "SMOOTH"),
        "script-message-to enhancement_controls set-preset ANIME_LIGHT" => Choice("user-data/mpvnet/enhancement/applied", "ANIME_LIGHT"),
        "script-message-to enhancement_controls set-preset ANIME_STRONG" => Choice("user-data/mpvnet/enhancement/applied", "ANIME_STRONG"),
        "script-message-to capture_controls set-default-format webp" => Choice("user-data/mpvnet/capture/clipboard_format", "webp"),
        "script-message-to capture_controls set-default-format gif" => Choice("user-data/mpvnet/capture/clipboard_format", "gif"),
        "script-message-to capture_controls set-default-format mp4" => Choice("user-data/mpvnet/capture/clipboard_format", "mp4"),
        _ => null
    };

    private static void OnRadioItemsChanged(object? sender, NotifyCollectionChangedEventArgs args)
    {
        // The host recreates these containers before it opens the popup.
        if (sender is ItemCollection items)
            MarkRadioItems(args.NewItems ?? items);
    }

    private static void MarkRadioItems(System.Collections.IEnumerable items)
    {
        foreach (var item in items.OfType<MenuItem>())
        {
            MenuMarks.SetShowMark(item, true);
            MenuMarks.SetIsRadio(item, true);
        }
    }

    public void Dispose()
    {
        if (_styles is not { } styles)
            return;

        foreach (var group in _radioGroups)
            ((INotifyCollectionChanged)group).CollectionChanged -= OnRadioItemsChanged;
        foreach (var entry in _items)
            SetGesture(entry.Item, entry.HostGesture);
        _root.Resources.MergedDictionaries.Remove(styles);
        if (_hostStyleBinding is not null)
            BindingOperations.SetBinding(_root, FrameworkElement.StyleProperty, _hostStyleBinding);
        else if (_hostLocalStyle == DependencyProperty.UnsetValue)
            _root.ClearValue(FrameworkElement.StyleProperty);
        else
            _root.Style = (Style?)_hostLocalStyle;
        _styles = null;
    }
}

public static class MenuMarks
{
    public static readonly DependencyProperty ShowMarkProperty = Register("ShowMark");
    public static readonly DependencyProperty IsRadioProperty = Register("IsRadio");
    public static readonly DependencyProperty IsMarkedProperty = Register("IsMarked");

    private static DependencyProperty Register(string name) =>
        DependencyProperty.RegisterAttached(name, typeof(bool), typeof(MenuMarks));

    public static bool GetShowMark(DependencyObject item) => (bool)item.GetValue(ShowMarkProperty);
    public static void SetShowMark(DependencyObject item, bool value) => item.SetValue(ShowMarkProperty, value);
    public static bool GetIsRadio(DependencyObject item) => (bool)item.GetValue(IsRadioProperty);
    public static void SetIsRadio(DependencyObject item, bool value) => item.SetValue(IsRadioProperty, value);
    public static bool GetIsMarked(DependencyObject item) => (bool)item.GetValue(IsMarkedProperty);
    public static void SetIsMarked(DependencyObject item, bool value) => item.SetValue(IsMarkedProperty, value);
}

public sealed class LongHeaderTooltip : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is string { Length: > 28 } title ? title : null;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}
