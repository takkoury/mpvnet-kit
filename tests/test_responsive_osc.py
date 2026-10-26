"""Exercise actual default geometry, overflow pages and mouse dispatch in Lua 5.1."""
import json
from pathlib import Path
import unittest

from lua_runtime import load_lua51

from support.lua_source import fragment, typed_configuration

ROOT = Path(__file__).resolve().parents[1]
MODERNZ = ROOT / 'config/scripts/modernz.lua'


class ResponsiveOsc(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        prelude, cases = (ROOT / 'tests/lua/responsive_osc.lua').read_text(encoding='utf-8').split(
            '-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            fragment(source, 'local user_opts = {', 'local osc_param = {'), typed_configuration(ROOT / 'config/script-opts/modernz.conf'), prelude,
            fragment(source, 'local function ass_draw_rr_h_cw(', 'local function get_hidetimeout()'),
            fragment(source, 'local function scale_value(', '-- returns the position of an object'),
            fragment(source, 'local function get_time_codes_width()', 'local function mult_alpha('),
            fragment(source, 'local function mult_alpha(', '-- draw tooltip background box and label'),
            fragment(source, 'local function set_volume(', 'local function window_controls_enabled()'),
            fragment(source, 'close_popover = function()', 'local function prepare_elements()'),
            fragment(source, 'local function new_element(', '-- Local panels for the default layout'),
            fragment(source, 'local function setup_local_popovers()', '-- Window Controls'),
            fragment(source, 'local layouts = {}', 'layouts["compact"] = function ()'),
            fragment(source, 'local function prepare_elements()', '--\n-- Element Rendering'),
            fragment(source, 'local function bind_buttons(', '-- format seconds into a time string'),
            'local function build_volume_source()\nlocal ne\n' + fragment(source, '    --volumebar\n', '    -- zoom in/out helper') + '\nend',
            fragment(source, 'local function reset_timeout()', 'local function do_enable_keybindings()'),
            fragment(source, 'local function request_init_resize()', 'local function render_wipe('),
            fragment(source, 'observe_cached("speed", function()', 'mp.observe_property("user-data/mpvnet/enhancement"'),
            cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='responsive/' + case)

    def test_geometry_matrix_and_reachability(self):
        self.run_case('geometry_matrix')

    def test_actual_width_selects_layout(self):
        self.run_case('actual_width')

    def test_priority_and_transport_reduction(self):
        self.run_case('priority')

    def test_more_click_outside_escape_and_hover(self):
        self.run_case('click_lifecycle')

    def test_scroll_has_fixed_back_and_32_rows(self):
        self.run_case('scroll_and_back')

    def test_more_reaches_above_normal_showhide_region(self):
        self.run_case('showhide_regions')

    def test_capture_complete_page_and_mouse_aliases(self):
        self.run_case('capture_actions')

    def test_volume_subtitle_speed_actions(self):
        self.run_case('other_actions')

    def test_more_hints_only_forward_enabled_root_extra_actions(self):
        self.run_case('more_tooltips')

    def test_volume_slider_keeps_arbitrary_values_and_drag(self):
        self.run_case('volume_slider')

    def test_volume_popup_drag_matches_visible_rail_and_wider_hit_area(self):
        self.run_case('volume_popup_drag')

    def test_simple_action_runs_once(self):
        self.run_case('simple_action')

    def test_disabled_tracks_remain_visible_and_inert(self):
        self.run_case('no_tracks')

    def test_enhancement_footer_and_selection(self):
        self.run_case('enhancement_page')

    def test_resize_closes_and_refreshes_geometry(self):
        self.run_case('resize_lifecycle')

    def test_long_time_gets_priority_over_title(self):
        self.run_case('long_time')

    def test_speed_width_growth_requests_layout(self):
        self.run_case('speed_width_growth')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(MODERNZ)


if __name__ == '__main__':
    unittest.main()
