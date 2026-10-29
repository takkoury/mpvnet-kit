"""Compile the actual helper's C# and run physical-pixel geometry fixtures."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid

from support.install_fixtures import (create_fixture_root, powershell_path, run_recorded)

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Playlist uses the existing Windows PowerShell/WinForms runtime')
class PlaylistWindow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Explicit output root keeps probes away from user configuration and media.
        configured = os.environ.get('MPVNET_TEST_PLAYLIST_ARTIFACTS')
        if not configured:
            raise unittest.SkipTest('Set MPVNET_TEST_PLAYLIST_ARTIFACTS to a unique external artifact directory')
        cls.ps = powershell_path()
        cls.output = create_fixture_root(configured, ROOT, mode='unique')
        cls.helper = ROOT / 'config/helpers/playlist-window.ps1'

    def run_fixture(self, name):
        result = run_recorded([str(self.ps), '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                               '-File', str(ROOT / 'tests/fixtures' / name),
                               '-SourcePath', str(self.helper)], self.output / name, timeout=30, append_suffix=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return json.loads(result.stdout.decode('utf-8-sig'))

    def test_dynamic_shortcuts_use_shared_key_names_and_release_changed_keys(self):
        data = self.run_fixture('playlist_shortcuts.ps1')
        self.assertTrue(data['map_replace'] and data['unchanged_hold'] and data['empty_map'])
        self.assertEqual(data['key_cases'], 7)
        self.assertTrue(data['local_keys_preserved'])

    def test_actual_csharp_geometry(self):
        data = self.run_fixture('playlist_geometry.ps1')
        self.assertEqual(data['cases'], 10)
        self.assertTrue(data['fallback'])
        self.assertEqual(data['native_hits'], 3)
        self.assertTrue(data['activation_no_system_paint'])

    def test_hover_waits_expires_tracks_pointer_and_cancels_on_native_scroll(self):
        data = self.run_fixture('playlist_hover.ps1')
        self.assertTrue(all(data.values()), data)

    @unittest.skipUnless(os.environ.get('MPVNET_TEST_PLAYLIST_WINDOWS') == '1',
                         'Enable MPVNET_TEST_PLAYLIST_WINDOWS=1 for owned, briefly visible test windows')
    def test_owned_window_visible_edges(self):
        data = self.run_fixture('playlist_window_probe.ps1')
        self.assertEqual(len(data['frames']), 4)
        for frame in data['frames']:
            self.assertEqual(frame['top_gap'], 0, frame)
            self.assertEqual(frame['bottom_gap'], 0, frame)
            self.assertEqual(frame['edge_gap'], 0, frame)
            self.assertEqual(frame['remembered_width'], 340, frame)
            self.assertEqual(frame['follower_parent'], frame['expected_parent'], frame)
            self.assertTrue(frame['side_shown'], frame)
        # Explicit maximize/fullscreen setup can activate the owned parent.
        # Sample the side window's actual show/follow phases, before cleanup.
        self.assertTrue(data['first_show_focus_preserved'], data)
        self.assertTrue(data['side_never_foreground'], data)

    def run_helper(self, values):
        payload = self.output / ('mpvnet-playlist-%d-%d.json' % (os.getpid(), uuid.uuid4().int))
        payload.write_text(json.dumps(dict({'token': '123-456', 'script': 'playlist_controls',
                                           'visible': False}, **values)), encoding='utf-8')
        environment = dict(os.environ, TEMP=str(self.output), TMP=str(self.output))
        prefix = self.output / (self._testMethodName + '-' + uuid.uuid4().hex[:6])
        result = run_recorded([str(self.ps), '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                               '-File', str(self.helper), '-ValidateOnly', '-PayloadPath', str(payload)],
                              prefix, env=environment, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return json.loads(result.stdout.decode('utf-8-sig'))

    def test_full_helper_validate_only(self):
        data = self.run_helper({'playlist': [{'id': 71, 'filename': 'X:/fixture/one.mkv'}], 'position': 0})
        self.assertTrue(data['ok'])
        self.assertFalse(data['shown'])
        self.assertTrue(data['caption_empty'])
        self.assertTrue(data['no_minmax'])
        self.assertEqual(data['rows'][0]['id'], '71')
        self.assertTrue(data['footer_bounds_stable'], data['layout_bounds'])
        self.assertEqual(data['layout_bounds']['normal'], data['layout_bounds']['search'])
        self.assertEqual(data['layout_bounds']['normal'], data['layout_bounds']['restored'])

    def test_locate_reveals_current_id_and_clears_search(self):
        entries = [{'id': 100 + i, 'filename': 'X:/fixture/item-%02d.mkv' % i} for i in range(60)]
        # Selection follows the returned ID even when the cached position differs.
        data = self.run_helper({'playlist': entries, 'position': 0, 'filter': 'item-00',
                                'selected_id': '100', 'click_counter': True, 'locate_id': '154'})
        self.assertEqual([row['id'] for row in data['rows']], ['100'])
        self.assertEqual(data['locate']['selected_ids'], ['154'])
        self.assertEqual(data['locate']['focused_id'], '154')
        self.assertTrue(data['locate']['selected_visible'], data['locate'])
        self.assertGreater(data['locate']['top_index'], 0)
        self.assertFalse(data['locate']['searching'])
        self.assertEqual(data['locate']['filter'], '')
        self.assertTrue(data['locate']['focus_preserved'])
        self.assertEqual(data['locate']['counter_name'], '定位当前播放项')
        self.assertTrue(data['locate']['counter_hand'])
        self.assertEqual([action['action'] for action in data['actions']], ['locate'])
        self.assertEqual(data['actions'][0]['id'], '')

    def test_locate_empty_and_stale_ids_do_not_change_view(self):
        for values in ({'playlist': [], 'position': -1, 'locate_id': '', 'click_counter': True},
                       {'playlist': [{'id': 71, 'filename': 'X:/fixture/one.mkv'}],
                        'position': -1, 'filter': 'one', 'selected_id': '71',
                        'locate_id': 'removed', 'click_counter': True},
                       {'playlist': [{'id': 71, 'filename': 'X:/fixture/one.mkv'}],
                        'position': 0, 'filter': 'one', 'selected_id': '71', 'locate_id': 'removed'}):
            with self.subTest(values=values):
                data = self.run_helper(values)
                self.assertEqual(data['locate']['counter_enabled'], values['position'] >= 0)
                self.assertEqual(data['actions'], [])
                self.assertTrue(data['locate']['focus_preserved'])
                if values['playlist']:
                    self.assertEqual(data['locate']['selected_ids'], ['71'])
                    self.assertTrue(data['locate']['searching'])
                    self.assertEqual(data['locate']['filter'], 'one')

    def test_custom_caption_preserves_frame_layout_and_close_to_hide(self):
        for width in (220, 340):
            with self.subTest(width=width):
                data = self.run_helper({'playlist': [], 'position': -1,
                                        'client_width': width, 'click_close': True})
                view = data['presentation']
                self.assertFalse(view['native_caption'])
                self.assertTrue(view['sizing_frame'])
                self.assertTrue(view['title_above_list'])
                self.assertTrue(view['close_hides'])
                self.assertEqual(view['title'], '播放列表')
                self.assertEqual(view['close_name'], '关闭播放列表')
                self.assertEqual(data['actions'], [])
                self.assertTrue(data['footer_bounds_stable'])

    def test_empty_and_filtered_states_are_distinct(self):
        for entries, query, expected in (([], '', '播放列表为空'),
                ([{'id': 1, 'filename': 'X:/视频.mkv'}], 'missing', '没有匹配的项目')):
            with self.subTest(query=query):
                data = self.run_helper({'playlist': entries, 'position': -1, 'filter': query,
                    'paint_path': str(self.output / ('empty-' + uuid.uuid4().hex + '.png'))})
                self.assertEqual(data['presentation']['empty_text'], expected)
                self.assertTrue(data['painted'])
                self.assertEqual(data['actions'], [])

    def test_visible_search_button_toggles_existing_filter_and_counter_is_compact(self):
        entries = [{'id': 1, 'filename': 'X:/one.mkv'}, {'id': 2, 'filename': 'X:/two.mkv'}]
        data = self.run_helper({'playlist': entries, 'position': 0, 'search_probe': True})
        view = data['presentation']
        self.assertTrue(view['search_not_overlapping'])
        self.assertTrue(view['search_in_footer'])
        self.assertEqual(view['search_name'], '搜索播放列表（Ctrl+F）')
        self.assertEqual(view['search_toggle'], {'opened': True, 'closed': True, 'filtered': 1, 'rows_restored': 2, 'controls_separate': True})
        self.assertLess(view['counter_width'], view['footer_width'] / 2)
        self.assertEqual(data['actions'], [])

    def test_rendered_current_selected_hover_and_normal_are_distinct(self):
        entries = [{'id': i, 'filename': 'X:/测试 %d 长标题.mkv' % i} for i in range(1, 6)]
        data = self.run_helper({'playlist': entries, 'position': 0, 'selected_id': '2',
            'hover_id': '3', 'paint_path': str(self.output / 'states.png')})
        self.assertTrue(data['painted'])
        colors = data['presentation']['row_backgrounds']
        # Selection is the approved thin outline, not a second grey fill.
        self.assertEqual(colors['2'], colors['4'])
        self.assertEqual(len({colors[str(i)] for i in range(1, 5)}), 3, colors)
        outlines = data['presentation']['row_outlines']
        self.assertNotEqual(outlines['2'], outlines['4'])
        self.assertTrue(data['presentation']['current_bold'])
        self.assertEqual(data['presentation']['row_columns'], 2)
        self.assertEqual([row['number'] for row in data['rows']], ['01', '02', '03', '04', '05'])
        self.assertEqual(data['actions'], [])

    def test_narrow_search_footer_keeps_search_button_to_the_right(self):
        data = self.run_helper({'playlist': [{'id': 1, 'filename': 'X:/one.mkv'}],
            'position': 0, 'filter': 'one', 'client_width': 220,
            'paint_path': str(self.output / 'search.png')})
        view = data['presentation']
        self.assertTrue(view['search_in_footer'])
        self.assertTrue(view['search_controls_separate'])
        self.assertGreater(view['search_field_width'], 36)
        self.assertTrue(data['footer_bounds_stable'])
        self.assertEqual(data['actions'], [])

    def test_filtered_number_keeps_original_queue_position(self):
        data = self.run_helper({'playlist': [{'id': 71, 'filename': 'X:/one.mkv'},
                                            {'id': 93, 'filename': 'X:/two.mkv'}],
                                'position': 0, 'filter': 'two'})
        self.assertEqual(data['rows'][0]['number'], '02')
        self.assertEqual(data['rows'][0]['id'], '93')

    def test_counter_hover_has_rounded_corners(self):
        data = self.run_helper({'playlist': [{'id': 1, 'filename': 'X:/one.mkv'}],
                                'position': 0, 'counter_hover': True})
        pixels = data['presentation']['counter_hover']
        self.assertEqual(pixels['corner'], pixels['background'])
        self.assertNotEqual(pixels['edge'], pixels['background'])


if __name__ == '__main__':
    unittest.main()
