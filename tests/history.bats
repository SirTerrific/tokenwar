#!/usr/bin/env bats
@test "sanitized snapshots and comparisons preserve uncertainty" {
  # Relative path: node is a native binary on Windows and cannot open an MSYS
  # path such as /d/... when MSYS_NO_PATHCONV disables the automatic rewrite.
  cd "$BATS_TEST_DIRNAME"
  run node --test history.test.mjs
  [ "$status" -eq 0 ]
}
