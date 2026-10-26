"""Check source documentation links without private notes or network access."""
from pathlib import Path
import subprocess
import unittest

from support.dev_imports import package_lib

ROOT = Path(__file__).resolve().parents[1]


class DocumentationLinks(unittest.TestCase):
    def test_public_source_documentation_links(self):
        names = set(subprocess.check_output(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT
        ).decode().split('\0')) - {''}
        files = {name: (ROOT / name).read_bytes() for name in names if (ROOT / name).is_file()}
        # Reuse the package validator; the source set also includes developer docs.
        package_lib._markdown_links(files)
