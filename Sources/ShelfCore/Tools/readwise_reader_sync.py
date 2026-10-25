#!/usr/bin/env python3
"""Pull Readwise Reader progress and highlights into matching local EPUBs."""

from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from shelf_config import configured_path


BOOKS = Path.home() / "Books"
LIBRARY = configured_path("library", str(BOOKS / "Calibre Library"))
API = "https://readwise.io/api/v3/list/"


def api_get(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={"Authorization": f"Token {token}"})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            value = json.loads(response.read())
            return value if isinstance(value, dict) else {}
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise RuntimeError("Readwise rejected the saved access token. Reconnect Readwise in Shelf.") from None
        raise RuntimeError(f"Readwise returned HTTP {error.code}.") from None
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Could not reach Readwise: {type(error).__name__}.") from None


def documents(token: str, category: str) -> list[dict]:
    cursor = None
    result = []
    while True:
        query = {"category": category, "limit": "100"}
        if cursor:
            query["pageCursor"] = cursor
        page = api_get(API + "?" + urllib.parse.urlencode(query), token)
        result.extend(item for item in page.get("results", []) if isinstance(item, dict))
        cursor = page.get("nextPageCursor")
        if not cursor:
            return result
        time.sleep(3.1)


def normalize(value: str) -> str:
    value = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return "".join(char for char in value if char.isalnum())


def book_rows() -> list[dict]:
    db = LIBRARY / "metadata.db"
    if not db.is_file():
        raise RuntimeError("The configured Calibre library is unavailable.")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
    try:
        rows = conn.execute("""
            SELECT b.id,b.title,b.path,
              COALESCE((SELECT group_concat(a.name, ' ') FROM books_authors_link l
                        JOIN authors a ON a.id=l.author WHERE l.book=b.id),''),
              COALESCE((SELECT group_concat(d.name || '.' || lower(d.format), char(31))
                        FROM data d WHERE d.book=b.id AND lower(d.format)='epub'),'')
            FROM books b ORDER BY b.id
        """).fetchall()
    finally:
        conn.close()
    books = []
    for book_id, title, relative, author, files in rows:
        formats = [name for name in (files or "").split(chr(31)) if name]
        if not formats:
            continue
        filename = formats[0]
        path = LIBRARY / relative / filename
        if path.is_file():
            books.append({"id": int(book_id), "title": title or "", "author": author or "",
                          "path": str(path), "filename": filename})
    return books


