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
cp "$ROOT/Resources/RelayBridge/bridge.py" "$ROOT/Resources/RelayBridge/justwoker_compat.py" \
    "$STAGE/FinderHover.app/Contents/Resources/"
printf 'MacToolbox build output\n' > "$STAGE/FinderHover.app/Contents/Resources/finderhover-generated.txt"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Sources/AppModel.swift" "$ROOT/Sources/SettingsStore.swift" \
    "$ROOT/Sources/Geometry.swift" "$ROOT/Sources/AccessibilityService.swift" \
    "$ROOT/Sources/AppInstallation.swift" "$ROOT/Sources/UIKitBits.swift" \
    "$ROOT/Sources/WindowListPanel.swift" \
    "$ROOT/Sources/PocketStore.swift" \
    "$ROOT/Sources/ShakeDetector.swift" "$ROOT/Sources/DragShakeWatcher.swift" \
    "$ROOT/Sources/PocketPanel.swift" \
    "$ROOT/Sources/PocketStatusView.swift" "$ROOT/Sources/ShortcutManager.swift" \
    "$ROOT/Sources/PermissionWindow.swift" "$ROOT/Sources/SettingsWindow.swift" \
    "$ROOT/Sources/RelayBridgeWindow.swift" \
    "$ROOT/Sources/AppController.swift" "$ROOT/Sources/main.swift" \
    -framework AppKit -framework ApplicationServices -framework Carbon -framework Security \
    -framework SwiftUI -o "$STAGE/FinderHover.app/Contents/MacOS/FinderHover"
plutil -lint "$STAGE/FinderHover.app/Contents/Info.plist"
# Ad-hoc signatures are keyed to the binary hash, so every rebuild silently revokes
# the Accessibility grant. Any real certificate (self-signed or Apple Development)
# gives a stable identity and keeps the grant across rebuilds.
IDENTITY="${MACTOOLBOX_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    for candidate in "MacToolbox Local Signing" "Apple Development"; do
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
            IDENTITY="$candidate"
            break
        fi
    done
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier com.zijin.FinderHoverPrototype "$STAGE/FinderHover.app"
    printf '签名身份：%s\n' "$IDENTITY"
else
    echo '警告：未找到代码签名证书，回退 ad-hoc —— 每次重编译后辅助功能授权都会失效。' >&2
    echo '      建好证书后重新运行本脚本即可自动使用，详见 README「代码签名」。' >&2
    codesign --force --sign - --identifier com.zijin.FinderHoverPrototype "$STAGE/FinderHover.app"
fi
codesign --verify --deep --strict "$STAGE/FinderHover.app"
if [ -d "$APP" ]; then mv "$APP" "$STAGE/previous.app"; fi
if ! mv "$STAGE/FinderHover.app" "$APP"; then
    if [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP"; fi
    exit 1
fi
printf '\n构建成功：%s\n' "$APP"

# Accessibility is granted per bundle path and keyed to the code hash, so keeping a
# single install location is what makes the grant easy to reason about. Reinstalling
# still changes the hash, which means the switch has to be flipped once more.
if [ "${1:-}" = '--install' ]; then
    TARGET="/Applications/MacToolbox.app"
    if [ -d "$TARGET" ]; then mv "$TARGET" "$STAGE/previous-install.app"; fi
    if ditto "$APP" "$TARGET" && codesign --verify --deep --strict "$TARGET"; then
        printf '已安装：%s\n' "$TARGET"
        if [ -n "$IDENTITY" ]; then
            printf '签名身份固定（%s），重装不影响已有的辅助功能授权。\n' "$IDENTITY"
        else
            printf '提示：ad-hoc 签名，重装后需到辅助功能里把这一项关掉再打开一次。\n'
        fi
    else
        rm -rf "$TARGET"
        if [ -d "$STAGE/previous-install.app" ]; then mv "$STAGE/previous-install.app" "$TARGET"; fi
        echo '安装失败，已回滚到上一份。' >&2
        exit 1
    fi
fi
