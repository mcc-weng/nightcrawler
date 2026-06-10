# nightcrawler

A reliable macOS harness for scheduled, unattended automation chores
(browser tasks and more), driven by per-task hooks. See
`docs/superpowers/specs/2026-06-09-nightcrawler-design.md`.

Run a task once: `engine/runner.sh <task-name>`
Install a task's launchd agents: `engine/install-task.sh <task-name>`
Run tests: `bats tests/`

## Authoring a task
A task is a directory under `~/.nightcrawler/tasks/<name>/` with a `task.env`
manifest and hook scripts (`run`, `should_run`, optional `notify`/`cycle_id`).
See `docs/ENGINE.md` for the full contract and `examples/hello/` for a minimal,
runnable reference. Migrations of the first real consumers (iyf, alfred) follow
in separate plans.
