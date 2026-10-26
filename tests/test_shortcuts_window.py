"""Construct real WPF controls without showing windows or connecting to a player."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'config/helpers/shortcuts-window.ps1'
TOKEN = 'owned-fixture-token'
GROUPS = ['播放与定位', '循环与标记', '字幕与弹幕', '音频', '画面', '截图与片段', '窗口与界面', '文件', '工具与设置']


def state(revision='revision-one', **changes):
    value = {'schema': 1, 'revision': revision, 'editor_token': TOKEN, 'editor_visible': True,
             'forward_keys': [], 'opening_keys': ['Ctrl+k'], 'error': '', 'save_error': '',
             'saving': False, 'save_serial': 0,
             'actions': [{'id': 'pause', 'group': '播放与定位', 'label': '播放 / 暂停', 'command': 'cycle pause',
                          'default_keys': ['Space'], 'keys': ['p'], 'focus_main': True},
                         {'id': 'mute', 'group': '音频', 'label': '静音', 'command': 'cycle mute',
                          'default_keys': ['m'], 'keys': ['m'], 'focus_main': False}]}
    value.update(changes)
    return value


def repairable_state():
    value = state(error='快捷键存在重复分配', repairable=True)
    value['actions'].append({'id': 'info', 'group': '工具与设置', 'label': '媒体信息', 'command': 'show-text info',
                             'default_keys': ['i'], 'keys': ['i'], 'focus_main': False})
    value['editable_actions'] = [dict(row, keys=keys) for row, keys in zip(value['actions'], [['m'], ['m'], ['t']])]
    return value


def full_catalog(count=194):
    value = state()
    value['actions'] = [{'id': 'fixture.' + str(index), 'group': GROUPS[index % len(GROUPS)],
                         'label': '目录动作 ' + str(index), 'command': 'ignore',
                         'default_keys': ['Space'] if index == 0 else [],
                         'keys': ['Space'] if index == 0 else ['m'] if index == 1 else [],
                         'focus_main': False} for index in range(count)]
    return value


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/WPF runtime')
class ShortcutsWindow(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mpvnet-shortcuts-test-')
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)

    def run_helper(self, steps=None, initial=None, **changes):
        request = {'schema': 1, 'pipe': 'fixture-no-connection', 'parent_pid': os.getpid(),
                   'script': 'user_shortcuts', 'token': TOKEN,
                   'settings_path': str(self.folder / 'mpvnet-user.json'),
                   'validation_state': state() if initial is None else initial,
                   'validation_steps': steps or []}
        request.update(changes)
        path = self.folder / ('request-' + uuid.uuid4().hex + '.json')
        path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        completed = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                                    '-File', str(HELPER), '-Operation', 'Editor', '-RequestPath', str(path),
                                    '-ValidateOnly', '-NoShow'], capture_output=True, timeout=30)
        self.assertEqual(completed.stderr, b'', completed.stderr.decode('utf-8', errors='replace'))
        result = json.loads(completed.stdout.decode('utf-8-sig'))
        self.assertEqual(completed.returncode, 0, result)
        self.assertTrue(result['ok'])
        self.assertFalse(result['shown'])
        return result

    def test_real_controls_labels_bounds_and_disabled_save(self):
        data = self.run_helper()
        self.assertTrue(data['bounds_valid'], data['bounds'])
        self.assertEqual(len(data['rows']), 2)
        self.assertFalse(data['dirty'])
        self.assertFalse(data['can_save'])
        self.assertEqual(data['tab_navigation'], 'Continue')
        for label in ['快捷键', '全部功能', '已绑定', '未绑定', '已修改', '恢复此项', '恢复全部默认键位', '撤销未保存更改', '保存并应用']:
            self.assertIn(label, data['labels'])

    def test_small_and_large_logical_layout_bounds(self):
        for width, height in [(728, 492), (1000, 800)]:
            with self.subTest(width=width, height=height):
                data = self.run_helper(validation_width=width, validation_height=height)
                self.assertTrue(data['bounds_valid'], data['bounds'])

    def test_complete_catalog_counts_and_four_filters_include_unbound_actions(self):
        initial = full_catalog()
        data = self.run_helper(initial=initial)
        self.assertEqual(data['visible_rows'], 194)
        self.assertEqual(data['categories']['all'], 194)
        self.assertEqual(sum(data['categories'][group] for group in GROUPS), 194)
        self.assertEqual(len(data['categories']), 10)
        self.assertEqual(data['modified_count'], 1)
        self.assertFalse(data['dirty'])
        for filter_name, expected in [('bound', 2), ('unbound', 192), ('modified', 1), ('all', 194)]:
            data = self.run_helper([{'action': 'filter', 'value': filter_name}], initial=initial)
            self.assertEqual(data['visible_rows'], expected)
            self.assertEqual(data['filter'], filter_name)
            self.assertEqual(data['categories']['all'], 194)
        larger = full_catalog(196)
        larger['revision'] = 'revision-two'
        data = self.run_helper([{'action': 'state', 'state': larger}], initial=initial)
        self.assertEqual(data['visible_rows'], 196)
        self.assertEqual(data['categories']['all'], 196)

    def test_modified_filter_and_dirty_count_have_separate_baselines(self):
        data = self.run_helper([{'action': 'filter', 'value': 'modified'}])
        self.assertEqual(data['visible_order'], ['pause'])
        self.assertEqual(data['modified_count'], 1)
        self.assertEqual(data['dirty_count'], 0)
        data = self.run_helper([{'action': 'click', 'id': 'Key_mute_0'}, {'action': 'virtual-key', 'vk': 88}])
        self.assertEqual(data['modified_count'], 2)
        self.assertEqual(data['dirty_count'], 1)
        self.assertEqual(data['save_label'], '保存 1 项')
        data = self.run_helper([{'action': 'click', 'id': 'Key_mute_0'}, {'action': 'virtual-key', 'vk': 88},
                                {'action': 'undo'}, {'action': 'filter', 'value': 'modified'}])
        self.assertEqual(data['modified_count'], 1)
        self.assertEqual(data['dirty_count'], 0)
        self.assertEqual(data['visible_order'], ['pause'])
        self.assertEqual(data['rows'][0]['keys'], ['p'])

    def test_inline_capture_second_key_removal_restore_and_local_escape(self):
        steps = [{'action': 'click', 'id': 'Key_pause_0'}, {'action': 'virtual-key', 'vk': 74},
                 {'action': 'click', 'id': 'Key_pause_1'}, {'action': 'virtual-key', 'vk': 75}]
        data = self.run_helper(steps)
        self.assertTrue(all(item['invoked'] for item in data['clicks']))
        self.assertEqual(data['rows'][0]['keys'], ['j', 'k'])
        self.assertEqual(data['focus_id'], 'Key_pause_1')
        data = self.run_helper(steps + [{'action': 'click', 'id': 'Remove_pause_1'}])
        self.assertEqual(data['rows'][0]['keys'], ['j'])
        self.assertTrue(data['clicks'][-1]['invoked'])
        data = self.run_helper(steps + [{'action': 'click', 'id': 'Key_pause_0'}, {'action': 'virtual-key', 'vk': 27}])
        self.assertEqual(data['rows'][0]['keys'], ['j', 'k'])
        self.assertEqual(data['capture_id'], '')
        self.assertEqual(data['commands'], [])
        data = self.run_helper(steps + [{'action': 'click', 'id': 'Reset_pause'}])
        self.assertEqual(data['rows'][0]['keys'], ['Space'])

    def test_view_changes_cancel_capture_and_do_not_change_hidden_actions(self):
        for change, focus in [({'action': 'search', 'value': '静音'}, 'Search'),
                              ({'action': 'category', 'value': '音频'}, 'Category音频'),
                              ({'action': 'filter', 'value': 'unbound'}, 'Filterunbound')]:
            with self.subTest(change=change):
                data = self.run_helper([{'action': 'click', 'id': 'Key_pause_0'}, change,
                                        {'action': 'virtual-key', 'vk': 74}])
                self.assertEqual(data['capture_id'], '')
                self.assertEqual(data['rows'][0]['keys'], ['p'])
                self.assertEqual(data['focus_id'], focus)
        data = self.run_helper([{'action': 'click', 'id': 'Key_pause_0'},
                                {'action': 'state', 'state': state('revision-two')},
                                {'action': 'virtual-key', 'vk': 74}])
        self.assertEqual(data['capture_id'], '')
        self.assertEqual(data['rows'][0]['keys'], ['p'])
        self.assertEqual(data['focus_id'], 'Search')

    def test_search_focus_without_text_change_cancels_capture(self):
        data = self.run_helper([{'action': 'click', 'id': 'Key_pause_0'},
                                {'action': 'focus-search'}, {'action': 'virtual-key', 'vk': 65}])
        self.assertTrue(data['clicks'][0]['invoked'])
        self.assertEqual(data['capture_id'], '')
        self.assertEqual(data['focus_id'], 'Search')
        self.assertEqual(data['rows'][0]['keys'], ['p'])
        self.assertFalse(data['dirty'])

    def test_reset_all_confirmation_cancellation_keeps_draft(self):
        data = self.run_helper([{'action': 'restore-all', 'confirm': False}])
        self.assertEqual(data['reset_confirmations'], 1)
        self.assertEqual(data['rows'][0]['keys'], ['p'])
        self.assertFalse(data['dirty'])
        data = self.run_helper([{'action': 'restore-all', 'confirm': True}])
        self.assertEqual(data['reset_confirmations'], 1)
        self.assertEqual(data['rows'][0]['keys'], ['Space'])
        self.assertTrue(data['dirty'])
        self.assertEqual(data['commands'], [])

    def test_no_results_and_clear_search_use_real_controls(self):
        data = self.run_helper([{'action': 'search', 'value': 'not-present-anywhere'}])
        self.assertTrue(data['empty_visible'])
        self.assertEqual(data['visible_rows'], 0)
        data = self.run_helper([{'action': 'search', 'value': 'not-present-anywhere'},
                                {'action': 'click', 'id': 'ClearSearch'}])
        self.assertFalse(data['empty_visible'])
        self.assertEqual(data['visible_rows'], 2)
        self.assertEqual(data['focus_id'], 'Search')

    def test_small_layout_long_name_two_long_keys_and_full_tooltips(self):
        initial = state()
        initial['actions'] = [dict(initial['actions'][0], label='很长的功能名称' * 30,
                                   keys=['Ctrl+Alt+Shift+a', 'Ctrl+Alt+Shift+b'])]
        data = self.run_helper([{'action': 'click', 'id': 'Detail_pause'}], initial=initial,
                               validation_width=728, validation_height=492)
        self.assertTrue(data['bounds_valid'], data['bounds'])
        self.assertTrue(data['row_controls_fit'])
        label = next(control for control in data['controls'] if control['id'] == 'Detail_pause')
        self.assertEqual(label['tooltip'], initial['actions'][0]['label'])
        self.assertEqual(data['font'], 'Microsoft YaHei UI')
        self.assertEqual(data['window_size'], {'width': 960, 'height': 680, 'min_width': 760, 'min_height': 540})

    def test_default_keycaps_use_display_names_and_hide_redundant_restore(self):
        initial = state()
        initial['actions'][0]['keys'] = ['Space']
        data = self.run_helper([{'action': 'click', 'id': 'Detail_pause'}], initial=initial)
        self.assertEqual(data['default_keycaps'], [{'id': 'pause', 'texts': ['空格']}])
        controls = {control['id']: control for control in data['controls']}
        self.assertEqual(controls['Key_pause_0']['text'], '空格')
        self.assertNotIn('Reset_pause', controls)
        self.assertIn('Remove_pause_0', controls)
        initial['actions'][0]['keys'] = ['p']
        data = self.run_helper([{'action': 'search', 'value': '空格'}, {'action': 'click', 'id': 'Detail_pause'}], initial=initial)
        self.assertEqual(data['visible_order'], ['pause'])
        self.assertIn('Reset_pause', {control['id'] for control in data['controls']})

    def test_recording_hint_does_not_add_a_detail_row(self):
        initial = state()
        initial['actions'][0]['keys'] = ['Space']
        plain = self.run_helper([{'action': 'click', 'id': 'Detail_pause'}], initial=initial)
        capture = self.run_helper([{'action': 'capture', 'id': 'pause', 'index': 1}], initial=initial)
        self.assertEqual(plain['recording_hints'], [])
        self.assertEqual(capture['recording_hints'][0]['text'], 'Esc 取消')
        self.assertEqual(capture['capture_id'], 'pause')
        self.assertAlmostEqual(plain['row_heights']['pause'], capture['row_heights']['pause'], delta=1)
        self.assertTrue(capture['row_controls_fit'])

    def test_keycaps_center_at_29_dip_and_unbound_uses_subtle_ghost(self):
        initial = state()
        initial['actions'][0]['keys'] = ['j', 'F6']
        initial['actions'].append({'id': 'empty', 'group': '播放与定位', 'label': '尚未绑定的动作',
                                   'command': 'ignore', 'default_keys': [], 'keys': [], 'focus_main': False})
        data = self.run_helper(initial=initial)
        controls = {control['id']: control for control in data['controls']}
        for control_id in ['Key_pause_0', 'Key_pause_1', 'Key_empty_0']:
            control = controls[control_id]
            self.assertEqual(control['vertical_alignment'], 'Center')
            self.assertGreaterEqual(control['height'], 29)
            self.assertLessEqual(control['height'], 30)
        self.assertEqual(controls['Key_pause_0']['background'], '#FF25282D')
        empty = controls['Key_empty_0']
        self.assertEqual(empty['text'], '+ 录入')
        self.assertIn(empty['background'], ['#00FFFFFF', '#00000000'])
        self.assertEqual(empty['border'], '#FF383D44')
        self.assertEqual(empty['foreground'], '#FF92969B')
        self.assertIn('尚未绑定的动作', empty['name'])
        self.assertIn('未绑定', empty['name'])
        data = self.run_helper([{'action': 'click', 'id': 'Key_empty_0'}], initial=initial)
        empty = next(control for control in data['controls'] if control['id'] == 'Key_empty_0')
        self.assertEqual(data['capture_id'], 'empty')
        self.assertEqual(empty['background'], '#FF123C50')
        self.assertEqual(empty['foreground'], '#FFB4E8FF')

    def test_conflict_location_reveals_other_action_without_reassigning(self):
        data = self.run_helper([{'action': 'category', 'value': '播放与定位'},
                                {'action': 'click', 'id': 'Key_pause_0'}, {'action': 'virtual-key', 'vk': 77},
                                {'action': 'click', 'id': 'Conflict_pause'}])
        self.assertTrue(data['clicks'][-1]['invoked'])
        self.assertEqual(data['category'], 'all')
        self.assertEqual(data['expanded_id'], 'mute')
        self.assertEqual([row['keys'] for row in data['rows']], [['m'], ['m']])
        self.assertFalse(data['can_save'])

    def test_key_names_canonical_ascii_and_reserved_keys(self):
        cases = [(65, False, False, False, 'a'), (77, False, False, True, 'M'),
                 (77, True, False, True, 'Ctrl+Shift+m'), (65, True, True, True, 'Ctrl+Alt+Shift+a'),
                 (9, False, False, False, 'Tab'), (9, False, False, True, 'Shift+Tab'),
                 (49, False, False, True, '!'), (188, True, False, True, 'Ctrl+<'),
                 (187, False, False, True, '+'), (187, True, False, True, 'Ctrl++'),
                 (189, False, False, True, None), (189, True, False, True, 'Ctrl+_'),
                 (115, False, True, False, None), (70, True, False, False, None),
                 (135, True, False, False, 'Ctrl+F24'), (32, False, True, False, 'Alt+Space')]
        for vk in [16, 17, 18, 27, 38, 40, 46, 91, 92, 96]:
            cases.append((vk, False, False, False, None))
        data = self.run_helper(validation_key_cases=[{'vk': vk, 'ctrl': ctrl, 'alt': alt, 'shift': shift}
                                                     for vk, ctrl, alt, shift, _ in cases])
        self.assertEqual(data['key_names'], [case[4] for case in cases])

    def test_conflicts_are_visible_and_swapping_keys_can_save_together(self):
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'm'}])
        self.assertTrue(data['dirty'])
        self.assertFalse(data['can_save'])
        self.assertIn('同时用于', data['status'])
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'm'},
                                {'action': 'select', 'id': 'mute'}, {'action': 'key', 'index': 0, 'key': 'p'},
                                {'action': 'save'}])
        self.assertTrue(data['saving'])
        command = data['commands'][0]
        self.assertEqual(command[:5], ['script-message-to', 'user_shortcuts', 'save', TOKEN, 'revision-one'])
        self.assertEqual(json.loads(command[5]), {'pause': ['m'], 'mute': ['p']})

    def test_clear_disables_action_and_restore_all_only_edits_draft(self):
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'clear', 'index': 0}, {'action': 'save'}])
        self.assertEqual(json.loads(data['commands'][0][5]), {'pause': []})
        data = self.run_helper([{'action': 'restore-all', 'confirm': True}])
        self.assertTrue(data['dirty'])
        self.assertEqual(data['commands'], [])
        data = self.run_helper([{'action': 'restore-all', 'confirm': True}, {'action': 'save'}])
        self.assertEqual(json.loads(data['commands'][0][5]), {})

    def test_repairable_candidates_keep_other_custom_keys_when_conflict_is_fixed(self):
        initial = repairable_state()
        data = self.run_helper(initial=initial)
        self.assertEqual([row['keys'] for row in data['rows']], [['m'], ['m'], ['t']])
        self.assertFalse(data['dirty'])
        self.assertFalse(data['can_save'])
        self.assertIn('上一组有效快捷键', data['status'])
        steps = [{'action': 'select', 'id': 'mute'}, {'action': 'key', 'index': 0, 'key': 'n'}]
        data = self.run_helper(steps, initial=initial)
        self.assertTrue(data['dirty'])
        self.assertTrue(data['can_save'])
        data = self.run_helper(steps + [{'action': 'save'}], initial=initial)
        self.assertTrue(data['saving'])
        self.assertEqual(json.loads(data['commands'][0][5]), {'pause': ['m'], 'mute': ['n'], 'info': ['t']})
        failed = repairable_state()
        failed.update(save_serial=1, save_error='写入失败，请重试')
        failed_steps = steps + [{'action': 'save'}, {'action': 'state', 'state': failed}]
        data = self.run_helper(failed_steps, initial=initial)
        self.assertFalse(data['saving'])
        self.assertTrue(data['can_save'])
        self.assertEqual(data['status'], '写入失败，请重试')
        self.assertEqual([row['keys'] for row in data['rows']], [['m'], ['n'], ['t']])
        data = self.run_helper(failed_steps + [{'action': 'save'}], initial=initial)
        self.assertTrue(data['saving'])
        self.assertEqual(len(data['commands']), 2)

    def test_repairable_restore_all_changes_candidate_baseline_and_can_save(self):
        data = self.run_helper([{'action': 'restore-all', 'confirm': True}], initial=repairable_state())
        self.assertTrue(data['dirty'])
        self.assertTrue(data['can_save'])
        self.assertEqual([row['keys'] for row in data['rows']], [['Space'], ['m'], ['i']])
        data = self.run_helper([{'action': 'restore-all', 'confirm': True}, {'action': 'save'}], initial=repairable_state())
        self.assertEqual(json.loads(data['commands'][0][5]), {})

    def test_nonrepairable_state_error_blocks_save_but_save_error_can_retry(self):
        initial = repairable_state()
        initial['repairable'] = False
        initial['error'] = '配置版本或内容损坏，请修复配置后重新载入。'
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'},
                                {'action': 'save'}], initial=initial)
        self.assertTrue(data['dirty'])
        self.assertFalse(data['can_save'])
        self.assertEqual(data['commands'], [])
        self.assertEqual(data['rows'][2]['keys'], ['i'])
        self.assertEqual(data['status'], initial['error'])
        steps = [{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'}, {'action': 'save'},
                 {'action': 'state', 'state': state(save_error='写入失败', save_serial=1)}]
        data = self.run_helper(steps)
        self.assertTrue(data['can_save'])
        data = self.run_helper(steps + [{'action': 'save'}])
        self.assertTrue(data['saving'])
        self.assertEqual(len(data['commands']), 2)

    def test_other_token_is_ignored_and_external_revision_keeps_draft(self):
        other = state('revision-two', editor_token='other-instance')
        data = self.run_helper([{'action': 'state', 'state': other}])
        self.assertEqual(data['revision'], 'revision-one')
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'},
                                {'action': 'state', 'state': state('revision-two')}])
        self.assertTrue(data['stale'])
        self.assertTrue(data['dirty'])
        self.assertEqual(data['rows'][0]['keys'], ['x'])
        self.assertFalse(data['can_save'])
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'},
                                {'action': 'state', 'state': state('revision-two')}, {'action': 'reload', 'confirm': True}])
        self.assertEqual(data['revision'], 'revision-two')
        self.assertFalse(data['dirty'])
        self.assertFalse(data['stale'])

    def test_save_serial_controls_completion_and_errors_retain_draft(self):
        steps = [{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'}, {'action': 'save'}]
        data = self.run_helper(steps + [{'action': 'state', 'state': state(save_error='写入失败', save_serial=0)}])
        self.assertTrue(data['saving'])
        data = self.run_helper(steps + [{'action': 'state', 'state': state(save_error='写入失败', save_serial=1)}])
        self.assertFalse(data['saving'])
        self.assertTrue(data['dirty'])
        self.assertEqual(data['rows'][0]['keys'], ['x'])
        self.assertEqual(data['status'], '写入失败')
        self.assertEqual(data['status_color'], '#FFFFBB99')
        saved = state('revision-two', save_serial=1)
        saved['actions'][0]['keys'] = ['x']
        data = self.run_helper(steps + [{'action': 'state', 'state': saved}])
        self.assertFalse(data['saving'])
        self.assertFalse(data['dirty'])
        self.assertEqual(data['revision'], 'revision-two')
        self.assertEqual(data['status'], '已保存并应用。')
        self.assertEqual(data['status_color'], '#FF92969B')

    def test_pending_save_disables_close_without_discard_confirmation_until_ack(self):
        pre_ack = state('revision-two', save_serial=0)
        pre_ack['actions'][0]['keys'] = ['x']
        steps = [{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'x'},
                 {'action': 'save'}, {'action': 'close-attempt'},
                 {'action': 'state', 'state': pre_ack}, {'action': 'close-attempt'}]
        data = self.run_helper(steps)
        self.assertTrue(data['saving'])
        self.assertFalse(data['close_enabled'])
        self.assertEqual(data['close_attempts'], [True, True])
        self.assertEqual(data['discard_checks'], 0)
        saved = state('revision-two', save_serial=1)
        saved['actions'][0]['keys'] = ['x']
        data = self.run_helper(steps + [{'action': 'state', 'state': saved}, {'action': 'close-attempt'}])
        self.assertFalse(data['saving'])
        self.assertTrue(data['close_enabled'])
        self.assertEqual(data['close_attempts'], [True, True, False])
        self.assertEqual(data['discard_checks'], 0)

    def test_dark_scrollbar_alignment_and_neutral_fallback_icon(self):
        data = self.run_helper()
        self.assertEqual(data['scrollbar']['background'], '#FF222222')
        self.assertEqual(data['scrollbar']['width'], 14)
        for name in ['thumb', 'page_up', 'page_down', 'page_changed', 'page_restored', 'thumb_changed', 'list_uses_style']:
            self.assertTrue(data['scrollbar'][name], data['scrollbar'])
        self.assertTrue(data['has_icon'])
        self.assertEqual(data['icon_source'], 'fallback')

    def test_display_group_order_preserves_catalog_and_group_member_order(self):
        catalog = state()
        groups = ['字幕与弹幕', '播放与定位', '工具与设置', '循环与标记', '播放与定位',
                  '窗口与界面', '截图与片段', '画面', '音频', '文件']
        catalog['actions'] = [{'id': 'action-' + str(index), 'group': group, 'label': str(index),
                               'command': 'ignore', 'default_keys': [], 'keys': [], 'focus_main': False}
                              for index, group in enumerate(groups)]
        data = self.run_helper(initial=catalog)
        self.assertEqual([row['id'] for row in data['rows']], ['action-' + str(index) for index in range(len(groups))])
        self.assertEqual(data['visible_order'], ['action-1', 'action-4', 'action-3', 'action-0',
                                                 'action-8', 'action-7', 'action-6', 'action-5', 'action-9', 'action-2'])

    def test_search_filters_actual_controls(self):
        data = self.run_helper([{'action': 'search', 'value': '静音'}])
        self.assertEqual(data['visible_rows'], 1)
        self.assertFalse(data['dirty'])

    def test_invalid_key_does_not_change_draft(self):
        data = self.run_helper([{'action': 'select', 'id': 'pause'}, {'action': 'key', 'index': 0, 'key': 'Ctrl+f'}])
        self.assertFalse(data['dirty'])
        self.assertEqual(data['rows'][0]['keys'], ['p'])
        self.assertIn('重新录入', data['status'])

    def test_hidden_ipc_close_and_parent_exit(self):
        for mode in ['ClientClose', 'ParentExit']:
            with self.subTest(mode=mode):
                completed = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                                            '-File', str(ROOT / 'tests/fixtures/shortcuts_ipc.ps1'),
                                            '-SourcePath', str(HELPER), '-Mode', mode], capture_output=True, timeout=30)
                result = json.loads(completed.stdout.decode('utf-8-sig'))
                self.assertEqual(completed.returncode, 0, result)
                self.assertEqual(completed.stderr, b'')
                self.assertTrue(result['wrong_token_ignored'])
                self.assertTrue(result['settings_untouched'])
                self.assertEqual(result['ready'], ['script-message-to', 'user_shortcuts', 'editor-ready', 'fixture-token-123'])
                self.assertEqual(result['close'], ['script-message-to', 'user_shortcuts', 'editor-close', 'fixture-token-123'])


if __name__ == '__main__':
    unittest.main()
