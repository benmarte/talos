# Lessons

## 2026-09-07: delegate to cheaper models

- Ben asked that work be delegated to cheaper subagents. The orchestrating session should only plan, decide, and synthesise.
- Rule: spawn Sonnet for implementation and research, Haiku for read-only lookups and docs. Never do bulk file reading in the main session.
- Talos routing lives in `talos.pipeline.json` under `agents.model` (Sonnet) and `agents.roles.<role>.model` (as of 2026-10-02: Sonnet for validator, pm, developer, qa, reviewer, docs; Opus for planner, security, adversarial). Escalate one role at a time if it fails, never the global default.

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

## Roadmap run complete 2026-09-08: 15 issues, 24 PRs, one unfollowed rule

All 15 remaining roadmap issues merged in conflict-avoiding waves of two. Every PR needed one to three real fix rounds; the reviewer and security stages earned their cost (dot-sourced env file, unanchored stale sweep, watchdog orphan, argv token, missing known key, hard-coded role list, etc.).

- The orchestrator session ran on the pre-#182 playbook and never called `pipeline-hooks.sh post_stage` after relays, so `.talos/events.jsonl` has only the two entries QA generated. Next run: follow Rule 3 (post_stage with `--tokens/--tool-uses/--duration-s` from each completion notification) so `pipeline-events.sh cost` is real.
- `assert-sync` before every merge and after every QA stage caught two stray files; keep it.
- Owner steps still open: sandbox repo + `TALOS_CANARY_REPO`/`TALOS_CANARY_TOKEN` for the canary; decide on a release.

## Worktree lifecycle policy (Ben, 2026-09-09)

"They should always be cleaned once a PR is merged or created." Policy filed as #240: a stage's working copy lives only as long as its PR is open; post-merge removes every worktree and scratch branch for that issue (developer AND harness `agent-*` ones); Step 1 and Step 5 sweeps remove anything not tied to an open issue/PR, dirty or not, because dirty scratch is never work in progress (real work is on a pushed PR branch). Until #240 lands, run the manual cleanup at the end of each run: remove all non-main worktrees, delete all non-main local branches, `git worktree prune`.

## 2026-09-09: backlog at zero

#221, #237, #240 merged via Talos. Every open issue and PR is closed. The new `pipeline-worktree.sh remove <N>` cleaned each stage's worktree and branch on merge without manual work, and `sweep`/`status` report zero leftovers. Next run must: follow Rule 3 (post_stage with usage) so the cost log fills; use `tag <N>` in QA/docs prompts (now in the profiles).

## 2026-09-09: first live canary run found two real bugs; Agent model must be an alias

