#!/bin/bash
set -euo pipefail
# Run once on the developer's Mac. Only the public key is printed.
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this once on your Mac.' >&2; exit 1; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v gh >/dev/null || { echo 'Install GitHub CLI, sign in to your GitHub account, and rerun this script.' >&2; exit 1; }
# Test the exact API access needed before generating or exporting any secret.
gh api repos/Somamill/Shelf/actions/secrets/public-key --jq .key_id >/dev/null
existing="$(gh secret list --repo Somamill/Shelf --json name --jq '.[].name')"
if printf '%s\n' "$existing" | grep -Fxq SPARKLE_PRIVATE_KEY; then
  echo 'SPARKLE_PRIVATE_KEY is already configured. It was not replaced. Keep the existing signing key for future updates.'
  exit 0
fi
umask 077
temporary="$(mktemp -d "${TMPDIR:-/tmp}/shelf-updater-key.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
bash "$root/Scripts/download-sparkle.sh" "$temporary/sparkle"
"$temporary/sparkle/bin/generate_keys" --account app.shelf.dashboard
"$temporary/sparkle/bin/generate_keys" --account app.shelf.dashboard -x "$temporary/private.key"
# The private seed goes through stdin, not shell arguments or console output.
gh secret set SPARKLE_PRIVATE_KEY --repo Somamill/Shelf < "$temporary/private.key"
echo 'Configured SPARKLE_PRIVATE_KEY in GitHub Actions. The original key remains in your Mac login Keychain; keep a secure backup.'
"$temporary/sparkle/bin/generate_keys" --account app.shelf.dashboard -p
