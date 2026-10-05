#!/usr/bin/env bats
# Tests for pxpipe-desktop.sh — wiring the Claude desktop app through pxpipe.
# Nothing here starts a real proxy: pxpipe's warp modules are stubbed and the
# launcher is a mock.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/pxpipe-desktop.sh"
    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    export CALLS="$HOME/calls.log"
    export TW_PXPIPE_WAIT_SECS=2
    export SETTINGS="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"

    # pxpipe's warp modules, stubbed: only the CA path matters for wiring.
    local root="$HOME/pxpipe-proxy"
    mkdir -p "$root/dist/warp"
    printf 'export class CertificateAuthority { static loadOrCreate() { return { certPath: "C:/fake/warp-ca.pem" }; } }\n' > "$root/dist/warp/ca.js"
    printf 'export function createWarpHandlers() { return {}; }\n' > "$root/dist/warp/connect.js"
    printf 'export function parseRoute(s) { return s; }\n' > "$root/dist/warp/route.js"
    export TW_PXPIPE_ROOT="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/pxpipe"
    printf '#!/usr/bin/env bash\necho "schtasks $*" >> "%s"\n' "$CALLS" > "$MOCK_BIN/schtasks"
    # The launcher "starts" both proxies; curl answers once they are up.
    printf '#!/usr/bin/env bash\necho launched >> "%s"; touch "%s/up"\n' "$CALLS" "$HOME" > "$MOCK_BIN/launcher"
    cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
[[ -f "$HOME/up" ]] || exit 7
printf 200
EOF
    chmod +x "$MOCK_BIN"/*
    export TW_PXPIPE_LAUNCHER="$MOCK_BIN/launcher"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

env_of() {
    FILE="$(cygpath -m "$SETTINGS" 2>/dev/null || printf '%s' "$SETTINGS")" node -e '
        const s = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
        process.stdout.write(JSON.stringify(s.env || {}));'
}

@test "on: starts the proxy, then wires settings.json, keeping other settings" {
    echo '{"statusLine":{"command":"x"},"env":{"FOO":"1"}}' > "$SETTINGS"
    run bash "$SCRIPT" on
    [ "$status" -eq 0 ]
    grep -qx launched "$CALLS"
    [ "$(env_of)" = '{"FOO":"1","HTTPS_PROXY":"http://127.0.0.1:47822","NO_PROXY":"localhost,127.0.0.1,::1","NODE_EXTRA_CA_CERTS":"C:/fake/warp-ca.pem"}' ]
    grep -q '"statusLine"' "$SETTINGS"
    [ -f "$SETTINGS.tokenwar-pxpipe.bak" ]
}

@test "on: never wires settings.json to a proxy that did not start" {
    printf '#!/usr/bin/env bash\necho launched >> "%s"\n' "$CALLS" > "$MOCK_BIN/launcher"
    echo '{"env":{"FOO":"1"}}' > "$SETTINGS"
    run bash "$SCRIPT" on
    [ "$status" -eq 1 ]
    [[ "$output" == *"settings.json left unchanged"* ]]
    [ "$(env_of)" = '{"FOO":"1"}' ]
}

@test "on: registers the logon task on Windows" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "Windows Task Scheduler" ;; esac
    run bash "$SCRIPT" on
    [ "$status" -eq 0 ]
    grep -q "schtasks /Create /TN tokenwar-pxpipe-desktop /TR .*pxpipe-desktop.sh.* run /SC ONLOGON /RL LIMITED /F" "$CALLS"
}

@test "off: removes only our keys, and leaves a foreign proxy alone" {
    touch "$HOME/up"
    bash "$SCRIPT" on >/dev/null 2>&1
    run bash "$SCRIPT" off
    [ "$status" -eq 0 ]
    [ "$(env_of)" = '{}' ]
    # A corporate HTTPS_PROXY is not ours to remove.
    echo '{"env":{"HTTPS_PROXY":"http://corp:3128","NO_PROXY":".corp"}}' > "$SETTINGS"
    run bash "$SCRIPT" off
    [ "$(env_of)" = '{"HTTPS_PROXY":"http://corp:3128","NO_PROXY":".corp"}' ]
}

@test "status flags settings wired to a proxy that is down" {
    touch "$HOME/up"
    bash "$SCRIPT" on >/dev/null 2>&1
    rm -f "$HOME/up"
    run bash "$SCRIPT" status
    [ "$status" -ne 0 ]
    [[ "$output" == *"wired to a proxy that is down"* ]]
}

@test "tokenwar pxpipe desktop dispatches to the script" {
    run bash "$BATS_TEST_DIRNAME/../scripts/tokenwar.sh" pxpipe desktop bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: tokenwar pxpipe desktop on|off|status"* ]]
}
