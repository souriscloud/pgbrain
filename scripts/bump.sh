#!/usr/bin/env bash
#
# Bump pgBrain's version in Resources/Info.plist.
# Reads CFBundleShortVersionString, bumps it per the kind argument, writes
# back, and also increments CFBundleVersion (the build number).
#
# Usage:
#   scripts/bump.sh patch    # 0.0.1 → 0.0.2
#   scripts/bump.sh minor    # 0.0.1 → 0.1.0
#   scripts/bump.sh major    # 0.0.1 → 1.0.0
#   scripts/bump.sh 1.2.3    # explicit
#
# Prints the new version to stdout so a calling script can capture it.

set -euo pipefail
cd "$(dirname "$0")/.."

KIND="${1:-patch}"
PLIST="Resources/Info.plist"

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")

IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"
MAJ=${MAJ:-0}; MIN=${MIN:-0}; PAT=${PAT:-0}

case "$KIND" in
    patch) PAT=$((PAT + 1));;
    minor) MIN=$((MIN + 1)); PAT=0;;
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0;;
    *)
        # Explicit version like "1.2.3"
        if [[ "$KIND" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IFS='.' read -r MAJ MIN PAT <<< "$KIND"
        else
            echo "Unknown kind: $KIND (expected patch|minor|major|X.Y.Z)" >&2
            exit 1
        fi
        ;;
esac

NEW_VERSION="${MAJ}.${MIN}.${PAT}"
NEW_BUILD=$((BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

echo "$NEW_VERSION (build $NEW_BUILD)"
