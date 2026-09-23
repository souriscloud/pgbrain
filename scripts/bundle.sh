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

# Local builds are signed with the Developer ID from scripts/.env when it is
# available: a stable identity means the Keychain recognises every rebuild as
# the same app (and as the release build), so saved passwords don't prompt
# after each build. Without it (or with PGBRAIN_ADHOC=1) fall back to ad-hoc,
# which the Keychain treats as a new app on every build.
SIGN_IDENTITY="-"
if [[ "${PGBRAIN_ADHOC:-0}" != "1" && -f scripts/.env ]]; then
    CODESIGN_IDENTITY="$(sed -n 's/^CODESIGN_IDENTITY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' scripts/.env | head -1)"
    if [[ -n "$CODESIGN_IDENTITY" ]] && security find-identity -v -p codesigning | grep -qF "$CODESIGN_IDENTITY"; then
        SIGN_IDENTITY="$CODESIGN_IDENTITY"
    fi
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "→ Ad-hoc signing for local dev…"
    ENTITLEMENTS="Resources/pgBrain-dev.entitlements"
else
    echo "→ Signing with ${SIGN_IDENTITY} (local, not notarized)…"
    ENTITLEMENTS="Resources/pgBrain.entitlements"
fi

# Sign nested Sparkle helpers first (Apple's strict signing order: deepest
# first). scripts/release.sh re-signs everything with a secure timestamp.
SPARKLE_VERSION_DIR="${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B"
for target in \
    "${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc" \
    "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc" \
    "${SPARKLE_VERSION_DIR}/Autoupdate" \
    "${SPARKLE_VERSION_DIR}/Updater.app" \
    "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
do
    [[ -e "$target" ]] || continue
    codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp=none "$target" >/dev/null 2>&1 \
        || echo "  ! sign failed: $target" >&2
done

codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    "${APP_DIR}" >/dev/null 2>&1 || {
        echo "  (retrying ad-hoc without hardened runtime)"
        codesign --force --sign - "${APP_DIR}" >/dev/null
    }

echo "✓ Bundled ${APP_DIR}"
echo "  Bundle ID: ${BUNDLE_ID}"
echo "  Run with:  open ${APP_DIR}"
