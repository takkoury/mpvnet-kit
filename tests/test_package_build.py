"""The source checkout can build a complete package without local-only files."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from support.dev_imports import package_zip, stage_package

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'dev-tools/build-package.py'
PACKAGER = ROOT / 'dev-tools/prepare-release.py'


class PackageBuild(unittest.TestCase):
    def fixture(self, root, files=None):
        files = files or {
            'README.md': b'# Package\n\n[Guide](docs/guide.md#usage)\n',
            'docs/guide.md': b'# Guide\n\n## Usage\n\nRead the guide.\n',
            'LICENSE': b'Synthetic license fixture.\n',
            'LICENSES.md': b'# Licenses\n\nSynthetic test content.\n',
        }
        source = root / 'source'
        source.mkdir()
        for name, data in files.items():
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        mapping = {'schema': 1, 'version': 'test', 'files': [
            {'source': name, 'destination': name, 'component': 'author', 'origin': 'test'}
            for name in files
        ]}
        spec = root / 'map.json'
        spec.write_text(json.dumps(mapping), encoding='utf-8')
        return source, spec, mapping

    def write_manifest(self, source, entries, version='test'):
        (source / 'manifest.json').write_text(json.dumps({
            'schema': 1, 'version': version, 'status': 'generated-distribution',
            'files': entries,
        }), encoding='utf-8')

    def snapshot(self, directory):
        return {p.relative_to(directory).as_posix(): p.read_bytes()
                for p in directory.rglob('*') if p.is_file()}

    def invoke(self, destination, *args, expected=0):
        result = subprocess.run([
            sys.executable, '-B', str(BUILDER), '--source', str(ROOT),
            '--destination', str(destination), '--map', str(ROOT / 'dev-tools/package-map.json'),
            *args,
        ], capture_output=True)
        self.assertEqual(result.returncode, expected, result.stderr.decode('utf-8', errors='replace'))
        return result

    def test_preview_apply_and_zip_exclude_development_content(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / 'package'
            preview = json.loads(self.invoke(directory).stdout)
            self.assertTrue(preview['dry_run'])
            self.assertFalse(directory.exists())
            self.invoke(directory, '--apply')
            manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
            names = {f['path'] for f in manifest['files']}
            spec = json.loads((ROOT / 'dev-tools/package-map.json').read_text(encoding='utf-8'))
            self.assertEqual(names, {f['destination'] for f in spec['files']})
            self.assertFalse(any(n.startswith(('tests/', 'dev-tools/', '.git/', '.notes/')) for n in names))
            self.assertFalse(names & {'AGENTS.md', 'AGENTS.local.md', 'CONTRIBUTING.md', 'docs/roadmap.md'})
            for f in manifest['files']:
                self.assertEqual(hashlib.sha256((directory / f['path']).read_bytes()).hexdigest(), f['sha256'])
            output = Path(temp) / 'trial.zip'
            report = package_zip(directory, output)
            self.assertEqual(report['blockers'], [])
            self.assertFalse(output.exists())
            package_zip(directory, output, apply=True)
            with zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(set(archive.namelist()), {
                    'mpvnet-kit-' + manifest['version'] + '/' + n for n in names | {'manifest.json'}
                })

    def test_modified_package_is_preserved_and_git_checkout_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / 'package'
            self.invoke(directory, '--apply')
            target = directory / 'README.md'
            target.write_bytes(b'External edit. Preserve this file.')
            before = {str(p.relative_to(directory)): p.read_bytes() for p in directory.rglob('*') if p.is_file()}
            self.invoke(directory, '--apply', expected=1)
            self.assertEqual(before, {str(p.relative_to(directory)): p.read_bytes() for p in directory.rglob('*') if p.is_file()})
            checkout = Path(temp) / 'checkout'
            (checkout / '.git').mkdir(parents=True)
            self.invoke(checkout, '--apply', expected=1)
            self.assertEqual(list(checkout.iterdir()), [checkout / '.git'])

    def test_library_defaults_and_repeated_apply_preserve_package_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, spec, _ = self.fixture(root)
            destination, output = root / 'package', root / 'trial.zip'
            preview = stage_package(source, destination, spec)
            self.assertTrue(preview['dry_run'])
            self.assertFalse(destination.exists())
            applied = stage_package(source, destination, spec, apply=True)
            self.assertEqual(applied, {**preview, 'dry_run': False})
            before = self.snapshot(destination)
            self.assertEqual(stage_package(source, destination, spec, apply=True), applied)
            self.assertEqual(before, self.snapshot(destination))
            zip_preview = package_zip(destination, output)
            self.assertTrue(zip_preview['dry_run'])
            self.assertEqual(zip_preview['blockers'], [])
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output) + '.sha256').exists())
            zip_applied = package_zip(destination, output, apply=True)
            self.assertEqual(zip_applied, {**zip_preview, 'dry_run': False, 'result': 'created-or-identical'})
            original = output.read_bytes()
            package_zip(destination, output, apply=True)
            self.assertEqual(original, output.read_bytes())
            self.assertEqual(hashlib.sha256(original).hexdigest(), zip_applied['zip_sha256'])
            self.assertEqual(Path(str(output) + '.sha256').read_bytes(),
                             (zip_applied['zip_sha256'] + '  trial.zip\n').encode())
            with zipfile.ZipFile(output) as archive:
                self.assertEqual({name[len('mpvnet-kit-test/'):]: archive.read(name)
                                  for name in archive.namelist()}, before)

    def test_invalid_versions_are_rejected_before_stage_or_zip_write(self):
        for version in (None, '', '../bad', 'v 1', '1/2', '1:2'):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, spec, mapping = self.fixture(root)
                mapping['version'] = version
                spec.write_text(json.dumps(mapping), encoding='utf-8')
                self.write_manifest(source, [], version)
                with self.assertRaisesRegex(ValueError, 'invalid export map schema/version'):
                    stage_package(source, root / 'package', spec, apply=True)
                with self.assertRaisesRegex(ValueError, 'invalid manifest schema/version'):
                    package_zip(source, root / 'trial.zip', apply=True)
                self.assertFalse((root / 'package').exists())
                self.assertFalse((root / 'trial.zip').exists())

    def test_invalid_package_paths_are_rejected_before_stage_or_zip_write(self):
        cases = [
            ('../outside.txt', 'unsafe relative path'),
            ('config/NUL.txt', 'nonportable Windows path'),
            ('config/trailing.', 'nonportable Windows path'),
            ('config/trailing ', 'nonportable Windows path'),
            ('config/bad?.txt', 'nonportable Windows path'),
            ('MANIFEST.JSON', 'reserved manifest entry'),
            ('.GIT/config', 'reserved manifest entry'),
        ]
        for name, error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, spec, mapping = self.fixture(root, {'file.txt': b'fixture'})
                mapping['files'][0]['destination'] = name
                spec.write_text(json.dumps(mapping), encoding='utf-8')
                self.write_manifest(source, [{'path': name, 'sha256': '0' * 64}])
                with self.assertRaisesRegex(ValueError, error):
                    stage_package(source, root / 'package', spec, apply=True)
                with self.assertRaisesRegex(ValueError, error):
                    package_zip(source, root / 'trial.zip', apply=True)
                self.assertFalse((root / 'package').exists())
                self.assertFalse((root / 'trial.zip').exists())

    def test_directory_case_collisions_are_rejected_by_both_operations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, spec, mapping = self.fixture(root, {'Dir/one.txt': b'one', 'two.txt': b'two'})
            mapping['files'][1]['destination'] = 'dir/two.txt'
            spec.write_text(json.dumps(mapping), encoding='utf-8')
            self.write_manifest(source, [
                {'path': 'Dir/one.txt', 'sha256': hashlib.sha256(b'one').hexdigest()},
                {'path': 'dir/two.txt', 'sha256': hashlib.sha256(b'two').hexdigest()},
            ])
            with self.assertRaisesRegex(ValueError, 'case-insensitive path collision'):
                stage_package(source, root / 'package', spec, apply=True)
            with self.assertRaisesRegex(ValueError, 'case-insensitive path collision'):
                package_zip(source, root / 'trial.zip', apply=True)
            self.assertFalse((root / 'package').exists())
            self.assertFalse((root / 'trial.zip').exists())

    def test_all_existing_link_forms_are_checked_before_either_write(self):
        cases = [
            ('[Missing](missing.md)', 'missing local Markdown link'),
            ('[Missing][target]\n\n[target]: missing.md', 'missing local Markdown link'),
            ('<img src="missing.png">', 'missing local Markdown link'),
            ('[Missing](README.md#absent)', 'missing local Markdown heading'),
            ('<a href="README.md#absent">Missing</a>', 'missing local Markdown heading'),
            ('[External](//example.invalid/path)', 'nonportable Markdown link'),
        ]
        for link, error in cases:
            with self.subTest(link=link), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                data = ('# Package\n\n' + link + '\n').encode()
                source, spec, _ = self.fixture(root, {'README.md': data})
                self.write_manifest(source, [{'path': 'README.md', 'sha256': hashlib.sha256(data).hexdigest()}])
                with self.assertRaisesRegex(ValueError, error):
                    stage_package(source, root / 'package', spec, apply=True)
                with self.assertRaisesRegex(ValueError, error):
                    package_zip(source, root / 'trial.zip', apply=True)
                self.assertFalse((root / 'package').exists())
                self.assertFalse((root / 'trial.zip').exists())

    def test_valid_reference_html_and_encoded_heading_links_are_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            readme = ('# Package\n\n[Inline](<docs/guide.md#usage> "Guide")\n'
                      '[Reference][guide]\n\n[guide]: docs/guide.md#usage\n'
                      '<a href="docs/guide.md#%E4%BD%BF%E7%94%A8">Guide</a>\n'
                      '[External](https://example.invalid/)\n').encode()
            source, spec, _ = self.fixture(root, {
                'README.MD': readme,
                'docs/guide.md': '# Guide\n\n## Usage\n\n## 使用\n'.encode(),
                'LICENSE': b'Test license.\n', 'LICENSES.md': b'# Licenses\n',
            })
            stage_package(source, root / 'package', spec, apply=True)
            self.assertEqual(package_zip(root / 'package', root / 'trial.zip')['blockers'], [])

    def test_private_text_is_rejected_by_both_operations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data = b'fixture=C:/Users/SyntheticUser/private.txt\n'
            source, spec, _ = self.fixture(root, {'settings.conf': data})
            self.write_manifest(source, [{'path': 'settings.conf', 'sha256': hashlib.sha256(data).hexdigest()}])
            with self.assertRaisesRegex(ValueError, 'private environment reference'):
                stage_package(source, root / 'package', spec, apply=True)
            with self.assertRaisesRegex(ValueError, 'private environment reference'):
                package_zip(source, root / 'trial.zip', apply=True)
            self.assertFalse((root / 'package').exists())
            self.assertFalse((root / 'trial.zip').exists())

    def test_unknown_collision_and_retired_managed_file_preserve_destination(self):
        for change in ('collision', 'retired'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, spec, mapping = self.fixture(root)
                destination = root / 'package'
                stage_package(source, destination, spec, apply=True)
                if change == 'collision':
                    (source / 'new.txt').write_bytes(b'new managed data')
                    (destination / 'new.txt').write_bytes(b'unknown data to preserve')
                    mapping['files'].append({'source': 'new.txt', 'destination': 'new.txt',
                                             'component': 'author', 'origin': 'test'})
                    error = 'unknown destination collision'
                else:
                    mapping['files'] = [entry for entry in mapping['files'] if entry['source'] != 'LICENSE']
                    error = 'old managed files removed'
                spec.write_text(json.dumps(mapping), encoding='utf-8')
                before = self.snapshot(destination)
                with self.assertRaisesRegex(ValueError, error):
                    stage_package(source, destination, spec, apply=True)
                self.assertEqual(before, self.snapshot(destination))

    def test_zip_rejects_modified_input_and_different_existing_outputs(self):
        for change in ('source', 'zip', 'sidecar'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, spec, _ = self.fixture(root)
                destination, output = root / 'package', root / 'trial.zip'
                stage_package(source, destination, spec, apply=True)
                if change == 'source':
                    (destination / 'LICENSE').write_bytes(b'changed externally')
                    error = 'SHA256 mismatch'
                else:
                    target = output if change == 'zip' else Path(str(output) + '.sha256')
                    target.write_bytes(b'existing output to preserve')
                    error = 'existing output differs'
                before = self.snapshot(root)
                with self.assertRaisesRegex(ValueError, error):
                    package_zip(destination, output, apply=True)
                self.assertEqual(before, self.snapshot(root))

    def test_license_blockers_remain_preview_only_until_zip_apply(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, spec, _ = self.fixture(root, {'README.md': b'# Package\n'})
            destination, output = root / 'package', root / 'trial.zip'
            stage_package(source, destination, spec, apply=True)
            self.assertEqual(package_zip(destination, output)['blockers'], [
                'manifest must include a nonempty top-level LICENSE',
                'manifest must include LICENSES.md',
            ])
            with self.assertRaisesRegex(ValueError, 'release blocked'):
                package_zip(destination, output, apply=True)
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output) + '.sha256').exists())

    def test_cli_defaults_explicit_preview_and_error_prefixes_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, spec, mapping = self.fixture(root)
            destination, output = root / 'package', root / 'trial.zip'
            build_command = [sys.executable, '-B', str(BUILDER), '--source', str(source),
                             '--destination', str(destination), '--map', str(spec)]
            default = subprocess.run(build_command, capture_output=True)
            explicit = subprocess.run(build_command + ['--dry-run'], capture_output=True)
            self.assertEqual(default.returncode, 0, default.stderr)
            self.assertEqual(default.stdout, explicit.stdout)
            self.assertFalse(destination.exists())
            stage_package(source, destination, spec, apply=True)
            zip_command = [sys.executable, '-B', str(PACKAGER), '--source', str(destination),
                           '--output', str(output)]
            default = subprocess.run(zip_command, capture_output=True)
            explicit = subprocess.run(zip_command + ['--dry-run'], capture_output=True)
            self.assertEqual(default.returncode, 0, default.stderr)
            self.assertEqual(default.stdout, explicit.stdout)
            self.assertEqual(json.loads(default.stdout), package_zip(destination, output))
            self.assertFalse(output.exists())
            mapping['version'] = '../bad'
            spec.write_text(json.dumps(mapping), encoding='utf-8')
            failed_build = subprocess.run(build_command + ['--apply'], capture_output=True)
            self.assertEqual(failed_build.returncode, 1)
            self.assertTrue(failed_build.stderr.startswith(b'Package build stopped: '))
            (destination / 'LICENSE').write_bytes(b'changed externally')
            failed_zip = subprocess.run(zip_command + ['--apply'], capture_output=True)
            self.assertEqual(failed_zip.returncode, 1)
            self.assertTrue(failed_zip.stderr.startswith(b'Release preparation stopped: '))
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
