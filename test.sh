#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -L "$ROOT/build" ] || [ -L "$ROOT/TestResults" ]; then echo '拒绝使用符号链接输出目录' >&2; exit 1; fi
mkdir -p "$ROOT/build" "$ROOT/TestResults"
xcrun swiftc -swift-version 5 "$ROOT/Sources/Geometry.swift" "$ROOT/Tests/main.swift" \
    -framework Foundation -framework CoreGraphics -o "$ROOT/build/GeometryTests"
"$ROOT/build/GeometryTests" | tee "$ROOT/TestResults/logic-tests.txt"
POCKET_TEST="$ROOT/build/PocketTests"
xcrun swiftc -swift-version 5 "$ROOT/Sources/ShakeDetector.swift" "$ROOT/Sources/DragShakeWatcher.swift" \
    "$ROOT/Sources/PocketStore.swift" "$ROOT/Tests/PocketTests.swift" \
    -framework AppKit -framework CoreGraphics -o "$POCKET_TEST"
"$POCKET_TEST" | tee "$ROOT/TestResults/pocket-tests.txt"
SHORTCUT_TEST="$ROOT/build/ShortcutTests"
xcrun swiftc -swift-version 5 "$ROOT/Sources/ShortcutManager.swift" "$ROOT/Tests/ShortcutTests.swift" \
    -framework AppKit -framework Carbon -o "$SHORTCUT_TEST"
"$SHORTCUT_TEST" | tee "$ROOT/TestResults/shortcut-tests.txt"
MODEL_TEST="$ROOT/build/ModelTests"
xcrun swiftc -swift-version 5 "$ROOT/Sources/AppModel.swift" "$ROOT/Sources/SettingsStore.swift" \
    "$ROOT/Tests/ModelTests.swift" \
    -framework Foundation -framework CoreGraphics -framework ApplicationServices -o "$MODEL_TEST"
"$MODEL_TEST" | tee "$ROOT/TestResults/model-tests.txt"
"$ROOT/build.sh"
APP="$ROOT/build/FinderHover.app/Contents/MacOS/FinderHover"
# Launch the binary directly instead of `open --args`: LaunchServices does not
# reliably forward arguments here, which made the app fall back to its first-run
# branch and wait instead of exiting. Every mode below terminates on its own.
for theme in light dark; do
    rm -f "$ROOT/TestResults/preview-$theme.png" "$ROOT/TestResults/preview-$theme.png.json"
    "$APP" --render-preview "$ROOT/TestResults/preview-$theme.png" --appearance "$theme"
done
rm -f "$ROOT/TestResults/diagnostics.json"
"$APP" --diagnose "$ROOT/TestResults/diagnostics.json"
rm -f "$ROOT/TestResults/menu.json"
"$APP" --menu-test "$ROOT/TestResults/menu.json"
rm -f "$ROOT/TestResults/animation.json"
"$APP" --animation-test "$ROOT/TestResults/animation.json"
for asset in settings permission; do
    rm -f "$ROOT/TestResults/$asset.png" "$ROOT/TestResults/$asset.png.json"
done
rm -f "$ROOT/TestResults"/settings-p*.png "$ROOT/TestResults/settings-window.png"
"$APP" --render-settings "$ROOT/TestResults/settings.png"
"$APP" --render-permission "$ROOT/TestResults/permission.png"
python3 - "$ROOT" <<'PY'
import json, struct, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'TestResults'
def verify_transparency(meta):
    strong = meta['systemReducedTransparency'] or meta['systemIncreasedContrast']
    expected_strength = 1.0 if strong else meta['configuredGlassStrength']
    expected_transparency = meta['configuredGlassTransparency']
    assert abs(meta['backgroundOpacity'] - expected_strength) < 0.001, meta
    assert 0 <= expected_transparency <= 100, meta
    assert meta['foregroundOpacity'] == 1, meta
    assert meta['separateBackgroundAndForeground'] is True, meta
    assert meta['backgroundFrameMatchesForeground'] is True, meta
    assert meta['backgroundIgnoresMouseEvents'] is True, meta
    assert meta['backgroundWindowVisible'] is True, meta
    assert all(alpha < 0.01 for alpha in meta['cachedForegroundBackgroundAlphaSamples']), meta
    samples = meta['cachedBackgroundAlphaSamples']
    assert samples and all(0 <= alpha <= min(1, expected_strength + 0.08) for alpha in samples), meta
    assert abs(meta['windowServerBackgroundAlpha'] - expected_strength) < 0.005, meta
    assert meta['cachedIconPeakAlpha'] > 0.98, meta
    return expected_transparency
