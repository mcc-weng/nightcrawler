#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  export NC_LAUNCHAGENTS_DIR="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT/demo" "$NC_LAUNCHAGENTS_DIR"
  cat > "$NC_TASKS_ROOT/demo/task.env" <<'EOF'
SCHEDULE_HOUR=9
SCHEDULE_MINUTE=0
RETRY_ENABLED=true
EOF
  INSTALL="$BATS_TEST_DIRNAME/../engine/install-task.sh"
}

@test "render-only produces a lint-clean primary plist with the right Hour" {
  run bash "$INSTALL" demo --render-only
  [ "$status" -eq 0 ]
  primary="$NC_LAUNCHAGENTS_DIR/com.nightcrawler.demo.plist"
  [ -f "$primary" ]
  run plutil -lint "$primary"
  [ "$status" -eq 0 ]
  run plutil -extract StartCalendarInterval.Hour raw "$primary"
  [ "$output" = "9" ]
  run plutil -extract ProgramArguments.1 raw "$primary"
  [ "$output" = "demo" ]
}

@test "render-only produces a retry plist when RETRY_ENABLED=true" {
  run bash "$INSTALL" demo --render-only
  [ "$status" -eq 0 ]
  retry="$NC_LAUNCHAGENTS_DIR/com.nightcrawler.demo-retry.plist"
  [ -f "$retry" ]
  run plutil -lint "$retry"
  [ "$status" -eq 0 ]
  run plutil -extract StartInterval raw "$retry"
  [ "$output" = "1800" ]
}
