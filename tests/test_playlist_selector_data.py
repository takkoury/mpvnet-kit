"""Exercise the live playlist mapping through the actual selector controller."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / 'config/scripts/track-selection.lua'
MODULE = ROOT / 'config/script-modules/playlist-selector-data.lua'
FIXTURE = ROOT / 'tests/lua/playlist_selector_data.lua'


class PlaylistSelectorData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        prelude, cases = FIXTURE.read_text(encoding='utf-8').split('-- COMPLETE CONTROLLER IS INSERTED HERE\n', 1)
        cls.source = ('local function make_playlist_model()\n' + MODULE.read_text(encoding='utf-8') +
                      '\nend\nlocal playlist_model = make_playlist_model()\n' + prelude +
                      '\n' + CONTROLLER.read_text(encoding='utf-8') + '\n' + cases)

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='playlist-selector/' + name)


def _case(name):
    def test(self):
        self.run_case(name)
    return test


for _name in (
    'names_modes_and_current_are_derived_without_mutating_entries',
    'observers_refresh_only_meaningful_changes_and_keep_identities',
    'submitted_identity_uses_latest_index_and_replays_current',
    'removal_replacement_and_duplicate_ids_cannot_inherit_old_selections',
    'empty_unavailable_and_retry_have_distinct_states',
    'removal_and_reorder_during_close_are_rechecked',
    'stale_callbacks_do_not_cross_sessions_and_errors_hide_details',
):
    setattr(PlaylistSelectorData, 'test_' + _name, _case(_name))
