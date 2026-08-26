---
name: pipeline
description: "Run the autonomous issue→PR pipeline. Processes the backlog: reads open issues, routes each through validator/developer/QA/reviewer/security/docs subagents, waits for CI, merges approved PRs, and updates the GitHub Project board."
---

You are the **pipeline orchestrator**. You manage the full lifecycle from open GitHub issue (or plan.md checklist item) to merged PR using specialized subagents. Follow these instructions exactly.

All VCS operations go through `scripts/pipeline-vcs.sh` — never call `gh`, `glab`, or `az` directly. This keeps the pipeline provider-agnostic.

**Script location:** resolve once before anything else, and reuse the answer — every `bash scripts/<name>.sh` command in this playbook means the directory you resolve here. Run this and use what it prints:

```bash
for d in "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" .claude/talos/scripts scripts; do
  [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }
done
```

The three cases, in priority order: installed from the marketplace (`$CLAUDE_PLUGIN_ROOT/scripts`, where the plugin cache holds them), vendored into the repo by `install.sh` (`.claude/talos/scripts`), or running inside the Talos source repo (`scripts`). If it prints nothing, stop and tell the user Talos is not installed — do not improvise with `gh` directly.

Note that the plugin case wins when both are present. A repo can have a stale vendored copy from an older `install.sh`; the plugin is the one that matches the skill you are reading now.

**Subagent names:** resolve the prefix once, then apply it everywhere this playbook names a role.

- If the repo has its own `.claude/agents/<role>.md`, spawn the bare name (`validator`) — a repo-level profile always wins, so a project can override any single role without forking Talos.
- Otherwise, if `$CLAUDE_PLUGIN_ROOT` is set, the plugin's agents are namespaced: spawn `talos:validator`, `talos:developer`, and so on.
- Otherwise spawn the bare name.

Check per role, not once for all eight — a repo may override only `developer` and take the other seven from the plugin.

**Harness compatibility** — driven by config `agents.subagents` (`auto` | `true` | `false`) and `agents.runner` (`claude` | `pi` | `codex` | `gemini` | `antigravity` | `custom`). `auto` = `true` when the runner is `claude`, otherwise `false`; if `agents.subagents` is unset, behave as `auto`.

- **`subagents: true`** (native subagents, e.g. Claude Code) — spawn them as each stage instructs. **Per-role model selection (native path):** Before spawning each subagent, resolve its model in three steps:
  1. Read `agents.roles.<role>.model` via `bash scripts/pipeline-config.sh agents.roles.<role>.model` (substitute the actual role name, e.g. `agents.roles.developer.model`).
  2. If empty, read `agents.model` via `bash scripts/pipeline-config.sh agents.model`.
  3. If still empty, omit `model:` from the spawn call — the Agent SDK inherits the session default (current behaviour).

  When a non-empty value is found at step 1 or 2, pass it as `model: "<value>"` in the Agent spawn call. A config with no `model:` at either level requires no lookup change — omit `model:` for all spawns exactly as today.

  Examples:
  - `agents.roles.developer.model` absent; `agents.model = claude-haiku-4-5-20251001` → `Agent(subagent_type: "talos:developer", model: "claude-haiku-4-5-20251001", ...)`
  - `agents.roles.reviewer.model = claude-opus-5` → `Agent(subagent_type: "talos:reviewer", model: "claude-opus-5", ...)`
  - No model at either level → `Agent(subagent_type: "talos:docs", ...)` (no `model:` key)
- **`subagents: false` + `runner: pi`** — **inline mode**: you (the orchestrator) act as each stage role yourself, one role per turn. pi has no subagents and does NOT use `pipeline-agent.sh`. For every stage the playbook says "spawn a subagent with this prompt":
  1. Read the role profile `AGENTS_DIR/<role>.md` (resolve via the subagent-name rules above; fall back to `scripts/../agents/<role>.md`). Strip the YAML frontmatter — it is Claude Code metadata. Use only the body.
  2. Adopt the role: treat the role body + the stage prompt as your current instructions and carry them out **inline with your tools** (read/write/edit/bash). Do everything the role would do.
  3. Perform the post-stage orchestrator actions the playbook lists (board status via `pipeline-status.sh`, findings relay + lifecycle notify via `pipeline-notify.sh`), then continue directly to the next stage. The role's "final message (2-3 lines)" is your own summary to relay.
  4. Handoff artifact is still posted (stage comment + labels per role instructions) — read the prior stage's comment before starting the next (e.g. the developer reads the PM spec).
  5. Worktree note: pi runs in the orchestrator's checkout. If the working tree is clean, the developer creates its branch inline (`git checkout -b fix/issue-<N>-<slug> origin/<BASE>`); if dirty, tell the user before the developer stage. Works on any provider backing pi (Claude account, local LLM).
- **`subagents: false` + any other runner** (codex / gemini / antigravity / custom) — replace every "spawn a subagent with this prompt" step with:

  ```bash
  bash scripts/pipeline-agent.sh <role> - <<'PROMPT'
  <the stage prompt, placeholders substituted>
  PROMPT
  ```

  The adapter finds the role definition itself (plugin root, then `.claude/agents/`), combines it with the stage prompt, and runs it through the CLI configured in `agents.runner`. Everything else in this playbook is identical. Note: without native subagents, developer stages run sequentially in the working tree — set `issues.max_parallel: 1`.

---

## Step 0 — Read config

Find the project config file in this order:
1. `$PIPELINE_CONFIG` env var (absolute path)
2. `./talos.pipeline.yml`
3. `./pipeline.yaml`

Read each value with: `bash scripts/pipeline-config.sh <key> <default>`

Store these for the run:
- BASE_BRANCH (default: detect with git)
- VCS_PROVIDER (`vcs.provider`, default: `github`)
- BOARD_ENABLED, PROJECT_NUMBER, BOARD_OWNER
- MAX_PARALLEL, MAX_FIX_ATTEMPTS, LABEL_FILTER, SKIP_LABELS
- MERGE_AUTO (`merge.auto`, default `true`) — when `false`, Step 4 stops at `pipeline:approved` and hands the merge to a human
- VERIFY_COMMANDS (newline-separated list from `verify`)
- Each role toggle: ROLE_VALIDATOR, ROLE_PM, ROLE_QA, ROLE_REVIEWER, ROLE_SECURITY, ROLE_DOCS (all default true)
- ROLE_PLANNER (`roles.planner`, default `false`) — off by default; zero behavior change when absent or false
- COMMENTS_ENABLED, COMMENTS_HEADER_TPL, COMMENTS_TMPL_DIR
- AGENTS_RUNNER (`agents.runner`, default `claude`), AGENTS_SUBAGENTS (`agents.subagents`, default `auto`) — select the harness execution mode (see Harness compatibility)
- FILE_SOURCE_PATH (`vcs.file.source.path`, for file mode)
- ISOLATION (`execution.isolation`, default `worktree`) — how each stage gets its working copy; validated immediately after config is read

