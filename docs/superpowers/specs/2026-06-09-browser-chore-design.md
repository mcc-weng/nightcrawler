# browser-chore — Design Spec

**Date:** 2026-06-09
**Status:** Draft (pending user review)
**Working name:** `browser-chore` (provisional — easy to rename before publish)

---

## 1. Summary

A reliable, open-source **macOS harness for scheduled, unattended automation chores** — primarily browser tasks driven by the Claude CLI against an already-logged-in browser, but mechanism-agnostic. It extracts the hard-won reliability machinery currently duplicated across two real projects (`iyf-daily-coin` and `alfred`) into one thin, hook-driven engine, and adds a Claude **skill** as the front door for authoring and managing tasks by describing them in plain language.

The one-line pitch: **a reliable macOS automation harness + an LLM authoring assistant that picks the right execution mechanism per task.** Not "an LLM browser agent that runs daily for everything."

---

## 2. Problem & Motivation

The reliability machinery for unattended macOS browser automation is **genuinely hard** — it took ~2 weeks of iteration on `iyf-daily-coin` to get right: waking the Mac from sleep, staying awake during the run, not double-running, knowing whether the work actually succeeded, and self-healing when a run is missed.

That machinery is now **duplicated and drifting**:

- `iyf-daily-coin/scripts/collect.sh` — the original.
- `alfred/scripts/fill_runner.sh` — explicitly "iyf-style" (per its own plan doc). The PID lock, `caffeinate -is -t`, launchd primary+retry, retry-on-wake, and logging are **verbatim copies**.

Worse, the two tasks coordinate through a **hack**: `alfred/scripts/fill_runner.sh:24–32` hard-codes a check for *iyf's* lock path and yields to it, because each task invented its own lock and they share one logged-in browser.

Any improvement to the machinery now has to be hand-applied in N places. This is exactly the drift that extraction kills.

**Second motivation — mechanism diversity.** iyf's chosen mechanism (LLM driving a logged-in browser) is optimized for *iyf* (login + captcha). It is the wrong default for a simple deterministic flow, which a scripted Playwright job does faster, cheaper, and more reliably with no LLM at runtime. The harness must not impose iyf's mechanism on every task.

---

## 3. Goals / Non-Goals

### Goals
- Extract a **thin, reusable engine** for scheduled unattended chores, with all reliability machinery in one place.
- Migrate **both** `iyf-daily-coin` and `alfred`'s fill onto it (consumers #1 and #2), deleting their duplicated harness and the defer-to-sibling hack.
- Make the **execution mechanism per-task** (LLM-in-browser, scripted Playwright, plain shell/API).
- A **skill** front door: describe a task in plain language → it's authored, validated, and scheduled.
- New tasks pass a **shakedown** before they're trusted (no silently-flaky tasks).
- Distribute as a **Claude Code plugin** (engine scripts + skill), open-source-friendly.

### Non-Goals (v1)
- **Cross-platform.** macOS only — `launchd`, `pmset`, `caffeinate` are Mac-specific. Linux/systemd is a later port.
- **Zero-touch setup.** macOS forbids programmatic TCC grants and requires `sudo` for `pmset`; the tool *guides* these, it can't eliminate them.
- **Parallel browser tasks.** A single logged-in browser session means tasks driving it **serialize** (global lock). Not a parallel job runner.
- **A heavyweight config schema / framework.** The engine stays thin and hook-driven; we extract only what iyf + alfred actually need. No speculative hooks until a third task asks (YAGNI).
- **Speculative executors.** Build the executors the two real consumers need; add others on demand.

---

## 4. Core Concept

Four layers, with a hard rule: **the magic (skill/authoring) is never a dependency of the reliable core (engine).**

1. **Engine** (the reusable gold). A thin runtime invoked by launchd. Its entire job:

   > On a schedule (or an external kick), if the task's `should_run` check says go, take the global browser lock, optionally `caffeinate`, run the task's command, detect success from its markers/exit code, log it, fire the notify hook, and self-heal missed runs via retry-on-wake.

2. **Task** (data + hooks on disk). A directory per task: a manifest plus the per-task pieces the engine calls — the executor command, the `should_run` check, success spec, notify target.

