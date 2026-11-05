"""Regression coverage for history rows and the Windows history file boundary."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'config/script-modules/history-data.lua'
STORE = ROOT / 'config/helpers/history-store.ps1'


class HistoryData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.fixture = (ROOT / 'tests/lua/history_data.lua').read_text(encoding='utf-8')
        cls.source = DATA.read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, cases = self.fixture.split('-- DATA MODULE IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\nlocal Data=(function()\n' + self.source + '\nend)()\n' +
                         cases + '\n' + name + '()', name='history-data/' + name)

    def test_reverse_file_order_and_exact_path_deduplication(self):
        self.run_case('reverse_file_order_and_exact_path_deduplication')

    def test_invalid_lines_never_become_loadable_truncated_paths(self):
        self.run_case('invalid_lines_never_become_loadable_truncated_paths')

    def test_unsafe_date_options_use_default_and_missing_metadata_uses_basename(self):
        self.run_case('unsafe_date_options_use_default_and_missing_metadata_uses_basename')


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/.NET')
class HistoryStore(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mpvnet-history-test-')
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.history = self.folder / "[合成 '历史'].jsonl"
        self.original = ('\ufeff{"path":"D:/合成/片段.mkv","time":1735689600}\r\n'
                         '{"path":"https://example.invalid/file.mp4","time":1735689631}').encode('utf-8')
        self.history.write_bytes(self.original)

    def invoke(self, operation='Read', expected=None):
        args = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(STORE), '-Operation', operation, '-Path', str(self.history)]
        if expected is not None:
            args += ['-ExpectedHash', expected]
        completed = subprocess.run(args, capture_output=True, timeout=20)
        self.assertEqual(completed.stderr, b'', completed.stderr.decode('utf-8', errors='replace'))
        self.assertEqual(completed.returncode, 0)
        return json.loads(completed.stdout.decode('utf-8'))

    def test_read_exact_bytes_and_clear_preserves_file_and_neighbors(self):
        watch_later = self.folder / 'watch_later'
        watch_later.mkdir()
        progress = watch_later / 'SYNTHETIC'
        media = self.folder / '片段.mkv'
        progress.write_bytes(b'start=40\n')
        media.write_bytes(b'synthetic-media')
        snapshot = self.invoke()
        self.assertTrue(snapshot['ok'])
        self.assertEqual(snapshot['content'].encode('utf-8'), self.original)
        self.assertEqual(snapshot['hash'].lower(), hashlib.sha256(self.original).hexdigest())
        self.assertEqual(self.invoke('Clear', snapshot['hash']), {'ok': True})
        self.assertEqual(self.history.read_bytes(), b'')
        self.assertEqual(self.invoke(), {'ok': True, 'content': '', 'hash': hashlib.sha256(b'').hexdigest().upper()})
        self.assertEqual(progress.read_bytes(), b'start=40\n')
        self.assertEqual(media.read_bytes(), b'synthetic-media')
        self.assertEqual(set(self.folder.iterdir()), {watch_later, media, self.history})

    def test_appended_or_replaced_bytes_are_preserved_on_conflict(self):
        previous = self.invoke()['hash']
        for modified in (self.original + b'\r\n{}', self.original.replace(b'1735689600', b'1735689601')):
            with self.subTest(length=len(modified)):
                self.history.write_bytes(modified)
                self.assertEqual(self.invoke('Clear', previous), {'ok': False, 'code': 'conflict'})
                self.assertEqual(self.history.read_bytes(), modified)
        self.assertEqual(self.invoke('Clear', 'bad hash'), {'ok': False, 'code': 'conflict'})
        self.assertEqual(self.history.read_bytes(), modified)

    def test_read_and_clear_fail_safely_with_existing_writable_handle(self):
        previous = self.invoke()['hash']
        # A native writer's open handle prevents obtaining either snapshot lock.
        with self.history.open('r+b') as writer:
            self.assertEqual(self.invoke(), {'ok': False, 'code': 'io'})
            self.assertEqual(self.invoke('Clear', previous), {'ok': False, 'code': 'io'})
            self.assertEqual(writer.read(), self.original)

    def test_missing_history_is_distinct_and_never_created_by_clear(self):
        self.history.unlink()
        self.assertEqual(self.invoke(), {'ok': True, 'missing': True})
        self.assertEqual(self.invoke('Clear', hashlib.sha256(self.original).hexdigest()),
                         {'ok': False, 'code': 'conflict'})
        self.assertFalse(self.history.exists())

    def test_oversized_and_unreadable_content_is_never_returned_truncated(self):
        oversized = b'x' * (2 * 1024 * 1024 + 1)
        self.history.write_bytes(oversized)
        self.assertEqual(self.invoke(), {'ok': False, 'code': 'too_large'})
        self.assertEqual(self.invoke('Clear', hashlib.sha256(oversized).hexdigest()),
                         {'ok': False, 'code': 'too_large'})
        self.assertEqual(self.history.read_bytes(), oversized)
        for unreadable in (b'{\xff}', b'{}\x00{}'):
            self.history.write_bytes(unreadable)
            self.assertEqual(self.invoke(), {'ok': False, 'code': 'encoding'})
            self.assertEqual(self.history.read_bytes(), unreadable)
