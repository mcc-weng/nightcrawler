# nightcrawler

A reliable macOS harness for scheduled, unattended automation chores
(browser tasks and more), driven by per-task hooks. See
`docs/superpowers/specs/2026-06-09-nightcrawler-design.md`.

Run a task once: `engine/runner.sh <task-name>`
Install a task's launchd agents: `engine/install-task.sh <task-name>`
Run tests: `bats tests/`
