#!/usr/bin/env bash
# pxpipe-desktop.sh — route the Claude desktop app through pxpipe.
#
#   on      start the desktop proxy (pxpipe-desktop.mjs), register it to start
#           at logon (a shortcut in the user's Startup folder — schtasks
#           /SC ONLOGON needs admin rights), and point Claude Code at it:
#           HTTPS_PROXY + NO_PROXY + NODE_EXTRA_CA_CERTS in the env block of
#           ~/.claude/settings.json. Quit and reopen the desktop app afterwards.
#   off     undo all three. Use it first if Claude stops answering.
#   status  what is wired and what is running.
#   run     the supervised loop the Startup shortcut runs (restarts the proxy).
#
# The CA is trusted only through NODE_EXTRA_CA_CERTS, i.e. by Claude Code
# processes; nothing is added to the Windows certificate store.
#
# Caveats, from DivyeshPatro/pxpipe-windows: while wired, Claude Code needs the
# proxy running (`off` restores direct access), and the desktop app may rewrite
# settings.json — `status` shows when the wiring was dropped; `on` restores it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/osdetect.sh
source "${SCRIPT_DIR}/lib/osdetect.sh"

readonly DAEMON="${SCRIPT_DIR}/pxpipe-desktop.mjs"
readonly CONNECT_PORT="${TW_PXPIPE_CONNECT_PORT:-47822}"
readonly PROXY_URL="http://127.0.0.1:${CONNECT_PORT}"
readonly NO_PROXY_HOSTS="localhost,127.0.0.1,::1"
readonly SETTINGS="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
readonly LOG="${HOME}/.pxpipe/desktop.log"
readonly TASK_NAME="tokenwar-pxpipe-desktop"
readonly START_WAIT_SECS="${TW_PXPIPE_WAIT_SECS:-20}"
readonly RESTART_DELAY_SECS=5

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

# Listening is all we check: any HTTP answer at all, as opposed to curl's
# 7 (connection refused) or 28 (timeout).
daemon_up() {
    curl -s -o /dev/null -m 2 "http://127.0.0.1:${CONNECT_PORT}/" 2>/dev/null
    local rc=$?
    [[ $rc -ne 7 && $rc -ne 28 ]]
}
pxpipe_up() { curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:47821/ 2>/dev/null | grep -q '^200$'; }

# The command that runs `run` with no console window: mintty hidden on Windows.
launch_hidden() {
    if [[ -n "${TW_PXPIPE_LAUNCHER:-}" ]]; then   # tests: never start a real proxy
        "$TW_PXPIPE_LAUNCHER"; return
    fi
    if tw_is_windows; then
        "$(cygpath -u "$(mintty_path)")" -w hide -e /usr/bin/bash -l "$(tw_node_path "${SCRIPT_DIR}/pxpipe-desktop.sh")" run &
    else
        nohup bash "${SCRIPT_DIR}/pxpipe-desktop.sh" run >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
}
mintty_path() { cygpath -w /usr/bin/mintty.exe; }

