#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/Resources/PythonRuntime}"
TAG="20261026"
VERSION="3.13.18"
if [[ -x "$DEST/arm64/python/bin/python3" && -x "$DEST/x86_64/python/bin/python3" ]] &&
   "$DEST/arm64/python/bin/python3" --version 2>&1 | grep -Fq "Python $VERSION"; then
  exit 0
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/shelf-python.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$DEST"
download_runtime() {
  local arch="$1" expected="$2"
  local asset="cpython-${VERSION}+${TAG}-${arch}-apple-darwin-install_only_stripped.tar.gz"
  local archive="$STAGING/$arch.tar.gz"
  local folder="$DEST/$arch"
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${asset//+/%2B}" \
    --output "$archive"
  echo "$expected  $archive" | shasum --check --status
  mkdir -p "$folder"
  tar -xzf "$archive" -C "$folder"
  test -x "$folder/python/bin/python3"
}
download_runtime aarch64 8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405
download_runtime x86_64 7412c19d896c99431b74a18a5643e110449a7f9590fbab179c3e5ab27b9aa9e3
# Publish stable architecture directory names used by Shelf at runtime.
if [[ -d "$DEST/aarch64" ]]; then mv "$DEST/aarch64" "$DEST/arm64"; fi
for arch in arm64 x86_64; do
  python="$DEST/$arch/python/bin/python3"
  file "$python" | grep -q 'Mach-O'
done
"$DEST/arm64/python/bin/python3" --version
