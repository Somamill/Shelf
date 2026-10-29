#!/bin/bash
set -euo pipefail
# Same pinned binary and SHA-256 as Sparkle 2.10.1's official SPM manifest.
root="${1:?Usage: download-sparkle.sh destination-directory}"
mkdir -p "$root"
archive="$root/Sparkle.zip"
if [[ ! -f "$archive" ]]; then
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 2 \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip -o "$archive"
fi
printf '%s\n' "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a  $archive" | shasum -a 256 -c -
# ditto preserves framework symlinks and executable permissions.
ditto -x -k "$archive" "$root"
