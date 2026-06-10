#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "lib.sh sources and honors NC_LOG_ROOT override" {
  [ "$NC_LOG_ROOT" = "$BATS_TEST_TMPDIR/logs" ]
  [ "$NC_LOCK_DIR" = "$BATS_TEST_TMPDIR/logs/.browser.lock" ]
}
