"""Real ModernZ visibility, pause, lease and media handlers with an mpv host double."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51
from support.lua_source import fragment

ROOT = Path(__file__).resolve().parents[1]


class SettingsDisplay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        source = (ROOT / 'config/scripts/modernz.lua').read_text(encoding='utf-8')
        prelude, cases = (ROOT / 'tests/lua/settings_display.lua').read_text(encoding='utf-8').split(
            '-- SOURCE FUNCTIONS ARE INSERTED HERE\n', 1)
        cls.source = '\n'.join([
            fragment(source, 'local user_opts = {', 'local osc_param = {'), prelude,
            fragment(source, 'local function kill_animation(', 'local function set_osd('),
            fragment(source, 'local function get_hidetimeout()', 'local function cache_enabled()'),
            fragment(source, 'local function show_bar(', 'local function update_tracklist('),
            fragment(source, 'local function set_bar_visible(', '-- use_down:'),
            fragment(source, 'local function show_wc()', 'local function handle_touch('),
            fragment(source, 'local function do_enable_keybindings()', 'local function render()'),
            'local function autohide()\nlocal now=mp.get_time()\n' +
            fragment(source, '    -- autohide\n', '    -- actual rendering\n') + '\nend',
            fragment(source, 'local function always_on(', 'local function idlescreen_visibility('),
            fragment(source, 'local function apply_pause_policy(', 'mp.add_key_binding(nil, "progress-toggle"'),
            fragment(source, 'mp.register_event("shutdown", function()', 'mp.observe_property("track-list"'),
            fragment(source, 'observe_cached("idle-active", function()', 'mp.observe_property("display-fps"'),
            fragment(source, '-- read options from config and command-line', '\nload_locale_file()'),
            'local settings_model_fixture=(function()\n' +
            (ROOT / 'config/script-modules/user-settings.lua').read_text(encoding='utf-8') + '\nend)()',
            'local function install_settings_owners()\nlocal dofile=function() return settings_model_fixture end\n' +
            fragment(source, '-- ModernZ applies its own live option', '\nset_virt_mouse_area(') + '\nend',
            cases,
        ])

    def run_case(self, name):
        self.lua.execute(self.source + '\n' + name + '()', name='settings-display/' + name)

    def test_live_pause_previews_update_real_policy_and_restore_advanced_showonpause(self):
        self.run_case('live_pause_previews_restore_policy')

    def test_modes_keep_the_bottom_bar_visible_without_changing_visibility(self):
        self.run_case('modes_and_mouse_leave')

    def test_lease_cancels_an_already_running_fade_out(self):
        self.run_case('lease_cancels_fade_out')

    def test_heartbeat_extends_only_a_live_lease_and_expires_at_three_seconds(self):
        self.run_case('renew_expiry_and_foreign_tokens')

    def test_manual_visibility_and_hide_take_precedence_over_preview(self):
        self.run_case('manual_modes_and_hide')

    def test_pause_keep_modes_restore_the_current_policy(self):
        self.run_case('pause_policy_matrix')

    def test_manual_visibility_while_paused_supersedes_the_old_restore_point(self):
        self.run_case('manual_pause_override')

    def test_manual_visibility_without_a_lease_preserves_the_existing_pause_state(self):
        self.run_case('manual_pause_without_lease')

    def test_showonpause_disabled_keeps_normal_visibility_and_pause_flags_on_release(self):
        self.run_case('pause_display_disabled')

    def test_media_events_and_shutdown_revoke_without_heartbeat_revival(self):
        self.run_case('media_shutdown_and_reopen')

    def test_option_changes_revoke_but_other_options_keep_the_lease(self):
        self.run_case('option_changes')

    def test_idle_and_console_revoke_preview_display(self):
        self.run_case('idle_and_console')


if __name__ == '__main__':
    unittest.main()
