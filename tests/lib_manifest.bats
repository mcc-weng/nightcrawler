#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT/demo"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
  cat > "$NC_TASKS_ROOT/demo/task.env" <<'EOF'
SCHEDULE_HOUR=9
SUCCESS_MODE=markers
SUCCESS_MARKERS=("OK: DONE")
EOF
}

@test "load_manifest sets declared vars and applies defaults" {
  nc_load_manifest demo
  [ "$SCHEDULE_HOUR" = "9" ]
  [ "$SCHEDULE_MINUTE" = "0" ]
  [ "$CAFFEINATE_TIMEOUT" = "0" ]
  [ "$NEEDS_BROWSER_LOCK" = "false" ]
  [ "$LABEL" = "demo" ]
}

@test "load_manifest fails when SCHEDULE_HOUR is missing" {
  echo 'SUCCESS_MODE=exitcode' > "$NC_TASKS_ROOT/demo/task.env"
  run nc_load_manifest demo
  [ "$status" -ne 0 ]
}

@test "run_hook executes an existing hook with NC_ env set" {
  printf '#!/bin/bash\necho "task=$NC_TASK dir=$NC_TASK_DIR"\n' > "$NC_TASKS_ROOT/demo/probe"
  chmod +x "$NC_TASKS_ROOT/demo/probe"
  run nc_run_hook demo probe
  [ "$status" -eq 0 ]
  [[ "$output" == "task=demo dir=$NC_TASKS_ROOT/demo" ]]
}

@test "run_hook returns 127 when the hook is missing" {
  run -127 nc_run_hook demo nonexistent
  [ "$status" -eq 127 ]
}

@test "run_hook propagates the hook's exit code" {
  printf '#!/bin/bash\nexit 3\n' > "$NC_TASKS_ROOT/demo/probe"
  chmod +x "$NC_TASKS_ROOT/demo/probe"
  run nc_run_hook demo probe
  [ "$status" -eq 3 ]
}
