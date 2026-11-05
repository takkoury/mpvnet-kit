"""Run subtitle parsing and the controller against a deferred mpv subprocess double."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'config/script-modules/subtitle-lines.lua'
CONTROLLER = ROOT / 'config/scripts/track-selection.lua'


class SubtitleLines(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.data = DATA.read_text(encoding='utf-8')
        cls.controller = CONTROLLER.read_text(encoding='utf-8')
        cls.fixture = (ROOT / 'tests/lua/subtitle_lines.lua').read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, controller_and_cases = self.fixture.split('-- DATA MODULE IS INSERTED HERE\n', 1)
        setup, cases = controller_and_cases.split('-- CONTROLLER IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\nlocal Data=(function()\n' + self.data + '\nend)()\n' +
                         setup + '\n' + self.controller + '\n' + cases + '\n' + name + '()',
                         name='subtitle-lines/' + name)

    def test_extraction_source_uses_real_stream_index_and_fallback_order(self):
        self.run_case('extraction_source_uses_real_stream_index_and_fallback_order')

    def test_parse_keeps_text_and_time_paired_and_strips_markup(self):
        self.run_case('parse_keeps_text_and_time_paired_and_strips_markup')

    def test_bounds_reject_partial_results(self):
        self.run_case('bounds_reject_partial_results')

    def test_unavailable_sources_and_failures_can_recover(self):
        self.run_case('unavailable_sources_and_failures_can_recover')

    def test_submit_uses_latest_delay_and_marker_does_not_reload(self):
        self.run_case('submit_uses_latest_delay_and_marker_does_not_reload')

    def test_changes_reject_previous_row_ids_and_reread(self):
        self.run_case('changes_reject_previous_row_ids_and_reread')

    def test_cancel_timeout_and_media_retirement_abort_their_own_jobs(self):
        self.run_case('cancel_timeout_and_media_retirement_abort_their_own_jobs')
