#!/usr/bin/env python3
"""Build the settings window with local .NET SDK and Framework references. Preview by default."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from dev_paths import is_link_or_reparse


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = 'KitSettings.exe'
ASSET_PATH = 'config/helpers/' + ASSEMBLY
SOURCE_METADATA_KEY = 'KitSettings.SourceSha256'
MANIFEST = 'src/settings-window/app.manifest'
SOURCE_FILES = tuple('config/helpers/' + name for name in (
    'user-preferences-storage.cs', 'settings-preview.cs', 'shortcut-key-names.cs',
    'settings-shortcuts.cs', 'settings-controls.cs', 'settings-chrome.cs',
    'settings-close.cs', 'settings-window.cs', 'settings-host.cs',
)) + (MANIFEST,)
FRAMEWORK_VERSION = 'v4.7.2'
REFERENCE_FILES = (
    'mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Web.Extensions.dll',
    'System.Windows.Forms.dll', 'System.Xaml.dll', 'WindowsBase.dll',
    'PresentationCore.dll', 'PresentationFramework.dll',
)


def _source_snapshot(source):
    contents = {}
    for name in SOURCE_FILES:
        path = source / name
        if any(is_link_or_reparse(part) for part in (path, *path.parents)) or not path.is_file():
            raise ValueError('missing or linked settings source: ' + name)
        with path.open('rb') as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError('oversized settings source: ' + name)
        contents[name] = data
    return contents


def _source_digest(contents):
    digest = hashlib.sha256()
    for name, data in sorted(contents.items()):
        digest.update(name.encode('utf-8') + b'\0' + len(data).to_bytes(8, 'little'))
        digest.update(data)
    return digest.hexdigest()


def source_digest(source):
    """Hash the exact allowlisted source files relative to a checkout root."""
    return _source_digest(_source_snapshot(source))


def matches_source_digest(data, digest):
    # ECMA custom-attribute blob: prolog, two SerStrings, zero named arguments.
    key = SOURCE_METADATA_KEY.encode('ascii')
    metadata = b'\x01\x00' + bytes([len(key)]) + key + b'\x40' + digest.encode('ascii') + b'\x00\x00'
    return data.startswith(b'MZ') and metadata in data


def validate_output(output, source=ROOT):
    output = output.absolute()
    if output.drive.startswith(('\\\\?\\', '\\\\.\\')):
        raise ValueError('device output paths are not supported')
    if any(is_link_or_reparse(path) for path in (output, *output.parents)):
        raise ValueError('output path contains a link or junction')
    output = output.resolve()
    if output.exists():
        raise ValueError('output must be a fresh directory')
    protected = [source.resolve()]
    if os.environ.get('MPVNET_HOME'):
        protected.append(Path(os.environ['MPVNET_HOME']).resolve())
    for variable in ('APPDATA', 'LOCALAPPDATA'):
        if os.environ.get(variable):
            protected.append((Path(os.environ[variable]) / 'mpv.net').resolve())
    if any(output == path or path in output.parents for path in protected):
        raise ValueError('output must be outside source and player configuration directories')
    markers = ('mpvnet.exe', 'mpv.exe', 'portable_config')
    if any((parent / marker).exists() for parent in output.parents for marker in markers):
        raise ValueError('output must be outside player directories')
    return output


def _compiler():
    dotnet = shutil.which('dotnet')
    if dotnet is None:
        raise ValueError('the locally installed .NET 10 SDK is required')
    result = subprocess.run([dotnet, '--list-sdks'], check=True, capture_output=True, encoding='utf-8')
    versions = []
    for line in result.stdout.splitlines():
        match = re.fullmatch(r'(10\.\d+\.\d+) \[(.+)\]', line.strip())
        if match:
            versions.append((tuple(map(int, match[1].split('.'))), Path(match[2]) / match[1]))
    if not versions:
        raise ValueError('the locally installed .NET 10 SDK is required')
    sdk = max(versions)[1]
    compiler = sdk / 'Roslyn/bincore/csc.dll'
    if not compiler.is_file():
        raise ValueError('the local .NET 10 SDK is missing its Roslyn compiler')
    return dotnet, compiler, sdk.name


def _reference_snapshot():
    program_files = os.environ.get('ProgramFiles(x86)') or os.environ.get('ProgramFiles')
    if not program_files:
        raise ValueError('local .NET Framework ' + FRAMEWORK_VERSION + ' reference assemblies are required')
    directory = Path(program_files) / 'Reference Assemblies/Microsoft/Framework/.NETFramework' / FRAMEWORK_VERSION
    references = {}
    for name in REFERENCE_FILES:
        path = directory / name
        if not path.is_file():
            raise ValueError('missing local .NET Framework ' + FRAMEWORK_VERSION + ' reference: ' + name)
        references[name] = path.read_bytes()
    return references


def _compile(output, dotnet, compiler, contents, references, digest):
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='build-', dir=output) as directory:
        staging = Path(directory)
        for name, data in contents.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        refs = staging / 'refs'
        refs.mkdir()
        for name, data in references.items():
            (refs / name).write_bytes(data)
        (staging / 'BuildEvidence.cs').write_text(
            '[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=' + FRAMEWORK_VERSION + '")]\n'
            f'[assembly: System.Reflection.AssemblyMetadata("{SOURCE_METADATA_KEY}", "{digest}")]\n',
            encoding='utf-8',
        )
        # Roslyn escapes path-map separators by doubling them.
        mapped_path = str(staging).replace('=', '==').replace(',', ',,')
        result = subprocess.run([
            dotnet, str(compiler), '-nologo', '-noconfig', '-nostdlib+', '-utf8output',
            '-codepage:65001', '-target:winexe', '-platform:anycpu', '-langversion:7.3',
            '-deterministic+', '-optimize+', '-warnaserror+', f'-pathmap:{mapped_path}=/_/src',
            f'-win32manifest:{MANIFEST}', f'-out:{ASSEMBLY}',
            *(f'-reference:refs/{name}' for name in references),
            *(name for name in contents if name.endswith('.cs')), 'BuildEvidence.cs',
        ], cwd=staging, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            (output / 'build.log').write_bytes(result.stdout)
            raise ValueError('settings compilation failed; see build.log in the output directory')
        return (staging / ASSEMBLY).read_bytes()


def build_settings_window(output, *, apply=False):
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
            raise ValueError('compiled settings asset is missing its source digest')
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
    mode.add_argument('--apply', action='store_true', help='compile the settings window and write build evidence')
    args = parser.parse_args()
    try:
        print(json.dumps(build_settings_window(args.output, apply=args.apply), sort_keys=True))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Settings build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
