#!/usr/bin/env bash
# tokenwar check-updates — detect available upgrades for the tokenwar stack.
#
# Strategy: refresh marketplace manifests (throttled, 24h cache), then compare
# installed version vs marketplace `version` field for each plugin. For RTK,
# compare local `rtk --version` against `cargo search rtk` registry result.
#
# Output: one line per tool with status `up-to-date | update-available | ahead | unknown`.
# Exit codes: 0 = all up-to-date, 2 = at least one update available, 1 = error.
#
# Cache: ~/.claude/tokenwar/upgrade-check.json — refreshed when older than CACHE_TTL_SECONDS.
# Force refresh: pass --force.

set -euo pipefail

readonly CACHE_DIR="${HOME}/.claude/tokenwar"
readonly CACHE_FILE="${CACHE_DIR}/upgrade-check.json"
readonly CACHE_TTL_SECONDS=86400  # 24h

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"
readonly SLUG_PONY="ponytail@ponytail"

readonly MARKETPLACE_CTX="context-mode"
readonly MARKETPLACE_MEM="thedotmack"
readonly MARKETPLACE_CAVE="caveman"
readonly MARKETPLACE_PONY="ponytail"

readonly MARKETPLACE_ROOT="${HOME}/.claude/plugins/marketplaces"
readonly MARKETPLACE_MANIFEST_REL=".claude-plugin/marketplace.json"
readonly PLUGIN_MANIFEST_REL=".claude-plugin/plugin.json"
readonly RTK_BIN="rtk"
readonly PXPIPE_BIN="pxpipe"
readonly PXPIPE_NPM_PACKAGE="pxpipe-proxy"
readonly OPENWIKI_NPM_PACKAGE="openwiki"

# "Latest" always comes from the component's own registry, never from a
# constant: a hardcoded number goes stale between tokenwar releases and reports
# a phantom up-to-date (pxpipe sat at a pinned 0.10.0 while 0.14.0 shipped). Each
# lookup has a hard timeout, and any failure degrades to an honest `unknown`
# rather than a wrong verdict. Every URL is overridable so tests stay offline.
readonly REGISTRY_TIMEOUT_SECS=10
# graphify publishes to PyPI as `graphifyy`; the plain `graphify` name on PyPI
# is an unaffiliated package (see the upstream README).
readonly GRAPHIFY_BIN="graphify"
readonly GRAPHIFY_PYPI_PACKAGE="graphifyy"
readonly GRAPHIFY_PYPI_URL="https://pypi.org/pypi/${GRAPHIFY_PYPI_PACKAGE}/json"
readonly PXPIPE_NPM_URL="https://registry.npmjs.org/${PXPIPE_NPM_PACKAGE}/latest"
readonly OPENWIKI_NPM_URL="https://registry.npmjs.org/${OPENWIKI_NPM_PACKAGE}/latest"
readonly RTK_RELEASE_URL="https://api.github.com/repos/rtk-ai/rtk/releases/latest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"

readonly STATUS_UPTODATE="up-to-date"
readonly STATUS_UPDATE="update-available"
readonly STATUS_AHEAD="ahead"
readonly STATUS_UNKNOWN="unknown"

force_refresh=false
quiet=false
for arg in "$@"; do
    case "$arg" in
        --force) force_refresh=true ;;
        --quiet) quiet=true ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

mkdir -p "$CACHE_DIR"

cache_is_fresh() {
    [[ -f "$CACHE_FILE" ]] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    (( age < CACHE_TTL_SECONDS ))
}

# Refresh marketplaces (network call). Per-marketplace `git fetch` only — we
# read the latest `marketplace.json` from the fetched upstream ref
# (`marketplace_version` below), so we never `git pull`/`git checkout` and never
# need a clean working tree. This is critical: a locally-customized clone (e.g.
# a `plugin.json` rewritten to point at a bun binary + absolute paths) would
# make `git pull --ff-only` fail forever and poison the cache with phantom
# "up-to-date" verdicts. Failures are surfaced on stderr (unless --quiet) but
# never abort — we still emit a cache below, and the global `refresh_ok` flag
# tells consumers the cache may be stale.
#
# We intentionally do NOT call `claude plugin marketplace update` here: it
# races against the subsequent `claude plugin list --json` invocations (the
# CLI briefly returns an empty list while it rewrites its registry).
readonly REFRESHABLE_MARKETPLACES=(
    "$MARKETPLACE_CTX"
    "$MARKETPLACE_MEM"
    "$MARKETPLACE_CAVE"
    "$MARKETPLACE_PONY"
)
refresh_marketplaces() {
    local mp dir rc=0
    for mp in "${REFRESHABLE_MARKETPLACES[@]}"; do
        # git is a native Windows binary: it cannot chdir into an MSYS path when
        # MSYS_NO_PATHCONV=1 disables the implicit rewrite.
        dir="$(tw_node_path "${MARKETPLACE_ROOT}/${mp}")"
        if [[ ! -d "${dir}/.git" ]]; then
            $quiet || echo "tokenwar: marketplace clone missing: $dir" >&2
            rc=1
            continue
        fi
        if ! git -C "$dir" fetch --quiet 2>/dev/null; then
            $quiet || echo "tokenwar: git fetch failed for marketplace '$mp'" >&2
            rc=1
            continue
        fi
    done
    return $rc
}

