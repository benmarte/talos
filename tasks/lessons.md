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
