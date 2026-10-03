#!/usr/bin/env bash
# tokenwar gain — aggregate per-tool + per-provider token savings
#
# Each tool is read from its OWN native telemetry — we never fabricate:
#   RTK          — `rtk gain` (+ `rtk gain --monthly` for the $ breakdown)
#   context-mode — its SQLite stores under ~/.claude/context-mode (bytes kept
#                  out of context, its own strict formula). CTX_STATS_JSON, when
#                  a caller sets it, still overrides.
#   claude-mem   — its claude-mem.db (real per-observation discovery tokens);
#                  older releases: chroma-sync-state.json (counts, estimated).
#   caveman      — a SessionStart style nudge with no buffer transform, hence
#                  no measurable byte delta → honest N/A (no telemetry surface).
#   pxpipe       — ~/.pxpipe/events.jsonl (real proxy-side token deltas).
#   graphify     — `graphify benchmark` on the global graph. It reports a
#                  per-query reduction ratio, not a cumulative saved-token
#                  counter, so the ratio goes in the note and the token column
#                  stays N/A — mixing a per-query figure into the cumulative
#                  TOTAL would overstate the stack.
#
# Each AI provider is read from its OWN native telemetry:
#   Codex  — ~/.codex/state_5.sqlite → threads.tokens_used (real per-session)
#   Gemini — no local token store → honest N/A
#   Kimi   — no documented local token-count store → honest N/A
#   opencode — ~/.local/share/opencode/opencode.db → session token cols (real)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"

readonly CHARS_PER_TOKEN=4
readonly RTK_BIN="rtk"

# claude-mem legacy telemetry (before 13): chroma-sync-state.json holds real per-project
# counts of stored observations/summaries (the compact memory it injects on
# resume instead of re-reading full transcripts). Counts are real; the
# tokens-per-item multiplier is a conservative estimate (memory items are short
# — typically a sentence or two), surfaced as "~est" and never as hard truth.
readonly MEM_SYNC_STATE="${HOME}/.claude-mem/chroma-sync-state.json"
# claude-mem 13+ dropped chroma-sync-state.json; its SQLite store records, per
# observation, the tokens spent producing it (discovery_tokens). claude-mem's own
# context header reports savings as that work minus the cost of reading the
# memory back — read cost being (title + subtitle + narrative + facts JSON)
# characters / 4. This is the same formula, summed over every observation.
readonly MEM_DB="${HOME}/.claude-mem/claude-mem.db"
readonly MEM_SQL_SAVINGS="SELECT COUNT(*), COALESCE(SUM(discovery_tokens), 0),
           COALESCE(SUM((COALESCE(length(title),0) + COALESCE(length(subtitle),0)
                + COALESCE(length(narrative),0) + COALESCE(length(facts) + 2, 2) + 3) / 4), 0),
           COUNT(DISTINCT project)
    FROM observations"
readonly MEM_EST_TOKENS_PER_ITEM=40
readonly CTX_DATA_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode"
readonly CTX_SQL_AVOIDED="SELECT COALESCE(SUM(bytes_avoided), 0), COUNT(*) FROM session_events"
readonly CTX_SQL_CONTENT="SELECT COALESCE(SUM(LENGTH(content) + LENGTH(title)), 0) FROM chunks"
readonly PXPIPE_EVENTS_LOG="${HOME}/.pxpipe/events.jsonl"

# graphify keeps per-repo graphs under <repo>/graphify-out/ and an optional
# cross-repo graph at ~/.graphify/global-graph.json. Only the global one is a
# host-level source, so that is what `tokenwar gain` measures.
readonly GRAPHIFY_BIN="graphify"
readonly GRAPHIFY_GLOBAL_GRAPH="${HOME}/.graphify/global-graph.json"
readonly GRAPHIFY_BENCHMARK_TIMEOUT_SECS=30

