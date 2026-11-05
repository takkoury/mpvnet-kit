"""Run the real screen menu and controller against a Lua mpv double."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / 'config/scripts/track-selection.lua'
MENU = ROOT / 'config/script-modules/selector-menu.lua'


class SelectorMenu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        fixture = (ROOT / 'tests/lua/selector_menu.lua').read_text(encoding='utf-8')
        prelude, cases = fixture.split('-- COMPLETE SOURCE IS INSERTED HERE\n', 1)
        cls.source = ('local function make_menu()\n' + MENU.read_text(encoding='utf-8') + '\nend\n' +
                      prelude + '\n' + CONTROLLER.read_text(encoding='utf-8') + '\n' + cases)

    def test_complete_module_syntax(self):
        self.lua.check_syntax(MENU)


def _case(name):
    def test(self):
        self.lua.execute(self.source + '\n' + name + '()', name='selector-menu/' + name)
    return test


for _name in (
    'all_whitelisted_actions_dispatch_after_close',
    'visibility_uses_live_media_and_preserves_ids',
    'malformed_sources_cannot_add_rows_or_commands',
    'refresh_is_in_place_and_rejects_stale_and_never_presented_rows',
    'retirement_prevents_old_actions_and_can_open_child_inline',
    'failure_stays_in_chinese_and_uses_the_same_retryable_panel',
):
    setattr(SelectorMenu, 'test_' + _name, _case(_name))
