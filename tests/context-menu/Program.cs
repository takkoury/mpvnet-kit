using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

internal static class Program
{
    private const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

    [STAThread]
    private static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        try
        {
            var assembly = Assembly.LoadFile(System.IO.Path.GetFullPath(args.Single()));
            var type = assembly.GetType("KitContextMenu.MenuPresentation", throwOnError: true)!;

            var globalStyle = new Style(typeof(MenuItem));
            globalStyle.Setters.Add(new Setter(FrameworkElement.HeightProperty, 22d));
            app.Resources[typeof(MenuItem)] = globalStyle;
            var globalMenu = new Style(typeof(ContextMenu));
            globalMenu.Setters.Add(new Setter(FrameworkElement.WidthProperty, 135d));
            app.Resources[typeof(ContextMenu)] = globalMenu;
            var globalSeparator = new Style(typeof(Separator));
            app.Resources[MenuItem.SeparatorStyleKey] = globalSeparator;

            var menu = new ContextMenu();
            var category = new MenuItem { Header = "Category" };
            var pause = new MenuItem { Header = "Pause", InputGestureText = "Space", Tag = "kept" };
            var unknown = new MenuItem { Header = "Unknown", InputGestureText = "Ctrl+F" };
            var ignore = new MenuItem { Header = "Recent", InputGestureText = "O, Ctrl+v" };
            var speed = new MenuItem { Header = "Speed" };
            var reset = new MenuItem { Header = "Reset" };
            var half = new MenuItem { Header = "Half" };
            var device = new MenuItem { Header = "Device" };
            var tracks = new MenuItem { Header = "Tracks" };
            var chapter = new MenuItem { Header = "Chapter" };
            var originalTrack = new MenuItem { Header = "old", IsChecked = true };
            var separator = new Separator();
            separator.SetResourceReference(FrameworkElement.StyleProperty, MenuItem.SeparatorStyleKey);
            var unrelated = new ContextMenu();
            var otherItem = new MenuItem { Header = "Category" };
            var otherSeparator = new Separator();
            otherSeparator.SetResourceReference(FrameworkElement.StyleProperty, MenuItem.SeparatorStyleKey);
            unrelated.Items.Add(otherItem);
            otherItem.Items.Add(otherSeparator);

            menu.Items.Add(category);
            foreach (var item in new object[] { pause, unknown, separator, ignore, speed, device, tracks, chapter })
                category.Items.Add(item);
            speed.Items.Add(reset);
            speed.Items.Add(half);
            tracks.Items.Add(originalTrack);

            var items = new (string[] Path, string Command)[]
            {
                (new[] { "Category", "Pause" }, "script-binding playback_feedback/toggle-pause"),
                (new[] { "Category", "Unknown" }, "user command"),
                (new[] { "Category", "Recent" }, "ignore"),
                (new[] { "Category", "Speed", "Reset" }, "script-binding playback_feedback/speed-reset"),
                (new[] { "Category", "Speed", "Half" }, "script-message-to playback_feedback set-speed 0.5")
            };

            var evidence = new Dictionary<string, bool>
            {
                ["isolatedLoadFileContext"] = AssemblyLoadContext.GetLoadContext(assembly) != AssemblyLoadContext.Default,
                ["beforeNativeStyle"] = pause.Height == 22 && menu.Width == 135 &&
                    ReferenceEquals(separator.Style, globalSeparator)
            };
            var owner = type.GetMethod("FindRoot", BindingFlags.NonPublic | BindingFlags.Static)!;
            Func<string, MenuItem?> lookup = title => title switch
            {
                "Category" => category,
                "Pause" => pause,
                "Other" => otherItem,
                _ => null
            };
            evidence["ownerFromNestedBeforeOpen"] = ReferenceEquals(
                owner.Invoke(null, new object[] { lookup, new[] { "missing", "Pause" } }), menu);
            evidence["ambiguousOwnerRejected"] =
                owner.Invoke(null, new object[] { lookup, new[] { "Category", "Other" } }) is null;

            var constructor = type.GetConstructors(Instance).Single();
            var apply = type.GetMethod("Apply", Instance)!;
            var presentation = constructor.Invoke(new object[] { menu, items, new[] { tracks, device } });
            apply.Invoke(presentation, new object[] { 420d });
            var replacementMenu = new Style(typeof(ContextMenu));
            replacementMenu.Setters.Add(new Setter(FrameworkElement.WidthProperty, 142d));
            app.Resources[typeof(ContextMenu)] = replacementMenu;
            menu.InvalidateProperty(FrameworkElement.StyleProperty);
            menu.ApplyTemplate();
            separator.ApplyTemplate();
            evidence["rootTemplateSurvivesStyleReevaluation"] = menu.Width == 176 &&
                ReferenceEquals(menu.Style, menu.ReadLocalValue(FrameworkElement.StyleProperty)) &&
                VisualTreeHelper.GetChildrenCount(menu) == 1 &&
                VisualTreeHelper.GetChild(menu, 0) is Border { Background: SolidColorBrush rootBrush } &&
                rootBrush.Color == Color.FromRgb(0x15, 0x15, 0x15);
            evidence["separatorDynamicStyleUsesLocalLine"] = VisualTreeHelper.GetChildrenCount(separator) == 1 &&
                VisualTreeHelper.GetChild(separator, 0) is Border { Height: 1, Background: SolidColorBrush lineBrush } &&
                lineBrush.Color == Color.FromRgb(0x35, 0x35, 0x35);
            var refresh = type.GetMethod("Refresh", Instance)!;
            var applied = "{\"schema\":1,\"error\":\"invalid draft\",\"actions\":[{\"command\":\"script-binding playback_feedback/space\",\"keys\":[\"F3\",\"Ctrl+k\"]}]}";
            Func<string, string> read = property => property switch
            {
                "user-data/mpvnet/shortcuts" => applied,
                "pause" => "yes",
                "speed" => "0.500000",
                _ => ""
            };
            refresh.Invoke(presentation, new object[] { read, 400d });

            var rebuilt = new MenuItem { Header = "A: 未经选中路径 __后缀 继续测试文本_。长标题会使用提示显示完整内容", IsChecked = true };
            var uncheckedTrack = new MenuItem { Header = "unselected" };
            var audioDevice = new MenuItem { Header = "设备" };
            var dynamicChapter = new MenuItem { Header = "Chapter one", InputGestureText = "00:04:03" };
            int originalClicks = 0, dynamicClicks = 0;
            pause.Click += (_, _) => originalClicks++;
            rebuilt.Click += (_, _) => dynamicClicks++;
            tracks.Items.Clear();
            tracks.Items.Add(rebuilt);
            tracks.Items.Add(uncheckedTrack);
            device.Items.Add(audioDevice);
            audioDevice.IsChecked = true;
            chapter.Items.Add(dynamicChapter);

            foreach (var item in new[] { category, pause, unknown, ignore, reset, half, device, tracks, chapter,
                     rebuilt, uncheckedTrack, audioDevice, dynamicChapter })
                item.ApplyTemplate();

            static Visibility VisibilityOf(MenuItem item, string name) =>
                ((FrameworkElement)item.Template.FindName(name, item)!).Visibility;
            evidence["layoutStyle176And32"] = menu.Width == 176 && pause.Height == 32 && rebuilt.Height == 32;
            evidence["isolatedResources"] = otherItem.Height == 22 &&
                ReferenceEquals(app.Resources[typeof(MenuItem)], globalStyle) &&
                (ReferenceEquals(unrelated.Style, globalMenu) || ReferenceEquals(unrelated.Style, replacementMenu)) &&
                ReferenceEquals(otherSeparator.Style, globalSeparator);
            evidence["ignoredCommandHasNoGesture"] = ignore.InputGestureText == "";
            evidence["currentShortcutOverridesHost"] = pause.InputGestureText == "F3, Ctrl+k";
            evidence["unknownCommandRetainsGesture"] = unknown.InputGestureText == "Ctrl+F";
            evidence["chapterRetainsDuration"] = dynamicChapter.InputGestureText == "00:04:03";
            evidence["staticCheckedWithoutClickMutation"] = VisibilityOf(pause, "CheckMark") == Visibility.Visible
                && !pause.IsCheckable && !pause.IsChecked && Equals(pause.Tag, "kept");
            evidence["groupAlignment"] = VisibilityOf(unknown, "CheckSpace") == Visibility.Visible;
            evidence["staticRadioMarker"] = VisibilityOf(half, "RadioMark") == Visibility.Visible
                && VisibilityOf(reset, "RadioMark") == Visibility.Collapsed;
            evidence["rebuiltRadioMarker"] = VisibilityOf(rebuilt, "RadioMark") == Visibility.Visible
                && VisibilityOf(rebuilt, "CheckMark") == Visibility.Collapsed && rebuilt.IsChecked && !rebuilt.IsCheckable;
            evidence["uncheckedReservedRadioColumn"] = VisibilityOf(uncheckedTrack, "CheckSpace") == Visibility.Visible
                && VisibilityOf(uncheckedTrack, "RadioMark") == Visibility.Collapsed;
            evidence["radioMarkerUpdatesOnHostCheck"] = VisibilityOf(audioDevice, "RadioMark") == Visibility.Visible;
            evidence["longHeaderTooltipPreservesLiteralUnderscores"] =
                rebuilt.ToolTip is string tooltip && tooltip.Equals(rebuilt.Header);
            evidence["submenuTemplateHasNativePopup"] = category.Template.FindName("PART_Popup", category)
                is System.Windows.Controls.Primitives.Popup;
            pause.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent, pause));
            rebuilt.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent, rebuilt));
            evidence["hostClickEventsPreserved"] = originalClicks == 1 && dynamicClicks == 1;
            applied = "{\"schema\":1,\"actions\":[{\"command\":\"script-binding playback_feedback/space\",\"keys\":[]}]}";
            refresh.Invoke(presentation, new object[] { read, 400d });
            evidence["emptyKeysClearHostGesture"] = pause.InputGestureText == "";
            applied = "{";
            refresh.Invoke(presentation, new object[] { read, 400d });
            evidence["invalidPublicationFallsBack"] = pause.InputGestureText == "Space";
            ((IDisposable)presentation).Dispose();
            evidence["restoreHostStyleAndGesture"] = ReferenceEquals(menu.Style, replacementMenu) &&
                ReferenceEquals(separator.Style, globalSeparator) && pause.Height == 22 &&
                pause.InputGestureText == "Space" && ignore.InputGestureText == "O, Ctrl+v";
            var boundMenu = new ContextMenu();
            var binding = new Binding { Source = globalMenu };
            BindingOperations.SetBinding(boundMenu, FrameworkElement.StyleProperty, binding);
            var boundPresentation = constructor.Invoke(new object[] { boundMenu, items, Array.Empty<MenuItem>() });
            apply.Invoke(boundPresentation, new object[] { 420d });
            ((IDisposable)boundPresentation).Dispose();
            evidence["restoreOriginalRootStyleBinding"] =
                ReferenceEquals(BindingOperations.GetBindingBase(boundMenu, FrameworkElement.StyleProperty), binding) &&
                ReferenceEquals(boundMenu.Style, globalMenu);
            evidence["noVisibleWindowOrPopup"] = app.Windows.Count == 0 && !menu.IsOpen && !category.IsSubmenuOpen
                && PresentationSource.FromVisual(menu) is null;
            evidence["noHostAssembliesLoaded"] = !AppDomain.CurrentDomain.GetAssemblies()
                .Any(a => a.GetName().Name is "mpvnet" or "libmpvnet");
            var passed = evidence.Values.All(x => x);
            Console.WriteLine(JsonSerializer.Serialize(new { runtime = Environment.Version.ToString(), evidence, passed },
                new JsonSerializerOptions { WriteIndented = true }));
            return passed ? 0 : 1;
        }
        finally { app.Shutdown(); }
    }
}
