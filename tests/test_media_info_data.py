"""Media information contracts and optional real local MediaInfo report fidelity."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave
import zlib

ROOT = Path(__file__).resolve().parents[1]
OVERVIEW_KEYS = {'duration', 'size', 'container', 'resolution', 'fps', 'aspect',
                 'video_codec', 'bit_depth', 'dynamic_range', 'total_bitrate', 'audio', 'subtitle'}


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell')
class MediaInfoDataTests(unittest.TestCase):
    def run_case(self, update=None, properties=None, native=False, corrupt_dll=False, image=False):
        with tempfile.TemporaryDirectory(prefix='mpvnet-media-info-data-') as temp:
            request = Path(temp)/'request.json'
            data = dict(schema=1, token='fixture', parent_pid=os.getpid(), activation_path=str(request)+'.activate',
                        has_media=True, local_path='', title='合成媒体', properties={})
            data.update(update or {})
            data['properties'] = properties or data['properties']
            if native or corrupt_dll or data['local_path'] in ('$fixture', '$linked_fixture'):
                sample_root = Path(temp)/'sample'
                sample_root.mkdir()
                sample = sample_root/'合成音频.wav'
                with wave.open(str(sample), 'wb') as output:
                    output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                    output.writeframes(struct.pack('<h', 0)*8000)
                if image:
                    sample = sample_root/'合成静态图.png'
                    def chunk(kind, body):
                        return struct.pack('>I', len(body))+kind+body+struct.pack('>I', zlib.crc32(kind+body))
                    sample.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))+
                                       chunk(b'IDAT', zlib.compress(b'\0\0\0\0'))+chunk(b'IEND', b''))
                if data['local_path'] == '$linked_fixture':
                    link = Path(temp)/'linked'
                    created = subprocess.run(['cmd.exe', '/c', 'mklink', '/J', str(link), str(sample_root)], capture_output=True)
                    self.assertEqual(created.returncode, 0, created.stderr)
                    data['local_path'] = str(link/sample.name)
                else:
                    data['local_path'] = str(sample)
            request.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
            args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    str(ROOT/'tests/fixtures/media_info_data_probe.ps1'),
                    '-SourcePath', str(ROOT/'config/helpers/media-info-data.cs'),
                    '-RequestPath', str(request), '-ParentPid', str(os.getpid())]
            if native:
                args += ['-MediaInfoDll', os.environ['MPVNET_TEST_MEDIAINFO']]
            if corrupt_dll:
                invalid = Path(temp)/'invalid-image.dll'
                invalid.write_bytes(b'fixture: invalid native image')
                args += ['-MediaInfoDll', str(invalid), '-SkipBaseline']
            result = subprocess.run(args, capture_output=True, timeout=40)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
            return json.loads(result.stdout.decode('utf-8-sig'))

    def test_network_uses_properties_without_file_report_or_invented_sdr(self):
        value = self.run_case(properties=dict(duration=3723, file_size=1048576, container='matroska',
            width=1920, height=1080, aspect=16/9, fps=23.976, video_format='hevc', bit_depth=10,
            gamma='bt.1886', total_bitrate=2000000, audio_codec='aac', sample_rate=48000, channels=2))
        self.assertEqual(value['kind'], 'network')
        self.assertEqual(value['report'], '')
        self.assertEqual(value['error'], '网络媒体未取得完整文件报告。')
        self.assertEqual(set(value['overview']), OVERVIEW_KEYS)
        self.assertEqual(value['overview']['duration'], '01:02:03')
        self.assertEqual(value['overview']['resolution'], '1920 × 1080')
        self.assertEqual(value['overview']['size'], '1 MiB')
        self.assertEqual(value['overview']['total_bitrate'], '2 Mb/s')
        self.assertEqual(value['overview']['dynamic_range'], '')
        self.assertTrue(value['probe_parent_retained'])

    def test_video_bitrate_does_not_become_total_bitrate(self):
        value = self.run_case(properties=dict(video_format='av1', video_bitrate=9000000, gamma='pq'))
        self.assertEqual(value['overview']['total_bitrate'], '')
        self.assertEqual(value['overview']['dynamic_range'], 'PQ')
        self.assertEqual(value['overview']['bit_depth'], '')

    def test_empty_has_no_report_or_fabricated_values(self):
        value = self.run_case(update=dict(has_media=False, title=''), properties=dict(tracks=[]))
        self.assertEqual(value['kind'], 'empty')
        self.assertEqual(value['report'], '')
        self.assertEqual(value['error'], '')
        self.assertTrue(all(item == '' for item in value['overview'].values()))

    def test_known_empty_tracks_differ_from_missing_track_information(self):
        empty = self.run_case(properties=dict(tracks=[]))
        self.assertEqual(empty['overview']['audio'], '未发现音轨')
        self.assertEqual(empty['overview']['subtitle'], '未发现字幕')
        video = self.run_case(properties=dict(tracks=[{'type': 'video', 'codec': 'hevc'}]))
        self.assertEqual(video['overview']['audio'], '未发现音轨')
        self.assertEqual(video['overview']['subtitle'], '未发现字幕')
        missing = self.run_case(update=dict(local_path='$fixture'))
        self.assertTrue(missing['error'])
        self.assertEqual(missing['overview']['audio'], '')
        self.assertEqual(missing['overview']['subtitle'], '')

    def test_selected_tracks_are_primary_with_other_track_counts(self):
        value = self.run_case(properties=dict(tracks=[
            {'id': 1, 'type': 'audio', 'codec': 'aac', 'lang': 'jpn', 'selected': False},
            {'id': 2, 'type': 'audio', 'codec': 'flac', 'lang': 'eng', 'selected': True,
             'audio-channels': 2, 'demux-samplerate': 48000},
            {'id': 3, 'type': 'sub', 'codec': 'ass', 'lang': 'zho'},
            {'id': 4, 'type': 'sub', 'codec': 'subrip', 'lang': 'eng', 'selected': True}]))
        self.assertEqual(value['kind'], 'audio')
        self.assertNotIn('aac', value['overview']['audio'])
        self.assertIn('flac', value['overview']['audio'])
        self.assertIn('48 kHz', value['overview']['audio'])
        self.assertIn('另有 1 条音轨', value['overview']['audio'])
        self.assertNotIn('ass', value['overview']['subtitle'])
        self.assertIn('subrip', value['overview']['subtitle'])
        self.assertIn('另有 1 条字幕', value['overview']['subtitle'])

    def test_missing_dll_keeps_available_overview(self):
        value = self.run_case(update=dict(local_path='$fixture'), properties=dict(duration=1, audio_codec='pcm_s16le'))
        self.assertEqual(value['kind'], 'audio')
        self.assertIn('MediaInfo.dll', value['error'])
        self.assertEqual(value['overview']['duration'], '00:00:01')
        self.assertEqual(value['report'], '')

    def test_url_and_pipe_are_rejected_without_restricting_file_system_paths(self):
        for path in (r'\\.\pipe\never-open', 'https://example.invalid/video'):
            with self.subTest(path=path):
                value = self.run_case(update=dict(local_path=path))
                self.assertTrue(value['error'])
                self.assertEqual(value['report'], '')
                self.assertFalse(value['probe_local_file_accepted'])
                self.assertFalse(value['probe_paths']['https://example.invalid/media'])
                self.assertFalse(value['probe_paths'][r'\\.\pipe\fixture'])
                self.assertFalse(value['probe_paths'][r'\\?\pipe\fixture'])
                self.assertTrue(value['probe_paths'][r'\\fixture-server\share\media.mkv'])
                self.assertTrue(value['probe_paths'][r'Z:\mapped-media.mkv'])

    def test_file_system_link_is_kept_readable(self):
        value = self.run_case(update=dict(local_path='$linked_fixture'))
        self.assertTrue(value['probe_local_file_accepted'])

    def test_bad_native_library_keeps_overview(self):
        value = self.run_case(corrupt_dll=True, properties=dict(duration=3, audio_codec='pcm_s16le'))
        self.assertEqual(value['kind'], 'audio')
        self.assertIn('MediaInfo.dll', value['error'])
        self.assertEqual(value['report'], '')
        self.assertEqual(value['overview']['duration'], '00:00:03')

    def test_url_title_is_not_echoed(self):
        value = self.run_case(update=dict(title='https://example.invalid/video?secret=fixture'))
        self.assertEqual(value['title'], '网络媒体')
        self.assertNotIn('secret', json.dumps(value))

    @unittest.skipUnless(os.environ.get('MPVNET_TEST_MEDIAINFO'), 'Set MPVNET_TEST_MEDIAINFO to an existing local MediaInfo.dll')
    def test_native_report_matches_default_mediainfo_inform(self):
        self.assertTrue(Path(os.environ['MPVNET_TEST_MEDIAINFO']).is_file())
        # A player's cover-art dimensions must not turn an audio file into video.
        value = self.run_case(native=True, properties=dict(width=600, height=600, video_format='mjpeg', tracks=[
            {'id': 1, 'type': 'audio', 'codec': 'pcm_s16le', 'selected': False},
            {'id': 2, 'type': 'audio', 'codec': 'flac', 'lang': 'jpn', 'selected': True},
            {'id': 3, 'type': 'sub', 'codec': 'ass', 'lang': 'zho', 'selected': True}]))
        self.assertEqual(value['error'], '')
        self.assertEqual(value['kind'], 'audio')
        self.assertEqual(value['report'], value['probe_default_report'])
        self.assertGreater(len(value['report']), 200)
        self.assertIn('General', value['report'])
        self.assertIn('Audio', value['report'])
        self.assertGreater(value['probe_complete_report_length'], len(value['report']))
        self.assertTrue(value['overview']['duration'])
        self.assertTrue(value['overview']['audio'])
        self.assertTrue(value['overview']['size'])
        self.assertIn('flac', value['overview']['audio'])
        self.assertNotIn('PCM', value['overview']['audio'])
        self.assertIn('另有 1 条音轨', value['overview']['audio'])
        self.assertEqual(value['overview']['subtitle'], 'ass · zho')
        self.assertTrue(value['probe_parent_retained'])
        # No mpv tracks/codecs may hide a size_t(-1) Count_Get ABI error here.
        fallback = self.run_case(native=True, properties={})
        self.assertEqual(fallback['error'], '')
        self.assertEqual(fallback['kind'], 'audio')
        self.assertEqual(fallback['report'], fallback['probe_default_report'])
        self.assertIn('PCM', fallback['overview']['audio'])
        self.assertIn('1 channel', fallback['overview']['audio'])
        self.assertRegex(fallback['overview']['audio'], r'\b(?:8[ ,]?000 Hz|8(?:\.0+)? kHz)\b')
        self.assertEqual(fallback['overview']['subtitle'], '未发现字幕')
        no_audio = self.run_case(native=True, properties={}, image=True)
        self.assertEqual(no_audio['error'], '')
        self.assertTrue(no_audio['report'])
        self.assertEqual(no_audio['overview']['audio'], '未发现音轨')
        self.assertEqual(no_audio['overview']['subtitle'], '未发现字幕')


if __name__ == '__main__':
    unittest.main()
