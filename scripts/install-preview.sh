#!/bin/bash
# Install the preview at a stable per-user path so macOS can reopen it at login.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="build/TackShelf.app"
DESTINATION="${TACKSHELF_INSTALL_PATH:-$HOME/Applications/TackShelf.app}"
STAGING="${DESTINATION}.updating"

if [ ! -d "$SOURCE" ]; then
  echo "Missing $SOURCE; run scripts/build-preview.sh first" >&2
  exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$STAGING"
ditto "$SOURCE" "$STAGING"
codesign --verify --deep --strict "$STAGING"
rm -rf "$DESTINATION"
mv "$STAGING" "$DESTINATION"
echo "Installed $DESTINATION"
