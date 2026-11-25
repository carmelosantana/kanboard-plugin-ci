#!/usr/bin/env bash
# Tests for run-plugin-tests.sh against a throwaway Kanboard tree that borrows the real
# vendor/ (so PHPUnit is real) and fixture plugins, so nothing under the shared
# testing/kanboard-src/plugins is touched.
#
# Usage: testing/run-plugin-tests.test.sh   (needs testing/kanboard-src with vendor/, or KB_SRC)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-plugin-tests.sh"
REAL_KB="${KB_SRC:-}"
if [[ -z "$REAL_KB" ]]; then
  REAL_KB="$HERE/kanboard-src"
  if [[ ! -d "$REAL_KB/vendor" ]]; then
    common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [[ -n "$common" ]] && REAL_KB="$(dirname "$common")/testing/kanboard-src"
  fi
  # The harness cloned into a workspace as ./harness: the workspace's testing/kanboard-src.
  [[ -d "$REAL_KB/vendor" ]] || REAL_KB="$(cd "$HERE/../.." && pwd)/testing/kanboard-src"
  [[ -d "$REAL_KB/vendor" || -z "$common" ]] || REAL_KB="$(dirname "$(dirname "$common")")/testing/kanboard-src"
fi
[[ -x "$REAL_KB/vendor/bin/phpunit" ]] || { echo "SKIP: no PHPUnit under $REAL_KB"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; echo "$2" | sed 's/^/       /'; fails=$((fails + 1)); }

# Throwaway Kanboard: real vendor/ and tests/units, our own plugins/.
KB="$TMP/kb"
mkdir -p "$KB/tests" "$KB/plugins"
ln -s "$REAL_KB/vendor" "$KB/vendor"
ln -s "$REAL_KB/app" "$KB/app"
cp "$REAL_KB/tests/units.sqlite.xml" "$KB/tests/units.sqlite.xml"

# make_plugin <dir> <marker>: a plugin whose suite has 4 tests; test 1 fails, testMarker
# passes only when marker.txt says "worktree", and testAssetPath needs <Kanboard>/plugins/<Name>
# to exist (Kanboard's AssetHelper stats plugin assets there, ignoring PLUGINS_DIR).
make_plugin() {
  mkdir -p "$1/Test"
  echo '{ "name": "RptFixture", "version": "1.0.0" }' > "$1/plugin.json"
  printf '<?php\nnamespace Kanboard\\Plugin\\RptFixture;\nclass Plugin {}\n' > "$1/Plugin.php"
  echo "$2" > "$1/marker.txt"
  cat > "$1/Test/FixtureTest.php" <<'PHP'
<?php
use PHPUnit\Framework\TestCase;
class FixtureTest extends TestCase
{
    public function testAFails(): void { $this->assertTrue(false); }
    public function testBPasses(): void { $this->assertTrue(true); }
    public function testMarker(): void
    {
        $this->assertSame('worktree', trim(file_get_contents(__DIR__ . '/../marker.txt')));
    }
    public function testAssetPath(): void
    {
        $this->assertFileExists(getcwd() . '/plugins/RptFixture/marker.txt');
    }
}
PHP
}

ROOT="$TMP/root"
make_plugin "$ROOT/RptFixture" main
make_plugin "$TMP/wt/fixture-branch" worktree

run() { PLUGINS_ROOT="$ROOT" KB_SRC="$KB" "$RUNNER" "$@" 2>&1; }

# 1. A failing test must not stop the run: PHPUnit reports all 4 tests, and on a fresh
#    Kanboard tree the asset path resolves (only testAFails and testMarker fail).
out="$(run RptFixture)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qE 'Tests: 4, Assertions: 4, Failures: 2\.' <<<"$out"; then
  pass "full test count after a failure (rc=$rc)"
else
  fail "full test count after a failure (rc=$rc)" "$out"
fi

# 2. A path argument tests that checkout (a worktree) in place of PLUGINS_ROOT/<Name>.
out="$(run "$TMP/wt/fixture-branch")"
if grep -q "Source        : $TMP/wt/fixture-branch" <<<"$out" \
   && grep -qE 'Tests: 4, Assertions: 4, Failures: 1\.' <<<"$out"; then
  pass "path argument runs the worktree's code"
