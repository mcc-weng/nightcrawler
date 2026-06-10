#!/usr/bin/env bats

setup() {
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_TASKS_ROOT/a" "$NC_TASKS_ROOT/b"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
  printf 'SCHEDULE_HOUR=9\nSCHEDULE_MINUTE=0\n'  > "$NC_TASKS_ROOT/a/task.env"
  printf 'SCHEDULE_HOUR=7\nSCHEDULE_MINUTE=30\n' > "$NC_TASKS_ROOT/b/task.env"
}

@test "earliest_wake returns the earliest task time across all tasks" {
  run nc_earliest_wake
  [ "$output" = "07:30" ]
}

@test "wake_target subtracts one minute" {
  run nc_wake_target "07:30"
  [ "$output" = "07:29:00" ]
}

@test "wake_target underflows across midnight" {
  run nc_wake_target "00:00"
  [ "$output" = "23:59:00" ]
}

@test "earliest_wake ignores a SCHEDULE_MINUTE leaked by a prior load_manifest" {
  # The installer calls nc_load_manifest <task> before nc_earliest_wake, leaking
  # the loaded task's SCHEDULE_MINUTE into the shell. A task that omits the minute
  # must still default to :00, not inherit the leaked value.
  printf 'SCHEDULE_HOUR=8\nSCHEDULE_MINUTE=45\n' > "$NC_TASKS_ROOT/a/task.env"
  nc_load_manifest a
  printf 'SCHEDULE_HOUR=6\n' > "$NC_TASKS_ROOT/b/task.env"
  run nc_earliest_wake
  [ "$output" = "06:00" ]
}
