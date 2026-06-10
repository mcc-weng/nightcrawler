# Nightcrawler Plan B — Migrate iyf onto the Engine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `iyf-daily-coin` the engine's first real consumer — a `~/.nightcrawler/tasks/iyf/` task that reproduces today's `collect.sh` behavior exactly — then cut launchd over to it.

**Architecture:** A small generic enhancement to the engine's `notify` contract (export `NC_RETRY`, fire `notify` on the skip path), then iyf expressed as engine hooks (`run`/`should_run`/`cycle_id`/`notify`) that port `collect.sh`'s logic **verbatim**. An equivalence check proves the idempotency/cycle decisions match before any cutover. Cutover is the last, explicitly-gated step.

**Tech Stack:** bash, `bats-core`, macOS `launchctl`/`pmset`, the existing `claude --print` iyf flow.

**Source of truth for the port:** `/Users/mikeweng/Projects/iyf-daily-coin/scripts/collect.sh` (the production script, with the notification feature). Port its logic verbatim; do not redesign it.

---

## Critical context (read before starting)

The engine principle holds: the engine stays generic; **all iyf-specific logic lives in iyf's hooks**. Approach (A): the only engine change is enriching the `notify` hook's *context* so a task's own `notify` can be smart — the engine learns nothing about Slack/healthchecks.

`collect.sh` today (the behavior to preserve exactly):
- **Cycle date** keyed to a 09:00 boundary: before 09:00 → `date -v-1d`, else today (`collect.sh:29-33`). Log file `$LOG_DIR/<cycle-date>.log`.
- **Idempotency**: skip when the cycle log shows both quests done — `SIGNIN: (COIN_COLLECTED|ALREADY_COLLECTED)` AND `SHARE: (COIN_COLLECTED|ALREADY_COMPLETED)` (`cycle_done`, `collect.sh:72-76`).
- **`--retry`** defers before 09:00 (`collect.sh:121-124`).
- **Notifications** (best-effort, never abort): Slack webhook + macOS banner (`notify`), healthchecks ping on every done cycle (`hc_ping`), per-cycle dedup via `NOTIFIED:` log lines, trial-week heartbeat (`positive_confirm`/`within_trial`), and the post-run on-wake logic — `fresh_collected_both` → ✅ self-heal FYI; retry-ran-but-still-not-done → 🚨 action alert; ALREADY → silent (`collect.sh:50-108, 296-324`). Config from `iyf-daily-coin/.env.local` (`SLACK_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`, `NOTIFY_ON_SELF_HEAL`, `NOTIFY_ON_SUCCESS_UNTIL`).

Engine ↔ collect.sh mapping for notifications:
| collect.sh moment | engine equivalent |
|---|---|
| skip path (`cycle_done` at start) does `hc_ping` + `positive_confirm` | `should_run` returns skip → runner calls `notify SKIPPED` → iyf `notify` does `hc_ping` + `positive_confirm` |
| post-run `hc_ping` if done; retry self-heal/action alert; `positive_confirm` | runner calls `notify DONE|FAILED` with `NC_RETRY` set → iyf `notify` replicates the post-run block |

This is why the engine must (1) export `NC_RETRY` to hooks and (2) call `notify` on skip. Those are the only engine changes.

**Reliability gate:** the core value is "the coin gets collected every day." Task B3 (equivalence) MUST pass before Task B5 (cutover). Cutover keeps the old agents recoverable.

---

### Task B1: Engine — enrich the `notify` contract (`NC_RETRY` + fire on skip)

**Files:**
- Modify: `engine/runner.sh`
- Test: `tests/runner.bats`

- [ ] **Step 1: Write failing tests** — append to `tests/runner.bats`:

