#!/usr/bin/env bash
#
# pgBrain release pipeline.
#
# Steps:
#   1. Preflight (gh, cert, notary, sparkle key, clean tree, tag free)
#   2. Bump Info.plist version (scripts/bump.sh)
#   3. swift build -c release + bundle the .app (scripts/bundle.sh release)
#   4. codesign with Developer ID (env CODESIGN_IDENTITY)
#   5. Notarize + staple the .app (env NOTARYTOOL_PROFILE)
#   6. Build branded DMG (scripts/build-dmg.sh)
#   7. codesign + notarize + staple the DMG
#   8. sign_update against the DMG → EdDSA signature
#   9. Append item to appcast.xml
#  10. Commit Info.plist + appcast.xml, push, gh release create with DMG
#
# Required: scripts/.env (see scripts/.env.example) — TEAM_ID,
# CODESIGN_IDENTITY, NOTARYTOOL_PROFILE, GITHUB_REPO.
#
# Usage:
#   scripts/release.sh patch         # 0.0.1 → 0.0.2
#   scripts/release.sh minor         # 0.0.1 → 0.1.0
#   scripts/release.sh major         # 0.0.1 → 1.0.0
#   scripts/release.sh 1.2.3         # explicit
#   scripts/release.sh patch --skip-notarize   # dry-run without Apple creds
#   scripts/release.sh patch --skip-upload     # skip GitHub release publish

set -euo pipefail
cd "$(dirname "$0")/.."

# --- Configuration (.env) ---
ENV_FILE="scripts/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found. Copy scripts/.env.example and fill it in." >&2
    exit 1
fi
# shellcheck source=scripts/.env
source "$ENV_FILE"

for var in TEAM_ID CODESIGN_IDENTITY NOTARYTOOL_PROFILE GITHUB_REPO; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in $ENV_FILE" >&2
        exit 1
    fi
done

# --- Args ---
BUMP_KIND="${1:-patch}"
SKIP_NOTARIZE=0
SKIP_UPLOAD=0
for arg in "$@"; do
    [[ "$arg" == "--skip-notarize" ]] && SKIP_NOTARIZE=1
    [[ "$arg" == "--skip-upload" ]] && SKIP_UPLOAD=1
done

APP_NAME="pgBrain"
APP_PATH="build/${APP_NAME}.app"
PLIST="Resources/Info.plist"
RELEASES_DIR="releases"

