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


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF')
class SettingsWindow(unittest.TestCase):
    def run_window(self, steps=(), initial=None, width=1100, height=720):
        with tempfile.TemporaryDirectory(prefix='mpvnet-settings-window-') as temp:
            request = Path(temp) / 'request.json'
            request.write_text(json.dumps(dict(schema=1, token=TOKEN, script='user_settings',
                parent_pid=os.getpid(), pipe='fixture-unused', validation_state=initial or state(),
                validation_steps=list(steps), validation_width=width, validation_height=height), ensure_ascii=False), encoding='utf-8')
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
        for width, height, column in [(1100, 720, 1), (1100, 640, 1), (760, 640, 0)]:
            with self.subTest(width=width, height=height):
                data = self.run_window(width=width, height=height)
                self.assertTrue(data['layout_valid'])
                self.assertEqual(data['preview_column'], column)

    def test_percentage_slider_updates_draft_and_sends_ratio(self):
        data = self.run_window([dict(op='slide', id='sub-scale', percent=135)])
        self.assertEqual(data['editor_types']['sub-scale'], 'Slider')
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
