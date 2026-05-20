#!/usr/bin/env bash
#
# Build pgBrain via SwiftPM and assemble a macOS .app bundle in build/.
# Ad-hoc signs for local development. Production signing happens in the
# release pipeline (Developer ID + notarization), not here.
#
# Usage:
#   scripts/bundle.sh [debug|release]   (default: debug)

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="pgBrain"
BUNDLE_ID="cloud.souris.pgbrain"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "→ Building (${CONFIG})…"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release --arch arm64
    BIN_PATH=".build/release/${APP_NAME}"
else
    swift build
    BIN_PATH=".build/debug/${APP_NAME}"
fi

if [[ ! -f "$BIN_PATH" ]]; then
    echo "✗ Build did not produce ${BIN_PATH}" >&2
    exit 1
fi

# Generate icon if missing or older than the generator script.
if [[ ! -f "Resources/AppIcon.icns" ]] || [[ "scripts/gen-icon.swift" -nt "Resources/AppIcon.icns" ]]; then
    echo "→ Generating AppIcon.icns…"
    swift scripts/gen-icon.swift Resources/AppIcon.icns
fi

echo "→ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# PkgInfo (legacy but expected).
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "→ Ad-hoc signing for local dev…"
codesign --force --sign - \
    --entitlements Resources/pgBrain.entitlements \
    --options runtime \
    --timestamp=none \
    "${APP_DIR}" >/dev/null 2>&1 || {
        # Fall back to entitlement-less ad-hoc sign if hardened runtime rejects the entitlements during dev.
        echo "  (retrying without hardened runtime)"
        codesign --force --sign - "${APP_DIR}" >/dev/null
    }

echo "✓ Bundled ${APP_DIR}"
echo "  Bundle ID: ${BUNDLE_ID}"
echo "  Run with:  open ${APP_DIR}"
