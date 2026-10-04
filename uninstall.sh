#!/usr/bin/env bash
# tokenwar uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/uninstall.sh | bash
#
# Does:
#   1. remove statusLine from ~/.claude/settings.json (if it points at tokenwar)
#   2. remove ~/.claude/skills/tokenwar
#
# Does NOT touch:
#   - context-mode, claude-mem, caveman, ponytail plugins (those are separate;
#     remove with `claude plugin uninstall`)
#   - the RTK CLI or its hook (delete ~/.claude/hooks/rtk-rewrite.sh manually if wanted)
#   - the pxpipe CLI (`npm rm -g pxpipe-proxy`)
#   - the graphify CLI, its skill, or any built graph (`graphify uninstall`, then
#     `uv tool uninstall graphifyy` / `pipx uninstall graphifyy`)
#   - settings.json backups created by install.sh (kept on purpose)

set -euo pipefail

INSTALL_DIR="${TOKENWAR_DIR:-$HOME/.claude/skills/tokenwar}"
SETTINGS_JSON="$HOME/.claude/settings.json"
STATUSLINE_CMD='bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh'

readonly TW_RC_BEGIN="# >>> tokenwar shell integration >>>"
readonly TW_RC_END="# <<< tokenwar shell integration <<<"
# context-mode routing block install.sh --with-plugins writes into CLAUDE.md.
readonly CLAUDE_MD="$HOME/.claude/CLAUDE.md"
readonly TW_MD_BEGIN="<!-- >>> tokenwar context-mode routing >>> -->"
readonly TW_MD_END="<!-- <<< tokenwar context-mode routing <<< -->"

# Duplicated from scripts/lib/osdetect.sh — this script is piped from curl, so
# it cannot source anything out of the install it is about to remove.
tw_is_windows() {
    [[ "${OS:-}" == "Windows_NT" ]] && return 0
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

# node is a native Windows binary and cannot open an MSYS path. Without this,
# under MSYS_NO_PATHCONV=1 the settings read fails silently and the statusLine
# is left behind while the uninstall reports success.
tw_node_path() {
    if tw_is_windows && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
        return
    fi
    printf '%s' "$1"
}

color()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
green()  { color 32 "$1"; }
yellow() { color 33 "$1"; }
say()    { printf '%s %s\n' "$(green '==>')" "$*"; }
warn()   { printf '%s %s\n' "$(yellow '!!')" "$*" >&2; }

if [[ -f "$SETTINGS_JSON" ]]; then
    say "Unwiring statusLine from $SETTINGS_JSON"
    SETTINGS_JSON="$(tw_node_path "$SETTINGS_JSON")" STATUSLINE_CMD="$STATUSLINE_CMD" node --input-type=module -e '
import { readFileSync, writeFileSync, copyFileSync } from "fs";
const path = process.env.SETTINGS_JSON;
const desired = process.env.STATUSLINE_CMD;
let cfg = {};
try { cfg = JSON.parse(readFileSync(path, "utf8")); } catch { process.exit(0); }
// Match by the script name rather than the exact string: install.sh writes a
// different command on Windows ("<bash.exe>" -c '~/...'), and an exact compare
// would silently leave that statusLine behind on uninstall.
const isOurs = cfg.statusLine
    && typeof cfg.statusLine.command === "string"
    && (cfg.statusLine.command === desired
        || cfg.statusLine.command.includes("tokenwar-statusline.sh"));
if (isOurs) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    copyFileSync(path, `${path}.bak-${stamp}`);
    delete cfg.statusLine;
    writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    console.log(`    removed statusLine (backup at ${path}.bak-${stamp})`);
} else {
    console.log("    statusLine not pointing at tokenwar — leaving settings.json alone");
}
'
else
    warn "$SETTINGS_JSON does not exist — skipping settings patch"
fi

# Strip a tokenwar block (between <begin> and <end> marker lines) from a file:
# the shell-integration block from an rc file, or the routing block from CLAUDE.md.
# Usage: unwire_block <file> [<begin> <end> <label>]
unwire_block() {
    local rc_file="$1" begin="${2:-$TW_RC_BEGIN}" end="${3:-$TW_RC_END}" label="${4:-shell integration}"
    [[ -f "$rc_file" ]] || return 0
    grep -qF "$begin" "$rc_file" 2>/dev/null || return 0
    local tmp
    tmp="$(mktemp "${rc_file}.tokenwar.XXXXXX")" || { warn "mktemp failed for $rc_file"; return 1; }
    TW_BEGIN="$begin" TW_END="$end" awk '
        $0 == ENVIRON["TW_BEGIN"] { skip = 1 }
        skip != 1 { print }
        $0 == ENVIRON["TW_END"]   { skip = 0 }
    ' "$rc_file" > "$tmp" || { warn "could not rewrite $rc_file"; rm -f "$tmp"; return 1; }
    if mv -f "$tmp" "$rc_file"; then
        say "Removed tokenwar ${label} from $rc_file"
    else
        warn "could not write $rc_file"; rm -f "$tmp"; return 1
    fi
}

say "Removing shell integration"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    unwire_block "$rc"
done
unwire_block "$CLAUDE_MD" "$TW_MD_BEGIN" "$TW_MD_END" "context-mode routing"

if [[ -d "$INSTALL_DIR" ]]; then
    say "Removing $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    warn "$INSTALL_DIR does not exist — already removed"
fi

cat <<EOF

$(green 'tokenwar uninstalled.')

Restart Claude Code to drop the statusline.

The 6 tools tokenwar orchestrates remain installed. Remove them yourself if wanted:
  claude plugin uninstall context-mode@context-mode
  claude plugin uninstall claude-mem@thedotmack
  claude plugin uninstall caveman@caveman
  claude plugin uninstall ponytail@ponytail
  rm ~/.claude/hooks/rtk-rewrite.sh   # also remove PreToolUse hook from settings.json
  npm uninstall -g pxpipe-proxy
EOF
