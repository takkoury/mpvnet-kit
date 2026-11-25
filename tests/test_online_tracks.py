"""Source-level checks for yt-dlp catalogue identity and per-entry recovery."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51


ROOT = Path(__file__).resolve().parents[1]


class OnlineTracks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        module = (ROOT / 'config/script-modules/online-tracks.lua').read_text(encoding='utf-8')
        cases = (ROOT / 'tests/lua/online_tracks.lua').read_text(encoding='utf-8')
        cls.source = 'local M = (function()\n' + module + '\nend)()\n' + cases

    def test_groups_and_native_tracks(self):
        self.lua.execute(self.source + '\ncheck_catalog()')

    def test_restore_same_entry_once(self):
        self.lua.execute(self.source + '\ncheck_reload(false)')

    def test_new_selection_cancels_recovery(self):
        self.lua.execute(self.source + '\ncheck_reload(true)')
