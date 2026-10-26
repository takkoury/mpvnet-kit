"""Execute ModernZ's actual marker rendering, hover path, and paused refresh."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51


ROOT = Path(__file__).resolve().parents[1]
MODERNZ = ROOT / 'config/scripts/modernz.lua'


def fragment(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


class SeekbarMarkers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        fixture = (ROOT / 'tests/lua/seekbar_markers.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            fragment(source, 'local user_opts = {', 'local osc_param = {'), prelude,
            fragment(source, 'local function scale_value(', '-- returns the position of an object'),
            fragment(source, 'local function get_element_hitbox(', 'local function add_area('),
            fragment(source, 'local function ass_append_alpha(', 'local function ass_draw_rr_h_cw('),
            fragment(source, 'local function get_chapter(possec)', '-- Computes handle position'),
            fragment(source, 'local function get_seekbar_handle_pos(', 'local function render_persistent_progress('),
            fragment(source, 'format_time = function(seconds)', 'local function build_cache_seek_ranges('),
            'local tick = function() end\nlocal tick_delay = 0.03',
            fragment(source, 'local function request_tick()', 'local function request_init()'),
            fragment(source, 'mp.observe_property("ab-loop-a"', 'observe_cached("osd-dimensions"'),
            cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='seekbar/' + case)

    def test_unpaired_endpoints_do_not_fill_to_end(self):
        self.run_case('unpaired_endpoints')

    def test_two_ranges_use_separate_lanes(self):
        self.run_case('overlapping_ranges')

    def test_shared_projection_and_clipping(self):
        self.run_case('shared_projection')

    def test_invalid_times_and_durations(self):
        self.run_case('invalid_values')

    def test_capture_pending_generation_and_clear(self):
        self.run_case('capture_generation')

    def test_crowded_labels_keep_shapes_and_hover(self):
        self.run_case('crowded_labels')

    def test_hover_reports_type_endpoint_and_time(self):
        self.run_case('typed_hover')

    def test_real_hover_preserves_chapter_time_and_seek(self):
        self.run_case('hover_preserves_preview')

    def test_fade_and_ass_context(self):
        self.run_case('fade_and_context')

    def test_paused_loop_observers_request_tick(self):
        self.run_case('paused_observers')

    def test_persistent_and_other_sliders_have_no_markers(self):
        self.run_case('normal_seekbar_only')

    def test_final_event_position_keeps_ranges_on_track(self):
        self.run_case('isolated_drawing_events')

    def test_narrow_hover_fits_or_omits_auxiliary_text(self):
        self.run_case('narrow_hover')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(MODERNZ)


if __name__ == '__main__':
    unittest.main()
