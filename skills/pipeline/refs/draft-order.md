# Draft stage order (`PR_DRAFT = true`)

Read when `talos.sh env` prints `ref=draft-order` or `next` answers `wait reason=draft`. `pr.draft: true` keeps the PR DRAFT through every no-CI stage; CI runs once, at `ready-pr`, on the final head. This replaces the default order (developer, QA, docs, reviewer + security, merge) for the issue; Steps 3a/3b and the Step 4 gates are unchanged.

**Flags.** Every `talos.sh prompt` and every `talos.sh done` takes `--draft`. The developer dispatch (first pass and each fix round) opens the PR as a DRAFT with `Required checks: none`. With `done --draft`, a QA `FAIL` is converted back first (`draft-pr`, drop `qa:pass`); a reviewer/security/adversarial CHANGES/FINDINGS answers `next=batch`: no attempt is recorded and the developer is not re-dispatched by it.

## Order

1. **Developer: open the DRAFT PR.** Step 3c; the local `verify:` run is the only gate before review. Run the mergeability gate as written, but "proceed to Step 3d" means "proceed to step 2" (resolve conflicts while still a draft).
2. **Docs: CHANGELOG now.** Step 3e phase 1, so the docs commit lands before any approval marker exists and never makes one stale. A push to a draft runs no CI.
3. **Review: reviewer, security and adversarial (when `roles.adversarial`) in one parallel batch**, on the draft (Step 3e phases 2 and 3). Wait for every dispatched role; never re-dispatch the developer on one role's verdict. Review runs before QA, so no role runs tests or waits for CI here, and the "only after `qa:pass`" rule of Step 3e does not apply.
4. **Developer: ONE fix round for every finding.** Any CHANGES/FINDINGS: collect the findings of ALL roles into one fix-round dispatch (Step 3c) and call `gate fix-round` once: `bash scripts/talos.sh gate fix-round <N> <that-role> --pr <PR_NUMBER>` (`verdict=block`: board "Blocked", stop). Afterwards the re-stamps review only the delta: re-stamp variant for roles that approved, full stage for roles that raised findings; when documented behaviour changed, re-run docs (step 2) first, inside this draft window.
5. **`ready-pr`: the ONE CI run.** Preconditions: `check-approval-sha <PR_NUMBER> --stale-list` exit 0 with every enabled approval label present (`docs:done`, `review:approved`, `security:approved`, `adversarial:approved` when enabled), no `pipeline:blocked`, `pr-mergeable <PR_NUMBER>` not `CONFLICTING`. Then `bash scripts/pipeline-vcs.sh ready-pr <PR_NUMBER>`; non-zero: stop this pass, report `ready-pr failed for #<N>`, never dispatch QA. The `ready_for_review` event is the only CI trigger in the whole flow.
6. **QA: on a ready PR only.** Step 3d, preceded by the draft guard below. Under `qa_mode: ci` QA trusts `pr-checks-required` (the one run).
7. **Merge.** Step 4, unchanged: the approval SHAs and `ci-complete` on the final head are still required. A ready PR bypasses no gate.

`tests/test-draft-stage-order.sh` replays these calls against a stub that counts CI runs:

```text
happy path:     create-pr --draft -> ready-pr -> QA, merge
failure round:  draft-pr -> label-pr --remove qa:pass -> developer fix + re-stamps -> ready-pr -> QA, merge
```

**QA failure or CI failure** (QA FAIL, its CI wait failed closed, or Step 4's `pr-checks-required` still failing after its re-run budget): convert the PR back FIRST with `bash scripts/pipeline-vcs.sh draft-pr <PR_NUMBER>` (non-zero: stop, report `draft-pr failed for #<N>`; never push a fix to a ready PR, each push spends a run), then `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --remove qa:pass` (a no-op when `qa:pass` is absent; non-zero: stop, report `label-pr failed for #<N>`). Otherwise the stale `qa:pass` blocks step 5's `--stale-list` check permanently; with it gone, QA runs in full on the ready PR (step 6, `qa:pass` absent). Then `gate fix-round <N> qa --pr <PR_NUMBER>`, one developer fix round, the re-stamps on the delta, and `ready-pr` again: exactly one CI run however many commits the fix took. A QA `FAIL` with `--draft` has already run `draft-pr` and dropped `qa:pass`; the round still ends with `ready-pr`.

## QA draft guard

Before EVERY QA dispatch (the first, a retry after a fix round, a Step 4 re-stamp) and before any CI wait, ask the PR itself, never memory:

```bash
STATE="$(bash scripts/pipeline-vcs.sh pr-is-draft <PR_NUMBER>)"; RC=$?
```

Dispatch QA (and start the CI wait) ONLY when `RC` is 1 AND `STATE` is exactly `ready`. Anything else starts nothing:
- `RC` 0 (`draft`): still in the draft window; QA and the CI wait would wait for a run that never comes. Continue the order at the first missing step (docs, review, fix round, then `ready-pr`).
- `RC` 2 (unverified: fetch failed, bad id, unparseable response, unsupported provider), or any other `RC`/`STATE` pair: stop this issue for this pass and report `pr-is-draft not verified for #<N>`. Never read it as `ready` or `draft`; do not call `ready-pr` or `draft-pr` on it.

Under `VERIFY_QA_MODE` `ci` the PR was just marked ready: run the CI gate (`refs/ci-gate.md`) with `--wait <B>`, `B` = `min(VERIFY_CI_WAIT_S, VERIFY_TIMEOUT_MS/1000 - 30)`, the Bash call's timeout `VERIFY_TIMEOUT_MS`. The table is unchanged (2, still pending at `B`, spawns QA). QA passing ends the QA stage; Step 3e is NOT entered again, since its review already ran on the draft. Go to Step 4.

## Merge

`gate merge` asks `pr-is-draft` itself and never lets a draft through (`redispatch`): `draft-pr` and `ci-failed` mean the PR was never CI-verified, so go back to this order (`draft-pr`, developer fix, re-stamps, `ready-pr`). No gate is waived for a draft-flow PR.

**Capture the CI-run count BEFORE `merge-pr`.** `merge-pr` deletes the head branch, after which GitHub returns every run with an empty `pull_requests[]` and `pr-ci-runs` exits 2. `gate merge` therefore reads it while the PR is open and prints `ci_runs=<n>`: keep it as `CI_RUNS` and pass `--ci-runs "$CI_RUNS"` to `post-merge`. Never call `pr-ci-runs` after the merge. On `warn reason=ci-runs-unrecorded` (or a heal, or no captured value) omit the flag, never guess, and add `ci_runs not recorded for #<N>` to the run summary; a missing metric never blocks or delays an otherwise green merge.

```text
merge sequence:  pr-ci-runs -> merge-pr -> post_stage merged --ci-runs
```
