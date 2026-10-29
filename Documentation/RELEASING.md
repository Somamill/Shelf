# Releasing Shelf for macOS

The release workflow builds a self-contained DMG for every version tag. It uses Developer ID signing and Apple notarization when the repository secrets are configured. If those credentials are unavailable, it publishes an ad-hoc signed, unsigned-for-distribution community build instead. Ad-hoc signing preserves bundle integrity but does not identify Shelf as an Apple-verified developer; macOS Gatekeeper remains enabled and users may need to approve the first launch manually using [Apple's documented steps](https://support.apple.com/en-nz/102445).

## One-time GitHub setup

Create and export a Developer ID Application certificate from the Apple Developer account, then add these repository Actions secrets:

- `APPLE_CERTIFICATE_BASE64`: base64-encoded `.p12` certificate export
- `APPLE_CERTIFICATE_PASSWORD`: password used to export the `.p12`
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_ID`: Apple account used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for that Apple account

Use the Apple account's least-privileged suitable access. Never commit these values or paste them into issues or chat. Rotate the certificate/password if they are exposed.

## Automatic-update signing

Configure the persistent `SPARKLE_PRIVATE_KEY` secret once using `Scripts/setup-updater-signing.sh` on the developer Mac. Update archives and feeds are signed independently of Apple Developer ID. The release workflow now fails closed when this key is missing and publishes complete signed assets atomically from a draft. See [automatic updates](AUTOMATIC-UPDATES.md).

## Create a release

Push a version tag such as `v0.1.38`. The `macOS release` workflow builds Shelf with its universal Python runtimes, then either notarizes it or creates the unsigned community build. It publishes `Shelf.dmg`, a versioned app ZIP, and a SHA-256 checksum to the matching GitHub release. The Homebrew cask downloads the stable `Shelf.dmg` asset and discloses that macOS may require a one-time approval. Do not remove quarantine attributes or disable Gatekeeper to make installation appear seamless.

For the certificate and notarization requirements, see Apple's [Developer ID certificate guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Installers and Homebrew

The repository includes `Scripts/download-python-runtime.sh` to fetch and verify universal arm64/x86_64 Python runtimes, `Scripts/package-dmg.sh` for producing a standard drag-to-Applications DMG, and `Casks/shelf.rb` for Homebrew installation. The packaged app does not ask users to install developer tools or Python. The Homebrew cask tracks the latest release. Configure the five Apple secrets above whenever Developer ID signing and notarization become available; without them the workflow continues with the clearly labeled community build.
