# Shelf

**A calm, unified reading dashboard for macOS.** Shelf brings your Calibre library, reading progress, connected services, and supported devices into one place while keeping your book files under your control.

<p align="center">
  <img src="Resources/Icons/AppIcon.png" width="96" alt="Shelf app icon">
</p>

> Current version: **0.2.1** · macOS · MIT licensed

## What Shelf does

- **One shelf across sources.** Browse Calibre titles and formats alongside reading records from Apple Books, Hardcover, and connected readers. Matching uses title and author evidence so different editions can share one shelf entry.
- **Covers and metadata.** Loads embedded Calibre covers, then checks high-confidence Open Library results for missing artwork and saves successful matches back into Calibre. If no reliable cover is available, Shelf shows a readable title card instead of an empty image box. A read-only library health summary points out missing covers, authors, formats, and likely duplicate records.
- **Read and track.** Open EPUBs in the built-in paginated reader, keep progress and highlights, and view finish status and reading statistics.
- **Highlights and review.** Search passages across sources, edit notes and tags, save collections, review highlights, and export Markdown/CSV/JSON. Imports, annotation backups, and an optional upload queue keep the workflow local until you enable a destination. See [Highlights guide](Documentation/HIGHLIGHTS.md).
- **Reading Studio.** Recognize text from images/PDFs locally, transcribe downloaded audio, ask cited questions of your highlights, and export snapshots directly to Notion. External uploads require explicit action. See [Studio setup and limits](Documentation/STUDIO.md).
- **Sync services.** Check Calibre, KOReader Sync, CrossPoint, Hardcover, Readwise, and Readwise Reader connections from the dashboard.
- **Device setup.** Configure supported KOReader/CrossPoint readers and see when a reader last sent progress. A disconnected reader can only upload after it reconnects to Wi-Fi.
- **A focused interface.** Choose Black (OLED black) or Bright. Motion follows macOS reduced-motion settings and uses native WebKit timing at the display’s supported refresh rate.

### Shelf in action

These showcase images use illustrative sample books and connection states. They do not contain a personal library, account details, or local network addresses.

| Bookshelf and EPUB import | Connected reading services | Reading statistics |
| --- | --- | --- |
| ![Shelf bookshelf and EPUB import](Documentation/Screenshots/library.png) | ![Shelf service connections](Documentation/Screenshots/connections.png) | ![Shelf reading statistics](Documentation/Screenshots/reading-statistics.png) |

## Install and build

### Install a release

Download the latest [Shelf DMG](https://github.com/Somamill/Shelf/releases/latest) and drag Shelf into Applications. Releases are self-contained and do not require Xcode, Command Line Tools, or a separate Python installation. Until Apple Developer signing is available, the DMG is an unsigned community build. If macOS blocks its first launch, open Shelf once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. This approves Shelf while leaving Gatekeeper enabled. See [Apple's instructions](https://support.apple.com/en-nz/102445) and check the release's SHA-256 checksum before installing. Homebrew users can install it with:

```sh
brew tap somamill/shelf https://github.com/Somamill/Shelf.git
brew trust --cask somamill/shelf/shelf
brew install --cask somamill/shelf/shelf
```

The first launch checks common Calibre library locations and prepares an incoming-books folder. If your library is elsewhere, choose its folder once; optional sync services can be connected later.

### Automatic updates

Updater-enabled releases can check, download, and install signed updates from inside Shelf. Enable the options under Updates after the one-time bootstrap installation. Developers configure update signing once; see [Automatic updates](Documentation/AUTOMATIC-UPDATES.md).

### Build from source

Requirements: macOS 14 or later, Xcode, Python 3, and a local Calibre library.

```sh
git clone https://github.com/Somamill/Shelf.git
cd Shelf
Scripts/build-and-install.sh
```

To package a locally built app for testing, run `Scripts/package-dmg.sh /Applications/Shelf.app`. See [release setup](Documentation/RELEASING.md) for the signed and unsigned release paths.

## Set up your reading sources

1. Choose a local Calibre library and a folder for incoming books.
2. Add the services and devices you use under **Connections** and **Setup**.
3. Keep Calibre’s active library on local storage. Use iCloud Drive, OneDrive, or Google Drive only for incoming files that their official sync app downloads to this Mac. Do not sync Calibre’s live database folder through a cloud drive.
4. On CrossPoint/KOReader devices, enable document metadata and sync when the reader is back online. Shelf processes a reader upload automatically; it cannot make a disconnected device upload over Wi-Fi.

Apple Books support reads the locally synced Books database on this Mac and reports available progress. Protected Apple Books files stay in Books; Shelf does not copy or alter them. Catalog metadata import is separate from importing book files.

## Privacy and data safety

- Shelf reads Calibre metadata and cover files locally. User passwords and API keys are kept in owner-only files under `~/Library/Application Support/Shelf`.
- Apple Books data is read locally. The catalog importer creates metadata-only Calibre entries and does not copy protected book content.
- Shelf does not upload your library to a Shelf-operated cloud service. Connected services receive only the data needed for the enabled sync feature.
- Review diagnostic exports before sharing. Never commit credentials, private library databases, or personal logs.

## Project layout

```text
Sources/ShelfCore/       Shared models and core logic
Sources/ShelfMacApp/     Native macOS application and service adapters
Resources/Dashboard/     Shelf dashboard and reader interface
Resources/Icons/         App icon and macOS icon set
Scripts/                 Build and optional maintenance helpers
Documentation/           Architecture, dependencies, and screenshots
```

See [Architecture](Documentation/ARCHITECTURE.md), [Dependencies](Documentation/DEPENDENCIES.md), [Security](SECURITY.md), [Contributing](CONTRIBUTING.md), and [Changelog](CHANGELOG.md).

## Scope

Shelf is currently a macOS app. The shared core is structured to support a future iPhone companion, but an iPhone app and direct Google Drive/Microsoft Graph integrations are not included in this release. Cloud-drive support means using files that the provider’s official macOS sync client has made available locally.

## License

Shelf is released under the [MIT License](LICENSE).
