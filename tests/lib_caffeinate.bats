#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  cat > "$BATS_TEST_TMPDIR/fake-caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate-args: $*"
shift 3
exec "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-caffeinate"
  export NC_CAFFEINATE_BIN="$BATS_TEST_TMPDIR/fake-caffeinate"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "timeout 0 runs the command directly, no caffeinate" {
  run nc_run_with_caffeinate 0 echo ran-direct
  [ "$status" -eq 0 ]
  [ "$output" = "ran-direct" ]
}

@test "positive timeout wraps in caffeinate -is -t <timeout>" {
  run nc_run_with_caffeinate 1800 echo ran-wrapped
  [ "$status" -eq 0 ]
  [[ "$output" == *"caffeinate-args: -is -t 1800"* ]]
  [[ "$output" == *"ran-wrapped"* ]]
}

@test "non-numeric timeout is treated as no caffeinate" {
  run nc_run_with_caffeinate "" echo ran-empty
  [ "$status" -eq 0 ]
  [ "$output" = "ran-empty" ]
}
