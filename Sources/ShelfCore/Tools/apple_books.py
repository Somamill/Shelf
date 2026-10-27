#!/usr/bin/env python3
"""Read audiobook progress from the local Apple Books library, if available.

Apple does not expose this data through a public macOS API. This importer is
intentionally read-only and treats the on-disk Books database as optional and
schema-versioned. It never changes or unlocks the Books database.
"""
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


def candidate_databases():
    home = Path.home()
    roots = [
        home / "Library/Containers/com.apple.iBooksX/Data/Documents",
        home / "Library/Containers/com.apple.BKAgentService/Data/Documents",
        home / "Library/Group Containers/group.com.apple.iBooks",
        home / "Library/Group Containers/group.com.apple.BKAgentService",
    ]
    found = set()
    denied = False
    for root in roots:
        def onerror(error):
            nonlocal denied
            if isinstance(error, PermissionError) or getattr(error, "errno", None) == 1:
                denied = True

        try:
            for folder, _directories, filenames in os.walk(root, onerror=onerror):
                for filename in filenames:
                    if filename.startswith("BKLibrary") and filename.endswith((".sqlite", ".sqlite3")):
                        found.add(Path(folder) / filename)
        except PermissionError:
            denied = True
    return sorted(p for p in found if p.is_file()), denied


def clean(value):
    return value.strip() if isinstance(value, str) else value


def core_date(value):
    if value is None or value == "":
        return None
    try:
        number = float(value)
        # Core Data timestamps are seconds since 2001-01-01.
        if 0 < number < 500_000_000:
            number += 978307200
        if number > 0:
            return datetime.fromtimestamp(number, timezone.utc).astimezone().isoformat()
    except (TypeError, ValueError, OverflowError, OSError):
        pass
    return str(value)


def read_database(path):
    uri = path.as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only=ON")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "ZBKLIBRARYASSET" not in tables:
            return None
        columns = {row[1].upper() for row in connection.execute("PRAGMA table_info('ZBKLIBRARYASSET')")}
        if "ZTITLE" not in columns or not ({"ZREADINGPROGRESS", "ZHIGHWATERMARKPROGRESS"} & columns):
            return {"status": "unsupported_schema", "books": []}

        mapping = {
            "title": "ZTITLE", "author": "ZAUTHOR", "progress": "ZREADINGPROGRESS",
            "highWater": "ZHIGHWATERMARKPROGRESS", "duration": "ZDURATION",
            "assetId": "ZASSETID", "guid": "ZPERMANENTID", "coverURL": "ZURL",
            "kind": "ZKIND", "audioFlag": "ZISSTOREAUDIOBOOK", "finished": "ZISFINISHED",
            "lastOpened": "ZLASTOPENDATE", "lastEngaged": "ZLASTENGAGEDDATE",
            "hidden": "ZHIDDEN", "sample": "ZISSAMPLE", "supplemental": "ZISSUPPLEMENTAL",
        }
        available = {key: col for key, col in mapping.items() if col in columns}
        selected = ",".join(f'"{column}" AS "{key}"' for key, column in available.items())
        rows = connection.execute(f"SELECT {selected} FROM ZBKLIBRARYASSET").fetchall()
        books = []
        for row in rows:
            item = dict(row)
            kind = str(item.get("kind") or "").lower()
            is_audio = bool(item.get("audioFlag")) or "audiobook" in kind or "audio-book" in kind
            if not is_audio or not clean(item.get("title")):
                continue
            if any(bool(item.get(key)) for key in ("hidden", "sample", "supplemental")):
                continue
            progress = item.get("progress")
            if progress is None:
                progress = item.get("highWater")
            try:
                progress = max(0.0, min(1.0, float(progress or 0)))
            except (TypeError, ValueError):
                progress = 0.0
            duration = item.get("duration")
            try:
                duration = max(0, int(float(duration))) if duration is not None else None
            except (TypeError, ValueError, OverflowError):
                duration = None
            books.append({
                "title": clean(item.get("title")), "author": clean(item.get("author")) or "",
                "progress": progress, "highWater": item.get("highWater"), "duration": duration,
                "assetId": clean(item.get("assetId")), "guid": clean(item.get("guid")),
                "coverURL": clean(item.get("coverURL")),
                "finished": bool(item.get("finished")) or progress >= 0.97,
                "lastOpened": core_date(item.get("lastOpened")),
                "lastEngaged": core_date(item.get("lastEngaged")),
            })
        books.sort(key=lambda b: b.get("lastEngaged") or b.get("lastOpened") or "", reverse=True)
        return {"status": "connected", "books": books}
    finally:
        connection.close()


def main():
    try:
        paths, denied = candidate_databases()
        for path in paths:
            result = read_database(path)
            if result:
                print(json.dumps(result, ensure_ascii=False))
                return
        if denied:
            print(json.dumps({"status": "permission_required", "books": []}))
            return
        print(json.dumps({"status": "not_found", "books": []}))
    except (sqlite3.Error, OSError, ValueError) as error:
        # Keep user paths out of dashboard state and diagnostic messages.
        print(json.dumps({"status": "unavailable", "books": [], "detail": type(error).__name__}))


if __name__ == "__main__":
    main()