animation = json.loads((root / 'animation.json').read_text())
assert animation.get('reopenSurvivesOlderDismissal') is True, animation
print('PASS: reopening native panel interrupts older dismissal safely')
assert animation['glassTransparencyMinimumClamped'] is True, animation
assert animation['glassTransparencyMaximumClamped'] is True, animation
verify_transparency(animation['liveAdjustment'])
assert abs(animation['liveAdjustment']['configuredGlassTransparency'] - 88) < 0.001, animation
print('PASS: live 0-100% transparency update, range limits and opaque foreground')
adjust = animation['liveAdjustment']
assert adjust['metricsAppliedToLayout'] is True, adjust
assert abs(adjust['appliedRowHeight'] - 64) < 0.001, adjust
assert abs(adjust['appliedTitleFontSize'] - 18) < 0.001, adjust
assert abs(adjust['rowPitch'] - 64) < 0.001, adjust
print('PASS: live appearance change reaches the laid-out rows (row height 64, font 18)')
for theme in ('light', 'dark'):
    meta = json.loads((root / f'preview-{theme}.png.json').read_text())
    assert meta.get('rowCount') == 8, meta
    assert meta.get('allRowsFitDocument') is True, meta
    assert meta.get('previewUsesSampleData') is True, meta
    assert meta.get('nativeLiquidGlass') is True, meta
    assert meta.get('metricsAppliedToLayout') is True, meta
    assert 34 <= meta['appliedRowHeight'] <= 72, meta
    assert 11 <= meta['appliedTitleFontSize'] <= 22, meta
    assert 240 <= meta['appliedWidthCap'] <= 640, meta
    assert 0.3 <= meta['appliedMaxHeightFraction'] <= 0.9, meta
    assert 4 <= meta['appliedDockGap'] <= 40, meta
    assert 0 <= meta['appliedCornerRadius'] <= 36, meta
    assert meta['panelWidth'] <= meta['appliedWidthCap'] + 0.5, meta
    assert abs(meta['rowPitch'] - meta['appliedRowHeight']) < 0.001, meta
    assert meta['panelAppName'], meta
    assert meta['omittedWindowCount'] == meta['switchableWindowCount'] - meta['rowCount'], meta
    assert meta['switchableWindowCount'] > meta['rowCount'], meta
    expected_transparency = verify_transparency(meta)
    png = (root / f'preview-{theme}.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', png[16:24])
    assert height > width > 0, (width, height)
    assert len(png) > 1000
    print(f'PASS: {theme} vertical panel layout ({width}x{height}, 8 rows)')
    print(f'PASS: {theme} uses native NSGlassEffectView; glass style {meta["glassStyle"]}')
    print(f'PASS: {theme} header app "{meta["panelAppName"]}", {meta["switchableWindowCount"]} windows '
          f'showing {meta["rowCount"]} (row {meta["appliedRowHeight"]}pt, font {meta["appliedTitleFontSize"]}pt, '
          f'gap {meta["appliedDockGap"]}pt, radius {meta["appliedCornerRadius"]}pt)')
    print(f'PASS: {theme} transparency setting {expected_transparency:.0f}%, compositor alpha {meta["windowServerBackgroundAlpha"]:.2f}, icon alpha {meta["cachedIconPeakAlpha"]:.2f}')
print('NOTE: PNGs verify foreground layout, not desktop glass refraction. Inspect the live preview for glass.')
diagnostic = json.loads((root / 'diagnostics.json').read_text())
for key in ('accessibilityTrusted', 'dockRunning', 'windowSwitcherEnabled', 'pocketEnabled',
            'dockAppItemCount', 'dockApps', 'managedAppCount', 'enabledAppCount', 'enabledApps',
            'bundlePath', 'executableName', 'translocated', 'signature', 'duplicateCopies'):
    assert key in diagnostic, sorted(diagnostic)
