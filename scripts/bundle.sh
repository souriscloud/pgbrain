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
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Embed Sparkle.framework. SPM links the framework's binary at compile
# time but doesn't bundle the framework folder (Autoupdate, Updater.app,
# XPCServices) — without these inside Contents/Frameworks/, the auto-
# update install step fails at runtime even though the check works.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "✗ Sparkle.framework not found at ${SPARKLE_SRC}." >&2
    echo "  Did 'swift build' fetch the dependency? Re-run if Sparkle is missing." >&2
    exit 1
fi
echo "→ Embedding Sparkle.framework…"
# Use ditto so symlinks (Versions/Current → B, Sparkle → Versions/Current/Sparkle)
# are preserved exactly — cp -R doesn't keep all of them right.
ditto "$SPARKLE_SRC" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"

# PkgInfo (legacy but expected).
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "→ Ad-hoc signing for local dev…"
# Sign nested Sparkle helpers first (Apple's strict signing order: deepest
# first). Skip in release flow — scripts/release.sh re-signs with the real
# Developer ID identity.
SPARKLE_VERSION_DIR="${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B"
for target in \
    "${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc" \
    "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc" \
    "${SPARKLE_VERSION_DIR}/Autoupdate" \
    "${SPARKLE_VERSION_DIR}/Updater.app" \
    "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
do
    [[ -e "$target" ]] || continue
    codesign --force --sign - --timestamp=none "$target" >/dev/null 2>&1 || true
done

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
