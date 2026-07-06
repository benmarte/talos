# Talos

> *The bronze automaton that patrols your backlog.* Formerly "claude-pipeline".

An autonomous issue→PR pipeline driven by a **Claude Code orchestrator session** — no CI runner required, no separate daemon, no Hermes. You open a Claude Code session in your repo, run `/pipeline`, and Claude drives the full backlog: validating issues, writing specs, implementing code (in isolated worktrees), verifying with your own test commands, running parallel QA/review/security/docs passes, and squash-merging when CI is green.

GitHub Issues (or a local markdown checklist in file mode) serve as the state machine. GitHub Projects optionally tracks board status. Everything else runs in your terminal.

> **Historical note**: an earlier design used GitHub Actions (`anthropics/claude-code-action`) as the event-driven driver. That variant lives in `.github/workflows/pipeline.yml` and `.claude/commands/pipeline-tick.md` for reference, but the primary, production-tested model is the orchestrator session described here.

---

## How it maps to Daedalus

[Daedalus](https://github.com/benmarte/daedalus) is the full-featured Hermes plugin this is distilled from. claude-pipeline takes the same ideas and runs them on pure Claude Code.

| Daedalus | claude-pipeline |
|----------|-----------------|
| 9 role SOULs + Hermes kanban | `.claude/agents/*.md` subagents + GitHub labels |
| Dispatcher cron | You run `/pipeline` in a Claude Code session |
| `classify_blocked` routing | Orchestrator skill (`skills/pipeline/SKILL.md`) |
| Worktree isolation | `isolation: "worktree"` on the developer subagent |
| Validator gate | `pipeline:ready` → validator must emit CONFIRMED |
| QA-gates-review | `qa:pass` required before reviewer/security/docs |
| Auto-merge | Orchestrator merges when CI + all stage labels are green |
| Dashboard / per-project config | `.claude-pipeline.yaml` per repo |

---

## Pipeline stages

```
issue: pipeline:ready
  └─ validator ──→ pipeline:confirmed
       └─ pm ─────→ pipeline:dev
            └─ developer (worktree) ──→ PR: pipeline:review
                 ├─ qa ─────────────→ qa:pass
                 ├─ reviewer ────────→ review:approved
                 ├─ security ────────→ security:approved
                 └─ docs ────────────→ docs:done
                      └─ all labels green + CI green → MERGE → close issue
```

Any stage can set `pipeline:blocked` with a comment. A blocked issue is skipped until a human resolves it and removes the label.

---

## VCS providers

All VCS operations are delegated to `scripts/pipeline-vcs.sh`, which wraps each provider's CLI into a uniform verb interface. You never call `gh`, `glab`, or `az` directly from skill prompts.

| Provider | `vcs.provider` | CLI required | Status | Notes |
|----------|---------------|--------------|--------|-------|
| GitHub | `github` | `gh` | **Battle-tested** | Full support. Requires `gh auth login`. |
| GitLab | `gitlab` | `glab` | **Best-effort** | Implemented; `glab` version quirks may surface. Requires `glab auth login`. |
| Azure DevOps | `azure` | `az` + azure-devops extension | **Best-effort** | Labels map to ADO Tags; `diff-pr` not supported. Requires `az login` and `az extension add --name azure-devops`. |
| File / chat | `file` | none | **Supported** | Work items are `- [ ] Task` checkboxes in a local markdown file. No PRs; developer commits to a branch; QA/review/security/docs stages skipped. |

### File mode and chat mode

**File mode** (`vcs.provider: file`) treats a local markdown file (`plan.md` by default) as both the board and the issue tracker. Each `- [ ] Task` line is one work item. The pipeline marks items checked when complete; no remote VCS calls are made.

**Chat mode** is how you start a pipeline with no pre-existing issues or plan file. Describe your tasks conversationally to the orchestrator (e.g., "fix the login bug, add dark mode, update the README") and it will:
1. Extract tasks from the conversation.
2. Write `plan.md` with one checkbox item per task.
3. Set `vcs.provider: file` in the config automatically.
4. Run the file-mode pipeline on those items.

### Provider prerequisites summary

```bash
# GitHub (default)
gh auth login

# GitLab
glab auth login

# Azure DevOps
az login
az extension add --name azure-devops
az devops configure --defaults organization=https://dev.azure.com/MYORG project=MYPROJECT

# File mode — no auth needed
```

---

## Quickstart

### 1. Copy files into your repo

```bash
# Option A: install as a Claude Code plugin (recommended)
cd your-repo
# Claude Code plugin install is not yet GA — copy manually for now (see install.sh)

# Option B: manual copy
cp -r path/to/claude-pipeline/scripts/ .claude/pipeline/scripts/
cp -r path/to/claude-pipeline/skills/  .claude/pipeline/skills/
cp -r path/to/claude-pipeline/.claude/agents/ .claude/agents/
```

Or run the included installer:

```bash
bash path/to/claude-pipeline/install.sh /path/to/your-repo
```

### 2. Configure

```bash
cp path/to/claude-pipeline/pipeline.yaml.example .claude-pipeline.yaml
# Edit .claude-pipeline.yaml for your project
```

Minimum viable config (board and notifications optional):

```yaml
base_branch: dev        # the branch PRs target
verify:
  - python -m pytest tests/ -x -q   # your actual test command
```

### 3. Bootstrap labels (GitHub / GitLab / Azure only)

```bash
bash .claude/pipeline/scripts/bootstrap-labels.sh
```

This creates the `pipeline:*`, `qa:pass`, `review:approved`, `security:approved`, and `docs:done` labels in your repo (idempotent). Skip this step for file mode — checkboxes replace labels.

### 4. Optional: GitHub Project board

Create a GitHub Project with a single-select **Status** field containing: Ready, In progress, In review, Done, Blocked. Set `board.enabled: true` and fill in `board.project_number` and `board.owner` in your config. (GitHub only; skipped in file mode.)

### 5. Optional: notifications

Set one or more of these in your environment or in a `.env` file at the repo root:

```
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
TEAMS_WEBHOOK_URL=https://...
```

Alternatively, set `notifications.slack_channel` / `notifications.discord_channel` in your config and put `SLACK_BOT_TOKEN` / `DISCORD_BOT_TOKEN` in `~/.hermes/.env` (Hermes platform credential store — optional convenience, not required).

### 6. Queue work

**VCS mode** (GitHub / GitLab / Azure): add the `pipeline:ready` label to any issue.

**File mode**: add a `- [ ] Task` item to `plan.md`.

**Chat mode**: just describe the work conversationally after running `/pipeline` and the orchestrator will create `plan.md` for you.

Then open a Claude Code session in your repo and run:

```
/pipeline
```

---

## Config reference

All keys live in `.claude-pipeline.yaml` at your repo root. Every key is optional and falls back to a sensible default.

| Key | Default | Description |
|-----|---------|-------------|
| `base_branch` | repo default branch | Branch all PRs target |
| `release_branch` | `main` | Production branch (changelog headers) |
| `vcs.provider` | `github` | VCS backend: `github`, `gitlab`, `azure`, or `file` |
| `vcs.repo` | auto-detect | `owner/repo` override (required when git remote unavailable) |
| `vcs.azure.org_url` | — | Azure DevOps org URL (`https://dev.azure.com/MYORG`) |
| `vcs.azure.project` | — | Azure DevOps project name |
| `vcs.file.source.path` | `plan.md` | Markdown checklist file for file mode |
| `board.enabled` | `false` | Enable GitHub Project board updates |
| `board.project_number` | — | Your project board number |
| `board.owner` | repo owner | GitHub org/user owning the board |
| `board.status_field` | `Status` | Single-select field name |
| `board.statuses.*` | see example | Display names for each status option |
| `verify` | `[]` | Shell commands every code subagent must pass |
| `merge.method` | `squash` | `squash`, `merge`, or `rebase` |
| `merge.required_checks` | `[]` | CI check names required before merge |
| `merge.delete_branch` | `true` | Delete feature branch after merge |
| `issues.label_filter` | `pipeline:ready` | Label that queues issues |
| `issues.skip_labels` | `[pipeline:blocked, wontfix]` | Issues with these are skipped |
| `issues.max_parallel` | `1` | Max issues in-flight at once |
| `roles.validator` | `true` | Phase-1 gate: confirms issue is real |
| `roles.pm` | `true` | Writes implementation spec |
| `roles.qa` | `true` | Verifies PR satisfies acceptance criteria |
| `roles.reviewer` | `true` | Code-quality review |
| `roles.security` | `true` | Security review |
| `roles.docs` | `true` | Updates docs/CHANGELOG; terminal stage |
| `comments.enabled` | `true` | Post a stage comment at each handoff (Daedalus parity) |
| `comments.header` | `**Agent:** {role} (claude-pipeline)` | Header prepended to every stage comment; `{role}` is replaced at runtime |
| `comments.templates_dir` | `templates/comments` | Path (relative to repo root) containing comment templates |
| `notifications.slack_channel` | `""` | Slack channel ID fallback |
| `notifications.discord_channel` | `""` | Discord channel ID fallback |
| `notifications.templates_dir` | `templates/notifications` | Path to notification message templates; `""` disables templates |
| `notifications.threading` | `true` | Thread all events per issue in one Slack/Discord thread (bot-token mode only) |
| `notifications.events` | all (unset) | Events filter. **Leave unset** — when set, any unlisted event is silently dropped, including all role events that make up the conversation stream. See warning below. |
| `limits.max_fix_attempts` | `3` | Developer retries before escalating |

### Comment templates

Stage comments use `string.Template`-style `${PLACEHOLDER}` substitution. Templates live in `templates/comments/`:

| File | Posted by | Variables used |
|------|-----------|----------------|
| `validator-verdict.md` | validator | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `pr-opened.md` | developer | `${HEADER}`, `${PR}`, `${SUMMARY}`, `${DETAILS}` |
| `qa-verdict.md` | qa | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `review-signoff.md` | reviewer | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `security-signoff.md` | security | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `docs-posted.md` | docs | `${HEADER}`, `${SUMMARY}`, `${DETAILS}` |
| `issue-closed.md` | orchestrator | `${HEADER}`, `${PR}`, `${DETAILS}` |
| `blocked.md` | any stage | `${HEADER}`, `${SUMMARY}`, `${DETAILS}` |

Edit these files to customise the comment format for your team. The subagent falls back to an inline summary if a template file is missing.

### Notification templates

Notification messages are rendered as Slack Block Kit (header + section + colored attachment) or Discord embeds (title/description/color/footer). The first line of the rendered template becomes the title; the rest becomes the body. Templates use `${PLACEHOLDER}` substitution with variables `${ICON}`, `${REF}`, `${MSG}`, `${EVENT}`.

**Role event templates** (one per agent — make up the conversation stream):

| File | Event arg | Sent after |
|------|-----------|-----------|
| `validator.md` | `validator` | Validator returns |
| `developer.md` | `developer` | Developer opens PR |
| `qa.md` | `qa` | QA returns |
| `reviewer.md` | `reviewer` | Reviewer returns |
| `security.md` | `security` | Security analyst returns |
| `docs.md` | `docs` | Docs agent returns |
| `orchestrator.md` | `orchestrator` | Orchestrator merges and closes |

**Lifecycle event templates** (structural signals):

| File | Event arg | Sent when |
|------|-----------|-----------|
| `pr-opened.md` | `pr-opened` | PR created by developer |
| `merged.md` | `merged` | PR merged |
| `blocked.md` | `blocked` | Any stage sets pipeline:blocked |
| `issue-closed.md` | `issue-closed` | Issue closed after merge |
| `info.md` | `info` | Generic informational events |

**Events-filter warning:** `notifications.events` defaults to unset (all events fire). If you set a list, any event not in it is **silently dropped** — no error, no log line. A lifecycle-only list like `[pr-opened, merged, blocked, issue-closed]` kills the entire conversation stream. When you need a filter, copy the full list from `pipeline.yaml.example` and remove only what you don't want.

### Environment variable overrides

Scripts respect these env vars, which take priority over the config file:

| Variable | Overrides |
|----------|-----------|
| `PIPELINE_CONFIG` | path to config file |
| `PIPELINE_PROJECT_NUMBER` | `board.project_number` |
| `PIPELINE_BOARD_OWNER` | `board.owner` |
| `PIPELINE_STATUS_FIELD` | `board.status_field` |
| `PIPELINE_REPO` | detected repo (owner/name) |
| `PIPELINE_SLACK_CHANNEL` | `notifications.slack_channel` |
| `PIPELINE_DISCORD_CHANNEL` | `notifications.discord_channel` |
| `PIPELINE_THREAD_STATE` | path to thread anchor state file (default: `~/.claude-pipeline/threads.json`) |
| `PIPELINE_NOTIFY_DEBUG` | set to `1` to print payloads without posting (safe for testing) |

### Per-issue notification threading

When `notifications.threading: true` (the default) and a Slack or Discord **bot token** is in use, all events for the same issue land in a single thread rather than flooding the channel as separate top-level messages.

The orchestrator passes the issue number as the 4th argument to `pipeline-notify.sh` so that all role events and lifecycle events reply to the same root message:

```bash
bash scripts/pipeline-notify.sh validator   "#42" "CONFIRMED: …" 42
bash scripts/pipeline-notify.sh developer   "#42" "PR #31 opened — …" 42
bash scripts/pipeline-notify.sh pr-opened   "#42" "PR #31 opened" 42
bash scripts/pipeline-notify.sh qa          "#42" "PASS: 3 criteria verified" 42
bash scripts/pipeline-notify.sh reviewer    "#42" "APPROVED: clean fix" 42
bash scripts/pipeline-notify.sh security    "#42" "CLEAR: no injection risk" 42
bash scripts/pipeline-notify.sh docs        "#42" "docs posted: CHANGELOG + auth.md" 42
bash scripts/pipeline-notify.sh orchestrator "#42" "all stages passed — merged PR #31" 42
bash scripts/pipeline-notify.sh merged      "#42" "PR #31 merged" 42
bash scripts/pipeline-notify.sh issue-closed "#42" "issue resolved" 42
```

#### Conversation stream

After each subagent completes, the orchestrator relays that agent's findings summary to the channel thread using the role name as the event. `pipeline-notify.sh` renders the message from `templates/notifications/<role>.md` when that file exists. This makes the Slack/Discord thread read as a **conversation between agents** — validator speaks first, then developer, QA, reviewer, security, docs, and finally orchestrator announces the merge. This mirrors Daedalus's thread delivery model.

**Role events** (one per subagent):

| Event arg | When sent | Template |
|-----------|-----------|----------|
| `validator` | After validator returns | `templates/notifications/validator.md` |
| `developer` | After developer opens PR | `templates/notifications/developer.md` |
| `qa` | After QA returns | `templates/notifications/qa.md` |
| `reviewer` | After reviewer returns | `templates/notifications/reviewer.md` |
| `security` | After security returns | `templates/notifications/security.md` |
| `docs` | After docs returns | `templates/notifications/docs.md` |
| `orchestrator` | After merge | `templates/notifications/orchestrator.md` |

**Lifecycle events** (unchanged, same thread):

| Event arg | When sent |
|-----------|-----------|
| `pr-opened` | PR created by developer |
| `merged` | PR merged |
| `blocked` | Any stage blocks the issue |
| `issue-closed` | Issue closed after merge |

Thread anchors are stored in `~/.claude-pipeline/threads.json` keyed by `<repo-slug>:<issue-number>`. If the anchor message is deleted, the script detects the stale anchor, clears it, and posts a fresh root thread automatically.

**Webhook mode limitation**: Slack incoming webhooks and Discord webhooks do not expose thread IDs at post time, so threading is silently skipped in webhook mode. Use bot tokens if threading is important.

---

## How a run works end-to-end

1. You run `/pipeline` in a Claude Code session.
2. The orchestrator reads `.claude-pipeline.yaml` and reconciles any in-flight PRs from a previous run.
3. It lists issues with `pipeline:ready` (up to `max_parallel`).
4. For each issue:
   - **Validator** reads the issue and codebase. CONFIRMED advances; anything else sets `pipeline:blocked`.
   - **PM** turns the confirmed issue into a spec comment (goal, acceptance criteria, branch name, out-of-scope).
   - **Developer** spawns in an isolated git worktree. It implements, runs your `verify` commands, and opens a PR. The worktree is discarded after the PR is pushed.
   - **QA** checks out the PR branch and verifies each acceptance criterion.
   - **Reviewer + Security + Docs** run in parallel after QA passes.
5. Once all stage labels are on the PR and required CI checks are green, the orchestrator squash-merges, closes the issue, sets the board status to Done, and sends a notification.
6. If any stage returns a blocking outcome, the issue gets `pipeline:blocked` and a comment explaining what a human must do. The orchestrator moves on to the next issue.

---

## Human-only gates

The pipeline deliberately preserves three gates that only a human should act on:

1. **Moving an issue to Ready** — adding `pipeline:ready` starts the pipeline. The orchestrator never re-queues a `pipeline:blocked` issue automatically.
2. **Emergency stops** — remove `pipeline:ready` from an issue or close it to prevent the pipeline from picking it up.
3. **Merge override** — set `merge.method: merge` and `merge.required_checks: []` only if you intentionally want no CI gate.

---

## Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/pipeline-config.sh KEY [default]` | Dot-path config reader (YAML/JSON) |
| `scripts/pipeline-vcs.sh [--dry-run] <verb> [args...]` | Uniform VCS adapter (github/gitlab/azure/file) |
| `scripts/pipeline-status.sh [--dry-run] <issue> <status>` | Set GitHub Project board status |
| `scripts/pipeline-notify.sh <event> <ref> <message> [thread_key]` | Post event to Slack/Discord/Teams |
| `scripts/bootstrap-labels.sh [owner/repo]` | Create `pipeline:*` labels (idempotent) |

### pipeline-vcs.sh verbs

| Verb | Arguments | Description |
|------|-----------|-------------|
| `list-issues` | | List open issues / unchecked plan items |
| `view-issue` | `<id>` | Show issue body and metadata |
| `comment-issue` | `<id> <body>` | Post a comment on an issue |
| `close-issue` | `<id> [reason]` | Close an issue |
| `label-issue` | `<id> --add label [--remove label]` | Add/remove labels (or tags for Azure) |
| `create-pr` | `<branch> <title> <body-file>` | Open a PR targeting base_branch |
| `view-pr` | `<branch>` | Show PR number, URL, status |
| `list-prs` | | List open PRs |
| `diff-pr` | `<pr-number>` | Show PR diff (not supported on Azure) |
| `checkout-pr` | `<pr-number>` | Check out a PR branch locally |
| `approve-pr` | `<pr-number> [summary]` | Approve a PR |
| `label-pr` | `<pr-number> --add label [--remove label]` | Add/remove PR labels |
| `pr-checks` | `<pr-number>` | List CI check statuses |
| `merge-pr` | `<pr-number>` | Merge a PR (uses `merge.method` from config) |
| `comment-pr` | `<pr-number> <body>` | Post a PR review comment |

Pass `--dry-run` as the first argument to print the underlying CLI command without executing it.

---

## Tests

Every script has an offline regression suite, plus an end-to-end simulation
that installs Talos into a scratch repo and drives one issue through the full
label → validator → PR → QA → merge → close lifecycle against stubbed
`gh`/`curl` (no network, no credentials, nothing posted anywhere):

```bash
bash tests/run-tests.sh            # everything
bash tests/run-tests.sh notify     # only files matching "notify"
```

CI runs the suite on Ubuntu and macOS for every push and PR
(`.github/workflows/tests.yml`).

---

## Credits

claude-pipeline is a distillation of [Daedalus](https://github.com/benmarte/daedalus) — a full-featured Hermes plugin with a 9-agent roster, kanban board, dashboard, and per-project config. If you need multi-project management, a dashboard UI, or a long-running daemon, use Daedalus. If you want a drop-in, zero-infrastructure pipeline driven from a Claude Code session — supporting GitHub (battle-tested), GitLab, Azure DevOps, and a local file mode — this is it.
