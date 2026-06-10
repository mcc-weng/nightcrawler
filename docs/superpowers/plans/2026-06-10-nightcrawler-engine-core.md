# Nightcrawler Engine Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the thin, generic, hook-driven engine that reliably runs a scheduled unattended chore on macOS — and prove it end-to-end with a bundled example task, with zero real-site dependency.

**Architecture:** A small bash library (`engine/lib.sh`) of focused functions (logging, global browser lock, caffeinate wrap, success detection, manifest load, hook invocation), an orchestrator (`engine/runner.sh`) that launchd invokes per task, and an installer (`engine/install-task.sh`) that renders launchd plists from templates and computes the single pmset wake. Everything task-specific lives in per-task hook scripts the engine *calls* — the engine embeds no task logic, and ships **no default `should_run`** (idempotency is 100% task-owned). This plan is Plan A of three; migrating iyf (Plan B) and alfred (Plan C) come after.

**Tech Stack:** bash (dependency-free runtime), `bats-core` for tests, macOS `launchctl`/`pmset`/`caffeinate`/`plutil`.

---

## File Structure

```
nightcrawler/
  engine/
    lib.sh                      # sourced helpers — one function group per task below
    runner.sh                   # orchestrator: runner.sh <task> [--retry]
    install-task.sh             # render plists + load launchd + compute pmset wake
    templates/
      primary.plist.tmpl        # StartCalendarInterval primary agent
      retry.plist.tmpl          # StartInterval retry agent
  examples/
    hello/                      # bundled reference task (no real site) — proves the engine
      task.env
      run
      should_run
  tests/
    smoke.bats
    lib_log.bats
    lib_lock.bats
    lib_caffeinate.bats
    lib_success.bats
    lib_manifest.bats
    runner.bats
    install.bats
    wake.bats
  docs/superpowers/...          # spec + this plan
  README.md
```

**Engine interface contract (locked here, used by Plans B & C):**

- **Manifest** `~/.nightcrawler/tasks/<name>/task.env` (bash-sourced):
  `SCHEDULE_HOUR`, `SCHEDULE_MINUTE`, `CAFFEINATE_TIMEOUT` (seconds; 0 = none), `NEEDS_BROWSER_LOCK` (true/false), `SUCCESS_MODE` (`markers`|`exitcode`), `SUCCESS_MARKERS` (bash array, markers mode), `RETRY_ENABLED` (true/false), `LABEL`.
- **Hooks** (executable scripts in the task dir), invoked with env `NC_TASK`, `NC_TASK_DIR`, `NC_LOG_FILE`:
  - `run` (required) — the executor; its stdout/stderr is teed to the cycle log and scanned for success.
  - `should_run` (required) — idempotency/"go?" decision; exit 0 = proceed, non-zero = skip. **No engine default.**
  - `notify` (optional) — called with one arg (`DONE`/`FAILED`).
  - `cycle_id` (optional) — echoes an opaque per-cycle string used to name the log file; default `date +%F`. (This is where a task like iyf will carry its cycle-boundary logic verbatim — the engine never computes it.)
- **Env overrides for testing:** `NC_LOG_ROOT` (default `$HOME/Library/Logs/nightcrawler`), `NC_TASKS_ROOT` (default `$HOME/.nightcrawler/tasks`), `NC_CAFFEINATE_BIN` (default `caffeinate`), `NC_LAUNCHAGENTS_DIR` (default `$HOME/Library/LaunchAgents`).

---

### Task 0: Scaffold + test harness

**Files:**
- Create: `engine/lib.sh`
- Create: `tests/smoke.bats`
- Create: `examples/hello/task.env`, `examples/hello/run`, `examples/hello/should_run`
- Create: `README.md`

- [ ] **Step 1: Install bats-core**

Run: `brew install bats-core`
Then verify — Run: `bats --version`
Expected: prints e.g. `Bats 1.11.0` (any version).

- [ ] **Step 2: Write the smoke test**

Create `tests/smoke.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  export NC_TASKS_ROOT="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$NC_LOG_ROOT" "$NC_TASKS_ROOT"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "lib.sh sources and honors NC_LOG_ROOT override" {
  [ "$NC_LOG_ROOT" = "$BATS_TEST_TMPDIR/logs" ]
  [ "$NC_LOCK_DIR" = "$BATS_TEST_TMPDIR/logs/.browser.lock" ]
}
```

