#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
  OUT="$BATS_TEST_TMPDIR/out.txt"
}

@test "markers mode: all markers present -> success" {
  printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$OUT"
  run nc_check_success markers 0 "$OUT" "SIGNIN: COIN_COLLECTED" "SHARE: COIN_COLLECTED"
  [ "$status" -eq 0 ]
}

@test "markers mode: a missing marker -> failure" {
  printf 'SIGNIN: COIN_COLLECTED\n' > "$OUT"
  run nc_check_success markers 0 "$OUT" "SIGNIN: COIN_COLLECTED" "SHARE: COIN_COLLECTED"
  [ "$status" -eq 1 ]
}

@test "exitcode mode: rc 0 -> success" {
  : > "$OUT"
  run nc_check_success exitcode 0 "$OUT"
  [ "$status" -eq 0 ]
}

@test "exitcode mode: rc nonzero -> failure" {
  : > "$OUT"
  run nc_check_success exitcode 7 "$OUT"
  [ "$status" -eq 1 ]
}

@test "markers mode: no markers given -> failure (misconfiguration)" {
  : > "$OUT"
  run nc_check_success markers 0 "$OUT"
  [ "$status" -eq 1 ]
}
