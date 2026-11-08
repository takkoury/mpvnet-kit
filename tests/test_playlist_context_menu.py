"""Exercise the production WinForms context menu without displaying a popup."""
import json
import os
from pathlib import Path
import unittest
import uuid

from support.install_fixtures import create_fixture_root, powershell_path, run_recorded

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Playlist context menu requires Windows WinForms')
class PlaylistContextMenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        configured = os.environ.get('MPVNET_TEST_PLAYLIST_ARTIFACTS')
        if not configured:
            raise unittest.SkipTest('Set MPVNET_TEST_PLAYLIST_ARTIFACTS to an external artifact directory')
        cls.output = create_fixture_root(Path(configured) / ('menu-probe-' + uuid.uuid4().hex[:10]), ROOT)
        result = run_recorded([str(powershell_path()), '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', str(ROOT / 'tests/fixtures/playlist_context_menu_probe.ps1'),
            '-SourceDirectory', str(ROOT / 'config/helpers'), '-PaintPath', str(cls.output / 'row-menu.png')],
            cls.output / 'probe', timeout=30)
        if result.returncode:
            raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
        cls.data = json.loads(result.stdout.decode('utf-8-sig'))
        (cls.output / 'result.json').write_text(json.dumps(cls.data, ensure_ascii=False, indent=2), encoding='utf-8')

    def test_menu_contains_accepted_actions_in_the_expected_groups(self):
        self.assertEqual(len(self.data['commands']), 17)
        self.assertEqual(self.data['groups'], ['打开', '追加', '播放顺序'])

    def test_hidden_prepare_and_execute_respect_row_identity_and_queue_state(self):
        self.assertTrue(self.data['state_and_target'])
        self.assertEqual(self.data['global_events'], 15)
        self.assertEqual(self.data['prepared'], 5)

    def test_hints_and_real_menu_input_handoff_preserve_local_shortcuts(self):
        self.assertTrue(self.data['hints'])
        self.assertTrue(self.data['input_handoff'])

    def test_menu_paints_offscreen_without_showing_a_window(self):
        self.assertTrue(self.data['style_geometry'])
        self.assertFalse(self.data['shown'])
        self.assertTrue(Path(self.data['paint_path']).is_file())
        self.assertTrue(all(value > 0 for value in self.data['paint_size']))


if __name__ == '__main__':
    unittest.main()