- [ ] **Step 3: Run the smoke test to verify it fails**

Run: `bats tests/smoke.bats`
Expected: FAIL — `engine/lib.sh` does not exist yet (source error).

- [ ] **Step 4: Create `engine/lib.sh` with header + path vars only**

Create `engine/lib.sh`:

```bash
#!/bin/bash
# nightcrawler engine library — sourced by runner.sh, install-task.sh, and tests.
# Pure helpers; no side effects at source time beyond setting these vars.

NC_LOG_ROOT="${NC_LOG_ROOT:-$HOME/Library/Logs/nightcrawler}"
NC_TASKS_ROOT="${NC_TASKS_ROOT:-$HOME/.nightcrawler/tasks}"
NC_LOCK_DIR="$NC_LOG_ROOT/.browser.lock"
NC_CAFFEINATE_BIN="${NC_CAFFEINATE_BIN:-caffeinate}"

nc_task_dir() { printf '%s/%s' "$NC_TASKS_ROOT" "$1"; }
```

- [ ] **Step 5: Run the smoke test to verify it passes**

Run: `bats tests/smoke.bats`
Expected: PASS (1 test).

- [ ] **Step 6: Create the bundled example task**

Create `examples/hello/task.env`:

```bash
SCHEDULE_HOUR=9
SCHEDULE_MINUTE=0
CAFFEINATE_TIMEOUT=0
NEEDS_BROWSER_LOCK=false
SUCCESS_MODE=markers
SUCCESS_MARKERS=("HELLO: DONE")
RETRY_ENABLED=true
LABEL="hello example"
```

Create `examples/hello/run` (make executable in step 7):

```bash
#!/bin/bash
# Example executor: no browser, no network — just emits a success marker.
echo "HELLO: DONE (task=$NC_TASK dir=$NC_TASK_DIR)"
```

Create `examples/hello/should_run`:

```bash
#!/bin/bash
# Example idempotency: run only if a sentinel file is absent for today.
# Demonstrates that should_run is 100% task-owned.
sentinel="$NC_TASK_DIR/.done-$(date +%F)"
[[ -e "$sentinel" ]] && exit 1   # already done today -> skip
: > "$sentinel"                  # mark done; real tasks check the log instead
exit 0
```

- [ ] **Step 7: Make hooks executable + write README stub**

Run:
```bash
chmod +x examples/hello/run examples/hello/should_run
```

Create `README.md`:

```markdown
# nightcrawler

A reliable macOS harness for scheduled, unattended automation chores
(browser tasks and more), driven by per-task hooks. See
`docs/superpowers/specs/2026-06-09-nightcrawler-design.md`.

Run a task once: `engine/runner.sh <task-name>`
Install a task's launchd agents: `engine/install-task.sh <task-name>`
Run tests: `bats tests/`
```

- [ ] **Step 8: Commit**

```bash
git add engine/lib.sh tests/smoke.bats examples/hello README.md
git commit -m "feat: scaffold engine lib + bats harness + hello example task"
```

---

### Task 1: Logging (`nc_cycle_id`, `nc_logfile`, `nc_log`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/lib_log.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib_log.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/lib_log.bats`
Expected: FAIL — `nc_cycle_id: command not found`.

- [ ] **Step 3: Implement the functions**

Append to `engine/lib.sh`:

```bash
nc_cycle_id() {
  local task="$1" hook
  hook="$(nc_task_dir "$task")/cycle_id"
  if [[ -x "$hook" ]]; then
    "$hook"
  else
    date +%F
  fi
}

nc_logfile() {
  local task="$1"
  printf '%s/%s/%s.log' "$NC_LOG_ROOT" "$task" "$(nc_cycle_id "$task")"
}

nc_log() {
  local task="$1" msg="$2" file
  file="$(nc_logfile "$task")"
  mkdir -p "$(dirname "$file")"
  printf '%s\t%s\n' "$(date +%FT%T%z)" "$msg" >> "$file"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/lib_log.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add engine/lib.sh tests/lib_log.bats
git commit -m "feat: cycle-id-keyed logging helpers"
```

---