def partial_md5(path: str) -> str:
    digest = hashlib.md5()
    with open(path, "rb") as source:
        for offset in [0] + [1024 * (4 ** index) for index in range(11)]:
            source.seek(offset)
            block = source.read(1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def match_book(document: dict, books: list[dict]) -> dict | None:
    title = normalize(document.get("title", ""))
    author = normalize(document.get("author", ""))
    if len(title) < 4:
        return None
    ranked = []
    for book in books:
        book_title = normalize(book["title"])
        score = difflib.SequenceMatcher(None, title, book_title).ratio()
        if title == book_title:
            score = 1.0
        book_author = normalize(book["author"])
        author_score = difflib.SequenceMatcher(None, author, book_author).ratio() if author and book_author else 0.0
        ranked.append((score, author_score, book))
    ranked.sort(key=lambda row: (row[0], row[1]), reverse=True)
    if not ranked or ranked[0][0] < 0.90:
        return None
    if len(ranked) > 1 and ranked[0][:2] == ranked[1][:2]:
        return None
    if author and ranked[0][1] < 0.5:
        return None
    return ranked[0][2]


def iso_timestamp(value: str | None) -> int:
    if not value:
        return 0
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except ValueError:
        return 0


def sync_endpoint(root: str, token: str, username: str, doc: str, progress: float,
                  timestamp: int, title: str, author: str, filename: str) -> bool | None:
    root = root.rstrip("/")
    headers = {"x-auth-user": username, "x-auth-key": token,
               "Accept": "application/vnd.koreader.v1+json", "Content-Type": "application/json"}
    safe = urllib.parse.quote(doc, safe="")
    current_time = 0
    try:
        request = urllib.request.Request(f"{root}/syncs/progress/{safe}", headers=headers)
        with urllib.request.urlopen(request, timeout=8) as response:
            current = json.loads(response.read())
            current_time = int(current.get("timestamp", 0) or 0)
    except (OSError, ValueError):
        current_time = 0
    if current_time >= timestamp and current_time > 0:
        return False
    body = {"document": doc, "progress": f"{progress:.6f}", "percentage": progress,
            "timestamp": timestamp, "device": "Readwise Reader", "device_id": "shelf-readwise-reader",
            "metadata": {"title": title, "authors": author, "filename": filename}}
    request = urllib.request.Request(f"{root}/syncs/progress", data=json.dumps(body).encode(),
                                     headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            return response.status in (200, 201, 204)
    except (OSError, ValueError):
        return None


def create_highlight(token: str, title: str, author: str, text: str) -> dict:
    items = documents(token, "epub")
    target = {"title": title, "author": author}
    book = match_book(target, [{"id": i, "title": str(item.get("title", "")),
                               "author": str(item.get("author", "")), "path": "", "filename": ""}
                              for i, item in enumerate(items)])
    if book is None:
        raise RuntimeError("No matching Readwise Reader EPUB was found for this book.")
    parent = items[book["id"]].get("id")
    if not parent:
        raise RuntimeError("The matching Readwise Reader book has no document ID.")
    request = urllib.request.Request(
        "https://readwise.io/api/v3/save/",
        data=json.dumps({"parent_id": parent, "content": text}).encode(),
        headers={"Authorization": f"Token {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return {"created": response.status in (200, 201)}
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise RuntimeError("Readwise rejected the saved access token.") from None
        if error.code == 400:
            raise RuntimeError("Readwise could not match this passage to the EPUB text.") from None
        raise RuntimeError(f"Readwise returned HTTP {error.code} while saving the highlight.") from None
    except OSError as error:
        raise RuntimeError(f"Could not reach Readwise: {type(error).__name__}.") from None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        token = str(payload.get("readwiseToken", "")).strip()
        if payload.get("action") == "createHighlight":
            if not token:
                raise RuntimeError("Connect Readwise in Shelf to sync highlights.")
            result = create_highlight(token, str(payload.get("title", "")),
                                      str(payload.get("author", "")),
                                      str(payload.get("text", "")).strip())
            print(json.dumps({"ok": True, **result}))
            return 0
        username = str(payload.get("username", "")).strip()
        sync_key = str(payload.get("syncKey", "")).strip()
        endpoints = [str(value).rstrip("/") for value in payload.get("syncEndpoints", []) if value]
        if not token or not username or not sync_key:
            raise RuntimeError("Add Readwise and KOReader Sync credentials in Shelf first.")
        local = book_rows()
        reader_books = documents(token, "epub")
        matches = []
        by_reader_id = {}
        seen_local = set()
        for item in reader_books:
            if not item.get("title"):
                continue
            book = match_book(item, local)
            if not book:
                continue
            item = {**item, "shelfBookId": book["id"]}
            by_reader_id[str(item.get("id", ""))] = book
            matches.append(item)
            seen_local.add(book["id"])
        pushed = 0
        newer_local = 0
        failures = 0
        for item in matches:
            progress = item.get("reading_progress")
            if not isinstance(progress, (int, float)) or not 0 <= progress <= 1:
                continue
            book = by_reader_id[str(item.get("id", ""))]
            timestamp = iso_timestamp(item.get("last_opened_at") or item.get("updated_at"))
            doc = partial_md5(book["path"])
            item_pushed = False
            item_newer = False
            for endpoint in endpoints:
                status = sync_endpoint(endpoint, sync_key, username, doc, float(progress), timestamp,
                                       str(item.get("title", book["title"])),
                                       str(item.get("author", book["author"])), book["filename"])
                item_pushed |= status is True
                item_newer |= status is False
                failures += status is None
            if item_pushed:
                pushed += 1
            elif item_newer:
                newer_local += 1
        highlights_by_book: dict[str, list[dict]] = {}
        if by_reader_id:
            for highlight in documents(token, "highlight"):
                parent = str(highlight.get("parent_id", ""))
                book = by_reader_id.get(parent)
                text = str(highlight.get("content") or highlight.get("title") or "").strip()
                if not book or not text:
                    continue
                bucket = highlights_by_book.setdefault(str(book["id"]), [])
                bucket.append({"text": text[:4096], "note": str(highlight.get("notes") or "")[:1200],
                               "id": str(highlight.get("id", ""))})
        print(json.dumps({"ok": True, "matched": len(matches), "progressPushed": pushed,
                          "newerLocalProgress": newer_local, "syncFailures": failures,
                          "highlightsByBook": highlights_by_book},
                         ensure_ascii=False))
        return 0
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stdout)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
