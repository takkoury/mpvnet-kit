#!/usr/bin/env python3
"""Build the menu extension against a local mpv.net single-file host. Preview by default."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

from dev_paths import is_link_or_reparse


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src' / 'context-menu'
SOURCE_FILES = ('ContextMenu.csproj', 'ContextMenuExtension.cs', 'MenuPresentation.cs', 'MenuStyles.xaml')
ASSEMBLY = 'KitContextMenu.dll'
SOURCE_METADATA_KEY = 'KitContextMenu.SourceSha256'
BUNDLE_SIGNATURE = bytes.fromhex('8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae')
HOST_FILES = {
    'mpvnet.dll': (1, 32 * 1024 * 1024),
    'libmpvnet.dll': (1, 32 * 1024 * 1024),
    'mpvnet.runtimeconfig.json': (4, 64 * 1024),
}


def _read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError('truncated host bundle')
    return data


def _read_string(stream):
    # BinaryReader uses a seven-bit encoded byte count for UTF-8 strings.
    length = 0
    for shift in range(0, 35, 7):
        part = _read_exact(stream, 1)[0]
        length |= (part & 0x7f) << shift
        if part < 0x80:
            if not 0 < length <= 1024:
                raise ValueError('invalid host bundle string length')
            return _read_exact(stream, length).decode('utf-8')
    raise ValueError('invalid host bundle string length')


def _bundle_entries(stream):
    prefix = stream.read(8 * 1024 * 1024)
    marker = prefix.find(BUNDLE_SIGNATURE)
    if not prefix.startswith(b'MZ') or marker < 8 or prefix.count(BUNDLE_SIGNATURE) != 1:
        raise ValueError('expected a Windows .NET single-file host')
    header, = struct.unpack_from('<q', prefix, marker - 8)
    bundle_start = marker + len(BUNDLE_SIGNATURE)
    end = stream.seek(0, os.SEEK_END)
    if not bundle_start <= header < end:
        raise ValueError('invalid host bundle header offset')
    stream.seek(header)
    major, minor, count = struct.unpack('<IIi', _read_exact(stream, 12))
    if (major, minor) != (6, 0) or not 0 < count <= 4096:
        raise ValueError('unsupported host bundle version or entry count')
    _read_string(stream)  # Bundle ID.
    _read_exact(stream, 40)  # Dependency and runtime config locations, then flags.

    names = set()
    selected = {}
    for _ in range(count):
        offset, size, compressed_size, kind = struct.unpack('<qqqB', _read_exact(stream, 25))
        name = _read_string(stream).casefold()
        stored_size = compressed_size or size
        if name in names:
            raise ValueError('duplicate host bundle entry')
        names.add(name)
        if size < 0 or compressed_size < 0 or not bundle_start <= offset <= header - stored_size:
            raise ValueError('invalid host bundle entry range')
        if name in HOST_FILES:
            expected_kind, limit = HOST_FILES[name]
            if kind != expected_kind or not 0 < size <= limit or stored_size > limit:
                raise ValueError('invalid host reference size or type: ' + name)
            selected[name] = offset, size, compressed_size

    if selected.keys() != HOST_FILES.keys():
        raise ValueError('missing host bundle entries: ' + ', '.join(sorted(HOST_FILES.keys() - selected.keys())))
    return selected


def read_host_references(stream):
    """Extract only the required reference bytes, without executing the host."""
    entries = _bundle_entries(stream)
    references = {}
    for name, (offset, size, compressed_size) in entries.items():
        stream.seek(offset)
        data = _read_exact(stream, compressed_size or size)
        if compressed_size:
            decoder = zlib.decompressobj(-zlib.MAX_WBITS)
            try:
                data = decoder.decompress(data, size + 1)
            except zlib.error as error:
                raise ValueError('invalid compressed host entry: ' + name) from error
            if not decoder.eof or decoder.unused_data or len(data) != size:
                raise ValueError('invalid compressed host entry length: ' + name)
        references[name] = data
    return references


def _source_snapshot(source_dir):
    if any(is_link_or_reparse(path) for path in (source_dir, *source_dir.parents)):
        raise ValueError('extension source path contains a link or junction')
    contents = {}
    for name in SOURCE_FILES:
        path = source_dir / name
        if is_link_or_reparse(path) or not path.is_file():
            raise ValueError('missing or linked extension source: ' + name)
        with path.open('rb') as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError('oversized extension source: ' + name)
        contents[name] = data
    return contents


def _source_digest(contents):
    digest = hashlib.sha256()
    for name, data in sorted(contents.items()):
        digest.update(name.encode('utf-8') + b'\0' + len(data).to_bytes(8, 'little'))
        digest.update(data)
    return digest.hexdigest()


def source_digest(source_dir):
    """Hash the exact allowlisted source snapshot embedded in a built extension."""
    return _source_digest(_source_snapshot(source_dir))


def validate_output(output, host, root=ROOT):
    """Require a fresh output outside the source and player/config directories."""
    output = output.absolute()
    if any(is_link_or_reparse(path) for path in (output, *output.parents)):
        raise ValueError('output path contains a link or junction')
    output = output.resolve()
    if output.exists():
        raise ValueError('output must be a fresh directory')
    protected = [root.resolve(), host.resolve().parent]
    if os.environ.get('MPVNET_HOME'):
        protected.append(Path(os.environ['MPVNET_HOME']).resolve())
    for variable in ('APPDATA', 'LOCALAPPDATA'):
        if os.environ.get(variable):
            protected.append((Path(os.environ[variable]) / 'mpv.net').resolve())
    if any(output == path or path in output.parents for path in protected):
        raise ValueError('output must be outside source, host and player configuration directories')
    markers = ('mpvnet.exe', 'mpv.exe', 'portable_config')
    if any((parent / marker).exists() for parent in output.parents for marker in markers):
        raise ValueError('output must be outside player directories')
    return output


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _host_snapshot(host):
    with host.open('rb') as stream:
        references = read_host_references(stream)
        stream.seek(0)
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    options = json.loads(references['mpvnet.runtimeconfig.json'])
    runtime = options.get('runtimeOptions') if isinstance(options, dict) else None
    if not isinstance(runtime, dict) or runtime.get('tfm') != 'net10.0':
        raise ValueError('expected an mpv.net host with a .NET 10 runtime')
    return references, digest.hexdigest(), runtime


def _build(output, dotnet, contents, references, digest):
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='build-', dir=output) as directory:
        staging = Path(directory)
        project = staging / 'src'
        refs = staging / 'refs'
        project.mkdir()
        refs.mkdir()
        for name, data in contents.items():
            (project / name).write_bytes(data)
        for name, data in references.items():
            (refs / name).write_bytes(data)
        (project / 'BuildEvidence.cs').write_text(
            f'[assembly: System.Reflection.AssemblyMetadata("{SOURCE_METADATA_KEY}", "{digest}")]\n',
            encoding='utf-8',
        )
        (staging / 'global.json').write_text(
            '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}\n',
            encoding='utf-8',
        )
        nuget = staging / 'NuGet.Config'
        nuget.write_text('<configuration><packageSources><clear /></packageSources></configuration>\n', encoding='utf-8')
        env = dict(os.environ,
                   DOTNET_CLI_HOME=str(staging / 'cli'),
                   DOTNET_CLI_TELEMETRY_OPTOUT='1',
                   DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
                   DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true',
                   DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false',
                   DOTNET_NOLOGO='1',
                   NUGET_PACKAGES=str(staging / 'packages'))
        version = subprocess.run([dotnet, '--version'], cwd=staging, env=env, capture_output=True)
        if version.returncode:
            raise ValueError('the locally installed .NET 10 SDK is required')
        binary_dir = staging / 'bin'
        result = subprocess.run([
            dotnet, 'build', 'ContextMenu.csproj', '--configuration', 'Release',
            '--output', str(binary_dir), '--disable-build-servers',
            f'-p:HostReferenceDirectory={refs}', f'-p:RestoreConfigFile={nuget}',
            '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false',
            '-p:ImportDirectoryPackagesProps=false', '-p:ContinuousIntegrationBuild=true',
            '-p:EnableSourceControlManagerQueries=false', '-p:EnableSourceLink=false',
            '-p:IncludeSourceRevisionInInformationalVersion=false', '-p:NuGetAudit=false',
            f'-p:PathMap={project}=/_/src',
        ], cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            with (output / 'build.log').open('xb') as stream:
                stream.write(result.stdout)
            raise ValueError('extension compilation failed; see build.log in the output directory')
        return (binary_dir / ASSEMBLY).read_bytes(), version.stdout.decode('utf-8').strip()


def build_context_menu(host, output, *, apply=False):
    output = validate_output(output, host)
    contents = _source_snapshot(SOURCE)
    references, host_digest, runtime = _host_snapshot(host)
    evidence = {
        'sourceSha256': _source_digest(contents),
        'sourceFiles': {name: _sha256(data) for name, data in contents.items()},
        'hostSha256': host_digest,
        'hostReferences': {name: _sha256(data) for name, data in references.items()},
        'hostRuntimeOptions': runtime,
    }
    if apply:
        dotnet = shutil.which('dotnet')
        if dotnet is None:
            raise ValueError('the locally installed .NET 10 SDK is required')
        assembly, sdk_version = _build(output, dotnet, contents, references, evidence['sourceSha256'])
        evidence.update({'assemblySha256': _sha256(assembly), 'sdkVersion': sdk_version})
        with (output / ASSEMBLY).open('xb') as stream:
            stream.write(assembly)
        with (output / 'build-evidence.json').open('x', encoding='utf-8') as stream:
            json.dump(evidence, stream, indent=2, sort_keys=True)
            stream.write('\n')
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, type=Path, help='original single-file mpv.net executable')
    parser.add_argument('--output', required=True, type=Path, help='new directory outside the repository and player')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='validate the inputs without writing (default)')
    mode.add_argument('--apply', action='store_true', help='compile the extension and write build evidence')
    args = parser.parse_args()
    try:
        print(json.dumps(build_context_menu(args.host, args.output, apply=args.apply), sort_keys=True))
    except (ValueError, OSError) as error:
        parser.exit(1, 'Context menu build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