# Read `version` from a marketplace.json's plugins[] entry matching `name`.
# Reads the manifest from the fetched upstream ref (origin/<branch>) first, so
# a clone that is behind upstream — or has local working-tree edits — never
# reports a stale "latest". Falls back to the on-disk manifest (no upstream).
# When the marketplace entry carries no `version`, the plugin's own
# .claude-plugin/plugin.json is next: caveman declares its version only there,
# and that is the version Claude Code installs and reports. Comparing the
# installed "3.1.0" against a git SHA instead flagged a permanent phantom
# update. The short git SHA is the last resort, for a plugin versioned by
# commit alone.
readonly MARKETPLACE_GIT_SHA_LEN=12

# `git show <ref>:<path>` with MSYS argument conversion switched off. Under Git
# Bash, "origin/main:.claude-plugin/plugin.json" looks like a POSIX path list
# and is rewritten into garbage, so git fails — and every caller here falls back
# to the on-disk file, i.e. a clone that is behind upstream reports its own
# stale version as "latest" (ponytail sat on 4.9.0 while 5.0.0 was out).
# MSYS2_ARG_CONV_EXCL='*' exempts the call regardless of MSYS_NO_PATHCONV.
git_show_ref() {
    local dir="$1" spec="$2"
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 git -C "$dir" show "$spec" 2>/dev/null
}

