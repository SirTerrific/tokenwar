#!/usr/bin/env bats
# Tests for scripts/lib/osdetect.sh — the Windows/POSIX seam.
#
# These run identically on Linux, macOS and Windows: TW_FORCE_OS pins the OS
# answer so the POSIX expectations are asserted on every platform, which is what
# guards against a Windows branch quietly changing POSIX behaviour.

setup() {
    OSDETECT="$BATS_TEST_DIRNAME/../scripts/lib/osdetect.sh"
    PROVIDERS="$BATS_TEST_DIRNAME/../scripts/lib/providers.sh"
    STATUSLINE="$BATS_TEST_DIRNAME/../scripts/tokenwar-statusline.sh"
    [ -f "$OSDETECT" ] || skip "osdetect.sh not found"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

# Run a snippet with osdetect.sh sourced.
od_eval() {
    bash -c "source '$OSDETECT'; $1"
}

# ── tw_is_windows ───────────────────────────────────────────────────

@test "tw_is_windows honours TW_FORCE_OS=windows" {
    run env TW_FORCE_OS=windows bash -c "source '$OSDETECT'; tw_is_windows"
    [ "$status" -eq 0 ]
}

@test "tw_is_windows honours TW_FORCE_OS=posix" {
    run env TW_FORCE_OS=posix bash -c "source '$OSDETECT'; tw_is_windows"
    [ "$status" -ne 0 ]
}

@test "tw_is_windows agrees with uname on the real host" {
    # No override: the detector must match what uname reports, on any platform.
    local expected=1
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) expected=0 ;; esac
    [[ "${OS:-}" == "Windows_NT" ]] && expected=0
    run od_eval "tw_is_windows"
    [ "$status" -eq "$expected" ]
}

# ── tw_user ─────────────────────────────────────────────────────────

@test "tw_user prefers USER when set" {
    run env USER=alice USERNAME=bob bash -c "source '$OSDETECT'; tw_user"
    [ "$output" = "alice" ]
}

@test "tw_user falls back to USERNAME when USER is empty" {
    # The Git Bash case: USER is unset, only USERNAME carries the account name.
    # Without this the statusline caches collapse onto one shared filename.
    run env USER= USERNAME=bob bash -c "source '$OSDETECT'; tw_user"
    [ "$output" = "bob" ]
}

@test "tw_user never returns empty" {
    run env USER= USERNAME= LOGNAME= bash -c "source '$OSDETECT'; tw_user"
    [ -n "$output" ]
}

# ── tw_strip_cr ─────────────────────────────────────────────────────

@test "tw_strip_cr removes carriage returns from a stream" {
    run bash -c "source '$OSDETECT'; printf 'rtk 0.46.0\r\nsecond\r\n' | tw_strip_cr | od -c | grep -c '\\\\r'"
    [ "$output" = "0" ]
}

@test "tw_strip_cr leaves LF-only input untouched" {
    run bash -c "source '$OSDETECT'; printf 'a\nb\n' | tw_strip_cr"
    [ "$output" = "a
b" ]
}

# ── tw_bash_path / tw_win_path ──────────────────────────────────────

@test "tw_bash_path reports failure on POSIX" {
    run env TW_FORCE_OS=posix bash -c "source '$OSDETECT'; tw_bash_path"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "tw_win_path is the identity on POSIX" {
    run env TW_FORCE_OS=posix bash -c "source '$OSDETECT'; tw_win_path /home/x/.claude"
    [ "$output" = "/home/x/.claude" ]
}

@test "tw_bash_path names an executable bash on Windows" {
    od_eval "tw_is_windows" || skip "not running on Windows"
    run od_eval "tw_bash_path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bash.exe" ]]
    # The path is Windows-shaped for a native caller, so translate it back to
    # check it actually exists.
    run bash -c "test -x \"\$(cygpath -u '$output')\""
    [ "$status" -eq 0 ]
}

# ── tw_config_dir / tw_data_dir ─────────────────────────────────────

