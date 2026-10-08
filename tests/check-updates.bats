#!/usr/bin/env bats
# Tests for check-updates.sh — where a plugin's "latest" version comes from.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-updates.sh"
    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    mkdir -p "$HOME/.claude/tokenwar"
    # git is a native binary on Windows: hand it paths it can open, even with
    # MSYS_NO_PATHCONV=1. No-op elsewhere.
    winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
    # Offline by default: every registry points at a missing file unless a test
    # serves one.
    local none="file:///$(winpath "$HOME/no-registry.json" | sed 's|^/||')"
    export TW_GRAPHIFY_PYPI_URL="$none" TW_PXPIPE_NPM_URL="$none" \
           TW_OPENWIKI_NPM_URL="$none" TW_RTK_RELEASE_URL="$none"
    # No plugins installed unless a test says so; the real CLI is slow and
    # reports the host's own plugins.
    printf '#!/usr/bin/env bash\n[[ "$1 $2 $3" == "plugin list --json" ]] && echo "[]"\nexit 0\n' > "$MOCK_BIN/claude"
    chmod +x "$MOCK_BIN/claude"
    # Only the mocks and what the script needs: the host's real provider CLIs
    # (codex, kimi, copilot…) cost seconds each and leak host versions in.
    local tool
    for tool in node curl; do
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$tool")" > "$MOCK_BIN/$tool"
        chmod +x "$MOCK_BIN/$tool"
    done
    # git keeps its directory: a local push spawns git-receive-pack from PATH.
    export PATH="$MOCK_BIN:$(dirname "$(command -v git)"):/usr/bin:/bin"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# claude reports caveman installed at <version>.
mock_claude_caveman() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "plugin list --json" ]]; then
    echo '[{"id":"caveman@caveman","version":"$1","enabled":true}]'
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

# A caveman marketplace clone tracking a local bare "origin". Its
# marketplace.json carries NO version — like the real one — and the plugin's
# own plugin.json, when given, declares <plugin_version>.
# Usage: make_caveman_marketplace <source> [plugin_version]
make_caveman_marketplace() {
    local source="$1" plugin_version="${2:-}"
    local up work clone plugin_dir
    up="$(winpath "$HOME/caveman-up.git")"
    work="$(winpath "$HOME/caveman-work")"
    git init -q --bare -b main "$up"
    git init -q -b main "$work"
    git -C "$work" config user.email t@t
    git -C "$work" config user.name t
    mkdir -p "$work/.claude-plugin"
    printf '{"name":"caveman","plugins":[{"name":"caveman","source":"%s"}]}\n' "$source" \
        > "$work/.claude-plugin/marketplace.json"
    if [[ -n "$plugin_version" ]]; then
        plugin_dir="$work/${source#./}"
        mkdir -p "$plugin_dir/.claude-plugin"
        printf '{"name":"caveman","version":"%s"}\n' "$plugin_version" \
            > "$plugin_dir/.claude-plugin/plugin.json"
    fi
    git -C "$work" add -A
    git -C "$work" commit -qm init
    git -C "$work" remote add origin "$up"
    git -C "$work" push -q origin main
    clone="$HOME/.claude/plugins/marketplaces/caveman"
    mkdir -p "$(dirname "$clone")"
    git clone -q "$up" "$(winpath "$clone")"
}

@test "caveman's latest comes from its plugin.json, not a git SHA" {
    # Regression: the marketplace entry has no version, so the check fell back
    # to the clone's git SHA and compared "3.1.0" against it — a permanent
    # phantom update that `tokenwar upgrade` could never clear.
    mock_claude_caveman "3.1.0"
    make_caveman_marketplace "./" "3.1.0"
    run bash "$SCRIPT" --force
    [[ "$output" =~ caveman\ +3\.1\.0\ +→\ 3\.1\.0\ +up-to-date ]]
}

@test "plugin.json is found under a nested marketplace source" {
    mock_claude_caveman "3.0.0"
    make_caveman_marketplace "./plugins/caveman" "3.1.0"
    run bash "$SCRIPT" --force
    [[ "$output" =~ caveman\ +3\.0\.0\ +→\ 3\.1\.0\ +update-available ]]
}

@test "a plugin with no version anywhere still falls back to the git SHA" {
    mock_claude_caveman "3.1.0"
    make_caveman_marketplace "./"
    local sha
    sha="$(git -C "$(winpath "$HOME/.claude/plugins/marketplaces/caveman")" rev-parse --short=12 HEAD)"
    run bash "$SCRIPT" --force
    [[ "$output" == *"caveman"*"→ $sha"* ]]
}

@test "a marketplace clone behind upstream still reports upstream's version" {
    # Regression: under Git Bash `git show origin/main:<path>` was rewritten by
    # MSYS and failed silently, so the stale on-disk plugin.json was reported as
    # "latest" and a new release (ponytail 4.9.0 -> 5.0.0) was never flagged.
    # Must hold with MSYS path conversion on AND off.
    mock_claude_caveman "3.1.0"
    make_caveman_marketplace "./" "3.1.0"
    local work
    work="$(winpath "$HOME/caveman-work")"
    printf '{"name":"caveman","version":"3.2.0"}\n' > "$work/.claude-plugin/plugin.json"
    git -C "$work" commit -qam bump
    git -C "$work" push -q origin main
    # The clone still holds 3.1.0 on disk; only origin has 3.2.0.
    run bash "$SCRIPT" --force
    [[ "$output" =~ caveman\ +3\.1\.0\ +→\ 3\.2\.0\ +update-available ]]
    unset MSYS_NO_PATHCONV
    run bash "$SCRIPT" --force
    [[ "$output" =~ caveman\ +3\.1\.0\ +→\ 3\.2\.0\ +update-available ]]
}


