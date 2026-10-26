"""Exercise the complete Playlist script with only the mpv/IO host replaced."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'config/scripts/playlist-controls.lua'


class PlaylistControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.script = SCRIPT.read_text(encoding='utf-8')
        cls.fixture = (ROOT / 'tests/lua/playlist_controls.lua').read_text(encoding='utf-8')

    def run_case(self, name, initial_properties=''):
        prelude, cases = self.fixture.split('-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\n' + initial_properties + '\n' + self.script + '\n' + cases + '\n' + name + '()',
                         name='playlist/' + name)

    def test_open_failure_paths(self):
        self.run_case('open_failure_paths')

    def test_worker_failure_and_cancellation(self):
        self.run_case('worker_failure_and_cancellation')

    def test_success_and_shutdown_are_silent(self):
        self.run_case('success_and_shutdown_are_silent')

    def test_append_rejections_and_partial_success(self):
        self.run_case('append_rejections_and_partial_success')

    def test_actions_keep_queue_ids_and_token_boundary(self):
        self.run_case('actions_keep_queue_ids_and_token_boundary')

    def test_locate_reads_current_queue_without_playing(self):
        self.run_case('locate_reads_current_queue_without_playing')

    def test_shortcut_changes_release_old_keys_and_update_forwarding(self):
        self.run_case('shortcut_changes_release_old_keys_and_update_forwarding')

    def test_equivalent_shortcut_updates_keep_held_keys_and_invalid_state_restores_defaults(self):
        self.run_case('equivalent_shortcut_updates_keep_held_keys_and_invalid_state_restores_defaults')

    def test_initial_shortcuts_define_forwarding(self):
        self.run_case('initial_shortcuts_define_forwarding',
                      "properties['user-data/mpvnet/shortcuts']={schema=1,forward_keys={'F8'}}")

    def test_complete_script_syntax(self):
        self.lua.check_syntax(SCRIPT)


if __name__ == '__main__':
    unittest.main()
