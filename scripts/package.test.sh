#!/usr/bin/env bash
# Smoke test for package.sh: builds a fixture plugin zip and asserts structure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture plugin
mkdir -p "$TMP/src/DemoPlugin/Test"
cat > "$TMP/src/DemoPlugin/Plugin.php" <<'PHP'
<?php
PHP
cat > "$TMP/src/DemoPlugin/plugin.json" <<'JSON'
{ "name": "DemoPlugin", "version": "2.3.4" }
JSON
echo "junk" > "$TMP/src/DemoPlugin/Test/foo.php"

OUT="$("$HERE/package.sh" "$TMP/src/DemoPlugin" "$TMP/out")"
[ -f "$TMP/out/DemoPlugin-2.3.4.zip" ] || { echo "FAIL: expected DemoPlugin-2.3.4.zip"; exit 1; }

# Top-level entry must be DemoPlugin/, and Test/ excluded
LIST="$(unzip -Z1 "$TMP/out/DemoPlugin-2.3.4.zip")"
echo "$LIST" | grep -q '^DemoPlugin/Plugin.php$' || { echo "FAIL: missing DemoPlugin/Plugin.php"; exit 1; }
echo "$LIST" | grep -q 'Test/' && { echo "FAIL: Test/ should be excluded"; exit 1; }

# A symlink in the plugin would make zip store whatever it points at: refuse to build.
mkdir -p "$TMP/src/LinkPlugin"
echo '{ "name": "LinkPlugin", "version": "1.0.0" }' > "$TMP/src/LinkPlugin/plugin.json"
echo outside > "$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$TMP/src/LinkPlugin/link.txt"
if ERR="$("$HERE/package.sh" "$TMP/src/LinkPlugin" "$TMP/out" 2>&1)"; then
  echo "FAIL: a symlinked file must stop the build"; exit 1
fi
echo "$ERR" | grep -q 'symlink' || { echo "FAIL: the error should name the symlink: $ERR"; exit 1; }
[ ! -e "$TMP/out/LinkPlugin-1.0.0.zip" ] || { echo "FAIL: no zip may be written"; exit 1; }

echo "package.test.sh PASS"
