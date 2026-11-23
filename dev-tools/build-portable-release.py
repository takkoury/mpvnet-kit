#!/usr/bin/env python3
"""Build a private offline installer candidate from the pinned upstream ZIP."""
import argparse
import json
from pathlib import Path
import zipfile

from portable_release import build_portable_release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='validate inputs without writing (default)')
    mode.add_argument('--apply', action='store_true', help='create the package directory, ZIP and checksum')
    args = parser.parse_args()
    try:
        report = build_portable_release(Path(__file__).resolve().parents[1], args.upstream,
                                        args.destination, args.output, apply=args.apply)
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, zipfile.BadZipFile) as error:
        parser.exit(1, 'Portable release build stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
