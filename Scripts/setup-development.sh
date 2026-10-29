#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Run this setup on your Mac, not in the cloud environment.' >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  xcode-select --install || true
  echo 'Finish installing Apple Command Line Tools, then run this setup again.' >&2
  exit 1
fi
REPO="${1:-$HOME/Developer/Shelf}"
if [[ ! -e "$REPO" ]]; then
  mkdir -p "$(dirname "$REPO")"
  git clone --branch main https://github.com/Somamill/Shelf.git "$REPO"
fi
BOOTSTRAP="$(mktemp -d "${TMPDIR:-/tmp}/shelf-development.XXXXXX")"
trap 'rm -rf "$BOOTSTRAP"' EXIT
curl --fail --location --silent --show-error \
  https://raw.githubusercontent.com/Somamill/Shelf/main/Scripts/development-sync.py \
  --output "$BOOTSTRAP/development-sync.py"
/usr/bin/python3 "$BOOTSTRAP/development-sync.py" setup --repo "$REPO"
