"""The precompiled settings window is tied to its exact build inputs."""

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
BUILD = runpy.run_path(str(ROOT / 'dev-tools/build-settings-window.py'))
ASSET = BUILD['ASSET_PATH']
INPUTS = BUILD['SOURCE_FILES']


class SettingsBuild(unittest.TestCase):
    def copy_inputs(self, source):
        for name in INPUTS:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())

    def test_digest_covers_each_fixed_input_and_ignores_other_files(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            self.copy_inputs(source)
            digest = BUILD['source_digest']
            expected = digest(ROOT)
            (source / 'unrelated.txt').touch()
            self.assertEqual(digest(source), expected)
            for name in INPUTS:
                with self.subTest(name=name):
                    path = source / name
                    original = path.read_bytes()
                    path.write_bytes(original + b'\r\n')
                    self.assertNotEqual(digest(source), expected)
                    path.write_bytes(original)
            (source / BUILD['MANIFEST']).unlink()
            with self.assertRaisesRegex(ValueError, 'missing or linked settings source'):
                digest(source)

    def test_staging_checks_settings_sources_without_starting_the_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, destination = root / 'source', root / 'package'
            self.copy_inputs(source)
            (source / ASSET).write_bytes((ROOT / ASSET).read_bytes())
            mapping = {'schema': 1, 'version': 'test', 'files': [
                {'source': ASSET, 'destination': ASSET, 'component': 'author', 'origin': 'test'},
            ]}
            spec = root / 'map.json'
            spec.write_text(json.dumps(mapping), encoding='utf-8')
            path = source / 'config/helpers/settings-host.cs'
            original = path.read_bytes()
            with patch('subprocess.run') as process:
                stage_package(source, destination, spec)
                path.unlink()
                with self.assertRaisesRegex(ValueError, 'missing or linked settings source'):
                    stage_package(source, destination, spec, apply=True)
                path.write_bytes(original + b'\n')
                with self.assertRaisesRegex(ValueError, 'does not match its sources'):
                    stage_package(source, destination, spec, apply=True)
                path.write_bytes(original)
                (source / ASSET).write_bytes(b'MZ stale executable')
                with self.assertRaisesRegex(ValueError, 'does not match its sources'):
                    stage_package(source, destination, spec, apply=True)
            process.assert_not_called()
            self.assertFalse(destination.exists())

    def test_output_must_be_fresh_and_outside_source_and_player(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            source = root / 'source'
            player = root / 'player'
            (player / 'portable_config').mkdir(parents=True)
            roaming, local, home = root / 'roaming', root / 'local', root / 'mpvnet-home'
            validate = BUILD['validate_output']
            with patch.dict(os.environ, {'APPDATA': str(roaming), 'LOCALAPPDATA': str(local), 'MPVNET_HOME': str(home)}):
                for parent in (source, player, roaming / 'mpv.net', local / 'mpv.net', home):
                    output = parent / 'fresh'
                    with self.subTest(parent=parent.name), self.assertRaisesRegex(ValueError, 'outside'):
                        validate(output, source)
                    self.assertFalse(output.exists())
                output = root / 'outside'
                self.assertEqual(validate(output, source), output)
                output.mkdir()
                with self.assertRaisesRegex(ValueError, 'fresh'):
                    validate(output, source)

    def test_output_refuses_links_in_the_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            target, link = root / 'target', root / 'link'
            target.mkdir()
            if os.name == 'nt':
                subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/j', str(link), str(target)],
                               check=True, capture_output=True)
            else:
                link.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'link or junction'):
                BUILD['validate_output'](link / 'output', root / 'source')
            self.assertFalse((target / 'output').exists())

    def test_dry_run_reads_sources_without_touching_sdk_or_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'unused' / 'fresh'
            with patch('subprocess.run') as process, patch('shutil.which') as sdk:
                evidence = BUILD['build_settings_window'](output)
            process.assert_not_called()
            sdk.assert_not_called()
            self.assertFalse(output.parent.exists())
            self.assertEqual(evidence['sourceSha256'], BUILD['source_digest'](ROOT))
            self.assertEqual(set(evidence['sourceFiles']), set(INPUTS))
