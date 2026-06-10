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
