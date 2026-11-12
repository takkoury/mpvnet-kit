"""Exercise the complete motion script with Lua 5.1 and a fake mpv host."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51
from support.lua_source import feedback_module


ROOT = Path(__file__).resolve().parents[1]


class MotionControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        prelude, cases = (ROOT / 'tests/lua/motion_controls.lua').read_text(encoding='utf-8').split(
            '-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        prelude = prelude.replace('-- SETTINGS MODEL IS INSERTED HERE',
                                  (ROOT / 'config/script-modules/user-settings.lua').read_text(encoding='utf-8'))
        cls.source = '\n'.join([
            'local feedback_module = ' + feedback_module(), prelude,
            (ROOT / 'config/scripts/motion-controls.lua').read_text(encoding='utf-8'), cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='motion/' + case)

    def test_only_two_options_and_per_media_restore(self):
        self.run_case('only_two_options_and_per_media_restore')

    def test_startup_consumes_first_read_and_save_waits(self):
        self.run_case('startup_consumes_first_read_and_save_waits')

    def test_late_startup_respects_successful_manual_choice(self):
        self.run_case('late_startup_respects_successful_manual_choice')

    def test_late_startup_recovers_from_unavailable_media(self):
        self.run_case('late_startup_recovers_from_unavailable_media')

    def test_unavailable_output_restores_and_recovers(self):
        self.run_case('unavailable_output_restores_and_recovers')

    def test_display_sync_status_comes_from_core(self):
        self.run_case('display_sync_status_comes_from_core')

    def test_failed_write_and_readback_restore_previous_pair(self):
        self.run_case('failed_write_and_readback_restore_previous_pair')

    def test_failed_rollback_reports_unknown_and_can_recover(self):
        self.run_case('failed_rollback_reports_unknown_and_can_recover')

    def test_failed_reads_never_claim_success(self):
        self.run_case('failed_reads_never_claim_success')

    def test_automatic_write_retries_only_when_eligible_again(self):
        self.run_case('automatic_write_retries_only_when_eligible_again')

    def test_external_option_change_clears_applied_without_writing(self):
        self.run_case('external_option_change_clears_applied_without_writing')
