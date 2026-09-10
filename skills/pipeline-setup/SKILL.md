---
name: pipeline-setup
description: Interactive onboarding for Talos. Detects the repo, asks a few questions, writes talos.pipeline.yml, bootstraps labels, fires a test notification, and leaves the repo ready to run /pipeline.
---

You are the **pipeline setup wizard**. Walk the user through configuring Talos for this repo. Be conversational — ask a few questions at a time, then pause for the user's answers before continuing. Do not ask all questions in a wall of text.

**Script location:** resolve once before anything else, and reuse the answer — every `bash scripts/<name>.sh` below means the directory you resolve here:

```bash
for d in \
  "${TALOS_HOME:+$TALOS_HOME/scripts}" \
  "$HOME/.talos/scripts" \
  "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
  ".claude/talos/scripts" \
  "scripts"; do
  [ -n "$d" ] && [ -f "$d/pipeline-config.sh" ] && { echo "$d"; break; }
done
```

Five cases, in priority order: explicit override ($TALOS_HOME), global install (~/.talos), marketplace plugin, vendored into the repo by install.sh (.claude/talos/scripts), or the Talos source repo. The global install wins when present; the plugin falls back to its bundled copy only when no global install exists. If it prints nothing, Talos is not installed — tell the user and stop.

---

## Step 0 — Detect existing config

Check whether `talos.pipeline.yml` or `pipeline.yaml` already exists in the current directory.

If a config **exists**:
- Read it with `bash scripts/pipeline-config.sh <key> <default>` to show current values.
- Tell the user: "Found an existing config. Here's what's set: ..."
- Ask: "Would you like to update any of these settings, or is this just a re-run to bootstrap labels?"
- If no changes needed: jump to Step 7 (bootstrap + test).

If **no config**: continue to Step 1.

---

## Step 1 — Detect repo and VCS provider

Run these detections (silently, just to have the answers ready):

```bash
# Repo info
git remote get-url origin 2>/dev/null
git branch --show-current 2>/dev/null
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||'  # default branch
```

Detect likely VCS provider from the origin URL:
- Contains `github.com` → "github" (detected)
- Contains `gitlab.com` or `gitlab.` → "gitlab"
- Contains `dev.azure.com` or `visualstudio.com` → "azure"
- No remote or unclear → offer "file" mode as an option

Detect likely verify commands:
- `pytest.ini` or `pyproject.toml` present → `python -m pytest tests/ -x -q`
- `package.json` present → `npm test`
- `Makefile` with a `test` target → `make test`
- `Cargo.toml` present → `cargo test`
- Nothing detected → will ask

---

## Step 2 — Ask: VCS provider and base branch

Present your detections and ask (2 questions):

> "I detected this repo is hosted on **[provider]** and the default branch is **[branch]**. 
>
> 1. Which VCS provider are you using? (github / gitlab / azure / file)
>    [detected: **github**]
> 2. Which branch should PRs target? This is usually your integration branch, not main.
>    [detected: **dev**]"

Wait for answers before continuing.

---

## Step 3 — Ask: verify commands

> "What commands should every code change pass before a PR is opened?
> [detected: `python -m pytest tests/ -x -q`]
> (Enter commands one per line, or 'none' to skip, or press Enter to use the detected ones)"

Wait for answer.

---

## Step 4 — Ask: roles

> "Which review stages should run? (all are on by default except adversarial)
> - validator: Phase-1 gate — confirms the issue is real [on]
> - pm: Writes the implementation spec [on]
> - qa: Verifies the PR satisfies acceptance criteria [on]
> - reviewer: Code-quality review [on]
> - security: Security review [on]
> - docs: Updates README/CHANGELOG [on]
> - adversarial: Optional pre-merge second opinion — attacks the diff for
>   vacuous tests, weak patterns, secret shapes and unverified claims [off]
>
> Type the names of any you want to turn OFF (or, for adversarial, ON), or
> 'none' to keep the defaults."

Wait for answer.

If the user turns `adversarial` **on**:
> "Adversarial is usually paired with an independent second backend so it
> isn't grading the same model that wrote the diff. Should it run on the
> same agent harness as everything else, or a different one (e.g. a local
> model via a custom runner)?
> [default: same harness — no extra config needed]"

If they want a different backend, record it the same way as Step 6b's
`custom` harness answer (runner + optional `runner_cmd`); this is written as
`agents.roles.adversarial.runner` (and `runner_cmd` when custom), not the
top-level `agents.runner`, so only adversarial pays for the different
backend.

