"""Independent subtitle panel with actual Lua 5.1 and only mpv mocked."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class SubtitleSelector(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'tests/lua/subtitle_selector.lua').read_text(encoding='utf-8').replace(
            '-- MODULE SOURCE', (ROOT / 'config/script-modules/subtitle-selector.lua').read_text(encoding='utf-8'))

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='subtitle-selector/' + case)

    def test_open_close_repeat_and_borrowed_input_properties(self):
        self.run_case('open_close_repeated_and_temporary_ownership')

    def test_unicode_cursor_delete_and_ime_commit_channel(self):
        self.run_case('unicode_editing_and_ime_events_are_single_channel')

    def test_keyboard_selection_current_off_and_no_matching_tracks(self):
        self.run_case('keyboard_selection_off_current_and_filtered_empty')

    def test_submit_failure_dynamic_tracks_and_reentrant_callbacks(self):
        self.run_case('errors_refresh_reentrant_submission_and_stale_callback')

    def test_tooltip_dwell_expiry_and_no_track_state(self):
        self.run_case('tooltip_and_empty_panel')

    def test_scroll_wheel_and_mouse_click_use_visible_track_ids(self):
        self.run_case('scrolling_mouse_click_hover_and_dynamic_resize')

    def test_small_osd_empty_error_no_match_and_language_fallback_names(self):
        self.run_case('fitting_empty_no_match_error_and_language_names')

    def test_console_handoff_external_changes_focus_and_shutdown(self):
        self.run_case('console_handoff_and_conditional_restoration')

    def test_open_failure_zero_osd_and_resize_release_every_resource(self):
        self.run_case('failed_open_and_zero_osd_restore')

    def test_missing_optional_property_uses_only_first_native_return_value(self):
        self.run_case('missing_optional_property_error_does_not_become_number_base')

    def test_thumb_drag_and_controller_media_close_cannot_submit_stale_row(self):
        self.run_case('thumb_drag_cancel_and_media_close_do_not_submit')

    def test_initial_or_deferred_false_focus_does_not_close_until_true_was_seen(self):
        self.run_case('initial_unfocused_notification_requires_a_prior_true_before_close')

    def test_zero_negative_nan_and_infinite_dpi_use_a_visible_unit_scale(self):
        self.run_case('invalid_hidpi_values_use_visible_unit_scale')


if __name__ == '__main__':
    unittest.main()
