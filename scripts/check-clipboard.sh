#!/bin/bash
# Exercise ClipboardWatcher without touching the user's clipboard or app settings.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_PATH="$(xcode-select -p)"
SDK_PATH="${TACKSHELF_SDK_PATH:-$DEVELOPER_PATH/SDKs/MacOSX.sdk}"
if [ ! -d "$SDK_PATH" ]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
OUT=".build/clipboard-checks"
mkdir -p "$OUT"
sources=()
for source in Sources/Tendedero/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then
    sources+=("$source")
  fi
done
swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx14.0" \
  -module-name Tendedero "${sources[@]}" Tests/ClipboardWatcherChecks/main.swift \
  -o "$OUT/clipboard-checks"
"$OUT/clipboard-checks"
