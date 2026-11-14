"""Exercise the audio owner's public mode/settings interface with Lua 5.1."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51
from support.lua_source import feedback_module

ROOT = Path(__file__).resolve().parents[1]


class AudioControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        prelude, cases = (ROOT / 'tests/lua/audio_controls.lua').read_text(encoding='utf-8').split(
            '-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        prelude = prelude.replace('-- SETTINGS MODEL IS INSERTED HERE',
                                  (ROOT / 'config/script-modules/user-settings.lua').read_text(encoding='utf-8'))
        cls.source = '\n'.join(['local feedback_module = ' + feedback_module(), prelude,
            (ROOT / 'config/scripts/audio-controls.lua').read_text(encoding='utf-8'), cases])

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='audio/' + name)

    def test_only_owned_filter_changes_and_off_preserves_external_chain(self):
        self.run_case('only_owned_filter_changes')

    def test_eligibility_tracks_audio_reconfiguration_without_transient_teardown(self):
        self.run_case('eligibility_and_transients')

    def test_media_end_cleans_owned_label_and_retains_instance_selection(self):
        self.run_case('media_lifecycle')

    def test_saved_defaults_do_not_replace_the_startup_snapshot(self):
        self.run_case('startup_snapshot')

    def test_successful_manual_choice_wins_over_late_startup(self):
        self.run_case('late_startup')

    def test_foreign_label_is_never_replaced_or_removed(self):
        self.run_case('foreign_label')

    def test_external_filter_changes_withdraw_ownership_without_reapplying(self):
        self.run_case('external_changes')

    def test_failed_add_and_partial_add_do_not_erase_other_filters(self):
        self.run_case('failed_add')

    def test_failed_remove_can_be_retried_without_false_restore(self):
        self.run_case('failed_remove')

    def test_readback_failure_after_add_can_be_recovered(self):
        self.run_case('readback_recovery')

    def test_gapless_playback_uses_the_first_settled_audio_format(self):
        self.run_case('gapless_format_arrives_after_file_loaded')

    def test_unload_removes_the_filter_before_next_file_profile_backup(self):
        self.run_case('synchronous_unload_precedes_next_profile_backup')

    def test_same_file_track_switch_waits_for_new_decoder_even_when_paused(self):
        self.run_case('switch_track_waits_for_the_new_decoder_format')

    def test_resume_filter_fingerprint_does_not_override_saved_startup_mode(self):
        self.run_case('restored_managed_label_does_not_override_startup_default')