```bash
@test "notify hook receives NC_RETRY=true under --retry" {
  printf '#!/bin/bash\necho "retry=$NC_RETRY status=$1" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo --retry
  [ "$status" -eq 0 ]
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"retry=true status=DONE"* ]]
}

@test "notify hook receives NC_RETRY=false without --retry" {
  printf '#!/bin/bash\necho "retry=$NC_RETRY" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"retry=false"* ]]
}

@test "notify hook is called with SKIPPED when should_run skips" {
  printf '#!/bin/bash\nexit 1\n' > "$NC_TASKS_ROOT/demo/should_run"
  chmod +x "$NC_TASKS_ROOT/demo/should_run"
  printf '#!/bin/bash\necho "status=$1" >> "%s/notify.out"\n' "$NC_LOG_ROOT" \
    > "$NC_TASKS_ROOT/demo/notify"
  chmod +x "$NC_TASKS_ROOT/demo/notify"
  run bash "$RUNNER" demo
  [ "$status" -eq 0 ]
  run cat "$NC_LOG_ROOT/notify.out"
  [[ "$output" == *"status=SKIPPED"* ]]
}
```
(Note: `tests/runner.bats` `setup()` gives `demo` SCHEDULE_HOUR=0, so `--retry` does not defer.)

- [ ] **Step 2: Run to confirm failure** — `bats tests/runner.bats` → the three new tests FAIL (no `NC_RETRY`; no notify on skip).

- [ ] **Step 3: Implement** in `engine/runner.sh`:
  - After the `--retry` arg parse (the `for a in "$@"` loop that sets `RETRY`), add: `export NC_RETRY="$RETRY"`.
  - In the `should_run` skip branch (currently `elif [[ $sr -ne 0 ]]; then nc_log ... "SKIP (should_run exit $sr)"; exit 0`), add a notify call before the `exit 0`:
    ```bash
    elif [[ $sr -ne 0 ]]; then
      nc_log "$TASK" "SKIP (should_run exit $sr)"
      set +e; nc_run_hook "$TASK" notify "SKIPPED"; set -e
      exit 0
    fi
    ```
  - Leave the existing post-run `notify "$status"` call as-is (it now runs with `NC_RETRY` exported).

- [ ] **Step 4: Run to confirm pass** — `bats tests/runner.bats` (all green), then `bats tests/` (whole suite green; was 36, now 39).

- [ ] **Step 5: Update `docs/ENGINE.md`** — in the hooks section, document that `notify` is called with `DONE`/`FAILED`/`SKIPPED` and that `NC_RETRY` (`true`/`false`) is exported to all hooks.

- [ ] **Step 6: Commit**
```bash
git add engine/runner.sh tests/runner.bats docs/ENGINE.md
git commit -m "feat(engine): export NC_RETRY to hooks + fire notify on skip path"
```

---

### Task B2: The iyf task — collection core (no notify yet)