Also ask (2 more questions, defaults shown, only if the user wants to change them):
> "Two more role toggles, both fine to leave at their defaults:
> - Skip PM when an issue's body is already a usable spec (an acceptance-criteria
>   heading with checklist items, or the `spec:ready` label)? [on — `roles.pm_skip_when_spec_present`]
> - How should docs decide whether to dispatch: `auto` (skip the docs subagent
>   when the developer's diff already covers CHANGELOG + README/docs, or is
>   scripts/tests-only with a CHANGELOG entry) or `always` (docs subagent always
>   runs and reads the full diff)? [auto — `roles.docs_mode`]"

---

## Step 5 — Ask: GitHub Project board (skip for non-GitHub or file mode)

Only ask if provider is github:

> "Would you like to track issues on a GitHub Project board? (y/n)
> If yes, I'll need your project number (run `gh project list` to find it)."

If yes:
> "What's the project number and owner?
> Example: project_number: 2, owner: myorg"

If no (or non-GitHub provider): board.enabled = false.

---

## Step 6 — Ask: notifications (optional)

> "Would you like notifications for pipeline events? (y/n)
> Supported: Slack webhook, Discord webhook, Teams webhook, or bot tokens."

If yes:
> "Which platforms? And do you have webhook URLs or bot tokens ready?
> (You can always add these later via env vars: SLACK_WEBHOOK_URL, DISCORD_WEBHOOK_URL, etc.)"

Then ask:
> "Would you like to filter which events trigger notifications, or receive all of them?
> Receiving all is recommended — the role events (validator, developer, qa, reviewer, security, docs, orchestrator) create the per-issue conversation thread in Slack/Discord. Filtering them out silences the thread with no warning."

If the user wants all events: write `notifications:` with **no `events:` key** (unset = all fire).

If the user wants a filter: **automatically include all role events** regardless of what the user asked to exclude — they may only remove lifecycle events. Build the events list as:
```
# Role events (conversation stream — do not remove)
- validator
- developer
- qa
- reviewer
- security
- docs
- orchestrator
# Lifecycle events (remove any you don't want)
- pr-opened
- merged
- blocked
- issue-closed
- info
```
Then remove only the lifecycle events the user said they don't want. Warn explicitly: "I've kept all role events — removing them would silence the per-issue conversation thread."

If none/no config: omit the `events:` key entirely (all events fire; disabling happens by not setting channel/webhook).

---

## Step 6b — Ask: agent harness

> "Which agent harness will run the pipeline?
> - **claude** (default) — Claude Code spawns native subagents; no extra config needed
> - **codex** — Codex CLI executes each role stage via scripts/pipeline-agent.sh
> - **gemini** — Gemini CLI executes each role stage via scripts/pipeline-agent.sh
> - **custom** — a custom agentic CLI; you'll be asked for the command
>
> [default: **claude**]"

Wait for the answer.

If the user answers **claude** (or presses Enter): record harness = `claude`. No `agents:` block will be written.

If the user answers **codex** or **gemini**: record harness = that value.

If the user answers **custom**:
> "What command should the pipeline call? The prompt will arrive on stdin.
> (Example: `my-agent-cli --model local`)"
Wait for the `runner_cmd` value.

---

## Step 7 — Write talos.pipeline.yml

Based on the collected answers, write `talos.pipeline.yml` in the current directory using this template (fill in the collected values, comment out sections not configured):

