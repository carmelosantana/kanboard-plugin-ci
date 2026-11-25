#!/usr/bin/env bash
# run-realdb-tests.sh — Run one plugin's PHPUnit suite against a real MariaDB or Postgres.
#
# Usage:
#   testing/run-realdb-tests.sh <PluginName> mariadb|postgres
#
# The plugin is <PLUGINS_ROOT>/<PluginName>; PLUGINS_ROOT and KB_SRC default as in run-plugin-tests.sh.
#
# Starts a throwaway database container (official image, pinned by digest, data on tmpfs, no host files mounted) and
# runs testing/run-plugin-tests.sh <PluginName> with DB_DRIVER=mysql|postgres in a throwaway PHP container built
# from the kb-suite dev image (stock Kanboard plus sodium; it has pdo_mysql and pdo_pgsql, which the host PHP may
# lack) plus php84-tokenizer and opcache.save_comments=1 for PHPUnit. Both share an internal Docker network (no route out)
# and are removed afterwards. Only testing/run-plugin-tests.sh, the Kanboard source (KB_SRC) and the plugin are mounted, all
# read-only (so is kanboard-src/.git: nothing in the container can plant a hook that later runs on the host). The
# paths a run regenerates, kanboard-src/tests/plugin-bootstrap.php and PHPUnit's tests/.phpunit.result.cache, are
# throwaway host files mounted over them. No .env file of the host reaches the container, which a preflight in the
# container checks before the suite runs. Exit code: the suite's (97: preflight).
#
# Env: KB_IMAGE (default: built here from testing/Dockerfile.sodium, whose base is pinned by digest).
#      REALDB_TIMEOUT (default 1800): seconds before the test container is killed. The container is also capped at
#      2 CPUs, 2 GB of memory (no extra swap) and 1024 processes, so a hostile or runaway suite cannot take the host down.
#      REALDB_SUBNET (default 10.213.77.0/24): the test network's private subnet, given explicitly so the run works
#      when Docker's default address pools are exhausted. If it is taken, a few random 10.213.N.0/24 subnets are
#      tried, then Docker's own pool. No other network is touched.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The same defaults as run-plugin-tests.sh (keep the two blocks in step).
MAIN_ROOT="$HARNESS_ROOT"
common_dir="$(git -C "$HARNESS_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ -n "$common_dir" ]] && MAIN_ROOT="$(dirname "$common_dir")"
default_plugins_root="$(dirname "$HARNESS_ROOT")"
for dir in "$HARNESS_ROOT" "$MAIN_ROOT" "$(dirname "$HARNESS_ROOT")" "$(dirname "$MAIN_ROOT")"; do
  if compgen -G "${dir}/*/plugin.json" > /dev/null; then default_plugins_root="$dir"; break; fi
done
PLUGINS_ROOT="$(cd "${PLUGINS_ROOT:-$default_plugins_root}" && pwd)"
default_kb_src="${PLUGINS_ROOT}/testing/kanboard-src"
for dir in "$HARNESS_ROOT" "$MAIN_ROOT" "$(dirname "$HARNESS_ROOT")" "$(dirname "$MAIN_ROOT")"; do
  if [[ -d "${dir}/testing/kanboard-src/vendor" ]]; then default_kb_src="${dir}/testing/kanboard-src"; break; fi
done
KB_SRC="$(cd "${KB_SRC:-$default_kb_src}" && pwd)"
PLUGIN="${1:-}"
ENGINE="${2:-}"
KB_IMAGE="${KB_IMAGE:-}"
MARIADB_IMAGE='mariadb:11.4@sha256:611a2fcc5fa7c6ceb8644c6f74b25ede004ff6c3a6b38c8f8c23d3bbf6c26430'
POSTGRES_IMAGE='postgres:17-alpine@sha256:eee6c6e1b0894fa4fe0075eb054af9fd1cf39a35321c2d4110626cfe506411fb'

if [[ -z "$PLUGIN" || ! -f "${PLUGINS_ROOT}/${PLUGIN}/plugin.json" || ! "$ENGINE" =~ ^(mariadb|postgres)$ ]]; then
  echo "Usage: $0 <PluginName> mariadb|postgres"
  exit 1
fi

