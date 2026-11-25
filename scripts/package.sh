#!/usr/bin/env bash
# package.sh <PluginDir> <OutDir>
# Build a Kanboard-plugin release zip whose single top-level folder is the
# plugin name, excluding dev-only paths (Test/, .git/). Prints the artifact path.
set -euo pipefail

SRC="${1:?usage: package.sh <PluginDir> <OutDir>}"
OUT="${2:?usage: package.sh <PluginDir> <OutDir>}"

NAME="$(basename "$SRC")"
VERSION="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$SRC/plugin.json" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ -n "$VERSION" ] || { echo "ERROR: could not read version from $SRC/plugin.json" >&2; exit 1; }

# zip follows symlinks, so one would put whatever it points at into the release: refuse.
LINKS="$(cd "$SRC" && find . -path ./.git -prune -o -type l -print)"
[ -z "$LINKS" ] || { echo "ERROR: symlinks in $NAME would be followed into the zip:" >&2; echo "$LINKS" >&2; exit 1; }

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Copy the plugin under a top-level folder = plugin name, excluding dev paths.
rsync -a --exclude '.git' --exclude 'Test' --exclude '.DS_Store' "$SRC/" "$STAGE/$NAME/"

ARTIFACT="$OUT/${NAME}-${VERSION}.zip"
rm -f "$ARTIFACT"
( cd "$STAGE" && zip -q -r "$ARTIFACT" "$NAME" )

echo "$ARTIFACT"