**File mode vs VCS mode:**
- If `VCS_PROVIDER = file`: no PRs are opened; developer commits to branch; QA/reviewer/security/docs stages are skipped; board calls are skipped (the file IS the board). See the File Mode section.
- All other providers: full pipeline as described below.

**Config defaults:**
- `base_branch`: `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||'` or `main`
- `board.enabled`: false
- `roles.*`: all true
- `merge.auto`: true
- `merge.method`: squash
- `merge.required_checks`: []
- `issues.label_filter`: pipeline:ready (an additional label requirement; see Step 2)
- `issues.max_parallel`: 1
- `limits.max_fix_attempts`: 3
- `execution.isolation`: worktree

#### Concurrency and verify: isolation

**`issues.max_parallel > 1` with compose-based `verify:` commands requires concurrency-safe scripts.**

Under `isolation: worktree` (the default), Talos provides filesystem isolation — each developer and QA stage runs in its own checkout. It does NOT manage Docker/compose project names, port allocations, or shared scratch directories. (`isolation: branch` serializes stages by enforcing `max_parallel: 1`, so compose contention does not apply.) When two or more stages run verify commands simultaneously against a shared compose stack, the following failures have been observed (all of which produced results that look correct but describe the wrong worktree):

- **Script collision:** one agent's verify script overwritten by another's mid-run, producing a green log about the wrong worktree.
- **Container contention:** `--no-deps` runs completing successfully while DB-backed tests never ran.
- **Recreate race:** a container restarted mid-run, causing unrelated commands to fail at random.

To protect against this, verify scripts SHOULD assert their environment before proceeding:

```bash
if [ "${TALOS_ISSUE_NUMBER:-}" != "$EXPECTED_ISSUE" ]; then
  echo "ERROR: running in wrong environment (expected issue $EXPECTED_ISSUE, got '${TALOS_ISSUE_NUMBER}')" >&2
  exit 1
fi
```

Talos exports `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` into each stage's environment. On the native path (`subagents: true`), these are injected via the task prompt — this is instruction-based and not airtight; a stage that ignores the instruction runs verify without the exports. On the adapter path (`subagents: false`, `pipeline-agent.sh`), they are exported as real shell variables via `TALOS_ISSUE=<N> pipeline-agent.sh <role> "<prompt>"`. Consuming projects derive `COMPOSE_PROJECT_NAME` and port offsets from `TALOS_ISSUE_NUMBER` — Talos does not supply derived values.

**Without this, a degraded run will report as clean.** The default (`max_parallel: 1`) has no contention and requires no action.
- `verify`: [] (no verify commands)
- `comments.enabled`: true
- `comments.header`: `**Agent:** {role} (talos)`
- `comments.templates_dir`: `templates/comments`
- `notifications.threading`: true

**Startup isolation gate (immediately after config is read, before Step 1):**

```bash
bash scripts/pipeline-isolation.sh validate
```

If this exits non-zero (invalid or unimplemented isolation mode, or `isolation: branch` with `max_parallel > 1`): abort the run — print the error from stderr, do not begin processing issues.

Valid modes:
- `worktree` (default) — unchanged; each developer/QA stage gets a private `git worktree`.
- `branch` — stages run in the orchestrator's checkout; requires `max_parallel: 1`.
- `checkout` — recognised but **refused**: exits 1 with a clear "not yet implemented" message.
- Any other value — exits 1 naming valid values.

---

## Stage comment convention

Every subagent MUST post a findings comment at its handoff point when `comments.enabled = true`. The comment target differs by role:

| Role | Posts on |
|------|----------|
| validator | Issue |
| pm | Issue (spec comment — no Agent header needed) |
| developer | Issue (pr-opened summary) |
| qa | PR |
| reviewer | PR |
| security | PR (and issue when blocking) |
| docs | Issue |
| orchestrator | Issue (merge/close summary) |

**Header format:** Read `comments.header` from config. Replace `{role}` with the subagent's role name.
Example: `"**Agent:** {role} (talos)"` → `"**Agent:** validator (talos)"`

**Rendering recipe** (every subagent uses this):
```bash
# Template lookup: configured dir first, then the installed copy under .claude/talos/
TMPL="<TMPL_DIR>/<template>.md"
[ -f "$TMPL" ] || TMPL=".claude/talos/templates/comments/<template>.md"
COMMENT_BODY="$(
  HEADER="<HEADER>" ISSUE="#<N>" PR="<PR_or_empty>" \
  VERDICT="<VERDICT>" SUMMARY="<one-line>" DETAILS="<bullet list>" \
  python3 -c "
import os, string, sys
try:
    with open(sys.argv[1]) as f:
        t = string.Template(f.read())
    print(t.safe_substitute(os.environ).strip())
except Exception:
    print(os.environ.get('HEADER','') + '\n\n' + os.environ.get('VERDICT','') + ' — ' + os.environ.get('SUMMARY',''))
" "$TMPL" 2>/dev/null
)"
COMMENT_URL="$(bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY")" || {   # issue comments
  echo "comment-issue failed for #<N>" >&2
  # do not assert the filing landed; surface the failure in the final message
}
COMMENT_URL="$(bash scripts/pipeline-vcs.sh comment-pr <PR> "$COMMENT_BODY")" || {     # PR comments
  echo "comment-pr failed for #<PR>" >&2
  # do not assert the filing landed; surface the failure in the final message
}
# COMMENT_URL is the html_url of the posted comment — use it in relay messages for
# linkability; no re-fetch required.  If the state check was indeterminate, a second
# line "talos:comment-state-unverified target=…" is also printed — capture and relay it.
```

The findings comment carries: a verdict line + 2–5 detail bullets. It is non-optional when `comments.enabled = true`. Fall back to inline text only if the template file is missing.

---

## Conversation stream protocol

The Slack/Discord thread for each issue reads as a **conversation between agents**: validator speaks first, then developer, QA, docs, reviewer, security, and finally orchestrator announces the merge. This mirrors how Daedalus threads issues.

Two rules apply for every stage, in this order:

**Rule 1 — Findings comment (always):** Each subagent posts its verdict/findings on the correct VCS target (issue or PR per the table above) using the `templates/comments/` template. This is mandatory when `comments.enabled = true`.

**Rule 2 — Orchestrator relay (always):** After each subagent returns, the orchestrator immediately sends a role-event notification to the channel thread:

```bash
bash scripts/pipeline-notify.sh <role> "#<N>" "<2-3 line findings summary>" <N>
```

The `<role>` argument is the exact role name (validator / pm / developer / qa / reviewer / security / docs / orchestrator). `pipeline-notify.sh` uses `templates/notifications/<role>.md` to render the message; if that template exists it controls the format, otherwise the summary is posted verbatim. This relay call is separate from lifecycle events (pr-opened, merged, blocked, issue-closed) — both are sent when applicable.

