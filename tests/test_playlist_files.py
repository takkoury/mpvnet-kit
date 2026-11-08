"""Actual host libmpv parsing and atomic M3U8 storage with isolated fixtures."""
import ctypes
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest

import test_playlist_input as input_tests


@unittest.skipUnless(os.name == 'nt', 'Requires Windows, Framework and the existing host libmpv')
class PlaylistFiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        input_tests.PlaylistInput.setUpClass.__func__(cls)
        configured = os.environ.get('MPVNET_TEST_LIBMPV')
        if not configured:
            raise AssertionError('Set MPVNET_TEST_LIBMPV to an existing host libmpv; tests never install one')
        cls.libmpv = Path(configured)
        if not cls.libmpv.is_absolute() or not cls.libmpv.is_file():
            raise AssertionError('MPVNET_TEST_LIBMPV must name an existing absolute library path')
        # Also exercises production discovery via the parent's loaded modules.
        cls.library = ctypes.CDLL(str(cls.libmpv))

    setUp = input_tests.PlaylistInput.setUp
    request_path = input_tests.PlaylistInput.request_path

    def invoke(self, behavior='select', executable=False, **changes):
        request = self.request_path(**changes)
        command = ([str(self.executable), '-RequestPath', str(request)] if executable else
                   [str(self.probe), str(request), behavior, '', str(self.libmpv)])
        process = subprocess.run(command, capture_output=True, timeout=20)
        self.assertEqual(process.stderr, b'', process.stderr.decode('utf-8', errors='replace'))
        return json.loads(process.stdout.decode('utf-8-sig'))

    def playlist(self, name='输入.m3u8', content=None, encoding='utf-8'):
        path = self.root/name
        if content is None:
            content = '#EXTM3U\n#EXTINF:-1,中文 标题\n' + self.video.name + '\n' + self.audio.name + '\n' + self.video.name + '\n'
        path.write_text(content, encoding=encoding)
        return path

    def snapshot(self, target):
        response = self.invoke(operation='save-dialog', mode='save', paths=[str(target)])
        self.assertEqual(response['status'], 'ok')
        return {key: response[key] for key in ('target_path', 'target_exists', 'target_sha256')}

    def save(self, target, entries=None, snapshot=None, **changes):
        snapshot = snapshot if snapshot is not None else self.snapshot(target)
        return self.invoke(operation='save', mode='save', save_entries=entries if entries is not None else
                           [dict(path=str(self.video), title='显示标题')], **snapshot, **changes)

    def assert_clean(self):
        self.assertEqual(list(self.root.glob('.mpvnet-playlist-*.tmp')), [])
        self.assertEqual(list(self.root.glob('.mpvnet-result-*.tmp')), [])

    @contextmanager
    def target_lock(self, target):
        identity = hashlib.sha256(str(target).lower().encode('utf-8')).hexdigest().upper()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        kernel.CreateMutexW.restype = ctypes.c_void_p
        kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        mutex = kernel.CreateMutexW(None, 1, 'Local\\mpvnet-kit-playlist-' + identity)
        self.assertTrue(mutex)
        try:
            yield
        finally:
            kernel.ReleaseMutex(mutex)
            kernel.CloseHandle(mutex)

    def detached_request(self, target, **changes):
        payload = dict(operation='save', mode='save', request_id=self.request['request_id'] + '-' + str(self.sequence + 1),
                       save_entries=[dict(path=str(self.video), title='分离保存')], **self.snapshot(target))
        payload.update(changes)
        request = self.request_path(**payload)
        owned = self.root/('mpvnet-input-' + payload['request_id'] + '.json')
        request.rename(owned)
        return owned

    def start_detached(self, request):
        process = subprocess.Popen([str(self.executable), '-RequestPath', str(request), '-DetachedSave'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   creationflags=subprocess.DETACHED_PROCESS)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def wait_for_writer(self, process):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and process.poll() is None:
            if list(self.root.glob('.mpvnet-playlist-*.tmp')):
                return
            time.sleep(0.01)
        self.fail('The detached helper did not reach its pre-commit mutex wait')

    def finish_detached(self, process, request):
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(stdout, b'')
        self.assertEqual(stderr, b'')
        self.assertFalse(request.exists())
        self.assertFalse(Path(str(request) + '.cancel').exists())
        self.assert_clean()
        return Path(str(request) + '.result')

    def test_utf8_utf8_bom_utf16_and_relative_paths_keep_order_duplicates_titles(self):
        for index, encoding in enumerate(('utf-8', 'utf-8-sig', 'utf-16')):
            with self.subTest(encoding=encoding):
                path = self.playlist(f'编码{index}.m3u8', encoding=encoding)
                response = self.invoke(paths=[str(path)])
                self.assertEqual(response['status'], 'ok', response)
                self.assertEqual([entry['path'] for entry in response['entries']],
                                 [str(self.video), str(self.audio), str(self.video)])
                self.assertEqual(response['entries'][0]['title'], '中文 标题')
                self.assertTrue(all(entry['from_playlist'] for entry in response['entries']))
                self.assertTrue(response['had_playlist'])
                self.assertFalse(response['single_media'])
                self.assertEqual(response['duplicates'], 0)

    def test_core_codepage_option_is_forwarded_without_guessing_or_source_write(self):
        path = self.playlist('旧编码.m3u', '#EXTM3U\n#EXTINF:-1,旧编码标题\n' + self.video.name + '\n', 'gb18030')
        original = path.read_bytes()
        response = self.invoke(paths=[str(path)], metadata_codepage='gb18030')
        self.assertEqual(response['status'], 'ok', response)
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video)])
        self.assertEqual(response['entries'][0]['title'], '旧编码标题')
        self.assertEqual(path.read_bytes(), original)

    def test_partial_and_all_missing_are_counted_without_changing_source(self):
        for all_missing in (False, True):
            path = self.playlist(content='#EXTM3U\nmissing.mkv\n' + ('also-missing.flac' if all_missing else self.video.name) + '\n')
            before = path.read_bytes()
            response = self.invoke(paths=[str(path)])
            self.assertEqual(response['status'], 'ok')
            self.assertEqual(response['missing_files'], 2 if all_missing else 1)
            self.assertEqual(len(response['entries']), 0 if all_missing else 1)
            self.assertTrue(response['had_playlist'])
            self.assertEqual(path.read_bytes(), before)

    def test_multiple_lists_expand_in_place_and_only_later_ordinary_inputs_deduplicate(self):
        path = self.playlist()
        response = self.invoke(mode='append', existing_paths=[str(self.video)],
                               paths=[str(self.audio), str(path), str(self.video), str(path), str(self.audio)])
        self.assertEqual([entry['path'] for entry in response['entries']],
                         [str(self.audio)] + [str(self.video), str(self.audio), str(self.video)] * 2)
        self.assertEqual(response['duplicates'], 2)

    def test_explicit_playlist_images_keep_titles_and_duplicates_with_switch_off_or_on(self):
        image = self.root/'明确图片.gif'
        image.write_bytes(b'synthetic reference; playlist reader does not decode it')
        path = self.playlist(content='#EXTM3U\n#EXTINF:-1,第一幅\n' + image.name + '\n' +
                             self.video.name + '\n#EXTINF:-1,重复图片\n' + image.name + '\n')
        before = path.read_bytes()
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                response = self.invoke(operation='paths', mode='append', paths=[str(path), str(image)],
                    existing_paths=[str(image)], image_exts=['gif'], include_images=enabled)
                self.assertEqual([entry['path'] for entry in response['entries']],
                    [str(image), str(self.video), str(image)])
                self.assertEqual([entry['kind'] for entry in response['entries']], ['image', 'media', 'image'])
                self.assertEqual([entry['title'] for entry in response['entries']], ['第一幅', '', '重复图片'])
                self.assertTrue(all(entry['from_playlist'] for entry in response['entries']))
                self.assertEqual(response['skipped_images'], 0 if enabled else 1)
                self.assertEqual(response['duplicates'], 1 if enabled else 0)
                self.assertEqual(path.read_bytes(), before)

    def test_side_paths_expand_explicit_lists_and_never_attach_list_subtitles(self):
        path = self.playlist(content='#EXTM3U\n' + self.subtitle.name + '\n' + self.video.name + '\n')
        response = self.invoke(operation='paths', paths=[str(path)])
        self.assertEqual([entry['kind'] for entry in response['entries']], ['media', 'media'])
        self.assertTrue(all(entry['from_playlist'] for entry in response['entries']))

    def test_nested_list_stays_single_reference_and_urls_do_not_connect(self):
        nested = self.playlist('nested.m3u8', '#EXTM3U\n' + self.video.name + '\n')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(0.1)
            url = f'http://127.0.0.1:{listener.getsockname()[1]}/unreachable?raw=%23#keep'
            path = self.playlist(content='#EXTM3U\n' + nested.name + '\n' + url + '\n')
            response = self.invoke(paths=[str(path)])
            self.assertEqual(response['status'], 'ok', response)
            self.assertEqual([entry['path'] for entry in response['entries']], [str(nested), url])
            self.assertEqual([entry['kind'] for entry in response['entries']], ['native', 'native'])
            self.assertEqual(response['missing_files'], 0)
            with self.assertRaises(socket.timeout):
                listener.accept()

    def test_hls_is_one_native_source_even_with_extensionless_segments(self):
        for encoding in ('utf-8', 'utf-8-sig', 'utf-16', 'utf-16-be'):
            with self.subTest(encoding=encoding):
                content = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment-without-extension\n#EXT-X-ENDLIST\n'
                if encoding == 'utf-16-be':
                    path = self.root/'hls.m3u8'
                    path.write_bytes(b'\xfe\xff' + content.encode(encoding))
                else:
                    path = self.playlist('hls.m3u8', content, encoding)
                response = self.invoke(operation='paths', paths=[str(path)])
                self.assertEqual([entry['path'] for entry in response['entries']], [str(path)])
                self.assertEqual(response['entries'][0]['kind'], 'native')
                self.assertTrue(response['entries'][0]['from_playlist'])

    def test_production_executable_uses_parent_loaded_host_library(self):
        response = self.invoke(executable=True, operation='paths', paths=[str(self.playlist())])
        self.assertEqual(response['status'], 'ok', response)
        self.assertEqual([entry['path'] for entry in response['entries']], [str(self.video), str(self.audio), str(self.video)])

    def test_oversized_source_and_expanded_list_reject_whole_request(self):
        path = self.playlist(content='#EXTM3U\n' + 'x' * (2 * 1024 * 1024))
        self.assertEqual(self.invoke(paths=[str(self.video), str(path)])['error_code'], 'input_too_large')
        path.write_text('#EXTM3U\n' + (self.video.name + '\n') * 10001, encoding='utf-8')
        response = self.invoke(paths=[str(path)])
        self.assertEqual(response['error_code'], 'input_too_large')
        self.assertEqual(response['entries'], [])
        path.write_text('#EXTM3U\n' + (self.video.name + '\n') * 6000, encoding='utf-8')
        response = self.invoke(paths=[str(path), str(path)])
        self.assertEqual(response['error_code'], 'input_too_large')
        self.assertEqual(response['entries'], [])

    def test_save_is_utf8_without_bom_and_roundtrips_unicode_titles_duplicates_and_relative_paths(self):
        folder = self.root/'子目录'
        folder.mkdir()
        child = folder/'子 文件.mkv'
        child.touch()
        literal = self.root/'#百分%20.mkv'
        literal.touch()
        target = self.root/'保存.m3u8'
        entries = [dict(path=str(path), title='第一行\n第二行\t字幕') for path in (self.video, child, literal, self.video)]
        response = self.save(target, entries)
        self.assertTrue(response['saved'], response)
        content = target.read_bytes()
        self.assertTrue(content.startswith(b'#EXTM3U\n'))
        self.assertNotIn(str(self.root).encode('utf-8'), content)
        self.assertIn('子目录\\子 文件.mkv'.encode('utf-8'), content)
        self.assertIn('.\\#百分%20.mkv'.encode('utf-8'), content)
        loaded = self.invoke(paths=[str(target)])
        self.assertEqual([entry['path'] for entry in loaded['entries']], [entry['path'] for entry in entries])
        self.assertEqual(loaded['entries'][0]['title'], '第一行 第二行 字幕')
        self.assert_clean()

    def test_save_cross_directory_absolute_uri_verbatim_and_missing_paths_preserved(self):
        target_folder = self.root/'lists'
        target_folder.mkdir()
        target = target_folder/'queue.m3u8'
        url = 'https://example.invalid/A%20B?literal=%23#fragment'
        missing = str(self.root/'missing.mkv')
        response = self.save(target, [dict(path=value, title='') for value in (str(self.video), missing, url)])
        self.assertTrue(response['saved'], response)
        self.assertEqual(target.read_text(encoding='utf-8').splitlines(), ['#EXTM3U', str(self.video), missing, url])

    def test_cancel_save_dialog_never_touches_existing_target(self):
        target = self.root/'old.m3u8'
        target.write_bytes(b'keep original')
        response = self.invoke(behavior='cancel', operation='save-dialog', mode='save', paths=[str(target)])
        self.assertEqual(response['status'], 'cancelled')
        self.assertEqual(target.read_bytes(), b'keep original')
        self.assert_clean()

    def test_overwrite_uses_snapshot_and_rejects_changed_or_new_target_competition(self):
        target = self.root/'overwrite.m3u8'
        target.write_bytes(b'original')
        snapshot = self.snapshot(target)
        self.assertEqual(snapshot['target_sha256'], hashlib.sha256(b'original').hexdigest())
        target.write_bytes(b'external edit')
        response = self.save(target, snapshot=snapshot)
        self.assertEqual(response['error_code'], 'target_changed')
        self.assertEqual(target.read_bytes(), b'external edit')
        response = self.save(target)
        self.assertTrue(response['saved'], response)
        new = self.root/'new.m3u8'
        snapshot = self.snapshot(new)
        new.write_bytes(b'competitor')
        response = self.save(new, snapshot=snapshot)
        self.assertEqual(response['error_code'], 'target_changed')
        self.assertEqual(new.read_bytes(), b'competitor')
        self.assert_clean()

    def test_write_failure_and_parent_exit_preserve_old_bytes_and_cleanup_owned_temp(self):
        target = self.root/'locked.m3u8'
        target.write_bytes(b'old bytes')
        snapshot = self.snapshot(target)
        # Python's Windows file handle denies deletion, so atomic replacement
        # fails after the temporary file has been written and flushed.
        with target.open('rb'):
            response = self.save(target, snapshot=snapshot)
        self.assertEqual(response['error_code'], 'save_failed')
        self.assertEqual(target.read_bytes(), b'old bytes')
        response = self.save(target, snapshot=snapshot, behavior='parent-exited')
        self.assertEqual(response['error_code'], 'parent_unavailable')
        self.assertEqual(target.read_bytes(), b'old bytes')
        self.assert_clean()

    def test_target_commit_lock_reports_busy_and_preserves_bytes(self):
        target = self.root/'busy.m3u8'
        target.write_bytes(b'old bytes')
        snapshot = self.snapshot(target)
        with self.target_lock(target):
            response = self.save(target, snapshot=snapshot)
            self.assertEqual(response['error_code'], 'target_busy')
            self.assertEqual(target.read_bytes(), b'old bytes')
            self.assert_clean()

    def test_detached_save_publishes_complete_matching_json_without_stdout(self):
        target = self.root/'detached.m3u8'
        request = self.detached_request(target)
        expected_id = json.loads(request.read_text(encoding='utf-8'))['request_id']
        process = self.start_detached(request)
        result = self.finish_detached(process, request)
        response = json.loads(result.read_text(encoding='utf-8'))
        self.assertEqual(process.returncode, 0)
        self.assertEqual(response['request_id'], expected_id)
        self.assertEqual(response['schema'], 1)
        self.assertEqual(response['status'], 'ok')
        self.assertTrue(response['saved'])
        self.assertEqual(response['target_path'], str(target))
        self.assertIn('分离保存', target.read_text(encoding='utf-8'))

    def test_detached_save_runs_without_inherited_standard_handles(self):
        target = self.root/'no-standard-handles.m3u8'
        request = self.detached_request(target)
        process = subprocess.Popen([str(self.executable), '-RequestPath', str(request), '-DetachedSave'],
                                   close_fds=True, creationflags=subprocess.DETACHED_PROCESS)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        self.assertEqual(process.wait(timeout=10), 0)
        result = Path(str(request) + '.result')
        self.assertTrue(json.loads(result.read_text(encoding='utf-8'))['saved'])
        self.assertFalse(request.exists())
        self.assert_clean()

    def test_detached_save_reports_early_schema_error_with_own_request_id(self):
        target = self.root/'invalid-detached.m3u8'
        for changes in (dict(schema=2), dict(operation='paths', mode='open')):
            with self.subTest(changes=changes):
                request = self.detached_request(target)
                data = json.loads(request.read_text(encoding='utf-8'))
                data.update(changes)
                request.write_text(json.dumps(data), encoding='utf-8')
                result = self.finish_detached(self.start_detached(request), request)
                response = json.loads(result.read_text(encoding='utf-8'))
                self.assertEqual(response['request_id'], data['request_id'])
                self.assertEqual(response['error_code'], 'invalid_request')
                self.assertFalse(target.exists())

    def test_detached_unrelated_or_mismatched_request_preserves_original_and_unknown_siblings(self):
        variants = [b'not JSON; preserve these exact bytes',
                    json.dumps(dict(request_id='valid-header', parent_pid=os.getpid())).encode('utf-8'),
                    json.dumps(dict(request_id='bad.id', parent_pid=os.getpid())).encode('utf-8')]
        for index, original in enumerate(variants):
            with self.subTest(index=index):
                request = self.root/('mpvnet-input-bad.id.json' if index == 2 else f'unrelated-{index}.txt')
                request.write_bytes(original)
                cancellation = Path(str(request) + '.cancel')
                result = Path(str(request) + '.result')
                cancellation.write_bytes(b'unknown cancellation occupant')
                result.write_bytes(b'unknown result occupant')
                process = self.start_detached(request)
                stdout, stderr = process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(stdout, b'')
                self.assertEqual(stderr, b'')
                self.assertEqual(request.read_bytes(), original)
                self.assertEqual(cancellation.read_bytes(), b'unknown cancellation occupant')
                self.assertEqual(result.read_bytes(), b'unknown result occupant')
                self.assert_clean()

    def test_detached_result_failure_keeps_unknown_file_and_does_not_undo_saved_target(self):
        target = self.root/'result-failure.m3u8'
        request = self.detached_request(target)
        result = Path(str(request) + '.result')
        result.write_bytes(b'unknown result occupant')
        process = self.start_detached(request)
        self.finish_detached(process, request)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result.read_bytes(), b'unknown result occupant')
        self.assertTrue(target.read_bytes().startswith(b'#EXTM3U\n'))

    def test_detached_cancel_while_waiting_for_commit_preserves_target_and_cleans_owned_files(self):
        target = self.root/'cancelled.m3u8'
        target.write_bytes(b'old bytes')
        request = self.detached_request(target)
        with self.target_lock(target):
            process = self.start_detached(request)
            self.wait_for_writer(process)
            Path(str(request) + '.cancel').write_bytes(b'cancel')
            self.assertIsNone(process.poll())
        result = self.finish_detached(process, request)
        self.assertFalse(result.exists())
        self.assertEqual(target.read_bytes(), b'old bytes')

    def test_detached_real_parent_exit_preserves_target_and_cleans_owned_files(self):
        target = self.root/'parent-exit.m3u8'
        target.write_bytes(b'old bytes')
        parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        self.addCleanup(lambda: parent.poll() is None and parent.kill())
        request = self.detached_request(target, parent_pid=parent.pid)
        with self.target_lock(target):
            process = self.start_detached(request)
            self.wait_for_writer(process)
            parent.terminate()
            parent.wait(timeout=5)
            self.assertIsNone(process.poll(), 'The writer must reach its own cancellation/cleanup instead of being killed')
        result = self.finish_detached(process, request)
        self.assertFalse(result.exists())
        self.assertEqual(target.read_bytes(), b'old bytes')

    def test_invalid_save_control_paths_empty_queue_and_unconfirmed_suffix_are_rejected(self):
        target = self.root/'invalid.m3u8'
        snapshot = self.snapshot(target)
        for entries in ([], [dict(path='bad\nentry.mkv', title='')], [dict(path='bad\x00entry.mkv', title='')]):
            with self.subTest(entries=entries):
                self.assertEqual(self.save(target, entries, snapshot)['error_code'], 'invalid_request')
        for name in ('unexpected.m3u', 'unexpected.txt'):
            response = self.invoke(operation='save-dialog', mode='save', paths=[str(self.root/name)])
            self.assertEqual(response['error_code'], 'invalid_target')
            self.assertFalse((self.root/(Path(name).stem + '.m3u8')).exists())
        self.assertFalse(target.exists())
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()
