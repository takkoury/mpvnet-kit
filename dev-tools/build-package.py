#!/usr/bin/env python3
"""Build an allowlisted package directory. Preview by default; never deploys to a player."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile
from urllib.parse import unquote


def digest(data):
    return hashlib.sha256(data).hexdigest()


def relative(value):
    if not isinstance(value, str):
        raise ValueError('relative path must be a string: ' + repr(value))
    p = PurePosixPath(value)
    if not value or p.is_absolute() or '..' in p.parts or '\\' in value or ':' in value or p.as_posix() != value:
        raise ValueError('unsafe relative path: ' + str(value))
    return p


def safe_file(root, name):
    parts = relative(name).parts
    current = root
    if current.is_symlink():
        raise ValueError('symlink root: ' + str(root))
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('symlink entry: ' + name)
    return current


def heading_slugs(value):
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


def inspect_text(files):
    forbidden = re.compile(r'(?:[A-Za-z]:[/\\]Users[/\\][^/\\\s]+|/mnt/[a-z]/(?:Users/[^/\s]+|projects)|/home/[^/\s]+|[A-Za-z]:[/\\]projects|mpvnet-[\w-]+-20\d{6}|file://)', re.I)
    names = set(files)
    for name, data in files.items():
        try:
            value = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        if forbidden.search(value):
            raise ValueError('private environment reference in ' + name)
        if name.endswith('.md'):
            for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', value):
                target = target.strip('<>')
                if re.match(r'https?://|mailto:', target):
                    continue
                path, _, fragment = target.partition('#')
                path, fragment = unquote(path), unquote(fragment)
                if re.match(r'[a-z]+:', target, re.I) or target.startswith('/'):
                    raise ValueError('nonportable Markdown link in ' + name)
                from posixpath import normpath, join, dirname
                linked = normpath(join(dirname(name), path)) if path else name
                if linked not in names:
                    raise ValueError('missing local Markdown link: ' + name + ' -> ' + target)
                if fragment:
                    linked_text = files[linked].decode('utf-8')
                    if fragment not in heading_slugs(linked_text):
                        raise ValueError('missing local Markdown heading: ' + name + ' -> ' + target)


def export(source, destination, spec, dry_run=True):
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
    contents, entries = {}, []
    if mapping.get('schema') != 1 or not isinstance(mapping.get('version'), str):
        raise ValueError('invalid export map schema/version')
    for item in mapping['files']:
        src, dst = item['source'], item['destination']
        relative(src); relative(dst)
        if any(PurePosixPath(name).name.lower() == 'mpvnet-user.json' for name in (src, dst)):
            raise ValueError('user preferences must not be exported: ' + src)
        if dst == 'manifest.json' or '.git' in PurePosixPath(dst).parts or dst in contents:
            raise ValueError('duplicate or reserved destination: ' + dst)
        path = safe_file(source, src)
        if not path.is_file():
            raise ValueError('missing source file: ' + src)
        data = path.read_bytes()
        contents[dst] = data
        entries.append({'path': dst, 'sha256': digest(data), 'component': item['component'], 'origin': item['origin']})
    inspect_text(contents)
    entries.sort(key=lambda x: x['path'])
    manifest = {'schema': 1, 'version': mapping['version'], 'status': 'generated-distribution', 'files': entries}
    manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()
    old = {}
    manifest_old_data = None
    manifest_path = safe_file(destination, 'manifest.json')
    if destination.exists() and not destination.is_dir():
        raise ValueError('destination is not a directory')
    if manifest_path.exists():
        manifest_old_data = manifest_path.read_bytes()
        prior = json.loads(manifest_old_data.decode('utf-8'))
        if prior.get('schema') != 1 or prior.get('status') not in ('local-unpublished-preview', 'generated-distribution'):
            raise ValueError('unrecognized destination manifest')
        for entry in prior['files']:
            name = entry['path']; relative(name)
            if name in old or name == 'manifest.json' or '.git' in PurePosixPath(name).parts:
                raise ValueError('invalid old manifest entry')
            old[name] = entry['sha256']
        if set(old) - set(contents):
            raise ValueError('old managed files removed from allowlist; manual review required')
    elif destination.exists():
        # An unexpected pre-existing destination is never adopted.
        raise ValueError('existing destination without managed manifest; preserve and review')
    for name, expected in old.items():
        path = safe_file(destination, name)
        if not path.is_file() or digest(path.read_bytes()) != expected:
            raise ValueError('externally modified/missing managed file: ' + name)
    for name in contents:
        path = safe_file(destination, name)
        if path.exists() and name not in old:
            raise ValueError('unknown destination collision: ' + name)
        if path.exists() and not path.is_file():
            raise ValueError('destination type collision: ' + name)
        for parent in path.parents:
            if parent == destination.parent:
                break
            if parent.exists() and not parent.is_dir():
                raise ValueError('destination parent collision: ' + name)
    report = {'version': manifest['version'], 'file_count': len(entries), 'manifest_sha256': digest(manifest_data), 'dry_run': dry_run}
    if dry_run:
        return report
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in list(contents.items()) + [('manifest.json', manifest_data)]:
        path = safe_file(destination, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        expected = manifest_old_data if name == 'manifest.json' else old.get(name)
        if expected is not None:
            if not path.is_file():
                raise ValueError('managed target changed during export: ' + name)
            current = path.read_bytes()
            if (current != expected if name == 'manifest.json' else digest(current) != expected):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--map', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='preview only (default)')
    mode.add_argument('--apply', action='store_true', help='write the package directory')
    args = parser.parse_args()
    try:
        print(json.dumps(export(args.source, args.destination, args.map, not args.apply), sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, 'Package build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
