#!/usr/bin/env python3

import fcntl
import difflib
import hashlib
import json
import os
import re
import sqlite3
import shutil
import subprocess
import sys
import time
import tempfile
import unicodedata
from datetime import datetime
from shelf_config import configured_path, configured_value, configuration_section

BOOKS = str(configured_path("booksRoot", "~/Books"))
LIBRARY = str(configured_path("library", os.path.join(BOOKS, "Calibre Library")))
METADATA_DB = os.path.join(LIBRARY, "metadata.db")
STATE = str(configured_path("state", os.path.join(BOOKS, "state")))
LOGS = str(configured_path("logs", os.path.join(BOOKS, "logs")))

USERNAME = configured_value("account", "username", "reader")
TOOLS = configuration_section("tools")
CONTAINERS = configuration_section("containers")
CALIBREDB = TOOLS.get("calibredb") or shutil.which("calibredb") or "/Applications/calibre.app/Contents/MacOS/calibredb"
DOCKER = TOOLS.get("docker") or shutil.which("docker") or "/usr/bin/docker"
SERVER = configured_value("services", "calibreCli", "http://127.0.0.1:8080/#Calibre_Library")
CONTAINER = CONTAINERS.get("kosync", "kosync")
COMMAND_TIMEOUT = 150  # calibredb's default network timeout is 120 seconds.
PASSFILE = os.path.join(STATE, "calibre-server-password")
LOGFILE = os.path.join(LOGS, "kosync-calibre-bridge.log")
LOCK = os.path.join(STATE, ".kosync-calibre-bridge.lock")
ALIASES = os.path.join(STATE, "kosync-calibre-aliases.json")
UNMATCHED = os.path.join(STATE, "kosync-calibre-unmatched.json")
CROSSPOINT_DB = os.path.expanduser(configured_value("paths", "crosspointDatabase", os.path.join(BOOKS, "KOSync", "crosspoint-sync", "data", "crosspoint.db")))

os.makedirs(LOGS, exist_ok=True)

def log(msg):
    with open(LOGFILE, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.now().isoformat(sep=' ', timespec='seconds')}] {msg}\n")

def cmd(args, check=True):
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=check,
        timeout=COMMAND_TIMEOUT,
    )

def redis(*args):
    return cmd(
        [DOCKER, "exec", CONTAINER, "redis-cli", "-n", "1", *args]
    ).stdout.strip()

def partial_md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        # KOReader samples from byte 0, then at 1 KiB * 4**i for i=0..10.
        # The byte-zero sample is essential; inserting a 256-byte sample here
        # creates a different ID that no KOReader device will recognize.
        for offset in [0] + [1024 * (4 ** i) for i in range(11)]:
            f.seek(offset)
            sample = f.read(1024)
            if not sample:
                break
            h.update(sample)

    return h.hexdigest()

def local_format_paths():
    """Resolve Calibre format names to files; remote calibredb returns names only."""
    uri = f"file:{METADATA_DB}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    try:
        rows = conn.execute(
            "SELECT d.book, b.path, d.name, d.format "
            "FROM data d JOIN books b ON b.id=d.book ORDER BY d.book, d.format"
        ).fetchall()
    finally:
        conn.close()

    paths = {}
    for book_id, relpath, name, fmt in rows:
        candidate = os.path.join(LIBRARY, relpath, f"{name}.{fmt.lower()}")
        if os.path.isfile(candidate):
            paths.setdefault(book_id, []).append((fmt.upper(), candidate))
    return paths

def normalized_title(value):
    value = unicodedata.normalize("NFKC", str(value or "")).casefold()
    value = re.sub(r"\s*[（(][^）)]*[）)]\s*$", "", value)
    return "".join(ch for ch in value if ch.isalnum())

def normalized_author(value):
    tokens = re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", str(value or "")).casefold(), re.UNICODE)
    return "".join(sorted(tokens))

