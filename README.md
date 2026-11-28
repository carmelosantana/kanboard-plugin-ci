# kanboard-plugin-ci

Shared CI and test runners for a suite of [Kanboard](https://kanboard.org) plugins. Each plugin
lives in its own repository and calls the reusable workflows here, so every plugin is tested and
released the same way, and local runs use the same scripts as CI.

For a walkthrough with diagrams of the test job, the release checks and the real-database
isolation, see [How kanboard-plugin-ci works](https://projects.madeinnewburgh.com/broadside/s/E3FVItyCskUSggauk8pt63NJH3H3A8ZnsiTS83TlFJw).

## What is here

| Path | What it does |
| --- | --- |
| `.github/workflows/plugin-test.yml` | Reusable workflow. It checks out Kanboard v1.2.47 and installs its dev dependencies. It then checks out the plugins named in the plugin's `requires` and `recommends`, at the release the [ModMenu directory](https://github.com/carmelosantana/kanboard-modmenu-directory) lists, and runs the plugin's PHPUnit suite. |
| `.github/workflows/plugin-release.yml` | Reusable workflow for a pushed `vX.Y.Z` tag. It checks the tag against `plugin.json`, and against any version still hard-coded in `Plugin.php`. It then builds a zip with a single top-level folder (8 MB cap) and publishes a GitHub release. |
| `templates/workflows/` | The two short files a plugin repo carries: `test.yml` for PRs and pushes to `main`, and `release.yml` for tags (test, then release). |
| `scripts/sync-workflows.sh` | Writes those templates into plugin checkouts, pinned to a commit of this repo on `origin/main`. |
| `scripts/package.sh` | Builds a release zip locally, the same shape the release workflow publishes. |
| `scripts/plugin-meta.sh` | Reads `name` and `version` from `plugin.json` and refuses values that are unsafe in a path. The release workflow and `package.sh` both use it. |
| `testing/run-plugin-tests.sh` | Runs one plugin's PHPUnit suite, or every plugin's with `--all`, against a Kanboard source checkout on in-memory SQLite. |
| `testing/run-realdb-tests.sh` | Runs one plugin's suite against a throwaway MariaDB or Postgres. Everything runs in containers on an internal network, with the sources mounted read-only and the test container capped in CPU, memory, processes and time. |
| `testing/access-map-guard.ts` | Fails when two plugins, or a plugin and core, share a controller short name. Kanboard's AccessMap keys rules by that name alone. |
| `testing/ci-requires.php`, `testing/ci-phpunit.sh` | Helpers for `plugin-test.yml`. |

## Calling it from a plugin

`.github/workflows/test.yml` in the plugin repo:

```yaml
name: test
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  test:
    uses: carmelosantana/kanboard-plugin-ci/.github/workflows/plugin-test.yml@<commit sha>
```

Pin a full commit SHA, never a branch. `scripts/sync-workflows.sh <PluginDir>...` writes both
files with the pin filled in (`--ship-docs` keeps `docs/` in that plugin's zip). It only writes
files: review, commit and open the PR in each plugin repo yourself.

The plugin's directory name comes from the `namespace Kanboard\Plugin\X;` line in its `Plugin.php`.
A plugin that `requires` a private repository cannot be tested here: dependencies are cloned
without credentials.

## Running the tests locally

The scripts find plugins and Kanboard in one of two layouts:

- **Standalone:** plugin checkouts sit next to this repo's own files.
- **Nested:** this repo is cloned as `./harness` inside a directory of plugin checkouts.

In both layouts, `testing/kanboard-src` holds the Kanboard source.

```bash
git clone --depth 1 --branch v1.2.47 https://github.com/kanboard/kanboard.git testing/kanboard-src
composer install -d testing/kanboard-src

testing/run-plugin-tests.sh MyPlugin        # one suite
testing/run-plugin-tests.sh --all           # every suite, then a pass/fail table
testing/run-realdb-tests.sh MyPlugin postgres
```

Environment overrides: `PLUGINS_ROOT` (where plugin checkouts live), `KB_SRC` (the Kanboard
source), `LOG_DIR` (`--all` logs), and `ACCESS_MAP_WAIVERS`, a JSON file with more access-map
waivers in the same `{name, parties, reason}` shape as the built-in list.

This repo's own tests run in `harness-test.yml`:

```bash
testing/run-plugin-tests.test.sh
node --test testing/access-map-guard.test.ts    # Node 22.18+
testing/ci-requires.test.sh
scripts/package.test.sh
scripts/sync-workflows.test.sh
scripts/plugin-meta.test.sh
```

## License

MIT