# ── latest versions come from the live registries ────────────────

# file:// URL for a fixture. curl is a native binary on Windows and needs the
# C:/ form of the path; the plain path elsewhere.
file_url() {
    local p
    p="$(winpath "$1")"
    printf 'file:///%s' "${p#/}"
}

# Field <tool>.<key> of the cache the last run wrote.
cache_field() {
    CACHE="$(winpath "$HOME/.claude/tokenwar/upgrade-check.json")" node -e '
        const d = JSON.parse(require("fs").readFileSync(process.env.CACHE, "utf8"));
        process.stdout.write(String((d.tools[process.argv[1]] || {})[process.argv[2]] || ""));
    ' "$1" "$2"
}

# A CLI that answers --version with <output>.
mock_version_cli() {
    printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && echo "%s"\nexit 0\n' "$2" > "$MOCK_BIN/$1"
    chmod +x "$MOCK_BIN/$1"
}

@test "pxpipe's latest comes from the npm registry, not a pinned constant" {
    mock_version_cli pxpipe "0.10.0"
    echo '{"name":"pxpipe-proxy","version":"0.14.0"}' > "$HOME/npm.json"
    TW_PXPIPE_NPM_URL="$(file_url "$HOME/npm.json")" run bash "$SCRIPT" --force --quiet
    [ "$(cache_field pxpipe latest)" = "0.14.0" ]
    [ "$(cache_field pxpipe state)" = "update-available" ]
}

@test "rtk's latest is the newest GitHub release, leading v dropped" {
    mock_version_cli rtk "rtk 0.49.0"
    echo '{"tag_name":"v0.51.0","assets":[]}' > "$HOME/release.json"
    TW_RTK_RELEASE_URL="$(file_url "$HOME/release.json")" run bash "$SCRIPT" --force --quiet
    [ "$(cache_field rtk latest)" = "0.51.0" ]
    [ "$(cache_field rtk state)" = "update-available" ]
}

@test "OpenWiki is checked against npm, its version read from package.json" {
    # OpenWiki has no --version flag: the installed version is its package.json.
    local root="$HOME/npm-root"
    mkdir -p "$root/openwiki"
    echo '{"name":"openwiki","version":"0.5.1"}' > "$root/openwiki/package.json"
    printf '#!/usr/bin/env bash\n[[ "$1 $2" == "root -g" ]] && echo "%s"\nexit 0\n' "$(winpath "$root")" > "$MOCK_BIN/npm"
    chmod +x "$MOCK_BIN/npm"
    echo '{"name":"openwiki","version":"0.7.0"}' > "$HOME/ow.json"
    TW_OPENWIKI_NPM_URL="$(file_url "$HOME/ow.json")" run bash "$SCRIPT" --force --quiet
    [ "$(cache_field openwiki installed)" = "0.5.1" ]
    [ "$(cache_field openwiki state)" = "update-available" ]
}

@test "an unreachable registry reports unknown, never up-to-date" {
    mock_version_cli pxpipe "0.10.0"
    TW_PXPIPE_NPM_URL="$(file_url "$HOME/missing.json")" run bash "$SCRIPT" --force --quiet
    [ "$(cache_field pxpipe state)" = "unknown" ]
}

@test "ponytail is tracked like the other plugins" {
    run bash "$SCRIPT" --force --quiet
    CACHE="$(winpath "$HOME/.claude/tokenwar/upgrade-check.json")" node -e '
        const d = JSON.parse(require("fs").readFileSync(process.env.CACHE, "utf8"));
        process.exit(d.tools.ponytail && d.tools.ponytail.slug === "ponytail@ponytail" ? 0 : 1);
    '
}

# A tokenwar clone running its own check-updates.sh, <behind> commits behind
# origin. Echoes the clone path.
make_tokenwar_clone() {
    local up seed tw
    up="$(winpath "$HOME/tw-up.git")"
    seed="$(winpath "$HOME/tw-seed")"
    tw="$(winpath "$HOME/tw-clone")"
    git init -q --bare -b main "$up"
    git init -q -b main "$seed"
    git -C "$seed" config user.email t@t; git -C "$seed" config user.name t
    cp -r "$BATS_TEST_DIRNAME/../scripts" "$seed/"
    git -C "$seed" add -A; git -C "$seed" commit -qm v1
    git -C "$seed" remote add origin "$up"; git -C "$seed" push -q origin main
    git clone -q "$up" "$tw"
    git -C "$tw" config user.email t@t; git -C "$tw" config user.name t
    if [[ "$1" == behind ]]; then
        echo v2 > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm v2
        git -C "$seed" push -q origin main
    else
        echo local > "$tw/f"; git -C "$tw" add f; git -C "$tw" commit -qm local
    fi
    printf '%s' "$tw"
}

@test "tokenwar reports an update when its clone is behind origin" {
    local tw
    tw="$(make_tokenwar_clone behind)"
    run bash "$tw/scripts/check-updates.sh" --force --quiet
    [ "$(cache_field tokenwar state)" = "update-available" ]
}

@test "a tokenwar clone ahead of origin is current, not behind" {
    local tw
    tw="$(make_tokenwar_clone ahead)"
    run bash "$tw/scripts/check-updates.sh" --force --quiet
    [ "$(cache_field tokenwar state)" = "up-to-date" ]
}
