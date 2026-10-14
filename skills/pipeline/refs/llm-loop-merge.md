# The LLM loop: Step 3e (review stages) and Step 4 (merge)

Read when the LLM loop reaches Step 3e or Step 4 (`ORCHESTRATOR=llm`).

### 3e. Review stages

Only after `qa:pass` (with `PR_DRAFT` this stage runs BEFORE QA on the draft, `ref=draft-order`).

**Phase 1 — Docs first:** `bash scripts/talos.sh docs-gate <PR> --issue <N>` decides it in code. `docs=skip`: the verb stamped `docs:done` and ran `done docs`; dispatch nothing. `docs=dispatch`: spawn docs with `talos.sh prompt docs --issue <N> --pr <PR> [--docs-paths-file F]` (`paths-file=F` → `--docs-paths-file F`, else the full diff), then `done docs --issue <N> --pr <PR> --summary-file F`. After a fix round (a stale `docs:done`) it answers for the delta since the approved SHA: `docs=skip reason=no-docs-delta` is a stamp like any skip; `docs=dispatch reason=docs-delta shape=restamp restamp-file=F` is the docs re-stamp: render `talos.sh prompt docs --issue <N> --pr <PR> --shape restamp --restamp-file F`, spawn docs on the re-stamp model and effort of `refs/restamp.md`, delete `F`, then `done docs --issue <N> --pr <PR> --verdict RESTAMP_PASS|RESTAMP_FAIL --summary-file F`, the verdict being the word the agent's first line starts with. A docs `RESTAMP_FAIL` is `next=continue`, never a fix round: the verb dropped `docs:done`, so the next pass runs the full stage.

**Sync guard (non-isolated stages):** before dispatching reviewer and security run `bash scripts/pipeline-vcs.sh assert-sync`; non-zero halts this issue with the error output (main can advance mid-run).

**Re-stamp check (fix-round path):** before reviewer/security (and adversarial) run `bash scripts/pipeline-vcs.sh check-approval-sha <PR> --stale-list` and capture `stale role=<role> label=<label> [sha=<approved SHA>]`. **Trigger:** re-stamp a role only when its approval label is present on the PR AND `--stale-list` reports it stale; a role whose label is absent (first pass, or stripped after FAIL/CHANGES/FINDINGS) gets the full dispatch. Step 4's stale handling shares this flow, for `qa`, `reviewer`, `security` and `adversarial` alike. How to dispatch one (same role and profile, delta-only prompt, restamp model/effort): `refs/restamp.md`. A re-stamp never clears `pipeline:blocked` (`gate fix-round` did before the fix round that made the approval stale). Report it with `done <role> ... --verdict RESTAMP_PASS|RESTAMP_FAIL`; on `RESTAMP_FAIL` the verb first strips the stale label (`qa:pass`, `review:approved`, `security:approved`, `adversarial:approved`), or the next pass would re-stamp forever; `next=fix-round` = the full-stage re-dispatch.

**Phase 2 — Reviewer and security in parallel** (each `roles.<role>`), after docs; a role named by the re-stamp check gets its re-stamp variant, not the full prompt: `talos.sh prompt reviewer --issue <N> --pr <PR> --prior-file F` and `talos.sh prompt security ...`. Phase 3, adversarial (default off): `ref=adversarial`.

Then for each role: `done <role> --issue <N> --pr <PR> --verdict <V> --summary-file F` (the reviewer's summary includes its top 1-2 human-attention items). `next=fix-round stage=<role>` (a RESTAMP_FAIL too) → `bash scripts/talos.sh gate fix-round <N> <role> --pr <PR>`: `verdict=redispatch` → developer; `verdict=block` → stop; `verdict=ask-owner` → the owner decides first. A blocked stage → `pipeline:blocked` on the issue, move on.

---

## Step 4 — Merge when ready (VCS mode)

```bash
bash scripts/talos.sh gate merge <PR_NUMBER> <N>
```

It runs every gate and never merges itself: no `pipeline:blocked`; every enabled role's approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`, `adversarial:approved`), waived only by a human's `skip-qa`; `check-approval-sha`; `check-pr-files`; `check-closing-keyword`; the draft state; `pr-checks-required` (2 re-runs per head SHA); the stale-base guard; `merge.auto`. Act on the first line:
- `merge`: `bash scripts/pipeline-vcs.sh merge-pr <PR_NUMBER>`, then `post-merge`. With `PR_DRAFT` capture `ci_runs=` first (`ref=draft-order`).
- `handoff` (`merge.auto = false`): `ref=human-merge`.
- `wait`: do not merge, nothing is blocked, look again next pass. `ci-failed`: 2 re-runs are spent, a human or a new commit must act. `base-synced`: a base update was pushed, CI must rerun on the new head.
- `redispatch`: `stale-approvals` (the verb stripped the `stale=` labels and commented): re-stamp below. `merge-conflict`: `refs/merge-conflict.md`. With `PR_DRAFT`, `draft-pr` and `ci-failed` return to the draft order.
- `block` (`forbidden-files`, `closing-keyword`, `siblings-capped`): the verb set `pipeline:blocked`, commented and sent the `blocked` notice. Move on; only a human may clear it.
- `stop reason=<r>`: a gate could not be checked (fail closed): do NOT merge, report it.

**Stale approvals.** Approvals are bound to the PR head SHA. `merge.approval_waiver_paths` (default `*.md`, `docs/**`, `CHANGELOG.md`, `*.example`; never code, tests or agent instructions) keep approvals standing. Dispatch in `stale=` order (QA first):
- `qa` / `reviewer` / `security` / `adversarial` stale: it already has a prior approval on this PR, so dispatch its **re-stamp** variant (`refs/restamp.md`), never the full stage. A `RESTAMP_FAIL` is not merged against: the next pass re-dispatches the full stage.
- `docs` stale: run Phase 1 of Step 3e; `docs-gate` decides it (`gate merge` stripped `docs:done`, so it is the first-pass decision). Approvals are stamped with `post-approval` at the head SHA.

**After `merge-pr`:** `bash scripts/talos.sh post-merge <PR_NUMBER> <N>` — one call: the sibling sync, the issue-closed comment, `close-issue`, board Done, the checkout back on the base (`checkout=`, hard rule 8), the worktree removal, the notices, the `merged` and `issue-closed` events and the spend block; each non-fatal (`warn reason=<r> issue=<N>` → run summary).
- `recorded=yes`: done earlier (idempotent). `spend=<line>`: print it; `warn reason=spend-upsert-failed`: ONE Step 5 line, never retried.
- `post-merge` pushes nothing to the base; it returns the checkout to the base itself (hard rule 8).
- **Sibling sync** (`merge.auto_sync` true): `sibling=<pr> action=clean|mergebase|update-branch|developer|unverified`; relay it. `developer` → the merge-base task (`refs/merge-conflict.md`) immediately, never more than one per merge, re-checking `pr-mergeable` between, relay `pipeline-notify.sh info "merge-base" - <N>` (stdin `#<N> sibling PR #<PR> synced with new base (developer)`). A sync touching non-waived paths invalidates approvals: wait for the re-stamps.
