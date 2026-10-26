"""Shared helpers keep fixture ownership and Lua value types explicit."""
import hashlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from support import install_fixtures as fixtures
from support.lua_source import fragment, string_configuration, typed_configuration


class TestSupport(unittest.TestCase):
    def test_lua_configuration_modes_preserve_different_types(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'options.conf'
            path.write_text('# ignore\nboolean=yes\nnumber=1.25\nlabel=中文\n', encoding='utf-8')
            self.assertEqual(string_configuration(path),
                             'user_opts["boolean"] = "yes"\nuser_opts["number"] = "1.25"\nuser_opts["label"] = "中文"')
            self.assertEqual(typed_configuration(path),
                             'user_opts["boolean"] = true\nuser_opts["number"] = 1.25\nuser_opts["label"] = "中文"')
        self.assertEqual(fragment('prefix BEGINvalueEND tail', 'BEGIN', 'END'), 'BEGINvalue')
        with self.assertRaises(ValueError):
            fragment('BEGIN changed', 'BEGIN', 'END')

    def test_preflight_preserves_new_and_unique_directory_modes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'; source.mkdir()
            other = root / 'other-worktree'; other.mkdir()
            package = root / 'package'; package.mkdir()
            (package / 'manifest.json').write_text('{}', encoding='utf-8')
            with patch.object(fixtures, 'source_worktrees', return_value=[source, other]):
                for value in [source / 'output', other / 'output', package / 'output', root]:
                    with self.subTest(value=value), self.assertRaises(RuntimeError):
                        fixtures.checked_fixture_root(value, source, packages=(package,))
                new = root / 'new'
                self.assertEqual(fixtures.checked_fixture_root(new, source), new)
                self.assertFalse(new.exists())
                self.assertEqual(fixtures.create_fixture_root(new, source), new)
                store = root / 'store'; store.mkdir()
                first = fixtures.create_fixture_root(store, source, mode='unique')
                second = fixtures.create_fixture_root(store, source, mode='unique')
                self.assertNotEqual(first, second)
                self.assertEqual(first.parent, store)
                self.assertTrue(first.is_dir())

    def test_release_hashes_are_checked_before_use(self):
        data = b'fixture=1\n'; buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('config/mpv.conf', data)
        release = {'commit': 'fixed-commit', 'files': [{'path': 'mpv.conf', 'sha256': hashlib.sha256(data).hexdigest()}]}
        with patch.object(fixtures.subprocess, 'check_output', return_value=buffer.getvalue()):
            self.assertEqual(fixtures.load_release_files('repository', release), {'mpv.conf': data})
            release['files'][0]['sha256'] = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'Catalog'):
                fixtures.load_release_files('repository', release)

    def test_evidence_preserves_both_existing_filename_conventions(self):
        result = subprocess.CompletedProcess(['fixture'], 7, b'out', b'error')
        with tempfile.TemporaryDirectory() as temp, patch.object(fixtures.subprocess, 'run', return_value=result):
            prefix = Path(temp) / 'script.ps1'
            self.assertIs(fixtures.run_recorded(['fixture'], prefix), result)
            self.assertEqual((Path(temp) / 'script.stdout').read_bytes(), b'out')
            fixtures.run_recorded(['fixture'], prefix, append_suffix=True)
            self.assertEqual((Path(temp) / 'script.ps1.stderr').read_bytes(), b'error')