marketplace_version() {
    local marketplace="$1" plugin_name="$2"
    local marketplace_dir
    marketplace_dir="$(tw_node_path "${MARKETPLACE_ROOT}/${marketplace}")"
    local upstream="" manifest_json="" v="" src=""

    if [[ -d "${marketplace_dir}/.git" ]]; then
        upstream=$(git -C "$marketplace_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
        if [[ -n "$upstream" ]]; then
            manifest_json=$(git_show_ref "$marketplace_dir" "${upstream}:${MARKETPLACE_MANIFEST_REL}" || echo "")
        fi
    fi
    # The on-disk manifest is only a fallback for a clone with no upstream. When
    # an upstream exists but cannot be read, answer "unknown" instead of
    # silently reporting the (possibly stale) working-tree version as latest.
    if [[ -z "$manifest_json" && -z "$upstream" && -f "${marketplace_dir}/${MARKETPLACE_MANIFEST_REL}" ]]; then
        manifest_json=$(cat "${marketplace_dir}/${MARKETPLACE_MANIFEST_REL}" 2>/dev/null || echo "")
    fi
    if [[ -n "$manifest_json" ]]; then
        # "<version>|<plugin dir relative to the marketplace root>"
        local entry
        entry=$(MANIFEST_JSON="$manifest_json" PLUGIN_NAME="$plugin_name" node --input-type=module -e "
            const m = JSON.parse(process.env.MANIFEST_JSON);
            const list = Array.isArray(m.plugins) ? m.plugins : [];
            const entry = list.find(p => p.name === process.env.PLUGIN_NAME);
            const src = typeof entry?.source === 'string'
                ? entry.source.replace(/^\.\/?/, '').replace(/\/+$/, '') : '';
            process.stdout.write((entry?.version || '') + '|' + src);
        " 2>/dev/null || echo "")
        v="${entry%%|*}"
        src="${entry#*|}"
        if [[ -n "$v" ]]; then echo "$v"; return; fi
    fi

    local plugin_rel="${src:+${src}/}${PLUGIN_MANIFEST_REL}" plugin_json=""
    if [[ -n "$upstream" ]]; then
        plugin_json=$(git_show_ref "$marketplace_dir" "${upstream}:${plugin_rel}" || echo "")
    fi
    if [[ -z "$plugin_json" && -z "$upstream" && -f "${marketplace_dir}/${plugin_rel}" ]]; then
        plugin_json=$(cat "${marketplace_dir}/${plugin_rel}" 2>/dev/null || echo "")
    fi
    if [[ -n "$plugin_json" ]]; then
        v=$(PLUGIN_JSON="$plugin_json" node --input-type=module -e "
            process.stdout.write(JSON.parse(process.env.PLUGIN_JSON).version || '');
        " 2>/dev/null || echo "")
        if [[ -n "$v" ]]; then echo "$v"; return; fi
    fi
    if [[ -d "${marketplace_dir}/.git" ]]; then
        git -C "$marketplace_dir" rev-parse --short="$MARKETPLACE_GIT_SHA_LEN" "${upstream:-HEAD}" 2>/dev/null || echo ""
        return
    fi
    echo ""
}

# claude runs from bash, not from node's execSync: on Windows node spawns
# through cmd.exe, which resolves a different `claude` than this shell's PATH.
installed_plugin_version() {
    local slug="$1" list
    list=$(claude plugin list --json 2>/dev/null) || list=""
    PLUGIN_LIST_JSON="$list" PLUGIN_QUERY="$slug" node --input-type=module -e "
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || '[]');
        const entry = arr.find(p => p.id === process.env.PLUGIN_QUERY);
        process.stdout.write(entry?.version || '');
    " 2>/dev/null || echo ""
}

rtk_installed_version() {
    command -v "$RTK_BIN" >/dev/null 2>&1 || { echo ""; return; }
    # A trailing \r here never matches the semver regex in classify(), which
    # would report the tool as update-available on every single run.
    "$RTK_BIN" --version 2>/dev/null | tw_strip_cr | awk '{print $2}'
}

pxpipe_installed_version() {
    command -v "$PXPIPE_BIN" >/dev/null 2>&1 || { echo ""; return; }
    "$PXPIPE_BIN" --version 2>/dev/null | tw_strip_cr | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
}

graphify_installed_version() {
    command -v "$GRAPHIFY_BIN" >/dev/null 2>&1 || { echo ""; return; }
    "$GRAPHIFY_BIN" --version 2>/dev/null | tw_strip_cr | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
}

# registry_version <url> <field> — the version a registry's JSON reports at
# <field>: "info.version" (PyPI), "version" (npm), "tag_name" (GitHub release).
# A leading "v" is dropped so it compares with `--version` output. Empty on any
# failure (no curl, no network, malformed payload) so classify() returns
# `unknown` instead of inventing drift.
#
# The payload is piped straight into node rather than staged in an environment
# variable: PyPI's project JSON lists every release file ever published and
# already exceeds the kernel's argv/env limit, which fails with
# "Argument list too long" and silently degrades the check to `unknown`.
registry_version() {
    command -v curl >/dev/null 2>&1 || { echo ""; return; }
    curl -fsSL --max-time "$REGISTRY_TIMEOUT_SECS" "$1" 2>/dev/null \
        | FIELD="$2" node --input-type=module -e '
            let s = "";
            process.stdin.on("data", d => s += d).on("end", () => {
                let d; try { d = JSON.parse(s); } catch { return; }
                const v = process.env.FIELD.split(".").reduce((o, k) => o?.[k], d);
                process.stdout.write(String(v || "").replace(/^v/, ""));
            });
        ' 2>/dev/null || echo ""
}

graphify_latest_version() { registry_version "${TW_GRAPHIFY_PYPI_URL:-$GRAPHIFY_PYPI_URL}" info.version; }
pxpipe_latest_version()   { registry_version "${TW_PXPIPE_NPM_URL:-$PXPIPE_NPM_URL}" version; }
openwiki_latest_version() { registry_version "${TW_OPENWIKI_NPM_URL:-$OPENWIKI_NPM_URL}" version; }

# OpenWiki has no --version flag ("Unknown option"), so read the version from
# the globally installed package's own package.json.
openwiki_installed_version() {
    command -v npm >/dev/null 2>&1 || { echo ""; return; }
    local root
    root="$(npm root -g 2>/dev/null | tw_strip_cr)"
    [[ -n "$root" ]] || { echo ""; return; }
    PKG="${root}/${OPENWIKI_NPM_PACKAGE}/package.json" node -e '
        try { process.stdout.write(String(require(process.env.PKG).version || "")); } catch {}
    ' 2>/dev/null || echo ""
}

# tokenwar's own install is a git clone (install.sh makes it). "installed" is
# the local HEAD, "latest" the fetched upstream tip — unless the clone already
# contains that tip: a checkout ahead of origin is current, not behind.
# Prints "<installed> <latest>", or nothing for a non-git install.
tokenwar_versions() {
    local root
    root="$(tw_node_path "$(cd "${SCRIPT_DIR}/.." && pwd)")"
    [[ -d "${root}/.git" ]] || return 0
    git -C "$root" fetch --quiet 2>/dev/null || true
    local head upstream
    head="$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null)" || return 0
    upstream="$(git -C "$root" rev-parse --short=12 '@{u}' 2>/dev/null || echo "")"
    if [[ -z "$upstream" ]] || git -C "$root" merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
        upstream="$head"
    fi
    printf '%s %s' "$head" "$upstream"
}

# Determine rtk's authoritative latest version.
#
#   1. Path-installed (`cargo install --path /path/to/rtk` — dev build). The
#      installed `rtk` binary was built from a local clone; latest = the
#      `version` field in that clone's Cargo.toml on the tracked upstream
#      branch. We `git fetch` first, then read `origin/<branch>:Cargo.toml`
#      so a stale local checkout doesn't shadow upstream.
#   2. Otherwise a released binary (rtk's installer, or the Windows zip):
#      latest = the newest GitHub release. Not `cargo search` — the public
#      crate named `rtk` is a different project (Rust Type Kit).
rtk_latest_version() {
    if command -v cargo >/dev/null 2>&1; then
        local repo_path
        repo_path=$(cargo install --list 2>/dev/null \
            | awk '/^rtk v.* \(.*\):$/ { match($0, /\(([^)]+)\)/, m); print m[1]; exit }')
        if [[ -n "$repo_path" && -d "$repo_path/.git" ]]; then
            git -C "$repo_path" fetch --quiet 2>/dev/null || true
            local branch ref
            branch=$(git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
            ref="${branch:-HEAD}"
            git_show_ref "$repo_path" "${ref}:Cargo.toml" \
                | awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}'
            return
        fi
    fi
    registry_version "${TW_RTK_RELEASE_URL:-$RTK_RELEASE_URL}" tag_name
}

# Compare two version strings. Returns one of: up-to-date | update-available | ahead | unknown.
#   - Equal → up-to-date
#   - Both parseable semver and installed < latest → update-available
#   - Both parseable semver and installed > latest → ahead (dev build)
#   - Otherwise (SHA, missing field) → up-to-date if equal, else update-available
classify() {
    local installed="$1" latest="$2"
    if [[ -z "$installed" || -z "$latest" ]]; then
        echo "$STATUS_UNKNOWN"; return
    fi
    if [[ "$installed" == "$latest" ]]; then
        echo "$STATUS_UPTODATE"; return
    fi
    # semver compare
    if [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local cmp
        cmp=$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)
        if [[ "$cmp" == "$installed" ]]; then
            echo "$STATUS_UPDATE"
        else
            echo "$STATUS_AHEAD"
        fi
        return
    fi
    # non-semver (git SHA, etc.) — different strings means update assumed
    echo "$STATUS_UPDATE"
}

if $force_refresh || ! cache_is_fresh; then
    refresh_ok=true
    refresh_marketplaces || refresh_ok=false

    ctx_installed=$(installed_plugin_version "$SLUG_CTX")
    mem_installed=$(installed_plugin_version "$SLUG_MEM")
    cave_installed=$(installed_plugin_version "$SLUG_CAVE")
    pony_installed=$(installed_plugin_version "$SLUG_PONY")
    openwiki_installed=$(openwiki_installed_version)
    tokenwar_installed="" tokenwar_latest=""
    read -r tokenwar_installed tokenwar_latest <<<"$(tokenwar_versions)" || true
    rtk_installed=$(rtk_installed_version)
    pxpipe_installed=$(pxpipe_installed_version)
    graphify_installed=$(graphify_installed_version)

    # Provider CLI versions
    codex_installed=$(provider_version "$PROVIDER_IDX_CODEX")
    gemini_installed=$(provider_version "$PROVIDER_IDX_GEMINI")
    kimi_installed=$(provider_version "$PROVIDER_IDX_KIMI")
    opencode_installed=$(provider_version "$PROVIDER_IDX_OPENCODE")
    copilot_installed=$(provider_version "$PROVIDER_IDX_COPILOT")
    # Latest provider versions: we don't have a reliable upstream source yet
    # (npm view would require knowing the exact package name). For now,
    # installed == latest unless we can prove otherwise via `codex doctor`.
    codex_latest="$codex_installed"
    gemini_latest="$gemini_installed"
    kimi_latest="$kimi_installed"
    opencode_latest="$opencode_installed"
    # Copilot CLI updates itself: `autoUpdate` defaults to true and the binary
    # pulls its own release. tokenwar reports the version it finds rather than
    # duplicating (and racing) that mechanism.
    copilot_latest="$copilot_installed"
    # Codex self-reports updates via `codex doctor` — parse if available
    if command -v codex >/dev/null 2>&1 && [[ -n "$codex_installed" ]]; then
        codex_doctor_latest=$(codex doctor 2>/dev/null | awk '/updates available/ {print $2}' | head -1 || echo "")
        [[ -n "$codex_doctor_latest" ]] && codex_latest="$codex_doctor_latest"
    fi
    ctx_latest=$(marketplace_version "$MARKETPLACE_CTX" "context-mode")
    mem_latest=$(marketplace_version "$MARKETPLACE_MEM" "claude-mem")
    cave_latest=$(marketplace_version "$MARKETPLACE_CAVE" "caveman")
    pony_latest=$(marketplace_version "$MARKETPLACE_PONY" "ponytail")
    rtk_latest=$(rtk_latest_version)
    pxpipe_latest=$(pxpipe_latest_version)
    graphify_latest=$(graphify_latest_version)
    openwiki_latest=$(openwiki_latest_version)

    ctx_state=$(classify "$ctx_installed" "$ctx_latest")
    mem_state=$(classify "$mem_installed" "$mem_latest")
    cave_state=$(classify "$cave_installed" "$cave_latest")
    pony_state=$(classify "$pony_installed" "$pony_latest")
    openwiki_state=$(classify "$openwiki_installed" "$openwiki_latest")
    tokenwar_state=$(classify "$tokenwar_installed" "$tokenwar_latest")
    rtk_state=$(classify "$rtk_installed" "$rtk_latest")
    pxpipe_state=$(classify "$pxpipe_installed" "$pxpipe_latest")
    graphify_state=$(classify "$graphify_installed" "$graphify_latest")
    codex_state=$(classify "$codex_installed" "$codex_latest")
    gemini_state=$(classify "$gemini_installed" "$gemini_latest")
    kimi_state=$(classify "$kimi_installed" "$kimi_latest")
    opencode_state=$(classify "$opencode_installed" "$opencode_latest")
    copilot_state=$(classify "$copilot_installed" "$copilot_latest")

    now=$(date +%s)
    TOKENWAR_CACHE_FILE="$(tw_node_path "$CACHE_FILE")" \
    NOW="$now" \
    REFRESH_OK="$($refresh_ok && echo 1 || echo 0)" \
    CTX_I="$ctx_installed" CTX_L="$ctx_latest" CTX_S="$ctx_state" \
    MEM_I="$mem_installed" MEM_L="$mem_latest" MEM_S="$mem_state" \
    CAVE_I="$cave_installed" CAVE_L="$cave_latest" CAVE_S="$cave_state" \
    PONY_I="$pony_installed" PONY_L="$pony_latest" PONY_S="$pony_state" \
    OPENWIKI_I="$openwiki_installed" OPENWIKI_L="$openwiki_latest" OPENWIKI_S="$openwiki_state" \
    TOKENWAR_I="$tokenwar_installed" TOKENWAR_L="$tokenwar_latest" TOKENWAR_S="$tokenwar_state" \
    RTK_I="$rtk_installed" RTK_L="$rtk_latest" RTK_S="$rtk_state" \
    PXPIPE_I="$pxpipe_installed" PXPIPE_L="$pxpipe_latest" PXPIPE_S="$pxpipe_state" \
    GRAPHIFY_I="$graphify_installed" GRAPHIFY_L="$graphify_latest" GRAPHIFY_S="$graphify_state" \
    CODEX_I="$codex_installed" CODEX_L="$codex_latest" CODEX_S="$codex_state" \
    GEMINI_I="$gemini_installed" GEMINI_L="$gemini_latest" GEMINI_S="$gemini_state" \
    KIMI_I="$kimi_installed" KIMI_L="$kimi_latest" KIMI_S="$kimi_state" \
    OPENCODE_I="$opencode_installed" OPENCODE_L="$opencode_latest" OPENCODE_S="$opencode_state" \
    COPILOT_I="$copilot_installed" COPILOT_L="$copilot_latest" COPILOT_S="$copilot_state" \
    node --input-type=module -e "
        import { writeFileSync } from 'node:fs';
        const e = process.env;
        const data = {
            checked_at: Number(e.NOW),
            refresh_ok: e.REFRESH_OK === '1',
            tools: {
                'context-mode': { installed: e.CTX_I, latest: e.CTX_L, state: e.CTX_S, slug: '$SLUG_CTX' },
                'claude-mem':   { installed: e.MEM_I, latest: e.MEM_L, state: e.MEM_S, slug: '$SLUG_MEM' },
                'caveman':      { installed: e.CAVE_I, latest: e.CAVE_L, state: e.CAVE_S, slug: '$SLUG_CAVE' },
                'ponytail':     { installed: e.PONY_I, latest: e.PONY_L, state: e.PONY_S, slug: '$SLUG_PONY' },
                'rtk':          { installed: e.RTK_I, latest: e.RTK_L, state: e.RTK_S, slug: 'github:rtk-ai/rtk' },
                'pxpipe':       { installed: e.PXPIPE_I, latest: e.PXPIPE_L, state: e.PXPIPE_S, slug: 'npm:$PXPIPE_NPM_PACKAGE' },
                'graphify':     { installed: e.GRAPHIFY_I, latest: e.GRAPHIFY_L, state: e.GRAPHIFY_S, slug: 'pypi:$GRAPHIFY_PYPI_PACKAGE' },
                'openwiki':     { installed: e.OPENWIKI_I, latest: e.OPENWIKI_L, state: e.OPENWIKI_S, slug: 'npm:$OPENWIKI_NPM_PACKAGE' },
                'tokenwar':     { installed: e.TOKENWAR_I, latest: e.TOKENWAR_L, state: e.TOKENWAR_S, slug: 'git:tokenwar' }
            },
            providers: {
                'codex':  { installed: e.CODEX_I, latest: e.CODEX_L, state: e.CODEX_S },
                'gemini': { installed: e.GEMINI_I, latest: e.GEMINI_L, state: e.GEMINI_S },
                'kimi':   { installed: e.KIMI_I, latest: e.KIMI_L, state: e.KIMI_S },
                'opencode': { installed: e.OPENCODE_I, latest: e.OPENCODE_L, state: e.OPENCODE_S },
                'copilot':  { installed: e.COPILOT_I, latest: e.COPILOT_L, state: e.COPILOT_S }
            }
        };
        writeFileSync(e.TOKENWAR_CACHE_FILE, JSON.stringify(data, null, 2));
    "
fi

# Render cache → stdout (unless --quiet, in which case only set exit code).
_render_cache() {
    local cache_file="$1" quiet="$2" status_upd_val="$3"
    TWC_QUIET="$quiet" TWC_STAT_UPD="$status_upd_val" TWC_CACHE_FILE="$(tw_node_path "$cache_file")" node --input-type=module <<'NODESCRIPT'
import { readFileSync } from 'node:fs';

const data = JSON.parse(readFileSync(process.env.TWC_CACHE_FILE, 'utf8'));
const toolEntries = Object.entries(data.tools);
const providerEntries = data.providers ? Object.entries(data.providers) : [];
const allEntries = [...toolEntries, ...providerEntries];
const updates = allEntries.filter(([, v]) => v.state === process.env.TWC_STAT_UPD);

if (process.env.TWC_QUIET !== '1') {
    const pad = (s, n) => String(s).padEnd(n);
    for (const [name, v] of toolEntries) {
        const line = `  ${pad(name, 14)} ${pad(v.installed || '-', 16)} → ${pad(v.latest || '-', 16)} ${v.state}`;
        console.log(line);
    }
    if (providerEntries.length > 0) {
        console.log('');
        for (const [name, v] of providerEntries) {
            const line = `  ${pad(name, 14)} ${pad(v.installed || '-', 16)} → ${pad(v.latest || '-', 16)} ${v.state}`;
            console.log(line);
        }
    }
    if (data.refresh_ok === false) {
        console.log('');
        console.log('  ⚠ marketplace refresh had errors — cache may understate available updates.');
    }
    if (updates.length > 0) {
        console.log('');
        console.log('  → ' + updates.length + ' update(s) available. Run `/tokenwar upgrade` to apply.');
    }
}
process.exit(updates.length > 0 ? 2 : 0);
NODESCRIPT
}
_render_cache "$CACHE_FILE" "$($quiet && echo 1 || echo 0)" "$STATUS_UPDATE"
