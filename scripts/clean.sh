#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .build build
echo "✓ Cleaned .build/ and build/"
