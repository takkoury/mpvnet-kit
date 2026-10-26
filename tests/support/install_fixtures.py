"""Read-only preflight and owned output helpers for installer regressions."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import uuid
import zipfile


def absolute_without_links(value):
    path = Path(value)
    if not path.is_absolute():
        raise RuntimeError('Fixture/package paths must be absolute')
    for parent in (path, *path.parents):
        if parent.is_symlink() or (hasattr(parent, 'is_junction') and parent.is_junction()):
            raise RuntimeError('Fixture paths cannot traverse links')
    return path.resolve()


def source_worktrees(source):
    source = Path(source).resolve()
    roots = [source]
    if (source / '.git').exists():
        output = subprocess.check_output(['git', 'worktree', 'list', '--porcelain'],
                                         cwd=source, encoding='utf-8')
        roots.extend(Path(line[9:]).resolve() for line in output.splitlines()
                     if line.startswith('worktree '))
    return roots


def package_directory(value):
    path = absolute_without_links(value)
    if not (path / 'manifest.json').is_file():
        raise RuntimeError('Missing package manifest: ' + str(path))
    return path


def checked_fixture_root(value, source, *, packages=(), mode='new'):
    """Validate without writing; unique mode permits an existing artifact store."""
    if mode not in ('new', 'unique'):
        raise ValueError('Unknown fixture directory mode')
    root = absolute_without_links(value)
    if any(root == tree or tree in root.parents for tree in source_worktrees(source)):
        raise RuntimeError('Fixture root must be outside source worktrees')
    if mode == 'new' and root.exists():
        raise RuntimeError('Fixture root must be new')
    if root.exists() and not root.is_dir():
        raise RuntimeError('Artifact store must be a directory')
    for value in packages:
        package = package_directory(value)
        if root == package or root in package.parents or package in root.parents:
            raise RuntimeError('Fixture and package roots must be separate')
    return root


def create_fixture_root(value, source, *, packages=(), mode='new'):
    root = checked_fixture_root(value, source, packages=packages, mode=mode)
    if mode == 'unique':
        root = root / ('tests-' + uuid.uuid4().hex[:10])
    root.mkdir(parents=True, exist_ok=False)
    return root


def powershell_path():
    if os.name != 'nt':
        raise RuntimeError('Requires Windows PowerShell')
    path = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if not path.is_file():
        raise RuntimeError('Windows PowerShell is unavailable')
    return path


def load_release_files(repository, release):
    """Read the fixed catalog commit and verify every byte before fixture writes."""
    data = subprocess.check_output(['git', '-C', str(repository), 'archive', '--format=zip', release['commit']])
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        files = {entry['path']: archive.read('config/' + entry['path']) for entry in release['files']}
    for entry in release['files']:
        if hashlib.sha256(files[entry['path']]).hexdigest() != entry['sha256']:
            raise RuntimeError('Catalog is inconsistent with immutable release archive')
    return files


def runtime_hashes(package):
    manifest = json.loads((Path(package) / 'manifest.json').read_text(encoding='utf-8-sig'))
    result = {}
    for item in manifest['files']:
        name = item['path']
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            raise ValueError('Unsafe package entry: ' + name)
        if name.startswith('config/') and not name.lower().endswith('.example'):
            result[name[7:]] = item['sha256']
    return result


def run_recorded(command, prefix, *, env=None, timeout=60, append_suffix=False):
    result = subprocess.run(command, env=env, capture_output=True, timeout=timeout)
    prefix = Path(prefix)
    for suffix, data in (('.stdout', result.stdout), ('.stderr', result.stderr)):
        output = Path(str(prefix) + suffix) if append_suffix else prefix.with_suffix(suffix)
        output.write_bytes(data)
    return result
