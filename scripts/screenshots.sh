#!/usr/bin/env bash
#
# Regenerate the marketing screenshots in docs/screenshots/.
#
#   scripts/screenshots.sh [scene,scene…]     (default: every scene)
#
# Seeds a throwaway database (pgbrain_showcase), builds a debug app with
# ad-hoc signing, runs it once per appearance in showcase mode — windows
# rendered off-screen, no Dock icon, no focus change, no Keychain, its own
# Application Support folder and preferences suite — then frames the PNGs.
# The database is always dropped, even on failure.
#
# Needs: a local PostgreSQL reachable as $USER without a password (trust or
# peer auth), PostGIS optional (the map scene is skipped without it),
# pngquant optional (smaller PNGs).

set -euo pipefail
cd "$(dirname "$0")/.."

DB="${PGBRAIN_SHOWCASE_DB:-pgbrain_showcase}"
OUT="docs/screenshots"
ONLY="${1:-}"
APP="build/pgBrain.app/Contents/MacOS/pgBrain"
WORK="$(mktemp -d -t pgbrain-showcase)"
BG_PIDS=()

fail() { echo "✗ $*" >&2; exit 1; }

cleanup() {
    local status=$?
    for pid in "${BG_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
    dropdb --if-exists --force "$DB" 2>/dev/null || echo "⚠ could not drop database $DB — drop it by hand" >&2
    defaults delete cloud.souris.pgbrain.showcase >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/cloud.souris.pgbrain.showcase.plist"
    rm -rf "$WORK"
    exit $status
}
trap cleanup EXIT INT TERM

command -v pg_isready >/dev/null || fail "PostgreSQL client tools not on PATH"
pg_isready -q || fail "no local PostgreSQL is accepting connections (pg_isready)"

VERSION="$(sed -n 's/^## v\([0-9][^ ]*\).*/\1/p' CHANGELOG.md | head -1)"
[[ -n "$VERSION" ]] || fail "no '## vX.Y.Z' section in CHANGELOG.md"

echo "→ Seeding ${DB}…"
dropdb --if-exists --force "$DB" 2>/dev/null
createdb "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f scripts/showcase/seed.sql >"$WORK/seed.log" 2>&1 \
    || { cat "$WORK/seed.log" >&2; fail "seeding failed"; }

echo "→ Building (debug, ad-hoc signed)…"
PGBRAIN_ADHOC=1 ./scripts/bundle.sh >"$WORK/build.log" 2>&1 \
    || { tail -30 "$WORK/build.log" >&2; fail "build failed"; }

# Other clients, so the Activity panel has more than pgBrain's own pool:
# a long report, a transaction holding a row lock, and a writer waiting on it.
PGAPPNAME=reporting-worker psql -X -q -d "$DB" \
    -c "SELECT count(*), pg_sleep(900) FROM analytics.events" >/dev/null 2>&1 &
BG_PIDS+=($!)
PGAPPNAME=checkout-api psql -X -q -d "$DB" \
    -c "BEGIN; SELECT id FROM orders WHERE id = 42 FOR UPDATE; SELECT pg_sleep(900);" >/dev/null 2>&1 &
BG_PIDS+=($!)
sleep 1
PGAPPNAME=inventory-sync psql -X -q -d "$DB" \
    -c "UPDATE orders SET status = 'paid' WHERE id = 42" >/dev/null 2>&1 &
BG_PIDS+=($!)

FRONT_BEFORE="$(lsappinfo front 2>/dev/null || true)"
mkdir -p "$WORK/raw"
for APPEARANCE in light dark; do
    echo "→ Rendering $APPEARANCE scenes…"
    RUN="$WORK/run-$APPEARANCE"
    mkdir -p "$RUN"
    # Launched directly, not via `open`: LaunchServices would activate it.
    PGBRAIN_SHOWCASE="$RUN" \
    PGBRAIN_SUPPORT_DIR="$WORK/support-$APPEARANCE" \
    PGBRAIN_SHOWCASE_DB="$DB" \
    PGBRAIN_SHOWCASE_APPEARANCE="$APPEARANCE" \
    PGBRAIN_SHOWCASE_ONLY="$ONLY" \
    PGBRAIN_SHOWCASE_VERSION="$VERSION" \
        "$APP" -AppleLocale en_US -AppleLanguages "(en)" >"$RUN/stdout.log" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 400); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        cat "$RUN/showcase.log" >&2 2>/dev/null || true
        fail "$APPEARANCE run timed out"
    fi
    if ! wait "$APP_PID"; then
        cat "$RUN/showcase.log" >&2 2>/dev/null || tail -20 "$RUN/stdout.log" >&2
        fail "$APPEARANCE run failed"
    fi
    cp "$RUN"/*.png "$WORK/raw/"
done
FRONT_AFTER="$(lsappinfo front 2>/dev/null || true)"
[[ "$FRONT_BEFORE" == "$FRONT_AFTER" ]] || echo "⚠ frontmost app changed during the run ($FRONT_BEFORE → $FRONT_AFTER)" >&2

echo "→ Framing…"
mkdir -p "$OUT"
if [[ -z "$ONLY" ]]; then
    find "$OUT" -name '*.png' -delete
fi
swift scripts/showcase/frame.swift "$WORK/raw" "$OUT" >/dev/null

if command -v pngquant >/dev/null; then
    echo "→ Optimising with pngquant…"
    find "$OUT" -name '*.png' -print0 | xargs -0 -n 8 pngquant --force --skip-if-larger --strip \
        --quality 80-98 --speed 1 --ext .png || true
else
    echo "  (pngquant not installed — PNGs left unoptimised; brew install pngquant)"
fi

COUNT="$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')"
SIZE="$(du -sh "$OUT" | cut -f1)"
echo "✓ $COUNT screenshots in $OUT ($SIZE) for v$VERSION"
