#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
if [ -L "$BUILD" ]; then echo '拒绝使用符号链接 build 目录' >&2; exit 1; fi
mkdir -p "$BUILD"
APP="$BUILD/FinderHover.app"
if [ -e "$APP" ]; then
    if [ -L "$APP" ] || [ ! -f "$APP/Contents/Resources/finderhover-generated.txt" ] ||
       [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" != 'com.zijin.FinderHoverPrototype' ]; then
        echo '已有 app 不是本脚本生成的产物；中止，未覆盖。' >&2; exit 1
    fi
fi
STAGE="$(mktemp -d "$BUILD/.compile-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/FinderHover.app/Contents/MacOS" "$STAGE/FinderHover.app/Contents/Resources"
cp "$ROOT/Info.plist" "$STAGE/FinderHover.app/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$STAGE/FinderHover.app/Contents/Resources/AppIcon.icns"
printf 'FinderHover build output\n' > "$STAGE/FinderHover.app/Contents/Resources/finderhover-generated.txt"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Sources/Geometry.swift" "$ROOT/Sources/AccessibilityService.swift" \
    "$ROOT/Sources/WindowListPanel.swift" "$ROOT/Sources/AppController.swift" "$ROOT/Sources/main.swift" \
    -framework AppKit -framework ApplicationServices -o "$STAGE/FinderHover.app/Contents/MacOS/FinderHover"
plutil -lint "$STAGE/FinderHover.app/Contents/Info.plist"
codesign --force --sign - --identifier com.zijin.FinderHoverPrototype "$STAGE/FinderHover.app"
codesign --verify --deep --strict "$STAGE/FinderHover.app"
if [ -d "$APP" ]; then mv "$APP" "$STAGE/previous.app"; fi
if ! mv "$STAGE/FinderHover.app" "$APP"; then
    if [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP"; fi
    exit 1
fi
printf '\n构建成功：%s\n' "$APP"
