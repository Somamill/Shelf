# Highlights, review, and exports

Shelf stores annotations in an owner-only SQLite database at
`~/Library/Application Support/Shelf/annotations.sqlite`. No account is required.
Existing reader highlights migrate automatically, once; the original preferences
are retained. New annotations use the SQLite library as their source of truth.

## Highlights

Select a passage in the EPUB reader and choose **Highlight**, or open **Highlights**
and choose **Add passage**. Search passages, book titles, authors, notes, or tags.
Filter by source, book, tag, favorites, or annotations with notes. Settings controls
sorting, list/card view, and the default color.

**Notes & tags** edits personal notes, comma-separated tags, color, a linked local
book, and review frequency. Source text remains unchanged. **Archive** hides a
passage locally; it never deletes a source annotation or a remote highlight.
Re-importing the same provider identity preserves its archive and personal note.
Provider changes appear under **Source changes to review**, where you can keep
Shelf's version or explicitly accept the source passage and note.

**Open in book** uses text offsets plus surrounding context. It refuses to guess
when the same quote occurs more than once without a reliable position. Imported
annotations must be linked to a local book to use this action. Exported
`shelf://highlight/<id>` links use the same local annotation library; they are not
public web links. Restoring a backup preserves these IDs on another Mac.

Save the current filters as a collection. Collections can be pinned, unpinned,
removed, and selected as a daily-review source. Removing a collection does not
remove its highlights.

## Import and restore

**Import** supports:

- Shelf/generic JSON lists with `text`, `title`, `author`, `note`, `tags`, `source`,
  and optional `sourceId`, `bookId`, and `location` fields.
- KOReader JSON exports with `entries`, or entries grouped under book titles.
- Kindle `My Clippings.txt` highlight blocks in English, German, or Japanese.
- CSV files with a `text` column; title, author, note, tags, and source are optional.
- Apple Books annotations from the supported local `ZAEANNOTATION` schema.

Choose a file and inspect the preview before applying it. A preview shows up to
100 records; the import applies the entire file, up to 20 MB. You can optionally
link all imported passages to one selected local book. JSON/CSV imports are
annotation imports, not ebook-file imports. Unsupported KOReader/Kindle export
variants need conversion into the documented JSON/CSV shape; Lua sidecar files
are never executed.

Apple Books access is read-only and schema-dependent. Books must have synced to
this Mac, and macOS may require permission. Deleted annotations are skipped.
Apple Books PDF markings may not be available. This adapter is covered by a
fixture test; actual Mac access must be validated on the user's machine.

**Settings → Privacy & storage → Back up annotations** saves a portable JSON file
containing all highlights (including archives), settings, and collections.
**Preview backup restore** merges without deleting current records or overwriting
existing personal edits. Imports and restores roll back if validation fails.
Backups also include Studio captures, local chat history, preferences, and confirmed Notion receipts. Credentials, pending upload jobs, original audio/images, tool paths, and local folder grants are excluded. See [Studio](STUDIO.md).

## Review

Review resurfaces your own highlights, including short passages and Japanese text.
It has no streak, score, recommendation, or minimum English-word requirement.
Use Tomorrow, Next week, or In a month to schedule a passage again. Skipping does
not mark it reviewed. Enter schedules the next week; the right arrow skips.

Settings controls session size (1–50), days of the week, a source collection,
excluded tags/books, and a local reminder time. Each highlight has a frequency
weight; zero excludes it. Snooze suppresses reviews for 24 hours. Reminders are
in-app notices while Shelf is open on the dashboard, not system notifications or
an always-running background agent.

## Export

Export the current filtered view, or clear filters to export the visible library.
Markdown and CSV support personal notes, tags, and source/location options; JSON
is also available. Markdown templates accept literal `{title}`, `{author}`,
`{date}`, and `{highlights}` fields. Templates cannot execute code.

Markdown can be opened in Obsidian, Logseq, or any text editor. This is a portable
file export, not a direct account integration with those apps. The standard
macOS save dialog lets you choose each export's name and location.

Choose an export folder to enable automatic snapshots while Shelf is open.
The filename pattern applies to these snapshots. Shelf creates content-addressed,
Shelf-prefixed files when the output changes and does not overwrite existing
notes. Moving the folder or losing access requires selecting it again. No process
is expected to survive app termination or an environment snapshot.

## Connections and pending uploads

New highlights remain local unless destinations are enabled in Settings. Existing
highlights can be queued individually with **Queue export**. Destinations are:

- **Readwise Highlights**: sends passages, personal notes, and book metadata through
  the Highlights API.
- **Readwise Reader**: sends passages, notes, and tags to a matching Reader EPUB.
  Shelf can separately import Reader highlights and reading progress; both import
  types have toggles. Progress requires a configured KOReader/CrossPoint endpoint;
  highlight imports do not.
- **CrossPoint annotations**: sends passages and their locations using a device
  file fingerprint and the existing sync credentials.

The Readwise destinations share the token configured in Connections. Choose
Sync now or enable automatic uploads while Shelf is open. Each destination can
be paused. Queued jobs persist across restarts; each pass processes at most five.
Connection summaries show pending counts, attention counts, and successful uploads.
Other providers managed by CrossPoint remain configured in CrossPoint itself.

Rate limiting uses backoff. Unconfirmed uploads, including lost responses, stop
in an **uncertain** state. Check the destination before explicitly retrying: the
first upload might have succeeded. Completed uploads are not silently sent again.
Archiving cancels unsent jobs, but cannot undo a request already in flight.
Disconnecting removes the local token and stops credential-dependent uploads;
it retains local annotations. Edits to personal notes/tags do not automatically
rewrite previously published remote highlights.

Tokens are supplied only to the active sync subprocess and are never persisted
in the annotation database or exported backup. No ebook file is uploaded by the
annotation queue. Live provider behavior still requires validation with the
user's accounts; the automated tests use controlled service responses.

## Reading settings

Choose whether to remember appearance per book, restore the last position, and
open ordinary books in Shelf or the default macOS reader. Opening a specific
highlight always uses Shelf. Font, size, theme, and spacing remain available in
the reader's Appearance popover. Opening with the system reader locates the source
file without converting it first.

## Development checks

```sh
python3 -m unittest discover -s Tests/Python -v
node --check Resources/Dashboard/app.js
```

With Playwright and system Chromium installed, run:

```sh
python3 Tests/Dashboard/test_annotations_ui.py
```

The browser test exercises real SQLite operations through a simulated native
message bridge and verifies the actual embedded reader anchor code. It does not
replace an AppKit/WebKit build or Mac testing of permissions, deep links, file
panels, scheduled exports, and live service integrations. The existing macOS CI
build includes the new Python resource and URL scheme metadata.