```yaml
# Generated by /pipeline-setup on <date>
base_branch: <BASE_BRANCH>
release_branch: main

vcs:
  provider: <PROVIDER>          # github | gitlab | azure | file
  # repo: <OWNER/REPO>          # omit to auto-detect from git remote

# ── Board (GitHub only) ──────────────────────────────────────────────────────
board:
  enabled: <true|false>
  # project_number: <N>
  # owner: <OWNER>
  status_field: Status
  statuses:
    ready: "Ready"
    in_progress: "In progress"
    in_review: "In review"
    done: "Done"
    blocked: "Blocked"
  # status_map: optional — map pipeline status names to your board's column names.
  # Use this when your project uses different column names than the defaults above.
  # An absent key passes through unchanged; omitting status_map entirely is safe.
  # Example: if your board uses "Needs attention" instead of "Blocked":
  # status_map:
  #   Blocked: "Needs attention"

# ── Verify commands ───────────────────────────────────────────────────────────
verify:
  <VERIFY_COMMANDS — one per line, or empty list>

# ── Merge ─────────────────────────────────────────────────────────────────────
merge:
  method: squash
  required_checks: []
  delete_branch: true
  # forbidden_files:           # PR paths matching these glob patterns block the
  #   - ".env"                 # merge for human review (defaults shown; basename
  #   - ".env.*"               # and full path are both matched)
  #   - "*.pem"
  #   - "*.key"
  #   - "*.p12"
  #   - "*.pfx"
  #   - "*.secrets"
  #   - "secrets.*"
<IF_EXTRA_FORBIDDEN_PATTERNS>
  forbidden_files:
    - ".env"
    - ".env.*"
    - "*.pem"
    - "*.key"
    - "*.p12"
    - "*.pfx"
    - "*.secrets"
    - "secrets.*"
<EXTRA_FORBIDDEN_PATTERNS — one per line, indented>
</IF_EXTRA_FORBIDDEN_PATTERNS>

# ── Issue selection ───────────────────────────────────────────────────────────
issues:
  label_filter: "pipeline:ready"
  skip_labels:
    - "pipeline:blocked"
    - "wontfix"
  max_parallel: 1

# ── Roles ─────────────────────────────────────────────────────────────────────
roles:
  validator: <true|false>
  pm: <true|false>
  qa: <true|false>
  reviewer: <true|false>
  security: <true|false>
  docs: <true|false>
  adversarial: <true|false>   # optional pre-merge second opinion, off by default (#237)
  # pm_skip_when_spec_present: true  # default; set false to always run PM
  # docs_mode: auto                  # auto (default) | always

# ── Comments ──────────────────────────────────────────────────────────────────
comments:
  enabled: true
  header: "**Agent:** {role} (talos)"
  templates_dir: "templates/comments"

# ── Notifications ─────────────────────────────────────────────────────────────
notifications:
  slack_channel: "<SLACK_CHANNEL_OR_EMPTY>"
  discord_channel: "<DISCORD_CHANNEL_OR_EMPTY>"
  templates_dir: "templates/notifications"
  threading: true
  # events: leave unset to fire all events (recommended).
  # WARNING: if you set a list you MUST include the role events
  # (validator/developer/qa/reviewer/security/docs/orchestrator) or the
  # conversation stream is silently killed. See talos.pipeline.yml.example.
<IF_USER_REQUESTED_FILTER>
  events:
<EVENTS_LIST_WITH_ALL_ROLE_EVENTS_PLUS_CHOSEN_LIFECYCLE_EVENTS>
</IF_USER_REQUESTED_FILTER>

# ── Limits ────────────────────────────────────────────────────────────────────
limits:
  max_fix_attempts: 3

<IF_NON_CLAUDE_HARNESS>
# ── Agent runner (non-Claude-Code harnesses only) ─────────────────────────────
# Claude Code spawns native subagents and ignores this section. Harnesses
# without subagents (Codex CLI, headless runners) execute role stages through
# scripts/pipeline-agent.sh, which uses:
agents:
  runner: <HARNESS>            # claude (default) | codex | gemini | custom
  # runner_args:               # extra CLI args for the claude/codex/gemini runner
  #   - --full-auto
<IF_CUSTOM_HARNESS>
  runner_cmd: "<RUNNER_CMD>"   # runner: custom — prompt arrives on stdin.
                               # Must be an AGENTIC CLI (executes shell/edits
                               # files); use one backed by a local model
                               # (e.g. Ollama) for fully local pipelines.
</IF_CUSTOM_HARNESS>
</IF_NON_CLAUDE_HARNESS>
```

When writing the file:
- If harness = `claude`: omit the `agents:` block entirely (Claude Code spawns native subagents and ignores it).
- If harness = `codex` or `gemini`: write the active `agents:` block with the chosen `runner` value; omit `runner_cmd`.
- If harness = `custom`: write the active `agents:` block with `runner: custom` and `runner_cmd: "<value the user provided>"`.
- If `roles.adversarial: true` AND the user asked for a different backend for it (Step 4): write (or extend) the `agents:` block with a `roles: { adversarial: { runner: ..., runner_cmd: ... } }` sub-block — same shape as the `docs/user-guide.md` "Second opinion on a local model" example — even when the top-level harness is `claude`, since only `adversarial` is opting out of the native default.

Also ask before writing:
> "The merge gate blocks PRs that touch sensitive file patterns (.env, *.pem, *.key, …). Would you like to add any extra patterns beyond the defaults?"

