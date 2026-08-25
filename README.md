# Talos

> *The bronze automaton that patrols your backlog.* Formerly "claude-pipeline".

An autonomous issue→PR pipeline driven by a **Claude Code orchestrator session** — no CI runner required, no separate daemon, no Hermes. You open a Claude Code session in your repo, run `/pipeline`, and Claude drives the full backlog: validating issues, writing specs, implementing code (in isolated worktrees), verifying with your own test commands, running QA, then documentation and parallel review/security passes, and squash-merging when CI is green.

GitHub Issues (or a local markdown checklist in file mode) serve as the state machine. GitHub Projects optionally tracks board status. Everything else runs in your terminal.

> 📖 **New here? Start with the [User Guide](docs/user-guide.md)** — per-harness setup (Claude Code, Codex CLI, Gemini CLI, local models via llama.cpp), prerequisites, environment variables, feature matrix, and troubleshooting. This README is the architecture and configuration reference.

> **Historical note**: an earlier design used GitHub Actions (`anthropics/claude-code-action`) as the event-driven driver. That variant lives in `examples/github-actions/` and `.claude/commands/pipeline-tick.md` for reference, but the primary, production-tested model is the orchestrator session described here.

---

> **Talos installs [agent-skills](https://github.com/addyosmani/agent-skills) for you.** The role profiles delegate their methodology to those skills rather than restating it, so it is a hard requirement — but never a manual step. The plugin declares it as a dependency (`+ 1 dependency: agent-skills`); `install.sh` fetches it into `.claude/skills/` (skip with `--no-agent-skills`). Upstream, MIT, unmodified.

---

## How it maps to Daedalus

[Daedalus](https://github.com/benmarte/daedalus) is the full-featured Hermes plugin this is distilled from. Talos takes the same ideas and runs them on pure Claude Code.

| Daedalus | Talos |
|----------|-----------------|
| 9 role SOULs + Hermes kanban | `.claude/agents/*.md` subagents + GitHub labels |
| Dispatcher cron | You run `/pipeline` in a Claude Code session |
| `classify_blocked` routing | Orchestrator skill (`skills/pipeline/SKILL.md`) |
| Worktree isolation | `isolation: "worktree"` on the developer subagent |
| Validator gate | `pipeline:ready` → validator must emit CONFIRMED |
| QA-gates-review | `qa:pass` required before reviewer/security/docs |
| Auto-merge | Orchestrator merges when CI + all stage labels are green |
| Dashboard / per-project config | `talos.pipeline.yml` per repo |

---

## Pipeline stages

```
issue: pipeline:ready
  └─ validator ──→ pipeline:confirmed
       ├─ planner (optional) ──→ sub-issues created (epic) OR pass-through (non-epic)
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
| GitHub (token-only) | `github-api` | none | **Supported** | All 18 verbs via `curl` + `GITHUB_TOKEN`. No `gh` CLI needed — ideal for CI/containers. Set `GITHUB_TOKEN` or `GH_TOKEN`. Projects v2 board updates also use the token. |
| GitLab | `gitlab` | `glab` | **Best-effort** | Implemented; `glab` version quirks may surface. Requires `glab auth login`. |
| Azure DevOps | `azure` | `az` + azure-devops extension | **Supported** | Full issue/board/PR flow — work items, Tags, board State, and PR labels/comments/diff (via `az rest` where `az` has no command). Merges are human-gated when `main` has branch policies. `find-pr`/`check-pr-files`/`rerun-ci` not implemented. Requires `az login` + `az extension add --name azure-devops`. |
| File / chat | `file` | none | **Supported** | Work items are `- [ ] Task` checkboxes in a local markdown file. No PRs; developer commits to a branch; QA/review/security/docs stages skipped. |

### File mode and chat mode

**File mode** (`vcs.provider: file`) treats a local markdown file (`plan.md` by default) as both the board and the issue tracker. Each `- [ ] Task` line is one work item. The pipeline marks items checked when complete; no remote VCS calls are made. It is the zero-infrastructure path: **no VCS system needed at all** — no remote, no `gh`/`glab`/`az`, no auth, fully offline. Ideal for local sessions and local-LLM harnesses like pi.

**Chat mode** is how you start a pipeline with no pre-existing issues or plan file. Describe your tasks conversationally to the orchestrator (e.g., "fix the login bug, add dark mode, update the README") and it will:
1. Extract tasks from the conversation.
2. Write `plan.md` with one checkbox item per task.
3. Set `vcs.provider: file` in the config automatically.
4. Run the file-mode pipeline on those items.

### Provider prerequisites summary

```bash
# GitHub (default — requires gh CLI)
gh auth login

# GitHub API (token-only — no gh CLI required)
export GITHUB_TOKEN="ghp_your_token_here"
# talos.pipeline.yml: vcs.provider: github-api

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

### 1. Install

**Option A — Claude Code plugin (recommended).** Once per machine; every repo then only needs a config file.

```
/plugin marketplace add benmarte/talos
/plugin install talos@talos
```

Restart the session, then run `/pipeline-setup` in any repo to write `talos.pipeline.yml` and bootstrap labels. The plugin carries the skills, all eight role agents, the scripts and the templates; the repo carries nothing but its config.

agent-skills comes with it automatically (`+ 1 dependency: agent-skills`). If you already use Addy's marketplace you will see agent-skills registered twice; that is expected and harmless, see the [user guide](docs/user-guide.md) for why.

**Option B — vendor into the repo with `install.sh`.** Use this when the pipeline must be driven by a harness that cannot load a Claude Code plugin (Codex CLI, Gemini CLI, Antigravity), or when you want the pipeline pinned in-tree and reviewed alongside your code.

```bash
bash path/to/talos/install.sh /path/to/your-repo
# add --harness codex or --harness antigravity to also write the AGENTS.md section
```

**Option C — manual copy.** Equivalent to Option B, by hand.

```bash
cp -r path/to/talos/scripts/   .claude/talos/scripts/
cp -r path/to/talos/skills/pipeline/ .claude/skills/pipeline/   # MUST be .claude/skills/ — see below
cp -r path/to/talos/templates/ .claude/talos/templates/   # required for rich messages
cp -r path/to/talos/agents/    .claude/agents/
```

The two paths coexist. Talos resolves its scripts in this order — plugin root (`$CLAUDE_PLUGIN_ROOT/scripts`), vendored (`.claude/talos/scripts`), source repo (`scripts`) — so if a repo has both, the plugin wins, which is what you want: it is the copy that matches the skill being run.

> **Why `.claude/skills/`?** Claude Code discovers skills at `<repo>/.claude/skills/<name>/SKILL.md`
> and `~/.claude/skills/<name>/SKILL.md`. It does not recurse, so a skill under
> `.claude/talos/skills/` — where Talos wrote it before 0.5.0 — registers no command at all.
> Re-run `install.sh` to migrate an older install; it relocates the file for you.
>
> The same rule governs agents: plugin-shipped role definitions must sit in `agents/`
> at the plugin root, which is where they moved in 0.6.0. Before that they lived in
> `.claude/agents/` and the plugin shipped none of them.

### 2. Configure

```bash
cp path/to/talos/talos.pipeline.yml.example talos.pipeline.yml
# Edit talos.pipeline.yml for your project
```

Minimum viable config (board and notifications optional):

```yaml
base_branch: dev        # the branch PRs target
verify:
  - python -m pytest tests/ -x -q   # your actual test command
```

### 3. Bootstrap labels (GitHub / GitLab / Azure only)

```bash
bash .claude/talos/scripts/bootstrap-labels.sh
```

This creates the `pipeline:*`, `qa:pass`, `review:approved`, `security:approved`, and `docs:done` labels in your repo (idempotent). Skip this step for file mode — checkboxes replace labels.

### 4. Optional: GitHub Project board

Create a GitHub Project with a single-select **Status** field. Set `board.enabled: true` and fill in `board.project_number` and `board.owner` in your config. (GitHub only; skipped in file mode.)

The pipeline validates and sets four status columns: **In progress**, **In review**, **Done**, and **Blocked**. A fifth column **Ready** is conventional for backlog visibility but is not set by the pipeline. If your board uses different column names, configure `board.status_map` to remap them (see Config reference below). When a required option is missing, the issue is still added to the board in the default column and `talos:board-unverified project=<N>` is emitted on stdout — the pipeline continues running (board failures are warnings, not fatal errors).

### 5. Optional: notifications

Set one or more of these in your environment (exported variables always win) or in a `.env` file at the repo root (`<repo>/.env`):

```
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
TEAMS_WEBHOOK_URL=https://...
```

Alternatively, set `notifications.slack_channel` / `notifications.discord_channel` in your config and put `SLACK_BOT_TOKEN` / `DISCORD_BOT_TOKEN` in `~/.hermes/.env` (Hermes platform credential store — optional convenience, not required).

For [Buzz](https://github.com/block/buzz) (self-hosted Nostr/NIP-29 workspace — no webhooks), install the [`nak`](https://github.com/fiatjaf/nak) CLI (`brew install nak`), set `notifications.buzz_channel` to the channel UUID, and provide the relay + bot key (env, repo `.env`, or `~/.hermes/.env`):

```
BUZZ_RELAY_URL=ws://your-relay:3000
BUZZ_BOT_PRIVATE_KEY=<bot nsec or hex secret>
```

Talos publishes a signed `kind:9` event tagged with the channel; on a closed or allowlisted relay, add the bot's pubkey as a member/allowlist entry first (see buzz's `NOSTR.md`).

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

All keys live in `talos.pipeline.yml` at your repo root. Every key is optional and falls back to a sensible default.

| Key | Default | Description |
|-----|---------|-------------|
| `base_branch` | repo default branch | Branch all PRs target |
| `release_branch` | `main` | Production branch (changelog headers) |
| `vcs.provider` | `github` | VCS backend: `github`, `gitlab`, `azure`, or `file` |
| `vcs.repo` | auto-detect | `owner/repo` override (required when git remote unavailable) |
| `vcs.azure.org_url` | — | Azure DevOps org URL (`https://dev.azure.com/MYORG`) |
| `vcs.azure.project` | — | Azure DevOps project name |
| `vcs.azure.work_item_type` | `Product Backlog Item` | Type for `create-issue` (Azure) |
| `vcs.azure.area_path` | project root | Area path new work items land in (Azure) |
| `vcs.file.source.path` | `plan.md` | Markdown checklist file for file mode |
| `board.enabled` | `false` | Enable board updates (GitHub Projects / Azure State) |
| `board.project_number` | — | Your project board number (GitHub) |
| `board.owner` | repo owner | GitHub org/user owning the board |
| `board.status_field` | `Status` | Single-select field name (GitHub) |
| `board.statuses.*` | see example | Display names for each status option (GitHub) |
| `board.status_map` | unset | Optional flat mapping from pipeline status names to the board's actual column names. Example: `{Blocked: "Needs attention"}`. An absent key passes through unchanged; omitting the map entirely is a no-op. Validation and option-ID lookup both run against the mapped name, so a correctly mapped name is treated as present. |
| `board.azure_states.*` | Scrum defaults | Pipeline status → ADO work-item State (Azure) |
| `verify` | `[]` | Shell commands every code subagent must pass |
| `merge.method` | `squash` | `squash`, `merge`, or `rebase` |
| `merge.required_checks` | `[]` | CI check names required before merge |
| `merge.delete_branch` | `true` | Delete feature branch after merge |
| `merge.forbidden_files` | see defaults | Glob patterns (matched against filename and full path) for files that must not appear in a PR. Defaults (20 patterns): `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`. Setting this key **adds** to the defaults (union semantics) — the built-in patterns remain active alongside any configured patterns. To replace the defaults entirely, also set `merge.forbidden_files_replace: true` (see below). **Note:** `*id_rsa*` also matches `id_rsa.pub` (a harmless public key) — this is an accepted false positive. If you commit public keys, add `id_rsa.pub` (or the specific filename) to `merge.forbidden_files_allow`. **Note:** `*.keystore` may also block self-signed test keystores committed for CI use — `fnmatch` cannot distinguish a real keystore from a test one. This is expected behaviour; operators who legitimately commit test keystores should add the specific filename to `merge.forbidden_files_allow` (e.g. `["test.keystore", "debug.keystore"]`). **Note:** `.netrc` and `_netrc` are literal patterns (no glob characters). As of #76 (PR #90), literal deny patterns generate canaries and wildcard allow entries that match them are rejected — the deferral that kept `.netrc` out of the defaults is resolved (#78). **Note:** Three extensions were deliberately excluded from the defaults in #78: `*.gpg` (`pass`/SOPS/git-crypt workflows commit GPG-encrypted blobs intentionally — encryption-at-rest is a legitimate reason to put a secret in a repo), `*.asc` (detached signatures and public signing keys are routinely committed as release artifacts), and `*.der` (DER is an encoding used equally by public X.509 certificates and private keys — the extension alone is not a reliable signal). If one of these applies to files that should genuinely never appear in your PRs, add the pattern to `merge.forbidden_files`. |
| `merge.forbidden_files_replace` | `false` | Set to `true` to restore the pre-v0.13 replacement behaviour: `merge.forbidden_files` will then **replace** the built-in defaults entirely rather than unioning with them. **Security warning:** this suppresses the built-in secret-protection patterns for every PR until the key is removed. A `talos:forbidden-files-defaults-replaced` marker is emitted on stdout on every run so the suppressed state is auditable in the PR record. Keep this `false` unless you have a specific reason to narrow the deny list. |
| `merge.forbidden_files_allow` | `[]` | Explicit exemptions for `merge.forbidden_files`. Globs matched against filename and full path, checked **before** deny patterns. Use this when a deny pattern over-matches a committed template (e.g. allow `.env.example` while keeping `.env.production` blocked). Example: `[".env.example"]`. **Security note:** each entry punches a hole in the secret-protection gate — if a real secret file matches an allow entry it will not be blocked. Keep the allow list minimal and specific. **Literal-override caveat:** the allow-list validation generates canaries from both wildcard and literal deny patterns. A wildcard allow entry (e.g. `*.env`) that matches a canary derived from any deny pattern is rejected. The one permitted exception is an allow entry that is an exact string match for a literal deny pattern (e.g. adding `.env` to allow when `.env` is a deny pattern) — this is treated as a deliberate operator decision to permit that specific file. Keep such overrides intentional and minimal. |
| `merge.approval_waiver_paths` | `["*.md", "docs/**", "CHANGELOG.md"]` | Glob patterns for files that, when they are the **only** changes between an approval SHA and the current head, do not invalidate that approval. A docs-only commit pushed after QA approval will therefore carry the approval forward rather than forcing a full re-run. **Hard-coded non-waivable (cannot be widened by this key):** any path under `scripts/`, any path under `tests/`, `talos.pipeline.yml`, and `pipeline.yaml` — these are enforced structurally after the config waiver check. **Validation:** entries that are too broad (catch-all globs such as `*`, `**`, `*/*`, or any pattern that would match the hard-coded non-waivable paths) are rejected at validation time and will **block the merge** (fail-closed), matching the behaviour of `merge.forbidden_files_allow`. Keep entries minimal and specific. |
| `issues.label_filter` | `pipeline:ready` | Label that queues issues |
| `issues.skip_labels` | `[pipeline:blocked, wontfix]` | Issues with these are skipped |
| `issues.max_parallel` | `1` | Max issues in-flight at once. **Concurrency warning:** raising this above `1` requires concurrency-safe `verify:` scripts. Talos provides filesystem isolation (one worktree per issue) but does NOT manage Docker/compose project names, port allocations, or shared scratch directories. Two simultaneous verify runs against a shared compose stack will collide — observed failures include container-recreate races, script overwrites, and green transcripts that describe the wrong worktree. Consuming projects must derive their own isolation from `TALOS_ISSUE_NUMBER` (e.g. `COMPOSE_PROJECT_NAME=talos-$TALOS_ISSUE_NUMBER`). With the integer guard in place, `TALOS_ISSUE_NUMBER` is guaranteed to be digits or empty — never shell-unsafe. **Footgun:** when `TALOS_ISSUE` is not set, `TALOS_ISSUE_NUMBER` is empty and the example yields `COMPOSE_PROJECT_NAME=talos-`, a name shared across all agents; under `max_parallel > 1` this silently undoes isolation. Always set `TALOS_ISSUE=<N>` when running concurrent pipelines. The default (`1`) has no contention and requires no action. |
| `roles.validator` | `true` | Phase-1 gate: confirms issue is real |
| `roles.pm` | `true` | Writes implementation spec |
| `roles.qa` | `true` | Verifies PR satisfies acceptance criteria |
| `roles.reviewer` | `true` | Code-quality review |
| `roles.security` | `true` | Security review |
| `roles.docs` | `true` | Updates docs/CHANGELOG; terminal stage |
| `roles.planner` | `false` | Epic decomposition (optional, off by default) — detects epics (via `epic` label, ≥ 4 checklist items, or body ≥ 2000 chars) and creates dependency-ordered sub-issues; independent sub-issues enter the queue immediately, dependent sub-issues are unblocked automatically as predecessors close |
| `comments.enabled` | `true` | Post a stage comment at each handoff (Daedalus parity) |
| `comments.header` | `**Agent:** {role} (talos)` | Header prepended to every stage comment; `{role}` is replaced at runtime |
| `comments.templates_dir` | `templates/comments` | Path (relative to repo root) containing comment templates |
| `notifications.slack_channel` | `""` | Slack channel ID fallback |
| `notifications.discord_channel` | `""` | Discord channel ID fallback |
| `notifications.buzz_channel` | `""` | Buzz channel UUID (Nostr `h` tag target) |
| `notifications.templates_dir` | `templates/notifications` | Path to notification message templates; `""` disables templates |
| `notifications.threading` | `true` | Thread all events per issue in one Slack/Discord thread (bot-token mode only) |
| `notifications.events` | all (unset) | Events filter. **Leave unset** — when set, any unlisted event is silently dropped, including all role events that make up the conversation stream. See warning below. |
| `limits.max_fix_attempts` | `3` | Max **consecutive** failures of the **same blocking stage** before `pipeline:blocked` is set. Resets to 1 when a different stage blocks next. **Behaviour change from v0.13:** this key previously counted every developer dispatch; it now counts consecutive same-stage failures only. Operators with existing configs should audit: a value of `3` previously allowed 3 total dispatches; it now allows 2 re-dispatches for the same stage (the third recording exits non-zero and blocks). |
| `limits.max_total_dispatches` | `8` | Absolute ceiling on total developer dispatches per issue, across all stage changes. **Never resets** — not even when the blocking stage changes. Prevents a QA→reviewer→QA ping-pong from exploiting per-stage resets to run indefinitely. When the total reaches this value, `record-attempt` exits non-zero regardless of which stage is blocking. |
| `markers.trusted_authors` | unset | Allowlist of GitHub login strings (YAML list) whose `talos:approval` and `talos:attempt` markers are accepted by `check-approval-sha` and `read-attempt`. Example: `["talos-bot", "gh-actions-bot"]`. When set and non-empty, a marker from any login not in the list is silently skipped — treated as absent by `read-attempt`, or as stale by `check-approval-sha`. **When absent or empty, author checking is skipped entirely (fail-open). The key's absence is NOT equivalent to enforced author security** — an operator should not treat this key as protection they have until it is actually set and non-empty. When author checking is skipped, both readers emit `talos:marker-authors-unverified reader=<verb>` on stdout (see Marker placement and trusted-author allow-list below). |

### Board status options: required columns and `talos:board-unverified`

The pipeline sets four GitHub Projects Status column values during a run: `In progress`, `In review`, `Done`, and `Blocked`. On the first `pipeline-status.sh` call of a run, the script fetches the board's Status field options and verifies all four are present (after `board.status_map` substitution — so a mapped name is what gets checked, not the default pipeline name).

**What happens when a required option is missing:** the issue is still added to the board in the project's default column (`item-add` runs before the option check). A `talos:board-unverified project=<N>` marker is emitted on stdout, a warning naming the missing option(s) is written to stderr, and the script exits 0. Board failures are warnings by design (Rule 11) — a missing column degrades visibility, not progress. The pipeline continues running normally.

| Marker | When emitted | What to do |
|--------|-------------|-----------|
| `talos:board-unverified project=N` | A required Status option (`In progress`, `In review`, `Done`, or `Blocked`, after `status_map` substitution) is absent from the board | Add the missing column to the project, or map the pipeline name to an existing column via `board.status_map` (see config table above) |

**`board.status_map` worked example.** If your board uses "Needs attention" instead of "Blocked":

```yaml
board:
  enabled: true
  project_number: 4
  owner: myorg
  status_map:
    Blocked: "Needs attention"
```

With this config, `pipeline-status.sh 42 "Blocked"` looks up and sets the "Needs attention" column option. The `talos:board-unverified` warning is suppressed as long as "Needs attention" exists on the board. Keys not in `status_map` pass through as-is (e.g. `In progress`, `In review`, and `Done` continue to use their default names).

Note: `Ready` is a conventional fifth column that operators often add for backlog visibility, but the pipeline does not set it via `pipeline-status.sh` and it is not included in the startup validation.

### Forbidden-files gate: stdout markers

`check-pr-files` emits the following markers on **every** run so the gate state is always auditable in the pipeline record:

| Marker | When emitted | Fields |
|--------|-------------|--------|
| `talos:forbidden-files-active patterns=N defaults=STATE` | Always (every run) | `N` = number of active deny patterns; `STATE` = `in-force` (built-in defaults are active) or `replaced` (defaults suppressed by `merge.forbidden_files_replace: true`) |
| `talos:forbidden-files-defaults-replaced patterns=N` | Only when `merge.forbidden_files_replace: true` | Signals that built-in secret-protection patterns are suppressed — a weakened gate. |

`defaults=replaced` in the `talos:forbidden-files-active` marker means the operator opted out of the built-in defaults. Treat this as an audit flag: a PR that passes `check-pr-files` with `defaults=replaced` was checked against a reduced deny list. The clean-path message also records this state: `no forbidden files [N patterns: defaults=replaced]`.

The `talos:forbidden-files-defaults-replaced` marker is also emitted as a stderr warning to make suppression visible in agent logs regardless of stdout capture.

### `github-api` provider: allow-list validation now enforced (behaviour change)

Prior to this release the `github-api` provider ignored `merge.forbidden_files_allow` entirely — it performed no allow-list validation. As of v0.14 the `github-api` provider performs the same allow-list canary validation as the `github` provider. **If you are using the `github-api` provider with `merge.forbidden_files_allow` set, an overly-broad allow entry (such as `*`) that previously passed silently will now be rejected at validation time and will block the merge.**

### Upgrade note: `merge.forbidden_files` union semantics (v0.14+)

**If you have `merge.forbidden_files` set in your `talos.pipeline.yml` before upgrading to v0.14+, your configuration now means something different.**

Previously, setting `merge.forbidden_files` replaced the built-in defaults entirely — only your configured patterns were active. From v0.14 onward, your configured patterns are **added to** the built-in defaults (union semantics). The built-in patterns (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`) are always active alongside your patterns.

**What to do:**

- **If you intended to add extra patterns on top of the defaults** (the common case): no action required. Your config now works as you most likely intended.
- **If you intentionally narrowed the deny list** (removed some built-in patterns to allow those file types): add `merge.forbidden_files_replace: true` to restore the old replacement behaviour. Review the security warning in the `merge.forbidden_files_replace` table row above before doing so — replacement suppresses all built-in secret-protection patterns and should be treated as a deliberate security trade-off.

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

Notification messages are rendered as Slack Block Kit (header + section + colored attachment) or Discord embeds (title/description/color/footer). The first line of the rendered template becomes the title; the rest becomes the body. Templates use `${PLACEHOLDER}` substitution with these variables:

| Variable | Value |
|----------|-------|
| `${ICON}` / `${EVENT}` / `${MSG}` | event icon, event name, message text |
| `${REF}` | issue ref as passed (e.g. `#42`) |
| `${ROLE}` | role label (validator / project-manager / developer / …) |
| `${TITLE}` / `${REF_TITLE}` | issue title / `#42: title` |
| `${PR}` / `${PR_TITLE}` / `${PR_REF}` | PR number / title / `PR #9: title` |
| `${ISSUE_URL}` / `${PR_URL}` | GitHub URLs (empty if undetectable) |
| `${REF_LINK}` / `${PR_LINK}` | markdown links `[#42: title](url)` — Slack/Discord render them clickable; fall back to plain text when no URL |
| `${BOARD}` | board name (owner-repo) |

Keep the first template line free of markdown links — Discord embed titles don't render them (the embed title is made clickable via the embed `url` instead). Put `${REF_LINK}`/`${PR_LINK}` in the body.

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

**Events-filter warning:** `notifications.events` defaults to unset (all events fire). If you set a list, any event not in it is **silently dropped** — no error, no log line. A lifecycle-only list like `[pr-opened, merged, blocked, issue-closed]` kills the entire conversation stream. When you need a filter, copy the full list from `talos.pipeline.yml.example` and remove only what you don't want.

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
| `PIPELINE_BUZZ_CHANNEL` | `notifications.buzz_channel` |
| `PIPELINE_THREAD_STATE` | path to thread anchor state file (default: `~/.talos/threads.json`) |
| `PIPELINE_REPO_URL` | repo URL used to build issue/PR links (default: detected via `gh repo view`) |
| `PIPELINE_ISSUE_TITLE` / `PIPELINE_PR` / `PIPELINE_PR_TITLE` | issue/PR context for templates (skips the `gh` lookups) |
| `PIPELINE_NOTIFY_DEBUG` | set to `1` to print payloads without posting (safe for testing) |
| `PIPELINE_RUN_ID` | when set, scopes the per-run board-validation sentinel in `pipeline-status.sh` to this value so multiple concurrent pipeline runs sharing one `/tmp` directory do not interfere with each other. Without it, the sentinel is keyed on project number alone. |
| `TALOS_SWEEP_ALL_LANES` | set to `1` to allow `pipeline-worktree.sh sweep` to run across all lanes when multiple `.talos-lane-home` markers exist in the repo. Without this, sweep exits safely when more than one lane home is detected (multi-lane interlock). `remove <N>` is always unaffected by this variable. |

### Per-issue notification threading

When `notifications.threading: true` (the default) and a Slack or Discord **bot token** is in use, all events for the same issue land in a single thread rather than flooding the channel as separate top-level messages. Buzz is always key-based, so it always threads when enabled — follow-ups publish as NIP-10 replies (`["e", <root-id>, "", "reply"]`) to the issue's root event.

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

After each subagent completes, the orchestrator relays that agent's findings summary to the channel thread using the role name as the event. `pipeline-notify.sh` renders the message from `templates/notifications/<role>.md` when that file exists. This makes the Slack/Discord thread read as a **conversation between agents** — validator speaks first, then developer, QA, docs, reviewer, security, and finally orchestrator announces the merge. This mirrors Daedalus's thread delivery model.

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

Thread anchors are stored in `~/.talos/threads.json` keyed by `<repo-slug>:<issue-number>`. If the anchor message is deleted, the script detects the stale anchor, clears it, and posts a fresh root thread automatically.

**Webhook mode limitation**: Slack incoming webhooks and Discord webhooks do not expose thread IDs at post time, so threading is silently skipped in webhook mode. Use bot tokens if threading is important.

---

## How a run works end-to-end

1. You run `/pipeline` in a Claude Code session.
2. The orchestrator reads `talos.pipeline.yml` and reconciles any in-flight PRs from a previous run.
3. It lists issues with `pipeline:ready` (up to `max_parallel`).
4. For each issue:
   - **Validator** reads the issue and codebase. CONFIRMED advances; anything else sets `pipeline:blocked`.
   - **PM** turns the confirmed issue into a spec comment (goal, acceptance criteria, branch name, out-of-scope).
   - **Developer** spawns in an isolated git worktree. It implements, runs your `verify` commands, and opens a PR. The worktree is removed (branch and all) right after the PR merges, via `pipeline-worktree.sh remove`; a startup sweep reclaims any orphaned worktree as a backstop.
   - **QA** checks out the PR branch and verifies each acceptance criterion.
   - **Docs** runs first after QA passes (phase 1); **Reviewer + Security** run in parallel after docs completes (phase 2).
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
| `create-issue` | `<title> <body-file> [--label label]` | Create a new issue; `--label` may be repeated (used by planner to create sub-issues). Exits non-zero if the POST fails. |
| `list-issues` | | List open issues / unchecked plan items |
| `view-issue` | `<id>` | Show issue body and metadata |
| `comment-issue` | `<id> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on an issue. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. **Exits 1 if the issue is closed** unless `--allow-closed` is passed (required when GitHub auto-closes via `Closes #N` at merge). Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup (network error), posts (exit 0) and emits `talos:comment-state-unverified target=issue#<N> reason=<short>` on stdout. |
| `close-issue` | `<id> [reason]` | Close an issue |
| `label-issue` | `<id> --add label [--remove label]` | Add/remove labels (or tags for Azure) |
| `create-pr` | `<branch> <title> <body-file>` | Open a PR targeting base_branch. Exits non-zero if the POST fails. |
| `view-pr` | `<branch>` | Show PR number, URL, status |
| `list-prs` | | List open PRs |
| `diff-pr` | `<pr-number>` | Show PR diff (Azure: via `git diff` between refs) |
| `checkout-pr` | `<pr-number>` | Check out a PR branch locally |
| `approve-pr` | `<pr-number> [summary]` | Approve a PR |
| `label-pr` | `<pr-number> --add label [--remove label]` `[--require-marker]` | Add/remove PR labels. When an approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) is added and no approval marker exists at the current PR head, a WARNING is printed to stderr and the command exits 0 (non-fatal, so label-then-stamp call sites continue working). Pass `--require-marker` to make this check fatal and pre-apply: the label is not added if no marker is present at the current head (exits 1). `--require-marker` and the post-apply warning are `github` provider only. See **Approval-marker guard** below. |
| `pr-checks` | `<pr-number>` | List CI check statuses |
| `merge-pr` | `<pr-number>` | Merge a PR (uses `merge.method` from config) |
| `comment-pr` | `<pr-number> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on a PR. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. **Exits 1 if the PR is closed without being merged** unless `--allow-closed` is passed. Merged PRs are always commentable without the flag. Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup, posts (exit 0) and emits `talos:comment-state-unverified target=pr#<N> reason=<short>` on stdout. |
| `find-pr` | `<issue-number> [open\|merged\|all]` | Find PRs belonging to an issue (session-recovery adoption) |
| `check-pr-files` | `<pr-number>` | Exit 1 if the PR touches `merge.forbidden_files` patterns |
| `check-closing-keyword` | `<pr-number> <issue-n>` | Exit 1 if the PR body carries a closing keyword (`Closes/Fixes/Resolves #N`, all standard verb forms, case-insensitive, including `owner/repo#N` and full GitHub issue URL forms — both scoped to the current repository — and `GH-N` (case-insensitive)) while other PRs referencing issue `N` are still open. Fail-open: exits 0 and emits `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` on stdout when PR body or sibling list cannot be fetched or repository cannot be resolved. GitHub provider only; no-op under gitlab, azure, and file. |
| `rerun-ci` | `<pr-number>` | Re-run failed CI runs for the PR head SHA (flaky-CI retry) |
| `pr-head` | `<pr-number>` | Print the current head SHA for a PR. Fail-closed: exits 1 when the SHA cannot be resolved. Used by approval roles to stamp the SHA they approved. |
| `check-approval-sha` | `<pr-number>` | Exit 1 if any approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) was earned against a non-current head SHA whose delta is not fully covered by `merge.approval_waiver_paths`. Fail-closed: unresolvable head SHA, missing marker, invalid waiver config, or `git diff` failure all exit non-zero. |
| `record-attempt` | `<issue-n> <stage>` | Record one re-dispatch attempt for the given blocking stage on the issue. Reads prior state, computes the new per-stage count and running total, posts a `<!-- talos:attempt -->` marker comment on the issue, verifies the write landed, and prints `stage=<s> count=<k> total=<t>` on stdout. Exits non-zero when either ceiling (`max_fix_attempts` or `max_total_dispatches`) would be reached by this attempt — callers must check the exit code before re-dispatching the developer. Fail-closed: a corrupt or unparseable marker exits non-zero rather than silently resetting to zero. |
| `read-attempt` | `<issue-n>` | Print the current attempt state (`stage=<s> count=<k> total=<t>`) from the most-recent attempt marker on the issue. Prints `stage= count=0 total=0` when no marker exists (a new issue). Always exits 0 unless the marker is corrupt (in which case it exits 1, fail-closed). Read-only; does not post a new comment. |
| `check-attempt` | `<issue-n>` | Exit 1 (with reason on stderr) when either ceiling is already reached for the issue. Exit 0 otherwise. Does **not** record a new attempt — use `record-attempt` for that. Fail-closed: propagates a corrupt-marker exit 1 from `read-attempt`. |
| `assert-sync` | | Assert the orchestrator working tree is clean and current with `origin/<base_branch>`. **Dirty tree** (any uncommitted change) — exits 1, names the dirty files, instructs operator to commit or stash; this check runs *before* `git fetch origin` so the tree is never read in a mixed state. **Behind origin** — exits 1, prints both local and remote SHAs plus the commit gap, instructs `Run: git pull --ff-only`. **Diverged** (ahead and behind simultaneously) — exits 1, warns against force-push. **Ahead of origin only** — exits 0 but prints a stderr warning: *"pipeline-vcs: assert-sync: WARNING -- working tree is ahead of origin/<base> by N commit(s); non-isolated stages will read unpushed commits."* **Clean and level** — exits 0, no output. `base_branch` is resolved in order: `talos.pipeline.yml` config key, then `git symbolic-ref refs/remotes/origin/HEAD`, then `main`. Provider-agnostic; runs before the VCS provider dispatch. |

**Stale-checkout guard.** Non-worktree-isolated stages (reviewer, security) evaluate a PR by reading source from the orchestrator's working tree alongside the diff output from `diff-pr`. If that tree is stale or dirty, those stages read wrong context — in the incident that prompted this (PR #92), a one-commit-behind checkout led the security stage to produce a detailed, confident, entirely wrong BLOCK. `assert-sync` is called at two points: the end of Step 0 (before any work begins for the issue) and immediately before Phase 2 of section 3e (before reviewer and security are dispatched, because `main` can advance between run-start and that dispatch). A non-zero exit halts the current issue with the error output; the operator is given the exact failure state and a recovery instruction. The verb never stashes, never pulls over uncommitted work, and never force-pushes. An operator who hits the dirty-tree ABORT should commit or stash their in-progress work and re-run the pipeline. An operator who sees the **ahead-of-origin warning** (exits 0) should be aware that reviewer and security will read commits that are not yet visible on the remote; this is the same class of problem as a stale tree, mirrored — the non-isolated stages see source that no other observer can verify.

**Attempt-counting model.** Attempt state is stored as a `<!-- talos:attempt stage=<s> count=<k> total=<t> -->` HTML comment posted by `record-attempt` on the issue (not in orchestrator memory). Because the state lives on GitHub, it survives a crashed or restarted orchestrator session — the next session reads the same counts from the issue. Two ceilings apply:

- **Per-stage ceiling** (`limits.max_fix_attempts`, default 3): counts consecutive failures of the **same** blocking stage. The count resets to 1 the first time a **different** stage blocks. With the default of 3, the developer can be re-dispatched twice for the same stage; the third recording exits non-zero and blocks.
- **Total ceiling** (`limits.max_total_dispatches`, default 8): counts every re-dispatch across all stages, and never resets. With the default of 8, the developer can be re-dispatched seven times in total before the eighth recording blocks. This ceiling exists to stop a QA→reviewer→QA ping-pong from exploiting per-stage resets to run indefinitely.

Both ceilings use `>=` comparison: they trigger when the count **reaches** the configured value, not only when it exceeds it.

**Fail-closed and recovery.** The reader uses a two-stage detector: a loose pattern finds any comment that looks like a `talos:attempt` marker, and a strict pattern validates it. If a comment matches the loose pattern but fails strict validation (unknown stage name, non-numeric field, `total < count`, missing field, etc.), all three verbs exit 1 rather than silently treating the issue as having zero attempts. This prevents a corrupted marker from inadvertently granting an infinite retry budget.

If an issue becomes blocked with a corrupt marker, the recovery procedure is:

1. Go to the GitHub issue.
2. Find the comment containing the `<!-- talos:attempt ... -->` marker (search for `talos:attempt` in the comment thread).
3. Delete that comment using the GitHub UI (three-dot menu → Delete).
4. `read-attempt` will then fall back to the next most-recent valid marker, or report zero attempts if none exists.
5. Remove `pipeline:blocked`, re-add `pipeline:ready` to re-enter the pipeline.

Do not edit the marker comment — partial edits may leave it in an ambiguous state. Delete and let the pipeline rewrite it.

**`talos:attempt` marker placement.** `read-attempt` requires the `<!-- talos:attempt ... -->` marker to be the **last non-whitespace line** of the comment body. A marker that appears earlier in the body — for example inside a GitHub Quote-reply block — is silently skipped (see Marker placement and trusted-author allow-list below for the full rule, which applies equally to `talos:attempt` and `talos:approval`).

**Approval-SHA model.** Each approval role stamps `<!-- talos:approval sha=<HEAD_SHA> role=<role> -->` in its verdict comment when posting a pass. At Step 4, `check-approval-sha` compares every present approval label's stamped SHA against the current PR head. If a stamped SHA is older than the current head, the tool runs `git diff <approval-sha>..<current-head>` to collect changed files, then intersects that set with the PR's own file set (computed via `git diff origin/<base>...<current-head>`, a three-dot diff against the base branch) to exclude files that arrived purely from a routine base-branch sync. Every file remaining in the intersection is checked against `merge.approval_waiver_paths`. A file touched by both the sync and the PR stays in the intersection and is evaluated normally. If the three-dot diff cannot be computed, the full two-dot set is used (fail-closed). If any non-waivable file remains after filtering (or the two-dot diff cannot be computed), the gate blocks the merge, strips the stale labels, and the orchestrator re-dispatches the affected stages. A human sees a PR comment listing which labels were stale and why; the fix is to re-run the affected stage (e.g. ask QA to re-approve after a source-code push).

**Marker placement and trusted-author allow-list.** Both `check-approval-sha` (for `talos:approval`) and `read-attempt` (for `talos:attempt`) enforce two independent rules on every marker they read:

1. **Last-line rule (unconditional).** The marker must be the **last non-whitespace line** of the comment body. A marker that appears anywhere else in the body — including inside a GitHub "Quote reply" block, a fenced code block, or any earlier paragraph — is silently skipped and does not satisfy the gate. This rule is unconditional: it is enforced regardless of whether `markers.trusted_authors` is configured. The reason is to prevent a GitHub Quote-reply from replaying an earlier approval; a quoted or copied marker must not reactivate a gate. For agents and operators posting approval comments, this means the `<!-- talos:approval sha=... role=... -->` line must be the final content of the comment with no non-whitespace text after it. `record-attempt` always writes its marker as the last line automatically; do not edit a `talos:attempt` comment in a way that appends content after the marker.

2. **Author allow-list (configured via `markers.trusted_authors`).** When this config key is set and non-empty, only markers posted by a login in the list are accepted; markers from any other author are silently skipped. When the key is absent or empty, this check is skipped entirely (fail-open) — **an unconfigured key provides no author-verification protection**. See the `markers.trusted_authors` row in the config table for details.

**`talos:marker-authors-unverified` marker.** When `markers.trusted_authors` is absent or empty, both `check-approval-sha` and `read-attempt` emit `talos:marker-authors-unverified reader=<check-approval-sha|read-attempt>` on **stdout** before accepting a marker. Exit status is unchanged — the marker is accepted and the gate proceeds normally (fail-open). This machine-readable line signals that author provenance was not verified; no pipeline action is triggered. Operators who see this marker in logs and want author enforcement should configure `markers.trusted_authors`.

Pass `--dry-run` as the first argument to print the underlying CLI command without executing it. Pass `--allow-closed` to bypass the closed-target guard on `comment-issue` and `comment-pr`.

**Closed-target guard.** `comment-issue` and `comment-pr` refuse to post on a closed issue or a closed-unmerged PR (exit 1) by default. A comment filed on a closed issue is silently lost in the GitHub UI — no notification is sent to anyone watching the issue, so findings filed this way disappear without trace (see issue #55). The one legitimate exception is the post-merge orchestrator summary, where GitHub auto-closes the issue via `Closes #N` before the comment step runs; pass `--allow-closed` there. Merged PRs are always commentable without the flag.

**Comment URL on stdout (behaviour change).** Both `comment-issue` and `comment-pr` print the `html_url` of the created comment to stdout on success (e.g. `https://github.com/owner/repo/issues/42#issuecomment-123`). Capture it for relay messages or audit trails — no re-fetch required. **Callers that previously captured output from these verbs will now receive a URL instead of empty output.**

**`talos:comment-state-unverified` marker.** When the state-check API call fails (transient network error, insufficient token scope), both verbs post the comment anyway (exit 0) and emit `talos:comment-state-unverified target=<issue|pr>#<N> reason=<short>` on stdout after the URL line. Operators who see this marker in logs should verify manually that the target was open at post time; no action is required if the pipeline is otherwise healthy.

**POST failure exits non-zero (behaviour change from previous versions).** `comment-issue`, `comment-pr`, `create-issue`, and `create-pr` now exit non-zero immediately when the underlying HTTP POST fails, on both the `github` (gh CLI) and `github-api` providers. Previously, a failed POST was silently absorbed by the subshell-capture assignment — the script returned exit 0 with no URL on stdout, indistinguishable from success to a caller that did not check `$?`. **Callers must check the exit status** after any of these four verbs: a non-zero exit means the remote operation failed and no comment, issue, or PR was created. No URL is printed on failure.

**Bare-path guard (`comment-pr` / `comment-issue`).** Both verbs reject a positional `<body>` argument that is a readable absolute path (i.e. starts with `/` and `[ -r ]` resolves). The command exits 1 with a hint to use `--body-file` instead. This prevents the silent failure mode where an agent writes a verdict to a file, passes the path as the body argument, and receives exit 0 with a one-line path as the posted comment. A string that starts with `/` but does not resolve to a readable file on the current machine is still posted as literal text (no over-rejection). The guard covers both the `github` and `github-api` providers.

```
# Wrong — posts the file path as a one-line comment (now exits 1):
bash scripts/pipeline-vcs.sh comment-pr 9 /tmp/verdict.md

# Correct — posts the file content:
bash scripts/pipeline-vcs.sh comment-pr 9 --body-file /tmp/verdict.md
```

**Approval-marker guard (`label-pr`).** When `label-pr --add <approval-label>` successfully applies a recognised approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) and no approval marker exists at the current PR head, the command prints a WARNING to stderr naming the exact `comment-pr` command needed and exits 0 (non-fatal, so existing label-then-stamp call sites continue working). The warning reads:

```
pipeline-vcs: label-pr: WARNING — added approval label(s) but no approval marker found at current head.
pipeline-vcs: label-pr: If you have not already posted your verdict reasoning, do so first.
pipeline-vcs: label-pr: The gate will reject this PR. Post the marker:
pipeline-vcs:   HEAD_SHA=$(bash scripts/pipeline-vcs.sh pr-head N)
pipeline-vcs:   bash scripts/pipeline-vcs.sh comment-pr N "<!-- talos:approval sha=$HEAD_SHA role=<role> -->"
```

Pass `--require-marker` to make the check fatal and pre-apply: the label is not added if no marker exists at the current head; the command exits 1 with the same corrective hint. Both the post-apply warning and `--require-marker` are `github` provider only — the `github-api` provider is silently unprotected by this guard. Operators using `github-api` who want marker enforcement should use `check-approval-sha` directly after labelling.

**Closing-keyword gate.** `check-closing-keyword <pr> <N>` exits 1 when the PR body carries a closing keyword (`Closes/Fixes/Resolves #N`, all standard verb forms, case-insensitive) in any recognised reference form and at least one other PR referencing issue `N` is still open. Merging a PR with a closing keyword while siblings are in flight would auto-close the issue tracker and orphan that in-progress work.

Recognised reference forms:

- `#N` (bare, implicitly current repo) and `repo#N` (single-segment, no slash) — the `#` provides the left boundary; these forms are not repo-scoped
- `owner/repo#N` — scoped to the current repository (case-insensitive on owner and name); a foreign `other-owner/other-repo#N` does **not** match
- `GH-N` (case-insensitive; a `(?<![0-9])` left-guard prevents a digit-prefixed token such as `1GH-57` from matching; a `(?!\d)` right-guard prevents `GH-571` from matching issue 57)
- `https://github.com/<owner>/<repo>/issues/N` — scoped to the current repository (case-insensitive on owner/name); trailing `/`, `?query`, or `#fragment` are allowed; a URL pointing to a foreign repository's issue does **not** match

The colon form `Closes: #N` is **not** recognised. It is not part of GitHub's documented closing-keyword syntax, and the gate deliberately excludes it. A PR body that uses only the colon form will not trigger the gate, and no `talos:closing-keyword-unverified` marker is emitted.

This gate implements Rule 6: the legitimate final PR in a multi-PR issue says `Closes #N`. By the time it is ready to merge, all prior siblings are already merged — no open siblings exist, so the gate exits 0 and does not block. The gate only fires when a sibling is still open. An operator who sees this gate block should either merge the open sibling PRs first, or change this PR's body from `Closes #N` to `Part of #N` if it is not actually the final PR.

**Known limitation:** a lone PR that overclaims its deliverables (one PR carrying `Closes #N` with no sibling PRs at all) cannot be detected by this gate. Detecting overclaiming requires a work-ledger that records how many items the issue committed to; nothing in the pipeline maintains such a ledger in VCS mode today. This gate exclusively catches the sibling-still-open case.

**`talos:closing-keyword-unverified` marker.** When the PR body fetch or the open-PR list fetch fails (network error, insufficient token scope), `check-closing-keyword` exits 0 (fail-open) and prints `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` to stdout. The `reason` field is one of `pr-fetch-failed`, `sibling-fetch-failed`, `sibling-check-failed`, or `repo-unresolved` (emitted when the current repository cannot be resolved, so repo-scoped forms cannot be checked). Operators who see this marker in logs should confirm that any sibling PRs are in the expected state before the merge proceeds. No automatic pipeline action is triggered; the existing CI and approval gates still apply.

**`find-pr` anchored issue-number matching (behaviour change).** `find-pr <N>` previously used substring matching, so `find-pr 7` could match a branch named `fix/issue-71-x` or a PR body containing `#71`. Both checks are now anchored: branch names must match `(?:^|/)issue-N(?:-|$)` and body text must match `#N(?!\d)`. As a result, `fix/issue-71-x` is no longer returned by `find-pr 7`, and `#71` in a body no longer matches issue `7`. This affects Step 1 session-recovery reconciliation — the orchestrator's `find-pr` call will no longer adopt a PR whose branch or body merely shares a numeric prefix with the target issue number.

---

## Other harnesses: pi, Codex CLI, Gemini CLI, Antigravity, local models

Claude Code is the first-class harness (native subagents, worktree isolation),
but the pipeline itself is plain bash + markdown — any **agentic** CLI can
orchestrate it. The execution mode is chosen by `agents.subagents` and
`agents.runner` in `talos.pipeline.yml`:

```yaml
agents:
  runner: codex        # claude (default) | pi | codex | gemini | antigravity | custom
  subagents: auto      # auto | true | false   (auto = true for claude, else false)
  model: claude-haiku-4-5-20251001   # optional — model for all stages (native path only)
  roles:               # optional — per-role model overrides (native path only)
    reviewer: {model: claude-opus-5}
```

- **`runner: claude`** (subagents: true) — native parallel subagents.
- **`runner: pi`** (subagents: false) — **inline one-agent-per-turn**: the pi
  session acts as each stage role itself (validator → pm → developer → qa →
  review/security/docs → merge), one role per turn. No subagents, no
  `pipeline-agent.sh`, no subprocesses. Works on any provider backing pi
  (Claude account via `/login` or `ANTHROPIC_API_KEY`, or a local model). For
  a fully offline pipeline, combine pi with `vcs.provider: file` — `plan.md`
  is the board, no remote/VCS/auth needed.
- **Any other runner** (subagents: false) — headless per-stage via
  `pipeline-agent.sh`, e.g. `bash install.sh /path/to/your/repo --harness codex`
  to add a marker-fenced Talos section to `AGENTS.md` telling the harness to
  follow the playbook and run role stages through the adapter:

  ```bash
  bash .claude/talos/scripts/pipeline-agent.sh <role> - <<'PROMPT'
  <stage prompt>
  PROMPT
  ```

  The adapter merges `.claude/agents/<role>.md` (frontmatter stripped) with the
  stage prompt and executes it via the runner configured in `talos.pipeline.yml`
  (`codex` → `codex exec`, `pi` → `pi -p`, `custom` → `runner_cmd` on stdin).

### Per-role model selection (`agents.model` and `agents.roles.<role>.model`)

**Applies to the native path (`subagents: true`) only.** The adapter path (`subagents: false`) routes by role using `$TALOS_ROLE` in `runner_cmd` — see below.

When spawning each subagent the orchestrator resolves the model in three steps:

1. `agents.roles.<role>.model` — role-specific override.
2. `agents.model` — global model for all stages not explicitly overridden.
3. Neither present — omit `model:` entirely; the Agent SDK inherits the session default (current behaviour, fully backwards compatible).

**Judgement vs. volume (the primary use case):** implementation work is high-volume and verifiable; review work requires judgement. Set a cheap model globally and a quality model for the stages that matter:

```yaml
agents:
  runner: claude
  model: claude-haiku-4-5-20251001      # volume stages: developer, QA, docs, …
  roles:
    reviewer: {model: claude-opus-5}    # judgement stages
    security: {model: claude-opus-5}
```

Two overrides rather than eight entries. A new role added later automatically inherits `agents.model` rather than silently reverting to the session default.

**Global override (all stages, one model):**

```yaml
agents:
  model: claude-sonnet-5    # all stages; no roles: block needed
```

**Backwards compatibility:** a config with no `model:` key at either level behaves byte-identically to earlier versions — `model:` is omitted from each Agent spawn call.

**pi:** register the `pipeline` skill with pi (e.g. `skills` in `~/.pi/settings.json`
pointing at this repo's `skills/`), set `agents.subagents: false` and
`agents.runner: pi`, then tell pi to run the talos pipeline. The playbook's
Harness-compatibility section handles the inline mode. No `install.sh --harness pi`
needed — pi reads the canonical skill directly.

**Google Antigravity:** `--harness antigravity` writes the same `AGENTS.md`
section (Antigravity reads `AGENTS.md` natively since v1.20.3; `GEMINI.md`
takes precedence when both exist). Set `agents.runner: antigravity` in
`talos.pipeline.yml` to route role stages through `agy -p`.

**Local models:** the `custom` runner accepts any command, so a local-model
pipeline works by pointing `runner_cmd` at an agentic CLI backed by Ollama,
llama.cpp, or similar. The hard requirement is *agentic*, not *cloud*: whatever
runs a stage must be able to execute shell commands and edit files — a bare
chat endpoint can generate text but cannot open a PR. Expect stage quality to
track model capability; the validator/QA gates exist precisely to catch weak
stage output.

`TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, and `TALOS_WORKTREE_PATH` identify the current stage across both execution paths. How they arrive depends on the path:

- **Adapter path (`subagents: false`, `pipeline-agent.sh`):** all three are exported as real shell variables to every `runner_cmd` invocation. `TALOS_ISSUE_NUMBER` is the issue number passed by the caller via `TALOS_ISSUE=<N>`; it is the empty string when the caller does not set `TALOS_ISSUE`. **`TALOS_ISSUE` must be a plain non-negative integer (digits only) or unset** — any other value (shell metacharacters, whitespace, letters) causes `pipeline-agent.sh` to exit 2 with a diagnostic before the runner is invoked. `TALOS_WORKTREE_PATH` is `$PWD` at the time `pipeline-agent.sh` was invoked. These are real shell exports — verify scripts inherit them automatically.

- **Native path (`subagents: true`, Claude Code):** there is no shared shell environment between the orchestrator and a subagent. `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` are injected into the stage's **task prompt**; the stage is instructed to `export` them before running any `verify:` command. This is **instruction-based and not airtight** — a stage that ignores the instruction runs verify without the exports. The exports make a degraded run visible (verify scripts can self-check) without claiming to make identity confusion impossible.

Verify scripts can self-check their environment on the adapter path (and on the native path when the stage exports correctly):

```bash
if [ "${TALOS_ISSUE_NUMBER:-}" != "$EXPECTED_ISSUE" ]; then
  echo "ERROR: wrong environment (expected $EXPECTED_ISSUE, got '${TALOS_ISSUE_NUMBER}')" >&2
  exit 1
fi
```

`TALOS_ROLE` lets you route by role without a wrapper script. For the judgement-vs-volume split:

```yaml
agents:
  runner: custom
  runner_cmd: |
    case "$TALOS_ROLE" in
      developer|qa) exec pi -p --provider ds4 --model deepseek-v4-flash "$(cat)" ;;
      *)            exec claude -p "$(cat)" ;;
    esac
