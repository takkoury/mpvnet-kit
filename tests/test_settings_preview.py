"""Compile actual preview C# and test crop geometry without creating a window."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell/WPF assemblies')
class SettingsPreviewGeometry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cases = []
        for mode in ['full', 'subtitles', 'controlbar']:
            for position in [0, 50, 100]:
                cases.append(dict(name=f'{mode}-{position}', width=1920, height=1080,
                                  bounds=[10, 20, 600, 300], mode=mode, position=position))
        cases.extend([
            dict(name='repeat', width=1920, height=1080, bounds=[10, 20, 600, 300], mode='subtitles', position=100),
            dict(name='portrait', width=1080, height=1920, bounds=[0, 0, 600, 300], mode='subtitles', position=50),
            dict(name='portrait-bottom', width=1080, height=1920, bounds=[0, 0, 600, 300], mode='controlbar', position=50),
            dict(name='clamp-low', width=1920, height=1080, bounds=[10, 20, 600, 300], mode='subtitles', position=-99),
            dict(name='clamp-high', width=1920, height=1080, bounds=[10, 20, 600, 300], mode='subtitles', position=201),
            dict(name='dpi150', width=1920, height=1080, bounds=[15, 30, 900, 450], mode='subtitles', position=100),
            dict(name='dpi200', width=1920, height=1080, bounds=[20, 40, 1200, 600], mode='controlbar', position=100),
            dict(name='tiny', width=1, height=1, bounds=[0, 0, 1, 1], mode='subtitles', position=100),
            dict(name='zero-source', width=0, height=1080, bounds=[0, 0, 600, 300], mode='full', position=100),
            dict(name='zero-bounds', width=1920, height=1080, bounds=[0, 0, 0, 300], mode='full', position=100),
            dict(name='unknown-mode', width=1920, height=1080, bounds=[10, 20, 600, 300], mode='unknown', position=100),
        ])
        script = r'''
param([string]$SourcePath, [string]$CasesPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$references = @('System.Core', 'System.Xaml', [Windows.Window].Assembly.Location,
    [Windows.Media.Brushes].Assembly.Location, [Windows.Threading.Dispatcher].Assembly.Location)
Add-Type -Path $SourcePath -ReferencedAssemblies $references
function Coordinates($rect) { return @($rect.X, $rect.Y, $rect.Width, $rect.Height) }
$results = @{}
foreach ($case in (Get-Content -LiteralPath $CasesPath -Raw | ConvertFrom-Json)) {
    $bounds = New-Object Windows.Rect($case.bounds[0], $case.bounds[1], $case.bounds[2], $case.bounds[3])
    $geometry = [SettingsPreviewGeometry]::Calculate($bounds, $case.width, $case.height, $case.mode, $case.position)
    if ($geometry.Source.IsEmpty) { $results[$case.name] = @{empty=$true}; continue }
    $results[$case.name] = @{source=(Coordinates $geometry.Source); destination=(Coordinates $geometry.Destination); scale=$geometry.Scale}
}
# Guard invalid runtime values, without using JSON's unsupported NaN/Infinity.
$normal = New-Object Windows.Rect(0, 0, 600, 300)
$results['nan-source'] = @{empty=([SettingsPreviewGeometry]::Calculate($normal, [Double]::NaN, 1080, 'full').Source.IsEmpty)}
$results['infinite-source'] = @{empty=([SettingsPreviewGeometry]::Calculate($normal, 1920, [Double]::PositiveInfinity, 'full').Source.IsEmpty)}
$results['nan-position'] = @{source=(Coordinates ([SettingsPreviewGeometry]::Calculate($normal, 1920, 1080, 'subtitles', [Double]::NaN).Source))}
$crop = New-Object Windows.Rect(0, 594, 1920, 486)
$outer = New-Object Windows.Rect(-1200, 100, 1936, 1120)
$origin = New-Object Windows.Point(-1192, 132)
$results['client-to-window'] = @{source=(Coordinates ([SettingsPreviewGeometry]::SourceInWindow($crop, $outer, $origin, 1936, 1120)))}
# DPI-virtualized window coordinates map to the physical DWM texture once.
$results['client-to-window-dpi150'] = @{source=(Coordinates ([SettingsPreviewGeometry]::SourceInWindow($crop, $outer, $origin, 2904, 1680)))}
$over = New-Object Windows.Rect(-20, -50, 2000, 1200)
$results['client-to-window-clamp'] = @{source=(Coordinates ([SettingsPreviewGeometry]::SourceInWindow($over, $outer, $origin, 1936, 1120)))}
$zero = New-Object Windows.Rect(0, 0, 0, 0)
$results['client-to-window-invalid'] = @{empty=([SettingsPreviewGeometry]::SourceInWindow($crop, $zero, $origin, 1936, 1120).IsEmpty)}
$results | ConvertTo-Json -Depth 5 -Compress
'''
        with tempfile.TemporaryDirectory(prefix='mpvnet-settings-geometry-') as temp:
            probe = Path(temp) / 'probe.ps1'
            inputs = Path(temp) / 'cases.json'
            probe.write_text(script, encoding='utf-8')
            inputs.write_text(json.dumps(cases), encoding='utf-8')
            result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', str(probe), '-SourcePath', str(ROOT / 'config/helpers/settings-preview.cs'),
                '-CasesPath', str(inputs)], capture_output=True, timeout=30)
        if result.returncode or result.stderr:
            raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
        cls.frames = json.loads(result.stdout.decode('utf-8-sig'))

    def test_subtitle_crop_tracks_top_middle_and_bottom(self):
        self.assertEqual(self.frames['subtitles-0']['source'], [0, 0, 1920, 486])
        self.assertEqual(self.frames['subtitles-50']['source'], [0, 297, 1920, 486])
        self.assertEqual(self.frames['subtitles-100']['source'], [0, 594, 1920, 486])

    def test_controlbar_crop_keeps_bottom_and_ignores_subtitle_position(self):
        for position in [0, 50, 100]:
            self.assertEqual(self.frames[f'controlbar-{position}']['source'], [0, 702, 1920, 378])

    def test_position_changes_never_change_scale_or_destination(self):
        base = self.frames['subtitles-0']
        for position in [50, 100]:
            frame = self.frames[f'subtitles-{position}']
            self.assertEqual(frame['scale'], base['scale'])
            self.assertEqual(frame['destination'], base['destination'])
        self.assertEqual(self.frames['repeat'], self.frames['subtitles-100'])

    def test_destination_preserves_aspect_and_stays_inside_preview(self):
        for name, frame in self.frames.items():
            if 'destination' not in frame:
                continue
            with self.subTest(name=name):
                sx, sy, sw, sh = frame['source']
                x, y, width, height = frame['destination']
                self.assertAlmostEqual(width / height, sw / sh)
                self.assertAlmostEqual(width / sw, frame['scale'])
                self.assertAlmostEqual(height / sh, frame['scale'])
                bx, by, bw, bh = ([15, 30, 900, 450] if name == 'dpi150' else
                    [20, 40, 1200, 600] if name == 'dpi200' else [0, 0, 1, 1] if name == 'tiny' else
                    [0, 0, 600, 300] if name.startswith('portrait') else [10, 20, 600, 300])
                self.assertGreaterEqual(x, bx - 1e-8)
                self.assertGreaterEqual(y, by - 1e-8)
                self.assertLessEqual(x + width, bx + bw + 1e-8)
                self.assertLessEqual(y + height, by + bh + 1e-8)

    def test_portrait_crop_fits_height_without_distortion(self):
        self.assertEqual(self.frames['portrait']['source'], [0, 528, 1080, 864])
        self.assertAlmostEqual(self.frames['portrait']['scale'], 300 / 864)
        self.assertEqual(self.frames['portrait-bottom']['source'], [0, 1248, 1080, 672])

    def test_out_of_range_positions_clamp_without_growing_crop(self):
        self.assertEqual(self.frames['clamp-low'], self.frames['subtitles-0'])
        self.assertEqual(self.frames['clamp-high'], self.frames['subtitles-100'])
        self.assertEqual(self.frames['nan-position']['source'], self.frames['subtitles-100']['source'])

    def test_dpi_changes_destination_pixels_and_preserves_source_crop(self):
        for name, base, factor in [('dpi150', 'subtitles-100', 1.5), ('dpi200', 'controlbar-100', 2)]:
            self.assertEqual(self.frames[name]['source'], self.frames[base]['source'])
            for actual, original in zip(self.frames[name]['destination'], self.frames[base]['destination']):
                self.assertAlmostEqual(actual, original * factor)

    def test_full_picture_fallback_and_unknown_mode_are_full_client(self):
        for position in [0, 50, 100]:
            self.assertEqual(self.frames[f'full-{position}']['source'], [0, 0, 1920, 1080])
        self.assertEqual(self.frames['unknown-mode'], self.frames['full-100'])

    def test_empty_and_nonfinite_sources_do_not_produce_rectangles(self):
        for name in ['zero-source', 'zero-bounds', 'nan-source', 'infinite-source']:
            self.assertTrue(self.frames[name]['empty'], name)

    def test_minimum_source_stays_positive_and_in_bounds(self):
        self.assertEqual(self.frames['tiny']['source'], [0, 0, 1, 1])
        self.assertEqual(self.frames['tiny']['destination'], [0, 0, 1, 1])

    def test_client_crop_maps_to_full_window_texture_with_nonclient_offset(self):
        self.assertEqual(self.frames['client-to-window']['source'], [8, 626, 1920, 486])
        self.assertEqual(self.frames['client-to-window-dpi150']['source'], [12, 939, 2880, 729])

    def test_full_window_source_mapping_clamps_invalid_edges(self):
        self.assertEqual(self.frames['client-to-window-clamp']['source'], [0, 0, 1936, 1120])
        self.assertTrue(self.frames['client-to-window-invalid']['empty'])
