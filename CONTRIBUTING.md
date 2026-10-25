# Contributing

## Project layout

- `Sources/ShelfMacApp/` contains the macOS application and service adapters.
- `Sources/ShelfCore/ShelfCore/` contains Foundation-only profile and provider models shared with a future iOS target.
- `Sources/ShelfCore/Tools/` contains Python library, reader, settings, and progress helpers.
- `Resources/Dashboard/` contains the local HTML, CSS, and JavaScript interface.
- `Resources/Icons/` contains the app icon assets.
- `Config/` contains safe example settings. Per-machine settings live in `~/Library/Application Support/Shelf/config.json` and must not be committed.
- `Scripts/` contains build and asset-generation scripts.
- `Documentation/` contains setup, dependency, architecture, contribution, and security notes.

## Build

Open `Shelf.xcodeproj` in Xcode or run `Scripts/build-and-install.sh` on macOS. `project.yml` is the XcodeGen spec. Regenerate the project with `xcodegen generate --spec project.yml --project Shelf.xcodeproj` after editing the spec.

## Change guidance

- Keep passwords and API keys in Keychain or the provider's own credential store.
- Keep Calibre's active database local; cloud folders are intake destinations.
- Keep provider and device identities platform-neutral in `ShelfCore`.
- Treat cloud files as user-selected documents and respect security-scoped access/bookmarks.
- Avoid bundling personal launch agents, service logs, library databases, ebooks, and private configuration.

## Before opening a pull request

- Build the macOS target with Xcode.
- Run `node --check Resources/Dashboard/app.js`.
- Run `python3 -m py_compile Sources/ShelfCore/Tools/*.py`.
- Scan for personal paths, local IPs, credentials, private logs, and generated app bundles.
- Describe the integrations you exercised and any unavailable services.