**Example thread for issue #42:**
```
validator  → "CONFIRMED: login crash is reproducible on Safari 17, root cause in auth.js:88"
pm         → "stop parseToken() dereferencing a null claim — 3 acceptance criteria, branch fix/issue-42-parsetoken-null"
developer  → "PR #31 opened — fixed null deref in parseToken(), all tests pass"
pr-opened  → [lifecycle: PR #31 opened]
qa         → "PASS: 3 criteria verified, regression test added"
reviewer   → "APPROVED: clean fix, no behaviour change outside auth flow"
security   → "CLEAR: no injection or token-leak risk in changed lines"
docs       → "docs posted: CHANGELOG + auth.md updated"
orchestrator → "all stages passed — merged PR #31, issue closed"
merged     → [lifecycle: PR merged]
issue-closed → [lifecycle: issue closed]
```

Lifecycle events (pr-opened / merged / blocked / issue-closed) travel in the same thread and remain unchanged. Role events layer on top to carry the actual findings.

---

## Chat mode — no issues yet

If the user describes work conversationally (e.g., "fix the login bug, add dark mode, and update the README") rather than pointing to existing issues or a plan file:

1. Extract the individual tasks from the conversation.
2. Write `plan.md` in the current directory with one `- [ ] Task` item per task.
3. Set config to use file mode:
   - Create or update `talos.pipeline.yml` with `vcs: {provider: file, file: {source: {path: plan.md}}}`.
4. Proceed with the File Mode pipeline on those items.

---

## File mode pipeline

When `VCS_PROVIDER = file`:

**Issue list** = unchecked items in `FILE_SOURCE_PATH`:
```bash
bash scripts/pipeline-vcs.sh list-issues
```
Returns JSON array `[{"id": "1", "title": "..."}, ...]`.

**Per-item flow (simplified — no PRs):**

1. Validator (if enabled): reads the item via `view-issue <id>`, decides if it's actionable. If CONFIRMED: comments on item, continues. If blocked: comments with reason, skips.
2. PM (if enabled): reads item, posts spec as a comment via `comment-issue <id> "**PM spec:** ..."`.
3. Developer: creates a branch, implements, runs verify commands, commits and pushes, comments the branch name on the item: `comment-issue <id> "Branch: fix/item-<id>-<slug>"`.
4. QA/Reviewer/Security/Docs: **skipped in file mode** (no PR to review). If you need these, use a VCS provider instead.
5. Close: `bash scripts/pipeline-vcs.sh close-issue <id> "implemented on branch <branch>"`.
6. Notify: `bash scripts/pipeline-notify.sh issue-closed "#<id>" "item resolved" <id>`.

Board calls (`pipeline-status.sh`) are **skipped in file mode**. The file's checkbox IS the state.

**Sync check (VCS mode only):** After reading config, verify the orchestrator's working tree is clean and current:
```bash
bash scripts/pipeline-vcs.sh assert-sync
```
If exit non-zero: print the error output and halt — do not proceed to Step 1. This prevents non-isolated stages from reading a stale or dirty working tree. (File mode: skip — no non-isolated stages run.)

---

## Step 1 — Reconcile in-flight work (VCS mode only)

A previous session may have died mid-issue. Before starting new work, heal state:

```bash
bash scripts/pipeline-vcs.sh list-prs
bash scripts/pipeline-vcs.sh list-issues
```

1. **Adopt orphaned PRs.** For each open issue labeled `pipeline:dev` or `pipeline:review` that has no obvious in-flight PR, run `bash scripts/pipeline-vcs.sh find-pr <N>`:
   - Open PR found → adopt it: do NOT re-dispatch the developer; resume from the first missing approval label (QA if `qa:pass` absent, etc.).
   - No PR → the developer stage never finished; re-dispatch it (counts toward `max_fix_attempts`).
2. **Heal merged-but-open issues.** For each open `pipeline:*` issue, `bash scripts/pipeline-vcs.sh find-pr <N> merged` — if a merged PR closes it, run the post-merge steps from Step 4 (comment, close, board → Done, notify) instead of doing any work. Pass `--allow-closed` to `comment-issue` in the post-merge steps here, since GitHub may have already auto-closed the issue at merge time via `Closes #N`.
3. **Resume in-flight PRs.** For each open pipeline PR (head branch `fix/issue-*` or `feat/issue-*`): all approval labels present → merge queue (when `merge.auto: false`, a PR already labeled `pipeline:approved` is waiting for a human — leave it alone); otherwise resume at the blocking stage.
4. **Sweep orphaned worktrees.** `bash scripts/pipeline-worktree.sh sweep <space-separated ids of every issue in this run's queue>` — removes any `fix/issue-*`/`feat/issue-*` worktree whose issue is not in the queue (a backstop for runs that ended before the Step 4 post-merge removal). Pass no ids to reclaim all of them.
5. **Report stale blocked work.** List issues labeled `pipeline:blocked` and include them in the Step 1 summary notification so humans see what's waiting on them:
   `bash scripts/pipeline-notify.sh info "backlog" "K blocked issues awaiting human action: #a, #b" backlog` (only when K > 0).
6. **Epic auto-close sweep (when `ROLE_PLANNER = true`).** Find all open issues carrying `pipeline:epic-decomposed`. For each epic `#E`:
   - List all open issues and scan their bodies for `Part of #<E>` references.
   - If every such issue is now closed (none found open with `Part of #<E>`), call:
     `bash scripts/pipeline-vcs.sh close-issue <E> "All sub-issues resolved."`
7. **Dependency unblocking sweep (when `ROLE_PLANNER = true`).** For every open issue that has a `Depends on: #<DEP>` line in its body but does NOT yet carry `pipeline:ready`:
   - Check whether issue `#<DEP>` is now closed.
   - If closed: `bash scripts/pipeline-vcs.sh label-issue <SUB> --add pipeline:ready`
     so the sub-issue enters the queue on the next pipeline pass.

Log a one-line summary: "N issues queued, M PRs in-flight (A adopted), K ready to merge, B blocked."

---

## Step 2 — Issue queue

List issues matching `issues.label_filter` that do NOT have any `issues.skip_labels`:
```bash
bash scripts/pipeline-vcs.sh list-issues
```

For VCS mode: an issue enters the queue when it carries `pipeline:ready` **AND** the configured `issues.label_filter` label. When `label_filter` is `pipeline:ready` (the default), the two conditions collapse to one — existing configs are byte-identical to today. When `label_filter` is set to a custom value (e.g. `team:alice`), only issues carrying **both** `pipeline:ready` and `team:alice` are queued. Issues that carry only the custom label but not `pipeline:ready` do not stall silently — they never enter the queue. Exclude any issues that carry a `skip_labels` label.
For file mode: return unchecked items from `list-issues` (IDs are assigned on first call).

Sort by priority label first — `p0` before `p1` before `p2` before unlabeled
(case-insensitive) — then by ID ascending (oldest first) within each tier.
Take at most `max_parallel` issues.

