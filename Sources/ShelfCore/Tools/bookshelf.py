#!/usr/bin/env python3
"""Read the Calibre library's local reading-progress fields without writing to it."""

import json
import math
import sqlite3
from pathlib import Path

from shelf_config import configured_path

BOOKS_ROOT = configured_path('booksRoot', '~/Books')
LIBRARY = configured_path('library', str(BOOKS_ROOT / 'Calibre Library'))
DB = LIBRARY / 'metadata.db'
UNMATCHED_FILE = configured_path('state', str(BOOKS_ROOT / 'state')) / 'kosync-calibre-unmatched.json'


def main():
    if not DB.is_file():
        raise FileNotFoundError(f'Calibre metadata database not found: {DB}')
    connection = sqlite3.connect(f'file:{DB}?mode=ro', uri=True, timeout=5)
    connection.row_factory = sqlite3.Row
    try:
        total = connection.execute('SELECT count(*) FROM books').fetchone()[0]
        rows = connection.execute('''
            SELECT b.id, b.title, b.path, b.has_cover, b.timestamp,
                   p.value AS progress,
                   (SELECT group_concat(a.name, ' · ')
                      FROM books_authors_link l JOIN authors a ON a.id=l.author
                     WHERE l.book=b.id) AS authors,
                   (SELECT group_concat(s.name, ' · ')
                      FROM books_series_link l JOIN series s ON s.id=l.series
                     WHERE l.book=b.id) AS series,
                   (SELECT group_concat(t.name, ' · ')
                      FROM books_tags_link l JOIN tags t ON t.id=l.tag
                     WHERE l.book=b.id) AS tags,
                   (SELECT group_concat(d.format, ',') FROM data d WHERE d.book=b.id) AS formats
              FROM books b
              LEFT JOIN custom_column_1 p ON p.book=b.id
             ORDER BY datetime(b.timestamp) DESC, b.id DESC
        ''').fetchall()
    finally:
        connection.close()

    books = []
    reading = []
    for row in rows:
        raw = row['progress']
        try:
            progress = float(raw) if raw is not None else None
            if progress is not None and not math.isfinite(progress):
                progress = None
        except (TypeError, ValueError):
            progress = None
        if progress is not None and progress > 1:
            progress /= 100
        if progress is not None:
            progress = max(0.0, min(1.0, progress))

        cover = LIBRARY / row['path'] / 'cover.jpg' if row['has_cover'] else None
        book = {
            'id': row['id'],
            'title': row['title'],
            'authors': row['authors'] or 'Unknown author',
            'series': row['series'] or '',
            'tags': row['tags'] or '',
            'progress': progress,
            'formats': row['formats'] or '',
            'added': row['timestamp'] or '',
            'coverPath': str(cover) if cover and cover.is_file() else '',
        }
        books.append(book)
        if progress is not None and 0 < progress < 0.999:
            reading.append(book)

    try:
        with UNMATCHED_FILE.open('r', encoding='utf-8') as source:
            unmatched_data = json.load(source)
            unmatched = unmatched_data.get('items', [])
            review_matches = unmatched_data.get('review', [])
            if not isinstance(unmatched, list):
                unmatched = []
            if not isinstance(review_matches, list):
                review_matches = []
    except (OSError, ValueError, TypeError):
        unmatched = []
        review_matches = []

    print(json.dumps({
        'total': total,
        'reading': sorted(reading, key=lambda b: b['progress'] or 0, reverse=True),
        'recent': books[:10],
        'allBooks': books,
        'unmatchedProgress': unmatched,
        'reviewProgressMatches': review_matches,
        'source': 'Calibre Library',
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
