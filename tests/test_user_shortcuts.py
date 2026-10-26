"""Run the production shortcut model and script in Lua 5.1 with an mpv/IO host double."""
import json
import os
from pathlib import Path
import re
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'config/script-modules/user-shortcuts.lua'
SCRIPT = ROOT / 'config/scripts/user-shortcuts.lua'
# InputHelp.GetDefaults also contains keyboard-only actions after the menu.
# The independent native-menu snapshot covers the rest, including unbound items.
KEYBOARD_ONLY_COMMANDS = {
    'script-message-to mpvnet show-menu', 'seek 60', 'seek -60', 'ignore',
    'no-osd seek 1 exact', 'no-osd seek -1 exact', 'no-osd seek 5 exact', 'no-osd seek -5 exact',
    'revert-seek', 'revert-seek mark', 'no-osd sub-seek -1', 'no-osd sub-seek 1',
    'no-osd seek 5', 'no-osd seek -5',
}
NATIVE_COMMANDS = set(json.loads((ROOT / 'tests/fixtures/native-menu.json').read_text(encoding='utf-8'))['native_commands']) | KEYBOARD_ONLY_COMMANDS


class UserShortcuts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'tests/lua/user_shortcuts.lua').read_text(encoding='utf-8')
        cls.source = cls.source.replace('-- MODEL SOURCE IS INSERTED HERE', MODULE.read_text(encoding='utf-8'))
        cls.source = cls.source.replace('-- SCRIPT SOURCE IS INSERTED HERE', SCRIPT.read_text(encoding='utf-8'))
        cls.source = 'local input_source = [===[\n' + (ROOT / 'config/input.conf').read_text(encoding='utf-8') + '\n]===]\n' + cls.source
        cls.source = 'local native_commands = {' + ','.join(json.dumps(command) for command in sorted(NATIVE_COMMANDS)) + '}\n' + cls.source

    def run_case(self, name, initial_document=None):
        setup = '' if initial_document is None else 'files[user_path]=[===[' + initial_document + ']===]'
        source = self.source.replace('-- INITIAL DOCUMENT IS INSERTED HERE', setup)
        self.lua.execute(source + '\n' + name + '()', name='user-shortcuts/' + name)

    def test_catalog_comes_from_managed_input(self):
        self.run_case('catalog_defaults')

    def test_every_native_default_command_has_exact_or_semantic_mapping(self):
        self.run_case('native_catalog_coverage')

    def test_every_actionable_managed_menu_command_has_a_catalog_item(self):
        self.run_case('menu_catalog_coverage')

    def test_osc_actions_and_project_public_apis_are_covered(self):
        self.run_case('project_catalog_coverage')

    def test_new_actions_have_no_default_keys_and_can_receive_user_keys(self):
        self.run_case('new_action_bindings')

    def test_trial_renderer_actions_require_their_exact_managed_menu(self):
        self.run_case('trial_catalog')

    def test_native_snapshot_matches_cached_upstream_getdefaults(self):
        value = os.environ.get('MPVNET_NATIVE_INPUT_HELP')
        if not value:
            self.skipTest('Set MPVNET_NATIVE_INPUT_HELP for optional upstream source comparison')
        path = Path(value)
        if not path.is_file():
            self.skipTest('Optional upstream source cache is absent; the checked-in command snapshot remains covered')
        actual = set()
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            match = re.search(r'Add\(b,\s*new\s*\((.*)\)\);', line)
            if not match:
                continue
            inner = match.group(1)
            args, start, depth, quoted, escape = [], 0, 0, False, False
            for index, char in enumerate(inner):
                if quoted:
                    if escape:
                        escape = False
                    elif char == '\\':
                        escape = True
                    elif char == '"':
                        quoted = False
                elif char == '"':
                    quoted = True
                elif char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                elif char == ',' and depth == 0:
                    args.append(inner[start:index].strip())
                    start = index + 1
            args.append(inner[start:].strip())
            if len(args) >= 3 and args[2].startswith('"'):
                command = ' '.join(json.loads(args[2]).split())
                if command:
                    actual.add(command)
        self.assertEqual(actual, NATIVE_COMMANDS)

    def test_key_normalization_matches_windows_editor(self):
        self.run_case('key_normalization')

    def test_atomic_swap_disable_and_reset_plan(self):
        self.run_case('swap_disable_and_reset')

    def test_conflicts_reserved_keys_and_foreign_actions(self):
        self.run_case('mapping_rejections')

    def test_conflict_details_include_all_valid_candidate_actions(self):
        self.run_case('complete_conflict_candidates')

    def test_startup_conflict_can_be_repaired_without_losing_other_overrides(self):
        self.run_case('repair_startup_conflict',
                      '{"schema":1,"future":{"null":null},"shortcuts":{'
                      '"future.action":[],"playback.pause":["Right"],"subtitle.copy":["F3"]}}')

    def test_startup_conflict_can_reset_without_losing_unknown_fields(self):
        self.run_case('reset_startup_conflict',
                      '{"schema":1,"future":{"null":null},"shortcuts":{'
                      '"future.action":[],"playback.pause":["Right"],"subtitle.copy":["F3"]}}')

    def test_strict_json_and_schema_validation(self):
        self.run_case('json_validation')

    def test_unknown_fields_and_json_shapes_survive_save_and_reset(self):
        self.run_case('unknown_fields_preserved')

    def test_runtime_uses_direct_default_keybind_and_keeps_forced_sections(self):
        self.run_case('direct_default_bindings')

    def test_changed_keys_are_released_before_rebinding(self):
        self.run_case('release_changed_keys')

    def test_keybind_failure_restores_previous_runtime_mapping(self):
        self.run_case('binding_failure')

    def test_runtime_success_waits_for_writer_then_publishes(self):
        self.run_case('save_success')

    def test_bom_file_preserves_expected_bytes_and_sends_valid_document(self):
        self.run_case('bom_save')

    def test_save_request_preserves_unknown_numeric_and_date_text(self):
        self.run_case('document_text_preserved')

    def test_runtime_writer_failure_and_stale_revision_do_not_apply(self):
        self.run_case('save_failures_and_stale')

    def test_external_reload_keeps_previous_valid_bindings_on_invalid_file(self):
        self.run_case('external_reload')

    def test_runtime_reset_keeps_unknown_fields(self):
        self.run_case('runtime_reset')

    def test_editor_uses_instance_pipe_and_owned_lifecycle(self):
        self.run_case('editor_lifecycle')

    def test_only_user_file_can_be_written(self):
        self.run_case('write_boundaries')

    def test_complete_lua_syntax(self):
        self.lua.check_syntax(MODULE)
        self.lua.check_syntax(SCRIPT)


if __name__ == '__main__':
    unittest.main()