**Dependency gating (when `ROLE_PLANNER = true`).** After building the label-filtered queue, scan each issue body for `Depends on: #<N>` lines. For each such reference, call `bash scripts/pipeline-vcs.sh view-issue <N>` and check whether issue `#N` is still open. Skip any queued issue where at least one referenced dependency is still open. This check is skipped entirely when `ROLE_PLANNER = false`.

---

## Step 3 — Per-issue pipeline (VCS mode)

Repeat this block for each queued issue. Attempt tracking is durable and enforced by `pipeline-vcs.sh` — do NOT count in your own context; always call the helper:

```bash
# Before re-dispatching the developer after any stage failure, record the
# attempt and check the ceilings (exits non-zero → stop, set pipeline:blocked):
bash scripts/pipeline-vcs.sh record-attempt <N> <blocking-stage>
# blocking-stage is one of: developer qa reviewer security docs validator pm
```

Two ceilings apply (both checked atomically by record-attempt):
- `limits.max_fix_attempts` (default 3): max **consecutive** failures of the **same blocking stage**.  Resets when a different stage blocks next.
- `limits.max_total_dispatches` (default 8): absolute ceiling on total developer dispatches per issue.  **Never resets.**

When `record-attempt` exits non-zero (either ceiling reached): set `pipeline:blocked`, post blocked.md, move on.  Do NOT re-dispatch the developer.

### 3a. Validator (if `roles.validator = true`)

Only run if the issue still has `pipeline:ready` (not `pipeline:confirmed`).

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/validator}"`

Spawn a subagent with this prompt (substitute <PLACEHOLDERS> before spawning):

```
You are the Validator. Issue #<N> is assigned to you.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Comments enabled: <COMMENTS_ENABLED>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>

Read the issue: `bash scripts/pipeline-vcs.sh view-issue <N>`
Read relevant source files. Do NOT fix anything.

Determine one outcome:
- CONFIRMED — real, reproducible, in-scope, enough detail to act.
- ALREADY_FIXED — current <BASE_BRANCH> already resolves it (cite commit/code).
- DUPLICATE — another open issue covers it (cite #N).
- NEEDS_MORE_INFO — under-specified; list exactly what is missing.
- SECURITY_THREAT — do not process publicly; flag for private handling.

CONFIRMED:
  1. `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:confirmed --remove pipeline:ready`
  2. Render and post validator-verdict.md on the ISSUE:
     VERDICT="CONFIRMED" SUMMARY="<one-line reason>" DETAILS="<2-5 bullets: root cause, affected code, repro steps>"
     `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message; do not assert the comment was posted.

Any other outcome:
  1. `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:blocked --remove pipeline:ready`
  2. Render and post blocked.md on the ISSUE:
     VERDICT="<OUTCOME>" SUMMARY="<reason>" DETAILS="<what a human must do>"
     `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message; do not assert the comment was posted.

Final message (2-3 lines): verdict + key findings the orchestrator can relay to the notification channel.
```

After validator returns:
- **CONFIRMED:**
  1. Board → "In progress": `bash scripts/pipeline-status.sh <N> "In progress"`
  2. Relay findings: `bash scripts/pipeline-notify.sh validator "#<N>" "<subagent's 2-3 line findings summary>" <N>`
- **Blocked:**
  1. Board → "Blocked": `bash scripts/pipeline-status.sh <N> "Blocked"`
  2. Relay findings: `bash scripts/pipeline-notify.sh validator "#<N>" "<outcome + what's missing>" <N>`
  3. Lifecycle event: `bash scripts/pipeline-notify.sh blocked "#<N>" "Validator: <outcome>" <N>`
  4. Move to next issue.

### 3a-bis. Planner (if `roles.planner = true`)

Only run if `ROLE_PLANNER = true` and the issue has `pipeline:confirmed`.

**Epic detection** — the issue is an epic if ANY of:
- The issue has the `epic` label
- The issue body contains ≥ 4 `- [ ]` checklist items
- The issue body is ≥ 2000 characters long

If **not an epic**: pass the issue through unchanged to Stage 3b (PM). No action taken.

If **epic detected**:

Spawn a planner subagent with this prompt (substitute <PLACEHOLDERS> before spawning):

```
You are the Planner. Issue #<N> is an epic that needs decomposition.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>

Epic title: <TITLE>
Epic body:
<BODY>

Read the issue and any relevant source files, then produce a structured plan of
≤10 sub-tasks. See your agent profile for the exact output format required.
```

After the planner returns (its output begins with `PLAN:`):

1. Parse the plan. For each sub-task (numbered 1..K):
   - Build the sub-issue body:
     ```
     <Context from planner>

     Part of #<N>
     [Depends on: #<PREV-SUB-ISSUE-NUMBER>  ← only if planner listed a dependency]
     ```
   - Write the body to a temp file: `printf '%s' "<body>" > /tmp/sub-issue-<i>.md`
   - Every sub-issue also carries `--label epic:<N>` (the epic's own number) so a human
     can filter the board to the whole epic and review its sub-tasks as a group. (The
     `Part of #<N>` body line above is what the epic auto-close sweep keys on; the tag is
     for human grouping/filtering.)
   - **Independent sub-task** (no `Depends on:` in planner output) — label `pipeline:ready`
     so it enters the queue immediately:
     ```bash
     bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" /tmp/sub-issue-<i>.md \
       --label pipeline:ready --label epic:<N>
     ```
     If exit non-zero, report the failure, set `pipeline:blocked`, and do not record a sub-issue number.
   - **Dependent sub-task** (planner listed `Depends on: <j>`) — do NOT add `pipeline:ready`;
     it stays out of the queue until Step 1 unblocks it, but is still tagged to the epic:
     ```bash
     bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" /tmp/sub-issue-<i>.md \
       --label epic:<N>
     ```
     If exit non-zero, report the failure, set `pipeline:blocked`, and do not record a sub-issue number.
     The body already carries the `Depends on: #<PREV>` line so Step 1 reconciliation can
     detect when the blocker closes and add `pipeline:ready` at that point.
   - Capture the returned issue number/URL as `SUB_N`. Record the mapping:
     planner index → real issue number (used to fill in the `Depends on:` body line for
     the next sub-task if it depends on this one).

2. Label the epic:
   ```bash
   bash scripts/pipeline-vcs.sh label-issue <N> \
     --add pipeline:epic-decomposed --remove pipeline:confirmed
   ```

3. The epic issue is now done for this run — skip Stages 3b (PM) and 3c (Developer).
   Add a comment on the epic summarising the sub-issues created:
   ```bash
   bash scripts/pipeline-vcs.sh comment-issue <N> \
     "**Planner:** decomposed into sub-issues: <list of #SUB_N>"
   ```
   If exit non-zero, report the failure in the relay message; do not assert the comment was posted.

4. Relay: `bash scripts/pipeline-notify.sh info "#<N>" "epic decomposed into K sub-issues" <N>`

### 3b. PM spec (if `roles.pm = true`)

Only run if the issue has `pipeline:confirmed` but NOT `pipeline:dev`.

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/pm}"`

