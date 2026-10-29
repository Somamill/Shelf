#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$HOME/Library/Application Support/Shelf"
CONFIG_FILE="$CONFIG_DIR/config.json"
BUILD_ROOT="/tmp/ShelfBuild-$UID"
APP_NAME="Shelf"
if [[ "${SHELF_DEVELOPMENT_BUILD:-0}" == 1 ]]; then
  APP_NAME="Shelf Dev"
  BUILD_ROOT="$BUILD_ROOT-Dev"
fi
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APPLICATIONS_DIR="${SHELF_APPLICATIONS_DIR:-/Applications}"
APP="$APPLICATIONS_DIR/$APP_NAME.app"

# Prefer a stable Apple identity; otherwise create a persistent local Shelf
# identity once. Ad-hoc signatures change on every build and re-trigger ACLs.
SIGNING_IDENTITY="${SHELF_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Developer ID Application:.*|Apple Development:.*|Shelf Stable Code Signing)"/\1/p' \
    | head -n 1 || true)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="Shelf Stable Code Signing"
  KEYCHAIN="$(security default-keychain -d user 2>/dev/null | awk -F '"' 'NF > 1 {print $2; exit}' || true)"
  [[ -n "$KEYCHAIN" ]] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Shelf Stable Code Signing'; then
    if ! command -v openssl >/dev/null 2>&1; then
      echo "Install OpenSSL or set SHELF_SIGNING_IDENTITY to a stable Apple signing identity." >&2
      exit 1
    fi
    SIGN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/shelf-signing.XXXXXX")"
    chmod 700 "$SIGN_TMP"
    trap 'rm -rf "$SIGN_TMP"' EXIT
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -keyout "$SIGN_TMP/shelf.key" -out "$SIGN_TMP/shelf.crt" \
      -subj "/CN=Shelf Stable Code Signing" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
      -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    SIGN_PASSWORD="$(openssl rand -hex 32)"
    export SIGN_PASSWORD
    openssl pkcs12 -export -legacy -inkey "$SIGN_TMP/shelf.key" -in "$SIGN_TMP/shelf.crt" \
      -out "$SIGN_TMP/shelf.p12" -passout "env:SIGN_PASSWORD" >/dev/null 2>&1
    security import "$SIGN_TMP/shelf.p12" -k "$KEYCHAIN" -P "$SIGN_PASSWORD" \
      -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGN_TMP/shelf.crt"
    unset SIGN_PASSWORD
    rm -rf "$SIGN_TMP"
    trap - EXIT
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Shelf Stable Code Signing'; then
      echo "Could not register a stable Shelf signing identity in the login keychain." >&2
      exit 1
    fi
  fi
