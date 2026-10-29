# Automatic app updates

Shelf uses Sparkle 2.10.1 for signed in-app updates. SSH and a local source checkout
are not needed for installed users. Install the first updater-enabled release
manually once: older releases such as 0.2.0 do not contain Sparkle and cannot
bootstrap themselves into this update flow.

In **Updates → Shelf app updates**, enable automatic checking and automatic
installation. Sparkle asks for update permission on a later launch and preserves
the user's preference. It checks approximately every four hours while Shelf runs,
can download/install in the background, and may defer installation until quit or
ask for macOS authorization. **Shelf → Check for Shelf Updates…** checks manually.
The separate Calibre/CrossPoint update controls continue to manage those products.

## One-time developer setup

Updates require a persistent Ed25519 signing seed stored as the GitHub Actions
repository secret `SPARKLE_PRIVATE_KEY`. Do not paste it into chat, commit it, or
print it in CI logs. The connected coding integration cannot access the repository
secrets API (HTTP 403), so the repository owner must do this setup using their own
GitHub account.

On the developer Mac, from a current Shelf source checkout, run:

```sh
Scripts/setup-updater-signing.sh
```

This requires GitHub CLI (`gh`) authenticated with permission to manage repository
Actions secrets. The script tests the exact required API access before generating
or exporting any key. It refuses to overwrite an existing `SPARKLE_PRIVATE_KEY`.
If GitHub CLI is not installed/authenticated, install it and use `gh auth login`
locally, then rerun; do not share a GitHub token in chat.

The script downloads the official checksum-verified Sparkle tools, generates or
reuses an app-specific key in the Mac login Keychain, exports it only into a
private temporary file, and sends it to `gh secret set` through stdin. The temporary
export is removed on exit. The original key stays in Keychain. Keep a secure backup
of that Keychain item: losing the signing key can require a manual reinstall or a
carefully planned key-rotation release.

The public key is derived from the private seed and embedded in the app during a
release build. It is safe to publish and is attached to each release as
`sparkle-public-key.txt`. No public-key source edit or separate GitHub variable is
needed. Normal local builds without a configured public key leave the updater
disabled and show an explicit setup message; they do not accept unsigned updates.

## Each future release

1. Increase `MARKETING_VERSION` and the numeric `CURRENT_PROJECT_VERSION`.
2. Update the changelog, pass CI, and push the matching `vMAJOR.MINOR.PATCH` tag.
3. Actions embeds the public key, builds/signs the app, signs its update archive
   and feed, verifies the signatures, and uploads all assets to a draft release.
4. Only after all assets exist is the release made public/latest. Installed apps
   discover it through the stable HTTPS appcast URL.

The pipeline rejects missing/malformed signing seeds, mismatched version tags,
non-increasing build numbers, silently changed signing keys, and attempts to
replace a published release. It verifies the previous signed feed before trusting
its build number. Snapshots are not published as an unsigned fallback if signing
setup is incomplete. Existing legacy release 0.2.0 remains downloadable.

Sparkle checks the archive signature before extraction and requires signed feeds
and release notes. Invalid feed signatures do not expire into an unsigned fallback.
The appcast is hosted at:

`https://github.com/Somamill/Shelf/releases/latest/download/appcast.xml`

Ed25519 update signing is separate from Apple Developer ID signing/notarization.
The former authenticates updates; the latter gives the smoothest Gatekeeper
installation experience. Community builds can still require a first-launch
approval, and automatic installation can require authorization. Gatekeeper,
quarantine, TLS verification, and update-signature verification stay enabled.

## Validation

macOS CI uses a temporary test seed unrelated to production. It builds the app,
signs/verifies an update archive and appcast using Sparkle's official tools,
checks that a tampered archive is rejected, and launches the app with automatic
network checking disabled to verify the dashboard loads with Sparkle embedded.
The generated Xcode project is retained as an artifact so the tracked project can
be synchronized with XcodeGen output. Never distribute the CI test-key build.

The production bootstrap release cannot be published until the one-time repository
secret is configured. End-to-end replacement/relaunch on a user's Mac still needs
a genuine older updater-enabled build and a newer signed release.
