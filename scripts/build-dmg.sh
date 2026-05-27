#!/usr/bin/env bash
#
# Build the pgBrain DMG using pure macOS tools (hdiutil + osascript).
# Produces a branded layout — coloured background, drag-arrow visual,
# Applications symlink for one-step install.
#
# No `create-dmg` Homebrew dep. The flow:
#   1. Stage app + Applications symlink + .background image
#   2. hdiutil create (UDRW, read-write)
#   3. Mount it, AppleScript Finder into setting view options + icon
#      positions + background image
#   4. Detach
#   5. hdiutil convert (UDZO, compressed read-only)
#
# Usage: scripts/build-dmg.sh [path/to/output.dmg]
#
# Reads: build/pgBrain.app  (produced by scripts/bundle.sh release)

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/pgBrain.dmg}"
APP="build/pgBrain.app"
BG="Resources/dmg-background.png"
VOLUME_NAME="pgBrain"
STAGING="build/dmg-staging"
TEMP_DMG="build/pgBrain-temp.dmg"

if [[ ! -d "$APP" ]]; then
    echo "✗ ${APP} not present. Run scripts/bundle.sh release first." >&2
    exit 1
fi

# Regenerate the background if missing or older than the generator.
if [[ ! -f "$BG" ]] || [[ "scripts/gen-dmg-background.swift" -nt "$BG" ]]; then
    echo "→ Generating DMG background…"
    swift scripts/gen-dmg-background.swift "$BG"
fi

# Clean up any prior staging.
rm -rf "$STAGING" "$TEMP_DMG" "$OUT"
mkdir -p "$STAGING/.background"

echo "→ Staging app + Applications symlink + background…"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$BG" "$STAGING/.background/background.png"

echo "→ Creating writable DMG…"
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$TEMP_DMG" \
    -quiet

echo "→ Mounting + arranging icons…"
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$TEMP_DMG" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')

# Finder needs a moment to register the mounted volume before AppleScript
# can talk to it. ~1s is usually enough.
sleep 1

# Window 660×400 matches the background image size from gen-dmg-background.swift.
# Icon positions mirror the visual drag arrow rendered into the bg:
#   pgBrain.app at (180, 200), Applications at (480, 200).
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "pgBrain.app" of container window to {180, 200}
        set position of item "Applications" of container window to {480, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Make sure Finder has flushed the .DS_Store.
sync
sleep 1

hdiutil detach "$MOUNT_DIR" -quiet

echo "→ Converting to compressed read-only DMG…"
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$OUT" \
    -quiet

rm -f "$TEMP_DMG"
rm -rf "$STAGING"
echo "✓ DMG built: $OUT"
