"""Check native property snapshots and the selector with a synthetic mpv host."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class PropertiesData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        data = (ROOT / 'config/script-modules/properties-data.lua').read_text(encoding='utf-8')
        controller = (ROOT / 'config/scripts/track-selection.lua').read_text(encoding='utf-8')
        fixture = (ROOT / 'tests/lua/properties_data.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- CONTROLLER IS INSERTED HERE\n', 1)
        cls.source = ('local function make_properties_data()\n' + data + '\nend\n' +
                      prelude + '\n' + controller + '\n' + cases)

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='properties-data/' + name)

    def test_flattens_native_values_and_paths(self):
        self.run_case('flattens_native_values_and_paths')

    def test_option_roots_preserve_the_original_log_level(self):
        self.run_case('option_roots_preserve_the_original_log_level')

    def test_failures_restore_the_borrowed_level(self):
        self.run_case('failures_restore_the_borrowed_level')

    def test_refuses_cyclic_and_oversized_data(self):
        self.run_case('refuses_cyclic_and_oversized_data')

    def test_selects_the_original_value_as_literal_detail(self):
        self.run_case('selects_the_original_value_as_literal_detail')

    def test_logs_only_a_chosen_detail_without_video_output(self):
        self.run_case('logs_only_a_chosen_detail_without_video_output')

    def test_invalidates_callbacks_on_retry_media_change_and_reentry(self):
        self.run_case('invalidates_callbacks_on_retry_media_change_and_reentry')

    def test_failure_feedback_omits_native_diagnostics(self):
        self.run_case('failure_feedback_omits_native_diagnostics')
