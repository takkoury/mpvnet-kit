#!/usr/bin/env python3
"""Build an allowlisted package directory. Preview by default; never deploys to a player."""
import argparse
import json
from pathlib import Path

from package_lib import stage_package


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
        print(json.dumps(stage_package(args.source, args.destination, args.map, apply=args.apply), sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, UnicodeError) as error:
        parser.exit(1, 'Package build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
