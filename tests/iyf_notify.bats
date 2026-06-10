#!/usr/bin/env bats

setup() {
    # Fixture env — no real URLs so no real network/UI calls.
    cat > "$BATS_TEST_TMPDIR/env" <<'EOF'
SLACK_WEBHOOK_URL=""
HEALTHCHECKS_PING_URL=""
NOTIFY_ON_SELF_HEAL=true
NOTIFY_ON_SUCCESS_UNTIL=""
EOF
    export NC_IYF_ENV="$BATS_TEST_TMPDIR/env"
    export NC_LOG_FILE="$BATS_TEST_TMPDIR/cycle.log"

    # Fake-bin dir: osascript shim records each invocation; curl is a no-op.
    local fakebin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fakebin"

    cat > "$fakebin/osascript" <<'SHIM'
#!/bin/bash
echo "osascript: $*" >> "$BATS_TEST_TMPDIR/calls"
SHIM

    cat > "$fakebin/curl" <<'SHIM'
#!/bin/bash
# URLs are empty; record nothing, exit 0.
exit 0
SHIM

    chmod +x "$fakebin/osascript" "$fakebin/curl"
    export PATH="$fakebin:$PATH"
    export BATS_TEST_TMPDIR  # expose to shims

    NOTIFY="$BATS_TEST_DIRNAME/../tasks/iyf/notify"
}

# Count recorded banner (osascript) invocations.
banners() { grep -c . "$BATS_TEST_TMPDIR/calls" 2>/dev/null || echo 0; }

# ---- test cases ----

@test "SKIPPED + both-done log + not in trial → no banner" {
    printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$NC_LOG_FILE"

    run bash "$NOTIFY" SKIPPED
    [ "$status" -eq 0 ]
    [ "$(banners)" -eq 0 ]
}

@test "DONE + NC_RETRY=true + fresh-both log → one self-heal banner, deduped" {
    printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$NC_LOG_FILE"

    NC_RETRY=true run bash "$NOTIFY" DONE
    [ "$status" -eq 0 ]
    [ "$(banners)" -eq 1 ]
    grep -q "caught it on wake" "$BATS_TEST_TMPDIR/calls"
    grep -q "NOTIFIED: POSITIVE" "$NC_LOG_FILE"

    # Second invocation — dedup: still exactly one banner.
    NC_RETRY=true run bash "$NOTIFY" DONE
    [ "$status" -eq 0 ]
    [ "$(banners)" -eq 1 ]
}

@test "FAILED + NC_RETRY=true + not-done log → one action banner, deduped" {
    printf 'SIGNIN: FAILED\nSHARE: FAILED\n' > "$NC_LOG_FILE"

    NC_RETRY=true run bash "$NOTIFY" FAILED
    [ "$status" -eq 0 ]
    [ "$(banners)" -eq 1 ]
    grep -q "NOT collected" "$BATS_TEST_TMPDIR/calls"
    grep -q "NOTIFIED: ACTION" "$NC_LOG_FILE"

    # Second invocation — dedup: still exactly one banner.
    NC_RETRY=true run bash "$NOTIFY" FAILED
    [ "$status" -eq 0 ]
    [ "$(banners)" -eq 1 ]
}

@test "DONE + NC_RETRY=false (primary) + done log → no self-heal/action banner" {
    printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$NC_LOG_FILE"

    NC_RETRY=false run bash "$NOTIFY" DONE
    [ "$status" -eq 0 ]
    # positive_confirm is a no-op (not in trial); NC_RETRY=false skips the retry block.
    [ "$(banners)" -eq 0 ]
}
