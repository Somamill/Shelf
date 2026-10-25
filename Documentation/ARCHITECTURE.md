# Architecture and cloud storage

## Current macOS design

Shelf has a small shared Swift package (`ShelfCore`) and a macOS app target (`Shelf`). The app shell, dashboard, reader, and local adapters are kept separate. There are no third-party Swift package dependencies.

Cloud provider choice currently means a **locally available folder** supplied by the provider's official macOS app or File Provider integration. Shelf stages incoming EPUBs there. It does not collect a Google or Microsoft password, implement provider OAuth, or claim a direct cloud API connection. The user chooses the import folder through the system folder picker; Shelf saves its path and bookmark in the private configuration.

The Calibre library remains a local, single-writer library. Do not put the active `metadata.db` under Google Drive, OneDrive, iCloud Drive, Dropbox, or a network share. Calibre documents that cloud synchronization can conflict with an open library, calls Google Drive incompatible, and recommends using the Content server for access from other devices. The wizard therefore describes cloud storage as an import destination, separate from the active Calibre library. [Calibre FAQ](https://manual.calibre-ebook.com/faq.html)

## Planned iPhone companion

`ShelfCore` is Foundation-only and builds for macOS 14 and iOS 17. It owns Codable profile and provider identities that the desktop setup wizard uses. A future iOS target can reuse those models and add a SwiftUI setup/library interface.

On iOS, cloud folders should be selected through the Files document picker. Apple's picker supports third-party File Provider locations and returns security-scoped URLs; persistent access uses bookmarks and coordinated file operations. This provides one user-controlled path for iCloud Drive, OneDrive, Google Drive, and other providers without embedding separate credentials in Shelf. [Apple: Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)

Remote reading progress should go through the configured Calibre/KOReader/CrossPoint servers. The iPhone app should not sync or open a cloud-mirrored Calibre database directly.

## Direct cloud APIs

Provider API connections are intentionally not implemented yet. Google Drive and Microsoft Graph require OAuth app registration, scoped grants, token refresh, conflict handling, retries, and provider-specific upload/download behavior. For now, official desktop sync clients plus a user-picked folder are lower-friction and reuse macOS/iOS File Provider security. A later direct API adapter can be added behind a shared storage protocol after OAuth registration and threat-model review.
