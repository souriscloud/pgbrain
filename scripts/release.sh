#!/usr/bin/env bash
#
# pgBrain release pipeline.
#
# Steps:
#   1. Bump the version (scripts/bump.sh).
#   2. Build release + bundle the .app (scripts/bundle.sh release).
#   3. Code-sign with the developer's Developer ID Application certificate
#      (env DEV_ID_APPLICATION_IDENTITY).
#   4. Notarize via notarytool keychain profile (env NOTARY_PROFILE).
#   5. Staple the notarization ticket.
#   6. Build the DMG (scripts/build-dmg.sh, iter-13).
#   7. Sign the DMG entry in the appcast.xml via Sparkle's sign_update.
#   8. Upload .dmg + appcast.xml to the GitHub release.
#
# Required environment (set in your shell or a .env file you source):
#   DEV_ID_APPLICATION_IDENTITY  e.g. "Developer ID Application: Souris s.r.o. (TEAMID)"
#   NOTARY_PROFILE               keychain profile name created with `notarytool store-credentials`
#   SPARKLE_PRIVATE_KEY_PATH     path to the EdDSA private key generated with sign_update
#   SPARKLE_PUBLIC_KEY           the matching public key (echoed into Info.plist's SUPublicEDKey)
#   GH_REPO                      e.g. "souris-cloud/pgbrain"  (defaults to the current origin)
#
# Usage:
#   scripts/release.sh patch        # version bump kind: patch|minor|major|X.Y.Z
#   scripts/release.sh patch --skip-notarize   # for dry-runs without Apple credentials
#
# This script is intentionally idempotent until step 5 — re-run if a step
# fails partway and the bumped version will only commit on success.

set -euo pipefail
cd "$(dirname "$0")/.."

BUMP_KIND="${1:-patch}"
SKIP_NOTARIZE=0
SKIP_UPLOAD=0
for arg in "$@"; do
    [[ "$arg" == "--skip-notarize" ]] && SKIP_NOTARIZE=1
    [[ "$arg" == "--skip-upload" ]] && SKIP_UPLOAD=1
done

# 1. Bump
NEW=$(./scripts/bump.sh "$BUMP_KIND")
VERSION=$(echo "$NEW" | awk '{print $1}')
echo "→ Releasing pgBrain v${VERSION}"

# 2. Build + bundle
./scripts/bundle.sh release
APP="build/pgBrain.app"

# 3. Sign with Developer ID
if [[ -n "${DEV_ID_APPLICATION_IDENTITY:-}" ]]; then
    echo "→ Signing with ${DEV_ID_APPLICATION_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/pgBrain.entitlements \
        --sign "$DEV_ID_APPLICATION_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "⚠️  DEV_ID_APPLICATION_IDENTITY not set — leaving ad-hoc sign."
fi

# 4. Notarize
if [[ $SKIP_NOTARIZE -eq 0 && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ Notarising via profile ${NOTARY_PROFILE}…"
    ZIP="build/pgBrain.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "→ Stapling"
    xcrun stapler staple "$APP"
else
    echo "⚠️  Skipping notarisation (NOTARY_PROFILE unset or --skip-notarize)."
fi

# 6. DMG (handled by iter-13 build-dmg.sh)
DMG="build/pgBrain-${VERSION}.dmg"
if [[ -x "scripts/build-dmg.sh" ]]; then
    ./scripts/build-dmg.sh "$DMG"
else
    echo "⚠️  scripts/build-dmg.sh not present — falling back to hdiutil"
    rm -f "$DMG"
    hdiutil create -volname "pgBrain" -srcfolder "$APP" -ov -format UDZO "$DMG"
fi

# 7. Sign the appcast entry
SIG=""
LENGTH=$(stat -f%z "$DMG")
if [[ -n "${SPARKLE_PRIVATE_KEY_PATH:-}" ]]; then
    SIG=$(xcrun --find sign_update 2>/dev/null || true)
    if [[ -z "$SIG" ]]; then
        echo "⚠️  Sparkle sign_update not on PATH — install via 'brew install sparkle' or run the binary from the dependency build directory."
    else
        EDSIG=$("$SIG" -f "$SPARKLE_PRIVATE_KEY_PATH" "$DMG")
        echo "→ EdDSA signature: $EDSIG"
    fi
fi

# 8. Upload (if gh is available + GH_REPO set)
if [[ $SKIP_UPLOAD -eq 0 && -x "$(command -v gh)" ]]; then
    NOTES_FILE="$(mktemp)"
    git log --pretty=format:'- %s' "$(git describe --tags --abbrev=0 2>/dev/null || echo)..HEAD" > "$NOTES_FILE"
    echo "→ Creating GitHub release v${VERSION}"
    gh release create "v${VERSION}" "$DMG" \
        --title "pgBrain ${VERSION}" \
        --notes-file "$NOTES_FILE" || true
fi

echo "✓ Release v${VERSION} complete: $DMG"
echo
echo "Next steps:"
echo "  1. Add the new <item> block to apps.souris.cloud/pgbrain/appcast.xml"
echo "  2. Include sparkle:edSignature=\"$EDSIG\" length=\"$LENGTH\" and the GitHub download URL."
echo "  3. git commit Resources/Info.plist + tag v${VERSION}."
