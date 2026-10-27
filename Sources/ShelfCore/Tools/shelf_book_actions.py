#!/usr/bin/env python3
"""Persist small Shelf-only book actions without changing Calibre metadata."""

import json
import os
import sys
import tempfile
from pathlib import Path

from shelf_config import configured_path


BOOKS_ROOT = configured_path('booksRoot', '~/Books')
STATE = configured_path('state', str(BOOKS_ROOT / 'state'))
OVERRIDES = STATE / 'shelf-finished-books.json'


def load_ids():
    try:
        data = json.loads(OVERRIDES.read_text(encoding='utf-8'))
        values = data.get('bookIds', []) if isinstance(data, dict) else []
        return {int(value) for value in values if str(value).isdigit()}
    except (OSError, ValueError, TypeError):
        return set()


def save_ids(book_ids):
    STATE.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE, 0o700)
    fd, temp_path = tempfile.mkstemp(prefix='.shelf-finished-', dir=STATE)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as target:
            json.dump({'bookIds': sorted(book_ids)}, target, indent=2)
            target.write('\n')
            target.flush()
            os.fsync(target.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, OVERRIDES)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def main():
    if len(sys.argv) != 3:
        raise ValueError('Expected a Calibre book ID and finished/reading action.')
    book_id = int(sys.argv[1])
    action = sys.argv[2]
    if book_id <= 0 or action not in {'finished', 'reading'}:
        raise ValueError('Invalid book action.')
    book_ids = load_ids()
    if action == 'finished':
        book_ids.add(book_id)
    else:
        book_ids.discard(book_id)
    save_ids(book_ids)
    print(json.dumps({'ok': True, 'bookId': book_id, 'finished': action == 'finished'}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        raise SystemExit(1)
