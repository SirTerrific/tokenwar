---
type: workflow
title: Status, check, toggle and maintenance commands
description: What tokenwar status, check, enable/disable, restore-settings, prune, bundle and the statusline do, their exit codes, and which of them change anything.
tags: [status, check, toggle, bundle, prune, statusline, openwiki]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-cb0f48698229910e3c22e879
    resource: repo://scripts/bundle.sh
  - id: openwiki-source-f9fafda300b014057921ac73
    resource: repo://scripts/check.sh
  - id: openwiki-source-b0329cd9819e2b2b767ff0eb
    resource: repo://scripts/prune.sh
  - id: openwiki-source-19ba93f011d39c1fdd2d03c4
    resource: repo://scripts/restore-settings.sh
  - id: openwiki-source-2e965a63097ccd817481eb65
    resource: repo://scripts/status.sh
  - id: openwiki-source-2ef433a11d62e1edeb624b00
    resource: repo://scripts/toggle.sh
  - id: openwiki-source-0a1aa7f7da78cd1afee847b5
    resource: repo://scripts/tokenwar-statusline.sh
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Status, check, toggle and maintenance commands

These are the small commands dispatched by `scripts/tokenwar.sh`. Only
`toggle`, `bundle` and `restore-settings` change state; the rest only read.

## status

`scripts/status.sh` reports the 7 token-saving tools (context-mode, claude-mem,
RTK, caveman, ponytail, pxpipe, graphify) plus the AI provider CLIs.

- Per-tool states are `OK`, `installed-disabled`, `not-installed` or `unknown`.
- Plugin state comes from `lib/plugins.sh` (`tw_load_plugin_list`): the
  `claude plugin list --json` output first, then the on-disk plugin files.
- Exit 0 only when all 7 tools are healthy. Providers are informational: a
  Claude-only host has no other provider CLI and must still exit 0.
- `--json` prints machine-readable output; `--test` adds a liveness ping per
  tool. context-mode cannot be pinged from a shell, so the caller must invoke
  its `ctx_stats` MCP tool separately.
- An unknown argument exits 2.

## check

`scripts/check.sh` verifies the tools are complementary, not conflicting. Five
rules, despite the "four rules" header comment:

| Rule | Meaning |
|---|---|
| R1 | bash double-hook: counts PreToolUse hooks with matcher `Bash` in `settings.json` (0 = WARN, 1 = PASS, more = FAIL) |
| R2 | memory overlap: claude-mem writes to `~/.claude-mem`, context-mode to `~/.claude/projects/<slug>/memory`; disjoint sinks pass |
| R3 | output compression: always PASS, RTK compresses tool output and caveman the model response |
| R4 | install drift: WARN if a plugin, `rtk`, `pxpipe` or `graphify` is missing; it does not compare versions (no network) |
| R5 | provider overlap: needs the CLI on PATH **and** its config dir to exist; always PASS today |

The verdict is `COMPLEMENTARY` (all PASS, exit 0), `DEGRADED` (any WARN, exit 1)
or `CONFLICT` (any FAIL, exit 1). `--json` emits the rules, verdict and an `ok`
flag.

## enable / disable

`scripts/toggle.sh` toggles the four Claude Code plugins (`context-mode`,
`claude-mem`, `caveman`, `ponytail`) by running `claude plugin enable|disable`
on their marketplace slug. The plugin stays installed. `rtk`, `pxpipe` and
`graphify` are standalone binaries, so toggling them exits 3 and prints the
per-tool command instead. Usage errors exit 2.

## bundle

`scripts/bundle.sh` applies a session-start preset by calling `toggle.sh`:

| Bundle | Enable | Disable |
|---|---|---|
| `dev` | rtk, caveman, ponytail, claude-mem | pxpipe |
| `devops` | rtk, caveman | graphify, pxpipe |
| `architect` | graphify, claude-mem, caveman | pxpipe |
| `testing` | rtk, caveman | graphify, pxpipe |

It asks for confirmation unless `--yes` is given (and refuses without a
terminal), supports `--dry-run`, and warns to apply bundles at the **start** of a
session: changing the tool inventory invalidates the prompt-cache prefix, which
is rebilled at 1.25x instead of read at 0.1x. Enabling a tool that is not
installed is reported as skipped and makes the exit status 1.

## restore-settings

`scripts/restore-settings.sh` merges `~/.claude/settings.local.json` into
`~/.claude/settings.json` (local keys win) after copying the current file to
`settings.json.tokenwar-bak`. It exists because Claude Code has been seen
wiping settings on a session start. With no local file it exits 1; with no
`settings.json` it copies the local file in.

## prune

`scripts/prune.sh [--days N]` (default 30) runs `scan.mjs --json` and prints
skills and MCP servers that were never invoked, with their per-request listing
cost and the removal commands. It **never deletes**: a skill used twice a year
can still be worth its listing cost.

## statusline

`scripts/tokenwar-statusline.sh` is the Claude Code `statusLine` command. It
prints one badge per tool: green when active, red when not. A yellow `⬆` marks a
tool with an update available, and `⬆ N updates · /tokenwar upgrade` ends the
bar. It must never block or turn red because of a slow lookup:

- `claude plugin list --json` and `rtk gain` are cached for 30 seconds and fall
  back to the stale cache on a timeout.
- Update state is read from the `check-updates.sh` cache (24 hour TTL); a stale
  cache triggers a background refresh instead of a blocking call.
- ponytail is green only when the plugin is enabled and
  `~/.claude/.ponytail-active` reports a live mode.
- On Windows it adds `~/.local/bin` to PATH, because Claude Code spawns it
  with the Windows PATH and not a Git Bash login environment.

See also: [architecture overview](../architecture/overview.md),
[savings accounting](../concepts/savings-accounting.md).
