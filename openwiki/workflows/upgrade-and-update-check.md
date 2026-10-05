---
type: workflow
title: Upgrade and update check
description: How check-updates.sh decides what is out of date and caches the answer, how upgrade.sh confirms and applies updates, and how rtk-update.sh installs RTK with sha256 verification.
tags: [upgrade, updates, registry, rtk, cache, openwiki]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-f8ae26e7f20dd71dcdc9b79d
    resource: repo://scripts/check-updates.sh
  - id: openwiki-source-e723d58fa32bab22d135b3e5
    resource: repo://scripts/rtk-update.sh
  - id: openwiki-source-e79504490bc0e4483076e0f8
    resource: repo://scripts/upgrade.sh
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Upgrade and update check

Three scripts cooperate: `check-updates.sh` finds out what is outdated and
writes a cache, `upgrade.sh` reads it and applies updates, and `rtk-update.sh`
is the single RTK installer used by both `install.sh --with-rtk` and `upgrade`.

## check-updates.sh

Output is one line per tool with a state of `up-to-date`, `update-available`,
`ahead` or `unknown`. Exit codes: 0 all current, 2 at least one update, 1 error.
Flags: `--force` (ignore the cache) and `--quiet` (set the exit code only).

**Cache.** `~/.claude/tokenwar/upgrade-check.json`, valid for 24 hours by file
mtime. The status line reads it and never blocks on the network (see
[status commands](status-check-toggle.md)). The cache records `refresh_ok`, so a
failed marketplace fetch is visible as "may be stale".

**Where "latest" comes from.** Always the component's own registry, never a
hardcoded number (a pinned pxpipe once reported up-to-date while a newer version
had shipped):

| Component | Source |
|---|---|
| plugins | `marketplace.json` `version` on the fetched upstream ref; if absent, the plugin's own `.claude-plugin/plugin.json` |
| pxpipe, OpenWiki | npm registry `/latest` (`pxpipe-proxy`, `openwiki`) |
| graphify | PyPI JSON for `graphifyy` (not the unrelated `graphify` project) |
| RTK | GitHub releases `tag_name`; for a `cargo install --path` dev build, the `Cargo.toml` version on the clone's upstream branch |
| tokenwar | local `HEAD` against the fetched upstream tip |
| Codex, Gemini, Kimi, opencode, Copilot | provider-specific lookups |

Every lookup has a 10 second timeout and every URL is overridable
(`TW_*_URL`) so tests stay offline. Any failure yields `unknown`, never a guess.
The registry payload is piped straight into node instead of an environment
variable, because PyPI's JSON exceeds the argv/env size limit.

**Marketplaces** are refreshed with `git fetch` only, never `pull`, so a locally
customized clone cannot poison the cache. `claude plugin marketplace update` is
avoided on purpose: it races the following `claude plugin list --json`.

**classify(installed, latest).** Empty on either side is `unknown`; equal is
`up-to-date`; two plain semver strings are compared with `sort -V`
(`update-available` or `ahead`); any other pair (for example git SHAs) that
differs is treated as `update-available`. A tokenwar checkout that already
contains the upstream tip counts as current.

OpenWiki has no `--version` flag, so its installed version is read from the
global package's `package.json`.

## upgrade.sh

Usage: `upgrade.sh` (confirm first), `--yes` (no prompt), `--all` (ignore the
cache and try every tool). Exit 0 on success or nothing to do, 1 if any update
failed, 2 for an unknown argument.

Flow:

1. Unless `--all`, re-run `check-updates.sh --force --quiet` so the decision
   reflects the registries now. If no cache can be read, all tools are tried.
2. Print the tools that will change and ask `Upgrade now? [y/N]` on
   `/dev/tty` (overridable with `TW_TTY`). With no terminal and no `--yes` it
   prints a notice and skips.
3. Apply in a fixed order, remembering failures:
   - plugins: fast-forward the marketplace clone, look up the install scope with
     `claude plugin list --json`, then `claude plugin update <slug> --scope <scope>`;
   - RTK: rebuild a path-installed dev build from its clone, otherwise run
     `rtk-update.sh`;
   - pxpipe and OpenWiki: `npm install -g <pkg>@latest`;
   - graphify: upgrade through whichever of `uv tool`, `pipx` or `pip` owns it,
     then re-run `graphify install` to refresh the skill files;
   - tokenwar itself last, with `git pull --ff-only`, inside one compound command
     so bash has parsed it before the pull rewrites the running script.
4. Re-run the check with `--force` so the cache and the status-line arrow update
   immediately.

The marketplace fast-forward closes a loop: `check-updates.sh` reads
`origin/<branch>`, but `claude plugin update` installs the clone's local HEAD,
so a SHA-versioned plugin would otherwise report an update forever. A clone that
cannot fast-forward (local edits) is left alone with a warning.

## rtk-update.sh

Exit 0 when updated, already current, or skipped on purpose; 1 on failure.

- Only an `rtk` in `~/.local/bin` is managed. One installed elsewhere (Homebrew,
  cargo) is left to its package manager.
- Linux and macOS: pipe RTK's official installer into `sh` with
  `RTK_INSTALL_DIR=~/.local/bin`.
- Windows: that installer refuses Windows, so the script downloads
  `rtk-<arch>-pc-windows-msvc.zip` from the latest GitHub release and checks the
  sha256 digest GitHub publishes for the asset. A release with no digest, or a
  mismatch, is refused. The archive is also scanned for unsafe paths before
  extraction.
- The old `rtk.exe` is renamed to `.old` before the new one is copied, because a
  running exe cannot be overwritten on Windows; on a copy failure it is restored.

Overrides for tests: `TW_RTK_INSTALL_URL`, `TW_RTK_RELEASE_URL`.

See also: [install and uninstall](install-and-uninstall.md).
