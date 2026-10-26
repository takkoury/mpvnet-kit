"""Opt-in isolated maintenance workflows; never launch or close a player.

MPVNET_MAINTENANCE_ROOT must be a new external directory, and
MPVNET_MAINTENANCE_PACKAGE a generated package. Player enumeration is replaced
inside each disposable test process, never by a public bypass switch.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

from support.install_fixtures import (create_fixture_root, checked_fixture_root, package_directory, powershell_path, load_release_files, run_recorded)

ROOT = Path(__file__).resolve().parents[1]
USER = b'{\r\n "schema":1,"future":{"keep":true},"shortcuts":{}\r\n}\r\n'


def read(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def files(root):
    if not root.exists():
        return {}
    return {p.relative_to(root).as_posix(): sha(p.read_bytes()) for p in root.rglob('*') if p.is_file()}


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell')
class Maintenance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = os.environ.get('MPVNET_MAINTENANCE_ROOT')
        package = os.environ.get('MPVNET_MAINTENANCE_PACKAGE')
        if not root and not package:
            raise unittest.SkipTest('Set MPVNET_MAINTENANCE_ROOT/PACKAGE')
        if not root or not package:
            raise RuntimeError('Both fixture root and package are required')
        cls.ps = powershell_path()
        cls.package = package_directory(package)
        checked_fixture_root(root, ROOT, packages=(cls.package,))
        release_repo = Path(os.environ.get('MPVNET_LEGACY_RELEASE_REPO', ROOT))
        release = next(r for r in read(cls.package / 'tools/legacy-releases.json')['releases'] if r['version'] == '0.2.0')
        cls.legacy = load_release_files(release_repo, release)
        cls.root = create_fixture_root(root, ROOT, packages=(cls.package,))
        cls.runner = cls.root / 'run-maintenance.ps1'
        cls.runner.write_text('''param([string]$PackageRoot,[string]$PlayerPath,[string]$Target,[string]$BackupRoot,
 [string]$Operation='Inspect',[string]$ExpectedPlanToken='', [string]$OutputFormat='Json',[switch]$Details,[switch]$Running)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'tools/maintenance.psm1')
& (Get-Module maintenance) {
 param($Running)
 $script:FixtureRunning=[bool]$Running
 Set-Item Function:script:Get-MaintenanceRunningPlayers {
  if ($script:FixtureRunning) { [pscustomobject]@{pid=1234;name='mpvnet'} }
 }
} ([bool]$Running)
$parameters=@{PlayerPath=$PlayerPath;ConfigDirectory=$Target;BackupRoot=$BackupRoot;PackageRoot=$PackageRoot;
 Operation=$Operation;ExpectedPlanToken=$ExpectedPlanToken;OutputFormat=$OutputFormat;Details=$Details}
& (Join-Path $PackageRoot 'tools/maintain.ps1') @parameters
exit $LASTEXITCODE
''', encoding='utf-8-sig')

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.case.mkdir()
        self.target = self.case / 'target'
        self.target.mkdir()
        self.backup = self.case / 'backups'
        self.player = self.case / 'mpvnet.exe'
        self.player.write_text('Not executable. Never launch.', encoding='utf-8')
        self.calls = 0
        self.env = dict(os.environ, MPVNET_HOME=str(self.target))

    def invoke(self, operation='Inspect', token='', package=None, expected=0, text=False, details=False, running=False):
        self.calls += 1
        args = [str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(self.runner),
                '-PackageRoot', str(package or self.package), '-PlayerPath', str(self.player),
                '-Target', str(self.target), '-BackupRoot', str(self.backup), '-Operation', operation,
                '-OutputFormat', 'Text' if text else 'Json']
        if token:
            args += ['-ExpectedPlanToken', token]
        if details:
            args += ['-Details']
        if running:
            args += ['-Running']
        p = self.case / ('call-%02d' % self.calls)
        result = run_recorded(args, p, env=self.env, timeout=90)
        self.assertEqual(result.returncode, expected, result.stderr.decode('utf-8', errors='replace'))
        output = result.stdout.decode('utf-8-sig')
        return output if text else json.loads(output)

    def user_state(self):
        (self.target / 'mpvnet-user.json').write_bytes(USER)
        (self.target / 'cache').mkdir()
        (self.target / 'cache/opaque').write_bytes(b'Never read user history')

    def install(self, package=None):
        plan = self.invoke(package=package)
        self.assertTrue(plan['eligible'])
        return self.invoke('Apply', plan['planToken'], package=package)

    def updated_package(self):
        package = self.case / 'new-package'
        shutil.copytree(self.package, package)
        config = package / 'config/mpv.conf'
        config.write_bytes(config.read_bytes() + b'\n# fixture update only\n')
        manifest = read(package / 'manifest.json')
        manifest['version'] = 'fixture-next'
        next(f for f in manifest['files'] if f['path'] == 'config/mpv.conf')['sha256'] = sha(config.read_bytes())
        (package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        return package

    def assert_blocked_unchanged(self, package=None, running=False):
        before = files(self.target), files(self.backup)
        p = self.invoke(package=package, running=running)
        self.assertEqual(p['action'], 'blocked')
        self.assertFalse(p['eligible'])
        self.invoke('Apply', p.get('planToken') or 'invalid', package=package, running=running, expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)
        return p

    def test_fresh_install_and_remove(self):
        self.user_state(); before = files(self.target)
        p = self.invoke()
        self.assertEqual(p['action'], 'install')
        self.assertFalse(self.backup.exists())
        result = self.invoke('Apply', p['planToken'])
        self.assertEqual(result['mode'], 'applied')
        receipt = read(self.target / '.mpvnet-kit-install.json')
        self.assertEqual(receipt['schema'], 1)
        self.assertEqual(receipt['kind'], 'receipt')
        current = self.invoke()
        self.assertEqual(current['action'], 'current')
        self.assertTrue(current['canRestore'])
        self.assertEqual(current['restoreKind'], 'remove-install')
        self.invoke('Restore', current['restorePlanToken'])
        self.assertEqual(files(self.target), before)

    def test_managed_update_and_restore_chain(self):
        self.user_state(); initial = files(self.target)
        self.install(); first = files(self.target)
        package = self.updated_package()
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'update')
        self.invoke('Apply', p['planToken'], package=package)
        self.assertNotEqual(files(self.target)['mpv.conf'], first['mpv.conf'])
        p = self.invoke(package=package)
        self.assertEqual(p['restoreKind'], 'restore-version')
        self.invoke('Restore', p['restorePlanToken'], package=package)
        self.assertEqual(files(self.target), first)
        p = self.invoke()
        self.invoke('Restore', p['restorePlanToken'])
        self.assertEqual(files(self.target), initial)

    def test_legacy_update_and_restore_without_fabricated_receipt(self):
        for name, data in self.legacy.items():
            path = self.target / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        (self.target / 'mpvnet-user.json').write_bytes(USER)
        (self.target / 'unknown.txt').write_bytes(b'keep unknown')
        before = files(self.target)
        p = self.invoke()
        self.assertEqual(p['action'], 'update')
        result = self.invoke('Apply', p['planToken'])
        self.assertEqual(read(Path(result['legacySnapshotManifest']))['kind'], 'legacy-snapshot')
        record = read(Path(result['backupManifest']))
        self.assertFalse(record['previousReceipt']['exists'])
        p = self.invoke()
        self.assertEqual(p['restoreKind'], 'restore-version')
        self.invoke('Restore', p['restorePlanToken'])
        self.assertEqual(files(self.target), before)

    def test_unknown_clean_target_refused(self):
        (self.target / 'unknown.txt').write_bytes(b'Keep me')
        self.assert_blocked_unchanged()

    def test_modified_managed_refused(self):
        self.install()
        (self.target / 'mpv.conf').write_bytes(b'User modified configuration')
        p = self.assert_blocked_unchanged()
        self.assertFalse(p['canRestore'])

    def test_modified_legacy_refused(self):
        for name, data in self.legacy.items():
            path = self.target / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        (self.target / 'mpv.conf').write_bytes(b'User modified legacy')
        self.assert_blocked_unchanged()

    def test_new_runtime_collision_refused(self):
        for name, data in self.legacy.items():
            path = self.target / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        path = self.target / 'helpers/shortcuts-window.ps1'
        path.write_bytes((self.package / 'config/helpers/shortcuts-window.ps1').read_bytes())
        self.assert_blocked_unchanged()

    def test_running_process_blocks_apply(self):
        plan = self.invoke()
        before = files(self.target), files(self.backup)
        blocked = self.invoke(running=True)
        self.assertEqual(blocked['action'], 'blocked')
        self.assertFalse(blocked['eligible'])
        self.invoke('Apply', plan['planToken'], running=True, expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_stale_plan_refused(self):
        plan = self.invoke()
        (self.target / 'mpv.conf').write_bytes(b'Appeared after preview')
        before = files(self.target), files(self.backup)
        self.invoke('Apply', plan['planToken'], expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_target_identity_replaced_refused(self):
        plan = self.invoke()
        self.target.rename(self.case / 'original-target'); self.target.mkdir()
        self.invoke('Apply', plan['planToken'], expected=1)
        self.assertFalse(self.backup.exists())
        self.assertEqual(files(self.target), {})

    def test_apply_requires_confirmation_even_explicit(self):
        self.invoke('Apply', expected=1)
        self.assertFalse(self.backup.exists())
        self.assertEqual(files(self.target), {})

    def test_restore_requires_its_own_token(self):
        plan = self.invoke(); self.invoke('Apply', plan['planToken'])
        before = files(self.target), files(self.backup)
        self.invoke('Restore', plan['planToken'], expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_private_state_change_does_not_become_managed(self):
        self.user_state(); self.install()
        (self.target / 'mpvnet-user.json').write_bytes(USER + b'\r\n')
        (self.target / 'unknown-new.txt').write_bytes(b'personal addition')
        p = self.invoke()
        self.assertEqual(p['action'], 'current')
        self.assertTrue(p['canRestore'])
        self.invoke('Restore', p['restorePlanToken'])
        self.assertEqual((self.target / 'mpvnet-user.json').read_bytes(), USER + b'\r\n')
        self.assertEqual((self.target / 'unknown-new.txt').read_bytes(), b'personal addition')

    def test_untrusted_pending_record_blocks(self):
        (self.target / '.mpvnet-kit-operation.json').write_bytes(b'{"target":"C:/not-authorized"}')
        self.assert_blocked_unchanged()

    def test_text_summary_and_details(self):
        text = self.invoke(text=True)
        self.assertIn(str(self.target), text)
        self.assertNotIn('refused-or-failed', text)
        detail = self.invoke(text=True, details=True)
        self.assertIn('mpv.conf', detail)
        self.assertFalse(self.backup.exists())

    def interrupt(self, operation, token, package=None, after_writes=1):
        runner = self.case / ('interrupt-' + operation + '.ps1')
        runner.write_text('''param([string]$PackageRoot,[string]$PlayerPath,[string]$Target,[string]$BackupRoot,
 [string]$Operation,[string]$ExpectedPlanToken,[int]$AfterWrites=1)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'tools/maintenance.psm1')
& (Get-Module maintenance) {
 param($AfterWrites)
 Set-Item Function:script:Get-MaintenanceRunningPlayers { @() }
 $script:FixtureOriginalWriter=(Get-Command Write-MaintenanceTargetFile).ScriptBlock
 $script:FixtureWrites=0; $script:FixtureAfterWrites=$AfterWrites
 Set-Item Function:script:Write-MaintenanceTargetFile {
  param($Path,$Bytes,$ExpectedHash)
  & $script:FixtureOriginalWriter $Path $Bytes $ExpectedHash
  $script:FixtureWrites++
  if ($script:FixtureWrites -eq $script:FixtureAfterWrites) { [Environment]::Exit(77) }
 }
} $AfterWrites
Invoke-KitMaintenance -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Operation $Operation -ExpectedPlanToken $ExpectedPlanToken | Out-Null
exit 98
''', encoding='utf-8-sig')
        result = subprocess.run([str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner),
            '-PackageRoot', str(package or self.package), '-PlayerPath', str(self.player), '-Target', str(self.target),
            '-BackupRoot', str(self.backup), '-Operation', operation, '-ExpectedPlanToken', token,
            '-AfterWrites', str(after_writes)], env=self.env, capture_output=True, timeout=90)
        (self.case / ('interrupt-' + operation + '.stdout')).write_bytes(result.stdout)
        (self.case / ('interrupt-' + operation + '.stderr')).write_bytes(result.stderr)
        self.assertEqual(result.returncode, 77, result.stderr.decode('utf-8', errors='replace'))
        self.assertTrue((self.target / '.mpvnet-kit-operation.json').exists())

    def test_interrupted_new_install_recovers(self):
        self.user_state(); before = files(self.target)
        p = self.invoke(); self.interrupt('Apply', p['planToken'])
        p = self.invoke()
        self.assertEqual(p['action'], 'recover')
        self.assertTrue(p['eligible'])
        self.invoke('Recover', p['planToken'])
        self.assertEqual(files(self.target), before)
        self.assertEqual(self.invoke()['action'], 'install')

    def test_interrupted_update_recovers_original_receipt(self):
        self.user_state(); self.install(); before = files(self.target)
        package = self.updated_package(); p = self.invoke(package=package)
        self.interrupt('Apply', p['planToken'], package=package)
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'recover')
        self.invoke('Recover', p['planToken'], package=package)
        self.assertEqual(files(self.target), before)
        self.assertTrue(self.invoke()['canRestore'])

    def test_interrupted_restore_recovers_to_pre_restore_version(self):
        self.user_state(); self.install()
        package = self.updated_package(); self.install(package)
        before = files(self.target)
        p = self.invoke(package=package)
        self.interrupt('Restore', p['restorePlanToken'], package=package)
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'recover')
        self.invoke('Recover', p['planToken'], package=package)
        self.assertEqual(files(self.target), before)
        p = self.invoke(package=package)
        self.assertTrue(p['canRestore'])
        self.invoke('Restore', p['restorePlanToken'], package=package)
        self.assertEqual((self.target / 'mpv.conf').read_bytes(), (self.package / 'config/mpv.conf').read_bytes())

    def test_recovery_itself_can_be_interrupted_and_retried(self):
        self.install(); before = files(self.target)
        package = self.updated_package(); p = self.invoke(package=package)
        self.interrupt('Apply', p['planToken'], package=package)
        p = self.invoke(package=package)
        self.interrupt('Recover', p['planToken'], package=package)
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'recover')
        self.invoke('Recover', p['planToken'], package=package)
        self.assertEqual(files(self.target), before)

    def test_recovery_refuses_unrelated_file_bytes(self):
        self.install()
        package = self.updated_package(); p = self.invoke(package=package)
        self.interrupt('Apply', p['planToken'], package=package)
        (self.target / 'mpv.conf').write_bytes(b'New user changes after interruption')
        before = files(self.target), files(self.backup)
        p = self.invoke(package=package)
        self.assertFalse(p['eligible'])
        self.invoke('Recover', p.get('planToken') or 'invalid', package=package, expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_document_only_package_is_current(self):
        self.install()
        package = self.case / 'docs-package'; shutil.copytree(self.package, package)
        path = package / 'README.md'; path.write_bytes(path.read_bytes() + b'\nFixture documentation edit.\n')
        manifest = read(package / 'manifest.json')
        next(f for f in manifest['files'] if f['path'] == 'README.md')['sha256'] = sha(path.read_bytes())
        (package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        before = files(self.target), files(self.backup)
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'current')
        self.assertEqual(p['changedFiles'], 0)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_forged_journal_cannot_claim_unknown_file(self):
        user = self.target / 'unknown-user-file.txt'
        user.write_bytes(b'Personal bytes; never part of an installation')
        record_id = 'a' * 32
        directory = self.backup / record_id; directory.mkdir(parents=True)
        journal = {'schema': 1, 'owner': 'mpvnet-kit', 'kind': 'maintenance-operation', 'id': record_id,
            'target': str(self.target), 'backupRoot': str(self.backup), 'operation': 'Apply',
            'files': [{'path': user.name, 'beforeExists': False, 'beforeSha256': None,
                       'afterExists': True, 'afterSha256': sha(user.read_bytes()), 'backup': None}],
            'receipt': {'beforeExists': False, 'beforeSha256': None, 'afterExists': False,
                        'afterSha256': None, 'backup': None}}
        raw = (json.dumps(journal) + '\n').encode('utf-8')
        (directory / 'operation.json').write_bytes(raw)
        (self.target / '.mpvnet-kit-operation.json').write_text(json.dumps({
            'schema': 1, 'owner': 'mpvnet-kit', 'kind': 'pending-operation', 'id': record_id,
            'target': str(self.target), 'backupRoot': str(self.backup), 'journalSha256': sha(raw),
        }), encoding='utf-8')
        before = files(self.target), files(self.backup)
        plan = self.invoke()
        self.assertFalse(plan['eligible'])
        self.invoke('Recover', plan.get('planToken') or 'invalid', expected=1)
        self.assertEqual((files(self.target), files(self.backup)), before)

    def test_recovery_uses_backup_when_package_metadata_changes(self):
        self.install(); before = files(self.target)
        package = self.updated_package(); p = self.invoke(package=package)
        self.interrupt('Apply', p['planToken'], package=package)
        path = package / 'README.md'; path.write_bytes(path.read_bytes() + b'\nNew documentation only.\n')
        manifest = read(package / 'manifest.json')
        next(f for f in manifest['files'] if f['path'] == 'README.md')['sha256'] = sha(path.read_bytes())
        (package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        p = self.invoke(package=package)
        self.assertEqual(p['action'], 'recover')
        self.assertTrue(p['eligible'])
        self.invoke('Recover', p['planToken'], package=package)
        self.assertEqual(files(self.target), before)

    def test_process_enumeration_failure_under_lock_refuses_write(self):
        runner = self.case / 'process-error.ps1'
        runner.write_text('''param([string]$PackageRoot,[string]$PlayerPath,[string]$Target,[string]$BackupRoot)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $PackageRoot 'tools/maintenance.psm1')
& (Get-Module maintenance) { Set-Item Function:script:Get-MaintenanceRunningPlayers { @() } }
$p=Get-KitMaintenancePlan -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot
& (Get-Module maintenance) {
 $script:FixtureCalls=0
 Set-Item Function:script:Get-MaintenanceRunningPlayers {
  $script:FixtureCalls++
  if ($script:FixtureCalls -eq 2) { throw 'Injected enumeration failure under lock' }
  @()
 }
}
$failure=''
try { Invoke-KitMaintenance -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Operation Apply -ExpectedPlanToken $p.planToken | Out-Null }
catch { $failure=$_.Exception.Message }
if (-not $failure) { throw 'Enumeration failure was ignored' }
[Console]::WriteLine((@{refused=$true;error=$failure} | ConvertTo-Json -Compress))
''', encoding='utf-8-sig')
        result = subprocess.run([str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner),
            '-PackageRoot', str(self.package), '-PlayerPath', str(self.player), '-Target', str(self.target),
            '-BackupRoot', str(self.backup)], capture_output=True, timeout=90)
        (self.case / 'process-error.stdout').write_bytes(result.stdout)
        (self.case / 'process-error.stderr').write_bytes(result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        self.assertTrue(json.loads(result.stdout.decode('utf-8-sig'))['refused'])
        self.assertEqual(files(self.target), {})
        self.assertFalse(self.backup.exists())

    def test_original_cli_record_and_restore_remain_compatible(self):
        self.user_state(); before = files(self.target)
        result = subprocess.run([str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(self.package / 'tools/install.ps1'), '-PlayerPath', str(self.player), '-ConfigDirectory', str(self.target),
            '-BackupRoot', str(self.backup), '-PackageRoot', str(self.package), '-Apply'], capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        p = self.invoke()
        self.assertEqual(p['action'], 'current')
        self.assertTrue(p['canRestore'])
        self.invoke('Restore', p['restorePlanToken'])
        self.assertEqual(files(self.target), before)
        result = self.install()
        restored = subprocess.run([str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(self.package / 'tools/restore.ps1'), '-BackupManifest', result['backupManifest'], '-Apply'],
            capture_output=True, timeout=60)
        self.assertEqual(restored.returncode, 0, restored.stderr.decode('utf-8', errors='replace'))
        self.assertEqual(files(self.target), before)

    def test_package_cannot_manage_pending_marker(self):
        package = self.case / 'invalid-package'; shutil.copytree(self.package, package)
        p = package / 'config/.mpvnet-kit-operation.json'; p.write_bytes(b'{}')
        manifest = read(package / 'manifest.json')
        manifest['files'].append({'path': 'config/.mpvnet-kit-operation.json', 'sha256': sha(p.read_bytes())})
        (package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        self.assert_blocked_unchanged(package=package)


if __name__ == '__main__':
    unittest.main()
