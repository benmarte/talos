# Talos

> *The bronze automaton that patrols your backlog.* Formerly "claude-pipeline".

An autonomous issue→PR pipeline driven by a **Claude Code orchestrator session** — no CI runner required, no separate daemon, no Hermes. You open a Claude Code session in your repo, run `/talos:pipeline`, and Claude drives the full backlog: validating issues, writing specs, implementing code (in isolated worktrees), verifying with your own test commands, running QA, then documentation and parallel review/security passes, and squash-merging when CI is green.

GitHub Issues (or a local markdown checklist in file mode) serve as the state machine. GitHub Projects optionally tracks board status. Everything else runs in your terminal.

> 📖 **New here? Start with the [User Guide](docs/user-guide.md)** — per-harness install and start lines (Claude Code, pi, Codex CLI, Gemini CLI, Antigravity, local models via llama.cpp, any other agent), prerequisites, environment variables, feature matrix, and troubleshooting. This README is the architecture and configuration reference.

---

> **Talos installs [agent-skills](https://github.com/addyosmani/agent-skills) for you.** The role profiles delegate their methodology to those skills rather than restating it, so it is a hard requirement — but never a manual step. The plugin declares it as a dependency (`+ 1 dependency: agent-skills`); `install.sh` fetches it into `.claude/skills/` (skip with `--no-agent-skills`). Upstream, MIT, unmodified.

---

## How it maps to Daedalus

[Daedalus](https://github.com/benmarte/daedalus) is the full-featured Hermes plugin this is distilled from. Talos takes the same ideas and runs them on pure Claude Code.

| Daedalus | Talos |
|----------|-----------------|
| 9 role SOULs + Hermes kanban | `.claude/agents/*.md` subagents + GitHub labels |
| Dispatcher cron | You run `/talos:pipeline` in a Claude Code session |
| `classify_blocked` routing | Orchestrator skill (`skills/pipeline/SKILL.md`) |
| Worktree isolation | `isolation: "worktree"` on the developer subagent |
| Validator gate | `pipeline:ready` → validator must emit CONFIRMED |
| QA-gates-review | `qa:pass` required before reviewer/security/docs |
| Auto-merge | Orchestrator merges when CI + all stage labels are green |
| Dashboard / per-project config | `talos.pipeline.json` per repo (JSON only, #526; exactly two canonical files) |

---

## Pipeline stages

```
issue: pipeline:ready
  └─ validator ──→ pipeline:confirmed
       ├─ planner (optional) ──→ sub-issues created (epic) OR pass-through (non-epic)
       └─ pm (skipped when body already has acceptance criteria, or spec:ready) ──→ pipeline:dev
            └─ developer (worktree) ──→ PR: pipeline:review
                 ├─ qa ─────────────→ qa:pass
                 ├─ reviewer ────────→ review:approved
                 ├─ security ────────→ security:approved
                 ├─ adversarial (optional, roles.adversarial, after security) ─→ adversarial:approved
                 └─ docs (auto-stamped when the diff already covers docs, else filtered context) ─→ docs:done
                      └─ all labels green + CI green → MERGE → close issue
```

Any stage can set `pipeline:blocked` with a comment. Stages only add the label; the orchestrator removes it automatically when re-dispatching a developer fix round after `record-attempt` exits 0 (SKILL.md Step 3, "Fix-round gate"). Otherwise, a human resolves the block and removes `pipeline:blocked` from both the PR and its issue. Removing it from only one leaves the work stuck: the issue label keeps it out of the queue (`issues.skip_labels`) and the PR label blocks the merge. Each run's Step 1 reports blocked issues and blocked PRs together in one `backlog` notification (#312).

**Reading a `pipeline:blocked` comment (#272):** every stage prompt requires that a stop/block/ask outcome name the file and quote the line that triggered it, and say whether that line is an explicit requirement (a spec acceptance criterion, a config threshold, a script's hard failure) or the agent's own interpretation. The `blocked.md` comment template surfaces this as a `Blocked by: <file>:<quoted line> (explicit|interpreted)` line, always the last line before the resume instructions — read that line first: `explicit` means the stage hit a hard rule and a human must resolve the underlying condition (fix the code, raise a limit, correct the spec) before re-queuing; `interpreted` means the stage's own judgment call and a human may simply disagree and override it, then re-queue without any other change.

**Where a role's instructions live (#179):** `agents/<role>.md` is the single
home for a role's methodology — its workflow steps, verdict procedures, and
the exact `pipeline-vcs.sh` commands it runs. `skills/pipeline/SKILL.md`'s
per-stage blocks in Step 3 stay task prompts: per-issue values (issue/PR
numbers, branch, comment header, verify commands) plus a pointer back to the
profile, not a restatement of the procedure. On the adapter path
(`subagents: false`) `pipeline-agent.sh` concatenates the profile with the
task prompt before running it; on the native path (`subagents: true`) Claude
Code loads the profile as the subagent's system prompt and the orchestrator
supplies the task prompt as its message — either way the role only has to be
taught once.

**Stopping condition convention (#270):** every `agents/<role>.md` carries
exactly one `Done when: ...` line, placed right after the role's opening task
statement and before the "Skills" paragraph/procedure — a concrete, checkable
condition for when that stage is finished, so the agent stops instead of
deciding for itself when to keep testing, re-reading, or polishing. The
matching dispatch prompt for that stage, `templates/prompts/<role>.md` (rendered
by `scripts/talos.sh prompt`, #468), carries the identical line. If you edit a
role's prompt, keep both copies in sync.

**Criteria first, red-first tests (#421):** the PM numbers each acceptance
criterion `AC<n>` and marks it `(test)` or `(prose: <reason>)`, and names the
test files on a `Tests:` line. The developer's first commit is the failing
tests, one per `(test)` criterion, named by its id, with the red run (command,
exit code, failing ids) in the commit body; it then implements until they pass.
QA reruns those files, proves they were red at the first branch commit, and
reports one line per id. `scripts/pipeline-criteria.sh` does the mapping from
the runner's output to ids. See the [user guide](docs/user-guide.md#criteria-first-red-first-tests-421).

---

## VCS providers

All VCS operations are delegated to `scripts/pipeline-vcs.sh`, which wraps each provider's CLI into a uniform verb interface. You never call `gh`, `glab`, or `az` directly from skill prompts.

| Provider | `vcs.provider` | CLI required | Status | Notes |
|----------|---------------|--------------|--------|-------|
| GitHub | `github` | `gh` | **Battle-tested** | Full support. Requires `gh auth login`. `list-issues`/`list-prs` paginate fully via `gh api --paginate` — no cap. |
| GitHub (token-only) | `github-api` | none | **Supported** | The `github` provider's one REST client, pinned to the `curl` transport (`GITHUB_TOKEN`; `github` itself uses `gh api` when `gh` is logged in and falls back to the token otherwise), so every verb behaves the same. No `gh` CLI needed — ideal for CI/containers. Set `GITHUB_TOKEN` or `GH_TOKEN`. Projects v2 board updates also use the token. `list-issues`/`list-prs` paginate fully via Link-header pagination — same no-cap behavior as `github`, so backlogs over 100 items are never silently truncated on either GitHub provider (#171). |
| GitLab | `gitlab` | `glab` | **Best-effort** | Implemented; `glab` version quirks may surface. Requires `glab auth login`. Since #303 the forbidden-files merge gate (`check-pr-files`) and the epic sweep (`check-epic-acceptance`) fail closed when the fetch fails. `check-closing-keyword` keeps the github semantics: on a fetch failure it fails open and prints a `talos:closing-keyword-unverified` marker. It also accepts GitLab's closing keywords and same-project `/-/issues/N` URLs. `pr-files` (MR diffs API, every page) and `rerun-ci` (retries the MR's head pipeline) exit 1 on any failure. `list-issues`/`list-prs` are capped at 100 items (`glab` has no "fetch every page" flag for these commands) — a result landing exactly on the cap prints a `WARNING result capped at 100` line to stderr rather than truncating silently. |
| Azure DevOps | `azure` | `az` + azure-devops extension | **Supported** | Full issue/board/PR flow — work items, Tags, board State, and PR labels/comments/diff (via `az rest` where `az` has no command). Merges are human-gated when `main` has branch policies. **Closing work items:** `create-pr` links the work item named by the `issue-<N>` branch (`--work-items <N> --transition-work-items true`), and that link is the primary close path — ADO ignores `Closes #N` / `Fixes #N` keywords on a squash merge, so a keyword alone never closes anything. `transitionWorkItems` closes the item when the PR completes into **any** target branch, including an integration `base_branch` that is not the repo default. `find-pr` (the Step 1 heal backstop) reads the work item's linked PRs, falling back to the branch convention; `close-issue` moves the item to `board.azure_states.done` and strips its `pipeline:*` tags (#298). Since #304 the merge gates work too: `pr-files` reads the last PR iteration's changes (every page), `check-pr-files` fails closed when that fetch fails, and `check-epic-acceptance` scans the work item's HTML `System.Description` (`- [ ]`, an unchecked `<input type="checkbox">`, `☐`) and exits 1 when the fetch fails. `check-closing-keyword` is link-based: it blocks when the PR is linked to the work item and another active PR is linked to it or sits on an `issue-<N>` branch; a fetch failure prints the `talos:closing-keyword-unverified` marker and exits 0. `rerun-ci` re-queues failed build-validation policies and exits 2 when the PR has none. `pr-checks-required` reads the PR's policy evaluations, including policies that do not apply to the PR (REST `includeNotApplicable=true`, #328), and matches `merge.required_checks` to them by display name, case-insensitively, with github's exit codes (0 passed, 1 failed, 2 pending or missing); a path-filtered policy that does not apply passes, an expired or stale approval is pending, and a fetch failure exits 1 (#318). Requires `az login` + `az extension add --name azure-devops`. `list-issues` is bounded only by ADO's own 20000-item ceiling on a flat WIQL query (`az boards query` has no `--top`/page flag and WIQL has no `TOP` clause — ADO rejects one with TF51006, #278); `list-prs` is capped at 1000 (`az repos pr list --top`, no further pagination). A result landing exactly on either cap prints a `WARNING result capped at <N>` line to stderr rather than truncating silently. |
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
# talos.pipeline.json: { "vcs": { "provider": "github-api" } }

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

Restart the session, then run `/talos:setup` in any repo to write `talos.pipeline.json` and bootstrap labels. The commands are `/talos:pipeline` and `/talos:setup`; the `talos:` prefix is the plugin's name. The plugin carries the skills, all eight role agents, the scripts and the templates; the repo carries nothing but its config.

agent-skills comes with it automatically (`+ 1 dependency: agent-skills`). If you already use Addy's marketplace you will see agent-skills registered twice; that is expected and harmless, see the [user guide](docs/user-guide.md) for why.

**Option B — global install with `install.sh`.** Installs once to `~/.talos/`; every repo and every harness on this machine picks it up.

```bash
git clone https://github.com/benmarte/talos
bash talos/install.sh --global          # ~/.talos/ always (scripts, agents, templates, skills); only when Claude is selected or detected: ~/.claude/agents, the talos plugin (/talos:*) and the legacy /pipeline aliases
bash talos/install.sh /path/to/your-repo  # writes config; no scripts copied into repo
# writes the Talos block into /path/to/your-repo/AGENTS.md for every harness (commit it);
# --no-agents-md skips it, --import-agents-md also adds an @AGENTS.md import to an existing CLAUDE.md / GEMINI.md
# --harness <list> picks the installer glue (no default): claude codex gemini antigravity pi cursor opencode generic;
#   the AGENTS.md block is the same for all
```

`--harness` selects installer glue (what is written where); `agents.runner` selects the CLI that runs stages. They are separate: `--harness codex` does not set `agents.runner`. `--harness` is an optional comma-separated list of lower-case names (`claude codex gemini antigravity pi cursor opencode generic`); any other `[a-z0-9-]+` name is treated as `generic` with a printed hint, and an empty item or a missing value exits 1. A tool Talos has no glue for needs no installer support: pass any `--harness` name, set `agents.runner: custom`, and give `agents.runner_cmd` (the prompt arrives on stdin).

The global install always writes `~/.talos/`. It writes `~/.claude/agents`, registers the plugin and writes the two alias skills in `~/.claude/skills` only when the Claude adapter runs. With `--harness`, that is exactly when the list contains `claude`. Without it, that is when Claude is detected: `CLAUDE_CONFIG_DIR` is set, `${CLAUDE_CONFIG_DIR:-~/.claude}` is a directory, or `claude` is on PATH. `--harness claude` forces the adapter; a list without `claude` skips it, and a skipped adapter neither refreshes nor deletes an existing `~/.claude` (`--harness claude,codex` does both). With `codex`, `pi`, `cursor` or `opencode` in the list, `--global` also writes pointer skills to `${TALOS_AGENTS_HOME:-~/.agents}/skills`. [Install and start, per harness](docs/user-guide.md#install-and-start-per-harness) has the full table with each harness's start line and what is verified.

**Command names (`/talos:<command>`).** Both Claude Code install paths give the same two commands: `/talos:pipeline` and `/talos:setup`. Claude Code namespaces only plugin skills (`plugin:skill`); a skill copied into `~/.claude/skills` is invoked by its directory name and cannot take a colon. So the Claude adapter of `install.sh --global` registers this checkout as the `talos` plugin: `claude plugin marketplace add <checkout>` (a local directory marketplace) and `claude plugin install talos@talos`, both guarded, so a failure prints a notice and never aborts the install. Three things to know:

- Claude Code copies the plugin into its own plugin cache when it installs it, so a `git pull` in the checkout reaches `/talos:*` only after you re-run `install.sh --global` (or update the plugin). The marketplace entry still points at the checkout: if you move or delete the clone, re-run `install.sh --global` from the new location and it repoints the marketplace.
- Installing the plugin also installs its `agent-skills` dependency from `github.com/addyosmani/agent-skills`, which needs network.
- If your Claude config already has a marketplace named `talos` from a non-directory source (for example you ran `/plugin marketplace add benmarte/talos`), the installer leaves it alone and says so; that source already provides the names. With no `claude` on PATH, or a Claude Code without `claude plugin`, it prints the two commands to run inside Claude Code and deletes nothing.

The old names `/pipeline`, `/pipeline-setup` and `/talos:pipeline-setup` were removed in #553 (the v0.20 promise). `install.sh --global` removes an older install's Talos-owned bare copies in `~/.claude/skills` (`pipeline`, `pipeline-setup`, the old `talos-resume`) once the plugin is registered; a skill there that is not Talos's is never overwritten or deleted. `/talos:setup` offers to rewrite old command names in your `CLAUDE.md` and `AGENTS.md`. A re-run from a second checkout repoints the `talos` marketplace to that checkout and prints the old and new paths; `--keep-marketplace` leaves an existing registration untouched.

`install.sh <repo>` writes one marker-fenced Talos block (between a begin and an end HTML comment, shown by `bash scripts/pipeline-instructions.sh print`) into the repo's `AGENTS.md` for every harness, so a non-Claude agent finds the playbook paths under `~/.talos/skills/`. A missing file is created, a file without the markers gets the block appended, and a stale block is repaired in place (the output says `added the Talos block to`, `updated the Talos block in`, or `up to date`). A malformed fence or a symlinked `AGENTS.md` is left byte-identical with a notice. Text outside the markers is never touched. Commit the file: an untracked `AGENTS.md` makes `pipeline-vcs.sh assert-sync` abort on a dirty tree, and it runs at Step 0 under every isolation mode.

- `--no-agents-md` writes no `AGENTS.md`.
- `--import-agents-md` appends a fenced `@AGENTS.md` import to an existing `<repo>/CLAUDE.md` and `<repo>/GEMINI.md`. It never creates either file and never writes the block into them. Without the flag, when a Claude instructions file exists that does not import `AGENTS.md`, the install prints a notice with the line to add (`@AGENTS.md` for a root `CLAUDE.md`, `@../AGENTS.md` for `.claude/CLAUDE.md`), because Claude Code 2.1.277+ reads `AGENTS.md` only when no `CLAUDE.md` exists.

To update all repos at once:

```bash
git -C path/to/talos pull && bash path/to/talos/install.sh --global
```

**Option C — vendored (legacy).** Existing `.claude/talos/` installs keep working with zero user action; the probe order includes them at position 4. Re-install to upgrade an existing vendored copy:

```bash
bash path/to/talos/install.sh --global   # recommended: upgrade globally
# or keep vendored: bash path/to/talos/install.sh --global followed by
# your existing .claude/talos/ install continues to work as-is
```

Talos resolves its scripts in this order -- `$TALOS_HOME/scripts` (explicit override, skipped when unset), `~/.talos/scripts` (global install), `$CLAUDE_PLUGIN_ROOT/scripts` (plugin), `.claude/talos/scripts` (legacy vendored), `scripts` (source repo). The global install wins when present; the plugin falls back to its bundled copy only when no global install exists.

> **Security note:** `TALOS_HOME` sits at the top of the probe order and is read from the
> environment. Treat it like `PATH` -- point it only at a directory you trust, because Talos
> executes scripts from the location it resolves to. This is a documented property of the
> design: the skill already executes from `$CLAUDE_PLUGIN_ROOT`, `.claude/talos/`, and
> `scripts/`; `$TALOS_HOME` is a new, environment-controlled entry at the highest priority.

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
cp path/to/talos/talos.pipeline.json.example talos.pipeline.json
# Edit talos.pipeline.json for your project — config is JSON only (#526).
# Exactly two canonical files: talos.pipeline.json (repo) and
# ~/.talos/talos.pipeline.json (user-level). Any other talos.pipeline.* file
# in a layer directory fails the load closed (reason=config-shadowed /
# reason=config-legacy-file); convert a legacy YAML to JSON by hand.
```

Minimum viable config (board and notifications optional):

```json
{ "base_branch": "dev", "verify": ["python -m pytest tests/ -x -q"] }
```

### 3. Bootstrap labels (GitHub / GitLab / Azure only)

```bash
bash ~/.talos/scripts/bootstrap-labels.sh          # global install
# or: bash .claude/talos/scripts/bootstrap-labels.sh  # vendored legacy
```

This creates the `pipeline:*`, `spec:ready`, `qa:pass`, `review:approved`, `security:approved`, and `docs:done` labels in your repo (idempotent). Skip this step for file mode — checkboxes replace labels.

### 4. Optional: GitHub Project board

Create a GitHub Project with a single-select **Status** field. Set `board.enabled: true` and fill in `board.project_number` and `board.owner` in your config. (GitHub only; skipped in file mode.)

The pipeline validates and sets four status columns: **In progress**, **In review**, **Done**, and **Blocked**. A fifth column **Ready** is conventional for backlog visibility but is not set by the pipeline. If your board uses different column names, configure `board.status_map` to remap them (see the [Config reference](docs/user-guide.md#config-reference)). When a required option is missing, the issue is still added to the board in the default column and `talos:board-unverified project=<N>` is emitted on stdout — the pipeline continues running (board failures are warnings, not fatal errors).

Run `bash scripts/bootstrap-board.sh` to provision the missing Status options for you (idempotent — safe to re-run; a no-op once every option exists). GitHub's underlying `updateProjectV2Field` mutation replaces the Status field's entire option list in one call, so the script always resends every existing option's name/color/description exactly as fetched before appending the missing ones, then re-fetches and verifies every pre-existing option kept its id — failing loudly if one didn't, since a silently reassigned id would blank every card's status. Azure/GitLab providers use the same script to *validate* (never create) the states/labels their boards rely on: Azure reports each `board.azure_states.*` value as present or missing against the work item type's allowed states (exits non-zero on a miss, naming the config key); GitLab boards are label-driven, so it just confirms `pipeline:blocked` (etc.) exist. `board.enabled: false` or `vcs.provider: file` print "board disabled" and exit 0.

### 5. Optional: notifications

Set one or more of these in your environment (exported variables always win), in a `.env` file at the repo root (`<repo>/.env`), or, once for every repo, in `~/.talos/.env`:

```
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
TEAMS_WEBHOOK_URL=https://...
```

`~/.talos/.env` (`$TALOS_HOME/.env`) is where secrets belong. Talos refuses it unless it is a regular file you own with mode 0600 (`chmod 600 ~/.talos/.env`) and outside every git work tree, and one stderr line names the fix; notifications that came from it stop until you apply it. A repo `.env` is parsed, never sourced, and only the notification variables above (plus `BUZZ_*`, `PIPELINE_SLACK_CHANNEL`, `PIPELINE_DISCORD_CHANNEL`, `PIPELINE_BUZZ_CHANNEL`, `PIPELINE_BUZZ_RELAY`) are read from it: the checkout can be a PR branch, so any other key (`BASH_ENV`, `PATH`, `LD_PRELOAD`, …) is ignored with one stderr line naming it, and a deny list wins over the allow list. `~/.hermes/.env` is **deprecated**: it is still read as the last fallback, with one deprecation line, and `TALOS_HERMES_ENV=<path>` moves it (empty disables it); move your Talos variables to `~/.talos/.env`.

A config file never holds a secret. To read a webhook or token from a differently named variable, set the key to a reference such as `notifications.slack.webhook: env:ACME_SLACK_HOOK`; a literal value, or a secret-shaped one, is refused. See [Secrets](docs/user-guide.md#secrets) in the user guide.

Alternatively, set `notifications.slack_channel` / `notifications.discord_channel` in your config and put `SLACK_BOT_TOKEN` / `DISCORD_BOT_TOKEN` in the environment or `~/.talos/.env` (bot-token mode threads per issue).

**Teams has no bot-token path.** `TEAMS_WEBHOOK_URL` is Talos's only way to deliver to Teams — there is no bot-token/channel-ID alternative like Slack and Discord have — and `pipeline-notify.sh` reads it from the environment, the repo `.env`, `~/.talos/.env` or the deprecated `~/.hermes/.env`, like every other platform's credential. Because delivery is always webhook-only, Teams also never threads (see [Per-issue notification threading](#per-issue-notification-threading)). Microsoft retired the legacy Office 365 "Incoming Webhook" connector in May 2026; provision a Power Automate **Workflows** webhook instead ("Post to a channel when a webhook request is received") and put its URL in `TEAMS_WEBHOOK_URL`.

For [Buzz](https://github.com/block/buzz) (self-hosted Nostr/NIP-29 workspace — no webhooks), install the [`nak`](https://github.com/fiatjaf/nak) CLI (`brew install nak`), set `notifications.buzz_channel` to the channel UUID, and provide the relay + bot key (env, repo `.env`, or `~/.talos/.env`):

```
BUZZ_RELAY_URL=ws://your-relay:3000
BUZZ_BOT_PRIVATE_KEY=<bot nsec or hex secret>
```

Talos publishes a signed `kind:9` event tagged with the channel; on a closed or allowlisted relay, add the bot's pubkey as a member/allowlist entry first (see buzz's `NOSTR.md`). The bot key is handed to `nak` through the `NOSTR_SECRET_KEY` environment variable it documents for `--sec`, so it never appears on the command line where `ps` would expose it. Each publish is bounded by `notifications.buzz_timeout_s` (default `15` seconds): a relay that never answers logs one line to stderr and is skipped, exactly like any other failed publish.

For anything else — a local desktop notifier, a webhook relay, a log shipper — set `notifications.cmd` to a shell command. It runs (via `sh -c`) after the four sinks above, for every event that passes `notifications.events`, with a JSON object on stdin:

```json
{"event": "pr-opened", "ref": "#42", "message": "🔀 [talos] pr-opened #42 — ...", "thread_key": "42", "fields": [{"label": "PR", "text": "#9", "url": "https://github.com/acme/widget/pull/9"}], "repo": "acme/widget", "issue": 42}
```

`message` is the same rendered text the other sinks build their message from; `fields` is the same platform-neutral metadata table (PR/Issue/Stage/Repo) they render natively. Bounded by `notifications.cmd_timeout_s` (default `10` seconds); a missing command, non-zero exit, or timeout logs one line to stderr and never blocks the pipeline or any other sink.

### 6. Queue work

**VCS mode** (GitHub / GitLab / Azure): add the `pipeline:ready` label to any issue.

**File mode**: add a `- [ ] Task` item to `plan.md`.

**Chat mode**: just describe the work conversationally after running `/talos:pipeline` and the orchestrator will create `plan.md` for you.

Then open a Claude Code session in your repo and run:

```
/talos:pipeline
```

**Deterministic orchestrator**: LLM-driven orchestration (`/talos:pipeline`, Claude) is the default;
`bash scripts/talos.sh run` is the deterministic orchestrator for local and weak-model profiles. It loops
`talos.sh next` and dispatches each stage through `pipeline-agent.sh` itself — code routes, gates and does
the bookkeeping, no orchestrator session; an LLM still does every stage, through the runner
`agents.runner` names (`agents.fallback` failover applies). `--issue <N>` scopes
it to one issue; `--max-iterations <n>` (default 20) caps the dispatch passes; every stop/ask-owner wait
exits clean with its `stop` line. Resume after a crash re-runs `run`: the lease ledger and the #419
handoff files carry the state.

---

## Config reference

Every config key, its type and its default live in one table, `scripts/pipeline-defaults.sh`, and nothing else states a default: the key reference (about 120 rows, one per key) is the [Config reference](docs/user-guide.md#config-reference) section of the user guide, and `tests/test-docs-defaults-vs-table.sh` fails when it or an example config disagrees with the table.

- **See what a repo resolves:** `bash scripts/pipeline-config.sh --show` prints every key with its value and the layer that decided it (`default`, `global`, `repo` or `env`). A secret is never printed.
- **Two config files, four layers**, each overriding the one below key by key (#526): the table defaults, the user-level file `~/.talos/talos.pipeline.json` (every key except the repo-only ones), your repo's `talos.pipeline.json`, then the key's environment variable. A stray `talos.pipeline.yml`/`.yaml` in a layer directory fails every config read closed (`reason=config-shadowed` / `reason=config-legacy-file`).
- **Secrets are never config values.** A webhook or token key holds an `env:NAME` reference; the value comes from the environment, the repo `.env` or `~/.talos/.env` (mode 0600, yours, outside every repo). `~/.hermes/.env` is deprecated. A secret-shaped value in a config file is dropped on load.
- **Example:** `talos.pipeline.json.example` (the `_note` is the teaching text; it is tested against the table, and a stray yml example would fail the load closed).

### Hooks

For a worked example wiring one shell script to both `hooks.pre_dispatch` and `hooks.post_stage`, see [One script, both hooks](docs/user-guide.md#one-script-both-hooks) in the user guide.

`hooks.pre_dispatch` lets an external tool — a project-memory store, a cost budget, a style guide, anything — contribute context to a stage's prompt without Talos depending on it. Disabled by default.

The configured command runs once per stage, before that stage's prompt is assembled, with this JSON on stdin (fields the caller doesn't know yet — e.g. `pr`/`files_hint` before a PR exists — are `null`/`[]` rather than omitted):

```json
{
  "role": "developer",
  "issue": 42,
  "pr": 57,
  "repo": "owner/name",
  "base_branch": "main",
  "worktree_path": "/abs/path",
  "files_hint": ["a.sh", "b.md"]
}
```

`TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, and `TALOS_WORKTREE_PATH` are also exported into the command's environment — the same names/values `pipeline-agent.sh` already exports to `agents.runner_cmd`.

Contract: a non-zero exit, a timeout (`hooks.timeout_s`, default 30s), or empty stdout is a silent no-op — the prompt is left unmodified — with exactly one line on stderr explaining why. `hooks.pre_dispatch` never blocks dispatch. Non-empty stdout is prepended to the prompt exactly as:

```
## Context
<hook stdout>
---
<the rest of the prompt, unchanged>
```

Implemented in `scripts/pipeline-hooks.sh`; wired into the adapter path (`scripts/pipeline-agent.sh`) and the native orchestrator path (`skills/pipeline/refs/hooks.md`, named by `talos.sh env` as `ref=hooks`).

`hooks.post_stage` is the outcome-side counterpart: it runs after every verdict, approval, block, and merge is known — the moment a subagent posts findings, the moment a lifecycle event (`pr-opened`/`merged`/`blocked`/`issue-closed`) fires. Fire-and-forget with the same never-block contract as `hooks.pre_dispatch`, disabled by default.

The configured command receives this JSON on stdin (fields the caller didn't supply, e.g. `sha`/`verdict`/`attempt` before they're known, are `null` rather than omitted):

```json
{
  "event": "qa",
  "role": "qa",
  "issue": 42,
  "pr": 57,
  "repo": "owner/name",
  "sha": "<40hex or null>",
  "verdict": "PASS",
  "summary": "3 criteria verified",
  "details": "...",
  "attempt": { "stage": "qa", "count": 1, "total": 3 },
  "model": "claude-sonnet-5",
  "runner": "claude",
  "duration_s": 312,
  "ts": "2026-09-07T14:00:00Z"
}
```

`model` comes from `agents.roles.<role>.model`, falling back to `agents.model`; `runner` from `agents.runner`. `duration_s` is `null` unless the caller supplies it — Talos does not time stages today. `ts` is UTC, ISO-8601.

Contract: a non-zero exit or a timeout (`hooks.timeout_s`) is a silent no-op with exactly one line on stderr; `hooks.post_stage` never blocks the pipeline and has no output to prepend anywhere — it is purely a side channel. `TALOS_ROLE` and `TALOS_ISSUE_NUMBER` are also exported into the command's environment.

Implemented in `scripts/pipeline-hooks.sh` (`post_stage`, sharing its watchdog/timeout machinery with `pre_dispatch`); wired into the adapter path (`scripts/pipeline-agent.sh`, once per stage run — event `stage_complete`, verdict from the runner's exit code) and the native orchestrator path (`skills/pipeline/SKILL.md`, Stage protocol, Stage return: `scripts/talos.sh done`, #469).

### Events log

Every `hooks.post_stage` payload (see the JSON schema above) is also appended, as one JSON line, to a local `events.jsonl` audit log in Talos's run-state directory, `<git common dir>/talos/` — independently of whether `hooks.post_stage` itself is configured. This gives every run a local, durable record of what happened without depending on an external sink.

Enabled by default (`events.enabled: true`); set it to `false` to disable. The log path (`events.path`, default `talos/events.jsonl`) is resolved relative to the **git common dir** via `git rev-parse --git-common-dir` — so a developer/QA/reviewer stage running from inside a per-issue worktree still appends to the one log file shared by every worktree of the repo. The run state lives **outside every git tree**: it is never staged or pushed, and an agent's `git add -A` cannot commit it (#517). The deliberately in-tree `.talos/` files (the per-worktree `.talos/env`, `providers.json`) are auto-ignored via `.git/info/exclude` before their first write — Talos never edits a tracked `.gitignore`.

Appends are a single `printf '%s\n' >>` (one `O_APPEND` write syscall) — a JSON event line is well under the POSIX `PIPE_BUF` atomic-write threshold, so concurrent stages appending at once (e.g. under `issues.max_parallel`) never interleave partial lines. No file lock is used or needed. A failure to write (unresolvable path, permissions, disk full) is a stderr note only — it never affects the pipeline's exit code.

Read the log with `scripts/pipeline-events.sh`:

```
bash scripts/pipeline-events.sh path
bash scripts/pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
bash scripts/pipeline-events.sh tail [--issue N]
```

`list` (and `tail`, shorthand for `list --last 20`) print one line per matching event, oldest first: by default a compact tab-separated table (`ts`, `event`, `role`, `issue`, `pr`, `verdict`, `summary` truncated to 80 chars); `--json` prints one JSON object per line instead. A malformed line in the log is skipped, with the count of skipped lines reported once on stderr — never on stdout, and never fatal.

#### Cost accounting

`post_stage` also accepts `--tokens N` and `--tool-uses N` (validated non-negative integers; an invalid or omitted value is `null` in the payload, with one stderr note for an invalid value), stored alongside `duration_s`. Summarize with `bash scripts/pipeline-events.sh cost [--issue N] [--json]`: a per-issue, per-role table (`issue`, `role`, `events`, `tokens`, `tool_uses`, `duration_s`, `unrecorded`, `restamp`) with a `TOTAL` row — `unrecorded` counts events with a null `tokens` field (e.g. adapter-path runs, which record duration only) so an untracked group is visible rather than reading as a real zero; `restamp` counts events with verdict `RESTAMP_PASS`/`RESTAMP_FAIL` (#258) — a cheap delta re-review of a PR the same role already approved — separately from that group's full-stage events/tokens. `post_stage --ci-runs N` (#332, a validated non-negative integer, normally `pipeline-vcs.sh pr-ci-runs <pr>` recorded on the `merged` event) adds a `ci_runs` key to that event only when supplied; when at least one matched event carries it, `cost` gains a trailing `ci_runs` column (and a trailing `ci_runs` field in `--json` rows and total), and with no such event its output is unchanged.

Spend views over the same log (#334): `cost --issue N [--pr M] --line` is the one-line spend summary the playbook prints after each stage; `--markdown` is the body of the PR spend comment (posted with `pipeline-vcs.sh upsert-pr-comment`); `cost --summary --issue A [--issue B ...]` is the end-of-run report; `--pr M` scopes the report to one PR. `--line`, `--markdown` and `--summary` are mutually exclusive (exit 2 if combined), and they leave the `orchestrator` rows out, unlike the default table. `pipeline-budget.sh check` is the budget guard and `talos-status.sh --line` is the status-line renderer. The budget guard is off by default. Details, exit codes and caveats: [Seeing token spend](docs/user-guide.md#seeing-token-spend-334).

### Board status options: required columns and `talos:board-unverified`

The pipeline sets four GitHub Projects Status column values during a run: `In progress`, `In review`, `Done`, and `Blocked`. On the first `pipeline-status.sh` call of a run, the script fetches the board's Status field options and verifies all four are present (after `board.status_map` substitution — so a mapped name is what gets checked, not the default pipeline name).

**What happens when a required option is missing:** the issue is still added to the board in the project's default column (`item-add` runs before the option check). A `talos:board-unverified project=<N>` marker is emitted on stdout, a warning naming the missing option(s) is written to stderr, and the script exits 0. Board failures are warnings by design (Rule 11) — a missing column degrades visibility, not progress. The pipeline continues running normally.

| Marker | When emitted | What to do |
|--------|-------------|-----------|
| `talos:board-unverified project=N` | A required Status option (`In progress`, `In review`, `Done`, or `Blocked`, after `status_map` substitution) is absent from the board | Add the missing column to the project, or map the pipeline name to an existing column via `board.status_map` (see config table above) |

**`board.status_map` worked example.** If your board uses "Needs attention" instead of "Blocked":

```json
{
  "board": {
    "enabled": true,
    "project_number": 4,
    "owner": "myorg",
    "status_map": { "Blocked": "Needs attention" }
  }
}
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

### Upgrade note: `github-api` list endpoints must return JSON arrays (#319, #329)

Every `github-api` list endpoint (paginated through `_ga_fetch_all_pages`) must return a JSON array on each page. A non-array page — for example a test stub returning `{}` — now fails the verb outright instead of being read as an empty list. Update any test stub that serves a `github-api` list endpoint to return `[]`, not `{}`, when it has nothing to return.

### Upgrade note: `merge.forbidden_files` union semantics (v0.14+)

**If you have `merge.forbidden_files` set in your `talos.pipeline.json` before upgrading to v0.14+, your configuration now means something different.**

Previously, setting `merge.forbidden_files` replaced the built-in defaults entirely — only your configured patterns were active. From v0.14 onward, your configured patterns are **added to** the built-in defaults (union semantics). The built-in patterns (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`, plus the ten credential-file patterns added in #436: `.npmrc`, `.pypirc`, `.git-credentials`, `credentials.json`, `*-credentials.json`, `*_credentials.json`, `.aws/credentials`, `*/.aws/credentials`, `.docker/config.json`, `*/.docker/config.json`) are always active alongside your patterns.

**What to do:**

- **If you intended to add extra patterns on top of the defaults** (the common case): no action required. Your config now works as you most likely intended.
- **If you intentionally narrowed the deny list** (removed some built-in patterns to allow those file types): add `merge.forbidden_files_replace: true` to restore the old replacement behaviour. Review the security warning in the `merge.forbidden_files_replace` table row above before doing so — replacement suppresses all built-in secret-protection patterns and should be treated as a deliberate security trade-off.

### Upgrade note: wider forbidden-files defaults and case-insensitive matching (#436)

The defaults grew from 20 to 30 patterns (the credential files listed in the `merge.forbidden_files` row), and every consumer now matches case-insensitively: the `check-pr-files` deny list and `merge.forbidden_files_allow`, the allow-list validator, the `pipeline-mergebase.sh` cross-checks and `pipeline-worktree.sh checkpoint`.

**What to do:** if `merge.forbidden_files_allow` holds a broad entry such as `*.json`, it now fails validation and `check-pr-files` fails closed, because the entry would exempt `credentials.json`. Replace it with the specific filenames you need (for example `["tsconfig.json", "package.json"]`). A narrow entry that does not match a default is unaffected. Existing `merge.forbidden_files` additions keep working.

The same rule now applies to `merge.union_paths`: a broad entry such as `*.json` is rejected at validation time, because it would let `pipeline-mergebase.sh` union-merge `credentials.json` and the other default-denied files. Name the specific files you need (the default is `["CHANGELOG.md"]`).

### Status line and resume

**Status line (#550).** `install.sh --global` wires one line into Claude Code's status bar (`statusLine` in `~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json`; never over a status line you already have, it prints how to chain instead):

```
talos #7 qa ●●●◐○○ 3.41M
```

The issue, the running stage, one dot per stage (validator, pm, developer, review, qa, merge; ● done, ◐ running, ○ pending; a role switched off in the config has no dot) and the issue's token total, which rises while a stage runs. It is `talos-status.sh --line`: offline, no model tokens, nothing printed when no issue is active. Any other harness calls the same command from its own status hook. Details: [Seeing token spend](docs/user-guide.md#seeing-token-spend-334).

**Resume.** There is nothing to resume from and nothing to read first. After a cleared session, a token limit or a switch to another LLM, start the pipeline again (`/talos:pipeline`, or `bash scripts/talos.sh run`): Step 0 prints three lines from `talos.sh state --summary` (in flight, waiting, next action) and the run goes on from the labels, PRs and events on the remote. A developer re-dispatched on an issue whose worktree has a checkpoint (`pipeline-worktree.sh checkpoint`, written on a provider failover) is told to read it and continue instead of starting over. The tracked status file, its `status.*` keys, the `docs/status.d` fragments and the `/talos:resume` skill are gone (#550); a leftover `TALOS_STATUS.md` or `status.*` key in your config is simply unused (the config loader warns once about the unknown key) and can be deleted.

### Upgrade notes (v0.19+)

Config and secrets (epic #437: #439-#446). The full rules are in the user guide's [Config reference](docs/user-guide.md#config-reference); what can break an existing setup is listed here. Several of these stop notifications or ignore a config file until you fix a file mode, so check them after upgrading.

**(a) `~/.talos/.env` and `~/.hermes/.env` must be mode 0600 and owned by you (#443).** A `.env` with any other mode or owner is refused with one stderr line that carries the fix (`chmod 600 <file>`), and notifications that came from it stop until you apply it. A symbolic link is refused too.

**(b) A `.env` inside any git work tree is refused (#443).** A dotfiles repository at `$HOME` puts `~/.hermes/.env` and `~/.talos/.env` inside a work tree. Move the file outside every repository, set `TALOS_HOME` to a directory outside it, or export the variables in your shell.

**(c) A group- or world-writable global `talos.pipeline.json` is read as absent (#443).** The file drives `hooks.*` and `notifications.cmd`, which run commands, so a copy anyone else can write is not trusted; your global settings stop applying and one stderr line names the file. Fix with `chmod go-w ~/.talos/talos.pipeline.json`.

**(d) `TEAMS_WEBHOOK_URL` is now read from the `.env` files (#443).** It used to come from the environment and the repo `.env` only; it is now looked up like every other credential (environment, repo `.env`, `~/.talos/.env`, deprecated `~/.hermes/.env`). A Teams webhook you had in `~/.hermes/.env` that never did anything now takes effect.

**(e) `~/.hermes/.env` is deprecated in favour of `~/.talos/.env` (#443).** It is still the last fallback, with the same mode, owner and work-tree checks and one deprecation line per run. Copy the Talos variables (only those) to `~/.talos/.env`; `TALOS_HERMES_ENV=<path>` moves the fallback and an empty value switches it off.

**(f) Secrets are `env:NAME` references, and secret-shaped values are rejected in any config layer (#443, #444).** The six keys `notifications.{slack,discord,teams}.webhook`, `notifications.{slack,discord}.bot_token` and `notifications.buzz.bot_key` accept only `env:NAME`; a literal is refused. A Slack, Discord or Teams webhook, a Slack or GitHub or GitLab token, an AWS key, a private key or a Nostr `nsec1` key in the repo or the global file is dropped on load, with a stderr line that names the key (never the value). If one was ever committed, rotate it.

**(g) Repo-only keys are dropped from the global file (#441).** The global file now accepts every key, except the ones that describe one repository (`base_branch`, `vcs.*`, `board.*`, `verify`, `merge.required_checks` and the other `merge.*` lists, `issues.label_filter`, `issues.skip_labels`, `markers.*` and a few more; the table's scope column is the list). One found there is ignored with a stderr note naming the key; put it in the repo's file.

**(h) The `.env` deny list wins over the allow list (#444).** `BASH_ENV`, `PATH`, `LD_PRELOAD`, `GIT_*`, `*_PROXY`, `GH_*`, `GITHUB_*`, `AWS_*` and similar names are never read from a `.env`, and an `env:NAME` reference to one is refused. `GITHUB_TOKEN` and `GH_TOKEN` have to be exported in your shell.

**(i) The environment is a fourth config layer, and `pipeline-config.sh --show` prints the result (#441, #442).** Lowest to highest: defaults, the global file, the repo file, the key's environment variable (`PIPELINE_SLACK_CHANNEL`, `PIPELINE_PROJECT_NUMBER`, ...). A list in a higher layer replaces the lower list whole. `--show` replaces `--dump-layers`, which is removed after one release.

**(j) A GitHub Actions or App token authenticates as a `[bot]` login that is never trusted implicitly (#453).** A run under such a token needs `markers.trusted_authors`; see the CI-bot caveat under *Marker placement and trusted-author allow-list* in the [Scripts reference](#scripts-reference) and [Approval-marker author verification](docs/user-guide.md#approval-marker-author-verification-markersverify_authors), which are not repeated here.

Also merged with v0.19 and visible to users:

**(k) `agents.capture_usage` defaults to `true` (#420).** On the adapter path (`pipeline-agent.sh`), `claude` stages now run with `--output-format json`, so token usage reaches the stage event; the printed message text is unchanged. Set `agents.capture_usage: false` to restore plain text mode; native subagents are unaffected. See [Token usage on adapter runs](#token-usage-on-adapter-runs-420).

**(l) Commands are `/talos:pipeline` and `/talos:setup` (#335).** The legacy `/pipeline` and `/pipeline-setup` aliases were removed in #553. `install.sh --global` registers a local `talos` plugin; pass `--keep-marketplace` to leave an existing registration alone. See [1. Install](#1-install).

**(m) A YAML config file fails the load closed (#526).** Config is JSON only: a `talos.pipeline.yml`/`.yaml` beside the canonical json stops every config read with `reason=config-shadowed` (winner, the strays, the `rm`/merge instruction), and one without a json stops with `reason=config-legacy-file` plus a hint to convert it by hand (the old `--convert` verb was removed in #553; it is in git history). Ambiguity never runs — the 2026-10-06 incident (a stray committed yml silently shadowed the json and cost three full CI runs) is why this is fail-closed, not a warn.

### Upgrade notes (v0.18+)

**(a) Issues are now assigned to the operator by default (`issues.assignee`, #299, #305, #321).** `create-issue` and the "In progress" claim assign the issue or work item to `self` (the authenticated `gh`/`glab`/`az` identity) on github, github-api, gitlab and azure. An existing assignee is never overwritten, and a rejected identity is a warning, never a stage failure. To keep the pre-0.18 behavior set `issues.assignee: none`, or the quoted `issues.assignee: ""`. A bare `assignee:` is YAML null and still means `self`. The value is trimmed of surrounding whitespace.

**(b) GitLab and Azure merge gates now enforce instead of passing (#303, #304, #318, #328).** `check-pr-files`, `check-epic-acceptance`, `check-closing-keyword`, `pr-files` and `rerun-ci` used to print "not implemented" and exit 0 on gitlab/azure. They now do real work. The forbidden-files gate and the epic sweep fail closed when a fetch fails, so a GitLab or Azure repo can now see merges or epic closes blocked that silently passed before. On azure, `pr-checks-required` is implemented: every `merge.required_checks` name must match an ADO policy display name (case-insensitive). A policy that does not apply to the PR counts as passed, and an approval for an older commit counts as pending.

**(c) `siblings-capped` blocks the merge (#319).** When `check-closing-keyword` cannot see every open sibling PR, it prints `talos:closing-keyword-unverified … reason=siblings-capped`. Step 4 then adds `pipeline:blocked` for a human instead of merging. Only very large repos hit the cap.

**(d) `github-api` list endpoints must return JSON arrays (#319, #329).** A non-array page (e.g. a test stub returning `{}`) now fails the paginated verb instead of reading as empty. Update any stub that serves a `github-api` list endpoint. Pagination links that point off the API host are refused before the token is sent (#320).

**(e) Comments with unfilled template placeholders or over 65536 characters are refused (#306).** `comment-issue` and `comment-pr` exit 1 and post nothing when a body still contains a placeholder such as `${HEADER}` (outside code fences). Custom templates in `comments.templates_dir` are checked too. Render with all variables set.

**(f) Only the orchestrator clears `pipeline:blocked` (#310, #312, #322).** Stage agents no longer remove the label when they approve. Blocked PRs are reported in Step 1 and are not resumed or adopted. To resume blocked work, remove the label from **both** the PR and its issue.

**(g) The Step 1 heal closes only issues a merged PR really closes (#298).** `find-pr <N> merged` matches only the `issue-<N>` branch or a closing keyword aimed at this repository, never a bare `#N` mention, so an epic or dependency is no longer closed by mistake. On azure, `create-pr` links the work item with `--transition-work-items true`, so ADO closes it when the PR completes.

**(h) New label `pipeline:needs-owner` (#345, part of #333).** Existing repos re-run `bash scripts/bootstrap-labels.sh` (idempotent) to create it; `mark-needs-owner` and `list-needs-owner` need it.

### Upgrade notes (v0.17+)

**(a) `merge.auto_sync` defaults to `true` (#289).** After every merge, Talos now syncs every other open pipeline PR's branch with the new base — union conflicts resolve mechanically, non-union ones go through the new `update-branch` server-side verb, then the developer merge-base dispatch. If you prefer conflicts to surface at each PR's own merge time (pre-0.17 behavior), set `merge.auto_sync: false`. Note `update-branch` requires a GitHub token with PR-write scope (the same one `merge-pr` uses) or `gh` auth.

**(b) Reviewer verdicts carry a "Human-attention report" (#294).** If you parse reviewer comments (e.g. `review-signoff` consumers), the verdict comment now ends with an `ATTENTION_REPORT` section — a trailing prose block. Vendored project copies of `templates/comments/review-signoff.md` render without the section until you re-copy the shipped template (`${ATTENTION_REPORT}` unsubstituted is a safe_substitute no-op, so nothing breaks — the section just stays empty).

**(c) `roles.changelog_fragments` is opt-in and default-`false` (#290, #296).** When `true`, docs writes `docs/CHANGELOG.d/<issue>.md` fragments instead of editing CHANGELOG.md and the orchestrator assembles them on the base branch post-merge (`scripts/pipeline-changelog.sh assemble`, non-fatal). When `false` (default) nothing changes. Enabling it requires nothing else — the `CHANGELOG MODE: fragments` trigger is wired into the docs dispatch automatically.

**(d) The stale-base guard now fires on every merge (#288).** Previously CHANGELOG-only; now any stale base resolves through the same conflict-files → union/update-branch → developer-dispatch ladder before `merge-pr`. If you relied on merging PRs with knowingly-stale bases, expect an automatic branch sync attempt first.

### Upgrade notes (v0.16+)

**(a) The 48 shipped per-platform notification templates are gone; one neutral template per event replaces them (#284).** Each event now has a single rich template at `<templates_dir>/<event>.md`, written in a neutral dialect that `pipeline-notify.sh` transpiles per sink (Slack mrkdwn, Discord/Teams markdown, pass-through GFM on Buzz). **Project overrides are unaffected** -- both `templates/notifications/<event>.md` and `templates/notifications/<platform>/<event>.md` in your repo keep working and still win over the shipped copy, so no customisation breaks.

**(b) If you ran `install.sh --global` while tracking `main` between #283 and #284, delete the orphaned per-platform directories.** `install.sh` copies files into `~/.talos/`; it never prunes ones that have been removed upstream. Resolution checks a root's `<platform>/<event>.md` *before* its `<event>.md`, so 48 stale files left in the install root would silently win over every new neutral template and you would keep getting the old layout with no error. This affects only people who installed from `main` between those two commits -- #283 never reached a release. Check and clean with:

```bash
ls -d ~/.talos/templates/notifications/{slack,discord,teams,buzz} 2>/dev/null   # should print nothing
rm -rf ~/.talos/templates/notifications/{slack,discord,teams,buzz}              # if it printed anything
```

**(c) The headline's issue/PR reference is now a link (#284).** `${HEADLINE}` renders as `<icon> **<Role>** - <verdict> · <ref>` with the ref linked to the event's primary URL (the PR for `pr-opened`/`merged`, the issue otherwise), degrading to plain text when no URL resolves. `${REF_LINK}` is a title line carried by thread roots only, and replies also omit the metadata block, so the linked ref is what gives a reply its route back to the PR. Anything scraping notification text for a bare `#42` should expect `<url|#42>` on Slack and `[#42](url)` elsewhere.

**(d) Role display labels changed where they were verbose.** `pm` now renders as **PM** rather than "Project Manager", aligning the label set with daedalus `_ROLE_LABELS`. The `${ROLE}` slug is unchanged (`pm` still maps to `project-manager`); only the human-facing `${ROLE_LABEL}` in the headline differs.

**(e) Teams cannot thread, and `TEAMS_WEBHOOK_URL` is read from the environment only.** Teams delivery is incoming-webhook only, so every event lands as a separate root post rather than a per-issue thread as on Slack, Discord and Buzz. Unlike `SLACK_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `BUZZ_RELAY_URL` and `BUZZ_BOT_PRIVATE_KEY`, `TEAMS_WEBHOOK_URL` was **not** sourced from `~/.hermes/.env` in v0.16 -- you had to export it (since v0.19 it is read from the `.env` files too; see [Upgrade notes (v0.19+)](#upgrade-notes-v019)). Microsoft retired the legacy Office 365 "Incoming Webhook" connector in May 2026; the supported route is a Power Automate **Workflows** webhook ("Post to a channel when a webhook request is received"). Treat that URL as a bearer credential: its `sig` query parameter authorises posting to the channel.

### Upgrade notes (v0.15+)

**(a) Approval-marker author verification is now on by default (#187).** `markers.verify_authors` defaults to `true`: `check-approval-sha`/`read-attempt` now only trust a `talos:approval`/`talos:attempt` marker posted by the identity Talos itself is authenticated as (inferred automatically, no config required) unioned with `markers.trusted_authors`. Previously any commenter's marker was trusted. If your setup relies on a separate bot/CI job posting markers under a different identity, list its login under `markers.trusted_authors`; to restore the exact pre-#187 behaviour (accept any commenter's marker, silently), set `markers.verify_authors: false`.

**(b) `pipeline-events.sh cost`'s `n/a` column is now `unrecorded` (#259).** Raw event lines in `.talos/events.jsonl` (written by `post_stage`) carry `tokens: null` when usage was not reported — expected for reviewer/security/validator/docs stages on the native subagent path, which record duration only. The `cost` report (table and `--json`) never surfaces that `null`: its `tokens` column is always an integer sum (treating a null event as `0`), and the previously `n/a`-named column — now `unrecorded` — separately counts how many of that group's events had a null `tokens` field, so an untracked group stays visible instead of reading as a real zero. Any script or dashboard consuming `pipeline-events.sh cost --json` must key on `unrecorded`, not on a null `tokens` value, since `tokens` in the `cost` report is never `null`.

**(c) Worktree lifecycle now removes every stage's worktree and scratch branch, not just the developer's (#240).** QA/reviewer/security/docs harness worktrees and their scratch branches are now tagged (`pipeline-worktree.sh tag`) and removed alongside the developer's once the PR merges or closes; `sweep` also reclaims any orphan regardless of dirty state, rather than preserving it indefinitely. No config key to change — this is a behaviour change to `remove`/`sweep`, not an opt-in. See [Worktree lifecycle](#worktree-lifecycle).

**(d) QA runs targeted tests only, via `run-tests.sh --for`/`--changed --strict` (#257).** QA no longer re-runs the full suite (CI already did, under `verify.qa_mode: ci`) and never falls back to the full suite for an unmapped path — an unmapped path is skipped instead, and an all-unmapped selection exits `3`. If you have external tooling that scrapes QA's test output expecting a full-suite run, expect a scoped selection instead; no config key changes this, it is the QA stage prompt itself. See the `--strict` documentation in [Tests](#tests).

**(e) CHANGELOG-only merge conflicts are now resolved mechanically, without a developer dispatch (#256).** A `CONFLICTING` PR whose only conflicting paths are covered by `merge.union_paths` (default `["CHANGELOG.md"]`) is now merged automatically by `pipeline-mergebase.sh` (`git merge-file --union`, both sides kept) instead of triggering a full developer merge-base task. Widen or narrow which paths qualify via `merge.union_paths`; entries under `scripts/**`, `tests/**`, or matching a pipeline config filename are rejected at validation time and can never be added.

**(f) `merge.required_checks` must only name checks that actually run on PRs, if you adopt the CI template (#260).** The new `templates/ci/github-tests.yml` splits the OS matrix by trigger — pull requests run `ubuntu-latest` only; pushes to the base branch run the full `ubuntu-latest` + `macos-latest` matrix. Naming a push-only check (e.g. `test (macos-latest)`) in `merge.required_checks` makes QA's CI-wait loop wait for a check that never appears on the PR, hanging until `verify.ci_wait_s` elapses. Keep `merge.required_checks` scoped to checks that run on every PR.

### Draft PRs (`pr.draft`, default, #332, #435)

CI runs on every push to an open PR, and a Talos PR gets several pushes before it is ready to verify: the developer's own, each fix round, the docs stage's CHANGELOG commit. This is the default flow (`pr.draft: false` opts out). The PR stays a **draft** through every stage that needs no CI, and CI runs once, when the PR is marked ready:

```
developer   code + local `verify:`, opens a DRAFT PR (create-pr --draft)
docs        CHANGELOG commit now, before any approval marker
reviewer + security + adversarial   review the draft in parallel
developer   ONE fix round for every finding; re-stamps review only the delta
ready-pr    the ONE CI run (ready_for_review)
QA          trusts the run (qa_mode: ci) and exercises the flow end to end
merge       approval SHAs and ci-complete on the final head, as always
```

A QA or CI failure costs exactly one more run however many commits the fix takes: `draft-pr`, developer fix, re-stamps, `ready-pr`. QA and the CI wait never start while the PR is a draft: the orchestrator asks `pipeline-vcs.sh pr-is-draft <pr>` first and dispatches only on exit 1 with stdout exactly `ready`; exit 0 (still a draft) starts nothing and exit 2 (unverified) stops and reports. `pipeline-events.sh cost` gains a trailing `ci_runs` column (from `pr-ci-runs`, recorded on the `merged` event) so the saving is measurable. Under `qa_mode: ci` the orchestrator waits for that one run with a single `pr-checks-required <pr> --wait <s>` call right after `ready-pr` (`<s>` is `verify.ci_wait_s`, capped under `verify.timeout_ms`), so no QA agent idles on it; under `qa_mode: local` QA is dispatched as before.

**Pair it with your CI (Talos checks and warns, it never edits a workflow file).** At the start of a run on `github`, `bash scripts/pipeline-draft-check.sh` reads `.github/workflows/` and prints one status: `ok`, `no-skip` (PR workflows exist and none skips drafts: Talos warns, `CI will still run on every push`), `no-ready-trigger` (a job skips drafts but `ready_for_review` is not in `types`; with `pr.draft` unset that run falls back to the ready flow, with it set to `true` Talos only warns), `none` (no `pull_request` workflow, silent) or `unknown` (anything it cannot read with confidence, including a symlinked or over-1-MB workflow; one note, never a block). Only a real draft skip counts: a job `if:` that is `github.event.pull_request.draft != true`, `== false` or `!github.event.pull_request.draft`, alone or `&&`-combined. `== true`, an `||` branch or a mere mention does not. When workflows disagree the worst state wins (`no-ready-trigger`, then `no-skip`, then `ok`), so one good workflow never hides a bad one. It parses with PyYAML when importable and falls back to a conservative grep, and the check always exits 0. `/talos:setup` runs the same check and, for `no-skip` and `no-ready-trigger`, offers a minimal change: `pipeline-draft-check.sh edit <file>` prints the exact diff (`ready_for_review` appended to `types`, `if: github.event.pull_request.draft != true` on a job without an `if:`, nothing else, never `permissions:`), and only `edit <file> --write` after an explicit yes writes it. An existing job `if:` is never edited: it is listed as `manual: job <name>` with the combined condition `(<existing>) && github.event.pull_request.draft != true` for you to apply by hand. It refuses a symlink, a non-regular file or a path outside `.github/workflows`. Two things must be true of the workflow that runs your required checks:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]   # ready_for_review is required
jobs:
  test:
    if: github.event.pull_request.draft != true                 # on every job
```

Without `ready_for_review` in `types`, marking a PR ready fires no event, no run ever starts, and QA waits for it until `verify.ci_wait_s` expires. Without the per-job `draft != true` guard the draft pushes still run CI, so you pay for every push and gain nothing. Talos's own `.github/workflows/tests.yml` already does both (#145/#160), as does `templates/ci/github-tests.yml`.

**A skipped required check is pending, not failed (#435).** A draft push leaves the job skipped until the `ready_for_review` run replaces it. `pr-checks-required` reads a skipped check (`gh` `skipping`, `github-api` conclusion `skipped` or `neutral`) as pending (exit 2) and never as `failed:`, so the orchestrator cannot mistake the draft-time skip for a red build and re-dispatch the developer. It never reads one as a pass either: a skip that persists ends in exit 2 at the `--wait` deadline.

**A draft-time run must never report success for a required check.** Skipping the jobs on a draft is not enough on its own, because a skipped check can still read as passing:

- **A skipped job counted as success.** GitHub branch protection counts a skipped required check as success (the job's `if:` was false, so it never ran). A draft push that skips `test` therefore does not hold the PR back for anything that merges on branch protection alone.
- **An `always()` aggregate job.** The common "all checks passed" job that has `needs: [test]` and `if: always()` runs even when `test` was skipped, and goes green on a draft push. Give it the same `if: github.event.pull_request.draft != true` guard instead of `always()`, or make it fail unless `needs.test.result == 'success'`, so a draft run is skipped or red, never green.

GitLab and Azure DevOps: Talos documents only the principle there (the required pipeline or build policy must not pass on a draft/WIP merge request or pull request, and must start when it is marked ready). The exact trigger and policy settings for those two providers are **unverified**; check them against your own pipeline before you rely on the draft flow there (the check above is `github` only).

**Trade-off.** Reviewers now see the code before CI has proven it; with `pr.draft: false` they are gated behind QA passing. The developer's local `verify:` run covers most of that risk. When CI catches something `verify:` missed, it costs one extra run, one step later than the ready flow. `github-api` and `file` cannot open draft PRs and always run the ready flow (`github-api` warns once). A default CI that never skips drafts only loses the saving; it cannot hang QA.

### Comment templates

Stage comments use `string.Template`-style `${PLACEHOLDER}` substitution. Templates live in `templates/comments/`:

| File | Posted by | Variables used |
|------|-----------|----------------|
| `validator-verdict.md` | validator | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `pr-opened.md` | developer | `${HEADER}`, `${PR}`, `${SUMMARY}`, `${DETAILS}` |
| `qa-verdict.md` | qa | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `review-signoff.md` | reviewer | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}`, `${ATTENTION_REPORT}` — renders the reviewer's human-attention report (#294): at most 3 bullets, highest-risk first, `file:line` each |
| `security-signoff.md` | security | `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}` |
| `docs-posted.md` | docs | `${HEADER}`, `${SUMMARY}`, `${DETAILS}` |
| `issue-closed.md` | orchestrator | `${HEADER}`, `${PR}`, `${DETAILS}` |
| `epic-acceptance-pending.md` | orchestrator | `${HEADER}`, `${DETAILS}` |
| `blocked.md` | any stage | `${HEADER}`, `${SUMMARY}`, `${DETAILS}`, `${BLOCKED_BY}` |

Edit these files to customise the comment format for your team. The subagent falls back to an inline summary if a template file is missing.

### Notification templates

Notification messages are rendered as Slack Block Kit (section + colored attachment), Discord embeds (title/description/color/footer), a Teams Adaptive Card, or Buzz GFM. Every event has **one neutral template**, written once in a small markdown dialect (`**bold**`, `[text](url)`, `- ` bullets, blank-line paragraphs, at most one leading `### ` heading) and transpiled into each sink's native syntax — templates never need per-platform conditionals. Templates use `${PLACEHOLDER}` substitution with these variables:

| Variable | Value |
|----------|-------|
| `${ICON}` / `${EVENT}` / `${MSG}` | event icon, event name, message text |
| `${REF}` | issue ref as passed (e.g. `#42`) |
| `${ROLE}` | role label (validator / project-manager / developer / …) |
| `${TITLE}` / `${REF_TITLE}` | issue title / `#42 title` — no colon; the title reads as one phrase now that it appears exactly once, not repeated under a verdict-first headline |
| `${PR}` / `${PR_TITLE}` / `${PR_REF}` | PR number / title / `PR #9: title` |
| `${ISSUE_URL}` / `${PR_URL}` | GitHub URLs (empty if undetectable) |
| `${REF_LINK}` / `${PR_LINK}` | markdown links `[#42 title](url)` / `[PR #9: title](url)` — transpiled to each sink's native link syntax; fall back to plain text when no URL |
| `${BOARD}` | board name (owner-repo) |
| `${REPO}` | repo slug (`owner/name`) |
| `${VERDICT}` | the leading verdict token lifted out of `${MSG}` — one of `PASS`, `FAIL`, `DONE`, `CLEAR`, `CLOSED`, `MERGED`, `BLOCKED`, `CHANGES`, `FINDINGS`, `APPROVED`, `CONFIRMED`, `RESTAMP_PASS`, `RESTAMP_FAIL`; empty when `${MSG}` carries none |
| `${SUMMARY}` | `${MSG}` with the verdict token (and, for `blocked`, a leading `<stage>:`) stripped off; a long single-line, semicolon-joined summary (over 160 chars, at least two `; `) is reflowed into a lead sentence plus `- ` bullets |
| `${ROLE_ICON}` / `${ROLE_LABEL}` | fixed per-role pair — 🔎 Validator, 📝 PM, 🛠 Developer, 🧪 QA, 👀 Reviewer, 🔐 Security, 📚 Docs, 🗺 Planner, 😈 Adversarial; every lifecycle event (`pr-opened`, `merged`, `blocked`, `issue-closed`, `dispatched`, `info`, `orchestrator`) is 🤖 Talos |
| `${HEADLINE}` | line 1 of every shipped template — assembled by the script itself, not written by the template, as `${ROLE_ICON} **${ROLE_LABEL}** — ${VERDICT or action} · ${REF}`, with `${REF}` itself linked to the issue/PR URL when one is known (the PR's URL for `pr-opened`/`merged`, otherwise the issue's) — a thread reply carries neither the title line nor the metadata block, so this linked ref is the only route back to GitHub a reply gets |

Every shipped template follows the same three-line layout: `${HEADLINE}` (line 1, who's speaking and their verdict), `${REF_LINK}` (line 2, the title once), then `${SUMMARY}` as the body, never fenced. A `pr-opened`/`merged`/`issue-closed` event shows the PR title as `${SUMMARY}` instead of the raw "PR https://… opened" boilerplate; a `blocked` event lifts a leading `<stage>: ` out of `${MSG}` into the headline (`blocked by <stage>`) rather than repeating it in the body.

**Root vs. reply.** A post with no thread anchor yet is the root — the first message for that issue — and gets the full card: `${HEADLINE}`, the `${REF_LINK}` title line, the native metadata construct (fields/FactSet), and, on Slack/Discord, a `repo · event · ref` context footer (Slack's `context` block, Discord's embed `footer`). A threaded reply (same issue, an anchor already on file) drops **both** the title line and the metadata block — the root above already carries them — and renders as just `${HEADLINE}` plus `${SUMMARY}` as the body; Slack/Discord replies still carry the context footer, Buzz replies carry neither footer nor metadata, just the headline and body. This is exactly why `${REF}` inside `${HEADLINE}` is linked: it is a reply's *only* click-through to the issue/PR. Teams never threads (see below), so every Teams post is a root card. See [Per-issue notification threading](#per-issue-notification-threading).

Anything outside this table renders as a literal `${NAME}` in a real notification, so `tests/test-notify-templates.sh` fails when a shipped template references an undocumented variable.

#### One template per event, transpiled per platform

Templates live under `notifications.templates_dir` — 14 shipped files, one per event, at the top level:

```
templates/notifications/
  <event>.md   # e.g. validator.md, qa.md, blocked.md, pr-opened.md, …
```

The formatter in `pipeline-notify.sh` (`to_platform()`, one dialect table per sink) turns the neutral dialect into each sink's native syntax right before the sink's payload formatter consumes it:

| Sink | Transpiles to |
|------|---------------|
| Slack | mrkdwn — `**bold**` → `*bold*`, `[text](url)` → `<url\|text>`, a heading → a bold line, `- ` → `• ` |
| Discord | native CommonMark, unchanged — bold/links/`- ` render as-is; a heading becomes a bold line (embeds have no heading syntax) |
| Teams | same rules as Discord — the heading/first line becomes the Adaptive Card's Bolder TextBlock, the rest a wrapping TextBlock; links stay markdown |
| Buzz | pass-through GFM — Buzz renders `remark-gfm`, so the dialect needs no transpiling |

The transpiler also tidies whatever an unavailable variable leaves behind — an empty link target, a dangling `·` separator, an empty `**bold**` run — so a template never needs a conditional: `[PR ${PR}](${PR_URL})` simply disappears when there is no PR, and `${REF_LINK}` degrades to plain text when no URL was detectable.

Metadata (PR / Issue / Stage / Repo) is rendered by the sink as its own native construct, **root messages only** — Block Kit `fields` on Slack, embed `fields` on Discord, an Adaptive Card `FactSet` on Teams (always, since Teams has no reply state), one compact `repo · [PR #n](url)` line on Buzz (in place of the four-row GFM table an earlier design used, since the role is on line 1 now). A sink is "rich" whenever a template resolved at all; only `notifications.cmd` (which never gets a template) and a project that has deleted its templates fall back to the shared fenced monospace grid.

**Per-platform files remain a valid, optional project override.** A project may still ship `templates/notifications/<platform>/<event>.md` to hand-tune one sink — Talos itself ships none. Resolution order per platform, first hit wins:

| # | Looked up | Wins when |
|---|-----------|-----------|
| 1 | `<project>/<templates_dir>/<platform>/<event>.md` | your repo overrides one platform |
| 2 | `<project>/<templates_dir>/<event>.md` | your repo overrides all platforms |
| 3 | `~/.talos/<templates_dir>/<platform>/<event>.md` | shipped, platform-specific (Talos ships none by default) |
| 4 | `~/.talos/<templates_dir>/<event>.md` | shipped, neutral |

The project copy wins at **both** layers, so an existing single-level `templates/notifications/<event>.md` override keeps winning over a shipped platform template — no config change, nothing to migrate.

**Adding your own:** drop a file at `templates/notifications/<event>.md` (or `templates/notifications/<platform>/<event>.md` to override one sink; create the directory if it does not exist) in your repo. Preview it without posting anything:

```bash
bash ~/.talos/scripts/pipeline-notify.sh --render buzz qa "#42" "PASS: 3 criteria verified"
```

`--render <platform> <event> [ref] [message]` prints the resolved template path and the exact payload that platform would send, then exits 0. It posts nothing, reads and writes no thread anchors, and ignores the `notifications.events` filter. It always renders the **root** form (title line + metadata) — since it touches no thread state, it has no anchor to treat as an existing thread. Platform is one of `slack`, `discord`, `teams`, `buzz`, or `default` (the neutral rendering `notifications.cmd` receives).

**Role event templates** (one per agent — make up the conversation stream):

| File | Event arg | Sent after |
|------|-----------|-----------|
| `validator.md` | `validator` | Validator returns |
| `pm.md` | `pm` | PM posts the spec |
| `developer.md` | `developer` | Developer opens PR |
| `qa.md` | `qa` | QA returns |
| `reviewer.md` | `reviewer` | Reviewer returns |
| `security.md` | `security` | Security analyst returns |
| `docs.md` | `docs` | Docs agent returns |
| `orchestrator.md` | `orchestrator` | Orchestrator merges and closes |

**Lifecycle event templates** (structural signals):

| File | Event arg | Sent when |
|------|-----------|-----------|
| `dispatched.md` | `dispatched` | A stage is dispatched — icon/headline wired, but not emitted by the shipped playbook; available for custom orchestration |
| `pr-opened.md` | `pr-opened` | PR created by developer |
| `merged.md` | `merged` | PR merged |
| `blocked.md` | `blocked` | Any stage sets pipeline:blocked |
| `issue-closed.md` | `issue-closed` | Issue closed after merge |
| `info.md` | `info` | Generic informational events |

**Events-filter warning:** `notifications.events` defaults to unset (all events fire). If you set a list, any event not in it is **silently dropped** — no error, no log line. A lifecycle-only list like `[pr-opened, merged, blocked, issue-closed]` kills the entire conversation stream. When you need a filter, copy the full list from `talos.pipeline.json.example` and remove only what you don't want.

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
| `TALOS_BOARD_MAX_PAGES` | overrides the page cap for `pipeline-status.sh`'s items() pagination loop (default `50`, i.e. 5000 items at 100/page). A non-positive-integer value falls back to the default with a warning on stderr. Hitting the cap, or a malformed page (`hasNextPage=true` with an empty cursor), bails out via `talos:board-unverified` instead of looping forever. |

### Per-issue notification threading

When `notifications.threading: true` (the default) and a Slack or Discord **bot token** is in use, all events for the same issue land in a single thread rather than flooding the channel as separate top-level messages. Buzz is always key-based, so it always threads when enabled — follow-ups publish as NIP-10 replies (`["e", <root-id>, "", "reply"]`) to the issue's root event. **Teams cannot thread at all:** delivery is incoming-webhook only, with no bot-token alternative to opt into, so every Teams event lands as a separate root card — unlike Slack, Discord, and Buzz, which all thread per issue.

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

1. You run `/talos:pipeline` in a Claude Code session.
2. The orchestrator reads `talos.pipeline.json` and reconciles any in-flight PRs from a previous run.
3. It lists issues with `pipeline:ready` (up to `max_parallel`).
4. For each issue:
   - **Validator** reads the issue and codebase. CONFIRMED advances; anything else sets `pipeline:blocked`.
   - **PM** turns the confirmed issue into a spec comment (goal, acceptance criteria, branch name, out-of-scope).
   - **Developer** spawns in an isolated git worktree. It implements, iterates with targeted tests (`verify.targeted`, default `true`), then runs your full `verify` commands exactly once before its final commit, and opens a PR. The worktree is removed (branch and all) right after the PR merges, via `pipeline-worktree.sh remove`; a startup sweep reclaims any orphaned worktree as a backstop.
   - **QA** checks out the PR branch and verifies each acceptance criterion. Under `verify.qa_mode: ci` (the default once `merge.required_checks` is set) it does not re-run `verify:` — it waits for CI to go green and fails closed if it doesn't; under `local` it runs `verify:` once itself.
   - **Docs** runs first after QA passes (phase 1); **Reviewer + Security** run in parallel after docs completes (phase 2). Reviewer and security run no tests at all — CI and QA already own that, and neither stage re-runs `verify:` or `run-tests.sh`.
   - By default (`pr.draft` is `true`) the order above changes (developer opens a draft, docs and review run before QA, `ready-pr` starts the one CI run); `pr.draft: false` keeps it: see [Draft PRs](#draft-prs-prdraft-default-332-435).
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
| `scripts/pipeline-config.sh KEY [default]` | Dot-path config reader (YAML/JSON); use `--dump` to print the entire resolved config as NUL-delimited key/value pairs |
| `scripts/pipeline-cfg-cache.sh` | Per-invocation config cache that eliminates redundant python3 parses (sourced by pipeline-*.sh internally) |
| `scripts/pipeline-contract.sh` | Single source of truth for roles, labels, and `talos:` markers (sourced by pipeline-vcs.sh and bootstrap-labels.sh; see "Contract" below) |
| `scripts/pipeline-vcs.sh [--dry-run] <verb> [args...]` | Uniform VCS adapter (github/gitlab/azure/file) |
| `scripts/pipeline-draft-check.sh [check [<dir>]\|resolve\|edit <file> [--write]]` | The draft-PR default (#435). `resolve` prints the effective `PR_DRAFT` (`true`/`false`) from `pr.draft` and `vcs.provider` and is the one value `/talos:pipeline` Step 0 and `pipeline-status-file.sh collect` both use; `check` scans `.github/workflows` and prints `ok`, `no-skip`, `no-ready-trigger`, `none` or `unknown`. `check` and `resolve` always exit 0 and never edit a file; `edit` prints the minimal workflow diff and writes only with `--write` (refuses a symlink or non-regular file, exit 1); see [Draft PRs](#draft-prs-prdraft-default-332-435) |
| `scripts/pipeline-status.sh [--dry-run] <issue> <status>` | Set GitHub Project board status |
| `scripts/pipeline-status-file.sh collect` | The normalised run state as JSON on stdout (open pipeline PRs with their next stage, blocked, queued, held, in-flight issues, owner questions), from read verbs only; the input of `talos.sh state` and `talos.sh next`. The name is historical: it no longer maintains a status file (#550); not `pipeline-status.sh`, which sets the Project board status |
| `scripts/pipeline-board-shared.sh` | Owner/project-id resolution + curl-GraphQL helpers shared by pipeline-status.sh and bootstrap-board.sh (sourced, not run directly) |
| `scripts/pipeline-notify.sh <event> <ref> <message> [thread_key]` | Post event to Slack/Discord/Teams |
| `scripts/bootstrap-labels.sh [owner/repo]` | Create `pipeline:*` labels (idempotent) |
| `scripts/bootstrap-board.sh [owner/project_number]` | Provision GitHub board Status options (id-preserving, idempotent); validate Azure states / GitLab labels for parity |
| `scripts/pipeline-agent.sh` | Run one pipeline role stage through a headless LLM CLI, for harnesses without native subagents (Codex CLI, Gemini CLI, Antigravity CLI, any headless runner); see [Other harnesses](#other-harnesses-pi-codex-cli-gemini-cli-antigravity-local-models) |
| `scripts/pipeline-instructions.sh print\|write <repo-dir> [--harness <list>] [--import-agents-md]` | The Talos block for `AGENTS.md`, one text for every harness. `print` writes it to stdout; `write` creates, appends or repairs it in `<repo-dir>/AGENTS.md` between its markers (the only file it writes, besides the opt-in `@AGENTS.md` import into an existing `CLAUDE.md` / `GEMINI.md`) and prints what you may need to do. `install.sh <repo>` calls it; see [Quickstart](#1-install) |
| `scripts/pipeline-events.sh path\|list [--issue N] [--role R] [--event E] [--last K] [--json]\|cost [--issue N] [--pr M] [--json\|--line\|--markdown\|--summary]` | Reader for the local events log (`<git common dir>/talos/events.jsonl` by default, outside every git tree); see [Events log](#events-log) and [Cost accounting](#cost-accounting) |
| `scripts/pipeline-budget.sh check --issue N [--json]` | The token budget guard (#334): prints `talos:budget <ok\|warn\|exceeded> ...` (nothing when `limits.tokens_per_issue` is off); exit 0 for ok, warn, unknown and off, 1 for exceeded only, 2 for usage; see [Seeing token spend](docs/user-guide.md#seeing-token-spend-334) |
| `scripts/talos-status.sh [--line]` | The harness status line (#385, #550): `talos #<issue> <stage> ●●◐○○○ <tokens>` from the events log and, for a running stage, the harness transcript on stdin (`transcript_path`); offline, exits 0 on every input, prints nothing without an active issue. `install.sh --global` copies it next to `pipeline-spend-format.py` (a shared module, not a command) and wires it into Claude Code's `statusLine`; see [Status line and resume](#status-line-and-resume) |
| `scripts/pipeline-hooks.sh` | Run `hooks.pre_dispatch`/`hooks.post_stage` external commands at fixed pipeline points; see [Hooks](#hooks) |
| `scripts/pipeline-isolation.sh validate` | Startup gate for `execution.isolation` + `issues.max_parallel` combinations; see the `execution.isolation` row in the [Config reference](docs/user-guide.md#config-reference) |
| `scripts/pipeline-bounded.sh` | Sourced helper exporting `talos_bounded` (run a command under a wall-clock limit on macOS and Linux, no `timeout(1)`) and `talos_pos_int`; shared by `hooks.*`, `notifications.cmd` and the Buzz `nak` call |
| `scripts/pipeline-lock.sh` | Portable `mkdir`-based advisory locking for shared local state (threads.json, worktree metadata, test cache) under `issues.max_parallel > 1`; see the `issues.max_parallel` row in the [Config reference](docs/user-guide.md#config-reference) |
| `scripts/pipeline-mergebase.sh` | Mechanical union merge for a CONFLICTING PR whose only conflicting paths are covered by `merge.union_paths` (default `CHANGELOG.md`), no developer dispatch; see the `merge.union_paths` row in the [Config reference](docs/user-guide.md#config-reference) |
| `scripts/pipeline-paths.sh` | Sourced helper exporting `_resolve_talos_dir()`, the canonical probe for the Talos scripts directory; see [1. Install](#1-install) |
| `scripts/pipeline-verify.sh --issue N --worktree PATH -- <cmd>` | Run a `verify:` command with `TALOS_ROLE`/`TALOS_ISSUE_NUMBER`/`TALOS_WORKTREE_PATH` exported mechanically for native Claude Code subagents; see [Context](#context) |
| `scripts/pipeline-criteria.sh ids\|map\|report\|qa-run` | Map a spec's `AC<n>` criteria to test results by id (#421): `ids <spec>` lists them as `test` or `prose`, `map <output> [--spec <spec>]` gives `pass`, `fail` or `missing` per id from a runner's `ok`/`FAIL` assertion labels, `report` gives QA's one line per id (`AC<n> red@<sha8> green@head`, or the failing case). Those three are text only: no network, no LLM. `qa-run <issue> <pr>` (#549) is QA's whole criteria check in one call: tags the worktree, checks `pr-mergeable`, checks out the PR, validates the spec's `Tests:` line as data (paths `^[A-Za-z0-9_./-]+$`, name filters `^[A-Za-z0-9_\|. -]+$`; anything else is refused and nothing from the spec runs), runs the files at the PR head and at the red commit, restores HEAD, and prints the `report` lines plus `qa-run: verdict PASS\|FAIL <why>`; see [Criteria first](docs/user-guide.md#criteria-first-red-first-tests-421) |
| `scripts/pipeline-worktree.sh` | Lifecycle for per-issue developer worktrees and Claude Code harness worktrees (create/remove/sweep, `checkpoint`/`handoff`); see [Worktree lifecycle](#worktree-lifecycle) |

### Contract

`scripts/pipeline-contract.sh` is the single source of truth for every role name, `pipeline:*`/`qa:pass`/`review:approved`/`security:approved`/`docs:done`/`spec:ready`/`skip-qa` label, and `talos:` marker Talos uses (issue #178 -- previously restated across `pipeline-vcs.sh`, `bootstrap-labels.sh`, and the prompts, and drifting silently). It's a plain sourceable bash file (indexed arrays, bash 3.2 compatible) that `pipeline-vcs.sh` and `bootstrap-labels.sh` read instead of hand-duplicating the lists, plus a `talos_contract_json` function that prints the whole contract as JSON. `tests/test-contract.sh` greps `skills/pipeline/SKILL.md`, `agents/*.md`, `templates/**`, `README.md`, and `docs/user-guide.md` for every such string and fails if any is missing from the contract.

It also holds two lists the installer and the tests read. `TALOS_RUNNERS` is the six `id|Display name` entries behind `agents.runner` (`claude`, `pi`, `codex`, `gemini`, `antigravity`, `custom`); the display names are the column headers of the user guide's harness feature matrix, which `tests/test-runner-conformance.sh` checks. `TALOS_COMMANDS` is `pipeline setup`, one per `skills/<command>/SKILL.md` (`skills/pipeline-setup/` is the deprecated `/talos:pipeline-setup` alias, not a command): `install.sh --global` copies each to `~/.talos/skills/<command>/SKILL.md` (`~/.talos/skills/pipeline/SKILL.md`, `~/.talos/skills/setup/SKILL.md`, `~/.talos/skills/resume/SKILL.md`), the `AGENTS.md` block names them, and the pointer skills are generated from them.

### pipeline-vcs.sh verbs

| Verb | Arguments | Description |
|------|-----------|-------------|
| `create-issue` | `<title> <body-file> [--label label]` | Create a new issue; `--label` may be repeated (used by planner to create sub-issues). Exits non-zero if the POST fails. |
| `assign-issue` | `<n>` | Assign issue `<n>` per `issues.assignee` (#299) only when it has no assignee; reads the field back and prints `assign-issue: #<n> assigned to <id>` only when the write is confirmed. Every failure is a stderr warning with exit 0. `create-issue` calls it on the new issue and `pipeline-status.sh` calls it on "In progress". github, github-api, gitlab, azure (not file). |
| `issue-assignees` | `<n>` | Print issue `<n>`'s assignee logins, one per line (#560); nothing when unassigned, exit 1 on a failed read. Azure DevOps prints the unique name. github, github-api, gitlab, azure (file exits 2). |
| `unassign-issue` | `<n> <login>` | Take `<login>` off issue `<n>` and keep any other assignee (Azure clears its single field), then read the field back (#560). Prints `unassign-issue: #<n> unassigned <login>`; exit 1 with a `WARNING` when the login is still there. |
| `list-assignees` | none | One JSON object `{"<n>": ["login", ...]}` of the open issues that have an assignee (#560), one paginated request on GitHub. Exit 1 on a failed read. |
| `list-issues` | `[--no-body]` | List open issues / unchecked plan items. `--no-body` (#449; `github`, `github-api`) leaves the `body` key out of every item, for callers that only need `number`, `title` and `labels`; the default output is unchanged. |
| `view-issue` | `<id> [--spec]` | Show issue body and metadata. `--spec` (#201) prints the same shape but trims `comments` to at most the latest comment whose body starts with `**PM spec:**`, dropping every `<!-- talos:` marker comment and every stage-verdict comment (body starting with `**Agent:**`) -- also every other comment, including plain human replies, since the spec is the contract each stage implements against. Reuses the paginated `read-comments` fetch, no new request. `github`/`github-api` only (parity); `gitlab`, `azure`, and `file` fall back to the plain full view with a stderr note. |
| `comment-issue` | `<id> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on an issue. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. A positional body of exactly `-` also exits 1 (#449): `-` is not stdin there, so it would have posted a one-character comment; use `--body-file -` with the text on stdin. **Exits 1 if the issue is closed** unless `--allow-closed` is passed (required when GitHub auto-closes via `Closes #N` at merge). Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup (network error), posts (exit 0) and emits `talos:comment-state-unverified target=issue#<N> reason=<short>` on stdout. |
| `close-issue` | `<id> [reason]` | Close an issue |
| `label-issue` | `<id> --add label [--remove label]` | Add/remove labels (or tags for Azure) |
| `check-epic-acceptance` | `<epic-n>` | Scan the epic issue's body for unticked `- [ ] ` checklist boxes (checkboxes inside fenced code blocks count too). Exit 0 with no output when none remain, including bodies with no checkboxes at all. Exit non-zero and print each unticked item's text, one per line, when any remain. `github`/`github-api`/`gitlab`/`azure` (#168, #303, #304); exits 1 on fetch failure. On `azure` it reads the work item's HTML `System.Description`, where an unchecked `<input type="checkbox">` or `☐` is also an unticked box, and a description over 65536 characters exits 1. Used by the epic auto-close sweep — see docs/user-guide.md's "Working with epics" section for the full flow. |
| `create-pr` | `<branch> <title> <body-file> [--draft]` | Open a PR targeting base_branch. Prints `PR #<n> <url>` on one line (github and github-api, #549; a response without a PR number or URL exits 1). Exits non-zero if the POST fails. `--draft` (#332, goes after the three positionals) opens it as a draft: `gh pr create --draft`, `glab mr create --draft`, `az repos pr create --draft true`; `github-api` exits 2 rather than silently opening a non-draft PR; `file` mode stays a no-op. |
| `ready-pr` | `<pr-number>` | Mark a draft PR ready for review (#332): `gh pr ready`, `glab mr update --ready`, `az repos pr update --draft false`. Exit 0 only on success; every failure (non-numeric id, setup error, `github-api`, `file`) is exit 2. |
| `draft-pr` | `<pr-number>` | Convert a PR back to a draft (#332): `gh pr ready --undo`, `glab mr update --draft`, `az repos pr update --draft true`. Same exit contract as `ready-pr`. |
| `pr-is-draft` | `<pr-number>` | Print `draft` or `ready` (#332). Exit 0 = draft (stdout exactly `draft`), 1 = ready (stdout exactly `ready`), 2 = unverified (failed fetch, non-numeric id, unparseable response, `github-api`/`file`, or a setup error such as a missing token, unknown provider or missing CLI); stdout is empty on every exit 2, so it never degrades to `ready`. Callers start QA or the CI wait only on exit 1. Reads `isDraft` (`gh`, `az`) or `draft` (`glab`). |
| `pr-ci-runs` | `<pr-number>` | Print the number of `pull_request`-triggered workflow runs of this PR that executed (#332): one paginated listing for the head branch, keeping runs whose `pull_requests[]` names this PR (another PR that reused the branch name does not inflate the count) and dropping those whose conclusion is `skipped`, so a draft push whose jobs are all skipped by `if: github.event.pull_request.draft != true` is not counted. One listing means one snapshot; there is no total-then-skipped window for a run to slip into. `github` only; every other provider exits 2, as does a setup error, a failed, truncated or unparseable listing, a run that cannot be attributed to a PR (empty `pull_requests[]`, e.g. a fork) and a total that reaches GitHub's 1000-result search cap (never a short count). Call it while the PR is **open**: `merge-pr` deletes the head branch, GitHub then returns every run for it with an empty `pull_requests[]`, and a merged PR reads as unverified (exit 2), so the orchestrator captures the count just before `merge-pr`. Feeds `post_stage --ci-runs`. |
| `view-pr` | `<branch>` | Show PR number, URL, status |
| `list-prs` | | List open PRs. On `github` and `github-api` each item also carries `isCrossRepository` (#346): true for a fork PR or one whose fork was deleted; `github-api` also reports `baseRefName` |
| `diff-pr` | `<pr-number> [--stat]` | Show PR diff (Azure: via `git diff` between refs). `--stat` (#201) prints a `git diff --stat`-style per-file additions/deletions summary instead, derived from the same paginated PR-files endpoint `pr-files` (#200) uses -- no new fetch. `github`/`github-api` only (parity); other providers print the full diff (flag ignored). |
| `checkout-pr` | `<pr-number>` | Check out a PR branch locally |
| `approve-pr` | `<pr-number> [summary]` | Approve a PR |
| `label-pr` | `<pr-number> --add label [--remove label]` `[--require-marker]` | Add/remove PR labels. When an approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) is added and no approval marker exists at the current PR head, a WARNING is printed to stderr and the command exits 0 (non-fatal, so label-then-stamp call sites continue working). Pass `--require-marker` to make this check fatal and pre-apply: the label is not added if no marker is present at the current head (exits 1). `--require-marker` and the post-apply warning are `github` provider only. See **Approval-marker guard** below. |
| `pr-checks` | `<pr-number>` | List CI check statuses |
| `pr-checks-required` | `<pr-number> [--wait <seconds>]` | `--wait <seconds>` (digits, at most 3600, else exit 2; read in base 10, so `08` and `09` are accepted and `0010` waits 10 s, #449) polls inside the one call on `github`/`github-api` (#355); other providers answer once. Exit 0 only when every check named in `merge.required_checks` passes on the current head; exit 2 while any is still pending or missing (a skipped check, `gh` `skipping` or `github-api` `skipped`, counts as pending, #435); exit 1 on an explicit failure or when `merge.required_checks` is empty (never a vacuous pass). `github`/`github-api` read the PR's checks; `azure` (#318) reads the PR's policy evaluations (REST `_apis/policy/evaluations` with `includeNotApplicable=true`, #328, since `az repos pr policy list` omits policies that do not apply to the PR) and matches each name, case-insensitively, to an evaluation's `configuration.settings.displayName` (else `configuration.type.displayName`): `approved` and `notApplicable` pass, `rejected`/`broken` fail, `queued`/`running` are pending, an `approved` evaluation whose `context.isExpired` is true or whose `context.lastMergeSourceCommitId` is not the PR's `lastMergeSourceCommit` is pending, and a name with no evaluation is missing; a non-numeric PR id, a project id that is not a GUID, or a fetch/parse failure exits 1. `gitlab` fails closed (exit 1) rather than fail open, since QA's CI-wait loop treats exit 0 as "all required checks passed" (#205); `file` mode fails closed (exit 1) the same way rather than falling into the generic "not applicable" no-op bucket. |
| `merge-pr` | `<pr-number>` | Merge a PR (uses `merge.method` from config) |
| `update-branch` | `<pr-number>` | Update the PR's head branch by merging its base into it server-side (#289): GitHub `PUT .../pulls/{n}/update-branch` with `expected_head_sha` (`github`/`github-api` parity), GitLab `glab mr rebase`. Exit 0 on success; exit 1 on a head-moved conflict (HTTP 409) or other failure; exit 2 where unsupported (`azure`, `file`) — callers fall back to the developer merge-base dispatch. Does not resolve content conflicts on the PR's own files. |
| `comment-pr` | `<pr-number> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on a PR. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. A positional body of exactly `-` also exits 1 (#449): `-` is not stdin there, so it would have posted a one-character comment; use `--body-file -` with the text on stdin. **Exits 1 if the PR is closed without being merged** unless `--allow-closed` is passed. Merged PRs are always commentable without the flag. Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup, posts (exit 0) and emits `talos:comment-state-unverified target=pr#<N> reason=<short>` on stdout. |
| `find-pr` | `<issue-number> [open\|merged\|all]` | Find PRs belonging to an issue (session-recovery adoption). `merged` counts only the `issue-<N>` branch convention or a closing keyword (`Closes/Fixes/Resolves #N`) — a bare mention such as `Depends on #N` or `Part of #N` never matches, so the Step 1 heal cannot close a parent epic or an unfinished dependency (#298). Other states keep the looser bare-`#N` match. `azure` also returns PRs linked to the work item. Exit 2 means `find-pr` is not implemented for the provider, never "no PR found". |
| `check-pr-files` | `<pr-number>` | Exit 1 if the PR touches `merge.forbidden_files` patterns. On `github`/`github-api`/`gitlab` (#303)/`azure` (#304) a failed fetch also exits 1 (fail closed). Not implemented on `file`: it prints a stderr warning and exits 0, so this gate does not protect it. |
| `pr-files` | `<pr-number>` | Print the PR's changed paths, one per line — no filtering or exit-1 gate (unlike `check-pr-files`). Fully paginated (`gh api --paginate` / `_ga_fetch_all_pages`, the same #171 pattern as `list-issues`/`list-prs`), so PRs with more than 100 changed files are never silently truncated; a failed page exits non-zero with no partial output. Used by the Step 3e Phase 1 `roles.docs_mode: auto` gate (#200) to decide whether the docs stage needs to dispatch at all. `github`/`github-api`/`gitlab` (#303)/`azure` (#304: the last PR iteration's changes, every `$top`/`$skip` page, paths without ADO's leading `/`); `file` fails open with a stderr warning and empty stdout. |
| `check-closing-keyword` | `<pr-number> <issue-n>` | Exit 1 if the PR body carries a closing keyword while other PRs referencing issue `N` are still open. On `github`/`github-api`: `Closes/Fixes/Resolves #N` (all standard verb forms, case-insensitive), `owner/repo#N`, full GitHub issue URLs, and `GH-N` (case-insensitive), all scoped to the current repository. On `gitlab` (#303): GitHub keywords plus GitLab keywords (`Closing`, `Implements`, etc.), every reference in a list after one keyword (`Closes #1, #2 and #3`, as GitLab itself closes them), and same-project `/-/issues/N` URLs on the project's own host (taken from `vcs.repo` or the `origin` remote; any host when neither names one). Fail-open: exits 0 and emits `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` on stdout when PR body or sibling list cannot be fetched or repository cannot be resolved; when the sibling list is capped without finding a sibling, it emits with `reason=siblings-capped`, and the pipeline blocks the merge (`pipeline:blocked`) until a human has checked the siblings. On `azure` (#304) the gate is link-based, since ADO closes a work item through the PR's work-item link, not a keyword: exit 1 when the PR is linked to work item `N` and another active PR is linked to `N` or sits on an `issue-<N>` branch; fetch failures fail open with the same marker. Not implemented on `file`: it prints a stderr warning and exits 0, with no marker. |
| `rerun-ci` | `<pr-number>` | Re-run failed CI runs for the PR head SHA (flaky-CI retry). `github`/`github-api`/`gitlab` (#303); on `gitlab` any failure, including an MR with no head pipeline, exits 1. On `azure` (#304) it re-queues each rejected or broken build-validation policy (`az repos pr policy queue`), exits 2 when the PR has no build policy and 1 on any failure. Not implemented on `file`: it prints a stderr warning and exits 0. |
| `pr-head` | `<pr-number>` | Print the current head SHA for a PR. Fail-closed: exits 1 when the SHA cannot be resolved. Used by approval roles to stamp the SHA they approved. |
| `pr-mergeable` | `<pr-number>` | Print exactly one of `MERGEABLE` / `CONFLICTING` / `UNKNOWN` on stdout; exit 0/1/2 respectively (#214). `github`/`github-api`: reads `mergeable` (GitHub computes it lazily) and retries up to 4 times, sleeping a `TALOS_RETRY_SLEEP_SCALE`-scaled 2s between attempts, before giving up and reporting `UNKNOWN`. `gitlab`/`azure`: best-effort off their own merge-status fields; an inconclusive status reports `UNKNOWN` with a stderr note. `file` mode: always `UNKNOWN` (no PR concept). Used before dispatching QA and before QA's CI wait, since a `CONFLICTING` PR gets no `pull_request` CI run to wait for. |
| `conflict-files` | `<pr-number>` | Print the paths that conflict between the PR's head and `origin/<base_branch>`, one per line (#256). Resolved with a throwaway `git merge --no-commit` in a detached temp worktree created outside the caller's own checkout — `git status`/`assert-sync` on the caller's checkout are unaffected, and the worktree is removed on every exit path. Exit 0 with output when conflicting, exit 0 with no output when clean, exit 2 when it cannot be determined (fetch or worktree failure). `github`/`github-api` only, backed by one shared implementation. Used by the Step 3c mergeability gate to decide whether a `CONFLICTING` PR qualifies for `pipeline-mergebase.sh`'s mechanical union merge instead of a developer merge-base dispatch. |
| `check-approval-sha` | `<pr-number> [--stale-list]` | Exit 1 if any approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) was earned against a non-current head SHA whose delta is not fully covered by `merge.approval_waiver_paths`. Pass `--stale-list` to additionally print one greppable stdout line per stale role (`stale role=<role> label=<label>`); stderr and exit codes are unchanged. Fail-closed: unresolvable head SHA, missing marker, invalid waiver config, or `git diff` failure all exit non-zero. |
| `record-attempt` | `<issue-n> <stage> [--pr <pr-n> \| --idempotency-key <token>]` | Record one re-dispatch attempt for the given blocking stage on the issue. Reads prior state, computes the new per-stage count and running total, posts a `<!-- talos:attempt -->` marker comment on the issue, verifies the write landed, and prints `stage=<s> count=<k> total=<t>` on stdout. Exits non-zero when either ceiling (`max_fix_attempts` or `max_total_dispatches`) would be reached by this attempt — callers must check the exit code before re-dispatching the developer. Fail-closed: a corrupt or unparseable marker exits non-zero rather than silently resetting to zero. **`--pr <pr-n>` (#172 follow-up):** derives the idempotency key itself as `<stage>-<pr-head-sha>` by resolving the PR's current head SHA server-side (same call as `pr-head`) — the caller never mints a token by hand, so the exact same command run again in a fresh shell or a fresh orchestrator process recomputes the same key as long as the PR head has not moved, and dedupes correctly. Fails closed (exit 1, nothing posted) if the head SHA cannot be resolved; mutually exclusive with `--idempotency-key`. **`--idempotency-key <token>` (#172):** when the most-recent marker already carries this stage and `key=<token>`, does not post again — reprints the existing (unincremented) counts and exits with the status those counts already imply. `token` must match `[A-Za-z0-9._-]+` (invalid token exits 1 before anything is posted). Intended only for stages with no PR yet (`--pr` is unavailable before a PR exists); prefer `--pr` whenever a PR number is known. Omitted entirely: unchanged back-compat behaviour (always posts). **Limitation:** `--pr` dedupes a retry at the same head across any process, including a fresh orchestrator restart — it cannot distinguish two genuinely separate attempts recorded while the head happens not to have moved. `--idempotency-key` (or no key at all) still only dedupes within the process that minted the token; it cannot detect a retry across a fresh orchestrator process. |
| `read-attempt` | `<issue-n>` | Print the current attempt state (`stage=<s> count=<k> total=<t>`, plus a trailing ` key=<token>` when the marker carries one) from the most-recent attempt marker on the issue. Prints `stage= count=0 total=0` when no marker exists (a new issue). Always exits 0 unless the marker is corrupt (in which case it exits 1, fail-closed). Read-only; does not post a new comment. Internally fetches via `read-comments` (fully paginated, no 100-comment cap). |
| `read-comments` | `<issue-or-pr-n>` | Print every comment on an issue or PR as `{"comments": [...]}`, fully paginated (`gh api --paginate` for `github`, Link-header pagination for `github-api` — no 100-comment cap). Shared reader used internally by `read-attempt` and by `post-approval`'s duplicate-marker check (#172). Fail-closed: prints nothing and exits 1 on any page failure. |
| `check-attempt` | `<issue-n>` | Exit 1 (with reason on stderr) when either ceiling is already reached for the issue. Exit 0 otherwise. Does **not** record a new attempt — use `record-attempt` for that. Fail-closed: propagates a corrupt-marker exit 1 from `read-attempt`. |
| `assert-sync` | | Assert the orchestrator working tree is clean and current with `origin/<base_branch>`. **Dirty tree** (any uncommitted change) — exits 1, names the dirty files, instructs operator to commit or stash; this check runs *before* `git fetch origin` so the tree is never read in a mixed state. **Behind origin** — exits 1, prints both local and remote SHAs plus the commit gap, instructs `Run: git pull --ff-only`. **Diverged** (ahead and behind simultaneously) — exits 1, warns against force-push. **Ahead of origin only** — exits 0 but prints a stderr warning: *"pipeline-vcs: assert-sync: WARNING -- working tree is ahead of origin/<base> by N commit(s); non-isolated stages will read unpushed commits."* **Clean and level** — exits 0, no output. `base_branch` is resolved in order: `talos.pipeline.json` config key, then `git symbolic-ref refs/remotes/origin/HEAD`, then `main`. Provider-agnostic; runs before the VCS provider dispatch. |
| `has-spec` | `<issue-n>` | Exit 0 when the issue body IS a usable spec (contains an "acceptance criteria" heading with at least one checklist item, or carries the `spec:ready` label); exit 1 otherwise. GitHub only (`github` and `github-api` providers). Used by PM skip-when-spec-present logic to detect when an issue is ready for direct developer dispatch. |
| `slug-for` | `<title>` | Derive a 40-character-or-less branch slug from an issue title (lowercased, non-alphanumeric runs collapsed to `--`, trimmed). Provider-agnostic; used for consistent branch naming in both the PM skip path and developer `fix/issue-<n>-<slug>` / `feat/issue-<n>-<slug>` branches. |
| `post-approval` | `<pr-number> <role> [--body-file <path>] [--issue <n>]` | Fetch the current head SHA via `pr-head`, construct the `<!-- talos:approval sha=<sha> role=<role> -->` marker, append it as the last line of the comment body (from `--body-file` or an empty body when the flag is omitted), post the comment via `comment-pr`, and apply the role's approval label -- all in one atomic operation. Valid roles: `qa`, `reviewer`, `security`, `docs`; an invalid role exits 1. GitHub and `github-api` providers only; non-GitHub providers exit 1. This is the recommended way for every review stage to close the approval gate -- it eliminates the five failure modes observed when markers were constructed by hand: three missing the `<!-- -->` wrapper, one carrying a placeholder SHA, and one where the label was applied with no marker at all. **Duplicate-marker check (#172):** before posting, fetches every PR comment via `read-comments` (fully paginated) and looks for this exact marker as the last non-whitespace line of any comment. Found at the **same head SHA** — prints a stderr note and exits 0 **without posting again** (the approval label is still applied defensively, since `label-pr` is idempotent). Re-stamping at a **different** head SHA is a different marker string and always posts. The comment fetch itself failing exits 1 with nothing posted (fail-closed) — a partial page set is never mistaken for "no duplicate found". **Self-check (#549):** after the label, the verb runs `check-approval-sha` itself and prints one result line ending `stamp ok`; anything but "all approval labels are current" prints `stamp FAILED (check-approval-sha rc=N: ...)` and exits 1 (no label at all, or this role's own stale approval); another role's stale approval, which that role's gate clears, only shows as `stamp ok (stale elsewhere: <roles>)`. `--issue <n>` tags the calling stage's worktree for that issue (best effort; the main checkout is never tagged). |
| `mark-needs-owner` | `<n> <text>` or `<n> --body-file <path\|->` | Park a pending owner decision on issue or PR `<n>` (#345, part of #333): posts the text, a blank line and `<!-- talos:needs-owner -->` as one comment, then adds the label `pipeline:needs-owner` and prints `marked n=<n> comment=<posted\|existing>`. Same 65536-character / 120000-byte caps and closed-stdin refusal as `approve-pr`. A failed comment is exit 1 with no label call; the same text asked again while the item is still unanswered posts nothing and only ensures the label. GitHub only (`github` and `github-api`); `gitlab`, `azure` and `file` exit 2 with `not implemented for provider '<p>'` |
| `list-needs-owner` | `[--json] [--clear-answered]` | List the open items labelled `pipeline:needs-owner` (#345, part of #333), in number order: `needs-owner n=<n> kind=<issue\|pr> answered=<yes\|no> question=<text>` (`question=` is last: one line, control characters removed, at most 200 characters); `--json` prints an array of `{n, kind, answered, question}` (`[]` when none). `answered=yes` means a newer non-Talos comment from a trusted author; with `markers.verify_authors` (default true) an outsider never answers, and `talos:marker-authors-unverified` on stderr means the trust set could not be resolved. `--clear-answered` removes the label from every answered item and prints `cleared n=<n>`; without it no label changes. A failed fetch is exit 1 with empty stdout; non-GitHub providers exit 2. `scripts/pipeline-status-file.sh refresh` reads it with `--json` and never with `--clear-answered` |
| `edit-pr-body` | `<pr> --body-file <path\|->` | Replace the description of a PR (#455), for a fix round whose summary changed (never `gh pr edit`). The body comes only from a file or stdin, never argv. Same character and byte caps and placeholder guard as `comment-pr`; an empty body, an unreadable file or a failed write is exit 1; a bad flag exit 2. `github` (`gh pr edit --body-file -`) and `github-api` (PATCH `pulls/<n>`) only (else exit 2, "not implemented"). Prints `edited pr=<n> body`. `--dry-run` prints the planned call. |
| `upsert-pr-comment` | `<pr> --marker <name> --body-file <path\|->` | Create or edit in place the one marker comment on a PR (#381, part of #334), for example `--marker spend`: edits the newest comment by the authenticated user whose last non-blank line is the marker, and an identical body writes nothing. Prints the URL, then `upserted pr=<n> comment=created\|updated\|unchanged`. `github` and `github-api` only (else exit 2, "not implemented"); exit 1 for a bad body or a failed write, and under an Actions `GITHUB_TOKEN`; never a blind duplicate. `--dry-run` prints the planned calls. |

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
5. Remove `pipeline:blocked` from the issue and from its PR if one is open, then re-add `pipeline:ready` to re-enter the pipeline.

Do not edit the marker comment — partial edits may leave it in an ambiguous state. Delete and let the pipeline rewrite it.

**`talos:attempt` marker placement.** `read-attempt` requires the `<!-- talos:attempt ... -->` marker to be the **last non-whitespace line** of the comment body. A marker that appears earlier in the body — for example inside a GitHub Quote-reply block — is silently skipped (see Marker placement and trusted-author allow-list below for the full rule, which applies equally to `talos:attempt` and `talos:approval`).

**Approval-SHA model.** Each approval role stamps `<!-- talos:approval sha=<HEAD_SHA> role=<role> -->` in its verdict comment when posting a pass. At Step 4, `check-approval-sha` compares every present approval label's stamped SHA against the current PR head. If a stamped SHA is older than the current head, the tool runs `git diff <approval-sha>..<current-head>` to collect changed files, then intersects that set with the PR's own file set (computed via `git diff origin/<base>...<current-head>`, a three-dot diff against the base branch) to exclude files that arrived purely from a routine base-branch sync. Every file remaining in the intersection is checked against `merge.approval_waiver_paths`. A file touched by both the sync and the PR stays in the intersection and is evaluated normally. If the three-dot diff cannot be computed, the full two-dot set is used (fail-closed). If any non-waivable file remains after filtering (or the two-dot diff cannot be computed), the gate blocks the merge, strips the stale labels, and the orchestrator re-dispatches the affected stages. A human sees a PR comment listing which labels were stale and why; the fix is to re-run the affected stage (e.g. ask QA to re-approve after a source-code push). Re-dispatch is selective: `check-approval-sha --stale-list` reports only the roles that are actually stale, and the orchestrator re-runs only those — a docs approval whose delta is confined to `*.example` or other waived paths re-stamps `docs:done` against the current head without re-running the docs stage at all.

**Stale approvals — cheap delta re-stamp (`agents.restamp_model`, #258).** A stale role reported by `check-approval-sha --stale-list` already approved this PR once — only the delta since its approved SHA is new. Re-running that role's full stage (a fresh read of the whole diff) is needed only the first time a role reviews a PR; a re-review triggered purely by a later commit invalidating an earlier approval is a **re-stamp**: same role and role profile, dispatched with the `--stale-list` file list, the approved SHA, the current head, `diff-pr --stat`, and the role's previous verdict comment URL — review the delta only, run only the tests that map to the changed files, and either re-confirm the prior verdict (`post-approval <PR> <role>`, verdict `RESTAMP_PASS`) or post findings as usual (verdict `RESTAMP_FAIL`, which also strips the role's now-stale approval label so the next pass dispatches a normal full stage instead of another re-stamp, exactly like a first-time CHANGES/FINDINGS verdict). This happens both at Step 4's stale-approval gate (which already strips the stale label before dispatching) and inline in Step 3e whenever a fix round returns a role to a delta it already approved — see `skills/pipeline/refs/restamp.md` for the exact dispatch prompt. Configure the model tier for these cheap re-reviews with `agents.restamp_model` (global) or `agents.roles.<role>.restamp_model` (per role); resolution precedence is role restamp model → global restamp model → `agents.model` (the same volume tier a re-stamp should use by default, not the session default). `pipeline-events.sh cost` reports re-stamp dispatches in their own `restamp` column (verdict `RESTAMP_PASS`/`RESTAMP_FAIL`), separate from full-stage events, so re-stamp cost is visible next to full-stage cost per role.

**Marker placement and trusted-author allow-list.** Both `check-approval-sha` (for `talos:approval`) and `read-attempt` (for `talos:attempt`) enforce two independent rules on every marker they read:

1. **Last-line rule (unconditional).** The marker must be the **last non-whitespace line** of the comment body. A marker that appears anywhere else in the body — including inside a GitHub "Quote reply" block, a fenced code block, or any earlier paragraph — is silently skipped and does not satisfy the gate. This rule is unconditional: it is enforced regardless of whether `markers.trusted_authors` is configured. The reason is to prevent a GitHub Quote-reply from replaying an earlier approval; a quoted or copied marker must not reactivate a gate. For agents and operators posting approval comments, this means the `<!-- talos:approval sha=... role=... -->` line must be the final content of the comment with no non-whitespace text after it. `record-attempt` always writes its marker as the last line automatically; do not edit a `talos:attempt` comment in a way that appends content after the marker.

2. **Author trust check (`markers.verify_authors`, default `true` — #187).** With verification on (the default), the *effective* trust set is `markers.trusted_authors` (if configured) **unioned with the currently-authenticated identity**, inferred with no config required: `gh api user --jq .login` for the `github` provider, `GET /user` for `github-api`. A marker whose author is outside that effective set is silently skipped — this is what closes the "one agent posts all four approval markers itself" gap #128's opt-in allow-list left open by default. Every skip across a single invocation is reported once, in aggregate, as `talos:marker-authors-rejected authors=<comma list>` on stderr — never one line per marker.

   Set `markers.verify_authors: false` to opt back out: author checking is then skipped entirely and silently (fail-open, no warning), exactly as it always has been. Fail-open also still applies automatically, with a warning, when verification is on but no identity could be resolved (e.g. an insufficiently-scoped token) **and** `markers.trusted_authors` is unset — see below.

   **CI-bot caveat:** the inferred identity is whichever account's credentials Talos itself runs under. A bot login (`*[bot]`) is **never** trusted implicitly just for looking like a bot — it is trusted only if it *is* that resolved identity, or if it is listed explicitly in `markers.trusted_authors`. A GitHub Actions workflow using the default `github-actions[bot]` token, for instance, must add `"github-actions[bot]"` to `markers.trusted_authors` if a step in that workflow (rather than Talos's own dispatch) posts approval/attempt markers.

**`talos:marker-authors-unverified` marker.** When author verification cannot be enforced — `markers.verify_authors: false`, or verification is on but the identity is unresolved and `markers.trusted_authors` is unset/empty — both `check-approval-sha` and `read-attempt` fail open (marker accepted, gate proceeds normally). Only the latter case (unresolved identity, no explicit list) additionally emits `talos:marker-authors-unverified reader=<check-approval-sha|read-attempt>` on **stdout**, once per invocation, as a machine-readable "author provenance was not verified" signal; `markers.verify_authors: false` fails open silently, with no marker and no warning, since that is an explicit, deliberate opt-out rather than a degraded condition worth flagging.

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

**Placeholder guard (`comment-pr` / `comment-issue` — #306).** Both verbs refuse to post a body containing an unfilled template placeholder — a `${NAME}` or `$NAME` variable whose NAME is used in the comment templates (derived from shipped `templates/comments/*.md` plus the project's `comments.templates_dir`). The command exits 1 with a list of unfilled placeholders on stderr, nothing posted. This prevents a half-rendered comment template from reaching readers. Text inside a closed code fence or inline code is exempt from the check (an unclosed fence exempts nothing); other `$` text (`$5`, `${foo}`, `$PATH`) that does not match a known template variable also posts freely. A body longer than 65536 characters (GitHub's comment limit) is refused the same way before the check runs, and a body that is not valid UTF-8 is still checked rather than blocked. The guard runs in the shared pre-post path before provider dispatch, so it applies on every provider (`github`, `github-api`, `gitlab`, `azure`, and `file`).

**`post-approval` -- the recommended single-command path.** Use `post-approval <pr> <role> [--body-file <path>] [--issue <n>]` instead of constructing the marker by hand. It fetches the head SHA, builds the wrapped marker, appends it to the comment body, posts the comment, applies the label, and then verifies its own stamp with `check-approval-sha` (#549) -- all in one step. It prints one result line ending `stamp ok`, or `stamp FAILED (...)` with exit 1, so no stage runs a confirmation after it. `--issue <n>` tags the calling stage's worktree for that issue. Before `post-approval` existed, five distinct failure modes were observed: three markers posted without the `<!-- -->` wrapper, one with a placeholder SHA, and one where the label was applied without any marker. Using `post-approval` eliminates all five. Example (qa stage):

```bash
# Write your verdict to a file, then post-approval appends the marker automatically:
bash scripts/pipeline-vcs.sh post-approval 42 qa --body-file /tmp/qa-verdict.md
# Equivalent for a one-liner body (marker appended as the only line):
bash scripts/pipeline-vcs.sh post-approval 42 reviewer
```

All four role profiles (`agents/qa.md`, `agents/reviewer.md`, `agents/security.md`, `agents/docs.md`) already call `post-approval`. If you are operating outside those profiles, use this verb rather than the manual `pr-head` + `comment-pr` + `label-pr` sequence.

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

A sibling PR only counts when *its own* body carries a closing keyword (colon optional, e.g. `Fixes: #N`) or a `Part of #N` line for the same issue in one of the recognised reference forms above; a PR that merely mentions `#N` in prose (`See #N`, `Related to #N`, `owned by #N`) is not treated as a sibling.

This gate implements Rule 6: the legitimate final PR in a multi-PR issue says `Closes #N`. By the time it is ready to merge, all prior siblings are already merged — no open siblings exist, so the gate exits 0 and does not block. The gate only fires when a sibling is still open. An operator who sees this gate block should either merge the open sibling PRs first, or change this PR's body from `Closes #N` to `Part of #N` if it is not actually the final PR.

**Known limitation:** a lone PR that overclaims its deliverables (one PR carrying `Closes #N` with no sibling PRs at all) cannot be detected by this gate. Detecting overclaiming requires a work-ledger that records how many items the issue committed to; nothing in the pipeline maintains such a ledger in VCS mode today. This gate exclusively catches the sibling-still-open case.

**`talos:closing-keyword-unverified` marker.** When the PR body fetch or the open-PR list fetch fails (network error, insufficient token scope), `check-closing-keyword` exits 0 (fail-open) and prints `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` to stdout. The `reason` field is one of `pr-fetch-failed`, `sibling-fetch-failed`, `sibling-check-failed`, or `repo-unresolved` (emitted when the current repository cannot be resolved, so repo-scoped forms cannot be checked). Operators who see this marker in logs should confirm that any sibling PRs are in the expected state before the merge proceeds. No automatic pipeline action is triggered; the existing CI and approval gates still apply.

**`find-pr` anchored issue-number matching (behaviour change).** `find-pr <N>` previously used substring matching, so `find-pr 7` could match a branch named `fix/issue-71-x` or a PR body containing `#71`. Both checks are now anchored: branch names must match `(?:^|/)issue-N(?:-|$)` and body text must match `#N(?!\d)`. As a result, `fix/issue-71-x` is no longer returned by `find-pr 7`, and `#71` in a body no longer matches issue `7`. This affects Step 1 session-recovery reconciliation — the orchestrator's `find-pr` call will no longer adopt a PR whose branch or body merely shares a numeric prefix with the target issue number.

---

## Other harnesses: pi, Codex CLI, Gemini CLI, Antigravity, local models

Claude Code is the first-class harness (native subagents, worktree isolation),
but the pipeline itself is plain bash + markdown — any **agentic** CLI can
orchestrate it. The execution mode is chosen by `agents.subagents` and
`agents.runner` in `talos.pipeline.json`:

```json
{
  "agents": {
    "runner": "codex",
    "subagents": "auto",
    "model": "claude-haiku-4-5-20251001",
    "roles": { "reviewer": { "model": "claude-opus-5" } }
  }
}
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
  `pipeline-agent.sh`. `bash install.sh /path/to/your/repo` writes a
  marker-fenced Talos block into the repo's `AGENTS.md` (every harness gets it)
  telling the harness to follow the playbook and run role stages through the
  adapter:

  ```bash
  bash ~/.talos/scripts/pipeline-agent.sh <role> - <<'TALOS_<rand>'
  <stage prompt>
  TALOS_<rand>
  ```

  There is no fixed heredoc delimiter: the stage prompt carries issue-derived text that could contain the closing line, so the playbook (`skills/pipeline/SKILL.md`) uses `TALOS_<rand>` with `<rand>` 12+ random characters invented fresh for each spawn; the playbook renders the prompt to a file with `scripts/talos.sh prompt` and pipes it in (`bash scripts/pipeline-agent.sh <role> - < "$PROMPT_FILE"`, #468). The path is what the `AGENTS.md` block resolves (`.claude/talos/scripts` is the legacy vendored location).

  The adapter merges the role profile (frontmatter stripped) with the
  stage prompt and executes it via the runner configured in `talos.pipeline.json`
  (`codex` → `codex exec`, `pi` → `pi -p`, `custom` → `runner_cmd` on stdin). It
  looks for the profile in `.claude/agents/<role>.md`, then
  `.agents/talos/agents/<role>.md`, then the install (`pipeline-agent.sh
  --resolve-profile <role>` prints the one it picked).

**Install and start, per harness.** `--harness` selects installer glue and `agents.runner` selects the CLI that runs stages (see [Quickstart](#1-install)); the same two steps apply everywhere, then one start line:

```bash
bash talos/install.sh --global --harness codex   # once per machine; pi, cursor, opencode, gemini, antigravity, generic likewise
bash talos/install.sh /path/to/your-repo --harness codex   # per repo; commit AGENTS.md and talos.pipeline.json
codex "Read ~/.talos/skills/pipeline/SKILL.md and follow it"
```

- **Playbooks for any agent.** `install.sh --global` writes `~/.talos/skills/pipeline/SKILL.md` and `~/.talos/skills/setup/SKILL.md`, and the `AGENTS.md` block names them. Start the pipeline or the setup wizard with `Read ~/.talos/skills/<command>/SKILL.md and follow it`; Claude Code has `/talos:pipeline`, `/talos:setup` and `/talos:resume` from either install path (the old `/pipeline` and `/pipeline-setup` work as aliases until v0.20).
- **pi, Codex CLI, Cursor, OpenCode.** `--global --harness <name>` also writes pointer skills `talos-<command>/SKILL.md` to `${TALOS_AGENTS_HOME:-~/.agents}/skills`, a directory those tools scan. A `SKILL.md` already there that is not a Talos pointer is never overwritten. Gemini CLI gets none: its file tools are confined to the workspace.
- **Any other agent.** Pass any `--harness` name (or `generic`), set `agents.runner: custom` and `agents.runner_cmd` (the prompt arrives on stdin), and start it with the plain-text line above. The `AGENTS.md` block is enough for any agent that reads `AGENTS.md`.

The user guide's [Install and start, per harness](docs/user-guide.md#install-and-start-per-harness) has one table with each harness's writes, runner, start line and what is verified versus unverified.

### Per-role model selection (`agents.model` and `agents.roles.<role>.model`)

**Applies to the native path (`subagents: true`) only.** The adapter path (`subagents: false`) routes by role using `$TALOS_ROLE` in `runner_cmd` — see below.

**The Talos config is the only place a role's model is set.** The shipped `agents/*.md` files carry no `model:` line, so there is no second source that can disagree with your config. When spawning each subagent the orchestrator resolves the model in three steps:

1. `agents.roles.<role>.model` — role-specific override.
2. `agents.model` — global model for all stages not explicitly overridden.
3. Neither present — omit `model:` entirely; the subagent inherits the session model.

**Two config layers.** Set your routing once for every repo in a user-level file, `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json`; a repo's own `talos.pipeline.json` is merged over it, key by key, and wins where both set the same key. Only the `agents.*` subtree is read from the user-level file (board, merge, issue and verify settings describe a repo, not a user); any other key there is ignored with one warning. **Every `agents.*` key in the user-level file applies to every repo you run Talos in** -- not just models but `agents.runner`, `agents.runner_args` and `agents.roles.<role>.runner_cmd` too, and the adapter path executes `runner_cmd` as a shell command. Put only settings and commands you trust in every repo there; a repo's own config can override a key but cannot remove the file's other keys. A missing, unreadable or malformed user-level file behaves as absent. The layer sits under whichever project config is found, including one named by `$PIPELINE_CONFIG`, and every chain below (`restamp_model`, `effort`, per-role `runner`) is evaluated on the merged config.

```json
// ~/.talos/talos.pipeline.json -- applies to every repo
{
  "agents": { "model": "sonnet", "roles": { "security": { "model": "opus" } } }
}
```

```json
// <repo>/talos.pipeline.json -- this repo only: qa runs on haiku
{
  "agents": { "roles": { "qa": { "model": "haiku" } } }
}
```

Run `/talos:setup` (or the setup skill in another agent) to be asked once how you want models assigned (one model for every role, one per role, or leave unset) and have the answer written to the user-level file. `bash scripts/pipeline-agent.sh --resolve-all` prints one line per role — model, re-stamp model, and which layer decided it (`project`, `global` for the user-level file, or `session default`) — and, when a `runner` / `runner_cmd` is set for a role (a user-level one applies to every repo), appends `runner=… runner_origin=…` and `runner_cmd_origin=…` with the layer that supplied it, then a TAB and `runner_cmd=…` as the last field (the value is free text and may hold spaces, so `cut -f2-` returns it whole). It also warns when a role file Claude Code would load still carries a `model:` frontmatter line. `--resolve <role>` keeps its one-line `runner=… model=… effort=…` output.

**Model names.** A value is a full model ID or one of the aliases `opus`, `sonnet`, `haiku`, stored and passed through as typed. If your harness's Agent tool accepts only aliases, the orchestrator maps a full ID to its family alias at spawn time; the config value is never rewritten.

**Upgrading from 0.18.x.** Earlier versions shipped `model: opus` (and `model: haiku` for docs) in the agent frontmatter, so a repo with no `agents` block ran eight roles on Opus. That line is gone: if you never configured models, every role now runs on the session model until you run `/talos:setup` (or add `agents.model` / `agents.roles.<role>.model` yourself). `install.sh --global` stays non-interactive and prints one hint line when no user-level config sets a model. Re-run it after upgrading so `~/.claude/agents/` and `~/.talos/agents/` lose the old line.

**Judgement vs. volume (the primary use case):** implementation work is high-volume and verifiable; review work requires judgement. Set a cheap model globally and a quality model for the stages that matter:

```json
{
  "agents": {
    "runner": "claude",
    "model": "haiku",
    "roles": { "reviewer": { "model": "opus" }, "security": { "model": "opus" } }
  }
}
```

Two overrides rather than eight entries. A new role added later automatically inherits `agents.model` rather than silently falling back to the session model.

**Global override (all stages, one model):**

```json
{ "agents": { "model": "sonnet" } }
```

**Backwards compatibility:** a config with no model key at either level omits `model:` from each Agent spawn call, so every role inherits the session model.

### Per-role reasoning effort (`agents.effort` and `agents.roles.<role>.effort`)

A finer lever than a model swap alone (#271): `low` | `medium` | `high` | `max`, resolved role-first exactly like `agents.model` — `agents.roles.<role>.effort` wins, else `agents.effort`, else empty (the runner's own default; omitted behaves byte-identically to earlier versions). `bash scripts/pipeline-agent.sh --resolve <role>` prints it alongside `runner`/`runner_cmd`/`model`. An invalid value (anything other than the four above) is rejected with a stderr warning and treated as unset — it never reaches a runner.

Applying the resolved value differs from `model`, because there is no per-spawn Agent tool parameter for effort, and the orchestrator never edits a tracked file at spawn time. On the **adapter path** (`codex` / `gemini` / `antigravity` / `custom`), `pipeline-agent.sh` applies it for real: it exports the resolved value as `TALOS_EFFORT` in the environment, the same way `TALOS_ROLE` is exported, so a `runner_cmd` can map it onto that CLI's own effort/reasoning flag. On the **native `claude` path**, this config key is advisory only — the mechanism Claude Code exposes for subagents is the dispatched agent definition's **frontmatter `effort:` field**, and that field is only ever set by committing it directly in `agents/<role>.md` (or its repo-override copy). If the resolved config value is non-empty and does not match what the role's committed frontmatter says, the orchestrator relays the one-line notice printed by `bash scripts/pipeline-agent.sh --check-effort <role>` (nothing when config is empty or matches) and spawns anyway — it does not rewrite the file:

```json
{
  "agents": {
    "effort": "medium",
    "roles": { "developer": { "effort": "high" } }
  }
}
```

```yaml
# agents/developer.md frontmatter — this is what actually changes effort
# on the native claude path:
---
model: claude-sonnet-5
effort: high
---
```

**Re-stamp effort (`agents.restamp_effort` / `agents.roles.<role>.restamp_effort`):** same chain shape as `agents.restamp_model` — role restamp effort → global restamp effort → `agents.effort` — for the cheap delta re-review dispatch described under "Stale approvals — cheap delta re-stamp" below.

### Per-role runner override (`agents.roles.<role>.runner` / `.runner_cmd`)

`agents.runner` picks one backend for the whole pipeline. `agents.roles.<role>.runner` (and `.runner_cmd`) overrides it for a single role, on **both** execution paths — resolved role-first: the role's own key wins when set, else `agents.runner` (default `claude`); `runner_cmd` follows the same precedence and is only read when the resolved runner is `custom`. `agents.runner_args` stays global-only — there is no `agents.roles.<role>.runner_args`.

```json
{
  "agents": {
    "runner": "claude",
    "roles": {
      "qa": { "model": "claude-opus-5" },
      "reviewer": { "runner": "custom", "runner_cmd": "..." }
    }
  }
}
```

On the native path (Claude Code, `subagents: true`), a role whose effective runner is `claude` still spawns as a native subagent; a role whose effective runner is anything else is dispatched via `bash scripts/pipeline-agent.sh <role> -` with the stage prompt on stdin (a heredoc whose `TALOS_<rand>` delimiter is invented fresh per spawn) instead — the orchestrator makes this decision per role, so the rest of the pipeline keeps running natively. On the adapter path, `pipeline-agent.sh` already resolves the same precedence internally, so no config change is needed to get the per-role behaviour there.

Run `bash scripts/pipeline-agent.sh --resolve <role>` to see what a role will actually use — it prints `runner=<r> runner_cmd=<c> model=<m> effort=<e>` without running anything, and it is the same resolution the orchestrator and `pipeline-agent.sh` itself use, so it never drifts from the real dispatch.

**Second opinion on a local model:** point one role at a llama.cpp-served model while the rest of the pipeline stays on the default runner — e.g. give `security` (or any single stage) an independent pass through a local model without rerouting everything:

```bash
# --jinja enables tool/function calling — agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

```json
{
  "agents": {
    "runner": "claude",
    "roles": {
      "security": {
        "runner": "custom",
        "runner_cmd": "OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local aider --model openai/local --yes-always --no-auto-commits --message $(cat)"
      }
    }
  }
}
```

Every other role keeps running natively; only `security` pays the local-model round trip, and it costs nothing per PR since the endpoint is local.

**pi:** run `install.sh --global --harness pi`, which writes the pointer skills pi scans in `~/.agents/skills` (the `AGENTS.md` block also names the playbooks), then `install.sh <repo>`. Set `agents.subagents: false` and
`agents.runner: pi`, then in a pi session say `Read ~/.talos/skills/pipeline/SKILL.md and follow it`. The playbook's
Harness-compatibility section handles the inline mode. Talos makes no claim about where pi keeps its settings. The runner conformance test covers `pi -p` only; pi's inline mode is not covered by it.

**Google Antigravity:** `install.sh <repo>` writes the same `AGENTS.md`
block as for every harness. Per its documentation, Antigravity reads both `AGENTS.md` and `GEMINI.md`, cumulatively, with no stated precedence (docs only; not run by Talos). `install.sh --global --harness antigravity` writes `~/.talos` only. Set `agents.runner: antigravity` in
`talos.pipeline.json` to route role stages through `agy -p`.

**Local models:** the `custom` runner accepts any command, so a local-model
pipeline works by pointing `runner_cmd` at an agentic CLI backed by Ollama,
llama.cpp, or similar: run `install.sh --global --harness generic` (or the CLI's own name), set `agents.runner: custom` and `agents.runner_cmd`. The hard requirement is *agentic*, not *cloud*: whatever
runs a stage must be able to execute shell commands and edit files — a bare
chat endpoint can generate text but cannot open a PR. Expect stage quality to
track model capability; the validator/QA gates exist precisely to catch weak
stage output.

`TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, and `TALOS_WORKTREE_PATH` identify the current stage across both execution paths. How they arrive depends on the path:

- **Adapter path (`subagents: false`, `pipeline-agent.sh`):** all three are exported as real shell variables to every `runner_cmd` invocation. `TALOS_ISSUE_NUMBER` is the issue number passed by the caller via `TALOS_ISSUE=<N>`; it is the empty string when the caller does not set `TALOS_ISSUE`. **`TALOS_ISSUE` must be a plain non-negative integer (digits only) or unset** — any other value (shell metacharacters, whitespace, letters) causes `pipeline-agent.sh` to exit 2 with a diagnostic before the runner is invoked. `TALOS_WORKTREE_PATH` is `$PWD` at the time `pipeline-agent.sh` was invoked. These are real shell exports — verify scripts inherit them automatically.

- **Native path (`subagents: true`, Claude Code):** there is no shared shell environment between the orchestrator and a subagent. `TALOS_ISSUE_NUMBER` and `TALOS_WORKTREE_PATH` are injected into the stage's **task prompt**, and the stage runs every `verify:` command through `bash scripts/pipeline-verify.sh --issue <N> --worktree <path> -- <cmd>` (#186) instead of exporting them by hand. The wrapper resolves the identity itself — from `--issue`/`--worktree`, then `<toplevel>/.talos/env` (`git rev-parse --show-toplevel` of the current worktree, so it still resolves from a subdirectory; written by `pipeline-worktree.sh create` and parsed, never sourced), then whatever is already in the environment — exports it, and prints `talos:verify issue=<N> worktree=<path>` on stderr so a transcript shows which identity a run actually used. This makes the mechanism **mechanical, not instruction-based**: the identity is set by the wrapper regardless of whether the stage remembers to `export` anything.

**`TALOS_WORKTREE_PATH` under `isolation: branch` or `isolation: checkout`:** this variable is not meaningful — there is no per-issue worktree. Stage prompts under `branch` mode call `pipeline-verify.sh` without `--worktree`; verify scripts that rely on it should still guard with `[ -n "${TALOS_WORKTREE_PATH:-}" ]` before using the value. Do not fabricate a path.

Verify scripts can self-check their environment on both paths — the adapter path exports the vars directly, and the native path's `pipeline-verify.sh` wrapper exports them before running anything:

```bash
if [ "${TALOS_ISSUE_NUMBER:-}" != "$EXPECTED_ISSUE" ]; then
  echo "ERROR: wrong environment (expected $EXPECTED_ISSUE, got '${TALOS_ISSUE_NUMBER}')" >&2
  exit 1
fi
```

`TALOS_ROLE` lets you route by role without a wrapper script. For the judgement-vs-volume split:

```json
{
  "agents": {
    "runner": "custom",
    "runner_cmd": "case \"$TALOS_ROLE\" in developer|qa) exec pi -p --provider ds4 --model deepseek-v4-flash \"$(cat)\" ;; *) exec claude -p \"$(cat)\" ;; esac"
  }
}
```

Example — llama.cpp serving an OpenAI-compatible endpoint:

```bash
# --jinja enables tool/function calling — agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

Then drive stages through any OpenAI-compatible agentic CLI, e.g. Aider:

```json
{
  "agents": {
    "runner": "custom",
    "runner_cmd": "OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local aider --model openai/local --yes-always --no-auto-commits --message $(cat)"
  }
}
```

Or configure Codex CLI with a local provider profile
(`~/.codex/config.toml` → `[model_providers.llamacpp]`
`base_url = "http://localhost:8080/v1"`) and use the named runner:

```json
{ "agents": { "runner": "codex", "runner_args": ["--profile", "local"] } }
```

Pick a model that supports function calling (Qwen coder-class or similar) —
models without it will chat about the task instead of executing it. For a
fully offline pipeline, combine a local runner with `vcs.provider: file`.

---

### Runner failover (`agents.fallback`)

With `agents.fallback` set, `pipeline-agent.sh` reruns a stage that died of a provider error on the next runner in the chain, with the same prompt. Every runner exit is `ok` (exit 0), `provider` (exit 75 from any runner, or a recognised, line-anchored claude 429, quota, overload, auth or network error, including the "You've hit your ... limit" spend-limit line captured from a real run (#540); the other patterns are **UNVERIFIED**, every other runner ships exit-75-only) or `task` (anything else, including a bare `429` in the model's prose). Only `provider` fails over; it never counts toward `limits.max_fix_attempts` or `limits.max_total_dispatches`. A failed provider is recorded in `.talos/providers.json` (deliberately in-tree at `<repo-root>/.talos/`, the parent of the git common dir, so every linked worktree shares one file; auto-ignored via `.git/info/exclude` before its first write, never via a tracked `.gitignore` commit, #517; atomic, under `with_lock`; unreadable means nothing is down) for `agents.provider_down_s` seconds, `talos:failover role=<r> from=<a> to=<b> reason=<class:detail>` goes to stderr, and a `failover` event (role `orchestrator`) is logged. A stage that already wrote (a successful `pipeline-vcs.sh` comment, PR or approval verb, or a moved `refs/remotes` ref) is never rerun: exit `69`. Exit `69` is also chain exhausted or every runner down; the orchestrator then sets `pipeline:blocked` and posts blocked.md naming `agents.fallback`. On the native Claude path nothing re-dispatches automatically: `pipeline-agent.sh --classify <runner> <rc> <file|->` and `--mark-down <runner> <class:detail>` let the orchestrator block with a resume note. Details, the classification table and the write guard are in [docs/user-guide.md](docs/user-guide.md#runner-failover-agentsfallback-418).

### Token usage on adapter runs (#420)

`pipeline-agent.sh` records the token usage of every runner attempt in the stage event, so `pipeline-events.sh cost`, `pipeline-budget.sh check` (`limits.tokens_per_issue`) and `talos-status.sh --line` count adapter and failover runs instead of listing them as `unrecorded`. `tokens` is input + output + cache-creation tokens, **excluding cache reads**, for every runner. The event's `runner` and `model` are those that ran, including a role routed with `agents.roles.<role>.runner` and a failover runner. Where a runner reports nothing usable the event carries `null`, never `0`.

- **`claude`** runs with `--output-format json` (`agents.capture_usage`, default `true`); only the message text is printed, exactly as without it. Turn it off with `agents.capture_usage: false`, or by putting `--output-format` in `agents.runner_args`.
- **`custom`** reports usage through a sidecar: `TALOS_USAGE_FILE`, a per-attempt path exported to `runner_cmd` next to `TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, `TALOS_WORKTREE_PATH` and `TALOS_EFFORT`, in a fresh temp directory that is removed when the attempt ends. Write one JSON object, every key optional: `{"tokens": 1234, "tool_uses": 7, "model": "qwen2.5-coder"}`. `tokens` and `tool_uses` must be integers of at most 15 digits (no negatives, booleans, floats or strings) and `model` must match `[A-Za-z0-9._:-]{1,100}`; anything else reads as `null`. A local model with no price still records its tokens.
- `codex`, `gemini`, `antigravity` and `pi` record `null`: none has a verified, committed capture yet. Pi inline mode never calls `pipeline-agent.sh`.
- Each attempt prints `talos:usage runner=<r> tokens=<N|null>` on stderr. After a failover, a failed attempt that reported usage gets its own `stage_attempt` event (verdict `FAIL`, its own runner); the final attempt keeps `stage_complete`.

The mapping per runner and the caveats are in [docs/user-guide.md](docs/user-guide.md#token-usage-on-adapter-runs-420).

## Worktree lifecycle

**Policy:** a stage's working copy lives exactly as long as the stage needs it — every developer, QA, reviewer, security, and docs worktree (and its scratch branch) is removed as soon as the PR it belongs to merges or closes, and anything left behind that doesn't belong to an issue still in the queue or with an open PR is garbage, removed on sight regardless of dirty/unpushed state.

Only the developer worktree identifies itself by naming convention (`fix|feat/issue-<N>-...`); the other stages get a Claude Code harness `agent-*` worktree with no issue number in its name, so the stage's own first verb writes `<worktree>/.talos/env` (#549): `pipeline-criteria.sh qa-run <N> <pr>` for QA, `post-approval <PR> <role> --issue <N>` for reviewer, security and docs; no profile runs a separate `tag` step, and a stage that stops before either is swept as unidentified garbage). `remove <N>` (post-merge) and `sweep [<open-id>...]` (Step 1 startup backstop and Step 5 end-of-run) both use this tag — or the naming convention — to find every worktree for an issue, developer and harness alike; `sweep` additionally deletes local branches that are not main/master/base, don't track a live remote, and aren't the head of an open PR, and prints `talos:worktree-sweep removed=<n> kept=<n> freed=<size>`. `pipeline-worktree.sh status` reports current worktree/dirty/branch counts and total `.claude/worktrees` disk usage.

**Checkpoint and handoff (#419).** `bash scripts/pipeline-worktree.sh checkpoint <N> [--local] [--runner R] [--model M]` WIP-commits (`wip(#<N>): checkpoint`, no `[skip ci]`) and pushes the issue branch, then refreshes `<git common dir>/talos/handoff/<N>.json` — the run-state directory, outside every git tree (#517; the old `<repo-root>/.talos/handoff/` was inside the tree in a normal clone); the optional JSON object on stdin carries `stage`, `criteria_done`, `criteria_remaining` (1-based positions in the spec's acceptance list), `last_verify` (`cmd`, `rc`, failing test names), `decisions` and `next_step`. The developer runs it after each green step (targeted tests only); a fix round passes `--local` so the open PR's head does not move. The file is mode 0600 in the 0700 run-state directory, never staged or pushed, this machine only, capped at 8 KiB, and a credential-shaped value is rejected, never redacted. `handoff <N>` prints it (exit 1 when absent, invalid or stale); `remove <N>` deletes it, `sweep` does not. Exit codes: 0 ok, 1 refused (the branch must be `(fix|feat)/issue-<N>-`), 2 usage, 3 push failed (commit kept, handoff written), 4 handoff rejected. See the [user guide](docs/user-guide.md#checkpoint-and-handoff).

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

**Contributor note: prompt files.** `agents/`, `.claude/agents/` and `.agents/talos/agents/` hold the role profiles, which are prompts that run with tool access, not documentation. A change under any of them needs prompt-level review (what the role is told to do, which commands it may run, what it treats as data), not only a diff read, and the test suite does not exercise them.

Test files run concurrently by default, in a bash job pool sized to the CPU
count (`nproc`, then `sysctl -n hw.ncpu`, then a fallback of 4). Override with
`-j N` or `TALOS_TEST_JOBS=N`. A file that cannot run in parallel (shared
fixtures, fixed ports) opts out with a full-line `# SERIAL` marker comment
anywhere in the file; marked files run sequentially, after the parallel
batch. `--quiet` (or `TALOS_TEST_QUIET=1`) prints one line per file
(pass/fail/cached) and shows full output only for failing files.

To run only the tests that cover a set of changed files instead of the whole
suite, use `--for` (repeatable) or `--changed`:

```bash
bash tests/run-tests.sh --for scripts/pipeline-worktree.sh   # -> test-worktree.sh
bash tests/run-tests.sh --changed                             # git diff vs origin/main + uncommitted
bash tests/run-tests.sh --changed HEAD~3                      # explicit base ref
bash tests/run-tests.sh --strict --changed                    # skip unmapped paths instead of falling back
```

`--strict` modifies `--for`/`--changed`: a path that would otherwise fall
back to the full suite (no convention mapping, or a `scripts/pipeline-<name>.sh`
with zero matches) is instead skipped, with a `run-tests.sh: --for: no test
mapping for '<path>' (skipped)` note on stderr -- the full suite never runs
under `--strict`. If every path ends up skipped (or `--for`/`--changed`
produced none to begin with), the resulting selection is empty:
`run-tests.sh: no targeted tests selected` is printed and the run exits `3`,
a distinct code so an empty selection is never mistaken for a pass. Without
`--strict`, the default behaviour (fail-safe fallback to the full suite for
any unmapped path) is unchanged.

Each path is mapped to test files by convention plus any test that references
the script: `scripts/pipeline-<name>.sh` maps to `tests/test-<name>*.sh`
unioned with every `tests/test-*.sh` file whose contents mention the script's
basename (a fixed-string `grep -l` sweep of the whole suite -- e.g.
`scripts/pipeline-vcs.sh` selects `test-vcs.sh` by convention plus every
other test file, such as `test-verb-parity.sh`, that names
`pipeline-vcs.sh`); `tests/test-*.sh` maps to itself; `agents/*.md`,
`skills/**`, and `templates/**` map to `tests/test-skill-names.sh` plus any
test file whose contents reference that path's directory. `tests/stubs/*`,
`tests/helpers.sh`, `tests/run-tests.sh`, `talos.pipeline.*`, `.github/**`,
and any path matching no rule above fall back to the full suite (fail-safe,
with a one-line stderr note for the unmapped case). The selected file list is
printed before running, and both flags compose with `--quiet`, `-j`,
`--no-cache`, and `--repeat`.

Passing runs are cached under `.talos/test-cache/` (gitignored), keyed on the
test file's own content plus a whole-set hash of **all tracked files except**
`tasks/**`, `.github/**`, and `.gitignore` (each
proven, via a `grep -l` sweep of every `tests/test-*.sh`, to be read by no
test) -- touching any other git-tracked file, including `tests/run-tests.sh`
itself, invalidates every cached result. Only tracked files are hashed;
untracked files are ignored by design and cannot invalidate the cache. A
cache hit prints `CACHED tests/<name>.sh` and skips re-running the file; a
failing file is never cached. `--no-cache` ignores the cache entirely (reads
and writes); CI always runs with `--no-cache`. If neither `sha256sum` nor
`shasum` is available, caching is disabled outright (with a warning) rather
than key on a degraded hash.

CI (`.github/workflows/tests.yml`) runs the suite on Ubuntu for every PR push
and on the full Ubuntu + macOS matrix for every push to `main` -- see the
[CI](#ci) section below for why. Test sandboxes unset Talos and Claude
environment variables (`TALOS_HOME`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_CONFIG_DIR`,
etc.) to isolate per-test configuration and prevent ambient settings from
leaking into test runs.

To reproduce a nondeterministic ("flaky") failure locally, re-run the same
selection under load with `--repeat N`: it runs the selected files N times,
stopping at the first iteration that fails (that iteration's full log is
printed, and the `RESULT` line names it, e.g. `RESULT: repeat 2/20 FAILED`).
`--repeat` implies `--no-cache` -- a cache hit on iteration 2+ would just
skip the re-run the flag exists for. `N=1` (the default) is a no-op: no
iteration banner, output unchanged from omitting the flag.

```bash
bash tests/run-tests.sh -j 8 --repeat 20 test-per-agent-env.sh   # one file, stress
bash tests/run-tests.sh -j 8 --repeat 3                          # whole suite, stress
```

### Nightly canary (real API)

Every test above stubs `gh`/`curl`/`glab`/`az` -- none of them touches a real
API, so schema drift in GitHub's REST responses or gh CLI output would pass
CI and fail in production. `.github/workflows/canary.yml` runs nightly (and
on demand via `workflow_dispatch`) and closes that gap with two jobs:

- **`base-currency`** -- runs `tests/run-tests.sh --no-cache --base-ref
  origin/main --quiet` on a full-history checkout, so the base-currency
  warning (a branch behind `origin/main`) is exercised in CI, not just
  locally.
- **`real-api`** -- `tests/canary/run.sh` bootstraps the Talos labels into
  the sandbox repo (`scripts/bootstrap-labels.sh`, idempotent), then drives
  a minimal pipeline flow (`create-issue` → `label-issue` → `view-issue
  --spec` → a trivial branch + commit + PR → `post-approval qa` →
  `check-approval-sha` → `pr-mergeable` → `check-pr-files`) against that
  real, dedicated sandbox repository, once for each of the `github` and
  `github-api` providers, then cleans up everything it created -- on
  success or failure, via a `trap ... EXIT`.

Two one-time setup steps enable `real-api` (it is a clean no-op, printing
`talos:canary-skipped reason=...` and exiting 0, until both are done):

1. Create a dedicated sandbox repository the canary is free to spam with
   throwaway issues/PRs -- never point it at a real project repo. It can
   start with zero labels; the canary bootstraps them itself.
2. On the *Talos* repo (not the sandbox), add repository variable
   `TALOS_CANARY_REPO` (`owner/repo` of the sandbox) and repository secret
   `TALOS_CANARY_TOKEN` -- a fine-grained PAT scoped to the sandbox repo with
   `issues`, `pull requests`, and `contents` write access.

`tests/test-canary.sh` runs the same script against `tests/stubs/` (no
network) -- happy path, a failing step (asserting cleanup still runs), and
the missing-repo/token skip path.

### CI

`templates/ci/github-tests.yml` is a **recommendation**, not something Talos
enforces -- CI cadence and cost are your repo's policy. It skips docs-only
pushes (`paths-ignore`), cancels superseded runs on the same branch
(`concurrency` + `cancel-in-progress`), runs pull requests on `ubuntu-latest`
only, and runs the full `ubuntu-latest` + `macos-latest` matrix on pushes to
the base branch (so cross-OS drift is caught just after merge instead of
before it). `/talos:setup` offers to write it to
`.github/workflows/tests.yml` when no existing workflow already runs your
test suite, and never edits a workflow that already exists. This repo's own
`.github/workflows/tests.yml` dogfoods it.

**Caveat:** if `merge.required_checks` names a job that this template no
longer runs on PRs (macOS, e.g. `test (macos-latest)`), **remove it -- or
the merge gate will wait forever**: QA's CI-wait loop
(`pipeline-vcs.sh pr-checks-required`) will wait for a check that never
appears on the PR until `verify.ci_wait_s` elapses, then fail closed, on
every single PR. Under this template, only `test (ubuntu-latest)` is safe to
name in `merge.required_checks`. This repo's own `talos.pipeline.json`
dogfoods that too -- `merge.required_checks` names only `test
(ubuntu-latest)`.

---

## Credits

Talos is a distillation of [Daedalus](https://github.com/benmarte/daedalus) — a full-featured Hermes plugin with a 9-agent roster, kanban board, dashboard, and per-project config. If you need multi-project management, a dashboard UI, or a long-running daemon, use Daedalus. If you want a drop-in, zero-infrastructure pipeline driven from a Claude Code session — supporting GitHub (battle-tested), GitLab, Azure DevOps, and a local file mode — this is it.
