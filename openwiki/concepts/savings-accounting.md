---
type: concept
title: Savings accounting
description: How `tokenwar gain` measures per-tool savings from each tool's own telemetry, reads per-provider usage, values savings in dollars month by month, and prices cached prompt blocks with the cache-aware cost model.
tags: [gain, telemetry, pricing, economics, providers]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-d58dc385f90d98331b19009a
    resource: repo://scripts/gain.sh
  - id: openwiki-source-2b1e20d43efb32361d8682a8
    resource: repo://scripts/lib/economics.mjs
  - id: openwiki-source-0823e5384e959042e0b96bfd
    resource: repo://scripts/lib/providers.sh
  - id: openwiki-source-393eb6db4d0e8f351ac6d2ad
    resource: repo://tests/gain.bats
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Savings accounting

`tokenwar gain` (`scripts/gain.sh`) reports how many tokens the stack saved and what that is worth. One rule applies everywhere: every figure comes from the tool's or provider's **own** telemetry. When there is no telemetry, the report shows `N/A` and a note explaining why. It never estimates a number to fill the gap.

## Per-tool sources

Each tool has a `*_summary` function. It returns `human | note | numeric tokens`, and the TOTAL row adds up the third field.

| Tool | Source | What is counted |
|------|--------|-----------------|
| RTK | `rtk gain`, plus `rtk gain --monthly` for the monthly table | RTK's own saved-token counter |
| context-mode | Its SQLite stores under `${CLAUDE_CONFIG_DIR:-~/.claude}/context-mode` | Bytes its hooks diverted (`session_events.bytes_avoided`) plus bytes it indexed instead of returning (`chunks`), divided by `CHARS_PER_TOKEN=4`. Bytes read by the sandbox (`bytes_sandboxed`) appear only in the note: they measure data handled, not tokens avoided. If a caller sets `CTX_STATS_JSON`, it still overrides the stores. |
| claude-mem | `~/.claude-mem/claude-mem.db` (13+) | For each observation, `discovery_tokens` minus the cost of reading it back, where read cost is (title + subtitle + narrative + facts) chars / 4. This is the same formula as claude-mem's own context header. Older releases fall back to `chroma-sync-state.json` counts × `MEM_EST_TOKENS_PER_ITEM=40`, labelled as an estimate. |
| caveman | none | Always `N/A`. It is a SessionStart style nudge that transforms no buffer, so there is no byte delta to measure. |
| pxpipe | `~/.pxpipe/events.jsonl` | Uses `pxpipe stats --json` (`savedTokensTotal`) when the CLI is available. Otherwise it parses the log directly, preferring explicit saved-token fields and falling back to baseline minus actual. |
| graphify | `graphify benchmark` on `~/.graphify/global-graph.json` | A **per-query reduction ratio**, shown in the note. Its token column stays `N/A` and it is never added to TOTAL, because counting a ratio as cumulative savings would include queries that have not happened yet. |

`tokenwar gain --json` returns the same data in machine-readable form, with graphify at `saved_tokens: 0` and its ratio in the note.

## Per-provider usage

`scripts/lib/providers.sh` lists every AI coding agent by index (`PROVIDER_COUNT=6`: Claude, Codex, Gemini, Kimi, opencode, Copilot), along with its label, config dir, and telemetry reader:

- **Codex**: `~/.codex/state_5.sqlite` → `threads.tokens_used`
- **opencode**: `~/.local/share/opencode/opencode.db` → session token columns
- **Copilot CLI**: `~/.copilot/session-store.db` → `assistant_usage_events`, including the AI credits GitHub actually bills (`total_nano_aiu` / 1e9)
- **Gemini, Kimi**: no local token store, so `N/A`

All three SQLite stores are read through `tw_sqlite_rows`. That function **runs** `python3` or `node:sqlite` to check that it works, rather than relying on `command -v`, because Windows' Store alias for `python3` exists but fails when actually run.

## Monthly dollar value

After the tables, `gain` shows a **Monthly value** section:

1. **Claude Code tools.** `tools_monthly` returns one `YYYY-MM <tool> <tokens>` line per month for RTK (from `rtk gain --monthly`), context-mode (from event `created_at` and source `indexed_at`), and claude-mem (from observation `created_at`). It uses the same stores and formulas as the table above, so the months add up to the table's figures. Each month is priced at `CLAUDE_INPUT_USD_PER_MTOK` (Claude Opus 5.5, $4.00/M input list price, checked 2026-10-04). The section is omitted when no tool has monthly data.
2. **Providers.** Providers with dated telemetry are priced at `provider_input_usd_per_mtok`. Every rate except Claude's is marked `VERIFY` in the source. Copilot's dollar figure is an API-equivalent valuation, never an invoice: Copilot is billed per seat plus AI credits, not per token.

The dollar figure is the **API-equivalent value** of the saved tokens, meaning what they would have cost at the input list price. It does not reflect a subscription bill. Output is not priced because the savings are on the input side.

## Cache-aware cost model

`scripts/lib/economics.mjs` is used by `scan` and the report, not by `gain`. It applies one rule: a static block in the prompt prefix is cached, so each turn after the first costs a **cache read**, not a fresh input token. Multiplying a prefix block by the number of turns overstates its cost by about 9×. The turn count describes how often the block was shown, which is a context-window fact, not a billing one.

- Multipliers relative to base input price: cache read `0.1` (default), 5-minute write `1.25`, 1-hour write `2.0`.
- `PRICING` (checked 2026-10-04) lists Fable 5.1 ($10/$50), Opus 5.5 ($4/$20), Sonnet 5.5 ($2/$10), and Haiku 4.5 ($1/$5). Fable and Opus have their own discounted cache-read rates ($0.025/M and $0.05/M), so `cacheReadRate(price)` uses a model's own rate when it has one and otherwise the default multiplier.
- `pricingFor(model)` maps a full model id to its family. Unknown ids default to `claude-sonnet`.
- `observedCost` prices the usage the provider reported; `uncachedCost` shows what the same traffic would cost with no caching. `prefixBlockCost` and `invalidationCost` value a static block and the cost of changing it (rewritten at 1.25× instead of read at the cache rate). `windowOccupancy` gives the share of the context window a block takes up, which is a separate fact from its cost.

## Keeping prices honest

Prices change with each model generation. Each constant includes a "checked" date and the source page. Before trusting a dollar column, re-check the live pricing page and update `gain.sh`, `providers.sh`, and `economics.mjs` together. `tests/gain.bats` (dollar values) and `tests/parse.bats` (economics) pin these values.
