"""Offline .NET Framework build mechanics shared by precompiled Windows helpers."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from dev_paths import is_link_or_reparse


def source_snapshot(source, source_files, label):
    contents = {}
    for name in source_files:
        path = source / name
        if any(is_link_or_reparse(part) for part in (path, *path.parents)) or not path.is_file():
            raise ValueError('missing or linked ' + label + ' source: ' + name)
        with path.open('rb') as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError('oversized ' + label + ' source: ' + name)
        contents[name] = data
    return contents


def source_digest(contents):
    digest = hashlib.sha256()
    for name, data in sorted(contents.items()):
        digest.update(name.encode('utf-8') + b'\0' + len(data).to_bytes(8, 'little'))
        digest.update(data)
    return digest.hexdigest()


def matches_source_digest(data, digest, metadata_key):
    # Both helpers use an ASCII key shorter than the one-byte SerString limit.
    key = metadata_key.encode('ascii')
    metadata = b'\x01\x00' + bytes([len(key)]) + key + b'\x40' + digest.encode('ascii') + b'\x00\x00'
    return data.startswith(b'MZ') and metadata in data


def validate_output(output, source):
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


def compiler():
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
    executable = sdk / 'Roslyn/bincore/csc.dll'
    if not executable.is_file():
        raise ValueError('the local .NET 10 SDK is missing its Roslyn compiler')
    return dotnet, executable, sdk.name


def reference_snapshot(framework_version, reference_files):
    program_files = os.environ.get('ProgramFiles(x86)') or os.environ.get('ProgramFiles')
    if not program_files:
        raise ValueError('local .NET Framework ' + framework_version + ' reference assemblies are required')
    directory = Path(program_files) / 'Reference Assemblies/Microsoft/Framework/.NETFramework' / framework_version
    references = {}
    for name in reference_files:
        path = directory / name
        if not path.is_file():
            raise ValueError('missing local .NET Framework ' + framework_version + ' reference: ' + name)
        references[name] = path.read_bytes()
    return references


def compile_assembly(output, dotnet, compiler_path, contents, references, digest, *,
                     assembly, framework_version, metadata_key, label, target='winexe', manifest=None):
    if target not in ('winexe', 'library'):
        raise ValueError('unsupported managed assembly target')
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
            '[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=' + framework_version + '")]\n'
            f'[assembly: System.Reflection.AssemblyMetadata("{metadata_key}", "{digest}")]\n',
            encoding='utf-8',
        )
        # Roslyn escapes path-map separators by doubling them.
        mapped_path = str(staging).replace('=', '==').replace(',', ',,')
        result = subprocess.run([
            dotnet, str(compiler_path), '-nologo', '-noconfig', '-nostdlib+', '-utf8output',
            '-codepage:65001', '-target:' + target, '-platform:anycpu', '-langversion:7.3',
            '-deterministic+', '-optimize+', '-warnaserror+', f'-pathmap:{mapped_path}=/_/src',
            *([f'-win32manifest:{manifest}'] if manifest else []), f'-out:{assembly}',
            *(f'-reference:refs/{name}' for name in references),
            *(name for name in contents if name.endswith('.cs')), 'BuildEvidence.cs',
        ], cwd=staging, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            (output / 'build.log').write_bytes(result.stdout)
            raise ValueError(label + ' compilation failed; see build.log in the output directory')
        return (staging / assembly).read_bytes()


def compile_winexe(output, dotnet, compiler_path, contents, references, digest, *,
                   assembly, manifest, framework_version, metadata_key, label):
    """Keep existing executable builders' call contract and default flags."""
    return compile_assembly(output, dotnet, compiler_path, contents, references, digest,
        assembly=assembly, manifest=manifest, framework_version=framework_version,
        metadata_key=metadata_key, label=label)
