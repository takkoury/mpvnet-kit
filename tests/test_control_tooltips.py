"""Execute real control construction, configured commands and tooltip placement."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51
from test_responsive_osc import configuration, fragment

ROOT = Path(__file__).resolve().parents[1]
MODERNZ = ROOT / 'config/scripts/modernz.lua'


class ControlTooltips(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        prelude, cases = (ROOT / 'tests/lua/control_tooltips.lua').read_text(encoding='utf-8').split(
            '-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            fragment(source, 'local user_opts = {', 'local osc_param = {'), configuration(),
            fragment(source, 'local language = {', 'local bidi = {'),
            'local locale = language.default', prelude,
            fragment(source, 'local function mult_alpha(', '-- draw tooltip background box and label'),
            fragment(source, '-- Button hints use a small self-drawn mouse,', 'local function ass_draw_cir_cw('),
            fragment(source, 'local function new_element(', 'local function add_layout('),
            fragment(source, 'local function bind_buttons(', '-- format seconds into a time string'),
            'local function build_controls()\nlocal ne\n',
            fragment(source, '    -- OSC title\n', '    -- Chapter title\n'),
            fragment(source, '    --play_pause\n', '    local jump_amount ='),
            fragment(source, '    --fullscreen\n', '    --screenshot\n'),
            fragment(source, '    --sub_track\n', '    --volumebar\n'),
            fragment(source, '    --screenshot\n', '    --file_loop\n'),
            fragment(source, '    --speed\n', '    --download\n'),
            fragment(source, '    -- Time codes display\n', '    -- load layout\n'), 'end',
            'local function render_hint(element)\nlocal elem_ass = new_ass()\n',
            fragment(source, '            local seeking_with_force_tooltip =', '        end\n\n        master_ass:merge(elem_ass)'),
            'if #elem_ass.ops > 0 then drawn = {ass = elem_ass} end\nreturn elem_ass\nend', cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='tooltips/' + case)

    def test_configured_hints_and_dispatch(self):
        self.run_case('configured_hints_and_dispatch')

    def test_title_local_network_and_custom_bindings(self):
        self.run_case('title_and_custom_bindings')

    def test_subtitle_states_and_custom_fallback(self):
        self.run_case('subtitle_states')

    def test_hints_above_unchanged_popover_and_omit_without_space(self):
        self.run_case('popover_placement')

    def test_title_subtitle_and_time_hints_clear_visible_title_backgrounds(self):
        self.run_case('title_placement')

    def test_absent_empty_and_disabled_hints_never_measure_or_draw(self):
        self.run_case('nil_and_empty_rendering')

    def test_simple_buttons_have_no_name_or_state_tooltip(self):
        self.run_case('simple_buttons')

    def test_mouse_prefixes_and_unknown_text_fallback(self):
        self.run_case('mouse_prefixes')

    def test_mouse_text_layout_measures_and_stays_in_canvas(self):
        self.run_case('mouse_layout')

    def test_mouse_contours_share_transform_and_right_fill_covers_center(self):
        self.run_case('mouse_shapes')

    def test_mouse_text_background_events_and_fade(self):
        self.run_case('mouse_events_and_alpha')


if __name__ == '__main__':
    unittest.main()
