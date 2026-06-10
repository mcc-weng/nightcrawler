#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_DIRNAME/../examples"
  mkdir -p "$NC_LOG_ROOT"
  # Shim caffeinate: echo its args (teed into the log) and exec the real command.
  cat > "$BATS_TEST_TMPDIR/fake-caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate-args: $*"
shift 3
exec "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-caffeinate"
  export NC_CAFFEINATE_BIN="$BATS_TEST_TMPDIR/fake-caffeinate"
  RUNNER="$BATS_TEST_DIRNAME/../engine/runner.sh"
}

intlog() { echo "$NC_LOG_ROOT/integrated/"*.log; }

@test "integrated path: lock + caffeinate + multiline markers -> DONE, lock released" {
  run bash "$RUNNER" integrated
  [ "$status" -eq 0 ]
  run cat $(intlog)
  [[ "$output" == *"caffeinate-args: -is -t 30"* ]]   # caffeinate wrapped the run
  [[ "$output" == *"A: OK"* ]]
  [[ "$output" == *"B: OK"* ]]
  [[ "$output" == *"RESULT: DONE"* ]]
  [ ! -d "$NC_LOG_ROOT/.browser.lock" ]               # lock released on exit
}

@test "integrated path: second run sees both markers in the log -> should_run skips" {
  bash "$RUNNER" integrated            # first run fills the log
  run bash "$RUNNER" integrated        # second run
  [ "$status" -eq 0 ]
  run cat $(intlog)
  [[ "$output" == *"SKIP (should_run exit 1)"* ]]
}
