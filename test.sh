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
if [ ! -d "$ROOT/build/FinderHover.app" ]; then "$ROOT/build.sh"; fi
for theme in light dark; do
    rm -f "$ROOT/TestResults/preview-$theme.png" "$ROOT/TestResults/preview-$theme.png.json"
    open -n -W "$ROOT/build/FinderHover.app" --args --render-preview "$ROOT/TestResults/preview-$theme.png" --appearance "$theme"
done
rm -f "$ROOT/TestResults/diagnostics.json"
open -n -W "$ROOT/build/FinderHover.app" --args --diagnose "$ROOT/TestResults/diagnostics.json"
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
for theme in ('light', 'dark'):
    meta = json.loads((root / f'preview-{theme}.png.json').read_text())
    assert meta.get('rowCount') == 8, meta
    assert meta.get('allRowsFitDocument') is True, meta
    assert meta.get('previewUsesSampleData') is True, meta
    assert meta.get('nativeLiquidGlass') is True, meta
    assert meta.get('macOS27InteractiveGlass') is False, meta
    expected_transparency = verify_transparency(meta)
    png = (root / f'preview-{theme}.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', png[16:24])
    assert height > width > 0, (width, height)
    assert len(png) > 1000
    print(f'PASS: {theme} vertical panel layout ({width}x{height}, 8 rows)')
    print(f'PASS: {theme} uses native NSGlassEffectView; unavailable interactive property is not required')
    print(f'PASS: {theme} glass style {meta["glassStyle"]}, transparency {expected_transparency:.0f}%, window alpha {meta["windowServerBackgroundAlpha"]:.2f}, icon alpha {meta["cachedIconPeakAlpha"]:.2f}')
    print(f'PASS: {theme} transparency setting {expected_transparency:.0f}%, compositor alpha {meta["windowServerBackgroundAlpha"]:.2f}')
print('NOTE: PNGs verify foreground layout, not desktop glass refraction. Inspect the live preview for glass.')
diagnostic = json.loads((root / 'diagnostics.json').read_text())
print('Accessibility trusted:', diagnostic['accessibilityTrusted'])
print('Real Finder windows:', diagnostic['windowCount'])
print('Finder Dock item found:', diagnostic['dockFinderItemFound'])
if not diagnostic['accessibilityTrusted']:
    print('BLOCKED: real hover/focus requires manual Accessibility permission.')
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
