#!/usr/bin/env python3
"""Load the production menu DLL in an isolated STA WPF process without opening any window."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests' / 'context-menu'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assembly', type=Path, required=True, help='Built KitContextMenu.dll')
    parser.add_argument('--output', type=Path, required=True, help='Fresh evidence directory outside the repository')
    args = parser.parse_args()

    dotnet = shutil.which('dotnet')
    if sys.platform != 'win32' or not dotnet:
        parser.error('Windows and a local .NET 10 SDK are required')
    assembly = args.assembly.resolve()
    if assembly.name != 'KitContextMenu.dll' or not assembly.is_file():
        parser.error('--assembly must point to a built KitContextMenu.dll')
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error('--output must be a fresh directory outside the repository')
    if any((parent / marker).exists() for parent in output.parents
           for marker in ('mpvnet.exe', 'mpv.exe', 'portable_config')):
        parser.error('--output must be outside player directories')

    output.mkdir(parents=True, exist_ok=False)
    project = output / 'harness'
    project.mkdir()
    for name in ('ContextMenu.Tests.csproj', 'Program.cs'):
        shutil.copyfile(TESTS / name, project / name)
    (output / 'global.json').write_text(
        '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}\n',
        encoding='utf-8',
    )
    nuget = output / 'NuGet.Config'
    nuget.write_text('<configuration><packageSources><clear /></packageSources></configuration>\n',
                     encoding='utf-8')
    env = dict(os.environ,
               DOTNET_CLI_HOME=str(output / 'cli'),
               DOTNET_CLI_TELEMETRY_OPTOUT='1',
               DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
               DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true',
               DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false',
               DOTNET_NOLOGO='1',
               NUGET_PACKAGES=str(output / 'packages'))
    bin_dir = output / 'bin'
    build = subprocess.run([
        dotnet, 'build', 'ContextMenu.Tests.csproj', '--configuration', 'Release',
        '--output', str(bin_dir), '--disable-build-servers',
        f'-p:RestoreConfigFile={nuget}', '-p:NuGetAudit=false',
        '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false',
        '-p:ImportDirectoryPackagesProps=false',
    ], cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'build.log').write_bytes(build.stdout)
    if build.returncode:
        print(f'WPF harness build failed. See {output / "build.log"}', file=sys.stderr)
        return build.returncode

    result = subprocess.run([dotnet, str(bin_dir / 'ContextMenu.Tests.dll'), str(assembly)],
                            cwd=output, env=env, capture_output=True)
    (output / 'result.json').write_bytes(result.stdout)
    print(result.stdout.decode('utf-8', errors='replace'), end='')
    if result.stderr:
        (output / 'harness.stderr.txt').write_bytes(result.stderr)
        print(result.stderr.decode('utf-8', errors='replace'), end='', file=sys.stderr)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
