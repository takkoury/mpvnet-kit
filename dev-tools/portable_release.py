"""Build an offline candidate using a pinned, unmodified mpv.net portable ZIP."""
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

from package_lib import (
    _clean_root, _safe_file, manifest_bytes, read_source_contents, release_blockers, write_package_zip,
)


DESCRIPTOR = 'tools/portable-release.json'


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
    """Validate an offline candidate, then create a fresh package directory and ZIP."""
    source, upstream = _clean_root(source), _clean_root(upstream)
    destination, output = _clean_root(destination), _clean_root(output)
    sidecar = _clean_root(Path(str(output) + '.sha256'))
    if source in upstream.parents or not upstream.is_file():
        raise ValueError('upstream ZIP must be a regular file outside the source checkout')
    if output.suffix.lower() != '.zip':
        raise ValueError('output must end in .zip')
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

    # Exclusive creation preserves any outputs that appear after preflight.
    destination.mkdir(parents=True)
    for name, data in contents.items():
        path = _safe_file(destination, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as handle:
            handle.write(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x+b') as handle:
        write_package_zip(handle, contents)
        handle.seek(0)
        report['zip_sha256'] = _stream_digest(handle)
    with sidecar.open('x', encoding='utf-8', newline='\n') as handle:
        handle.write(report['zip_sha256'] + '  ' + output.name + '\n')
    return report
