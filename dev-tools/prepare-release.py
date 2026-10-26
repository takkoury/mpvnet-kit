#!/usr/bin/env python3
"""Validate a public manifest; create a deterministic ZIP only with --apply."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import runpy
from urllib.parse import unquote, urlsplit
import zipfile

# Share the exporter’s path, privacy and heading rules without running its CLI.
_RULES = runpy.run_path(str(Path(__file__).with_name('build-package.py')))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def clean_root(path):
    path = Path(os.path.abspath(path))
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('symlink root or ancestor: ' + str(path))
    return path


def markdown_links(files):
    _RULES['inspect_text']({name + '.txt': data for name, data in files.items()})
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
            if parsed.fragment and unquote(parsed.fragment) not in _RULES['heading_slugs'](files[linked].decode('utf-8')):
                raise ValueError('missing local Markdown heading: ' + name + ' -> ' + target)


def package(source, output, apply=False):
    source, output = clean_root(source), clean_root(output)
    development = Path(__file__).resolve().parent.parent
    for root in (source, development):
        if output == root or root in output.parents:
            raise ValueError('output must be outside public and development repositories')
    if output.suffix.lower() != '.zip':
        raise ValueError('output must end in .zip')
    manifest_path = _RULES['safe_file'](source, 'manifest.json')
    manifest_data = manifest_path.read_bytes()
    manifest = json.loads(manifest_data.decode('utf-8'))
    version = manifest.get('version')
    if manifest.get('schema') != 1 or not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version):
        raise ValueError('invalid manifest schema/version')
    entries = manifest.get('files')
    if not isinstance(entries, list) or not entries:
        raise ValueError('manifest files must be a nonempty list')
    contents, folded = {}, {}
    for entry in entries:
        name = entry['path']
        parts = _RULES['relative'](name).parts
        if any(part.endswith(('.', ' ')) or re.search(r'[<>\"|?*\x00-\x1f]', part) or re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part, re.I) for part in parts):
            raise ValueError('nonportable Windows path: ' + name)
        if name.casefold() == 'manifest.json' or any(p.casefold() == '.git' for p in parts):
            raise ValueError('reserved manifest entry: ' + name)
        # Check every prefix, including directory names, for Windows collisions.
        for length in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:length])
            prior = folded.setdefault(prefix.casefold(), prefix)
            if prior != prefix:
                raise ValueError('case-insensitive path collision: ' + name)
        if name in contents:
            raise ValueError('duplicate manifest entry: ' + name)
        expected = entry['sha256']
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('invalid SHA256: ' + name)
        path = _RULES['safe_file'](source, name)
        if not path.is_file():
            raise ValueError('missing regular file: ' + name)
        data = path.read_bytes()
        if sha(data) != expected:
            raise ValueError('SHA256 mismatch: ' + name)
        contents[name] = data
    contents['manifest.json'] = manifest_data
    markdown_links(contents)
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
    checksum = (sha(data) + '  ' + output.name + '\n').encode('utf-8')
    sidecar = clean_root(Path(str(output) + '.sha256'))
    for path, intended in ((output, data), (sidecar, checksum)):
        if path.exists() and (not path.is_file() or path.read_bytes() != intended):
            raise ValueError('existing output differs; preserve and review: ' + str(path))
    report = {'version': version, 'root': prefix, 'file_count': len(contents), 'zip_sha256': sha(data), 'output': str(output), 'dry_run': not apply, 'blockers': blockers}
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--dry-run', action='store_true', help='explicit default: validate and report only')
    args = parser.parse_args()
    try:
        print(json.dumps(package(args.source, args.output, args.apply), ensure_ascii=False, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, UnicodeError) as error:
        parser.exit(1, 'Release preparation stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
