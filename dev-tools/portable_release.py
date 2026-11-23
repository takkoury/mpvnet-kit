"""Build an offline candidate using a pinned, unmodified mpv.net portable ZIP."""
import hashlib
import io
import json
from pathlib import Path
import re
import tempfile
import zipfile

import managed_build
from package_lib import (
    _clean_root, _safe_file, manifest_bytes, read_source_contents, release_blockers, write_package_zip,
)


DESCRIPTOR = 'tools/portable-release.json'
LAUNCHER = 'src/offline-installer/Program.cs'


def _compile_installer(staging, launcher, version, contents):
    framework = 'v4.7.2'
    dotnet, compiler, sdk = managed_build.compiler()
    references = managed_build.reference_snapshot(framework, (
        'mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.IO.Compression.dll', 'System.Windows.Forms.dll',
    ))
    with io.BytesIO() as buffer:
        write_package_zip(buffer, contents)
        payload = buffer.getvalue()
    payload_hash = hashlib.sha256(payload).hexdigest()
    identity = (
        'using System.Reflection;\n'
        '[assembly: AssemblyTitle("mpvnet-kit 离线安装程序")]\n'
        '[assembly: AssemblyProduct("mpvnet-kit")]\n'
        f'[assembly: AssemblyVersion("{version}.0")]\n'
        f'[assembly: AssemblyFileVersion("{version}.0")]\n'
        f'[assembly: AssemblyInformationalVersion("{version}")]\n'
        f'internal static class InstallerPayload {{ public const string Sha256 = "{payload_hash}"; }}\n'
    )
    build_dir = staging / 'compiler'
    try:
        exe = managed_build.compile_assembly(
            build_dir, dotnet, compiler,
            {**launcher, 'PackageIdentity.cs': identity.encode(), 'payload.zip': payload}, references,
            managed_build.source_digest(launcher), assembly='mpvnet-kit.exe', framework_version=framework,
            metadata_key='MpvnetKitInstallerSource', label='offline installer', platform='x64',
            resources=(('payload.zip', 'mpvnet-kit.payload.zip'),),
        )
    except ValueError:
        log = build_dir / 'build.log'
        if log.is_file():
            raise ValueError('offline installer compilation failed:\n' + log.read_text(encoding='utf-8-sig')) from None
        raise
    return exe, {'sdk_version': sdk, 'payload_sha256': payload_hash, 'exe_sha256': hashlib.sha256(exe).hexdigest()}


def _stream_digest(handle):
    digest = hashlib.sha256()
    for data in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(data)
    return digest.hexdigest()


