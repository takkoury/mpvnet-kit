#!/usr/bin/env python3
"""Run explicit groups of the repository's unittest suite."""
from test_runner import main
import sys

if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    raise SystemExit(main())