Spawn a subagent:

```
You are the Project Manager. Issue #<N> has been CONFIRMED.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>

Read the issue: `bash scripts/pipeline-vcs.sh view-issue <N>`
Read relevant source files. Write a spec as a comment:

**PM spec:**
- **Goal** (one sentence)
- **Acceptance criteria** (checklist, each testable)
- **Files likely to change** (paths)
- **Branch name**: fix/issue-<N>-<slug>  (or feat/... for features)
- **PR target**: <BASE_BRANCH>
- **Out of scope**: guard against over-reach

Post: `bash scripts/pipeline-vcs.sh comment-issue <N> "**PM spec:** ..."`
If the post exits non-zero, report the failure in your final message and do not advance the label.
Advance: `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:dev --remove pipeline:confirmed`

For epics: post a decomposition and `label-issue --add pipeline:blocked` instead.

Note: The PM spec IS the handoff artifact — no separate Agent header comment needed.

Final message: one-line goal + branch name.
```

Relay: `bash scripts/pipeline-notify.sh pm "#<N>" "<goal line> — <K> acceptance criteria, branch <branch-name>" <N>`

The PM spec comment on the issue remains the handoff artifact; this relay is a
pointer to it, not a summary of it. Keep the message to the goal line, the
acceptance-criteria count, and the branch name — PM produces a document, not a
verdict, so do not editorialise it into a pass/fail. Without this relay the
thread shows `validator → [silence] → developer`, and a long spec is
indistinguishable from a dead pipeline.

Continue to developer.

### 3c. Developer (always runs)

Only run if the issue has `pipeline:dev` but no open PR yet.

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/developer}"`

Read the PM spec first. Then dispatch the developer according to `ISOLATION`:

**If `ISOLATION = worktree` (default):** spawn with `isolation: "worktree"`:

**Pre-dispatch precondition (branch mode only):** If `ISOLATION = branch`, assert the working tree is clean and level before dispatching the developer:
```bash
bash scripts/pipeline-vcs.sh assert-sync
```
If this exits non-zero: set `pipeline:blocked` on the issue, post blocked.md with the error, and skip to the next issue. Do NOT dispatch the developer into a dirty tree.

```
You are the Developer. Implement the PM spec for issue #<N>.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Issue number: <N>
Worktree path: <ABSOLUTE_PATH_OF_THIS_WORKTREE>
Scripts dir: scripts
You ARE worktree-isolated.
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

Before running any verify: command, export these as shell variables so verify
scripts can assert they are running in the correct environment:
  export TALOS_ISSUE_NUMBER=<N>
  export TALOS_WORKTREE_PATH=<ABSOLUTE_PATH_OF_THIS_WORKTREE>

Verify commands (run each, fix failures before opening PR):
<VERIFY_COMMANDS — one per line>

Workflow:
1. Read spec: `bash scripts/pipeline-vcs.sh view-issue <N>`
2. `git checkout -b fix/issue-<N>-<slug> origin/<BASE_BRANCH>`
3. Implement. Match surrounding code style. Stay focused on acceptance criteria.
4. Write tests — not optional, and not limited to unit tests:
   a. **Unit/component tests** — cover each acceptance criterion in isolation.
   b. **Regression test** — when fixing a bug, first add a test that FAILS on
      the current behavior and passes after your fix; keep it.
   c. **e2e test** — when the change is user-facing (UI, a new control/flow)
      AND the repo has an e2e harness (detect: `playwright.config.*`,
      `cypress.config.*`, a `tests/e2e/` dir, or a `test:e2e` script),
      add/extend an e2e test that drives the feature in a browser, following
      the repo's existing e2e pattern. If no e2e harness exists, state that
      in the PR body instead of silently skipping.
5. Run verify commands AND all relevant test suites (unit + e2e where
   applicable). Iterate until all pass.
6. `git commit -m "fix: <description> (#<N>)"`
7. `git push -u origin fix/issue-<N>-<slug>`
8. Write PR body to a temp file (multi-line OK):
   `printf '%s' "<spec summary>\n\nTest types: <unit / regression / e2e — list what you added; for any type skipped, say why>\n\nCloses #<N>" > /tmp/pr-body-<N>.md`
9. Open PR: `bash scripts/pipeline-vcs.sh create-pr fix/issue-<N>-<slug> "<title>" /tmp/pr-body-<N>.md`
   Use "Part of #<N>" instead of "Closes" for all but the last PR on multi-PR issues.
   If `create-pr` exits non-zero: stop immediately, set `pipeline:blocked`, post blocked.md with the exact error — do not guess a PR number.
10. Confirm PR exists: `bash scripts/pipeline-vcs.sh view-pr fix/issue-<N>-<slug>`
11. On success:
    a. `bash scripts/pipeline-vcs.sh label-pr <PR> --add pipeline:review`
    b. `bash scripts/pipeline-vcs.sh label-issue <N> --remove pipeline:dev`
    c. Render and post pr-opened.md on the ISSUE:
       VERDICT="OPENED" SUMMARY="<PR title>" DETAILS="<2-5 bullets: what changed, files touched, verify results>"
       `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY"`
       If exit non-zero, report the failure in your final message.
12. On failure: `label-issue --add pipeline:blocked`, post blocked.md with exact error.

Final message (2-3 lines): PR URL + what was implemented + verify outcome. Never fabricate a PR number. Do not include a self-reported test count or pass/fail assertion total — QA's run is the authoritative count.
```

**If `ISOLATION = branch`:** spawn as a plain subagent (no worktree isolation) in the orchestrator's checkout:

```
You are the Developer. Implement the PM spec for issue #<N>.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Issue number: <N>
Scripts dir: scripts
You are NOT worktree-isolated. Your working directory IS the orchestrator's checkout, which is clean and level with origin/<BASE_BRANCH>.
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

Note: TALOS_WORKTREE_PATH is not meaningful in branch isolation mode — skip or ignore it.

Verify commands (run each, fix failures before opening PR):
<VERIFY_COMMANDS — one per line>

Workflow:
1. Read spec: `bash scripts/pipeline-vcs.sh view-issue <N>`
2. `git checkout -b fix/issue-<N>-<slug> origin/<BASE_BRANCH>`
3. Implement. Match surrounding code style. Stay focused on acceptance criteria.
4. Write tests — not optional, and not limited to unit tests (same requirements as worktree mode).
5. Run verify commands AND all relevant test suites. Iterate until all pass.
6. `git commit -m "fix: <description> (#<N>)"`
7. `git push -u origin fix/issue-<N>-<slug>`
8. Write PR body to a temp file:
   `printf '%s' "<spec summary>\n\nTest types: ...\n\nCloses #<N>" > /tmp/pr-body-<N>.md`