3. **Skill** (the front door). Authors tasks (describe → drive the site once → pick mechanism → generate manifest + hooks → install) and manages them conversationally.

4. **Plugin** (the container/distribution). A Claude Code plugin bundling the engine scripts + the skill. Install = add the plugin.

---

## 5. Architecture

### 5.1 The engine is hook-driven, not config-heavy

Everything task-specific is supplied **by the task** as a command or a small hook script the engine calls. The engine embeds none of it. This keeps the engine tiny and tasks self-contained and readable.

Per-task hooks the engine calls:

| Hook | Purpose | iyf | alfred-fill |
|------|---------|-----|-------------|
| **executor** | does the actual work | `claude --print -p @prompt.md` | `claude --print -p @prompt.md` (POSTs SKUs to Woolies Trolley API via the logged-in session) |
| **should_run** | idempotency / "go?" decision (exit 0 = go) | time-based: "not already collected this cycle" | state-based: "approved, not-yet-filled cart in `pending.json`" |
| **success spec** | how to read the result | success-marker grep (`SIGNIN: COIN_COLLECTED` …) | success-marker grep (`FILL: DONE/PARTIAL/RETRY/NOTHING/NOT_LOGGED_IN`) |
| **notify** | where results go | osascript (was an open TODO) | Discord webhook |

`should_run` being pluggable is **load-bearing**: iyf is time-based, alfred is state-based — there is no single built-in rule that serves both.

### 5.2 Global shared lock (replaces alfred's hack)

A **single** lock guards the shared logged-in browser across **all** tasks, so two tasks never drive it at once. This deletes alfred's hard-coded defer-to-iyf check. Tasks whose executor is *isolated* (a headless Playwright job with its own browser) declare `needs_browser_lock = false` and skip it.

Mechanism: the proven PID-tracked `mkdir` lock with dead-owner steal (from `collect.sh`), promoted to a single well-known path.

### 5.3 Trigger model: scheduled + event-kick + retry-on-wake net

Three ways a task can fire, unified:

- **Scheduled** — launchd `StartCalendarInterval` (iyf: pure clock).
- **Event-kicked** — an external event runs the task *now* if the Mac is awake (alfred: Discord cart approval kicks the fill immediately).
- **Catch-up net** — the launchd run + the retry-on-wake interval agent catch any fire that was missed because the Mac was asleep.

The insight: **the schedule is the safety net for event-kicked tasks**, which is exactly what retry-on-wake already is. Both trigger styles share one mechanism.

### 5.4 Scheduling & the single-wake constraint

