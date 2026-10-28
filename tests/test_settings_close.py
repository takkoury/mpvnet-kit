"""Close confirmation and sequential acknowledgements; real WPF, no HWND or files."""
import copy
import os
import unittest
import test_settings_window as window_fixture
from test_settings_shortcuts import state as shortcut_state

complete_state = window_fixture.complete_state


def saved_state(previous, page, serial, **values):
    state = copy.deepcopy(previous)
    revision = ('p' if page == 'paths' else 'r') + str(serial + 1)
    state.update(save_page=page, save_serial=serial, save_ok=True, save_revision=revision, save_error='')
    state['paths_revision' if page == 'paths' else 'revision'] = revision
    for field in state['fields']:
        if field['id'] in values:
            field.update(saved=values[field['id']], effective=values[field['id']], has_override=True)
    return state


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF')
class SettingsCloseTests(unittest.TestCase):
    run_window = window_fixture.SettingsWindow.run_window

    def test_three_equal_buttons_and_cancel_preserves_draft(self):
        steps = [dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close')]
        prompt = self.run_window(steps, complete_state())
        self.assertEqual([b['label'] for b in prompt['close_buttons']], ['保存','不保存','取消'])
        self.assertEqual({(b['width'],b['height']) for b in prompt['close_buttons']}, {(104,36)})
        self.assertEqual(prompt['close_buttons'][0]['background'],'#FF1287BB')
        self.assertNotEqual(prompt['close_buttons'][1]['background'],'#FF1287BB')
        canceled = self.run_window(steps+[dict(op='close-choice',id='CloseCancel')],complete_state())
        self.assertFalse(canceled['close_accepted'])
        self.assertFalse(canceled['overlay_open'])
        self.assertTrue(canceled['body_enabled'])
        self.assertEqual(canceled['dirty_pages'],['subtitles'])
        self.assertFalse(any(c[2] == 'save' for c in canceled['sent']))

    def test_discard_closes_and_retires_preview_without_saving(self):
        data = self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseDiscard')],complete_state())
        self.assertTrue(data['close_accepted'])
        self.assertEqual(data['sent'][-1][2],'editor-close')
        self.assertFalse(any(c[2] == 'save' for c in data['sent']))

    def test_clean_close_needs_no_confirmation_or_write(self):
        data = self.run_window([dict(op='request-close')],complete_state())
        self.assertTrue(data['close_accepted'])
        self.assertFalse(data['overlay_open'])
        self.assertFalse(data['show_in_taskbar'])
        self.assertEqual(data['window_style'],'None')
        self.assertEqual(data['caption_height'],36)

    def test_save_waits_for_refresh_and_positive_ack(self):
        initial = complete_state()
        steps = [dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave')]
        waiting = self.run_window(steps,initial)
        self.assertTrue(waiting['close_saving'])
        self.assertEqual(waiting['close_save_phase'],'refresh')
        self.assertFalse(waiting['close_accepted'])
        self.assertFalse(any(c[2]=='save' for c in waiting['sent']))
        refreshed = steps+[dict(op='state',state=copy.deepcopy(initial),current_refresh=True)]
        awaiting = self.run_window(refreshed,initial)
        self.assertTrue(awaiting['saving'])
        self.assertFalse(awaiting['close_accepted'])
        good = saved_state(initial,'subtitles',1,**{'sub-scale':1.2})
        result = self.run_window(refreshed+[dict(op='state',state=good)],initial)
        self.assertTrue(result['close_accepted'])
        self.assertEqual(result['dirty_pages'],[])

    def test_all_dirty_domains_save_in_order_before_close(self):
        initial = complete_state(); shorts = shortcut_state()
        subtitles = saved_state(initial,'subtitles',1,**{'sub-scale':1.2})
        paths = saved_state(subtitles,'paths',2,capture_root='C:/Temp/Capture')
        refreshed_shortcuts = copy.deepcopy(shorts); refreshed_shortcuts['revision']='r2'
        saved_shortcuts = copy.deepcopy(refreshed_shortcuts)
        saved_shortcuts.update(revision='r3',save_serial=1)
        saved_shortcuts['actions'][0]['keys']=['x']
        data = self.run_window([
            dict(op='shortcuts-state',state=shorts),dict(op='page',page='shortcuts'),dict(op='shortcut-edit',id='pause',key='x'),
            dict(op='edit',id='sub-scale',text='1.2'),dict(op='edit',id='capture_root',text='C:/Temp/Capture'),
            dict(op='request-close'),dict(op='close-choice',id='CloseSave'),
            dict(op='state',state=copy.deepcopy(initial),current_refresh=True),dict(op='state',state=copy.deepcopy(subtitles)),
            dict(op='state',state=copy.deepcopy(subtitles),current_refresh=True),dict(op='state',state=paths),
            dict(op='shortcuts-state',state=refreshed_shortcuts,current_refresh=True),dict(op='shortcuts-state',state=saved_shortcuts)],initial)
        saves=[c for c in data['sent'] if c[2]=='save']
        self.assertEqual([c[1] for c in saves],['user_settings','user_settings','user_shortcuts'])
        self.assertEqual([saves[0][5],saves[1][5]],['subtitles','paths'])
        self.assertEqual(data['close_saved_pages'],['subtitles','paths','shortcuts'])
        self.assertTrue(data['close_accepted'])
        self.assertEqual(data['dirty_pages'],[])

    def test_settings_pages_use_new_revision_after_each_ack(self):
        initial=complete_state()
        first=saved_state(initial,'subtitles',1,**{'sub-scale':1.2})
        second=saved_state(first,'controlbar',2,**{'modernz.scalewindowed':1.3})
        data=self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='edit',id='modernz.scalewindowed',text='1.3'),
            dict(op='request-close'),dict(op='close-choice',id='CloseSave'),dict(op='state',state=copy.deepcopy(initial),current_refresh=True),
            dict(op='state',state=copy.deepcopy(first)),dict(op='state',state=copy.deepcopy(first),current_refresh=True),dict(op='state',state=second)],initial)
        saves=[c for c in data['sent'] if c[2]=='save']
        self.assertEqual([c[4] for c in saves],['r1','r2'])
        self.assertEqual(data['close_saved_pages'],['subtitles','controlbar'])
        self.assertTrue(data['close_accepted'])

    def test_partial_failure_retains_remaining_drafts_and_window(self):
        initial=complete_state(); good=saved_state(initial,'subtitles',1,**{'sub-scale':1.2})
        failed=copy.deepcopy(good);failed.update(save_page='paths',save_serial=2,save_ok=False,save_error='目录不可写')
        data=self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='edit',id='capture_root',text='C:/Temp/Capture'),
            dict(op='request-close'),dict(op='close-choice',id='CloseSave'),dict(op='state',state=copy.deepcopy(initial),current_refresh=True),
            dict(op='state',state=copy.deepcopy(good)),dict(op='state',state=copy.deepcopy(good),current_refresh=True),dict(op='state',state=failed)],initial)
        self.assertFalse(data['close_accepted'])
        self.assertFalse(data['close_saving'])
        self.assertTrue(data['body_enabled'])
        self.assertEqual(data['page'],'paths')
        self.assertEqual(data['dirty_pages'],['paths'])
        self.assertEqual(data['close_saved_pages'],['subtitles'])
        self.assertIn('已保存：字幕',data['notice'])
        self.assertIn('目录不可写',data['notice'])

    def test_external_change_seen_at_refresh_stops_before_write(self):
        initial=complete_state(); external=copy.deepcopy(initial);external['revision']='external-r2'
        next(f for f in external['fields'] if f['id']=='sub-scale').update(saved=1.8,has_override=True)
        data=self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave'),
            dict(op='state',state=external,current_refresh=True)],initial)
        self.assertFalse(data['close_accepted'])
        self.assertFalse(data['close_saving'])
        self.assertEqual(data['dirty_pages'],['subtitles'])
        self.assertFalse(any(c[2]=='save' for c in data['sent']))

    def test_shortcut_conflict_preflight_does_not_partially_save_settings(self):
        data=self.run_window([dict(op='shortcuts-state',state=shortcut_state()),dict(op='page',page='shortcuts'),dict(op='shortcut-edit',id='pause',key='m'),
            dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave')],complete_state())
        self.assertFalse(data['close_accepted'])
        self.assertFalse(data['close_saving'])
        self.assertEqual(data['page'],'shortcuts')
        self.assertFalse(any(c[2]=='save' for c in data['sent']))

    def test_refresh_timeout_and_disconnect_never_auto_close(self):
        for op in ['close-timeout','disconnect']:
            with self.subTest(op=op):
                data=self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave'),dict(op=op)],complete_state())
                self.assertFalse(data['close_accepted'])
                self.assertFalse(data['close_saving'])
                self.assertEqual(data['dirty_pages'],['subtitles'])
                self.assertTrue(data['body_enabled'])

    def test_unconfirmed_save_can_discard_without_duplicate_submission(self):
        initial=complete_state()
        steps=[dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave'),
            dict(op='state',state=copy.deepcopy(initial),current_refresh=True),dict(op='close-timeout'),dict(op='request-close')]
        prompt=self.run_window(steps,initial)
        self.assertTrue(prompt['save_unconfirmed'])
        self.assertFalse(prompt['saving'])
        self.assertFalse(prompt['close_buttons'][0]['enabled'])
        self.assertTrue(prompt['close_buttons'][1]['enabled'])
        discarded=self.run_window(steps+[dict(op='close-choice',id='CloseDiscard')],initial)
        self.assertTrue(discarded['close_accepted'])
        self.assertEqual(len([c for c in discarded['sent'] if c[2]=='save']),1)

    def test_late_success_after_timeout_never_closes_window(self):
        initial=complete_state(); good=saved_state(initial,'subtitles',1,**{'sub-scale':1.2})
        data=self.run_window([dict(op='edit',id='sub-scale',text='1.2'),dict(op='request-close'),dict(op='close-choice',id='CloseSave'),
            dict(op='state',state=copy.deepcopy(initial),current_refresh=True),dict(op='close-timeout'),dict(op='state',state=good)],initial)
        self.assertFalse(data['close_accepted'])
        self.assertFalse(data['save_unconfirmed'])
        self.assertFalse(data['close_saving'])
        self.assertEqual(data['dirty_pages'],[])

    def test_shortcut_timeout_keeps_discard_available(self):
        initial=complete_state(); shorts=shortcut_state()
        steps=[dict(op='shortcuts-state',state=copy.deepcopy(shorts)),dict(op='page',page='shortcuts'),dict(op='shortcut-edit',id='pause',key='x'),
            dict(op='request-close'),dict(op='close-choice',id='CloseSave'),dict(op='shortcuts-state',state=shorts,current_refresh=True),
            dict(op='shortcuts-timeout'),dict(op='request-close')]
        data=self.run_window(steps+[dict(op='close-choice',id='CloseDiscard')],initial)
        self.assertTrue(data['save_unconfirmed'])
        self.assertTrue(data['close_accepted'])
        self.assertEqual(len([c for c in data['sent'] if c[2]=='save']),1)
