#!/usr/bin/env python3
"""Build precompiled WinForms playlist controls offline. Preview by default."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import managed_build


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = 'KitPlaylistWindow.dll'
ASSET_PATH = 'config/helpers/' + ASSEMBLY
SOURCE_METADATA_KEY = 'KitPlaylistWindow.SourceSha256'
SOURCE_FILES = tuple('config/helpers/' + name for name in (
    'playlist-window-controls.cs', 'shortcut-key-names.cs', 'playlist-context-menu.cs',
))
FRAMEWORK_VERSION = 'v4.7.2'
REFERENCE_FILES = ('mscorlib.dll', 'System.dll', 'System.Core.dll',
                   'System.Windows.Forms.dll', 'System.Drawing.dll')


def _source_snapshot(source):
    return managed_build.source_snapshot(source, SOURCE_FILES, 'playlist window')


def source_digest(source):
    """Read fixed build inputs without invoking an SDK or opening a window."""
    return managed_build.source_digest(_source_snapshot(source))


def matches_source_digest(data, digest):
    return managed_build.matches_source_digest(data, digest, SOURCE_METADATA_KEY)


def validate_output(output, source=ROOT):
    return managed_build.validate_output(output, source)


def build_playlist_window(output, *, apply=False):
    output = validate_output(output, ROOT)
    contents = _source_snapshot(ROOT)
    digest = managed_build.source_digest(contents)
    evidence = {
        'sourceSha256': digest,
        'sourceFiles': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()},
    }
    if apply:
        dotnet, compiler, sdk_version = managed_build.compiler()
        references = managed_build.reference_snapshot(FRAMEWORK_VERSION, REFERENCE_FILES)
        assembly = managed_build.compile_assembly(output, dotnet, compiler, contents, references, digest,
            assembly=ASSEMBLY, target='library', framework_version=FRAMEWORK_VERSION,
            metadata_key=SOURCE_METADATA_KEY, label='playlist window')
        if not matches_source_digest(assembly, digest):
            raise ValueError('compiled playlist window asset is missing its source digest')
        evidence.update({
            'sdkVersion': sdk_version,
            'compilerSha256': hashlib.sha256(compiler.read_bytes()).hexdigest(),
            'targetFramework': '.NETFramework,Version=' + FRAMEWORK_VERSION,
            'target': 'library',
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
    mode.add_argument('--apply', action='store_true', help='compile the playlist controls and write build evidence')
    args = parser.parse_args()
    try:
        print(json.dumps(build_playlist_window(args.output, apply=args.apply), sort_keys=True))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Playlist window build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
