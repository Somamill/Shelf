# Releasing a signed macOS build

Shelf 0.1.0 currently publishes source code only. A downloadable app for other Macs needs a Developer ID Application certificate and Apple notarization. Apple requires Developer ID signing, Hardened Runtime, and a notarization ticket for this distribution path. Unsigned DMGs are useful for local testing but macOS may warn or block them, so Homebrew and public releases use only notarized artifacts.

## One-time GitHub setup

Create and export a Developer ID Application certificate from the Apple Developer account, then add these repository Actions secrets:

- `APPLE_CERTIFICATE_BASE64`: base64-encoded `.p12` certificate export
- `APPLE_CERTIFICATE_PASSWORD`: password used to export the `.p12`
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_ID`: Apple account used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for that Apple account

Use the Apple account's least-privileged suitable access. Never commit these values or paste them into issues or chat. Rotate the certificate/password if they are exposed.

## Create a release

Push a version tag such as `v0.1.1`. The `Signed macOS release` workflow archives Shelf, signs it with Developer ID, submits it with `notarytool`, staples the ticket, and uploads `Shelf.dmg` and a versioned ZIP to the matching GitHub release. The cask downloads the stable `Shelf.dmg` asset from the latest release. If the required secrets are missing or notarization fails, the job stops and does not publish an unsigned app archive.

For the certificate and notarization requirements, see Apple's [Developer ID certificate guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Installers and Homebrew

The repository includes `Scripts/package-dmg.sh` for producing a standard drag-to-Applications DMG from a built app bundle, and `Casks/shelf.rb` for Homebrew installation. The Homebrew cask intentionally tracks only the latest signed release. Configure the five Apple secrets above before publishing a release so the DMG can be notarized.
