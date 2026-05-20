#!/usr/bin/env bash
# Build + bundle + launch.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
./scripts/bundle.sh "$CONFIG"

# Kill any prior instance so we get fresh logs.
pkill -x pgBrain 2>/dev/null || true

echo "→ Launching pgBrain.app…"
open -a "build/pgBrain.app"
