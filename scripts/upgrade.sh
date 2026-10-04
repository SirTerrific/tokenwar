#!/usr/bin/env bash
# tokenwar upgrade — bump the token-saving tools to their latest versions.
#
# Plugins (context-mode, claude-mem, caveman,
#          ponytail)                           → `claude plugin update <slug> --scope <scope>`.
# RTK (path-installed dev build)              → `cargo install --path <repo> --force`.
# RTK (released binary)                       → scripts/rtk-update.sh (latest release).
# pxpipe                                      → `npm install -g pxpipe-proxy@latest`.
# OpenWiki                                    → `npm install -g openwiki@latest`.
# graphify                                    → its own installer (uv tool / pipx / pip),
#                                               then `graphify install` to refresh the skill.
# tokenwar itself                             → `git pull --ff-only` of its clone, last.
#
# Source of "what needs updating": check-updates.sh, re-run with --force first
# so the answer reflects the registries NOW, not a cache up to 24h old. If the
# check cannot produce a cache, all tools are attempted.
#
# Usage:
#   upgrade.sh            # interactive: confirm before applying
#   upgrade.sh --yes      # non-interactive: apply without prompting
#   upgrade.sh --all      # ignore cache, attempt all tools
#
# Exit: 0 on success (or nothing to do), 1 if any upgrade command failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/osdetect.sh
source "${SCRIPT_DIR}/lib/osdetect.sh"

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"
readonly SLUG_PONY="ponytail@ponytail"

readonly CLAUDE_BIN="claude"
readonly CARGO_BIN="cargo"
readonly NPM_BIN="npm"
# @latest, never a pinned number: a pin goes stale between tokenwar releases.
readonly PXPIPE_NPM_SPEC="pxpipe-proxy@latest"
readonly OPENWIKI_NPM_SPEC="openwiki@latest"
readonly RTK_UPDATE_SCRIPT="${SCRIPT_DIR}/rtk-update.sh"
# Overridable so tests can stub the network check out.
readonly CHECK_UPDATES="${TW_CHECK_UPDATES:-${SCRIPT_DIR}/check-updates.sh}"
TOKENWAR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TOKENWAR_ROOT
readonly ALL_TOOLS="ctx mem cave pony rtk pxpipe graphify openwiki tokenwar"

readonly UV_BIN="uv"
readonly PIPX_BIN="pipx"
readonly PIP_BIN="pip"
readonly GRAPHIFY_BIN="graphify"
readonly GRAPHIFY_PYPI_PACKAGE="graphifyy"

readonly UPGRADE_CACHE_FILE="${HOME}/.claude/tokenwar/upgrade-check.json"
readonly STATE_UPDATE="update-available"

# Where the Claude CLI keeps its per-marketplace git clones. `claude plugin
# update` installs from a clone's LOCAL branch HEAD — NOT origin.
readonly MARKETPLACE_ROOT="${HOME}/.claude/plugins/marketplaces"

# Source of the interactive "Upgrade now? [y/N]" answer. The real controlling
# terminal by default (so the prompt works even when stdin is a pipe), but
# overridable via TW_TTY so the confirm path is testable without a live tty.
readonly TTY_DEVICE="${TW_TTY:-/dev/tty}"

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

assume_yes=false
force_all=false
for arg in "$@"; do
    case "$arg" in
        --yes) assume_yes=true ;;
        --all) force_all=true ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '%s %s\n' "${COL_GREEN}==>${COL_RESET}" "$*"; }
warn() { printf '%s %s\n' "${COL_YELLOW}!!${COL_RESET}" "$*" >&2; }
fail() { printf '%s %s\n' "${COL_RED}ERR${COL_RESET}" "$*" >&2; }

# True only if /dev/tty can actually be opened (a controlling terminal exists).
# The inner redirection's failure is swallowed by the group-level 2>/dev/null,
# so probing never leaks "No such device or address".
tty_readable() { { : <"$TTY_DEVICE"; } 2>/dev/null; }

# Which tools have an update? Echoes space-separated tool keys.
# Reads the cache; with --all or no cache, returns every managed updater.
tools_needing_update() {
    if $force_all || [[ ! -f "$UPGRADE_CACHE_FILE" ]]; then
        echo "$ALL_TOOLS"; return
    fi
    CACHE="$(tw_node_path "$UPGRADE_CACHE_FILE")" TW_STATE="$STATE_UPDATE" ALL="$ALL_TOOLS" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        let d; try { d = JSON.parse(readFileSync(process.env.CACHE, "utf8")); } catch { console.log(process.env.ALL); process.exit(0); }
        const t = d.tools || {};
        const want = process.env.TW_STATE;
        // tokenwar last: pulling it rewrites the scripts this run is executing.
        const map = { "context-mode": "ctx", "claude-mem": "mem", "caveman": "cave", "ponytail": "pony",
                      "rtk": "rtk", "pxpipe": "pxpipe", "graphify": "graphify", "openwiki": "openwiki",
                      "tokenwar": "tokenwar" };
        const out = [];
        for (const [name, key] of Object.entries(map)) {
            if (t[name] && t[name].state === want) out.push(key);
        }
        console.log(out.join(" "));
    ' 2>/dev/null || echo "$ALL_TOOLS"
}

