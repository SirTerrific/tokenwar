---
type: concept
title: Scan and session audit
description: How `tokenwar scan` parses coding-agent session logs, takes an inventory of what loads on every request, infers a workload profile, scores four categories against the cache-aware cost model, and writes terminal, HTML, JSON or sanitized snapshot reports.
tags: [scan, audit, parse, report, recommendations]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-bb5866897242801738c71436
    resource: repo://docs/scan.md
  - id: openwiki-source-e36841951b3a9a5fff51c03f
    resource: repo://scripts/lib/adapters.mjs
  - id: openwiki-source-8523137c6b4d51fb93895114
    resource: repo://scripts/lib/history.mjs
  - id: openwiki-source-fdc12df4fff9c7c1baaf7579
    resource: repo://scripts/lib/parse.mjs
  - id: openwiki-source-058e5be1c0cfc3d18b385d6b
    resource: repo://scripts/lib/profile.mjs
  - id: openwiki-source-a7b9f8aa281e45785b5cf3f8
    resource: repo://scripts/lib/recommend.mjs
  - id: openwiki-source-b865c9b30fc313b6e6527b77
    resource: repo://scripts/lib/report.mjs
  - id: openwiki-source-46107c9be0dac88e6c38f5ed
    resource: repo://scripts/scan.mjs
  - id: openwiki-source-8e7c03781fb8009c89a2e169
    resource: repo://scripts/scan.sh
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Scan and session audit

`tokenwar scan` is a local, read-only audit. It compares what a coding agent loads on every request with what the agent actually used, based on the agent's own session logs. The design follows [Yellow Lab Tools](https://github.com/gmetais/YellowLabTools): a small set of graded categories, each backed by the evidence behind its grade. Nothing leaves the machine.

```bash
tokenwar scan                    # last 30 days
tokenwar scan --days 7
tokenwar scan --html --open      # HTML report
tokenwar scan --json             # detailed local report
tokenwar prune                   # loaded every request, never used (deletes nothing)
tokenwar bundle devops --dry-run # preview a session-start bundle
```

## Pipeline

`scripts/scan.sh` is a thin wrapper. It sources `lib/osdetect.sh`, converts log-root paths with `tw_export_node_paths` (so MSYS paths reach native Windows node), and runs `scripts/scan.mjs`. That script works through the modules below in order:

| Step | Module | Role |
|------|--------|------|
| Find and parse sessions | `lib/parse.mjs`, `lib/adapters.mjs` | Lists session files per client (`listSessionFiles`) and turns each one into the same normalized shape |
| Aggregate | `lib/parse.mjs` (`aggregateSessions`) | Usage totals, tool and command counts, skills invoked |
| Inventory | `lib/inventory.mjs` | Installed skills and MCP servers and their on-disk listing size, cross-referenced against what was actually invoked |
| Profile | `lib/profile.mjs` | Workload-mode distribution |
| Recommend | `lib/recommend.mjs` | Tool and bundle recommendations, including their costs |
| Report | `lib/report.mjs` | Scores plus terminal and HTML rendering |
| History | `lib/history.mjs` | Sanitized snapshots, and comparison with the previous scan |

Log roots can be overridden with `TOKENWAR_<CLIENT>_LOG_ROOT` (Claude, Codex, Gemini, Copilot, opencode). `TOKENWAR_SKILLS_DIR`, `TOKENWAR_PLUGIN_CACHE_DIR` and `TOKENWAR_MCP_CONFIG` relocate the inventory sources.

## Parsing structure, not lines

An earlier version counted JSONL **lines** that matched regexes such as `git|grep|find|cat`. This inflated the numbers in several ways:

- One line holds several `tool_use` blocks.
- Results repeat each call.
- Prose that mentions a command counted as running it.
- `find` matched `findViewById`.
- Reading only the end of each session biased the sample toward verification-heavy work.

`parse.mjs` now does the following:

- Walks `message.content[]` and deduplicates on `tool_use.id`.
- Keeps sidechain (subagent) traffic separate.
- Splits compound commands and tokenizes each one to recover `argv[0]`, unwrapping `sudo`, `env`, `timeout` and leading `VAR=value` (`splitCommands`, `commandHead`, `classifyCommand`, `COMMAND_FAMILIES`).

