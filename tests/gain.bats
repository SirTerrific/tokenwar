#!/usr/bin/env bats
# Tests for gain.sh — aggregates per-tool token savings.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/gain.sh"
    [ -x "$SCRIPT" ] || skip "gain.sh not executable"

    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    mkdir -p "$HOME/.claude/tokenwar"
}

load sqlite_helper

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

mock_rtk() {
    cat > "$MOCK_BIN/rtk" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "gain" ]] && cat <<RTKOUT
RTK Token Savings
Total commands:    18956
Tokens saved:      44.7M (68.3%)
RTKOUT
EOF
    chmod +x "$MOCK_BIN/rtk"
}

@test "RTK parsed from rtk gain output" {
    mock_rtk
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTK"*"44.7M"* ]]
}

@test "TOTAL line present" {
    mock_rtk
    run bash "$SCRIPT"
    [[ "$output" == *"TOTAL"* ]]
}

@test "claude-mem N/A when native store missing" {
    mock_rtk
    # no ~/.claude-mem/chroma-sync-state.json in the isolated HOME
    run bash "$SCRIPT"
    [[ "$output" == *"claude-mem"*"N/A"* ]]
}

@test "claude-mem reads counts from chroma-sync-state.json" {
    mock_rtk
    mkdir -p "$HOME/.claude-mem"
    cat > "$HOME/.claude-mem/chroma-sync-state.json" <<'EOF'
{
  "projA": {"observations": 20000, "summaries": 5000, "prompts": 999},
  "projB": {"observations": 0,     "summaries": 0,     "prompts": 10}
}
EOF
    run bash "$SCRIPT"
    # (20000+5000) items × MEM_EST_TOKENS_PER_ITEM(40) = 1,000,000 → "1.0M"
    [[ "$output" == *"claude-mem"*"1.0M"* ]]
    [[ "$output" == *"25000 obs"* || "$output" == *"20000 obs"* ]]
}

# claude-mem 13+ keeps memories in claude-mem.db and no longer writes
# chroma-sync-state.json. Only the columns the savings formula reads.
MEM_DB_SCHEMA="CREATE TABLE observations (
  id integer PRIMARY KEY, project text, title text, subtitle text,
  narrative text, facts text, discovery_tokens integer DEFAULT 0);"

@test "claude-mem reads real savings from claude-mem.db (claude-mem 13+)" {
    mock_rtk
    mkdir -p "$HOME/.claude-mem"
    # Read cost per row = ceil((title + subtitle + narrative + facts JSON) / 4):
    #   row 1: 8 + 0 + 8 + len('[]')+2 = 20 chars -> 5 tokens
    #   row 2: 8 + 0 + 0 + 2 (no facts -> "[]")  = 10 chars -> 3 tokens
    # work 30000 - read 8 = 29992 saved.
    make_sqlite_db "$HOME/.claude-mem/claude-mem.db" "$MEM_DB_SCHEMA
INSERT INTO observations (project, title, narrative, facts, discovery_tokens)
  VALUES ('projA', 'abcdefgh', 'abcdefgh', '[]', 10000);
INSERT INTO observations (project, title, discovery_tokens)
  VALUES ('projB', 'abcdefgh', 20000);
" || skip "no SQLite engine available to build the fixture"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-mem"*"30.0K"*"2 obs across 2 projects: 30.0K work tokens recalled for 8 read"* ]]
    run bash "$SCRIPT" --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            process.exit(JSON.parse(s).tools["claude-mem"].saved_tokens === 29992 ? 0 : 1);
        });
    '
}

@test "claude-mem falls back to chroma-sync-state.json when the DB has no discovery telemetry" {
    mock_rtk
    mkdir -p "$HOME/.claude-mem"
    make_sqlite_db "$HOME/.claude-mem/claude-mem.db" "$MEM_DB_SCHEMA
INSERT INTO observations (project, title) VALUES ('projA', 'abcdefgh');
" || skip "no SQLite engine available to build the fixture"
    echo '{"projA": {"observations": 25000, "summaries": 0}}' > "$HOME/.claude-mem/chroma-sync-state.json"
    run bash "$SCRIPT"
    [[ "$output" == *"claude-mem"*"1.0M"*"~est"* ]]
}

