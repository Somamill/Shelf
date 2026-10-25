# Changelog

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