else
  fail "path argument runs the worktree's code" "$out"
fi

# 3. Existing links in the shared kanboard-src/plugins/ are never repointed, even by a path run.
link="$(readlink "$KB/plugins/RptFixture" || true)"
if [[ "$link" == "$ROOT/RptFixture" ]]; then
  pass "shared plugins/ link created once, not repointed ($link)"
else
  fail "shared plugins/ link created once, not repointed" "link=$link"
fi

# 4. --all reports the full count in its table too.
out="$(LOG_DIR="$TMP/logs" run --all)"
if grep -qE 'RptFixture +\| FAIL +\| Tests: 4,' <<<"$out"; then
  pass "--all table shows the full count"
else
  fail "--all table shows the full count" "$out"
fi
if grep -qE 'access-map-guard +\| PASS' <<<"$out"; then
  pass "--all runs the access-map guard"
else
  fail "--all runs the access-map guard" "$out"
fi

# 4b. A controller short name shared by two plugins fails --all through the guard row.
CLASH="$TMP/clash"
for p in ClashA ClashB; do
  mkdir -p "$CLASH/$p/Controller"
  echo "{ \"name\": \"$p\" }" > "$CLASH/$p/plugin.json"
  printf '<?php\nnamespace Kanboard\\Plugin\\%s;\nclass Plugin {}\n' "$p" > "$CLASH/$p/Plugin.php"
  printf '<?php\nnamespace Kanboard\\Plugin\\%s\\Controller;\nclass SettingsController {}\n' "$p" > "$CLASH/$p/Controller/SettingsController.php"
done
out="$(PLUGINS_ROOT="$CLASH" KB_SRC="$KB" LOG_DIR="$TMP/clash-logs" "$RUNNER" --all 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qE 'access-map-guard +\| FAIL' <<<"$out" \
   && grep -q 'settingscontroller — ClashA, ClashB' "$TMP/clash-logs/access-map-guard.log"; then
  pass "--all fails on a shared controller name (rc=$rc)"
else
  fail "--all fails on a shared controller name (rc=$rc)" "$out"
fi

# 5. Run from a linked harness worktree with no kanboard-src: falls back to the main one.
if [[ "$(git -C "$HERE" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)" \
      && ! -d "$HERE/kanboard-src" ]]; then
  out="$(PLUGINS_ROOT="$ROOT" "$RUNNER" --list 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]] && grep -qx RptFixture <<<"$out"; then
    pass "linked worktree finds the main checkout's kanboard-src"
  else
    fail "linked worktree finds the main checkout's kanboard-src" "$out"
  fi
  out="$(PLUGINS_ROOT="$ROOT" "$RUNNER" RptFixture 2>&1)"
  if grep -q "Kanboard root : $REAL_KB" <<<"$out"; then
    pass "linked worktree uses $REAL_KB"
  else
    fail "linked worktree uses $REAL_KB" "$out"
  fi
  rm -f "$REAL_KB/plugins/RptFixture"   # the fallback run linked the fixture there
else
  echo "skip - linked-worktree fallback (not run from a linked worktree)"
fi

# 6. ci-phpunit.sh (the CI step) exits with PHPUnit's status, not tee's, and writes the count
#    to the job summary. A plain `| tee` under `bash -e` once turned a failing suite green.
summary="$TMP/summary.md"; : > "$summary"
out="$(PLUGINS_ROOT="$ROOT" KB_SRC="$KB" GITHUB_STEP_SUMMARY="$summary" bash "$HERE/ci-phpunit.sh" RptFixture 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'RptFixture PHPUnit: Tests: 4, Assertions: 4, Failures: 2\.' "$summary"; then
  pass "ci-phpunit.sh fails with the suite and writes the summary (rc=$rc)"
else
  fail "ci-phpunit.sh fails with the suite and writes the summary (rc=$rc)" "$out
summary: $(cat "$summary")"
fi

