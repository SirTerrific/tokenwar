---
type: integration
title: Other providers, launcher and Copilot
description: How tokenwar treats the non-Claude coding agents — the provider registry and its native telemetry sources, the launch banner shell functions for Codex, Gemini, Kimi, opencode and Copilot, the Copilot wiring of hooks, skills and MCP, and the functional RTK/opencode proof.
tags: [providers, launcher, copilot, opencode, codex, telemetry]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-c87f4c5a6be93f22093900bd
    resource: repo://scripts/copilot.sh
  - id: openwiki-source-0823e5384e959042e0b96bfd
    resource: repo://scripts/lib/providers.sh
  - id: openwiki-source-e3f2af3d384757f5094b3840
    resource: repo://scripts/opencode-functional-test.sh
  - id: openwiki-source-a53d9dd5f6f7f244ccfbec7e
    resource: repo://scripts/tokenwar-launch.sh
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Other providers, launcher and Copilot

Tokenwar's tools are published for Claude Code. The other coding agents get two things: token telemetry read from each agent's own store, and a launch banner. Copilot CLI also gets the stack wired into its own extension points.

## Provider registry

`scripts/lib/providers.sh` is the single registry of AI coding providers. Each provider has an index from 0 to `PROVIDER_COUNT - 1` (6 providers), and callers use `provider_*` functions with that index (`provider_name`, `provider_cli`, `provider_is_installed`, `provider_version`, `provider_telemetry_total`, `provider_telemetry_monthly`, `provider_input_usd_per_mtok`, ...). `gain.sh`, `status.sh`, `check.sh`, `check-updates.sh` and the statusline source it.

| Index | Provider | Telemetry source |
|---|---|---|
| 0 | Claude Code | RTK (`rtk gain`), context-mode (`ctx_stats`), claude-mem (`claude-mem.db`) |
| 1 | Codex | `~/.codex/state_5.sqlite` → `threads.tokens_used` |
| 2 | Gemini CLI | no local token store — CLI detection only, telemetry N/A |
| 3 | Kimi Code CLI | `~/.kimi-code` holds sessions and config, but no documented token store — N/A |
| 4 | opencode | `~/.local/share/opencode/opencode.db` → session token columns |
| 5 | Copilot CLI | `~/.copilot/session-store.db` → `assistant_usage_events`, per model, with the AI credits GitHub bills |

Store locations honour `CODEX_HOME`, `KIMI_CODE_HOME`, `OPENCODE_DATA_HOME` and `COPILOT_HOME`; on Windows the defaults also consider `%APPDATA%` and `%LOCALAPPDATA%`. The three SQLite stores are read through `tw_sqlite_rows`, which runs the same SQL under `python3` or `node:sqlite`, so they stay readable on a stock Windows machine without Python.

<!-- openwiki: broken internal link [/openwiki/concepts/savings-accounting.md] link "/openwiki/concepts/savings-accounting.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Copilot's AI credits come from `total_nano_aiu` (1 credit = 1e9 nano-AIU). Copilot is not billed per token, so its dollar column is an API-equivalent valuation at a GPT-5-class input rate, never an invoice. The per-provider input prices are in [Savings accounting](/openwiki/concepts/savings-accounting.md); every non-Claude rate is marked VERIFY in the source.

## Launch banner

<!-- openwiki: broken internal link [/openwiki/integrations/pxpipe.md] link "/openwiki/integrations/pxpipe.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`install.sh` writes a shell-integration block into the user's rc file. For each CLI in `WRAPPED_PROVIDER_CLIS` (codex, gemini, kimi, opencode, copilot) it defines a function that first runs `scripts/tokenwar-launch.sh <cli>` and then the real CLI. The same block defines `tokenwar()` and routes `claude()` through `pxpipe-claude.sh` (see [pxpipe](/openwiki/integrations/pxpipe.md)).

None of these CLIs exposes a persistent status bar, so `tokenwar-launch.sh` prints the stack once at launch — the same renderer as the Claude statusline — plus a one-line hint to run `tokenwar status` and `tokenwar gain`. It stays silent for subcommands that must not get a banner (`exec`, `completion`, `mcp`, `--version`, `--help`, ...), when stdout is not a terminal, and for non-interactive runs such as `-p` or `--output-format`, so scripted output is never polluted. It always exits 0, so a banner failure never blocks the CLI.

## Copilot wiring

`scripts/copilot.sh` (also `tokenwar copilot`) maps the stack onto Copilot CLI's three extension points: hooks in `~/.copilot/hooks/*.json`, skills in `~/.copilot/skills/<name>/SKILL.md`, and MCP servers in `~/.copilot/mcp-config.json`.

| Tool | Via | How |
|---|---|---|
| rtk | hook | `rtk init -g --copilot` (PreToolUse command rewriting) |
| graphify | skill | `graphify copilot install` |
| caveman | skill | copied from the Claude plugin cache |
| ponytail | skill | copied from the Claude plugin cache |
| claude-mem | MCP | its own `.mcp.json` server re-registered as `claude-mem` |
| context-mode | — | not wired: its manifest pins an absolute, version-specific interpreter path that would break on upgrade |
| pxpipe | — | not wired: it proxies the Anthropic API path, and Copilot talks to GitHub's endpoint |

`copilot.sh` (or `check`) is read-only and exits 0 when every installed tool is wired. `copilot.sh wire` applies missing wiring after confirmation; `wire --yes` skips the prompt. `install.sh --with-copilot` delegates to this script, so the wiring has one implementation.

## opencode functional proof

`scripts/opencode-functional-test.sh` proves RTK really reaches opencode, for CI and local diagnosis. In a temporary `HOME` it runs `rtk init -g --opencode`, checks that `.config/opencode/plugins/rtk.ts` exists and delegates to `rtk rewrite`, then checks that `opencode debug config` references that plugin. It needs `rtk` and `opencode` on `PATH` (overridable with `RTK_BIN` and `OPENCODE_BIN`) and exits 127 when one is missing.
