#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$NC_LOG_ROOT"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "acquire succeeds on a free lock and writes our pid" {
  run nc_lock_acquire
  [ "$status" -eq 0 ]
  [ "$(cat "$NC_LOCK_DIR/pid")" = "$$" ]
}

@test "acquire fails when a live owner holds the lock" {
  mkdir -p "$NC_LOCK_DIR"
  echo "$$" > "$NC_LOCK_DIR/pid"
  run nc_lock_acquire
  [ "$status" -eq 1 ]
}

@test "acquire steals a lock whose owner pid is dead" {
  mkdir -p "$NC_LOCK_DIR"
  echo "999999" > "$NC_LOCK_DIR/pid"
  run nc_lock_acquire
  [ "$status" -eq 0 ]
  [ "$(cat "$NC_LOCK_DIR/pid")" = "$$" ]
}

@test "release removes the lock dir" {
  nc_lock_acquire
  nc_lock_release
  [ ! -d "$NC_LOCK_DIR" ]
}