# 7. run-realdb-tests.sh mounts kanboard-src read-only, with only plugin-bootstrap.php writable.
#    The runner must not write anything else under <Kanboard>/tests.
RO="$TMP/ro-kb"
mkdir -p "$RO/tests" "$RO/plugins"
ln -s "$REAL_KB/vendor" "$RO/vendor"
ln -s "$REAL_KB/app" "$RO/app"
cp "$REAL_KB/tests/units.sqlite.xml" "$RO/tests/units.sqlite.xml"
: > "$RO/tests/plugin-bootstrap.php"
ln -s "$ROOT/RptFixture" "$RO/plugins/RptFixture"
chmod a-w "$RO/tests" "$RO/plugins"
out="$(PLUGINS_ROOT="$ROOT" KB_SRC="$RO" "$RUNNER" RptFixture 2>&1)"
chmod u+w "$RO/tests" "$RO/plugins"
if grep -qE 'Tests: 4, Assertions: 4, Failures: 2\.' <<<"$out"; then
  pass "read-only <Kanboard>/tests (as run-realdb-tests.sh mounts it)"
else
  fail "read-only <Kanboard>/tests (as run-realdb-tests.sh mounts it)" "$out"
fi

# 8. Nested layout: the harness is its own checkout at <root>/harness, plugins and
#    testing/kanboard-src sit in <root>. With no PLUGINS_ROOT or KB_SRC set, the runner finds both.
N="$TMP/nested"
make_plugin "$N/RptFixture" worktree
mkdir -p "$N/testing/kanboard-src/tests" "$N/testing/kanboard-src/plugins" "$N/harness/testing"
ln -s "$REAL_KB/vendor" "$N/testing/kanboard-src/vendor"
ln -s "$REAL_KB/app" "$N/testing/kanboard-src/app"
cp "$REAL_KB/tests/units.sqlite.xml" "$N/testing/kanboard-src/tests/units.sqlite.xml"
cp "$RUNNER" "$HERE/access-map-guard.ts" "$N/harness/testing/"
git init -q "$N/harness"
out="$(env -u PLUGINS_ROOT -u KB_SRC "$N/harness/testing/run-plugin-tests.sh" RptFixture 2>&1)"
if grep -q "Kanboard root : $N/testing/kanboard-src" <<<"$out" \
   && grep -qE 'Tests: 4, Assertions: 4, Failures: 1\.' <<<"$out"; then
  pass "nested harness checkout finds <root> plugins and kanboard-src"
else
  fail "nested harness checkout finds <root> plugins and kanboard-src" "$out"
fi
out="$(env -u PLUGINS_ROOT -u KB_SRC LOG_DIR="$TMP/nested-logs" "$N/harness/testing/run-plugin-tests.sh" --all 2>&1)"
if grep -qE 'access-map-guard +\| PASS' <<<"$out"; then
  pass "nested --all runs the guard from the harness checkout"
else
  fail "nested --all runs the guard from the harness checkout" "$out"
fi

# 9. A linked worktree of a nested harness, outside the workspace: plugins come from the main
#    checkout's workspace, not the worktree's parent.
git -C "$N/harness" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$N/harness" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
git -C "$N/harness" worktree add -q --detach "$TMP/outside/wt" HEAD
out="$(env -u PLUGINS_ROOT -u KB_SRC "$TMP/outside/wt/testing/run-plugin-tests.sh" --list 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -qx RptFixture <<<"$out"; then
  pass "nested harness worktree finds the workspace's plugins"
else
  fail "nested harness worktree finds the workspace's plugins (rc=$rc)" "$out"
fi

# 10. --all with no plugins at all is a failure, not an empty green table.
mkdir -p "$TMP/empty"
out="$(PLUGINS_ROOT="$TMP/empty" KB_SRC="$KB" LOG_DIR="$TMP/empty-logs" "$RUNNER" --all 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'no plugins' <<<"$out"; then
  pass "--all fails when it finds no plugins (rc=$rc)"
else
  fail "--all fails when it finds no plugins (rc=$rc)" "$out"
fi

[[ $fails -eq 0 ]] && echo "run-plugin-tests.test.sh PASS" || { echo "run-plugin-tests.test.sh: $fails failed"; exit 1; }