macOS `pmset repeat wakeorpoweron` holds **one** repeating wake (a second call *replaces* the first — confirmed: `pmset -g sched` only ever shows one repeating event; alfred deliberately does **not** add its own and instead rides iyf's 08:59 wake, scheduling its fill at 09:01 to avoid contention).

Resolution: the tool manages **one** wake at *(earliest scheduled task) − 1 min*. Tasks at other times rely on the retry-on-wake net to self-heal when the Mac is next up. Documented limitation, reuses existing machinery instead of fighting pmset.

### 5.5 caffeinate is per-task

`caffeinate -is -t <timeout>` is only needed for **long-running, shared-browser** executors (iyf: 3600s; alfred: 600s — task's fill is fast). An isolated 2-second Playwright job needs neither caffeinate nor the lock. So both are per-task flags switched on by the executor type. Timeout is a manifest field.

---

## 6. A Task On Disk

```
~/.browser-chore/tasks/<name>/
  task.{toml|env}  # manifest (format TBD — see Open Question 3): schedule, executor,
                   #   caffeinate timeout, needs_browser_lock, success markers,
                   #   notify target, trigger style
  run              # the executor command (or it's named in the manifest)
  should_run       # optional hook script; exit 0 = proceed (default: time-based "ran this cycle?")
  prompt.md        # for claude-brave executors: the validated browser flow
  flow.js          # for playwright executors: the script
  state            # unverified | trusted, shakedown counter
~/Library/Logs/browser-chore/<name>/YYYY-MM-DD.log
~/Library/Logs/browser-chore/.browser.lock/pid     # the global shared-browser lock
```

Generated launchd agents per task (from templates): `com.browser-chore.<name>.plist` (primary) + `com.browser-chore.<name>-retry.plist` (retry). All share the global lock and the engine library.

The manifest is a small, readable, human-editable file. The skill writes it; you can hand-edit it.

---

## 7. Executors

The executor is "the command the engine runs." The skill picks it at authoring time from what it finds driving the site:

- **`claude-brave`** — LLM drives the already-logged-in browser via `claude --print` + browser tools (claude-in-chrome, with Playwright-MCP-over-CDP fallback). For login/captcha/dynamic flows. Needs the global lock + caffeinate. *(iyf and alfred-fill today.)*
- **`playwright`** — a scripted headless/headed Playwright flow with its own browser. For deterministic flows with stable selectors and no auth wall. No lock, no caffeinate, fast, ~free, no LLM at runtime.
- **`shell`** — an arbitrary command / API call. For no-browser chores.

**Success detection** normalizes across executors:
- LLM executors emit `MARKER: STATUS` lines → success spec is a grep over the declared markers.
- Scripted/shell executors → exit code 0 = success.

Authoring chooses the mechanism by what it hits: captcha / login wall / flaky DOM → `claude-brave`; clean stable selectors → `playwright`; no browser needed → `shell`. The user can override.

---

## 8. Authoring Flow (the skill)

You're in a Claude session and describe the task:

> *"every morning at 8, claim my daily login bonus on example.com."*

The skill:

1. **Drives the site once, live** (interactive — you watch and can correct). Identifies the flow and a **real** success marker, applying iyf's hard-won lessons: avoid always-in-DOM / opacity-toggled elements; prefer state that genuinely flips; for shared-session API flows, validate via a status endpoint.
2. **Picks the mechanism** (`claude-brave` / `playwright` / `shell`) from what it encountered. You can override.
3. **Generates the task files** — manifest + `prompt.md` or `flow.js` + `should_run` — from iyf/alfred-derived templates.
4. **Installs** — renders launchd plists from templates, loads them, recomputes the single pmset wake (prints the `sudo` command if it changed).
5. Marks the task **`unverified`**.

### 8.1 Shakedown (what makes a new task trustworthy)

A one-shot live run yields a **draft, not a trustworthy task** — proven by iyf's history: the real reliability came from a week of runs catching traps (the fake success marker, the trusted-click requirement, the reset-time boundary). So:

- A new task runs **`unverified`** for the first N cycles: it executes but **flags results for review** (logs pre/post state; asks you to confirm the marker actually flipped) rather than being silently trusted.
- After you confirm — or N clean cycles — it's promoted to **`trusted`**.

This is the guard against shipping a magical-but-flaky task that fails silently at run time — a direct defense of the core value.

---

## 9. Management (skill, conversational)

- *"show my chores"* → list with state + last result.
- *"run iyf now"* → one-shot `runner.sh iyf`.
- *"why did example.com fail yesterday?"* → reads the log and explains (battery? marker didn't flip? TCC? not logged in?).
- *"pause example.com"* → unloads its launchd agents.

A thin bare-script path exists for headless management; a full separate CLI binary is unnecessary surface for v1.

---

## 10. Onboarding / Setup

`setup` / `doctor` (skill-driven) checks and reports: Claude CLI present, Playwright MCP plugin available, browser present, **TCC perms** (Accessibility / Automation / Screen Recording), **pmset wake** set, launchd agents loaded. For the three things it **cannot** do for you it prints the exact commands / Settings panes and waits:

- Grant TCC permissions (Apple forbids programmatic granting).
- `sudo pmset repeat wakeorpoweron …`.
- Confirm the browser is logged in to the target site.

"Easy setup" realistically means **one command that checks everything and walks you through the 3 things only you can do.**

---

## 11. Distribution

- Primary: a **Claude Code plugin** (engine scripts + skill) — install = add the plugin; the audience already has Claude Code + browser tooling.
- The GitHub repo is the open-source home.
- Optional later: a Homebrew tap / `curl | bash` for the bare engine, for non-Claude-Code users.

Implementation language: **bash** for the engine (dependency-free runtime is essential — launchd invokes it with no shell niceties; reuses what already works), Python where logic warrants (cf. alfred's `cart_logic.py`).

---

## 12. Migration: iyf + alfred as consumers #1 and #2

The extraction is validated by migrating both real tasks onto the engine on day one:

- **iyf** → a `claude-brave` task; `should_run` = its time-based cycle check; markers `SIGNIN/SHARE: …`. Deletes the bespoke machinery in `collect.sh`, keeps the prompt.
- **alfred-fill** → a `claude-brave` task; `should_run` = its state-based `pending.json` check; markers `FILL: …`; notify = Discord. **Deletes the duplicated harness and the defer-to-sibling hack** — coordination now comes free from the global lock.

Designing the engine interface against **both** (not just iyf) is what keeps `should_run`, notify, and the trigger model honestly general.

---

## 13. Staged Build Order

1. **Stage 1 — Engine extraction + migrate iyf and alfred.** The thin hook-driven engine (global lock, caffeinate, schedule + retry, `should_run`, success, notify, launchd/plist generation) with iyf and alfred-fill as its first two consumers. *This is also the "review / best-practice" deliverable the user originally asked for — separating engine from task forces every hidden assumption into the open.* Certain value, low risk.
2. **Stage 2 — CLI / skill management + `setup`/`doctor`.** Onboarding, the manual-steps walkthrough, list/run/logs/pause.
3. **Stage 3 — Author-by-doing + shakedown.** The "describe it" magic, built last on a proven foundation, never a dependency of the reliable core.

Each stage ships value independently. The spec describes the full vision; the build order ships reuse first and treats the magic as the final layer.

---

## 14. Constraints & Limitations (honest)

- **Single browser session → tasks serialize** through the global lock. Not a parallel runner.
- **Single pmset wake** → one guaranteed wake time; other tasks self-heal via retry-on-wake.
- **TCC can't be automated** → manual grant on install.
- **Battery:** `caffeinate -s` is silently ignored on battery → closed-lid-on-battery runs may sleep-cycle; the retry-on-wake layer covers them. (iyf's empirically-validated behavior.)
- **macOS only** in v1.

---

## 15. Open Questions

1. **Name.** `browser-chore` is a placeholder. Candidates: `chore`, `brave-cron`, `nightcrawler`, `autobrowse`, `claude-chore`, `perch`. Decide before publish.
2. **v1 executor breadth.** Both current consumers are `claude-brave`. Do we build `playwright` + `shell` executors in Stage 1, or stub the abstraction and add them when the first non-LLM task appears? (Leaning: build the *abstraction* in Stage 1, implement `playwright` when the first real consumer needs it — YAGNI.)
3. **Manifest format.** `task.toml` vs a bash-native `task.env`. TOML is friendlier to read/share; `.env` is bash-native (no parser dependency). (Leaning: `.env` for the runtime-critical fields to keep the engine dependency-free; revisit if it gets unwieldy.)
4. **Where do consumer repos point?** Do iyf/alfred vendor the engine (git submodule / copy on install) or depend on the installed plugin? Affects how migration deletes their local copies.

---

## 16. Reference: iyf vs alfred-fill (grounding)

| Aspect | iyf-daily-coin | alfred-fill |
|--------|----------------|-------------|
| What | claim daily coins on iyf.tv | fill approved Woolworths cart |
| Executor | `claude --print` + logged-in Brave | `claude --print` + logged-in browser (POSTs SKUs to Trolley API) |
| Why LLM | login + slider captcha | reuse logged-in session auth without storing creds |
| Trigger | scheduled (09:00) | event (Discord approval) + scheduled catch-up (09:01) |
| should_run | time-based: collected this cycle? | state-based: approved + unfilled cart? |
| Lock | own PID lock | own PID lock **+ hard-coded defer to iyf** ← hack |
| caffeinate | `-is -t 3600` | `-is -t 600` |
| Success | `SIGNIN/SHARE: COIN_COLLECTED` markers | `FILL: DONE/PARTIAL/RETRY/…` markers |
| Notify | osascript (open TODO) | Discord webhook |
| Wake | owns the single 08:59 pmset wake | rides iyf's wake (no own pmset) |
| Verdict | engine consumer #1 | engine consumer #2 — proves the seam |
