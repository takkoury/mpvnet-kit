"""Run the actual chapter-preview path with explicit mpv/ASS host doubles."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51


from support.lua_source import fragment

ROOT = Path(__file__).resolve().parents[1]
MODERNZ = ROOT / 'config/scripts/modernz.lua'


class ChapterPreview(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = MODERNZ.read_text(encoding='utf-8')
        fixture = (ROOT / 'tests/lua/chapter_preview.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            fragment(source, 'local user_opts = {', 'local osc_param = {'), prelude,
            fragment(source, 'local text_measure_osd =', '-- width of the time codes element'),
            fragment(source, 'local function draw_tooltip(', 'local function ass_draw_cir_cw('),
            fragment(source, 'local function get_chapter(possec)', '-- Computes handle position'),
            'local function render_preview(element, slider_lo, elem_geo, elem_ass)\n'
            + fragment(source, '                        local sliderpos = get_slider_value(element)',
                       '                    elseif element.thumbnailable and thumbfast.available then')
            + '\nreturn {x = tx, chapter = chapter_text, width = chapter_width, time_width = tooltip_width}\nend',
            cases,
        ])

    def run_case(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='chapter/' + case)

    def test_plain_cjk_and_utf8(self):
        self.run_case('plain_cjk_and_utf8')

    def test_metadata_uses_escape_ass(self):
        self.run_case('metadata_uses_escape_ass')

    def test_long_text_at_both_edges(self):
        self.run_case('long_text_at_both_edges')

    def test_controlled_format_keeps_style(self):
        self.run_case('controlled_format_keeps_style')

    def test_thumbnail_and_text_keep_independent_anchors(self):
        self.run_case('thumbnail_and_text_keep_independent_anchors')

    def test_very_narrow_canvas(self):
        self.run_case('very_narrow_canvas')

    def test_absent_or_disabled_chapter(self):
        self.run_case('absent_or_disabled_chapter')

    def test_complete_script_syntax(self):
        self.lua.check_syntax(MODERNZ)


if __name__ == '__main__':
    unittest.main()
