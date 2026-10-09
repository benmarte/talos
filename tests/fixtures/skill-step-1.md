## Step 1 — Reconcile in-flight work (VCS mode only)

A prior session may have died mid-issue. Heal once: `bash scripts/talos.sh sweep <ids>` (runs items 1 and 4; never fails; `warn reason=` lines → Step 5; `heal=` → Rule 20 fast-forward).

1. **Adopt orphaned PRs.** `pipeline:dev`/`pipeline:review` issue with no obvious PR → `bash scripts/pipeline-vcs.sh find-pr <N>`: PR → adopt (resume at the first missing approval label); none → re-dispatch the developer (counts toward `max_fix_attempts`).
   - Open PR found → adopt it: do NOT re-dispatch the developer; resume from the first missing approval label (QA if `qa:pass` absent, etc.). A PR that carries `pipeline:blocked` (on the PR or its issue) is not resumed — leave it for item 5's blocked-work report.
**Heal merged-but-open issues.** `find-pr <N> merged` closes with `issue-<N>` branch or closing keyword (never bare `Depends on #N`/`Part of #N`, #298) → `heal=<N> pr=<M>` → the post-merge items (`--heal`: no sibling sync, no CI-run count). Exit 2 = unverified, never "no PR": "find-pr not verified for #N — heal skipped, verify manually" in the summary; `find-pr-failed` = same.
   - **`warn reason=find-pr-unverified issue=<N>` → not verified, not "no PR".** `find-pr` exits 2 when the provider cannot answer it — do NOT treat that as "no merged PR": the heal for `#N` was skipped; add `find-pr not verified for #N — heal skipped, verify manually` to the run summary (Step 5). `find-pr-failed` is a fetch failure: report it the same way.
3. **Resume in-flight PRs — `bash scripts/talos.sh next`** (one action per PR-side blocking stage; it reads the same state as `state`, acquires the issue's lease and never guesses):
   - `action=dispatch stage=<role> pr=<M> issue=<N>` → run that stage's Step 3 prompt for PR #M (a draft-window PR answers `wait reason=draft`: continue the Draft stage order, never QA).
   - `action=merge pr=<M> issue=<N>` → Step 4 (`gate merge`).
   - `action=wait reason=<blocked|ci|human-merge|owner|lease|none>` → nothing to resume; move on. `stop reason=...` → report it. Issue-side stages are not covered by `next` yet; a queued issue still enters Step 2 as below.
   A PR that carries `pipeline:blocked` (on the PR or its issue) is not resumed — item 5 reports it and Step 5 lists it as `blocked`; `wait reason=blocked` is that answer.
4. **Sweeps.** `worktree_sweep=` (#240). `blocked_issues=K` / `blocked_prs=J` (item 5, #312): stale blocked work, one `info backlog` notice when K + J > 0; a human clears `pipeline:blocked`. Planner on: `epic=<E> action=closed|pending|waiting` (else `pipeline:epic-children-done`, one comment; `warn reason=epic-acceptance-unsupported` = unsupported, left open; `unblocked=<N>` = `pipeline:ready` when every `Depends on:` issue closes).

Log a one-line summary: "N issues queued, M PRs in-flight (A adopted), K ready to merge, B blocked."

---