id="realdb-$$-$RANDOM"
net="$id-net"
db="$id-db"
php_ctr="$id-php"
password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
scratch="$(mktemp -d)"
cleanup() {
  docker rm -f -v "$php_ctr" "$db" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

# An explicit --subnet first (the host's default pools can be fully subnetted), then random neighbours if another
# network already holds it, then Docker's default pool as a last resort.
subnets=("${REALDB_SUBNET:-10.213.77.0/24}")
for _ in 1 2 3 4 5 6 7 8; do subnets+=("10.213.$((RANDOM % 254 + 1)).0/24"); done
created=
# --internal drops the default route; gateway mode "isolated" (Docker 28+) also leaves the host without an address on
# the bridge, so tests cannot reach services listening on the host either. Older engines would ignore the option.
engine="$(docker version --format '{{.Server.Version}}')"
if (( ${engine%%.*} < 28 )); then
  echo "ERROR: Docker Engine $engine cannot isolate the test network from the host (needs 28+)." >&2
  exit 1
fi
for subnet in "${subnets[@]}" ''; do
  if docker network create --internal -o com.docker.network.bridge.gateway_mode_ipv4=isolated \
      ${subnet:+--subnet "$subnet"} "$net" >/dev/null 2>"${scratch}/net.err"; then
    created=1
    break
  fi
done
if [[ -z "$created" ]]; then
  echo "ERROR: could not create the test network (tried ${subnets[*]} and the default pool):" >&2
  cat "${scratch}/net.err" >&2
  exit 1
fi
if [[ "$ENGINE" == mariadb ]]; then
  docker run -d --name "$db" --network "$net" --tmpfs /var/lib/mysql:rw \
    -e MARIADB_ROOT_PASSWORD="$password" -e MARIADB_DATABASE=kanboard_unit_test "$MARIADB_IMAGE" >/dev/null
  ready=(healthcheck.sh --connect --innodb_initialized)
  env=(-e DB_DRIVER=mysql -e DB_HOSTNAME="$db" -e DB_USERNAME=root -e DB_PASSWORD="$password")
else
  # Kanboard's units.postgres.xml fixes the user and password to postgres; the server is reachable only on $net.
  docker run -d --name "$db" --network "$net" --tmpfs /var/lib/postgresql/data:rw \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=kanboard_unit_test "$POSTGRES_IMAGE" >/dev/null
  ready=(pg_isready -U postgres -h 127.0.0.1)
  env=(-e DB_DRIVER=postgres -e DB_HOSTNAME="$db")
fi
for _ in $(seq 1 90); do
  docker exec "$db" "${ready[@]}" >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$db" "${ready[@]}" >/dev/null
echo "$ENGINE ready ($([[ "$ENGINE" == mariadb ]] && echo "$MARIADB_IMAGE" || echo "$POSTGRES_IMAGE")); running $PLUGIN with DB_DRIVER=${env[1]#DB_DRIVER=}"

# The Kanboard-plus-sodium base, unless KB_IMAGE names one: built from stdin (no build context).
if [[ -z "$KB_IMAGE" ]]; then
  KB_IMAGE=realdb-kb-sodium:local
  docker build -q -t "$KB_IMAGE" - < "${HARNESS_ROOT}/testing/Dockerfile.sodium" >/dev/null
fi

# PHPUnit needs ext-tokenizer, which the Kanboard image leaves out (Alpine package, same repository as php84-sodium),
# and doc comments: the image sets opcache.save_comments=0, which hides @dataProvider from PHPUnit. No memory cap: the
# image's 128M is a web-request limit, and big suites (Steward peaks near 118 MB) outgrow it.
php_image=realdb-php:local
docker build -q -t "$php_image" - >/dev/null <<DOCKERFILE
FROM $KB_IMAGE
RUN apk add --no-cache php84-tokenizer && printf 'opcache.save_comments=1\\nmemory_limit=-1\\n' > /etc/php84/conf.d/zz-realdb-tests.ini
DOCKERFILE

# Preflight, inside the PHP container before the suite: no host secret is visible (no file named .env, .env.<x> or
# <x>.env under any mounted root: plugins, harness, Kanboard source; only names are listed, nothing is read, and a scan
# error fails), there is no default route (the network is --internal and its gateway isolated: the suite reaches the
# database and nothing else), and kanboard-src and its .git can't be written. Exit 97 on a breach, before any test runs.
preflight='leak="$(find "$PLUGINS_ROOT" "$HARNESS_ROOT" "$KB_SRC" \( -name .env -o -name ".env.*" -o -name "*.env" \) -print -quit)" || { echo "preflight: the .env scan failed" >&2; exit 97; }
if test -n "$leak"; then echo "preflight: ${leak#"$PLUGINS_ROOT"/} (a .env file) is visible in the container" >&2; exit 97; fi
if awk '"'"'NR > 1 && $2 == "00000000" { found = 1 } END { exit !found }'"'"' /proc/net/route; then echo "preflight: the container has a default route (egress)" >&2; exit 97; fi
for d in "$KB_SRC" "$KB_SRC/.git"; do if touch "$d/.realdb-write-probe" 2>/dev/null; then rm -f "$d/.realdb-write-probe"; echo "preflight: $d is writable" >&2; exit 97; fi; done
echo "preflight: no .env files, no default route, kanboard-src and its .git read-only"'

# The read-only tree needs, on the host, the plugin's symlink and the mount points of the regenerated files.
kb_src="$KB_SRC"
[[ -e "${kb_src}/plugins/${PLUGIN}" ]] || ln -s "${PLUGINS_ROOT}/${PLUGIN}" "${kb_src}/plugins/${PLUGIN}"
for f in plugin-bootstrap.php .phpunit.result.cache; do
  [[ -e "${kb_src}/tests/$f" ]] || : > "${kb_src}/tests/$f"
  : > "${scratch}/$f"
done

# Named, so cleanup removes it even when the client is killed (timeout, Ctrl-C) before --rm runs.
timeout --foreground --kill-after=30 "${REALDB_TIMEOUT:-1800}" \
docker run --rm --name "$php_ctr" --network "$net" --user "$(id -u):$(id -g)" --entrypoint bash \
  --cpus 2 --memory 2g --memory-swap 2g --pids-limit 1024 \
  -v "${HARNESS_ROOT}/testing/run-plugin-tests.sh:${HARNESS_ROOT}/testing/run-plugin-tests.sh:ro" \
  -v "${kb_src}:${kb_src}:ro" \
  -v "${scratch}/plugin-bootstrap.php:${kb_src}/tests/plugin-bootstrap.php:rw" \
  -v "${scratch}/.phpunit.result.cache:${kb_src}/tests/.phpunit.result.cache:rw" \
  -v "${PLUGINS_ROOT}/${PLUGIN}:${PLUGINS_ROOT}/${PLUGIN}:ro" \
  -e HOME=/tmp -e PLUGINS_ROOT="$PLUGINS_ROOT" -e KB_SRC="$KB_SRC" -e HARNESS_ROOT="$HARNESS_ROOT" "${env[@]}" \
  -w "$PLUGINS_ROOT" "$php_image" -c "$preflight"' && exec "$0" "$1"' \
  "${HARNESS_ROOT}/testing/run-plugin-tests.sh" "$PLUGIN"
