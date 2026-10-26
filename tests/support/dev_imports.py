"""Import developer modules through one shared test path setup."""
from pathlib import Path
import sys

DEV_TOOLS = str(Path(__file__).resolve().parents[2] / 'dev-tools')
if DEV_TOOLS not in sys.path:
    sys.path.insert(0, DEV_TOOLS)

import package_lib
from package_lib import package_zip, stage_package

__all__ = ['package_lib', 'package_zip', 'stage_package']
