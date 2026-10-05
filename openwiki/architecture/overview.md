---
type: architecture overview
title: Architecture overview
description: How TokenWar is put together. It manages a stack of complementary token-saving tools, exposes them as a Claude Code skill (`/tokenwar`) and a shell dispatcher (`tokenwar <sub>`), and sends each subcommand to one bash script.
tags: [architecture, dispatcher, skill, plugins]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-210f372b904621a86172ec77
    resource: repo://scripts/lib/plugins.sh
  - id: openwiki-source-ca85d4fa7810b2ec45a46d1a
    resource: repo://scripts/tokenwar.sh
  - id: openwiki-source-47db2af5ddfc1909ac6b883e
    resource: repo://SKILL.md
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Architecture overview

TokenWar does not save tokens by itself. It installs, checks, measures and switches on or off a set of third-party tools. Each tool works on a different part of an agent's context window. TokenWar's job is to keep these tools **complementary**, so no two of them process the same buffer. It also reports each tool's savings from that tool's own telemetry, never from estimates.

## The managed stack

The skill description in `SKILL.md` lists seven core tools. TokenWar also installs and upgrades OpenWiki as a shared project-memory layer.

| Tool | Layer it works on | Where its savings come from |
|------|------------------|------------------------|
| context-mode | Heavy tool output is processed in a sandbox and indexed for FTS recall | SQLite stores under `~/.claude/context-mode/` |
| claude-mem | Memory and compact recall across sessions | `~/.claude-mem/claude-mem.db` |
| RTK | Shell and tool output is compressed before it enters context | `rtk gain` / `rtk gain --monthly` |
| pxpipe | A local proxy shrinks provider-bound prompt payloads | `~/.pxpipe/events.jsonl` |
| graphify | Builds a knowledge graph of the repo instead of reading the raw corpus | `graphify benchmark` (a per-query ratio, never summed) |
| caveman | Nudges the assistant toward terse prose | none: always `N/A` |
| ponytail | Ruleset for smaller code and less abstraction | none (ruleset only) |
| OpenWiki | Durable, grounded Markdown project memory | n/a: a documentation layer |

<!-- openwiki: broken internal link [/openwiki/concepts/savings-accounting.md] link "/openwiki/concepts/savings-accounting.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`docs/tokenwar-tools.md` has the full comparison, including alternative tools that are tracked but not installed (Serena, Probe, Stacklit, codebase-memory-mcp and others). Telemetry handling is covered in [Savings accounting](/openwiki/concepts/savings-accounting.md).

<!-- openwiki: broken internal link [/openwiki/workflows/install-and-uninstall.md] link "/openwiki/workflows/install-and-uninstall.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
context-mode, claude-mem, caveman and ponytail are **Claude Code plugins**. RTK, pxpipe, graphify and OpenWiki are **standalone CLIs** installed from GitHub releases, npm or PyPI. See [Install and uninstall](/openwiki/workflows/install-and-uninstall.md).

## Two entry points, one set of scripts

```
/tokenwar <sub>   (Claude Code skill: SKILL.md, the agent follows its instructions)
tokenwar <sub>    (shell function -> scripts/tokenwar.sh)
        │
        ▼
scripts/<sub>.sh  (status, gain, scan, prune, bundle, check, copilot,
                   upgrade, check-updates, toggle, pxpipe-desktop)
        │
        ▼
scripts/lib/      (osdetect.sh, plugins.sh, providers.sh, *.mjs)
```

- **The skill** (`SKILL.md`, installed under `~/.claude/skills/tokenwar/`) is an instruction document for the agent. If no argument is given, it runs `status`. It prints a `# /tokenwar <subcommand>` header and ends with a self-check: every CLI call exits 0, no number is made up (a missing source is reported as `N/A`, never `0`), and no auto-fix runs without confirmation through `AskUserQuestion`.
- **The dispatcher** (`scripts/tokenwar.sh`) gives the same commands to plain shells and to other CLIs (Codex, Gemini, and so on) that have no slash commands. It reads `cmd="${1:-status}"` and uses `exec` to hand control to the matching script.

### Subcommand map

| Subcommand | Implementation |
|------------|----------------|
| `status` (default) | `status.sh` |
| `test` | `status.sh --test`, plus a note that context-mode can only be pinged through its `ctx_stats` MCP tool |
| `gain` | `gain.sh` |
| `scan` | `scan.sh` → `scan.mjs` |
| `check` | `check.sh` |
| `doctor` | `status.sh --test`, then `check.sh`, then `gain.sh`; each step is non-fatal (`|| true`) |
| `upgrade` / `updates` | `upgrade.sh` / `check-updates.sh` |
| `enable X` / `disable X` | `toggle.sh` |
| `prune`, `bundle`, `copilot` | `prune.sh`, `bundle.sh`, `copilot.sh` |
| `pxpipe desktop on\|off\|status` | `pxpipe-desktop.sh` (any other `pxpipe` argument exits 2 with a usage message) |

<!-- openwiki: broken internal link [/openwiki/workflows/status-check-toggle.md] link "/openwiki/workflows/status-check-toggle.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/workflows/upgrade-and-update-check.md] link "/openwiki/workflows/upgrade-and-update-check.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/concepts/scan-and-audit.md] link "/openwiki/concepts/scan-and-audit.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/integrations/pxpipe.md] link "/openwiki/integrations/pxpipe.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
An unknown command prints usage to stderr and exits 2. See [Status, check, toggle](/openwiki/workflows/status-check-toggle.md), [Upgrade](/openwiki/workflows/upgrade-and-update-check.md), [Scan](/openwiki/concepts/scan-and-audit.md) and [pxpipe](/openwiki/integrations/pxpipe.md).

## Shared libraries

<!-- openwiki: broken internal link [/openwiki/platform/windows.md] link "/openwiki/platform/windows.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- `scripts/lib/osdetect.sh`: platform detection (Linux, macOS, Windows Git Bash/MSYS) and path helpers. Every other library sources it. See [Windows support](/openwiki/platform/windows.md).
- `scripts/lib/plugins.sh`: `tw_load_plugin_list` prints a JSON array of `{id, enabled, version}`. Its main source is `claude plugin list --json`. If that does not return a usable array, it falls back to `installed_plugins.json` plus `enabledPlugins` **OR-merged** from `settings.json` and `settings.local.json`. A plugin that is installed but missing from `enabledPlugins` counts as enabled, matching Claude Code's behavior. An explicit `false` stays disabled. Overrides: `CLAUDE_CONFIG_DIR` and `TW_CLAUDE_BIN`.
<!-- openwiki: broken internal link [/openwiki/integrations/providers-and-launcher.md] link "/openwiki/integrations/providers-and-launcher.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- `scripts/lib/providers.sh`: a registry of non-Claude providers (Codex, Gemini, Kimi, opencode, Copilot) and their telemetry. See [Other providers](/openwiki/integrations/providers-and-launcher.md).
<!-- openwiki: broken internal link [/openwiki/concepts/scan-and-audit.md] link "/openwiki/concepts/scan-and-audit.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- `scripts/lib/*.mjs`: Node modules for the scanner and for economics. See [Scan](/openwiki/concepts/scan-and-audit.md).

## Design invariants

- **Never fabricate.** If a tool has no telemetry, it is reported as `N/A`. caveman is always `N/A`, and no byte-logging hook may be wired up for it.
- **Complementarity.** `check.sh` verifies that no two tools process the same buffer.
- **Confirmation before side effects.** `activate`, `upgrade`, `enable` and `disable` ask before changing anything.
