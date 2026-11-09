"""Native WPF construction and draft transitions, without player or user files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = 'settings-fixture'


def state(**changes):
    fields = []
    for key, page, label in [('sub-scale', 'subtitles', '字幕缩放'),
                             ('modernz.scalewindowed', 'controlbar', '窗口控制栏缩放')]:
        fields.append(dict(id=key, page=page, label=label, default=1, saved=1,
                           search_terms='字幕大小 字号 比例 字体大小' if key == 'sub-scale' else '控制栏大小 比例 OSC',
                           has_override=False, effective=1, status='effective',
                           apply_error='', min=0.05, max=100, slider_min=0.5, slider_max=2, step=0.05, default_source='启动配置'))
    for key, label in [('capture_root', '截图与片段目录'), ('ffmpeg_path', 'FFmpeg 路径'),
                       ('python_path', 'Python 路径'), ('mpv_path', '缩略图播放器路径')]:
        fields.append(dict(id=key, page='paths', label=label, default='', saved='',
                           has_override=False, effective='', status='effective', apply_error=''))
    result = dict(schema=1, editor_token=TOKEN, revision='r1', paths_revision='p1',
                  error='', paths_error='', saving=False, save_serial=0, save_page='',
                  save_ok=False, save_error='', preview_error='', fields=fields)
    result.update(changes)
    return result


def complete_state():
    result = state()
    for f in result['fields'][:2]:
        f.update(kind='number', display='percent', timing='preview', section='字幕外观' if f['page'] == 'subtitles' else '显示比例')
    def add(key, page, label, kind, default, timing, **metadata):
        f = dict(id=key, page=page, label=label, kind=kind, default=default, saved=default,
                 has_override=False, effective=default, status='effective', apply_error='',
                 timing=timing, section={'audio': '启动时', 'window': '启动时', 'decoding': '下一媒体'}.get(page, '显示方式'), default_source='启动配置')
        f.update(metadata)
        result['fields'].append(f)
    add('slang', 'subtitles', '字幕语言顺序', 'string', 'zh,en', 'next-media', section='下一媒体')
    add('sub-visibility', 'subtitles', '默认显示字幕', 'boolean', True, 'next-media', section='下一媒体')
    add('sub-font', 'subtitles', '字幕字体', 'string', 'sans-serif', 'preview', section='字幕外观')
    add('sub-pos', 'subtitles', '字幕位置', 'number', 100, 'preview', display='position', min=0, max=100, slider_min=0, slider_max=100, step=1, section='字幕外观')
    add('alang', 'audio', '音轨语言顺序', 'string', 'zh,en', 'next-media', section='下一媒体')
    add('volume', 'audio', '启动音量', 'number', 80, 'startup', display='number', min=0, max=1000, slider_min=0, slider_max=100, step=1)
    add('mute', 'audio', '启动静音', 'boolean', False, 'startup')
    add('fullscreen', 'window', '默认全屏', 'boolean', False, 'startup')
    add('ontop', 'window', '默认置顶', 'boolean', False, 'startup')
    add('modernz.scalefullscreen', 'controlbar', '全屏控制栏缩放', 'number', 1, 'preview', display='percent', min=.25, max=4, slider_min=.5, slider_max=2, step=.05)
    add('modernz.hidetimeout', 'controlbar', '自动隐藏时间', 'number', 1.5, 'preview', display='seconds', min=0, max=60, slider_min=0, slider_max=10, step=.1)
    add('modernz.keeponpause', 'controlbar', '暂停时显示', 'choice', 'bottombar', 'preview', choices=[dict(value='no', label='不保持'), dict(value='bottombar', label='显示控制栏'), dict(value='both', label='显示全部')])
    for key, label in [('chapter_fmt', '显示章节标题'), ('timecurrent', '显示当前时间'), ('timems', '时间显示毫秒'), ('persistent_progress', '常驻进度线')]:
        add('modernz.' + key, 'controlbar', label, 'boolean', False, 'preview')
    add('hwdec', 'decoding', '硬件解码', 'choice', 'auto-copy', 'next-media', choices=[dict(value='auto-safe', label='自动安全硬解'), dict(value='no', label='关闭硬解')])
    for f in result['fields']:
        if f['page'] == 'paths': f.update(kind='string', timing='next-task' if f['id'] == 'capture_root' else 'restart', section='输出目录' if f['id'] == 'capture_root' else '外部程序')
    order = ['slang', 'sub-visibility', 'sub-font', 'sub-pos', 'sub-scale', 'alang', 'volume', 'mute', 'fullscreen', 'ontop',
             'modernz.scalewindowed', 'modernz.scalefullscreen', 'modernz.hidetimeout', 'modernz.keeponpause', 'modernz.chapter_fmt',
             'modernz.persistent_progress', 'modernz.timecurrent', 'modernz.timems', 'hwdec', 'capture_root', 'ffmpeg_path', 'python_path', 'mpv_path']
    result['fields'].sort(key=lambda field: order.index(field['id']))
    return result


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF')
class SettingsWindow(unittest.TestCase):
    def test_hidden_editor_sends_ipc_without_allocating_validation_capture(self):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', str(ROOT / 'tests/fixtures/window_ipc.ps1'), '-Editor', 'Settings',
            '-SourcePath', str(ROOT / 'config/helpers/settings-window.ps1')], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(result.stderr, b'')
        data = json.loads(result.stdout.decode('utf-8-sig'))
        self.assertEqual(data['ready'], ['script-message-to', 'user_settings', 'editor-ready', 'fixture-token-123'])
        self.assertEqual(data['close'], ['script-message-to', 'user_settings', 'editor-close', 'fixture-token-123', '0'])

    def test_ipc_drains_messages_queued_before_run_without_timer(self):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', str(ROOT / 'tests/fixtures/window_ipc.ps1'), '-Editor', 'Settings', '-Mode', 'QueuedClientClose',
            '-SourcePath', str(ROOT / 'config/helpers/settings-window.ps1')], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(result.stderr, b'')
        data = json.loads(result.stdout.decode('utf-8-sig'))
        self.assertEqual(data['close'], ['script-message-to', 'user_settings', 'editor-close', 'fixture-token-123', '7'])
        self.assertTrue(data['settings_untouched'])

    def test_background_prepares_once_and_adopts_live_state_without_preview(self):
        updated = state(revision='r2', editor_visible=False)
        updated['fields'][0].update(saved=1.4, has_override=True)
        data = self.run_window([dict(op='state', state=updated), dict(op='page', page='controlbar'),
                                dict(op='display-available', value=True),
                                dict(op='preview', id='modernz.scalewindowed')],
                               initial=state(editor_visible=False), entry=dict(start_hidden=True))
        self.assertTrue(data['prepared'])
        self.assertFalse(data['show_requested'])
        self.assertFalse(data['display_requested'])
        self.assertEqual(data['dirty_pages'], [])
        self.assertCountEqual(data['navigation_reused'], data['pages'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.4')
        self.assertEqual(data['sent'], [['script-message-to', 'user_settings', 'editor-prepared', TOKEN]])

    def test_background_rejects_wrong_token_and_waits_for_settings(self):
        wrong_state = state(editor_token='different', editor_visible=True, open_page='shortcuts', open_serial=2)
        step = dict(op='ipc', events=[dict(event='client-message', args=['mpvnet-settings-show', 'different'])])
        data = self.run_window([step], initial=wrong_state, entry=dict(start_hidden=True))
        self.assertFalse(data['prepared'])
        self.assertFalse(data['show_requested'])
        self.assertEqual(data['page'], 'subtitles')
        self.assertEqual(data['sent'], [])

    def test_show_message_before_first_settings_snapshot_is_held(self):
        show = dict(op='ipc', events=[dict(event='client-message', args=['mpvnet-settings-show', TOKEN])])
        waiting = self.run_window([show], initial={}, entry=dict(start_hidden=True))
        self.assertTrue(waiting['show_requested'])
        self.assertFalse(waiting['prepared'])
        self.assertFalse(waiting['ready_to_show'])
        ready = self.run_window([show, dict(op='state', state=state(editor_visible=False))],
                                initial={}, entry=dict(start_hidden=True))
        self.assertTrue(ready['prepared'])
        self.assertTrue(ready['ready_to_show'])

    def test_visible_snapshot_before_preparation_preserves_latest_shortcuts_navigation(self):
        early = state(fields=[], editor_visible=True)
        waiting = self.run_window(initial=early, entry=dict(start_hidden=True))
        self.assertTrue(waiting['show_requested'])
        self.assertFalse(waiting['ready_to_show'])
        incoming = state(editor_visible=True, open_page='shortcuts', open_serial=2)
        data = self.run_window([dict(op='state', state=incoming)], initial=early, entry=dict(start_hidden=True))
        self.assertTrue(data['prepared'])
        self.assertTrue(data['ready_to_show'])
        self.assertEqual(data['page'], 'shortcuts')
        self.assertEqual(data['navigation_serial'], 2)
        self.assertFalse(data['navigation_pending'])

    def test_background_close_in_same_ipc_batch_cancels_show(self):
        opened = dict(event='property-change', name='user-data/mpvnet/settings', data=state(editor_visible=True))
        closed = dict(event='client-message', args=['mpvnet-settings-close', TOKEN])
        data = self.run_window([dict(op='ipc', events=[opened, closed, opened])], initial={}, entry=dict(start_hidden=True))
        self.assertTrue(data['close_accepted'])
        self.assertFalse(data['prepared'])
        self.assertFalse(data['show_requested'])
        self.assertEqual(data['sent'], [['script-message-to', 'user_settings', 'editor-close', TOKEN, '0']])

    def test_background_disconnect_discards_pending_show_and_late_state(self):
        show = dict(op='ipc', events=[dict(event='client-message', args=['mpvnet-settings-show', TOKEN])])
        steps = [show, dict(op='disconnect'), dict(op='state', state=state(editor_visible=True)), show]
        data = self.run_window(steps, initial={}, entry=dict(start_hidden=True))
        self.assertFalse(data['prepared'])
        self.assertFalse(data['show_requested'])
        self.assertFalse(data['ready_to_show'])
        self.assertEqual(data['sent'], [])

    def test_shortcut_entry_starts_on_embedded_page(self):
        data = self.run_window(initial=state(open_page='shortcuts', open_serial=1),
                               entry=dict(open_page='shortcuts', open_serial=1))
        self.assertEqual(data['page'], 'shortcuts')
        self.assertTrue(data['embedded_shortcuts_visible'])
        self.assertFalse(data['navigation_pending'])

    def test_shortcut_navigation_preserves_drafts_and_consumes_each_serial_once(self):
        incoming = state(open_page='shortcuts', open_serial=1)
        steps = [dict(op='edit', id='sub-scale', text='1.2'), dict(op='search', text='字幕'),
                 dict(op='state', state=incoming)]
        data = self.run_window(steps)
        self.assertEqual(data['page'], 'shortcuts')
        self.assertTrue(data['embedded_shortcuts_visible'])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.2')
        self.assertFalse(any(c[2] == 'save' for c in data['sent']))
        data = self.run_window(steps + [dict(op='page', page='paths'), dict(op='state', state=incoming),
                                       dict(op='state', state=state(open_page='shortcuts', open_serial=0))])
        self.assertEqual(data['page'], 'paths')
        self.assertEqual(data['navigation_serial'], 1)

    def test_shortcut_navigation_waits_for_close_confirmation(self):
        steps = [dict(op='edit', id='sub-scale', text='1.2'), dict(op='request-close'),
                 dict(op='state', state=state(open_page='shortcuts', open_serial=1)), dict(op='navigation-poll')]
        blocked = self.run_window(steps)
        self.assertTrue(blocked['overlay_open'])
        self.assertTrue(blocked['navigation_pending'])
        self.assertEqual(blocked['page'], 'subtitles')
        data = self.run_window(steps + [dict(op='close-choice', id='CloseCancel'), dict(op='navigation-poll')])
        self.assertEqual(data['page'], 'shortcuts')
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        closed = self.run_window(steps + [dict(op='close-choice', id='CloseDiscard'), dict(op='navigation-poll')])
        self.assertTrue(closed['close_accepted'])
        self.assertEqual(closed['page'], 'subtitles')
        close_command = next(c for c in closed['sent'] if c[2] == 'editor-close')
        self.assertEqual(close_command[4], '1')

    def test_shortcut_navigation_waits_for_native_path_dialog(self):
        steps = [dict(op='page', page='paths'), dict(op='native-dialog', open=True),
                 dict(op='state', state=state(open_page='shortcuts', open_serial=1)), dict(op='navigation-poll')]
        blocked = self.run_window(steps)
        self.assertEqual(blocked['page'], 'paths')
        self.assertTrue(blocked['navigation_pending'])
        data = self.run_window(steps + [dict(op='native-dialog', open=False), dict(op='navigation-poll')])
        self.assertEqual(data['page'], 'shortcuts')

    def test_shortcut_navigation_waits_for_save_acknowledgement(self):
        from test_settings_close import saved_state
        incoming = state(open_page='shortcuts', open_serial=1)
        steps = [dict(op='edit', id='sub-scale', text='1.2'), dict(op='save'),
                 dict(op='state', state=incoming), dict(op='navigation-poll')]
        blocked = self.run_window(steps)
        self.assertTrue(blocked['saving'])
        self.assertEqual(blocked['page'], 'subtitles')
        data = self.run_window(steps + [dict(op='state', state=saved_state(incoming, 'subtitles', 1, **{'sub-scale': 1.2}))])
        self.assertEqual(data['page'], 'shortcuts')
        self.assertEqual(data['dirty_pages'], [])

    def test_navigation_rejects_unknown_target_stale_token_and_bad_serial(self):
        steps = [dict(op='state', state=state(open_page='paths', open_serial=99)),
                 dict(op='state', state=state(open_page='shortcuts', open_serial=5, editor_token='stale')),
                 dict(op='state', state=state(open_page='shortcuts', open_serial='bad'))]
        data = self.run_window(steps)
        self.assertEqual(data['page'], 'subtitles')
        self.assertEqual(data['navigation_serial'], 0)

    def test_navigation_only_replaces_content_when_its_dirty_marker_changes(self):
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'),
                                dict(op='state', state=state(editor_visible=True))])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertCountEqual(data['navigation_reused'], [page for page in data['pages'] if page != 'subtitles'])

    def run_window(self, steps=(), initial=None, width=1100, height=720, render=False, entry=None):
        with tempfile.TemporaryDirectory(prefix='mpvnet-settings-window-') as temp:
            request = Path(temp) / 'request.json'
            request.write_text(json.dumps(dict(schema=1, token=TOKEN, script='user_settings',
                parent_pid=os.getpid(), pipe='fixture-unused', validation_state=state() if initial is None else initial,
                validation_steps=list(steps), validation_width=width, validation_height=height,
                validation_render_path=str(Path(temp) / 'render.png') if render else '', **(entry or {})), ensure_ascii=False), encoding='utf-8')
            executable = os.environ.get('MPVNET_TEST_SETTINGS_EXECUTABLE')
            if executable:
                path = Path(executable)
                if not path.is_absolute() or not path.is_file():
                    raise RuntimeError('MPVNET_TEST_SETTINGS_EXECUTABLE must name an existing absolute path')
                launcher = [str(path)]
            else:
                launcher = ['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                            '-File', str(ROOT / 'config/helpers/settings-window.ps1')]
            result = subprocess.run([*launcher, '-RequestPath', str(request),
                '-ValidateOnly', '-NoShow'], capture_output=True, timeout=30)
            self.assertEqual(result.stderr, b'', result.stderr.decode('utf-8', errors='replace'))
            data = json.loads(result.stdout.decode('utf-8-sig'))
            self.assertEqual(result.returncode, 0, data)
            self.assertTrue(data['ok'])
            self.assertFalse(data['shown'])
            self.assertFalse(data['has_handle'])
            if render:
                self.assertEqual((Path(temp) / 'render.png').read_bytes()[:8], b'\x89PNG\r\n\x1a\n')
            return data

    def test_native_controls_initial_state(self):
        data = self.run_window()
        self.assertEqual(data['dirty_pages'], [])
        self.assertFalse(data['can_save'])
        self.assertEqual(len(data['drafts']), 6)

    def test_loading_notice_waits_for_current_editor_state(self):
        waiting = '正在连接播放器…'
        for entry in ({}, dict(open_page='shortcuts', open_serial=1)):
            with self.subTest(entry=entry):
                data = self.run_window(initial=state(editor_token='different-editor'), entry=entry)
                self.assertEqual(data['notice'], waiting)
                self.assertFalse(data['can_save'])
        loaded = self.run_window([dict(op='state', state=state())], initial={})
        self.assertEqual(loaded['notice'], '')
        failed = self.run_window([dict(op='disconnect')], initial={})
        self.assertIn('播放器连接中断', failed['notice'])

    def test_compiled_host_rejects_invalid_startup_before_creating_window(self):
        executable = ROOT / 'config/helpers/KitSettings.exe'
        for arguments in ([], ['-Unexpected'], ['-RequestPath'], ['-NoShow', '-NoShow']):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(executable), *arguments], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, b'')
                data = json.loads(result.stdout.decode('utf-8-sig'))
                self.assertFalse(data['ok'])
                self.assertIn('设置窗口', data['error'])

    def test_search_all_pages_preserves_other_drafts(self):
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'),
                               dict(op='search', text='FFmpeg'), dict(op='page', page='paths')])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.2')
        self.assertEqual(data['search_results'], ['FFmpeg 路径 · 输出与组件'])
        self.assertEqual([c[2] for c in data['sent']], ['preview'])

    def test_save_only_current_page_and_keep_other_draft(self):
        saved = state(revision='r2', save_revision='r2', save_serial=1, save_page='controlbar', save_ok=True)
        saved['fields'][1].update(saved=1.3, has_override=True, effective=1.3)
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'),
            dict(op='edit', id='modernz.scalewindowed', text='1.3'), dict(op='save'),
            dict(op='state', state=saved)])
        command = data['sent'][-1]
        self.assertEqual(command[2:6], ['save', TOKEN, 'r1', 'controlbar'])
        self.assertEqual(json.loads(command[6]), {'modernz.scalewindowed': 1.3})
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['revisions']['subtitles'], 'r2')

    def test_external_update_cannot_rebase_dirty_page(self):
        external = state(revision='r2')
        external['fields'][0].update(saved=1.6, has_override=True)
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'), dict(op='state', state=external), dict(op='save')])
        self.assertFalse(data['can_save'])
        self.assertEqual([c[2] for c in data['sent']], ['preview'])
        self.assertEqual(data['revisions']['subtitles'], 'r1')
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.2')

    def test_save_failure_keeps_draft_and_error(self):
        failed = state(save_serial=1, save_page='subtitles', save_error='配置冲突', save_ok=False)
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'), dict(op='save'), dict(op='state', state=failed)])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertFalse(data['saving'])
        self.assertIn('配置冲突', data['notice'])

    def test_external_write_after_save_retains_submitted_draft(self):
        external = state(revision='r3', save_revision='', save_serial=1, save_page='subtitles', save_ok=True)
        external['fields'][0].update(saved=1.8, has_override=True)
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'), dict(op='save'), dict(op='state', state=external)])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.2')
        self.assertIn('草稿已保留', data['notice'])

    def test_own_save_does_not_erase_existing_other_page_conflict(self):
        external = state(revision='r2')
        external['fields'][0].update(saved=1.8, has_override=True)
        saved = state(revision='r3', save_revision='r3', save_serial=1, save_page='controlbar', save_ok=True)
        saved['fields'][0].update(saved=1.8, has_override=True)
        saved['fields'][1].update(saved=1.3, has_override=True)
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'), dict(op='state', state=external),
            dict(op='edit', id='modernz.scalewindowed', text='1.3'), dict(op='save'), dict(op='state', state=saved),
            dict(op='page', page='subtitles')])
        self.assertEqual(data['revisions']['subtitles'], 'r1')
        self.assertFalse(data['can_save'])

    def test_reset_is_draft_and_preview_then_save_deletes_override(self):
        initial = state()
        initial['fields'][0].update(saved=1.4, effective=1.4, has_override=True)
        data = self.run_window([dict(op='reset'), dict(op='save')], initial)
        self.assertEqual(data['sent'][0][2:], ['preview', TOKEN, 'sub-scale', 'null'])
        self.assertEqual(json.loads(data['sent'][1][-1]), {'sub-scale': None})

    def test_undo_only_own_page_and_uses_latest_saved(self):
        external = state(revision='r2')
        external['fields'][0].update(saved=1.6, has_override=True)
        data = self.run_window([dict(op='edit', id='modernz.scalewindowed', text='1.3'),
            dict(op='edit', id='sub-scale', text='1.2'), dict(op='state', state=external), dict(op='undo')])
        self.assertEqual(data['sent'][-1][2:], ['cancel', TOKEN, 'subtitles'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.6')
        self.assertEqual(data['dirty_pages'], ['controlbar'])

    def test_media_change_keeps_draft_and_requires_new_preview(self):
        after = state()
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.3'), dict(op='preview', id='sub-scale'),
            dict(op='state', state=after)])
        self.assertEqual(len(data['sent']), 2)
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.3')

    def test_paths_use_separate_revision(self):
        initial = state()
        unc = r'\\server\share\Capture'
        capture = next(field for field in initial['fields'] if field['id'] == 'capture_root')
        capture.update(saved=unc, effective=unc, has_override=True)
        data = self.run_window([dict(op='edit', id='python_path', text=r'C:\python.exe'), dict(op='save')], initial=initial)
        self.assertEqual(data['sent'][-1][4:6], ['p1', 'paths'])
        self.assertEqual(json.loads(data['sent'][-1][-1]),
                         dict(capture_root=unc, ffmpeg_path='', python_path=r'C:\python.exe', mpv_path=''))

    def test_invalid_number_does_not_preview_or_save(self):
        for text in ['NaN', 'Infinity', '0', 'bad']:
            with self.subTest(text=text):
                data = self.run_window([dict(op='edit', id='sub-scale', text=text), dict(op='preview', id='sub-scale'), dict(op='save')])
                self.assertEqual(data['sent'], [])
                self.assertFalse(data['can_save'])

    def test_connection_failure_retains_draft_and_blocks_save(self):
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.3'), dict(op='disconnect'), dict(op='save')])
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.3')
        self.assertFalse(data['can_save'])
        self.assertIn('连接中断，草稿已保留', data['notice'])

    def test_inline_preview_keeps_aspect_and_only_appearance_pages(self):
        initial = self.run_window()
        self.assertTrue(initial['preview_visible'])
        x, y, width, height = map(float, initial['preview_fit'].split(','))
        self.assertAlmostEqual(width / height, 16 / 9)
        self.assertGreater(x, 0)
        self.assertEqual(y, 0)
        paths = self.run_window([dict(op='page', page='paths')])
        self.assertFalse(paths['preview_visible'])

    def test_controlbar_display_released_on_page_change_without_losing_draft(self):
        data = self.run_window([dict(op='page', page='controlbar'), dict(op='display-available', value=True),
            dict(op='edit', id='modernz.scalewindowed', text='1.3'), dict(op='page', page='paths')])
        messages = [c[-1] for c in data['sent'] if c[2] == 'preview-display']
        self.assertEqual(messages, ['controlbar', 'controlbar', 'none'])
        self.assertFalse(data['display_requested'])
        self.assertEqual(data['dirty_pages'], ['controlbar'])

    def test_unavailable_display_ends_lease_but_preserves_drafts(self):
        data = self.run_window([dict(op='edit', id='modernz.scalewindowed', text='1.3'),
            dict(op='display-available', value=False)])
        self.assertEqual([c[-1] for c in data['sent'] if c[2] == 'preview-display'], ['controlbar', 'none'])
        self.assertEqual(data['drafts']['modernz.scalewindowed']['text'], '1.3')

    def test_preview_and_save_remain_separate_in_wide_and_narrow_layout(self):
        for width, height, column in [(1100, 720, 0), (1100, 640, 0), (760, 640, 0)]:
            with self.subTest(width=width, height=height):
                data = self.run_window(width=width, height=height)
                self.assertTrue(data['layout_valid'])
                self.assertEqual(data['preview_column'], column)

    def test_percentage_slider_updates_draft_and_sends_ratio(self):
        data = self.run_window([dict(op='slide', id='sub-scale', percent=135)])
        self.assertEqual(data['editor_types']['sub-scale'], 'SettingsSlider')
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.35')
        self.assertEqual(data['scale_labels']['sub-scale'], '135%')
        self.assertEqual(data['sent'][-1][2:], ['preview', TOKEN, 'sub-scale', '1.35'])

    def test_extreme_saved_value_is_not_clamped_by_constructing_slider(self):
        initial = state()
        initial['fields'][0].update(saved=3, effective=3, has_override=True)
        data = self.run_window(initial=initial)
        self.assertEqual(data['drafts']['sub-scale']['text'], '3')
        self.assertEqual(data['dirty_pages'], [])
        self.assertEqual(data['sent'], [])
        self.assertEqual(data['scale_labels']['sub-scale'], '300%')
        changed = self.run_window([dict(op='slide', id='sub-scale', percent=150)], initial)
        self.assertEqual(changed['drafts']['sub-scale']['text'], '1.5')

    def test_slider_reset_and_undo_preserve_default_semantics(self):
        initial = state()
        initial['fields'][0].update(saved=1.3, effective=1.3, has_override=True)
        reset = self.run_window([dict(op='reset'), dict(op='save')], initial)
        self.assertEqual(reset['scale_labels']['sub-scale'], '100%')
        self.assertIsNone(json.loads(reset['sent'][-1][-1])['sub-scale'])
        undo = self.run_window([dict(op='slide', id='sub-scale', percent=170), dict(op='undo')], initial)
        self.assertEqual(undo['scale_labels']['sub-scale'], '130%')
        self.assertEqual(undo['dirty_pages'], [])

    def test_full_picture_toggle_changes_no_draft_or_preview_value(self):
        data = self.run_window([dict(op='slide', id='sub-scale', percent=125), dict(op='full-preview')])
        self.assertTrue(data['full_preview'])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.25')
        self.assertEqual(len(data['sent']), 1)

    def test_slider_keyboard_command_uses_five_percentage_point_step(self):
        data = self.run_window([dict(op='small-step', id='sub-scale')])
        self.assertEqual(data['scale_labels']['sub-scale'], '105%')
        self.assertEqual(data['sent'][-1][2:], ['preview', TOKEN, 'sub-scale', '1.05'])

    def test_previous_font_size_search_still_finds_subtitle_scale(self):
        data = self.run_window([dict(op='search', text='字号')])
        self.assertEqual(data['search_results'], ['字幕缩放 · 字幕'])

    def test_runtime_failure_remains_visible_without_per_field_descriptions(self):
        failed = state(save_serial=1, save_page='subtitles', save_ok=True)
        failed['fields'][0].update(status='apply-failed', apply_error='播放器未能应用此设置')
        data = self.run_window(initial=failed)
        self.assertIn('已保存。', data['notice'])
        self.assertIn('字幕缩放：播放器未能应用此设置', data['notice'])

    def test_slider_click_reapplies_unchanged_draft_after_media_change(self):
        data = self.run_window([dict(op='slide', id='sub-scale', percent=135),
            dict(op='state', state=state()), dict(op='slide-release', id='sub-scale')])
        self.assertEqual(data['drafts']['sub-scale']['text'], '1.35')
        self.assertEqual([c[2:] for c in data['sent']], [['preview', TOKEN, 'sub-scale', '1.35']] * 2)

    def test_slider_click_on_default_previews_without_creating_dirty_override(self):
        data = self.run_window([dict(op='slide-release', id='sub-scale')])
        self.assertEqual(data['dirty_pages'], [])
        self.assertEqual(data['sent'][-1][2:], ['preview', TOKEN, 'sub-scale', 'null'])

    def test_slider_transparent_row_receives_hits_above_and_below_track(self):
        data = self.run_window()
        hit = data['slider_hits']['sub-scale']
        self.assertEqual(hit['height'], 40)
        self.assertTrue(hit['full_row'])
        self.assertTrue(hit['grabbed'])
        self.assertAlmostEqual(hit['offset'], 5)

    def test_slider_pointer_ignores_vertical_distance_and_clamps_horizontal_edges(self):
        for x, y, expected in [(0.5, -20, '125%'), (0.5, 60, '125%'), (-0.2, 0, '50%'), (1.2, 0, '200%')]:
            with self.subTest(x=x, y=y):
                data = self.run_window([dict(op='pointer-position', id='sub-scale', x=x, y=y)])
                self.assertEqual(data['scale_labels']['sub-scale'], expected)


    def test_complete_catalog_renders_every_page_with_correct_controls(self):
        expected = {
            'subtitles': {'slang': 'Button', 'sub-visibility': 'CheckBox', 'sub-font': 'Button', 'sub-pos': 'SettingsSlider'},
            'audio': {'alang': 'Button', 'volume': 'SettingsSlider', 'mute': 'CheckBox'},
            'window': {'fullscreen': 'CheckBox', 'ontop': 'CheckBox'},
            'controlbar': {'modernz.hidetimeout': 'SettingsSlider', 'modernz.keeponpause': 'ComboBox', 'modernz.timems': 'CheckBox'},
            'decoding': {'hwdec': 'ComboBox'}, 'paths': {'capture_root': 'TextBox'}, 'shortcuts': {}, 'advanced': {}
        }
        for page, controls in expected.items():
            with self.subTest(page=page):
                data = self.run_window([dict(op='page', page=page)], complete_state(), width=760, height=640)
                self.assertEqual(data['pages'], list(expected))
                for key, kind in controls.items(): self.assertEqual(data['editor_types'][key], kind)
                self.assertEqual(data['preview_visible'], page in ('subtitles', 'controlbar'))
                self.assertTrue(data['row_alignment'])
                self.assertTrue(data['layout_valid'])

    def test_window_checkboxes_use_existing_page_save_flow(self):
        initial = complete_state()
        initial['fields'].append(dict(id='playlist.open-on-startup', page='window',
            label='启动时打开播放列表', kind='boolean', default=False, saved=False,
            has_override=False, effective=False, status='effective', apply_error='',
            timing='startup', section='', default_source='套件默认关闭'))
        initial['fields'].append(dict(id='playlist.include-images', page='window',
            label='将图片纳入播放列表', kind='boolean', default=False, saved=False,
            has_override=False, effective=False, status='effective', apply_error='',
            timing='next-task', section='', default_source='套件默认关闭'))
        initial['fields'].append(dict(id='updates.auto-check', page='window',
            label='自动检查更新', kind='boolean', default=True, saved=True,
            has_override=False, effective=True, status='effective', apply_error='',
            timing='startup', section='', default_source='套件默认开启'))
        for field in initial['fields']:
            if field['page'] == 'window': field['section'] = ''
        for width in (760, 1040):
            with self.subTest(width=width):
                data = self.run_window([dict(op='page', page='window'),
                    dict(op='choose', id='playlist.open-on-startup', index=1),
                    dict(op='choose', id='playlist.include-images', index=1),
                    dict(op='choose', id='updates.auto-check', index=2), dict(op='save')], initial, width=width)
                self.assertEqual(data['editor_types']['playlist.open-on-startup'], 'CheckBox')
                self.assertIs(json.loads(data['sent'][-1][-1])['playlist.open-on-startup'], True)
                self.assertIs(json.loads(data['sent'][-1][-1])['playlist.include-images'], True)
                self.assertIs(json.loads(data['sent'][-1][-1])['updates.auto-check'], False)
                self.assertEqual([command[2] for command in data['sent']], ['save'])
                self.assertEqual(data['section_headers'], [])
                self.assertTrue(all(data['label_content_fits'].values()), data['label_content_fits'])
                self.assertTrue(data['row_alignment'])

    def test_boolean_false_is_explicit_json_false_and_inherit_is_null(self):
        explicit = self.run_window([dict(op='page', page='window'), dict(op='choose', id='fullscreen', index=1), dict(op='choose', id='fullscreen', index=2), dict(op='save')], complete_state())
        self.assertIs(json.loads(explicit['sent'][-1][-1])['fullscreen'], False)
        self.assertTrue(explicit['drafts']['fullscreen']['overridden'])
        initial = complete_state()
        next(f for f in initial['fields'] if f['id'] == 'fullscreen').update(saved=True, effective=True, has_override=True)
        inherited = self.run_window([dict(op='inherit', id='fullscreen'), dict(op='save')], initial)
        self.assertIsNone(json.loads(inherited['sent'][-1][-1])['fullscreen'])
        self.assertEqual([c[2] for c in inherited['sent']], ['save'])

    def test_non_preview_fields_never_send_preview_and_keep_number_units(self):
        data = self.run_window([dict(op='edit', id='alang', text='ja,zh'), dict(op='edit', id='volume', text='85'), dict(op='save')], complete_state())
        self.assertEqual(data['scale_labels']['volume'], '85')
        self.assertEqual([c[2] for c in data['sent']], ['save'])
        self.assertEqual(json.loads(data['sent'][-1][-1])['volume'], 85)
        self.assertEqual(json.loads(data['sent'][-1][-1])['alang'], 'ja,zh')

    def test_position_and_timeout_keep_native_units(self):
        position = self.run_window([dict(op='slide', id='sub-pos', percent=92)], complete_state())
        self.assertEqual(position['scale_labels']['sub-pos'], '92%')
        self.assertEqual(position['sent'][-1][2:], ['preview', TOKEN, 'sub-pos', '92'])
        timeout = self.run_window([dict(op='slide', id='modernz.hidetimeout', percent=2.3)], complete_state())
        self.assertEqual(timeout['scale_labels']['modernz.hidetimeout'], '2.3 秒')
        self.assertEqual(timeout['sent'][-1][2:], ['preview', TOKEN, 'modernz.hidetimeout', '2.3'])

    def test_choice_advanced_inherited_default_is_preserved_until_explicit_selection(self):
        data = self.run_window([dict(op='page', page='decoding')], complete_state())
        self.assertEqual(data['drafts']['hwdec']['text'], 'auto-copy')
        self.assertFalse(data['drafts']['hwdec']['overridden'])
        changed = self.run_window([dict(op='choose', id='hwdec', index=2), dict(op='save')], complete_state())
        self.assertEqual(json.loads(changed['sent'][-1][-1])['hwdec'], 'no')
        self.assertEqual([c[2] for c in changed['sent']], ['save'])

    def test_empty_string_is_distinct_from_inherit(self):
        data = self.run_window([dict(op='edit', id='slang', text=''), dict(op='save')], complete_state())
        self.assertEqual(json.loads(data['sent'][-1][-1])['slang'], '')
        self.assertTrue(data['drafts']['slang']['overridden'])

    def test_search_locates_all_types_and_actions_without_losing_drafts(self):
        data = self.run_window([dict(op='edit', id='sub-font', text='Microsoft YaHei'), dict(op='search', text='硬件 解码'), dict(op='locate', index=0)], complete_state())
        self.assertEqual(data['page'], 'decoding')
        self.assertEqual(data['dirty_pages'], ['subtitles'])
        self.assertEqual(data['drafts']['sub-font']['text'], 'Microsoft YaHei')
        action = self.run_window([dict(op='search', text='input.conf'), dict(op='locate', index=0)], complete_state())
        self.assertEqual(action['page'], 'advanced')
        self.assertEqual(action['sent'], [])
        self.assertEqual(len(action['action_ids']), 4)

    def test_action_buttons_only_send_stable_action_id(self):
        for page, action in [('advanced', 'edit.mpv.conf'), ('advanced', 'open.config-folder')]:
            with self.subTest(action=action):
                data = self.run_window([dict(op='page', page=page), dict(op='action', id=action)], complete_state())
                self.assertEqual(data['sent'][-1][2:], ['open-action', TOKEN, action])
                self.assertFalse(data['can_save'])


    def test_offscreen_render_writes_actual_content_without_showing_window(self):
        data = self.run_window(initial=complete_state(), render=True)
        self.assertTrue(data['row_alignment'])
        self.assertTrue(data['layout_valid'])


    def test_startup_slider_can_explicitly_choose_inherited_number(self):
        data = self.run_window([dict(op='page', page='audio'), dict(op='slide-release', id='volume'), dict(op='save')], complete_state())
        self.assertTrue(data['drafts']['volume']['overridden'])
        self.assertEqual(json.loads(data['sent'][-1][-1])['volume'], 80)
        self.assertEqual([c[2] for c in data['sent']], ['save'])


    def test_action_failure_remains_visible_in_settings(self):
        initial = complete_state()
        initial.update(action_serial=1, action_error='无法打开此项目')
        data = self.run_window([dict(op='page', page='advanced')], initial)
        self.assertIn('无法打开此项目', data['notice'])


    def test_regular_string_limits_match_utf8_bytes_and_ascii_controls(self):
        data = self.run_window([dict(op='edit', id='slang', text='中' * 171),
            dict(op='edit', id='alang', text='zh\tja'), dict(op='edit', id='sub-font', text='font\x7f'), dict(op='save')], complete_state())
        for key in ['slang', 'alang', 'sub-font']:
            self.assertFalse(data['valid_fields'][key])
        self.assertFalse(data['can_save'])
        self.assertEqual(data['sent'], [])
        self.assertIn('512 字节', data['notice'])

    def test_language_and_font_are_selection_controls_not_raw_input(self):
        subtitles = self.run_window(initial=complete_state())
        self.assertEqual(subtitles['editor_types']['slang'], 'Button')
        self.assertEqual(subtitles['editor_types']['sub-font'], 'Button')
        self.assertEqual(subtitles['editor_types']['sub-visibility'], 'CheckBox')
        self.assertNotIn('填写', subtitles['field_details']['slang'])
        self.assertNotIn('填写', subtitles['field_details']['sub-font'])

    def test_unrelated_json_revision_preserves_and_rebases_unchanged_page(self):
        changed = complete_state()
        changed['revision'] = 'r2'
        data = self.run_window([dict(op='edit', id='sub-scale', text='1.2'),
            dict(op='state', state=changed), dict(op='save')], complete_state())
        self.assertEqual(data['sent'][-1][3:6], [TOKEN, 'r2', 'subtitles'])
        self.assertEqual(json.loads(data['sent'][-1][-1])['sub-scale'], 1.2)

    def test_global_search_has_visible_text_viewport_and_replaces_content(self):
        data = self.run_window([dict(op='search', text='音轨')], complete_state())
        self.assertGreaterEqual(data['search_viewport_height'], 18)
        self.assertFalse(data['ordinary_content_visible'])
        self.assertFalse(data['embedded_shortcuts_visible'])

    def test_font_picker_is_in_window_and_searchable(self):
        data = self.run_window([dict(op='font-picker'), dict(op='picker-query', text='Segoe UI')], complete_state())
        self.assertTrue(data['overlay_open'])
        self.assertFalse(data['body_enabled'])
        self.assertTrue(any('Segoe UI' in name for name in data['picker_items']))
        self.assertNotIn('Arial', data['picker_items'])
        self.assertEqual(data['dirty_pages'], [])

    def test_language_buttons_reorder_without_exposing_codes_or_losing_unknowns(self):
        initial = complete_state()
        field = next(f for f in initial['fields'] if f['id'] == 'slang')
        field.update(saved='zh,zho,chi,ja,jpn,x-custom', effective='zh,zho,chi,ja,jpn,x-custom',has_override=True)
        data = self.run_window([dict(op='invoke-control',name='上移日语')], initial)
        self.assertEqual(data['drafts']['slang']['text'], 'ja,jpn,zh,zho,chi,x-custom')
        self.assertEqual(data['dirty_pages'], ['subtitles'])

    def test_embedded_shortcuts_replace_launch_button_and_are_searchable_globally(self):
        from test_settings_shortcuts import state as shortcut_state
        data = self.run_window([dict(op='shortcuts-state',state=shortcut_state()),dict(op='page',page='shortcuts')], complete_state())
        self.assertTrue(data['embedded_shortcuts_visible'])
        self.assertNotIn('shortcuts.open',data['action_ids'])
        found = self.run_window([dict(op='shortcuts-state',state=shortcut_state()),dict(op='search',text='静音')], complete_state())
        self.assertTrue(any('快捷键 / 音频' in item for item in found['search_results']))
