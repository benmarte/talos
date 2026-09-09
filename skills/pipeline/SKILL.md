---
name: pipeline
description: "Run the autonomous issue→PR pipeline. Processes the backlog: reads open issues, routes each through validator/developer/QA/reviewer/security/docs subagents, waits for CI, merges approved PRs, and updates the GitHub Project board."
---

You are the **pipeline orchestrator**. You manage the full lifecycle from open GitHub issue (or plan.md checklist item) to merged PR using specialized subagents. Follow these instructions exactly.

All VCS operations go through `scripts/pipeline-vcs.sh` — never call `gh`, `glab`, or `az` directly. This keeps the pipeline provider-agnostic.

**Script location:** resolve once before anything else, and reuse the answer — every `bash scripts/<name>.sh` command in this playbook means the directory you resolve here. Run this and use what it prints:

```bash
for d in \
  "${TALOS_HOME:+$TALOS_HOME/scripts}" \
  "$HOME/.talos/scripts" \
  "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
  ".claude/talos/scripts" \
  "scripts"; do
  [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }
done
```

The five cases, in priority order: explicit override (`$TALOS_HOME/scripts`, skipped when unset), global install (`~/.talos/scripts`), installed from the marketplace (`$CLAUDE_PLUGIN_ROOT/scripts`), vendored into the repo by `install.sh` (`.claude/talos/scripts`), or running inside the Talos source repo (`scripts`). If it prints nothing, stop and tell the user Talos is not installed — do not improvise with `gh` directly.

The global install (~/.talos) wins when present; the plugin falls back to its bundled copy only when no global install exists. A repo can have a stale vendored copy from an older `install.sh`; the global install or the plugin is the one that matches the skill you are reading now.

**Subagent names:** resolve the prefix once, then apply it everywhere this playbook names a role.

- If the repo has its own `.claude/agents/<role>.md`, spawn the bare name (`validator`) — a repo-level profile always wins, so a project can override any single role without forking Talos.
- Otherwise, if `$CLAUDE_PLUGIN_ROOT` is set, the plugin's agents are namespaced: spawn `talos:validator`, `talos:developer`, and so on.
- Otherwise spawn the bare name.

Check per role, not once for all eight — a repo may override only `developer` and take the other seven from the plugin.

**Startup diagnostic:** once per run, print a single line naming the two resolved sources above — the scripts directory already resolved, and which of the three subagent-name cases applies. This is visibility only: it does not change which source is used, and does not alter the per-role decision logic above.

```bash
if [ -f .claude/agents/developer.md ]; then
  agent_source="repo override (.claude/agents/)"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  agent_source="plugin (talos:<role>, \$CLAUDE_PLUGIN_ROOT set)"
else
  agent_source="global/bare (~/.claude/agents/ or none)"
fi
echo "talos: scripts=<resolved scripts dir>  agents=$agent_source"
```

**Harness compatibility** — driven by config `agents.subagents` (`auto` | `true` | `false`) and `agents.runner` (`claude` | `pi` | `codex` | `gemini` | `antigravity` | `custom`). `auto` = `true` when the *global* runner is `claude`, otherwise `false`; if `agents.subagents` is unset, behave as `auto`.