```

Example — llama.cpp serving an OpenAI-compatible endpoint:

```bash
# --jinja enables tool/function calling — agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

Then drive stages through any OpenAI-compatible agentic CLI, e.g. Aider:

```yaml
agents:
  runner: custom
  runner_cmd: >-
    OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local
    aider --model openai/local --yes-always --no-auto-commits --message "$(cat)"
```

Or configure Codex CLI with a local provider profile
(`~/.codex/config.toml` → `[model_providers.llamacpp]`
`base_url = "http://localhost:8080/v1"`) and use the named runner:

```yaml
agents:
  runner: codex
  runner_args:
    - --profile
    - local
```

Pick a model that supports function calling (Qwen coder-class or similar) —
models without it will chat about the task instead of executing it. For a
fully offline pipeline, combine a local runner with `vcs.provider: file`.

---

## Multi-lane repos and `.talos-lane-home`

A single git remote can host multiple independent pipeline lanes — for example, a canonical `main` lane and one or more LLM-experiment branches (`qwen`, `phi4`, etc.) each with their own config and queue. These share one repo, which creates two hazards:

1. **PR scope bleed** — `gh pr list` is repo-wide. Without lane scoping, Step 1 reconciliation in lane A can adopt an in-flight PR that belongs to lane B, retarget it, and merge it into the wrong base branch. The `base_branch` config key sets `--base` on every `list-prs` call so each lane only sees its own open PRs.

