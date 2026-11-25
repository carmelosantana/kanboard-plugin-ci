#!/usr/bin/env bash
# Tests for ci-requires.php against a fixture directory feed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       got:  $2"; echo "       want: $3"; fails=$((fails + 1)); fi; }

cat > "$T/feed.json" <<'JSON'
[
  { "name": "Req", "homepage": "https://github.com/acme/req", "download": "https://github.com/acme/req/releases/download/v2.0.0/Req-2.0.0.zip" },
  { "name": "Rec", "homepage": "https://github.com/acme/rec/", "download": "https://github.com/acme/rec/releases/download/v1.1.0/Rec-1.1.0.zip" }
]
JSON

# requires and recommends are both checked out: tests may load a recommended plugin's classes.
cat > "$T/a.json" <<'JSON'
{ "requires": [ { "plugin": "Req", "min_version": "1.0.0" } ],
  "recommends": [ { "plugin": "Rec", "min_version": "1.0.0" }, { "plugin": "Gone" } ] }
JSON
out="$(php "$HERE/ci-requires.php" "$T/a.json" "$T/feed.json" 2>"$T/err")"; rc=$?
check "requires and listed recommends are printed" "$out" "$(printf 'Req https://github.com/acme/req.git v2.0.0\nRec https://github.com/acme/rec.git v1.1.0')"
check "an unlisted recommends only warns" "$rc" "0"
check "the warning names it" "$(grep -c 'Gone' "$T/err")" "1"

# A missing hard requirement still fails.
echo '{ "requires": [ { "plugin": "Gone" } ] }' > "$T/b.json"
php "$HERE/ci-requires.php" "$T/b.json" "$T/feed.json" >/dev/null 2>&1; rc=$?
check "an unlisted requires fails" "$rc" "1"

# A plugin both required and recommended is checked out once.
echo '{ "requires": [ { "plugin": "Req" } ], "recommends": [ { "plugin": "Req" } ] }' > "$T/c.json"
check "no duplicate checkout" "$(php "$HERE/ci-requires.php" "$T/c.json" "$T/feed.json" 2>/dev/null | wc -l | tr -d ' ')" "1"

# Names, repositories and tags reach `git clone` and a path under plugins/: anything unsafe is refused, never printed.
cat > "$T/evil-feed.json" <<'JSON'
[
  { "name": "../Escape", "homepage": "https://github.com/acme/escape", "download": "https://github.com/acme/escape/releases/download/v1.0.0/E.zip" },
  { "name": "Opt", "homepage": "--upload-pack=touch /tmp/x", "download": "https://github.com/acme/opt/releases/download/v1.0.0/O.zip" },
  { "name": "Host", "homepage": "https://evil.example/acme/host", "download": "https://github.com/acme/host/releases/download/v1.0.0/H.zip" },
  { "name": "Tag", "homepage": "https://github.com/acme/tag", "download": "https://github.com/acme/tag/releases/download/v1.0.0 --x/T.zip" },
  { "name": "Ok", "homepage": "https://github.com/acme/ok", "download": "https://github.com/acme/ok/releases/download/v1.0.0/Ok.zip" }
]
JSON
for dep in ../Escape Opt Host Tag; do
  echo "{ \"requires\": [ { \"plugin\": \"$dep\" } ] }" > "$T/e.json"
  out="$(php "$HERE/ci-requires.php" "$T/e.json" "$T/evil-feed.json" 2>"$T/err")"; rc=$?
  check "$dep: refused" "$rc" "1"
  check "$dep: nothing printed" "$out" ""
done
echo '{ "recommends": [ { "plugin": "Opt" } ], "requires": [ { "plugin": "Ok" } ] }' > "$T/f.json"
check "an unsafe recommends is skipped, the rest printed" "$(php "$HERE/ci-requires.php" "$T/f.json" "$T/evil-feed.json" 2>/dev/null)" "Ok https://github.com/acme/ok.git v1.0.0"

[[ $fails -eq 0 ]] && echo "ci-requires.test.sh PASS" || { echo "ci-requires.test.sh: $fails failed"; exit 1; }