# Look up a plugin's install scope (user|local|project|managed) from
# `claude plugin list --json`. Empty if unknown. Needed because `plugin update`
# defaults to user scope and fails on a plugin installed at another scope
# (e.g. claude-mem is commonly installed `local`).
plugin_scope() {
    "$CLAUDE_BIN" plugin list --json 2>/dev/null | PLUGIN_QUERY="$1" node --input-type=module -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let arr = []; try { arr = JSON.parse(s || "[]"); } catch {}
            const e = arr.find(p => p && p.id === process.env.PLUGIN_QUERY);
            if (e && e.scope) console.log(e.scope);
        });
    ' 2>/dev/null || true
}

# Fast-forward a plugin's marketplace clone to its fetched upstream before
# installing. This closes tokenwar's permanent-update loop: check-updates.sh
# reports "latest" from `origin/<branch>` (it only `git fetch`es, never merges),
# but `claude plugin update` installs from the clone's LOCAL branch HEAD. A
# SHA-versioned plugin (e.g. caveman) whose clone drifts behind origin then
# reports update-available forever — every upgrade reinstalls the same stale
# local HEAD. Fast-forwarding here makes the installed SHA reach origin so the
# next check clears. Clean clones only: a locally-customized clone can't
# ff-only — we warn and install the current local HEAD rather than abort (a
# hard reset would clobber the user's local edits).
sync_marketplace_clone() {
    local slug="$1"
    local marketplace="${slug##*@}"
    local dir
    # See the note in check-updates.sh: git needs a path it can chdir into.
    dir="$(tw_node_path "${MARKETPLACE_ROOT}/${marketplace}")"
    [[ -d "${dir}/.git" ]] || return 0
    git -C "$dir" fetch --quiet 2>/dev/null \
        || warn "marketplace '$marketplace': git fetch failed — installing current local HEAD"
    local upstream
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    [[ -n "$upstream" ]] || return 0
    if ! git -C "$dir" merge --ff-only "$upstream" --quiet 2>/dev/null; then
        warn "marketplace '$marketplace': clone not fast-forwardable (local edits?) — installing current local HEAD"
    fi
}

# Upgrade one plugin via the Claude CLI. Returns non-zero on failure.
upgrade_plugin() {
    local slug="$1"
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        warn "claude CLI not found — cannot update $slug"; return 1
    fi
    sync_marketplace_clone "$slug"
    say "Updating plugin $slug"
    local scope
    scope="$(plugin_scope "$slug")"
    if [[ -n "$scope" ]]; then
        "$CLAUDE_BIN" plugin update "$slug" --scope "$scope"
    else
        "$CLAUDE_BIN" plugin update "$slug"
    fi
}

# Upgrade RTK. A path-installed dev build (`cargo install --path`) is rebuilt
# from its clone; anything else is a released binary, updated to the latest
# GitHub release by rtk-update.sh (never `cargo install rtk`: that crate name
# belongs to a different project).
upgrade_rtk() {
    local repo_path=""
    if command -v "$CARGO_BIN" >/dev/null 2>&1; then
        repo_path=$("$CARGO_BIN" install --list 2>/dev/null \
            | awk '/^rtk v.* \(.*\):$/ { match($0, /\(([^)]+)\)/, m); print m[1]; exit }')
    fi
    if [[ -n "$repo_path" && -d "$repo_path/.git" ]]; then
        say "Updating RTK from $repo_path"
        git -C "$repo_path" pull --ff-only && "$CARGO_BIN" install --path "$repo_path" --force
        return
    fi
    bash "$RTK_UPDATE_SCRIPT"
}

upgrade_npm_global() {
    local label="$1" spec="$2"
    if ! command -v "$NPM_BIN" >/dev/null 2>&1; then
        warn "npm not found — cannot update $label"; return 1
    fi
    say "Updating $label ($spec)"
    "$NPM_BIN" install -g "$spec"
}

# Fast-forward tokenwar's own clone. Run last: it rewrites the scripts this
# upgrade is executing.
upgrade_tokenwar() {
    local root
    root="$(tw_node_path "$TOKENWAR_ROOT")"
    [[ -d "${root}/.git" ]] || { warn "tokenwar is not a git clone — reinstall it to update"; return 1; }
    say "Updating tokenwar ($TOKENWAR_ROOT)"
    git -C "$root" pull --ff-only --quiet \
        || { warn "tokenwar clone not fast-forwardable (local edits?) — left as is"; return 1; }
}

