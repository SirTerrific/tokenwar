---
type: testing
title: Test suite and CI
description: bats test layout, mocking conventions, SQLite fixtures, running the suite on Windows in both MSYS modes, act, and the GitHub workflows.
tags: [tests, bats, ci, github-actions, windows, act, openwiki]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-164e2da859b5277df81c7d94
    resource: repo://.github/workflows/ci.yml
  - id: openwiki-source-6d4b4e707b8d60b6ccfa3425
    resource: repo://.github/workflows/openwiki-update.yml
  - id: openwiki-source-393eb6db4d0e8f351ac6d2ad
    resource: repo://tests/gain.bats
  - id: openwiki-source-9666ee7208c6e3243cdfb1e6
    resource: repo://tests/history.bats
  - id: openwiki-source-44ae2da287d0f1976ea724ce
    resource: repo://tests/sqlite_helper.bash
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Test suite and CI

tokenwar is tested with [bats](https://github.com/bats-core/bats-core). The
suite has **24 `.bats` files and 287 tests** in `tests/`, plus one Node test
(`tests/history.test.mjs`) that `tests/history.bats` runs with `node --test`.

## Layout

Each script has its own test file: `gain.bats`, `status.bats`,
`check-updates.bats`, `upgrade.bats`, `rtk-update.bats`, `install.bats`,
`pxpipe-claude.bats`, `pxpipe-desktop.bats`, `scan.bats`, `parse.bats`,
`providers.bats`, `windows.bats`, and so on. Cross-cutting behaviour has its own
files as well, for example `upgrade-answers.bats` (interactive prompt handling),
`status-fallback.bats` and `opencode-functional.bats`.

## Conventions

Tests never touch the real machine:

- `setup()` points `HOME` at a fresh `mktemp -d` directory and puts a `MOCK_BIN`
  directory first on `PATH`. `teardown()` deletes both and restores the
  original `PATH`.
- External tools (`rtk`, `claude`, `npm`, `curl`, `pxpipe`, `graphify`,
  `node`, …) are replaced by small shell stubs written into `MOCK_BIN`.
  Helpers such as `mock_rtk`, `mock_claude_with_plugins`, `mock_pxpipe_alive`
  and `mock_copilot` create them. Many stubs log their arguments to a file, so
  a test can check exactly which commands ran.
- Network lookups are redirected through environment overrides (registry URLs,
  `TW_CHECK_UPDATES`, `TW_GRAPHIFY_PYPI_URL`, …) to local fixtures or to
  "unreachable", so the suite runs offline.
- Behaviour that is specific to an OS is pinned with `TW_FORCE_OS` (see
  [Windows support](../platform/windows.md)), so both branches run everywhere.

### SQLite fixtures — `tests/sqlite_helper.bash`

`make_sqlite_db <db> <schema+inserts>` builds a fixture database for the
telemetry tests (claude-mem, context-mode, Codex, opencode, Copilot). It uses
whichever engine the host has, in the same order the scripts read data:
`python3` first, then Node's `node:sqlite`. The Python probe actually imports
`sqlite3`, because the `python3` on Windows is often the Microsoft Store alias.
When neither engine is available, the tests that need a fixture are skipped
rather than failed.

## Running locally

```bash
bats tests/                  # whole suite
bats tests/gain.bats         # one file
```

On Windows, set a UTF-8 locale and also run the suite with path conversion
disabled, the same way CI does:

```bash
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
bats tests/
MSYS_NO_PATHCONV=1 bats tests/
```

The locale is required, not cosmetic. Several test names contain an em dash.
Under the default C locale on Windows, bats does not recognise those names and
silently runs only the ASCII-named tests, while still exiting 0.

Process spawning is much slower under Git Bash than on Linux, so a full Windows
run takes several minutes. Run only one suite at a time: two concurrent runs
produce results that are mixed up and hard to read.

`act` can run the Linux job locally (`act push -j test`).

## CI — `.github/workflows/ci.yml`

| Job | Runner | Steps |
| --- | ------ | ----- |
| `test` | `ubuntu-latest` | Install bats and shellcheck → `shellcheck` every `.sh` → `bats tests/` → smoke run of the statusline and `gain` → JSON contract smoke |
| `test-windows` | `windows-latest`, shell `bash` (Git Bash), `LANG`/`LC_ALL` = `en_US.UTF-8` | Check that no CRLF reached the shell sources → `shellcheck` → `bats tests/` → `bats tests/` again with `MSYS_NO_PATHCONV: 1` → the same smoke checks |

The Windows job sets `MSYS: winsymlinks:nativestrict` so that `ln -s` creates
real links instead of silent copies.

It also runs the suite twice: once normally and once with
`MSYS_NO_PATHCONV=1`. MSYS normally rewrites path-like arguments when it starts
a native program. Users who disable that rewrite would otherwise hit silent
failures: for example, `node.exe` cannot read a file because it received a POSIX
path, and an unreadable `settings.json` then looks identical to an absent one.

The **JSON contract smoke** step runs `status --json` and `gain --json` and
asserts that every managed tool (context-mode, claude-mem, rtk, caveman,
ponytail, pxpipe, graphify) and every registered provider appears in the
output. This catches a tool that was added to the text output but left out of
the JSON. Exit codes are ignored on purpose, because a bare runner has none of
the tools installed. The step only checks the shape of the output.

The workflow runs on a push to any branch (this fork is a solo working copy, so
feature branches are never opened as pull requests), on pull requests to `main`,
and when started manually.

## OpenWiki — `.github/workflows/openwiki-update.yml`

This workflow keeps this wiki current. It runs every day at 08:00 UTC and can
also be started manually (`workflow_dispatch`). It needs
`contents: write` and `pull-requests: write`. The steps are:

1. Check out the full history and set up Node. All actions are pinned by commit
   SHA.
2. Install `openwiki@0.7.0` together with the Mermaid tooling it needs to
   validate diagrams.
3. Run `openwiki code --update --print`, using the provider and model set in
   the workflow (`OPENWIKI_PROVIDER`, `OPENWIKI_MODEL_ID`). API keys come from
   repository secrets.
4. Remove the transient `openwiki/.run.json` and open (or update) a pull
   request with the changed pages through `peter-evans/create-pull-request`.
5. If the OpenWiki step failed, mark the job as failed only after the pull
   request step. The cleanup and pull request steps run whenever the run was not
   cancelled, so pages completed before the failure are kept.

How the wiki relates to graphify is described in
[Project memory](../operations/project-memory.md).
