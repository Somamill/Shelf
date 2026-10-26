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
        custom_metadata = connection.execute(
            'SELECT id, label, name FROM custom_columns ORDER BY id'
        ).fetchall()
        custom_expressions = []
        for column in custom_metadata:
            column_id = int(column['id'])
            table = f'custom_column_{column_id}'
            if not connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
            ).fetchone():
                continue
            table_fields = {field['name'] for field in connection.execute(f'PRAGMA table_info({table})')}
            if 'book' in table_fields:
                expression = f'(SELECT cm.value FROM {table} cm WHERE cm.book=b.id)'
            else:
                link = f'books_custom_column_{column_id}_link'
                expression = (
                    f'(SELECT group_concat(cm.value, \' · \') FROM {link} ln '
                    f'JOIN {table} cm ON cm.id=ln.value WHERE ln.book=b.id)'
                )
            custom_expressions.append(f'{expression} AS custom_{column_id}')
        custom_select = ',\n'.join(custom_expressions)
        custom_prefix = f'{custom_select},\n                   ' if custom_select else ''
        rows = connection.execute('''
            SELECT b.id, b.title, b.sort AS title_sort, b.author_sort, b.uuid,
                   b.path, b.has_cover, b.timestamp, b.last_modified,
                   p.value AS progress,
                   done.value AS device_finished,
                   (SELECT group_concat(a.name, ' · ')
                      FROM books_authors_link l JOIN authors a ON a.id=l.author
                     WHERE l.book=b.id) AS authors,
                   (SELECT group_concat(s.name, ' · ')
                      FROM books_series_link l JOIN series s ON s.id=l.series
                     WHERE l.book=b.id) AS series,
                   (SELECT group_concat(t.name, ' · ')
                      FROM books_tags_link l JOIN tags t ON t.id=l.tag
                     WHERE l.book=b.id) AS tags,
                   (SELECT p.name FROM books_publishers_link l JOIN publishers p ON p.id=l.publisher WHERE l.book=b.id) AS publisher,
                   (SELECT group_concat(lang.lang_code, ', ')
                      FROM books_languages_link l JOIN languages lang ON lang.id=l.lang_code
                     WHERE l.book=b.id) AS languages,
                   (SELECT group_concat(i.type || ': ' || i.val, ' · ')
                      FROM identifiers i WHERE i.book=b.id) AS identifiers,
                   (SELECT group_concat(r.rating, ', ')
                      FROM books_ratings_link l JOIN ratings r ON r.id=l.rating
                     WHERE l.book=b.id) AS rating,
                   c.text AS comments, b.pubdate, b.series_index,
                   (SELECT group_concat(d.format, ',') FROM data d WHERE d.book=b.id) AS formats
              FROM books b
              LEFT JOIN custom_column_1 p ON p.book=b.id
              LEFT JOIN custom_column_4 done ON done.book=b.id
              LEFT JOIN comments c ON c.book=b.id
              ORDER BY datetime(b.timestamp) DESC, b.id DESC
        '''.replace('SELECT b.id,', f'SELECT {custom_prefix}b.id,', 1)).fetchall()
    finally:
        connection.close()

    books = []
    reading = []
    finished = []
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
            'publisher': row['publisher'] or '',
            'languages': row['languages'] or '',
            'identifiers': row['identifiers'] or '',
            'rating': row['rating'] or '',
            'description': row['comments'] or '',
            'published': row['pubdate'] or '',
            'seriesIndex': row['series_index'],
            'titleSort': row['title_sort'] or '',
            'authorSort': row['author_sort'] or '',
            'uuid': row['uuid'] or '',
            'libraryPath': row['path'] or '',
            'modified': row['last_modified'] or '',
            'customMetadata': [
                {'label': column['name'], 'value': str(row[f'custom_{int(column["id"])}'])}
                for column in custom_metadata
                if row[f'custom_{int(column["id"])}'] is not None
                and str(row[f'custom_{int(column["id"])}']).strip()
            ],
            'progress': progress,
            'formats': row['formats'] or '',
            'added': row['timestamp'] or '',
            'coverPath': str(cover) if cover and cover.is_file() else '',
        }
        books.append(book)
        # Device percentages may stop short of 100% because of end matter or
        # differing page counts. Shelf treats 97% as complete without changing
        # Calibre's saved progress value.
        marked_finished = str(row['device_finished'] or '').strip().lower() in {'1', 'true', 'yes'}
        if marked_finished or (progress is not None and progress >= 0.97):
            book['finished'] = True
            finished.append(book)
        elif progress is not None and progress > 0:
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
        'finished': sorted(finished, key=lambda b: b['progress'] or 0, reverse=True),
        'recent': books[:10],
        'allBooks': books,
        'unmatchedProgress': unmatched,
        'reviewProgressMatches': review_matches,
        'source': 'Calibre Library',
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