# Upgrade graphify with whichever Python installer actually owns it. Order
# matters: `uv tool` and `pipx` each keep the package in their own isolated venv,
# and running `pip install -U` against a uv/pipx install writes to an unrelated
# environment — the `graphify` on PATH would stay on the old version while the
# check reported success. So we ask each manager whether it owns the package and
# only fall back to plain pip when neither does.
#
# The skill files are copied at install time, so a version bump alone leaves the
# assistant reading the previous playbook: re-run `graphify install` after the
# package upgrade to refresh them.
upgrade_graphify() {
    local upgraded=false
    if command -v "$UV_BIN" >/dev/null 2>&1 \
        && "$UV_BIN" tool list 2>/dev/null | grep -q "^${GRAPHIFY_PYPI_PACKAGE} "; then
        say "Updating graphify via uv tool ($GRAPHIFY_PYPI_PACKAGE)"
        "$UV_BIN" tool upgrade "$GRAPHIFY_PYPI_PACKAGE" || return 1
        upgraded=true
    elif command -v "$PIPX_BIN" >/dev/null 2>&1 \
        && "$PIPX_BIN" list --short 2>/dev/null | grep -q "^${GRAPHIFY_PYPI_PACKAGE} "; then
        say "Updating graphify via pipx ($GRAPHIFY_PYPI_PACKAGE)"
        "$PIPX_BIN" upgrade "$GRAPHIFY_PYPI_PACKAGE" || return 1
        upgraded=true
    elif command -v "$PIP_BIN" >/dev/null 2>&1; then
        say "Updating graphify via pip ($GRAPHIFY_PYPI_PACKAGE)"
        "$PIP_BIN" install --upgrade "$GRAPHIFY_PYPI_PACKAGE" || return 1
        upgraded=true
    fi
    if ! $upgraded; then
        warn "no uv/pipx/pip found — cannot update graphify"; return 1
    fi
    if command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; then
        say "Refreshing graphify skill files (graphify install)"
        "$GRAPHIFY_BIN" install >/dev/null 2>&1 \
            || warn "graphify install failed — run it manually to refresh the skill"
    fi
}

# === collect work ===
# Ask the registries now rather than trust a cache up to 24h old.
$force_all || bash "$CHECK_UPDATES" --force --quiet >/dev/null 2>&1 || true
read -r -a needing <<<"$(tools_needing_update)"
if (( ${#needing[@]} == 0 )); then
    say "All tools up-to-date — nothing to upgrade."
    exit 0
fi

echo ""
echo "${COL_YELLOW}tokenwar upgrade${COL_RESET} — the following tools will be updated:"
for key in "${needing[@]}"; do
    case "$key" in
        ctx)  printf "  %s\n" "context-mode" ;;
        mem)  printf "  %s\n" "claude-mem" ;;
        cave) printf "  %s\n" "caveman" ;;
        pony) printf "  %s\n" "ponytail" ;;
        rtk)  printf "  %s\n" "rtk" ;;
        pxpipe) printf "  %s\n" "pxpipe" ;;
        graphify) printf "  %s\n" "graphify" ;;
        openwiki) printf "  %s\n" "OpenWiki" ;;
        tokenwar) printf "  %s\n" "tokenwar" ;;
    esac
done
echo ""

# === confirm ===
if ! $assume_yes; then
    reply=""
    if tty_readable; then
        printf "Upgrade now? [y/N] "
        read -r reply <"$TTY_DEVICE" 2>/dev/null || reply=""
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            if [[ -z "$reply" ]]; then
                warn "No interactive terminal — re-run with --yes to apply. Skipped."
            else
                say "Skipped."
            fi
            exit 0
            ;;
    esac
fi

# === apply ===
rc=0
for key in "${needing[@]}"; do
    case "$key" in
        ctx)  upgrade_plugin "$SLUG_CTX"  || rc=1 ;;
        mem)  upgrade_plugin "$SLUG_MEM"  || rc=1 ;;
        cave) upgrade_plugin "$SLUG_CAVE" || rc=1 ;;
        pony) upgrade_plugin "$SLUG_PONY" || rc=1 ;;
        rtk)  upgrade_rtk                 || rc=1 ;;
        pxpipe) upgrade_npm_global pxpipe "$PXPIPE_NPM_SPEC" || rc=1 ;;
        graphify) upgrade_graphify        || rc=1 ;;
        openwiki) upgrade_npm_global OpenWiki "$OPENWIKI_NPM_SPEC" || rc=1 ;;
    esac
done

# tokenwar last, in one compound command: bash has parsed it all before the
# pull rewrites this file.
{
    if [[ " ${needing[*]} " == *" tokenwar "* ]]; then upgrade_tokenwar || rc=1; fi
    # Re-check so the cache (and the statusline arrow) reflect the new versions
    # now, not after its 24h expiry.
    bash "$CHECK_UPDATES" --force --quiet >/dev/null 2>&1 || true
    echo ""
    if (( rc == 0 )); then
        say "Upgrade complete. ${COL_DIM}Restart your CLI for plugin changes to load.${COL_RESET}"
    else
        fail "One or more upgrades failed — see messages above."
    fi
    exit "$rc"
}
