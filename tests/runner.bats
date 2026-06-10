#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT/demo"
  RUNNER="$BATS_TEST_DIRNAME/../engine/runner.sh"

  cat > "$NC_TASKS_ROOT/demo/task.env" <<'EOF'
SCHEDULE_HOUR=0
SUCCESS_MODE=markers
SUCCESS_MARKERS=("OK: DONE")
NEEDS_BROWSER_LOCK=false
CAFFEINATE_TIMEOUT=0
EOF
  printf '#!/bin/bash\necho "OK: DONE"\n' > "$NC_TASKS_ROOT/demo/run"
  printf '#!/bin/bash\nexit 0\n' > "$NC_TASKS_ROOT/demo/should_run"
  chmod +x "$NC_TASKS_ROOT/demo/run" "$NC_TASKS_ROOT/demo/should_run"
}

logfile() { echo "$NC_LOG_ROOT/demo/$(date +%F).log"; }

@test "happy path logs RESULT: DONE" {
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$(logfile)"
  [[ "$output" == *"RESULT: DONE"* ]]
}

@test "should_run exit 1 skips without running executor" {
  printf '#!/bin/bash\nexit 1\n' > "$NC_TASKS_ROOT/demo/should_run"
  chmod +x "$NC_TASKS_ROOT/demo/should_run"
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$(logfile)"
  [[ "$output" == *"SKIP (should_run exit 1)"* ]]
  [[ "$output" != *"RESULT:"* ]]
}

@test "missing should_run hook is a hard error" {
  rm "$NC_TASKS_ROOT/demo/should_run"
  run bash "$RUNNER" demo
  [ "$status" -eq 1 ]
}

@test "failed marker logs RESULT: FAILED and calls notify" {
  printf '#!/bin/bash\necho "nope"\n' > "$NC_TASKS_ROOT/demo/run"
  chmod +x "$NC_TASKS_ROOT/demo/run"
  printf '#!/bin/bash\necho "notified=$1" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$(logfile)"
  [[ "$output" == *"RESULT: FAILED"* ]]
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"notified=FAILED"* ]]
}

@test "browser lock prevents a second concurrent run" {
  sed -i '' 's/NEEDS_BROWSER_LOCK=false/NEEDS_BROWSER_LOCK=true/' "$NC_TASKS_ROOT/demo/task.env"
  mkdir -p "$NC_LOG_ROOT/.browser.lock"
  echo "$$" > "$NC_LOG_ROOT/.browser.lock/pid"   # live owner (bats process)
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$(logfile)"
  [[ "$output" == *"SKIP (browser lock held)"* ]]
}

@test "--retry defers (executor never runs) before the scheduled hour" {
  [ "$(date +%H)" = "23" ] && skip "current hour is 23: deferral gate not deterministically exercisable"
  sed -i '' 's/^SCHEDULE_HOUR=.*/SCHEDULE_HOUR=23/' "$NC_TASKS_ROOT/demo/task.env"
  run bash "$RUNNER" demo --retry
  [ "$status" -eq 0 ]
  run cat "$(logfile)"
  [[ "$output" == *"RETRY deferred"* ]]
  [[ "$output" != *"RESULT:"* ]]
}

@test "notify hook receives NC_RETRY=true under --retry" {
  printf '#!/bin/bash\necho "retry=$NC_RETRY status=$1" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo --retry
  [ "$status" -eq 0 ]
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"retry=true status=DONE"* ]]
}

@test "notify hook receives NC_RETRY=false without --retry" {
  printf '#!/bin/bash\necho "retry=$NC_RETRY" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"retry=false"* ]]
}

@test "notify hook is called with SKIPPED when should_run skips" {
  printf '#!/bin/bash\nexit 1\n' > "$NC_TASKS_ROOT/demo/should_run"
  chmod +x "$NC_TASKS_ROOT/demo/should_run"
  printf '#!/bin/bash\necho "status=$1" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"status=SKIPPED"* ]]
}
