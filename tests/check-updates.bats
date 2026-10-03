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
