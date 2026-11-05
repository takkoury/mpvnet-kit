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
        cls.history_data = (ROOT / 'config/script-modules/history-data.lua').read_text(encoding='utf-8')
        cls.watch_later_data = (ROOT / 'config/script-modules/watch-later-data.lua').read_text(encoding='utf-8')
        cls.fixture = (ROOT / 'tests/lua/track_selection.lua').read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, cases = self.fixture.split('-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        self.lua.execute('local function make_history_data()\n' + self.history_data + '\nend\n' +
                         'local function make_watch_later_data()\n' + self.watch_later_data + '\nend\n' +
                         prelude + '\n' + self.script + '\n' + cases + '\n' + name + '()',
                         name='track-selection/' + name)

    def test_complete_script_syntax(self):
        self.lua.check_syntax(SCRIPT)


def _case(name):
    def test(self):
        self.run_case(name)
    return test


for _name in (
    'all_tracks_use_composite_identity_and_independent_current_markers',
    'all_tracks_reorder_removal_and_retyping_preserve_identity',
    'all_tracks_occupancy_race_failure_and_auto_current_are_rechecked',
    'all_tracks_observers_and_session_retirement_do_not_cross_instances',
    'advanced_slots_include_all_tracks_and_do_not_mutate_source',
    'advanced_secondary_preserves_other_slot_visibility_and_danmaku_options',
    'advanced_occupancy_is_checked_again_at_submit_and_observed',
    'advanced_auto_slots_failures_and_stale_sessions_are_safe',
    'editions_use_actual_current_and_submit_original_index',
    'editions_reorder_or_title_change_rejects_old_selection',
    'editions_missing_single_failure_and_media_invalidation',
    'editions_set_can_synchronously_reload_without_reviving_old_session',
    'video_selection_filters_and_retires_restore_revision',
    'video_failure_and_stale_callbacks_do_not_invalidate_restore',
    'video_observers_only_refresh_active_video',
    'device_auto_repeat_and_identity_submission',
    'device_reorder_remove_reinsert_never_reuses_identity',
    'device_empty_invalid_names_and_missing_selected_notice',
    'device_duplicate_descriptions_and_unicode_suffixes_are_distinct',
    'device_failure_readback_mismatch_and_sync_observer_retry',
    'device_disappearing_without_notice_never_writes_fallback',
    'device_observers_media_and_cross_kind_retire_callbacks',
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
    'chapter_ids_keep_original_index_and_missing_title',
    'chapter_time_format_uses_duration_or_largest_timestamp',
    'current_chapter_reselection_writes_zero_based_chapter',
    'no_chapters_and_before_first_chapter_do_not_invent_selection',
    'chapter_reorder_observer_cannot_accept_pending_old_index',
    'chapter_deletion_and_in_place_changes_require_new_choice',
    'chapter_same_time_different_titles_cannot_silently_swap',
    'chapter_observers_do_not_interfere_with_audio_or_subtitle',
    'chapter_stale_callbacks_cancel_and_write_failures_are_safe',
    'chapter_cross_kind_retirement_rejects_old_submissions',
    'history_submit_revalidates_source_and_bytes',
    'history_read_errors_retry_and_disabled_states_are_distinct',
    'history_clear_uses_the_snapshot_and_requires_another_confirmation_after_conflict',
    'history_late_replies_do_not_revive_closed_or_replaced_panel',
    'watch_later_submits_plain_path_and_observes_resume_setting',
    'watch_later_changed_removed_and_new_directory_require_new_ids',
    'watch_later_distinguishes_empty_missing_path_and_unreadable',
    'watch_later_stale_reads_never_update_other_panels',
):
    setattr(TrackSelection, 'test_' + _name, _case(_name))


if __name__ == '__main__':
    unittest.main()