def normalized_identifiers(values):
    """Flatten EPUB/reader identifiers into stable type:value tokens."""
    if isinstance(values, str):
        try:
            decoded = json.loads(values)
            values = decoded if isinstance(decoded, (dict, list)) else values
        except (ValueError, TypeError):
            pass
    pairs = []
    def collect(key, value):
        if isinstance(value, dict):
            identifier_type = value.get("type") or value.get("scheme") or value.get("identifierType")
            identifier_value = value.get("value") or value.get("identifier")
            if identifier_type and identifier_value:
                pairs.append((str(identifier_type), identifier_value))
                return
            for child_key, child_value in value.items():
                collect(child_key, child_value)
        elif isinstance(value, list):
            for child in value:
                collect(key, child)
        elif isinstance(value, str) and key in (None, "") and ":" in value:
            child_key, child_value = value.split(":", 1)
            pairs.append((child_key, child_value))
        elif key not in (None, ""):
            pairs.append((str(key), value))
    collect(None, values)
    result = set()
    for key, value in pairs:
        if isinstance(value, (dict, list)):
            continue
        kind = re.sub(r"[^a-z0-9]", "", str(key).casefold())
        raw = str(value or "").casefold()
        compact = re.sub(r"[^a-z0-9x]", "", raw)
        if not compact:
            continue
        isbn_match = re.search(r"(?:urn:)?isbn[:/]([0-9xX-]{10,17})", raw)
        isbn = re.sub(r"[^0-9x]", "", (isbn_match.group(1) if isbn_match else raw).casefold())
        isbn_valid = False
        if len(isbn) == 10 and re.fullmatch(r"\d{9}[\dx]", isbn):
            checksum = sum((10 - index) * (10 if char == "x" else int(char)) for index, char in enumerate(isbn))
            isbn_valid = checksum % 11 == 0
        elif len(isbn) == 13 and isbn.isdigit():
            checksum = sum(int(char) * (1 if index % 2 == 0 else 3) for index, char in enumerate(isbn))
            isbn_valid = checksum % 10 == 0
        if isbn_valid:
            result.add(f"isbn:{isbn}")
        if kind in {"isbn", "isbn10", "isbn13"}:
            kind = "isbn"
        result.add(f"{kind}:{compact}")
    return result

def local_book_identities():
    conn = sqlite3.connect(f"file:{METADATA_DB}?mode=ro", uri=True, timeout=10)
    try:
        rows = conn.execute("""
            SELECT b.id, b.title,
                   COALESCE((SELECT group_concat(a.name, ' ')
                               FROM books_authors_link l JOIN authors a ON a.id=l.author
                              WHERE l.book=b.id), ''),
                   COALESCE((SELECT group_concat(d.name || '.' || lower(d.format), char(31))
                               FROM data d WHERE d.book=b.id), ''),
                   COALESCE((SELECT group_concat(i.type || ':' || i.val, char(31))
                               FROM identifiers i WHERE i.book=b.id), ''),
                   COALESCE(b.uuid, '')
              FROM books b
             ORDER BY b.id
        """).fetchall()
    finally:
        conn.close()
    return [{
        "id": int(book_id),
        "title": title or "",
        "author": author or "",
        "filenames": [name for name in (filenames or "").split(chr(31)) if name],
        "identifiers": normalized_identifiers(identifiers) | normalized_identifiers({"uuid": book_uuid}),
    } for book_id, title, author, filenames, identifiers, book_uuid in rows]

def crosspoint_document_metadata():
    if not os.path.isfile(CROSSPOINT_DB):
        return {}
    try:
        conn = sqlite3.connect(f"file:{CROSSPOINT_DB}?mode=ro", uri=True, timeout=3)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute("""
                SELECT d.document, d.title, d.author, d.filename
                  FROM documents d JOIN users u ON u.id=d.user_id
                 WHERE u.username=?
            """, (USERNAME,)).fetchall()
        finally:
            conn.close()
        return {row["document"].lower(): dict(row) for row in rows}
    except sqlite3.Error as e:
        log(f"WARNING could not read device title metadata: {type(e).__name__}")
        return {}

