#!/bin/bash
# Verify board history and copy actions without touching real user state.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_PATH="$(xcode-select -p)"
SDK_PATH="${FELTBOARD_SDK_PATH:-$DEVELOPER_PATH/SDKs/MacOSX.sdk}"
if [ ! -d "$SDK_PATH" ]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
OUT=".build/board-content-checks"
mkdir -p "$OUT"
sources=()
for source in Sources/Tendedero/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then
    sources+=("$source")
  fi
done
swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx14.0" \
  -module-name Tendedero "${sources[@]}" Tests/BoardContentChecks/main.swift \
  -o "$OUT/board-content-checks"
"$OUT/board-content-checks"
