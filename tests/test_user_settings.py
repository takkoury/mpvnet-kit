"""Production settings/controller/feature code with an mpv and IO host double."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class UserSettings(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'tests/lua/user_settings.lua').read_text(encoding='utf-8')
        for marker, path in (
            ('PARSER SOURCE', 'config/script-modules/user-shortcuts.lua'),
            ('MODEL SOURCE', 'config/script-modules/user-settings.lua'),
            ('PATHS SOURCE', 'config/script-modules/mpvnet-paths.lua'),
            ('CONTROLLER SOURCE', 'config/scripts/user-settings.lua'),
            ('SUBTITLE SOURCE', 'config/scripts/subtitle-controls.lua'),
        ):
            cls.source = cls.source.replace('-- ' + marker, (ROOT / path).read_text(encoding='utf-8'))
        modernz = (ROOT / 'config/scripts/modernz.lua').read_text(encoding='utf-8')
        start = modernz.index('-- ModernZ applies its own live option')
        end = modernz.index('\nset_virt_mouse_area(', start)
        cls.source = cls.source.replace('-- MODERNZ INTEGRATION', modernz[start:end])

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='user-settings/' + name)

    def test_raw_patch_preserves_unknown_fields_shortcuts_and_other_pages(self):
        self.run_case('raw_patch_preserves_other_pages_and_unknowns')

    def test_production_scripts_start_in_either_load_order(self):
        self.run_case('script_load_order_and_startup_saved_values')

    def test_preview_restores_only_owned_value_and_expires_on_media_change(self):
        self.run_case('preview_cancel_manual_and_media_fencing')

    def test_save_updates_temporary_subtitle_adjustment_baseline(self):
        self.run_case('save_and_temporary_adjustment_baseline')

    def test_two_instances_sync_saved_values_and_defer_effective_values(self):
        self.run_case('two_instances_defer_external_changes')

    def test_saved_file_and_runtime_application_report_separate_outcomes(self):
        self.run_case('save_failure_and_application_failure_are_separate')

    def test_closed_session_and_shutdown_reject_stale_actions(self):
        self.run_case('session_close_stale_preview_and_shutdown')

    def test_path_page_is_independent_and_program_paths_require_restart(self):
        self.run_case('paths_separate_revision_and_restart_rules')

    def test_invalid_files_and_conflicts_preserve_runtime_and_source(self):
        self.run_case('corrupt_files_and_conflict_keep_runtime')

    def test_reset_uses_actual_feature_default_and_removes_only_that_override(self):
        self.run_case('defaults_delete_only_the_current_override')

    def test_local_reader_matches_bom_semantics_and_freezes_program_paths_per_instance(self):
        self.run_case('local_reader_bom_and_new_task_frozen_program_paths')

    def test_newer_external_save_is_not_applied_as_the_current_windows_save(self):
        self.run_case('saved_success_with_newer_external_write_does_not_apply_foreign_value')

    def test_delayed_observers_keep_commits_and_reject_older_snapshots(self):
        self.run_case('delayed_observers_cannot_drop_commit_or_restore_old_saved_state')

    def test_advanced_startup_default_is_preserved_outside_editor_range(self):
        self.run_case('advanced_startup_baseline_is_never_replaced_by_editor_range')

    def test_failed_runtime_apply_keeps_the_previous_preview_cancelable(self):
        self.run_case('failed_save_application_keeps_preview_cancelable')

    def test_owned_manual_action_invalidates_preview_even_when_value_is_unchanged(self):
        self.run_case('explicit_manual_same_value_invalidates_preview')

    def test_failed_preview_cancel_keeps_the_restoration_point_for_retry(self):
        self.run_case('failed_cancel_preserves_ownership_for_retry')

    def test_path_write_receipt_cannot_be_mistaken_for_a_later_external_save(self):
        self.run_case('path_write_receipt_does_not_adopt_a_newer_external_write')

    def test_reopened_window_can_retry_its_retired_owner_but_not_unknown_owners(self):
        self.run_case('reopen_can_retry_only_its_retired_preview_owner')

    def test_reopened_preview_keeps_its_retired_owners_original_restoration_point(self):
        self.run_case('reopened_preview_retains_its_retired_restoration_point')

    def test_float32_roundtrip_is_successful_and_preview_ownership_uses_actual_value(self):
        self.run_case('float_roundtrip_accepts_apply_and_keeps_exact_preview_ownership')

    def test_complete_production_lua_syntax(self):
        for path in ('config/script-modules/user-settings.lua', 'config/scripts/user-settings.lua',
                     'config/scripts/modernz.lua', 'config/scripts/subtitle-controls.lua',
                     'config/script-modules/mpvnet-paths.lua'):
            self.lua.check_syntax(ROOT / path)


if __name__ == '__main__':
    unittest.main()
