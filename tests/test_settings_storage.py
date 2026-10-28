"""Exercise the shared writer through real PowerShell in owned temporary fixtures."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'config/helpers/settings-storage.ps1'
STORAGE = ROOT / 'config/helpers/user-preferences-storage.cs'


@unittest.skipUnless(os.name == 'nt', 'Requires existing Windows PowerShell/.NET')
class SettingsStorage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mpvnet-settings-test-')
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.settings = self.folder / 'mpvnet-user.json'
        (self.folder / 'script-opts').mkdir()
        self.local = self.folder / 'script-opts/mpvnet-local.conf'

    def command(self, operation='Save', **changes):
        target = self.local if operation == 'SaveLocal' else self.settings
        request = {'schema': 1, 'settings_path': str(target), 'expected_exists': target.exists(),
                   'expected_text': target.read_bytes().decode('utf-8', errors='replace') if target.exists() else ''}
        if operation == 'SaveLocal':
            request['values'] = {'capture_root': 'D:\\合成输出'}
        else:
            request['document_text'] = '{"schema":1,"settings":{"subtitle":{"font_size":42}}}'
        request.update(changes)
        path = self.folder / ('request-' + uuid.uuid4().hex + '.json')
        path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        return ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(HELPER), '-Operation', operation, '-RequestPath', str(path)]

    def result(self, completed):
        self.assertEqual(completed.stderr, b'', completed.stderr.decode('utf-8', errors='replace'))
        output = completed.stdout.decode('utf-8-sig')
        self.assertEqual(len(output.strip().splitlines()), 1, output)
        result = json.loads(output)
        expected = {'ok', 'error', 'conflict'}
        if 'written_text' in result:
            self.assertTrue(result['ok'], result)
            self.assertIsInstance(result['written_text'], str)
            expected.add('written_text')
        self.assertEqual(set(result), expected)
        self.assertEqual(completed.returncode == 0, result['ok'], result)
        return result

    def save(self, operation='Save', **changes):
        return self.result(subprocess.run(self.command(operation, **changes), capture_output=True, timeout=30))

    def assert_preserved(self, target, before, result):
        self.assertFalse(result['ok'], result)
        self.assertEqual(target.read_bytes(), before)
        self.assertEqual(list(target.parent.glob('.mpvnet-*.tmp')), [])

    def test_settings_only_and_empty_schema_one_documents(self):
        self.assertTrue(self.save()['ok'])
        self.assertEqual(json.loads(self.settings.read_text(encoding='utf-8'))['settings']['subtitle']['font_size'], 42)
        self.assertTrue(self.save(document_text='{"schema":1}')['ok'])
        self.assertEqual(self.settings.read_bytes(), b'{"schema":1}')

    def test_opt_in_write_receipt_reports_exact_saved_json_and_local_text(self):
        text = '\ufeff{ "schema":1, "settings":{}, "unknown":123456789012345678901234567890 }\r\n'
        response = self.save(document_text=text, return_written_text=True)
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['written_text'].encode('utf-8'), self.settings.read_bytes())
        self.assertEqual(response['written_text'], text.lstrip('\ufeff'))
        self.local.write_bytes(b'# retained\r\npython_path=C:\\python.exe\n')
        response = self.save('SaveLocal', return_written_text=True)
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['written_text'].encode('utf-8'), self.local.read_bytes())
        before = self.local.read_bytes()
        response = self.save('SaveLocal', expected_text='stale', return_written_text=True)
        self.assertTrue(response['conflict'], response)
        self.assertEqual(set(response), {'ok', 'error', 'conflict'})
        self.assertEqual(self.local.read_bytes(), before)
        self.assertNotIn('written_text', self.save('SaveLocal', return_written_text=False))

    def test_settings_preserve_raw_unknown_domains_and_shortcuts(self):
        original = ('{\r\n  "schema": 1, "shortcuts": {"pause":["p"]},\r\n'
                    '  "settings":{"subtitle":{"font_size":42},"future":[null,true]},\r\n'
                    '  "n":12345678901234567890123456789012345678901234567890,\r\n'
                    '  "s":"\\u4e2d\\/Date(0+0800)\\/"\r\n}\r\n')
        self.settings.write_bytes(original.encode('utf-8'))
        changed = original.replace('"font_size":42', '"font_size":44')
        self.assertTrue(self.save(document_text=changed)['ok'])
        self.assertEqual(self.settings.read_bytes(), changed.encode('utf-8'))
        self.assert_preserved(self.settings, changed.encode('utf-8'),
                              self.save(document_text=original, expected_text=original))

    def test_damaged_or_future_documents_and_bad_domains_are_preserved(self):
        for raw in [b'{broken', b'{"schema":2,"settings":{}}', b'{"schema":1,"settings":[]}',
                    b'{"schema":1,"shortcuts":null}', b'{"schema":1,"bad":"\xff"}']:
            with self.subTest(raw=raw):
                self.settings.write_bytes(raw)
                self.assert_preserved(self.settings, raw, self.save())
        self.settings.unlink()
        for text in ['{"schema":1,"settings":[]}', '{"schema":1,"settings":null}',
                     '{"schema":1,"shortcuts":[]}', '{"schema":2}', '[]']:
            with self.subTest(text=text):
                self.assertFalse(self.save(document_text=text)['ok'])
                self.assertFalse(self.settings.exists())

    def test_settings_and_legacy_shortcut_writer_share_cas(self):
        self.settings.write_bytes(b'{"schema":1,"shortcuts":{},"settings":{}}')
        first = self.command(document_text='{"schema":1,"shortcuts":{},"settings":{"size":42}}')
        second = self.command(document_text='{"schema":1,"shortcuts":{"pause":["p"]},"settings":{}}')
        second[second.index(str(HELPER))] = str(ROOT / 'config/helpers/shortcuts-window.ps1')
        self.assert_two_writers(first, second)

    def assert_two_writers(self, *commands):
        children = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for command in commands]
        results = []
        for child in children:
            out, err = child.communicate(timeout=30)
            results.append(self.result(subprocess.CompletedProcess(child.args, child.returncode, out, err)))
        self.assertEqual(sum(item['ok'] for item in results), 1, results)
        self.assertEqual(sum(item['conflict'] for item in results), 1, results)

    def test_local_create_replace_and_delete_one_override(self):
        self.assertTrue(self.save('SaveLocal', values={'capture_root': 'D:\\合成 # = 输出',
                        'ffmpeg_path': 'C:/Not installed/ffmpeg.exe'})['ok'])
        self.assertEqual(self.local.read_bytes(), 'capture_root=D:\\合成 # = 输出\r\nffmpeg_path=C:/Not installed/ffmpeg.exe\r\n'.encode('utf-8'))
        self.assertTrue(self.save('SaveLocal', values={'capture_root': ''})['ok'])
        self.assertEqual(self.local.read_bytes(), b'ffmpeg_path=C:/Not installed/ffmpeg.exe\r\n')
        self.assertTrue(self.save('SaveLocal', values={'ffmpeg_path': ''})['ok'])
        self.assertEqual(self.local.read_bytes(), b'')
        self.assertFalse(self.settings.exists())
        self.assertEqual(list(self.local.parent.glob('.mpvnet-*.tmp')), [])

    def test_local_preserves_unknown_comments_mixed_endings_and_unchanged_values(self):
        raw = ('# 私有注释\r\nfuture = x # 原文\nffmpeg_path=C:\\未安装\\ffmpeg.exe\r\n'
               'capture_root=D:\\旧目录\npython_path=C:/Python/python.exe\r\nunknown-without-equals')
        self.local.write_bytes(raw.encode('utf-8'))
        self.assertTrue(self.save('SaveLocal', values={'capture_root': 'D:\\新目录',
                        'python_path': 'C:/Python/python.exe'})['ok'])
        self.assertEqual(self.local.read_bytes(), raw.replace('D:\\旧目录', 'D:\\新目录').encode('utf-8'))
        self.assertTrue(self.save('SaveLocal', values={'mpv_path': 'C:\\新目录\\mpvnet.exe'})['ok'])
        self.assertTrue(self.local.read_bytes().endswith(b'unknown-without-equals\r\nmpv_path=C:\\' + '新目录'.encode('utf-8') + b'\\mpvnet.exe\r\n'))

    def test_local_delete_does_not_touch_other_lines_or_json(self):
        raw = b'# capture_root=D:\\example\r\ncapture_root=D:\\old\r\npython_path=C:\\python.exe\n# tail'
        self.local.write_bytes(raw)
        self.settings.write_bytes(b'{"schema":1,"settings":{"unknown":1}}')
        before_json = self.settings.read_bytes()
        self.assertTrue(self.save('SaveLocal', values={'capture_root': '', 'mpv_path': ''})['ok'])
        self.assertEqual(self.local.read_bytes(), raw.replace(b'capture_root=D:\\old\r\n', b''))
        self.assertEqual(self.settings.read_bytes(), before_json)

    def test_local_two_writers_and_exact_original_conflict(self):
        self.local.write_bytes(b'# initial\r\n')
        first = self.command('SaveLocal', values={'capture_root': 'D:\\first'})
        second = self.command('SaveLocal', values={'python_path': 'C:\\python.exe'})
        self.assert_two_writers(first, second)
        before = self.local.read_bytes()
        result = self.save('SaveLocal', expected_text=before.decode('utf-8').replace('\r\n', '\n'))
        self.assertTrue(result['conflict'], result)
        self.assert_preserved(self.local, before, result)
        self.assertTrue(self.save('SaveLocal', expected_exists=False, expected_text='')['conflict'])

    def test_local_rejects_invalid_values_and_preserves_original(self):
        self.local.write_bytes(b'# retained\r\ncapture_root=D:\\old\r\n')
        before = self.local.read_bytes()
        for value in ['relative', 'C:relative', '\\rooted', '\\\\server\\share',
                      'https://example.invalid', 'D:\\x\npython_path=C:\\injected', 'D:\\x\rhidden',
                      'D:\\x\x00', 'D:\\x\t', 'D:\\x\u2028hidden', 'D:\\x" --args', 'D:\\x:ads', None, 42, []]:
            with self.subTest(value=value):
                self.assert_preserved(self.local, before, self.save('SaveLocal', values={'capture_root': value}))
        self.assert_preserved(self.local, before, self.save('SaveLocal', values={'unknown': 'D:\\new'}))

    def test_local_duplicate_known_keys_and_invalid_utf8_are_preserved(self):
        for raw in [b'capture_root=D:\\first\n# comment\ncapture_root=D:\\second\n',
                    b'ffmpeg_path=C:\\first.exe\nffmpeg_path=\n', b'# invalid \xff\n']:
            with self.subTest(raw=raw):
                self.local.write_bytes(raw)
                self.assert_preserved(self.local, raw, self.save('SaveLocal'))

    def test_local_wrong_targets_and_request_schema_do_not_write(self):
        for target in [self.folder / 'mpvnet-local.conf', self.settings,
                       self.folder / 'script-opts/other.conf', self.folder / 'missing/script-opts/mpvnet-local.conf']:
            with self.subTest(target=target):
                self.assertFalse(self.save('SaveLocal', settings_path=str(target))['ok'])
                self.assertFalse(target.exists())
        self.assertFalse(self.save('SaveLocal', schema=2)['ok'])
        self.assertFalse(self.local.exists())

    def test_local_oversize_and_missing_existing_target_are_preserved(self):
        self.local.write_bytes(b'#' + b'x' * 262144)
        before = self.local.read_bytes()
        self.assert_preserved(self.local, before, self.save('SaveLocal'))
        self.local.unlink()
        result = self.save('SaveLocal', expected_exists=True, expected_text='# missing\n')
        self.assertTrue(result['conflict'], result)
        self.assertFalse(self.local.exists())

    def test_parse_local_matches_mp_options_literal_keys_values_and_comments(self):
        raw = ('#capture_root=D:\\ignored\r\n capture_root=D:\\unknown\n'
               'capture_root =D:\\unknown\nffmpeg_path=C:\\# tools\\ffmpeg=1.exe\r\n'
               'python_path=relative old value\nmpv_path=C:/mpv.exe\r')
        raw_file = self.folder / 'parse-input.conf'
        raw_file.write_bytes(raw.encode('utf-8'))
        script = self.folder / 'parse.ps1'
        script.write_text('''param($Source, $InputPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Web.Extensions
Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition ([IO.File]::ReadAllText($Source))
[UserPreferencesStorage]::Json().Serialize([UserPreferencesStorage]::ParseLocal([IO.File]::ReadAllText($InputPath)))
''', encoding='utf-8-sig')
        completed = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                   '-File', str(script), str(STORAGE), str(raw_file)], capture_output=True, timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode('utf-8', errors='replace'))
        self.assertEqual(json.loads(completed.stdout.decode('utf-8-sig')), {
            'capture_root': '', 'ffmpeg_path': 'C:\\# tools\\ffmpeg=1.exe',
            'python_path': 'relative old value', 'mpv_path': 'C:/mpv.exe'})

    def test_local_writer_waits_for_shared_file_mutex(self):
        before = b'capture_root=D:\\old\r\n'
        self.local.write_bytes(before)
        mutex_name = 'Local\\MpvnetUserSettings-' + hashlib.sha256(str(self.local).upper().encode('utf-8')).hexdigest().upper()
        ready, release = self.folder / 'ready', self.folder / 'release'
        holder_script = self.folder / 'hold.ps1'
        holder_script.write_text('''param($Name, $Ready, $Release)
$mutex = New-Object Threading.Mutex($false, $Name)
$held = $false
try {
    $held = $mutex.WaitOne(10000)
    if (-not $held) { exit 1 }
    [IO.File]::WriteAllText($Ready, 'ready')
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while (-not [IO.File]::Exists($Release) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
} finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
''', encoding='utf-8-sig')
        holder = subprocess.Popen(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                   '-File', str(holder_script), mutex_name, str(ready), str(release)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        writer = None
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline and holder.poll() is None:
                time.sleep(.05)
            self.assertTrue(ready.exists(), 'Mutex holder did not become ready')
            writer = subprocess.Popen(self.command('SaveLocal'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(1)
            self.assertIsNone(writer.poll(), 'Writer bypassed the shared mutex')
            self.assertEqual(self.local.read_bytes(), before)
        finally:
            release.write_text('release', encoding='utf-8')
            holder_out, holder_err = holder.communicate(timeout=15)
            if writer:
                out, err = writer.communicate(timeout=30)
        self.assertEqual(holder.returncode, 0, (holder_out, holder_err))
        self.assertTrue(self.result(subprocess.CompletedProcess(writer.args, writer.returncode, out, err))['ok'])


if __name__ == '__main__':
    unittest.main()
