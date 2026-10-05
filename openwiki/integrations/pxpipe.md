---
type: integration
title: pxpipe integration (terminal and desktop)
description: How TokenWar routes Claude Code through pxpipe — the terminal `claude` wrapper (pxpipe warp) and the desktop proxy (pxpipe-desktop.mjs + settings.json + Startup shortcut).
tags: [pxpipe, proxy, windows, desktop, claude-code]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-5745bdc3f982182a15424be8
    resource: repo://docs/windows.md
  - id: openwiki-source-6029420e652f310e6603f7e9
    resource: repo://scripts/pxpipe-claude.sh
  - id: openwiki-source-d72cf6b9f5aa93f42ef6c25e
    resource: repo://scripts/pxpipe-desktop.mjs
  - id: openwiki-source-d1cc8f4e3d97c7f80cc54992
    resource: repo://scripts/pxpipe-desktop.sh
  - id: openwiki-source-c6ad78c4f811fe2c4e420c25
    resource: repo://tests/pxpipe-desktop.bats
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# pxpipe integration (terminal and desktop)

[pxpipe](https://github.com/teamchong/pxpipe) is a local proxy (`127.0.0.1:47821`) that rewrites the bulky parts of a `/v1/messages` request (system prompt, tool docs, history) into PNG image blocks before it reaches Anthropic. It only saves tokens on requests that **actually pass through it**. TokenWar has two entry points, one for each kind of Claude client:

| Client | Mechanism | Script | Command |
|---|---|---|---|
| Terminal `claude` | `pxpipe warp -- claude` | `scripts/pxpipe-claude.sh` | automatic via the `claude()` shell function |
| Claude desktop app (and Claude Code it spawns) | HTTPS proxy on `127.0.0.1:47822` + `settings.json` env | `scripts/pxpipe-desktop.sh` + `scripts/pxpipe-desktop.mjs` | `tokenwar pxpipe desktop on\|off\|status` |

Neither path sets `ANTHROPIC_BASE_URL`: the desktop app pins it to `https://api.anthropic.com`, so a base-URL proxy never sees its traffic.

## Terminal: `pxpipe-claude.sh`

`install.sh` (with `--with-pxpipe`) writes a `claude()` shell function into the tokenwar block of `~/.bashrc` that calls `scripts/pxpipe-claude.sh`. The script:

1. **Skips the proxy for commands that never call the model** — `-v`, `--version`, `-h`, `--help`, `update`, `doctor`, `config`, `mcp`, `plugin(s)`, `install`, `setup-token`, `migrate-installer` exec plain `claude`.
2. **Falls back to plain `claude`** when `TOKENWAR_PXPIPE=off` or `pxpipe` is not on `PATH`.
3. **Starts the proxy if needed**: if `http://127.0.0.1:47821/` does not answer 200, it launches `pxpipe` detached (`nohup`, logging to `~/.pxpipe/proxy.log`) so later sessions reuse it, and polls for up to `TW_PXPIPE_WAIT_SECS` (default 15) seconds. If it never comes up, it runs plain `claude` — the wrapper never blocks a launch.
4. **Execs `pxpipe warp -- claude "$@"`.** `warp` gives the child `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS`, so no base URL is needed and pxpipe's CA is trusted only by that process tree — nothing is installed in the Windows certificate store.

## Desktop: `pxpipe-desktop.sh` + `pxpipe-desktop.mjs`

Approach adapted from [DivyeshPatro/pxpipe-windows](https://github.com/DivyeshPatro/pxpipe-windows). The desktop app ignores `ANTHROPIC_BASE_URL` but the Claude Code it spawns honours `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS` from the `env` block of `~/.claude/settings.json`.

### The proxy (`pxpipe-desktop.mjs`)

A long-lived Node HTTPS (CONNECT) proxy on `127.0.0.1:47822` (`TW_PXPIPE_CONNECT_PORT` overrides), built from pxpipe's own `dist/warp` modules (`ca.js`, `connect.js`, `route.js`) found under `npm root -g`/`pxpipe-proxy` (`TW_PXPIPE_ROOT` overrides):

- loads or creates pxpipe's CA in `~/.pxpipe` (`--ca-path` prints its path and exits);
- decrypts only `api.anthropic.com` and diverts `/v1/messages*` to `http://127.0.0.1:47821`; every other host is tunnelled untouched;
- supervises the pxpipe proxy itself: starts it when down, re-checks every 30 s, restarts it 5 s after it exits;
- exits quietly on `EADDRINUSE` (another instance already serves the port).

### The wiring (`tokenwar pxpipe desktop …`)

| Subcommand | Effect |
|---|---|
| `on` | Requires `pxpipe` (0.14+, for its CA). Starts the proxy hidden if it is not up (log `~/.pxpipe/desktop.log`, waits up to `TW_PXPIPE_WAIT_SECS`, default 20 s). **Only if it came up**, adds a Startup-folder shortcut `tokenwar-pxpipe-desktop.lnk` (hidden mintty running `pxpipe-desktop.sh run`) and writes `HTTPS_PROXY`, `NO_PROXY=localhost,127.0.0.1,::1` and `NODE_EXTRA_CA_CERTS` into `settings.json` (first run backs it up to `settings.json.tokenwar-pxpipe.bak`). Then quit the desktop app from the tray and reopen it. |
| `off` | Removes only the keys it owns (`HTTPS_PROXY` only while it still points at this proxy — a foreign proxy is left alone) and the Startup shortcut. The running proxy becomes unused and stops at logoff. |
| `status` | Reports settings wiring, desktop proxy, pxpipe proxy and autostart; warns loudly when settings are wired to a proxy that is down. |
| `run` | The supervised loop the Startup shortcut runs: restarts the daemon if it dies. |

Autostart uses a Startup shortcut rather than `schtasks /SC ONLOGON`, which needs admin rights. Off Windows, `on` warns that there is no autostart; run `tokenwar pxpipe desktop run` under your own supervisor.

**Caveats** (from pxpipe-windows): while wired, Claude Code needs the proxy running — if Claude stops answering, run `tokenwar pxpipe desktop off`. The desktop app may rewrite `settings.json`; `status` shows the wiring was dropped and `on` restores it.

## Which models are imaged

pxpipe only images models listed in `PXPIPE_MODELS` (default: Fable 5 and Opus 5.5). To include Sonnet 5.5, export it **before the proxy starts** (e.g. in `~/.bashrc`):

```bash
export PXPIPE_MODELS="claude-fable-5,claude-opus-5-5,claude-sonnet-5-5,gemini"
```

The dashboard's model chips are in-memory only. Other models are passed through as `unsupported_model`.

## Savings

<!-- openwiki: broken internal link [/openwiki/concepts/savings-accounting.md] link "/openwiki/concepts/savings-accounting.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
`tokenwar gain` reports pxpipe's own figure from `pxpipe stats --json` (falling back to `~/.pxpipe/events.jsonl`); see [Savings accounting](/openwiki/concepts/savings-accounting.md).

## Tests

- `tests/pxpipe-claude.bats` — warp when up; start-then-warp; fallback when the proxy will not start or pxpipe is missing; `TOKENWAR_PXPIPE=off`; non-model commands skip the proxy.
- `tests/pxpipe-desktop.bats` — `on` keeps other settings and never wires to a proxy that did not start; Startup shortcut add/remove; `off` removes only its keys and spares a foreign proxy; `status` flags a down proxy; dispatch from `tokenwar pxpipe desktop`.

<!-- openwiki: broken internal link [/openwiki/platform/windows.md] link "/openwiki/platform/windows.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
<!-- openwiki: broken internal link [/openwiki/workflows/install-and-uninstall.md] link "/openwiki/workflows/install-and-uninstall.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Related: [Windows platform notes](/openwiki/platform/windows.md) · [Install and uninstall](/openwiki/workflows/install-and-uninstall.md)
