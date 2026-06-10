# Nightcrawler Engine Interface Contract

This document is the locked interface used by Plans B & C (iyf, alfred migrations).

---

## Manifest

`~/.nightcrawler/tasks/<name>/task.env` (bash-sourced):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `SCHEDULE_HOUR` | integer | **required** | Hour of day for the primary scheduled run |
| `SCHEDULE_MINUTE` | integer | `0` | Minute of hour for the primary scheduled run |
| `CAFFEINATE_TIMEOUT` | integer (seconds) | `0` | `0` = no caffeinate; positive = wrap run in `caffeinate -is -t <N>` |
| `NEEDS_BROWSER_LOCK` | `true`/`false` | `false` | Whether to acquire the global shared browser lock before running |
| `SUCCESS_MODE` | `markers`/`exitcode` | `exitcode` | How to decide success: scan log for marker strings, or check exit code |
| `SUCCESS_MARKERS` | bash array | `()` | Marker strings (all must appear in the log) when `SUCCESS_MODE=markers` |
| `RETRY_ENABLED` | `true`/`false` | `false` | Whether to generate a retry launchd agent |
| `LABEL` | string | task name | Human-readable label logged at run start |

---

## Hooks

Executable scripts in the task directory, invoked with the standard `NC_` environment:

| Variable | Value |
|----------|-------|
| `NC_TASK` | Task name |
| `NC_TASK_DIR` | Absolute path to the task directory |
| `NC_LOG_FILE` | Absolute path to the cycle log file |

### `run` (required)

The executor. Its stdout/stderr is teed to the cycle log and scanned for success markers (in `markers` mode). The engine does not embed any task logic here.

### `should_run` (required)

Idempotency / "go?" decision. Exit 0 = proceed; non-zero = skip. **The engine ships no default `should_run`** — idempotency is 100% task-owned. A missing `should_run` is a hard error (runner exits 1).

### `notify` (optional)

Called with one argument: `DONE`, `FAILED`, or `SKIPPED`. `SKIPPED` is passed when `should_run` exits non-zero and the run is bypassed. Errors in `notify` never fail the overall run.

The environment variable `NC_RETRY` (`true` or `false`) is exported to all hooks for the duration of the run, indicating whether the runner was invoked with `--retry`.

### `cycle_id` (optional)

Echoes an opaque per-cycle string used to name the log file. Default: `date +%F`. This is where a task carries its cycle-boundary logic — for example, a run before 09:00 belonging to the previous day's cycle. The engine never computes cycle boundaries.

---

## Test Override Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NC_LOG_ROOT` | `$HOME/Library/Logs/nightcrawler` | Root for all cycle logs and the browser lock dir |
| `NC_TASKS_ROOT` | `$HOME/.nightcrawler/tasks` | Root for task directories |
| `NC_CAFFEINATE_BIN` | `caffeinate` | Caffeinate binary (shim in tests) |
| `NC_LAUNCHAGENTS_DIR` | `$HOME/Library/LaunchAgents` | Where plists are written/loaded |

---

## Usage

### Run a task

```bash
engine/runner.sh <task>
engine/runner.sh <task> --retry
```

`--retry` defers (no-op logs + exits 0) if the current hour is before `SCHEDULE_HOUR`, so the primary agent leads on the day's first run.

### Install a task's launchd agents

```bash
engine/install-task.sh <task>
engine/install-task.sh <task> --render-only
```

`--render-only` writes the plist files and runs `plutil -lint` but skips `launchctl load` and the `pmset` wake recompute. Use for testing and inspection.

---

## See Also

- `examples/hello/` — minimal, runnable reference task (no lock, no caffeinate, sentinel-file idempotency)
- `examples/integrated/` — iyf-shaped reference task (lock + caffeinate + task-owned `cycle_id` + log-grep `should_run` + multiline markers)
