"""Run actual C# input rules with synthetic files and injected UI/clipboard I/O."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows and local .NET Framework reference assemblies')
class PlaylistInput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='mpvnet-playlist-input-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        dotnet = shutil.which('dotnet')
        if not dotnet:
            raise AssertionError('Local .NET 10 SDK required; no dependencies are installed by this test')
        sdks = subprocess.run([dotnet, '--list-sdks'], capture_output=True, text=True, check=True)
        versions = []
        for line in sdks.stdout.splitlines():
            match = re.fullmatch(r'(10\.\d+\.\d+) \[(.+)\]', line.strip())
            if match:
                versions.append((tuple(map(int, match[1].split('.'))), Path(match[2])/match[1]))
        if not versions:
            raise AssertionError('Local .NET 10 SDK required')
        compiler = max(versions)[1]/'Roslyn/bincore/csc.dll'
        references = Path(os.environ['ProgramFiles(x86)'])/'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.7.2'
        common = [dotnet, str(compiler), '-nologo', '-noconfig', '-nostdlib+', '-utf8output',
                  '-codepage:65001', '-langversion:7.3', '-warnaserror+',
                  *(f'-reference:{references/name}' for name in ('mscorlib.dll', 'System.dll', 'System.Core.dll',
                    'System.Web.Extensions.dll', 'System.Windows.Forms.dll')),
                  str(ROOT/'config/helpers/playlist-input.cs')]
        cls.executable = cls.directory/'KitPlaylistInput.exe'
        cls.probe = cls.directory/'PlaylistInputProbe.exe'
        for output, options in ((cls.executable, ['-target:winexe', '-main:KitPlaylistInput.Program']),
                                (cls.probe, ['-target:exe', '-main:PlaylistInputProbe',
                                             str(ROOT/'tests/fixtures/playlist_input_probe.cs')])):
            compiled = subprocess.run(common + options + [f'-out:{output}'], capture_output=True, timeout=30)
            if compiled.returncode:
                raise AssertionError(compiled.stdout.decode('utf-8-sig') + compiled.stderr.decode('utf-8-sig'))

    def setUp(self):
        self.root = self.directory/self.id().split('.')[-1]
        self.root.mkdir()
        self.video = self.root/'视频 one.mkv'
        self.audio = self.root/'音频 two.FLAC'
        self.subtitle = self.root/'字幕.customsub'
        self.native = self.root/'列表.m3u'
        for path in (self.video, self.audio, self.subtitle, self.native):
            path.write_text('synthetic input; never played', encoding='utf-8')
        self.request = dict(schema=1, request_id='synthetic-session-1', parent_pid=os.getpid(),
                            operation='files', mode='open', working_directory=str(self.root), paths=[],
                            video_exts=['mkv', 'mp4'], audio_exts=['flac', 'mp3'], subtitle_exts=['customsub'],
                            existing_paths=[])
        self.sequence = 0

    def request_path(self, **changes):
        self.sequence += 1
        request = dict(self.request, **changes)
        target = self.root/f'request-{self.sequence}.json'
        target.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        return target

    def invoke(self, behavior='select', clipboard=None, executable=False, **changes):
        request = self.request_path(**changes)
        command = [str(self.executable), '-RequestPath', str(request)] if executable else [str(self.probe), str(request), behavior]
        if clipboard is not None:
            text = self.root/f'clipboard-{self.sequence}.txt'
            text.write_text(clipboard, encoding='utf-8')
            command.append(str(text))
        result = subprocess.run(command, capture_output=True, timeout=15)
        self.assertEqual(result.stderr, b'')
        return json.loads(result.stdout.decode('utf-8-sig'))

    def test_mixed_selection_preserves_order_and_classifies_subtitles_and_native(self):
        paths = [str(self.audio), str(self.video), str(self.subtitle), str(self.native), 'https://example.invalid/video']
        response = self.invoke(paths=paths)
        self.assertEqual([entry['path'] for entry in response['entries']], paths)
        self.assertEqual([entry['kind'] for entry in response['entries']], ['media', 'media', 'subtitle', 'native', 'native'])
        self.assertFalse(response['single_media'])

    def test_append_deduplicates_existing_and_batch_case_slashes_and_dot_segments(self):
        response = self.invoke(mode='append', existing_paths=[str(self.video).upper()],
            paths=[str(self.video), str(self.audio), str(self.audio).replace('\\', '/').upper(), '.\\' + self.audio.name])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.audio)])
        self.assertEqual(response['duplicates'], 3)
        self.assertEqual(response['entries'][0]['key'], str(self.audio).lower())

    def test_open_deduplicates_batch_but_does_not_use_old_queue(self):
        response = self.invoke(existing_paths=[str(self.video)], paths=[str(self.video), str(self.video).upper()])
        self.assertEqual(len(response['entries']), 1)
        self.assertEqual(response['duplicates'], 1)
        self.assertFalse(response['single_media'])

    def test_url_path_case_is_preserved_while_exact_native_duplicates_are_removed(self):
        response = self.invoke(paths=['https://example.invalid/A', 'https://example.invalid/a', 'https://example.invalid/A'])
        self.assertEqual([entry['path'] for entry in response['entries']], ['https://example.invalid/A', 'https://example.invalid/a'])
        self.assertEqual(response['duplicates'], 1)

    def test_single_media_uses_original_count_and_open_mode(self):
        self.assertTrue(self.invoke(paths=[str(self.video)])['single_media'])
        self.assertFalse(self.invoke(mode='append', paths=[str(self.video)])['single_media'])
        self.assertFalse(self.invoke(paths=[str(self.video), str(self.root/'missing.mp4')])['single_media'])
        self.assertFalse(self.invoke(paths=[str(self.subtitle)])['single_media'])

    def test_host_preprocessed_formats_reject_whole_request_even_in_media_extensions(self):
        for operation in ('files', 'clipboard'):
            for extension in ('iso', 'AVS', 'lnk'):
                special = self.root/('host.' + extension)
                special.write_bytes(b'synthetic special input')
                response = self.invoke(operation=operation, paths=[str(self.video), str(special)], video_exts=['mkv', extension])
                self.assertEqual(response['error_code'], 'native_entry_required')
                self.assertEqual(response['entries'], [])
        response = self.invoke(operation='paths', paths=[str(self.video), str(self.root/'host.iso')], video_exts=['mkv', 'iso'])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video)])
        self.assertEqual(response['skipped'], 1)
        response = self.invoke(paths=['https://example.invalid/video.iso'])
        self.assertEqual(response['entries'][0]['kind'], 'native')

    def test_missing_files_and_folders_are_skipped_without_modification(self):
        before = {path: path.read_bytes() for path in (self.video, self.audio, self.subtitle, self.native)}
        response = self.invoke(paths=[str(self.root/'missing.mkv'), str(self.root), str(self.video)])
        self.assertEqual(response['skipped'], 2)
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video)])
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_side_paths_accept_mixed_audio_video_but_filter_subtitles_native_urls(self):
        response = self.invoke(executable=True, operation='paths', paths=[str(self.audio), str(self.video),
            str(self.subtitle), str(self.native), 'https://example.invalid/video'])
        self.assertEqual([entry['kind'] for entry in response['entries']], ['media', 'media'])
        self.assertEqual(response['skipped'], 3)

    def test_relative_quoted_and_file_uri_paths_normalize(self):
        response = self.invoke(paths=['".\\' + self.video.name + '"', self.audio.as_uri()])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video), str(self.audio)])

    def test_windows_unc_extended_prefix_and_root_relative_keys(self):
        response = self.invoke(behavior='normalize', paths=[r'\\Server\Share\dir\..\Movie.MKV',
            r'\\?\UNC\Server\Share\Movie.MKV', '\\\\?\\' + str(self.video), r'\Media\Movie.MKV', 'C:ambiguous.mkv'])
        self.assertEqual(response[0]['path'], r'\\Server\Share\Movie.MKV')
        self.assertEqual(response[0]['key'], response[1]['key'])
        self.assertEqual(response[2]['path'], str(self.video))
        self.assertEqual(response[3]['path'], self.root.drive + r'\Media\Movie.MKV')
        self.assertIsNone(response[4])

    def test_file_uri_unc_and_drive_paths_share_windows_path_keys_without_io(self):
        response = self.invoke(behavior='normalize', paths=[
            'file://Server/Share/Folder/Movie%20One.MKV', r'\\Server\Share\Folder\Movie One.MKV',
            'file:///C:/Media/Movie%20One.MKV', r'C:\Media\Movie One.MKV',
            r'\\Server\Share\Movie%20One.MKV'])
        self.assertEqual(response[0]['path'], r'\\server\Share\Folder\Movie One.MKV')
        self.assertEqual(response[0]['key'], response[1]['key'])
        self.assertEqual(response[2]['key'], response[3]['key'])
        self.assertEqual(response[4]['path'], r'\\Server\Share\Movie%20One.MKV')

    def test_explicit_clipboard_text_reads_injected_lines_and_preserves_native_url(self):
        response = self.invoke(operation='clipboard', clipboard='\r\n"' + str(self.video) + '"\r\n' + str(self.audio) +
                               '\nhttps://example.invalid/video\n')
        self.assertEqual([entry['kind'] for entry in response['entries']], ['media', 'media', 'native'])
        self.assertFalse(response['single_media'])

    def test_cancel_and_unavailable_are_distinct_and_empty_is_success(self):
        self.assertEqual(self.invoke(behavior='cancel')['status'], 'cancelled')
        self.assertEqual(self.invoke(behavior='unavailable')['error_code'], 'input_unavailable')
        response = self.invoke(operation='clipboard', clipboard='\n\r\n')
        self.assertEqual(response['status'], 'ok')
        self.assertEqual(response['entries'], [])

    def test_invalid_schema_mode_control_characters_and_limits_are_rejected(self):
        for changes in (dict(schema=2), dict(schema=True), dict(mode='replace'), dict(operation='folders'),
                        dict(request_id='bad\nrequest'), dict(working_directory='relative'),
                        dict(paths=['bad\tpath']), dict(paths=['a' * 32768]), dict(paths=['a'] * 10001),
                        dict(subtitle_exts=['*']), dict(parent_pid=0)):
            with self.subTest(changes=str(changes)[:80]):
                self.assertEqual(self.invoke(**changes)['error_code'], 'invalid_request')

    def test_actual_winexe_has_utf8_json_and_no_console_subsystem(self):
        response = self.invoke(executable=True, operation='paths', paths=[str(self.video)])
        self.assertEqual(response['request_id'], 'synthetic-session-1')
        self.assertEqual(response['entries'][0]['path'], str(self.video))
        image = self.executable.read_bytes()
        pe = int.from_bytes(image[60:64], 'little')
        self.assertEqual(int.from_bytes(image[pe + 24 + 68:pe + 24 + 70], 'little'), 2)

    def test_invalid_parent_and_arguments_do_not_expose_paths_or_exceptions(self):
        response = self.invoke(executable=True, operation='paths', parent_pid=2147483647)
        self.assertEqual(response['error_code'], 'parent_unavailable')
        result = subprocess.run([str(self.executable), '-Wrong', str(self.video)], capture_output=True, timeout=10)
        self.assertNotIn(str(self.video).encode(), result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout.decode('utf-8-sig'))['error_code'], 'invalid_arguments')

    def test_actual_request_size_limit_and_bad_json_are_bounded(self):
        target = self.root/'invalid.json'
        for content in (b'{' + b' ' * (2 * 1024 * 1024), b'not-json', b'\xff'):
            target.write_bytes(content)
            result = subprocess.run([str(self.executable), '-RequestPath', str(target)], capture_output=True, timeout=10)
            self.assertEqual(json.loads(result.stdout.decode('utf-8-sig'))['status'], 'error')
            self.assertNotIn(str(target).encode(), result.stdout + result.stderr)

    def test_parent_exit_terminates_only_waiting_helper(self):
        parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        self.addCleanup(lambda: parent.poll() is None and parent.kill())
        request = self.request_path(parent_pid=parent.pid)
        helper = subprocess.Popen([str(self.probe), str(request), 'wait'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: helper.poll() is None and helper.kill())
        self.assertEqual(helper.stdout.readline().decode('utf-8-sig').strip(), 'READY')
        self.assertIsNone(parent.poll())
        parent.terminate()
        parent.wait(timeout=5)
        helper.wait(timeout=5)
        self.assertEqual(helper.returncode, 0)
        helper.stdout.close()
        helper.stderr.close()


if __name__ == '__main__':
    unittest.main()
