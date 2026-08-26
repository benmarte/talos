# Changelog

## [Unreleased]

### Fixed

- **`scripts/pipeline-vcs.sh` `check-approval-sha`: make unknown-role rejection explicit and self-documenting, with a diagnostic (#128).** Unknown role values were already rejected incidentally by the per-label equality check (`m.group(2) != role`): a marker with `role=review` could never satisfy a `reviewer` check, so it was silently skipped and the gate exited non-zero for a missing marker. The security posture is unchanged. What was missing was intentionality and observability: there was no explicit validated set, no indication that the rejection was by design rather than a coincidental mismatch, and no stderr message naming the offending value. Fix: a `VALID_ROLES = {'qa', 'reviewer', 'security', 'docs'}` constant is added to both the `_github` and `_github_api` provider copies of the `check-approval-sha` Python block. An unrecognised role now emits a diagnostic to stderr (`ignoring marker with unknown role <role> (valid: docs, qa, reviewer, security)`) before being skipped, making the rejection intentional and auditable. The valid set is a hard-coded literal, never interpolated from config or API text (PR #68 precedent). Reason strings are ASCII-only and byte-identical across both providers. **What this PR does NOT close:** dispatch provenance (a marker with no mandate -- an agent can still post all four markers with valid roles against the current head SHA and satisfy the gate) and contradictory verdicts (the marker format has no verdict field; a PASS marker alongside a FAIL prose comment is invisible to any marker-only scan). Both gaps remain open and require a separate design. Four new test cases in `tests/test-approval-sha.sh` and three in `tests/test-github-api.sh` cover the unknown-role diagnostic assertion (RED before fix from absent stderr line, not from wrong exit code), each individual valid role, the full four-role regression guard, and the stale-SHA path.

- **`scripts/pipeline-vcs.sh` `_github_api` `read-attempt` / `check-approval-sha`: paginate issue comments via Link header to find markers beyond comment #100 (#126).** Both verbs previously issued a single `GET /issues/N/comments?per_page=100` with no pagination. A marker at position #101+ was silently omitted: `check-attempt` then saw `count=0` (below every ceiling) and exited 0, letting `max_fix_attempts` and `max_total_dispatches` be exceeded without detection. Fix: new `_ga_fetch_all_comments` helper follows `Link: rel="next"` headers until exhausted. Both `read-attempt` and `check-approval-sha` use it. Secondary: normalization now uses `(c.get('user') or {})` to handle `"user": null` (deleted account) without AttributeError. Stub extended with `CURL_LINK_QUEUE` for Link-header simulation; four new regression tests cover the paginated-marker, null-user, ceiling-enforced-on-page-2, and <100-comment-unchanged paths.

- **`tests/run-tests.sh`: add source guard; `tests/helpers.sh`: add warning comment above `make_sandbox` (#121).** Sourcing `run-tests.sh` instead of executing it caused `make_sandbox` to run in the caller's shell: the call `cd "$SANDBOX"` changed the caller's CWD to a temp directory, and the EXIT trap deleted that directory on the subprocess's exit, stranding the caller in a path that no longer existed. Fix: a `BASH_SOURCE[0]` guard at the top of `run-tests.sh` prints `ERROR: do not source run-tests.sh; use: bash tests/run-tests.sh` and returns 1 when the file is sourced. A warning comment above `make_sandbox` names the constraint explicitly. New test file `tests/test-sandbox-cwd.sh` (5 assertions): T1/T2 confirm the sandbox directory is removed by the EXIT trap (on clean exit and on failure); T3 confirms that bash-executing a test file does not change the caller's CWD; T4 confirms `run-tests.sh` returns non-zero and emits ERROR when sourced; each assertion names the mutation that would turn it RED.

- **`scripts/pipeline-vcs.sh` `label-pr` default-path warning: replace `check-approval-sha` call with direct comment read, eliminating the read-after-write race (#115).** The post-dispatch approval-marker warning (added in #94) called `bash "$0" check-approval-sha` immediately after applying the label. `check-approval-sha` re-reads PR labels via `gh pr view --json labels`; if the newly-added label had not propagated by the time that read landed, the check saw only pre-existing labels (all with valid markers) and returned 0 — the warning never fired for the label just applied. Fix: replace the `check-approval-sha` sub-invocation with a direct fetch of `headRefOid,comments` only. Labels are never re-read; `_ADDING_APPROVAL_LABELS` (set locally from the command arguments) is the source of truth for which roles to check. For each role, the block greps comments for `talos:approval sha=<head> role=<role>` — the same pattern the `--require-marker` pre-apply path already uses. No timing dependency remains. New tests: `race-sim` asserts WARNING fires even when `STUB_PR_LABELS_JSON=[]` (simulates propagation lag — this assertion was RED on the pre-fix code); `wrong-sha-marker` asserts WARNING fires when a marker exists but with a stale SHA; `marker-present` asserts no WARNING when the correct marker is present; `non-approval-label` asserts no marker check runs for non-approval labels. Stub extended with `--json headRefOid,comments` pattern.

- **`scripts/pipeline-vcs.sh` `check-closing-keyword` sibling scan: add `GH-N` and own-repo issue URL reference forms (#113).** The sibling body-match pattern (`body_pat`) previously recognised only the `owner/repo#N` qualified form and bare `#N`. Two reference forms that `has_closing` gained in #73 and #88 — `GH-N` (case-insensitive, digit-boundary guarded) and `https://github.com/<owner>/<repo>/issues/N` (scoped to current repo) — were absent from the sibling scan, so a hand-written sibling PR using either form would bypass the merge guard silently. Fix: `body_pat` becomes a four-branch alternation adding `gh_pat` and `url_pat`, using boundary guards identical to those in `has_closing`. Both the `_github` and `_github_api` provider copies are updated. Nine new tests cover both forms, boundary guards, case-insensitivity, and the foreign-repo exclusion; all nine showed RED on the original code.

- **`tests/test-marker-contract.sh`: also enforce shared marker contract on repo-level `.claude/agents/<role>.md` overrides (#110).** The test previously covered only the four plugin-shipped profiles in `agents/`; a consumer repo that placed `.claude/agents/security.md` without the shared Rules block would pass silently, reintroducing the gap closed by #85. Fix: a new repo-level override section iterates the four review roles (reviewer, security, qa, docs). When `.claude/agents/<role>.md` exists, the test extracts its Rules block (via the same extract_rules_block helper) and asserts byte-identity with the canonical shipped hash. A missing Rules block fails loudly, naming the file. A role with no override file skips with a pass. Four new assertions cover each role; header comment now states the two-tier coverage explicitly.

- **`skills/pipeline/SKILL.md` Step 2: `issues.label_filter` now uses AND-logic with `pipeline:ready` (#118).** Setting `label_filter` to any non-default value previously caused Talos to queue issues that silently never progressed — SKILL.md line 289 said "list issues matching `label_filter`" (configurable) while line 294 said "filter for issues with `pipeline:ready`" (hardcoded), a direct contradiction. The fix: Step 2 now states that an issue enters the queue when it carries `pipeline:ready` AND the configured `label_filter` label. When `label_filter` is `pipeline:ready` (the default), the two conditions collapse to one — existing configs are byte-identical to today. When `label_filter` is a custom value (e.g. `team:alice`), only issues carrying both labels are queued. Issues that carry only the custom label never silently stall. No changes to `pipeline-vcs.sh`, config defaults, or stage gates (lifecycle labels remain `pipeline:ready`-anchored).

### Added

- **`scripts/pipeline-vcs.sh` `_github_api` provider: parity with `_github` — six missing verbs added (#75).** `_github_api` now exposes all 25 verbs that `_github` does. Added: `pr-head` (REST `GET /pulls/{n}` → `head.sha`), `read-attempt` (REST comments with REST→gh normalization), `record-attempt` (read + POST comment via `_ga_req`), `check-attempt` (delegates to `read-attempt`, ceiling arithmetic), `check-approval-sha` (two REST calls assembled into gh-compatible shape; full waiver and invariant logic copied verbatim), `check-closing-keyword` (closing-keyword regex + sibling scan via REST). All six share the same fail-closed semantics and dry-run output as their `_github` counterparts. REST comment responses are normalised (`user.login` → `author.login`, array → `{"comments":[...]}`) before the shared Python blocks run, so the blocks are copied verbatim with no divergence risk. `# INVARIANT (issue #79)` comments added to both `_github` and `_github_api` copies of `read-attempt` and `check-approval-sha`, immediately before the unconditional last-line check, making the ordering constraint explicit and diff-visible to future maintainers. New `tests/test-verb-parity.sh` parses both provider `case` statements, computes the symmetric difference, and fails if any verb is present in one adapter but absent from the other (with `# PARITY-EXCEPTION:` as an opt-out allowlist). New tests in `tests/test-github-api.sh` cover all six verbs plus the `label-pr` → `check-approval-sha` routing gate; all 28 test files passed.

- **`scripts/pipeline-isolation.sh` + `execution.isolation` config key: configurable working-copy strategy (#98).** Isolation strategy is now configurable rather than hardcoded to `worktree`. Three modes are defined: `worktree` (default, byte-identical to today — absent key keeps all existing configs working), `branch` (stages run in the orchestrator's checkout on a per-issue branch, serialized by enforcing `issues.max_parallel: 1` at startup), and `checkout` (recognised but refused with a clear "not yet implemented" message). An unknown mode name is also refused with a list of valid values. The startup gate lives in a new script, `scripts/pipeline-isolation.sh validate`, called by the orchestrator immediately after config is read; a `max_parallel > 1` + `branch` combination is a loud startup failure, not a silent corruption. Under `branch` mode the orchestrator calls `bash scripts/pipeline-vcs.sh assert-sync` (the guard added in #93) before dispatching the developer — a dirty or stale tree blocks the issue rather than corrupting the run. Worktree reaping (`pipeline-worktree.sh remove/sweep`) remains unconditional and idempotent; in non-worktree modes it is confirmed to be a safe no-op. Rule 15 in `skills/pipeline/SKILL.md` is restated from an isolation-axis framing to a HEAD-ownership framing: *"Only the developer stage may move HEAD in the orchestrator's checkout. All other stages must never run `git checkout`, `git switch`, or `git pull` in their working directory — read diffs via `diff-pr` only. This holds regardless of `execution.isolation` mode."* Rule 18 is updated to clarify that `TALOS_WORKTREE_PATH` is not meaningful under `branch`/`checkout` — skip or warn, do not fabricate a path. 14 new tests in `tests/test-isolation.sh` cover all acceptance criteria and showed RED before the implementation and GREEN after.

### Fixed

- **`scripts/pipeline-isolation.sh`: refuse non-numeric `issues.max_parallel` instead of silently accepting it (#120).** The previous guard `[ "$MAX_PARALLEL" -gt 1 ] 2>/dev/null` swallowed bash's "integer expression expected" error when `$MAX_PARALLEL` was non-numeric; the comparison failed, the guard did not fire, and a malformed value was accepted as if it were `1`. Since `max_parallel: 1` is the load-bearing serialization guarantee for `branch` mode (see #98), silently accepting a malformed value eroded a safety-critical check. Fix: a `case`-based integer guard is inserted immediately after the `MAX_PARALLEL=` assignment, before the `case "$ISOLATION"` dispatch — so it fires in all modes, not only `branch`. Non-numeric or empty values exit 1 with a message that names the offending value: `ERROR: issues.max_parallel must be an integer — got: 'two'. Fix the config and retry.` The now-redundant `2>/dev/null` is removed from the `-gt 1` comparison. An absent config key returns `"1"` via the default argument to `pipeline-config.sh`, so a legitimate missing key is never refused. Six new tests (assertions 9–12 in `tests/test-isolation.sh`) cover all new paths and showed RED before the fix from wrong behaviour (silent exit 0), not from absence.

- **`.gitignore`: add `.claude/worktrees/` to prevent `assert-sync` from aborting on the orchestrator's own checkout (#119).** `assert-sync` (added in #93, wired into the pipeline skill in #114) fires immediately before Phase 2 reviewer dispatch. With `isolation: worktree` (the default), Talos creates `.claude/worktrees/<agent-id>/` in the repository root; because that path was absent from `.gitignore`, `git status --porcelain` always reported it as untracked. The dirty-tree guard fired on every issue, set `pipeline:blocked`, and skipped the review — making the guard that exists to prevent stale-source reviews prevent reviews entirely. Fix: add `.claude/worktrees/` to `.gitignore` (ephemeral build artifact, never content). The dirty-check logic in `assert-sync` is unchanged — a genuinely dirty tree (edited tracked file or unrelated untracked file) still exits 1 and names the files. Three new tests in `tests/test-assert-sync-worktrees.sh` cover the regression (RED before fix, GREEN after), the genuine-dirty guard (proves it was not weakened), and the clean-checkout exit-zero proof.

- **`scripts/pipeline-vcs.sh`: enforce approval markers at the point of action (#94).** Two interface gaps that caused three distinct roles to post invalid or absent approval markers across multiple PRs are now closed. (1) `comment-pr`/`comment-issue` now reject a positional body that is a readable absolute path (exit 1, `--body-file` hint on stderr) — the security stage passed a file path twice and received exit 0 both times, silently posting a one-line path as the comment. A body that looks path-like but does not resolve to a readable file is still posted as literal text. (2) After `label-pr` successfully adds a recognised approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`), the script calls `check-approval-sha` internally; if no current-head marker exists, it prints a loud WARNING to stderr naming the exact `comment-pr` command needed, then exits 0 so existing label-then-stamp call sites continue working. A new `--require-marker` flag makes the check fatal and pre-apply: it verifies the marker exists before applying the label, exits 1 if absent. Both guards apply in the provider-agnostic normalisation block (Cause 2 covers both `github` and `github-api`; Cause 1 is `github`-only, mirroring `check-approval-sha`). 42 new tests in `tests/test-approval-markers.sh` cover all criteria for both providers, showed RED before the fix and GREEN after; no existing test was modified.

- **`scripts/pipeline-vcs.sh` `check-closing-keyword` sibling scan: scope `body_match` to the current repository (#91).** The sibling-scan Python block matched a bare `#N` anywhere in another PR's title or body, including `other-owner/other-repo#N` in a foreign-repository reference. An unrelated PR mentioning a same-numbered issue in a different repository was counted as a sibling, producing a false-positive merge block (fails closed, never a bad merge). The fix passes `$REPO` as a third positional argument to the Python block and builds a two-branch alternation: (1) own-repo qualified form `owner/repo#N` (current repo only, case-insensitive); (2) bare `#N` not preceded by a word character or slash — preserving the intentionally loose match that catches sibling PRs using "Part of #N" without a closing keyword. The `(?:^|/)issue-N(?:-|$)` branch-name matcher is unchanged (branch names are local to the repository). The top-of-function `[ -z "$REPO" ]` guard already returns `reason=repo-unresolved` before the sibling scan is reached; no new empty-REPO guard is needed.

- **`agents/reviewer.md`, `agents/security.md`, `agents/qa.md`, `agents/docs.md`: marker-contract Rules block is now byte-identical across all four review-stage profiles (#103).** Three asymmetries introduced in PR #99 are resolved: (1) `reviewer.md` and `security.md` lacked the `(Contrast: create-pr/create-issue take a body file.)` note on the `comment-pr` bullet — its absence directly explains the PR #92 failure where the security stage passed a filesystem path to `comment-pr` and the comment landed as a one-line path; (2) `qa.md` and `docs.md` had the `git rev-parse HEAD` prohibition inlined in the SHA bullet rather than as a standalone bullet, matching the structure of the other two profiles; (3) `docs.md`'s preamble stated only the post-push timing rationale for `pr-head` without the universal justification (`correct regardless of checkout state, isolation mode, or timing`) that the other three carry — the timing instruction is preserved as docs is the only stage that commits. A new `tests/test-marker-contract.sh` extracts and normalises the shared Rules block from all four profiles, hashes each, and asserts byte-equality; it showed RED with 2 failures on the pre-patch state and GREEN (8 passed, 0 failed) after the patches.

### Added

- **`scripts/pipeline-vcs.sh` new verb `assert-sync`: orchestrator stale-checkout guard (#93).** Non-worktree-isolated stages (reviewer, security) read the orchestrator's working tree; a stale tree silently feeds them wrong source, producing false BLOCKs (observed on PR #92) or false approvals (unobserved; the dangerous direction). The new verb checks in order: (1) dirty tree — refuses immediately before fetching, names dirty files, tells user to commit or stash; (2) `git fetch origin`; (3) behind `origin/<base_branch>` — exits 1 naming both SHAs and the gap count; (4) diverged — exits 1 with an explicit warning against force-push; (5) ahead-only — exits 0 with a stderr warning naming the base branch and commit count so operators know non-isolated stages will read unpushed commits; (6) clean and level — exits 0, no output. `base_branch` is resolved via config key then `git symbolic-ref refs/remotes/origin/HEAD`, never hardcoded to `main`. A comment in the implementation distinguishes the internal `git rev-parse HEAD` use ("what is my working tree at?") from the `pr-head` verb ("what does the PR point at?"), so future maintainers do not confuse the two or read it as contradicting the `rev-parse` prohibition in agent profiles from PR #99. Two call sites added to `skills/pipeline/SKILL.md`: end of Step 0 (VCS mode only) and immediately before Phase 2 of section 3e (before reviewer and security dispatch, after docs completes).

- **Per-agent environment identity: `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` (#54).** Concurrent agents (`issues.max_parallel > 1`) share one compose project and scratch directory; verify scripts had no way to detect they were running in the wrong environment, producing silently incorrect results. Two new exports make degraded runs visible:
  - **Adapter path (`subagents: false`, `pipeline-agent.sh`):** `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` are now exported alongside `TALOS_ROLE` to every `runner_cmd`. Callers set `TALOS_ISSUE=<N>` in the environment; two-arg callers that do not set it receive `TALOS_ISSUE_NUMBER=""` (empty string, not unset), which lets verify scripts distinguish "Talos did not set this" from any real issue number. Backwards compatible: existing two-arg callers are unchanged.
  - **Native path (`subagents: true`, Claude Code):** The task prompt for worktree-isolated stages (developer, QA) now includes the issue number and worktree path and instructs the stage to `export` them before running `verify:` commands. This is instruction-based and not airtight — a stage that ignores the instruction still runs verify without the exports.
  - **`SKILL.md` Rule 18** added: worktree-isolated stages must export both values before any `verify:` command; honest documentation that the native-path mechanism is instruction-based.
  - **`SKILL.md` concurrency warning** added after the `issues.max_parallel` config default: explains the compose-stack failures, provides a self-check pattern, and states that `COMPOSE_PROJECT_NAME` and port offsets are derived by consuming projects from `TALOS_ISSUE_NUMBER` — Talos does not supply derived values.
  - Consuming projects derive `COMPOSE_PROJECT_NAME` via `talos-$TALOS_ISSUE_NUMBER`. Talos supplies identity, not infrastructure conventions.
  - **`TALOS_ISSUE` input validation:** `pipeline-agent.sh` now rejects non-integer values with exit 2 and a diagnostic before the runner is invoked. Empty (unset `TALOS_ISSUE`) is still accepted and exported as `""`. Digits-only values pass unchanged. This is a hard failure — callers that set `TALOS_ISSUE` to a non-numeric string (e.g. from a script that constructs the value incorrectly) will see exit 2 rather than silently passing a potentially unsafe value to runner_cmd.

- **`skills/pipeline/SKILL.md` Rule 17: foreground-only execution (#58).** Agents must never append `&`, use `nohup`, or call `disown`; polling with `until ! pgrep …; do sleep N; done` is also forbidden. Stranded background children cause the harness to fire duplicate completion notifications when they exit — observed at 210 stranded shells peak, with one agent generating 5 spurious signals 90 minutes after finishing; Talos cannot suppress the harness-side notification and can only prevent background children from being created.

- **Per-role model selection for native subagents (`agents.model`, `agents.roles.<role>.model`) and `TALOS_ROLE` export for adapter path (#96).** Two changes that together enable mixed-model pipelines without a human routing each stage:
  - **Native path (`subagents: true`, Claude Code):** Two new config keys control which model the orchestrator passes when spawning each subagent. `agents.model` sets a global model for all stages; `agents.roles.<role>.model` overrides it for a specific role. Resolution: role-specific → global → absent (omit `model:` entirely, Agent SDK inherits the session default). Backwards compatible: a config with neither key behaves byte-identically to prior versions.
  - **Adapter path (`subagents: false`, Codex / Gemini / custom):** `TALOS_ROLE` is now exported to every `runner_cmd` invocation, so a `case "$TALOS_ROLE"` statement can route implementation roles to a local model and review roles to a quality model without a wrapper script.
  - **`SKILL.md` updated** to instruct the orchestrator to resolve and pass the model before each Agent spawn.
  - No schema change required for existing configs. A config with no `agents.model` and no `agents.roles:` block continues to work exactly as before.

- **`pipeline-vcs.sh` built-in `merge.forbidden_files` defaults extended to 20 patterns (#78).** Added `*.pkcs12` (PKCS#12 bundles under the alternative extension), `*.kdbx` (KeePass databases), and `*.ovpn` (OpenVPN profiles, which frequently embed inline private keys) as wildcard patterns. Added `.netrc` and `_netrc` (plaintext credential stores; Windows spelling) as literal patterns — these were previously deferred pending the literal-pattern canary fix in #76 (PR #90, commit b1d3199). The stale deferral comment has been removed from both the `github` and `github-api` providers and replaced with a note that literal deny patterns now generate canaries. Not added: `*.gpg` (encrypted-at-rest workflow used by `pass`/SOPS/git-crypt is a legitimate use case), `*.asc` (detached signatures routinely committed as public artifacts), `*.der` (DER encodes public certificates as well as private keys). Both providers remain byte-for-byte identical (#75).

### Fixed

- **`scripts/pipeline-vcs.sh` `check-approval-sha`: routine base-branch syncs no longer falsely invalidate approval markers (#102).** The gate previously computed `git diff <marker_sha>..<head_sha> --name-only`, which included every file that arrived via a `git merge origin/main` sync — not just files the PR itself changed. A non-waivable file in any previously-merged PR would trigger STALE for all current approvals even when the PR's own content was unchanged (observed on PR #99: `scripts/pipeline-vcs.sh` and `tests/test-closing-keyword.sh` from #97 invalidated all four approvals). The fix intersects the `marker_sha..head_sha` diff with the PR's own file set, computed via `git diff --name-only origin/<baseRefName>...<head_sha>` (three-dot diff). Files that arrived purely from the base branch are absent from the three-dot set by construction and are excluded from the stale evaluation. `baseRefName` is fetched as part of the existing `gh pr view --json` call; no marker format change is required. Fail-closed guarantees preserved: (1) a genuine post-approval edit to a non-waivable path still invalidates; (2) a file touched by both the PR and the sync remains in the three-dot set and is evaluated normally; (3) if the three-dot diff call fails, the filter is skipped and the full `changed` set is evaluated (conservative / pre-fix behavior). The stale-approval message format is byte-identical to the previous version.

- **`scripts/pipeline-vcs.sh` `check-approval-sha`: error message for abbreviated SHAs now names `pr-head` as the correct SHA source (#101).** The remediation text in the abbreviated-SHA rejection path previously told stages to use `git rev-parse HEAD`, contradicting PR #99 which updated all four agent profiles to prohibit that command. The message now reads: `the {role} stage must obtain the SHA via pipeline-vcs.sh pr-head <PR>, not git rev-parse HEAD (which returns whatever commit is checked out locally)` — backticks are omitted from the message text because this Python block runs inside a double-quoted bash string and bash would perform command substitution on them. The 40-hex format check is unchanged. A new regression test asserts the remediation text so this cannot silently drift again.

- **`skills/pipeline/SKILL.md`, `agents/docs.md`: docs stage now runs before reviewer and security to eliminate concurrent-write race (#89; observed in PRs #80 and #87).** Docs commits and pushes to the branch; reviewer and security are read-only. Running all three in parallel meant a developer fix dispatched after a review block could collide with an in-flight docs push. Docs now runs first (phase 1); reviewer and security run in parallel after docs completes (phase 2). Rule 15 is corrected to classify docs as worktree-isolated. The `agents/docs.md` preamble no longer states the change is approved, since docs runs before review.

- **`agents/reviewer.md`, `agents/security.md`, `agents/docs.md`, `agents/qa.md`: all four stages now carry explicit approval-marker instructions (#85).** All four profiles were silent on how to obtain the approval-marker SHA and how to post the marker; agents improvised and produced wrong results (PR #84 security stamped main's SHA; PR #95 QA stamped main's SHA despite worktree isolation). Each profile now instructs the stage to obtain the SHA via `bash scripts/pipeline-vcs.sh pr-head <PR>` — which queries GitHub's API and is correct from any working-directory context regardless of isolation mode — and to pass the body as a string (not a filename) to `comment-pr`. The profiles also state that the marker must be the last non-whitespace line of the comment, that the full 40-character lowercase SHA must be pasted exactly as printed (abbreviated or uppercase SHAs are rejected by `check-approval-sha`), that adding an approval label does not satisfy the gate (the marker comment is separate and mandatory), and that `check-approval-sha <PR>` must return `rc=0` after posting. `skills/pipeline/SKILL.md` is unchanged — its stage prompts already used `pr-head` correctly.

- **`pipeline-vcs.sh` `check-closing-keyword`: foreign-repository issue URLs and `owner/repo#N` shorthand are no longer treated as closing the local issue (#88).** `ref_url` now requires the owner/name segments to match the resolved repo (case-insensitive). The `owner/repo#N` form of `ref_hash` is similarly scoped; bare `#N` and single-segment `repo#N` are unchanged. `$REPO` is passed to Python as a positional argument — no second `gh repo view` call. If `$REPO` is empty at gate entry, the gate emits `talos:closing-keyword-unverified … reason=repo-unresolved` and returns 0 (fail open), consistent with the existing `pr-fetch-failed`/`sibling-fetch-failed` precedent.

- **`pipeline-vcs.sh` `check-approval-sha`: fabricated marker SHAs now produce a clear diagnostic instead of a confusing git error (#81).** When a marker names a SHA that does not exist in the repository, the gate previously reported `git diff failed: fatal: Invalid revision range …` — a message that implies a tooling or environment problem. The gate now probes the SHA with `git cat-file -e <sha>^{commit}` before attempting the diff and emits a distinct message: `marker SHA <sha> does not exist in this repository — the <role> stage posted an invalid SHA; it must re-run and re-post its marker using a SHA read from git, not reconstructed`. Abbreviated SHAs (fewer than 40 hex characters) are now rejected at parse time with `marker SHA <sha> is not a valid 40-character commit SHA`; an abbreviated SHA can expand to the wrong commit, so the full 40-character form is required. Fail-closed behavior and the stale-approval message for real (existing) SHAs are byte-identical to the previous behavior.

- **`pipeline-vcs.sh` allow-list validation: wildcard allow entries that match a literal deny pattern canary are now REJECTED (#76).** Previously, canaries were only generated from wildcard deny patterns; literal deny patterns (e.g. `.env`) had a skip guard and generated no canaries, so a wildcard allow entry such as `*.env` or `?env` could silently defeat `.env` and pass validation. The fix removes the skip guard and generates three canary forms for every literal deny pattern (root, `sub/dir/`, `config/`) tagged with the source pattern. An allow entry that exactly equals the literal deny pattern (exact string, case-sensitive) is still permitted as a deliberate operator override; any other entry that matches a literal-pattern canary is rejected. Both provider blocks (`~441` github, `~1747` github-api) are changed identically.

- **`pipeline-vcs.sh` `check-closing-keyword`: now recognises `GH-N` (case-insensitive) and full GitHub issue URL (`https://github.com/<owner>/<repo>/issues/N`) as closing references (#73).** Both new forms carry the mandatory `(?!\d)` right-guard so `GH-571` does not collide with issue 57. `GH-N` also carries a `(?<![0-9])` left-guard. The unconfirmed colon form (`Closes: #N`) is deliberately excluded. Paired positive/negative tests added to `tests/test-closing-keyword.sh`.

- **`skills/pipeline/SKILL.md`: all 21 call sites for `comment-issue`, `comment-pr`, `create-issue`, and `create-pr` now include explicit failure handling (#83).** The two canonical capture forms at the top of the Rendering recipe now carry `|| { ... }` guards so the exit-status contract is visible in the template agents copy first. Every bare invocation inside a stage prompt gains a terse follow-on instruction specifying what the stage must do when the POST fails: for `create-pr`, stop and set `pipeline:blocked`; for comment/issue verbs, surface the failure in the final message without asserting the filing landed. A new Rule 16 states the exit-status contract and the URL-proof requirement explicitly. A new test (`tests/test-callsite-guard.sh`) fails if the canonical guards are removed.

- **`pipeline-vcs.sh`: `comment-issue`, `comment-pr`, `create-issue`, and `create-pr` now exit non-zero when the underlying POST fails (#69).** Previously, subshell-capture assignments (`_ci_url="$(gh …)"`, `_gaci_resp="$(_ga_req POST …)"`, etc.) absorbed non-zero exit codes silently — the script has `set -uo pipefail` but NOT `set -e`. Appending `|| exit 1` to each of the six POST assignments (lines 207, 322, 1308, 1394, 1429, 1613) makes failures propagate immediately, before any URL echo or `talos:comment-state-unverified` marker. Also fixed the same pattern in `create-issue` and `create-pr` on the `github-api` provider (lines 1394 and 1429), which share the identical bug shape.

- **`pipeline-status.sh`: issues always appear on the board even when a required status option is missing (#67).**
  Three related fixes:

  1. **Item-add before option-ID lookup** — the item is now added to the project board _before_
     the option-ID lookup can exit. Previously, when a status such as `Blocked` was absent from
     the board, `pipeline-status.sh` exited 1 before calling `gh project item-add`, so the issue
     never appeared on the board at all. The new order guarantees the issue is always present (in
     the project's default column), even when the status column does not exist.

  2. **`board.status_map` config key** — a new optional flat object under `board` maps pipeline
     status display names to the operator's actual column names.  Example:
     `board.status_map: {Blocked: "Needs attention"}`.  An absent key passes through unchanged;
     an absent map produces zero behavioural change.  The four required statuses are validated
     after `status_map` substitution, so a mapped name is checked against the board, not the
     default pipeline name.

  3. **`talos:board-unverified` marker** — on the first `pipeline-status.sh` call of a run, the
     script fetches the board's Status field options and checks that all four required statuses
     (`In progress`, `In review`, `Done`, `Blocked`, after `status_map` substitution) exist.  If
     any are missing, `talos:board-unverified project=<N>` is emitted on stdout and a detailed
     warning (naming the missing options) is written to stderr; the script exits 0 (board
     failures are warnings by design, Rule 11).  A sentinel file in `${TMPDIR:-/tmp}` keyed on
     project number (and `PIPELINE_RUN_ID` when set) ensures the validation fires at most once
     per run and caches the field-list response so `gh project field-list` is called exactly once
     regardless of how many status updates happen in the same run.

  4. **Secure sentinel cache location** — the sentinel/cache file is now stored in a user-private
     directory (`${XDG_RUNTIME_DIR:-$HOME/.cache}/talos/`) instead of `${TMPDIR:-/tmp}`, which is
     world-writable and allowed any local process to pre-create a poisoned file.  The directory is
     created with mode 0700 (`install -d -m 700`) and the file is written with mode 0600
     (`umask 177`).  Before trusting a cached file the script verifies: (a) it is a regular file,
     (b) it is owned by the current user (checked via `python3 os.stat` for BSD/GNU portability),
     (c) it has no group/world-write bits, and (d) it contains valid JSON with the expected
     `{fields:[{name,id,options:[]}]}` shape.  Any check failure falls back to a fresh
     `gh project field-list` call — degrade to correct-but-slower, never to trusting untrusted
     content.

- **`pipeline-vcs.sh`: `check-approval-sha` and `read-attempt` reject quoted/fenced markers and gain an author allow-list (#66).**
  Two independent fixes applied together:

  **Part B — last-line enforcement in `check-approval-sha`:** `check-approval-sha` previously accepted a
  `talos:approval` marker that appeared anywhere in a comment body, including inside a GitHub "Quote reply"
  block.  The fix applies the same last-line rule that `read-attempt` already enforced: the marker must be
  the final non-whitespace line of the comment body.  A quoted or fenced occurrence is now silently skipped,
  not accepted.  The false code comment that claimed the guard already existed in `check-approval-sha`
  ("same guard as `talos:approval`") has been removed — after this fix the guard genuinely exists in both
  readers and no misleading comment is needed.

  **Part A — author allow-list (`markers.trusted_authors`):** A new config key `markers.trusted_authors`
  (YAML list of GitHub login strings, e.g. `["talos-bot"]`) gates which accounts may post a winning marker
  for both `talos:approval` and `talos:attempt` types.  When configured and non-empty, a marker from any
  login not in the list is skipped (for `read-attempt`) or counted as stale (for `check-approval-sha`),
  with a diagnostic message to stderr.  When absent or empty the author check is skipped (fail-open) so
  existing installations with no config change are not broken; both readers then emit
  `talos:marker-authors-unverified reader=<verb>` on stdout so the skip is observable.

  Both fixes are unconditional with respect to each other and apply to the single copy of each reader in
  `pipeline-vcs.sh` (no separate `github-api` copies exist for these verbs).

- **`pipeline-vcs.sh`: `check-pr-files` default deny list now blocks SSH private keys and Java/Android keystores (#63).**
  Added 7 new wildcard patterns to `_BUILTIN_DEFAULTS` in both the `github` and `github-api` providers (byte-identical):
  `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`.
  These catch extensionless SSH private key files (`id_rsa`, `id_ecdsa`, `id_ed25519`, `id_dsa`) as well as
  path-prefixed and custom-named variants (`deploy_id_rsa`, `.ssh/id_rsa`, `id_rsa.bak`), PuTTY private key
  files (`*.ppk`), and Java/Android keystores (`*.jks`, `*.keystore`).
  **Accepted trade-off:** `*id_rsa*` also matches `id_rsa.pub` (a harmless public key). `fnmatch` has no negative
  lookahead, so blocking the public key is the cost of catching the private key with a single pattern. Operators
  who legitimately commit public keys should add the specific filename to `merge.forbidden_files_allow`.
  **Over-blocking note:** `*.keystore` may also match self-signed test keystores committed for CI use — `fnmatch`
  cannot distinguish a real keystore from a test one. This is expected behaviour; operators whose CI pipeline
  commits a test keystore should add the specific filename to `merge.forbidden_files_allow`
  (e.g. `["test.keystore", "debug.keystore"]`).
  **Note:** `.netrc` and `_netrc` were deferred at this release because literal patterns generated no canary. That
  blind spot is fixed in #76 (PR #90); both patterns are included in the defaults as of #78.

- **`pipeline-vcs.sh`: `check-pr-files` union semantics and canary fallback close compound gate bypass (#61, #64).**
  `merge.forbidden_files` now **unions** with the built-in defaults (`.env`, `.env.*`, `*.pem`, `*.key`,
  `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`) rather than replacing them wholesale.  Operators who
  genuinely need to narrow the list can set `merge.forbidden_files_replace: true`, which restores the
  old replacement behaviour and emits a stderr warning plus a `talos:forbidden-files-defaults-replaced`
  stdout marker on every run so the suppressed state is auditable.  A `talos:forbidden-files-active`
  marker is always emitted with the active pattern count and whether defaults are in force, so a
  neutered gate no longer looks identical to a real pass (#61).
  The allow-list canary generator now falls back to built-in canaries (`x.env`, `x.pem`, and
  subdirectory variants) when the deny list contains no wildcard patterns, so `merge.forbidden_files_allow: ['*']`
  is rejected even under an all-literal deny list rather than silently passing (#64).
  Both fixes are applied identically in the `github` and `github-api` providers; the `github-api`
  provider now also performs allow-list validation (it previously had none).
  The comment above the non-waivable path check in `check-approval-sha` is corrected to describe
  the real control flow (hard-coded paths are checked FIRST, then the config waiver).

- **`pipeline-vcs.sh`: anchored issue-number matching in `check-closing-keyword`, sibling lookup, and `find-pr` (all providers).**
  The closing-keyword regex now appends `(?!\d)` so `Closes #571` no longer falsely matches issue 57.
  The sibling lookup and both `find-pr` implementations (github and github-api providers) replaced
  substring `in` checks with anchored regex — branch names use `(?:^|/)issue-N(?:-|$)` and body
  text uses `#N(?!\d)` — so `fix/issue-571-x` is never treated as a sibling of issue 57, and
  `#71` in a body is not returned by `find-pr 7`.
  Includes 17 new regression tests in `test-closing-keyword.sh` covering the exact QA-failed case
  (`Closes #571` must not match issue 57) and the symmetric false-negative (`Closes #57` must still
  block when a sibling is open).

### Added

- **Closing-keyword gate: `check-closing-keyword <pr> <N>` in `pipeline-vcs.sh` (GitHub provider).**
  Blocks a PR from merging when its body carries a closing keyword (`Closes/Fixes/Resolves #N`,
  case-insensitive, all standard verb forms) while other PRs referencing the same issue are still
  OPEN — closing the tracker at that point would orphan in-flight sibling work.
  Implements Rule 6 enforcement: when the legitimate final PR of a multi-PR issue is ready to
  merge, all prior siblings are already merged (not open), so the gate passes cleanly.
  Fails open (exit 0) if PR body or sibling list cannot be fetched; emits a
  `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` marker on stdout so
  callers can detect the degraded run without parsing logs.
  No-op / exit 0 stub under gitlab, azure, and file providers.
  `view-pr` (GitHub provider) now includes `body` in its `--json` fields.
  SKILL.md Step 4 and Rule 6 updated to document the gate.
  Known limitation: a lone PR that overclaims its deliverables (no sibling PRs at all) cannot
  be detected — that requires a ledger, and nothing ticks one in VCS mode today.

- **Per-stage consecutive attempt counting with durable state (`record-attempt`, `read-attempt`, `check-attempt` in `pipeline-vcs.sh`).**
  Replaces the flat developer-dispatch counter (which lived only in orchestrator memory) with a durable HTML-marker comment on the issue:
  `<!-- talos:attempt stage=<blocking_stage> count=<k> total=<t> -->`.
  `record-attempt <issue-n> <stage>` reads prior state, computes the new per-stage count (resets when the blocking stage changes) and running total (never resets), posts the marker comment, verifies the write landed, and exits non-zero when either ceiling is reached.
  `read-attempt <issue-n>` prints the current state (or `stage= count=0 total=0` when no marker exists).
  `check-attempt <issue-n>` exits non-zero when either ceiling is already reached (read-only).
  New config key `limits.max_total_dispatches` (default: 8) provides the absolute per-issue ceiling; existing `limits.max_fix_attempts` (default: 3) now counts consecutive per-stage failures only.
  SKILL.md updated to call `record-attempt` at every QA/reviewer/security re-dispatch instead of counting in prose.
  Fail-closed: a corrupted or unparseable marker exits non-zero rather than silently resetting to zero.

- **Closed-target guard on `comment-issue` and `comment-pr` in `pipeline-vcs.sh`.**
  Both verbs now check the target's state before posting: a closed issue or a
  closed-unmerged PR causes a non-zero exit with the state printed to stderr.
  Use `--allow-closed` to opt in (required for the post-merge orchestrator summary,
  where GitHub auto-closes the issue via `Closes #N` before the comment runs).
  Merged PRs are always allowed — post-merge annotation is legitimate.
  If the state check itself fails (transient network error), both verbs proceed
  and print `warning: could not determine state` to stderr plus a machine-readable
  `talos:comment-state-unverified target=<issue|pr>#<N> reason=<short>` line on
  stdout so callers can detect the degraded run without parsing logs.

- **Comment URL returned by `comment-issue` and `comment-pr`.**  Both verbs now
  print the `html_url` of the posted comment to stdout (GitHub provider: via
  `gh issue comment --json url -q .url`; github-api provider: extracted from the
  POST response `html_url` field).  Callers can capture the URL for relay messages
  and audit trails without re-fetching.

- **`check-approval-sha` subcommand in `pipeline-vcs.sh`.** Verifies that every
  approval label present on a PR (`qa:pass`, `review:approved`, `security:approved`,
  `docs:done`) was earned against the current head SHA.  Each approval role now
  embeds an HTML marker `<!-- talos:approval sha=<HEAD_SHA> role=<role> -->` in
  its PR comment when posting a pass/approval verdict.  At Step 4, the orchestrator
  calls `check-approval-sha <PR>` before merging; a non-zero exit (stale label)
  triggers label stripping and re-dispatch of the affected stages.

- **`pr-head` subcommand in `pipeline-vcs.sh`.** Prints the current head SHA for
  a PR.  Used by approval roles to stamp the SHA they approved at comment time.

- **`merge.approval_waiver_paths` config key.** List of glob patterns
  (default `["*.md", "docs/**", "CHANGELOG.md"]`) for files that, when they are
  the only changes in the delta between an approval SHA and the current head, do
  not invalidate the approval.  Hard-coded non-waivable paths — `scripts/**`,
  `tests/**`, `talos.pipeline.yml`, `pipeline.yaml` — are enforced structurally
  after the config waiver and cannot be overridden by configuration.

### Security

- **SHA-scoped approval gate closes the stale-label attack surface.** Prior to
  this change a force-push after an approval left the label in place; the merge
  gate checked only label presence, not which commit the label was earned against.
  `check-approval-sha` is fail-closed: an unresolvable head SHA, a missing marker,
  or a `git diff` failure all exit non-zero and block the merge.  Waiver config
  entries that are too broad (catch-all or covering non-waivable paths) are
  rejected at validation time using the same canary approach as `check-pr-files`.



- **`_is_lane_home` guard in `pipeline-worktree.sh`.** `remove <N>` and `sweep` now refuse to delete a worktree that contains a `.talos-lane-home` marker file. The file is placed by the operator in every long-lived lane home (never committed); it never propagates to disposable per-issue worktrees. Prevents a sweep run from one lane from deleting another lane's working directory.

- **`_is_self` guard in `pipeline-worktree.sh`.** `remove <N>` and `sweep` now refuse to delete the checkout they are running from. In inline harnesses (`agents.runner: pi`) the developer stage works directly in the orchestrator's own checkout, which can match the per-issue branch pattern; removing it would destroy the running session. In subagent mode the guard is a no-op.

- **Multi-lane sweep interlock.** When more than one `.talos-lane-home` marker exists among a repo's worktrees, `sweep` exits 0 without touching anything (safe no-op). Set `TALOS_SWEEP_ALL_LANES=1` to override. The per-issue `remove <N>` verb is always unaffected. Prevents cross-lane sweep collisions in repos that share one remote across multiple pipeline lanes.

- **Lane-scoped `list-prs`.** `pipeline-vcs.sh list-prs` now passes `--base "$BASE_BRANCH"` (from `base_branch` config) to `gh pr list` and includes `baseRefName` in the `--json` field list. Without lane scoping, Step 1 reconciliation in a multi-lane repo can adopt another lane's open PR and merge it into the wrong base. This happened: the qwen-lane sweep merged a canonical-lane PR (base `main`) into `qwen`.

- **`merge.forbidden_files_allow` config key.** An explicit allow-list checked **before** the deny patterns in `check-pr-files`. Glob-matched against filename and full path. Solves the case where a deny pattern (e.g. `.env.*`) over-matches a committed template (`.env.example`) that cannot simply be renamed. See README for usage.

### Security

- **Semantic canary validation in `merge.forbidden_files_allow`.** Allow-list entries are now validated by testing them against canary paths derived from the active deny patterns using the same `fnmatch` rule the gate uses (basename AND full path). An entry is rejected if it would exempt any canary. This replaces the previous character-stripping approach, which caught `*` and `**` but was bypassed by `*/*`, `**/*`, `*[!x]*`, `[a-z]*`, and `config/*`. The validator generates three canary forms per deny pattern (root, nested `sub/dir/<name>`, and prefixed `config/<name>`) so it catches both basename-level and path-level bypasses. The gate fails closed on any invalid entry, naming the entry and the canary it would have exempted.

## [0.13.0] - 2026-08-15

### Fixed

- **The Buzz sink reported success for events the relay rejected.** `_buzz_publish` ran `nak` with `2>/dev/null` and branched on the exit code — but `nak` exits **0 even when the relay refuses the event**, and still prints the locally-signed JSON on stdout (it signs before publishing). So neither the exit code nor stdout distinguished delivered from dropped: a rejected post was recorded as sent and its id persisted as a thread anchor, leaving `~/.talos/threads.json` pointing at an event that was never stored.

  The failure is invisible in exactly the situation you most need it: a bot key that is unadmitted, revoked, or removed from a private channel produces a clean run and a silent channel. Found while configuring a fresh bot against a live relay — the sink "worked" through the entire setup while nothing had ever been delivered. The relay's verdict is only on stderr, so it is now captured and matched (`auth error` / `failed:` / `CLOSED:`), the reason is echoed, and a rejection no longer writes an anchor. Delivery still degrades softly: the script exits 0 regardless.

- **Tests were not hermetic and read the developer's real `~/.hermes/.env`.** `pipeline-notify.sh` scrapes that file for bot credentials, so on a machine with Buzz configured the suite picked up a real relay URL and bot key — inverting credential-absence assertions ("buzz without private key produces no buzz output" started finding a key) and making results depend on whose laptop ran them. `make_sandbox` now exports a sandbox-local `HOME`, seeded with a gitconfig so suites that commit still resolve an identity.

### Added

- **pi harness support — inline one-agent-per-turn mode.** Talos now runs on
  **pi** (a minimal single-agent coding harness) without subagents and without
  `pipeline-agent.sh`. New config `agents.subagents` (`auto` | `true` | `false`)
  selects the execution mode: `true` = native parallel subagents (Claude Code),
  `false` + `agents.runner: pi` = the pi session acts as each stage role itself
  (validator → pm → developer → qa → reviewer/security/docs → merge), one role
  per turn, waterfall handoff. `auto` = true when the runner is `claude`, else
  false. The canonical `pipeline` skill's Harness-compatibility section now
  spells out the inline rule (read the role profile body, act inline, post the
  handoff, relay, continue) so pi can follow it directly. Everything else —
  VCS, notifications, boards, skills, agent profiles — was already
  harness-agnostic plain bash/markdown.

- **`agents.runner: pi` case in `pipeline-agent.sh`.** Runs a single stage
  headlessly via `pi -p <prompt>` (print mode) when explicitly requested; the
  pi inline mode is the default for pi and does not call the adapter.

- **`notifications.buzz_relay` config key.** The relay URL is a hostname, not a secret, and identifies a deployment exactly the way `buzz_channel` does — but it was readable only from the environment, grouped in with the bot tokens, with no `cfg` lookup and no `PIPELINE_*` override. A repo therefore could not describe its own Buzz setup: a clone got the channel from the committed config and no relay, which (before the fix above) then failed silently. Precedence is env > repo/hermes `.env` > config, and `PIPELINE_BUZZ_RELAY` overrides. The bot **key** stays env-only — it is a full Nostr signing identity and must never enter a git-tracked file.

- **Buzz messages carry the context trailer.** Slack renders `$NCONTEXT` as a context block and Discord as an embed footer; Buzz sent bare template text, losing the `repo · role · #ref` provenance line. It is now appended as an italic CommonMark trailer, which `kind:9` renders. Colour has no `kind:9` equivalent and is still Slack/Discord only.

## [0.12.0] - 2026-08-13

### Fixed

- **Azure DevOps work items showed raw markdown as jibberish.** The `azure` adapter piped GitHub-flavored markdown bodies straight into a work item's `System.Description` — but that field (and work-item comments) render **HTML**, not markdown. So `# Heading`, `**bold**`, `- [ ]`, and pipe tables displayed as literal source on the board. This hit the planner hardest: every sub-issue it creates goes through `create-issue`, so an epic decomposition produced a board full of unreadable items.

  The mismatch is provider-specific and easy to miss because everything else in the pipeline is GitHub-first, where issue bodies *are* markdown and the host renders them. Azure was behaving correctly; the adapter was feeding the wrong format.

### Added

- **`_md_to_html` conversion in the azure adapter**, applied to `create-issue` descriptions and work-item comments (`comment-issue` / `close-issue`). It prefers `pandoc`, then the python `markdown` library, then a self-contained python3 converter (python3 is already a hard dependency of this adapter) covering headings, bold/italic, inline + fenced code, links, ordered/unordered lists, GFM checkboxes (☐/☑), and pipe tables. Bodies that already look like HTML pass through untouched, so it is safe to double-apply.

- **PR comment threads are deliberately left as markdown.** Azure PR threads *do* render markdown, so `comment-pr` is not converted — only the two work-item HTML fields are. The `comment-issue` dry-run now echoes the real (converted) body instead of a `<body>` placeholder, so the conversion is visible and testable.

- **Planner tags every sub-issue `epic:<N>`.** When an epic is decomposed, each created sub-issue now carries an `epic:<epic-number>` label (independent *and* dependent), so a human can filter the board to one epic and review its sub-tasks as a group. The existing `Part of #<N>` body line still drives the epic auto-close sweep; the tag is purely for human grouping/filtering.

## [0.11.0] - 2026-08-11

### Fixed

- **`comment-issue` / `comment-pr` silently discarded the body when given `--body-file`.** The provider branches took `"$2"` as the body verbatim, so `comment-issue 42 --body-file verdict.md` ran `gh issue comment 42 --body "--body-file"` — a comment whose entire content was the literal flag, the real text dropped, **and exit 0**. Nothing failed and nothing warned. Three subagent verdicts were lost in a single pipeline run (two validators and one QA), and they were only caught because two later agents read the issue and found the verdicts missing.

  The trap is in the verb list itself: `comment-issue <n> <body>` sits four lines from `create-pr <branch> <title> <body-file>`. One takes inline text, its sibling takes a path — so an agent composing a multi-KB markdown verdict reaches for `--body-file` by analogy, with this script's own siblings and with `gh`. Treating that as agent error misses the point; the interface invited it.

  Wanting a file is legitimate rather than lazy, which is why the fix accepts it instead of only rejecting it: long markdown is hostile as a shell argument (backticks, `$`, quotes, newlines), and a body containing raw URLs can be refused outright by a permission rule, leaving a file as the only route.

### Added

- **`comment-issue <n> --body-file <path>` and `comment-pr <n> --body-file <path>`** now work, alongside an explicit `--body <text>` form. Normalisation happens before provider dispatch, so github, github-api, gitlab, azure and file mode all inherit it. The verb list documents both spellings.

- **A body that is still a bare flag is refused with exit 1** and a usage message naming both accepted forms, rather than being posted. An unreadable `--body-file` path also exits 1 and names the path. A body that merely *starts* with a single dash — a markdown bullet — is still a body, and is asserted as such.

- 13 assertions in `tests/test-vcs.sh` covering both spellings, both refusals, the leading-dash case, and a regression check that non-comment verbs keep their own flag handling.

## [0.10.0] - 2026-08-11

Azure DevOps goes from **best-effort to a first-class provider**. The adapter was
exercised end-to-end against a live `dev.azure.com` org and every verb the
pipeline actually calls now works, plus GitHub-Projects-style board tracking.
`az`-CLI gaps are worked around with `az rest` against the ADO REST API.

### Fixed (Azure adapter — every one was a hard failure on a real org)

- **`list-issues` called `az boards work-item list`, which does not exist** — the
  pipeline's primary work-item discovery verb errored out. Now uses a WIQL query
  via `az boards query`, excluding ADO's terminal states (Done/Removed/Closed,
  not just Closed). (#45)
- **`create-pr` omitted `--repository`**, which `az repos pr create` requires — a
  live PR create failed. Now passes it. (#45)
- **`label-issue` used a nonexistent `--tags` flag.** Its `--fields System.Tags=`
  alternative *appends* (ADO merges tags on a json-patch "add"), so it could add
  but never remove. Rewritten to PATCH `System.Tags` with a json-patch "replace"
  via `az rest`. (#45)
- **`comment-issue` used `az boards work-item comment add`, which does not exist.**
  Now posts to the work-item comments REST endpoint via `az rest`.
- **`approve-pr` used `az repos pr comment add`, which does not exist.** Its
  optional comment now posts as a PR thread; the self-approve vote failure stays
  ignorable (the `review:approved` label is the gate).

### Added (Azure adapter — parity with the GitHub provider)

- **`create-issue` now opens a work item on ADO** (`az boards work-item create`),
  of the configured type in the configured area path, with `--label`s mapped to
  Tags. Previously it errored "not implemented — use the web UI". New config:
  `vcs.azure.work_item_type` (default `Product Backlog Item`) and
  `vcs.azure.area_path` (so pipeline-created items land on the right board).
- **Board status tracking on ADO.** `pipeline-status.sh` gained an Azure branch:
  a work item's **State** drives its Kanban column (ADO has no separate
  GitHub-Projects status field), so the pipeline moves the card as it progresses.
  Mapping is configurable via `board.azure_states.{ready,in_progress,in_review,done,blocked}`
  with Scrum defaults (New / Committed / Committed / Done / unchanged).
- **`label-pr` on ADO** (PR labels via `az rest`; `az` has no command for it).
  Remove resolves the label name to its id first — ADO rejects `:` in a URL path,
  and every pipeline label contains one.
- **`comment-pr` on ADO** posts a PR comment thread via `az rest`.
- **`diff-pr` on ADO** — resolves the PR's source/target refs and runs
  `git diff origin/<target>...origin/<source>`, reading the change without
  touching the working tree (safe for the non-worktree reviewer/security stages).
  Previously unsupported.
- **`checkout-pr` on ADO** now detaches (`git checkout --detach FETCH_HEAD`)
  instead of checking out the branch by name, which failed with "already checked
  out" while the developer worktree still held the branch.
- **`tests/test-providers.sh`** grew coverage for all of the above (create-issue,
  the az-rest comment/label paths, diff-pr, checkout-pr, and the status→State
  mapping), and the `az` stub honors `-o tsv` ref queries.

### Notes

- **Merges on ADO are human-gated by design.** A repo whose `main` has branch
  policies (minimum reviewers, build validation) cannot be auto-merged by an
  agent; run with `merge.auto: false` and let a human complete the PR. The
  pipeline still runs every stage and labels the PR `pipeline:approved`.
- **Still not implemented on ADO:** `find-pr`, `check-pr-files`, `rerun-ci`.

## [0.9.0] - 2026-08-07

### Added

- **`install.sh` now installs agent-skills too.** Since 0.8.0 the pack has been a hard requirement — the role profiles delegate their methodology to it rather than restating it — but only the *plugin* got it automatically. The vendored path printed a note and left the user to it, so the same product behaved differently depending on how you installed it, and the vendored install degraded silently if you skipped the note. It is now fetched into `<target>/.claude/skills/` by default; `--no-agent-skills` opts out and says what you give up. (#44, fixes #43)

  Only `skills/` is vendored — the roles invoke skills, never agents (they have no `Task` tool), so agent-skills' own agents would be dead weight in the target repo. `LICENSE` ships alongside as `AGENT-SKILLS-LICENSE`, since this is third-party MIT content landing in a user's repo, copied unmodified from upstream.

  Never fatal: no `git`, or an unreachable source, degrades the install with a clear message rather than aborting. The pipeline still runs; roles fall back to their embedded instructions. `TALOS_AGENT_SKILLS_REPO` overrides the source.

- **`tests/test-skill-names.sh`** — asserts every skill named in `agents/*.md` actually exists in agent-skills. Nothing else caught a typo'd or renamed skill: the role simply never invokes it and quietly falls back, with no error anywhere. This is the only test that needs the network, and it skips rather than fails when offline. All 15 current references verified.

- 11 assertions in `tests/test-install.sh` covering the vendoring, the licence, the opt-out, and graceful degradation on an unreachable source — run against a local fixture repo so the suite stays hermetic.

### Changed

- README gains a single note that Talos installs agent-skills for you, rather than a requirements section — the point is that it is never a manual step.

## [0.8.1] - 2026-08-07

### Fixed

- **Corrected a false claim about other harnesses.** 0.8.0 told every role that Codex, Gemini and Antigravity have no skill support. That is wrong: agent-skills ships `.gemini/commands`, `.opencode/skills`, a `.codex-plugin/` manifest and an `AGENTS.md` explicitly covering Claude Code, Cursor, Copilot and Antigravity. It is not Claude-Code-only, and it was the load-bearing argument in 0.7.0's case for *not* making it a dependency — an argument that should not have been made without checking. (#42, fixes #41)

  The fallback clause in all eight profiles now states the accurate condition: the dependency belongs to the **plugin** install, a vendored `install.sh` copy pulls nothing, and if the skills are absent the role follows its embedded steps. No harness is named as skill-less.

- `install.sh` now tells vendored users that the roles delegate to agent-skills, links upstream, and notes it supports Claude Code, Codex, Gemini, OpenCode and Antigravity — previously they were left to discover the degraded behaviour themselves.

### Added

- Assertions that no profile repeats the 0.8.0 claim, alongside the existing fallback check. 16 fail against 0.8.0.

## [0.8.0] - 2026-08-07

### Changed

- **`agent-skills` is now a required dependency of the plugin.** The role profiles delegate their methodology to those skills instead of restating it — which is why they are 20–60 lines rather than several hundred — so 0.7.0's "use it if available" left the pipeline's actual guidance up to chance. Installing Talos now pulls agent-skills automatically (`+ 1 dependency: agent-skills`); nothing to add by hand. (#40, closes #39)

  Two halves make this work, and they are only correct together: `dependencies: ["agent-skills"]` in `plugin.json`, and an `agent-skills` entry in Talos's `marketplace.json` sourced from `addyosmani/agent-skills`. Plugin dependencies resolve to a **marketplace-qualified id** — `agent-skills@talos` — so without the catalogue entry Talos fails to load outright, *even when agent-skills is already installed from Addy's marketplace*:

  ```
  Status: ✘ failed to load
  Error: Dependency "agent-skills@talos" is not installed
  ```

  The catalogue entry is byte-identical to the one in Addy's own marketplace and points upstream at `addyosmani/agent-skills` (MIT), unmodified. Talos does not fork or vendor it.

  **Known consequence:** anyone already using Addy's marketplace ends up with agent-skills registered twice, as `agent-skills@addy-agent-skills` and `agent-skills@talos`. Verified side by side — same version, no conflict, nothing errors. It is unavoidable for a cross-marketplace hard dependency; disable either one if the duplicate bothers you.

- **Every role now directs the model to use its skills** rather than treating them as optional, and the mapping widened from 9 skills to 16: `validator` adds `doubt-driven-development`; `developer` adds `git-workflow-and-versioning`, `code-simplification`, `frontend-ui-engineering`, `deprecation-and-migration`; `qa` adds `browser-testing-with-devtools`; `reviewer` adds `code-simplification`, `performance-optimization`. Skills are still named bare, so Claude Code built-ins and a repo's own `.claude/skills/` satisfy the same references.

- **Codex, Gemini and Antigravity are unaffected.** They install via `install.sh`, never the plugin, so the dependency does not reach them. Every profile carries an explicit fallback — use the skills where the harness has them, otherwise follow the embedded steps — and a test asserts all eight say so, because a mandate with no fallback would be a dead end on three of the four advertised harnesses.

### Added

- 9 more assertions in `tests/test-plugin-install.sh` (51 total): every role carries a mandatory skills clause, every role names the non-Claude fallback, the manifest declares the dependency, the marketplace catalogues it, and the catalogue entry points upstream rather than at a vendored copy. 19 fail against 0.7.0.

## [0.7.0] - 2026-08-07

### Fixed

- **All eight roles can now use skills.** Only `qa`, `reviewer` and `security` carried the `Skill` tool; `validator`, `pm`, `developer`, `docs` and `planner` did not. Any installed skill pack was therefore unreachable from five of the eight stages *no matter what the profile said* — including Claude Code's own `code-review` / `security-review`. The blocker was never a missing dependency; it was the tool grant. (#38, fixes #37)

### Added

- **Every role now names the skills it would benefit from**, guarded on availability: `validator` → `debugging-and-error-recovery`; `pm` → `spec-driven-development`, `api-and-interface-design`; `planner` → `planning-and-task-breakdown`; `developer` → `test-driven-development`, `incremental-implementation`, `debugging-and-error-recovery`; `qa` → adds `test-driven-development` to the existing `verify`/`run`; `reviewer` → adds `code-review-and-quality`; `security` → adds `security-and-hardening`; `docs` → `documentation-and-adrs`.

  Skills are referenced by **bare name, never by plugin**, so any provider satisfies them — a Claude Code built-in, a pack such as [agent-skills](https://github.com/addyosmani/agent-skills), or the repo's own `.claude/skills/`. Absent one, the role follows its embedded instructions silently.

- `developer` now states explicitly that it cannot spawn subagents, and should do the work itself where a repo's `CLAUDE.md`/`AGENTS.md` instructs delegating to a named agent. Talos roles *are* subagents and have no `Task` tool, so such a mandate would otherwise degrade silently.

- 18 new assertions in `tests/test-plugin-install.sh` (42 total): every role can invoke skills, every skill reference carries an availability guard, no role names a specific third-party plugin, and the manifest declares no `dependencies`. The five tool-grant assertions fail against 0.6.0.

### Changed

- The user guide's dependency FAQ is rewritten: still no dependency, and now explicit about *why* — a hard `dependencies` entry (a real manifest field that auto-enables what it names) would misrepresent Talos on the Codex, Gemini and Antigravity harnesses it advertises, where Claude Code skill packs cannot exist. Adds the per-role skill table and documents the `Task` limitation.

## [0.6.0] - 2026-08-07

### Fixed

- **The marketplace plugin now works at all.** 0.5.0 fixed the vendored install; the plugin path had never been functional. Four independent breaks (#36, fixes #35):

  1. **The plugin shipped none of the role agents.** Talos kept them in `.claude/agents/`; Claude Code loads plugin-shipped agents from `agents/` **at the plugin root**, and the manifest carried no `agents` override. A marketplace install therefore provided `/pipeline` and zero of the eight subagents it spawns. Role definitions moved to `agents/`, with `.claude/agents` left as a symlink so the Talos repo can still dogfood itself.
  2. **The scripts were unreachable.** `SKILL.md` resolved only `.claude/talos/scripts/` and `scripts/`; under a plugin install the repo has neither, since the scripts live in `~/.claude/plugins/cache/`. Both skills now resolve `$CLAUDE_PLUGIN_ROOT/scripts` → `.claude/talos/scripts` → `scripts`, and `pipeline-agent.sh` resolves role files the same way.
  3. **`"scripts": "scripts/"` was a no-op.** Not a recognized manifest field — Claude Code ignores unrecognized top-level fields. It read like it wired the scripts up, which is plausibly why break 2 went unnoticed. Removed.
  4. **The manifest failed schema validation.** `claude plugin validate` reported `plugins[0] plugin.json → skills: Invalid input`. The `skills` field names *directories to scan* for `<name>/SKILL.md`, not individual skill directories, and `skills/` is the default scan path regardless. Removed, along with adding the `author` and marketplace `description` the validator warned about. The shipped manifests now validate clean, and `tests/test-install.sh` asserts it.

  Two things already worked and are now covered by tests so they stay working: `pipeline-notify.sh` derives its template directory from the script's own location, so templates resolve to `<plugin>/templates/`; and `pipeline-config.sh` resolves `talos.pipeline.yml` from the cwd, so a plugin install reads the *user's* config rather than inheriting Talos's own.

### Added

- **Per-repo role overrides.** A repo-level `.claude/agents/<role>.md` now takes precedence over the plugin's `talos:<role>`, per role — override `developer` and keep the other seven from the plugin, without forking Talos. The orchestrator playbook and `pipeline-agent.sh` resolve in the same order so Claude and Codex pick the same profile.
- `tests/test-plugin-install.sh` — 24 assertions modelling a real marketplace layout: a plugin cache directory holding the Talos tree, and a target repo containing nothing but `talos.pipeline.yml`. Covers agent shipping, script resolution with and without `$CLAUDE_PLUGIN_ROOT`, role override precedence, loud failure on an unknown role, template resolution, and config staying per-repo. 13 of them fail against 0.5.0.

### Changed

- README and user guide lead with the plugin install; `install.sh` is documented as the path for harnesses that cannot load a Claude Code plugin (Codex, Gemini, Antigravity) or for pinning the pipeline in-tree. Both paths remain supported and can coexist — the plugin wins where both are present, since it is the copy that matches the skill being run.
- Agent-profile customization guidance now distinguishes the two installs: vendored profiles are yours to edit, plugin profiles live in a cache that `/plugin update` replaces wholesale and must be overridden per-repo instead.

## [0.5.0] - 2026-08-07

### Changed

- **`install.sh` now registers `/pipeline` itself** — the orchestrator skill installs to `<target>/.claude/skills/pipeline/SKILL.md` instead of `<target>/.claude/talos/skills/pipeline/SKILL.md`. Claude Code discovers skills at `<repo>/.claude/skills/<name>/SKILL.md` and `~/.claude/skills/<name>/SKILL.md` and does **not** recurse, so every install before this one shipped a skill that nothing scanned: a repo could have correct scripts, templates, all eight agents, a valid config, bootstrapped labels and an issue at `pipeline:ready`, and still have no `/pipeline` command. `docs/user-guide.md` already documented the right locations; the installer disagreed with the docs. The skill body probes for `.claude/talos/scripts/` vs `scripts/` to find its scripts, so relocating it changes nothing about how it runs. (#34, fixes #33)

  **Upgrading:** re-run `install.sh` against your repo. It relocates the file and deletes the stale `.claude/talos/skills/pipeline/SKILL.md`, which is not merely tidiness — the AGENTS.md block written for the codex/antigravity harnesses pointed at that path, so a stale playbook there stays live for non-Claude runners after an upgrade. Only the file Talos wrote is removed; unrelated files you kept in that directory survive, and so do their parent dirs. Then **restart any Claude Code session already open in the repo** — skills are enumerated at startup.

- **The marketplace plugin is no longer load-bearing for `/pipeline`** — it remains useful for `/pipeline-setup` and for repos where `install.sh` has not run. #32's plugin-detection messaging is removed along with its `CLAUDE_CONFIG_DIR` probe: it existed to explain why a correct install had no command, and that premise is gone. The one surviving form of #31 — a session open *before* the install, holding a stale skill list, where `/pipeline` can still fuzzy-match an unrelated skill — is now the explicit closing note of the installer, along with the path the skill was registered at. README gains an Option A (installer), demotes the plugin to Option C, and states the discovery rule inline. (#34)

### Added

- `assert_file_absent` test helper. `tests/test-install.sh` grows to 37 assertions covering the new location, the absence of the old one, the upgrade migration, preservation of unrelated user files in the old directory, and plugin-independent guidance in both config states. Nine of them fail against 0.4.0's `install.sh`. (#34)

## [0.4.0] - 2026-08-07

### Added

- **Buzz notification sink** — `pipeline-notify.sh` can now post pipeline events to a [Buzz](https://github.com/block/buzz) (Nostr/NIP-29) channel by publishing signed `kind:9` events via the `nak` CLI (`--auth` answers NIP-42). Configure `notifications.buzz_channel` (or `PIPELINE_BUZZ_CHANNEL`) plus `BUZZ_RELAY_URL` / `BUZZ_BOT_PRIVATE_KEY` (env, repo `.env`, or `~/.hermes/.env`). Per-issue threading via NIP-10 reply tags with stale-anchor recovery; graceful skip with a warning when `nak` is missing. New `tests/stubs/nak` + `tests/test-notify-buzz.sh` regression suite. (0c321db)

### Fixed

- **PM stage now relays a notification** — PM was the only enabled role that sent nothing, so the channel thread read `validator → [silence] → developer`. Since PM is typically the longest-running stage, a long spec was indistinguishable from a dead pipeline. `pipeline-notify.sh` already mapped `pm → project-manager`; missing were the template, the relay instruction, and `pm` in the Rule 2 role vocabulary. The original rationale is preserved — the relay is a *pointer* to the spec comment (goal line, acceptance-criteria count, branch name), never a fabricated pass/fail, because PM emits a document rather than a verdict. New `templates/notifications/pm.md` + `tests/test-notify-pm.sh` (7 assertions, incl. that a `pm` event threads under the issue's existing anchor instead of starting a second root). (#30, fixes #29)

- **`install.sh` no longer promises a command it does not register** — it ended with "run: `/pipeline`", but writes the orchestrator skill to `.claude/talos/skills/`, which Claude Code does not scan; the command comes from the marketplace plugin. The failure was silent rather than loud: an unresolvable `/pipeline` gets fuzzy-matched to the nearest registered skill containing the word, so users landed in an unrelated plugin's wizard with no error. The installer now detects whether a talos entry exists in the resolved Claude config and prints either the plain instruction or the marketplace command plus an explicit "once per machine, not per repo" note and the path it checked. Honours `CLAUDE_CONFIG_DIR` — non-default profiles are exactly the case that triggered the report. (#32, fixes #31)

## [0.3.0] - 2026-07-23

### Added

- **`merge.auto` toggle (human-merge mode)** — default `true`; when `false` the orchestrator runs every stage and gate (approval labels, `skip-qa` rules, forbidden files, CI) but stops at `pipeline:approved` with a "ready for human merge" PR comment instead of merging. The issue stays open and closes via the reconciliation sweep after the human merges. New `templates/comments/approved.md` template; documented in `talos.pipeline.yml.example` and the user guide. (9ddeba6)
- **Antigravity harness support** — named runner (`agy -p`) and `--harness antigravity` install support. (a460990)
- **Provider coverage tests** — regression suite now exercises every verb in the gitlab and azure adapters and all three Teams notification paths (debug, real AdaptiveCard post, silent no-op) via new `tests/test-providers.sh` + extended `tests/stubs/glab` + new `tests/stubs/az`. (3ec23f3)

### Fixed

- **Developer test-type mandate** — the developer stage now requires unit/component tests, a failing-first regression test on bug fixes, and an e2e test for user-facing changes when the repo has an e2e harness (`playwright.config.*` / `cypress.config.*` / `tests/e2e/` / `test:e2e` detection); the PR body must list test types added or skipped-with-reason. (11e4321)
- **Azure**: split org_arg into separate argv elements in the label-issue subprocess call so `az` receives `--org` and the URL as distinct arguments. (76d8041)
- **Self-run hardening** — SKILL.md rule + reviewer/security prompts prohibit `git checkout` in shared repo; re-approval paths clear `pipeline:blocked`; CHANGELOG serialization guard in Step 4; developer stage drops self-reported test counts; same-account `gh pr review --approve` failure documented as ignorable; `github-api` provider logs `X-RateLimit-Reset` on HTTP 429. (a315600)

## [0.2.0] - 2026-07-09

### Breaking Changes

- **Install layout moved to `.claude/talos/`** (was `.claude/pipeline/`). Re-run `install.sh` or move your directory manually. (8654d69)
- **`pipeline-notify.sh` now loads `.env` from repo root only** (`<repo-root>/.env` via `git rev-parse --show-toplevel`). Move any credentials from `.claude/talos/.env` (or `.claude/pipeline/.env`) to your repository root `.env`. Dotenv precedence: exported env vars always win over `.env` values. (1e27cbb)

### Added

- **Multi-harness support**: Codex CLI, Gemini CLI, and custom/local runners configurable in `pipeline-agent.sh` — Talos is no longer Claude-only. (9fa4c61)
- **Optional planner role**: new `roles.planner` toggle (default `false`). When enabled, a planner stage decomposes epics into dependency-ordered sub-issues before the PM/developer stages. Epics are detected by label, checklist count (>= 4), or body length (>= 2000 chars). (3e1a0a7)
- **Offline regression suite + e2e pipeline simulation** with stubbed `gh`/`curl` — full test coverage with no network dependency. (903527a)
- **Linked rich notifications**: messages now link to their GitHub issue/PR; notification templates are shipped automatically by `install.sh`. (e7de0d5)
- **Daedalus-style Talos-branded notifications** with install and label fixes. (848fcf5)
- **`github-api` provider**: token-only GitHub mode — all 18 VCS verbs via `curl + GITHUB_TOKEN` (REST + GraphQL for Projects v2). No `gh` CLI dependency required. (39e80d2)
- **Plugin marketplace manifest** (`.claude-plugin/marketplace.json`) — enables `/plugin marketplace add benmarte/talos` install flow. (7e66974)
- **Session-hardening batch**: recovery/reconciliation, find-pr, forbidden-files gate, priority handling, skip-qa flag, and CI retry support. (8a0fee4)

### Fixed

- Grant `Skill` tool access to `qa`, `reviewer`, and `security` role profiles — these roles were previously missing the tool permission. (9404d43)
- Dry-run variants and GitLab fail-open test coverage for all hardening verbs. (38b2d3a)

### Changed

- **Config renamed to `talos.pipeline.yml`** — legacy `.claude-pipeline.yaml`/`pipeline.yaml` are still honored; `talos.pipeline.yml` wins when both exist. No migration required for v0.1.0 configs. (f99eb97)
- **`/pipeline-setup` wizard** now prompts for agent harness (claude/codex/gemini/custom), emits `forbidden_files` defaults, and covers control labels in the generated `talos.pipeline.yml` template. (593f040)
- **Docs**: user guide expanded with per-harness setup, prerequisites, env vars, feature matrix, llama.cpp local-model recipe, and a worked example wiring `addyosmani/agent-skills` into role profiles. (40bc1c8, 88700d2, 21e5dd6)

## [0.1.0] - 2026-07-04

Initial release — autonomous issue-to-PR pipeline orchestrated by Claude Code.

### Added

- Orchestrator (`pipeline-orchestrator.sh`) driving validator -> PM -> developer -> QA -> reviewer -> security -> docs stages via labelled GitHub issues.
- Worktree-isolated developer subagent with per-issue git worktrees.
- VCS abstraction (`pipeline-vcs.sh`) with `github`, `gitlab`, `azure`, and `file` providers.
- Notification system (`pipeline-notify.sh`) with Hermes/ntfy/Slack adapters.
- Pipeline status dashboard (`pipeline-status.sh`).
- Setup wizard (`/pipeline-setup` skill).
- Claude Code plugin manifest (`.claude-plugin/plugin.json`) for marketplace install.
