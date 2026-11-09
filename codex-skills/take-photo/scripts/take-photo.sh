#!/bin/bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  printf '用法：take-photo.sh [--check]\n' >&2
  exit 64
fi
case "${1:-}" in
  ""|--check) ;;
  *) printf '用法：take-photo.sh [--check]\n' >&2; exit 64 ;;
esac

CAMERA_APP="${TACKSHELF_APP_PATH:-$HOME/Applications/TackShelf.app}"
CAMERA_PLIST="$CAMERA_APP/Contents/Info.plist"
if [ ! -x "$CAMERA_APP/Contents/MacOS/TackShelf" ] || [ ! -f "$CAMERA_PLIST" ]; then
  printf '找不到 TackShelf 拍照程序。请先构建应用，或用 TACKSHELF_APP_PATH 指向应用。\n' >&2
  exit 1
fi
CAMERA_BUNDLE="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$CAMERA_PLIST")"
CAMERA_SCHEME="$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$CAMERA_PLIST")"
if [ "$CAMERA_BUNDLE" != 'local.tackshelf.preview' ] || [ "$CAMERA_SCHEME" != 'tackshelf' ]; then
  printf '此 TackShelf 版本尚未接入拍照快捷入口，请更新本地构建。\n' >&2
  exit 1
fi

if [ "${1:-}" = '--check' ]; then
  printf '拍照 Skill 已就绪；检查未启动相机。\n'
  exit 0
fi

/usr/bin/open -a "$CAMERA_APP" 'tackshelf://camera'
printf '已发出拍照请求。请在 iPhone 拍摄并点“使用照片”，随后在 Codex 按 ⌘V。\n'
