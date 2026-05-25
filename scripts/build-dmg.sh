#!/usr/bin/env bash
#
# Build the pgBrain DMG. Uses `create-dmg` from Homebrew when available so
# we get the branded layout (custom background, sized window, drag-arrow);
# falls back to vanilla `hdiutil` if not installed.
#
# Usage:
#   scripts/build-dmg.sh [path/to/output.dmg]
#
# Requirements (optional but recommended):
#   brew install create-dmg
#
# Reads:
#   build/pgBrain.app  (produced by scripts/bundle.sh release)

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/pgBrain.dmg}"
APP="build/pgBrain.app"
BG="Resources/dmg-background.png"

if [[ ! -d "$APP" ]]; then
    echo "✗ ${APP} not present. Run scripts/bundle.sh release first." >&2
    exit 1
fi

# Regenerate the background if it's missing or older than the generator.
if [[ ! -f "$BG" ]] || [[ "scripts/gen-dmg-background.swift" -nt "$BG" ]]; then
    echo "→ Generating DMG background…"
    swift scripts/gen-dmg-background.swift "$BG"
fi

rm -f "$OUT"

if command -v create-dmg >/dev/null 2>&1; then
    echo "→ Building DMG via create-dmg"
    create-dmg \
        --volname "pgBrain" \
        --background "$BG" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 96 \
        --icon "pgBrain.app" 180 200 \
        --app-drop-link 480 200 \
        --hide-extension "pgBrain.app" \
        --no-internet-enable \
        "$OUT" \
        "$APP"
else
    echo "⚠️  create-dmg not installed; falling back to hdiutil. Install via 'brew install create-dmg' for the branded layout."
    hdiutil create -volname "pgBrain" -srcfolder "$APP" -ov -format UDZO "$OUT"
fi

echo "✓ DMG built: $OUT"
