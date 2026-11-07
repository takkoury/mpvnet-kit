"""Execute the complete input controller with mpv and temporary IO doubles."""
import json
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'config/script-modules/playlist-input.lua'


class PlaylistInputController(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.fixture = (ROOT / 'tests/lua/playlist_input.lua').read_text(encoding='utf-8')

    def run_case(self, name):
        source = ('local input_module = dofile(' + json.dumps(MODULE.as_posix()) + ')\n'
                  + 'local feedback_module = dofile('
                  + json.dumps((ROOT / 'config/script-modules/feedback.lua').as_posix()) + ')\n'
                  + self.fixture + '\n' + name + '()')
        self.lua.execute(source, 'playlist-input/' + name)

    def test_request_captures_current_inputs_and_launches_direct_helper(self):
        self.run_case('request_contract')

    def test_single_open_retains_autocreate_and_unpauses(self):
        self.run_case('single_open')

    def test_mixed_open_preserves_order_and_disables_autocreate_for_batch(self):
        self.run_case('mixed_open')

    def test_append_preserves_pause_order_and_empty_queue_stays_idle(self):
        self.run_case('append_preserves_state')

    def test_subtitle_only_and_native_entries(self):
        self.run_case('subtitle_and_native')

    def test_cancel_and_feedback_for_duplicates_empty_and_partial_results(self):
        self.run_case('result_feedback')

    def test_request_preparation_failures_never_launch_or_change_queue(self):
        self.run_case('preparation_failures')

    def test_invalid_helper_results_are_rejected_without_raw_paths(self):
        self.run_case('invalid_results')

    def test_request_snapshot_rejects_changed_queue_cwd_current_or_path(self):
        self.run_case('stale_snapshot')

    def test_new_request_and_shutdown_abort_only_owned_job_and_ignore_old_callbacks(self):
        self.run_case('retired_callbacks')

    def test_synchronous_invalidation_during_result_parsing_is_rejected(self):
        self.run_case('synchronous_snapshot_change')

    def test_synchronous_new_request_or_shutdown_stops_old_batch(self):
        self.run_case('synchronous_reentry')

    def test_command_failures_report_partial_result_and_do_not_fake_unpause(self):
        self.run_case('command_failures')

    def test_complete_module_syntax(self):
        self.lua.check_syntax(MODULE)


if __name__ == '__main__':
    unittest.main()