fi

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
"$PROJECT_ROOT/Scripts/download-python-runtime.sh"
if [[ ! -f "$PROJECT_FILE" || ( "$PROJECT_ROOT/project.yml" -nt "$PROJECT_FILE" && "${SHELF_DEVELOPMENT_BUILD:-0}" != 1 ) ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Install XcodeGen to regenerate the project after editing project.yml." >&2
    exit 1
  fi
  xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT"
fi

if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project "$PROJECT_ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
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
  SPARKLE_DIR="$BUILD_ROOT/Sparkle"
  bash "$PROJECT_ROOT/Scripts/download-sparkle.sh" "$SPARKLE_DIR"
  SPARKLE_FRAMEWORKS="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64"
  mkdir -p "$CONTENTS/Frameworks"
  ditto "$SPARKLE_FRAMEWORKS/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
  swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -F "$SPARKLE_FRAMEWORKS" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -framework AppKit -framework WebKit -framework Vision -framework PDFKit -I "$RESOURCES" -L "$RESOURCES" -lShelfCore \
    -Xlinker -rpath -Xlinker '@executable_path/../Resources' \
    -o "$CONTENTS/MacOS/Shelf" "$PROJECT_ROOT/Sources/ShelfMacApp/AppMain.swift"
  cp "$PROJECT_ROOT/Resources/Dashboard/index.html" "$PROJECT_ROOT/Resources/Dashboard/style.css" \
    "$PROJECT_ROOT/Resources/Dashboard/app.js" "$PROJECT_ROOT/Resources/Icons/AppIcon.icns" \
    "$PROJECT_ROOT/Sources/ShelfCore/Tools/"*.py "$PROJECT_ROOT/Config/config.example.json" "$RESOURCES/"
  ditto "$PROJECT_ROOT/Resources/PythonRuntime" "$RESOURCES/PythonRuntime"
  cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Shelf</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>app.shelf.highlights</string><key>CFBundleURLSchemes</key><array><string>shelf</string></array></dict></array>
<key>CFBundleIdentifier</key><string>app.shelf.dashboard</string>
<key>CFBundleName</key><string>Shelf</string>
<key>CFBundleDisplayName</key><string>Shelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>45</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  /usr/bin/python3 - "$PROJECT_ROOT/Config/Shelf-Info.plist" "$CONTENTS/Info.plist" <<'PYINFO'
import plistlib,sys
with open(sys.argv[1], 'rb') as f: custom=plistlib.load(f)
with open(sys.argv[2], 'rb') as f: info=plistlib.load(f)
info.update(custom)
with open(sys.argv[2], 'wb') as f: plistlib.dump(info,f)
PYINFO
fi
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Xcode completed without creating Shelf.app." >&2
  exit 1
fi
if [[ "${SHELF_DEVELOPMENT_BUILD:-0}" == 1 ]]; then
  /usr/bin/python3 - "$BUILT_APP/Contents/Info.plist" <<'PYDEV'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as f: info=plistlib.load(f)
info.update(CFBundleIdentifier='app.shelf.dashboard.dev',CFBundleName='Shelf Dev',
            CFBundleDisplayName='Shelf Dev',SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False)
info.pop('SUPublicEDKey',None)
info['CFBundleURLTypes']=[{'CFBundleURLName':'app.shelf.highlights.dev','CFBundleURLSchemes':['shelf-dev']}]
with open(path,'wb') as f: plistlib.dump(info,f)
PYDEV
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
if [[ "${SHELF_BUILD_ONLY:-0}" == 1 ]]; then
  echo "Built and verified $BUILT_APP"
  exit 0
fi
mkdir -p "$APPLICATIONS_DIR"
if [[ "${SHELF_DEVELOPMENT_BUILD:-0}" == 1 ]]; then
  # Stage and verify before stopping the running development app. Never quit Shelf.
  STAGED_APP="$(mktemp -d "$APPLICATIONS_DIR/.Shelf-Dev.XXXXXX")"
  trap 'rm -rf "$STAGED_APP"' EXIT
  ditto "$BUILT_APP" "$STAGED_APP/Shelf Dev.app"
  codesign --verify --deep --strict "$STAGED_APP/Shelf Dev.app"
  osascript -e 'tell application id "app.shelf.dashboard.dev" to quit' >/dev/null 2>&1 || true
  if [[ -e "$APP" ]]; then
    BACKUP_APP="$APPLICATIONS_DIR/Shelf Dev.previous.app"
    rm -rf "$BACKUP_APP"
    mv "$APP" "$BACKUP_APP"
  fi
  if ! mv "$STAGED_APP/Shelf Dev.app" "$APP"; then
    if [[ -n "${BACKUP_APP:-}" ]]; then mv "$BACKUP_APP" "$APP"; fi
    exit 1
  fi
  rm -rf "$STAGED_APP"
  trap - EXIT
  open -a "$APP"
  echo "Installed $APP (release updates disabled; source sync manages this app)"
  exit 0
fi
osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1 || true
if [[ -e "$APP" ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$APP\""
fi
ditto "$BUILT_APP" "$APP"
codesign --verify --deep --strict "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
touch "$APP"
killall Dock >/dev/null 2>&1 || true
open -a "$APP"
echo "Installed $APP"