Set up `benmarte/talos-canary` + `TALOS_CANARY_REPO` + fine-grained `TALOS_CANARY_TOKEN` (minted through the GitHub UI via the browser tools; there is no API for PATs). First run: `github` provider passes end to end; `github-api` fails at `check-approval-sha` because the live REST API pretty-prints JSON and the arm splits PR/comments payloads on `\n` (#244). Fresh sandbox also has no Talos labels, so `post-approval` failed until `bootstrap-labels.sh` ran against it (#245). Both are exactly what the canary exists to catch: the `curl` stub returns compact JSON, so no stubbed test could see either.

- In this harness the Agent tool's `model:` takes only the aliases `haiku|sonnet|opus|fable`; a full ID like `claude-haiku-4-5-20251001` from `talos.pipeline.json` is rejected. Map `agents.roles.<role>.model` to its alias before spawning.
- When a Talos-found bug is small, still file it and run it through Talos; do not hand-patch `pipeline-vcs.sh` from the orchestrator session.

## 2026-09-09 (later): canary green; five live-API bugs fixed via Talos in one afternoon

Canary run 34376183708 is fully green on both providers. Bugs it (and the board) surfaced, all merged through the full pipeline: #244 pretty-printed JSON split, #245 sandbox labels, #248 `items(first:200)` cap + fail-loud, #250 label description > 100 chars, #252 board sentinel keyed by project number only + gh path printing success on failure.

- GitHub facts now encoded in tests: ProjectV2 connections cap `first` at 100; label descriptions max 100 chars, names 50; REST bodies are pretty-printed. The `curl`/`gh` stubs used to hide all three.
- The real `~/.cache/talos` sentinel was poisoned by the test suite: `make_sandbox` sandboxed HOME but not `XDG_RUNTIME_DIR`. Any script that caches under `$XDG_RUNTIME_DIR` must be tested with that variable overridden. Fixed in #252.
- A project's built-in "closed → Done" automation can mask a broken board integration for weeks. Check a non-terminal status ("In review") when verifying the board, never "Done".
- CHANGELOG conflicts hit every second PR when two are in flight; each cost a merge-base developer dispatch (~50k tokens). Consider a changelog-fragments directory (`changelog.d/`) as a lean-mandate follow-up.
- Two review rounds on #249 both came from the same class: an unbounded loop / unvalidated operator input. Add "every loop has a cap; every env override is validated" to the developer profile's self-check.
- Rule 3 followed this run: `post_stage` fired with `--tokens/--tool-uses/--duration-s` after every stage, so `pipeline-events.sh cost` is populated for the first time.

## 2026-09-09: efficiency audit of the day's run (Ben asked whether we were prudent)

Measured from `.talos/events.jsonl` and `gh run list`: ~1.46M recorded subagent tokens for 7 issues, plus reviewer/security usage that went unrecorded because they were spawned as mailbox teammates (no usage in the notification). Leaks, largest first:
1. CHANGELOG merge-base dispatches (5 today, ~280k tokens, 5 extra CI runs). Fragments directory is the fix.
2. Re-stamp cascades: #248 needed QA three times (~170k) because each reviewer round moved the head. A cheaper "delta re-stamp" QA (Haiku, targeted tests only) would cut that by ~70%.
3. My QA prompts asked for the FULL suite via pipeline-verify even though #195 says QA trusts CI and runs targeted tests only. Orchestrator error — QA prompts must say `run-tests.sh --for <changed files>`, never the whole suite.
4. CI: 22 push runs on main today (4 were lessons.md-only commits) × 2 OS × ~5 min. No `paths-ignore`, no per-branch `concurrency: cancel-in-progress` (#249's 4 pushes all ran to completion), macOS on every PR push.
5. Reviewer/security spawned without usage capture → cost log undercounts by roughly a third.

## 2026-09-10: efficiency batch merged (#256-#260); first measured effects

All five efficiency issues merged through the full pipeline. Effects observed inside the same batch:
- Mechanical CHANGELOG merge (#256) ran live three times (on its own PR, #264, and via the developer for #265): 0 LLM tokens each vs ~57k per developer merge-base yesterday.
- Haiku delta re-stamps (formalised as #258) cost 24k-48k vs 49k-71k full re-runs; QA on #263 with `--for --strict` was 49k vs 60-70k full-suite runs.
- CI: `test (ubuntu-latest)` only on PRs; main pushes keep the matrix. `merge.required_checks` had to drop macOS or the gate hangs — the issue predicted it and the PR still hit it; the doc caveat alone was not enough, so the test now enforces required_checks ⊆ PR jobs.
- Reviewer/security caught one real gap per PR again (missing `permissions:` block, shared concurrency group on main, no forbidden-files cross-check on union paths, unlocked worktree ops, `--for` fail-open fallback, unscoped spawn rule, stale label surviving RESTAMP_FAIL). The pattern holds: every "simple" change had one thing a second reader had to find. Do not skip review stages to save tokens.
- Cost: 4.24M tokens across the whole `.talos/events.jsonl` (both days); reviewer/security now report usage (#259), so the log is complete from here on.
- Orchestrator discipline: no pushes to main mid-run this batch (Rule 19 now in the playbook).

## 2026-09-11: v0.15.0 released via Talos

Release flow that worked: one release issue (#268) combining the fresh docs audit's gaps, version bump, CHANGELOG rename and README upgrade notes; run through the full pipeline; orchestrator creates the annotated tag and GitHub release after main CI passes on the merge commit. Two review rounds were needed and both were real: the JSON example carried new keys only as prose in a `_note` (the guard test used a substring match), and one upgrade note misdescribed the cost report's `tokens` field as null. For future releases: example-config coverage must be a structural check (JSON tree walk / anchored YAML line), and every upgrade note must be verified against the script before it ships. `gh release view` has no `isLatest` field; use `gh release list`.

## 2026-09-12: "graph engineering" field-guide batch (#270-#272) dogfooded

Three ideas taken from an agent-fleet guide (done-in-one-line per stage, per-role effort knob, cite-the-line-that-blocked-you); the rest Talos already did. Run: 3 issues, 3 PRs merged, 2 fix rounds, ~960k recorded tokens.
- Global install was stale: `~/.talos/scripts` (Aug 27) and `~/.claude/skills/pipeline` (Sep 8) both older than the repo. The playbook says global wins, but inside the Talos source repo the repo copy is the truth. Re-run `install.sh` after a release, or the next orchestration follows an old playbook.
- Both fix rounds were real and both were design, not typos: #271 first applied effort by rewriting `.claude/agents/<role>.md` at spawn time (dirties the tree, trips `assert-sync`); #272 showed `BLOCKED_BY` as an inline shell literal (reporter-controlled text into `bash -c`). A second reader found each. The developer profile should say: never mutate tracked files at dispatch time; anything copied from an issue or file goes through a quoted heredoc.
- The Haiku docs stage fabricated a CHANGELOG claim (`pipeline-vcs.sh blocked --explicit-file-and-line`, a flag that never existed). Reviewer caught it. Docs prompts must say: describe only what the diff contains; never name a script, flag, or count you did not see in `pr-files`/the diff.
- Named (mailbox) spawns still report no usage: reviewer/security/validator rows show tokens 0 and `unrecorded` 7-12 per issue. Only `isolation: "worktree"` / background spawns carry usage. Playbook #259 says use the background form for every stage; I used named teammates for read-only roles. Next run: background form for all, so the cost table is complete.
- Orchestrator `assert-sync` fails after any merge in the run (checkout is behind main). `git pull --ff-only` on main between issues is the guard's own remedy and touches no in-flight worktree; do it right after each post-merge step rather than waiting for the guard to abort.
- PM skip (#199) fired on all three issues because each body carried `## Acceptance criteria` with checkboxes. Writing issues that way is the cheapest lean win available.
- Follow-up 2026-09-13: `install.sh --global` itself was the reason the global copy drifted — a hardcoded script list had missed `pipeline-isolation.sh`, `pipeline-mergebase.sh` and `templates/ci`. Fixed in #276 with globs plus a structural `diff -rq` test. With every stage spawned in the background form, `pipeline-events.sh cost` for #276 recorded tokens for all six roles (only orchestrator rows null, as expected): 310k for one small bug through the full pipeline.

## 2026-09-15: "get talos working on the open issues" means the Talos repo, not a consumer repo

- Ben asked, from a home-directory session, to "get talos working on the 2 issues that are currently open". I went looking for a Talos *config*, found `~/.talos/terrasow.pipeline.yml`, cd'd into terrasow and spent the session there. He meant Talos dogfooding its own GitHub issues in `~/Documents/github/ai/talos`.
- Rule: when the prompt names Talos as the subject and no repo is stated, the target is the Talos source repo. Before touching any other repo's config or checkout, state the resolved repo path in the first message and let Ben correct it.
- Rule: never `cd` into a repo that was not named; a `cd` in a Bash call silently rebinds the session's primary working directory and every later step inherits the mistake.
- Rule: check for other live Claude sessions in a repo (`ps -eo pid,command | grep <repo>`, `.talos/events.jsonl` mtime) before dispatching any stage that moves HEAD.

## 2026-09-15: dogfood run #278/#280/#281 — three-tier models, parallel developers, security fix-round scoping

- Model tiers now committed in `talos.pipeline.json`: Opus for developer and reviewer, Sonnet for PM/QA/security and every re-stamp, Haiku for validator/docs. Ben asked for all three tiers explicitly; this supersedes the 2026-09-07 "Sonnet for implementation" rule for this repo.
- **Two developers in one file can run in parallel if the orchestrator draws the boundary.** #280 and #281 both edited `scripts/pipeline-notify.sh`; each prompt named the other's region ("do not touch the Buzz send block" / "confine edits to the Buzz send block"). Result: zero conflicting hunks after the first merged, only a CHANGELOG union merge, which `pipeline-mergebase.sh` handled with no developer dispatch.
- **Scope the security re-review after a fix round or it finds a pre-existing weakness per round.** Round 1 on #283 was a real regression-adjacent finding (env-wide template substitution). Round 2 blocked on a fence-breakout path that already existed on main and the PR had merely refactored — one extra Opus developer dispatch. Rule: when re-dispatching security after a fix, say in the prompt that weaknesses pre-existing outside the PR's own delta are non-blocking notes or follow-up issues; verify "new in this PR" claims with `git show origin/main:<file>` before recording another attempt.
- **Fix-round developer when a worktree still holds the PR branch:** `git checkout --detach FETCH_HEAD`, commit, `git push origin HEAD:<branch>` — works whether or not the branch name is free. Cheaper than removing worktrees first, though `pipeline-worktree.sh remove <N>` only catches worktrees tagged via `tag <N>`; untagged developer worktrees need `git worktree remove --force <path>` by hand after confirming `status --porcelain` is empty and HEAD == PR head.
- **Reviewer/security/validator spawned without a worktree report through the mailbox with no usage**, so `pipeline-events.sh cost` shows `unrecorded` for them (this run: 11 of 17 events on #280). Known SKILL.md gap (#259); only worktree spawns carry usage.
- Re-stamp flow worked end to end on #283: `check-approval-sha --stale-list` → Sonnet re-stamps for qa/reviewer with the approved SHA, current head, `--stat` and prior-comment URL → `post-approval`. Two re-stamp rounds cost ~93k QA tokens total vs ~77k for the original full QA pass — re-stamps are not free; avoid needing them by scoping security up front.

## 2026-09-23: pipeline run #298/#299 — reread issue comments, escalate in-scope reviewer notes

- **Correction from Ben:** "make sure to reread the issues comments as there were updates to both of these." I had queued both issues from the `list-issues` bodies only. Two human comments on #298 (a squash-merge caveat and a tag JSON-patch gotcha) were posted before the validator ran. The PM spec picked up most of them but dropped two points (transitionWorkItems closes on ANY target branch; unlinked folded items). Rule: before dispatching the developer, run `read-comments <N>` and check that every point in each non-talos comment appears in the PM spec. For anything missing, post a "PM spec addendum" comment on the issue and send it to the developer. `gh api graphql ... userContentEdits` shows whether the body was edited after the run started.
- **A reviewer "non-blocking" note can be an in-scope correctness bug.** The #300 reviewer approved but noted that the new strict `merged` matcher accepted any `owner/repo#N` or issue URL, which is the same false-close class the issue was fixing. Verify such notes at the cited line, and send them back for a fix round when they contradict the issue's goal. Record the attempt as `record-attempt <N> reviewer --pr <PR>`.
- **Security agents report "removed pipeline:blocked" even when it was never set.** Check the label timeline (`gh api repos/.../issues/<PR>/events`) before treating it as evidence of a block.
- **Parallel PRs that each add tests to the same test file conflict**, even when their script regions are fenced. `update-branch` refuses, so a developer merge-base dispatch plus a full re-stamp round follows. Next time, also fence test files: have each developer put its tests in a separate section or file, or run such issues sequentially.

## 2026-09-24: follow-up run #302–#314 — ReDoS keeps recurring, timing inputs must be systematic

- **Every PR that added a regex over untrusted text needed a regex-complexity fix round** (#309 twice: exponential then quadratic; #308 once: quadratic across repeated keywords). Security's first timing pass used "obvious" inputs (`#12 ` runs) and missed the case where one substring both starts a keyword AND is a list item (`fix#1 fix#1 …`). Rule: brief developers up front to (a) cap scanned text at 65536 chars BEFORE any regex, (b) time adversarial inputs where the same substring can start a match at many offsets, (c) report a timing table. That brief on #304 made it land with zero complexity findings.
- **A reviewer "non-blocking" note is worth verifying at the cited line**: #307's unguarded `gh pr list` capture (failed call = "no PR") and #308's quadratic regex were both in attention reports or CHANGES that a lighter touch would have waved through.
- **Parallel reviewer+security both edited `pipeline:blocked`** — an approval erased the other role's block. Fixed in #310/#311: only the orchestrator clears it, right before a developer fix round.
- **`git --work-tree=<dir> checkout <ref> -- <paths>` writes the index of the current checkout.** Use `git archive <ref> <paths> | tar -x -C <dir>` or `git show <ref>:<file>` to export a PR's files for timing. A `cd` into a worktree in a Bash call also rebinds the session cwd — use `git -C` / absolute paths.
- **Transient API errors (spend limit 429, capacity 503) kill subagents mid-task.** Inspect the worktree (`git -C <wt> status`, compare `FETCH_HEAD`) before redoing work; resume the same agent with SendMessage when it has uncommitted edits, or re-route a small docs task to the docs role on a different model.

## 2026-09-24: follow-up run #318–#322 — merge order for PRs that edit the same helper

- **When two open PRs edit the same function, merge the smaller one first, then run the other's reviews once on the merged code.** #326 (link pinning) and #324 (parse-fail + stdin) both changed `_ga_fetch_all_pages`. Holding #324's reviews until #326 landed meant one review of the combined function instead of two.
- **Before re-stamping after a merge of main, prove the PR's own delta is unchanged:** `diff <(git diff $(git merge-base origin/main OLD) OLD -- scripts tests) <(git diff $(git merge-base origin/main NEW) NEW -- scripts tests)`. Identical → re-stamps are a quick confirmation, not a re-review.
- **Security fix rounds keep finding silent-empty coercions** (`except: page = []`, `2>/dev/null` on a gate fetch, `--limit N` with no cap warning). Brief developers up front: any fetch feeding a merge gate must fail or mark "unverified", never degrade to an empty result.
- **Pass large payloads to python on stdin, not env vars:** Linux caps a single env string at 128 KB (E2BIG).
- **`git show "$H:path"` with `H` set in a previous line of the same compound command printed the commit instead of the file** — use the explicit remote ref (`origin/<branch>:path`).

## 2026-09-24: follow-up run #328–#329 — prove platform-specific claims in a container

- **A regression test for a Linux-only failure can pass on macOS.** The E2BIG test (#329) passed on the Mac even with the bug reverted (macOS has no per-string env cap). QA proved the Linux failure by running the reverted code in `docker run ubuntu:24.04`. Rule: when a fix targets a Linux kernel limit, have QA reproduce the pre-fix failure in a Linux container, not just reason about it.
- **Docs-only nits on an approved PR go to a Haiku docs agent** (CHANGELOG/README are waiver paths, so approvals stay current) — cheaper than a developer round and no re-stamps.

## 2026-10-02: model routing must have one source of truth

- Ben asked to change the per-stage models; I edited `talos.pipeline.json` and reported the agent frontmatter and re-stamp model as "left alone". He expected one place to set models and everything to follow it.
- Rule: the Talos config is the intended single source of truth for models. When a model change leaves any other place disagreeing (agent `model:` frontmatter, `restamp_model`, the global install), either bring it in line or name it as a gap to close — never hand back a list of exceptions.
- Do not copy the routing table into `agents/*.md` frontmatter by hand: that is a second copy that drifts, and it changes the shipped defaults for every Talos user. Close the gap in the product (spec → PR) instead.

## 2026-10-02: long dogfood run (#336, #332, #340, #342, #343–#345) — where the tokens went and what to do first next time

- **Check required CI before dispatching QA.** Three QA passes (PR #351 twice, #354 once, ~350k tokens) ended in "CI is red" on things a macOS run cannot show: a flaky new test, the Linux 128 KiB env-string cap, a fixture relying on `init.defaultBranch`. Rule: after a developer returns, run `pr-checks-required <PR>` yourself; exit 1 goes straight back to the developer, no QA. Tell developers to wait for the check in the foreground before reporting. Filed as #355.
- **Standing lines for every developer brief** (each cost a fix round today): payloads reach python on stdin, never env or one argv element; `python3 -I`; fixtures set their own branch, identity and git options; a fetch that feeds a decision fails closed; never `git add -A` in a script that commits; prove Linux-only behaviour in `docker run ubuntu:24.04` before pushing.
- **Verify "non-blocking" review notes at the cited line.** Three were real defects: an unsandboxed test reading the real `~/.talos` (#337), assertions in a subshell that could not fail (#338), `git add -A` committing unrelated files (#354).
- **Collect the rest into one follow-up issue per wave** (#340, #342, #357) instead of another fix round plus three re-stamps per note. Give the issue an `## Acceptance criteria` checklist so PM is skipped.
- **Planner stays off in config.** Epic detection fires on any body of 2000+ characters, so a well-specified issue becomes an "epic". For a real epic (#333) dispatch the planner by hand, require `## Acceptance criteria` in every sub-task, and gate the sub-issues by labelling `pipeline:ready` yourself. A short validator pass (~45k tokens) on each sub-issue paid for itself every time with corrections to the planner's criteria.
- **Put platform assumptions in the validator brief.** #335 assumed a skill under `~/.claude/skills/` could be invoked as `/talos:<name>`; the validator tested it and it cannot. That saved a PM and a developer dispatch on an infeasible design.
- **Fix rounds:** resuming the same developer with SendMessage keeps its worktree and context, but each resume re-reads that context (300k tokens by round three). For a docs-only correction on an approved PR, use the docs role on a detached checkout; `CHANGELOG.md` is a waiver path, so approvals stay current.
- **QA negative controls leave litter.** Running a test with the cleanup trap removed left 24 `talos-status.*` directories in `$TMPDIR`. Tell QA to point `TMPDIR` at its sandbox and clean up after any control that disables cleanup.
- **zsh in the orchestrator's Bash tool:** `for d in $list` does not word-split (a "2 3" dependency list became one item and wrote a broken `Depends on: #` line), `$PIPESTATUS` is empty (zsh uses `$pipestatus`), and a command inside a `while read` loop can eat the loop's stdin. Capture exit codes into variables without a pipe, and redirect `</dev/null` inside read loops.
- **This checkout's `.git/config` carries a test identity** (`talos test <test@talos>`). Orchestrator commits to main use `git -c user.name=… -c user.email=…` until Ben removes the `[user]` block.

## 2026-10-02 (later): epic #333 through the planner, seven sub-issues, eleven more PRs

- **A verdict comment can be lost as a literal `-`.** After #351, `pipeline-notify.sh <event> <ref> -` reads stdin from a positional `-`, but `pipeline-vcs.sh comment-issue|comment-pr` only through `--body-file -`. A stage that mixes them posts `-` and the handoff is gone (validator on #349). Until #357 item 41 lands: tell every stage "never a bare `-` as the positional body; read your comment back", and when a developer reports a comment with body `-`, re-post the verdict from the stage's return message.
- **Planner sub-issues written before their dependencies exist go stale.** Each later sub-issue (#346–#349) needed a validator pass against what actually merged, plus an orchestrator addendum comment carrying review notes from the earlier PRs. Post those notes on the dependent issue as soon as the earlier PR merges; developers read issue comments, not the orchestrator's memory.
- **Fence parallel PRs by file and say which PR owns README.** #347 (playbook) and #348 (skill + README) ran side by side with zero conflicts because README, the playbook and the fixtures each had one owner. A docs agent then made README describe the state after both merged.
- **Verify platform naming claims by probe, not by docs recall.** Two agents disagreed on whether Claude Code names a skill from its directory or its frontmatter `name`. A one-call probe (`claude -p … --output-format stream-json --verbose`, read `slash_commands` in the init event) settled it: the directory name wins on 2.1.287.
- **For prose-only PRs (playbook, skills), QA means "follow the text verbatim in a sandbox".** That found nothing wrong in #359 and #361, and it is what makes a prose change testable; the reviewer then caught the rule-consistency gaps (Rule 21 vs Rules 15 and 19) that no walk shows.
- **Closing an epic with planner deviations:** list every deviation from the owner's text in the closing comment and say they were posted for veto and not answered; the acceptance check passing does not make them the owner's decisions.

## 2026-10-03: epic #353 (harness-neutral install) — sandboxing installer runs from a stage

- **Claude Code refuses any agent command that sets `HOME`.** QA on #363 could not follow the "sandbox `HOME` in the same command" brief. Point `TALOS_HOME` and `CLAUDE_CONFIG_DIR` at a `mktemp -d` dir in the same command as `install.sh --global` instead; in the global path `$HOME` only supplies their defaults, so the isolation is the same. Tests that need the `$HOME/.talos` default still set `HOME` themselves inside the test script, which the guard does not see. Brief installer stages with the `TALOS_HOME`/`CLAUDE_CONFIG_DIR` form and say plainly that `HOME` must not be set.
- **An inline `HOME=<scratch>` override can be silently ignored here, and the installer then writes the real `~/.claude`.** The #365 developer ran `HOME=<scratch> install.sh --global` by hand while debugging; the override did not take, Claude was detected from the real home, and 12 files under `~/.claude/{agents,skills}` were overwritten (by luck with byte-identical content from a refresh minutes earlier). Briefs must forbid manual `install.sh --global` outright for developers and QA; the default-`HOME` path is exercised only inside test scripts via `make_sandbox || exit 1`, and manual runs set `TALOS_HOME` and `CLAUDE_CONFIG_DIR` (never `HOME`). After any reported incident, compare the touched files with `cmp` against main and list files changed in the incident window with `find -newermt` before telling the owner what was lost.
- **A destructive test line under `$HOME` needs two guards.** #373's new test ran `rm -rf "$HOME/.talos" "$HOME/.claude"` after an unchecked `make_sandbox`, which returns 1 (and leaves the real `HOME`) when the file is sourced. Security flagged it as low; it would have wiped the owner's config. Any test that deletes under `$HOME` must use `make_sandbox || exit 1` and assert `$HOME` is inside `$SANDBOX` right before the delete. Read security's "low" notes against this session's own incidents before calling them non-blocking.
- **A docs push can break CI; check `pr-checks-required` after docs, before reviewer and security.** On #373 the docs stage wrote the literal `talos:begin`/`talos:end` markers into README, `tests/test-contract.sh` rejected them, and review and security had already run on a head whose CI was red. Brief docs to run `tests/test-contract.sh` (and any test mapped to README/docs) before pushing.
- **A stage can post its verdict and then hang without returning.** The #395 validator posted a complete CONFIRMED verdict at the 25-minute mark and then never returned for over an hour; its transcript file had not grown since. When a stage runs far past its peers, read the issue/PR comments for its verdict (`read-comments N`) before nudging or waiting; if the verdict is there, stop the agent (`TaskStop`) and proceed from the comment.
- **Security "low" notes that are pre-existing deserve a repo-wide grep.** One reviewer's aside ("`cmd_cost` runs `python3 -` without `-I`") was the tip of 196 call sites where a target repo could plant `json.py` and run code inside Talos (#395). When a note names a pattern, count it across `scripts/` before deciding where it goes.
- **Check environment facts yourself before relaying them to the owner.** The #352 planner said the installed `gh` was 2.94.0 without `--attach`; the orchestrator repeated it to the owner twice ("you'll need to upgrade gh") until a later validator ran `gh --version` and found 2.102.0 with `--attach`. One command (`gh --version`, `gh <cmd> --help | grep`) settles such claims; run it before telling the owner to change their machine.
- **The worktree guard also refuses `rc=$?` forms in some commands**, so a stage can lose an exit code (docs on #363, `check-approval-sha`). Ask for the helper's printed line, not its exit status, when the line is unambiguous.
- **Grep for a verb before naming it in a brief.** On PR #426 the orchestrator told the developer to update the PR body "with the PR-body edit verb in `pipeline-vcs.sh`"; no such verb exists, and the developer (correctly) stopped rather than call `gh` directly. `grep -n '^ *<verb>)' scripts/pipeline-vcs.sh` before the brief would have shown the gap (logged on #357).
- **Worktree-isolated stages can't run inline shell loops.** The harness guard refused `bash -c '<loop>'`, inline `until ... sleep` loops and `cmd; echo rc=$?` forms for developers and QA (#355, PR #425 QA). Any wait or retry a role prompt asks for must be a single script call with its own bound (e.g. `pr-checks-required <pr> --wait <s>`), never a loop typed into the prompt.
- **Planners are read-only; the orchestrator posts their plan.** Twice tonight a planner brief said "post the breakdown on the issue"; one planner obeyed (breaking its profile), the other correctly refused and handed back the file. Briefs for read-only roles (planner) must ask for the plan in the final message only; the orchestrator posts it with `comment-issue --body-file`.
- **Every path a test or QA script deletes must be a checked variable.** The #436 QA agent wrote `W="$(... create ... 2>/dev/null)"` then `rm -rf "$W/$f"`; an empty `W` makes that `rm -rf /<f>`. The owner's permission prompt and the worktree guard stopped it. Rule for every QA/developer scratch script: check each `mktemp`/`create` result (non-empty, is a directory) before use, delete only via `"${VAR:?}"/…`, and never hide a command's stderr and then use its output unchecked. `make_sandbox` itself had the same fail-open bug (fixed in #448).
- **Resumed developers get expensive; start fresh past ~250k context.** Each fix round resumed by SendMessage re-reads the whole prior context: #435's developer went 222k → 285k → 317k per round (825k total) and #440's 306k → 340k. When a developer's last completion is above ~250k tokens, dispatch a fresh developer on the existing branch with a precise brief (finding link, design decision, fence) instead of resuming it.
- **Watch the main-push CI legs, not only the PR's required check.** PR CI here runs ubuntu only; the macOS leg runs only on pushes to main and is not required, so it hung 6 h on every main push for two days (30+ runs, #479) while every PR looked green. Once per run, list `gh run list --workflow tests.yml --event push --limit 5`; any run `in_progress` for longer than a normal suite, or a string of `cancelled`, is a hang to diagnose (job log, orphan processes) before more merges land.
- **An infinite producer piped into `head` hangs on macOS CI.** `tr -dc … </dev/urandom | head -c 16` relies on SIGPIPE; the Actions runner starts steps with SIGPIPE ignored and BSD `tr` ignores EPIPE, so it reads forever (GNU `tr` exits, so ubuntu passes). Read a bounded input (`od -An -N8 -tx1 /dev/urandom`). Repro locally with `( trap '' PIPE; exec bash <script> )`.
- **After `ready-pr`, wait with `pr-checks-required <PR> --wait <s>`, not `gh pr checks --watch`.** The draft-time `skipping` check is already complete, so `--watch` returned at once on PR #478 before the ready-for-review run existed; the verb treats skipped as pending.
- **Check `pr-mergeable` right before every QA dispatch, not only after the developer.** Each merge to main can leave the other ready PRs CONFLICTING on CHANGELOG.md; QA treats a conflicting PR as an immediate FAIL (PR #485 cost a wasted QA run). Run `pr-mergeable <PR>` immediately before spawning QA and, on CONFLICTING, run `pipeline-mergebase.sh <PR>` first.
- **Many parallel `pr-checks-required --wait` calls exhaust the GraphQL quota.** Six background waits (30 s steps, `gh pr checks` is GraphQL) plus a dozen agents used all 5,000 GraphQL points in an hour on 2026-10-04, and `record-attempt` then failed with "could not resolve head SHA". With more than two PRs in CI, use one poller on the REST API (`repos/<o>/<r>/commits/<sha>/check-runs`, separate core quota) at a few-minute interval instead of one `--wait` per PR.
- **Never chain `ready-pr` after a mergebase attempt without checking its result.** On PR #500 the one-liner `[ CONFLICTING ] && pipeline-mergebase.sh …; check-approval-sha && ready-pr` marked a still-conflicting PR ready (mergebase refused a non-union path), so no CI could run. Gate `ready-pr` on `pr-mergeable` printing MERGEABLE after any mergebase.
- **Gate post-merge bookkeeping on the merge result, not on reaching the next line.** On #420 the merge chain's `assert-sync` failed (my own uncommitted lessons edit) but the closed-comment, Done status, merged event and worktree removal ran anyway; they must sit behind `merge-pr … && …` in one `&&` chain, and orchestrator edits to tracked files get committed before any merge gate.
