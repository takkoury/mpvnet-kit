"""Compile actual installer presentation; hidden controls, no maintenance writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WinForms')
class InstallerUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix='mpvnet-installer-ui-') as temp:
            result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', str(ROOT/'tests/fixtures/installer_ui_probe.ps1'), '-SourcePath', str(ROOT/'tools/installer-ui.cs'),
                '-OutputPath', str(Path(temp)/'confirmation.png')], capture_output=True, timeout=30)
            if result.returncode:
                raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
            cls.data = json.loads(result.stdout.decode('utf-8-sig'))

    def test_custom_frame_keeps_installer_window_capabilities(self):
        for item in self.data['frames']:
            self.assertFalse(item['shown'])
            self.assertTrue(item['taskbar'] and item['minimize'] and item['maximize'])
            self.assertEqual(item['system_paint'], 0)
            self.assertGreater(item['content_top'], 0)

    def test_confirmation_preserves_text_default_cancel_and_buttons(self):
        for item in self.data['dialogs']:
            self.assertFalse(item['shown'] or item['minmax'])
            for key in ('text_preserved', 'default_cancel', 'within_screen', 'buttons_visible', 'separate'):
                self.assertTrue(item[key], item)
            self.assertEqual(item['scrolling'], 'Vertical')

    def test_actual_confirmation_buttons_choose_cancel_or_apply(self):
        self.assertEqual(self.data['choices'], ['Cancel', 'OK'])

    def test_details_toggle_preserves_complete_content_controls_and_selection(self):
        self.assertEqual([item['scale'] for item in self.data['detail_dialogs']], [1, 1.5, 2])
        for item in self.data['detail_dialogs']:
            with self.subTest(scale=item['scale']):
                self.assertFalse(item['shown'])
                for key in ('initially_collapsed', 'expanded', 'collapsed_again', 'summary_preserved',
                            'details_preserved', 'expanded_content_preserved', 'textboxes_preserved',
                            'selection_preserved', 'details_subtle'):
                    self.assertTrue(item[key], item)
                self.assertEqual(item['dialog_result'], 'None')

    def test_details_confirmation_keeps_cancel_default_actions_right_and_restores_height(self):
        for item in self.data['detail_dialogs']:
            with self.subTest(scale=item['scale']):
                initial, expanded, collapsed = item['heights']
                self.assertGreater(expanded, initial, item)
                self.assertEqual(collapsed, initial, item)
                for key in ('details_fit', 'actions_fit', 'default_cancel', 'within_screen'):
                    self.assertTrue(item[key], item)

    def test_scroll_end_shows_whole_last_line_and_preserves_selection(self):
        for item in self.data['scroll']:
            self.assertTrue(item['complete'] and item['selection'], item)

    def test_mouse_and_timer_messages_do_not_rewrite_edit_margins(self):
        for item in self.data['idle']:
            self.assertEqual(item['margin_writes'], 0, item)
            self.assertTrue(item['selection'], item)

    def test_failure_summary_localizes_diagnostics_with_chinese_paths(self):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', str(ROOT/'tests/fixtures/installer_failure_cases.ps1'), '-SourceRoot', str(ROOT)],
            capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        data = json.loads(result.stdout.decode('utf-8-sig'))
        for item in data['cases']:
            self.assertFalse(item['shown'])
            self.assertEqual(item['state'], 'blocked')
            self.assertTrue(item['reason'].startswith(('配置包未通过', '安装记录或备份', '无法完成检查', '配置目录不可访问', '配置目录、配置包')), item)
            self.assertNotIn('checksum', item['summary'])
            self.assertIn(item['reason'], item['details'])
            self.assertIn(item['input'], item['details'])
        self.assertEqual(data['cases'][0]['reason'], data['cases'][2]['reason'])
        self.assertEqual(data['cases'][0]['reason'], data['cases'][3]['reason'])
        self.assertEqual(data['cases'][0]['reason'], data['cases'][4]['reason'])
        self.assertEqual(data['cases'][-1]['input'], data['cases'][-1]['reason'])
        self.assertNotIn('checksum', data['output']['Text'])
        self.assertIn('技术详情', data['output']['Details'])
        self.assertIn('Package checksum mismatch', data['output']['Details'])
        self.assertEqual(json.loads(data['output']['Json'])['error'], data['cases'][0]['input'])
