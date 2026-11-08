"""Playlist controls are precompiled and tied to their fixed source inputs."""

import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from support.dev_imports import stage_package


ROOT = Path(__file__).resolve().parents[1]
BUILD = runpy.run_path(str(ROOT/'dev-tools/build-playlist-window.py'))


class PlaylistWindowBuild(unittest.TestCase):
    def copy_inputs(self, source):
        for name in BUILD['SOURCE_FILES']:
            target = source/name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT/name).read_bytes())

    def test_digest_covers_fixed_sources_and_ignores_unrelated_files(self):
        with tempfile.TemporaryDirectory(prefix='playlist-window-sources-') as temp:
            source = Path(temp)
            self.copy_inputs(source)
            expected = BUILD['source_digest'](ROOT)
            (source/'not-a-build-input.txt').touch()
            self.assertEqual(BUILD['source_digest'](source), expected)
            for name in BUILD['SOURCE_FILES']:
                with self.subTest(name=name):
                    target = source/name
                    original = target.read_bytes()
                    target.write_bytes(original + b'\n')
                    self.assertNotEqual(BUILD['source_digest'](source), expected)
                    target.unlink()
                    with self.assertRaisesRegex(ValueError, 'missing or linked playlist window source'):
                        BUILD['source_digest'](source)
                    target.write_bytes(original)

    def test_metadata_matches_current_source_and_has_its_own_identity(self):
        data = (ROOT/BUILD['ASSET_PATH']).read_bytes()
        digest = BUILD['source_digest'](ROOT)
        with patch('subprocess.run') as process, patch('shutil.which') as sdk:
            self.assertTrue(BUILD['matches_source_digest'](data, digest))
            self.assertFalse(BUILD['matches_source_digest'](data, '0' * 64))
            self.assertFalse(BUILD['matches_source_digest'](b'MZ stale dll', digest))
            self.assertFalse(BUILD['matches_source_digest']((ROOT/'config/helpers/KitSettings.exe').read_bytes(), digest))
        process.assert_not_called()
        sdk.assert_not_called()

    def test_packaging_rejects_missing_or_stale_sources_without_starting_sdk(self):
        with tempfile.TemporaryDirectory(prefix='playlist-window-package-') as temp:
            root = Path(temp)
            source, destination = root/'source', root/'package'
            self.copy_inputs(source)
            asset = source/BUILD['ASSET_PATH']
            asset.write_bytes((ROOT/BUILD['ASSET_PATH']).read_bytes())
            spec = root/'map.json'
            spec.write_text(json.dumps(dict(schema=1, version='test', files=[dict(
                source=BUILD['ASSET_PATH'], destination=BUILD['ASSET_PATH'], component='author', origin='test')])), encoding='utf-8')
            control = source/BUILD['SOURCE_FILES'][0]
            original = control.read_bytes()
            with patch('subprocess.run') as process, patch('shutil.which') as sdk:
                stage_package(source, destination, spec)
                control.unlink()
                with self.assertRaisesRegex(ValueError, 'missing or linked playlist window source'):
                    stage_package(source, destination, spec, apply=True)
                control.write_bytes(original + b'\n')
                with self.assertRaisesRegex(ValueError, 'does not match its sources'):
                    stage_package(source, destination, spec, apply=True)
                control.write_bytes(original)
                asset.write_bytes(b'MZ stale dll')
                with self.assertRaisesRegex(ValueError, 'does not match its sources'):
                    stage_package(source, destination, spec, apply=True)
            process.assert_not_called()
            sdk.assert_not_called()
            self.assertFalse(destination.exists())

    def test_preview_reads_inputs_without_sdk_or_output_writes(self):
        with tempfile.TemporaryDirectory(prefix='playlist-window-preview-') as temp:
            output = Path(temp)/'unused'/'fresh'
            with patch('subprocess.run') as process, patch('shutil.which') as sdk:
                evidence = BUILD['build_playlist_window'](output)
            process.assert_not_called()
            sdk.assert_not_called()
            self.assertFalse(output.parent.exists())
            self.assertEqual(set(evidence['sourceFiles']), set(BUILD['SOURCE_FILES']))
            self.assertEqual(evidence['sourceSha256'], BUILD['source_digest'](ROOT))

    def test_output_uses_shared_source_and_player_isolation(self):
        with tempfile.TemporaryDirectory(prefix='playlist-window-output-') as temp:
            root = Path(temp)
            (root/'player'/'portable_config').mkdir(parents=True)
            for output in (ROOT/'unsafe-build', root/'player'/'unsafe-build', root):
                with self.subTest(output=output), self.assertRaises(ValueError):
                    BUILD['validate_output'](output)
            self.assertFalse((ROOT/'unsafe-build').exists())
            self.assertFalse((root/'player'/'unsafe-build').exists())


@unittest.skipUnless(os.name == 'nt', 'Actual Framework library build requires Windows')
class PlaylistWindowCompilation(unittest.TestCase):
    def test_offline_build_records_inputs_and_loads_hidden_controls(self):
        with tempfile.TemporaryDirectory(prefix='playlist-window-build-') as temp:
            root = Path(temp)
            output = root/'fresh'
            evidence = BUILD['build_playlist_window'](output, apply=True)
            dll = output/BUILD['ASSEMBLY']
            image = dll.read_bytes()
            self.assertTrue(BUILD['matches_source_digest'](image, BUILD['source_digest'](ROOT)))
            self.assertEqual(evidence, json.loads((output/'build-evidence.json').read_text(encoding='utf-8')))
            self.assertEqual(evidence['assemblySha256'], hashlib.sha256(image).hexdigest())
            self.assertEqual(evidence['targetFramework'], '.NETFramework,Version=v4.7.2')
            self.assertEqual(evidence['target'], 'library')
            self.assertEqual(set(evidence['referenceFiles']), set(BUILD['REFERENCE_FILES']))
            pe = int.from_bytes(image[60:64], 'little')
            self.assertTrue(int.from_bytes(image[pe+22:pe+24], 'little') & 0x2000, 'PE must be a DLL')
            probe = root/'probe.ps1'
            probe.write_text('''param([string]$DllPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path $DllPath
$form=New-Object PlaylistForm
$keys=New-Object PlaylistKeys($form)
try {
    $keys.MenuActive=$true
    $menuTypes=@($form.GetType().Assembly.GetTypes() | Where-Object { [Windows.Forms.ContextMenuStrip].IsAssignableFrom($_) })
    @{shown=$form.Visible; menu_active=$keys.MenuActive; menu_types=$menuTypes.Count; caption=$form.Text} | ConvertTo-Json -Compress
} finally { $keys.Dispose(); $form.Dispose() }
''', encoding='utf-8-sig')
            result = subprocess.run(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                                     '-File', str(probe), '-DllPath', str(dll)], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
            response = json.loads(result.stdout.decode('utf-8-sig'))
            self.assertFalse(response['shown'])
            self.assertTrue(response['menu_active'])
            self.assertGreater(response['menu_types'], 0)


if __name__ == '__main__':
    unittest.main()
