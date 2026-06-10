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
