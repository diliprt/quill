#!/usr/bin/env bash
#
# Install Quill.
#   curl -fsSL https://raw.githubusercontent.com/xfreeze2/quill/main/install.sh | bash
#
# Installs to ~/Applications, so it never needs sudo or your password.
set -euo pipefail

REPO="xfreeze2/quill"
DEST="$HOME/Applications/Quill.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '→ finding the latest release…\n'
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Quill\.zip"' | cut -d'"' -f4 | head -1)"

if [ -z "$URL" ]; then
  echo "Could not find a release. See https://github.com/$REPO/releases" >&2
  exit 1
fi

printf '→ downloading…\n'
curl -fsSL "$URL" -o "$TMP/Quill.zip"

printf '→ installing to %s\n' "$DEST"
ditto -x -k "$TMP/Quill.zip" "$TMP/unpacked"
osascript -e 'quit app "Quill"' >/dev/null 2>&1 || true
sleep 0.4
rm -rf "$DEST"
mkdir -p "$HOME/Applications"
ditto "$TMP/unpacked/Quill.app" "$DEST"

# Downloaded apps are quarantined; without this macOS refuses to open it and
# says the app is damaged. Stripping it is the user's own explicit choice, made
# here by running this script.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

printf '✓ installed. Opening — the setup window will show what to allow.\n'
open "$DEST"