def automatic_book_match(title, author, identities, filename="", identifiers=None):
    """Return a ranked suggestion only when identity evidence is meaningful."""
    wanted_identifiers = normalized_identifiers(identifiers)
    if wanted_identifiers:
        identifier_matches = [book for book in identities
                              if wanted_identifiers & set(book.get("identifiers", []))]
        if len(identifier_matches) == 1:
            return {"book_id": identifier_matches[0]["id"], "confidence": 1.0,
                    "reason": "Exact embedded book identifier"}
    query_values = []
    for value in (title, filename):
        value = str(value or "").strip()
        if not value:
            continue
        stem = os.path.splitext(os.path.basename(value))[0]
        variants = [stem]
        if value == filename:
            variants.extend(re.split(r"\s+(?:[-–—|]+)\s+", stem))
        for variant in variants:
            normalized = normalized_title(variant)
            if len(normalized) >= 4 and normalized not in query_values:
                query_values.append(normalized)
    if not query_values:
        return None

    wanted_author = normalized_author(author)
    ranked = []
    for book in identities:
        candidate_title = normalized_title(book["title"])
        candidate_names = {normalized_title(name) for name in book.get("filenames", [])}
        title_score = max((difflib.SequenceMatcher(None, wanted, candidate_title).ratio()
                           for wanted in query_values), default=0.0)
        filename_score = max((1.0 if wanted in candidate_names else
                              difflib.SequenceMatcher(None, wanted, name).ratio()
                              for wanted in query_values for name in candidate_names), default=0.0)
        score = max(title_score, filename_score)
        author_score = 0.0
        if wanted_author:
            author_score = difflib.SequenceMatcher(
                None, wanted_author, normalized_author(book["author"])
            ).ratio()
            score = score * 0.82 + author_score * 0.18
        ranked.append((score, author_score, book))
    if not ranked:
        return None
    ranked.sort(key=lambda row: (row[0], row[1], -row[2]["id"]), reverse=True)
    best_score, _, best = ranked[0]
    margin = best_score - (ranked[1][0] if len(ranked) > 1 else 0.0)
    exact_title = normalized_title(best["title"]) in query_values
    exact_filename = bool({normalized_title(name) for name in best.get("filenames", [])} & set(query_values))
    reason = "Exact Calibre filename" if exact_filename else "Exact title" if exact_title else "Best title and author similarity"
    confidence = max(0.0, min(1.0, best_score))
    if margin < 0.035:
        confidence = min(confidence, 0.62)
        reason = "Ambiguous between similar Calibre titles"
    if confidence < 0.60:
        return None
    return {"book_id": best["id"], "confidence": round(confidence, 4), "reason": reason}

def redis_book_metadata(key):
    fields = {name: redis("HGET", key, name) for name in ("metadata", "title", "author", "authors", "filename")}
    meta = {}
    if fields.get("metadata"):
        try:
            value = json.loads(fields["metadata"])
            if isinstance(value, dict):
                meta.update(value)
        except (ValueError, TypeError):
            pass
    for key_name in ("title", "author", "authors", "filename"):
        if fields.get(key_name) and key_name not in meta:
            meta[key_name] = fields[key_name]
    return meta

def set_custom(column, book_id, value):
    # calibredb list uses *label syntax for custom fields, but set_custom
    # expects the bare Calibre column label (for example, ko_progint).
    column_label = column[1:] if column.startswith("#") else column
    args = [
        CALIBREDB,
        "--with-library", SERVER,
        "--username", USERNAME,
        "--password", f"<f:{PASSFILE}>",
        "set_custom",
        column_label,
        str(book_id),
        str(value),
    ]

    p = cmd(args, check=False)
    if p.returncode != 0:
        detail = p.stderr.strip().replace("\n", " | ")[:300]
        log(
            f"ERROR custom field update failed: {column_label} book={book_id} "
            f"exit={p.returncode}: {detail}"
        )
        return False
    return True

def custom_value_matches(existing, desired, column):
    if existing is None or str(existing).strip().casefold() in {"", "none"}:
        return False
    label = column.lstrip("#*")
    if label in {"ko_progfloat"}:
        try:
            return abs(float(existing) - float(desired)) < 0.0000005
        except (TypeError, ValueError):
            return False
    if label == "ko_statusbool":
        old_bool = str(existing).strip().casefold() in {"1", "true", "yes"}
        new_bool = str(desired).strip().casefold() in {"1", "true", "yes"}
        return old_bool == new_bool
    if label in {"ko_lastsync", "ko_lastmod"}:
        current = str(existing).strip()
        try:
            parsed = datetime.fromisoformat(current.replace("Z", "+00:00"))
            current_date = parsed.astimezone().date().isoformat() if parsed.tzinfo else parsed.date().isoformat()
        except ValueError:
            current_date = current[:10]
        return current_date == str(desired).strip()[:10]
    return str(existing).strip().casefold() == str(desired).strip().casefold()

def set_custom_if_changed(column, book_id, value, book):
    """Avoid slow remote writes for Calibre fields that already match KOReader."""
    field = "*" + column.lstrip("#*")
    if custom_value_matches(book.get(field), value, column):
        return True, False
    if not set_custom(column, book_id, value):
        return False, False
    book[field] = value
    return True, True

def write_json_atomic(path, payload):
    fd, temp_path = tempfile.mkstemp(prefix=".kosync-calibre-", dir=STATE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)

