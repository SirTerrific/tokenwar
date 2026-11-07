#!/usr/bin/env bats
# prune.sh argument handling (the scan itself is covered by scan.bats).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/prune.sh"
}

@test "prune --days rejects a non-integer" {
    run bash "$SCRIPT" --days abc
    [ "$status" -eq 2 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "prune rejects an unknown option instead of ignoring it" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "prune --help exits 0" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}
