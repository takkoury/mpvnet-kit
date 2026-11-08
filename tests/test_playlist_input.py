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
                    'System.Web.Extensions.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')),
                  str(ROOT/'config/helpers/playlist-input.cs'), str(ROOT/'config/helpers/playlist-files.cs')]
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
        self.native = self.root/'列表.pls'
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

    def test_missing_files_skip_and_directories_expand_without_modification(self):
        before = {path: path.read_bytes() for path in (self.video, self.audio, self.subtitle, self.native)}
        response = self.invoke(paths=[str(self.root/'missing.mkv'), str(self.root), str(self.video)])
        self.assertEqual(response['skipped'], 1)
        self.assertEqual({entry['path'] for entry in response['entries']}, {str(self.video), str(self.audio)})
        self.assertEqual(response['duplicates'], 1)
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_folder_natural_order_mixed_media_and_only_direct_children(self):
        folder = self.root/'混合 目录'
        folder.mkdir()
        names = ['episode10.mkv', 'Episode2.mkv', 'episode02.mkv', 'Episode1.FLAC',
                 '超长编号99999999999999999999.mkv', '超长编号100000000000000000000.mkv']
        for name in names + ['subtitle.customsub', 'list.m3u', 'list.m3u8', 'list.pls', 'image.png',
                             'disc.iso', 'script.avs', 'shortcut.lnk', 'ignored.txt']:
            (folder/name).write_bytes(b'fixture')
        nested = folder/'nested.mkv'
        nested.mkdir()
        (nested/'episode0.mkv').touch()
        response = self.invoke(operation='folder', paths=[str(folder)], image_exts=['png'],
            video_exts=['mkv', 'm3u', 'm3u8', 'pls', 'png', 'iso', 'avs', 'lnk'])
        expected = ['Episode1.FLAC', 'Episode2.mkv', 'episode02.mkv', 'episode10.mkv',
                    '超长编号99999999999999999999.mkv', '超长编号100000000000000000000.mkv']
        # Equal numeric tokens compare by the complete filename with ordinal case.
        self.assertEqual([Path(entry['path']).name for entry in response['entries']], expected)
        self.assertTrue(all(entry['kind'] == 'media' for entry in response['entries']))
        self.assertEqual(response['skipped'], 0)
        self.assertEqual(response['unreadable_directories'], 0)
        self.assertFalse(response['single_media'])

    def test_all_managed_sources_expand_directories_at_their_input_position(self):
        first, second = self.root/'first', self.root/'second'
        first.mkdir()
        second.mkdir()
        for name in ['part10.mkv', 'part2.mkv']:
            (first/name).touch()
        (second/'music.FLAC').touch()
        paths = [str(self.audio), str(first), str(self.video), str(second)]
        expected = [str(self.audio), str(first/'part2.mkv'), str(first/'part10.mkv'),
                    str(self.video), str(second/'music.FLAC')]
        for operation in ('files', 'clipboard', 'paths'):
            with self.subTest(operation=operation):
                response = self.invoke(operation=operation, paths=paths)
                self.assertEqual([entry['path'] for entry in response['entries']], expected)
                self.assertFalse(response['single_media'])

    def test_directory_overlap_and_existing_queue_deduplicate_after_expansion(self):
        folder = self.root/'overlap'
        folder.mkdir()
        for name in ['part2.mkv', 'part10.mkv']:
            (folder/name).touch()
        second = str(folder/'part2.mkv')
        tenth = str(folder/'part10.mkv')
        response = self.invoke(paths=[second, str(folder), str(folder).upper(), tenth])
        self.assertEqual([entry['path'] for entry in response['entries']], [second, tenth])
        self.assertEqual(response['duplicates'], 4)
        response = self.invoke(mode='append', existing_paths=[second.upper()], paths=[str(folder), second])
        self.assertEqual([entry['path'] for entry in response['entries']], [tenth])
        self.assertEqual(response['duplicates'], 2)

    def test_folder_single_media_empty_missing_and_cancel_are_distinct(self):
        folder = self.root/'single'
        folder.mkdir()
        (folder/'only.mkv').touch()
        for operation in ('files', 'clipboard', 'paths', 'folder'):
            with self.subTest(operation=operation):
                response = self.invoke(operation=operation, paths=[str(folder)])
                self.assertEqual(len(response['entries']), 1)
                self.assertFalse(response['single_media'])
        (folder/'only.mkv').unlink()
        response = self.invoke(operation='folder', paths=[str(folder)])
        self.assertEqual(response['entries'], [])
        self.assertEqual(response['unreadable_directories'], 0)
        folder.rmdir()
        response = self.invoke(operation='folder', paths=[str(folder)])
        self.assertEqual(response['entries'], [])
        self.assertEqual(response['unreadable_directories'], 1)
        self.assertEqual(self.invoke(operation='folder', behavior='cancel')['status'], 'cancelled')

    def test_unreadable_and_disappeared_directories_keep_other_inputs_with_no_partial_directory(self):
        folder = self.root/'blocked'
        folder.mkdir()
        (folder/'partial.mkv').touch()
        for behavior in ('scanner-denied', 'scanner-late-denied', 'scanner-disappeared'):
            with self.subTest(behavior=behavior):
                response = self.invoke(behavior=behavior, paths=[str(self.video), str(folder), str(self.audio)])
                self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video), str(self.audio)])
                self.assertEqual(response['unreadable_directories'], 1)
        # This is an injected scanner failure, not evidence of real ACL behavior.

    def test_image_exclusions_apply_only_to_folder_expansion(self):
        folder = self.root/'images'
        folder.mkdir()
        image = folder/'cover.png'
        image.touch()
        (folder/'movie.mkv').touch()
        response = self.invoke(paths=[str(folder)], video_exts=['png', 'mkv'], image_exts=['png'])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(folder/'movie.mkv')])
        response = self.invoke(paths=[str(image)], video_exts=['png', 'mkv'], image_exts=['png'])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(image)])
        self.assertTrue(response['single_media'])

    def test_directory_item_and_enumeration_limits_are_global_without_partial_results(self):
        folders = [self.root/'first', self.root/'second']
        for folder in folders:
            folder.mkdir()
            (folder/'candidate.mkv').touch()
        for behavior in ('scanner-many-candidates', 'scanner-many-unrelated'):
            with self.subTest(behavior=behavior):
                response = self.invoke(behavior=behavior, paths=[str(folder) for folder in folders])
                self.assertEqual(response['error_code'], 'input_too_large')
                self.assertEqual(response['entries'], [])

    def test_folder_byte_budget_rejects_expansion_without_partial_results(self):
        folder = self.root/'bytes'
        folder.mkdir()
        # Each real filename is short enough for Framework's legacy path handling,
        # while Unicode makes 6000 candidate paths exceed the UTF-8 byte budget.
        for number in range(6000):
            (folder/('影片' * 30 + f'{number:04}.mkv')).touch()
        response = self.invoke(operation='folder', paths=[str(folder)])
        self.assertEqual(response['error_code'], 'input_too_large')
        self.assertEqual(response['entries'], [])

    def test_folder_json_output_limit_includes_keys_and_json_overhead(self):
        folder = self.root/'output'
        folder.mkdir()
        stem = '片' * max(1, 240 - len(str(folder)) - 9)
        path_bytes = len(str(folder/(stem + '0000.mkv')).encode('utf-8'))
        count = (2 * 1024 * 1024 - 16384) // path_bytes
        self.assertLessEqual(count, 10000)
        self.assertLess(count * path_bytes, 2 * 1024 * 1024)
        for number in range(count):
            (folder/(stem + f'{number:04}.mkv')).touch()
        # All candidate paths fit the input budget; duplicated path/key fields
        # and JSON punctuation alone push the final response beyond 4 MiB.
        response = self.invoke(operation='folder', paths=[str(folder)])
        self.assertEqual(response['error_code'], 'input_too_large')
        self.assertEqual(response['entries'], [])

    def test_modern_folder_com_options_work_without_showing_a_dialog(self):
        response = self.invoke(behavior='folder-com')
        self.assertEqual(response['options'] & response['required'], response['required'])
        self.assertEqual(response['options'] & 0x200, 0)
        self.assertFalse(response['initial'])
        self.assertTrue(response['selected'])
        self.assertFalse(response['fresh'], 'The recursive checkbox belongs only to one dialog request')

    def test_recursive_directory_order_is_parent_first_then_natural_depth_first(self):
        folder = self.root/'再生 目录'
        for relative in ['root10.mkv', 'root2.mkv', '目录10/child1.mkv', '目录2/child10.mkv',
                         '目录2/child2.FLAC', '目录2/深い/a.mkv', '目录1/first.mkv',
                         '目录2/list.m3u', '目录2/cover.png', '目录2/captions.customsub']:
            path = folder/relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        expected = ['root2.mkv', 'root10.mkv', '目录1/first.mkv', '目录2/child2.FLAC',
                    '目录2/child10.mkv', '目录2/深い/a.mkv', '目录10/child1.mkv']
        for behavior, changes in [('select', dict(include_subdirectories=True)), ('recursive-select', {})]:
            with self.subTest(behavior=behavior):
                response = self.invoke(behavior=behavior, operation='folder', paths=[str(folder)], image_exts=['png'], **changes)
                self.assertEqual([entry['path'] for entry in response['entries']], [str(folder/path) for path in expected])
                self.assertFalse(response['single_media'])
        # A subsequent request and ordinary paths/drop input keep the default.
        for operation in ('folder', 'paths'):
            response = self.invoke(operation=operation, paths=[str(folder)])
            self.assertEqual([entry['path'] for entry in response['entries']], [str(folder/path) for path in expected[:2]])

    def test_recursive_overlap_deduplicates_flattened_paths_and_existing_queue(self):
        folder = self.root/'tree'
        child = folder/'child'
        child.mkdir(parents=True)
        first, second = folder/'root.mkv', child/'child.mkv'
        first.touch()
        second.touch()
        response = self.invoke(operation='paths', mode='append', paths=[str(folder), str(child), str(second)],
                               include_subdirectories=True, existing_paths=[str(first).upper()])
        self.assertEqual([entry['path'] for entry in response['entries']], [str(second)])
        self.assertEqual(response['duplicates'], 3)

    def test_recursive_unreadable_children_are_counted_without_their_partial_results(self):
        folder = self.root/'tree'
        for relative in ['root.mkv', 'blocked/skip.mkv', 'late-blocked/partial.mkv',
                         'late-blocked/nested/skip.mkv', 'ok/kept.mkv']:
            path = folder/relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        response = self.invoke(behavior='scanner-denied-child', operation='folder', paths=[str(folder)],
                               include_subdirectories=True)
        self.assertEqual([entry['path'] for entry in response['entries']], [str(folder/'root.mkv'), str(folder/'ok/kept.mkv')])
        self.assertEqual(response['unreadable_directories'], 2)
        response = self.invoke(behavior='scanner-denied', operation='folder', paths=[str(folder)], include_subdirectories=True)
        self.assertEqual(response['entries'], [])
        self.assertEqual(response['unreadable_directories'], 1)

    def test_recursive_cancel_discards_prepared_roots_and_blocked_worker_does_not_delay_exit(self):
        folder = self.root/'tree'
        (folder/'cancel').mkdir(parents=True)
        (folder/'root.mkv').touch()
        response = self.invoke(behavior='scanner-cancel-child', operation='paths',
                               paths=[str(self.video), str(folder)], include_subdirectories=True)
        self.assertEqual(response['status'], 'cancelled')
        self.assertEqual(response['entries'], [])
        response = self.invoke(behavior='cancel-blocked-scan', operation='folder', paths=[str(folder)],
                               include_subdirectories=True)
        self.assertEqual(response['request_id'], self.request['request_id'])
        self.assertEqual(response['status'], 'cancelled')
        self.assertEqual(response['entries'], [])

    def test_directory_junctions_are_not_followed_including_explicit_roots_and_cycles(self):
        outside = self.root/'outside'
        outside.mkdir()
        (outside/'outside.mkv').touch()
        folder = self.root/'local'
        folder.mkdir()
        (folder/'inside.mkv').touch()
        nested, selected = folder/'nested', self.root/'selected'
        for link, target in ((nested, outside), (selected, folder), (folder/'cycle', folder)):
            subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/j', str(link), str(target)],
                           check=True, capture_output=True)
        response = self.invoke(operation='folder', paths=[str(selected)])
        self.assertEqual(response['entries'], [])
        self.assertEqual(response['skipped_links'], 1)
        for recursive in (False, True):
            response = self.invoke(operation='folder', paths=[str(folder)], include_subdirectories=recursive)
            self.assertEqual([entry['path'] for entry in response['entries']], [str(folder/'inside.mkv')])
            self.assertEqual(response['skipped_links'], 2 if recursive else 0)

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
                        dict(subtitle_exts=['*']), dict(parent_pid=0), dict(include_subdirectories=1),
                        dict(include_subdirectories='true'), dict(include_subdirectories=None)):
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
        for operation in ('files', 'folder'):
            with self.subTest(operation=operation):
                parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
                self.addCleanup(lambda process=parent: process.poll() is None and process.kill())
                request = self.request_path(parent_pid=parent.pid, operation=operation)
                helper = subprocess.Popen([str(self.probe), str(request), 'wait'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.addCleanup(lambda process=helper: process.poll() is None and process.kill())
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
