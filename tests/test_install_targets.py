"""Opt-in Windows directory/confirmation regressions using new external fixtures.

Set MPVNET_INSTALL_TARGET_ROOT to a NEW external directory. Evidence is retained.
No player, dependency executable, user configuration or historical fixture is run.
"""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
CASES = (
    'appdata-preview', 'home-priority', 'missing-home-portable',
    'explicit-direct-and-restore', 'auto-token-required', 'auto-apply',
    'source-switch', 'environment-switch', 'identity-switch', 'ancestor-switch',
    'target-appeared', 'package-changed', 'runtime-changed', 'user-state-excluded',
    'unsafe-candidates', 'unsafe-roots-overlap', 'junction', 'live-directory-lock', 'gui-stale-source',
    'gui-stale-ancestor', 'gui-preserve-and-failure',
)


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell and directory handles')
class InstallTargets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value = os.environ.get('MPVNET_INSTALL_TARGET_ROOT')
        if not value:
            raise unittest.SkipTest('Set MPVNET_INSTALL_TARGET_ROOT to a new external directory')
        cls.root = Path(value)
        if not cls.root.is_absolute():
            raise RuntimeError('Fixture root must be absolute')
        for p in (cls.root, *cls.root.parents):
            if p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()):
                raise RuntimeError('Fixture root must not traverse a link')
        cls.root = cls.root.resolve()
        worktrees = subprocess.check_output(['git', 'worktree', 'list', '--porcelain'],
                                            cwd=ROOT, encoding='utf-8')
        source_roots = [ROOT, *(Path(x[9:]).resolve() for x in worktrees.splitlines()
                               if x.startswith('worktree '))]
        if cls.root.exists() or any(p == cls.root or p in cls.root.parents for p in source_roots):
            raise RuntimeError('Fixture root must be new and outside source worktrees')
        cls.root.mkdir(parents=True, exist_ok=False)
        cls.ps = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'

    def run_case(self, case):
        result = subprocess.run([
            str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(ROOT / 'tests/fixtures/install_target_cases.ps1'),
            '-SourceRoot', str(ROOT), '-CaseRoot', str(self.root / case), '-Case', case,
        ], capture_output=True, timeout=60)
        (self.root / (case + '.stdout')).write_bytes(result.stdout)
        (self.root / (case + '.stderr')).write_bytes(result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        data = json.loads(result.stdout.decode('utf-8-sig'))
        self.assertTrue(data['passed'])
        self.assertFalse(data['playerLaunched'])

    def cli_fixture(self):
        case = self.root / self._testMethodName
        case.mkdir()
        player = case / 'player' / 'mpvnet.exe'
        player.parent.mkdir()
        player.write_text('Fixture only. Never execute.', encoding='utf-8')
        package = case / 'package'
        (package / 'config').mkdir(parents=True)
        payload = b'fixture=1\r\n'
        (package / 'config/mpv.conf').write_bytes(payload)
        (package / 'manifest.json').write_text(json.dumps({
            'schema': 1, 'version': 'fixture-cli', 'files': [
                {'path': 'config/mpv.conf', 'sha256': hashlib.sha256(payload).hexdigest()}],
        }), encoding='utf-8')
        target = case / 'home'
        target.mkdir()
        environment = dict(os.environ, MPVNET_HOME=str(target))
        return case, player, package, target, environment

    def invoke_cli(self, script, arguments, environment, case, expected=0):
        result = subprocess.run([str(self.ps), '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                 '-File', str(ROOT / 'tools' / script),
                                 *map(str, arguments)], env=environment, capture_output=True, timeout=60)
        evidence = case / ('call-%02d' % len(list(case.glob('call-*.stdout'))))
        evidence.with_suffix('.stdout').write_bytes(result.stdout)
        evidence.with_suffix('.stderr').write_bytes(result.stderr)
        self.assertEqual(result.returncode, expected, result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8-sig')

    def test_cli_json_text_and_restore(self):
        case, player, package, target, env = self.cli_fixture()
        args = ['-PlayerPath', player, '-PackageRoot', package, '-BackupRoot', case / 'backups']
        raw = self.invoke_cli('install.ps1', args, env, case)
        preview = json.loads(raw)
        self.assertEqual(preview['targetSource'], 'environment')
        text = self.invoke_cli('install.ps1', [*args, '-OutputFormat', 'Text'], env, case)
        self.assertIn('预览，尚未写入', text)
        self.assertIn(str(target), text)
        self.assertIn(preview['planToken'], text)
        self.assertNotIn('原 SHA256', text)
        detail = self.invoke_cli('install.ps1', [*args, '-OutputFormat', 'Text', '-Details'], env, case)
        self.assertIn('文件明细', detail)
        self.assertIn('mpv.conf', detail)
        self.assertEqual(json.loads(self.invoke_cli('install.ps1', [*args, '-Details'], env, case)), preview)
        installed = json.loads(self.invoke_cli('install.ps1', [*args, '-Apply', '-ExpectedPlanToken',
                                                                 preview['planToken']], env, case))
        self.assertEqual(installed['mode'], 'applied')
        restore_args = ['-BackupManifest', installed['backupManifest']]
        restored_text = self.invoke_cli('restore.ps1', [*restore_args, '-OutputFormat', 'Text', '-Details'], env, case)
        self.assertIn('恢复', restored_text)
        self.assertIn('mpv.conf', restored_text)
        result = json.loads(self.invoke_cli('restore.ps1', [*restore_args, '-Apply'], env, case))
        self.assertEqual(result['mode'], 'applied')
        self.assertFalse((target / 'mpv.conf').exists())

    def test_cli_missing_token_error_modes(self):
        case, player, package, target, env = self.cli_fixture()
        args = ['-PlayerPath', player, '-PackageRoot', package, '-BackupRoot', case / 'backups', '-Apply']
        failure = json.loads(self.invoke_cli('install.ps1', args, env, case, expected=1))
        self.assertEqual(failure['status'], 'refused-or-failed')
        text = self.invoke_cli('install.ps1', [*args, '-OutputFormat', 'Text'], env, case, expected=1)
        self.assertIn('原始错误', text)
        self.assertIn(failure['error'], text)
        self.assertEqual(list(target.iterdir()), [])
        self.assertFalse((case / 'backups').exists())

    def test_cli_dependency_target_and_text(self):
        case, player, package, target, env = self.cli_fixture()
        args = ['-PlayerPath', player, '-PackageRoot', package]
        check = json.loads(self.invoke_cli('check-dependencies.ps1', args, env, case))
        install = json.loads(self.invoke_cli('install.ps1', [*args, '-BackupRoot', case / 'backups'], env, case))
        self.assertEqual(check['configDirectory'], install['target'])
        self.assertEqual(check['targetSource'], install['targetSource'])
        text = self.invoke_cli('check-dependencies.ps1', [*args, '-OutputFormat', 'Text', '-Details'], env, case)
        self.assertIn('依赖检查（只读）', text)
        self.assertIn(str(target), text)
        self.assertIn('静态元数据', text)
        self.assertEqual(list(target.iterdir()), [])


for _case in CASES:
    setattr(InstallTargets, 'test_' + _case.replace('-', '_'),
            lambda self, case=_case: self.run_case(case))


if __name__ == '__main__':
    unittest.main()
