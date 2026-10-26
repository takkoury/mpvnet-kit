"""The runner must not turn missing coverage into success."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from support import dev_imports  # Set up ordinary imports from dev-tools.
import test_runner as runner


class RunnerContract(unittest.TestCase):
    def test_registry_covers_discovery_once(self):
        tests = runner.inventory()
        self.assertEqual(len(tests), len({test.id() for test in tests}))
        self.assertGreater(len(tests), 290)
        with patch.dict(runner.PROFILES, {'core': runner.PROFILES['core'] + (runner.PROFILES['lua'][0],)}):
            with self.assertRaisesRegex(RuntimeError, '重复归组'):
                runner.inventory()

    def test_missing_dependency_prevents_all_selected_groups(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runner, 'run') as execute:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runner.main(['--profile', 'core', '--profile', 'lua']), 2)
            execute.assert_not_called()

    def test_missing_install_package_does_not_create_fixture_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'must-stay-absent'
            with patch.dict(os.environ, {'MPVNET_INSTALL_TARGET_ROOT': str(root)}, clear=True), \
                 patch.object(runner, 'powershell_path', return_value=Path('powershell.exe')), \
                 patch.object(runner.shutil, 'which', return_value='git'), \
                 patch('support.install_fixtures.source_worktrees', return_value=[runner.ROOT]):
                with self.assertRaisesRegex(RuntimeError, 'MPVNET_LEGACY_PACKAGE'):
                    runner.preflight(['install'])
            self.assertFalse(root.exists())

    def test_listing_never_runs_or_prepares_fixtures(self):
        with patch.object(runner, 'preflight') as preflight, patch.object(runner, 'run') as execute:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner.main(['--list']), 0)
            preflight.assert_not_called(); execute.assert_not_called()

    def test_selected_groups_cannot_write_inside_any_input_package(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            package = root / 'package'; package.mkdir()
            (package / 'manifest.json').write_text(json.dumps({'files': []}), encoding='utf-8')
            env = {name: str(package) for name in (
                'MPVNET_LEGACY_PACKAGE', 'MPVNET_MAINTENANCE_PACKAGE',
                'MPVNET_USER_UPGRADE_OLD_PACKAGE', 'MPVNET_USER_UPGRADE_NEW_PACKAGE')}
            names = ('MPVNET_INSTALL_TARGET_ROOT', 'MPVNET_LEGACY_ROOT',
                     'MPVNET_MAINTENANCE_ROOT', 'MPVNET_USER_UPGRADE_ROOT')
            env.update({name: str(root / name) for name in names})
            env['MPVNET_TEST_PLAYLIST_ARTIFACTS'] = str(root / 'helpers')
            with patch.object(runner, 'powershell_path'), patch.object(runner.shutil, 'which', return_value='available'), \
                 patch('support.install_fixtures.source_worktrees', return_value=[runner.ROOT]):
                for name in (*names, 'MPVNET_TEST_PLAYLIST_ARTIFACTS'):
                    with self.subTest(name=name), patch.dict(os.environ, dict(env, **{name: str(package / 'output')}), clear=True):
                        with self.assertRaisesRegex(RuntimeError, 'separate'):
                            runner.preflight(['helpers', 'install'])
                        self.assertFalse((package / 'output').exists())
                nested = str(root / names[0] / 'helpers')
                with patch.dict(os.environ, dict(env, MPVNET_TEST_PLAYLIST_ARTIFACTS=nested), clear=True):
                    with self.assertRaisesRegex(RuntimeError, 'helpers'):
                        runner.preflight(['helpers', 'install'])
                self.assertTrue(all(not Path(env[name]).exists() for name in names))

    def test_helpers_requires_the_powershell_resolution_its_tests_use(self):
        with patch.object(runner, 'powershell_path'), patch.object(runner.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'Git'):
                runner.preflight(['helpers'])
        with patch.object(runner, 'powershell_path'), \
             patch.object(runner.shutil, 'which', side_effect=lambda name: 'git' if name == 'git' else None):
            with self.assertRaisesRegex(RuntimeError, 'PATH'):
                runner.preflight(['helpers'])

    def test_only_unconfigured_optional_tests_may_skip(self):
        test = unittest.FunctionTestCase(lambda: None)
        optional = next(iter(runner.OPTIONAL_SKIPS))
        result = unittest.TestResult()
        with patch.object(test, 'id', return_value=optional), patch.dict(os.environ, {}, clear=True):
            result.addSkip(test, 'optional input absent')
            self.assertEqual(runner.unexpected_skips(result), [])
            with patch.dict(os.environ, {runner.OPTIONAL_SKIPS[optional]: 'configured'}):
                self.assertEqual(len(runner.unexpected_skips(result)), 1)
        with patch.object(test, 'id', return_value='unregistered.skip'):
            self.assertEqual(len(runner.unexpected_skips(result)), 1)

    def test_unexpected_skip_changes_exit_code(self):
        class Skipped(unittest.TestCase):
            def runTest(self):
                self.skipTest('unexpected')
        name = Skipped.__module__ + '.' + Skipped.__name__
        with patch.dict(runner.PROFILES, {'fixture': (name,)}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.run(['fixture'], [Skipped()], stream=io.StringIO()), 1)
