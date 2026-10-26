"""Build allowlisted package directories and deterministic release archives.

Both operations validate before writing and preview unless apply=True. Staging
owns managed-file updates; ZIP creation never replaces different existing output.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import tempfile
from urllib.parse import unquote, urlsplit
import zipfile


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _relative(value):
    if not isinstance(value, str):
        raise ValueError('relative path must be a string: ' + repr(value))
    p = PurePosixPath(value)
    if not value or p.is_absolute() or '..' in p.parts or '\\' in value or ':' in value or p.as_posix() != value:
        raise ValueError('unsafe relative path: ' + str(value))
    return p


def _check_user_file(name):
    if PurePosixPath(name).name.casefold() == 'mpvnet-user.json':
        raise ValueError('user preferences must not be exported: ' + name)


def _register_path(name, folded):
    parts = _relative(name).parts
    if any(part.endswith(('.', ' ')) or re.search(r'[<>\"|?*\x00-\x1f]', part) or re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part, re.I) for part in parts):
        raise ValueError('nonportable Windows path: ' + name)
    _check_user_file(name)
    if name.casefold() == 'manifest.json' or any(p.casefold() == '.git' for p in parts):
        raise ValueError('reserved manifest entry: ' + name)
    # Check every prefix, including directory names, for Windows collisions.
    for length in range(1, len(parts) + 1):
        prefix = '/'.join(parts[:length])
        prior = folded.setdefault(prefix.casefold(), prefix)
        if prior != prefix:
            raise ValueError('case-insensitive path collision: ' + name)


def _schema_version(document, kind):
    version = document.get('version')
    if document.get('schema') != 1 or not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version):
        raise ValueError('invalid ' + kind + ' schema/version')
    return version


def _file_entries(document, kind):
    entries = document.get('files')
    if not isinstance(entries, list) or not entries:
        raise ValueError(kind + ' files must be a nonempty list')
    return entries


def _expected_digest(entry):
    expected = entry['sha256']
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('invalid SHA256: ' + entry['path'])
    return expected


def _safe_file(root, name):
    parts = _relative(name).parts
    current = root
    if current.is_symlink():
        raise ValueError('symlink root: ' + str(root))
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('symlink entry: ' + name)
    return current


def _heading_slugs(value):
    slugs, fence, previous = set(), None, ''
    for line in value.splitlines():
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if marker:
            if fence is None:
                fence = marker[1][0]
            elif marker[1][0] == fence:
                fence = None
            previous = ''
            continue
        if fence:
            continue
        heading = re.match(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$', line)
        text = heading[1] if heading else previous if previous and re.fullmatch(r' {0,3}(?:=+|-+)\s*', line) else None
        if text is not None:
            text = re.sub(r'<[^>]*>', '', text)
            text = re.sub(r'!?\[([^\]]+)\]\([^)]*\)', r'\1', text)
            base = re.sub(r'[^\w\s-]', '', text.strip().lower())
            base = re.sub(r'\s', '-', base)
            slug, suffix = base, 0
            while slug in slugs:
                suffix += 1
                slug = base + '-' + str(suffix)
            slugs.add(slug)
        previous = line.strip() if line.strip() and not line.lstrip().startswith('|') else ''
    return slugs


def _inspect_privacy(files):
    forbidden = re.compile(r'(?:[A-Za-z]:[/\\]Users[/\\][^/\\\s]+|/mnt/[a-z]/(?:Users/[^/\s]+|projects)|/home/[^/\s]+|[A-Za-z]:[/\\]projects|mpvnet-[\w-]+-20\d{6}|file://)', re.I)
    for name, data in files.items():
        try:
            value = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        if forbidden.search(value):
            raise ValueError('private environment reference in ' + name)


def _clean_root(path):
    path = Path(os.path.abspath(path))
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('symlink root or ancestor: ' + str(path))
    return path


def _markdown_links(files):
    for name, data in files.items():
        if not name.lower().endswith('.md'):
            continue
        value = data.decode('utf-8')
        # Reference definitions and HTML links supplement inline Markdown links.
        targets = re.findall(r'!?\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[\"\x27][^\"\x27]*[\"\x27])?\s*\)', value)
        targets += re.findall(r'^ {0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)', value, re.M)
        targets += re.findall(r'(?:href|src)\s*=\s*[\"\x27]([^\"\x27]+)', value, re.I)
        for target in targets:
            target = target.strip('<>')
            parsed = urlsplit(target)
            if parsed.scheme in ('https', 'http', 'mailto'):
                continue
            if parsed.scheme or parsed.netloc or target.startswith('/') or '\\' in target:
                raise ValueError('nonportable Markdown link: ' + name + ' -> ' + target)
            path = unquote(parsed.path)
            linked = posixpath.normpath(posixpath.join(posixpath.dirname(name), path)) if path else name
            if linked not in files:
                raise ValueError('missing local Markdown link: ' + name + ' -> ' + target)
            if parsed.fragment and unquote(parsed.fragment) not in _heading_slugs(files[linked].decode('utf-8')):
                raise ValueError('missing local Markdown heading: ' + name + ' -> ' + target)


def stage_package(source, destination, spec, *, apply=False) -> dict:
    """Validate an allowlist and stage managed files only when apply is true."""
    source, destination, spec = Path(source), Path(destination), Path(spec)
    if any(p.is_symlink() for root in (source, destination) for p in (root, *root.parents)):
        raise ValueError('symlink root or ancestor')
    source = source.absolute()
    destination = destination.absolute()
    if any(p.is_symlink() for root in (source, destination) for p in (root, *root.parents)):
        raise ValueError('symlink absolute root or ancestor')
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError('source and destination must be separate trees')
    if (destination / '.git').exists():
        raise ValueError('destination must be a package directory, not a Git checkout')
    mapping = json.loads(spec.read_text(encoding='utf-8'))
    contents, entries, folded = {}, [], {}
    version = _schema_version(mapping, 'export map')
    for item in _file_entries(mapping, 'export map'):
        src, dst = item['source'], item['destination']
        _relative(src)
        _check_user_file(src)
        _register_path(dst, folded)
        if dst in contents:
            raise ValueError('duplicate destination: ' + dst)
        path = _safe_file(source, src)
        if not path.is_file():
            raise ValueError('missing source file: ' + src)
        data = path.read_bytes()
        contents[dst] = data
        entries.append({'path': dst, 'sha256': _digest(data), 'component': item['component'], 'origin': item['origin']})
    entries.sort(key=lambda x: x['path'])
    manifest = {'schema': 1, 'version': version, 'status': 'generated-distribution', 'files': entries}
    manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()
    package_contents = {**contents, 'manifest.json': manifest_data}
    _inspect_privacy(package_contents)
    _markdown_links(package_contents)
    old = {}
    manifest_old_data = None
    manifest_path = _safe_file(destination, 'manifest.json')
    if destination.exists() and not destination.is_dir():
        raise ValueError('destination is not a directory')
    if manifest_path.exists():
        manifest_old_data = manifest_path.read_bytes()
        prior = json.loads(manifest_old_data.decode('utf-8'))
        if prior.get('schema') != 1 or prior.get('status') not in ('local-unpublished-preview', 'generated-distribution'):
            raise ValueError('unrecognized destination manifest')
        old_folded = {}
        for entry in prior['files']:
            name = entry['path']
            _register_path(name, old_folded)
            if name in old:
                raise ValueError('invalid old manifest entry')
            old[name] = _expected_digest(entry)
        if set(old) - set(contents):
            raise ValueError('old managed files removed from allowlist; manual review required')
    elif destination.exists():
        # An unexpected pre-existing destination is never adopted.
        raise ValueError('existing destination without managed manifest; preserve and review')
    for name, expected in old.items():
        path = _safe_file(destination, name)
        if not path.is_file() or _digest(path.read_bytes()) != expected:
            raise ValueError('externally modified/missing managed file: ' + name)
    for name in contents:
        path = _safe_file(destination, name)
        if path.exists() and name not in old:
            raise ValueError('unknown destination collision: ' + name)
        if path.exists() and not path.is_file():
            raise ValueError('destination type collision: ' + name)
        for parent in path.parents:
            if parent == destination.parent:
                break
            if parent.exists() and not parent.is_dir():
                raise ValueError('destination parent collision: ' + name)
    report = {'version': manifest['version'], 'file_count': len(entries), 'manifest_sha256': _digest(manifest_data), 'dry_run': not apply}
    if not apply:
        return report
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in list(contents.items()) + [('manifest.json', manifest_data)]:
        path = _safe_file(destination, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        expected = manifest_old_data if name == 'manifest.json' else old.get(name)
        if expected is not None:
            if not path.is_file():
                raise ValueError('managed target changed during export: ' + name)
            current = path.read_bytes()
            if (current != expected if name == 'manifest.json' else _digest(current) != expected):
                raise ValueError('managed target changed during export: ' + name)
            if current == data:
                continue
        elif path.exists():
            raise ValueError('unknown target appeared during export: ' + name)
        fd, temp = tempfile.mkstemp(prefix='.export-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(data)
            if expected is None:
                # Exclusive creation cannot overwrite an unknown file appearing after preflight.
                with path.open('xb') as handle:
                    handle.write(data)
            else:
                os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    return report


def package_zip(source, output, *, apply=False) -> dict:
    """Validate a staged manifest and create an immutable ZIP with apply=True."""
    source, output = _clean_root(source), _clean_root(output)
    development = Path(__file__).resolve().parent.parent
    for root in (source, development):
        if output == root or root in output.parents:
            raise ValueError('output must be outside public and development repositories')
    if output.suffix.lower() != '.zip':
        raise ValueError('output must end in .zip')
    manifest_path = _safe_file(source, 'manifest.json')
    manifest_data = manifest_path.read_bytes()
    manifest = json.loads(manifest_data.decode('utf-8'))
    version = _schema_version(manifest, 'manifest')
    entries = _file_entries(manifest, 'manifest')
    contents, folded = {}, {}
    for entry in entries:
        name = entry['path']
        _register_path(name, folded)
        if name in contents:
            raise ValueError('duplicate manifest entry: ' + name)
        expected = _expected_digest(entry)
        path = _safe_file(source, name)
        if not path.is_file():
            raise ValueError('missing regular file: ' + name)
        data = path.read_bytes()
        if _digest(data) != expected:
            raise ValueError('SHA256 mismatch: ' + name)
        contents[name] = data
    contents['manifest.json'] = manifest_data
    _inspect_privacy(contents)
    _markdown_links(contents)
    blockers = []
    if 'LICENSE' not in contents or not contents['LICENSE'].strip():
        blockers.append('manifest must include a nonempty top-level LICENSE')
    licenses = contents.get('LICENSES.md', b'').decode('utf-8')
    if not licenses.strip():
        blockers.append('manifest must include LICENSES.md')
    pending = r'license\s+pending|licen[cs]ing\s+pending|许可待|待选定|须决定|没有统一的项目许可证|未对.*新增授权'
    if re.search(pending, licenses, re.I):
        blockers.append('LICENSES.md contains unresolved licensing notice')
    if any(re.search(pending, str(entry.get('origin', '')), re.I) for entry in entries):
        blockers.append('manifest origin contains unresolved licensing notice')
    buffer = io.BytesIO()
    prefix = 'mpvnet-kit-' + version
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(contents):
            info = zipfile.ZipInfo(prefix + '/' + name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, contents[name])
    data = buffer.getvalue()
    checksum = (_digest(data) + '  ' + output.name + '\n').encode('utf-8')
    sidecar = _clean_root(Path(str(output) + '.sha256'))
    for path, intended in ((output, data), (sidecar, checksum)):
        if path.exists() and (not path.is_file() or path.read_bytes() != intended):
            raise ValueError('existing output differs; preserve and review: ' + str(path))
    report = {'version': version, 'root': prefix, 'file_count': len(contents), 'zip_sha256': _digest(data), 'output': str(output), 'dry_run': not apply, 'blockers': blockers}
    if apply:
        if blockers:
            raise ValueError('release blocked: ' + '; '.join(blockers))
        output.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation protects a target appearing after preflight. Preserve
        # partial output after I/O failure for inspection; never overwrite it.
        for path, intended in ((output, data), (sidecar, checksum)):
            try:
                with path.open('xb') as handle:
                    handle.write(intended)
            except FileExistsError:
                if not path.is_file() or path.read_bytes() != intended:
                    raise ValueError('output changed during creation: ' + str(path))
        report['result'] = 'created-or-identical'
    return report