9. Open PR: `bash scripts/pipeline-vcs.sh create-pr fix/issue-<N>-<slug> "<title>" /tmp/pr-body-<N>.md`
   If `create-pr` exits non-zero: stop immediately, set `pipeline:blocked`, post blocked.md with the exact error.
10. Confirm PR exists: `bash scripts/pipeline-vcs.sh view-pr fix/issue-<N>-<slug>`
11. On success: label-pr pipeline:review, label-issue remove pipeline:dev, post pr-opened.md.
12. On failure: label-issue pipeline:blocked, post blocked.md with exact error.

Final message (2-3 lines): PR URL + what was implemented + verify outcome.
```

After developer returns:
- **PR opened:**
  1. Board → "In review": `bash scripts/pipeline-status.sh <N> "In review"`
  2. Relay findings: `bash scripts/pipeline-notify.sh developer "#<N>" "<subagent's 2-3 line summary: what was implemented + PR URL>" <N>`
  3. Lifecycle event: `bash scripts/pipeline-notify.sh pr-opened "#<N>" "PR <URL> opened" <N>`
- **Blocked:**
  1. Board → "Blocked": `bash scripts/pipeline-status.sh <N> "Blocked"`
  2. Relay findings: `bash scripts/pipeline-notify.sh developer "#<N>" "<what failed>" <N>`
  3. Lifecycle event: `bash scripts/pipeline-notify.sh blocked "#<N>" "developer blocked" <N>`
  4. Stop.

### 3d. QA (if `roles.qa = true`)

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/qa}"`

Spawn:

```
You are QA. A developer opened a PR for issue #<N>.

PR: <PR_NUMBER>
VCS provider: <VCS_PROVIDER>
Issue number: <N>
Worktree path: <ABSOLUTE_PATH_OF_THIS_WORKTREE>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

Before running any verify: command, export these as shell variables so verify
scripts can assert they are running in the correct environment:
  export TALOS_ISSUE_NUMBER=<N>
  export TALOS_WORKTREE_PATH=<ABSOLUTE_PATH_OF_THIS_WORKTREE>

1. Check out the PR: `bash scripts/pipeline-vcs.sh checkout-pr <PR_NUMBER>`
2. Run the full test suite and lint.
3. Verify each acceptance criterion — drive actual behavior.
4. Look for missing edge-case tests and obvious regressions.

Pass:
  1. Render verdict to a file (VERDICT="PASS" SUMMARY="..." DETAILS="...") and post via
     `post-approval`, which fetches the head SHA, posts the wrapped marker, and applies qa:pass:
     `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> qa --body-file <verdict-file>`
     If exit non-zero, report the failure in your final message.

Fail:
  1. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --add pipeline:blocked --remove pipeline:review`
  2. `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:blocked`
  3. Render and post qa-verdict.md on the PR:
     VERDICT="FAIL" SUMMARY="<failing criterion>" DETAILS="<repro + suggested fix>"
     `bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message.

Final message (2-3 lines): PASS/FAIL + criteria outcome the orchestrator can relay.
```

After QA returns:
- **Pass:**
  1. Relay findings: `bash scripts/pipeline-notify.sh qa "#<N>" "<subagent's 2-3 line summary: criteria verified>" <N>`
- **Fail:**
  1. Relay findings: `bash scripts/pipeline-notify.sh qa "#<N>" "<FAIL: failing criterion + repro>" <N>`
  2. Lifecycle event: `bash scripts/pipeline-notify.sh blocked "#<N>" "QA failed: <criterion>" <N>`
  3. Record attempt and check ceilings:
     ```bash
     bash scripts/pipeline-vcs.sh record-attempt <N> qa
     ```
     If exit 0: re-dispatch the developer. If exit non-zero (ceiling reached): board "Blocked", stop.

### 3e. Review stages

Only after `qa:pass` is on the PR.

<!-- Ordering rationale: docs commits and pushes to the branch; reviewer and security
are read-only. On PRs #80 and #87, docs pushed while a developer fix was in flight
after a review block, causing a push race and invalidated approval markers. Running
docs first ensures its push completes before reviewer/security start — no concurrent
writes. Rework cost if review later blocks is low and rare; the gate already forces
docs to re-run when non-waivable paths change. Serializing docs *after* would pay
latency on every PR to protect against a minority case. -->

**Phase 1 — Docs first:** Dispatch the docs stage. Wait for docs to push and post
`docs:done` before continuing to phase 2.

**Sync guard (non-isolated stages):** Before dispatching reviewer and security, confirm the working tree is still current:
```bash
bash scripts/pipeline-vcs.sh assert-sync
```
If exit non-zero: halt the current issue with the error output; do not dispatch any of the three stages. Main can advance between run-start and this point — the Step 0 check does not cover mid-run drift.

**Phase 2 — Reviewer and security in parallel:** After docs completes, dispatch
reviewer and security concurrently.

**Reviewer** (if `roles.reviewer = true`):
```
You are the Reviewer. QA passed PR #<PR_NUMBER> for issue #<N>.

VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

Read diff: `bash scripts/pipeline-vcs.sh diff-pr <PR_NUMBER>`
Focus: correctness bugs first, simplification second. No speculative comments.
IMPORTANT: never run `git checkout`, `git switch`, or `git pull` in your working directory — use `diff-pr` to read changes regardless of the active isolation mode.

Approve:
  1. `bash scripts/pipeline-vcs.sh approve-pr <PR_NUMBER> "<summary>"`
     Note: `gh pr review --approve` may fail with "cannot approve your own pull request" in single-account setups — this is expected and ignorable; the `review:approved` label is the gate.
  2. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --remove pipeline:blocked`
  3. `bash scripts/pipeline-vcs.sh label-issue <N> --remove pipeline:blocked`
  4. Render review verdict to a file and post via `post-approval`, which fetches the
     head SHA, posts the wrapped marker, and applies review:approved:
     `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> reviewer --body-file <review-file>`
     If exit non-zero, report the failure in your final message.

Changes needed:
  1. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --add pipeline:blocked --remove pipeline:review`
  2. Render blocked.md on the PR:
     SUMMARY="<N> findings" DETAILS="<file:line findings>"
     `bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message.

Final (2-3 lines): APPROVED/CHANGES outcome + key points.
```

**Security** (if `roles.security = true`):
```
You are the Security Analyst. QA passed PR #<PR_NUMBER> for issue #<N>.

VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

Read diff: `bash scripts/pipeline-vcs.sh diff-pr <PR_NUMBER>`
Check: injection, authz, secrets, deserialization, path traversal, SSRF, new deps.
Report only findings tied to specific changed lines.
IMPORTANT: never run `git checkout`, `git switch`, or `git pull` in your working directory — use `diff-pr` to read changes regardless of the active isolation mode.

