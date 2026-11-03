"""Exercise the shared track controller with a synchronous renderer double."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'config/scripts/track-selection.lua'


class TrackSelection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.script = SCRIPT.read_text(encoding='utf-8')
        cls.fixture = (ROOT / 'tests/lua/track_selection.lua').read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, cases = self.fixture.split('-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\n' + self.script + '\n' + cases + '\n' + name + '()',
                         name='track-selection/' + name)

    def test_complete_script_syntax(self):
        self.lua.check_syntax(SCRIPT)


def _case(name):
    def test(self):
        self.run_case(name)
    return test


for _name in (
    'lazy_load_and_named_bindings',
    'audio_metadata_and_filter_are_preserved',
    'current_audio_and_explicit_off_disable_audio',
    'subtitle_filter_and_toggle_regression',
    'invalid_ids_recheck_live_tracks_without_observer_notification',
    'same_id_retyped_or_changed_to_danmaku_is_rejected',
    'current_selection_is_read_again_at_submit',
    'empty_lists_can_open_and_disable',
    'relevant_observers_refresh_only_active_kind',
    'close_retires_submit_and_writes_nothing',
    'repeated_open_retires_old_callback_before_synchronous_close',
    'cross_kind_callbacks_cannot_submit_or_close_new_panel',
    'lifecycle_invalidates_same_id_and_closed_callbacks',
    'write_failure_keeps_request_usable',
    'missing_module_reports_failure_and_can_retry',
    'invalid_module_contract_is_rejected',
    'open_failure_retires_request_and_cleans_partial_panel',
):
    setattr(TrackSelection, 'test_' + _name, _case(_name))


if __name__ == '__main__':
    unittest.main()
