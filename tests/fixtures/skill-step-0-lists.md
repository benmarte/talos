Store these for the run:
- BASE_BRANCH (default: detect with git)
- VCS_PROVIDER (`vcs.provider`, default: `github`)
- BOARD_ENABLED, PROJECT_NUMBER, BOARD_OWNER
- MAX_PARALLEL, MAX_FIX_ATTEMPTS, LABEL_FILTER, SKIP_LABELS
- MERGE_AUTO (`merge.auto`, default `true`) — when `false`, Step 4 stops at `pipeline:approved` and hands the merge to a human
- MERGE_AUTO_SYNC (`merge.auto_sync`, default `true`) — when `true`, Step 4's post-merge sibling sync block updates every other open pipeline PR's branch with the new base (#289); `false` skips it
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
- ROLE_CHANGELOG_FRAGMENTS (`roles.changelog_fragments`, default `false`) — when `true`, the docs stage writes `docs/CHANGELOG.d/<issue>.md` fragments instead of editing `CHANGELOG.md` (#290), and Step 4's post-merge bookkeeping runs `bash scripts/pipeline-changelog.sh assemble` after each merge that added fragments
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

**Config defaults:**
- `base_branch`: `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||'` or `main`
- `board.enabled`: false
- `roles.*`: all true
- `roles.docs_mode`: `auto`
- `roles.changelog_fragments`: false (#290 — when `true`, docs writes
  `docs/CHANGELOG.d/<issue>.md` fragments instead of editing `CHANGELOG.md`,
  and Step 4 assembles them after each merge)
- `merge.auto`: true
- `merge.auto_sync`: true
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

