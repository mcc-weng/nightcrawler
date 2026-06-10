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
SCHEDULE_HOUR=$((10#$SCHEDULE_HOUR))
SCHEDULE_MINUTE=$((10#$SCHEDULE_MINUTE))
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
