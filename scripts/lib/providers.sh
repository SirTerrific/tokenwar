#!/usr/bin/env bash
# tokenwar providers — single-source registry for all AI coding providers.
#
# Each provider is indexed 0..N-1. Call provider_* functions with the index.
# To iterate: for i in $(seq 0 $((PROVIDER_COUNT - 1))); do ... done
#
# Telemetry sources (native, never fabricated):
#   Claude — RTK (rtk gain), context-mode (ctx_stats MCP), claude-mem (chroma-sync-state)
#   Codex  — ~/.codex/state_5.sqlite → threads.tokens_used (real per-session counts)
#   Gemini — no local token store; CLI detection only, telemetry N/A
#   Kimi   — ~/.kimi-code stores sessions/config, but no documented token store
#   opencode — ~/.local/share/opencode/opencode.db → session token cols (real)
#
# The two SQLite-backed sources are read through tw_sqlite_rows, which runs the
# same SQL under python3 or node:sqlite — see the engine note there.

set -euo pipefail

TW_PROVIDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=osdetect.sh
source "${TW_PROVIDERS_DIR}/osdetect.sh"

# These constants form the registry's public API — they are read by the scripts
# that source this file (gain.sh, status.sh, check.sh, check-updates.sh,
# tokenwar-statusline.sh), not within this file, hence the SC2034 suppressions.
# shellcheck disable=SC2034
readonly PROVIDER_COUNT=5
# shellcheck disable=SC2034
readonly PROVIDER_IDX_CODEX=1
# shellcheck disable=SC2034
readonly PROVIDER_IDX_GEMINI=2
# shellcheck disable=SC2034
readonly PROVIDER_IDX_KIMI=3
# shellcheck disable=SC2034
readonly PROVIDER_IDX_OPENCODE=4

# Store locations. The env overrides stay authoritative (tests and relocated
# installs rely on them); tw_data_dir/tw_config_dir only supply the default, and
# on Windows they also consider the %APPDATA%/%LOCALAPPDATA% locations.
readonly CODEX_HOME="${CODEX_HOME:-$(tw_data_dir codex)}"
readonly CODEX_STATE_DB="${CODEX_HOME}/state_5.sqlite"
readonly KIMI_CODE_HOME="${KIMI_CODE_HOME:-$(tw_config_dir kimi)}"
readonly OPENCODE_DATA_HOME="${OPENCODE_DATA_HOME:-$(tw_data_dir opencode)}"
readonly OPENCODE_STATE_DB="${OPENCODE_DATA_HOME}/opencode.db"
# CHARS_PER_TOKEN is defined in gain.sh (primary consumer)

# ── SQLite access ─────────────────────────────────────────────────────
#
# Codex and opencode both keep their token counts in SQLite. python3 was the
# only reader, which makes both sources unreadable on a stock Windows box:
# Windows ships a python3 "app execution alias" that merely opens the Microsoft
# Store, so `command -v python3` succeeds while every actual run fails. node is
# already a hard dependency of tokenwar (every script parses JSON with it) and
# node:sqlite has been available since Node 22, so it is the natural fallback.
#
# Engines are probed once — by RUNNING them, never by `command -v` alone.
TW_SQLITE_ENGINE=""
tw_sqlite_engine() {
    if [[ -z "$TW_SQLITE_ENGINE" ]]; then
        if command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' >/dev/null 2>&1; then
            TW_SQLITE_ENGINE="python3"
        elif command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' >/dev/null 2>&1; then
            TW_SQLITE_ENGINE="node"
        else
            TW_SQLITE_ENGINE="none"
        fi
    fi
    printf '%s' "$TW_SQLITE_ENGINE"
}

# tw_sqlite_rows <db> <sql> — run a read-only query; echo one line per row with
# fields space-separated and NULL as empty. Silent (empty output) on any failure.
tw_sqlite_rows() {
    local db sql
    # Both engines are native Windows binaries and cannot open an MSYS path.
    db="$(tw_node_path "$1")"
    sql="$2"
    case "$(tw_sqlite_engine)" in
        python3)
            TW_DB="$db" TW_SQL="$sql" python3 -c '
import os, sqlite3, sys
try:
    # Read-only, so a report never mutates the user store. Normalise to
    # file:///<abs> so a Windows drive letter is a path segment, not a scheme.
    p = os.environ["TW_DB"].replace("\\", "/")
    if not p.startswith("/"):
        p = "/" + p
    db = sqlite3.connect("file://" + p + "?mode=ro", uri=True)
    for row in db.execute(os.environ["TW_SQL"]).fetchall():
        print(" ".join("" if v is None else str(v) for v in row))
except Exception:
    sys.exit(0)
