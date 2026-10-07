#!/bin/bash
# Build the shared Souris.CLOUD installer without opening Finder.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${PGBRAIN_DMG_APP:-build/pgBrain.app}"
[ -d "$APP" ] || { echo "Run scripts/bundle.sh release first" >&2; exit 1; }
exec ./scripts/installer/build.sh "$APP" "${1:-build/pgBrain.dmg}"
