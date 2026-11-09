#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CAMERA_SDK="${TACKSHELF_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
CAMERA_OUT=".build/phone-camera-checks"
mkdir -p "$CAMERA_OUT"
swiftc -sdk "$CAMERA_SDK" -target "$(uname -m)-apple-macosx14.0" \
  Sources/Tendedero/Inbox.swift Sources/Tendedero/PhoneCameraCapture.swift \
  Tests/PhoneCameraChecks/main.swift -o "$CAMERA_OUT/phone-camera-checks"
"$CAMERA_OUT/phone-camera-checks"
