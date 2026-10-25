#!/usr/bin/env python3
"""Prepare one local Calibre book for the dashboard's built-in reader."""

import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from shelf_config import configured_path, configuration_section

BOOKS_ROOT = configured_path('booksRoot', '~/Books')
LIBRARY = configured_path('library', str(BOOKS_ROOT / 'Calibre Library')).resolve()
DB = LIBRARY / 'metadata.db'
TOOLS = configuration_section('tools')
CONVERTER = Path(TOOLS.get('calibreApp') or shutil.which('ebook-convert') or '/Applications/calibre.app/Contents/MacOS/ebook-convert').expanduser()
STATE = configured_path('state', str(BOOKS_ROOT / 'state'))
WORK_ROOT = STATE / 'dashboard-reader'
ALIASES = STATE / 'kosync-calibre-aliases.json'


def partial_md5(path: Path) -> str:
    digest = hashlib.md5()
    # Match KOReader exactly: one sample at byte 0, followed by exponentially
    # spaced 1 KiB samples. A 256-byte leading sample produces an incompatible
    # document ID and prevents cross-device progress sync.
    for offset in [0] + [1024 * (4 ** i) for i in range(11)]:
        with path.open('rb') as source:
            source.seek(offset)
            chunk = source.read(1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        raise ValueError('Choose a book from your Calibre library.')
    book_id = int(sys.argv[1])
    if not DB.is_file() or not CONVERTER.is_file():
        raise FileNotFoundError('Calibre or its library is unavailable.')

    conn = sqlite3.connect(f'file:{DB}?mode=ro', uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        book = conn.execute('''
            SELECT b.id,b.title,b.path,
              (SELECT group_concat(a.name, ' · ') FROM books_authors_link l
                JOIN authors a ON a.id=l.author WHERE l.book=b.id) AS authors,
              (SELECT group_concat(lang.lang_code, ',') FROM books_languages_link bl
                JOIN languages lang ON lang.id=bl.lang_code WHERE bl.book=b.id) AS language
            FROM books b WHERE b.id=?
        ''', (book_id,)).fetchone()
        formats = conn.execute(
            'SELECT name,format FROM data WHERE book=? ORDER BY upper(format)',
            (book_id,),
        ).fetchall()
    finally:
        conn.close()
    if not book or not formats:
        raise ValueError('That book or its ebook file is no longer in Calibre.')

    source = None
    for row in formats:
        candidate = (LIBRARY / book['path'] / f"{row['name']}.{row['format'].lower()}").resolve()
        if candidate.is_file() and candidate.is_relative_to(LIBRARY):
            source = candidate
            break
    if source is None:
        raise FileNotFoundError('No readable ebook file was found for this book.')

    # Convert a copy into a private, temporary web view. The Calibre file stays untouched.
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    WORK = Path(tempfile.mkdtemp(prefix=f'book-{book_id}-', dir=WORK_ROOT))
    archive = WORK / 'book.htmlz'
    result = subprocess.run(
        [str(CONVERTER), str(source), str(archive)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
    )
    if result.returncode != 0 or not archive.is_file():
        detail = (result.stderr or result.stdout).strip().splitlines()[-1:]
        raise RuntimeError('Calibre could not prepare this book for reading.' + (f' {detail[0][:180]}' if detail else ''))

    extracted = WORK / 'content'
    extracted.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            target = (extracted / entry.filename).resolve()
            if not target.is_relative_to(extracted.resolve()):
                raise ValueError('The converted book contains an unsafe path.')
            bundle.extract(entry, extracted)
    archive.unlink(missing_ok=True)
    html = next((path for path in (extracted / 'index.html', extracted / 'index.xhtml') if path.is_file()), None)
    if html is None:
        html = next(iter(sorted(extracted.glob('*.html'))), None)
    if html is None:
        raise RuntimeError('Calibre produced no readable HTML for this book.')

    primary_document = partial_md5(source)
    sync_documents = [primary_document]
    try:
        stored_aliases = json.loads(ALIASES.read_text(encoding='utf-8'))
        if isinstance(stored_aliases, dict):
            for digest, value in stored_aliases.items():
                try:
                    alias_book_id = int(value.get('book_id')) if isinstance(value, dict) else int(value)
                except (TypeError, ValueError):
                    continue
                if (alias_book_id == book_id and isinstance(digest, str)
                        and len(digest) == 32 and all(c in '0123456789abcdefABCDEF' for c in digest)):
                    if digest.lower() not in sync_documents:
                        sync_documents.append(digest.lower())
    except (OSError, ValueError, TypeError):
        pass

    print(json.dumps({
        'bookId': book_id,
        'title': book['title'],
        'authors': book['authors'] or 'Unknown author',
        'language': book['language'] or '',
        'filename': source.name,
        'document': primary_document,
        'syncDocuments': sync_documents,
        'htmlPath': str(html),
        'workDir': str(WORK),
    }, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
        raise SystemExit(1)
