#!/usr/bin/env bash
# plugin-meta.sh <PluginDir> — print "<name> <version>" from <PluginDir>/plugin.json.
#
# Both end up in paths (the zip's top folder, <name>-<version>.zip), so each must be safe there: the name is a PHP
# namespace segment (^[A-Za-z][A-Za-z0-9_]*$) and the version is X.Y.Z with an optional -prerelease or +build suffix.
# Anything else, a missing field or malformed JSON exits 1. Used by package.sh and plugin-release.yml.
set -euo pipefail

json="${1:?usage: plugin-meta.sh <PluginDir>}/plugin.json"
[[ -f "$json" ]] || { echo "ERROR: no $json" >&2; exit 1; }
if ! read -r name version < <(jq -r 'if (.name|type) == "string" and (.version|type) == "string"
                                     then "\(.name) \(.version)" else empty end' "$json" 2>/dev/null); then
  echo "ERROR: $json needs string fields name and version" >&2; exit 1
fi
[[ "$name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { echo "ERROR: plugin.json name '$name' is not a plugin name ([A-Za-z][A-Za-z0-9_]*)" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
  || { echo "ERROR: plugin.json version '$version' is not X.Y.Z[-pre]" >&2; exit 1; }
echo "$name $version"
