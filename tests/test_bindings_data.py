"""Check native binding precedence and session-safe replay with a synthetic mpv host."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class BindingsData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        modules = ROOT / 'config/script-modules'
        data = (modules / 'bindings-data.lua').read_text(encoding='utf-8')
        catalog = (modules / 'user-shortcuts.lua').read_text(encoding='utf-8')
        controller = (ROOT / 'config/scripts/track-selection.lua').read_text(encoding='utf-8')
        fixture = (ROOT / 'tests/lua/bindings_data.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- CONTROLLER IS INSERTED HERE\n', 1)
        cls.source = ('local function make_bindings_data()\n' + data + '\nend\n' +
                      'local function make_shortcut_model()\n' + catalog + '\nend\n' +
                      prelude + '\n' + controller + '\n' + cases)

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='bindings-data/' + name)

    def test_effective_commands_and_labels(self):
        self.run_case('effective_commands_and_labels')

    def test_invalid_entries_do_not_become_rows(self):
        self.run_case('invalid_entries_do_not_become_rows')

    def test_snapshot_and_replay_take_place_after_input_restoration(self):
        self.run_case('snapshot_and_replay_take_place_after_input_restoration')

    def test_reassigned_removed_and_ignored_keys_do_not_execute(self):
        self.run_case('reassigned_removed_and_ignored_keys_do_not_execute')

    def test_execute_can_open_a_new_selector(self):
        self.run_case('execute_can_open_a_new_selector')

    def test_replacement_and_media_events_retire_old_callbacks(self):
        self.run_case('replacement_and_media_events_retire_old_callbacks')

    def test_retry_and_failure_messages_do_not_echo_commands(self):
        self.run_case('retry_and_failure_messages_do_not_echo_commands')
