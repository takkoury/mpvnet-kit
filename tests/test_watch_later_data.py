"""Exercise watch-later record parsing and read-only Windows snapshots."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'config/script-modules/watch-later-data.lua'
STORE = ROOT / 'config/helpers/watch-later-store.ps1'


class WatchLaterData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.fixture = (ROOT / 'tests/lua/watch_later_data.lua').read_text(encoding='utf-8')
        cls.source = DATA.read_text(encoding='utf-8')

    def run_case(self, name):
        prelude, cases = self.fixture.split('-- DATA MODULE IS INSERTED HERE\n', 1)
        self.lua.execute(prelude + '\nlocal Data=(function()\n' + self.source + '\nend)()\n' +
                         cases + '\n' + name + '()', name='watch-later-data/' + name)

    def test_sorted_rows_keep_exact_path_and_saved_bytes(self):
        self.run_case('sorted_rows_keep_exact_path_and_saved_bytes')

    def test_invalid_entries_remain_distinct_from_redirect_and_empty(self):
        self.run_case('invalid_entries_remain_distinct_from_redirect_and_empty')

    def test_snapshot_recheck_uses_literal_leaf_and_extra_byte(self):
        self.run_case('snapshot_recheck_uses_literal_leaf_and_extra_byte')


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/.NET')
class WatchLaterStore(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mpvnet-watch-later-test-')
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name) / "[合成 '稍后']"
        self.folder.mkdir()

    def invoke(self, folder=None):
        args = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(STORE), '-Path', str(folder if folder is not None else self.folder)]
        result = subprocess.run(args, capture_output=True, timeout=20)
        self.assertEqual(result.stderr, b'', result.stderr.decode('utf-8', errors='replace'))
        self.assertEqual(result.returncode, 0)
        return json.loads(result.stdout.decode('utf-8'))

    def test_literal_directory_returns_exact_bytes_mtime_and_only_direct_files(self):
        content = '\ufeff# D:/合成/片段.mkv\r\nstart=12.000000\r\n'.encode('utf-8')
        redirect = b'# redirect entry'
        record = self.folder / '合成 [A]'
        record.write_bytes(content)
        (self.folder / 'R').write_bytes(redirect)
        timestamp = 1735732800.125
        os.utime(record, (timestamp, timestamp))
        subdirectory = self.folder / 'ignore'
        subdirectory.mkdir()
        (subdirectory / 'neighbor').write_bytes(b'untouched')
        reply = self.invoke()
        self.assertTrue(reply['ok'])
        files = {item['name']: item for item in reply['files']}
        self.assertEqual(set(files), {record.name, 'R'})
        self.assertEqual(files[record.name]['content'].encode('utf-8'), content)
        self.assertAlmostEqual(files[record.name]['mtime'], timestamp, places=5)
        self.assertEqual(files['R']['content'].encode('utf-8'), redirect)
        self.assertEqual(record.read_bytes(), content)
        self.assertEqual((self.folder / 'R').read_bytes(), redirect)
        self.assertEqual(set(self.folder.iterdir()), {record, self.folder / 'R', subdirectory})
        self.assertEqual((subdirectory / 'neighbor').read_bytes(), b'untouched')

    def test_missing_empty_and_directory_io_failure_are_distinct(self):
        self.assertEqual(self.invoke(self.folder / 'absent'), {'ok': True, 'missing': True})
        self.assertFalse((self.folder / 'absent').exists())
        self.assertEqual(self.invoke(), {'ok': True, 'files': [],
                                        'skipped': {'encoding': 0, 'io': 0, 'too_large': 0}})
        file_path = self.folder / 'not-a-directory'
        file_path.touch()
        self.assertEqual(self.invoke(file_path), {'ok': False, 'code': 'io'})

    def test_unreadable_invalid_and_oversized_files_keep_readable_neighbors(self):
        contents = {
            'LOCKED': b'# D:/locked.mkv\nstart=1\n',
            'INVALID': b'# D:/invalid\xff.mkv\n',
            'WITH-NUL': b'# D:/nul\x00.mkv\n',
            'LARGE': b'a' * (64 * 1024 + 1),
            'GOOD': b'# D:/good.mkv\nstart=2\n',
            'NO-PATH': b'start=3\n',
        }
        for name, content in contents.items():
            (self.folder / name).write_bytes(content)
        with (self.folder / 'LOCKED').open('r+b'):
            reply = self.invoke()
        self.assertTrue(reply['ok'])
        self.assertEqual(reply['skipped'], {'encoding': 2, 'io': 1, 'too_large': 1})
        self.assertEqual({row['name'] for row in reply['files']}, {'GOOD', 'NO-PATH'})
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, contents)

    def test_total_byte_limit_keeps_newer_complete_records(self):
        data = b'x' * (64 * 1024)
        for index in range(33):
            item = self.folder / f'{index:02}'
            item.write_bytes(data)
            timestamp = 1735732800 + index
            os.utime(item, (timestamp, timestamp))
        reply = self.invoke()
        self.assertTrue(reply['ok'])
        self.assertEqual(reply['skipped'], {'encoding': 0, 'io': 0, 'too_large': 1})
        self.assertEqual({row['name'] for row in reply['files']}, {f'{i:02}' for i in range(1, 33)})
        self.assertTrue(all(len(row['content']) == len(data) for row in reply['files']))

    def test_file_count_limit_reports_incomplete_scan(self):
        for index in range(2049):
            (self.folder / f'{index:04}').touch()
        self.assertEqual(self.invoke(), {'ok': False, 'code': 'too_many'})
