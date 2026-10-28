# Dependencies

## Install Shelf

- macOS 14 or later.
- No Xcode, Command Line Tools, Python, or Homebrew installation is required. Shelf’s DMG includes a universal CPython runtime for its local helpers.

## Build Shelf from source

- Xcode 16 or later / macOS Command Line Tools with Swift, AppKit, WebKit, Foundation, Security, and CryptoKit.
- Python 3.13 is downloaded and checksum-verified by `Scripts/download-python-runtime.sh` for universal local builds.
- Node.js only for the optional JavaScript syntax check.

The embedded Python runtime is CPython from Astral’s python-build-standalone release; its upstream licenses remain in the app bundle under `Resources/PythonRuntime`. There are no third-party Swift packages in the current app. `ShelfCore` uses Foundation only and declares iOS 17 compatibility for future reuse.

## Optional integrations

- Calibre and its command-line tools for the library, reader conversion, and OPDS services.
- KOReader Sync or CrossPoint Sync for progress/highlight synchronization.
- The official OneDrive or Google Drive desktop client when using those synced folders on macOS.
- Docker, Homebrew, Android Debug Bridge, Restic, EPUBCheck, and ClamAV only when the matching optional jobs are configured.

These integrations are configured per Mac. Shelf does not bundle their binaries or credentials.