' 2>/dev/null || printf ''
            ;;
        node)
            TW_DB="$db" TW_SQL="$sql" node -e '
try {
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(process.env.TW_DB, { readOnly: true });
    for (const row of db.prepare(process.env.TW_SQL).all()) {
        console.log(Object.values(row).map(v => v === null ? "" : String(v)).join(" "));
    }
} catch { process.exit(0); }
' 2>/dev/null || printf ''
            ;;
        *) printf '' ;;
    esac
}

# tw_no_sqlite_note — why a SQLite-backed provider is unreadable, for the N/A row.
tw_no_sqlite_note() {
    printf 'no SQLite reader (need a working python3 or node >= 22)'
}

# tw_human_tokens <n> — 1234567 -> 1.2M, 30000 -> 30.0K, 42 -> 42.
tw_human_tokens() {
    awk -v t="$1" 'BEGIN {
        if (t >= 1000000)   printf "%.1fM", t / 1000000;
        else if (t >= 1000) printf "%.1fK", t / 1000;
        else                printf "%d", t;
    }'
}

# ── provider metadata ────────────────────────────────────────────────

provider_id() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
        4) echo "opencode" ;;
    esac
}

provider_name() {
    case "$1" in
        0) echo "Claude Code" ;;
        1) echo "Codex"       ;;
        2) echo "Gemini CLI"  ;;
        3) echo "Kimi Code CLI" ;;
        4) echo "opencode"    ;;
    esac
}

provider_cli() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
        4) echo "opencode" ;;
    esac
}

provider_input_usd_per_mtok() {
    case "$1" in
        0) echo "5.00"  ;;  # Claude Opus 4.8 input (claude-api skill, 2026-05-26)
        1) echo "1.25"  ;;  # Codex (gpt-5-codex) input — VERIFY at openai.com/pricing
        2) echo "1.25"  ;;  # Gemini 2.5 Pro input — VERIFY at ai.google.dev/pricing
        3) echo "0.30"  ;;  # Kimi K2/Kimi Code input — VERIFY at platform.kimi.ai/pricing
        4) echo "3.00"  ;;  # opencode is model-agnostic (BYO provider) — representative input rate, VERIFY per your model
    esac
}

provider_label() {
    case "$1" in
        0) echo "Claude Opus 4.8"      ;;
        1) echo "Codex (gpt-5-codex)"  ;;
        2) echo "Gemini 2.5 Pro"        ;;
        3) echo "Kimi Code"             ;;
        4) echo "opencode (BYO model)"  ;;
    esac
}

provider_config_dir() {
    case "$1" in
        0) tw_config_dir claude ;;
        1) tw_config_dir codex ;;
        2) tw_config_dir gemini ;;
        3) echo "$KIMI_CODE_HOME" ;;
        4) tw_config_dir opencode ;;
    esac
}

provider_is_installed() {
    local cli
    cli=$(provider_cli "$1")
    command -v "$cli" >/dev/null 2>&1
}

provider_version() {
    local cli
    cli=$(provider_cli "$1")
    if ! command -v "$cli" >/dev/null 2>&1; then echo "-"; return; fi
    # A provider CLI reached through an npm .cmd shim can answer with CRLF; the
    # version is the last field, so the \r would ride along into every compare.
    "$cli" --version 2>/dev/null | tw_strip_cr | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
}

# ── telemetry: total tokens saved per provider ────────────────────────
#
# Returns: human_readable|note|numeric_tokens
# Codex reads its own SQLite (real tokens_used per session).
# Gemini has no local token store → honest N/A.
# Claude telemetry is handled externally (RTK + context-mode + claude-mem
# are surfaced as tools, not as a single provider line).

provider_telemetry_total() {
    case "$1" in
        0) echo "N/A|Claude aggregated from tools (see per-tool rows)|0" ;;
        1) codex_telemetry_total ;;
        2) gemini_telemetry_total ;;
        3) kimi_telemetry_total ;;
        4) opencode_telemetry_total ;;
    esac
}

provider_telemetry_monthly() {
    case "$1" in
        0) echo "" ;;  # Claude monthly from RTK — handled separately
        1) codex_telemetry_monthly ;;
        2) gemini_telemetry_monthly ;;
        3) kimi_telemetry_monthly ;;
        4) opencode_telemetry_monthly ;;
    esac
}

# ── Codex native telemetry (SQLite) ───────────────────────────────────