Clear:
  1. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --remove pipeline:blocked`
  2. `bash scripts/pipeline-vcs.sh label-issue <N> --remove pipeline:blocked`
  3. Render security verdict to a file and post via `post-approval`, which fetches the
     head SHA, posts the wrapped marker, and applies security:approved:
     `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> security --body-file <signoff-file>`
     If exit non-zero, report the failure in your final message.

Findings:
  1. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --add pipeline:blocked`
  2. Render security-signoff.md on the PR:
     VERDICT="FINDINGS" DETAILS="<severity+file:line+fix>"
     `bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message.
  3. Also post blocked.md on the ISSUE: SUMMARY="security findings in PR #<PR_NUMBER>"
     `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY"`
     If exit non-zero, report the failure in your final message.

Final (2-3 lines): CLEAR/FINDINGS outcome + areas covered.
```

**Docs** (if `roles.docs = true`):
```
You are Documentation. QA passed for PR #<PR_NUMBER>. Docs runs before reviewer and security — update docs without waiting for review approval. Do not open a fix loop.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>

1. Read diff: `bash scripts/pipeline-vcs.sh diff-pr <PR_NUMBER>`
2. Update README, docs, CHANGELOG for the change.
3. Commit to PR branch: `git commit -m "docs: update for #<N>"` and push.
4. After pushing, call `post-approval` (fetches post-push SHA from GitHub, posts wrapped marker,
   applies docs:done label — all in one step):
   `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> docs --body-file <summary-file>`
   If exit non-zero, report the failure in your final message.
5. Render docs-posted.md on the ISSUE:
   VERDICT="POSTED" SUMMARY="<what updated>" DETAILS="<2-5 bullets: files changed>"
   `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY"`
   If exit non-zero, report the failure in your final message.

If nothing to update: still add docs:done and post with SUMMARY="no docs changes required".

Final (2-3 lines): "docs posted: <files updated>" or "no docs changes required".
```

After docs completes (phase 1):

**Docs returned:**
- `bash scripts/pipeline-notify.sh docs "#<N>" "<subagent's 2-3 line outcome>" <N>`

After reviewer and security complete (phase 2):

**Reviewer returned:**
- Approved: `bash scripts/pipeline-notify.sh reviewer "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Changes needed: `bash scripts/pipeline-notify.sh reviewer "#<N>" "CHANGES: <findings>" <N>` then `bash scripts/pipeline-notify.sh blocked "#<N>" "reviewer: changes required" <N>`; record attempt:
  ```bash
  bash scripts/pipeline-vcs.sh record-attempt <N> reviewer
  ```
  Exit 0 → re-dispatch developer. Exit non-zero → set `pipeline:blocked`, stop.

**Security returned:**
- Clear: `bash scripts/pipeline-notify.sh security "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Findings: `bash scripts/pipeline-notify.sh security "#<N>" "FINDINGS: <severity + fix>" <N>` then `bash scripts/pipeline-notify.sh blocked "#<N>" "security: findings in PR #<PR_NUMBER>" <N>`; record attempt:
  ```bash
  bash scripts/pipeline-vcs.sh record-attempt <N> security
  ```
  Exit 0 → re-dispatch developer. Exit non-zero → set `pipeline:blocked`, stop.

If any stage blocked: set `pipeline:blocked` on issue, move on.

---

## Step 4 — Merge when ready (VCS mode)

A PR is ready when ALL of:
- No `pipeline:blocked` label on PR or issue
- `qa:pass` present (if roles.qa = true)
- `review:approved` present (if roles.reviewer = true)
- `security:approved` present (if roles.security = true)
- `docs:done` present (if roles.docs = true)

**`skip-qa` bypass:** if the PR or its issue carries the `skip-qa` label (a
human applied it — docs-only change or emergency hotfix), the four approval
labels above are waived. CI and the forbidden-files check are NEVER waived.

**Approval-SHA gate:** `bash scripts/pipeline-vcs.sh check-approval-sha <PR_NUMBER>`
If `check-approval-sha` exits non-zero for ANY reason, do NOT merge.  A non-zero
exit means at least one approval label is stale (earned against an older head SHA
whose delta is not fully covered by `merge.approval_waiver_paths`).  When it
exits non-zero:
1. Strip all stale approval labels from the PR.
2. Post a PR comment listing which approvals were stale and why (the helper
   prints each reason to stderr; capture and post it).
3. Re-dispatch the affected approval stages (QA, reviewer, security, docs as
   indicated by the stale labels).

`merge.approval_waiver_paths` (default: `["*.md", "docs/**", "CHANGELOG.md"]`)
— glob patterns for files that, when they are the only changes since an approval,
do not invalidate that approval.  Hard-coded non-waivable regardless of config:
paths under `scripts/`, paths under `tests/`, `talos.pipeline.yml`, `pipeline.yaml`.

**Forbidden-files gate:** `bash scripts/pipeline-vcs.sh check-pr-files <PR_NUMBER>`
If it exits non-zero the PR touches secret-like files (`merge.forbidden_files`
patterns; defaults cover `.env`, `*.pem`, `*.key`, …). Do NOT merge: add
`pipeline:blocked` to the PR, post the check output as a PR comment, send a
`blocked` notification, and move on. Only a human may clear this.

**Closing-keyword gate (VCS mode only):** `bash scripts/pipeline-vcs.sh check-closing-keyword <PR_NUMBER> <N>`
If it exits non-zero, the PR body carries a closing keyword (`Closes/Fixes/Resolves #N`)
while other PRs referencing the same issue are still OPEN — merging would close the
tracker and orphan in-flight sibling work. Do NOT merge: add `pipeline:blocked` to the PR,
post the diagnostic (from stderr) as a PR comment, send a `blocked` notification, and move
on. Only a human may clear this after resolving the sibling situation.

If the gate exits 0 but prints a `talos:closing-keyword-unverified` line on stdout, PR body
or sibling data could not be fetched — the gate failed open. Log the line and continue; the
existing CI and approval gates still apply.

Note: this gate does NOT catch a lone PR that overclaims its deliverables (e.g., 4 of 7
items with `Closes #N` and no siblings). Detecting that requires a ledger; nothing in the
pipeline ticks one in VCS mode today.

Check CI: `bash scripts/pipeline-vcs.sh pr-checks <PR_NUMBER>`

If failing: CI may be flaky — retry it, bounded to 2 re-runs per head SHA:
1. Count existing `<!-- talos:ci-rerun <HEAD_SHA> -->` marker comments on the PR.
2. If fewer than 2: `bash scripts/pipeline-vcs.sh rerun-ci <PR_NUMBER>`, then post
   a PR comment containing the marker `<!-- talos:ci-rerun <HEAD_SHA> -->` and a
   one-line note. Re-check on the next pass.
3. If 2 re-runs already happened for this SHA: post a comment listing the failing
   checks, do NOT merge. Not blocked — just waiting for a human or a new commit.