info()    { printf "\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$*"; }
success() { printf "\033[1;32m==>\033[0m \033[1m%s\033[0m\n" "$*"; }
error()   { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

sparkle() { ./scripts/sparkle-tools.sh "$@"; }

# ==========================================================================
# PREFLIGHT
# ==========================================================================
info "Preflight checks"

command -v gh >/dev/null 2>&1 || error "GitHub CLI 'gh' not installed."
gh auth status >/dev/null 2>&1 || error "gh not authenticated. Run: gh auth login"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY" \
        || error "Codesigning identity not found: $CODESIGN_IDENTITY"
    xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" >/dev/null 2>&1 \
        || error "Notary profile '$NOTARYTOOL_PROFILE' not configured. Run: xcrun notarytool store-credentials \"$NOTARYTOOL_PROFILE\" --apple-id <email> --team-id $TEAM_ID --password <app-pw>"
fi

# Ensure the Sparkle dependency is fetched so the tools exist.
if [[ ! -x ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]]; then
    info "Sparkle tools not present — running swift build to fetch them"
    swift build >/dev/null
fi
sparkle generate_keys -p >/dev/null 2>&1 \
    || error "Sparkle EdDSA private key missing from Keychain. Run: ./scripts/sparkle-tools.sh generate_keys"

if ! git diff --quiet || ! git diff --cached --quiet; then
    error "Working tree has uncommitted changes. Commit or stash first."
fi

success "Preflight passed"

# ==========================================================================
# STEP 1: BUMP VERSION
# ==========================================================================
info "Step 1/10: Bumping version ($BUMP_KIND)"
NEW=$(./scripts/bump.sh "$BUMP_KIND")
VERSION=$(echo "$NEW" | awk '{print $1}')

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    git checkout -- "$PLIST" || true
    error "Git tag v$VERSION already exists. Choose a different version."
fi
success "Now releasing pgBrain v$VERSION"

# ==========================================================================
# STEP 2: BUILD + BUNDLE
# ==========================================================================
info "Step 2/10: Building release + bundling .app"
./scripts/bundle.sh release >/dev/null
[[ -d "$APP_PATH" ]] || error "Bundle missing at $APP_PATH"

# ==========================================================================
# STEP 3: CODESIGN
# ==========================================================================
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    info "Step 3/10: Codesigning with $CODESIGN_IDENTITY"
    # Sign nested Sparkle helpers first (deepest → shallowest), then the
    # main app last. --deep is deprecated; this is the modern approach
    # Apple's notary service expects.
    SPARKLE_VERSION_DIR="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"
    for target in \
        "${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc" \
        "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc" \
        "${SPARKLE_VERSION_DIR}/Autoupdate" \
        "${SPARKLE_VERSION_DIR}/Updater.app" \
        "${APP_PATH}/Contents/Frameworks/Sparkle.framework"
    do
        [[ -e "$target" ]] || continue
        codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$target"
    done
    codesign --force --options runtime --timestamp \
        --entitlements Resources/pgBrain.entitlements \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_PATH"
    codesign --verify --strict --verbose=2 "$APP_PATH"
else
    info "Step 3/10: (skip-notarize) leaving ad-hoc signature"
fi

# ==========================================================================
# STEP 4: NOTARIZE + STAPLE THE APP
# ==========================================================================
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    info "Step 4/10: Notarizing app"
    NOTARIZE_ZIP="build/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    rm -f "$NOTARIZE_ZIP"
    success "App notarized + stapled"
else
    info "Step 4/10: (skip-notarize)"
fi

# ==========================================================================
# STEP 5: BUILD DMG
# ==========================================================================
DMG_FILE="${APP_NAME}-${VERSION}.dmg"
DMG_BUILD_PATH="build/${DMG_FILE}"
info "Step 5/10: Building DMG ($DMG_FILE)"
./scripts/build-dmg.sh "$DMG_BUILD_PATH" >/dev/null

# ==========================================================================
# STEP 6: SIGN + NOTARIZE DMG
# ==========================================================================
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    info "Step 6/10: Signing + notarizing DMG"
    codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_BUILD_PATH"
    xcrun notarytool submit "$DMG_BUILD_PATH" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_BUILD_PATH"
    success "DMG signed + notarized"
else
    info "Step 6/10: (skip-notarize) DMG left ad-hoc"
fi

# ==========================================================================
# STEP 7: SPARKLE SIGN_UPDATE
# ==========================================================================
info "Step 7/10: EdDSA-signing DMG"
SIGN_OUTPUT=$(sparkle sign_update "$DMG_BUILD_PATH")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(stat -f%z "$DMG_BUILD_PATH")
[[ -n "$ED_SIGNATURE" ]] || error "sign_update didn't return a signature; got: $SIGN_OUTPUT"
success "Signature: $ED_SIGNATURE"

# ==========================================================================
# STEP 8: APPEND TO APPCAST
# ==========================================================================
info "Step 8/10: Updating appcast.xml"
mkdir -p "$RELEASES_DIR"
cp "$DMG_BUILD_PATH" "$RELEASES_DIR/$DMG_FILE"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_FILE"
PUB_DATE=$(LC_ALL=en_US date "+%a, %d %b %Y %H:%M:%S %z")

# Insert a fresh <item> at the top of <channel>. Awk-based so we don't need
# xmlstarlet or a full XML parser.
TMP_APPCAST=$(mktemp)
awk -v ver="$VERSION" -v pub="$PUB_DATE" -v url="$DOWNLOAD_URL" -v len="$LENGTH" -v sig="$ED_SIGNATURE" '
/<channel>/ && !inserted {
    print
    print "        <item>"
    print "            <title>" ver "</title>"
    print "            <pubDate>" pub "</pubDate>"
    print "            <sparkle:shortVersionString>" ver "</sparkle:shortVersionString>"
    print "            <sparkle:version>" ver "</sparkle:version>"
    print "            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>"
    print "            <enclosure url=\"" url "\" length=\"" len "\" type=\"application/octet-stream\" sparkle:edSignature=\"" sig "\"/>"
    print "        </item>"
    inserted = 1
    next
}
{ print }
' appcast.xml > "$TMP_APPCAST"
mv "$TMP_APPCAST" appcast.xml

# ==========================================================================
# STEP 9: COMMIT + PUSH
# ==========================================================================
info "Step 9/10: Committing release artefacts + pushing"
git add "$PLIST" appcast.xml
git commit -m "release v$VERSION"
git tag "v$VERSION"
CURRENT_BRANCH=$(git branch --show-current)
git push origin "$CURRENT_BRANCH"
git push origin "v$VERSION"

# ==========================================================================
# STEP 10: GH RELEASE
# ==========================================================================
if [[ $SKIP_UPLOAD -eq 0 ]]; then
    info "Step 10/10: Creating GitHub release v$VERSION"
    NOTES=$(mktemp)
    PREV_TAG=$(git tag --sort=-v:refname | sed -n '2p')
    if [[ -n "$PREV_TAG" ]]; then
        git log --pretty=format:'- %s' "${PREV_TAG}..v${VERSION}" > "$NOTES"
    else
        git log --pretty=format:'- %s' "v${VERSION}" > "$NOTES"
    fi
    gh release create "v$VERSION" \
        "$DMG_BUILD_PATH" \
        --repo "$GITHUB_REPO" \
        --title "pgBrain $VERSION" \
        --notes-file "$NOTES" \
        --latest
    rm -f "$NOTES"
else
    info "Step 10/10: (skip-upload) — upload manually with:"
    echo "    gh release create v$VERSION $DMG_BUILD_PATH --repo $GITHUB_REPO --title \"pgBrain $VERSION\" --notes …"
fi

echo
success "pgBrain v$VERSION released"
echo "  Release:  https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "  DMG:      $DOWNLOAD_URL"
echo "  Appcast:  https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml"