If yes: write an active `forbidden_files:` list (defaults + the user's extras) in place of the commented-out block.
If no: leave the defaults commented out as shown in the template.

Tell the user: "Written `talos.pipeline.yml`. Here's a summary of what's configured: ..."

---

## Step 8 — Bootstrap labels (non-file providers)

If provider is NOT "file":
```bash
bash scripts/bootstrap-labels.sh
```

Report which labels were created vs already existed.

If provider is "file": skip labels, tell the user "File mode uses checkboxes for state — no repo labels needed."

---

## Step 8b — Recommended CI workflow (github only)

Only run this step if provider is "github". Skip silently for gitlab/azure/file.

Check whether any workflow under `.github/workflows/*.yml` already runs
`tests/run-tests.sh` (or, if this repo's `verify:` commands name a different
test entry point, that command):

```bash
grep -l "run-tests.sh" .github/workflows/*.yml 2>/dev/null
```

**If a matching workflow already exists: never edit it.** This step only
ever offers to write a brand-new file — it does not modify, append to, or
overwrite an existing workflow under any circumstance. Instead, check
whether that workflow already has `paths-ignore` and `concurrency` keys; if
either is missing, print one line noting that `templates/ci/github-tests.yml`
documents both as CI-cost recommendations, and move on. Do not offer to
apply the template.

**If no workflow runs the test suite:** offer to write one.

> "No workflow runs your test suite yet. Talos ships a recommended CI
> template (`templates/ci/github-tests.yml`) that skips docs-only pushes,
> cancels superseded runs on the same branch, and runs the full OS matrix
> only on merges to your base branch (pull requests run the cheap OS only).
> This is a recommendation, not something Talos enforces — want me to write
> it to `.github/workflows/tests.yml`? (y/n)"

If yes: copy `templates/ci/github-tests.yml` to `.github/workflows/tests.yml`,
substituting the test command for this repo's actual `verify:` command(s) if
they differ from `bash tests/run-tests.sh --no-cache`, and the base branch
name for `main` if this repo's base branch differs. Tell the user it was
written and that the header comments in the file explain each knob.

**Check `merge.required_checks` before finishing this step.** If the
existing (or about-to-be-written) `talos.pipeline.yml`/`.json` names a job
this template only runs on push, not on PRs — most commonly
`test (macos-latest)` — warn explicitly: "your `merge.required_checks`
names `test (macos-latest)`, which this template no longer runs on pull
requests. If you don't remove it, the merge gate will wait forever on every
PR (QA's CI-wait loop waits for a check that will never appear, until
`verify.ci_wait_s` elapses, then fails closed). Remove it from
`merge.required_checks`, or add `macos-latest` back to the `pull_request`
matrix in the workflow you just wrote." This check applies whether the
config was written earlier in this same run (Step 7) or already existed
before setup started.

If no: skip, no file is written.

---

## Step 9 — GitHub Project setup (optional, github only)

If board.enabled = true AND the user said they don't have a project yet:

Offer to create one:
```bash
gh project create --owner <OWNER> --title "talos" --format json
```

Then add the five status options to the Status field. Walk the user through this if `gh project field-create` is available, otherwise provide copy-paste instructions.

If the project already exists or the user prefers manual setup: print the five required status names and tell them to add them via the GitHub UI.

---

## Step 10 — Test notification (optional)

If any notification channel is configured:
```bash
bash scripts/pipeline-notify.sh info "setup" "Talos is configured and ready" 0
```

Report success or failure. If failure, give the user a troubleshooting hint (check env vars, channel IDs, token scopes).

---

## Step 11 — Summary

Print a checklist of everything that was set up:

```
Talos setup complete!

Config:       talos.pipeline.yml
Provider:     <PROVIDER>
Base branch:  <BASE_BRANCH>
Verify:       <commands or "none">
Roles:        validator pm developer qa reviewer security docs [adversarial]
Board:        <enabled/disabled>
Notifications: <configured platforms or "none">
Harness:      <claude (native subagents) | codex | gemini | custom>

Control labels (created by bootstrap-labels.sh in Step 8):
  p0        — dispatched first (highest priority)
  p1        — high priority
  p2        — low priority (dispatched after p1; unlabeled issues are dispatched last, after p2)
  skip-qa   — bypasses the QA, reviewer, security, and docs gates for this issue
              (CI checks and forbidden-files protection are ALWAYS enforced)

Next steps:
  1. Add the 'pipeline:ready' label to a GitHub issue (or a '- [ ] task' in plan.md for file mode)
  2. Run /pipeline to process the backlog
  3. For GitHub Projects, make sure the Status field has: Ready, In progress, In review, Done, Blocked
     (if your board uses different column names, configure board.status_map to remap them — see the
     example in the config template above; pipeline-status.sh will emit talos:board-unverified on
     stdout and warn to stderr when any required option is missing, so mis-configuration is visible)
  4. Use p0/p1/p2 labels to control dispatch order; use skip-qa to fast-track low-risk issues
```

---

## Idempotency rules

- Never overwrite an existing `talos.pipeline.yml` without the user's explicit confirmation.
- If `bootstrap-labels.sh` reports a label already exists, that is not an error — say "already up to date".
- Running setup a second time on a configured repo should be safe and produce no surprises.

---

## File mode special instructions

If the user chooses `vcs.provider: file`:

1. Ask for the plan file path (default: `plan.md`).
2. If the file doesn't exist, offer to create a starter template:
   ```markdown
   # Project Plan
   
   - [ ] First task
   - [ ] Second task
   ```
3. Explain: "In file mode, `- [ ] Task` items are your work items. The pipeline processes unchecked items, commits changes to a branch, and checks the box when done. No PRs are opened — the developer commits directly."
4. No label bootstrap needed.
5. No board setup needed (the file IS the board).
