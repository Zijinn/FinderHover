#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -L "$ROOT/build" ] || [ -L "$ROOT/TestResults" ]; then echo '拒绝使用符号链接输出目录' >&2; exit 1; fi
mkdir -p "$ROOT/build" "$ROOT/TestResults"
xcrun swiftc -swift-version 5 "$ROOT/Sources/Geometry.swift" "$ROOT/Tests/main.swift" \
    -framework Foundation -framework CoreGraphics -o "$ROOT/build/GeometryTests"
"$ROOT/build/GeometryTests" | tee "$ROOT/TestResults/logic-tests.txt"
POCKET_TEST="$ROOT/build/PocketTests"
xcrun swiftc -swift-version 5 "$ROOT/Sources/ShakeDetector.swift" "$ROOT/Sources/PocketStore.swift" "$ROOT/Tests/PocketTests.swift" \
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
for theme in light dark; do
    rm -f "$ROOT/TestResults/preview-$theme.png" "$ROOT/TestResults/preview-$theme.png.json"
    open -n -W "$ROOT/build/FinderHover.app" --args --render-preview "$ROOT/TestResults/preview-$theme.png" --appearance "$theme"
done
rm -f "$ROOT/TestResults/diagnostics.json"
open -n -W "$ROOT/build/FinderHover.app" --args --diagnose "$ROOT/TestResults/diagnostics.json"
rm -f "$ROOT/TestResults/menu.json"
open -n -W "$ROOT/build/FinderHover.app" --args --menu-test "$ROOT/TestResults/menu.json"
rm -f "$ROOT/TestResults/animation.json"
open -n -W "$ROOT/build/FinderHover.app" --args --animation-test "$ROOT/TestResults/animation.json"
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
            'dockAppItemCount', 'dockApps', 'managedAppCount', 'enabledAppCount', 'enabledApps'):
    assert key in diagnostic, sorted(diagnostic)
assert diagnostic['dockRunning'] is True, diagnostic
assert isinstance(diagnostic['dockApps'], list), diagnostic
assert diagnostic['managedAppCount'] >= len(diagnostic['enabledApps']), diagnostic
print('Accessibility trusted:', diagnostic['accessibilityTrusted'])
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
            'appPickerRowsMatchManagedApps', 'perAppSubmenuBuilt', 'appearanceRowsComplete',
            'permissionNoteMatchesState', 'switcherShortcutRowPresent', 'pocketPanelConstructed'):
    assert menu_report.get(key) is True, (key, menu_report)
assert menu_report['actionItemsMissingTarget'] == 0, menu_report
assert menu_report['unresolvedSelectors'] == 0, menu_report
assert menu_report['emptySubmenuCount'] == 0, menu_report
assert menu_report['managedAppCount'] > 0, menu_report
assert menu_report['appearanceSliderRows'] == 7, menu_report
assert menu_report['topLevelItemCount'] >= 18, menu_report
print(f"PASS: toolbox menu graph builds ({menu_report['topLevelItemCount']} top rows, "
      f"{menu_report['managedAppCount']} managed apps, {menu_report['appPickerRows']} app rows, "
      f"7 appearance sliders, {menu_report['actionableItemCount']} actions, 0 unresolved selectors)")
PY
if [ "${1:-}" = '--integration' ]; then
    rm -f "$ROOT/TestResults/integration.json"
    open -n -W "$ROOT/build/FinderHover.app" --args --integration-test "$ROOT/TestResults/integration.json"
    python3 - "$ROOT/TestResults/integration.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result, ensure_ascii=False, indent=2))
if not result.get('passed'):
    sys.exit(2 if result.get('blocked') else 1)
PY
fi
