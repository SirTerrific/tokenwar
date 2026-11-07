#!/usr/bin/env bats
# restore-settings.sh merges settings.local.json into settings.json.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/restore-settings.sh"
    export CLAUDE_CONFIG_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$CLAUDE_CONFIG_DIR"
}

@test "no settings.local.json exits 0 so 'restore && claude' still launches" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to merge"* ]]
}

@test "local keys win and keys falsy in settings.json are not reported as restored" {
    echo '{"a":1,"b":false}' > "$CLAUDE_CONFIG_DIR/settings.json"
    echo '{"b":true,"c":2}' > "$CLAUDE_CONFIG_DIR/settings.local.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored keys: c" ]]
    run node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s.a,s.b,s.c)' "$(cygpath -m "$CLAUDE_CONFIG_DIR/settings.json" 2>/dev/null || echo "$CLAUDE_CONFIG_DIR/settings.json")"
    [ "$output" = "1 true 2" ]
}

@test "invalid settings.json is left untouched and reported" {
    echo '{bad' > "$CLAUDE_CONFIG_DIR/settings.json"
    echo '{"c":2}' > "$CLAUDE_CONFIG_DIR/settings.local.json"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]]
    [ "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = "{bad" ]
}
