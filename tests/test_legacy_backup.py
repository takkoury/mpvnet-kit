"""Opt-in M1-B checks against local release Git archives and a generated new package.

MPVNET_LEGACY_ROOT must be a new external directory; MPVNET_LEGACY_PACKAGE is
the new package. Optional MPVNET_LEGACY_RELEASE_REPO defaults to this repository.
All fixtures/evidence remain outside source worktrees. No player is executed.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
USER_BYTES = b'{\r\n "schema":1, "future":{"keep":[null,42]}, "shortcuts":{}\r\n}\r\n'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def snapshot(root):
    if not root.exists():
        return None
    return {p.relative_to(root).as_posix(): ('directory' if p.is_dir() else digest(p.read_bytes()))
            for p in root.rglob('*')}


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell')
class LegacyBackup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value, package = os.environ.get('MPVNET_LEGACY_ROOT'), os.environ.get('MPVNET_LEGACY_PACKAGE')
        if not value and not package:
            raise unittest.SkipTest('Set MPVNET_LEGACY_ROOT and MPVNET_LEGACY_PACKAGE')
        if not value or not package:
            raise RuntimeError('Both fixture root and generated package must be supplied')
        cls.root, cls.package = Path(value), Path(package)
        for path in (cls.root, cls.package):
            if not path.is_absolute():
                raise RuntimeError('Fixture/package paths must be absolute')
            for p in (path, *path.parents):
                if p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()):
                    raise RuntimeError('Fixture paths cannot traverse links')
        cls.root, cls.package = cls.root.resolve(), cls.package.resolve()
        trees = subprocess.check_output(['git', 'worktree', 'list', '--porcelain'], cwd=ROOT, encoding='utf-8')
        source_roots = [ROOT, *(Path(x[9:]).resolve() for x in trees.splitlines() if x.startswith('worktree '))]
        if cls.root.exists() or any(cls.root == p or p in cls.root.parents for p in source_roots):
            raise RuntimeError('Fixture root must be new and outside source worktrees')
        if cls.root == cls.package or cls.root in cls.package.parents or cls.package in cls.root.parents:
            raise RuntimeError('Package and fixture roots must be separate')
        cls.root.mkdir(parents=True, exist_ok=False)
        cls.release_repo = Path(os.environ.get('MPVNET_LEGACY_RELEASE_REPO', ROOT))
        cls.releases = {}
        catalog = read(cls.package / 'tools/legacy-releases.json')
        for release in catalog['releases']:
            archive = subprocess.check_output(['git', '-C', str(cls.release_repo), 'archive', '--format=zip', release['commit']])
            with zipfile.ZipFile(io.BytesIO(archive)) as z:
                cls.releases[release['version']] = {f['path']: z.read('config/' + f['path']) for f in release['files']}
            for f in release['files']:
                if digest(cls.releases[release['version']][f['path']]) != f['sha256']:
                    raise RuntimeError('Catalog is inconsistent with immutable release archive')
        cls.ps = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.case.mkdir()
        self.target = self.case / 'target'
        self.target.mkdir()
        self.backup = self.case / 'backups'
        self.player = self.case / 'mpvnet.exe'
        self.player.write_text('Not executable. Never launch.', encoding='utf-8')
        self.env = dict(os.environ, MPVNET_HOME=str(self.target))
        self.calls = 0

    def populate(self, version='0.2.0'):
        for name, data in self.releases[version].items():
            p = self.target / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        (self.target / 'mpvnet-user.json').write_bytes(USER_BYTES)
        (self.target / 'private-unknown.bin').write_bytes(b'Unmanaged private fixture; preserve only.')
        (self.target / 'script-opts/mpvnet-local.conf').write_bytes(b'# private fixture\r\n')
        (self.target / 'watch_later').mkdir(exist_ok=True)
        (self.target / 'watch_later/opaque').write_bytes(b'History fixture; must not enter snapshot')

    def invoke(self, script, args, expected=0, package=None):
        self.calls += 1
        command = [str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                   str((package or self.package) / 'tools' / script), *map(str, args)]
        result = subprocess.run(command, env=self.env, capture_output=True, timeout=60)
        prefix = self.case / ('call-%02d' % self.calls)
        prefix.with_suffix('.stdout').write_bytes(result.stdout)
        prefix.with_suffix('.stderr').write_bytes(result.stderr)
        self.assertEqual(result.returncode, expected, result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8-sig')

    def prepare(self, extra=(), expected=0, package=None):
        return self.invoke('prepare-legacy.ps1', ['-PlayerPath', self.player, '-ConfigDirectory', self.target,
            '-BackupRoot', self.backup, '-PackageRoot', package or self.package, *extra], expected, package)

    def assert_refused(self):
        before = snapshot(self.target), snapshot(self.backup)
        plan = json.loads(self.prepare())
        self.assertFalse(plan['eligible'])
        self.prepare(['-Apply', '-ExpectedPlanToken', plan.get('planToken') or 'invalid'], expected=1)
        self.assertEqual((snapshot(self.target), snapshot(self.backup)), before)
        return plan

    def assert_complete(self, version):
        self.populate(version)
        before = snapshot(self.target)
        plan = json.loads(self.prepare())
        self.assertTrue(plan['eligible'])
        self.assertEqual(plan['matchedRelease']['version'], version)
        self.assertEqual(snapshot(self.target), before)
        self.assertFalse(self.backup.exists())
        self.assertEqual(json.loads(self.prepare())['planToken'], plan['planToken'])
        applied = json.loads(self.prepare(['-Apply', '-ExpectedPlanToken', plan['planToken']]))
        self.assertEqual(applied['mode'], 'applied')
        manifest = Path(applied['backupManifest'])
        record = read(manifest)
        self.assertEqual(record['kind'], 'legacy-snapshot')
        self.assertNotIn('previousReceipt', record)
        self.assertFalse((self.target / '.mpvnet-kit-install.json').exists())
        self.assertEqual(len(record['files']), 31)
        for f in record['files']:
            self.assertNotIn('..', PurePosixPath(f['backup']).parts)
            self.assertEqual((manifest.parent / f['backup']).read_bytes(), self.releases[version][f['path']])
        self.assertEqual(snapshot(self.target), before)
        verified = json.loads(self.invoke('prepare-legacy.ps1', ['-SnapshotManifest', manifest]))
        self.assertEqual(verified['status'], 'verified')
        # This new baseline is not an invented receipt or an existing CLI rollback record.
        self.invoke('restore.ps1', ['-BackupManifest', manifest], expected=1)
        self.assertEqual(snapshot(self.target), before)
        return manifest

    def test_release_010(self):
        self.assert_complete('0.1.0')

    def test_release_011(self):
        self.assert_complete('0.1.1')

    def test_release_020(self):
        self.assert_complete('0.2.0')

    def test_modified_file(self):
        self.populate()
        p = self.target / 'mpv.conf'; p.write_bytes(p.read_bytes() + b'\r\n# user edit\r\n')
        self.assert_refused()

    def test_missing_file(self):
        self.populate()
        (self.target / 'mpv.conf').rename(self.case / 'preserved-mpv.conf')
        self.assert_refused()

    def test_mixed_release(self):
        self.populate()
        names = [n for n, b in self.releases['0.2.0'].items() if b != self.releases['0.1.0'][n]]
        self.assertGreater(len(names), 1)
        (self.target / names[0]).write_bytes(self.releases['0.1.0'][names[0]])
        self.assert_refused()

    def test_unknown_installation(self):
        (self.target / 'mpv.conf').write_bytes(b'Unknown custom installation')
        self.assert_refused()

    def test_new_path_same_bytes_collision(self):
        self.populate()
        files = read(self.package / 'manifest.json')['files']
        new = next(f['path'][7:] for f in files if f['path'].startswith('config/')
                   and not f['path'].endswith('.example') and f['path'][7:] not in self.releases['0.2.0'])
        target = self.target / new; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((self.package / 'config' / new).read_bytes())
        self.assert_refused()

    def test_receipt_occupied(self):
        self.populate()
        (self.target / '.mpvnet-kit-install.json').write_bytes(b'Not even valid JSON; never adopt it')
        self.assert_refused()

    def test_valid_receipt_chain_preserved(self):
        self.populate()
        installed = json.loads(self.invoke('install.ps1', ['-PlayerPath', self.player,
            '-ConfigDirectory', self.target, '-BackupRoot', self.case / 'existing-backups',
            '-PackageRoot', self.package, '-Apply']))
        receipt = (self.target / '.mpvnet-kit-install.json').read_bytes()
        existing_backup = snapshot(self.case / 'existing-backups')
        self.assert_refused()
        self.assertEqual((self.target / '.mpvnet-kit-install.json').read_bytes(), receipt)
        self.assertEqual(snapshot(self.case / 'existing-backups'), existing_backup)
        self.invoke('restore.ps1', ['-BackupManifest', installed['backupManifest'], '-Apply'])
        self.assertEqual((self.target / 'mpv.conf').read_bytes(), self.releases['0.2.0']['mpv.conf'])

    def test_apply_requires_token(self):
        self.populate()
        before = snapshot(self.target)
        self.prepare(['-Apply'], expected=1)
        self.assertFalse(self.backup.exists())
        self.assertEqual(snapshot(self.target), before)

    def test_target_replaced_after_preview(self):
        self.populate(); plan = json.loads(self.prepare())
        self.target.rename(self.case / 'original-target')
        shutil.copytree(self.case / 'original-target', self.target)
        before = snapshot(self.target)
        self.prepare(['-Apply', '-ExpectedPlanToken', plan['planToken']], expected=1)
        self.assertFalse(self.backup.exists())
        self.assertEqual(snapshot(self.target), before)

    def test_modified_after_preview(self):
        self.populate(); plan = json.loads(self.prepare())
        (self.target / 'mpv.conf').write_bytes(b'Concurrent edit')
        before = snapshot(self.target)
        self.prepare(['-Apply', '-ExpectedPlanToken', plan['planToken']], expected=1)
        self.assertFalse(self.backup.exists())
        self.assertEqual(snapshot(self.target), before)

    def test_snapshot_tampering(self):
        manifest = self.assert_complete('0.2.0')
        record = read(manifest)
        (manifest.parent / record['files'][0]['backup']).write_bytes(b'Tampered backup')
        self.invoke('prepare-legacy.ps1', ['-SnapshotManifest', manifest], expected=1)

    def test_incomplete_snapshot_refused(self):
        manifest = self.assert_complete('0.2.0')
        status_path = manifest.parent / 'status.json'
        status = read(status_path)
        status['state'] = 'prepared'
        status_path.write_text(json.dumps(status), encoding='utf-8')
        self.invoke('prepare-legacy.ps1', ['-SnapshotManifest', manifest], expected=1)

    def test_text_preview(self):
        self.populate()
        text = self.prepare(['-OutputFormat', 'Text'])
        self.assertIn('0.2.0', text)
        self.assertIn('31', text)
        self.assertIn(str(self.target), text)
        self.assertNotIn('原 SHA256', text)
        detailed = self.prepare(['-OutputFormat', 'Text', '-Details'])
        self.assertIn('mpv.conf', detailed)
        self.assertFalse(self.backup.exists())

    def altered_catalog(self, mutate, remove_from_manifest=False):
        package = self.case / 'changed-package'
        shutil.copytree(self.package, package)
        path = package / 'tools/legacy-releases.json'
        catalog = read(path)
        mutate(catalog)
        path.write_text(json.dumps(catalog), encoding='utf-8')
        manifest_path = package / 'manifest.json'
        manifest = read(manifest_path)
        if remove_from_manifest:
            manifest['files'] = [f for f in manifest['files'] if f['path'] != 'tools/legacy-releases.json']
        else:
            next(f for f in manifest['files'] if f['path'] == 'tools/legacy-releases.json')['sha256'] = digest(path.read_bytes())
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        return package

    def test_catalog_private_file_refused(self):
        self.populate()
        package = self.altered_catalog(lambda c: c['releases'][0]['files'][0].update(path='mpvnet-user.json'))
        self.prepare(expected=1, package=package)
        self.assertFalse(self.backup.exists())

    def test_catalog_escape_refused(self):
        self.populate()
        package = self.altered_catalog(lambda c: c['releases'][0]['files'][0].update(path='../outside'))
        self.prepare(expected=1, package=package)
        self.assertFalse(self.backup.exists())

    def test_catalog_must_be_manifest_managed(self):
        self.populate()
        package = self.altered_catalog(lambda c: None, remove_from_manifest=True)
        self.prepare(expected=1, package=package)
        self.assertFalse(self.backup.exists())

    def test_ambiguous_release_text_remains_a_blocked_preview(self):
        self.populate()
        package = self.altered_catalog(lambda c: c['releases'][0].update(files=c['releases'][2]['files']))
        plan = json.loads(self.prepare(package=package))
        self.assertFalse(plan['eligible'])
        self.assertEqual(plan['classification'], 'ambiguous')
        text = self.prepare(['-OutputFormat', 'Text'], package=package)
        self.assertIn('可准备备份：否', text)
        self.assertNotIn('未完成', text)
        self.assertFalse(self.backup.exists())

    def injected_backup_failure(self, change_source=False):
        self.populate()
        before = snapshot(self.target)
        runner = self.case / 'inject.ps1'
        runner.write_text('''param([string]$PackageRoot,[string]$PlayerPath,[string]$Target,[string]$BackupRoot,[switch]$ChangeSource)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $PackageRoot 'tools/legacy-install.psm1')
$p=Invoke-KitLegacyBackup -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot
& (Get-Module legacy-install) {
 param($Target,$ChangeSource)
 $script:FixtureOriginalWriter=(Get-Command Write-LegacySnapshotFile).ScriptBlock
 $script:FixtureWrites=0; $script:FixtureTarget=$Target; $script:FixtureChangeSource=$ChangeSource
 Set-Item Function:script:Write-LegacySnapshotFile {
  param($Path,$Bytes,$ExpectedHash)
  $script:FixtureWrites++
  if (-not $script:FixtureChangeSource -and $script:FixtureWrites -eq 2) { throw 'Injected copy failure' }
  & $script:FixtureOriginalWriter $Path $Bytes $ExpectedHash
  if ($script:FixtureChangeSource -and $script:FixtureWrites -eq 31) {
   [IO.File]::WriteAllText((Join-Path $script:FixtureTarget 'mpv.conf'),'Injected concurrent user edit')
  }
 }
} $Target ([bool]$ChangeSource)
$failure=''
try { Invoke-KitLegacyBackup -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Apply -ExpectedPlanToken $p.planToken | Out-Null }
catch { $failure=$_.Exception.Message }
if (-not $failure) { throw 'Expected injected failure' }
[Console]::WriteLine((@{failure=$failure} | ConvertTo-Json -Compress))
''', encoding='utf-8-sig')
        self.invoke(str(runner), ['-PackageRoot', self.package, '-PlayerPath', self.player,
            '-Target', self.target, '-BackupRoot', self.backup, *(['-ChangeSource'] if change_source else [])])
        manifests = list(self.backup.glob('*/manifest.json'))
        self.assertEqual(len(manifests), 1)
        self.assertEqual(read(manifests[0].parent / 'status.json')['state'], 'failed')
        self.invoke('prepare-legacy.ps1', ['-SnapshotManifest', manifests[0]], expected=1)
        if change_source:
            before['mpv.conf'] = digest(b'Injected concurrent user edit')
        self.assertEqual(snapshot(self.target), before)
        self.assertFalse((self.target / '.mpvnet-kit-install.json').exists())

    def test_copy_failure_retains_incomplete_snapshot(self):
        self.injected_backup_failure()

    def test_source_change_after_copy_refuses_completion(self):
        self.injected_backup_failure(change_source=True)

    def test_new_path_collision_does_not_read_content(self):
        self.populate()
        files = read(self.package / 'manifest.json')['files']
        name = next(f['path'][7:] for f in files if f['path'].startswith('config/')
                    and not f['path'].endswith('.example') and f['path'][7:] not in self.releases['0.2.0'])
        collision = self.target / name
        collision.parent.mkdir(parents=True, exist_ok=True)
        collision.write_bytes(b'Unknown data held exclusively; it must not be read')
        runner = self.case / 'locked-collision.ps1'
        runner.write_text('''param([string]$PackageRoot,[string]$PlayerPath,[string]$Target,[string]$BackupRoot,[string]$Collision)
$ErrorActionPreference='Stop'
$handle=[IO.File]::Open($Collision,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { & (Join-Path $PackageRoot 'tools/prepare-legacy.ps1') -PlayerPath $PlayerPath -ConfigDirectory $Target -BackupRoot $BackupRoot -PackageRoot $PackageRoot }
finally { $handle.Dispose() }
''', encoding='utf-8-sig')
        plan = json.loads(self.invoke(str(runner), ['-PackageRoot', self.package, '-PlayerPath', self.player,
            '-Target', self.target, '-BackupRoot', self.backup, '-Collision', collision]))
        self.assertFalse(plan['eligible'])
        self.assertTrue(any(c['path'] == name for c in plan['conflicts']))
        self.assertFalse(self.backup.exists())


if __name__ == '__main__':
    unittest.main()
