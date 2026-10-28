#!/bin/bash

set -euo pipefail

HOME_DIR="$HOME"
BOOKS="${SHELF_BOOKS_ROOT:-$HOME/Books}"
LOGS="$BOOKS/logs"

LOG="$LOGS/xteink-sync-configurator.log"
STAMP_DIR="$BOOKS/state/xteink-sync"

mkdir -p "$LOGS" "$STAMP_DIR"

exec >>"$LOG" 2>&1

echo
echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] scan"

LAN_IP=""

for IFACE in en0 en1 en2; do
    IP="$(/usr/sbin/ipconfig getifaddr "$IFACE" 2>/dev/null || true)"

    if [ -n "$IP" ]; then
        LAN_IP="$IP"
        break
    fi
done

if [ -z "$LAN_IP" ]; then
    exit 0
fi

for VOLUME in /Volumes/*; do

    [ -d "$VOLUME" ] || continue

    CFG="$VOLUME/.crosspoint/koreader.json"

    [ -f "$CFG" ] || continue

    STAMP="$STAMP_DIR/$(basename "$VOLUME").backed_up"
    BACKUP=""
    if [ -f "$STAMP" ]; then
        IFS= read -r BACKUP < "$STAMP" || true
    fi

    # Older stamp files were empty and were written even when cp failed.
    # Verify the recorded backup before trusting it; write the stamp only
    # after a successful copy.
    if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
        BACKUP="$CFG.pre-kosync.$(/bin/date '+%Y%m%d-%H%M%S').$$.bak"
        if ! /bin/cp -p "$CFG" "$BACKUP"; then
            echo "ERROR: Could not back up $CFG; leaving it unchanged."
            continue
        fi
        STAMP_TMP="$STAMP.tmp.$$"
        if ! printf '%s\n' "$BACKUP" > "$STAMP_TMP" || ! /bin/mv -f "$STAMP_TMP" "$STAMP"; then
            echo "ERROR: Could not record backup path for $VOLUME; leaving config unchanged."
            continue
        fi
        echo "Backup created: $BACKUP"
    fi

    CFG_PATH="$CFG" \
    LAN_IP="$LAN_IP" \
    /usr/bin/python3 <<'PYCODE'
import json
import os
import tempfile

path = os.environ["CFG_PATH"]
lan_ip = os.environ["LAN_IP"]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise ValueError("KOReader configuration root must be a JSON object")

old_url = data.get("serverUrl", "")

# Keep credentials completely untouched.
# Only change safe synchronization parameters.
desired = {
    "cfgVersion": 2,
    # Use the local CrossPoint Sync service (Caddy's LAN HTTP listener).
    # The legacy KOSync container on 7200 drops document metadata, which
    # prevents automatic matching when a reader has a different EPUB edition.
    "serverUrl": f"http://{lan_ip}:17302",
    "matchMethod": 1,
    # Keep title/author metadata enabled so identifier-only positions can be
    # matched against Calibre even when a device copy has a different hash.
    "sendMetadata": True,
    "syncBehavior": 1,
    # Use a long press to launch Sync Progress directly (CrossPoint enum 0).
    # Firmware still needs this user gesture; automatic background uploads are not supported.
    "longPressMenuFunction": 0,
}
changed = any(data.get(key) != value for key, value in desired.items())
if not changed:
    raise SystemExit(0)
data.update(desired)

fd, tmp = tempfile.mkstemp(
    prefix="koreader-",
    suffix=".json",
    dir=os.path.dirname(path)
)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.replace(tmp, path)

except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass

    raise

print(f"[{__import__('datetime').datetime.now().isoformat(sep=' ', timespec='seconds')}] Updated CrossPoint sync server to http://{lan_ip}:17302")
PYCODE

    echo "Xteink configuration enforced."

done
