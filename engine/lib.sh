#!/bin/bash
# nightcrawler engine library — sourced by runner.sh, install-task.sh, and tests.
# Pure helpers; no side effects at source time beyond setting these vars.

NC_LOG_ROOT="${NC_LOG_ROOT:-$HOME/Library/Logs/nightcrawler}"
NC_TASKS_ROOT="${NC_TASKS_ROOT:-$HOME/.nightcrawler/tasks}"
NC_LOCK_DIR="$NC_LOG_ROOT/.browser.lock"
NC_CAFFEINATE_BIN="${NC_CAFFEINATE_BIN:-caffeinate}"

nc_task_dir() { printf '%s/%s' "$NC_TASKS_ROOT" "$1"; }
