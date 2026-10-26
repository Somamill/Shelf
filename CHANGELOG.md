## 0.1.23

- Automatically hide old log errors after the same job records a successful recovery, and age out issues after seven days in diagnostic exports.
- Make Setup and Reader Setup controls follow the selected OLED, System, or Light theme consistently.

## 0.1.22

- Stop reporting historical 20-second Calibre bridge timeouts after the timeout fix is installed.

## 0.1.21

- Keep reader Follow Shelf colors in sync while the reader window remains open.

## 0.1.20

- Match Calibre's 120-second network timeout so slow progress updates do not fail at 20 seconds.
- Read existing sync metadata and write only fields that changed, reducing bridge time and repeated log noise.
- Make recently added book cards follow the dashboard's OLED and System palettes.
- Make the reader follow Shelf appearance by default, including true black in OLED mode, while retaining reader color choices.
- Sort the reader chapter menu by actual book document order instead of EPUB navigation-list order.

## 0.1.19

- Unify light appearance so navigation, cards, controls and book views share one balanced palette.
- Make OLED mode consistently black across all dashboard pages, cards, forms and controls.
- Make System appearance follow macOS changes immediately and safely handle unavailable local preferences.
- Remove conflicting legacy theme layers that caused light and dark surfaces to mix.

## 0.1.18

- Remove all runtime Keychain access from Shelf to prevent repeated Keychain dialogs.
- Store passwords and API tokens in owner-only local credential files with restricted file permissions.
- Keep scheduled jobs inside Operations so they no longer appear on the Books and other pages.

## 0.1.17

- Add a visible System / OLED black appearance picker so OLED mode works even if WKWebView misses the macOS appearance signal.
- Set the dashboard document color scheme to support both light and dark native controls.

## 0.1.16

- Combine reader setup with Setup and scheduled jobs with service operations.
- Add reading statistics for saved progress, reader sync activity and connected tracking APIs.
- Follow macOS appearance with an OLED-black Dark Mode and Liquid Glass controls.
- Keep service, book and provider data on automatic refresh; present sync and backup log entries in plain language.
- Hide old resolved issues from current diagnostics and keep each exported report based on fresh status and recent log tails.
- Restrict Shelf credential reads to non-interactive, non-synchronizable local Keychain items to stop repeated iCloud Keychain prompts.
- Keep book labels focused on title and author rather than internal file IDs or extensions.

## 0.1.15

- Keep Calibre covers visible in Finished and add a Recently added shelf.
- Show complete Calibre metadata in compact, expandable book details.
- Merge matching Hardcover records into the matching local book using title and author evidence.
- Stabilize local app signing and give Shelf credentials a persistent app access list to prevent repeat Keychain prompts.
- Add reduced-motion-friendly page and book transitions, refine the smaller book icon, and display activity times in the Mac’s local time zone.

## 0.1.14

- Treat 97% reading progress as finished in Calibre and Shelf, remove those books from Continue reading, and show them in Finished.
- Correct clean Japanese EPUB audit reports so zero-error summaries do not appear as Attention.
- Improve macOS window resizing and restore the current dock icon registration.
- Refresh the dashboard surfaces with a consistent, restrained glass treatment.

# Changelog

## 0.1.13

- Treat a zero-error EPUB audit summary as healthy instead of matching the word “errors” as a failure.
- Export only issues from the last seven days and choose the newest distinct issue instead of sorting messages alphabetically.

## 0.1.12

- Make background Keychain reads non-interactive with `LAContext` and cache successful lookups so periodic dashboard refreshes do not open repeated access dialogs. User-started sync actions can still request access when needed.
- Prefer a stable Apple signing identity during local installs, avoiding ad-hoc signatures when one is available.
- Warn when this Mac falls back to an ad-hoc signature, which can cause Keychain to ask again after app updates.

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
