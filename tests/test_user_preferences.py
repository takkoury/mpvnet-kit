"""Run the real atomic writer against disposable settings, never personal config."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'config/helpers/shortcuts-window.ps1'


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/.NET')
class UserPreferences(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mpvnet-preferences-test-')
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.settings = self.folder / 'mpvnet-user.json'

    def command(self, document=None, **changes):
        request = {'schema': 1, 'settings_path': str(self.settings),
                   'expected_exists': self.settings.exists(),
                   'expected_text': self.settings.read_bytes().decode('utf-8', errors='replace') if self.settings.exists() else '',
                   'document_text': json.dumps(document if document is not None else {'schema': 1, 'shortcuts': {}},
                                               ensure_ascii=False)}
        request.update(changes)
        path = self.folder / ('request-' + uuid.uuid4().hex + '.json')
        path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        return ['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', str(HELPER), '-Operation', 'Save', '-RequestPath', str(path)]

    def result(self, completed):
        self.assertEqual(completed.stderr, b'', completed.stderr.decode('utf-8', errors='replace'))
        output = completed.stdout.decode('utf-8-sig')
        self.assertEqual(len(output.strip().splitlines()), 1, output)
        result = json.loads(output)
        self.assertEqual(set(result), {'ok', 'error', 'conflict'})
        self.assertEqual(completed.returncode == 0, result['ok'], result)
        return result

    def save(self, document=None, **changes):
        return self.result(subprocess.run(self.command(document, **changes), capture_output=True, timeout=30))

    def assert_preserved(self, before, result):
        self.assertFalse(result['ok'], result)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(list(self.folder.glob('.mpvnet-user-*.tmp')), [])

    def test_atomic_create_replace_and_fresh_process_read(self):
        first = {'schema': 1, 'shortcuts': {'pause': ['Space']}, 'unknown': {'nothing': None, 'object': {}, 'array': []},
                 'large_integer': 9007199254740993, '中文': '完整保留', 'date_string': '/Date(0+0800)/'}
        self.assertTrue(self.save(first)['ok'])
        self.assertEqual(json.loads(self.settings.read_text(encoding='utf-8')), first)
        second = dict(first, shortcuts={'pause': [], 'open': ['Ctrl+o']})
        self.assertTrue(self.save(second)['ok'])
        self.assertEqual(json.loads(self.settings.read_text(encoding='utf-8')), second)
        self.assertFalse(self.settings.read_bytes().startswith(b'\xef\xbb\xbf'))
        self.assertEqual(list(self.folder.glob('.mpvnet-user-*.tmp')), [])

    def test_two_writers_compare_original_under_same_mutex(self):
        initial = {'schema': 1, 'shortcuts': {}}
        self.settings.write_text(json.dumps(initial), encoding='utf-8')
        commands = [self.command({'schema': 1, 'shortcuts': {'pause': [key]}}) for key in ['p', 'Space']]
        children = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for command in commands]
        results = []
        for child in children:
            out, err = child.communicate(timeout=30)
            results.append(self.result(subprocess.CompletedProcess(child.args, child.returncode, out, err)))
        self.assertEqual(sum(result['ok'] for result in results), 1, results)
        self.assertEqual(sum(result['conflict'] for result in results), 1, results)
        self.assertIn(json.loads(self.settings.read_text(encoding='utf-8'))['shortcuts']['pause'], [['p'], ['Space']])

    def test_document_text_preserves_exact_unknown_numbers_strings_and_formatting(self):
        document_text = ('{\r\n  "schema": 1, "shortcuts": {"pause": ["p"]},\r\n'
                         '  "huge_integer": 123456789012345678901234567890123456789012345678901234567890,\r\n'
                         '  "precise_decimal": 0.12345678901234567890123456789012345678901234567890,\r\n'
                         '  "date": "\\/Date(0+0800)\\/", "escaped": "\\u4e2d\\u6587",\r\n'
                         '  "unknown": {"nothing": null, "object": {}, "array": []}\r\n}\r\n')
        self.assertTrue(self.save(document_text=document_text)['ok'])
        self.assertEqual(self.settings.read_bytes(), document_text.encode('utf-8'))
        # A fresh helper validates the existing raw document without formatting it.
        next_text = document_text.replace('["p"]', '["Space"]')
        self.assertTrue(self.save(document_text=next_text, expected_text=document_text)['ok'])
        self.assertEqual(self.settings.read_bytes(), next_text.encode('utf-8'))

    def test_existing_schema_one_without_shortcuts_accepts_first_shortcut(self):
        original = '{"schema":1,"other":true}'
        self.settings.write_bytes(original.encode('utf-8'))
        document = {'schema': 1, 'other': True, 'shortcuts': {'pause': ['Space']}}
        self.assertTrue(self.save(document)['ok'])
        self.assertEqual(json.loads(self.settings.read_text(encoding='utf-8')), document)

    def test_bom_existing_text_compares_exactly_and_document_bom_can_be_removed(self):
        original = '\ufeff{"schema":1,"other":true}\r\n'
        self.settings.write_bytes(original.encode('utf-8'))
        document_text = '\ufeff{"schema":1,"other":true,"shortcuts":{"pause":["p"]}}\r\n'
        before = self.settings.read_bytes()
        result = self.save(expected_text=original.lstrip('\ufeff'), document_text=document_text)
        self.assertTrue(result['conflict'])
        self.assert_preserved(before, result)
        self.assertTrue(self.save(expected_text=original, document_text=document_text)['ok'])
        self.assertEqual(self.settings.read_bytes(), document_text.lstrip('\ufeff').encode('utf-8'))

    def test_conflict_does_not_overwrite_or_create(self):
        self.settings.write_text('{"schema":1,"shortcuts":{},"external":true}', encoding='utf-8')
        before = self.settings.read_bytes()
        self.assert_preserved(before, self.save(expected_text='{"schema":1,"shortcuts":{}}'))
        self.assertTrue(self.save(expected_exists=False, expected_text='')['conflict'])
        self.settings.unlink()
        result = self.save(expected_exists=True, expected_text='{"schema":1,"shortcuts":{}}')
        self.assertTrue(result['conflict'])
        self.assertFalse(self.settings.exists())

    def test_damaged_future_and_invalid_utf8_original_are_preserved(self):
        for before in [b'{broken', b'{"schema":2,"shortcuts":{}}', b'\xef\xbb\xbf{"schema":2,"shortcuts":{}}', b'{"schema":1,"shortcuts":[]}',
                       b'{"schema":1,"shortcuts":{},"bad":"\xff"}']:
            with self.subTest(before=before):
                self.settings.write_bytes(before)
                result = self.save(expected_exists=True, expected_text=before.decode('utf-8', errors='replace'))
                self.assert_preserved(before, result)

    def test_rejects_other_filename_missing_directory_and_bad_documents(self):
        other = self.folder / 'input.conf'
        result = self.save(settings_path=str(other))
        self.assertFalse(result['ok'])
        self.assertFalse(other.exists())
        self.assertFalse(self.save(settings_path=str(self.folder / 'missing/mpvnet-user.json'))['ok'])
        self.assertFalse(self.save(settings_path='mpvnet-user.json')['ok'])
        for document in [{'schema': 2, 'shortcuts': {}}, {'schema': 1, 'shortcuts': []},
                         {'schema': 1, 'shortcuts': None}, {'schema': 1}, []]:
            with self.subTest(document=document):
                self.assertFalse(self.save(document)['ok'])
                self.assertFalse(self.settings.exists())
        for document_text in [None, {}, 1, '{broken', 'null']:
            with self.subTest(document_text=document_text):
                self.assertFalse(self.save(document_text=document_text)['ok'])
                self.assertFalse(self.settings.exists())

    def test_oversize_and_deep_document_leave_original_untouched(self):
        self.settings.write_text('{"schema":1,"shortcuts":{}}', encoding='utf-8')
        before = self.settings.read_bytes()
        self.assert_preserved(before, self.save({'schema': 1, 'shortcuts': {}, 'extra': 'x' * 262144}))
        nested = {'leaf': 'kept'}
        for _ in range(90):
            nested = {'child': nested}
        self.assert_preserved(before, self.save({'schema': 1, 'shortcuts': {}, 'extra': nested}))

    def test_reparse_ancestor_is_rejected(self):
        actual = self.folder / 'actual'
        actual.mkdir()
        link = self.folder / 'linked'
        made = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(actual)], capture_output=True)
        if made.returncode:
            self.skipTest('Cannot create a disposable directory junction')
        try:
            result = self.save(settings_path=str(link / 'mpvnet-user.json'), expected_exists=False, expected_text='')
            self.assertFalse(result['ok'])
            self.assertFalse((actual / 'mpvnet-user.json').exists())
        finally:
            # Remove only this owned junction; never recursively traverse its target.
            os.rmdir(link)

    def test_reparse_target_is_rejected(self):
        actual = self.folder / 'owned-original.json'
        actual.write_text('{"schema":1,"shortcuts":{}}', encoding='utf-8')
        try:
            os.symlink(actual, self.settings)
        except OSError as error:
            self.skipTest('Cannot create a disposable file symlink: ' + str(error.winerror))
        before = actual.read_bytes()
        result = self.save()
        self.assertFalse(result['ok'])
        self.assertEqual(actual.read_bytes(), before)
        self.settings.unlink()


if __name__ == '__main__':
    unittest.main()
