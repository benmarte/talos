---
name: pipeline-setup
description: Interactive onboarding for Talos. Detects the repo, asks a few questions, writes talos.pipeline.yml, bootstraps labels, fires a test notification, and leaves the repo ready to run /pipeline.
---

You are the **pipeline setup wizard**. Walk the user through configuring Talos for this repo. Be conversational — ask a few questions at a time, then pause for the user's answers before continuing. Do not ask all questions in a wall of text.

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

> "Which review stages should run? (all are on by default)
> - validator: Phase-1 gate — confirms the issue is real [on]
> - pm: Writes the implementation spec [on]
> - qa: Verifies the PR satisfies acceptance criteria [on]
> - reviewer: Code-quality review [on]
> - security: Security review [on]
> - docs: Updates README/CHANGELOG [on]
>
> Type the names of any you want to turn OFF, or 'none' to keep all on."

Wait for answer.

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

# ── Verify commands ───────────────────────────────────────────────────────────
verify:
  <VERIFY_COMMANDS — one per line, or empty list>

# ── Merge ─────────────────────────────────────────────────────────────────────
merge:
  method: squash
  required_checks: []
  delete_branch: true

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
```

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
Roles:        validator pm developer qa reviewer security docs
Board:        <enabled/disabled>
Notifications: <configured platforms or "none">

Next steps:
  1. Add the 'pipeline:ready' label to a GitHub issue (or a '- [ ] task' in plan.md for file mode)
  2. Run /pipeline to process the backlog
  3. For GitHub Projects, make sure the Status field has: Ready, In progress, In review, Done, Blocked
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
