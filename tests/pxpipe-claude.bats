#!/usr/bin/env bats
# Tests for pxpipe-claude.sh — Claude Code behind pxpipe, proxy started on demand.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/pxpipe-claude.sh"
    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    export CALLS="$HOME/calls.log"
    export TW_PXPIPE_WAIT_SECS=2
    unset TOKENWAR_PXPIPE
    printf '#!/usr/bin/env bash\necho "claude $*" >> "%s"\n' "$CALLS" > "$MOCK_BIN/claude"
    chmod +x "$MOCK_BIN/claude"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# pxpipe mock: records its args; `pxpipe` with no args "starts the proxy" by
# creating the marker the curl mock reads.
mock_pxpipe() {
    cat > "$MOCK_BIN/pxpipe" <<EOF
#!/usr/bin/env bash
echo "pxpipe\${*:+ \$*}" >> "$CALLS"
[[ \$# -eq 0 ]] && touch "$HOME/proxy-up"
exit 0
EOF
    chmod +x "$MOCK_BIN/pxpipe"
}

# curl mock: the dashboard answers 200 only once the proxy is "up".
mock_curl() {
    cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
[[ -f "$HOME/proxy-up" ]] && printf 200 || printf 000
EOF
    chmod +x "$MOCK_BIN/curl"
}

@test "runs claude through pxpipe warp when the proxy is up" {
    mock_pxpipe; mock_curl; touch "$HOME/proxy-up"
    run bash "$SCRIPT" --model claude-opus-5-5 "a b"
    [ "$status" -eq 0 ]
    grep -qx "pxpipe warp -- claude --model claude-opus-5-5 a b" "$CALLS"
    [ "$(grep -c '^pxpipe$' "$CALLS")" -eq 0 ]    # no second proxy
}

@test "starts the proxy when it is not running, then warps" {
    mock_pxpipe; mock_curl
    run bash "$SCRIPT" hello
    [ "$status" -eq 0 ]
    grep -qx "pxpipe" "$CALLS"
    grep -qx "pxpipe warp -- claude hello" "$CALLS"
}

@test "falls back to plain claude when the proxy will not start" {
    mock_curl
    printf '#!/usr/bin/env bash\necho "pxpipe $*" >> "%s"\n' "$CALLS" > "$MOCK_BIN/pxpipe"
    chmod +x "$MOCK_BIN/pxpipe"
    run bash "$SCRIPT" hello
    [ "$status" -eq 0 ]
    [[ "$output" == *"did not start"* ]]
    grep -qx "claude hello" "$CALLS"
    [ "$(grep -c 'warp' "$CALLS")" -eq 0 ]
}

@test "plain claude when pxpipe is not installed" {
    run bash "$SCRIPT" hello
    [ "$status" -eq 0 ]
    grep -qx "claude hello" "$CALLS"
}

@test "TOKENWAR_PXPIPE=off bypasses the proxy" {
    mock_pxpipe; mock_curl; touch "$HOME/proxy-up"
    TOKENWAR_PXPIPE=off run bash "$SCRIPT" hello
    grep -qx "claude hello" "$CALLS"
    [ "$(grep -c '^pxpipe' "$CALLS")" -eq 0 ]
}

@test "commands that never call the model skip the proxy" {
    mock_pxpipe; mock_curl
    run bash "$SCRIPT" update
    grep -qx "claude update" "$CALLS"
    [ "$(grep -c '^pxpipe' "$CALLS")" -eq 0 ]
}