assert diagnostic['dockRunning'] is True, diagnostic
assert isinstance(diagnostic['dockApps'], list), diagnostic
assert isinstance(diagnostic['duplicateCopies'], list), diagnostic
assert diagnostic['bundlePath'].endswith(diagnostic['executableName']), diagnostic
assert diagnostic['signature'] in ('adhoc', 'certificate'), diagnostic
assert diagnostic['managedAppCount'] >= len(diagnostic['enabledApps']), diagnostic
print('Accessibility trusted:', diagnostic['accessibilityTrusted'])
print('Running from:', diagnostic['bundlePath'])
if diagnostic['duplicateCopies']:
    print('WARNING: other copies of the same bundle exist; the grant is per path:',
          diagnostic['duplicateCopies'])
print('Dock app items visible to this process:', diagnostic['dockAppItemCount'])
print('Managed apps:', diagnostic['managedAppCount'], 'enabled:', diagnostic['enabledAppCount'])
for app in diagnostic['enabledApps']:
    if app.get('inDock'):
        print('  enabled in Dock:', app['name'], 'windows',
              app.get('switchableWindowCount'), app.get('firstTitles', []))
    else:
        print('  enabled but not in Dock:', app['name'])
if not diagnostic['accessibilityTrusted']:
    print('BLOCKED: real hover/focus requires manual Accessibility permission.')
menu_report = json.loads((root / 'menu.json').read_text())
for key in ('menuBuilt', 'statusItemHasMenu', 'menuDelegateIsController', 'sectionHeadingsPresent',
            'settingsEntryPresent', 'settingsWindowConstructed', 'settingsSidebarComplete',
            'settingsAppRowsMatchManagedApps', 'settingsAppearanceSlidersComplete',
            'permissionNoteMatchesState', 'pocketPanelConstructed'):
    assert menu_report.get(key) is True, (key, menu_report)
assert menu_report['actionItemsMissingTarget'] == 0, menu_report
assert menu_report['unresolvedSelectors'] == 0, menu_report
assert menu_report['emptySubmenuCount'] == 0, menu_report
assert menu_report['settingsPageCount'] == 4, menu_report
assert menu_report['settingsManagedAppCount'] > 0, menu_report
assert menu_report['settingsSliderCount'] == 7, menu_report
assert menu_report['settingsSwitchCount'] >= 3, menu_report
assert menu_report['topLevelItemCount'] >= 9, menu_report
print(f"PASS: launcher menu builds ({menu_report['topLevelItemCount']} top rows, "
      f"{menu_report['actionableItemCount']} actions, 0 unresolved selectors)")
print(f"PASS: settings window builds ({menu_report['settingsPageCount']} pages, "
      f"{menu_report['settingsSidebarItemCount']} sidebar items, "
      f"{menu_report['settingsAppRowCount']} app rows, {menu_report['settingsSliderCount']} sliders, "
      f"{menu_report['settingsSwitchCount']} switches, {menu_report['settingsWindowSize']} pt)")
settings_report = json.loads((root / 'settings.png.json').read_text())
assert settings_report['pageCount'] == 4, settings_report
assert len(settings_report['pages']) == 4, settings_report
for page in settings_report['pages']:
    assert page['width'] == 576 and page['height'] == 560, page
    assert page['pngBytes'] > 5000, page
assert settings_report['window']['pngBytes'] > 5000, settings_report['window']
print('PASS: settings pages render (' + ', '.join(
    f"p{p['page']} {p['title']} {p['pixelsWide']}x{p['pixelsHigh']}" for p in settings_report['pages']) + ')')
permission_report = json.loads((root / 'permission.png.json').read_text())
assert permission_report['width'] == 560 and permission_report['height'] == 462, permission_report
assert permission_report['pngBytes'] > 5000, permission_report
assert permission_report['pixelsWide'] == 1120 and permission_report['pixelsHigh'] == 924, permission_report
print(f"PASS: permission guide renders ({permission_report['pixelsWide']}x"
      f"{permission_report['pixelsHigh']}, translocated={permission_report['translocated']}, "
      f"trusted={permission_report['trusted']})")
PY
if [ "${1:-}" = '--integration' ]; then
    rm -f "$ROOT/TestResults/integration.json"
    "$APP" --integration-test "$ROOT/TestResults/integration.json"
    python3 - "$ROOT/TestResults/integration.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result, ensure_ascii=False, indent=2))
if not result.get('passed'):
    sys.exit(2 if result.get('blocked') else 1)
PY
fi
