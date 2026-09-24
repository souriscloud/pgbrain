#!/usr/bin/env bash
#
# Automated smoke test of the whole app, through the off-screen showcase
# harness: every `smoke-*` scene drives a real window against throwaway
# databases, asserts the outcome and captures a PNG.
#
#   scripts/smoke.sh [smoke-scene,…]     (default: every smoke scene)
#
# Same guarantees as scripts/screenshots.sh — nothing on screen, no focus
# change, no Keychain, no real app data or preferences. Output (raw light
# PNGs + showcase-light.log) goes to a temp directory printed at the end.
# Exits non-zero if any smoke scene fails.

set -euo pipefail
cd "$(dirname "$0")/.."

DB="${PGBRAIN_SMOKE_DB:-pgbrain_smoke}"
OUT="$(mktemp -d -t pgbrain-smoke)"
PREFS_BEFORE="$(mktemp -t pgbrain-prefs)"
PREFS_AFTER="$(mktemp -t pgbrain-prefs)"

cleanup() {
    local status=$?
    dropdb --if-exists --force "${DB}_b" 2>/dev/null || echo "⚠ could not drop ${DB}_b — drop it by hand" >&2
    rm -f "$PREFS_BEFORE" "$PREFS_AFTER"
    echo "  smoke output: $OUT"
    exit $status
}
trap cleanup EXIT INT TERM

# A second database on the same server, for the database switcher scene.
dropdb --if-exists --force "${DB}_b" 2>/dev/null || true
createdb "${DB}_b"
psql -X -q -v ON_ERROR_STOP=1 -d "${DB}_b" \
    -c "CREATE TABLE sibling_only (id int PRIMARY KEY, label text); INSERT INTO sibling_only VALUES (1, 'from b');" >/dev/null

defaults export cloud.souris.pgbrain - >"$PREFS_BEFORE" 2>/dev/null || true

status=0
PGBRAIN_SHOWCASE_DB="$DB" \
PGBRAIN_SHOWCASE_OUT="$OUT" \
PGBRAIN_SHOWCASE_APPEARANCES="light" \
PGBRAIN_SHOWCASE_RAW=1 \
PGBRAIN_SHOWCASE_NO_CLIENTS=1 \
PGBRAIN_SHOWCASE_EXTRA_SEED="scripts/showcase/smoke-seed.sql" \
    ./scripts/screenshots.sh "${1:-smoke-*}" || status=$?

defaults export cloud.souris.pgbrain - >"$PREFS_AFTER" 2>/dev/null || true
if ! cmp -s "$PREFS_BEFORE" "$PREFS_AFTER"; then
    echo "✗ the run changed the real cloud.souris.pgbrain preferences" >&2
    status=1
fi

LOG="$OUT/showcase-light.log"
if [[ -f "$LOG" ]]; then
    grep -E '^(scene |  ✗|FAILED|ABORT)' "$LOG" || true
fi
if [[ $status -ne 0 ]]; then
    echo "✗ smoke test failed" >&2
    exit $status
fi
echo "✓ smoke test passed"
