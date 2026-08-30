#!/usr/bin/env bats
# Tests for scripts/lib/osdetect.sh — the Windows/POSIX seam.
#
# These run identically on Linux, macOS and Windows: TW_FORCE_OS pins the OS
# answer so the POSIX expectations are asserted on every platform, which is what
# guards against a Windows branch quietly changing POSIX behaviour.

# `run -<code>` (used for the shim's 127 exit) needs bats 1.5+.
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    OSDETECT="$REPO_ROOT/scripts/lib/osdetect.sh"
    PROVIDERS="$REPO_ROOT/scripts/lib/providers.sh"
    STATUSLINE="$REPO_ROOT/scripts/tokenwar-statusline.sh"
    [ -f "$OSDETECT" ] || skip "osdetect.sh not found"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

# The .cmd/.ps1 entry points only mean anything on Windows.
require_windows() {
    od_eval "tw_is_windows" || skip "Windows-only entry point"
}

# Absolute Windows path for a repo-relative file.
win_path() {
    ( cd "$REPO_ROOT" && cygpath -w "$PWD/$1" )
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

# ── PowerShell / cmd entry points ───────────────────────────────────

@test "PowerShell scripts are ASCII-only" {
    # Windows PowerShell 5.1 reads a .ps1 without a BOM using the ANSI codepage,
    # so a UTF-8 character inside a double-quoted string decodes into stray bytes
    # and breaks parsing outright. Keeping these files ASCII sidesteps the whole
    # encoding question. Runs on every platform — it is a pure text check.
    for f in "$REPO_ROOT/install.ps1" "$REPO_ROOT/uninstall.ps1" "$REPO_ROOT/bin/tokenwar.ps1"; do
        [ -f "$f" ] || continue
        run env LC_ALL=C grep -c '[^ -~]' "$f"
        [ "$output" = "0" ]
    done
}

@test "PowerShell scripts parse" {
    require_windows
    command -v powershell.exe >/dev/null 2>&1 || skip "powershell.exe not available"
    for rel in install.ps1 uninstall.ps1 bin/tokenwar.ps1; do
        [ -f "$REPO_ROOT/$rel" ] || continue
        local wp; wp="$(win_path "$rel")"
        run powershell.exe -NoProfile -Command "\$e=\$null;\$null=[System.Management.Automation.Language.Parser]::ParseFile('$wp',[ref]\$null,[ref]\$e);if(\$e){'FAIL'}else{'OK'}"
        [[ "$output" == *"OK"* ]]
    done
}

@test "tokenwar.cmd reaches the dispatcher" {
    require_windows
    command -v cmd.exe >/dev/null 2>&1 || skip "cmd.exe not available"
    [ -f "$REPO_ROOT/bin/tokenwar.cmd" ] || skip "cmd shim not present"
    # NB: cmd.exe needs //c here — MSYS rewrites a lone /c into a path, cmd then
    # sees no switch and opens an interactive shell that never returns.
    run env TOKENWAR_DIR="$(cd "$REPO_ROOT" && cygpath -w "$PWD")" \
        cmd.exe //c "$(win_path bin/tokenwar.cmd)" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"token-saving stack manager"* ]]
}

@test "tokenwar.cmd fails cleanly when the install is missing" {
    require_windows
    command -v cmd.exe >/dev/null 2>&1 || skip "cmd.exe not available"
    [ -f "$REPO_ROOT/bin/tokenwar.cmd" ] || skip "cmd shim not present"
    # 127 is the shim's own "not installed" code, hence `run -127`.
    run -127 env TOKENWAR_DIR='C:\no\such\place' cmd.exe //c "$(win_path bin/tokenwar.cmd)" help
    [[ "$output" == *"dispatcher not found"* ]]
}

@test "tokenwar.ps1 reaches the dispatcher" {
    require_windows
    command -v powershell.exe >/dev/null 2>&1 || skip "powershell.exe not available"
    [ -f "$REPO_ROOT/bin/tokenwar.ps1" ] || skip "ps1 shim not present"
    local root; root="$(cd "$REPO_ROOT" && cygpath -w "$PWD")"
    run powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        "\$env:TOKENWAR_DIR='$root'; & '$(win_path bin/tokenwar.ps1)' help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"token-saving stack manager"* ]]
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