2. **Sweep scope bleed** — `pipeline-worktree.sh sweep` is also repo-wide. An inline runner (`agents.runner: pi`) checks out `fix/issue-<N>-*` directly in its lane home directory, making that home match the per-issue worktree pattern. A sweep from another lane would delete a live checkout mid-run.

The `.talos-lane-home` marker file prevents the second hazard. An operator creates it by hand in every checkout that is a lane home:

```bash
touch /path/to/lane-home/.talos-lane-home   # mark once; never commit it
```

The file is untracked and never propagates to worktrees created from a branch, so per-issue developer worktrees remain removable by their own lane's sweep. When more than one `.talos-lane-home` marker exists across a repo's worktrees, `sweep` skips entirely and exits 0 (safe no-op) unless `TALOS_SWEEP_ALL_LANES=1` is set. The per-issue `remove <N>` verb is always unaffected by the interlock.

**When do you need this?** Only when you have multiple lanes sharing one remote. A single-lane repo (the common case) has zero `.talos-lane-home` files and sweep behaves exactly as before.

> **Marking is all-or-nothing.** The interlock fires only when **more than one** `.talos-lane-home` marker exists across the repo's worktrees. A single marker provides no protection — if you mark one lane home and leave the others unmarked, the threshold is never reached and sweep runs unrestricted. If you mark any lane home, mark them all.

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

Talos is a distillation of [Daedalus](https://github.com/benmarte/daedalus) — a full-featured Hermes plugin with a 9-agent roster, kanban board, dashboard, and per-project config. If you need multi-project management, a dashboard UI, or a long-running daemon, use Daedalus. If you want a drop-in, zero-infrastructure pipeline driven from a Claude Code session — supporting GitHub (battle-tested), GitLab, Azure DevOps, and a local file mode — this is it.
