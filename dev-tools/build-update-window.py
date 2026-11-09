#!/usr/bin/env python3
"""Build the update window with local .NET SDK and Framework references. Preview by default."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import managed_build


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = 'KitUpdate.exe'
ASSET_PATH = 'config/helpers/' + ASSEMBLY
SOURCE_METADATA_KEY = 'KitUpdate.SourceSha256'
MANIFEST = 'src/update-window/app.manifest'
SOURCE_FILES = tuple('config/helpers/' + name for name in (
    'update-check.cs', 'update-window.cs', 'update-host.cs',
)) + (MANIFEST,)
FRAMEWORK_VERSION = 'v4.7.2'
REFERENCE_FILES = (
    'mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Web.Extensions.dll',
    'System.Windows.Forms.dll', 'System.Xaml.dll', 'WindowsBase.dll',
    'PresentationCore.dll', 'PresentationFramework.dll',
)


def _source_snapshot(source):
    return managed_build.source_snapshot(source, SOURCE_FILES, 'update')


def _source_digest(contents):
    return managed_build.source_digest(contents)


def source_digest(source):
    """Hash the exact allowlisted source files relative to a checkout root."""
    return _source_digest(_source_snapshot(source))


def matches_source_digest(data, digest):
    return managed_build.matches_source_digest(data, digest, SOURCE_METADATA_KEY)


def validate_output(output, source=ROOT):
    return managed_build.validate_output(output, source)


def _compiler():
    return managed_build.compiler()


def _reference_snapshot():
    return managed_build.reference_snapshot(FRAMEWORK_VERSION, REFERENCE_FILES)


def _compile(output, dotnet, compiler, contents, references, digest):
    return managed_build.compile_winexe(output, dotnet, compiler, contents, references, digest,
        assembly=ASSEMBLY, manifest=MANIFEST, framework_version=FRAMEWORK_VERSION,
        metadata_key=SOURCE_METADATA_KEY, label='update')


def build_update_window(output, *, apply=False):
    output = validate_output(output, ROOT)
    contents = _source_snapshot(ROOT)
    digest = _source_digest(contents)
    evidence = {
        'sourceSha256': digest,
        'sourceFiles': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()},
    }
    if apply:
        dotnet, compiler, sdk_version = _compiler()
        references = _reference_snapshot()
        compiler_digest = hashlib.sha256(compiler.read_bytes()).hexdigest()
        assembly = _compile(output, dotnet, compiler, contents, references, digest)
        if not matches_source_digest(assembly, digest):
            raise ValueError('compiled update asset is missing its source digest')
        evidence.update({
            'sdkVersion': sdk_version,
            'compilerSha256': compiler_digest,
            'targetFramework': '.NETFramework,Version=' + FRAMEWORK_VERSION,
            'referenceFiles': {name: hashlib.sha256(data).hexdigest() for name, data in references.items()},
            'assemblySha256': hashlib.sha256(assembly).hexdigest(),
        })
        with (output / ASSEMBLY).open('xb') as stream:
            stream.write(assembly)
        with (output / 'build-evidence.json').open('x', encoding='utf-8') as stream:
            json.dump(evidence, stream, indent=2, sort_keys=True)
            stream.write('\n')
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='new directory outside the repository and player')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='validate the sources without writing (default)')
    mode.add_argument('--apply', action='store_true', help='compile the update window and write build evidence')
    args = parser.parse_args()
    try:
        print(json.dumps(build_update_window(args.output, apply=args.apply), sort_keys=True))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Update build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