def _verify_upstream(description, data):
    version = description['version']
    if (description['schema'] != 1 or description['architecture'] != 'x64'
            or not isinstance(version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){3}', version)):
        raise ValueError('invalid portable release schema, version or architecture')
    name = 'mpv.net-v' + version + '-portable-x64.zip'
    archive = description['archive']
    source = 'https://github.com/mpvnet-player/mpv.net/releases/download/v' + version + '/' + name
    if archive['path'] != 'upstream/' + name or archive['source'] != source:
        raise ValueError('portable release must name the matching official x64 attachment')
    if hashlib.sha256(data).hexdigest() != archive['sha256']:
        raise ValueError('upstream archive SHA256 mismatch: ' + name)
    runtime = description['runtime']
    with zipfile.ZipFile(io.BytesIO(data)) as upstream:
        for role, filename in (('executable', 'mpvnet.exe'), ('core', 'libmpv-2.dll')):
            if runtime[role] != filename:
                raise ValueError('invalid portable runtime entry: ' + role)
            with upstream.open(filename) as handle:
                if _stream_digest(handle) != runtime[role + 'Sha256']:
                    raise ValueError('upstream runtime SHA256 mismatch: ' + filename)
    return {'path': archive['path'], 'sha256': archive['sha256'], 'component': 'upstream', 'origin': source}


def _check_new_path(path, source):
    if path == source or source in path.parents or path in source.parents:
        raise ValueError('build outputs must be outside the source checkout: ' + str(path))
    if path.exists():
        raise ValueError('build output already exists; preserve and choose a new path: ' + str(path))
    for parent in path.parents:
        if parent.exists() and not parent.is_dir():
            raise ValueError('build output parent must be a directory: ' + str(parent))


def build_portable_release(source, upstream, destination, output, *, apply=False):
    """Build a single Windows installer or an unpackaged ZIP for internal trials."""
    source, upstream = _clean_root(source), _clean_root(upstream)
    destination, output = _clean_root(destination), _clean_root(output)
    sidecar = _clean_root(Path(str(output) + '.sha256'))
    if source in upstream.parents or not upstream.is_file():
        raise ValueError('upstream ZIP must be a regular file outside the source checkout')
    executable = output.suffix.lower() == '.exe'
    if not executable and output.suffix.lower() != '.zip':
        raise ValueError('output must end in .exe (installer) or .zip (fixture)')
    for path in (destination, output, sidecar):
        _check_new_path(path, source)
    for path in (output, sidecar):
        if destination == path or destination in path.parents or path in destination.parents:
            raise ValueError('package directory and ZIP outputs must be separate')

    mapping = json.loads(_safe_file(source, 'dev-tools/package-map.json').read_text(encoding='utf-8'))
    portable = mapping['portable']
    version, contents, entries = read_source_contents(source, {
        'schema': mapping['schema'],
        'version': portable['version'],
        'files': mapping['files'] + portable['files'],
    })
    if 'Install.cmd' not in contents or DESCRIPTOR not in contents:
        raise ValueError('portable package requires Install.cmd and ' + DESCRIPTOR)
    if any(name.split('/', 1)[0].casefold() == 'upstream' for name in contents):
        raise ValueError('the upstream directory is reserved for the official ZIP')
    if executable:
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or any(int(p) > 65534 for p in version.split('.')):
            raise ValueError('the installer needs a three-part numeric Windows file version')
        launcher = managed_build.source_snapshot(source, (LAUNCHER,), 'offline installer')
    upstream_data = upstream.read_bytes()
    entry = _verify_upstream(json.loads(contents[DESCRIPTOR]), upstream_data)
    entries.append(entry)
    contents[entry['path']] = upstream_data
    contents['manifest.json'] = manifest = manifest_bytes(version, entries)
    blockers = release_blockers(contents, entries)
    if blockers:
        raise ValueError('portable release blocked: ' + '; '.join(blockers))
    report = {
        'version': version, 'file_count': len(contents),
        'manifest_sha256': hashlib.sha256(manifest).hexdigest(),
        'upstream_sha256': entry['sha256'], 'destination': str(destination), 'output': str(output),
        'dry_run': not apply,
    }
    if not apply:
        return report

    output.parent.mkdir(parents=True, exist_ok=True)
    if executable:
        # Fail before creating either deliverable if the offline compiler is unavailable.
        with tempfile.TemporaryDirectory(prefix='mpvnet-compile-', dir=output.parent) as work:
            exe, details = _compile_installer(Path(work), launcher, version, contents)
        report.update(details)
    # Exclusive creation preserves any outputs that appear after preflight.
    destination.mkdir(parents=True)
    for name, data in contents.items():
        path = _safe_file(destination, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as handle:
            handle.write(data)
    if executable:
        # Windows rename publishes only a complete, closed PE and refuses an existing destination.
        with tempfile.TemporaryDirectory(prefix='mpvnet-publish-', dir=output.parent) as work:
            staged = Path(work) / 'installer.exe'
            staged.write_bytes(exe)
            staged.rename(output)
        checksum = report['exe_sha256']
    else:
        with output.open('x+b') as handle:
            write_package_zip(handle, contents)
            handle.seek(0)
            checksum = report['zip_sha256'] = _stream_digest(handle)
    with sidecar.open('x', encoding='utf-8', newline='\n') as handle:
        handle.write(checksum + '  ' + output.name + '\n')
    return report