# Financial valuation constants — provider-specific rates live in providers.sh.
# These are kept here for the tool-level (RTK) monthly section which is
# Claude-specific.
readonly CLAUDE_INPUT_USD_PER_MTOK="5.00"
readonly CLAUDE_LABEL="Claude Opus 4.8"
readonly MONTH_ROW_RE='^[0-9]{4}-[0-9]{2}[[:space:]]'

readonly COL_BOLD=$'\033[1m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

json_mode=false
for arg in "$@"; do
    case "$arg" in
        --json) json_mode=true ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# === RTK ===
# Returns: human-readable saved | note | numeric tokens saved
rtk_summary() {
    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then
        echo "N/A|RTK not installed|0"; return
    fi
    local out
    out="$("$RTK_BIN" gain 2>/dev/null || true)"
    # "Total commands:    18956" ends the line, so a CRLF build would hand awk a
    # count of "18956\r" and print a control char straight into the table.
    out="${out//$'\r'/}"
    if [[ -z "$out" ]]; then
        echo "N/A|rtk gain returned nothing|0"; return
    fi
    # Parse lines like:  Tokens saved:      44.7M (68.3%)
    #                    Total commands:    18956
    local saved_human pct count saved_num
    saved_human=$(echo "$out" | awk '/Tokens saved:/ {print $3; exit}')
    pct=$(echo "$out"         | awk -F'[()%]' '/Tokens saved:/ {print $2; exit}')
    count=$(echo "$out"       | awk '/Total commands:/ {print $3; exit}')
    saved_human="${saved_human:-?}"; pct="${pct:-?}"; count="${count:-?}"
    # Convert human suffix (M/K/G) to integer
    saved_num=$(echo "$saved_human" | awk '
        /M$/ { gsub(/M$/,""); printf "%.0f", $1 * 1e6; exit }
        /K$/ { gsub(/K$/,""); printf "%.0f", $1 * 1e3; exit }
        /G$/ { gsub(/G$/,""); printf "%.0f", $1 * 1e9; exit }
        { printf "%.0f", $1+0; exit }
    ')
    saved_num="${saved_num:-0}"
    echo "${saved_human}|${count} commands (${pct}%)|${saved_num}"
}

# === context-mode ===
# Read from context-mode's own SQLite stores, so `tokenwar gain` measures it from
# any shell. ctx_stats (the MCP tool) now answers in prose, not JSON, so the old
# caller-injected CTX_STATS_JSON can no longer be produced; it is still honoured
# when set. The measure is context-mode's strict "kept out" formula (its
# ADR-0004): bytes its hooks diverted (session_events.bytes_avoided) plus the
# bytes it indexed instead of returning (content chunks). Hook-captured event
# data is excluded, as that ADR rules: it never entered the context window.
ctx_summary() {
    if [[ -z "${CTX_STATS_JSON:-}" ]]; then
        local sessions=() contents=()
        shopt -s nullglob
        sessions=("${CTX_DATA_DIR}"/sessions/*.db)
        contents=("${CTX_DATA_DIR}"/content/*.db)
        shopt -u nullglob
        if (( ${#sessions[@]} + ${#contents[@]} == 0 )); then
            echo "N/A|context-mode store not found (${CTX_DATA_DIR})|0"; return
        fi
        if [[ "$(tw_sqlite_engine)" == "none" ]]; then
            echo "N/A|$(tw_no_sqlite_note) to read context-mode|0"; return
        fi
        local avoided events content bytes tokens
        read -r avoided events <<<"$(tw_sqlite_rows_each "$CTX_SQL_AVOIDED" ${sessions[@]+"${sessions[@]}"} \
            | awk '{ a += $1; n += $2 } END { printf "%d %d", a, n }')"
        content="$(tw_sqlite_rows_each "$CTX_SQL_CONTENT" ${contents[@]+"${contents[@]}"} \
            | awk '{ c += $1 } END { printf "%d", c }')"
        bytes=$((avoided + content))
        if (( bytes == 0 )); then
            echo "N/A|no measured context-mode redirects yet|0"; return
        fi
        tokens=$((bytes / CHARS_PER_TOKEN))
        echo "$(tw_human_tokens "$tokens")|$((bytes / 1024)) KB kept out of context (diverted + indexed) over ${events} captures|${tokens}"
        return
    fi
    node --input-type=module -e "
        const j = JSON.parse(process.env.CTX_STATS_JSON);
        const kb = j.total_size_kb || j.totalSizeKb || j.size_kb || 0;
        const entries = j.entry_count || j.entries || j.count || 0;
        const tokens = Math.round((kb * 1024) / $CHARS_PER_TOKEN);
        const human = tokens >= 1e6 ? (tokens/1e6).toFixed(1)+'M' :
                       tokens >= 1e3 ? (tokens/1e3).toFixed(1)+'K' : String(tokens);
        console.log(human + '|' + entries + ' entries indexed|' + tokens);
    " 2>/dev/null || echo "N/A|ctx_stats JSON parse failed|0"
}

# === claude-mem from its native store ===
# claude-mem.db when it carries discovery-token telemetry (real numbers);
# otherwise the legacy chroma-sync-state.json (real counts, tokens estimated).
mem_summary() {
    if [[ -f "$MEM_DB" && "$(tw_sqlite_engine)" != "none" ]]; then
        local obs work cost projects
        read -r obs work cost projects <<<"$(tw_sqlite_rows "$MEM_DB" "$MEM_SQL_SAVINGS")"
        # An unreadable DB, or rows predating discovery_tokens, fall through.
        if [[ -n "${work:-}" && "$work" -gt "${cost:-0}" ]]; then
            echo "$(tw_human_tokens "$((work - cost))")|${obs} obs across ${projects} projects: $(tw_human_tokens "$work") work tokens recalled for $(tw_human_tokens "$cost") read (claude-mem.db)|$((work - cost))"
            return
        fi
    fi
    if [[ ! -f "$MEM_SYNC_STATE" ]]; then
        echo "N/A|claude-mem store not found ($MEM_SYNC_STATE)|0"; return
    fi
    MEM_STATE="$(tw_node_path "$MEM_SYNC_STATE")" PER_ITEM="$MEM_EST_TOKENS_PER_ITEM" \
    node --input-type=module -e "
        import { readFileSync } from 'fs';
        let j; try { j = JSON.parse(readFileSync(process.env.MEM_STATE,'utf8')); } catch { console.log('N/A|claude-mem state parse failed|0'); process.exit(0); }
        let obs=0, sum=0, projects=0;
        for (const k of Object.keys(j)) {
            const v = j[k]; if (!v || typeof v !== 'object') continue;
            obs += v.observations||0; sum += v.summaries||0; projects++;
        }
        const items = obs + sum;
        if (items === 0) { console.log('N/A|no memories stored yet|0'); process.exit(0); }
        const tokens = items * Number(process.env.PER_ITEM);
        const human = tokens>=1e6 ? (tokens/1e6).toFixed(1)+'M' : tokens>=1e3 ? (tokens/1e3).toFixed(1)+'K' : String(tokens);
        console.log(human + '|~est: ' + obs + ' obs + ' + sum + ' summaries across ' + projects + ' projects|' + tokens);
    " 2>/dev/null || echo "N/A|claude-mem state read failed|0"
}

# === caveman ===
# caveman is a SessionStart prompt-style nudge ("write terse"); it transforms no
# buffer, so there is no before/after byte delta to measure. Honest N/A — we do
# not invent a number for a tool with no telemetry surface.
caveman_summary() {
    echo "N/A|style-only hook — no measurable buffer (no native telemetry)|0"
}

# === pxpipe from its native proxy events log ===
# pxpipe turns selected prompt/context text into PNG payloads before the API
# call. Its proxy writes one JSON object per request; field names have changed
# across releases, so accept explicit saved-token fields first, then baseline
# minus actual token fields.
pxpipe_summary() {
    if [[ ! -f "$PXPIPE_EVENTS_LOG" ]]; then
        echo "N/A|pxpipe events log not found ($PXPIPE_EVENTS_LOG)|0"; return
    fi
    PXPIPE_EVENTS="$(tw_node_path "$PXPIPE_EVENTS_LOG")" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const pick = (o, keys) => {
            for (const k of keys) {
                const v = k.split(".").reduce((acc, p) => acc && acc[p], o);
                if (typeof v === "number" && Number.isFinite(v)) return v;
            }
            return undefined;
        };
        const savedKeys = ["saved_tokens", "tokens_saved", "savedInputTokens", "input_tokens_saved", "savings.tokens", "savings.input_tokens"];
        const baselineKeys = ["baseline_input_eff", "baselineInputEff", "baseline_eff", "baseline_tokens", "baselineInputTokens", "counterfactual_input_eff"];
        const actualKeys = ["actual_input_eff", "actualInputEff", "actual_eff", "actual_tokens", "actualInputTokens", "proxied_input_eff"];
        let saved = 0;
        let compressed = 0;
        let parsed = 0;
        for (const line of readFileSync(process.env.PXPIPE_EVENTS, "utf8").split("\n")) {
            if (!line.trim()) continue;
            let event;
            try { event = JSON.parse(line); } catch { continue; }
            parsed++;
            if (event.applied === false || event.compressed === false) continue;
            let delta = pick(event, savedKeys);
            if (delta === undefined) {
                const baseline = pick(event, baselineKeys);
                const actual = pick(event, actualKeys);
                if (baseline !== undefined && actual !== undefined) delta = baseline - actual;
            }
            if (typeof delta === "number" && delta > 0) {
                saved += delta;
                compressed++;
            }
        }
        if (saved <= 0) {
            console.log("N/A|no pxpipe token savings in events log (" + parsed + " events)|0");
            process.exit(0);
        }
        const human = saved >= 1e6 ? (saved/1e6).toFixed(1)+"M" : saved >= 1e3 ? (saved/1e3).toFixed(1)+"K" : String(Math.round(saved));
        console.log(human + "|" + compressed + " compressed requests (native pxpipe events)|" + Math.round(saved));
    ' 2>/dev/null || echo "N/A|pxpipe events log read failed|0"
}

# === graphify from its own benchmark ===
# `graphify benchmark <graph.json>` is deterministic and offline: it compares the
# naive "read the whole corpus" token cost against the average cost of answering
# through the graph. That is a RATIO per query, not a running total of tokens
# already saved, so it is reported as N/A + a note rather than being summed into
# TOTAL. Reporting it as a cumulative number would double-count every future
# query the user has not made yet.
graphify_summary() {
    if ! command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; then
        echo "N/A|graphify CLI not installed|0"; return
    fi
    if [[ ! -f "$GRAPHIFY_GLOBAL_GRAPH" ]]; then
        echo "N/A|no global graph — run \`graphify extract <repo> --global\` to register one|0"; return
    fi
    local raw
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout "$GRAPHIFY_BENCHMARK_TIMEOUT_SECS" "$GRAPHIFY_BIN" benchmark "$GRAPHIFY_GLOBAL_GRAPH" 2>/dev/null)
    else
        raw=$("$GRAPHIFY_BIN" benchmark "$GRAPHIFY_GLOBAL_GRAPH" 2>/dev/null)
    fi
    if [[ -z "$raw" ]]; then
        echo "N/A|graphify benchmark produced no output|0"; return
    fi
    GRAPHIFY_BENCH="$raw" node --input-type=module -e '
        const strip = s => s.replace(/\x1b\[[0-9;]*m/g, "");
        const raw = strip(process.env.GRAPHIFY_BENCH || "");
        const nodes = raw.match(/Graph:\s+([\d,]+)\s+nodes/);
        const reduction = raw.match(/Reduction:\s+([\d.]+)x/);
        if (!reduction) { console.log("N/A|graphify benchmark reported no reduction figure|0"); process.exit(0); }
        const where = nodes ? nodes[1] + " nodes in the global graph, " : "";
        console.log("N/A|" + where + reduction[1] + "x fewer tokens per query vs naive corpus read (graphify benchmark)|0");
    ' 2>/dev/null || echo "N/A|graphify benchmark parse failed|0"
}

# === json mode ===
if $json_mode; then
    # Gather per-tool summaries (reuse inline node blocks — just serialize)
    rtk_s=$(rtk_summary); ctx_s=$(ctx_summary); mem_s=$(mem_summary)
    caveman_s=$(caveman_summary); pxpipe_s=$(pxpipe_summary)
    graphify_s=$(graphify_summary)

    # Compute total tokens (sum numeric third field)
    total_tokens=0
    for s in "$rtk_s" "$ctx_s" "$mem_s" "$caveman_s" "$pxpipe_s" "$graphify_s"; do
        t=$(echo "$s" | awk -F'|' '{print $3}')
        total_tokens=$((total_tokens + ${t:-0}))
    done
    if (( total_tokens >= 1000000 )); then
        total_human="$(awk -v t="$total_tokens" 'BEGIN{printf "%.1fM", t/1000000}')"
    elif (( total_tokens >= 1000 )); then
        total_human="$(awk -v t="$total_tokens" 'BEGIN{printf "%.1fK", t/1000}')"
    else
        total_human="$total_tokens"
    fi

    # Gather provider totals
    provider_entries=""
    for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
        pid=$(provider_id "$i")
        pname=$(provider_name "$i")
        raw=$(provider_telemetry_total "$i")
        saved_p=""; note_p=""; tokens_p=""
        IFS='|' read -r saved_p note_p tokens_p <<<"$raw"
        tokens_p="${tokens_p:-0}"
        entry=$(PID="$pid" PNAME="$pname" SAVED="$saved_p" NOTE="$note_p" TOKENS="$tokens_p" node --input-type=module -e '
            const e = {
                id: process.env.PID,
                name: process.env.PNAME,
                saved: process.env.SAVED,
                saved_tokens: Number(process.env.TOKENS) || 0,
                note: process.env.NOTE
            };
            console.log(JSON.stringify(e));
        ')
        if [[ -z "$provider_entries" ]]; then
            provider_entries="$entry"
        else
            provider_entries="$provider_entries,$entry"
        fi
    done

    # Gather monthly data (RTK + providers) if any
    rtk_monthly_raw=""
    if command -v "$RTK_BIN" >/dev/null 2>&1; then
        rtk_monthly_raw="$("$RTK_BIN" gain --monthly 2>/dev/null || true)"
        rtk_monthly_raw="${rtk_monthly_raw//$'\r'/}"
    fi
    rtk_has_monthly=false
    if [[ -n "$rtk_monthly_raw" ]] && grep -qE "$MONTH_ROW_RE" <<<"$rtk_monthly_raw"; then
        rtk_has_monthly=true
    fi
    # Build monthly JSON via node (parse same way as text mode)
    monthly_json="{}"
    if $rtk_has_monthly; then
        # Use node to parse monthly rows into JSON array
        rtk_monthly_json=$(RTK_MONTHLY="$rtk_monthly_raw" CLAUDE_IN="$CLAUDE_INPUT_USD_PER_MTOK" node --input-type=module -e '
            const strip = s => s.replace(/\x1b\[[0-9;]*m/g, "");
            const RE = /^(\d{4}-\d{2})\s+\S+\s+\S+\s+\S+\s+(\S+)/;
            const toNum = h => { const m = String(h).trim().match(/^([\d.]+)\s*([KMGB]?)/i); if (!m) return 0; const u = (m[2]||"").toUpperCase(); return Math.round(parseFloat(m[1]) * ({K:1e3,M:1e6,G:1e9,B:1e9}[u]||1)); };
            const CL = parseFloat(process.env.CLAUDE_IN);
            const rows = [];
            for (const ln of strip(process.env.RTK_MONTHLY||"").split("\n")) {
                const m = ln.match(RE); if (!m) continue;
                const tok = toNum(m[2]); if (!tok) continue;
                rows.push({ month: m[1], saved: m[2], saved_tokens: tok, dollars: tok/1e6*CL });
            }
            console.log(JSON.stringify(rows));
        ' 2>/dev/null || echo "[]")
        monthly_json=$(echo "$rtk_monthly_json" | node --input-type=module -e '
            import { readFileSync } from "node:fs";
            const rtk = JSON.parse(process.argv[1] || "[]");
            console.log(JSON.stringify({ rtk }));
        ' "$rtk_monthly_json" 2>/dev/null || echo '{"rtk":[]}')
    fi
    # Provider monthly: collect each provider’s monthly lines
    provider_monthly_entries=""
    for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
        mraw=$(provider_telemetry_monthly "$i")
        [[ -z "$mraw" ]] && continue
        pid=$(provider_id "$i")
        # Convert "YYYY-MM tokens count" lines to JSON array via node
        pj=$(PID="$pid" MRAW="$mraw" node --input-type=module -e '
            const pid = process.env.PID;
            const raw = process.env.MRAW || "";
            const rows = [];
            for (const ln of raw.trim().split("\n")) {
                if (!ln.trim()) continue;
                const parts = ln.trim().split(/\s+/);
                if (parts.length < 2) continue;
                rows.push({ month: parts[0], tokens: parseInt(parts[1],10)||0, sessions: parseInt(parts[2],10)||0 });
            }
            console.log(JSON.stringify({ id: pid, rows }));
        ' 2>/dev/null)
        if [[ -z "$pj" ]]; then
            continue
        fi
        if [[ -z "$provider_monthly_entries" ]]; then
            provider_monthly_entries="$pj"
        else
            provider_monthly_entries="$provider_monthly_entries,$pj"
        fi
    done
    if [[ -n "$provider_monthly_entries" ]]; then
        # Merge provider monthly into monthly_json (which may already contain rtk)
        monthly_json=$(MONTHLY_JSON="$monthly_json" PROVIDER_MONTHLY="[$provider_monthly_entries]" node --input-type=module -e '
            const base = JSON.parse(process.env.MONTHLY_JSON || "{}");
            const prov = JSON.parse(process.env.PROVIDER_MONTHLY || "[]");
            if (prov.length) base.providers = prov;
            console.log(JSON.stringify(base));
        ' 2>/dev/null || echo "$monthly_json")
    fi

    RTK_S="$rtk_s" CTX_S="$ctx_s" MEM_S="$mem_s" CAVEMAN_S="$caveman_s" PXPIPE_S="$pxpipe_s" \
    GRAPHIFY_S="$graphify_s" \
    TOTAL_TOKENS="$total_tokens" TOTAL_HUMAN="$total_human" \
    PROVIDER_ENTRIES="[$provider_entries]" MONTHLY_JSON="$monthly_json" \
    node --input-type=module -e '
        const parse = s => {
            const [saved, note, tokens] = s.split("|");
            return { saved: saved || "N/A", saved_tokens: parseInt(tokens,10)||0, note: note || "" };
        };
        const tools = {
            "RTK": parse(process.env.RTK_S),
            "context-mode": parse(process.env.CTX_S),
            "claude-mem": parse(process.env.MEM_S),
            "caveman": parse(process.env.CAVEMAN_S),
            "pxpipe": parse(process.env.PXPIPE_S),
            "graphify": parse(process.env.GRAPHIFY_S)
        };
        // augment tools with tool name for easier assertions
        const toolsList = Object.entries(tools).map(([tool, v]) => ({ tool, ...v }));
        const total = { saved: process.env.TOTAL_HUMAN, saved_tokens: parseInt(process.env.TOTAL_TOKENS,10)||0 };
        const providers = JSON.parse(process.env.PROVIDER_ENTRIES || "[]");
        const monthly = JSON.parse(process.env.MONTHLY_JSON || "{}");
        const out = { tools, tools_list: toolsList, total, providers };
        if (Object.keys(monthly).length) out.monthly = monthly;
        console.log(JSON.stringify(out, null, 2));
    '
    exit 0
fi

# === render (text mode) ===
echo ""
echo "${COL_BOLD}# /tokenwar gain — token savings${COL_RESET}"
echo ""

# ── Tools table (Claude Code token-saving stack) ────────────────────
printf "  %-14s  %-10s  %s\n" "tool" "saved" "note"
echo   "  ─────────────────────────────────────────────────────────────"

total=0
for entry in \
    "RTK|$(rtk_summary)" \
    "context-mode|$(ctx_summary)" \
    "claude-mem|$(mem_summary)" \
    "caveman|$(caveman_summary)" \
    "pxpipe|$(pxpipe_summary)" \
    "graphify|$(graphify_summary)"; do
    tool="${entry%%|*}"
    summary="${entry#*|}"
    saved=""; note=""; tokens=""
    IFS='|' read -r saved note tokens <<<"$summary"
    printf "  %-14s  %-10s  %s\n" "$tool" "$saved" "${COL_DIM}${note}${COL_RESET}"
    total=$((total + ${tokens:-0}))
done

echo   "  ─────────────────────────────────────────────────────────────"
if (( total >= 1000000 )); then
    human="$(awk -v t="$total" 'BEGIN{printf "%.1fM", t/1000000}')"
elif (( total >= 1000 )); then
    human="$(awk -v t="$total" 'BEGIN{printf "%.1fK", t/1000}')"
else
    human="$total"
fi
printf "  %-14s  %-10s  %s\n" "TOTAL (tools)" "$human" "summed across tools with telemetry"

# ── Providers table (per-agent token usage from native telemetry) ───
echo ""
printf "  %-14s  %-10s  %s\n" "provider" "tokens" "note"
echo   "  ─────────────────────────────────────────────────────────────"

for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
    pid=$(provider_id "$i")
    pname=$(provider_name "$i")
    raw=$(provider_telemetry_total "$i")
    saved=""; note=""; tokens=""
    IFS='|' read -r saved note tokens <<<"$raw"

    # Skip Claude in provider table — its tools are above
    if [[ "$pid" == "claude" ]]; then
        continue
    fi

    printf "  %-14s  %-10s  %s\n" "$pname" "$saved" "${COL_DIM}${note}${COL_RESET}"
done

# ── Monthly value section ──────────────────────────────────────────

# Part 1: RTK monthly (Claude Code tool savings)
rtk_monthly_raw=""
if command -v "$RTK_BIN" >/dev/null 2>&1; then
    rtk_monthly_raw="$("$RTK_BIN" gain --monthly 2>/dev/null || true)"
    rtk_monthly_raw="${rtk_monthly_raw//$'\r'/}"
fi
rtk_has_monthly=false
if [[ -n "$rtk_monthly_raw" ]] && grep -qE "$MONTH_ROW_RE" <<<"$rtk_monthly_raw"; then
    rtk_has_monthly=true
fi

# Part 2: Provider-native monthly (Codex SQLite, etc.)
# Collect which providers have monthly data
declare -a monthly_providers=()
for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
    pid=$(provider_id "$i")
    monthly_raw=$(provider_telemetry_monthly "$i")
    if [[ -n "$monthly_raw" ]]; then
        monthly_providers+=("$i")
    fi
done

has_any_monthly=false
$rtk_has_monthly && has_any_monthly=true
(( ${#monthly_providers[@]} > 0 )) && has_any_monthly=true

if $has_any_monthly; then
    echo ""
    echo "${COL_BOLD}Monthly value — API-equivalent \$ saved${COL_RESET}"
    echo ""

    # ── RTK (Claude Code) monthly ──
    if $rtk_has_monthly; then
        printf "  ${COL_DIM}%s · input \$%s/M${COL_RESET}\n" \
            "$CLAUDE_LABEL" "$CLAUDE_INPUT_USD_PER_MTOK"
        printf "  %-9s  %-10s  %s\n" "month" "saved" "claude \$"
        echo   "  ─────────────────────────────────────────────────────────────"
        RTK_MONTHLY="$rtk_monthly_raw" \
        CLAUDE_IN="$CLAUDE_INPUT_USD_PER_MTOK" \
        MONTH_RE="$MONTH_ROW_RE" \
        node --input-type=module -e '
            const strip = s => s.replace(/\x1b\[[0-9;]*m/g, "");
            // Columns: Month Cmds Input Output Saved Save% Time — capture Month + Saved (5th).
            const RE = /^(\d{4}-\d{2})\s+\S+\s+\S+\s+\S+\s+(\S+)/;
            const toNum = h => { const m = String(h).trim().match(/^([\d.]+)\s*([KMGB]?)/i); if (!m) return 0; const u = (m[2]||"").toUpperCase(); return Math.round(parseFloat(m[1]) * ({K:1e3,M:1e6,G:1e9,B:1e9}[u]||1)); };
            const human = t => t>=1e6 ? (t/1e6).toFixed(1)+"M" : t>=1e3 ? (t/1e3).toFixed(1)+"K" : String(t);
            const CL = parseFloat(process.env.CLAUDE_IN);
            let tT=0, tCl=0;
            for (const ln of strip(process.env.RTK_MONTHLY||"").split("\n")) {
                const m = ln.match(RE); if (!m) continue;
                const tok = toNum(m[2]); if (!tok) continue;
                const cl = tok/1e6*CL;
                tT+=tok; tCl+=cl;
                console.log("  " + m[1].padEnd(9) + "  " + human(tok).padEnd(10) + "  $" + cl.toFixed(2));
            }
            console.log("  ─────────────────────────────────────────────────────────────");
            console.log("  " + "TOTAL".padEnd(9) + "  " + human(tT).padEnd(10) + "  $" + tCl.toFixed(2));
        ' || echo "  (RTK monthly parse failed)"
        echo ""
    fi

    # ── Per-provider monthly (Codex, Gemini, Kimi, opencode, ...) ──
    for pi in "${monthly_providers[@]}"; do
        pid=$(provider_id "$pi")
        pname=$(provider_name "$pi")
        plabel=$(provider_label "$pi")
        pprice=$(provider_input_usd_per_mtok "$pi")
        monthly_raw=$(provider_telemetry_monthly "$pi")

        printf "  ${COL_DIM}%s · input \$%s/M${COL_RESET}\n" "$plabel" "$pprice"
        printf "  %-9s  %-10s  %s\n" "month" "tokens" "${pid} \$"
        echo   "  ─────────────────────────────────────────────────────────────"

        PROVIDER_MONTHLY="$monthly_raw" \
        PROVIDER_PRICE="$pprice" \
        node --input-type=module -e '
            const toNum = t => parseInt(t, 10);
            const human = t => t>=1e6 ? (t/1e6).toFixed(1)+"M" : t>=1e3 ? (t/1e3).toFixed(1)+"K" : String(t);
            const price = parseFloat(process.env.PROVIDER_PRICE);
            const lines = (process.env.PROVIDER_MONTHLY||"").trim().split("\n").filter(Boolean);
            let tT=0, tD=0;
            for (const ln of lines) {
                const parts = ln.split(" ");
                if (parts.length < 3) continue;
                const month = parts[0];
                const tok = toNum(parts[1]);
                if (!tok) continue;
                const dollars = tok/1e6*price;
                tT+=tok; tD+=dollars;
                console.log("  " + month.padEnd(9) + "  " + human(tok).padEnd(10) + "  $" + dollars.toFixed(2));
            }
            if (tT > 0) {
                console.log("  ─────────────────────────────────────────────────────────────");
                console.log("  " + "TOTAL".padEnd(9) + "  " + human(tT).padEnd(10) + "  $" + tD.toFixed(2));
            }
        ' || echo "  (${pid} monthly parse failed)"
        echo ""
    done

    printf "  ${COL_DIM}Savings are input-side (context offload), so output price is not applied.${COL_RESET}\n"
    printf "  ${COL_DIM}Provider prices should be verified against official pricing pages.${COL_RESET}\n"
fi

echo ""
echo "(Next: run /tokenwar check to verify the gain is real and not double-counted.)"
