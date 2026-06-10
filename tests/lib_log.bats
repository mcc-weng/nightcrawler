#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT/demo"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "nc_cycle_id defaults to today's date" {
  run nc_cycle_id demo
  [ "$output" = "$(date +%F)" ]
}

@test "nc_cycle_id uses a task cycle_id hook when present" {
  printf '#!/bin/bash\necho CYCLE-XYZ\n' > "$NC_TASKS_ROOT/demo/cycle_id"
  chmod +x "$NC_TASKS_ROOT/demo/cycle_id"
  run nc_cycle_id demo
  [ "$output" = "CYCLE-XYZ" ]
}

@test "nc_logfile is rooted under the task log dir, named by cycle_id" {
  run nc_logfile demo
  [ "$output" = "$NC_LOG_ROOT/demo/$(date +%F).log" ]
}

@test "nc_log appends a tab-separated timestamped line" {
  nc_log demo "START hello"
  file="$NC_LOG_ROOT/demo/$(date +%F).log"
  [ -f "$file" ]
  run cat "$file"
  [[ "$output" == *$'\t'"START hello" ]]
}
