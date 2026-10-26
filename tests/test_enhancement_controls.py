"""Run enhancement state and ModernZ panel footer with real Lua, replacing only the host."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'config/scripts/enhancement-controls.lua'
MODERNZ = ROOT / 'config/scripts/modernz.lua'


def fragment(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


class EnhancementControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        prelude, cases = (ROOT / 'tests/lua/enhancement_controls.lua').read_text(encoding='utf-8').split(
            '-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        cls.source = '\n'.join([prelude, SCRIPT.read_text(encoding='utf-8'), cases])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='enhancement/' + case)

    def test_initialization_and_no_video_reasons(self):
        self.run_case('initialization_and_no_video_reasons')

    def test_sdr_settings_and_explicit_feedback(self):
        self.run_case('sdr_settings_and_explicit_feedback')

    def test_hdr_and_unknown_metadata(self):
        self.run_case('hdr_and_unknown_metadata')

    def test_validation_and_shader_gates(self):
        self.run_case('validation_and_shader_gates')

    def test_failed_write_restores_previous_settings(self):
        self.run_case('failed_write_restores_previous_settings')

    def test_snapshot_and_rollback_failures(self):
        self.run_case('snapshot_and_rollback_failures')

    def test_cross_media_keeps_choice_and_rechecks_gates(self):
        self.run_case('cross_media_keeps_choice_and_rechecks_gates')

    def test_renderer_loss_and_recovery_are_silent(self):
        self.run_case('renderer_loss_and_recovery_are_silent')

    def test_renderer_error_and_lifecycle(self):
        self.run_case('renderer_error_and_lifecycle')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(SCRIPT)
        self.lua.check_syntax(MODERNZ)


class ModernzEnhancementFooter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        prelude, cases = (ROOT / 'tests/lua/modernz_enhancement.lua').read_text(encoding='utf-8').split(
            '-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            prelude,
            fragment(source, 'local function osc_color_convert(', 'local osc_styles'),
            fragment(source, 'local function ass_draw_rr_h_cw(', 'local function get_hidetimeout()'),
            fragment(source, 'local function mult_alpha(', '-- draw tooltip background box and label'),
            fragment(source, 'local function get_hitbox_coords(', 'local function get_slider_ele_pos_for('),
            fragment(source, 'close_popover = function()', 'local function enhancement_ready('),
            fragment(source, 'local function enhancement_ready(', 'local function prepare_elements()'),
            fragment(source, 'local function new_element(', '-- Local panels for the default layout'),
            fragment(source, 'local function setup_local_popovers()', 'local function update_popover()'),
            fragment(source, 'local function prepare_elements()', '--\n-- Element Rendering'),
            fragment(source, 'local function update_popover()', '-- Window Controls'),
            fragment(source, 'local function reset_timeout()', 'local function do_enable_keybindings()'),
            fragment(source, 'mp.observe_property("user-data/mpvnet/enhancement"',
                     'mp.observe_property("user-data/mpvnet/capture"'),
            cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='modernz-enhancement/' + case)

    def test_normal_panel_has_only_five_options(self):
        self.run_case('normal_panel_has_only_five_options')

    def test_disabled_row_hover_explains_gate_without_click(self):
        self.run_case('disabled_row_hover_explains_gate_without_click')

    def test_footer_keeps_rows_and_hover_stable(self):
        self.run_case('footer_keeps_rows_and_hover_stable')

    def test_background_and_input_share_footer_bounds(self):
        self.run_case('background_and_input_share_footer_bounds')

    def test_long_reason_wraps_and_narrow_canvas_stays_inside(self):
        self.run_case('long_reason_wraps_and_narrow_canvas_stays_inside')

    def test_short_canvas_does_not_move_rows_to_fit_footer(self):
        self.run_case('short_canvas_does_not_move_rows_to_fit_footer')

    def test_legacy_fields_and_failure_reason(self):
        self.run_case('legacy_fields_and_failure_reason')

    def test_status_observer_is_silent_and_updates_rows(self):
        self.run_case('status_observer_is_silent_and_updates_rows')

    def test_footer_respects_close_hide_other_panel_and_fade(self):
        self.run_case('footer_respects_close_hide_other_panel_and_fade')


if __name__ == '__main__':
    unittest.main()
