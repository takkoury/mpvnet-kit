"""Execute ModernZ's real input functions with layout and mpv host doubles."""
import json
from pathlib import Path
import unittest

from lua_runtime import load_lua51


from support.lua_source import fragment, string_configuration

ROOT = Path(__file__).resolve().parents[1]
MODERNZ = ROOT / 'config/scripts/modernz.lua'


class ModernzInteractions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        playlist = (ROOT / 'config/scripts/playlist-controls.lua').read_text(encoding='utf-8')
        feedback = (ROOT / 'config/scripts/playback-feedback.lua').read_text(encoding='utf-8')
        fixture = (ROOT / 'tests/lua/modernz_interactions.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        pieces = [
            fragment(source, 'local user_opts = {', 'local osc_param = {'),
            string_configuration(ROOT / 'config/script-opts/modernz.conf'), prelude,
            fragment(source, 'local function contains(', 'local thumbfast = {'),
            fragment(source, 'local function get_hitbox_coords(', 'local function limit_range('),
            fragment(source, 'local function new_element(', 'local function add_layout('),
            fragment(source, 'local function bind_buttons(', '-- format seconds into a time string'),
            fragment(source, 'local function prepare_elements()', '--\n-- Element Rendering'),
            fragment(playlist, 'local function queue()', 'local function find_id('),
            fragment(playlist, 'local function step(direction)', 'local function extension_sets()'),
            fragment(feedback, 'local function show_speed()', 'local seek_timer ='),
            fragment(source, 'close_popover = function()', 'local function enhancement_ready('),
            fragment(source, 'local function update_popover()', '-- Window Controls'),
            fragment(source, 'local function reset_timeout()', 'local function do_enable_keybindings()'),
            'local function build_queue_buttons()\n'
            '    state.playlist_count = #entries\n'
            '    state.playlist_pos_1 = current_position + 1\n'
            + fragment(source, '    -- some often needed stuff\n', '    local function make_escaped_title(') +
            '    local ne\n' + fragment(source, '    -- playlist buttons\n', '    --play control buttons\n') + '\nend',
            cases,
        ]
        cls.source = '\n'.join(pieces)

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='modernz/' + name)

    def test_queue_boundaries(self):
        self.run_case('queue_boundaries')

    def test_speed_anchor_wheel(self):
        self.run_case('speed_anchor_wheel')

    def test_popup_body_does_not_route_wheel(self):
        self.run_case('popup_body_does_not_route_wheel')

    def test_close_and_move_away(self):
        self.run_case('close_and_move_away')

    def test_other_popovers_and_middle_button(self):
        self.run_case('other_popovers_and_middle_button')

    def test_hidden_and_active_drag(self):
        self.run_case('hidden_and_active_drag')

    def test_anchor_without_wheel_action(self):
        self.run_case('anchor_without_wheel_action')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(MODERNZ)


if __name__ == '__main__':
    unittest.main()