@test "tw_config_dir returns the POSIX default when nothing exists" {
    run env TW_FORCE_OS=posix HOME="$HOME" bash -c "source '$OSDETECT'; tw_config_dir codex"
    [ "$output" = "$HOME/.codex" ]
}

@test "tw_config_dir prefers a candidate that exists on disk" {
    mkdir -p "$HOME/.codex"
    run env TW_FORCE_OS=posix HOME="$HOME" bash -c "source '$OSDETECT'; tw_config_dir codex"
    [ "$output" = "$HOME/.codex" ]
}

@test "tw_config_dir honours CLAUDE_CONFIG_DIR" {
    run env TW_FORCE_OS=posix HOME="$HOME" CLAUDE_CONFIG_DIR=/tmp/cc bash -c "source '$OSDETECT'; tw_config_dir claude"
    [ "$output" = "/tmp/cc" ]
}

@test "tw_data_dir returns the POSIX opencode store by default" {
    run env TW_FORCE_OS=posix HOME="$HOME" bash -c "source '$OSDETECT'; tw_data_dir opencode"
    [ "$output" = "$HOME/.local/share/opencode" ]
}

@test "tw_config_dir rejects an unknown provider" {
    run env TW_FORCE_OS=posix bash -c "source '$OSDETECT'; tw_config_dir nope"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ── SQLite engine selection (providers.sh) ──────────────────────────

@test "tw_sqlite_engine only names an engine that actually runs" {
    [ -f "$PROVIDERS" ] || skip "providers.sh not found"
    run bash -c "source '$PROVIDERS'; tw_sqlite_engine"
    case "$output" in
        python3) run bash -c "python3 -c 'import sqlite3'"; [ "$status" -eq 0 ] ;;
        node)    run bash -c "node -e 'require(\"node:sqlite\")'"; [ "$status" -eq 0 ] ;;
        none)    skip "no SQLite engine on this host" ;;
        *)       false ;;
    esac
}

@test "tw_sqlite_engine does not trust a python3 that cannot run" {
    # Windows ships a python3 "app execution alias" that only opens the Microsoft
    # Store: it satisfies `command -v` and fails on every actual invocation.
    [ -f "$PROVIDERS" ] || skip "providers.sh not found"
    local fake="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake"
    printf '#!/usr/bin/env bash\nexit 9\n' > "$fake/python3"
    chmod +x "$fake/python3"
    run env PATH="$fake:$PATH" bash -c "source '$PROVIDERS'; tw_sqlite_engine"
    [ "$output" != "python3" ]
}

# ── statusline regressions ──────────────────────────────────────────

@test "statusline renders when USER is empty" {
    # Git Bash leaves USER unset. Under `set -u` the cache-filename expansion
    # aborted the whole script with "USER: unbound variable", so the status bar
    # was not merely wrong on Windows — it never rendered at all.
    run env USER= USERNAME=tester HOME="$HOME" bash "$STATUSLINE" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"ponytail"* ]]
}

@test "statusline prints no stray errors on a first-ever run" {
    # ~/.claude/tokenwar does not exist yet: creating the refresh lock failed and
    # bash reported the redirection error into the status bar itself.
    run env USER= USERNAME=tester HOME="$HOME" bash "$STATUSLINE" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"No such file or directory"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "statusline caches are namespaced per user" {
    local tmpdir="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$tmpdir"
    run env USER= USERNAME=tester HOME="$HOME" TMPDIR="$tmpdir" bash "$STATUSLINE" </dev/null
    [ "$status" -eq 0 ]
    # Never the bare "tokenwar-plugins-.json" that an empty USER produced.
    [ ! -e "$tmpdir/tokenwar-plugins-.json" ]
}

@test "tw_human_tokens renders M, K and bare counts" {
    [ -f "$PROVIDERS" ] || skip "providers.sh not found"
    run bash -c "source '$PROVIDERS'; tw_human_tokens 3680300000"
    [ "$output" = "3680.3M" ]
    run bash -c "source '$PROVIDERS'; tw_human_tokens 30000"
    [ "$output" = "30.0K" ]
    run bash -c "source '$PROVIDERS'; tw_human_tokens 42"
    [ "$output" = "42" ]
}