def main():

    lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock_fd)
        return

    try:

        log("BRIDGE START")

        book_result = cmd([
            CALIBREDB,
            "--with-library", SERVER,
            "--username", USERNAME,
            "--password", f"<f:{PASSFILE}>",
            "--timeout=120",
            "list",
            "--for-machine",
            "--fields", "id,title,formats,*ko_md5,*ko_progfloat,*ko_progint,*ko_status,*ko_statusbool,*ko_loc,*ko_device_name,*ko_device_id,*ko_lastsync,*ko_lastmod",
        ], check=False)

        if book_result.returncode != 0:
            detail = book_result.stderr.strip().replace("\n", " | ")[:500]
            log(f"ERROR calibredb list failed (exit={book_result.returncode}): {detail}")
            return

        raw = book_result.stdout.strip()
        if not raw:
            log("ERROR calibredb list returned empty output; skipping this bridge pass")
            return

        try:
            decoder = json.JSONDecoder()
            books, end = decoder.raw_decode(raw)
        except json.JSONDecodeError as e:
            log(f"ERROR calibredb list returned invalid JSON at char {e.pos}; skipping this pass")
            return

        # The installed NoTrans plugin writes hook status to stdout after
        # calibredb's otherwise valid JSON response. Accept only those known
        # trailing diagnostics; unexpected text still fails closed.
        trailing = raw[end:].strip()
        if trailing:
            lines = [line.strip() for line in trailing.splitlines() if line.strip()]
            if not lines or not all(line.startswith("NoTrans:") for line in lines):
                log("ERROR unexpected text after calibredb JSON; skipping this pass")
                return
            log(f"INFO ignored {len(lines)} NoTrans hook diagnostic lines")

        if not isinstance(books, list):
            log("ERROR calibredb list returned unexpected JSON type; skipping this pass")
            return

        mapping = {}
        md5_count = 0
        local_paths = local_format_paths()
        identities = local_book_identities()
        remote_metadata = crosspoint_document_metadata()
        book_ids = {int(book.get("id")) for book in books if book.get("id") is not None}
        book_values = {int(book["id"]): book for book in books if book.get("id") is not None}

        try:
            with open(ALIASES, "r", encoding="utf-8") as aliases_file:
                aliases = json.load(aliases_file)
            if not isinstance(aliases, dict):
                aliases = {}
        except FileNotFoundError:
            aliases = {}
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
            aliases = {}
            log(f"WARNING could not load progress aliases: {type(e).__name__}: {e}")

        for book in books:

            book_id = book.get("id")

            existing = (
                book.get("ko_md5")
                or book.get("#ko_md5")
                or book.get("*ko_md5")
                or ""
            )

            if isinstance(existing, list):
                existing = existing[0] if existing else ""

            existing = str(existing).strip()

            formats = book.get("formats") or []

            if isinstance(formats, str):
                formats = [formats]

            available = {
                str(fmt).upper()
                for fmt in formats
                if isinstance(fmt, str)
            }
            candidates = [
                path for fmt, path in local_paths.get(book_id, [])
                if not available or fmt in available
            ]

            # Hash every local format so Calibre can match a device copy even
            # when the same title has EPUB/AZW3/PDF editions. The first format
            # remains the canonical ID used by the dashboard reader.
            candidate_digests = []
            for path in candidates:
                if not os.path.isfile(path):
                    continue
                try:
                    digest = partial_md5(path)
                    if digest not in candidate_digests:
                        candidate_digests.append(digest)
                except Exception:
                    continue

            if not candidate_digests:
                continue

            # Previous releases used a non-KOReader checksum. Preserve those
            # IDs as aliases before correcting the Calibre custom column.
            if (existing and existing not in candidate_digests
                    and len(existing) == 32
                    and all(c in "0123456789abcdefABCDEF" for c in existing)):
                aliases.setdefault(existing.lower(), {
                    "book_id": int(book_id),
                    "reason": "Preserved previous Calibre sync identifier",
                })
                mapping[existing.lower()] = book_id

            canonical = candidate_digests[0]
            if existing.lower() != canonical.lower():
                if set_custom_if_changed("#ko_md5", book_id, canonical, book_values[book_id])[0]:
                    md5_count += 1

            for digest in candidate_digests:
                mapping[digest.lower()] = book_id

        # Additional device file hashes can identify another edition of a
        # Calibre title. Validate and preserve the map on every bridge pass.
        valid_aliases = {}
        saved_suggestions = {}
        for digest, value in aliases.items():
            if not isinstance(digest, str) or len(digest) != 32 or any(c not in "0123456789abcdef" for c in digest.lower()):
                continue
            try:
                alias_book_id = int(value.get("book_id")) if isinstance(value, dict) else int(value)
            except (TypeError, ValueError):
                continue
            if alias_book_id in book_ids:
                if isinstance(value, dict) and value.get("automatic"):
                    try:
                        confidence = float(value.get("confidence", 0))
                    except (TypeError, ValueError):
                        confidence = 0
                    if confidence < 0.82:
                        saved_suggestions[digest.lower()] = value
                        continue
                valid_aliases[digest.lower()] = value
                mapping[digest.lower()] = alias_book_id
        aliases = valid_aliases
        write_json_atomic(ALIASES, aliases)

        # koreader-sync-server stores each document as a Redis hash at
        # user:<username>:document:<partial-md5>, not as separate keys with
        # field suffixes. Match the server's actual schema and read fields
        # with HGET.
        keys = cmd([
            DOCKER,
            "exec", CONTAINER,
            "redis-cli", "-n", "1",
            "--scan",
            "--pattern", f"user:{USERNAME}:document:*",
        ]).stdout.splitlines()

        found = 0
        latest_by_book = {}
        unmatched = []

        for key in keys:

            prefix = f"user:{USERNAME}:document:"
            if not key.startswith(prefix):
                continue

            if key == f"user:{USERNAME}:key":
                continue
            digest = key[len(prefix):]

            percentage = redis("HGET", key, "percentage")
            progress = redis("HGET", key, "progress")
            device = redis("HGET", key, "device")
            device_id = redis("HGET", key, "device_id")
            timestamp = redis("HGET", key, "timestamp")
            if not percentage:
                continue

            found += 1

            book_id = mapping.get(digest)
            old_suggestion = saved_suggestions.get(digest.lower())
            suggestion = None
            title = ""
            author = ""
            filename = ""

            if book_id is None:
                metadata = redis_book_metadata(key)
                stored = remote_metadata.get(digest.lower(), {})
                for field in ("title", "author", "authors", "filename", "identifiers", "identifier", "isbn", "uuid"):
                    if not metadata.get(field) and stored.get(field):
                        metadata[field] = stored[field]
                title = str(metadata.get("title") or (old_suggestion or {}).get("source_title") or "").strip()
                author = str(metadata.get("author") or metadata.get("authors") or (old_suggestion or {}).get("source_author") or "").strip()
                filename = str(metadata.get("filename") or stored.get("filename") or (old_suggestion or {}).get("source_filename") or "").strip()
                if old_suggestion:
                    suggestion = {"book_id": int(old_suggestion["book_id"]), "confidence": float(old_suggestion.get("confidence", 0))}
                if (title or metadata.get("filename") or metadata.get("identifiers")
                        or metadata.get("identifier") or metadata.get("isbn") or metadata.get("uuid")):
                    candidate = automatic_book_match(
                        title, author, identities, metadata.get("filename"),
                        metadata.get("identifiers") or metadata.get("identifier") or
                        ({"isbn": metadata.get("isbn")} if metadata.get("isbn") else
                         {"uuid": metadata.get("uuid")} if metadata.get("uuid") else None),
                    )
                    candidate_id = candidate.get("book_id") if candidate and candidate.get("confidence", 0) >= 0.82 else None
                    if candidate_id in book_ids:
                        book_id = candidate_id
                        mapping[digest.lower()] = candidate_id
                        aliases[digest.lower()] = {
                            "book_id": candidate_id,
                            "reason": candidate["reason"],
                            "confidence": candidate["confidence"],
                            "automatic": True,
                            "source_title": title,
                            "source_author": author,
                            "source_filename": str(metadata.get("filename") or ""),
                        }
                        log(f"AUTO-MATCHED confidence={candidate['confidence']:.2f} md5={digest} book={candidate_id} title={title[:100]}")
                    elif candidate and candidate.get("book_id") in book_ids:
                        suggestion = candidate
                        log(f"MATCH-SUGGESTED confidence={candidate['confidence']:.2f} md5={digest} book={candidate['book_id']} title={title[:100]}")

            if book_id is None:
                log(f"UNMATCHED md5={digest} percent={percentage} device={device}")
                try:
                    item = {
                        "document": digest,
                        "percentage": max(0.0, min(1.0, float(percentage))),
                        "device": device or "Unknown device",
                        "timestamp": int(timestamp or 0),
                    }
                    if title:
                        item["title"] = title
                    if author:
                        item["author"] = author
                    if filename:
                        item["filename"] = os.path.basename(filename)
                    if suggestion:
                        item["suggestedBookId"] = suggestion["book_id"]
                        item["suggestedConfidence"] = suggestion["confidence"]
                    unmatched.append(item)
                except (TypeError, ValueError):
                    pass
                continue

            try:
                pct = float(percentage)
                sort_timestamp = int(timestamp or 0)
            except (TypeError, ValueError):
                log(f"WARNING invalid progress fields md5={digest}; skipped")
                continue

            current = latest_by_book.get(book_id)
            if current is None or sort_timestamp >= current[0]:
                latest_by_book[book_id] = (
                    sort_timestamp, digest, percentage, progress, device, device_id, pct
                )

        changed_books = 0
        unchanged_books = 0
        for book_id, (sort_timestamp, digest, percentage, progress, device, device_id, pct) in latest_by_book.items():

            pct100 = max(0, min(100, round(pct * 100)))

            # Treat the last few percent as complete: different readers count
            # end matter and pages differently, and some stop at 97–99%.
            status = "Finished" if pct >= 0.97 else "Reading"
            finished = "true" if pct >= 0.97 else "false"

            update_ok = True
            fields_changed = 0
            for column, value in [
                ("#ko_progfloat", percentage),
                ("#ko_progint", str(pct100)),
                ("#ko_status", status),
                ("#ko_statusbool", finished),
            ]:
                success, changed = set_custom_if_changed(column, book_id, value, book_values[book_id])
                update_ok = success and update_ok
                fields_changed += int(changed)

            if progress:
                success, changed = set_custom_if_changed("#ko_loc", book_id, progress, book_values[book_id])
                update_ok = success and update_ok
                fields_changed += int(changed)

            if device:
                success, changed = set_custom_if_changed("#ko_device_name", book_id, device, book_values[book_id])
                update_ok = success and update_ok
                fields_changed += int(changed)

            if device_id:
                success, changed = set_custom_if_changed("#ko_device_id", book_id, device_id, book_values[book_id])
                update_ok = success and update_ok
                fields_changed += int(changed)

            if sort_timestamp:
                try:
                    dt = datetime.fromtimestamp(sort_timestamp)
                    datestr = dt.strftime("%Y-%m-%d")
                except Exception:
                    datestr = datetime.now().strftime("%Y-%m-%d")
            else:
                datestr = datetime.now().strftime("%Y-%m-%d")

            success, changed = set_custom_if_changed("#ko_lastsync", book_id, datestr, book_values[book_id])
            update_ok = success and update_ok
            fields_changed += int(changed)
            success, changed = set_custom_if_changed("#ko_lastmod", book_id, datestr, book_values[book_id])
            update_ok = success and update_ok
            fields_changed += int(changed)

            if update_ok:
                if fields_changed:
                    changed_books += 1
                    log(f"SYNCED book={book_id} fields_updated={fields_changed} percentage={percentage} device={device}")
                else:
                    unchanged_books += 1
            else:
                log(f"ERROR partial progress sync book={book_id} md5={digest}")

        review = []
        identity_by_id = {book["id"]: book for book in identities}
        for digest, value in aliases.items():
            if not isinstance(value, dict) or not value.get("automatic"):
                continue
            try:
                confidence = float(value.get("confidence", 1.0))
                book_id = int(value.get("book_id"))
            except (TypeError, ValueError):
                continue
            if confidence >= 0.82 or book_id not in identity_by_id:
                continue
            candidate = identity_by_id[book_id]
            review.append({
                "document": digest,
                "bookId": book_id,
                "bookTitle": candidate["title"],
                "bookAuthor": candidate["author"],
                "confidence": confidence,
                "sourceTitle": value.get("source_title", ""),
                "sourceAuthor": value.get("source_author", ""),
                "sourceFilename": os.path.basename(str(value.get("source_filename", ""))),
            })
        write_json_atomic(UNMATCHED, {"generatedAt": int(time.time()), "items": unmatched, "review": review})

        log(
            f"BRIDGE END books={len(books)} "
            f"md5_created={md5_count} "
            f"documents={found} matched={len(latest_by_book)} "
            f"updated={changed_books} unchanged={unchanged_books}"
        )

    except Exception as e:

        log(f"ERROR {type(e).__name__}: {e}")
        raise

    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)

if __name__ == "__main__":
    main()
