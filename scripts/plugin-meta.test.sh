#!/usr/bin/env bash
# Tests for plugin-meta.sh: it prints "<name> <version>" from plugin.json only when both are safe to use in paths.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       got:  $2"; echo "       want: $3"; fails=$((fails + 1)); fi; }
meta() { mkdir -p "$T/p"; printf '%s' "$1" > "$T/p/plugin.json"; "$HERE/plugin-meta.sh" "$T/p" 2>"$T/err"; }

check "name and version" "$(meta '{ "name": "DemoPlugin", "version": "2.3.4" }')" "DemoPlugin 2.3.4"
check "a prerelease version" "$(meta '{ "name": "Harbor", "version": "2.0.0-beta.2" }')" "Harbor 2.0.0-beta.2"
check "the top-level name, not a nested one" "$(meta '{ "requires": [ { "name": "Dep" } ], "name": "Top", "version": "1.0.0" }')" "Top 1.0.0"

for bad in '"../../../home/runner/.local/bin"' '"Two Words"' '"-rf"' '"9Lives"' '""' '"a/b"'; do
  meta "{ \"name\": $bad, \"version\": \"1.0.0\" }" >/dev/null; rc=$?
  check "name $bad is refused" "$rc" "1"
done
check "the error names the field" "$(grep -c 'name' "$T/err")" "1"
for bad in '"1.0/../../x"' '"-1.0.0"' '"1.0"' '"1.0.0 x"' '"1.0.0-"' '1'; do
  meta "{ \"name\": \"Demo\", \"version\": $bad }" >/dev/null; rc=$?
  check "version $bad is refused" "$rc" "1"
done
meta '{ "version": "1.0.0" }' >/dev/null; check "a missing name is refused" "$?" "1"
meta '{ "name": "Demo", ' >/dev/null; check "malformed JSON is refused" "$?" "1"
"$HERE/plugin-meta.sh" "$T/none" >/dev/null 2>&1; check "a missing plugin.json is refused" "$?" "1"

[[ $fails -eq 0 ]] && echo "plugin-meta.test.sh PASS" || { echo "plugin-meta.test.sh: $fails failed"; exit 1; }
