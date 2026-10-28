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
    for key, page, label in [('sub-scale', 'subtitles', '字幕字号'),
                             ('modernz.scalewindowed', 'controlbar', '窗口控制栏缩放')]:
        fields.append(dict(id=key, page=page, label=label, default=1, saved=1,
                           has_override=False, effective=1, status='effective',
                           apply_error='', min=0.05, max=100, default_source='启动配置'))
    for key, label in [('capture_root', '截图与片段目录'), ('ffmpeg_path', 'FFmpeg 路径'),
                       ('python_path', 'Python 路径'), ('mpv_path', '缩略图播放器路径')]:
        fields.append(dict(id=key, page='paths', label=label, default='', saved='',
                           has_override=False, effective='', status='effective', apply_error=''))
    result = dict(schema=1, editor_token=TOKEN, revision='r1', paths_revision='p1',
                  error='', paths_error='', saving=False, save_serial=0, save_page='',
                  save_ok=False, save_error='', preview_error='', fields=fields)
    result.update(changes)
    return result


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF')
class SettingsWindow(unittest.TestCase):
    def run_window(self, steps=(), initial=None):
        with tempfile.TemporaryDirectory(prefix='mpvnet-settings-window-') as temp:
            request = Path(temp) / 'request.json'
            request.write_text(json.dumps(dict(schema=1, token=TOKEN, script='user_settings',
                parent_pid=os.getpid(), pipe='fixture-unused', validation_state=initial or state(),
                validation_steps=list(steps)), ensure_ascii=False), encoding='utf-8')
            result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', str(ROOT / 'config/helpers/settings-window.ps1'), '-RequestPath', str(request),
                '-ValidateOnly', '-NoShow'], capture_output=True, timeout=30)
            self.assertEqual(result.stderr, b'', result.stderr.decode('utf-8', errors='replace'))
            data = json.loads(result.stdout.decode('utf-8-sig'))
            self.assertEqual(result.returncode, 0, data)
            self.assertTrue(data['ok'])
            self.assertFalse(data['shown'])
            return data

    def test_native_controls_initial_state(self):
        data = self.run_window()
        self.assertEqual(data['dirty_pages'], [])
        self.assertFalse(data['can_save'])
        self.assertEqual(len(data['drafts']), 6)

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
        data = self.run_window([dict(op='edit', id='capture_root', text='C:\\Capture'), dict(op='save')])
        self.assertEqual(data['sent'][-1][4:6], ['p1', 'paths'])
        self.assertEqual(json.loads(data['sent'][-1][-1])['capture_root'], 'C:\\Capture')

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
