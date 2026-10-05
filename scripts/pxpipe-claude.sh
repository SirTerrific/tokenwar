#!/usr/bin/env bash
# pxpipe-claude.sh — run Claude Code behind pxpipe, starting the proxy if needed.
#
# The shell integration's `claude` function calls this. pxpipe only saves tokens
# on requests that pass through it, and nothing routes Claude there by default:
# `pxpipe warp` does, without ANTHROPIC_BASE_URL (which the Claude desktop app
# overrides anyway) and without trusting any certificate system-wide — the CA it
# makes is trusted by the wrapped process only.
#
# Falls back to plain `claude` — never blocks a launch — when pxpipe is absent,
# the proxy cannot be started, or TOKENWAR_PXPIPE=off.
#
# Usage: pxpipe-claude.sh [claude args...]

set -uo pipefail

readonly CLAUDE_BIN="claude"
readonly PXPIPE_BIN="pxpipe"
readonly PXPIPE_URL="http://127.0.0.1:47821/"
readonly PXPIPE_LOG="${HOME}/.pxpipe/proxy.log"
readonly PXPIPE_START_WAIT_SECS="${TW_PXPIPE_WAIT_SECS:-15}"

warn() { printf '[tokenwar] %s\n' "$*" >&2; }

proxy_up() { curl -s -o /dev/null -m 2 -w '%{http_code}' "$PXPIPE_URL" 2>/dev/null | grep -q '^200$'; }

# Commands that never call the model: no reason to start a proxy for them.
case "${1:-}" in
    -v|--version|-h|--help|update|doctor|config|mcp|plugin|plugins|install|setup-token|migrate-installer)
        exec "$CLAUDE_BIN" "$@" ;;
esac

if [[ "${TOKENWAR_PXPIPE:-on}" == "off" ]] || ! command -v "$PXPIPE_BIN" >/dev/null 2>&1; then
    exec "$CLAUDE_BIN" "$@"
fi

if ! proxy_up; then
    mkdir -p "$(dirname "$PXPIPE_LOG")"
    # Detached, so it outlives this terminal and serves the next sessions too.
    nohup "$PXPIPE_BIN" >>"$PXPIPE_LOG" 2>&1 &
    disown 2>/dev/null || true
    for (( i = 0; i < PXPIPE_START_WAIT_SECS; i++ )); do
        proxy_up && break
        sleep 1
    done
    if ! proxy_up; then
        warn "pxpipe proxy did not start (see $PXPIPE_LOG) — running claude without it"
        exec "$CLAUDE_BIN" "$@"
    fi
fi

exec "$PXPIPE_BIN" warp -- "$CLAUDE_BIN" "$@"
