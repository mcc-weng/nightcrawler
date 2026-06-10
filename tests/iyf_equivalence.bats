#!/usr/bin/env bats

# iyf should_run must skip iff BOTH quests are done (COIN_COLLECTED or ALREADY_*),
# matching collect.sh cycle_done(). Exit 1 = skip, exit 0 = run.
setup() {
  SR="$BATS_TEST_DIRNAME/../tasks/iyf/should_run"
  export NC_LOG_FILE="$BATS_TEST_TMPDIR/cycle.log"
  export NC_TASK=iyf NC_TASK_DIR="$BATS_TEST_DIRNAME/../tasks/iyf"
}

run_sr() { run bash "$SR"; }

@test "no log -> run (exit 0)" { run_sr; [ "$status" -eq 0 ]; }

@test "both COIN_COLLECTED -> skip (exit 1)" {
  printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "both ALREADY -> skip (exit 1)" {
  printf 'SIGNIN: ALREADY_COLLECTED\nSHARE: ALREADY_COMPLETED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "mixed COIN + ALREADY -> skip (exit 1)" {
  printf 'SIGNIN: COIN_COLLECTED\nSHARE: ALREADY_COMPLETED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "only SIGNIN done -> run (exit 0)" {
  printf 'SIGNIN: COIN_COLLECTED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 0 ]
}

@test "FAILED markers -> run (exit 0)" {
  printf 'SIGNIN: FAILED — x\nSHARE: FAILED — y\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 0 ]
}

# Regression: an agent essay that QUOTES the markers inline (not at line start)
# must NOT poison idempotency. Real on 2026-06-11: a logged-out-path run wrote
# prose containing `SIGNIN: COIN_COLLECTED` while its actual verdict was FAILED;
# the old unanchored grep skipped subsequent runs. Anchored ^ fixes it.
@test "inline prose quoting markers does not trigger skip (must run)" {
  printf 'Latest log shows `SIGNIN: COIN_COLLECTED`, `SHARE: COIN_COLLECTED`.\nSIGNIN: FAILED — not logged in\nSHARE: FAILED — not reached\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 0 ]
}
