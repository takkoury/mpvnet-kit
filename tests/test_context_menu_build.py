"""Verify extension build inputs with a synthetic .NET bundle and no SDK."""

import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib


BUILD = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'dev-tools' / 'build-context-menu.py'))
REFERENCES = {
    'mpvnet.dll': (1, b'MZ synthetic host reference'),
    'libmpvnet.dll': (1, b'MZ synthetic library reference' * 16),
    'mpvnet.runtimeconfig.json': (4, b'{"runtimeOptions":{"tfm":"net10.0"}}'),
}


def bundle_string(value):
    data = value.encode('utf-8')
    length = len(data)
    prefix = bytearray()
    while length >= 128:
        prefix.append((length & 127) | 128)
        length >>= 7
    prefix.append(length)
    return prefix + data


def synthetic_bundle(*, extra=None, compressed_size_delta=0, offset_delta=0):
    header_location = 64
    image = bytearray(b'MZ'.ljust(header_location + 8, b'\0') + BUILD['BUNDLE_SIGNATURE'])
    entries = dict(REFERENCES)
    if extra:
        entries.update(extra)
    manifest = bytearray()
    for name, (kind, data) in entries.items():
        compressed_size = 0
        payload = data
        size = len(data)
        if name == 'libmpvnet.dll':
            encoder = zlib.compressobj(wbits=-zlib.MAX_WBITS)
            payload = encoder.compress(data) + encoder.flush()
            compressed_size = len(payload)
            size += compressed_size_delta
        manifest += struct.pack('<qqqB', len(image) + offset_delta, size, compressed_size, kind)
        manifest += bundle_string(name)
        image += payload
    struct.pack_into('<q', image, header_location, len(image))
    return image + struct.pack('<IIi', 6, 0, len(entries)) + bundle_string('bundle-id') + bytes(40) + manifest


class ContextMenuBuild(unittest.TestCase):
    def test_reads_only_the_required_raw_and_compressed_entries(self):
        image = synthetic_bundle(extra={'../' + 'x' * 130: (0, b'ignored')})
        self.assertEqual(BUILD['read_host_references'](io.BytesIO(image)),
                         {name: data for name, (_, data) in REFERENCES.items()})

    def test_rejects_truncated_duplicate_and_out_of_range_entries(self):
        for image, message in (
            (synthetic_bundle()[:-1], 'truncated'),
            (synthetic_bundle(extra={'MPVNET.DLL': (1, b'other')}), 'duplicate'),
            (synthetic_bundle(offset_delta=10_000), 'entry range'),
            (synthetic_bundle(compressed_size_delta=32 * 1024 * 1024), 'size or type'),
            (synthetic_bundle(compressed_size_delta=-1), 'compressed host entry length'),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                BUILD['read_host_references'](io.BytesIO(image))

    def test_output_protects_source_player_and_player_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'
            host = root / 'player' / 'mpvnet.exe'
            portable_player = root / 'other-player'
            (portable_player / 'portable_config').mkdir(parents=True)
            roaming = root / 'appdata'
            explicit_home = root / 'mpvnet-home'
            with patch.dict(os.environ, {'APPDATA': str(roaming), 'MPVNET_HOME': str(explicit_home)}):
                for parent in (source, host.parent, portable_player, roaming / 'mpv.net', explicit_home):
                    output = parent / 'fresh'
                    with self.subTest(parent=parent.name), self.assertRaisesRegex(ValueError, 'outside'):
                        BUILD['validate_output'](output, host, source)
                    self.assertFalse(output.exists())
                output = root / 'outside'
                self.assertEqual(BUILD['validate_output'](output, host, source), output.resolve())
                output.mkdir()
                with self.assertRaisesRegex(ValueError, 'fresh'):
                    BUILD['validate_output'](output, host, source)

    def test_source_digest_identifies_the_allowlisted_file_names_and_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            for name in BUILD['SOURCE_FILES']:
                (source / name).write_bytes(name.encode('utf-8'))
            digest = BUILD['source_digest'](source)
            (source / 'unrelated.txt').touch()
            self.assertEqual(BUILD['source_digest'](source), digest)
            (source / 'MenuStyles.xaml').write_bytes(b'changed')
            self.assertNotEqual(BUILD['source_digest'](source), digest)
            (source / 'MenuStyles.xaml').write_bytes(bytes(1024 * 1024 + 1))
            with self.assertRaisesRegex(ValueError, 'oversized extension source'):
                BUILD['source_digest'](source)
            (source / 'MenuStyles.xaml').unlink()
            with self.assertRaisesRegex(ValueError, 'missing or linked extension source'):
                BUILD['source_digest'](source)

    def test_dry_run_hashes_inputs_and_does_not_prepare_output_or_start_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'
            source.mkdir()
            for name in BUILD['SOURCE_FILES']:
                (source / name).write_bytes(name.encode('utf-8'))
            host = root / 'host' / 'mpvnet.exe'
            host.parent.mkdir()
            image = synthetic_bundle()
            host.write_bytes(image)
            output = root / 'unused-parent' / 'output'
            build = BUILD['build_context_menu']
            with patch.dict(build.__globals__, {'SOURCE': source}), patch('shutil.which') as sdk:
                evidence = build(host, output)
            sdk.assert_not_called()
            self.assertFalse(output.parent.exists())
            self.assertEqual(evidence['hostSha256'], hashlib.sha256(image).hexdigest())
            self.assertEqual(evidence['sourceSha256'], BUILD['source_digest'](source))
            self.assertEqual(evidence['hostRuntimeOptions']['tfm'], 'net10.0')

    def test_apply_publishes_only_the_extension_and_matching_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'
            source.mkdir()
            for name in BUILD['SOURCE_FILES']:
                (source / name).touch()
            host = root / 'host' / 'mpvnet.exe'
            host.parent.mkdir()
            host.write_bytes(synthetic_bundle())
            output = root / 'output'
            assembly = b'MZ synthetic extension'

            def compile_extension(target, dotnet, sources, references, digest):
                self.assertEqual(set(sources), set(BUILD['SOURCE_FILES']))
                self.assertEqual(set(references), set(REFERENCES))
                self.assertEqual(digest, BUILD['source_digest'](source))
                target.mkdir()
                return assembly, '10.0.403'

            build = BUILD['build_context_menu']
            with patch.dict(build.__globals__, {'SOURCE': source, '_build': compile_extension}), \
                 patch('shutil.which', return_value='dotnet'):
                evidence = build(host, output, apply=True)
            self.assertEqual(sorted(path.name for path in output.iterdir()),
                             ['KitContextMenu.dll', 'build-evidence.json'])
            self.assertEqual((output / 'KitContextMenu.dll').read_bytes(), assembly)
            self.assertEqual(json.loads((output / 'build-evidence.json').read_text(encoding='utf-8')), evidence)
            self.assertEqual(evidence['assemblySha256'], hashlib.sha256(assembly).hexdigest())
