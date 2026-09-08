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
