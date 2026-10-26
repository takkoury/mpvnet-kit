"""Exercise the complete subtitle script with only its mpv/input host replaced."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'config/scripts/subtitle-controls.lua'


class SubtitleControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.script = SCRIPT.read_text(encoding='utf-8')
        cls.fixture = (ROOT / 'tests/lua/subtitle_controls.lua').read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, cases = self.fixture.split('-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\n' + self.script + '\n' + cases + '\n' + name + '()',
                         name='subtitle/' + name)

    def test_repeated_entry_keeps_first_baseline(self):
        self.run_case('repeated_entry_keeps_first_baseline')

    def test_reset_inside_adjustment(self):
        self.run_case('reset_inside_adjustment')

    def test_reset_outside_adjustment_without_primary_track(self):
        self.run_case('reset_outside_adjustment_without_primary_track')

    def test_no_record_does_not_write_properties(self):
        self.run_case('no_record_does_not_write_properties')

    def test_reentry_after_reset_captures_new_baseline(self):
        self.run_case('reentry_after_reset_captures_new_baseline')

    def test_lifecycle_cleanup_is_silent_and_clears_record(self):
        self.run_case('lifecycle_cleanup_is_silent_and_clears_record')

    def test_normal_exit_keeps_working_adjustments(self):
        self.run_case('normal_exit_keeps_working_adjustments')

    def test_single_actions_keep_mode_off_and_share_baseline(self):
        self.run_case('single_actions_keep_mode_off_and_share_baseline')

    def test_single_actions_preserve_active_mode(self):
        self.run_case('single_actions_preserve_active_mode')

    def test_single_actions_without_primary_subtitle_are_noops(self):
        self.run_case('single_actions_without_primary_subtitle_are_noops')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(SCRIPT)


if __name__ == '__main__':
    unittest.main()
