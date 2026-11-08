using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Linq;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

public static class PlaylistContextMenuProbe
{
    const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.DeclaredOnly;
    static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    static Dictionary<string, ToolStripMenuItem> Commands(PlaylistContextMenu menu)
    {
        return (Dictionary<string, ToolStripMenuItem>)typeof(PlaylistContextMenu).GetField("commands", PrivateInstance).GetValue(menu);
    }
    static void CallMenu(PlaylistContextMenu menu, string method, object argument)
    {
        var member = typeof(PlaylistContextMenu).GetMethod(method, PrivateInstance);
        Check(member != null && member.DeclaringType == typeof(PlaylistContextMenu), "production override missing: " + method);
        member.Invoke(menu, new[] { argument });
    }
    public static Dictionary<string, object> Run(string paintPath)
    {
        var result = new Dictionary<string, object>();
        using (var form = new PlaylistForm())
        using (var list = new ListView())
        using (var search = new TextBox())
        {
            form.Font = new Font("Microsoft YaHei UI", 9F); form.Controls.Add(list); form.Controls.Add(search);
            list.View = View.Details; list.Columns.Add("name", 260); list.Size = new Size(320, 240);
            list.Items.Add(new ListViewItem("第一项") { Name = "71" });
            list.Items.Add(new ListViewItem("第二项") { Name = "92" });
            IntPtr unused = form.Handle; unused = list.Handle;
            using (var keys = new PlaylistKeys(form))
            using (var menu = new PlaylistContextMenu(form, list, keys))
            {
                var commands = Commands(menu);
                string[] expected = { "play", "remove", "open-files", "open-folder", "open-clipboard", "append-files",
                    "append-folder", "append-clipboard", "save-playlist", "search", "locate", "previous", "next", "first", "last", "shuffle", "clear-playlist" };
                Check(commands.Keys.OrderBy(x => x).SequenceEqual(expected.OrderBy(x => x)), "menu must expose only accepted actions");
                var groups = menu.Items.OfType<ToolStripMenuItem>().Where(x => x.DropDownItems.Count != 0).ToArray();
                Check(groups.Select(x => x.Text).SequenceEqual(new[] { "打开", "追加", "播放顺序" }), "menu group order");
                Check(groups[0].DropDownItems.OfType<ToolStripMenuItem>().Select(x => x.Name).SequenceEqual(expected.Skip(2).Take(3)), "open submenu");
                Check(groups[1].DropDownItems.OfType<ToolStripMenuItem>().Select(x => x.Name).SequenceEqual(expected.Skip(5).Take(3)), "append submenu");
                result["commands"] = expected; result["groups"] = groups.Select(x => x.Text).ToArray();

                int total = 2, prepared = 0; bool current = true, targetExists = true;
                menu.Prepare += delegate { prepared++; menu.SetState(total, current, targetExists); };
                var actions = new List<string>(); var transmissions = new List<string>();
                menu.InvokeAction += delegate(string action, string id) { actions.Add(action + ":" + id); };
                keys.Transmit += delegate(string phase, string key) { transmissions.Add(phase + ":" + key); };
                menu.PrepareTarget("71");
                Check(commands["play"].Available && commands["remove"].Available, "row commands unavailable");
                Check(commands["save-playlist"].Enabled && commands["locate"].Enabled && commands["shuffle"].Enabled, "populated state");
                list.Items[1].Selected = true;
                menu.Execute("play"); menu.Execute("remove");
                Check(actions.SequenceEqual(new[] { "play:71", "remove:71" }), "context target must not follow changed selection");
                actions.Clear(); targetExists = false; menu.PrepareTarget("71"); menu.Execute("play"); menu.Execute("remove");
                Check(actions.Count == 0 && !commands["play"].Available, "stale row must not act");
                menu.PrepareTarget("");
                Check(!commands["play"].Available && !commands["remove"].Available, "blank context contains row actions");
                foreach (var action in expected.Skip(2)) menu.Execute(action);
                Check(actions.SequenceEqual(expected.Skip(2).Select(x => x + ":")), "global actions must emit empty row ID");
                int validActions = actions.Count; menu.Execute("clear"); menu.Execute("exec");
                Check(actions.Count == validActions, "unknown menu action accepted");
                total = 0; current = false; menu.PrepareTarget(null); actions.Clear();
                foreach (var action in new[] { "save-playlist", "locate", "previous", "next", "first", "last", "shuffle", "clear-playlist" }) menu.Execute(action);
                Check(actions.Count == 0 && !commands["save-playlist"].Enabled && !commands["clear-playlist"].Enabled && !commands["locate"].Enabled && !groups[2].Enabled, "empty actions enabled");
                menu.Execute("open-files"); menu.Execute("append-folder"); menu.Execute("search");
                Check(actions.SequenceEqual(new[] { "open-files:", "append-folder:", "search:" }), "empty queue globals disabled");
                total = 1; targetExists = true; menu.PrepareTarget("71");
                Check(commands["save-playlist"].Enabled && commands["first"].Enabled && !commands["shuffle"].Enabled, "single item state");
                Check(prepared == 5 && !menu.Visible && !form.Visible, "prepare must remain hidden");
                result["state_and_target"] = true; result["global_events"] = validActions; result["prepared"] = prepared;

                menu.SetHint("open-files", "Ctrl+o"); Check(commands["open-files"].ShortcutKeyDisplayString == "Ctrl+o", "hint update");
                menu.SetHint("open-files", null); Check(commands["open-files"].ShortcutKeyDisplayString == "", "hint clear");
                menu.SetHint("search", "F8"); menu.SetHint("remove", "F9"); menu.SetHint("unknown", "F10");
                Check(commands["search"].ShortcutKeyDisplayString == "Ctrl+F" && commands["remove"].ShortcutKeyDisplayString == "Delete", "local hints overwritten");
                result["hints"] = true;

                var held = (Dictionary<int, string>)typeof(PlaylistKeys).GetField("held", PrivateInstance).GetValue(keys);
                held.Add(32, "Space"); transmissions.Clear();
                CallMenu(menu, "OnOpening", new CancelEventArgs(false));
                Check(keys.MenuActive && held.Count == 0 && transmissions.SequenceEqual(new[] { "release:" }), "opening must release and block forwarding");
                Check(commands["remove"].ShortcutKeys == Keys.Delete && commands["search"].ShortcutKeys == (Keys.Control | Keys.F), "local menu shortcuts not enabled");
                CallMenu(menu, "OnClosed", new ToolStripDropDownClosedEventArgs(ToolStripDropDownCloseReason.Keyboard));
                Check(!keys.MenuActive, "closing did not end menu input ownership");
                Check(commands["remove"].ShortcutKeys == Keys.None && commands["search"].ShortcutKeys == Keys.None, "closed menu retained stale target shortcuts");
                foreach (var vk in new[] { 13, 27, 32, 37, 38, 39, 40, 35, 36, 33,34,9,93,121,46,70 })
                {
                    Check(keys.FilterMenuKey(0x100, vk, 0x40000000L), "held repeat leaked: " + vk);
                    Check(keys.FilterMenuKey(0x104, vk, 0x40000000L), "held system repeat leaked: " + vk);
                    Check(keys.FilterMenuKey(0x101, vk, 0), "handoff key-up leaked: " + vk);
                    Check(!keys.FilterMenuKey(0x100, vk, 0), "fresh key-down blocked: " + vk);
                    Check(!keys.FilterMenuKey(0x100, vk, 0x40000000L), "fresh key repeat blocked: " + vk);
                }
                keys.EndMenu(); Check(!keys.FilterMenuKey(0x100, 13, 0), "fresh down without prior up should resume");
                Check(!keys.FilterMenuKey(0x101, 13, 0), "fresh up swallowed");
                Check(!keys.FilterMenuKey(0x100, 75, 0x40000000L), "unrelated key swallowed");
                Check(PlaylistKeys.IsContextInvocation(93, Keys.None) && PlaylistKeys.IsContextInvocation(121, Keys.Shift), "local menu keys not recognized");
                Check(!PlaylistKeys.IsContextInvocation(93, Keys.Control) && !PlaylistKeys.IsContextInvocation(121, Keys.None) &&
                    !PlaylistKeys.IsContextInvocation(121, Keys.Control | Keys.Shift), "modified unrelated key stolen");
                held.Add(32, "Space"); transmissions.Clear();
                CallMenu(menu, "OnOpening", new CancelEventArgs(true));
                Check(!keys.MenuActive && held.Count == 1 && transmissions.Count == 0, "cancelled opening stole input");
                held.Clear(); result["input_handoff"] = true;

                total = 2; current = true; menu.PrepareTarget("71");
                menu.PerformLayout(); menu.Size = menu.GetPreferredSize(Size.Empty); menu.CreateControl();
                Check(!menu.Visible && !form.Visible, "painting must not show any window");
                using (var bitmap = new Bitmap(menu.Width, menu.Height))
                { menu.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(paintPath, ImageFormat.Png); }
                result["layout"] = menu.Items.Cast<ToolStripItem>().Select(x => new { text = x.Text, bounds = x.Bounds.ToString(), preferred = x.GetPreferredSize(Size.Empty).ToString() }).ToArray();
                commands["search"].Select();
                using (var bitmap = new Bitmap(menu.Width, menu.Height))
                { menu.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(Path.ChangeExtension(paintPath, "hover.png"), ImageFormat.Png); }
                var submenu = groups[0].DropDown;
                submenu.PerformLayout(); submenu.Size = submenu.GetPreferredSize(Size.Empty); submenu.CreateControl();
                using (var bitmap = new Bitmap(submenu.Width, submenu.Height))
                { submenu.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(Path.ChangeExtension(paintPath, "submenu.png"), ImageFormat.Png); }
                Check(menu.Font.FontFamily.Name == "Microsoft YaHei UI", "menu font differs from mpv menu");
                Check(Math.Abs(menu.Font.SizeInPoints - 9.75f) < 0.01f, "menu font must be 13 DIP at fixture DPI");
                Check(menu.Items.OfType<ToolStripMenuItem>().All(x => x.Height == 32), "root row height must match mpv menu");
                Check(submenu.Items.OfType<ToolStripMenuItem>().All(x => x.Height == 32), "submenu row height must match mpv menu");
                Check(menu.Region != null && submenu.Region != null, "rounded popup regions missing");
                Check(menu.Items.OfType<ToolStripMenuItem>().All(x => x.Bounds.Right <= menu.Width), "root items clip at popup edge");
                Check(submenu.Items.OfType<ToolStripMenuItem>().All(x => x.Bounds.Right <= submenu.Width), "submenu items clip at popup edge");
                result["style_geometry"] = true;
                result["paint_path"] = paintPath; result["paint_size"] = new[] { menu.Width, menu.Height };
                result["shown"] = menu.Visible || form.Visible;
            }
        }
        return result;
    }
}
