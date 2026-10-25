# Releasing a signed macOS build

Shelf 0.1.0 currently publishes source code only. A downloadable app for other Macs needs a Developer ID Application certificate and Apple notarization. Apple requires Developer ID signing, Hardened Runtime, and a notarization ticket for this distribution path.

## One-time GitHub setup

Create and export a Developer ID Application certificate from the Apple Developer account, then add these repository Actions secrets:

- `APPLE_CERTIFICATE_BASE64`: base64-encoded `.p12` certificate export
- `APPLE_CERTIFICATE_PASSWORD`: password used to export the `.p12`
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_ID`: Apple account used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for that Apple account

Use the Apple account's least-privileged suitable access. Never commit these values or paste them into issues or chat. Rotate the certificate/password if they are exposed.

## Create a release

Push a version tag such as `v0.1.1`. The `Signed macOS release` workflow archives Shelf, signs it with Developer ID, submits it with `notarytool`, staples the ticket, and uploads a ZIP to the matching GitHub release. If the required secrets are missing or notarization fails, the job stops and does not publish an unsigned app archive.

For the certificate and notarization requirements, see Apple's [Developer ID certificate guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
