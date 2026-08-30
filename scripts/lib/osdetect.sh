#!/usr/bin/env bash
# tokenwar OS detection — the single place that knows we might be on Windows.
#
# tokenwar runs on Windows through Git Bash (the MSYS2 bash shipped with Git for
# Windows). That environment is POSIX enough for the scripts to run unchanged,
# with a handful of exceptions this file exists to isolate:
#
#   - $OSTYPE is "cygwin" under Git Bash too (MSYS2 is a Cygwin fork), so it is
#     NOT a usable "am I on Windows" signal on its own. `uname -s` (MINGW*/MSYS*/
#     CYGWIN*) and $OS (Windows_NT) are.
#   - $USER is empty under Git Bash; only $USERNAME is set.
#   - Claude Code spawns the statusline as a native Windows process, so the
#     command it stores must name a bash.exe by its Windows path.
#   - Native Windows binaries (a native rtk build) emit CRLF; a trailing \r
#     silently corrupts every version compare and status badge downstream.
#   - Provider CLIs keep their config under %APPDATA%/%LOCALAPPDATA% rather than
#     ~/.config and ~/.local/share.
#
# Every Windows branch elsewhere in tokenwar goes through a function here, so the
# POSIX path stays byte-for-byte what it always was.
#
# Override for tests: TW_FORCE_OS=windows|posix pins tw_is_windows.

# Git for Windows' launcher directory holds the bash.exe wrapper intended for
# external callers; MSYS exposes it as $EXEPATH. These are the fallbacks when a
# shell was started some other way and $EXEPATH is not set.
TW_WIN_BASH_FALLBACKS=(
    "C:\\Program Files\\Git\\bin\\bash.exe"
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe"
)

# tw_is_windows — true when running on Windows (Git Bash, MSYS2, or Cygwin).
tw_is_windows() {
    case "${TW_FORCE_OS:-}" in
        windows) return 0 ;;
        posix)   return 1 ;;
    esac
    [[ "${OS:-}" == "Windows_NT" ]] && return 0
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

# tw_user — a non-empty user identifier for per-user cache filenames.
# $USER is empty under Git Bash, which would collapse every user's cache onto the
# same path (tokenwar-plugins-.json).
tw_user() {
    printf '%s' "${USER:-${USERNAME:-${LOGNAME:-tw}}}"
}

# tw_strip_cr — filter: drop CR from stdin.
# Use on the output of any external binary that may be a native Windows build.
# For an already-captured string prefer the pure-bash "${var//$'\r'/}".
tw_strip_cr() {
    tr -d '\r'
}

# tw_win_path <posix-path> — convert to a Windows path when on Windows.
# Echoes the input unchanged elsewhere (and when cygpath is unavailable).
tw_win_path() {
    local p="$1"
    if tw_is_windows && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p" 2>/dev/null || printf '%s' "$p"
        return
    fi
    printf '%s' "$p"
}

# tw_bash_path — Windows path to a bash.exe that a native Windows process can
# spawn (Claude Code's statusLine, hooks). Empty + non-zero off Windows.
tw_bash_path() {
    tw_is_windows || return 1

    # Preferred: Git for Windows' own launcher dir, reported by MSYS as $EXEPATH.
    if [[ -n "${EXEPATH:-}" ]]; then
        local exe="${EXEPATH%\\}\\bash.exe"
        local probe
        probe="$(cygpath -u "$exe" 2>/dev/null || printf '')"
        if [[ -n "$probe" && -x "$probe" ]]; then
            printf '%s' "$exe"
            return 0
        fi
    fi

    local candidate probe
    for candidate in "${TW_WIN_BASH_FALLBACKS[@]}"; do
        probe="$(cygpath -u "$candidate" 2>/dev/null || printf '')"
        if [[ -n "$probe" && -x "$probe" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # Last resort: whatever bash is running us, translated to a Windows path.
    local self
    self="$(command -v bash 2>/dev/null || printf '')"
    if [[ -n "$self" ]]; then
        tw_win_path "$self"
        return 0
    fi
    return 1
}

# tw_config_dir <provider> — where a provider CLI keeps its config.
#
# Echoes the first candidate that exists on disk; when none do, echoes the
# platform's conventional location so callers still have a path to report. The
# POSIX list is unchanged from what providers.sh always used.
tw_config_dir() {
    local provider="$1"
    local -a candidates=()
    local appdata="" localappdata=""

    if tw_is_windows; then
        [[ -n "${APPDATA:-}" ]]      && appdata="$(cygpath -u "$APPDATA" 2>/dev/null || printf '')"
        [[ -n "${LOCALAPPDATA:-}" ]] && localappdata="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '')"
    fi

    case "$provider" in
        claude)
            candidates=("${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")
            ;;
        codex)
            candidates=("${HOME}/.codex")
            [[ -n "$appdata" ]] && candidates+=("${appdata}/codex")
            ;;
        gemini)
            candidates=("${HOME}/.gemini")
            [[ -n "$appdata" ]] && candidates+=("${appdata}/gemini")
            ;;
        kimi)
            candidates=("${KIMI_CODE_HOME:-${HOME}/.kimi-code}")
            [[ -n "$appdata" ]] && candidates+=("${appdata}/kimi-code")
            ;;
        opencode)
            candidates=("${HOME}/.config/opencode")
            [[ -n "$appdata" ]] && candidates+=("${appdata}/opencode")
            [[ -n "$localappdata" ]] && candidates+=("${localappdata}/opencode")
            ;;
        *)
            printf ''
            return 1
            ;;
    esac

    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            printf '%s' "$dir"
            return 0
        fi
    done
    printf '%s' "${candidates[0]}"
}

# tw_data_dir <provider> — where a provider CLI keeps its state/telemetry store.
# Same first-existing-wins contract as tw_config_dir.
tw_data_dir() {
    local provider="$1"
    local -a candidates=()
    local localappdata=""

    if tw_is_windows && [[ -n "${LOCALAPPDATA:-}" ]]; then
        localappdata="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '')"
    fi

    case "$provider" in
        codex)
            candidates=("${HOME}/.codex")
            [[ -n "$localappdata" ]] && candidates+=("${localappdata}/codex")
            ;;
        opencode)
            candidates=("${OPENCODE_DATA_HOME:-${HOME}/.local/share/opencode}")
            [[ -n "$localappdata" ]] && candidates+=("${localappdata}/opencode")
            ;;
        *)
            printf ''
            return 1
            ;;
    esac

    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            printf '%s' "$dir"
            return 0
        fi
    done
    printf '%s' "${candidates[0]}"
}
