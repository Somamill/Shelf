# Automatic app updates

Shelf uses Sparkle 2.10.1 for signed in-app updates. SSH and a local source checkout
are not needed for installed users. Install the first updater-enabled release
manually once: older releases such as 0.2.0 do not contain Sparkle and cannot
bootstrap themselves into this update flow.

Automatic checks and background installation are enabled by default. Saved user
preferences take precedence; change them in **Updates → Shelf app updates**. It checks approximately every four hours while Shelf runs,
can download/install in the background, and may defer installation until quit or
ask for macOS authorization. **Shelf → Check for Shelf Updates…** checks manually.
The separate Calibre/CrossPoint update controls continue to manage those products.

## One-time developer setup

Updates require a persistent Ed25519 signing seed stored as the GitHub Actions
repository secret `SPARKLE_PRIVATE_KEY`. Do not paste it into chat, commit it, or
print it in CI logs. Use an authenticated GitHub CLI session with repository-secret access for setup.

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
`sparkle-public-key.txt`. The production public key is also tracked in `Config/Shelf-Info.plist`, so normal
local builds retain update support. Isolated development builds remove that key
and disable automatic updates to avoid replacing the development app.

### Without GitHub CLI

Alternatively, on your Mac, generate the standard 32-byte Sparkle signing seed
and copy it directly to your clipboard without displaying it:

```sh
umask 077
key_dir="$HOME/Library/Application Support/Shelf/UpdaterSigning"
mkdir -p "$key_dir"
chmod 700 "$key_dir"
if [ ! -e "$key_dir/ed25519.seed" ]; then
  openssl rand -base64 32 > "$key_dir/ed25519.seed"
fi
chmod 600 "$key_dir/ed25519.seed"
pbcopy < "$key_dir/ed25519.seed"
```

Open [the repository's new Actions secret page](https://github.com/Somamill/Shelf/settings/secrets/actions/new),
name the secret `SPARKLE_PRIVATE_KEY`, and paste the clipboard into the value field.
Do this only for the initial setup, not to replace an existing release key.
Keep a secure backup of `ed25519.seed`. This alternative stores the original seed
in an owner-only local file rather than Keychain. No key belongs in chat.

## Each future release

1. Increase `MARKETING_VERSION` and the numeric `CURRENT_PROJECT_VERSION`.
2. Update the changelog and merge to `main`. When its build/validation workflow
   succeeds, the release workflow checks the version against the latest release
   and automatically publishes an increased version. Commits without a version
   bump do not release. Manual version-tag pushes and workflow dispatch also work.
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

## Apple Developer ID signing and notarization

The Apple Developer Program must expose a paid team in Xcode. A **Personal Team**
is for development and cannot issue a Developer ID Application certificate.
In **Xcode → Settings → Apple Accounts**, select the paid team, open
**Manage Certificates**, and create **Developer ID Application** if missing.

Then run locally in Terminal:

```sh
python3 Scripts/setup-apple-signing.py
```

The assistant selects one Developer ID identity, asks privately for the Apple
Account and an app-specific password from [account.apple.com](https://account.apple.com/),
validates notarization access with Apple, exports only that identity to a private
temporary PKCS#12 file, and uploads five encrypted GitHub Actions secrets:
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`,
`APPLE_CERTIFICATE_PASSWORD`, and `APPLE_CERTIFICATE_BASE64`.
It removes the temporary export afterward. Never send these values in chat.

The assistant sets `REQUIRE_APPLE_SIGNING=true` after successful setup. Missing or
partial Apple configuration then fails the release instead of publishing an
unsigned fallback. The CI signing keychain and temporary private exports are
removed even when the release fails. Apple notarization must pass before the
app is stapled, Gatekeeper-checked, and published.

For a read-only readiness check:

```sh
python3 Scripts/setup-apple-signing.py --check
```

Apple signing and Sparkle signing use separate keys. Do not replace the existing
Sparkle seed when enabling Apple signing: existing users trust that seed's public key.

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
