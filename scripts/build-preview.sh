#!/bin/bash
# Build a local, separately named style preview without changing Xcode settings.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/TackShelf.app"
OUT=".build/tackshelf-preview"
DEVELOPER_PATH="$(xcode-select -p)"
SDK_PATH="${TACKSHELF_SDK_PATH:-$DEVELOPER_PATH/SDKs/MacOSX.sdk}"
if [ ! -d "$SDK_PATH" ]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
ARCH="$(uname -m)"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
  -module-name Tendedero Sources/Tendedero/*.swift -o "$OUT/TackShelf"
cp "$OUT/TackShelf" "$APP/Contents/MacOS/TackShelf"

# The system camera importer needs its own activating AppKit process because
# the shelf intentionally never becomes a key window. Bundle the small local
# helper, with no updater or clipboard/paste behavior.
HELPER="$APP/Contents/Helpers/PhoneCameraCapture.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
swiftc -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
  Helpers/PhoneCameraCapture/main.swift -o "$HELPER/Contents/MacOS/PhoneCameraCapture"
cp Helpers/PhoneCameraCapture/LICENSE "$HELPER/Contents/Resources/LICENSE"
mkdir -p "$APP/Contents/Resources/ThirdParty/ContinuityCapture"
cp Helpers/PhoneCameraCapture/LICENSE "$APP/Contents/Resources/ThirdParty/ContinuityCapture/LICENSE"
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TackShelf Camera</string>
  <key>CFBundleDisplayName</key><string>TackShelf Camera</string>
  <key>CFBundleIdentifier</key><string>local.tackshelf.preview.phonecamera</string>
  <key>CFBundleExecutable</key><string>PhoneCameraCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.17</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$HELPER"

swiftc -sdk "$SDK_PATH" scripts/make-preview-icon.swift -o "$OUT/make-preview-icon"
"$OUT/make-preview-icon" "$OUT/preview-icon.png"
ICONSET="$OUT/TackShelf.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$OUT/preview-icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  double=$((s * 2))
  sips -z "$double" "$double" "$OUT/preview-icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/TackShelf.icns"

for directory in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$directory" "$APP/Contents/Resources/"
done
cp Sources/Tendedero/Resources/InstantCamera.png "$APP/Contents/Resources/InstantCamera.png"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSES/Tendedero-MIT.txt "$APP/Contents/Resources/Licenses/Tendedero-MIT.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TackShelf</string>
  <key>CFBundleDisplayName</key><string>TackShelf</string>
  <key>CFBundleIdentifier</key><string>local.tackshelf.preview</string>
  <key>CFBundleExecutable</key><string>TackShelf</string>
  <key>CFBundleIconFile</key><string>TackShelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.17</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.tackshelf.preview.camera</string>
    <key>CFBundleURLSchemes</key><array><string>tackshelf</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>用于显示你选择接收的桌面截图。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>用于显示你选择的文件夹中的图片。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>用于显示你选择的文件夹中的图片。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
