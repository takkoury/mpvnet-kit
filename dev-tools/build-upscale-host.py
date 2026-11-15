#!/usr/bin/env python3
"""Build the upscale host extension offline against a local mpv.net executable."""

import argparse
from functools import partial
import importlib.util
import json
from pathlib import Path

import managed_build


ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'UpscaleHost.csproj'
ASSEMBLY = 'KitUpscaleHost.dll'
SOURCE_METADATA_KEY = 'KitUpscaleHost.SourceSha256'
SOURCE_FILES = (PROJECT, 'UpscaleHostExtension.cs', 'RuntimeBundle.cs', 'NativeRuntime.cs')


def source_digest(source):
    inputs = source / 'src' / 'upscale-host'
    return managed_build.source_digest(managed_build.source_snapshot(inputs, SOURCE_FILES, 'upscale host'))


def matches_source_digest(data, digest):
    return managed_build.matches_source_digest(data, digest, SOURCE_METADATA_KEY)


def build_upscale_host(host, output, *, apply=False):
    spec = importlib.util.spec_from_file_location('extension_build', Path(__file__).with_name('build-context-menu.py'))
    extension_build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extension_build)
    compile_extension = partial(extension_build._build, project_file=PROJECT, assembly=ASSEMBLY,
                                metadata_key=SOURCE_METADATA_KEY)
    return extension_build.build_extension(host, output, ROOT / 'src' / 'upscale-host', SOURCE_FILES,
                                           ASSEMBLY, compile_extension, apply=apply)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, type=Path, help='original single-file mpv.net executable')
    parser.add_argument('--output', required=True, type=Path, help='new directory outside the repository and player')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='validate the inputs without writing (default)')
    mode.add_argument('--apply', action='store_true', help='compile the extension and write build evidence')
    args = parser.parse_args()
    try:
        print(json.dumps(build_upscale_host(args.host, args.output, apply=args.apply), sort_keys=True))
    except (ValueError, OSError) as error:
        parser.exit(1, 'Upscale host build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