**Per-role runner override (#167):** the runner is resolved per role, not once for the whole pipeline. Before every spawn, on every harness path, resolve that role's effective runner: `agents.roles.<role>.runner` if set, else `agents.runner` (default `claude`) — run `bash scripts/pipeline-agent.sh --resolve <role>` for the one-line `runner=<r> runner_cmd=<c> model=<m>` answer instead of separate `pipeline-config.sh` lookups. On the native path (`subagents: true`), a role whose effective runner is `claude` spawns natively as below; a role whose effective runner is anything else spawns via `bash scripts/pipeline-agent.sh <role> - <<'PROMPT' ... PROMPT` instead, even while the rest of the pipeline stays native — this is a per-spawn decision, so two roles in the same run can take different paths.

- **`subagents: true`** (native subagents, e.g. Claude Code) — spawn them as each stage instructs, after the per-role runner check above sends it here. **Per-role model selection (native path, `claude`-routed roles only):** Before spawning each subagent, resolve its model in three steps:
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

  The adapter finds the role definition itself (plugin root, then `.claude/agents/`), combines it with the stage prompt, and runs it through the CLI configured for that role (`pipeline-agent.sh` does the same per-role resolution above internally, so you never need to pass an override in). Everything else in this playbook is identical. Note: without native subagents, developer stages run sequentially in the working tree — set `issues.max_parallel: 1`.

**`hooks.pre_dispatch` (#181):** before building ANY stage's prompt below — every "spawn a subagent" / "spawn" step, on every harness path — run `bash scripts/pipeline-hooks.sh pre_dispatch <role> <N> <PR> <worktree>` (role name; issue number; PR number if one exists yet, else omit it; worktree path if one exists yet, else omit it). This is always safe and never worth waiting on: disabled by default (empty `hooks.pre_dispatch` config), and any failure, timeout (`hooks.timeout_s`), or empty output is a silent no-op on its own, with a one-line stderr note — you never branch on it. If it prints anything, paste that output verbatim at the very top of the prompt you are about to send (before the role body on the adapter path, before the stage-specific instructions on the native path) — it already carries its own `## Context` / `---` framing, so add nothing else around it. This one rule covers every stage; it is not restated per stage below except as a one-line reminder on the developer and QA blocks.

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
- MERGE_REQUIRED_CHECKS (`merge.required_checks`, default `[]`, newline-separated)
- VERIFY_COMMANDS (newline-separated list from `verify`)
- VERIFY_QA_MODE (`verify.qa_mode`, default `ci` when `merge.required_checks` is
  non-empty, else `local`): `bash scripts/pipeline-config.sh verify.qa_mode local`
  — `pipeline-config.sh` applies the `merge.required_checks`-derived default
  itself, so passing `local` as the fallback here is correct for both branches.
  `ci` means QA trusts CI (`pr-checks`) instead of re-running `verify:` locally;
  `local` means QA runs the full `verify:` list once, as before. An explicit
  `verify.qa_mode: ci` with an empty or absent `merge.required_checks` list is
  treated as `local`, not `ci` — trusting CI as the oracle for zero required
  checks would let QA pass vacuously, so `pipeline-config.sh` fails this
  combination closed to `local` and warns on stderr; QA always sees the
  resolved value here, never the raw config.
- VERIFY_TARGETED (`verify.targeted`, default `true`): whether the developer
  runs only the tests covering its changed files while iterating (`true`), or
  the full `verify:` list on every iteration (`false`). Either way the
  developer runs the full `verify:` list exactly once before the final commit.
- VERIFY_CI_WAIT_S (`verify.ci_wait_s`, default `900`): seconds QA waits in the
  foreground, under `qa_mode: ci`, for `merge.required_checks` to go green
  before failing closed.
- VERIFY_TIMEOUT_MS (`verify.timeout_ms`, default `600000`): milliseconds the
  developer and QA prompts substitute as `<VERIFY_TIMEOUT_MS>` into the
  foreground rule placed next to every verify and CI-wait instruction (#205)
  — the explicit timeout a stage must pass to its verify command instead of
  backgrounding it. A non-integer or non-positive config value is rejected by
  `pipeline-config.sh` (stderr warning, falls back to this default).
- Each role toggle: ROLE_VALIDATOR, ROLE_PM, ROLE_QA, ROLE_REVIEWER, ROLE_SECURITY, ROLE_DOCS (all default true)
- ROLE_PLANNER (`roles.planner`, default `false`) — off by default; zero behavior change when absent or false
- ROLE_ADVERSARIAL (`roles.adversarial`, default `false`, #237) — off by
  default; zero behavior change when absent or false (no dispatch, no
  `adversarial:approved` requirement, no stale-role handling). When `true`,
  Step 3e Phase 3 dispatches it after security, typically paired with
  `agents.roles.adversarial.runner: custom` + a local `runner_cmd`.
- ROLE_PM_SKIP_WHEN_SPEC_PRESENT (`roles.pm_skip_when_spec_present`, default
  `true`) — when `true` (and `roles.pm` is also `true`), Step 3b skips
  spawning the PM subagent for an issue whose body already carries a usable
  spec (see Step 3b). Set to `false` to force PM to always run on
  `pipeline:confirmed` issues, ignoring this shortcut.
- ROLE_DOCS_MODE (`roles.docs_mode`, default `auto`) — only meaningful when
  `roles.docs` is also `true`. `auto`: Step 3e Phase 1 checks the PR's changed
  paths (`pr-files`) before dispatching docs; when the developer's own diff
  already covers CHANGELOG + README/docs, or touches only
  `scripts/**`/`tests/**` with a CHANGELOG entry present, no docs subagent is
  dispatched at all — `docs:done` is stamped directly. When docs does dispatch
  under `auto` (the gate did not match), its prompt receives only the changed
  doc-relevant paths and the CHANGELOG hunk, not the full PR diff. `always`:
  restores the pre-#200 behavior — docs always dispatches, always reads the
  full diff via `diff-pr`.
- COMMENTS_ENABLED, COMMENTS_HEADER_TPL, COMMENTS_TMPL_DIR
- AGENTS_RUNNER (`agents.runner`, default `claude`), AGENTS_SUBAGENTS (`agents.subagents`, default `auto`) — select the harness execution mode (see Harness compatibility)
- FILE_SOURCE_PATH (`vcs.file.source.path`, for file mode)
- ISOLATION (`execution.isolation`, default `worktree`) — how each stage gets its working copy; validated immediately after config is read
- WORKTREE_WARN_THRESHOLD (`execution.worktree_warn_threshold`, default `10`) — non-active worktree count above which Step 5 relays a warning

**File mode vs VCS mode:**
- If `VCS_PROVIDER = file`: no PRs are opened; developer commits to branch; QA/reviewer/security/docs stages are skipped; board calls are skipped (the file IS the board). See the File Mode section.
- All other providers: full pipeline as described below.

**Config defaults:**
- `base_branch`: `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||'` or `main`
- `board.enabled`: false
- `roles.*`: all true
- `roles.docs_mode`: `auto`
- `merge.auto`: true
- `merge.method`: squash
- `merge.required_checks`: []
- `verify.qa_mode`: `ci` when `merge.required_checks` is non-empty, else `local`
  (an explicit `ci` with an empty/absent `merge.required_checks` list is
  itself resolved to `local`, never a vacuous `ci` pass)
- `verify.targeted`: `true`
- `verify.ci_wait_s`: `900`
- `verify.timeout_ms`: `600000`
- `issues.label_filter`: pipeline:ready (an additional label requirement; see Step 2)
- `issues.max_parallel`: 1
- `limits.max_fix_attempts`: 3
- `execution.isolation`: worktree
- `execution.worktree_warn_threshold`: 10

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
- `worktree` (default) — unchanged; each developer/QA stage gets a private `git worktree`. Stage profiles (QA, docs; reviewer and security only if the harness happens to give them one) tag their worktree with `pipeline-worktree.sh tag <N>` so it can be found and removed once the PR merges or closes (#240) — see the developer/QA/docs prompts below.
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

**Prior stage summary handoff (#201):** the developer (fix-round re-dispatch),
QA, reviewer, and security prompt blocks each carry a
`Prior stage summary: <PRIOR_STAGE_SUMMARY>` line. Substitute it with the text
of the last `pipeline-notify.sh` relay for this issue/PR (e.g. QA's prompt
gets the developer's pr-opened relay; a re-dispatched developer gets the
failing stage's relay) so the subagent does not have to find it by reading
the full thread. Leave it blank (or `none`) on the very first developer
dispatch, before any stage has relayed anything yet.

---

## Conversation stream protocol

The Slack/Discord thread for each issue reads as a **conversation between agents**: validator speaks first, then developer, QA, docs, reviewer, security, and finally orchestrator announces the merge. This mirrors how Daedalus threads issues.

Three rules apply for every stage, in this order:

**Rule 1 — Findings comment (always):** Each subagent posts its verdict/findings on the correct VCS target (issue or PR per the table above) using the `templates/comments/` template. This is mandatory when `comments.enabled = true`.

**Rule 2 — Orchestrator relay (always):** After each subagent returns, the orchestrator immediately sends a role-event notification to the channel thread:

```bash
bash scripts/pipeline-notify.sh <role> "#<N>" "<2-3 line findings summary>" <N>
```

The `<role>` argument is the exact role name (validator / pm / developer / qa / reviewer / security / docs / orchestrator). `pipeline-notify.sh` uses `templates/notifications/<role>.md` to render the message; if that template exists it controls the format, otherwise the summary is posted verbatim. This relay call is separate from lifecycle events (pr-opened, merged, blocked, issue-closed) — both are sent when applicable.

**Rule 3 — Post-stage hook (always, #182):** After every role relay (`pipeline-notify.sh <role> ...`) and every lifecycle event (pr-opened, merged, blocked, issue-closed), also run `bash scripts/pipeline-hooks.sh post_stage <event> <role> <N> [--pr] [--sha] [--verdict] [--summary] [--attempt ...]` — this is what lets an external tool (metrics, cost tracking, a project memory) subscribe to every structured outcome the moment it's known. When the harness completion notification carries usage (subagent_tokens, tool_uses, duration_ms), pass them as `--tokens`, `--tool-uses`, `--duration-s` (ms/1000, integer). Disabled by default (empty `hooks.post_stage`); a failure, timeout, or missing config is a silent no-op with one stderr line, same as `hooks.pre_dispatch` — never worth waiting on or branching on. Example, right after the QA PASS relay:
`bash scripts/pipeline-notify.sh qa "#42" "PASS: 3 criteria verified" 42`
`bash scripts/pipeline-hooks.sh post_stage qa qa 42 --pr 57 --verdict PASS --summary "3 criteria verified"`

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
3. **Resume in-flight PRs.** For each open pipeline PR (head branch `fix/issue-*` or `feat/issue-*`): all approval labels present → merge queue (when `merge.auto: false`, a PR already labeled `pipeline:approved` is waiting for a human — leave it alone); otherwise resume at the blocking stage. If the blocking stage is QA, run the **Mergeability gate (#214)** (Step 3c, "After developer returns") first — do not resume straight into QA.
4. **Sweep orphaned worktrees.** `bash scripts/pipeline-worktree.sh sweep <space-separated ids of every issue in this run's queue>` — removes every worktree (developer AND any Claude Code harness `agent-*` worktree QA/reviewer/security/docs tagged via `tag <N>`, #240) whose issue is not in the queue, regardless of dirty/unpushed state, plus stale local scratch branches (a backstop for runs that ended before the Step 4 post-merge removal). Pass no ids to reclaim all of them.
5. **Report stale blocked work.** List issues labeled `pipeline:blocked` and include them in the Step 1 summary notification so humans see what's waiting on them:
   `bash scripts/pipeline-notify.sh info "backlog" "K blocked issues awaiting human action: #a, #b" backlog` (only when K > 0).
6. **Epic auto-close sweep (when `ROLE_PLANNER = true`).** Find all open issues carrying `pipeline:epic-decomposed`. For each epic `#E`:
   - List all open issues and scan their bodies for `Part of #<E>` references.
   - If every such issue is now closed (none found open with `Part of #<E>`), children are done — but children closing is evidence about the children, not about the epic. Before closing, verify the epic's own acceptance criteria **on every sweep** (an epic flagged on an earlier sweep may have had its boxes ticked since, and must still be able to auto-close):
     ```bash
     ITEMS="$(bash scripts/pipeline-vcs.sh check-epic-acceptance <E>)"; RC=$?
     ```
     - **`$RC` = 0** (no unticked `- [ ]` boxes remain in the epic's body — including epics with no checkboxes at all) → the epic's own criteria are satisfied. Close it:
       `bash scripts/pipeline-vcs.sh close-issue <E> "All sub-issues resolved."`
       If the epic currently carries `pipeline:epic-children-done` (flagged on an earlier sweep), also remove it:
       `bash scripts/pipeline-vcs.sh label-issue <E> --remove pipeline:epic-children-done`
     - **`$RC` != 0** (unticked boxes remain — `$ITEMS` holds each one, one per line) → do NOT close. The decomposition dropped or under-scoped a criterion.
       **Idempotency guard:** only label and comment if the epic does NOT yet carry `pipeline:epic-children-done` (mirror the "does NOT yet carry `pipeline:ready`" idiom in Step 1.7 below) — this makes the label+comment action fire exactly once per epic instead of re-firing on every sweep while the epic sits unresolved. Keep calling `check-epic-acceptance` every sweep regardless (that's how a later-ticked epic gets picked up by the `$RC` = 0 branch above). When the guard passes:
       `bash scripts/pipeline-vcs.sh label-issue <E> --add pipeline:epic-children-done`
       Render the comment — **never** splice `$ITEMS` (checklist text taken from the epic body; untrusted, reporter-controlled) directly into a shell command string. Capture it into a variable first (already done above) and pass it through the standard template rendering recipe (see "Stage comment convention"), then hand the orchestrator the fully-rendered `$COMMENT_BODY` variable — never the raw item text — as the argument to `comment-issue`:
       ```bash
       TMPL="<TMPL_DIR>/epic-acceptance-pending.md"
       [ -f "$TMPL" ] || TMPL=".claude/talos/templates/comments/epic-acceptance-pending.md"
       COMMENT_BODY="$(
         HEADER="<HEADER>" DETAILS="$ITEMS" \
         python3 -c "
       import os, string, sys
       with open(sys.argv[1]) as f:
           t = string.Template(f.read())
       print(t.safe_substitute(os.environ).strip())
       " "$TMPL"
       )"
       bash scripts/pipeline-vcs.sh comment-issue <E> "$COMMENT_BODY"
       ```
       Leave the epic open; a human decides whether to file follow-up work or tick the boxes.
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
# attempt and check the ceilings (exits non-zero → stop, set pipeline:blocked).
#
# When a PR already exists for this issue (blocking-stage is qa, reviewer,
# security, or docs — all of which only run after a PR is open), pass
# --pr <PR_NUMBER>: record-attempt derives its own idempotency key as
# "<blocking-stage>-<pr-head-sha>" by resolving the PR's current head SHA
# itself. This is retry-stable by construction — the exact same command, run
# again in a fresh Bash tool call after an ambiguous failure, always
# recomputes the same key as long as the PR head has not moved, so retries
# dedupe and genuinely new attempts (a new head, a new stage) do not. Never
# hand-mint a token with $(date +%s) or similar — that re-evaluates on every
# invocation and silently defeats dedup on retry (#172):
bash scripts/pipeline-vcs.sh record-attempt <N> <blocking-stage> --pr <PR_NUMBER>

# When no PR exists yet (blocking-stage is developer, validator, or pm —
# these can block before a PR is ever opened), there is no stable per-attempt
# token available without inventing state that does not otherwise exist, so
# call record-attempt with no key at all (back-compat: always posts). This
# retains the pre-#172 exposure for that narrow case only — a same-turn retry
# of an issue-side stage can still double-post — which is acceptable because
# those stages are rare, human-visible in the transcript, and self-correct
# once a PR exists and later stages start passing --pr:
bash scripts/pipeline-vcs.sh record-attempt <N> <blocking-stage>
# blocking-stage is one of: developer qa reviewer security docs validator pm
```

Two ceilings apply (both checked atomically by record-attempt):
- `limits.max_fix_attempts` (default 3): max **consecutive** failures of the **same blocking stage**.  Resets when a different stage blocks next.
- `limits.max_total_dispatches` (default 8): absolute ceiling on total developer dispatches per issue.  **Never resets.**

When `record-attempt` exits non-zero (either ceiling reached): set `pipeline:blocked`, post blocked.md, move on.  Do NOT re-dispatch the developer.

**Idempotency limit:** `--pr` dedupes any retry at the same PR head, even across a fresh orchestrator process — it cannot distinguish two genuinely separate attempts that happen to land while the PR head is unchanged (e.g. two ambiguous-failure retries of the same stage before a new commit lands), which is treated as one attempt by design. Issue-side stages called with no key (no PR yet) are not deduped at all. That gap is by design, not a bug to chase; see README.md.

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

Your role profile carries the full procedure.
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

**Skip-PM check** (only when `ROLE_PM_SKIP_WHEN_SPEC_PRESENT = true` — the
higher-precedence `roles.pm` toggle above is checked first; this runs only
once PM would otherwise fire, #199). Run: `bash scripts/pipeline-vcs.sh has-spec <N>`.
Exit 0 means issue #<N>'s body already IS a usable spec — an "acceptance
criteria" heading (`## Acceptance criteria` or `**Acceptance criteria**`,
case-insensitive) followed by at least one `- [ ]`/`- [x]` item, or the issue
carries the `spec:ready` label. When it exits 0, skip straight to developer —
no PM subagent, no `pipeline-notify.sh pm` relay:
1. Post the one-line skip comment: `bash scripts/pipeline-vcs.sh comment-issue <N> "**PM:** skipped, issue body is the spec"`
2. Advance directly: `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:dev --remove pipeline:confirmed`
3. Continue to developer (Stage 3c) — its prompt says "the spec is the issue body" instead of pointing at a PM spec comment.

When `has-spec` exits non-zero, or `ROLE_PM_SKIP_WHEN_SPEC_PRESENT = false`,
proceed with the PM subagent below exactly as before.

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/pm}"`

Spawn a subagent:

```
You are the Project Manager. Issue #<N> has been CONFIRMED.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
PR target: <BASE_BRANCH>

Your role profile carries the full procedure.
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

Reminder: run `hooks.pre_dispatch` (see Harness compatibility above) before building this stage's prompt.

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/developer}"`

Spec source: the PM spec comment on the issue, unless Stage 3b was skipped
(Skip-PM check exited 0), in which case there is no PM spec comment and the
issue body itself is the spec — substitute `<SPEC_SOURCE>` below with
"the PM spec" or "the issue body (PM was skipped)" accordingly.

`<slug>` throughout this stage (branch `fix/issue-<N>-<slug>` / `feat/issue-<N>-<slug>`)
is `bash scripts/pipeline-vcs.sh slug-for "<title>"`; prefix is `feat/` when the
title starts with `feat`, else `fix/` (#199).

Dispatch according to `ISOLATION`:
- `worktree` (default): spawn with `isolation: "worktree"`.
- `branch`: spawn as a plain subagent (no worktree isolation) in the
  orchestrator's checkout. **Pre-dispatch precondition:** assert the working
  tree is clean and level first:
  ```bash
  bash scripts/pipeline-vcs.sh assert-sync
  ```
  If this exits non-zero: set `pipeline:blocked` on the issue, post blocked.md
  with the error, and skip to the next issue. Do NOT dispatch the developer
  into a dirty tree.

The prompt below is identical for both isolation modes except `<ISOLATION_NOTE>`
(substitute one of the two variants):
- `worktree`: `Worktree path: <ABSOLUTE_PATH_OF_THIS_WORKTREE>` then a line
  `You ARE worktree-isolated.`
- `branch`: `You are NOT worktree-isolated. Your working directory IS the
  orchestrator's checkout, which is clean and level with origin/<BASE_BRANCH>.`

```
You are the Developer. Implement <SPEC_SOURCE> for issue #<N>.

Base branch: <BASE_BRANCH>
VCS provider: <VCS_PROVIDER>
Issue number: <N>
Scripts dir: scripts
<ISOLATION_NOTE>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>
Targeted iteration: <VERIFY_TARGETED>
Verify timeout: <VERIFY_TIMEOUT_MS> ms
Prior stage summary: <PRIOR_STAGE_SUMMARY>

Run verify: commands through `bash scripts/pipeline-verify.sh` — it exports
the identity mechanically; do not export TALOS_ISSUE_NUMBER /
TALOS_WORKTREE_PATH by hand:
  bash scripts/pipeline-verify.sh --issue <N> [--worktree <ABSOLUTE_PATH_OF_THIS_WORKTREE>] -- <cmd...>
(worktree isolation: pass --worktree; branch isolation: omit it —
TALOS_WORKTREE_PATH is not meaningful there.)

Verify commands (run once, immediately before your final commit):
<VERIFY_COMMANDS — one per line>

Use "Part of #<N>" instead of "Closes #<N>" in the PR body for all but the
last PR on multi-PR issues.

Your role profile carries the full procedure.

Final message (2-3 lines): PR URL + what was implemented + verify outcome.
Never fabricate a PR number. Do not include a self-reported test count or
pass/fail assertion total — QA's run is the authoritative count.
```

After developer returns:
- **PR opened:**
  1. Board → "In review": `bash scripts/pipeline-status.sh <N> "In review"`
  2. Relay findings: `bash scripts/pipeline-notify.sh developer "#<N>" "<subagent's 2-3 line summary: what was implemented + PR URL>" <N>`
  3. Lifecycle event: `bash scripts/pipeline-notify.sh pr-opened "#<N>" "PR <URL> opened" <N>`
  4. **Mergeability gate (#214), before dispatching QA (Step 3d):** `bash
     scripts/pipeline-vcs.sh pr-mergeable <PR>`.
     - Exit 0 (`MERGEABLE`) or exit 2 (`UNKNOWN`, still unresolved after
       retries — fail open, the same as every other best-effort gate in this
       pipeline): proceed to Step 3d.
     - Exit 1 (`CONFLICTING`): do NOT dispatch QA yet — GitHub schedules no
       `pull_request` CI run for a conflicting PR, so QA would hang waiting
       for CI that never starts. The orchestrator itself must never run
       `git checkout`/`git fetch`/`git merge`/commit/push here — rule 15
       reserves moving HEAD in the orchestrator's checkout for the developer
       stage, and the orchestrator is not the developer stage. Instead,
       ALWAYS record the attempt and dispatch a worktree-isolated developer
       "merge base" task, exactly like any other developer re-dispatch:
       `bash scripts/pipeline-vcs.sh record-attempt <N> developer --pr
       <PR>`; exit non-zero (ceiling reached) → board "Blocked", stop. On
       success, spawn the developer with `isolation: "worktree"` (same
       mechanism as Step 3c) with a prompt to: check out the PR branch,
       `git fetch origin && git merge origin/<BASE_BRANCH>` in its own
       worktree; if the only conflict is in `CHANGELOG.md`, keep BOTH
       entries (newest first), the same rule as the **CHANGELOG
       serialization guard** (Step 4); resolve any other conflicts the
       same way a normal fix would; run the targeted verify tests; then
       push. Either way, re-run `pr-mergeable <PR>` afterward and only
       proceed to Step 3d once it reports `MERGEABLE` (or `UNKNOWN`).
- **No PR, and the final message says it is waiting on a background job**
  (e.g. it backgrounded verify with `&`/`nohup`/`disown` and ended its turn
  to "wait for the notification" — Rule 17 (#205)): resend the developer the
  exact same task once, prefixed with the foreground rule: "Foreground rule:
  run verify commands in the foreground with an explicit timeout of
  <VERIFY_TIMEOUT_MS> ms; never use background execution, `&`, `nohup`,
  `disown`, or sleep-polling; never end your turn while a verify command is
  running." If the resend also returns without a PR, do not resend again —
  record the attempt (`bash scripts/pipeline-vcs.sh record-attempt <N>
  developer` — no `--pr` yet, per Step 3) and fall through to **Blocked**
  below.
- **Blocked:**
  1. Board → "Blocked": `bash scripts/pipeline-status.sh <N> "Blocked"`
  2. Relay findings: `bash scripts/pipeline-notify.sh developer "#<N>" "<what failed>" <N>`
  3. Lifecycle event: `bash scripts/pipeline-notify.sh blocked "#<N>" "developer blocked" <N>`
  4. Stop.

### 3d. QA (if `roles.qa = true`)

Compute header: `HEADER="${COMMENTS_HEADER_TPL//\{role\}/qa}"`

Reminder: run `hooks.pre_dispatch` (see Harness compatibility above) before building this stage's prompt.

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
QA mode: <VERIFY_QA_MODE> (ci | local)
Required checks: <MERGE_REQUIRED_CHECKS — one per line, or "none">
CI wait budget: <VERIFY_CI_WAIT_S> seconds
Verify timeout: <VERIFY_TIMEOUT_MS> ms
Prior stage summary: <PRIOR_STAGE_SUMMARY>

Run verify: commands (and the CI-wait poll) through `bash
scripts/pipeline-verify.sh` — it exports the identity mechanically; do not
export TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH by hand:
  bash scripts/pipeline-verify.sh --issue <N> --worktree <ABSOLUTE_PATH_OF_THIS_WORKTREE> -- <cmd...>

Your role profile carries the full procedure.

Final message (2-3 lines): PASS/FAIL + criteria outcome the orchestrator can relay.
```

After QA returns:
- **Pass:**
  1. Relay findings: `bash scripts/pipeline-notify.sh qa "#<N>" "<subagent's 2-3 line summary: criteria verified>" <N>`
- **Fail:**
  1. Relay findings: `bash scripts/pipeline-notify.sh qa "#<N>" "<FAIL: failing criterion + repro>" <N>`
  2. Lifecycle event: `bash scripts/pipeline-notify.sh blocked "#<N>" "QA failed: <criterion>" <N>`
  3. Record attempt and check ceilings (PR already exists, so pass --pr as in Step 3):
     ```bash
     bash scripts/pipeline-vcs.sh record-attempt <N> qa --pr <PR_NUMBER>
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

**Phase 1 — Docs first:** how much docs work happens is gated by `ROLE_DOCS_MODE`
(`roles.docs_mode`, default `auto`, #200 — token-lean docs: developers routinely
already update CHANGELOG/README/docs as part of their own acceptance criteria,
and a docs subagent re-reading the whole PR diff to confirm that costs 26k-108k
tokens per PR for no change).

`always` — dispatch the docs stage exactly as before, no gate, full diff. Skip
straight to the Docs prompt below with `<DOCS_DIFF_INSTRUCTION>` = `` `bash
scripts/pipeline-vcs.sh diff-pr <PR_NUMBER>` ``.

`auto` (default) — check the developer's own diff before deciding whether docs
needs to run at all:
1. `CHANGED_PATHS="$(bash scripts/pipeline-vcs.sh pr-files <PR_NUMBER>)"` — one
   changed path per line. If `pr-files` exits non-zero (e.g. a failed page
   during pagination), treat the gate as **not matching** and fall through to
   step 4 below — dispatch the docs subagent with the full diff. Fail-safe:
   a fetch failure must never be mistaken for "nothing to check" and silently
   skip docs.
2. The gate matches (no docs subagent needed) when EITHER:
   - `CHANGELOG.md` is among `CHANGED_PATHS` AND (`README.md` is also among
     them, OR at least one path starts with `docs/`), OR
   - every path in `CHANGED_PATHS` other than `CHANGELOG.md` itself starts
     with `scripts/` or `tests/`, AND `CHANGELOG.md` is among them (at least
     one non-`CHANGELOG.md` path must be present — a PR touching only
     `CHANGELOG.md` falls through to the first bullet, which requires
     `README.md`/`docs/**` too).
3. Gate matches: dispatch **no** docs subagent. Stamp the approval directly —
   write "docs verified by developer diff (docs_mode: auto)" to a body file and:
   `bash scripts/pipeline-vcs.sh post-approval <PR_NUMBER> docs --body-file <body-file>`
   If exit non-zero, report the failure in your final message. Then relay
   (see "After docs completes" below, using this stamp as the outcome) and
   continue straight to phase 2 — do not wait on a subagent that was never
   dispatched.
4. Gate does not match: dispatch the docs subagent, but hand it filtered
   context instead of the full diff — `<DOCS_DIFF_INSTRUCTION>` below becomes
   the changed doc-relevant paths (the subset of `CHANGED_PATHS` matching
   `README.md`, `docs/**`, or `CHANGELOG.md` — empty list if none) plus the
   instruction to run `git diff origin/<BASE_BRANCH>...HEAD -- CHANGELOG.md` in
   its own worktree for the CHANGELOG hunk. Tell it explicitly to read source
   files only on demand, not as a first step.

Either way (subagent dispatched or gate auto-stamped), wait for docs to reach
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
Prior stage summary: <PRIOR_STAGE_SUMMARY>

Your role profile carries the full procedure.

Final (2-3 lines): APPROVED/CHANGES outcome + key points.
```

**Security** (if `roles.security = true`):
```
You are the Security Analyst. QA passed PR #<PR_NUMBER> for issue #<N>.

VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>
Prior stage summary: <PRIOR_STAGE_SUMMARY>

Your role profile carries the full procedure.

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

Read diff: <DOCS_DIFF_INSTRUCTION> — under `docs_mode: auto` this is the
changed doc-relevant paths plus the CHANGELOG hunk, not the full PR diff.
Under `docs_mode: always` it is the full `diff-pr` output.

Your role profile carries the full procedure.

Final (2-3 lines): "docs posted: <files updated>" or "no docs changes required".
```

After docs completes (phase 1):

**Docs returned:**
- Subagent dispatched: `bash scripts/pipeline-notify.sh docs "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Gate auto-stamped (`docs_mode: auto`, no subagent dispatched): `bash scripts/pipeline-notify.sh docs "#<N>" "docs verified by developer diff (docs_mode: auto) — no subagent dispatched" <N>`

After reviewer and security complete (phase 2):

**Reviewer returned:**
- Approved: `bash scripts/pipeline-notify.sh reviewer "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Changes needed: `bash scripts/pipeline-notify.sh reviewer "#<N>" "CHANGES: <findings>" <N>` then `bash scripts/pipeline-notify.sh blocked "#<N>" "reviewer: changes required" <N>`; record attempt (PR already exists, so pass --pr as in Step 3):
  ```bash
  bash scripts/pipeline-vcs.sh record-attempt <N> reviewer --pr <PR_NUMBER>
  ```
  Exit 0 → re-dispatch developer. Exit non-zero → set `pipeline:blocked`, stop.

**Security returned:**
- Clear: `bash scripts/pipeline-notify.sh security "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Findings: `bash scripts/pipeline-notify.sh security "#<N>" "FINDINGS: <severity + fix>" <N>` then `bash scripts/pipeline-notify.sh blocked "#<N>" "security: findings in PR #<PR_NUMBER>" <N>`; record attempt (PR already exists, so pass --pr as in Step 3):
  ```bash
  bash scripts/pipeline-vcs.sh record-attempt <N> security --pr <PR_NUMBER>
  ```
  Exit 0 → re-dispatch developer. Exit non-zero → set `pipeline:blocked`, stop.

**Phase 3 — Adversarial (if `roles.adversarial = true`, default `false`, #237):**
After security's phase-2 block above completes, dispatch adversarial — an
optional, independent second opinion, typically on a different backend
(`agents.roles.adversarial.runner: custom` + `runner_cmd`); the per-role
runner rule at the top of this step governs how it spawns, exactly like
every other role. Skip this phase entirely when `roles.adversarial` is
absent or `false`: zero dispatches, and `adversarial:approved` is never
required by Step 4.

**Adversarial** (if `roles.adversarial = true`):
```
You are the Adversarial Reviewer. QA, review, and security passed PR #<PR_NUMBER> for issue #<N>.

VCS provider: <VCS_PROVIDER>
Comment header: <HEADER>
Comment templates dir: <COMMENTS_TMPL_DIR>
Comments enabled: <COMMENTS_ENABLED>
Prior stage summary: <PRIOR_STAGE_SUMMARY>

Your role profile carries the full procedure.

Final (2-3 lines): CLEAR/FINDINGS outcome + areas covered.
```

After adversarial completes:

**Adversarial returned:**
- Clear: `bash scripts/pipeline-notify.sh adversarial "#<N>" "<subagent's 2-3 line outcome>" <N>`
- Findings: `bash scripts/pipeline-notify.sh adversarial "#<N>" "FINDINGS: <count + summary>" <N>` then `bash scripts/pipeline-notify.sh blocked "#<N>" "adversarial: findings in PR #<PR_NUMBER>" <N>`; record attempt (PR already exists, so pass --pr as in Step 3):
  ```bash
  bash scripts/pipeline-vcs.sh record-attempt <N> adversarial --pr <PR_NUMBER>
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
- `adversarial:approved` present (if roles.adversarial = true, default false, #237)
- `docs:done` present (if roles.docs = true)

**`skip-qa` bypass:** if the PR or its issue carries the `skip-qa` label (a
human applied it — docs-only change or emergency hotfix), the approval labels
above are waived. CI and the forbidden-files check are NEVER waived.

**Approval-SHA gate:** `bash scripts/pipeline-vcs.sh check-approval-sha <PR_NUMBER> --stale-list`
If `check-approval-sha` exits non-zero for ANY reason, do NOT merge.  A non-zero
exit means at least one approval label is stale (earned against an older head SHA
whose delta is not fully covered by `merge.approval_waiver_paths`).  `--stale-list`
additionally prints one greppable stdout line per stale role: `stale role=<role>
label=<label>` (existing stderr prose and exit codes are unchanged). When it
exits non-zero:
1. Strip only the labels reported stale by `--stale-list` (not all four).
2. Post a PR comment listing which approvals were stale and why (the helper
   prints each reason to stderr; capture and post it).
3. Selective re-dispatch, driven by the stale roles from `--stale-list`, in
   dependency order (QA before reviewer/security/docs, mirroring Step 3e's
   docs-before-reviewer/security ordering):
   - `qa` stale → re-dispatch QA (Step 3d).
   - `reviewer` stale → re-dispatch reviewer (Step 3e phase 2).
   - `security` stale → re-dispatch security (Step 3e phase 2).
   - `adversarial` stale → re-dispatch adversarial (Step 3e phase 3; only
     reachable when `roles.adversarial = true`, since the label is otherwise
     never present to go stale).
   - `docs` stale → check whether the delta since docs' approved SHA touches
     any docs-relevant path: `README.md`, `docs/**`, `CHANGELOG.md`,
     `templates/**`, or any other `*.md` outside `tests/`.
     - If yes: re-dispatch docs (Step 3e phase 1) normally.
     - If no: do NOT dispatch the docs subagent. Re-stamp `docs:done` directly
       against the current head SHA: `bash scripts/pipeline-vcs.sh
       post-approval <PR_NUMBER> docs --body-file <synthetic-summary>` with
       synthetic summary text "no docs-relevant changes since prior docs
       approval". This is strictly cheaper than a dispatch and has no
       prompt-injection surface to design — the issue's own docs-stage change
       (Step 3e Docs prompt) already skips the commit/push when there is
       nothing to do; a zero-dispatch re-stamp applies the same idea one level
       up, at the orchestrator.

`merge.approval_waiver_paths` (default: `["*.md", "docs/**", "CHANGELOG.md",
"*.example"]`) — glob patterns for files that, when they are the only changes
since an approval, do not invalidate that approval. `*.example` covers generated
pipeline-config examples (e.g. `talos.pipeline.json.example`), which are never
executed. Hard-coded non-waivable regardless of config: paths under `scripts/`,
paths under `tests/`, `talos.pipeline.yml`, `pipeline.yaml`.

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

Check CI: `bash scripts/pipeline-vcs.sh pr-checks-required <PR_NUMBER>` -- scoped to
`merge.required_checks` only (#205), so an unrelated non-required check does not
block a merge that every required check has already cleared. Exit 0 means every
required check passed; any non-zero exit (1 = a required check failed, 2 = one is
still pending or missing) means do not merge yet.

If failing (non-zero exit): CI may be flaky — retry it, bounded to 2 re-runs per head SHA:
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
4. **Remove the developer worktree.** `bash scripts/pipeline-worktree.sh remove <N>` — deletes the `fix/issue-<N>-*` developer worktree AND any Claude Code harness `agent-*` worktree QA/reviewer/security/docs tagged to <N> (#240), plus their now-merged local branches, so worktrees don't accumulate on disk. Idempotent: a no-op if no worktree matches. Do this on every merge, including when healing a merged-but-open issue in Step 0.
5. Relay: `bash scripts/pipeline-notify.sh orchestrator "#<N>" "all stages passed — merged PR #<PR_NUMBER>, issue closed" <N>`
6. Lifecycle: `bash scripts/pipeline-notify.sh merged "#<N>" "PR #<PR_NUMBER> merged" <N>`
7. Lifecycle: `bash scripts/pipeline-notify.sh issue-closed "#<N>" "issue resolved" <N>`
8. Rule 3: also fire `hooks.post_stage` for both lifecycle events above (`merged` and `issue-closed`) — see Conversation stream protocol.

---

## Step 5 — End of run summary

1. **Sweep worktrees unconditionally.** `bash scripts/pipeline-worktree.sh sweep <space-separated ids of every issue in this run's queue, PLUS the issue id of every PR still open>` — this runs at the end of EVERY run, not only as the Step 1 startup backstop (use `list-prs`/`find-pr` to resolve open-PR issue ids so a PR that's still awaiting review after this run doesn't lose its worktree). It removes every worktree — developer AND any Claude Code harness `agent-*` worktree tagged via `tag <N>` (#240) — whose issue is not in that combined list, regardless of dirty/unpushed state, plus stale local scratch branches (not main/master/base, not tracking a live remote, not the head of an open PR). Preserves ONLY worktrees identified with an id in that list. Relay the `talos:worktree-sweep removed=<n> kept=<n> freed=<size>` summary line it prints. (Step 4 post-merge item 4, `remove <N>` per issue, is unchanged and still runs on every merge.)
2. **Warn above the worktree threshold.** `bash scripts/pipeline-worktree.sh list` — if its output includes a `pipeline-worktree: WARNING:` line, relay it verbatim: `bash scripts/pipeline-notify.sh info "worktrees" "<the WARNING line>" ""`. Say nothing when no warning line is present (count at or under `execution.worktree_warn_threshold`, default `10`).

After processing all issues, print a summary table:

| Issue | Outcome | PR | Notes |
|-------|---------|----|----|
| #N    | merged  | #M | ... |
| #N    | blocked | —  | reason |
| #N    | in-flight | #M | waiting on CI |

3. **Cost column.** After the outcome table, print `bash scripts/pipeline-events.sh cost` output scoped to the issues processed in this run (loop `--issue N` per issue, or run it unscoped and read only the matching rows) — a compact per-issue, per-role tokens / tool uses / duration_s table, so a run's spend is visible without hand-tallying harness notifications (#202).

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
12. Attempt counting is durable and enforced by `record-attempt`: call `bash scripts/pipeline-vcs.sh record-attempt <N> <stage> --pr <PR_NUMBER>` (or, before a PR exists, with no key at all) before each developer re-dispatch, exactly as in Step 3.  When it exits non-zero (either `max_fix_attempts` consecutive same-stage failures OR `max_total_dispatches` total dispatches reached): set `pipeline:blocked`, notify, move on.  Never count attempts in orchestrator memory — the helper is the source of truth.
13. In file mode: skip board calls, skip QA/reviewer/security/docs, developer commits to branch directly.
14. Never merge a PR that fails `check-pr-files` — secret-like files require a human; `skip-qa` does not waive this gate (nor CI).
15. Only the developer stage may move HEAD in the orchestrator's checkout. All other stages (reviewer, security, docs, QA, validator, PM) must never run `git checkout`, `git switch`, or `git pull` in their working directory — read diffs via `diff-pr` only. This holds regardless of `execution.isolation` mode.
16. `comment-issue`, `comment-pr`, `create-issue`, and `create-pr` exit non-zero when their POST fails. A stage must not assert a filing landed without a non-empty URL returned by the command. For `create-pr` failures, set `pipeline:blocked` immediately — no PR means all downstream stages are impossible.
17. Run all long-running work in the **foreground** — never append `&`, use `nohup`, or call `disown`. Do not poll for child exit with `until ! pgrep …; do sleep N; done`. The reason: when a stranded background child finally exits, the harness interprets its exit as a new completion event; those duplicates are indistinguishable from real completions on arrival (observed: 210 stranded shells at peak, one agent emitting 5 spurious "task finished" signals 90 minutes after finishing, two agents stopped by hand). Talos cannot suppress the harness-side notification — it can only ensure no background children remain.
18. Under `isolation: worktree`, the developer and QA stages run every `verify:` command through `bash scripts/pipeline-verify.sh --issue <N> --worktree <path> -- <cmd>` instead of exporting `TALOS_ISSUE_NUMBER`/`TALOS_WORKTREE_PATH` by hand — both values are present in the task prompt and the wrapper exports them itself before running the command, mechanically, on the native path (#186). Under `isolation: branch`, `TALOS_WORKTREE_PATH` is not meaningful — omit `--worktree`. The adapter path (`pipeline-agent.sh`) exports them as real shell variables automatically before invoking the runner CLI; running `pipeline-verify.sh` there is a same-value no-op, never a conflict.
