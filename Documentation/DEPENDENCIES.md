# Dependencies

## App build

- Xcode 16 or later / macOS Command Line Tools with Swift, AppKit, WebKit, Foundation, Security, and CryptoKit.
- macOS 14 or later for the desktop app.
- Python 3 and the standard library for the included local book and progress helpers.
- Node.js only for the optional JavaScript syntax check.

There are no third-party Swift packages in the current app. `ShelfCore` uses Foundation only and declares iOS 17 compatibility for future reuse.

## Optional integrations

- Calibre and its command-line tools for the library, reader conversion, and OPDS services.
- KOReader Sync or CrossPoint Sync for progress/highlight synchronization.
- The official OneDrive or Google Drive desktop client when using those synced folders on macOS.
- Docker, Homebrew, Android Debug Bridge, Restic, EPUBCheck, and ClamAV only when the matching optional jobs are configured.

These integrations are configured per Mac. Shelf does not bundle their binaries or credentials.