### Task 2: Global browser lock (`nc_lock_acquire`, `nc_lock_release`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/lib_lock.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib_lock.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$NC_LOG_ROOT"
  source "$BATS_TEST_DIRNAME/../engine/lib.sh"
}

@test "acquire succeeds on a free lock and writes our pid" {
  run nc_lock_acquire
  [ "$status" -eq 0 ]
  [ "$(cat "$NC_LOCK_DIR/pid")" = "$$" ]
}

@test "acquire fails when a live owner holds the lock" {
  mkdir -p "$NC_LOCK_DIR"
  echo "$$" > "$NC_LOCK_DIR/pid"   # $$ (the bats process) is alive
  run nc_lock_acquire
  [ "$status" -eq 1 ]
}

@test "acquire steals a lock whose owner pid is dead" {
  mkdir -p "$NC_LOCK_DIR"
  echo "999999" > "$NC_LOCK_DIR/pid"   # almost certainly not a live pid
  run nc_lock_acquire
  [ "$status" -eq 0 ]
  [ "$(cat "$NC_LOCK_DIR/pid")" = "$$" ]
}

@test "release removes the lock dir" {
  nc_lock_acquire
  nc_lock_release
  [ ! -d "$NC_LOCK_DIR" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/lib_lock.bats`
Expected: FAIL — `nc_lock_acquire: command not found`.

- [ ] **Step 3: Implement the functions**

Append to `engine/lib.sh`:

```bash
# Single global lock guarding the shared logged-in browser across ALL tasks.
# PID-tracked; a lock whose owner process is gone is stolen immediately
# (crash-safe, no fixed timeout that could wrongly steal a long run).
nc_lock_acquire() {
  mkdir -p "$NC_LOG_ROOT"
  if mkdir "$NC_LOCK_DIR" 2>/dev/null; then
    echo $$ > "$NC_LOCK_DIR/pid"; return 0
  fi
  local owner
  owner="$(cat "$NC_LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  rm -rf "$NC_LOCK_DIR" 2>/dev/null || true
  mkdir "$NC_LOCK_DIR" 2>/dev/null || return 1
  echo $$ > "$NC_LOCK_DIR/pid"; return 0
}

nc_lock_release() { rm -rf "$NC_LOCK_DIR" 2>/dev/null || true; }
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/lib_lock.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add engine/lib.sh tests/lib_lock.bats
git commit -m "feat: global PID-tracked browser lock with dead-owner steal"
```

---

### Task 3: Caffeinate wrapper (`nc_run_with_caffeinate`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/lib_caffeinate.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib_caffeinate.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export NC_LOG_ROOT="$BATS_TEST_TMPDIR/logs"
  # Shim caffeinate so we can assert how it's invoked without sleeping the Mac.
  cat > "$BATS_TEST_TMPDIR/fake-caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate-args: $*"
# Drop the leading flags/timeout (-is -t N) and exec the real command.
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/lib_caffeinate.bats`
Expected: FAIL — `nc_run_with_caffeinate: command not found`.

- [ ] **Step 3: Implement the function**

Append to `engine/lib.sh`:

```bash
# Wrap a command in `caffeinate -is -t <timeout>` when timeout is a positive
# integer; otherwise run it directly. -i blocks idle sleep, -s blocks system
# sleep (AC only), -t caps the assertion so a hang can't drain the battery.
nc_run_with_caffeinate() {
  local timeout="${1:-0}"; shift
  if [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout > 0 )); then
    "$NC_CAFFEINATE_BIN" -is -t "$timeout" "$@"
  else
    "$@"
  fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/lib_caffeinate.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add engine/lib.sh tests/lib_caffeinate.bats
git commit -m "feat: parameterized caffeinate wrapper"
```

---

### Task 4: Success detection (`nc_check_success`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/lib_success.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib_success.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/lib_success.bats`
Expected: FAIL — `nc_check_success: command not found`.

- [ ] **Step 3: Implement the function**

Append to `engine/lib.sh`:

```bash
# Decide success. markers mode: every marker string must appear in the output
# file. exitcode mode: the executor's exit code must be 0.
nc_check_success() {
  local mode="$1" rc="$2" outfile="$3"; shift 3
  case "$mode" in
    exitcode) [[ "$rc" -eq 0 ]] ;;
    markers)
      local m
      for m in "$@"; do
        [[ -n "$m" ]] || continue
        grep -qF -- "$m" "$outfile" || return 1
      done
      return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/lib_success.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add engine/lib.sh tests/lib_success.bats
git commit -m "feat: success detection (markers + exitcode modes)"
```

---

### Task 5: Manifest load + hook invocation (`nc_load_manifest`, `nc_run_hook`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/lib_manifest.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib_manifest.bats`:

```bash
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
  [ "$SCHEDULE_MINUTE" = "0" ]        # default
  [ "$CAFFEINATE_TIMEOUT" = "0" ]      # default
  [ "$NEEDS_BROWSER_LOCK" = "false" ]  # default
  [ "$LABEL" = "demo" ]                # default = task name
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
  run nc_run_hook demo nonexistent
  [ "$status" -eq 127 ]
}

@test "run_hook propagates the hook's exit code" {
  printf '#!/bin/bash\nexit 3\n' > "$NC_TASKS_ROOT/demo/probe"
  chmod +x "$NC_TASKS_ROOT/demo/probe"
  run nc_run_hook demo probe
  [ "$status" -eq 3 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/lib_manifest.bats`
Expected: FAIL — `nc_load_manifest: command not found`.

- [ ] **Step 3: Implement the functions**

Append to `engine/lib.sh`:

```bash
# Source a task's manifest into the current shell and apply defaults.
# Fails if the manifest is absent or SCHEDULE_HOUR is undeclared.
nc_load_manifest() {
  local task="$1" f
  f="$(nc_task_dir "$task")/task.env"
  [[ -f "$f" ]] || { echo "nc: no manifest for task '$task' ($f)" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$f"
  [[ -n "${SCHEDULE_HOUR:-}" ]] || { echo "nc: task.env missing SCHEDULE_HOUR" >&2; return 1; }
  : "${SCHEDULE_MINUTE:=0}"
  : "${CAFFEINATE_TIMEOUT:=0}"
  : "${NEEDS_BROWSER_LOCK:=false}"
  : "${SUCCESS_MODE:=exitcode}"
  : "${RETRY_ENABLED:=false}"
  : "${LABEL:=$task}"
}

# Invoke a task hook with the standard NC_ environment. Returns 127 if the
# hook does not exist/executable; otherwise the hook's own exit code.
nc_run_hook() {
  local task="$1" hook="$2"; shift 2
  local path; path="$(nc_task_dir "$task")/$hook"
  [[ -x "$path" ]] || return 127
  NC_TASK="$task" \
  NC_TASK_DIR="$(nc_task_dir "$task")" \
  NC_LOG_FILE="$(nc_logfile "$task")" \
  "$path" "$@"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/lib_manifest.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add engine/lib.sh tests/lib_manifest.bats
git commit -m "feat: manifest loading + task hook invocation"
```

---

### Task 6: Orchestrator (`engine/runner.sh`) — run / skip / lock paths

**Files:**
- Create: `engine/runner.sh`
- Test: `tests/runner.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/runner.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/runner.bats`
Expected: FAIL — `engine/runner.sh` does not exist.

- [ ] **Step 3: Implement the orchestrator**

Create `engine/runner.sh`:

```bash
#!/bin/bash
# nightcrawler orchestrator. Invoked by launchd per task:
#   runner.sh <task> [--retry]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/lib.sh
source "$HERE/lib.sh"

TASK="${1:?usage: runner.sh <task> [--retry]}"; shift || true
RETRY=false
for a in "$@"; do [[ "$a" == "--retry" ]] && RETRY=true; done

nc_load_manifest "$TASK"

# --retry defers before the task's scheduled hour so the primary agent leads.
# 10# forces base-10 so a leading-zero hour (09) isn't parsed as octal.
if [[ "$RETRY" == true ]] && (( 10#$(date +%H) < 10#$SCHEDULE_HOUR )); then
  nc_log "$TASK" "RETRY deferred before ${SCHEDULE_HOUR}:00"
  exit 0
fi

# Idempotency is 100% task-owned. The engine ships no default should_run.
set +e
nc_run_hook "$TASK" should_run
sr=$?
set -e
if [[ $sr -eq 127 ]]; then
  nc_log "$TASK" "ERROR: required should_run hook missing"
  exit 1
elif [[ $sr -ne 0 ]]; then
  nc_log "$TASK" "SKIP (should_run exit $sr)"
  exit 0
fi

# One shared browser → take the global lock (when the task needs it).
if [[ "$NEEDS_BROWSER_LOCK" == true ]]; then
  if ! nc_lock_acquire; then
    nc_log "$TASK" "SKIP (browser lock held)"
    exit 0
  fi
  trap 'nc_lock_release' EXIT
fi

LOG_FILE="$(nc_logfile "$TASK")"
mkdir -p "$(dirname "$LOG_FILE")"
OUT="$(mktemp)"
RUN="$(nc_task_dir "$TASK")/run"
if [[ ! -x "$RUN" ]]; then
  nc_log "$TASK" "ERROR: required run hook missing"
  exit 1
fi

nc_log "$TASK" "START ${LABEL}"
export NC_TASK="$TASK" NC_TASK_DIR="$(nc_task_dir "$TASK")" NC_LOG_FILE="$LOG_FILE"
set +e
nc_run_with_caffeinate "$CAFFEINATE_TIMEOUT" "$RUN" 2>&1 | tee -a "$LOG_FILE" "$OUT"
rc=${PIPESTATUS[0]}
set -e

if nc_check_success "$SUCCESS_MODE" "$rc" "$OUT" "${SUCCESS_MARKERS[@]:-}"; then
  status=DONE
else
  status=FAILED
fi
nc_log "$TASK" "RESULT: $status"
rm -f "$OUT"

# Optional notify hook (never fails the run).
set +e
nc_run_hook "$TASK" notify "$status"
set -e

exit 0
```

- [ ] **Step 4: Make it executable + run the tests**

Run:
```bash
chmod +x engine/runner.sh
bats tests/runner.bats
```
Expected: PASS (5 tests).

- [ ] **Step 5: End-to-end check with the bundled example task**

Run:
```bash
rm -rf /tmp/nc-e2e && NC_TASKS_ROOT="$PWD/examples" NC_LOG_ROOT=/tmp/nc-e2e bash engine/runner.sh hello
cat /tmp/nc-e2e/hello/$(date +%F).log
```
Expected: log contains `START hello example`, `HELLO: DONE`, and `RESULT: DONE`.
Run it a second time:
```bash
NC_TASKS_ROOT="$PWD/examples" NC_LOG_ROOT=/tmp/nc-e2e bash engine/runner.sh hello
cat /tmp/nc-e2e/hello/$(date +%F).log
```
Expected: a `SKIP (should_run exit 1)` line (the example's sentinel makes it idempotent). Then clean up the example's sentinel: `rm -f examples/hello/.done-$(date +%F)`.

- [ ] **Step 6: Commit**

```bash
git add engine/runner.sh tests/runner.bats
git commit -m "feat: runner orchestrator (run/skip/lock/notify, task-owned should_run)"
```

---

### Task 7: Plist templates + installer (`engine/install-task.sh`)

**Files:**
- Create: `engine/templates/primary.plist.tmpl`
- Create: `engine/templates/retry.plist.tmpl`
- Create: `engine/install-task.sh`
- Test: `tests/install.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/install.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — `engine/install-task.sh` does not exist.

- [ ] **Step 3: Create the templates**

Create `engine/templates/primary.plist.tmpl`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nightcrawler.__TASK__</string>
    <key>ProgramArguments</key>
    <array>
        <string>__RUNNER__</string>
        <string>__TASK__</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>__HOUR__</integer>
        <key>Minute</key>
        <integer>__MIN__</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>__LAUNCHD_LOG__</string>
    <key>StandardErrorPath</key>
    <string>__LAUNCHD_LOG__</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

Create `engine/templates/retry.plist.tmpl`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nightcrawler.__TASK__-retry</string>
    <key>ProgramArguments</key>
    <array>
        <string>__RUNNER__</string>
        <string>__TASK__</string>
        <string>--retry</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>StandardOutPath</key>
    <string>__LAUNCHD_LOG__</string>
    <key>StandardErrorPath</key>
    <string>__LAUNCHD_LOG__</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

- [ ] **Step 4: Implement the installer**

Create `engine/install-task.sh`:

```bash
#!/bin/bash
# Render + install a task's launchd agents.
#   install-task.sh <task> [--render-only]
# --render-only writes the plists (for tests / inspection) and skips
# launchctl load + the pmset wake recompute.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/lib.sh
source "$HERE/lib.sh"

TASK="${1:?usage: install-task.sh <task> [--render-only]}"; shift || true
RENDER_ONLY=false
for a in "$@"; do [[ "$a" == "--render-only" ]] && RENDER_ONLY=true; done

NC_LAUNCHAGENTS_DIR="${NC_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
RUNNER="$HERE/runner.sh"
LAUNCHD_LOG="$NC_LOG_ROOT/$TASK/launchd.log"

nc_load_manifest "$TASK"
mkdir -p "$NC_LAUNCHAGENTS_DIR" "$NC_LOG_ROOT/$TASK"

render() {
  sed -e "s|__TASK__|$TASK|g" \
      -e "s|__RUNNER__|$RUNNER|g" \
      -e "s|__HOUR__|$SCHEDULE_HOUR|g" \
      -e "s|__MIN__|$SCHEDULE_MINUTE|g" \
      -e "s|__LAUNCHD_LOG__|$LAUNCHD_LOG|g" \
      "$1"
}

primary="$NC_LAUNCHAGENTS_DIR/com.nightcrawler.$TASK.plist"
render "$HERE/templates/primary.plist.tmpl" > "$primary"
plutil -lint "$primary" >/dev/null

retry=""
if [[ "$RETRY_ENABLED" == true ]]; then
  retry="$NC_LAUNCHAGENTS_DIR/com.nightcrawler.$TASK-retry.plist"
  render "$HERE/templates/retry.plist.tmpl" > "$retry"
  plutil -lint "$retry" >/dev/null
fi

if [[ "$RENDER_ONLY" == true ]]; then
  echo "rendered: $primary${retry:+ and $retry}"
  exit 0
fi

launchctl unload "$primary" 2>/dev/null || true
launchctl load "$primary"
if [[ -n "$retry" ]]; then
  launchctl unload "$retry" 2>/dev/null || true
  launchctl load "$retry"
fi
echo "installed launchd agents for '$TASK'."
echo "NOTE: update the wake schedule (requires sudo):"
echo "  sudo pmset repeat wakeorpoweron MTWRFSU $(nc_wake_target "$(nc_earliest_wake)")"
```

(Note: `nc_wake_target` and `nc_earliest_wake` are added in Task 8; the `--render-only` path tested here does not call them.)

- [ ] **Step 5: Make executable + run the tests**

Run:
```bash
chmod +x engine/install-task.sh
bats tests/install.bats
```
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add engine/templates engine/install-task.sh tests/install.bats
git commit -m "feat: launchd plist templates + task installer (render/load)"
```

---

### Task 8: Single pmset wake computation (`nc_earliest_wake`, `nc_wake_target`)

**Files:**
- Modify: `engine/lib.sh`
- Test: `tests/wake.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/wake.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/wake.bats`
Expected: FAIL — `nc_earliest_wake: command not found`.

- [ ] **Step 3: Implement the functions**

Append to `engine/lib.sh`:

```bash
# Earliest scheduled time across all installed tasks, as HH:MM.
# (macOS pmset holds only ONE repeating wake, so all tasks share it; tasks at
# later times rely on the retry-on-wake agent to self-heal.)
nc_earliest_wake() {
  local d
  for d in "$NC_TASKS_ROOT"/*/; do
    [[ -f "$d/task.env" ]] || continue
    ( # subshell so sourced vars don't leak
      # shellcheck disable=SC1091
      source "$d/task.env"
      printf '%02d:%02d\n' "$((10#${SCHEDULE_HOUR:-99}))" "$((10#${SCHEDULE_MINUTE:-0}))"
    )
  done | sort | head -1
}

# Given HH:MM, return the wake target one minute earlier as HH:MM:00,
# wrapping across midnight.
nc_wake_target() {
  local h="${1%%:*}" m="${1##*:}" total
  total=$(( 10#$h * 60 + 10#$m - 1 ))
  (( total < 0 )) && total=$(( total + 1440 ))
  printf '%02d:%02d:00\n' $(( total / 60 )) $(( total % 60 ))
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/wake.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Full suite green**

Run: `bats tests/`
Expected: PASS — all suites (smoke, log, lock, caffeinate, success, manifest, runner, install, wake).

- [ ] **Step 6: Commit**

```bash
git add engine/lib.sh tests/wake.bats
git commit -m "feat: single-wake computation for the shared pmset schedule"
```

---

### Task 9: Integrated end-to-end — the path real tasks actually use

The `hello` example deliberately exercises the *easy* path (no lock, no caffeinate, no cycle_id, single-line marker). This task adds a second bundled example shaped like a real task and an integration test that drives the **whole** integrated path at once: global lock acquire/release + caffeinate wrapping + a task-owned `cycle_id` boundary + log-grep `should_run` idempotency + multiline marker detection. Without this, "suite green" would not imply "the engine can run iyf."

**Files:**
- Create: `examples/integrated/task.env`, `examples/integrated/run`, `examples/integrated/should_run`, `examples/integrated/cycle_id`
- Test: `tests/integration.bats`

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/integration.bats`
Expected: FAIL — the `examples/integrated` task does not exist yet.

- [ ] **Step 3: Create the iyf-shaped example task**

Create `examples/integrated/task.env`:

```bash
SCHEDULE_HOUR=9
SCHEDULE_MINUTE=0
CAFFEINATE_TIMEOUT=30
NEEDS_BROWSER_LOCK=true
SUCCESS_MODE=markers
SUCCESS_MARKERS=("A: OK" "B: OK")
RETRY_ENABLED=true
LABEL="integrated example"
```

Create `examples/integrated/run`:

```bash
#!/bin/bash
# Emits a multiline, multi-marker result (no real site).
echo "A: OK"
echo "B: OK"
```

Create `examples/integrated/should_run`:

```bash
#!/bin/bash
# Real-pattern idempotency: skip if THIS cycle's log already shows both
# success markers. The engine passes the cycle-keyed log path as NC_LOG_FILE.
[[ -f "$NC_LOG_FILE" ]] || exit 0
grep -qF "A: OK" "$NC_LOG_FILE" && grep -qF "B: OK" "$NC_LOG_FILE" && exit 1
exit 0
```

Create `examples/integrated/cycle_id`:

```bash
#!/bin/bash
# Demonstrates a task-owned cycle boundary (the engine never computes this):
# a run before 09:00 belongs to the previous day's cycle. iyf will carry its
# real boundary logic here, verbatim from collect.sh, in Plan B.
if (( 10#$(date +%H) < 9 )); then
  date -v-1d +%F
else
  date +%F
fi
```

- [ ] **Step 4: Make hooks executable + run the test**

Run:
```bash
chmod +x examples/integrated/run examples/integrated/should_run examples/integrated/cycle_id
bats tests/integration.bats
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add examples/integrated tests/integration.bats
git commit -m "test: integrated e2e — lock+caffeinate+cycle_id+log-grep should_run+multiline markers"
```

---

### Task 10: Engine docs + full-suite gate

**Files:**
- Modify: `README.md`
- Create: `docs/ENGINE.md`

- [ ] **Step 1: Write the engine reference doc**

Create `docs/ENGINE.md` documenting the locked interface (copy the "Engine interface contract" block from this plan's File Structure section verbatim: manifest fields, the four hooks and their env, the test override vars, and the `runner.sh <task> [--retry]` / `install-task.sh <task> [--render-only]` usage).

- [ ] **Step 2: Point README at it**

Append to `README.md`:

```markdown

## Authoring a task
A task is a directory under `~/.nightcrawler/tasks/<name>/` with a `task.env`
manifest and hook scripts (`run`, `should_run`, optional `notify`/`cycle_id`).
See `docs/ENGINE.md` for the full contract and `examples/hello/` for a minimal,
runnable reference. Migrations of the first real consumers (iyf, alfred) follow
in separate plans.
```

- [ ] **Step 3: Verify the whole suite + example one more time**

Run:
```bash
bats tests/
rm -rf /tmp/nc-e2e && NC_TASKS_ROOT="$PWD/examples" NC_LOG_ROOT=/tmp/nc-e2e bash engine/runner.sh hello && grep -q "RESULT: DONE" /tmp/nc-e2e/hello/$(date +%F).log && echo E2E-OK
rm -f examples/hello/.done-$(date +%F)
```
Expected: all tests PASS and `E2E-OK` printed.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ENGINE.md
git commit -m "docs: engine interface reference + authoring quickstart"
```

---

## Self-Review

**1. Spec coverage (Plan A's slice):**
- Thin hook-driven engine, embeds no task logic → Tasks 1–6 ✓
- No engine default `should_run` (task-owned idempotency) → Task 6 (hard error if missing; skip on non-zero) ✓
- Global shared browser lock → Task 2 + Task 6 ✓
- Per-task caffeinate, only when needed → Task 3 + Task 6 ✓
- Success detection (markers + exitcode) → Task 4 ✓
- `cycle_id` hook so cycle logic stays in the task → Task 1 ✓
- launchd primary + retry generation; `--retry` defers before scheduled hour → Tasks 6, 7 ✓
- Single pmset wake = earliest task − 1 min → Task 8 + installer note ✓
- Notify hook → Task 6 ✓
- Proven end-to-end without a real site → `examples/hello` (Tasks 0, 6) ✓
- **Integrated path exercised as a whole** (lock + caffeinate + task-owned `cycle_id` + log-grep `should_run` + multiline markers) → `examples/integrated` + `tests/integration.bats` (Task 9) ✓ — so "suite green" means "the engine can run an iyf-shaped task," not just a toy.
- **Deferred to Plans B/C (out of scope here, by design):** migrating iyf and alfred, the equivalence-check/cutover, removing alfred's defer-to-iyf hack, executors beyond the generic `run` hook (`playwright`/`shell`), the skill/CLI front door, `setup`/`doctor`. These are named so the reader knows they're intentional, not gaps.

**2. Placeholder scan:** No TBD/TODO; every code/test step shows complete content; the one forward-reference (installer mentions `nc_wake_target`/`nc_earliest_wake`) is called out and the tested path doesn't exercise it.

**3. Type/name consistency:** Function names (`nc_log`, `nc_cycle_id`, `nc_logfile`, `nc_lock_acquire`, `nc_lock_release`, `nc_run_with_caffeinate`, `nc_check_success`, `nc_load_manifest`, `nc_run_hook`, `nc_task_dir`, `nc_earliest_wake`, `nc_wake_target`), manifest keys, hook names (`run`/`should_run`/`notify`/`cycle_id`), and env vars (`NC_LOG_ROOT`/`NC_TASKS_ROOT`/`NC_CAFFEINATE_BIN`/`NC_LAUNCHAGENTS_DIR`/`NC_TASK`/`NC_TASK_DIR`/`NC_LOG_FILE`) are consistent across all tasks and match the locked contract.

**4. Known macOS test caveats:** `sed -i ''` (Task 6 lock test) and `plutil` are BSD/macOS variants — correct for the target platform. `bats` must be installed (Task 0).

---

## Notes for Plans B & C (carry forward)

- **Plan B (iyf):** the iyf `cycle_id` and `should_run` hooks must be ported **verbatim** from `collect.sh` — the `< 9` hour gate, the `date -v-1d` previous-cycle mapping, and the COIN_COLLECTED-**or**-ALREADY skip rule (the engine has no cycle logic to lean on). Plan B is the acceptance gate for Stage 1: it **must** include the equivalence check (seed cycle logs across the COIN/ALREADY/empty/mixed combinations and assert the new `should_run` decision matches `collect.sh`'s documented behavior), plus a shadow period running the new agents alongside the old before disabling the old ones. "Engine suite green" is a waypoint, not the stopping point.
- **Plan C (alfred):** alfred's executor emits a multi-state result (`FILL: DONE/PARTIAL/RETRY/NOTHING/NOT_LOGGED_IN`), but the engine collapses success to binary DONE/FAILED. Verify (don't assume) that mapping `PARTIAL`/`RETRY` → `FAILED` produces the retry behavior alfred wants — it likely does because alfred's `should_run` reads `pending.json` state rather than the binary result, but confirm against alfred's intended semantics. Also confirm the global lock (first-come, no priority) is acceptable in place of the deleted defer-to-iyf hack: neither task may depend on winning the race.
