#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SHELF_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${1:-/Applications/Shelf.app}/Contents/Info.plist" 2>/dev/null || sed -n 's/.*MARKETING_VERSION: //p' "$ROOT/project.yml" | head -1)}"
APP_PATH="${1:-/Applications/Shelf.app}"
OUTPUT="${2:-$ROOT/dist/Shelf-${VERSION}.dmg}"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Shelf.app not found at: $APP_PATH" >&2
  echo "Build it first or pass the app bundle path as the first argument." >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/shelf-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_PATH" "$STAGE/Shelf.app"
PYTHON_ROOT="$STAGE/Shelf.app/Contents/Resources/PythonRuntime"
if [[ ! -x "$PYTHON_ROOT/arm64/python/bin/python3" || ! -x "$PYTHON_ROOT/x86_64/python/bin/python3" ]]; then
  "$ROOT/Scripts/download-python-runtime.sh" "$PYTHON_ROOT"
  # This fallback is for locally built preview DMGs. Public release builds
  # embed and Developer ID sign the runtimes before packaging.
  codesign --force --deep --sign - "$STAGE/Shelf.app"
fi
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install Shelf.txt" <<'TXT'
Install Shelf

1. Drag Shelf.app into Applications.
2. Open Shelf from Applications.
3. On first launch, choose Use detected library, or select your Calibre library in Setup.

For release builds, download the notarized DMG from the official Shelf GitHub release page.
TXT
hdiutil create -quiet -volname "Shelf ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT"
echo "Created $OUTPUT"
