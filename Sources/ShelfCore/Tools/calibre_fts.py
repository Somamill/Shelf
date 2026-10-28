#!/usr/bin/env python3
"""Opt-in Calibre full-text indexing/search bridge with bounded command time."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from shelf_config import configured_path, configured_value


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"status", "enable", "disable", "search"}:
        print(json.dumps({"ok": False, "message": "Choose status, enable, or search."}))
        return 2
    action = sys.argv[1]
    query = " ".join(sys.argv[2:]).strip() if action == "search" else ""
    if action == "search" and not query:
        print(json.dumps({"ok": False, "message": "Enter words to search for."}))
        return 2
    cli = configured_value("tools", "calibredb", "/Applications/calibre.app/Contents/MacOS/calibredb")
    cli_path = Path(cli).expanduser()
    if not cli_path.is_file():
        print(json.dumps({"ok": False, "message": "Install Calibre to use its full-text search."}))
        return 1
    library = configured_value("services", "calibreCli", "http://127.0.0.1:8080/#Calibre_Library")
    args = [str(cli_path), "--with-library", library]
    username = configured_value("account", "username", "")
    if username:
        args += ["--username", username]
    password_file = configured_path("state", "~/Books/state") / "calibre-server-password"
    if password_file.is_file():
        args += ["--password", f"<f:{password_file}>"]
    if action == "status":
        args += ["fts_index", "status"]
    elif action == "enable":
        args += ["fts_index", "enable", "--indexing-speed=slow"]
    elif action == "disable":
        args += ["fts_index", "disable"]
    else:
        args += ["fts_search", "--output-format=json", query]
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=35, check=False)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "message": "Calibre did not respond within 35 seconds. Try again when its server is idle."}))
        return 1
    output = (result.stdout + "\n" + result.stderr).strip()
    if result.returncode != 0:
        message = output[-1000:] or "Calibre full-text search returned an error."
        print(json.dumps({"ok": False, "message": message}))
        return result.returncode
    if action == "search":
        payload = None
        clean = result.stdout.strip()
        try:
            payload = json.loads(clean)
        except ValueError:
            decoder = json.JSONDecoder()
            for start, char in enumerate(clean):
                if char not in "[{":
                    continue
                try:
                    payload, _ = decoder.raw_decode(clean[start:])
                    break
                except ValueError:
                    continue
        if payload is None:
            payload = output[-6000:]
        print(json.dumps({"ok": True, "action": action, "results": payload}, ensure_ascii=False))
    else:
        print(json.dumps({"ok": True, "action": action, "message": output[-1600:] or "Complete."}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
