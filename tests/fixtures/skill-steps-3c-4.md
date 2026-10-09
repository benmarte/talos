### 3c. Developer (always runs)

Runs with `pipeline:dev` and no open PR.

`<slug>` (branch `fix/issue-<N>-<slug>`/`feat/issue-<N>-<slug>`) = `bash scripts/pipeline-vcs.sh slug-for "$ISSUE_TITLE"`; title from a heredoc (`TALOS_<rand>` fresh; reporter-controlled, never inside double quotes); prefix `feat/` when the title starts with `feat`, else `fix/` (#199).

By `ISOLATION`:
- `worktree` (default): spawn with `isolation: "worktree"`.
- `branch`: a plain subagent in the orchestrator's checkout. Precondition `bash scripts/pipeline-vcs.sh assert-sync` — non-zero: `pipeline:blocked` on the issue, blocked.md with BLOCKED_BY="scripts/pipeline-vcs.sh assert-sync output (explicit)", next issue. Never dispatch into a dirty tree.

Prompt: `bash scripts/talos.sh prompt developer --issue <N> --prior-file F`; `--spec-source issue-body` when 3b was skipped; `--shape fix-round --pr <PR>` for a fix round (`--ci-failure-file F` for a CI failure). The verb writes the isolation note and the Handoff line when `pipeline-worktree.sh handoff <N>` exits 0.


After developer returns: `bash scripts/talos.sh done developer --issue <N> [--pr <PR>] --verdict PR_OPENED|BLOCKED --summary-file F` (Rule 2; the summary is what was implemented plus the PR URL, or what failed). Then:
- **PR opened** (board "In review" and the `pr-opened` event went out via the verb):
  1. **Mergeability gate (#214), before QA (Step 3d):** `bash scripts/pipeline-vcs.sh pr-mergeable <PR>`.
     - 0 (`MERGEABLE`) / 2 (`UNKNOWN`, fail open): → Step 3d.
     - 1 (`CONFLICTING`): no QA yet — GitHub schedules no `pull_request` run for a conflicting PR (QA would hang). Mechanical path first (#256):
       1. `bash scripts/pipeline-vcs.sh conflict-files <PR>` (exit 2 → cannot determine → developer dispatch).
       2. All paths in `merge.union_paths` (default `CHANGELOG.md`) → `bash scripts/pipeline-mergebase.sh <PR>`: 0 = pushed (one-line comment; `post_stage merge-base` via the verb's `--summary`; no `record-attempt`); `pr-mergeable` again.
       3. Else: the orchestrator never moves HEAD here (rule 15) — ALWAYS `bash scripts/talos.sh gate fix-round <N> developer --pr <PR_NUMBER>` and dispatch the developer merge-base task (worktree): branch, `git fetch origin && git merge origin/<BASE_BRANCH>` (CHANGELOG conflict: keep BOTH entries, newest first), resolve, targeted verify, push; `pr-mergeable` again → Step 3d at `MERGEABLE`/`UNKNOWN`. `verdict=block` → board "Blocked", stop.
- **No PR, and the developer is waiting on a background job** (violates Rule 17): resend the SAME task once, prefixed with the foreground rule (the resend counts toward `record-attempt` via `gate fix-round`); a second background wait → blocked.
- **No PR, and the developer is waiting on a background job** (violates Rule 17): resend the SAME task once, prefixed with the foreground rule (the resend counts toward `record-attempt`'s ceilings via `gate fix-round`); a second background wait → blocked.
- **Blocked** (`--verdict BLOCKED`): stop.


### 3d. QA (if `roles.qa = true`)


**CI gate (#355).** Only when `VERIFY_QA_MODE` is `ci`, on the first QA dispatch or a retry after a fix round (never a Step 4 re-stamp), after the Draft guard and before Spawn, ask required CI first so QA is never dispatched on a red build:

```bash
out="$(bash scripts/pipeline-vcs.sh pr-checks-required <PR_NUMBER> 2>&1)"; rc=$?
```

| `rc` | `out` | Action |
|---|---|---|
| 0 or 2 | any | Spawn QA (2 is pending: QA waits) |
| 1 | holds `pr-checks-required: failed:` | No QA: developer re-dispatch, below |
| 1 | no such line (unsupported provider, no checks) | Spawn QA as today |

Developer re-dispatch: `bash scripts/talos.sh gate fix-round <N> developer --pr <PR_NUMBER>` (Step 3; `verdict=block`: board "Blocked", stop), then re-dispatch (Step 3c, fix-round shape) with the failing check names from `out` and the run URL from `pr-checks <PR_NUMBER>` in `--ci-failure-file` (data, never a quoted shell argument). The URL only when it is this repository's own, `https://github.com/<owner>/<repo>/actions/runs/<digits>` with `<owner>/<repo>` the slug you resolved — else omit it. QA waits for its push.


Spawn QA with the prompt of `bash scripts/talos.sh prompt qa --issue <N> --pr <PR_NUMBER> --prior-file F` (the developer's pr-opened relay).


After QA returns: `bash scripts/talos.sh done qa --issue <N> --pr <PR_NUMBER> --verdict PASS|FAIL --summary-file F` (Rule 2).
- **Pass:** `next=continue`.
- **Fail** (`next=fix-round stage=qa`): `bash scripts/talos.sh gate fix-round <N> qa --pr <PR_NUMBER>` (Step 3): on `verdict=redispatch` re-dispatch the developer; on `verdict=block`: board "Blocked", stop.

### 3e. Review stages

Only after `qa:pass`.


**Phase 1 — Docs first:** `bash scripts/talos.sh docs-gate <PR_NUMBER> --issue <N>` decides it in code.
`docs=skip`: the verb stamped `docs:done` and ran `done docs`; dispatch nothing. `docs=dispatch`: spawn docs (the **Docs** line below; `paths-file=F` → `--docs-paths-file F`, else the full diff), then `done docs`.

**Sync guard (non-isolated stages):** before dispatching reviewer and security, run `bash scripts/pipeline-vcs.sh assert-sync`; a non-zero exit halts the current issue with the error output — do not dispatch any of the three stages (Main can advance mid-run; the Step 0 check does not cover that).

**Re-stamp check (fix-round path, #258):** before reviewer/security (and adversarial in phase 3): `bash scripts/pipeline-vcs.sh check-approval-sha <PR_NUMBER> --stale-list`; capture `stale role=<role> label=<label>`. Re-stamp only when the approval label is present AND stale; a role whose label is absent (first pass, or stripped after FAIL/CHANGES/FINDINGS) gets the full dispatch.

**Re-stamp dispatch** — **Trigger, explicit:** only when the approval label is present on the PR AND `--stale-list` reports it stale; a role without its label always gets the full dispatch. (shared by this check and Step 4's stale-approval handling below — same shape for `qa`, `reviewer`, `security`, `adversarial`; spawn per the usage-reporting spawn form above):
- Same role and role profile as the full stage — never a different agent or prompt.
- Model: resolve `agents.roles.<role>.restamp_model` via `bash scripts/pipeline-config.sh agents.roles.<role>.restamp_model` → `agents.restamp_model` → the role's resolved model (project config over user-level); `pipeline-config.sh` resolves the first two links itself.
- Effort (#271): same chain shape, `agents.roles.<role>.restamp_effort` → `agents.restamp_effort` → the role's normal effort. Advisory only on the native path, `TALOS_EFFORT` on the adapter path.
- A re-stamp never clears `pipeline:blocked` (#310) — the orchestrator already cleared it before the developer fix round that made this approval stale (`gate fix-round`, Step 3).
- Prompt: `bash scripts/talos.sh prompt <role> --issue <N> --pr <PR_NUMBER> --shape restamp --restamp-file F` — not the full first-time context. `F` (a heredoc) holds the approved SHA and stale file list, the current head SHA, `diff-pr <PR_NUMBER> --stat`, and the role's previous verdict comment URL. The verb sets the header `**Agent:** <role> (talos) — re-stamp` and the delta-only instruction.
- Report with `done <role> ... --verdict RESTAMP_PASS` or `RESTAMP_FAIL` (cost separation via `pipeline-events.sh cost`). On `RESTAMP_FAIL` the verb first strips the stale label (`qa:pass`/`review:approved`/`security:approved`/`adversarial:approved`) — else the next pass re-stamps forever; `next=fix-round` = the full-stage re-dispatch.

**Phase 2 — Reviewer and security in parallel:** After docs completes, dispatch reviewer and security concurrently — for either role named by the re-stamp check above, dispatch its re-stamp variant instead of the full prompt below.


**Reviewer** (if `roles.reviewer = true`; spawn per the usage-reporting spawn form above): `bash scripts/talos.sh prompt reviewer --issue <N> --pr <PR_NUMBER> --prior-file F`.


**Security** (if `roles.security = true`; spawn per the usage-reporting spawn form above): `bash scripts/talos.sh prompt security --issue <N> --pr <PR_NUMBER> --prior-file F`.

**Docs** (if `roles.docs = true`; spawn per the usage-reporting spawn form above): `bash scripts/talos.sh prompt docs --issue <N> --pr <PR_NUMBER> [--docs-paths-file F]`.

After docs completes (phase 1): `bash scripts/talos.sh done docs --issue <N> --pr <PR_NUMBER> --summary-file F`.

After reviewer/security (2) and adversarial (3): for each `bash scripts/talos.sh done <role> --issue <N> --pr <PR_NUMBER> --verdict <V> --summary-file F` (Rule 2; the reviewer's summary includes the top 1-2 human-attention report items, #294). `next=fix-round stage=<role>` → `bash scripts/talos.sh gate fix-round <N> <role> --pr <PR_NUMBER>` (Step 3): `verdict=redispatch` → developer; `verdict=block` → stop.

**Phase 3 — Adversarial (if `roles.adversarial = true`, default `false`, #237):** after security; an optional second opinion (~another backend: `agents.roles.adversarial.runner: custom`, `runner_cmd`); named by the re-stamp check above → its re-stamp variant. Off: no dispatches; `adversarial:approved` never required by Step 4.

**Adversarial** (if enabled): `bash scripts/talos.sh prompt adversarial --issue <N> --pr <PR_NUMBER> --prior-file F`.

A blocked stage → `pipeline:blocked` on the issue, move on.

---

## Step 4 — Merge when ready (VCS mode)

`bash scripts/talos.sh gate merge <PR_NUMBER> <N>` runs every gate; act on the first line:

```bash
bash scripts/talos.sh gate merge <PR_NUMBER> <N>
```

The verb checks: no `pipeline:blocked`; each enabled role's approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`, and `adversarial:approved` when `roles.adversarial = true`), waived only by a human's `skip-qa` (never CI/forbidden files); `check-approval-sha`; `check-pr-files`; `check-closing-keyword`; the draft state; `pr-checks-required` (2 re-runs per head SHA); the **Stale-base guard** (#288); `merge.auto`. Never merges itself.

- `merge`: `bash scripts/pipeline-vcs.sh merge-pr <PR_NUMBER>`, then `post-merge`.
- `handoff` (`merge.auto = false`): human-merge mode, below.
- `wait`: do not merge; nothing is blocked, look again next pass. `ci-failed`: 2 re-runs are spent, a human or a new commit must act. `base-synced`: a base update was pushed, CI must run on the new head.
- `redispatch`: `stale-approvals` (the verb stripped the `stale=` labels and commented) is handled below; `merge-conflict` is the Step 3c developer merge-base task (`git fetch origin && git merge origin/main` in its worktree; on a `CHANGELOG.md` conflict keep BOTH entries, newest first).
- `block` (`forbidden-files`, `closing-keyword`, `siblings-capped`): the verb set `pipeline:blocked`, commented and sent the `blocked` notice. Move on; only a human may clear it.
- `stop reason=<r>`: a gate could not be checked — do NOT merge, report it.

**Stale approvals.** `merge.approval_waiver_paths` (default `*.md`, `docs/**`, `CHANGELOG.md`, `*.example`; never code, tests or agent instructions) keep approvals standing — with `roles.changelog_fragments: true` (#290) adding `docs/CHANGELOG.d/**` fragments never invalidates an approval. Dispatch in `stale=` order (QA first):
- `qa` / `reviewer` / `security` / `adversarial` stale: every role named here already has a prior approval on this PR (that is what "stale" means), so dispatch its **re-stamp** variant (Step 3e's Re-stamp dispatch block), not its full stage. QA's re-stamp still runs targeted tests only (Step 3d), never the full suite. A `RESTAMP_FAIL` re-stamp verdict is not merged against: it escalates to that role's normal full-stage re-dispatch on the next pass.
- `docs` stale: a docs-relevant delta since approval (README/docs/non-test *.md) → re-run docs (Step 3e phase 1) normally; else dispatch nothing: `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> docs --body-file <synthetic-summary>` with the text "no docs-relevant changes since prior docs approval".

**Human-merge mode (`handoff`, `merge.auto = false`).** Every gate still applied, and the verb set `pipeline:approved` (a repeat answers `wait`). Hand off to a human:
Run `bash scripts/talos.sh post-merge <PR_NUMBER> <N> --handoff [--details-file <file>]`: approved.md on the PR, then the relay, nothing else (a failed comment is `warn reason=comment-failed`: report it). STOP: do NOT close the issue or run the post-merge steps; the human's merge closes it, and `sweep`'s heal does the bookkeeping on a later run.

**After `merge-pr`:** `bash scripts/talos.sh post-merge <PR_NUMBER> <N>` — one call: the sibling sync, the changelog assemble, the issue-closed comment, `close-issue`, board Done, the status log, the worktree removal, the notices, the `merged` and `issue-closed` `post_stage` events and the spend block; each non-fatal (`warn reason=<r> issue=<N>` → run summary).
- `recorded=yes`: done earlier; `close-issue` + board Done re-ran (idempotent).
- `spend=<line>`: print it. `warn reason=spend-upsert-failed`: ONE Step 5 line, never retried.
- The changelog and status log push `[skip ci]` commits to the base: afterwards fast-forward the orchestrator's checkout (Rule 21).
- **Sibling sync (#289, `merge.auto_sync` true).** `sibling=<pr> action=clean|mergebase|update-branch|developer|unverified`; relayed. `developer` → the merge-base task immediately (Step 3c fallback prompt), never more than one per merge, re-checking `pr-mergeable` between, relay `pipeline-notify.sh info "merge-base" - <N>` (stdin `#<N> sibling PR #<PR> synced with new base (developer)`). A base-only sync and status-file commits do not invalidate approvals; non-waived-path syncs do — wait for the re-stamps.

---