**Files (create under the repo so it's version-controlled, then symlink/install — see below):**
- Create: `tasks/iyf/task.env`, `tasks/iyf/run`, `tasks/iyf/should_run`, `tasks/iyf/cycle_id`, `tasks/iyf/prompt.md`

**Convention:** real task definitions live in the repo at `tasks/<name>/` (version-controlled) and are deployed to `~/.nightcrawler/tasks/<name>/` (a symlink) at install time. This keeps iyf's task under git. (The `examples/` dir stays as reference-only.)

- [ ] **Step 1: `tasks/iyf/prompt.md`** — copy the EXACT prompt string from `collect.sh` (the `PROMPT="..."` heredoc body, `collect.sh` lines ~173-278, from "Your job is to complete TWO daily quests" through the two final `SHARE:` output-format lines). Strip the surrounding `PROMPT="` / `"` and unescape the shell-escaped backticks (`\`` → `` ` `` ) and `\$` → `$` so it's clean markdown. Do NOT change any step content.

- [ ] **Step 2: `tasks/iyf/task.env`**:
```bash
SCHEDULE_HOUR=9
SCHEDULE_MINUTE=0
CAFFEINATE_TIMEOUT=3600
NEEDS_BROWSER_LOCK=true
SUCCESS_MODE=exitcode
RETRY_ENABLED=true
LABEL="iyf daily coin"
```
**Why `exitcode`, not `markers`:** iyf's "done" is `COIN_COLLECTED` **OR** `ALREADY_*` — an OR the engine's AND-of-markers mode can't express. In markers mode a healthy pre-reset ALREADY cycle (agent prints `ALREADY_COLLECTED`/`ALREADY_COMPLETED`) would log `RESULT: FAILED`, which `collect.sh` never did and which would look like breakage. So the `run` hook (Step 5) owns the OR-check and returns its exit code; the engine just records it. The SIGNIN/SHARE marker lines still land in the cycle log (the run hook prints them, the engine tees them), so `should_run` can still grep them next cycle.

- [ ] **Step 3: `tasks/iyf/cycle_id`** (`chmod +x`) — ported verbatim from `collect.sh:29-33`:
```bash
#!/bin/bash
# iyf cycle boundary (verbatim from collect.sh): a run before 09:00 belongs to
# the previous cycle. iyf's daily reset is in (06:01, 09:00) AEST.
if (( 10#$(date +%H) < 9 )); then
  date -v-1d +%Y-%m-%d
else
  date +%Y-%m-%d
fi
```

- [ ] **Step 4: `tasks/iyf/should_run`** (`chmod +x`) — ports `cycle_done` (`collect.sh:72-76`); skip (exit 1) when both quests are already done this cycle. The engine passes `NC_LOG_FILE` (the cycle-keyed log):
```bash
#!/bin/bash
# Idempotency, ported verbatim from collect.sh cycle_done(): skip if this cycle's
# log already shows both quests done (fresh COIN_COLLECTED OR pre-reset ALREADY_*).
LOG="$NC_LOG_FILE"
if [[ -f "$LOG" ]] \
    && grep -qE 'SIGNIN: (COIN_COLLECTED|ALREADY_COLLECTED)' "$LOG" \
    && grep -qE 'SHARE: (COIN_COLLECTED|ALREADY_COMPLETED)' "$LOG"; then
    exit 1   # already done this cycle -> skip
fi
exit 0
```

- [ ] **Step 5: `tasks/iyf/run`** (`chmod +x`) — runs the agent and OWNS the success determination (exit 0 iff both quests done this cycle, COIN or ALREADY). The engine applies caffeinate + the lock; the run hook does NOT. `ENV_FILE` is overridable via `NC_IYF_ENV` so tests can point at a fixture:
```bash
#!/bin/bash
# iyf executor. Success = BOTH quests terminal this cycle (fresh COIN or pre-reset
# ALREADY) — same OR-condition as should_run, so an ALREADY cycle is RESULT: DONE,
# not FAILED. We judge from the agent's printed markers, NOT claude's exit code
# (a crashed agent prints no markers -> grep fails -> nonzero -> RESULT: FAILED).
set -uo pipefail
ENV_FILE="${NC_IYF_ENV:-/Users/mikeweng/Projects/iyf-daily-coin/.env.local}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
# Preflight kept for parity with collect.sh. NOTE: the prompt's login branch is
# vestigial (Brave is already logged in; the slider-captcha login was abandoned).
# The prompt references ${IYF_EMAIL}/${IYF_PASSWORD} literally and never reaches
# them, so we deliberately do NOT interpolate creds into the prompt.
if [[ -z "${IYF_EMAIL:-}" || -z "${IYF_PASSWORD:-}" ]]; then
  echo "ERROR: IYF_EMAIL and IYF_PASSWORD must be set"
  exit 1
fi
out="$(/Users/mikeweng/.local/bin/claude --print --dangerously-skip-permissions \
       -p "$(cat "$NC_TASK_DIR/prompt.md")" 2>&1)"
printf '%s\n' "$out"   # engine tees this to the cycle log (markers must land here)
# Exit status = both quests done this cycle (fresh OR already).
printf '%s\n' "$out" | grep -qE 'SIGNIN: (COIN_COLLECTED|ALREADY_COLLECTED)' \
  && printf '%s\n' "$out" | grep -qE 'SHARE: (COIN_COLLECTED|ALREADY_COMPLETED)'
```

- [ ] **Step 6: Smoke-check the hooks in isolation** (no real run): verify each hook is executable and syntactically valid:
```bash
bash -n tasks/iyf/run tasks/iyf/should_run tasks/iyf/cycle_id
for h in run should_run cycle_id; do [ -x "tasks/iyf/$h" ] && echo "$h ok"; done
```
Expected: syntax OK, all three executable.

- [ ] **Step 7: Commit**
```bash
git add tasks/iyf
git commit -m "feat(iyf): collection-core task hooks (run/should_run/cycle_id/prompt)"
```

---

### Task B3: Equivalence check — prove the decisions match collect.sh

This is the reliability gate. A bats test seeds a cycle log with every relevant marker combination and asserts iyf's `should_run` makes the SAME skip/run decision `collect.sh` documents.

**Files:**
- Test: `tests/iyf_equivalence.bats`

- [ ] **Step 1: Write the test**:
```bash
#!/usr/bin/env bats

# iyf should_run must skip iff BOTH quests are done (COIN_COLLECTED or ALREADY_*),
# matching collect.sh cycle_done(). Exit 1 = skip, exit 0 = run.
setup() {
  SR="$BATS_TEST_DIRNAME/../tasks/iyf/should_run"
  export NC_LOG_FILE="$BATS_TEST_TMPDIR/cycle.log"
  export NC_TASK=iyf NC_TASK_DIR="$BATS_TEST_DIRNAME/../tasks/iyf"
}

run_sr() { run bash "$SR"; }

@test "no log -> run (exit 0)" { run_sr; [ "$status" -eq 0 ]; }

@test "both COIN_COLLECTED -> skip (exit 1)" {
  printf 'SIGNIN: COIN_COLLECTED\nSHARE: COIN_COLLECTED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "both ALREADY -> skip (exit 1)" {
  printf 'SIGNIN: ALREADY_COLLECTED\nSHARE: ALREADY_COMPLETED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "mixed COIN + ALREADY -> skip (exit 1)" {
  printf 'SIGNIN: COIN_COLLECTED\nSHARE: ALREADY_COMPLETED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 1 ]
}

@test "only SIGNIN done -> run (exit 0)" {
  printf 'SIGNIN: COIN_COLLECTED\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 0 ]
}

@test "FAILED markers -> run (exit 0)" {
  printf 'SIGNIN: FAILED — x\nSHARE: FAILED — y\n' > "$NC_LOG_FILE"
  run_sr; [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run** — `bats tests/iyf_equivalence.bats` → all PASS (the should_run from B2 already implements this; if any fail, the port is wrong — fix `tasks/iyf/should_run`, not the test).

- [ ] **Step 3: Manual cycle_id spot-check** (documented, run by hand): confirm the boundary matches collect.sh at representative hours:
```bash
# before 09:00 -> previous day; 09:00+ -> today
TZ=Australia/Melbourne date   # note current hour
tasks/iyf/cycle_id            # eyeball vs the <9 rule
```

- [ ] **Step 4: Commit**
```bash
git add tests/iyf_equivalence.bats
git commit -m "test(iyf): should_run equivalence with collect.sh idempotency"
```

---

### Task B4: The iyf `notify` hook — port collect.sh's notifications

Port `collect.sh`'s notification helpers + flow into a single `tasks/iyf/notify` hook, driven by the engine's `notify <status>` call (`DONE`/`FAILED`/`SKIPPED`) and the exported `NC_RETRY`.

**Files:**
- Create: `tasks/iyf/notify`
- Test: `tests/iyf_notify.bats`

- [ ] **Step 1: Write the notify hook** (`chmod +x`). Port verbatim from `collect.sh` lines 50-108 (helpers) and 296-324 (flow), adapting: read the cycle log from `$NC_LOG_FILE`; use `$NC_RETRY` instead of `$RETRY_MODE`; the entrypoint is the `$1` status. Structure:
```bash
#!/bin/bash
# iyf notifications — ported from collect.sh (best-effort; never fails the run).
# Called by the engine as: notify <DONE|FAILED|SKIPPED>, with NC_RETRY + NC_LOG_FILE set.
set -uo pipefail
STATUS="${1:-}"
LOG="$NC_LOG_FILE"
# Overridable so tests can point at a fixture instead of the real config.
ENV_FILE="${NC_IYF_ENV:-/Users/mikeweng/Projects/iyf-daily-coin/.env.local}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# --- helpers (verbatim from collect.sh, $LOG_FILE -> $LOG) ---
notify() { ... osascript + Slack ...; }              # collect.sh:53-60
hc_ping() { ... }                                    # collect.sh:65-68
cycle_done() { ... grep "$LOG" ... }                 # collect.sh:72-76
fresh_collected_both() { ... grep "$LOG" ... }       # collect.sh:80-84
already_notified() { ... }                           # collect.sh:88
mark_notified() { ... }                              # collect.sh:89
within_trial() { ... }                               # collect.sh:94-99
positive_confirm() { ... }                           # collect.sh:102-108

# --- flow ---
# SKIPPED: the engine skipped via should_run (cycle already done). Mirror
# collect.sh's idempotency-skip path (collect.sh:159-164): hc_ping + positive_confirm.
if [[ "$STATUS" == "SKIPPED" ]]; then
  hc_ping
  positive_confirm
  exit 0
fi

# DONE/FAILED (a real run happened). Mirror collect.sh:296-324:
if cycle_done; then hc_ping; fi
if [[ "${NC_RETRY:-false}" == "true" ]]; then
  if fresh_collected_both; then
    if [[ "${NOTIFY_ON_SELF_HEAL:-true}" == "true" ]] && ! already_notified POSITIVE; then
      notify "✅ iyf coin: 9 AM missed — caught it on wake. Coin is safe."
      mark_notified POSITIVE
    fi
  elif ! cycle_done && ! already_notified ACTION; then
    notify "🚨 iyf coin NOT collected — on-wake retry failed. Collect manually at iyf.tv before the next reset (about 09:00 AEST)."
    mark_notified ACTION
  fi
fi
positive_confirm
```
Use the EXACT helper bodies from collect.sh (only swap `$LOG_FILE`→`$LOG`). Do not redesign the logic.

- [ ] **Step 2: Write `tests/iyf_notify.bats`** — verify the dedup + branch logic without sending real notifications. Hermetic setup: point `NC_IYF_ENV` at a fixture env file in `$BATS_TEST_TMPDIR` (with `SLACK_WEBHOOK_URL=""`, `HEALTHCHECKS_PING_URL=""`, etc.) so the hook never sources the real `.env.local`; set `NC_LOG_FILE` to a temp log; and override `osascript`/`curl` by prepending a fake-bin dir to `PATH` that records calls to a file. Cases:
  - `SKIPPED` with both-done log → no ACTION/POSITIVE banner unless within trial; one `hc_ping` attempt.
  - `DONE` + `NC_RETRY=true` + fresh-both log → exactly one POSITIVE banner; a second invocation (ACTION/POSITIVE already marked) → no duplicate.
  - `FAILED` + `NC_RETRY=true` + not-done log → exactly one ACTION banner; second invocation → none.
  - `NC_RETRY=false` (primary) + done log → no self-heal/action banner.
  (Assert against the recorded-calls file + the `NOTIFIED:` lines appended to `$NC_LOG_FILE`.)

- [ ] **Step 3: Run** — `bats tests/iyf_notify.bats` (all pass), then `bats tests/` (whole suite green).

- [ ] **Step 4: Commit**
```bash
git add tasks/iyf/notify tests/iyf_notify.bats
git commit -m "feat(iyf): notify hook — port collect.sh Slack/healthcheck/heartbeat logic"
```

---

### Task B5: Cutover — install iyf on the engine, retire the old agents

**This task changes the live, working iyf system. It is gated: do NOT run it until B1–B4 are committed and green, and STOP for explicit user confirmation before the irreversible step (Step 4).**

**Files:** none new (operational).

- [ ] **Step 1: Deploy the task dir** — symlink the version-controlled task into place:
```bash
mkdir -p ~/.nightcrawler/tasks
ln -snf /Users/mikeweng/Projects/nightcrawler/tasks/iyf ~/.nightcrawler/tasks/iyf
```

- [ ] **Step 2: Shadow run (no cutover yet)** — run the engine-driven iyf once, manually, and confirm it behaves like collect.sh:
```bash
/Users/mikeweng/Projects/nightcrawler/engine/runner.sh iyf
# inspect ~/Library/Logs/nightcrawler/iyf/<cycle-date>.log:
#   START / SIGNIN: ... / SHARE: ... / RESULT: DONE|FAILED
```
Expected: the same SIGNIN/SHARE outcome the old script would produce this cycle. (Note: the global engine lock at `~/Library/Logs/nightcrawler/.browser.lock` is separate from collect.sh's `~/Library/Logs/iyf-daily-coin/.collect.lock`; while both systems are installed they do NOT mutually exclude — so only run one at a time during the shadow period. This is exactly why Step 4 retires the old agents.)

- [ ] **Step 3: Render + load the engine's iyf agents**:
```bash
/Users/mikeweng/Projects/nightcrawler/engine/install-task.sh iyf
# loads com.nightcrawler.iyf{,-retry}; prints the pmset line (already 08:59 — unchanged).
```

- [ ] **Step 4: 🚦 GATE — retire the old iyf agents (irreversible-ish; CONFIRM WITH USER FIRST).** Only after the shadow run looks right:
```bash
launchctl unload ~/Library/LaunchAgents/com.iyf.daily-coin.plist
launchctl unload ~/Library/LaunchAgents/com.iyf.daily-coin-retry.plist
# keep the plist files on disk (recovery: launchctl load them again)
```
Now only the engine's `com.nightcrawler.iyf` agents drive iyf. The old `collect.sh` + plists remain on disk, unloaded, as a rollback path.

- [ ] **Step 5: Verify the cutover** — confirm only the engine agents are loaded and the wake is intact:
```bash
launchctl list | grep -E 'iyf|nightcrawler'   # expect com.nightcrawler.iyf{,-retry}; NOT com.iyf.daily-coin*
pmset -g sched                                  # 8:59 wake intact
```

- [ ] **Step 6: Watch one real cycle** — the next 09:00 run should land in `~/Library/Logs/nightcrawler/iyf/<date>.log` with `RESULT: DONE` (or a self-heal on the retry). Document the outcome. Rollback if it regresses: `launchctl load` the two old plists, `launchctl unload` the nightcrawler ones.

---

## Self-Review

**Spec coverage (Plan B):**
- Engine notify enrichment (`NC_RETRY` + notify-on-skip), generic → B1 ✓
- iyf collection core as hooks, cycle/idempotency ported verbatim → B2 ✓
- Equivalence check (the reliability gate) before cutover → B3 ✓
- iyf notifications ported (Slack/healthcheck/heartbeat/self-heal/action/dedup) → B4 ✓
- Cutover, gated + reversible, old agents retained → B5 ✓
- Global lock replaces the cross-task hack: iyf no longer needs a defer-to-sibling check; alfred's removal is Plan C ✓ (noted, not in scope here)

**Placeholder scan:** B4 Step 1 intentionally references collect.sh line ranges for the verbatim helper bodies rather than re-transcribing them — this is a deliberate "port verbatim from the tested source," not a placeholder. B4's test bodies are specified by behavior + assertion targets; the implementer writes the fake-bin stubs. Everything else is concrete.

**Consistency:** hook names (`run`/`should_run`/`cycle_id`/`notify`), `NC_RETRY`/`NC_LOG_FILE`/`NC_TASK_DIR`, markers (`SIGNIN/SHARE: COIN_COLLECTED|ALREADY_*`), and the 09:00 boundary all match the engine contract (docs/ENGINE.md) and collect.sh.

**Risk:** B5 is the only step touching production. It is gated, shadow-tested, and reversible (old plists retained). B3 must be green first.

## Notes for Plan C (alfred)
Reuse this shape. alfred's `should_run` reads `pending.json` (state-based, not time-based); its `notify` is Discord; **delete alfred's hard-coded defer-to-iyf check** — the global lock now serializes both. Confirm `PARTIAL`/`RETRY` map to a sensible engine status.