## Clients

Claude Code `.jsonl` sessions are parsed natively. Other clients go through `ADAPTERS`:

| Client | Adapter | Token usage |
|--------|---------|-------------|
| Claude Code | `parseSessionFile` | Yes |
| Codex | `parseCodexSession` (`rollout-*.jsonl`) | Yes |
| Gemini CLI | `parseGeminiSession` (`logs.json`) | No. It counts as tool evidence only and is excluded from every cost figure. |
| Copilot CLI, opencode | none yet | Detected and reported as `format unsupported`. A missing parser is never reported as zero usage. |

## The four categories

| Category | Question | Evidence |
|----------|----------|----------|
| Capability inventory | How many installed skills were ever invoked? | `tool_use` blocks and `attributionSkill` |
| Context-window hygiene | How much of the window is used up before any work starts? | Skill listing sizes on disk (`windowOccupancy`) |
| Prefix stability | How much input arrives as cache writes rather than reads? | `cache_creation_input_tokens` |
| Cache efficiency | How much of the presented input is served from cache? | `cache_read_input_tokens` |

Token figures come from the usage fields the provider reports. The only estimates are the sizes of on-disk text that the prompt does not report (characters / 4), and these are labelled as estimates.

## Cost model

<!-- openwiki: broken internal link [/openwiki/concepts/savings-accounting.md] link "/openwiki/concepts/savings-accounting.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
All dollar figures go through `lib/economics.mjs` (see [Savings accounting](/openwiki/concepts/savings-accounting.md)). A static block in the prompt prefix is billed as a **cache read** on every turn after the first, not as fresh input. The naive "block × turns × input price" overstates the cost by about 9×. The report shows both numbers and says which assumption each one uses. Where the real cost is the window occupancy itself, the report shows the block's share of the context window instead. Cache TTL expiry during idle gaps does not appear in the logs, so the cached cost is a lower bound, not an exact figure.

## Workload profile

`inferProfile` returns a **distribution** over `INFERRABLE_MODES` (`dev`, `devops`, `architect`, `testing`), never a single label. Each mode has to pass a minimum-evidence gate before it can be claimed at all. The shares are then renormalized. Modes that coding-agent logs cannot reveal are listed in `NOT_INFERRABLE_MODES` (`seo`, `po`, `designer`), together with the reason, so they are never guessed.

## Recommendations and bundles

Each recommendation states:

- the signal that justifies it
- the signal that would rule it out
- the cost of the recommended tool
- a break-even rule

Tools that do not reach break-even are listed as `NOT YET`, and one is listed as `AVOID`. The report applies two rules to itself:

- **Savings are never summed.** RTK, context-mode and caveman act on overlapping lanes, so the report flags the overlap instead of adding their individual claims together.
- **Cost is always modelled.** Examples are graphify's up-front build, OpenWiki's output-priced maintenance against cache-read-priced reads (an adverse ratio of about 50:1), and claude-mem's injected prefix.

`tokenwar bundle dev|devops|architect|testing` applies a predefined session-start selection (`BUNDLES` in `recommend.mjs`).

## Outputs

- **Terminal or HTML** (`renderTerminal`, `renderHtml`): grades, evidence and recommendations.
- **`--json`**: the detailed local report. It is **not** an upload contract.
- **`--summary-json`** (`--source-id`, `--client`, `--max-sessions`): a versioned (`SCHEMA_VERSION`) sanitized aggregate. It contains no session paths, prompts, command arguments, tool results or skill names, and makes no network request. `TOKENWAR_SCAN_SKIP_STATUS=1` skips the status subprocesses, which leaves tool states unknown.
- **`--history DIR`**: writes `<timestamp>.<id>.snapshot.json` (`recordSnapshot`) and compares it with the previous snapshot (`compareSnapshots`).

## Limits

- MCP tool counts can only be known from a live session. Pass them with `TOKENWAR_MCP_TOOL_COUNTS`; otherwise they are shown as unknown.
- "Never invoked in the window" does not mean "unwanted". `prune` prints a review list and deletes nothing.
