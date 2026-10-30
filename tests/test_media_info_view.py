"""Actual WPF media view; immutable synthetic reports and no native windows."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPORT = (
    'General\r\nComplete name : D:\\Videos\\fixture.mkv\r\n'
    'URL : https://example.test/media?q=one:two\r\n'
    'Duration : 00:24:18.000\r\n\r\nVideo\r\nFormat : HEVC\r\n'
    'Display aspect ratio : 16:9\r\nChroma subsampling : 4:2:0\r\n'
    'Audio #1\r\nLanguage：Japanese\r\n\r\nMenu\r\n'
    '00:08:20.000 : Chapter two\r\n'
    'https://example.test/raw:report\r\nUnparsed line with [future] data\r\n'
)


def media(**changes):
    value = dict(title='山间的一天.mkv', kind='local', error='', report=REPORT,
                 overview=dict(duration='24 min 18 s', size='1.42 GiB', container='Matroska',
                               resolution='1920 × 1080', fps='23.976 fps', aspect='16:9',
                               video_codec='HEVC', bit_depth='10 bit', dynamic_range='SDR',
                               total_bitrate='8.37 Mb/s', audio='Japanese · AAC · 48 kHz', subtitle='Chinese · ASS'))
    value.update(changes)
    return value


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF')
class MediaInfoViewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = Path(os.environ.get('MPVNET_MEDIA_VIEW_ARTIFACTS',
                                  'D:/artifacts/mpvnet-kit/m2-d5-media-20261031'))
        cls.output = base / ('view-tests-' + uuid.uuid4().hex[:10])
        cls.output.mkdir(parents=True, exist_ok=False)

    def run_view(self, item=None, steps=(), width=740, height=620, render=False, request_changes=None):
        folder = self.output / (self._testMethodName + '-' + uuid.uuid4().hex[:6])
        folder.mkdir()
        request = dict(schema=1, token='media-fixture', parent_pid=os.getpid(),
                       activation_path=str(folder / 'activation.serial'))
        request.update(request_changes or {})
        # A pending request must remain unconsumed in NoShow, even on Run/Tick.
        (folder / 'activation.serial').write_text('37', encoding='ascii')
        source = folder / 'request.json'
        source.write_text(json.dumps(dict(request=request, fixture_parent_pid=os.getpid(), media=item or media(), steps=list(steps),
                                         width=width, height=height), ensure_ascii=False), encoding='utf-8')
        args = ['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
                str(ROOT / 'tests/fixtures/media_info_view_probe.ps1'), '-SourcePath',
                str(ROOT / 'config/helpers/media-info-view.cs'), '-InputPath', str(source)]
        if render:
            args += ['-RenderPath', str(folder / 'view.png')]
        result = subprocess.run(args, capture_output=True, timeout=35)
        (folder / 'stdout.json').write_bytes(result.stdout)
        (folder / 'stderr.txt').write_bytes(result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return json.loads(result.stdout.decode('utf-8-sig'))

    def test_no_show_run_tick_snapshot_and_dispose_never_create_hwnd_or_timer(self):
        data = self.run_view(steps=[dict(run=True), dict(loaded=True)])
        for name in ('handle_created', 'timer_created', 'timer_running', 'shown', 'owner_attached',
                     'show_in_taskbar', 'topmost', 'disposed_handle_created'):
            self.assertFalse(data[name], (name, data))
        self.assertEqual(data['last_seen_serial'], 0)

    def test_report_preserves_every_line_timestamp_url_unknown_and_original_copy(self):
        data = self.run_view(steps=[dict(page='details')])
        self.assertEqual(data['report'], REPORT)
        self.assertEqual(data['copy_source'], REPORT)
        self.assertEqual([row['raw'] for row in data['parsed_rows']], REPORT.split('\r\n'))
        fields = {row['key']: row['value'] for row in data['parsed_rows'] if row['type'] == 'field'}
        self.assertEqual(fields['00:08:20.000'], 'Chapter two')
        self.assertEqual(fields['URL'], 'https://example.test/media?q=one:two')
        self.assertEqual(fields['Display aspect ratio'], '16:9')
        self.assertEqual(fields['Language'], 'Japanese')
        raw = [row['raw'] for row in data['parsed_rows'] if row['type'] == 'raw']
        self.assertIn('https://example.test/raw:report', raw)
        self.assertIn('Unparsed line with [future] data', raw)

    def test_search_highlights_without_hiding_rows_and_clear_restores_plain_report(self):
        data = self.run_view(steps=[dict(page='details'), dict(query='HEVC'), dict(query='no-such-field'), dict(query='')])
        full, found, missing, restored = data['history']
        for snapshot in data['history']:
            self.assertEqual([row['raw'] for row in snapshot['visible_rows']], REPORT.split('\r\n'))
        self.assertIn('HEVC', [text for row in found['visible_rows'] for text in row['selected_text']])
        self.assertEqual(found['match_count'], '1 处')
        self.assertEqual(missing['highlighted_rows'], [])
        self.assertEqual(missing['match_count'], '0 处')
        self.assertEqual(restored['visible_rows'], full['visible_rows'])
        self.assertTrue(all(entry['copy_source'] == REPORT for entry in data['history']))

    def test_search_scrolls_to_late_match_and_keeps_unmatched_fields(self):
        report = 'General\n' + '\n'.join('Field %d : Value %d' % (i, i) for i in range(90)) + '\nLast : needle'
        data = self.run_view(media(report=report), steps=[dict(page='details'), dict(query='needle')], render=True)
        self.assertGreater(data['report_offset'], 0)
        self.assertEqual(len(data['visible_rows']), 92)
        self.assertIn('needle', data['visible_rows'][-1]['selected_text'])

    def test_copy_uses_available_overview_or_complete_original_report_per_tab(self):
        data = self.run_view(steps=[dict(page='overview'), dict(page='details'), dict(page='overview')])
        first, detail, last = data['history']
        self.assertIn('山间的一天.mkv', first['copy_source'])
        self.assertIn('Japanese', first['copy_source'])
        self.assertEqual(detail['copy_source'], REPORT)
        self.assertEqual(first['copy_source'], last['copy_source'])
        for item in [media(kind='network', report='', error='网络媒体未取得完整文件报告。'),
                     media(report='', error='无法读取媒体文件')]:
            available = self.run_view(item, steps=[dict(page='overview'), dict(page='details')])
            self.assertTrue(available['history'][0]['copy_enabled'])
            self.assertIn('Japanese', available['history'][0]['copy_source'])
            self.assertFalse(available['history'][1]['copy_enabled'])

    def test_layout_has_scrollable_content_right_confirmation_and_no_reading_underlines(self):
        for width, height in [(740, 620), (380, 440)]:
            with self.subTest(width=width):
                data = self.run_view(steps=[dict(page='details')], width=width, height=height, render=True)
                self.assertTrue(data['footer_fits'], data)
                self.assertGreater(data['report_viewport'], 30)
                self.assertTrue(data['reading_controls_unbordered'])
                self.assertEqual(data['confirm_background'].upper(), '#FF1287BB')

    def test_overview_uses_only_supplied_values_and_missing_fields_are_explicit(self):
        data = self.run_view(media(overview=dict(audio='FLAC·96 kHz', subtitle='Chinese · ASS')), render=True)
        self.assertEqual(data['page'], 'overview')
        self.assertIn('FLAC', data['overview_text'])
        self.assertIn('Chinese', data['overview_text'])
        self.assertNotIn('1920', data['overview_text'])
        self.assertNotIn('1.42', data['overview_text'])
        self.assertTrue(data['footer_fits'])
        for segment in ['FLAC', '96 kHz', 'Chinese', 'ASS']:
            self.assertIn(segment, data['segment_values'])
        self.assertTrue(all('·' not in segment for segment in data['segment_values']))

    def test_empty_network_audio_and_read_failure_keep_explicit_states(self):
        cases = [
            (media(kind='empty', title='', overview={}, report=''), '没有可显示的信息'),
            (media(kind='network', overview=dict(audio='AAC'), report='', error='网络媒体未取得完整文件报告。'), '未取得完整文件报告'),
            (media(kind='audio', overview=dict(audio='FLAC · 96 kHz'), report='General\nFormat : FLAC\nAudio\nSampling rate : 96.0 kHz'), 'Sampling rate'),
            (media(report='', error='无法读取媒体文件'), '未能读取完整详情'),
        ]
        for item, expected in cases:
            with self.subTest(kind=item['kind'], error=item['error']):
                data = self.run_view(item, steps=[dict(page='details')])
                self.assertIn(expected, data['display_text'] + '\n' + data['report'])
                if not item['report']:
                    self.assertFalse(data['copy_enabled'])
                if item['kind'] == 'network':
                    self.assertEqual(data['notice'], '')
                    self.assertNotIn('1.42', data['overview_text'])

    def test_invalid_parent_identity_is_rejected(self):
        folder = self.output / 'invalid-parent'
        folder.mkdir()
        request = dict(schema=1, token='fixture', parent_pid=os.getpid() + 1, activation_path=str(folder / 'serial'))
        source = folder / 'request.json'
        source.write_text(json.dumps(dict(request=request, fixture_parent_pid=os.getpid(), media=media(), steps=[])), encoding='utf-8')
        result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
                                 str(ROOT / 'tests/fixtures/media_info_view_probe.ps1'), '-SourcePath',
                                 str(ROOT / 'config/helpers/media-info-view.cs'), '-InputPath', str(source)],
                                capture_output=True, timeout=35)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
