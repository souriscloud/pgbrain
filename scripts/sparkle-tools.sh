#!/usr/bin/env bash
#
# sparkle-tools.sh — Locate and run Sparkle CLI tools from the SPM build.
#
# Usage:  ./scripts/sparkle-tools.sh <tool> [args...]
# Tools:  generate_keys | sign_update | generate_appcast | BinaryDelta
#
# pgBrain is an SwiftPM-only project (no Xcode workspace), so the Sparkle
# binaries live under `.build/artifacts/sparkle/...` rather than the
# DerivedData path VirtualMirror's helper looks at. Build the project once
# (`swift build`) and the Sparkle dependency is resolved + extracted.

set -euo pipefail
cd "$(dirname "$0")/.."

TOOL="${1:-}"
if [[ -z "$TOOL" ]]; then
    echo "Usage: $0 <tool> [args...]"
    echo "Tools: generate_keys, sign_update, generate_appcast, BinaryDelta"
    exit 1
fi
shift

CANDIDATES=(
    ".build/artifacts/sparkle/Sparkle/bin/$TOOL"
    ".build/artifacts/Sparkle/Sparkle/bin/$TOOL"
    ".build/checkouts/Sparkle/$TOOL"
)

BIN=""
for path in "${CANDIDATES[@]}"; do
    if [[ -x "$path" ]]; then BIN="$path"; break; fi
done

if [[ -z "$BIN" ]]; then
    if command -v "$TOOL" >/dev/null 2>&1; then
        BIN="$TOOL"
    else
        echo "ERROR: Sparkle tool '$TOOL' not found." >&2
        echo "Run 'swift build' once to fetch the Sparkle dependency, then try again." >&2
        exit 1
    fi
fi

exec "$BIN" "$@"
