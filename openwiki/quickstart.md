---
type: quickstart
title: Quickstart
description: What TokenWar is, how to install and run it, the tokenwar command map, and which wiki page answers which question.
tags: [quickstart, overview, commands, openwiki]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-14586213345f63fc2ffbcb43
    resource: repo://docs/installation.md
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
  - id: openwiki-source-ca85d4fa7810b2ec45a46d1a
    resource: repo://scripts/tokenwar.sh
  - id: openwiki-source-47db2af5ddfc1909ac6b883e
    resource: repo://SKILL.md
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Quickstart

TokenWar is a manager for **seven complementary token-saving tools** plus a
shared project-memory layer (OpenWiki). This repository is the
`SirTerrific/tokenwar` fork of `oratelecom/tokenwar` and adds Windows support
(Git Bash runtime, PowerShell and Command Prompt entry points).

| Tool | Saves tokens on |
|---|---|
| RTK | shell command output |
| context-mode | large data, via a sandbox and an index |
| claude-mem | repeated session memory |
| pxpipe | provider prompt payloads (text rendered as images) |
| graphify | repository exploration (a graph instead of grep sweeps) |
| caveman | verbose model responses (style only, no telemetry) |
| ponytail | oversized generated code (ruleset, no telemetry) |

OpenWiki is not an eighth live lane: it is a committed wiki that a team reuses.
Never run `openwiki --init` implicitly, since it writes docs and invokes an LLM.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash -s -- --all
source ~/.bashrc
```

On Windows, from a clone in PowerShell: `.\install.ps1 -All`. Git for Windows is
required because its bash is the engine. A bare install (no flags) only wires
the statusline and shell functions and installs no managed tool. Details:
[install and uninstall](workflows/install-and-uninstall.md) and
[Windows](platform/windows.md).

## Run

`tokenwar` with no argument runs `status`. Commands dispatched by
`scripts/tokenwar.sh`:

| Command | What it does | Page |
|---|---|---|
| `status` | state of the 7 tools and the providers | [status, check, toggle](workflows/status-check-toggle.md) |
| `check` | complementarity rules R1-R5 | [status, check, toggle](workflows/status-check-toggle.md) |
| `test` | `status --test`, a liveness ping per tool | [status, check, toggle](workflows/status-check-toggle.md) |
| `enable X` / `disable X` | toggle a plugin without uninstalling | [status, check, toggle](workflows/status-check-toggle.md) |
| `bundle X` | apply `dev`, `devops`, `architect` or `testing` | [status, check, toggle](workflows/status-check-toggle.md) |
| `prune` | list skills and MCP servers never invoked | [status, check, toggle](workflows/status-check-toggle.md) |
| `updates` / `upgrade` | check and apply updates | [upgrade and update check](workflows/upgrade-and-update-check.md) |
| `gain` | per-tool savings and monthly API-equivalent value | [savings accounting](concepts/savings-accounting.md) |
| `scan` | audit local agent logs | [scan and audit](concepts/scan-and-audit.md) |
| `copilot` | GitHub Copilot CLI wiring | [providers and launcher](integrations/providers-and-launcher.md) |
| `pxpipe desktop on|off|status` | route the Claude desktop app through pxpipe | [pxpipe](integrations/pxpipe.md) |
| `doctor` | `status --test`, then `check`, then `gain` | this page |

An unknown command exits 2. After an install, the sanity checks are
`tokenwar status` (all 7 tools OK), `tokenwar check` (COMPLEMENTARY) and
`tokenwar gain` (real per-tool numbers, never invented).

## Which page answers what

| Question | Page |
|---|---|
| How is the repository organised and how do the scripts fit together? | [architecture overview](architecture/overview.md) |
| How are savings measured, and why is a tool `N/A`? | [savings accounting](concepts/savings-accounting.md) |
| What does `tokenwar scan` read and recommend? | [scan and audit](concepts/scan-and-audit.md) |
| How do Codex, Gemini, Kimi, opencode and Copilot get counted and wrapped? | [providers and launcher](integrations/providers-and-launcher.md) |
| How does pxpipe run for the CLI and the desktop app? | [pxpipe](integrations/pxpipe.md) |
| What is different on Windows? | [Windows](platform/windows.md) |
| How do Graphify and OpenWiki work for a team, and in CI? | [project memory](operations/project-memory.md) |
| How do I run the tests or read the CI setup? | [test suite and CI](testing/test-suite-and-ci.md) |