@test "caveman is always N/A (no telemetry surface)" {
    mock_rtk
    run bash "$SCRIPT"
    [[ "$output" == *"caveman"*"N/A"*"style-only"* ]]
}

@test "no context-mode store → context-mode shows N/A" {
    mock_rtk
    unset CTX_STATS_JSON
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"N/A"* ]]
}

@test "context-mode is read from its own stores: diverted + indexed + sandboxed" {
    mock_rtk
    unset CTX_STATS_JSON
    local ctx="$HOME/.claude/context-mode"
    mkdir -p "$ctx/sessions" "$ctx/content"
    # Two session DBs: 2048 diverted bytes each. The 10000-byte captured event
    # payload in the first one never entered the context window, so it must NOT
    # count (context-mode's ADR-0004).
    make_sqlite_db "$ctx/sessions/a.db" "
CREATE TABLE session_events (data TEXT, bytes_avoided INTEGER DEFAULT 0);
INSERT INTO session_events VALUES (hex(zeroblob(5000)), 2048);
" || skip "no SQLite engine available to build the fixture"
    make_sqlite_db "$ctx/sessions/b.db" "
CREATE TABLE session_events (data TEXT, bytes_avoided INTEGER DEFAULT 0);
INSERT INTO session_events VALUES ('x', 2048);
"
    # A pre-bytes_avoided schema: unreadable by the query, and must not zero the rest.
    make_sqlite_db "$ctx/sessions/0old.db" "CREATE TABLE session_events (data TEXT);
INSERT INTO session_events VALUES ('x');"
    # Indexed content: title 2 + content 4094 = 4096 bytes.
    make_sqlite_db "$ctx/content/c.db" "
CREATE TABLE chunks (title TEXT, content TEXT);
INSERT INTO chunks VALUES ('ab', hex(zeroblob(2047)));
"
    # Per-session runtime stats: bytes the sandbox processed. Only
    # bytes_sandboxed counts; bytes_indexed would double-count the chunks above.
    echo '{"bytes_sandboxed":4096,"bytes_indexed":4096}' > "$ctx/sessions/stats-s1.json"
    echo '{"bytes_sandboxed":4096}' > "$ctx/sessions/stats-s2.json"
    echo '{broken' > "$ctx/sessions/stats-s3.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # diverted 2048 + 2048 + indexed 4096 = 8 KB; sandboxed 4096 + 4096 = 8.0 KB;
    # 16384 bytes / 4 chars per token = 4096 tokens.
    [[ "$output" == *"context-mode"*"4.1K"*"8 KB diverted + indexed, 8.0 KB processed in its sandbox, over 2 captures"* ]]
}

@test "CTX_STATS_JSON, when a caller sets it, still overrides the stores" {
    mock_rtk
    mkdir -p "$HOME/.claude/context-mode/sessions"
    CTX_STATS_JSON='{"total_size_kb":4,"entry_count":7}' run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"1.0K"*"7 entries indexed"* ]]
}

@test "rtk absent → RTK shows N/A" {
    # no rtk binary
    run bash "$SCRIPT"
    [[ "$output" == *"RTK"*"N/A"* ]]
}

@test "pxpipe N/A when native events log missing" {
    mock_rtk
    run bash "$SCRIPT"
    [[ "$output" == *"pxpipe"*"N/A"*"events log not found"* ]]
}

@test "pxpipe reads saved tokens from native events log" {
    mock_rtk
    mkdir -p "$HOME/.pxpipe"
    cat > "$HOME/.pxpipe/events.jsonl" <<'EOF'
{"saved_tokens":1200,"applied":true}
{"baseline_input_eff":5000,"actual_input_eff":3000,"applied":true}
{"baseline_tokens":1000,"actual_tokens":900,"applied":false}
EOF
    run bash "$SCRIPT"
    [[ "$output" == *"pxpipe"*"3.2K"* ]]
    [[ "$output" == *"2 compressed requests"* ]]
}

