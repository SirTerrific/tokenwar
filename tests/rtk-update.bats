#!/usr/bin/env bats
# Tests for rtk-update.sh — installs the latest RTK release, offline: every
# URL points at a fixture on disk.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/rtk-update.sh"
    [ -f "$SCRIPT" ] || skip "rtk-update.sh not found"
    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    # Mocks and system tools only: the host's own rtk must stay out of sight.
    local tool
    for tool in node curl; do
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$tool")" > "$MOCK_BIN/$tool"
        chmod +x "$MOCK_BIN/$tool"
    done
    export PATH="$MOCK_BIN:$HOME/.local/bin:/usr/bin:/bin"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

is_windows() {
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
    return 1
}

# file:// URL that curl (a native binary on Windows) can open.
file_url() {
    local p
    p="$(cygpath -m "$1" 2>/dev/null || printf '%s' "$1")"
    printf 'file:///%s' "${p#/}"
}

# A release zip holding a fake rtk.exe reporting <version>, plus the GitHub
# release JSON describing it. <digest> overrides the published sha256
# ("none" omits it).
make_release() {
    local version="$1" digest="${2:-}"
    local dir="$HOME/release"
    mkdir -p "$dir/pkg"
    printf '#!/bin/sh\necho "rtk %s"\n' "$version" > "$dir/pkg/rtk.exe"
    (cd "$dir/pkg" && /c/Windows/System32/tar.exe -a -c -f ../rtk.zip rtk.exe)
    local sha
    sha="$(sha256sum "$dir/rtk.zip" | awk '{print $1}')"
    [[ -n "$digest" ]] && sha="$digest"
    local digest_field=",\"digest\":\"sha256:$sha\""
    [[ "$digest" == none ]] && digest_field=""
    printf '{"tag_name":"v%s","assets":[{"name":"rtk-x86_64-pc-windows-msvc.zip","browser_download_url":"%s"%s}]}\n' \
        "$version" "$(file_url "$dir/rtk.zip")" "$digest_field" > "$dir/release.json"
    export TW_RTK_RELEASE_URL="$(file_url "$dir/release.json")"
}

@test "Windows: installs the latest release zip after checking its sha256" {
    is_windows || skip "Windows release path"
    make_release 0.51.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/bin/rtk.exe" ]
    [[ "$output" == *"RTK 0.51.0 installed"* ]]
}

@test "Windows: replaces an older rtk.exe in ~/.local/bin" {
    is_windows || skip "Windows release path"
    mkdir -p "$HOME/.local/bin"
    printf '#!/bin/sh\necho "rtk 0.49.0"\n' > "$HOME/.local/bin/rtk.exe"
    chmod +x "$HOME/.local/bin/rtk.exe"
    make_release 0.51.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$("$HOME/.local/bin/rtk.exe" --version)" = "rtk 0.51.0" ]
    [ ! -e "$HOME/.local/bin/rtk.exe.old" ]
}

@test "Windows: refuses a zip whose sha256 does not match" {
    is_windows || skip "Windows release path"
    make_release 0.51.0 "$(printf '0%.0s' {1..64})"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sha256 mismatch"* ]]
    [ ! -e "$HOME/.local/bin/rtk.exe" ]
}

@test "Windows: refuses a release that publishes no digest" {
    is_windows || skip "Windows release path"
    make_release 0.51.0 none
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no sha256 digest"* ]]
    [ ! -e "$HOME/.local/bin/rtk.exe" ]
}

@test "Linux/macOS: runs rtk's official installer into ~/.local/bin" {
    is_windows && skip "Linux/macOS installer path"
    cat > "$HOME/install.sh" <<'EOF'
echo "dir=$RTK_INSTALL_DIR" > "$HOME/installer.log"
EOF
    export TW_RTK_INSTALL_URL="$(file_url "$HOME/install.sh")"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "dir=$HOME/.local/bin" "$HOME/installer.log"
}

@test "leaves an rtk installed elsewhere to the tool that installed it" {
    printf '#!/bin/sh\necho "rtk 0.1.0"\n' > "$MOCK_BIN/rtk"
    chmod +x "$MOCK_BIN/rtk"
    export TW_RTK_RELEASE_URL="$(file_url "$HOME/missing.json")"
    export TW_RTK_INSTALL_URL="$TW_RTK_RELEASE_URL"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"was not installed into"* ]]
}
