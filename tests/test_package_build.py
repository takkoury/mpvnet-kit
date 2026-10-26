"""The source checkout can build a complete package without local-only files."""
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'dev-tools/build-package.py'
PACKAGER = runpy.run_path(str(ROOT / 'dev-tools/prepare-release.py'))['package']


class PackageBuild(unittest.TestCase):
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
            report = PACKAGER(directory, output, False)
            self.assertEqual(report['blockers'], [])
            self.assertFalse(output.exists())
            PACKAGER(directory, output, True)
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


if __name__ == '__main__':
    unittest.main()
