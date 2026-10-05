---
type: operations
title: "Project memory: graphify and OpenWiki"
description: The two shared project-memory layers TokenWar installs — graphify (structural graph) and OpenWiki (grounded Markdown wiki) — how they are installed and upgraded, and the scheduled openwiki-update workflow.
tags: [graphify, openwiki, project-memory, ci]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-6d4b4e707b8d60b6ccfa3425
    resource: repo://.github/workflows/openwiki-update.yml
  - id: openwiki-source-c5e22699794b54c118f20d71
    resource: repo://docs/project-memory.md
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-1e2898c546292dad2bfa5898
    resource: repo://tests/graphify.bats
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Project memory: graphify and OpenWiki

Without durable project memory, every agent session rediscovers the tree, entry points, architecture and invariants. TokenWar ships two complementary layers that pay that cost once (rationale in `docs/project-memory.md`):

| Layer | Produces | Cost model | Typical use |
|---|---|---|---|
| [graphify](https://github.com/Graphify-Labs/graphify) | structural graph of the repo | AST / code-only extraction is deterministic and uses no LLM; semantic extraction of docs, papers or images may | bounded architecture queries before broad `rg`/`find`/file-reading sweeps |
| [OpenWiki](https://github.com/langchain-ai/openwiki) | grounded Markdown committed in Git (this wiki) | init and changed updates consume LLM tokens; a clean update is a local no-op | shared, reviewable team understanding across humans and agents |

OpenWiki differs from claude-mem: claude-mem is personal, local session memory; OpenWiki is project-owned, versioned and reviewed. Its Claims tie statements to repository evidence. Agents should read the wiki index and open only relevant pages — loading the whole wiki into every prompt erases part of the gain.

<!-- openwiki: broken internal link [/openwiki/concepts/savings-accounting.md] link "/openwiki/concepts/savings-accounting.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
The accounting is a net figure: *repeated repository-reading tokens avoided − wiki generation and update tokens*. It amortizes faster with larger repos, teams and lifetimes; a throwaway repo may not break even. `tokenwar gain` reports graphify only as a per-query ratio from its own benchmark, never summed into the total (see [Savings accounting](/openwiki/concepts/savings-accounting.md)).

## Install

Both are opt-in `install.sh` flags (also part of `--all`):

- `--with-graphify` — installs the `graphifyy` PyPI package (CLI `graphify`) and registers its skill.
- `--with-openwiki` — installs the `openwiki` npm package (`OPENWIKI_NPM_SPEC=openwiki@latest`). OpenWiki needs Node.js 22+.

**Installation never initializes a repository**: initialization writes generated docs and invokes an LLM, so it stays an explicit per-project decision. After installing, inside each long-lived repository: run `graphify .` once and initialize OpenWiki once; then `graphify update .` after code changes and an OpenWiki update after merges. For a coding-agent integration use OpenWiki's own command, e.g. `openwiki integrations install codex`.

> Note: `docs/project-memory.md` still says TokenWar "pins the reviewed OpenWiki release", but `install.sh` now installs `openwiki@latest`; only the CI workflow below pins a version.

## Upgrade and status

<!-- openwiki: broken internal link [/openwiki/workflows/upgrade-and-update-check.md] link "/openwiki/workflows/upgrade-and-update-check.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
graphify is one of the seven tracked tools (see [Upgrade and update check](/openwiki/workflows/upgrade-and-update-check.md)), covered by `tests/graphify.bats`:

- the statusline shows a green `graphify` badge with its version, red when the CLI is absent, and the update arrow when an update is pending;
- `check-updates` reads the latest version from the PyPI JSON API and degrades to `unknown` when the registry is unreachable;
- `upgrade` lists graphify only when the cache flags it, upgrades through `uv tool` when uv owns the package (then refreshes the skill), falls back to `pipx`, never runs `pip` against a uv-owned install, and reports failure when no Python installer is available;
- `tokenwar enable/disable` refuses graphify (it is a binary, not a plugin) and points at `graphify install`/`uninstall`.

OpenWiki is upgraded by `tokenwar upgrade` via `npm install -g openwiki@latest`; it has no `--version` flag, so its installed version is read from the global package's `package.json`.

## Scheduled wiki update (`.github/workflows/openwiki-update.yml`)

| Aspect | Value |
|---|---|
| Triggers | `workflow_dispatch` and daily cron `0 8 * * *` |
| Checkout | `fetch-depth: 0`, so `openwiki code --update` can diff HEAD against the last documented commit |
| Toolchain | Node 22; `npm install --global openwiki@0.7.0 mermaid@11.16.0 jsdom@29.1.1` (mermaid/jsdom only validate Mermaid diagrams) |
| Run | `openwiki code --update --print`, provider `openai`, model `gpt-5.6-terra`, `continue-on-error: true`; secrets `OPENAI_API_KEY`, `OPENWIKI_LANGSMITH_API_KEY`, optional `LANGSMITH_API_KEY` tracing |
| Output | removes `openwiki/.run.json`, then opens a PR on branch `openwiki/update` (`docs: update OpenWiki`) staging `openwiki`, `AGENTS.md`, the workflow, and `CLAUDE.md` only if present |
| Failure | the PR still carries pages completed before the failure (merge it to keep that progress as the baseline); a final step re-fails the job |

All actions are pinned by commit SHA. The workflow follows OpenWiki's maintained GitHub example; `docs/project-memory.md` links equivalents for auto-merge, GitLab CI and Bitbucket. Prefer one scheduled/post-merge job over regenerating the wiki in every PR branch: the project pays once and reviews once.

## Recommended policy

- graphify: one initial scan, then structural updates after code changes.
- OpenWiki: one initial generation, then updates after merges or on a schedule; treat a clean no-op as cheap and a changed update as metered work.
- Keep generated knowledge reviewable in Git, and measure provider usage before claiming a net saving.

<!-- openwiki: broken internal link [/openwiki/architecture/overview.md] link "/openwiki/architecture/overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Related: [Architecture overview](/openwiki/architecture/overview.md)
