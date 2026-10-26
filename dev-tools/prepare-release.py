#!/usr/bin/env python3
"""Validate a public manifest; create a deterministic ZIP only with --apply."""
import argparse
import json
from pathlib import Path

from package_lib import package_zip


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--dry-run', action='store_true', help='explicit default: validate and report only')
    args = parser.parse_args()
    try:
        print(json.dumps(package_zip(args.source, args.output, apply=args.apply), ensure_ascii=False, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, UnicodeError) as error:
        parser.exit(1, 'Release preparation stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
