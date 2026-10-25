#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$HOME/Library/Application Support/Shelf"
CONFIG_FILE="$CONFIG_DIR/config.json"
BUILD_ROOT="/tmp/ShelfBuild-$UID"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APPLICATIONS_DIR="${SHELF_APPLICATIONS_DIR:-/Applications}"
APP="$APPLICATIONS_DIR/Shelf.app"

mkdir -p "$CONFIG_DIR" "$BUILD_ROOT"
if [[ ! -e "$CONFIG_FILE" ]]; then
  cp "$PROJECT_ROOT/Config/config.example.json" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
fi

/usr/bin/python3 - "$CONFIG_FILE" "$PROJECT_ROOT" <<'PY'
import json
import os
import sys

path, project_root = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        config = json.load(source)
except (OSError, ValueError):
    config = {}
paths = config.setdefault("paths", {})
if not paths.get("project") or paths["project"] == "~/Shelf":
    paths["project"] = project_root
with open(path, "w", encoding="utf-8") as output:
    json.dump(config, output, ensure_ascii=False, indent=2)
    output.write("\n")
os.chmod(path, 0o600)
PY

PROJECT_FILE="$PROJECT_ROOT/Shelf.xcodeproj/project.pbxproj"
if [[ ! -f "$PROJECT_FILE" || "$PROJECT_ROOT/project.yml" -nt "$PROJECT_FILE" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Install XcodeGen to regenerate the project after editing project.yml." >&2
    exit 1
  fi
  xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT"
fi

osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1 || true
if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project "$PROJECT_ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
  BUILT_APP="$DERIVED_DATA/Build/Products/Release/Shelf.app"
else
  BUILT_APP="$BUILD_ROOT/Manual/Shelf.app"
  CONTENTS="$BUILT_APP/Contents"
  RESOURCES="$CONTENTS/Resources"
  mkdir -p "$CONTENTS/MacOS" "$RESOURCES"
  swift "$PROJECT_ROOT/Scripts/generate_icon.swift" "$PROJECT_ROOT/Resources/Icons/AppIcon.iconset"
  iconutil --convert icns "$PROJECT_ROOT/Resources/Icons/AppIcon.iconset" --output "$PROJECT_ROOT/Resources/Icons/AppIcon.icns"
  swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -emit-module -emit-library -module-name ShelfCore \
    -emit-module-path "$RESOURCES/ShelfCore.swiftmodule" \
    -o "$RESOURCES/libShelfCore.dylib" "$PROJECT_ROOT/Sources/ShelfCore/ShelfCore/SetupModels.swift"
  swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -framework AppKit -framework WebKit -I "$RESOURCES" -L "$RESOURCES" -lShelfCore \
    -Xlinker -rpath -Xlinker '@executable_path/../Resources' \
    -o "$CONTENTS/MacOS/Shelf" "$PROJECT_ROOT/Sources/ShelfMacApp/AppMain.swift"
  cp "$PROJECT_ROOT/Resources/Dashboard/index.html" "$PROJECT_ROOT/Resources/Dashboard/style.css" \
    "$PROJECT_ROOT/Resources/Dashboard/app.js" "$PROJECT_ROOT/Resources/Icons/AppIcon.icns" \
    "$PROJECT_ROOT/Sources/ShelfCore/Tools/"*.py "$PROJECT_ROOT/Config/config.example.json" "$RESOURCES/"
  cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Shelf</string>
<key>CFBundleIdentifier</key><string>app.shelf.dashboard</string>
<key>CFBundleName</key><string>Shelf</string>
<key>CFBundleDisplayName</key><string>Shelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  xattr -cr "$BUILT_APP" 2>/dev/null || true
  codesign --force --deep --sign - "$BUILT_APP"
fi
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Xcode completed without creating Shelf.app." >&2
  exit 1
fi
mkdir -p "$APPLICATIONS_DIR"
if [[ -e "$APP" ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$APP\""
fi
ditto "$BUILT_APP" "$APP"
codesign --verify --deep --strict "$APP"
open -a "$APP"
echo "Installed $APP"