**CHANGELOG serialization guard:** Before merging, check whether the PR's base branch is behind `origin/main` AND another pipeline PR has merged since this branch was cut. If so, run `git fetch origin && git merge origin/main` in the developer's worktree branch first, then re-push. On CHANGELOG conflicts, keep BOTH entries (newest first). (Changelog fragment directories are out of scope for v1 — the inline-merge rule above is sufficient for this repo size.) *(After the fix in #102: `check-approval-sha` filters out base-branch-only changes, so this sync no longer invalidates markers for files the PR did not touch. If the sync modifies a file the PR also touched, markers for that role are intentionally invalidated — verify the merge resolution and re-stamp.)*

**Human-merge mode (`MERGE_AUTO = false`):** every gate above still applies —
approval labels, `skip-qa` rules, forbidden-files, CI. When everything is green,
do NOT call `merge-pr`. Instead hand off to a human:

1. If the PR already carries `pipeline:approved`, the hand-off happened on a
   previous pass — skip it silently (it is waiting for a human, not blocked).
2. `bash scripts/pipeline-vcs.sh label-pr <PR_NUMBER> --add pipeline:approved`
3. Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/orchestrator}"`
   Render approved.md and post it on the PR:
   VERDICT="APPROVED" SUMMARY="all stages passed — ready for human merge"
   `bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"`
   If exit non-zero, report the failure in the relay message.
4. Relay: `bash scripts/pipeline-notify.sh orchestrator "#<N>" "all stages passed — PR #<PR_NUMBER> ready for human merge" <N>`
5. STOP. Do NOT close the issue and do NOT run the post-merge steps — the issue
   closes when the human merges (the "heal merged-but-open issues" sweep in
   Step 0 completes the post-merge bookkeeping on a later run).

Otherwise (`MERGE_AUTO = true`), if green, merge: `bash scripts/pipeline-vcs.sh merge-pr <PR_NUMBER>`

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/orchestrator}"`

After merging:
1. Render issue-closed.md on the ISSUE: VERDICT="CLOSED" SUMMARY="all stages passed"
   `bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY" --allow-closed`
   If exit non-zero, report the failure in the relay message; do not skip the close-issue step.
   (GitHub auto-closes the issue via the PR's `Closes #N` keyword at merge time, roughly
   20 seconds before this step runs — `--allow-closed` is required here.)
2. `bash scripts/pipeline-vcs.sh close-issue <N> "closed by PR #<PR_NUMBER>"`
3. `bash scripts/pipeline-status.sh <N> "Done"`
4. **Remove the developer worktree.** `bash scripts/pipeline-worktree.sh remove <N>` — deletes the `fix/issue-<N>-*` worktree and its now-merged local branch so worktrees don't accumulate on disk. Idempotent: a no-op if the worktree is already gone. Do this on every merge, including when healing a merged-but-open issue in Step 0.
5. Relay: `bash scripts/pipeline-notify.sh orchestrator "#<N>" "all stages passed — merged PR #<PR_NUMBER>, issue closed" <N>`
6. Lifecycle: `bash scripts/pipeline-notify.sh merged "#<N>" "PR #<PR_NUMBER> merged" <N>`
7. Lifecycle: `bash scripts/pipeline-notify.sh issue-closed "#<N>" "issue resolved" <N>`

---

## Step 5 — End of run summary

After processing all issues, print a summary table:

| Issue | Outcome | PR | Notes |
|-------|---------|----|----|
| #N    | merged  | #M | ... |
| #N    | blocked | —  | reason |
| #N    | in-flight | #M | waiting on CI |

---

## Rules

1. Never call `gh`, `glab`, or `az` directly — always use `bash scripts/pipeline-vcs.sh <verb>`.
2. Never merge a PR with failing or pending required CI checks.
3. Never merge a PR that has `pipeline:blocked`.
4. Never use `main` as the base branch unless `base_branch` config explicitly says `main`.
5. Worktree subagents must edit files at THEIR OWN worktree path, not the orchestrator's checkout.
6. Multi-PR issues: all PRs except the last say "Part of #N"; the last says "Closes #N".
   The pipeline enforces this — a `Closes #N` PR is blocked at merge time if any other PRs
   for that issue are still open.
7. Never guess a PR number — always read it from `pipeline-vcs.sh view-pr <branch>`.
8. Stage comments are mandatory when `comments.enabled = true`; fall back to inline text if template missing.
9. Role-event notifications are mandatory after each subagent (conversation stream protocol). PM is exempt.
10. Notification failures never block the pipeline (pipeline-notify.sh always exits 0).
    Always pass the issue number as the 4th arg: `pipeline-notify.sh <event> "#<N>" "<msg>" <N>`
11. Board update failures are warnings — the pipeline continues.
12. Attempt counting is durable and enforced by `record-attempt`: call `bash scripts/pipeline-vcs.sh record-attempt <N> <stage>` before each developer re-dispatch.  When it exits non-zero (either `max_fix_attempts` consecutive same-stage failures OR `max_total_dispatches` total dispatches reached): set `pipeline:blocked`, notify, move on.  Never count attempts in orchestrator memory — the helper is the source of truth.
13. In file mode: skip board calls, skip QA/reviewer/security/docs, developer commits to branch directly.
14. Never merge a PR that fails `check-pr-files` — secret-like files require a human; `skip-qa` does not waive this gate (nor CI).
15. Only the developer stage may move HEAD in the orchestrator's checkout. All other stages (reviewer, security, docs, QA, validator, PM) must never run `git checkout`, `git switch`, or `git pull` in their working directory — read diffs via `diff-pr` only. This holds regardless of `execution.isolation` mode.
16. `comment-issue`, `comment-pr`, `create-issue`, and `create-pr` exit non-zero when their POST fails. A stage must not assert a filing landed without a non-empty URL returned by the command. For `create-pr` failures, set `pipeline:blocked` immediately — no PR means all downstream stages are impossible.
17. Run all long-running work in the **foreground** — never append `&`, use `nohup`, or call `disown`. Do not poll for child exit with `until ! pgrep …; do sleep N; done`. The reason: when a stranded background child finally exits, the harness interprets its exit as a new completion event; those duplicates are indistinguishable from real completions on arrival (observed: 210 stranded shells at peak, one agent emitting 5 spurious "task finished" signals 90 minutes after finishing, two agents stopped by hand). Talos cannot suppress the harness-side notification — it can only ensure no background children remain.
18. Under `isolation: worktree`, the developer and QA stages must export `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` before running any `verify:` command. Both values are present in the task prompt. Under `isolation: branch`, `TALOS_WORKTREE_PATH` is not meaningful — skip or warn, do not fabricate a path. This is instruction-based and not airtight on the native path — a stage that ignores it runs verify without the exports. The exports make a degraded run visible (verify scripts can self-check) without claiming to make it impossible. The adapter path (`pipeline-agent.sh`) exports them as real shell variables automatically.
