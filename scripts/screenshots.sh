#!/usr/bin/env bash
#
# Regenerate the marketing screenshots in docs/screenshots/.
#
#   scripts/screenshots.sh [scene,scene…]     (default: every marketing scene;
#                                              `prefix-*` matches a family)
#
# Environment overrides:
#   PGBRAIN_SHOWCASE_OUT           output directory (default docs/screenshots)
#   PGBRAIN_SHOWCASE_APPEARANCES   appearances to render (default "light dark")
#   PGBRAIN_SHOWCASE_RAW=1         skip framing / pngquant: copy the raw PNGs and
#                                  each run's showcase log to the output directory
#   PGBRAIN_SHOWCASE_EXTRA_SEED    extra SQL file run after seed.sql
#   PGBRAIN_SHOWCASE_NO_CLIENTS=1  don't start the background psql clients
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
OUT="${PGBRAIN_SHOWCASE_OUT:-docs/screenshots}"
APPEARANCES="${PGBRAIN_SHOWCASE_APPEARANCES:-light dark}"
RAW="${PGBRAIN_SHOWCASE_RAW:-0}"
EXTRA_SEED="${PGBRAIN_SHOWCASE_EXTRA_SEED:-}"
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
if [[ -n "$EXTRA_SEED" ]]; then
    psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$EXTRA_SEED" >>"$WORK/seed.log" 2>&1 \
        || { cat "$WORK/seed.log" >&2; fail "extra seeding ($EXTRA_SEED) failed"; }
fi

echo "→ Building (debug, ad-hoc signed)…"
PGBRAIN_ADHOC=1 ./scripts/bundle.sh >"$WORK/build.log" 2>&1 \
    || { tail -30 "$WORK/build.log" >&2; fail "build failed"; }

# Other clients, so the Activity panel has more than pgBrain's own pool:
# a long report, a transaction holding a row lock, and a writer waiting on it.
if [[ "${PGBRAIN_SHOWCASE_NO_CLIENTS:-0}" != 1 ]]; then
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
fi

FRONT_BEFORE="$(lsappinfo front 2>/dev/null || true)"
mkdir -p "$WORK/raw"
[[ "$RAW" == 1 ]] && mkdir -p "$OUT"
for APPEARANCE in $APPEARANCES; do
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
    if [[ "$RAW" == 1 ]]; then
        cp "$RUN"/*.png "$OUT/" 2>/dev/null || true
        cp "$RUN/showcase.log" "$OUT/showcase-$APPEARANCE.log" 2>/dev/null || true
    fi
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        cat "$RUN/showcase.log" >&2 2>/dev/null || true
        fail "$APPEARANCE run timed out"
    fi
    if ! wait "$APP_PID"; then
        cat "$RUN/showcase.log" >&2 2>/dev/null || tail -20 "$RUN/stdout.log" >&2
        fail "$APPEARANCE run failed"
    fi
    cp "$RUN"/*.png "$WORK/raw/" 2>/dev/null || true
done
FRONT_AFTER="$(lsappinfo front 2>/dev/null || true)"
[[ "$FRONT_BEFORE" == "$FRONT_AFTER" ]] || echo "⚠ frontmost app changed during the run ($FRONT_BEFORE → $FRONT_AFTER)" >&2

if [[ "$RAW" == 1 ]]; then
    COUNT="$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')"
    echo "✓ $COUNT raw PNGs in $OUT"
    exit 0
fi

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
