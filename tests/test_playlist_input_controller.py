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

    def test_image_input_setting_and_per_entry_loading_policy(self):
        self.run_case('image_inputs_capture_setting_and_use_local_still_duration')
        self.run_case('image_lists_keep_policy_by_real_id_and_retire_it_on_replacement')

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

    def test_folder_request_never_autocreates_and_reports_empty_unreadable_or_oversized_inputs(self):
        self.run_case('folder_input_and_feedback')

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

    def test_playlist_segments_keep_native_titles_repeats_and_mixed_input_order(self):
        self.run_case('playlist_segments')

    def test_import_loading_policy_belongs_only_to_new_live_ids_and_matching_paths(self):
        self.run_case('playlist_loading_policy')

    def test_failed_import_does_not_register_loading_policy_or_prevent_later_media(self):
        self.run_case('playlist_segment_failure')

    def test_playlist_empty_missing_partial_and_read_failure_feedback(self):
        self.run_case('playlist_feedback')

    def test_playlist_result_metadata_is_validated_before_any_commit(self):
        self.run_case('playlist_invalid_metadata')

    def test_save_uses_latest_complete_queue_after_dialog_and_always_prompts_again(self):
        self.run_case('save_latest_queue')

    def test_save_cancel_empty_incomplete_and_invalid_target_never_write(self):
        self.run_case('save_rejections')

    def test_save_dialog_is_retired_by_new_input_and_old_callbacks_cannot_write(self):
        self.run_case('save_dialog_retired')

    def test_save_write_survives_new_input_and_repeated_save_reports_busy(self):
        self.run_case('save_independent_write')

    def test_save_worker_errors_and_unconfirmed_success_never_report_saved(self):
        self.run_case('save_result_validation')

    def test_save_write_preparation_failure_releases_slot_for_retry(self):
        self.run_case('save_write_preparation_failure_releases_slot')

    def test_shutdown_cleans_owned_requests_without_aborting_active_write(self):
        self.run_case('save_shutdown')

    def test_all_import_sources_are_prepared_before_queue_changes_and_io_failure_cleans_them(self):
        self.run_case('playlist_prepare_failure_preserves_queue')

    def test_import_reentry_cleans_sources_and_cannot_tag_retired_ids(self):
        self.run_case('playlist_reentry_cleans_prepared_sources')

    def test_detached_writer_launch_failure_releases_saving_slot(self):
        self.run_case('save_detach_launch_failure')

    def test_detached_reply_ownership_and_timeout_cancel_without_killing_worker(self):
        self.run_case('save_reply_ownership_and_timeout')

    def test_shutdown_does_not_leave_cancel_file_when_worker_already_finished(self):
        self.run_case('save_shutdown_without_worker_avoids_orphan_cancel')

    def test_save_dialog_parse_reentry_cannot_launch_old_write(self):
        self.run_case('save_dialog_parse_reentry_cannot_start_old_writer')

    def test_internal_utf8_transport_borrows_forced_codepage_and_preserves_external_changes(self):
        self.run_case('playlist_transport_encoding_ownership')

    def test_complete_module_syntax(self):
        self.lua.check_syntax(MODULE)


if __name__ == '__main__':
    unittest.main()
