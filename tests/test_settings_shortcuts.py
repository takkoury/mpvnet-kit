"""Embedded shortcut controls and draft/save contracts; no HWND, player or files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = 'embedded-shortcuts-fixture'


def state(**changes):
    result = dict(schema=1, editor_token=TOKEN, revision='r1', error='', save_error='',
                  saving=False, save_serial=0, actions=[
                      dict(id='pause', label='播放 / 暂停', group='播放与定位', default_keys=['Space'], keys=['p']),
                      dict(id='mute', label='静音', group='音频', default_keys=['m'], keys=['m']),
                      dict(id='info', label='媒体信息', group='工具与设置', default_keys=[], keys=[]),
                  ])
    result.update(changes)
    return result


HARNESS = r'''
using System;
using System.Linq;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

public sealed class ShortcutFixtureSource : PresentationSource
{
    public override Visual RootVisual { get; set; }
    public override bool IsDisposed { get { return false; } }
    protected override CompositionTarget GetCompositionTargetCore() { return null; }
}
public static class EmbeddedShortcutFixture
{
    static object Field(object o, string name) { return o.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(o); }
    static void Call(object o, string name, params object[] args) { o.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(o, args); }
    static string Text(Dictionary<string, object> d, string name) { object v; return d.TryGetValue(name,out v) ? Convert.ToString(v) : ""; }
    static int Int(Dictionary<string, object> d, string name) { object v; return d.TryGetValue(name,out v) ? Convert.ToInt32(v) : 0; }
    static bool Flag(Dictionary<string, object> d, string name) { object v; return d.TryGetValue(name,out v) && v is bool && (bool)v; }
    static void Layout(SettingsShortcutsPanel p, int width, int height) { p.Measure(new Size(width,height)); p.Arrange(new Rect(0,0,width,height)); p.UpdateLayout(); }
    public static string Run(string requestJson)
    {
        var json = new JavaScriptSerializer(); var request = (Dictionary<string,object>)json.DeserializeObject(requestJson);
        var sent = new List<object[]>(); int changes = 0, confirms = 0; Action pendingConfirm = null;
        var p = new SettingsShortcutsPanel(command => sent.Add(command), () => changes++, (title,text,action) => { confirms++; pendingConfirm = action; });
        p.Adopt((Dictionary<string,object>)request["state"]);
        int width = Int(request,"width"), height = Int(request,"height"); Layout(p,width,height);
        var keyHandled = new List<bool>();
        foreach (Dictionary<string,object> step in (object[])request["steps"]) {
            string op = Text(step,"op"), id = Text(step,"id");
            if(op=="key") Call(p,"ChangeKey",id,Int(step,"index"),Text(step,"key"));
            else if(op=="clear") Call(p,"ChangeKey",id,Int(step,"index"),null);
            else if(op=="capture") Call(p,"BeginCapture",id,Int(step,"index"));
            else if(op=="vk") Call(p,"AcceptCapture",Int(step,"vk"),Flag(step,"ctrl"),Flag(step,"alt"),Flag(step,"shift"),Flag(step,"windows"));
            else if(op=="search") ((TextBox)Field(p,"search")).Text=Text(step,"text");
            else if(op=="focus-search") p.FocusSearch();
            else if(op=="filter") { p.GetType().GetField("filter",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(p,Text(step,"value")); Call(p,"RefreshRows"); }
            else if(op=="category") ((ComboBox)Field(p,"categories")).SelectedItem=Text(step,"value");
            else if(op=="locate") p.Locate(id);
            else if(op=="conflict") Call(p,"LocateConflict",id);
            else if(op=="restore") Call(p,"Restore",id);
            else if(op=="reset") p.Reset();
            else if(op=="confirm") { if(pendingConfirm!=null) pendingConfirm(); }
            else if(op=="revert") p.Revert();
            else if(op=="save") p.Save();
            else if(op=="state") p.Adopt((Dictionary<string,object>)step["state"]);
            else if(op=="disable") p.IsEnabled=false;
            else if(op=="timeout") { p.GetType().GetField("saveStarted",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(p,DateTime.UtcNow.AddSeconds(-20)); p.Tick(); }
            else if(op=="escape" || op=="typing") {
                var e = new KeyEventArgs(Keyboard.PrimaryDevice,new ShortcutFixtureSource(),0,op=="escape"?Key.Escape:Key.A) { RoutedEvent=Keyboard.PreviewKeyDownEvent };
                if(op=="typing") ((TextBox)Field(p,"search")).RaiseEvent(e); else p.RaiseEvent(e);
                keyHandled.Add(e.Handled);
            }
            else if(op=="click") {
                var button = Descendants<Button>(p).FirstOrDefault(b => System.Windows.Automation.AutomationProperties.GetAutomationId(b)==id);
                if(button==null) throw new InvalidOperationException("Missing button "+id);
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent,button));
            }
            Layout(p,width,height);
        }
        var visible = ((IEnumerable)Field(p,"visibleRows")).Cast<SettingsShortcutsPanel.ActionRow>().Select(x=>x.Id).ToArray();
        var boxes = Descendants<TextBox>(p).Select(x=>new { width=x.ActualWidth,height=x.ActualHeight,template_width=Descendants<ScrollViewer>(x).Select(s=>s.ActualWidth).FirstOrDefault(),template_height=Descendants<ScrollViewer>(x).Select(s=>s.ActualHeight).FirstOrDefault() }).ToArray();
        var localControls = Descendants<Button>(p).Where(b => b.IsVisible || b.Visibility==Visibility.Visible).Select(b=>new { id=System.Windows.Automation.AutomationProperties.GetAutomationId(b),width=b.ActualWidth }).ToArray();
        var result = new { dirty=p.Dirty,saving=p.Saving,can_save=p.CanSave,notice=p.Notice,sent=sent,confirms=confirms,changes=changes,
            draft=Field(p,"draft"),baseline=Field(p,"baseline"),revision=Field(p,"revision"),stale=Field(p,"stale"),capture=Field(p,"captureId"),expanded=Field(p,"expandedId"),
            search=((TextBox)Field(p,"search")).Text,category=Field(p,"category"),filter=Field(p,"filter"),visible=visible,
            results=p.Search(Text(request,"global_query")).Select(x=>new {id=x.Id,label=x.Label,group=x.Group}).ToArray(),
            key_handled=keyHandled,boxes=boxes,controls=localControls,
            defaults=Descendants<ItemsControl>(p).Where(x=>x.Name=="DefaultKeycaps").Select(x=>new {id=((SettingsShortcutsPanel.ActionRow)x.DataContext).Id,keys=x.Items.Cast<string>().ToArray()}).ToArray(),
            windows=Descendants<Window>(p).Count(),is_grid=p is Grid };
        return json.Serialize(result);
    }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T:DependencyObject
    {
        for(int i=0;i<VisualTreeHelper.GetChildrenCount(root);i++) { var child=VisualTreeHelper.GetChild(root,i);if(child is T)yield return (T)child; foreach(var nested in Descendants<T>(child))yield return nested; }
    }
}
'''

SCRIPT = r'''
param([string]$Root,[string]$Request,[string]$Harness)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$writer=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),$utf8)
try {
    Add-Type -AssemblyName System.Web.Extensions,PresentationFramework,PresentationCore,WindowsBase
    $references=@('System.Web.Extensions','System.Core','System.Xaml',[Windows.Window].Assembly.Location,[Windows.Media.Brushes].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location)
    Add-Type -ReferencedAssemblies $references -Path @((Join-Path $Root 'config/helpers/shortcut-key-names.cs'),(Join-Path $Root 'config/helpers/settings-shortcuts.cs'),$Harness)
    $writer.WriteLine([EmbeddedShortcutFixture]::Run([IO.File]::ReadAllText($Request,$utf8)))
} catch { $writer.WriteLine($_.Exception.ToString()); exit 1 } finally { $writer.Dispose() }
'''


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/WPF')
class SettingsShortcutsPanelTests(unittest.TestCase):
    def run_panel(self, steps=(), initial=None, query='', width=680, height=580):
        with tempfile.TemporaryDirectory(prefix='mpvnet-embedded-shortcuts-') as directory:
            folder = Path(directory)
            (folder / 'fixture.cs').write_text(HARNESS, encoding='utf-8-sig')
            (folder / 'run.ps1').write_text(SCRIPT, encoding='utf-8-sig')
            (folder / 'request.json').write_text(json.dumps(dict(state=initial or state(), steps=list(steps), global_query=query,
                width=width, height=height), ensure_ascii=False), encoding='utf-8')
            proc = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', str(folder / 'run.ps1'),
                '-Root', str(ROOT), '-Request', str(folder / 'request.json'), '-Harness', str(folder / 'fixture.cs')], capture_output=True, timeout=35)
            self.assertEqual(proc.returncode, 0, proc.stdout.decode('utf-8-sig', errors='replace') + proc.stderr.decode('utf-8', errors='replace'))
            self.assertEqual(proc.stderr, b'')
            return json.loads(proc.stdout.decode('utf-8-sig'))

    def test_embedded_controls_and_search_text_viewport(self):
        for width in [410, 680]:
            with self.subTest(width=width):
                data = self.run_panel(width=width)
                self.assertTrue(data['is_grid'])
                self.assertEqual(data['windows'], 0)
                self.assertFalse(data['dirty'])
                self.assertFalse(data['can_save'])
                self.assertGreater(data['boxes'][0]['template_height'], 10)
                self.assertGreater(data['boxes'][0]['template_width'], 100)
                self.assertEqual(set(data['visible']), {'pause', 'mute', 'info'})
                self.assertNotIn('Save', [c['id'] for c in data['controls']])

    def test_local_search_filters_and_global_search_are_independent(self):
        data = self.run_panel([dict(op='search', text='空格'), dict(op='category', value='音频')], query='媒体 信息')
        self.assertEqual(data['visible'], [])
        self.assertEqual([x['id'] for x in data['results']], ['info'])
        self.assertFalse(data['dirty'])
        data = self.run_panel([dict(op='filter', value='modified'), dict(op='search', text='播放 p')])
        self.assertEqual(data['visible'], ['pause'])

    def test_capture_preserves_modifier_case_and_reserved_keys(self):
        data = self.run_panel([dict(op='capture', id='pause'), dict(op='vk', vk=70, ctrl=True),
            dict(op='vk', vk=65, shift=True), dict(op='capture', id='pause', index=1), dict(op='vk', vk=65, ctrl=True, shift=True)])
        self.assertEqual(data['draft']['pause'], ['A', 'Ctrl+Shift+a'])
        self.assertTrue(data['can_save'])
        self.assertEqual(data['capture'], '')
        data = self.run_panel([dict(op='capture', id='pause'), dict(op='vk', vk=115, alt=True)])
        self.assertEqual(data['draft']['pause'], ['p'])
        self.assertEqual(data['capture'], 'pause')
        self.assertIn('保留', data['notice'])

    def test_search_and_filter_cancel_capture_without_dirtying(self):
        for action in [dict(op='search', text='静音'), dict(op='focus-search'), dict(op='filter', value='unbound'), dict(op='category', value='音频')]:
            with self.subTest(action=action):
                data = self.run_panel([dict(op='capture', id='pause'), action, dict(op='vk', vk=65)])
                self.assertEqual(data['capture'], '')
                self.assertFalse(data['dirty'])
        data = self.run_panel([dict(op='capture', id='pause'), dict(op='typing')])
        self.assertFalse(data['dirty'])
        self.assertEqual(data['key_handled'], [False])

    def test_esc_consumes_local_state_then_bubbles_to_host(self):
        data = self.run_panel([dict(op='search', text='播放'), dict(op='escape'), dict(op='locate', id='pause'), dict(op='escape'), dict(op='escape')])
        self.assertEqual(data['key_handled'], [True, True, False])
        self.assertEqual(data['search'], '')
        self.assertEqual(data['expanded'], '')

    def test_two_key_limit_conflict_and_navigation(self):
        data = self.run_panel([dict(op='key', id='pause', key='m'), dict(op='key', id='pause', index=1, key='x'),
            dict(op='key', id='pause', index=2, key='z'), dict(op='search', text='播放'), dict(op='conflict', id='pause')])
        self.assertEqual(data['draft']['pause'], ['m', 'x'])
        self.assertFalse(data['can_save'])
        self.assertEqual(data['expanded'], 'mute')
        self.assertEqual(data['search'], '')
        self.assertEqual(data['filter'], 'all')

    def test_real_row_buttons_default_keycaps_and_restoration(self):
        data = self.run_panel([dict(op='click', id='ShortcutDetail_pause'), dict(op='click', id='ShortcutRestore_pause')])
        self.assertEqual(data['draft']['pause'], ['Space'])
        self.assertTrue(data['dirty'])
        self.assertIn(dict(id='pause', keys=['空格']), data['defaults'])

    def test_reset_requires_host_confirmation_and_only_changes_draft(self):
        data = self.run_panel([dict(op='reset')])
        self.assertFalse(data['dirty'])
        self.assertEqual(data['confirms'], 1)
        data = self.run_panel([dict(op='reset'), dict(op='confirm'), dict(op='confirm')])
        self.assertEqual(data['draft']['pause'], ['Space'])
        self.assertEqual(data['sent'], [])
        self.assertTrue(data['dirty'])

    def test_save_payload_ack_and_revert(self):
        saved = state(revision='r2', save_serial=1)
        saved['actions'][0]['keys'] = ['x']
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='save'), dict(op='key', id='pause', key='z'), dict(op='state', state=saved)])
        self.assertEqual(data['sent'][0][:5], ['script-message-to', 'user_shortcuts', 'save', TOKEN, 'r1'])
        self.assertEqual(json.loads(data['sent'][0][5]), {'pause': ['x']})
        self.assertFalse(data['saving'])
        self.assertFalse(data['dirty'])
        self.assertEqual(data['draft']['pause'], ['x'])
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='revert')])
        self.assertEqual(data['draft']['pause'], ['p'])
        self.assertFalse(data['dirty'])

    def test_external_revision_keeps_draft_and_revert_reloads(self):
        external = state(revision='r2')
        external['actions'][0]['keys'] = ['z']
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='state', state=external), dict(op='save')])
        self.assertTrue(data['stale'])
        self.assertEqual(data['draft']['pause'], ['x'])
        self.assertEqual(data['sent'], [])
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='state', state=external), dict(op='revert')])
        self.assertEqual(data['draft']['pause'], ['z'])
        self.assertFalse(data['dirty'])
        self.assertFalse(data['stale'])

    def test_settings_domain_revision_rebases_only_identical_shortcut_baseline(self):
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='state', state=state(revision='settings-domain-r2')), dict(op='save')])
        self.assertEqual(data['draft']['pause'], ['x'])
        self.assertTrue(data['dirty'])
        self.assertFalse(data['stale'])
        self.assertEqual(data['sent'][0][4], 'settings-domain-r2')
        self.assertEqual(json.loads(data['sent'][0][5]), {'pause': ['x']})
        for changed in ['defaults', 'identity', 'error', 'read_only']:
            external = state(revision='r2')
            if changed == 'defaults': external['actions'][0]['default_keys'] = ['q']
            elif changed == 'identity': external['actions'][0]['id'] = 'new-pause'
            elif changed == 'error': external['error'] = '配置读取错误'
            else: external['read_only'] = True
            with self.subTest(changed=changed):
                data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='state', state=external), dict(op='save')])
                self.assertEqual(data['sent'], [])
                self.assertFalse(data['can_save'])
                self.assertTrue(data['stale'])
                self.assertEqual(data['draft']['pause'], ['x'])

    def test_save_failure_timeout_and_later_external_change_preserve_draft(self):
        for outcome in [dict(op='state', state=state(save_serial=1, save_error='磁盘错误')),
                        dict(op='timeout'), dict(op='state', state=state(save_serial=1, revision='r3'))]:
            with self.subTest(outcome=outcome):
                data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='save'), outcome])
                self.assertTrue(data['dirty'])
                self.assertFalse(data['saving'])
                self.assertEqual(data['draft']['pause'], ['x'])
                self.assertTrue(data['notice'])

    def test_readonly_repairable_invalid_and_disconnected_safety(self):
        for initial in [state(error='无法读取用户配置'), state(actions=[dict(id='bad', keys=['not-a-key'], default_keys=[])])]:
            data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='save')], initial=initial)
            self.assertFalse(data['can_save'])
            self.assertFalse(data['dirty'])
            self.assertEqual(data['sent'], [])
        repair = state(error='快捷键存在重复分配', repairable=True)
        repair['editable_actions'] = [dict(a) for a in repair['actions']]
        repair['editable_actions'][0]['keys'] = ['m']
        data = self.run_panel([dict(op='restore', id='pause'), dict(op='save')], initial=repair)
        self.assertTrue(data['saving'])
        self.assertEqual(json.loads(data['sent'][0][5]), {})
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='disable'), dict(op='save')])
        self.assertFalse(data['can_save'])
        self.assertTrue(data['dirty'])
        self.assertEqual(data['sent'], [])

    def test_foreign_token_and_schema_do_not_replace_state(self):
        data = self.run_panel([dict(op='state', state=state(editor_token='foreign', revision='r9')),
                               dict(op='state', state=state(schema=2, revision='r8'))])
        self.assertEqual(data['revision'], 'r1')
        self.assertFalse(data['stale'])

    def test_full_catalog_search_and_unbound_filter_keep_all_actions(self):
        initial = state()
        groups = ['播放与定位', '循环与标记', '字幕与弹幕', '音频', '画面', '截图与片段', '窗口与界面', '文件', '工具与设置']
        initial['actions'] = [dict(id='fixture.' + str(i), label='较长的合成目录操作 ' + str(i), group=groups[i % len(groups)],
            default_keys=['Space'] if i == 0 else [], keys=['Space'] if i == 0 else []) for i in range(195)]
        data = self.run_panel([dict(op='filter', value='unbound')], initial=initial, query='194', width=410)
        self.assertEqual(len(data['visible']), 194)
        self.assertEqual([row['id'] for row in data['results']], ['fixture.194'])
        self.assertFalse(data['dirty'])

    def test_same_action_duplicate_blocks_save_and_capture_cancel_clears_error(self):
        data = self.run_panel([dict(op='key', id='pause', index=1, key='p'), dict(op='save')])
        self.assertFalse(data['can_save'])
        self.assertIn('重复', data['notice'])
        self.assertEqual(data['sent'], [])
        data = self.run_panel([dict(op='capture', id='pause'), dict(op='vk', vk=70, ctrl=True), dict(op='escape')])
        self.assertEqual(data['capture'], '')
        self.assertEqual(data['notice'], '')
        self.assertFalse(data['dirty'])

    def test_malformed_publication_keeps_draft_locked_until_valid_state(self):
        malformed = state(revision='r2', actions=[dict(id='invalid', default_keys=[], keys=['not-a-key'])])
        data = self.run_panel([dict(op='key', id='pause', key='x'), dict(op='state', state=malformed), dict(op='revert'), dict(op='save')])
        self.assertEqual(data['draft']['pause'], ['x'])
        self.assertTrue(data['dirty'])
        self.assertFalse(data['can_save'])
        self.assertEqual(data['sent'], [])


if __name__ == '__main__':
    unittest.main()
