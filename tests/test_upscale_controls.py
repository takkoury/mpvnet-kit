"""Exercise the real upscale owner through its public actions and host events."""
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class UpscaleControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        prelude, cases = (ROOT / 'tests/lua/upscale_controls.lua').read_text(encoding='utf-8').split(
            '-- MODULE HERE\n', 1)
        module = (ROOT / 'config/script-modules/upscale.lua').read_text(encoding='utf-8')
        cls.source = prelude + '\nlocal module=(function()\n' + module + '\nend)()\n' + cases

    def check(self, case):
        self.lua.execute(self.source + '\n' + case + '()', name='upscale/' + case)

    def test_missing_components_install_does_not_activate(self):
        self.check('missing_components_install_does_not_activate')

    def test_cancel_waits_for_exit_and_preserves_manual_pause(self):
        self.check('cancel_waits_for_exit_and_preserves_manual_pause')

    def test_old_media_completion_cannot_activate_new_media(self):
        self.check('old_media_completion_cannot_activate_new_media')

    def test_only_actual_output_marks_active_and_external_hwdec_survives(self):
        self.check('only_actual_output_marks_active_and_external_hwdec_survives')

    def test_old_dialog_exit_does_not_hide_new_dialog(self):
        self.check('old_dialog_exit_does_not_hide_new_dialog')

    def test_cancel_host_wait_ignores_late_ready(self):
        self.check('cancel_host_wait_ignores_late_ready')

    def test_removed_filter_withdraws_active_and_releases_hwdec(self):
        self.check('removed_filter_withdraws_active_and_releases_hwdec')

    def test_activation_reads_current_color_interpretation(self):
        self.check('activation_reads_current_color_interpretation')

    def test_component_probe_survives_media_change(self):
        self.check('component_probe_survives_media_change')

    def test_resume_reclaims_only_new_managed_signature(self):
        self.check('resume_reclaims_only_new_managed_signature')

    def test_failed_removal_keeps_ownership_for_explicit_retry(self):
        self.check('failed_removal_keeps_ownership_for_explicit_retry')