# Set or clear our three keys in settings.json's env block. Only touches keys
# we own: HTTPS_PROXY is removed only while it still points at our proxy.
settings_env() {
    local mode="$1" ca="${2:-}"
    mkdir -p "$(dirname "$SETTINGS")"
    [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
    [[ "$mode" == on && ! -f "${SETTINGS}.tokenwar-pxpipe.bak" ]] && cp "$SETTINGS" "${SETTINGS}.tokenwar-pxpipe.bak"
    MODE="$mode" FILE="$(tw_node_path "$SETTINGS")" URL="$PROXY_URL" CA="$ca" NOPROXY="$NO_PROXY_HOSTS" node -e '
        const fs = require("fs"), e = process.env;
        const s = JSON.parse(fs.readFileSync(e.FILE, "utf8") || "{}");
        const env = s.env && typeof s.env === "object" ? s.env : {};
        if (e.MODE === "on") {
            env.HTTPS_PROXY = e.URL; env.NO_PROXY = e.NOPROXY; env.NODE_EXTRA_CA_CERTS = e.CA;
        } else if (env.HTTPS_PROXY === e.URL) {
            delete env.HTTPS_PROXY; delete env.NO_PROXY; delete env.NODE_EXTRA_CA_CERTS;
        }
        if (Object.keys(env).length) s.env = env; else delete s.env;
        fs.writeFileSync(e.FILE, JSON.stringify(s, null, 2) + "\n");
    '
}

settings_wired() {
    FILE="$(tw_node_path "$SETTINGS")" URL="$PROXY_URL" node -e '
        try { const s = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
              process.exit(s.env && s.env.HTTPS_PROXY === process.env.URL && s.env.NODE_EXTRA_CA_CERTS ? 0 : 1); }
        catch { process.exit(1); }' 2>/dev/null
}

# Per-user Startup folder (TW_STARTUP_DIR overrides it for tests).
startup_shortcut() {
    local dir="${TW_STARTUP_DIR:-}"
    if [[ -z "$dir" ]]; then
        dir="$(powershell -NoProfile -Command "[Environment]::GetFolderPath('Startup')" 2>/dev/null | tw_strip_cr)"
        [[ -n "$dir" ]] || return 1
        dir="$(cygpath -u "$dir")"
    fi
    printf '%s/%s.lnk' "$dir" "$TASK_NAME"
}

task_registered() { local l; tw_is_windows && l="$(startup_shortcut)" && [[ -f "$l" ]]; }

# A .lnk to mintty with a hidden window: no admin rights, no console flash.
# Paths travel through the environment so nothing needs quoting for PowerShell.
install_startup_shortcut() {
    local lnk
    lnk="$(startup_shortcut)" || return 1
    mkdir -p "$(dirname "$lnk")"
    # shellcheck disable=SC2016  # $s and $env: are PowerShell's, not the shell's
    LNK="$(cygpath -w "$lnk")" TGT="$(mintty_path)" \
    ARGS="-w hide -e /usr/bin/bash -l \"$(tw_node_path "${SCRIPT_DIR}/pxpipe-desktop.sh")\" run" \
        powershell -NoProfile -Command '$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); $s.TargetPath = $env:TGT; $s.Arguments = $env:ARGS; $s.WindowStyle = 7; $s.Save()' >/dev/null 2>&1
    [[ -f "$lnk" ]]
}

cmd_run() {
    mkdir -p "$(dirname "$LOG")"
    # Exit 0 = another instance already serves the port: stop looping.
    until node "$(tw_node_path "$DAEMON")" >>"$LOG" 2>&1; do sleep "$RESTART_DELAY_SECS"; done
}

cmd_on() {
    command -v pxpipe >/dev/null 2>&1 || { warn "pxpipe not installed — run: tokenwar upgrade, or install.sh --with-pxpipe"; return 1; }
    local ca
    ca="$(node "$(tw_node_path "$DAEMON")" --ca-path 2>/dev/null | tw_strip_cr)"
    [[ -n "$ca" ]] || { warn "could not load pxpipe's CA (is pxpipe 0.14+ installed?)"; return 1; }

    # Proxy first: wiring settings.json to a proxy that is not up would stall Claude.
    if ! daemon_up; then
        say "Starting the desktop proxy on $PROXY_URL"
        launch_hidden
        local i
        for (( i = 0; i < START_WAIT_SECS; i++ )); do daemon_up && pxpipe_up && break; sleep 1; done
    fi
    if ! daemon_up || ! pxpipe_up; then
        warn "the proxy did not come up (see $LOG) — settings.json left unchanged"; return 1
    fi

    if tw_is_windows; then
        if install_startup_shortcut; then
            say "Autostart at logon: $(startup_shortcut)"
        else
            warn "could not create the Startup shortcut — after a reboot, run: tokenwar pxpipe desktop on"
        fi
    else
        warn "no autostart off Windows — run \`tokenwar pxpipe desktop run\` under your own supervisor"
    fi

    settings_env on "$ca"
    say "Wired $SETTINGS (HTTPS_PROXY=$PROXY_URL, NODE_EXTRA_CA_CERTS=$ca)"
    say "Quit the Claude desktop app from the tray and reopen it. Undo with: tokenwar pxpipe desktop off"
}

cmd_off() {
    settings_env off
    say "Removed the proxy settings from $SETTINGS"
    if task_registered; then
        rm -f "$(startup_shortcut)" && say "Removed the Startup shortcut"
    fi
    say "Restart the Claude desktop app. The proxy process, if running, is now unused; it stops at logoff."
}

cmd_status() {
    local ok=true
    if settings_wired; then say "settings.json: wired to $PROXY_URL"; else warn "settings.json: not wired"; ok=false; fi
    if daemon_up; then say "desktop proxy: up on $PROXY_URL"; else warn "desktop proxy: down"; ok=false; fi
    if pxpipe_up; then say "pxpipe proxy: up on :47821"; else warn "pxpipe proxy: down"; ok=false; fi
    if tw_is_windows; then
        if task_registered; then say "autostart: $(startup_shortcut)"; else warn "autostart: no Startup shortcut"; ok=false; fi
    fi
    if settings_wired && ! daemon_up; then
        warn "Claude Code is wired to a proxy that is down — run \`tokenwar pxpipe desktop on\` (or \`off\`)"
    fi
    $ok
}

case "${1:-status}" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    run)    cmd_run ;;
    *) echo "usage: tokenwar pxpipe desktop on|off|status" >&2; exit 2 ;;
esac
