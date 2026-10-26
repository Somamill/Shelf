# Changelog

## 0.1.11

- Fixes diagnostics export by creating its temporary report folder before writing files, then building the ZIP.
- Logs successful and failed export attempts locally and reports the count of included log and pasted-output issues accurately.


## 0.1.10

- Replaces the book mark with a larger, simpler open-book silhouette whose outer page wings lift upward from the spine.
- Regenerates every macOS icon size and updates the Shelf dashboard wordmark to use the same mark.


## 0.1.9

- Recognizes chapter links emitted by Calibre HTMLZ conversion, including EPUBs whose chapter markers are flattened into titled `div.main` elements rather than semantic headings.
- Extends Liquid Glass-inspired surfaces and controls consistently across dashboard pages, library, setup, service cards, overlays, and reader toolbar while keeping book text legible.
- Adds dark-mode, reduced-transparency, reduced-motion, and narrow-window treatments to the shared UI finish.


## 0.1.8

- Adds persistent cover-grid and compact-list library layouts, natural title/author sorting, progress sorting, and search across title, author, series, and tags.
- Extends automatic reader matching with exact embedded identifiers such as valid ISBN-10 and ISBN-13 values before title similarity; ambiguous matches remain unlinked.
- Refreshes navigation with consistent vector page icons, responsive glass surfaces, reduced-transparency and reduced-motion support, and system dark mode.
- Documents Readest’s metadata and file-content settings for reliable KOReader-to-Calibre matching.


## 0.1.7

- Adds a paste-ready Readwise access-token field on Connections, validates tokens against Readwise before saving them to Keychain, and links directly to the token page.
- Improves automatic book matching when author names are ordered differently across Calibre and reader metadata.
- Hides raw document IDs from unmatched-position cards; matching continues to use metadata and binary identity behind the scenes.
- Uses the documented Readwise authentication endpoint for secure token verification.

## 0.1.6

- Moves Readwise Reader key setup and sync controls to Connections, with a visible connection state and disconnect action.
- Retries Readest unmatched positions when it sends title metadata and avoids automatically linking weak or ambiguous title matches.
- Preserves old low-confidence matches as suggestions instead of silently treating them as confirmed links.
- Documents the Readest metadata setting that enables automatic matching for existing and future progress records.
- Adds automatic suggestions for close title and author matches.

## 0.1.5

- Adds a Readwise Reader sync action for matching EPUB progress and highlights with the local Calibre library and KOReader sync services.
- Makes reader highlights persist locally and preserves text selection when using the native reader toolbar.
- Shrinks diagnostic exports to deduplicated issue summaries and removes full log contents.
- Removes the retired dashboard device identifier from new progress records.

## 0.1.4

- Adds automatic BOOX rotation setup to the Android settings transfer, including a backup of the previous system auto-rotate value.
- Corrects the legacy KOReader settings-file location so existing endpoint values are updated in the file KOReader actually reads.
- Keeps the reader preparation helper compatible with the bundled macOS Python 3.9 runtime.

## 0.1.3

- Adds horizontal swipes between dashboard sections while preserving navigation controls and vertical scrolling.
- Opens the reader immediately while saved progress loads in the background; EPUB conversion is cached by file revision for faster repeat opens.
- Simplifies the reader header to an icon-only back control and retains chapter navigation in the lower reader controls.
- Automatically links each progress record to its strongest Calibre candidate when title or filename identity is available, and adds a review lane for lower-confidence suggestions.
- Ships the Japanese and multilingual EPUB chapter lookup and paginated column-count fixes from 0.1.2.


## 0.1.2

- Adds horizontal page turns by touch swipe and trackpad gestures while keeping keyboard and button navigation available.
- Improves EPUB table-of-contents extraction, chapter navigation, and paginated column counting to prevent extra blank pages.
- Expands automatic KOReader matching to exact Calibre file names as well as title metadata, while keeping ambiguous matches unresolved.
- Makes the signed-release workflow skip cleanly with a notice when Apple signing credentials are not configured.

## 0.1.1

- Reworks the reader controls into a floating, translucent navigation and action layer, with more room for the book page.
- Adds icons to reader actions and setup sections, and refines the setup layout with lighter spacing and responsive glass surfaces.
- Raises the outer page edges in the Shelf book mark so the open pages read as lifting upward from the spine.
- Keeps the reading canvas and text opaque and legible while reserving glass materials for controls and navigation.

## 0.1.0

- First public release of Shelf under the MIT License.
- Adds a native macOS dashboard for a local Calibre library, EPUB reading, progress, and highlights.
- Adds first-run setup for a Calibre library, import folder, cloud-synced intake folder, devices, and connected services.
- Adds per-user configuration and Keychain storage for credentials.
- Adds shared `ShelfCore` models to support a future iPhone client.
- Documents current limits: OneDrive and Google Drive use their macOS sync clients; direct provider OAuth and the iPhone app are not included yet.
