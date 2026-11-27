#!/usr/bin/env bash
# Tests for sync-workflows.sh against a throwaway harness clone whose origin is a local bare repo.
# Usage: scripts/sync-workflows.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "$2" | sed 's/^/       /'; fails=$((fails + 1)); }
g() { git -c user.name=test -c user.email=test@example.invalid "$@"; }

# A harness clone: templates + the script, with origin/main holding one commit.
git init -q --bare -b main "$TMP/origin.git"
H="$TMP/harness"
git init -q -b main "$H"
mkdir -p "$H/scripts" "$H/templates"
cp "$HERE/sync-workflows.sh" "$H/scripts/"
cp -r "$HERE/../templates/workflows" "$H/templates/"
g -C "$H" add -A && g -C "$H" commit -qm pushed
g -C "$H" remote add origin "$TMP/origin.git" && g -C "$H" push -q origin main
PUSHED="$(git -C "$H" rev-parse HEAD)"
g -C "$H" commit -q --allow-empty -m local-only
LOCAL="$(git -C "$H" rev-parse HEAD)"

plugin() { mkdir -p "$TMP/$1" && echo '{ "name": "X", "version": "1.0.0" }' > "$TMP/$1/plugin.json" && echo "$TMP/$1"; }

# 1. A pushed commit pins test.yml and release.yml to kanboard-plugin-ci at that sha.
P="$(plugin p1)"
out="$("$H/scripts/sync-workflows.sh" --sha "$PUSHED" "$P" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "uses: carmelosantana/kanboard-plugin-ci/.github/workflows/plugin-test.yml@${PUSHED} # harness " "$P/.github/workflows/test.yml" \
   && grep -q "plugin-release.yml@${PUSHED}" "$P/.github/workflows/release.yml" \
   && grep -q 'ship-docs: false' "$P/.github/workflows/release.yml"; then
  pass "pins a commit on origin/main"
else
  fail "pins a commit on origin/main (rc=$rc)" "$out"
fi

# 2. A commit not on origin/main is refused and nothing is written.
P="$(plugin p2)"
out="$("$H/scripts/sync-workflows.sh" --sha "$LOCAL" "$P" 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'not on origin/main' <<<"$out" && [[ ! -e "$P/.github" ]]; then
  pass "refuses a commit not on origin/main (rc=$rc)"
else
  fail "refuses a commit not on origin/main (rc=$rc)" "$out"
fi

# 3. --ship-docs keeps docs/ in that plugin's zip.
P="$(plugin p3)"
out="$("$H/scripts/sync-workflows.sh" --ship-docs "$P" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'ship-docs: true' "$P/.github/workflows/release.yml" \
   && grep -q "@${PUSHED} " "$P/.github/workflows/test.yml"; then
  pass "--ship-docs, default sha is origin/main"
else
  fail "--ship-docs, default sha is origin/main (rc=$rc)" "$out"
fi

# 4. A symlinked .github, .github/workflows or workflow file is refused, and nothing is written through it.
for link in .github .github/workflows .github/workflows/test.yml; do
  P="$(plugin "p4-${link//\//-}")"; OUT="$TMP/outside-${link//\//-}"; mkdir -p "$OUT"
  mkdir -p "$P/$(dirname "$link")"
  if [[ "$link" == *.yml ]]; then : > "$OUT/test.yml"; ln -s "$OUT/test.yml" "$P/$link"; else ln -s "$OUT" "$P/$link"; fi
  out="$("$H/scripts/sync-workflows.sh" "$P" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'symlink' <<<"$out" && [[ -z "$(find "$OUT" -type f -size +0)" && ! -e "$OUT/release.yml" && ! -e "$OUT/workflows" ]]; then
    pass "refuses a symlinked $link (rc=$rc)"
  else
    fail "refuses a symlinked $link (rc=$rc)" "$out"
  fi
done

[[ $fails -eq 0 ]] && echo "sync-workflows.test.sh PASS" || { echo "sync-workflows.test.sh: $fails failed"; exit 1; }
