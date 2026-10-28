#!/usr/bin/env python3
"""Return the local file path for a Calibre book's first available format."""
import json, sqlite3, sys
from pathlib import Path
from shelf_config import configured_path
root = configured_path('library', str(Path.home() / 'Books' / 'Calibre Library'))
book_id = int(sys.argv[1]) if len(sys.argv) > 1 else 0
db = root / 'metadata.db'
try:
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=5)
    row = con.execute('SELECT b.path,d.name,d.format FROM books b JOIN data d ON d.book=b.id WHERE b.id=? ORDER BY CASE lower(d.format) WHEN "epub" THEN 0 WHEN "pdf" THEN 1 ELSE 2 END LIMIT 1', (book_id,)).fetchone()
    con.close()
    if not row: raise RuntimeError('This library entry has no local book file.')
    folder, name, fmt = row
    path = root / folder / f'{name}.{fmt.lower()}'
    if not path.is_file(): raise RuntimeError('The local book file is missing from the library.')
    print(json.dumps({'path': str(path), 'format': fmt.lower()}))
except Exception as error:
    print(json.dumps({'error': str(error)}))
    raise SystemExit(1)
