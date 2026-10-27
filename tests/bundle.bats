#!/usr/bin/env bats
# Tests for bundle.sh — toggle.sh is replaced by a fake via TOKENWAR_TOGGLE_SCRIPT.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/bundle.sh"
    FAKE="$(mktemp)"
    cat > "$FAKE" <<'EOT'
#!/usr/bin/env bash
case "$2" in
    rtk|pxpipe|graphify) echo "$2 is a standalone tool; use its own command" >&2; exit 3 ;;
    missing) exit 1 ;;
    *) exit 0 ;;
esac
EOT
    export TOKENWAR_TOGGLE_SCRIPT="$FAKE"
}

teardown() { rm -f "$FAKE"; }

@test "standalone tools (toggle exit 3) are reported as manual, not as a failure" {
    run bash "$SCRIPT" devops --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"manual    rtk"* ]]
    [[ "$output" == *"manual    pxpipe"* ]]
    [[ "$output" == *"enabled   caveman"* ]]
    [[ "$output" != *"not installed"* ]]
}

@test "a plugin that toggle cannot switch still makes the bundle exit 1" {
    cat > "$FAKE" <<'EOT'
#!/usr/bin/env bash
[[ "$2" == caveman ]] && exit 1
exit 0
EOT
    run bash "$SCRIPT" devops --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"skipped   caveman (not installed)"* ]]
}
