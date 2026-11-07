"""Precompiled input helper provenance and deterministic offline build checks."""

import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from support import dev_imports  # Establish the shared developer-tool import path.


ROOT = Path(__file__).resolve().parents[1]
BUILD = runpy.run_path(str(ROOT/'dev-tools/build-playlist-input.py'))


class PlaylistInputBuild(unittest.TestCase):
    def copy_inputs(self, source):
        for name in BUILD['SOURCE_FILES']:
            target = source/name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT/name).read_bytes())

    def test_source_digest_covers_only_fixed_inputs_and_requires_each(self):
        with tempfile.TemporaryDirectory(prefix='playlist-input-sources-') as temp:
            source = Path(temp)
            self.copy_inputs(source)
            digest = BUILD['source_digest']
            expected = digest(ROOT)
            (source/'not-a-build-input.txt').write_text('ignored', encoding='utf-8')
            self.assertEqual(digest(source), expected)
            for name in BUILD['SOURCE_FILES']:
                with self.subTest(name=name):
                    target = source/name
                    original = target.read_bytes()
                    target.write_bytes(original + b'\n')
                    self.assertNotEqual(digest(source), expected)
                    target.unlink()
                    with self.assertRaisesRegex(ValueError, 'missing or linked playlist input source'):
                        digest(source)
                    target.write_bytes(original)

    def test_asset_metadata_matches_current_sources_and_uses_its_own_key(self):
        data = (ROOT/BUILD['ASSET_PATH']).read_bytes()
        with patch('subprocess.run') as process, patch('shutil.which') as sdk:
            self.assertTrue(BUILD['matches_source_digest'](data, BUILD['source_digest'](ROOT)))
            self.assertFalse(BUILD['matches_source_digest'](data, '0' * 64))
            self.assertFalse(BUILD['matches_source_digest'](b'MZ stale executable', BUILD['source_digest'](ROOT)))
            self.assertFalse(BUILD['matches_source_digest']((ROOT/'config/helpers/KitSettings.exe').read_bytes(),
                                                         BUILD['source_digest'](ROOT)))
        process.assert_not_called()
        sdk.assert_not_called()

    def test_preview_validates_sources_without_sdk_or_output_writes(self):
        with tempfile.TemporaryDirectory(prefix='playlist-input-preview-') as temp:
            output = Path(temp)/'unused'/'fresh'
            with patch('subprocess.run') as process, patch('shutil.which') as sdk:
                evidence = BUILD['build_playlist_input'](output)
            process.assert_not_called()
            sdk.assert_not_called()
            self.assertFalse(output.parent.exists())
            self.assertEqual(set(evidence['sourceFiles']), set(BUILD['SOURCE_FILES']))
            self.assertEqual(evidence['sourceSha256'], BUILD['source_digest'](ROOT))

    def test_output_protection_is_shared_with_settings(self):
        with tempfile.TemporaryDirectory(prefix='playlist-input-output-') as temp:
            root = Path(temp)
            (root/'player'/'portable_config').mkdir(parents=True)
            for output in (ROOT/'unsafe-build', root/'player'/'unsafe-build', root):
                with self.subTest(output=output), self.assertRaises(ValueError):
                    BUILD['validate_output'](output)
            self.assertFalse((ROOT/'unsafe-build').exists())
            self.assertFalse((root/'player'/'unsafe-build').exists())


@unittest.skipUnless(os.name == 'nt', 'Actual Framework executable build requires Windows')
class PlaylistInputCompilation(unittest.TestCase):
    def test_actual_offline_build_compiles_current_sources_and_records_inputs(self):
        with tempfile.TemporaryDirectory(prefix='playlist-input-build-') as temp:
            output = Path(temp)/'fresh'
            evidence = BUILD['build_playlist_input'](output, apply=True)
            image = (output/BUILD['ASSEMBLY']).read_bytes()
            # A later local SDK may emit different bytes. Provenance checks use
            # the source digest; reproducibility requires the recorded compiler
            # and reference hashes as well as the same source inputs.
            self.assertTrue(BUILD['matches_source_digest'](image, BUILD['source_digest'](ROOT)))
            self.assertEqual(evidence, json.loads((output/'build-evidence.json').read_text(encoding='utf-8')))
            self.assertEqual(evidence['assemblySha256'], hashlib.sha256(image).hexdigest())
            self.assertEqual(evidence['targetFramework'], '.NETFramework,Version=v4.7.2')
            self.assertEqual(set(evidence['referenceFiles']), set(BUILD['REFERENCE_FILES']))
            pe = int.from_bytes(image[60:64], 'little')
            self.assertEqual(int.from_bytes(image[pe+24+68:pe+24+70], 'little'), 2)
            request = Path(temp)/'request.json'
            request.write_text(json.dumps(dict(schema=1, request_id='build-check-1', parent_pid=os.getpid(),
                operation='paths', mode='open', working_directory=str(Path(temp)), paths=[],
                video_exts=[], audio_exts=[], subtitle_exts=[], existing_paths=[])), encoding='utf-8')
            result = subprocess.run([str(output/BUILD['ASSEMBLY']), '-RequestPath', str(request)],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            response = json.loads(result.stdout.decode('utf-8-sig'))
            self.assertEqual(response['status'], 'ok')
            self.assertEqual(response['request_id'], 'build-check-1')
            self.assertEqual(response['entries'], [])
            self.assertTrue(request.exists(), 'The helper must not delete request-selected files')


if __name__ == '__main__':
    unittest.main()
