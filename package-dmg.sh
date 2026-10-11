#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DMG_ROOT="$BUILD/dmg-root"
APP="$BUILD/FinderHover.app"
DMG="$BUILD/Mac工具箱-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist").dmg"

if [ "$(uname -s)" != "Darwin" ]; then
  echo 'package-dmg.sh must run on macOS' >&2
  exit 1
fi
"$ROOT/build.sh"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/Mac工具箱.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG"
hdiutil create -volname "Mac工具箱" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
printf 'Created %s\n' "$DMG"
