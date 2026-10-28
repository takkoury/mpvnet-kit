"""Production settings/controller/feature code with an mpv and IO host double."""
from pathlib import Path
import json
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class UserSettings(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'tests/lua/user_settings.lua').read_text(encoding='utf-8')
        package_options = {}
        for line in (ROOT / 'config/mpv.conf').read_text(encoding='utf-8').splitlines():
            key, separator, value = line.partition('=')
            key, value = key.strip(), value.strip()
            if separator and key in ('slang', 'alang', 'sub-visibility'):
                if key in package_options:
                    raise AssertionError('Duplicate package default: ' + key)
                if key == 'sub-visibility':
                    if value not in ('yes', 'no'):
                        raise AssertionError('Invalid package subtitle visibility')
                    value = value == 'yes'
                package_options[key] = value
        cls.source = cls.source.replace('-- PACKAGE OPTIONS', ',\n'.join(
            '[' + json.dumps(key) + ']=' + (str(value).lower() if isinstance(value, bool) else json.dumps(value))
            for key, value in package_options.items()))
        for marker, path in (
            ('PARSER SOURCE', 'config/script-modules/user-shortcuts.lua'),
            ('MODEL SOURCE', 'config/script-modules/user-settings.lua'),
            ('PATHS SOURCE', 'config/script-modules/mpvnet-paths.lua'),
            ('CONTROLLER SOURCE', 'config/scripts/user-settings.lua'),
            ('SUBTITLE SOURCE', 'config/scripts/subtitle-controls.lua'),
            ('OPTIONS SOURCE', 'config/scripts/settings-options.lua'),
        ):
            cls.source = cls.source.replace('-- ' + marker, (ROOT / path).read_text(encoding='utf-8'))
        modernz = (ROOT / 'config/scripts/modernz.lua').read_text(encoding='utf-8')
        start = modernz.index('-- ModernZ applies its own live option')
        end = modernz.index('\nset_virt_mouse_area(', start)
        cls.source = cls.source.replace('-- MODERNZ INTEGRATION', modernz[start:end])
        start = modernz.index('    ne.eventresponder["mbtn_left_up"]', modernz.index('    -- Time codes display'))
        end = modernz.index('    ne.eventresponder["mbtn_right_up"]', start)
        cls.source = cls.source.replace('-- MODERNZ TIME ACTION', modernz[start:end])
        start = modernz.index('mp.add_key_binding(nil, "progress-toggle"')
        end = modernz.index('mp.register_script_message("osc-idlescreen"', start)
        cls.source = cls.source.replace('-- MODERNZ PROGRESS ACTION', modernz[start:end])

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='user-settings/' + name)

    def test_raw_patch_preserves_unknown_fields_shortcuts_and_other_pages(self):
        self.run_case('raw_patch_preserves_other_pages_and_unknowns')

    def test_editor_refresh_reads_external_without_writing_or_changing_session(self):
        self.run_case('editor_refresh_reads_external_without_writing_or_changing_session')

    def test_editor_refresh_rejects_invalid_busy_and_closed_requests(self):
        self.run_case('editor_refresh_rejects_invalid_busy_and_closed_requests')

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

    def test_display_preview_accepts_only_the_current_editor_and_known_operations(self):
        self.run_case('display_preview_token_and_operation_fencing')

    def test_display_preview_finishes_on_close_helper_exit_and_shutdown(self):
        self.run_case('display_preview_editor_lifecycle')

    def test_typed_false_empty_string_null_and_raw_unknown_values(self):
        self.run_case('typed_values_and_raw_page_patch')

    def test_complete_fields_publish_editor_metadata(self):
        self.run_case('all_fields_publish_their_type_timing_and_page')

    def test_one_feature_dispatches_multiple_preview_owners_without_overwriting(self):
        self.run_case('multiple_preview_fields_restore_independently')

    def test_language_visibility_and_decode_apply_in_on_load_before_selection(self):
        self.run_case('next_media_options_run_before_selection_and_never_at_save')

    def test_startup_settings_apply_once_and_saved_false_remains_an_override(self):
        self.run_case('startup_overrides_initialize_once_and_false_is_not_missing')

    def test_deferred_observers_and_external_updates_follow_each_fields_timing(self):
        self.run_case('options_observers_can_be_delayed_and_external_changes_defer')

    def test_all_modernz_fields_preview_restore_and_update_internal_display_state(self):
        self.run_case('all_modernz_fields_apply_preview_and_cancel')

    def test_open_actions_allow_only_fixed_ids_from_the_current_editor(self):
        self.run_case('actions_require_current_token_and_fixed_allowlist')

    def test_explicit_baseline_equal_values_survive_different_host_defaults(self):
        self.run_case('explicit_values_equal_to_baseline_keep_the_override')

    def test_first_on_load_reads_preferences_before_delayed_observers(self):
        self.run_case('first_media_hook_reads_snapshot_before_delayed_notifications')

    def test_manual_time_and_progress_actions_invalidate_their_preview_owners(self):
        self.run_case('manual_modernz_actions_invalidate_owned_preview')

    def test_saved_modernz_values_apply_locally_and_defer_picture_changes_elsewhere(self):
        self.run_case('saved_modernz_booleans_and_strings_defer_other_instances')

    def test_both_host_remember_orders_initialize_volume_and_mute_at_first_load_once(self):
        self.run_case('host_remember_volume_orders_apply_only_at_first_load')

    def test_new_save_before_first_media_does_not_change_frozen_startup_target(self):
        self.run_case('first_load_uses_frozen_startup_snapshot_despite_new_save')

    def test_first_media_inheritance_does_not_apply_values_saved_during_idle(self):
        self.run_case('inherited_startup_stays_inherited_when_saved_before_first_load')

    def test_repair_before_first_media_cannot_replace_an_invalid_bootstrap(self):
        self.run_case('invalid_bootstrap_cannot_be_repaired_into_this_startup')

    def test_idle_status_and_default_follow_host_until_first_media_initializes(self):
        self.run_case('equal_startup_override_is_pending_until_first_load_and_baseline_refreshes')

    def test_failed_first_media_initialization_reports_failure_without_retrying_next_media(self):
        self.run_case('failed_first_media_initialization_is_not_retried_on_media_change')

    def test_package_language_and_visibility_defaults_match_the_startup_owner(self):
        self.run_case('package_language_defaults_come_from_actual_startup_configuration')

    def test_language_defaults_preserve_advanced_custom_values_and_null_reset(self):
        self.run_case('language_defaults_preserve_advanced_configuration_and_explicit_empty_values')

    def test_complete_production_lua_syntax(self):
        for path in ('config/script-modules/user-settings.lua', 'config/scripts/user-settings.lua',
                     'config/scripts/modernz.lua', 'config/scripts/subtitle-controls.lua', 'config/scripts/settings-options.lua',
                     'config/script-modules/mpvnet-paths.lua'):
            self.lua.check_syntax(ROOT / path)


if __name__ == '__main__':
    unittest.main()
