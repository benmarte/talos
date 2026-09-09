# Lessons

## 2026-09-07: delegate to cheaper models

- Ben asked that work be delegated to cheaper subagents. The orchestrating session should only plan, decide, and synthesise.
- Rule: spawn Sonnet for implementation and research, Haiku for read-only lookups and docs. Never do bulk file reading in the main session.
- Talos routing lives in `talos.pipeline.json` under `agents.model` (Haiku) and `agents.roles.<role>.model` (Sonnet for developer, pm, qa, reviewer, security). Escalate one role at a time if it fails, never the global default.

## 2026-09-07: Talos over-tests and over-reads by design; make it lean

- Ben's mandate: Talos must be as performant and lean as possible, low token spend, low GitHub API usage. This is a product goal for Talos, not a per-run tweak.
- Measured in this run (per PR): 5-6 local full-suite runs plus 2 CI runs; developer 100k-320k tokens, QA 75k-160k, reviewer 60k-127k, security 50k-85k, PM 40k-90k, docs 26k-108k (mostly to say "no changes"), validator 40k-50k.
- Root causes are in Talos prompts and gates, not in this repo: SKILL.md tells developer and QA to run the full suite; docs re-runs on example-config commits; PM restates specs already in the body; every stage re-reads the full issue thread.
- Rule: when a run feels slow or expensive, measure per-stage cost first, then fix the prompt or gate in Talos (file an issue) rather than patching the orchestration prompt for one run.
- Filed: #195 test-once + CI oracle, #196 no redundant re-runs, #197 targeted tests, #198 quiet output, #199 skip PM when spec present, #200 lean docs, #201 compact handoff, #202 cost accounting. #175 gained a result cache.

## 2026-09-08: "no CI run" on a PR usually means the branch conflicts with main

- GitHub schedules no pull_request workflow when it cannot build the merge ref. Under Talos' CI-oracle QA this looks like "pending or missing" forever (PR #212 cost a 12-minute QA pass and an empty retrigger commit before the conflict was found).
- Rule: when `pr-checks` reports no checks for a fresh head, run `git merge-tree --write-tree origin/main origin/<branch>` first. A conflict is the diagnosis; merge main into the branch (never rebase), then CI appears.
- Running two PRs concurrently that touch CHANGELOG.md, the JSON example note, or the verb tables in pipeline-vcs.sh guarantees this. Prefer pairing PRs with disjoint files, or accept one merge-fix pass per pair. Filed #214 so Talos detects CONFLICTING before dispatching QA.

## Linux caps a single argv element at 128 KB; macOS does not (2026-09-08)

PR #215's new test passed a 200 KB prompt as one argument to `pipeline-agent.sh`. Green locally on macOS, red on both CI runners (`Argument list too long`, exit 126; ubuntu enforces MAX_ARG_STRLEN=131072, and the macOS runner tripped over it as well). Two developer rounds and one QA round were spent before the CI log was read.

- Any test or script feeding large text to a child process must use stdin (`pipeline-agent.sh <role> -`) or a file, never argv.
- When CI is red and the local run is green, read the failing job log first (`gh run view <id> --log-failed | grep -A3 FAIL`) before dispatching a fix; the diagnosis took one command.

## API spend limit kills subagents mid-task (2026-09-08)

Two Sonnet subagents died on HTTP 429 (monthly spend limit) with uncommitted work in worktrees. Before dispatching a long developer task near a budget boundary, prefer smaller commits; when a subagent dies, immediately WIP-commit and push its worktree so `pipeline-worktree.sh sweep` cannot destroy the work, then label the issue `pipeline:blocked` with a resume note.

## Board updates were skipped for a whole run (2026-09-08)

`board.enabled: true` (project 4) yet no `pipeline-status.sh <N> <status>` call was made for #208, #214, #205, #174, #176, #201 until Ben asked why the board was empty. The playbook lists the board call as step 1 after every validator/developer/merge outcome; I dropped it while trimming stages for token cost.

- Board calls are one cheap shell command each and are part of the visible contract. Never trim them.
- Checklist per transition: validator CONFIRMED → "In progress"; PR opened → "In review"; blocked → "Blocked"; merged → "Done".

## Run summary 2026-09-08 (second session): 5 PRs merged, 6 issues closed

Every PR needed at least one fix round; the findings were real, not noise: Linux 128 KB argv cap, unchecked `mktemp -d`, orchestrator-run git in SKILL.md (rule 15), validation missing from the `--dump` path, `2>/dev/null` swallowing a feature's only output, a missing known key, `%s` vs `%r` in a warning. Pattern: features that only manifest on stderr or on a second code path need a test that drives the real consumer (a cache, a CI runner, another OS), not the function in isolation.

- macOS GitHub runners lack PyYAML; anything YAML-fixture-based must simulate its absence locally.
- The `pr-mergeable` verb (#214) caught two CONFLICTING PRs on its first day; the CHANGELOG is the usual conflict file, so merging main via a developer task right after each merge is the cheap default.

## A QA agent overwrote the orchestrator's talos.pipeline.json (2026-09-08)

QA for PR #219 wrote a 77-byte test config (`agents.runner: custom`) over the real `talos.pipeline.json` in the main checkout; the next board call silently skipped with "project_number not configured" and `--dump` showed the test config. Cause: a subagent's `cd <worktree>` does not persist between its shell calls, so a later `cat > talos.pipeline.json` landed in the orchestrator's cwd.

- Run `bash scripts/pipeline-vcs.sh assert-sync` before dispatching reviewer/security (the playbook's sync guard) and after every QA stage; a dirty tree here is always a leak.
- QA/developer prompts: "every sandbox file goes under an absolute `$SANDBOX` path; never write a relative `talos.pipeline.*`; prefix multi-step commands with `cd <abs worktree> &&`".
- Any `pipeline-status` "not configured; skipping" or config value that suddenly reads empty means the config file was replaced, not that config is missing.

## Reviewer left a relative-path verdict file in the orchestrator checkout (2026-09-08)

`rev-233.md` appeared in the main checkout; `assert-sync` caught it before the next merge. Same root cause as the config overwrite: a subagent wrote a relative path after its `cd` had not persisted. Stage prompts now say `/tmp/<file>`; keep it that way, and keep running `assert-sync` before every merge.
