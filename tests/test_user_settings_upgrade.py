"""Opt-in Windows installer checks; preserve all isolated targets and evidence.

Set MPVNET_USER_UPGRADE_ROOT to a new external directory and
MPVNET_USER_UPGRADE_OLD_PACKAGE / MPVNET_USER_UPGRADE_NEW_PACKAGE to packages.
The stub .exe is only an existence fixture and is never executed.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import unittest


from support.install_fixtures import (create_fixture_root, checked_fixture_root, package_directory, powershell_path, run_recorded)

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = '.mpvnet-kit-install.json'
USER_BYTES = (b'{\r\n  "schema" : 1, "shortcuts" : { "playback.pause" : ["Ctrl+p"],'
              b' "playlist.toggle" : [] },\r\n'
              b'  "settings" : { "mute" : false, "volume" : 0, "alang" : "",'
              b' "future" : { "disabled" : false, "zero" : 0, "empty" : "" } },\r\n'
              b'  "unknown" : { "future" : [null, 7] },'
              b' "rawformat" : "\\u4fdd\\u7559"\r\n}\r\n')
LOCAL_BYTES = ('# 私有路径与注释\r\nfuture_option = keep # 原文\n'
               'capture_root=D:\\旧输出\r\npython_path=C:/fixture/python.exe\n'
               '# tail without newline').encode('utf-8')


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def digest(data):
    return hashlib.sha256(data).hexdigest()


from support.install_fixtures import runtime_hashes as runtime


@unittest.skipUnless(os.name == 'nt', 'Uses the existing Windows PowerShell installer')
class UserSettingsUpgrade(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        names = ('MPVNET_USER_UPGRADE_ROOT', 'MPVNET_USER_UPGRADE_OLD_PACKAGE',
                 'MPVNET_USER_UPGRADE_NEW_PACKAGE')
        if not any(os.environ.get(name) for name in names):
            raise unittest.SkipTest('Set MPVNET_USER_UPGRADE_ROOT/OLD_PACKAGE/NEW_PACKAGE')
        if not all(os.environ.get(name) for name in names):
            raise RuntimeError('All three MPVNET_USER_UPGRADE variables are required')
        cls.ps = powershell_path()
        cls.old = package_directory(os.environ[names[1]])
        cls.new = package_directory(os.environ[names[2]])
        cls.root = checked_fixture_root(os.environ[names[0]], ROOT, packages=(cls.old, cls.new))
        cls.old_runtime, cls.new_runtime = runtime(cls.old), runtime(cls.new)
        if not cls.old_runtime or not set(cls.old_runtime) < set(cls.new_runtime):
            raise RuntimeError('Expected an additive upgrade with existing runtime preserved')
        if {'mpvnet-user.json', 'script-opts/mpvnet-local.conf'} & set(cls.new_runtime):
            raise RuntimeError('New package must not manage user settings or local paths')
        cls.root = create_fixture_root(cls.root, ROOT, packages=(cls.old, cls.new))
        cls.player = cls.root / 'player-stub.exe'
        cls.player.write_bytes(b'Not executable: installer path validation fixture only.\r\n')

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.case.mkdir()
        self.target, self.backup = self.case / 'target', self.case / 'backups'
        self.calls, self.checks = 0, []
        if self._testMethodName == 'test_clean_install_preserves_user_json_and_refuses_unknown':
            return
        # Establish the old receipt using the old package's own installer.
        installed = self.install(self.old, apply=True, tool_package=self.old)
        self.assertEqual(installed['mode'], 'applied')
        self.assertEqual(installed['runtimeFiles'], len(self.old_runtime))
        self.old_manifest = Path(installed['backupManifest'])
        self.old_receipt = (self.target / RECEIPT).read_bytes()
        (self.target / 'mpvnet-user.json').write_bytes(USER_BYTES)
        (self.target / 'script-opts/mpvnet-local.conf').write_bytes(LOCAL_BYTES)
        self.unknown = self.target / 'unknown-user-file.txt'
        self.unknown.write_bytes(b'Preserve this unmanaged file.\r\n')
        self.initial = self.snapshot(self.target)

    def tearDown(self):
        (self.case / 'checks.json').write_text(json.dumps({
            'old_runtime_count': len(self.old_runtime), 'new_runtime_count': len(self.new_runtime),
            'completed_checks': self.checks, 'calls': self.calls,
            'user_sha256': digest(USER_BYTES), 'local_sha256': digest(LOCAL_BYTES),
            'player_launched': False,
        }, indent=2) + '\n', encoding='utf-8')

    @staticmethod
    def snapshot(root):
        return {p.relative_to(root).as_posix(): digest(p.read_bytes())
                for p in root.rglob('*') if p.is_file()}

    def invoke(self, script, arguments, failure=None, tool_package=None):
        command = [str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                   str((tool_package or self.new) / 'tools' / script), *map(str, arguments)]
        self.calls += 1
        prefix = self.case / ('%02d-%s' % (self.calls, Path(script).name))
        result = run_recorded(command, prefix, timeout=60)
        parsed = json.loads(result.stdout.decode('utf-8-sig'))
        prefix.with_suffix('.json').write_text(json.dumps({
            'command': command, 'exit_code': result.returncode, 'result': parsed,
        }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if failure:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(parsed['status'], 'refused-or-failed')
            self.assertIn(failure, parsed['error'])
        else:
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
            self.assertNotEqual(parsed.get('status'), 'refused-or-failed')
        return parsed

    def install(self, package, apply=False, failure=None, tool_package=None):
        return self.invoke('install.ps1', ['-PlayerPath', self.player, '-ConfigDirectory', self.target,
                           '-BackupRoot', self.backup, '-PackageRoot', package,
                           *(['-Apply'] if apply else [])], failure, tool_package)

    def assert_user_preserved(self, user=USER_BYTES, local=LOCAL_BYTES):
        self.assertEqual((self.target / 'mpvnet-user.json').read_bytes(), user)
        self.assertEqual((self.target / 'script-opts/mpvnet-local.conf').read_bytes(), local)
        self.assertEqual(self.unknown.read_bytes(), b'Preserve this unmanaged file.\r\n')
        managed = {f['path'] for f in read(self.target / RECEIPT)['files']}
        self.assertFalse({'mpvnet-user.json', 'script-opts/mpvnet-local.conf'} & managed)

    def save_preferences(self, operation='Save', **changes):
        target = self.target / ('script-opts/mpvnet-local.conf' if operation == 'SaveLocal'
                                else 'mpvnet-user.json')
        request = {'schema': 1, 'settings_path': str(target),
                   'expected_exists': target.exists(),
                   'expected_text': target.read_bytes().decode('utf-8'),
                   'return_written_text': True, **changes}
        # The real helper accepts request files only below the OS temporary root.
        with tempfile.TemporaryDirectory(prefix='mpvnet-upgrade-save-') as folder:
            path = Path(folder) / 'request.json'
            path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
            result = self.invoke(str(self.new / 'config/helpers/settings-storage.ps1'),
                                 ['-Operation', operation, '-RequestPath', path])
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['conflict'], result)
        self.assertEqual(result['written_text'].encode('utf-8'), target.read_bytes())
        return target.read_bytes()

    def assert_runtime(self, expected):
        receipt = {f['path']: f['sha256'] for f in read(self.target / RECEIPT)['files']}
        self.assertEqual(receipt, expected)
        for name, sha in expected.items():
            self.assertEqual(digest((self.target / name).read_bytes()), sha, name)

    def assert_refused_without_changes(self, package, error):
        before = self.snapshot(self.target), self.snapshot(self.backup)
        self.install(package, apply=True, failure=error)
        self.assertEqual((self.snapshot(self.target), self.snapshot(self.backup)), before)
        self.assert_user_preserved()

    def test_upgrade_and_restore_preserve_raw_user_json(self):
        before = self.snapshot(self.target), self.snapshot(self.backup)
        preview = self.install(self.new)
        self.assertEqual(preview['mode'], 'preview')
        self.assertEqual(preview['runtimeFiles'], len(self.new_runtime))
        self.assertEqual((self.snapshot(self.target), self.snapshot(self.backup)), before)
        self.assert_user_preserved()
        self.checks.append('upgrade preview leaves target and backup bytes unchanged')
        applied = self.install(self.new, apply=True)
        self.assertEqual(applied['mode'], 'applied')
        self.assert_runtime(self.new_runtime)
        self.assert_user_preserved()
        record = Path(applied['backupManifest'])
        self.assertEqual((record.parent / 'previous-receipt.json').read_bytes(), self.old_receipt)
        self.assertFalse({'mpvnet-user.json', 'script-opts/mpvnet-local.conf'} &
                         {f['path'] for f in read(record)['files']})
        self.checks.append('upgrade installs expected runtime and leaves raw user JSON unmanaged')
        before = self.snapshot(self.target), self.snapshot(self.backup)
        preview = self.invoke('restore.ps1', ['-BackupManifest', record])
        self.assertEqual(preview['mode'], 'preview')
        self.assertEqual((self.snapshot(self.target), self.snapshot(self.backup)), before)
        self.assert_user_preserved()
        self.checks.append('restore preview leaves target and backup bytes unchanged')
        restored = self.invoke('restore.ps1', ['-BackupManifest', record, '-Apply'])
        self.assertEqual(restored['mode'], 'applied')
        self.assert_runtime(self.old_runtime)
        self.assertEqual((self.target / RECEIPT).read_bytes(), self.old_receipt)
        self.assertEqual(self.snapshot(self.target), self.initial)
        self.assert_user_preserved()
        self.checks.append('restore returns exact original runtime, receipt and unmanaged bytes')

    def test_saved_settings_shortcuts_and_local_paths_survive_restore(self):
        applied = self.install(self.new, apply=True)
        record = Path(applied['backupManifest'])
        self.assert_runtime(self.new_runtime)
        self.assert_user_preserved()
        settings_text = USER_BYTES.decode('utf-8').replace('"volume" : 0', '"volume" : 17')
        saved = self.save_preferences(document_text=settings_text)
        self.assertEqual(saved, settings_text.encode('utf-8'))
        shortcuts_text = settings_text.replace('"Ctrl+p"', '"Ctrl+Alt+p"')
        saved = self.save_preferences(document_text=shortcuts_text)
        self.assertEqual(saved, shortcuts_text.encode('utf-8'))
        local = self.save_preferences('SaveLocal', values={'capture_root': 'D:\\新输出',
                                    'python_path': 'C:/fixture/python.exe'})
        self.assertEqual(local, LOCAL_BYTES.decode('utf-8').replace('D:\\旧输出', 'D:\\新输出').encode('utf-8'))
        self.assert_user_preserved(saved, local)
        self.assertEqual(read(self.target / 'mpvnet-user.json')['settings']['mute'], False)
        self.assertEqual(read(self.target / 'mpvnet-user.json')['settings']['alang'], '')
        self.assertEqual(read(self.target / 'mpvnet-user.json')['settings']['future'],
                         {'disabled': False, 'zero': 0, 'empty': ''})
        self.checks.append('packaged real helper saves settings then shortcuts and patches only changed local path')
        before = self.snapshot(self.target), self.snapshot(self.backup)
        preview = self.invoke('restore.ps1', ['-BackupManifest', record])
        self.assertEqual(preview['mode'], 'preview')
        self.assertEqual((self.snapshot(self.target), self.snapshot(self.backup)), before)
        self.assert_user_preserved(saved, local)
        self.checks.append('declining restore after preview leaves all saved personal bytes unchanged')
        restored = self.invoke('restore.ps1', ['-BackupManifest', record, '-Apply'])
        self.assertEqual(restored['mode'], 'applied')
        self.assert_runtime(self.old_runtime)
        self.assertEqual((self.target / RECEIPT).read_bytes(), self.old_receipt)
        self.assert_user_preserved(saved, local)
        expected = dict(self.initial, **{'mpvnet-user.json': digest(saved),
                                       'script-opts/mpvnet-local.conf': digest(local)})
        self.assertEqual(self.snapshot(self.target), expected)
        self.checks.append('restore reinstates exact v0.3 runtime and receipt while retaining later personal saves')

    def test_restore_refuses_modified_runtime_without_touching_user_files(self):
        applied = self.install(self.new, apply=True)
        path = self.target / sorted(self.new_runtime)[0]
        path.write_bytes(path.read_bytes() + b'\r\n# edit after upgrade\r\n')
        before = self.snapshot(self.target), self.snapshot(self.backup)
        self.invoke('restore.ps1', ['-BackupManifest', applied['backupManifest'], '-Apply'],
                    failure='Managed file modified or deleted')
        self.assertEqual((self.snapshot(self.target), self.snapshot(self.backup)), before)
        self.assert_user_preserved()
        self.checks.append('restore refuses modified managed bytes and preserves target, backups and personal files')

    def test_identical_new_runtime_collision_is_refused(self):
        name = sorted(set(self.new_runtime) - set(self.old_runtime))[0]
        path = self.target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((self.new / 'config' / name).read_bytes())
        self.assert_refused_without_changes(self.new, 'Unknown file occupies a new runtime path')
        self.checks.append('same-hash unknown collision refused with target and backups unchanged')

    def test_modified_old_runtime_is_refused(self):
        path = self.target / sorted(self.old_runtime)[0]
        path.write_bytes(path.read_bytes() + b'\r\n# external fixture edit\r\n')
        self.assert_refused_without_changes(self.new, 'Managed file modified or deleted')
        self.checks.append('external managed edit refused with target and backups unchanged')

    def test_user_json_only_package_is_refused(self):
        package = self.case / 'forged-package'
        (package / 'config').mkdir(parents=True)
        (package / 'config/mpvnet-user.json').write_bytes(USER_BYTES)
        (package / 'manifest.json').write_text(json.dumps({
            'schema': 1, 'version': 'fixture', 'files': [
                {'path': 'config/mpvnet-user.json', 'sha256': digest(USER_BYTES)}],
        }) + '\n', encoding='utf-8')
        self.assert_refused_without_changes(package, 'Private or state files cannot be package runtime files')
        self.checks.append('user JSON-only package refused with target and backups unchanged')

    def test_clean_install_preserves_user_json_and_refuses_unknown(self):
        player = self.case / 'mpvnet.exe'
        player.write_bytes(self.player.read_bytes())
        runner = self.case / 'clean-fixture.ps1'
        runner.write_text('''param([string]$ModulePath, [string]$PlayerPath, [string]$PackageRoot,
    [string]$Target, [switch]$Apply)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
try {
    $env:MPVNET_HOME = $Target
    Import-Module $ModulePath -Force
    $plan = Get-CleanInstallPlan -PlayerPath $PlayerPath -PackageRoot $PackageRoot
    if ($plan.target -ine $Target) { throw 'Fixture target mismatch' }
    $result = [ordered]@{ mode = 'preview'; target = $plan.target;
        retainedFiles = $plan.baseline.retainedFiles;
        userEntry = $plan.baseline.entries['mpvnet-user.json']; files = $plan.files.Count }
    if ($Apply) {
        $installed = Invoke-CleanInstall -Plan $plan
        $result.mode = 'applied'; $result.files = $installed.files
    }
    [Console]::WriteLine(($result | ConvertTo-Json -Depth 5))
} catch {
    [Console]::WriteLine((@{ status = 'refused-or-failed'; error = $_.Exception.Message } | ConvertTo-Json))
    exit 1
}
''', encoding='utf-8-sig')
        self.target.mkdir()
        (self.target / 'mpvnet-user.json').write_bytes(USER_BYTES)
        arguments = ['-ModulePath', self.new / 'tools/clean-install.psm1', '-PlayerPath', player,
                     '-PackageRoot', self.new, '-Target', self.target]
        before = self.snapshot(self.target)
        preview = self.invoke(str(runner), arguments)
        self.assertEqual(preview['userEntry'], 'state-file')
        self.assertEqual(preview['retainedFiles'], 1)
        self.assertEqual(self.snapshot(self.target), before)
        applied = self.invoke(str(runner), [*arguments, '-Apply'])
        self.assertEqual(applied['mode'], 'applied')
        self.assertEqual(applied['files'], len(self.new_runtime))
        self.assertEqual((self.target / 'mpvnet-user.json').read_bytes(), USER_BYTES)
        self.assertEqual(self.snapshot(self.target), dict(self.new_runtime, **{'mpvnet-user.json': digest(USER_BYTES)}))
        self.checks.append('clean plan recognizes user state and clean install preserves its raw bytes')
        unknown_target = self.case / 'unknown-target'
        unknown_target.mkdir()
        (unknown_target / 'mpvnet-user.json').write_bytes(USER_BYTES)
        (unknown_target / 'unknown-user-file.txt').write_bytes(b'Unknown fixture must be refused')
        before = self.snapshot(unknown_target)
        arguments[-1] = unknown_target
        self.invoke(str(runner), [*arguments, '-Apply'], failure='unknown-user-file.txt')
        self.assertEqual(self.snapshot(unknown_target), before)
        self.checks.append('clean installer still refuses unknown files without modifying either file')


if __name__ == '__main__':
    unittest.main()
