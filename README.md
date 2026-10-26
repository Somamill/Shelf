# Shelf

**Current release: 0.1.11** — an early macOS release. See [GitHub Releases](https://github.com/Somamill/Shelf/releases) for downloads and notes.

Shelf is a native macOS reading dashboard for a Calibre library. It includes a searchable Calibre bookshelf with cover-grid and compact-list views, a paginated EPUB reader, reading-progress and highlight sync, setup wizard, service health, and optional device configuration. The setup model is shared in `ShelfCore` so an iPhone companion can be added later.

## macOS setup

1. Install Xcode or the Xcode Command Line Tools, plus Python 3.
2. Open `Shelf.xcodeproj` in Xcode, or run `Scripts/build-and-install.sh` to build and install `Shelf.app`.
3. Complete the Setup screen. Choose a local Calibre library, an EPUB import folder, devices, and available sync servers.
4. If using OneDrive or Google Drive, install the provider's official macOS sync app and choose its local folder as the import destination. Shelf does not ask for or store cloud-provider passwords.

The project has no third-party Swift package dependencies. `project.yml` is the XcodeGen source spec; install XcodeGen only if you need to regenerate the checked-in Xcode project after changing that spec. See [Dependencies](Documentation/DEPENDENCIES.md) and [Architecture](Documentation/ARCHITECTURE.md).

## Cloud and Calibre library safety

The selected cloud folder is for EPUB intake and other user-managed files. Keep Calibre's active library and `metadata.db` on local storage. Calibre warns against running file sync while its library is open and says Google Drive is incompatible with a live Calibre library. Use the Calibre Content Server for access from other devices. [Calibre FAQ](https://manual.calibre-ebook.com/faq.html)

The macOS app uses the system folder picker and persists its folder choices in a private per-user configuration. Passwords and sync keys entered in Setup are stored in macOS Keychain. No OAuth credentials for Google or Microsoft are requested.

## Current and planned support

- **Available now:** macOS setup, Calibre bookshelf/reader, local folder import, KOReader Sync/CrossPoint endpoints, Hardcover and Readwise connector status, and optional Mac service controls.
- **Readwise Reader:** pull progress and highlights into matching local EPUBs and connected KOReader sync. Highlights from Shelf can be sent to a matching Readwise Reader EPUB.
- **Future:** a native iPhone target using the shared `ShelfCore` models and iOS Files document picker for iCloud Drive and third-party File Provider locations.
- **Not included yet:** direct Google Drive or Microsoft Graph OAuth/API sync. Current OneDrive/Google Drive support uses files made available by their official desktop sync clients.

## Optional local integrations

Backup, import, audit, and safety actions can call scripts in the configured scripts directory. Those are optional adapters and are not required for the built-in reader or progress mapping. Docker, Homebrew, Android Debug Bridge, Restic, EPUBCheck, and ClamAV are needed only when their corresponding integrations are enabled.

## Security and support

Review the private configuration and diagnostic ZIP before sharing them. Do not commit API keys, passwords, library data, or exported logs. See [Security](SECURITY.md), [Contributing](CONTRIBUTING.md), and [Architecture](Documentation/ARCHITECTURE.md).
