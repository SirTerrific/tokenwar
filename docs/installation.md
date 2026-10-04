# Installation

## Quick start

Two ways in — pick your interface. **A human runs one curl. An agent gets a
prompt.** Both end at the same installed-activated-verified state.

### 🤖 Agent install (the future default)

Paste this prompt into any coding agent (Claude Code, Codex, Gemini, Cursor,
opencode…). The agent reads the installer, runs it, then proves it works — no
copy-pasting flags:

```text
Install, activate, and verify that https://github.com/SirTerrific/tokenwar works.

Steps:
1. Install: run `curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash -s -- --all`
   (fetch and read the script first if you want to inspect it — it only wires
   the statusline, shell functions, the 4 Claude plugins, RTK, pxpipe,
   Graphify, and the OpenWiki CLI, each at its latest version).
2. Activate: reload the shell (`source ~/.bashrc`) so the tokenwar / codex /
   gemini / kimi / opencode wrappers take effect. For Claude Code, restart it so
   the statusLine loads.
3. Verify: run `tokenwar status` — every one of the 7 tools must report OK.
   Then run `tokenwar check` (must print COMPLEMENTARY) and `tokenwar gain`
   (must show real per-tool token savings, not all N/A).
4. Report back the status table and the total tokens saved. If any tool is
   red, run `tokenwar upgrade` and re-check.
```

One line, if your agent likes it terse:

```text
Install, activate, and verify https://github.com/SirTerrific/tokenwar — run its install.sh --all, reload the shell, then confirm `tokenwar status` shows all 7 tools OK, `tokenwar check` says COMPLEMENTARY, and `tokenwar gain` reports real savings.
```

### 👤 Human install

One command installs the whole stack: the 4 Claude Code plugins, **RTK**,
**pxpipe**, **Graphify**, the **OpenWiki** CLI, statusline, shell
functions, Copilot wiring, and RTK's hook:

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash -s -- --all
```

Then activate + verify:

```bash
source ~/.bashrc      # load the shell wrappers (or open a new terminal)
tokenwar status       # all 7 tools should report OK
tokenwar check        # must print COMPLEMENTARY
tokenwar gain         # real per-tool token savings
```

Restart Claude Code to load the plugins. `--all` includes `--with-plugins`,
`--with-rtk`, `--with-pxpipe`, `--with-graphify`, `--with-openwiki`, and
`--with-copilot`; use individual flags for one part. OpenWiki requires Node.js
22 or newer. Installation does not run `openwiki --init`, because that command
writes project documentation and invokes an LLM.

`--with-plugins` (and so `--all`) also adds a short, marked block to your global
`~/.claude/CLAUDE.md` telling Claude to route large outputs (logs, test output,
JSON, big diffs) through context-mode's `ctx_execute`. Without it Claude rarely
uses the sandbox, and the plugin saves little. Re-running the installer replaces
the block instead of duplicating it; `uninstall.sh` removes it and leaves the
rest of the file untouched.

Prefer no surprise mutations? Drop the flags — `… | bash` just wires the statusline + shell functions, then `/tokenwar activate` installs the plugins on confirmation:

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash
/tokenwar activate
```

The bare installer does not install any managed tool. When OpenWiki is absent,
it prints a strong recommendation for active team repositories and the explicit
`--with-openwiki` command. See [shared project memory](project-memory.md) for
initialization and CI updates.

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/uninstall.sh | bash
```

### Manual install

```bash
git clone https://github.com/SirTerrific/tokenwar ~/.claude/skills/tokenwar
chmod +x ~/.claude/skills/tokenwar/scripts/*.sh

# Diagnose current state
bash ~/.claude/skills/tokenwar/scripts/status.sh

# Verify complementarity
bash ~/.claude/skills/tokenwar/scripts/check.sh

# Token savings report (per-tool + monthly $ value)
bash ~/.claude/skills/tokenwar/scripts/gain.sh
```

`gain.sh` reads each tool from its **own native telemetry** — never fabricated:
RTK (`rtk gain`), context-mode (its own stores: diverted and indexed bytes; sandbox volume is noted, not counted), claude-mem
(`~/.claude-mem/claude-mem.db` discovery tokens minus read cost; older releases: `chroma-sync-state.json` counts), pxpipe
(`~/.pxpipe/events.jsonl` proxy events), and graphify (`graphify benchmark` on
`~/.graphify/global-graph.json`). caveman is a
style-only nudge with no measurable buffer, so it is always `N/A`; graphify's
benchmark is a per-query ratio rather than a cumulative counter, so its ratio is
printed in the note while its token column stays `N/A` and it never inflates the
TOTAL. It also
prints a per-month breakdown of RTK, context-mode and claude-mem, valuing each month's
saved tokens at the Claude Opus 5.5 input list price (the API-equivalent $ saved).
