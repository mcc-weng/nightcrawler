#!/bin/bash
# nightcrawler engine library — sourced by runner.sh, install-task.sh, and tests.
# Pure helpers; no side effects at source time beyond setting these vars.

NC_LOG_ROOT="${NC_LOG_ROOT:-$HOME/Library/Logs/nightcrawler}"
NC_TASKS_ROOT="${NC_TASKS_ROOT:-$HOME/.nightcrawler/tasks}"
NC_LOCK_DIR="$NC_LOG_ROOT/.browser.lock"
NC_CAFFEINATE_BIN="${NC_CAFFEINATE_BIN:-caffeinate}"

nc_task_dir() { printf '%s/%s' "$NC_TASKS_ROOT" "$1"; }

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

# Decide success. markers mode: every marker string must appear in the output
# file, and at least one non-empty marker must be checked (zero markers is a
# task misconfiguration, not vacuous success). exitcode mode: rc must be 0.
nc_check_success() {
  local mode="$1" rc="$2" outfile="$3"; shift 3
  case "$mode" in
    exitcode) [[ "$rc" -eq 0 ]] ;;
    markers)
      local m checked=0
      for m in "$@"; do
        [[ -n "$m" ]] || continue
        checked=1
        grep -qF -- "$m" "$outfile" || return 1
      done
      [[ "$checked" -eq 1 ]] ;;
    *) return 1 ;;
  esac
}

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
# CAVEAT: a hook that itself exits 127 is indistinguishable from "not found".
nc_run_hook() {
  local task="$1" hook="$2"; shift 2
  local path; path="$(nc_task_dir "$task")/$hook"
  [[ -x "$path" ]] || return 127
  NC_TASK="$task" \
  NC_TASK_DIR="$(nc_task_dir "$task")" \
  NC_LOG_FILE="$(nc_logfile "$task")" \
  "$path" "$@"
}

# Earliest scheduled time across all installed tasks, as HH:MM.
# (macOS pmset holds only ONE repeating wake, so all tasks share it; tasks at
# later times rely on the retry-on-wake agent to self-heal.)
nc_earliest_wake() {
  local d
  for d in "$NC_TASKS_ROOT"/*/; do
    [[ -f "$d/task.env" ]] || continue
    ( # subshell so sourced vars don't leak; unset first so an omitted
      # SCHEDULE_MINUTE doesn't inherit a value leaked by a prior nc_load_manifest.
      unset SCHEDULE_HOUR SCHEDULE_MINUTE
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
