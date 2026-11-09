"""Offline update checks, real process coalescing and WPF NoShow validation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'config/helpers/KitUpdate.exe'
FIXTURE = ROOT / 'tests/fixtures/update_check_cases.ps1'


@unittest.skipUnless(os.name == 'nt', 'Requires Windows WPF')
class UpdateCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='mpvnet-update-test-')
        cls.base = Path(cls.temp.name)
        cls.fixture_assembly = cls.base / 'UpdateCases.dll'
        result = subprocess.run(cls.command('-Build'), capture_output=True, timeout=30)
        if result.returncode:
            cls.temp.cleanup()
            raise AssertionError(result.stdout.decode('utf-8-sig', errors='replace') + result.stderr.decode(errors='replace'))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def command(cls, *args):
        return ['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', str(FIXTURE),
                '-Runtime', str(RUNTIME), '-FixtureAssembly', str(cls.fixture_assembly), *args]

    def directory(self):
        path = self.base / self.id().rsplit('.', 1)[-1]
        path.mkdir()
        return path

    def run_case(self, name, directory=None):
        result = subprocess.run(self.command('-Case', name, '-Directory', str(directory or self.directory())), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8-sig', errors='replace') + result.stderr.decode(errors='replace'))
        data = json.loads(result.stdout.decode('utf-8-sig'))
        self.assertTrue(data['ok'], data)
        return data

    def test_numeric_versions_and_official_release_validation(self):
        self.run_case('versions')

    def test_receipt_identity_and_development_versions(self):
        self.run_case('receipt')

    def test_daily_throttle_failure_cache_and_manual_retry(self):
        self.run_case('throttle')

    def test_auto_preferences_rechecked_before_notification(self):
        self.run_case('preferences')

    def test_notification_marked_only_after_show_and_only_once(self):
        self.run_case('notification')

    def test_corrupt_state_requires_explicit_recovery(self):
        self.run_case('corrupt-state')

    def test_parent_exit_cancels_inflight_check_without_late_notification(self):
        self.run_case('parent-exit')

    def test_processes_coalesce_manual_network_check_and_notification(self):
        directory = self.directory()
        (directory / '.mpvnet-kit-install.json').write_text(json.dumps(dict(schema=1, owner='mpvnet-kit', kind='receipt',
            target=str(directory), packageVersion='0.5.0')), encoding='utf-8')
        first = subprocess.Popen(self.command('-Case', 'hold-check', '-Directory', str(directory)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = None
        try:
            deadline = time.monotonic() + 15
            while not (directory / 'entered').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((directory / 'entered').exists(), 'first process did not enter transport')
            second = subprocess.Popen(self.command('-Case', 'join-check', '-Directory', str(directory)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            # Hold the first network request while the separate PowerShell
            # process loads and joins the same named kernel mutex.
            time.sleep(1)
            (directory / 'release').write_text('1', encoding='ascii')
            for process in (first, second):
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0, stdout.decode(errors='replace') + stderr.decode(errors='replace'))
                self.assertEqual(json.loads(stdout.decode('utf-8-sig'))['status'], 'available')
            self.assertEqual((directory / 'network.log').read_text().splitlines(), ['fetch'])
            contenders = [subprocess.Popen(self.command('-Case', 'notify', '-Directory', str(directory)), stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
            shown = []
            for process in contenders:
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0, stdout.decode(errors='replace') + stderr.decode(errors='replace'))
                shown.append(json.loads(stdout.decode('utf-8-sig'))['shown'])
            self.assertEqual(sorted(shown), [False, True])
            self.assertEqual((directory / 'notifications.log').read_text().splitlines(), ['show'])
        finally:
            for process in (first, second):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)

    def test_no_show_wpf_new_release_content_and_focus_policy(self):
        data = self.run_case('window')
        self.assertEqual(data['heading'], '发现新版本 0.6.0')
        self.assertEqual(data['description'], '当前版本 0.5.0')
        self.assertEqual((data['primary'], data['close']), ('查看新版', '稍后'))
        for key in ('handle_created', 'has_shown', 'show_in_taskbar', 'topmost', 'show_activated', 'owner_attached'):
            self.assertFalse(data[key], key)

    def test_executable_request_validation_creates_no_window_or_state(self):
        directory = self.directory()
        request = directory / 'request.json'
        data = dict(schema=1, token='fixture', parent_pid=os.getpid(), config_directory=str(directory), automatic=True,
                    activation_path=str(request) + '.activate')
        def launch():
            request.write_text(json.dumps(data), encoding='utf-8')
            result = subprocess.run([str(RUNTIME), '-RequestPath', str(request), '-NoShow'], capture_output=True, timeout=15)
            return result.returncode, json.loads(result.stdout.decode('utf-8-sig'))
        code, result = launch()
        self.assertEqual(code, 0, result)
        self.assertFalse(result['handle_created'])
        self.assertFalse((directory / '.mpvnet-kit-update.json').exists())
        for field, invalid in (('schema', 2), ('token', ''), ('parent_pid', -1), ('automatic', 'true'),
                               ('activation_path', str(directory / 'unrelated')), ('config_directory', 'relative')):
            previous = data[field]
            data[field] = invalid
            code, result = launch()
            self.assertEqual(code, 1, (field, result))
            self.assertFalse(result['ok'])
            self.assertNotIn(str(directory), result['error'])
            data[field] = previous


if __name__ == '__main__':
    unittest.main()