mock_rtk_monthly() {
    cat > "$MOCK_BIN/rtk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "gain" && "$2" == "--monthly" ]]; then
cat <<RTKOUT
M Monthly Breakdown (2 monthlys)
Month         Cmds      Input     Output      Saved   Save%     Time
2026-03       5915      21.2M       2.8M      18.4M   86.7%     7.4s
2026-04      10022      37.6M      13.7M      23.9M   63.5%    24.1s
TOTAL        15937      58.8M      16.5M      42.3M   71.9%    18.0s
RTKOUT
elif [[ "$1" == "gain" ]]; then
cat <<RTKOUT2
RTK Token Savings
Total commands:    15937
Tokens saved:      42.3M (71.9%)
RTKOUT2
fi
EOF
    chmod +x "$MOCK_BIN/rtk"
}

@test "monthly value table renders per-month \$ from rtk --monthly" {
    mock_rtk_monthly
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # 18.4M saved → Claude $5/M = $92.00
    [[ "$output" == *"2026-03"*'$92.00'* ]]
    # 23.9M saved → Claude = $119.50
    [[ "$output" == *"2026-04"*'$119.50'* ]]
    # Codex monthly is now separate (native SQLite telemetry, not RTK-based)
    # — not tested here since Codex DB is not mocked
}

@test "monthly total sums saved-token \$ value, not the rtk TOTAL row" {
    mock_rtk_monthly
    run bash "$SCRIPT"
    # 18.4M + 23.9M = 42.3M → Claude $5/M = $211.50 (computed from rows; TOTAL row ignored)
    [[ "$output" == *'$211.50'* ]]
}

@test "no monthly section when rtk has no monthly rows" {
    mock_rtk   # plain gain output, no YYYY-MM rows
    run bash "$SCRIPT"
    [[ "$output" != *"Monthly value"* ]]
}

# ── graphify (repo/doc structure lane) ────────────────────────────
# graphify's own `benchmark` reports a per-QUERY reduction ratio, not a running
# total of tokens already saved. So it is surfaced as N/A + a note and must never
# be summed into TOTAL — that would credit the stack for queries never made.

mock_graphify_benchmark() {
    cat > "$MOCK_BIN/graphify" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "benchmark" ]]; then
cat <<'BENCH'

graphify token reduction benchmark
──────────────────────────────────────────────────
  Corpus:          11,800 words → ~15,733 tokens (naive)
  Graph:           236 nodes, 284 edges
  Avg query cost:  ~347 tokens
  Reduction:       45.3x fewer tokens per query
BENCH
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/graphify"
}

@test "graphify N/A with an actionable note when no global graph exists" {
    mock_rtk
    mock_graphify_benchmark
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphify"*"N/A"* ]]
    [[ "$output" == *"graphify extract"* ]]
}

@test "graphify N/A when the CLI is not installed" {
    mock_rtk
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v node)" > "$MOCK_BIN/node" && chmod +x "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT"
    [[ "$output" == *"graphify"*"N/A"*"CLI not installed"* ]]
}

@test "graphify surfaces the measured reduction ratio from its own benchmark" {
    mock_rtk
    mock_graphify_benchmark
    mkdir -p "$HOME/.graphify"
    echo '{}' > "$HOME/.graphify/global-graph.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"236 nodes in the global graph"* ]]
    [[ "$output" == *"45.3x fewer tokens per query"* ]]
}

@test "graphify's per-query ratio is NOT summed into TOTAL" {
    # RTK alone reports 44.7M. Adding graphify must leave the total untouched.
    mock_rtk
    mock_graphify_benchmark
    mkdir -p "$HOME/.graphify"
    echo '{}' > "$HOME/.graphify/global-graph.json"
    run bash "$SCRIPT"
    [[ "$output" == *"TOTAL (tools)"*"44.7M"* ]]
}

@test "--json exposes graphify with zero saved_tokens and the ratio in its note" {
    mock_rtk
    mock_graphify_benchmark
    mkdir -p "$HOME/.graphify"
    echo '{}' > "$HOME/.graphify/global-graph.json"
    run bash "$SCRIPT" --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            const j = JSON.parse(s);
            const g = j.tools["graphify"];
            if (g.saved !== "N/A") process.exit(1);
            if (g.saved_tokens !== 0) process.exit(1);
            if (!/45\.3x fewer tokens per query/.test(g.note)) process.exit(1);
        });
    '
}
