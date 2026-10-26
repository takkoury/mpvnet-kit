#!/usr/bin/env python3
"""Read-only source inventory for the M2 entry-point review.

This is a source locator, not a Lua/PowerShell parser or a runtime coverage test.
It never reads an installed player's configuration or opens a window.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


def inventory(root):
    menus, actions, references, sources = [], [], [], []
    paths = [root / "config/input.conf", root / "Install.cmd"]
    for directory in ("config/scripts", "config/script-modules", "config/helpers", "tools"):
        paths.extend(p for p in (root / directory).rglob("*")
                     if p.suffix.lower() in (".lua", ".ps1", ".psm1"))
    patterns = {
        "selection_or_statistics": r"(?:select/|stats/|console/|require\(['\"]mp\.input)",
        "host_window": r"(?:show-menu|show-conf-editor|show-input-editor|show-about|show-media-info)",
        "external_or_system_window": r"(?:OpenFileDialog|FolderBrowserDialog|MessageBox|shell-execute|edit-conf-file)",
        "window_lifecycle": r"(?:ShowDialog|New-Object .*\.Form|<Window\b|Add_FormClosing|Add_Closing)",
        "feedback": r"(?:osd_message\(|show-text|\.Text\s*=|Write-Host|\bthrow\s)",
    }
    action_row = re.compile(r"^\s*\{'([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)'")
    for path in sorted(set(paths)):
        relative = path.relative_to(root).as_posix()
        raw = path.read_bytes()
        sources.append({"path": relative, "sha256": hashlib.sha256(raw).hexdigest()})
        for number, line in enumerate(raw.decode("utf-8-sig").splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", "--")):
                continue
            location = {"path": relative, "line": number}
            if relative == "config/input.conf" and "#menu:" in line:
                body, label = line.split("#menu:", 1)
                key, command = body.strip().split(None, 1)
                menus.append(location | {"label": label.strip(), "key": key,
                                          "command": command, "separator": label.strip().endswith(" > -")})
            if relative == "config/script-modules/user-shortcuts.lua":
                match = action_row.match(line)
                if match:
                    action_id, category, label, command = match.groups()
                    actions.append(location | {"id": action_id, "category": category,
                                               "label": label, "command": command})
            for kind, expression in patterns.items():
                if re.search(expression, line):
                    references.append(location | {"kind": kind, "text": stripped})
    return {
        "schema": 1,
        "scope": "Source references only; dynamic routes, inactive branches and actual visibility need review.",
        "counts": {"sources": len(sources), "menu_rows": len(menus),
                   "action_rows": len(actions), "references": len(references)},
        "sources": sources, "menus": menus, "actions": actions, "references": references,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1],
                        help="Source checkout; never use an installed player directory.")
    args = parser.parse_args()
    root = args.source.resolve()
    if not (root / "dev-tools/package-map.json").is_file():
        parser.error("Expected a source checkout containing dev-tools/package-map.json.")
    sys.stdout.reconfigure(encoding="utf-8")
    json.dump(inventory(root), sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