# COALESCE keeps the first field non-NULL: rows are space-joined, so a leading
# NULL (empty table) would otherwise be eaten by `read` and shift COUNT into it.
readonly CODEX_SQL_TOTAL="SELECT COALESCE(SUM(tokens_used), 0), COUNT(*) FROM threads WHERE tokens_used > 0"
readonly CODEX_SQL_MONTHLY="SELECT strftime('%Y-%m', datetime(created_at, 'unixepoch')) AS m,
           SUM(tokens_used), COUNT(*)
    FROM threads WHERE tokens_used > 0 AND created_at > 0
    GROUP BY m ORDER BY m"

codex_telemetry_total() {
    if [[ ! -f "$CODEX_STATE_DB" ]]; then
        echo "N/A|Codex state DB not found ($CODEX_STATE_DB)|0"; return
    fi
    if [[ "$(tw_sqlite_engine)" == "none" ]]; then
        echo "N/A|$(tw_no_sqlite_note) to read Codex DB|0"; return
    fi
    local tokens sessions
    read -r tokens sessions <<<"$(tw_sqlite_rows "$CODEX_STATE_DB" "$CODEX_SQL_TOTAL")"
    # Unreadable DB yields no rows; an empty one yields 0. Both are honest N/A.
    if [[ -z "${tokens:-}" || "$tokens" == "0" ]]; then
        echo "N/A|no Codex sessions with tokens|0"; return
    fi
    echo "$(tw_human_tokens "$tokens")|${sessions} Codex sessions (real tokens_used)|${tokens}"
}

codex_telemetry_monthly() {
    [[ -f "$CODEX_STATE_DB" ]] || { echo ""; return; }
    [[ "$(tw_sqlite_engine)" != "none" ]] || { echo ""; return; }
    tw_sqlite_rows "$CODEX_STATE_DB" "$CODEX_SQL_MONTHLY"
}

# ── Gemini telemetry — no local token store ───────────────────────────

gemini_telemetry_total() {
    if ! command -v gemini >/dev/null 2>&1; then
        echo "N/A|Gemini CLI not installed|0"; return
    fi
    # Gemini has no local token-count store (no SQLite, no history.jsonl with
    # token fields). It stores sessions server-side. Honest N/A until Google
    # exposes token counts via CLI or API.
    echo "N/A|no local token telemetry (Gemini stores sessions server-side)|0"
}

gemini_telemetry_monthly() {
    echo ""  # No monthly data available
}

# ── Kimi telemetry — no documented local token-count store ───────────

kimi_telemetry_total() {
    if ! command -v kimi >/dev/null 2>&1; then
        echo "N/A|Kimi Code CLI not installed|0"; return
    fi
    echo "N/A|no documented local token telemetry (${KIMI_CODE_HOME})|0"
}

kimi_telemetry_monthly() {
    echo ""  # No monthly data available
}

# ── opencode native telemetry (SQLite) ───────────────────────────────
# opencode records real per-session token usage in its Drizzle SQLite DB
# (session.tokens_input/output/reasoning, time_created in epoch ms).

readonly OPENCODE_SQL_TOTAL="SELECT COALESCE(SUM(tokens_input+tokens_output+tokens_reasoning), 0), COUNT(*)
    FROM session WHERE (tokens_input+tokens_output) > 0"
readonly OPENCODE_SQL_MONTHLY="SELECT strftime('%Y-%m', datetime(time_created/1000, 'unixepoch')) AS m,
           SUM(tokens_input+tokens_output+tokens_reasoning), COUNT(*)
    FROM session WHERE (tokens_input+tokens_output) > 0 AND time_created > 0
    GROUP BY m ORDER BY m"

opencode_telemetry_total() {
    if [[ ! -f "$OPENCODE_STATE_DB" ]]; then
        echo "N/A|opencode DB not found ($OPENCODE_STATE_DB)|0"; return
    fi
    if [[ "$(tw_sqlite_engine)" == "none" ]]; then
        echo "N/A|$(tw_no_sqlite_note) to read opencode DB|0"; return
    fi
    local tokens sessions
    read -r tokens sessions <<<"$(tw_sqlite_rows "$OPENCODE_STATE_DB" "$OPENCODE_SQL_TOTAL")"
    # Unreadable DB yields no rows; an empty one yields 0. Both are honest N/A.
    if [[ -z "${tokens:-}" || "$tokens" == "0" ]]; then
        echo "N/A|no opencode sessions with tokens|0"; return
    fi
    echo "$(tw_human_tokens "$tokens")|${sessions} opencode sessions (real token cols)|${tokens}"
}

opencode_telemetry_monthly() {
    [[ -f "$OPENCODE_STATE_DB" ]] || { echo ""; return; }
    [[ "$(tw_sqlite_engine)" != "none" ]] || { echo ""; return; }
    tw_sqlite_rows "$OPENCODE_STATE_DB" "$OPENCODE_SQL_MONTHLY"
}
