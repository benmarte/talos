# Talos User Guide

Complete setup and usage reference for every supported harness. For
architecture and internals, see the [README](../README.md).

Talos is an autonomous issue→PR pipeline: you label a GitHub issue (or add a
checklist item in file mode), and an LLM orchestrator drives it through
validate → spec → implement → QA → review → security → docs → merge, posting
progress as issue/PR comments and threaded Slack/Discord messages along the way.

---

## Contents

1. [Features](#features)
2. [Prerequisites](#prerequisites)
3. [Environment variables](#environment-variables)
4. [Setup: Claude Code](#setup-claude-code) (recommended)
5. [Setup: pi](#setup-pi)
6. [Setup: Codex CLI](#setup-codex-cli)
7. [Setup: Gemini CLI](#setup-gemini-cli)
8. [Setup: Google Antigravity](#setup-google-antigravity)
9. [Setup: local models (llama.cpp, Ollama)](#setup-local-models-llamacpp-ollama)
10. [Harness feature matrix](#harness-feature-matrix)
    ([Install and start, per harness](#install-and-start-per-harness))
11. [Running the pipeline](#running-the-pipeline)
12. [Config reference](#config-reference)
13. [Troubleshooting](#troubleshooting)
14. [FAQ](#faq)

---

## Features

- **Full issue→PR lifecycle** — validator, PM (spec), developer, QA, reviewer,
  security, docs, and orchestrator roles, each with its own agent definition
  and quality gate. Label state machine (`pipeline:ready` → … → merged) tracks
  progress on the issue itself.
- **Optional planner role** (off by default) — detects epic issues (via `epic`
  label, ≥ 4 checklist items, or body ≥ 2000 chars) and decomposes them into
  dependency-ordered sub-issues via `create-issue`. Independent sub-issues are
  labelled `pipeline:ready` immediately; dependent sub-issues are unlabelled and
  auto-unblocked when their predecessor closes. Enable with
  `roles.planner: true` in `talos.pipeline.json`.
- **Provider-agnostic VCS** — GitHub (battle-tested), GitLab, Azure DevOps, or
  **file mode** (a local `plan.md` checklist; no VCS, no network — works fully
  offline).
- **Harness-agnostic execution** — Claude Code with native parallel subagents,
  or any agentic CLI (Codex, Gemini, custom/local) via the
  `pipeline-agent.sh` adapter.
- **Rich notifications** — Slack (Block Kit), Discord (embeds), Teams
  (Adaptive Cards), Buzz (Nostr kind:9 via `nak`). One neutral markdown
  template per event, transpiled into each platform's native syntax. Per-issue
  threading (bot-token mode; NIP-10 replies on Buzz; Teams cannot thread —
  webhook-only), clickable issue/PR links.
- **Stage comments on GitHub** — every role posts its verdict/findings on the
  issue or PR, so the audit trail lives where the code lives.
- **GitHub Projects v2 board** — optional automatic Status column updates.
  `scripts/bootstrap-board.sh` provisions the required Status options
  (id-preserving, idempotent) so the columns exist before the pipeline needs
  them; it also validates Azure states and GitLab's board-relied-on labels.
- **Safety limits** — `max_fix_attempts` before an issue is marked
  `pipeline:blocked` for human attention; human-only gates for destructive
  actions; **forbidden-files gate** blocks merging PRs that touch secret-like
  paths (`.env`, `*.pem`, `.npmrc`, `credentials.json`, …; 30 defaults, matched
  case-insensitively; `merge.forbidden_files`).
- **Rate-limit retry with backoff** — every network call in every provider
  (`glab`/`az` CLI invocations, and the GitHub providers' `gh api` / `curl`
  requests) automatically retries on HTTP 429, a GitHub secondary rate limit,
  or a matching CLI rate-limit error, honouring `Retry-After` when supplied
  (capped at 60s) and otherwise backing off exponentially (2s, doubling, capped at 60s), up
  to `limits.max_retries` (default `5`, must be a non-negative integer) times. Everything else (401, 404,
  422, …) still fails immediately with no added delay. `--dry-run` never
  sleeps or retries.
- **Human-merge mode** — `merge.auto: false` runs every stage and gate but
  stops at `pipeline:approved` and hands the final merge to a human (for
  protected integration branches).
- **Session recovery** — on startup the orchestrator adopts PRs left by an
  interrupted session, heals merged-but-open issues, sweeps orphaned
  worktrees, and reports stale blocked work.
- **Backlog controls** — `p0`/`p1`/`p2` priority labels order dispatch;
  `skip-qa` (human-applied) bypasses review gates for docs-only/emergency
  changes (CI and forbidden-files still enforced); `spec:ready`
  (human-applied) force-skips the PM stage for an issue whose body is already
  a usable spec; flaky CI is retried up to 2× per head SHA before waiting on a
  human.
- **Token-lean PM skip** — when an issue's body already has an "acceptance
  criteria" heading with a checklist item (or carries `spec:ready`), the
  orchestrator skips spawning a PM subagent entirely and advances straight to
  `pipeline:dev` (`roles.pm_skip_when_spec_present`, default `true` — see
  [Config reference](#config-reference)).
- **Token-lean docs** — the docs subagent is dispatched only when the PR
  changes `README.md`, `docs/**` (CHANGELOG and status fragments excluded) or
  `scripts/pipeline-defaults.sh` (a config key); otherwise
  `talos.sh docs-gate` stamps `docs:done` itself ("no docs-relevant changes")
  and no LLM runs. The developer writes the CHANGELOG line in its own PR. A
  dispatched docs stage reads only the changed doc paths, not the full PR diff
  (`roles.docs_mode`, default `auto` — see
  [Config reference](#config-reference)).
- **Compact stage handoff** — `pipeline-vcs.sh view-issue <n> --spec` prints
  the issue body plus only the latest `**PM spec:**` comment, dropping every
  `<!-- talos:` marker, stage-verdict, and other comment, so a busy thread
  (10+ comments by the time security runs) is not re-ingested in full by
  every stage; `diff-pr <pr> --stat` prints a per-file additions/deletions
  summary instead of the full diff. Developer, QA, reviewer, and security now
  read the compact forms first and fall back to the full thread/diff only
  when a prior verdict is referenced (fix rounds); both are `github`/
  `github-api` only (#201).
- **Offline test suite** — 140+ assertions, zero credentials needed, CI on
  Ubuntu + macOS.

## Prerequisites

Core (all setups):

| Tool | Needed for | Notes |
|------|-----------|-------|
| `bash` | everything | macOS/Linux; Windows via WSL or Git Bash |
| `git` | everything | |
| `python3` (3.9+) | config parsing, notify payloads | stdlib only; every embedded call runs as `python3 -I` (isolated mode, so a file in the target repo named like a module, such as `json.py`, can never run inside Talos). Config is JSON only (#526): `talos.pipeline.json` needs no extra dependency. |
| `curl` | notifications | skip if you don't use notifications |
| `nak` | Buzz notifications only | `brew install nak`; signs/publishes Nostr events — skip unless you use Buzz |

> **Note: examples throughout this guide use JSON (`talos.pipeline.json`).** Config is JSON only (#526): exactly two canonical files (the repo's own and the user-level one), no other name is ever read.

Per VCS provider (pick one):

| Provider | Tool | Auth |
|----------|------|------|
| `github` (default) | [`gh`](https://cli.github.com), or none | `gh auth login` (or `GH_TOKEN` env var); without a logged-in `gh` it uses `GITHUB_TOKEN`/`GH_TOKEN` over `curl` |
| `github-api` | none | `GITHUB_TOKEN` or `GH_TOKEN` env var — no `gh` CLI needed; pins the `curl` transport |
| `gitlab` | [`glab`](https://gitlab.com/gitlab-org/cli) | `glab auth login` |
| `azure` | `az` + azure-devops extension | `az login`; `az extension add --name azure-devops` |
| `file` | none | fully offline |

Both GitHub providers are one REST client (#551). Its transport is `gh api` when `gh` is installed and logged in (`gh` owns auth, paging and enterprise hosts), and `curl` with `GITHUB_TOKEN` or `GH_TOKEN` otherwise; every verb behaves the same on either. `github-api` always uses `curl` and never asks `gh`, which is the recommended choice for **CI/CD environments or minimal containers**: set `GITHUB_TOKEN` (or `GH_TOKEN`) and add `vcs.provider: github-api` to your `talos.pipeline.json`. Reads use REST rather than GraphQL, so they spend the core quota; the one GraphQL call is the `ready-pr`/`draft-pr` mutation REST does not offer.

Per feature (optional):

- **Notifications** — a Slack/Discord/Teams webhook URL, or a bot token +
  channel ID for threaded conversations (see
  [Environment variables](#environment-variables)).
- **Project board** — a GitHub Projects v2 board and `gh` authenticated with
  `project` scope (`gh auth refresh -s project`).
- **An agentic harness** — Claude Code, Codex CLI, Gemini CLI, or any agentic
  CLI for the custom runner. This is what supplies the LLM; Talos itself makes
  no model API calls.

## Environment variables

**Credentials** (only what you use; all optional):

| Variable | Purpose |
|----------|---------|
| `SLACK_WEBHOOK_URL` | Slack via incoming webhook (no threading) |
| `SLACK_BOT_TOKEN` | Slack via bot (threading works; needs `chat:write`) |
| `DISCORD_WEBHOOK_URL` | Discord via webhook (no threading) |
| `DISCORD_BOT_TOKEN` | Discord via bot (threading works) |
| `TEAMS_WEBHOOK_URL` | Teams via incoming webhook (no threading — Teams has no bot-token alternative, so this is its only delivery path) |
| `BUZZ_RELAY_URL` | Buzz relay websocket URL, e.g. `ws://localhost:3000` ([block/buzz](https://github.com/block/buzz); needs `BUZZ_BOT_PRIVATE_KEY` + `notifications.buzz_channel`) |
| `BUZZ_BOT_PRIVATE_KEY` | Nostr key (nsec or hex) the Buzz bot signs kind:9 events with (threading via NIP-10 replies) |
| `GITHUB_TOKEN` | GitHub API token for the `curl` transport (`github-api`, or `github` without a logged-in `gh`): Personal Access Token or Actions token |
| `GH_TOKEN` | Alternative to `GITHUB_TOKEN`; also accepted by the `gh` CLI |

Where to put them, first match wins: your shell env (exported variables always
win), a `.env` file at the **repo root** (`<repo>/.env`), then `~/.talos/.env`
(`$TALOS_HOME/.env`), which is where secrets belong when you want them for every
repo. `~/.talos/.env` must be a regular file you own with mode 0600 and sit
outside every git work tree, or Talos refuses it with a `chmod 600` hint. The
old `~/.hermes/.env` is **deprecated**: it is still the last fallback, with the
same checks and one deprecation line, and `TALOS_HERMES_ENV=<path>` moves it
(empty disables it). Note: the old `.claude/talos/.env` path is no longer read —
move any credentials to `~/.talos/.env` or the repo root. A config key can also
point at a differently named variable with an `env:NAME` reference. All of this,
and what to do when a file is refused, is in [Secrets](#secrets).

A `.env` is parsed, never sourced, and only the notification variables
(`SLACK_*`, `DISCORD_*`, `TEAMS_WEBHOOK_URL`, `BUZZ_*`, `PIPELINE_*_CHANNEL`,
`PIPELINE_BUZZ_RELAY`) are read from it (#476); a deny list (`BASH_ENV`, `PATH`,
`LD_*`, `GH_*`, `GITHUB_*`, ...) wins over that allow list (#444). `GITHUB_TOKEN` /
`GH_TOKEN` and every other key are ignored there, with one stderr line naming the
key: export them in your shell instead.

Also note: Microsoft retired the legacy Office 365 "Incoming Webhook"
connector in May 2026. Provision a Power Automate **Workflows** webhook
instead ("Post to a channel when a webhook request is received") and put its
URL in `TEAMS_WEBHOOK_URL`.

**Overrides** (optional; take priority over `talos.pipeline.json`):

| Variable | Overrides |
|----------|-----------|
| `PIPELINE_CONFIG` | path to the config file |
| `PIPELINE_SLACK_CHANNEL` / `PIPELINE_DISCORD_CHANNEL` / `PIPELINE_BUZZ_CHANNEL` | notification channels |
| `PIPELINE_PROJECT_NUMBER` / `PIPELINE_BOARD_OWNER` / `PIPELINE_STATUS_FIELD` | board settings |
| `PIPELINE_REPO` | detected `owner/repo` |
| `PIPELINE_REPO_URL` | repo URL used for issue/PR links |
| `PIPELINE_ISSUE_TITLE` / `PIPELINE_PR` / `PIPELINE_PR_TITLE` | notification context (skips `gh` lookups) |
| `PIPELINE_THREAD_STATE` | thread anchor file (default `~/.talos/threads.json`) |
| `PIPELINE_NOTIFY_DEBUG` | `1` = print payloads instead of posting |

**Runtime/testing** (optional; advanced):

| Variable | Purpose |
|----------|---------|
| `TALOS_RETRY_SLEEP_SCALE` | Scale factor for retry backoff sleeps (default `1`; tests set to `0` for instant runs without delay). Scales every sleep uniformly — e.g. `TALOS_RETRY_SLEEP_SCALE=0.1` makes retries 10x faster for local testing, `TALOS_RETRY_SLEEP_SCALE=0` skips all sleeps entirely (network calls still retry, no delay between attempts). |
| `TALOS_STATUS_DEBUG` | `1` makes `talos-status.sh` print stderr notes saying why it printed nothing (otherwise its stderr is silent); see [The status line](#the-status-line) |
| `TALOS_STATUS_TIMEOUT_S` | Hard alarm of `talos-status.sh` in seconds, an integer 1 to 10 (default `3`; anything else uses `3`); on expiry it prints nothing and exits 0 |

Nothing is strictly *required*: with no credentials at all, notifications are
a silent no-op and the pipeline still runs.

## Setup: Claude Code

The first-class harness — native parallel subagents, worktree isolation for
the developer role.

**Recommended: install as a Claude Code plugin.** Once per machine:

```
/plugin marketplace add benmarte/talos
/plugin install talos@talos
```

Restart the session, then in any repo:

```bash
# in a Claude Code session:  /talos:setup     — writes talos.pipeline.json, bootstraps labels
gh issue edit 42 --add-label pipeline:ready
# in a Claude Code session:  /talos:pipeline
```

The plugin carries the skills, the eight role agents, the scripts and the
templates. The repo gets one file: `talos.pipeline.json`. Nothing is vendored,
and upgrading is `/plugin update talos@talos` rather than a re-install per repo.

**Alternative: vendor into the repo.** Use this when the pipeline is driven by a
harness that cannot load a Claude Code plugin (pi, Codex, Gemini, Antigravity — see
the sections below), or when you want the pipeline pinned in-tree and reviewed
alongside your code.

```bash
# 1. Global install (once per machine -- all repos share this copy)
git clone https://github.com/benmarte/talos
bash talos/install.sh --global --harness claude   # ~/.talos/ always; ~/.claude/{skills,agents} too, because claude is in the list

# 2. Per-repo config (once per repo -- writes config; no scripts copied into repo)
bash talos/install.sh /path/to/your-repo
# also writes the Talos block into your-repo/AGENTS.md for every harness (commit it)
# --no-agents-md skips that; --import-agents-md adds an @AGENTS.md import to an existing CLAUDE.md / GEMINI.md
# --harness <list> picks the installer glue (optional, no default): claude codex gemini antigravity pi cursor opencode generic;
#   the AGENTS.md block is the same for all

# 3. Configure (interactive -- or copy talos.pipeline.json.example manually)
cd /path/to/your-repo
# in a Claude Code session:  /talos:setup

# 4. Bootstrap the label state machine (GitHub/GitLab/Azure only)
bash ~/.talos/scripts/bootstrap-labels.sh

# 5. Queue work and run
gh issue edit 42 --add-label pipeline:ready
# in a Claude Code session:  /talos:pipeline
```

`--harness` selects installer glue (what is written where); `agents.runner`
selects the CLI that runs stages. The two are independent: `--harness codex`
does not set `agents.runner`, and `agents.runner: codex` does not install
anything. An unknown tool needs no installer support: pass any `--harness`
name (any other `[a-z0-9-]+` name is treated as `generic`, with a printed
hint), set `agents.runner: custom`, and give `agents.runner_cmd` (the prompt
arrives on stdin).

What the global install writes. `~/.talos/{scripts,agents,templates,skills}/`
always (`skills/<command>/SKILL.md` holds the `pipeline` and `setup`
playbooks, so any agent can be pointed at a path under `~/.talos`; see
"Playbooks for any other agent" below). Only when the Claude adapter runs, it
ALSO writes the role profiles to `~/.claude/agents/<role>.md` -- that second
copy is what Claude Code's native subagent discovery actually reads, so a
global install no longer leaves Claude Code sessions pinned to a stale plugin
profile -- registers the checkout as the `talos` plugin (see "Command names"
below). A repo-level `.claude/agents/<role>.md` still
wins over both. Per-repo installs write only `talos.pipeline.*` config (never
overwritten), the `AGENTS.md` block, and agent-skills to `.claude/skills/`
(skip with `--no-agent-skills`); no Talos scripts are copied into repos.

**When the Claude adapter runs.** With `--harness`, exactly when the list
contains `claude`. Without it, when Claude is detected: `CLAUDE_CONFIG_DIR` is
set and non-empty, or `${CLAUDE_CONFIG_DIR:-~/.claude}` is a directory (a
dangling symlink is not detected), or `claude` is on PATH. Override:
`--harness claude` forces it; a list without `claude` skips it (so
`--harness claude,codex` does both). A skipped adapter never refreshes or
deletes an existing `~/.claude`, and `--global` prints one line saying whether
the adapter ran and why. With no `--harness` and no Claude, `~/.claude` is not
created. This is a change from earlier versions, where
`--global --harness codex` still refreshed `~/.claude`.

**Command names (`/talos:<command>`).** A marketplace install and
`install.sh --global` both give Claude Code `/talos:pipeline` and `/talos:setup`.
Claude Code applies the `plugin:skill` form to plugin
skills only (a skill under `~/.claude/skills` is invoked by its directory name,
and a `name:` with a colon or a nested directory does not change that), so the
Claude adapter registers this checkout as a plugin: `claude plugin marketplace
add <checkout>` (a local directory marketplace, which `.claude-plugin/
marketplace.json` already is) and `claude plugin install talos@talos`. Both are
guarded: a failure, a missing `claude`, or a Claude Code without `claude plugin`
prints a notice (with the two commands to run inside Claude Code) and never
aborts the install or deletes anything.

- *Cached copy.* Claude Code copies the plugin into its own plugin cache when
  it installs it, so a `git pull` in the checkout reaches `/talos:*` only after
  you re-run `install.sh --global` (or update the plugin). The marketplace
  entry still points at the checkout: if you move or delete the clone,
  re-running `install.sh --global` from the new location repoints it.
- *Side effect.* Installing the plugin also installs its `agent-skills`
  dependency from GitHub, which needs network and adds a second plugin to your
  Claude config, even with `--no-agent-skills` (the installer says so just before
  it installs).
- *An existing `talos` marketplace.* Re-adding a marketplace with the same name
  silently replaces its source, so the installer reads `claude plugin
  marketplace list --json` first. The same directory: nothing to do. Another
  directory (you moved the clone, or you ran the installer from a second
  checkout): it repoints and prints one line naming the old and new paths; pass
  `--keep-marketplace` to leave the existing registration untouched (`--no-overwrite`
  does too). Any other source, such as a
  GitHub marketplace you added by hand: left alone, with a notice, because that
  source already provides the names. A list it cannot read: no registration.
- *The old bare names are gone (#553).* `/pipeline`, `/pipeline-setup` and
  `/talos:pipeline-setup` no longer exist. `install.sh --global` removes an
  older install's Talos-owned copies of `~/.claude/skills/pipeline` and
  `pipeline-setup` (an alias with its ownership comment line, or a pre-alias full
  copy: frontmatter `name:` plus a Talos script or config name in the text) and
  the old `~/.claude/skills/talos-resume`. It deletes only once the plugin is
  registered; until then the old copy is still the only way to run the command,
  so it is kept. A skill there that is not Talos's is never overwritten or
  deleted, and a symlink on the path is skipped. `/talos:setup` offers to
  rewrite old command names in your `CLAUDE.md` and `AGENTS.md`.
  `--no-legacy-aliases` is accepted and ignored.

**Playbooks for any other agent.** Every agent can be pointed at the
playbooks by path: `Read ~/.talos/skills/pipeline/SKILL.md and follow it`
(the setup wizard is `~/.talos/skills/setup/SKILL.md`). `install.sh <repo>`
prints that line, and the `AGENTS.md` block names the two paths.

**Pointer skills in `~/.agents/skills`.** With `codex`, `pi`, `cursor` or
`opencode` in the `--harness` list, `--global` also writes
`${TALOS_AGENTS_HOME:-~/.agents}/skills/talos-<command>/SKILL.md` for the three
commands: thin pointers to `~/.talos/skills/<command>/SKILL.md`, so there is no
second playbook to drift. There is no detection (no `--harness`, `claude`,
`antigravity`, `gemini` or `generic` write nothing under `~/.agents`), and
per-repo mode writes none. A `SKILL.md` already at one of those paths that is
not a Talos pointer is never overwritten, even though `--global` overwrites by
default, and a symlink on the path is skipped with a notice.
`TALOS_AGENTS_HOME` is an installer-only override, like `TALOS_HOME` and
`CLAUDE_CONFIG_DIR`: no harness reads it, so set it only to point a trial run at
a scratch directory. Gemini CLI gets no pointers, because its file tools are
confined to the workspace (see the table below). To update every repo at once:

```bash
git -C path/to/talos pull && bash path/to/talos/install.sh --global
```

**Vendored (legacy) back-compat**: existing `.claude/talos/` installs keep
working with zero user action. The probe order includes `.claude/talos/scripts`
at position 4, so old vendored copies are found automatically. No migration
required -- run `install.sh --global` when you are ready to switch.

**Probe order** (first directory containing `pipeline-vcs.sh` wins):
1. `$TALOS_HOME/scripts` -- explicit override (skipped when unset); highest priority
2. `~/.talos/scripts` -- global install; wins over plugin when present
3. `$CLAUDE_PLUGIN_ROOT/scripts` -- Claude Code plugin; bundled copy matching the running skill
4. `.claude/talos/scripts` -- legacy vendored install; back-compat, no action needed
5. `scripts` -- Talos source repo; used when developing Talos itself

The global install wins when present; the plugin falls back to its bundled
copy only when no global install exists.

**Security note:** `$TALOS_HOME` is environment-controlled and sits at the top of
the probe order. Treat it like `PATH` -- point it only at a directory you trust,
because Talos executes scripts from the location it resolves to. This is a
documented property of the design: the skill already executed from
`$CLAUDE_PLUGIN_ROOT`, `.claude/talos/`, and `scripts/` before this change;
`$TALOS_HOME` is a new, environment-controlled entry at the highest priority.

## Setup: pi

pi is a minimal single-agent coding harness. It has no native subagents, so it
runs the pipeline **inline, one agent per turn**: the pi session acts as each
stage role itself (validator → pm → developer → qa → docs → reviewer/security →
merge), waterfall handoff. No `pipeline-agent.sh`, no subprocesses. Works on
any provider backing pi — a Claude account (`/login` → Claude Pro/Max, or
`ANTHROPIC_API_KEY`) or a local model (llama.cpp / Ollama via `/login llama.cpp`).

**Fully offline:** pair pi with `vcs.provider: file` for a zero-infrastructure
pipeline — no remote, no `gh`/`glab`/`az`, no auth, no network. `plan.md`
(a local markdown checklist) is both the board and the issue tracker; each
`- [ ] Task` line is one work item. This is the ideal setup for running talos
on a local LLM.

```bash
# 1. Install: once per machine, then once per repo
bash talos/install.sh --global --harness pi   # ~/.talos, plus pointer skills in ~/.agents/skills
bash talos/install.sh /path/to/your-repo      # talos.pipeline.json and the AGENTS.md block (commit it)

# 2. Config — inline pi mode (talos.pipeline.json)
# { "agents": { "runner": "pi", "subagents": false } }

# 3. Queue work and run the pipeline in a pi session
#    Add 'pipeline:ready' to a GitHub issue (or '- [ ]' to plan.md in file mode),
#    then in the repo start pi and say:
#      Read ~/.talos/skills/pipeline/SKILL.md and follow it
```

pi loads the pipeline from the pointer skills `talos-pipeline`,
and `talos-setup` that `--harness pi` writes into
`~/.agents/skills` (a directory pi scans), or from the `AGENTS.md` block, which
names the same playbooks. No pi settings file needs editing, and this guide makes
no claim about where pi keeps its settings or its default agent directory.

The canonical playbook's Harness-compatibility section selects inline mode from
`agents.subagents: false` / `agents.runner: pi`. The role profiles'
frontmatter (`model:`, `tools:`, `skills:`) is Claude Code metadata — pi reads
only the body, using its own `read/write/edit/bash` tools.

## Setup: Codex CLI

Codex has no native subagents, so role stages run headlessly through
`pipeline-agent.sh`.

```bash
# 1. Install: once per machine (pointer skills in ~/.agents/skills), then once per repo
bash talos/install.sh --global --harness codex
bash talos/install.sh /path/to/your-repo
```

Per-repo `--harness` only shapes the "Next steps" that `install.sh <repo>`
prints and the Gemini import notice; the `AGENTS.md` block is the same for
every harness.

Every install writes a marker-fenced Talos block in your repo's `AGENTS.md`
(not only `--harness codex`) that teaches Codex to act as the orchestrator and
run each stage via the adapter. Existing `AGENTS.md` content is preserved;
re-installs repair the block in place rather than duplicating it, and say
`added the Talos block to`, `updated the Talos block in`, or `up to date`. A
malformed fence or a symlinked `AGENTS.md` is left byte-identical with a notice.

Two flags control it:

- `--no-agents-md` writes no `AGENTS.md`.
- `--import-agents-md` appends a fenced `@AGENTS.md` import to an existing
  `<repo>/CLAUDE.md` and `<repo>/GEMINI.md`; it never creates them or writes the
  block into them. Without it, the install prints a notice when a Claude
  instructions file exists that does not import `AGENTS.md` (`@AGENTS.md` for a
  root `CLAUDE.md`, `@../AGENTS.md` for `.claude/CLAUDE.md`), since Claude Code
  2.1.277+ reads `AGENTS.md` only when no `CLAUDE.md` exists.

`talos.pipeline.json` — route role stages through codex:

```json
{ "agents": { "runner": "codex" } }
```

```bash
# 3. Bootstrap labels, queue an issue (same as Claude Code), then:
codex "Read ~/.talos/skills/pipeline/SKILL.md and follow it"
```

Codex scans `~/.agents/skills` and reads `AGENTS.md`. Whether it can read
`~/.talos` from outside the workspace under its default sandbox is UNVERIFIED
(its docs are silent); see the table under the feature matrix.

Set `issues.max_parallel: 1` — without native subagents, stages run
sequentially in the working tree.

## Setup: Gemini CLI

Same model as Codex: Gemini orchestrates by following the playbook, stages run
through the adapter.

`talos.pipeline.json` — stages run via `gemini -p "<prompt>"`:

```json
{ "agents": { "runner": "gemini" } }
```

```bash
# 1. Install: once per machine (~/.talos only, no pointer skills), then once per repo
bash talos/install.sh --global --harness gemini
bash talos/install.sh /path/to/your-repo
```

`install.sh <repo>` writes the `AGENTS.md` block for every harness. Gemini CLI
reads `GEMINI.md` by default: either set `context.fileName` to
`["AGENTS.md","GEMINI.md"]` in your Gemini settings (Talos prints this and never
edits Gemini settings), or re-run the install with `--import-agents-md` to add
an `@AGENTS.md` import to an existing `GEMINI.md`. Then:

```bash
# 2. Bootstrap labels, queue an issue (same as Claude Code), then:
gemini "Read ~/.talos/skills/pipeline/SKILL.md and follow it"
```

**Caveat: that start line probably fails under Gemini's defaults.** Gemini's
file tools are confined to the workspace (checked against the docs and the
v0.62.0 source), so a model-initiated read of `~/.talos/skills/...` is refused.
`install.sh` still prints this start line, and it is not presented here as
working end to end. For that reason `--harness gemini` writes no pointer skills.
Whether a workaround such as `/directory add ~/.talos` helps is UNVERIFIED.

## Setup: Google Antigravity

Same model as Codex and Gemini: Antigravity orchestrates by following the
playbook; role stages run through the adapter.

**Orchestrator:** `install.sh <repo>` writes a marker-fenced Talos block into
your repo's `AGENTS.md` (every harness gets it; `--harness antigravity` is not
required for that). Per Antigravity's documentation (not run by Talos),
`AGENTS.md` and `GEMINI.md` are both read and cumulative, with no stated
precedence; no separate config file is needed. Antigravity has its own skill
directories (`~/.gemini/config/skills`, `~/.gemini/antigravity-cli/skills`) and
Talos writes nothing there.

```bash
# 1. Install: once per machine (~/.talos only), then once per repo
bash talos/install.sh --global --harness antigravity
bash talos/install.sh /path/to/your-repo
```

**Runner config:** set `agents.runner: antigravity` in `talos.pipeline.json`
so that role stages are dispatched via `agy -p "<prompt>"` (Antigravity CLI
headless mode):

```json
{ "agents": { "runner": "antigravity" } }
```

**Bootstrap and run:**

```bash
# 2. Bootstrap labels, queue an issue (same as Claude Code), then:
agy "Read ~/.talos/skills/pipeline/SKILL.md and follow it"
```

Set `issues.max_parallel: 1` — without native subagents, stages run
sequentially in the working tree.

## Setup: local models (llama.cpp, Ollama)

Talos never calls a model API itself — it needs an **agentic CLI** (one that
can execute shell commands and edit files). A bare chat endpoint can't run a
stage. So the local recipe is: serve the model, point an agentic CLI at it,
give Talos that CLI as a `custom` runner.

**llama.cpp:**

```bash
# --jinja enables tool/function calling — agentic CLIs require it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

`talos.pipeline.json` — e.g. Aider against the local endpoint:

```json
{
  "agents": {
    "runner": "custom",
    "runner_cmd": "OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local aider --model openai/local --yes-always --no-auto-commits --message $(cat)"
  }
}
```

The `custom` runner pipes the assembled role prompt to `runner_cmd` on stdin.
Any agentic CLI works the same way (Ollama-backed agents, Goose, OpenCode, …).

Install Talos with the generic glue (or the CLI's own name when it is `cursor`
or `opencode`), then start the playbook from the CLI:

```bash
bash talos/install.sh --global --harness generic   # ~/.talos only; "--harness opencode" or "cursor" also writes pointer skills
bash talos/install.sh /path/to/your-repo
# in your agentic CLI, in the repo:
#   Read ~/.talos/skills/pipeline/SKILL.md and follow it
```

**Fully offline:** combine a local runner with `vcs.provider: file` — work
items are checklist entries in `plan.md`, no `gh`, no network at all (skip
notification credentials and nothing is posted).

**Model guidance:** pick a function-calling-capable coder model (Qwen
coder-class 32B+ recommended for the developer role). Small models will drop
playbook steps; the orchestrator role is the most demanding — QA/review gates
catch bad stage output, but nothing gates the orchestrator itself.

## Harness feature matrix

| Feature | Claude Code | pi | Codex CLI | Gemini CLI | Antigravity | Custom/local |
|---------|:-----------:|:--:|:---------:|:----------:|:-----------:|:------------:|
| Full pipeline (all roles/gates) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Parallel issues (`max_parallel > 1`) | ✅ | ❌ sequential | ❌ sequential | ❌ sequential | ❌ sequential | ❌ sequential |
| Developer worktree isolation | ✅ | ❌ working tree | ❌ working tree | ❌ working tree | ❌ working tree | ❌ working tree |
| Interactive setup wizard (`/talos:setup`) | ✅ `/talos:setup` | read `~/.talos/skills/setup/SKILL.md` | read `~/.talos/skills/setup/SKILL.md` | read `~/.talos/skills/setup/SKILL.md` | read `~/.talos/skills/setup/SKILL.md` | read `~/.talos/skills/setup/SKILL.md` |
| Optional review/verify skill enrichment | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Notifications / comments / board / file mode | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native AGENTS.md orchestration | only without a `CLAUDE.md`, or via `@AGENTS.md` | native | native | via `context.fileName` or an import | native (cumulative with `GEMINI.md`) | depends on the CLI |

(The notifications / comments / board / file mode row is harness-independent — plain bash. In the wizard row, any agent starts the wizard by reading its playbook; Claude Code also has the `/talos:setup` command. The wizard offers all six runner ids, with no default outside Claude Code, and offers to add the `AGENTS.md` block on its first run and on every re-run, writing it only when you say yes; `install.sh <repo>` writes it unconditionally unless `--no-agents-md`.)

### Install and start, per harness

Two axes, kept apart: `--harness` selects installer glue (what is written
where) and `agents.runner` selects the CLI that runs stages. An unknown tool
uses any `--harness` name, `agents.runner: custom`, and `agents.runner_cmd`
(the prompt arrives on stdin).

For every harness:

- `bash talos/install.sh --global [--harness <list>]`, once per machine, writes
  `${TALOS_HOME:-~/.talos}/{scripts,agents,templates,skills}`. `skills/<command>/SKILL.md`
  holds `pipeline` and `setup`; `skills/pipeline/refs/*.md` sits beside the pipeline
  playbook and is read on demand (`talos.sh env` and `next` print `ref=<topic>`).
- `bash talos/install.sh <repo> [--harness <list>] [--no-agents-md] [--import-agents-md]`
  writes `talos.pipeline.*` (never overwritten), the one marker-fenced block in
  `<repo>/AGENTS.md` (the same for every harness; it never writes the block into
  `CLAUDE.md` or `GEMINI.md`), and agent-skills into `<repo>/.claude/skills` unless
  `--no-agent-skills`. `--harness=x` is accepted too. Commit `AGENTS.md`: untracked,
  it makes `assert-sync` abort on a dirty tree.
- Role override for the adapter and pi inline paths:
  `<repo>/.agents/talos/agents/<role>.md`, after `.claude/agents/<role>.md` and
  before the install. The native Claude path never reads it.
- Start line for any agent: `Read ~/.talos/skills/pipeline/SKILL.md and follow it`
  (setup: `Read ~/.talos/skills/setup/SKILL.md and follow it`). Claude Code has
  `/talos:pipeline` and `/talos:setup`, from either install path.

| Harness | `--global --harness` writes | `agents.runner` | Start line |
|---------|-----------------------------|-----------------|------------|
| Claude Code | `~/.talos` plus, only when `claude` is listed, or with no `--harness` and Claude is detected: `~/.claude/agents` (role profiles), the `talos` plugin (`/talos:*`) and the `pipeline` / `pipeline-setup` aliases in `~/.claude/skills` | `claude` | `/talos:pipeline` |
| Codex CLI | `~/.talos` plus pointer skills | `codex` | `codex "Read ~/.talos/skills/pipeline/SKILL.md and follow it"` |
| Gemini CLI | `~/.talos` only, no pointer skills | `gemini` | `gemini "Read ~/.talos/skills/pipeline/SKILL.md and follow it"` (probably fails under Gemini's defaults, see below) |
| Antigravity | `~/.talos` only | `antigravity` (`agy -p`) | `agy "Read ~/.talos/skills/pipeline/SKILL.md and follow it"` |
| pi | `~/.talos` plus pointer skills | `pi`, with `agents.subagents: false` (inline, no `pipeline-agent.sh`) | `Read ~/.talos/skills/pipeline/SKILL.md and follow it`, said in the pi session |
| Cursor | `~/.talos` plus pointer skills | none: `custom` with `runner_cmd` | the plain-text line above |
| OpenCode | `~/.talos` plus pointer skills | none: `custom` with `runner_cmd` | the plain-text line above |
| generic or any unknown name | `~/.talos` only | `custom` with `runner_cmd` | the plain-text line above |

"Pointer skills" are `${TALOS_AGENTS_HOME:-~/.agents}/skills/talos-<command>/SKILL.md`,
written only by `--global` and only when `codex`, `pi`, `cursor` or `opencode`
is in the list. Each is a thin pointer to `~/.talos/skills/<command>/SKILL.md`, so no
second playbook can drift. An existing `SKILL.md` there that is not a Talos pointer
is never overwritten, and a symlink on the path is skipped with a notice.
`TALOS_AGENTS_HOME` is an installer-only override (like `TALOS_HOME` and
`CLAUDE_CONFIG_DIR`); no harness reads it, so use it only to send a trial run to a
scratch directory.

**VERIFIED** (docs or source, as recorded when each piece landed):

- Claude Code reads `AGENTS.md` only when there is no `CLAUDE.md`,
  `.claude/CLAUDE.md` or `CLAUDE.local.md` in the working directory or above
  (v2.1.277+), or through an `@AGENTS.md` import (code.claude.com/docs/en/memory).
- Codex reads `AGENTS.md` and scans `$HOME/.agents/skills`.
- Gemini CLI reads `GEMINI.md` by default and `AGENTS.md` only through
  `context.fileName` (`["AGENTS.md","GEMINI.md"]`) or an `@AGENTS.md` import
  (`--import-agents-md`). Its file tools are confined to the workspace (docs and
  source v0.62.0), so a model-initiated read of `~/.talos/skills/...` fails under
  the defaults. The start line is still the one `install.sh` prints; do not read
  it as working end to end.
- pi (0.85.1 source) scans `~/.agents/skills`, reads `AGENTS.md` (or `CLAUDE.md`),
  and has no permission gate. Its resource loader does not load `.agents/talos/`;
  Talos reads that override itself (`pipeline-agent.sh --resolve-profile <role>`).
- Cursor (docs) reads `AGENTS.md` and scans `~/.agents/skills`; a skill's `name`
  must equal its folder, which the pointers satisfy.
- OpenCode (docs) reads `AGENTS.md` (falling back to `CLAUDE.md`) and scans
  `~/.agents/skills` and also `~/.claude/skills`, so with `--harness claude,opencode`
  it sees both sets. Reads outside the workspace prompt (`external_directory`
  defaults to `ask`) rather than being blocked.
- Antigravity (docs only, not run by Talos): reads `AGENTS.md` and `GEMINI.md`,
  both, cumulative, with no stated precedence. It has its own skill directories,
  `~/.gemini/config/skills` and `~/.gemini/antigravity-cli/skills`; Talos writes
  none.
- The runner conformance test covers `pi -p` only; pi's inline mode is not covered
  by it (`agents.subagents: false` with `agents.runner: pi`).

**UNVERIFIED** (do not rely on these):

- whether Claude Code reads `~/.agents/skills` (no probe was recorded; Claude Code
  gets its skills from `~/.claude/skills` or the plugin);
- whether Codex or Cursor can read `~/.talos` from outside the workspace under
  their defaults (their docs are silent);
- a Codex commands directory (none found in its docs);
- any Gemini workaround, such as `/directory add ~/.talos`, and Gemini's skill-name
  rule;
- pi's agent-directory default and settings path, so this guide makes no claim
  about them;
- the Antigravity version in which it began reading `AGENTS.md`: an earlier
  version number in these docs is dropped.

## Running the pipeline

1. Add `pipeline:ready` to an issue (or add a `- [ ]` item to `plan.md` in
   file mode).
2. Start the orchestrator in your harness (`/talos:pipeline` in Claude Code; the
   playbook prompt shown above elsewhere).
3. The pipeline advances the label state machine:
   `pipeline:ready` → `pipeline:confirmed` (validator) → `pipeline:dev`
   (spec written) → `pipeline:review` (PR open) → `pipeline:approved` →
   merged + closed. Any failure sets `pipeline:blocked` with a comment
   explaining what a human must do.
4. Watch progress: issue/PR comments from each role, one Slack/Discord thread
   per issue, board column updates — or run
   `bash ~/.talos/scripts/pipeline-status.sh --dry-run <n> "In progress"`
   style commands manually.

**Deterministic orchestrator (`talos.sh run`, #472):** LLM-driven
orchestration (`/talos:pipeline`, Claude) is the default. `talos.sh run` is the
deterministic orchestrator for local and weak-model profiles: code routes,
gates and does the bookkeeping, and an LLM still does every stage. It drives
the pipeline without an orchestrator session:

```bash
bash scripts/talos.sh run                      # every queued or in-flight issue + open PR
bash scripts/talos.sh run --issue 42           # one issue
bash scripts/talos.sh run --max-iterations 50  # raise the dispatch cap (20)
```

`run` loops `talos.sh next`, renders each stage's prompt with `talos.sh
prompt`, dispatches it through `pipeline-agent.sh` (the configured
`agents.runner`, with `agents.fallback` failover), and does the end-of-stage
bookkeeping through `talos.sh done` — no LLM calls in the orchestration itself. When
the ready queue drains, a `wait` answer falls through to the in-flight issues
(#519): one `next --issue` per issue mid-state-machine (`pipeline:confirmed`,
`pipeline:dev` or `pipeline:epic-decomposed`) that has no open pipeline PR,
dispatching whatever it finds; an in-flight issue that is itself waiting
moves to the next one, and the run ends once the in-flight list is spent. It stops clean
(exit 0) on any remaining `stop`/`ask-owner`/`wait` answer, including
`reason=lease` (another run holds the issue's lease) and
`reason=iterations-exhausted max=<n>` at the dispatch cap; a failed state
read exits non-zero. A QA FAIL is a developer fix round, as in the playbook
(#537): `run` calls `gate fix-round <N> qa --pr <M>` (budget guard, attempt
ceilings, the unblock) and dispatches the developer in the fix-round shape;
after the push the normal path resumes (re-stamps, `ready-pr`, QA). A second
QA FAIL at the same PR head (the fix round pushed nothing) stops the run:
`pipeline:blocked` on the PR and the issue, `stop
reason=qa-fail-unchanged-head pr=<M> issue=<N>`, exit 0. Re-run `run` to resume: the lease ledger and the #419
handoff files carry the state.

**The verdict comes from the final message.** `run` reads each stage's verdict
from the agent's final message, never from a posted comment. A verdict-word
role's answer must carry a line whose first word is `<WORD>:` with WORD on
that role's own verdict list (for example `CONFIRMED: ...` on validator,
`PASS: ...`/`FAIL: ...` on QA, `APPROVED: ...`/`CHANGES: ...` on reviewer,
`CLEAR: ...`/`FINDINGS: ...` on security and adversarial); the
developer's message is read for its PR URL (`PR_OPENED`, and `BLOCKED` when
there is none); pm, planner and docs carry no verdict. An answer with no such
line is a dispatch failure (`verdict-unreadable`) — nothing is recorded, never
a guess. To keep even a weak local model's answer parseable, every verdict-word
role profile (`agents/{validator,qa,reviewer,security,adversarial}.md`) and
the QA prompt template now spell the contract: the FIRST LINE of the final
message is the verdict word, a colon and a one-line reason; 1-3 lines of
findings after it; NOTHING before it (#518).

**Human-merge mode:** set `merge.auto: false` in `talos.pipeline.json` to run the
full pipeline but leave the final merge to a human. Every gate still applies —
approval labels, forbidden-files check, green CI — but instead of merging, the
orchestrator labels the PR `pipeline:approved`, posts a "ready for human merge"
comment, sends the orchestrator notification, and stops. The issue stays open
and is closed by the reconciliation sweep after you merge. Use this on
integration branches whose protection requires a human review the pipeline
can't self-provide (single-account setups). Default is `merge.auto: true`.

**Working with epics:** when `roles.planner: true` is set in `talos.pipeline.json`,
the pipeline detects large issues as epics (any issue carrying the `epic` label,
containing ≥ 4 checklist items, or whose body is ≥ 2000 characters) and automatically
decomposes them before the PM and developer stages run. The planner subagent produces
a breakdown of up to 10 sub-tasks; the orchestrator creates a GitHub issue for each
one, linking it back to the parent epic with a `Part of #<N>` reference. Independent
sub-issues receive `pipeline:ready` immediately so they enter the queue on the current
or next run. Sub-issues that depend on another sub-issue are held back until their
predecessor closes, at which point the orchestrator's Step 1 reconciliation sweep
automatically adds `pipeline:ready`. The epic itself is labelled
`pipeline:epic-decomposed`.

Once every sub-issue is resolved, the epic auto-close sweep does NOT close the
epic on that signal alone — children closing is evidence about the children,
not about the epic. It runs `check-epic-acceptance <E>` (see README's
`pipeline-vcs.sh` verbs table for the exit codes) against the epic's
own body on every sweep: if the epic still has unticked `- [ ] ...` acceptance
boxes, the sweep leaves it open and — the first time this happens — adds
`pipeline:epic-children-done` and comments naming every outstanding item, so a
human can decide whether to tick them off or file follow-up work. That
label+comment step is idempotent: a repeated sweep against the same
still-unticked epic re-checks the boxes but does not re-label or re-comment,
so the notice fires once rather than on every pipeline run. Checkboxes inside
fenced code blocks are also counted as acceptance items. Once no unticked
boxes remain (including epics with no checklist at all) the sweep closes the
epic with `close-issue <E> "All sub-issues resolved."` as before, removing
`pipeline:epic-children-done` first if a prior sweep had added it — so an
epic flagged for missing boxes still auto-closes once a human ticks them.
The planner role is off by default — it adds API calls and is most useful
when you regularly work with multi-task epics.

### Resuming a run (#550)

There is nothing to resume from and nothing to read first. A cleared session, a
token limit or a switch to another LLM all resume the same way: start the
pipeline again (`/talos:pipeline` in Claude Code, `Read ~/.talos/skills/pipeline/SKILL.md
and follow it` in another agent, or `bash scripts/talos.sh run`). The state
lives on the remote (labels, PRs, comments) and in the local events log, not in
a file Talos keeps up to date.

- **Step 0 prints where the run stands.** `bash scripts/talos.sh state --summary`
  is read-only and prints at most three `where=` lines: what is in flight (open
  pipeline PRs with their next stage, issues mid-way), what is waiting (blocked
  work, questions held for the owner) and the next action. With several operators
  on the repo (see [multi-user claiming](#global-project-and-environment-configuration-and-multi-user-claiming))
  a fourth line, `where=theirs: #N (@login)`, lists the other operators' work,
  which is never routed. Only numbers and fixed
  words are printed, never an owner's question or any other free text. The run
  then goes on: `talos.sh next` hands out the same action.
- **A developer picks up a checkpoint.** When a provider failover or an out-of-tokens
  stop left a checkpoint (`pipeline-worktree.sh checkpoint <N>`, a WIP commit plus a
  handoff file under the git common dir), the next developer prompt for that issue
  says so, names `pipeline-worktree.sh handoff <N>`, and tells the developer to
  continue from it rather than restart.
- **What was removed.** The tracked status file (`TALOS_STATUS.md`), its generated
  Resume block and log, the `status.*` keys, the `docs/status.d/` fragments, the
  archive and the `/talos:resume` skill are gone; `/talos:setup` no longer asks about
  them. A `status:` block or a leftover file in an existing repo is unused (the
  config loader warns once about the unknown key); delete it in a normal commit.
  `pipeline-status-file.sh` keeps only `collect`, the state reader behind
  `talos.sh state` and `next`.
- **Needs-owner.** The orchestrator no longer marks work `pipeline:needs-owner` on
  its own. A `pipeline:needs-owner` label that a person sets is still honoured:
  the issue is held, `next` answers `ask-owner` for it, and `state --summary`
  lists it under waiting.

For a live view while a run works, see [The status line](#the-status-line).

### Draft PRs: one CI run per PR (`pr.draft`, default `true`, #332, #435)

By default Talos opens the developer's PR as a **draft**. Docs, reviewer,
security and the fix round all run while it is a draft, so no push to it starts
CI. Once every approval is in, the orchestrator marks the PR ready (`ready-pr`),
CI runs once on the final head, and QA uses that run. Under `verify.qa_mode: ci`
the orchestrator waits for it with one `pr-checks-required <pr> --wait <s>` call
(`<s>` is `verify.ci_wait_s`, capped under `verify.timeout_ms`), so no QA agent
sits idle on it. The developer's own CI wait is a no-op here: the brief says
`Required checks: none` because CI has not started. Set `pr.draft: false` to
keep the ready flow, where every push runs CI.

- **Provider support.** `github`, `gitlab` and `azure` take the default.
  `github-api` and `file` cannot open draft PRs and always use the ready flow
  (`github-api` prints one warning line).
- **Pair it with your CI.** Step 0 runs `scripts/pipeline-draft-check.sh` on
  `github` and prints at most one warning. `ok` is silent. `no-skip` means no
  workflow skips drafts, so CI still runs on every push (you lose the saving,
  nothing hangs). `no-ready-trigger` means a job skips drafts but
  `ready_for_review` is missing from `on.pull_request.types`: marking the PR
  ready would start no run and QA would wait for nothing, so with `pr.draft`
  unset that run uses the ready flow, and with `pr.draft: true` you get the
  warning only. See `templates/ci/github-tests.yml` for a workflow that has both.
  Only a real skip counts (`draft != true`, `== false` or `!draft`, alone or
  `&&`-combined; not `== true` or an `||` branch), and when workflows disagree
  the worst state wins. `/talos:pipeline` itself never edits a workflow.
  `/talos:setup` offers a minimal change: `pipeline-draft-check.sh edit
  <file>` prints the exact diff (`ready_for_review` appended to `types`, the
  skip added to a job that has no `if:`, nothing else, never `permissions:`),
  `edit <file> --write` applies it only after your explicit yes, and a symlink
  or non-regular file is refused. An existing job `if:` is never edited; it is
  listed as `manual: job <name>` with the combined condition `(<existing>) &&
  github.event.pull_request.draft != true` for you to apply by hand.
- **A skipped check is pending, not red.** A draft push leaves the job skipped
  until the `ready_for_review` run replaces it. `pr-checks-required` reads a
  skipped check as pending (exit 2), never as `failed:` and never as a pass.
- **Trade-off.** Reviewers see the code before CI has proven it. Your local
  `verify:` run covers most of that; a CI failure it missed costs one extra run.

### Running `verify:` once per PR, and QA trusting CI (`verify.qa_mode`, `verify.targeted`, `verify.ci_wait_s`, `verify.timeout_ms`)

The full `verify:` suite is expensive to run repeatedly, and by default CI
(`merge.required_checks`) already runs it on every push. Talos avoids paying
for the same suite run more than it needs to:

- **Developer** (`verify.targeted`, default `true`): two mutually exclusive
  modes.
  - `true` (default): while iterating, the developer runs only the tests
    that cover the files it changed — `tests/run-tests.sh --for <path>
    [--for <path> ...]`, or `tests/run-tests.sh --changed [<base-ref>]` to
    derive the paths from `git diff` plus uncommitted changes (default
    base ref `origin/main`) — then runs the full `verify:` list exactly
    once, after the last code change, immediately before its final commit
    and push. It never runs the full list more than once for the PR.
  - `false`: the developer runs the full `verify:` list after each
    meaningful change while iterating (the old, non-targeted behavior — no
    per-file test shortcut), and still exactly once after the last code
    change, immediately before its final commit and push.
  In both modes, the developer never runs `verify:` after that final run,
  in the background, or via a sleep-poll loop — and never zero times.
  Outside the pipeline, `tests/run-tests.sh --repeat N` stress-tests a
  selection (one flaky file, or the whole suite) by running it N times and
  stopping at the first failure — see the README's [Tests](../README.md#tests)
  section for the full flag reference.
- **QA never runs the full `verify:` list, in either mode (#257).** CI is the
  authoritative full run — the developer's own required-once-per-PR run
  (above) plus, under `qa_mode: ci`, the CI check itself. QA's only local
  test execution is targeted, and always passes `--strict`: `tests/run-tests.sh
  --for <each path from pr-files> --strict` (or `--changed
  origin/<base-branch> --strict`), through `pipeline-verify.sh`. `--strict`
  (#263) closes a gap plain `--for`/`--changed` left open: without it, a path
  with no convention mapping (e.g. `CHANGELOG.md`, most of `docs/**`) silently
  falls back to running the full suite — exactly the outcome QA must never
  produce. Under `--strict`, an unmapped path is skipped (`no test mapping for
  '<path>' (skipped)` on stderr) instead of triggering that fallback; if the
  resulting selection is empty, the run exits 3 with `no targeted tests
  selected` rather than running anything — QA reports that in its verdict
  and relies on CI instead of running the full suite. This is stated
  explicitly in both the QA prompt template (`templates/prompts/qa.md`, rendered
  by `scripts/talos.sh prompt`) and `agents/qa.md`, closing a gap where the orchestrator's stage prompt asked
  for verify commands generically and every QA dispatch ran the full suite
  anyway.
- **QA** (`verify.qa_mode`, default `ci` when `merge.required_checks` is
  non-empty, else `local`): before either mode runs, the orchestrator checks
  `pipeline-vcs.sh pr-mergeable <pr>` — a `CONFLICTING` PR gets no
  `pull_request` CI run to wait for, so QA is not dispatched into a poll
  that would never resolve. Under `ci`, QA additionally waits on
  `pipeline-vcs.sh pr-checks-required <pr> --wait <seconds>` in the foreground
  (one call that polls internally; no inline loop), bounded by
  `verify.ci_wait_s` (default `900` seconds; must be a positive integer,
  rejected otherwise with a one-line stderr warning and a fallback to the
  default -- it is interpolated unquoted into the CI-wait loop's shell test,
  same rule as `verify.timeout_ms` below), until every check named in
  `merge.required_checks` is passing. Unlike plain `pipeline-vcs.sh
  pr-checks` (which reports every check the provider knows about),
  `pr-checks-required` reads `merge.required_checks` itself and reports only
  those: exit 0 once all of them pass, exit 2 while any is still pending or
  missing (keep polling), exit 1 the instant one has definitively failed (stop
  early, no need to wait out the budget), and exit 1 -- never a vacuous pass --
  when `merge.required_checks` is empty. This closes two gaps in the earlier
  aggregate-everything poll: an unrelated non-required check stuck pending
  could no longer burn the whole wait budget, and a required check the
  provider hadn't scheduled yet could no longer read as a false PASS just
  because every check it *had* reported was green. Any required check that is
  failing, missing, or still pending when the budget elapses is treated as a
  QA **FAIL** -- this is fail-closed by design, never assume a missing check
  would have passed. The budget QA saves by not re-running the suite goes
  into driving acceptance criteria and edge cases instead. Under `local` (the
  default when no `merge.required_checks` are configured, so there is no CI
  oracle to trust), there is nothing extra to wait on, but the targeted-tests
  rule above still applies unchanged — QA does not fall back to a full run
  just because CI isn't configured; the developer's one required full
  `verify:` run before opening the PR is still the full-suite guarantee. An
  explicit `verify.qa_mode: ci` combined with an empty or absent
  `merge.required_checks` list is itself treated as `local` (with a one-line
  warning on stderr from `pipeline-config.sh`) — trusting CI as the oracle
  for zero required checks would let QA pass vacuously, without ever
  observing a real CI signal, so that combination fails closed to `local`
  instead of passing silently.
- **`--wait` and the CI gate before QA** (#355): `pr-checks-required <pr>
  --wait <seconds>` takes digits only, at most `3600`; anything else exits 2
  with usage. On `github` and `github-api` it polls inside the one call; other
  providers answer once. When `merge.required_checks` is set, the developer
  also waits for required CI before handing off, with `--wait` set to the
  smaller of `verify.ci_wait_s` and `verify.timeout_ms / 1000 - 30`. It fixes a
  red build in the same dispatch (at most 2 rounds) and reports `CI: green`,
  `CI: red` or `CI: pending` with the head SHA. Under `qa_mode: ci` the
  orchestrator does not dispatch QA while `pr-checks-required` exits 1 with
  `pr-checks-required: failed:`: it records a developer attempt and
  re-dispatches the developer instead. Draft PRs are skipped.
- **Reviewer, security, and docs never run `verify:`.** They only ever read
  the diff (`pipeline-vcs.sh diff-pr`) and CI status
  (`pipeline-vcs.sh pr-checks`) — this was already true in practice and is
  now stated explicitly in each profile.
- **`verify.timeout_ms`** (default `600000`): the explicit timeout, in
  milliseconds, that the developer and QA prompts substitute into a one-line
  foreground rule placed within a few lines of every verify and CI-wait
  instruction — never background execution (`&`, `nohup`, `disown`), never
  sleep-polling, never end the turn while a verify command or the CI-wait
  poll is running. This exists because developers backgrounded the verify
  suite and stalled waiting for its own notification on three separate runs,
  and QA did the same with its `pr-checks` poll under `qa_mode: ci` — Rule 17
  already forbade it in prose, hundreds of lines from the decision point, and
  agents missed it. Must be a positive integer; a non-integer or
  non-positive value is rejected by `pipeline-config.sh` (one-line warning on
  stderr, falls back to the default).

Set `verify.qa_mode: local` explicitly if you want QA to skip the CI-wait poll
regardless of `merge.required_checks` — for example, if your CI doesn't run
the same suite Talos does. It does not make QA re-run the full suite; QA
always runs targeted tests only (#257).

### Mechanical merge for CHANGELOG-only conflicts (`merge.union_paths`, #256)

When `pr-mergeable` reports `CONFLICTING`, the orchestrator does not jump
straight to a developer "merge base" dispatch. It first checks
`pipeline-vcs.sh conflict-files <pr>` — a purely mechanical git operation
(a throwaway merge attempt in a detached temp worktree, never in the
orchestrator's own checkout) that lists exactly which paths conflict. Two
PRs each adding a bullet under `CHANGELOG.md`'s `## [Unreleased]` heading is
the common case: that conflict is a git operation, not a reasoning task, and
does not need an LLM dispatch to resolve. If every conflicting path matches
`merge.union_paths` (default `["CHANGELOG.md"]`), `scripts/pipeline-mergebase.sh`
resolves it itself with `git merge-file --union` (both sides kept, the PR's
own entry first) and pushes — no developer subagent runs at all. Any other
conflicting path (or a config error) falls straight through to the same
developer merge-base dispatch as before #256. `merge.union_paths` entries
are validated the same way as `merge.approval_waiver_paths` — catch-all or
non-unionable-matching patterns (`scripts/**`, `tests/**`, pipeline config
filenames) are rejected, since a union merge blindly concatenates both
sides of a conflict, which is safe for an additive changelog but would
corrupt a source file. A mechanical union merge that only touches
`CHANGELOG.md` never invalidates an existing QA/security approval stamp —
`check-approval-sha` already treats `CHANGELOG.md` as a waiver path (see
`merge.approval_waiver_paths` above), so the orchestrator does not need to
re-dispatch those roles afterward.

### Stale approvals — cheap delta re-stamp (`agents.restamp_model`, #258)

A role reported by `check-approval-sha --stale-list` already approved this
PR once — a later commit (from a fix round, or a sibling stage sending the
PR back to the developer) just invalidated that approval's stamped SHA. Only
the delta since the approved SHA is new to that role; re-running its full
stage re-reads the entire diff for no reason. Both places the orchestrator
re-dispatches a stale role — Step 4's stale-approval gate before merge, and
Step 3e inline whenever a fix round returns to a role that already approved
— dispatch a **re-stamp** instead of the normal full stage:

- Same role and role profile as the full stage — never a different agent.
- Model: `agents.roles.<role>.restamp_model`, falling back to
  `agents.restamp_model`, falling back to `agents.model` (a re-stamp
  defaults to the same volume tier as `agents.model`, not the session
  default an unset `agents.roles.<role>.model` would fall back to).
- Comment header: `**Agent:** <role> (talos) — re-stamp`.
- Prompt inputs: the approved SHA and stale file list from
  `check-approval-sha --stale-list`'s output, the current head SHA,
  `diff-pr <PR> --stat`, and the role's previous verdict comment URL.
- Instruction: review only the delta since the prior approval; run only the
  tests that map to the changed files (`run-tests.sh --for <changed files>
  --strict`) if the role runs tests at all; if the delta does not change the
  prior verdict, re-confirm it with `post-approval <PR> <role>` (verdict
  `RESTAMP_PASS`); otherwise post findings exactly as a normal stage would
  (verdict `RESTAMP_FAIL`) — a re-stamp that finds a problem is not a
  special case, it escalates to that role's normal full stage on the next
  round, exactly like a first-time CHANGES/FINDINGS verdict.
- **Trigger condition, explicit:** a role only gets the re-stamp variant
  when its approval label is present on the PR AND `--stale-list` reports
  it stale. A role whose label is absent (first pass, or its own previous
  verdict left no approval label) always gets the full stage instead.
- **`RESTAMP_FAIL` strips the stale label** before relaying —
  `label-pr <PR> --remove <label>`, using the exact `label=<label>`
  `--stale-list` reported for that role (`qa:pass` / `review:approved` /
  `security:approved` / `adversarial:approved` — the label name does not
  always match the role name, so this is never guessed). Without this, the
  role's stale label would still be present on the next pass, so
  `--stale-list` would report it stale again and dispatch another re-stamp
  instead of the promised full stage. Step 4's own stale handling already
  strips this same label before it ever reaches the re-stamp dispatch
  (its step 1, below); the strip in the re-stamp dispatch itself is what
  makes the Step 3e fix-round path — which has no equivalent prior strip —
  correct too.

First-time approvals, and any verdict of BLOCKED/CHANGES REQUESTED/FINDINGS,
are unaffected — `check-approval-sha --stale-list` only ever names a role
that already has a (now-stale) approval, so the first pass through a stage
is never mistaken for a re-stamp. `pipeline-events.sh cost` reports
re-stamp dispatches in their own `restamp` column (a count of
`RESTAMP_PASS`/`RESTAMP_FAIL` events per issue/role), so re-stamp cost is
visible next to that role's full-stage cost rather than folded into the
same totals.

### Approval-marker author verification (`markers.verify_authors`)

**What it does.** `check-approval-sha` and `read-attempt` trust
`talos:approval`/`talos:attempt` markers only from an *effective trust set*.
As of #187, `markers.verify_authors` defaults to `true`, and that set is the
identity Talos itself is authenticated as — inferred automatically, with no
config needed — unioned with `markers.trusted_authors` (if you've also set
that). This closes the gap the pre-#187 opt-in allow-list left open by
default: previously, an unconfigured `markers.trusted_authors` meant *any*
commenter's marker was accepted, so a single misbehaving or compromised
stage could post all four approval markers itself and merge its own PR.

**How the identity is inferred.** No new credentials or scopes are
required — the same ones every other verb already uses:

- `github` provider: `gh api user --jq .login` (the identity `gh auth
  login` is signed in as).
- `github-api` provider: `GET /user` against the configured token
  (`GITHUB_TOKEN`/`GH_TOKEN`, or `vcs.token_env`).

The lookup happens at most once per `pipeline-vcs.sh` invocation, however
many markers that invocation reads.

**Opting out.** Set `markers.verify_authors: false` to restore the
pre-#187 behaviour exactly: author checking is skipped entirely, silently,
for every marker, regardless of `markers.trusted_authors`.

```yaml
markers:
  verify_authors: false   # pre-#187 behaviour: accept any commenter's marker
```

**When the identity can't be resolved.** If verification is on (the
default) but the lookup fails — an insufficiently-scoped token, a
transient API error — and `markers.trusted_authors` is also unset, Talos
falls open exactly as it always has: the marker is accepted, and a
`talos:marker-authors-unverified reader=<verb>` line is printed once so
you can see it happened. Configuring `markers.trusted_authors` (even
without a resolvable identity) is enough to enforce the check anyway.

**CI-bot caveat.** The inferred identity is whichever account's token
Talos runs under — it is *not* "any account whose login ends in
`[bot]`". If a separate CI job (not Talos's own dispatch) also posts
approval or attempt markers under a different bot identity — for example
`github-actions[bot]` — you must list that login explicitly:

```yaml
markers:
  trusted_authors: ["github-actions[bot]"]   # unioned with the inferred identity
```

Every marker skipped for an untrusted author is reported once per
invocation on stderr as `talos:marker-authors-rejected
authors=<comma-separated logins>` — never one line per marker, even when
several markers are rejected in the same run.

### Retries and attempt counting (`record-attempt`, #172)

**What it does.** Every re-dispatch of a blocking stage (developer fix
rounds, a re-run QA/reviewer/security cycle) is recorded via
`pipeline-vcs.sh record-attempt <issue-n> <stage>`, which posts a
`<!-- talos:attempt -->` marker comment on the issue and enforces the two
ceilings from `limits`: `max_fix_attempts` (per-stage) and
`max_total_dispatches` (across the whole issue). The orchestrator checks
the exit code before re-dispatching — a non-zero exit means a ceiling would
be exceeded, and the issue is blocked instead.

**Deduplication.** `record-attempt` accepts two mutually exclusive flags so
a retried call (a fresh shell, a restarted orchestrator process, a flaky
network write) doesn't double-count the same attempt:

- `--pr <pr-n>` derives the idempotency key itself as
  `<stage>-<pr-head-sha>` by resolving the PR's current head SHA
  server-side — nothing to mint by hand. As long as the PR head hasn't
  moved, calling `record-attempt` again for the same stage/PR recomputes
  the identical key and is a no-op (it reprints the existing counts instead
  of posting again). Prefer this whenever a PR already exists.
- `--idempotency-key <token>` is for stages with no PR yet (before a PR
  exists, `--pr` is unavailable); the caller mints its own token
  (`[A-Za-z0-9._-]+`). Deduplication here only covers the process that
  minted the token — it can't detect a retry across a fresh orchestrator
  restart the way `--pr` can.

Omitting both flags entirely preserves the pre-#172 behaviour: every call
posts a new marker, unconditionally. See README's `pipeline-vcs.sh` verbs
table for `record-attempt`'s full flag reference and `read-attempt` /
`check-attempt` for reading state back without recording a new attempt.

### Filtering which issues enter the queue (`issues.label_filter`)

> **Config format (#526):** the examples below are JSON — config is JSON only,
> in exactly two canonical files (`talos.pipeline.json` here, and the
> user-level `~/.talos/talos.pipeline.json`). JSON needs no extra dependency.

**What it does.** The orchestrator's Step 1 queue filter uses AND-logic: an
issue enters the queue when it carries **both** `pipeline:ready` **and** the
configured `issues.label_filter` label. The two labels must both be present on
the issue.

**Default:** `pipeline:ready`

At the default value the two conditions collapse to a single check -- an issue
needs `pipeline:ready`, and the filter requires `pipeline:ready`, so existing
configs are unaffected byte-for-byte. No migration is needed.

**Worked config example:**

```yaml
issues:
  label_filter: "team:alice"
```

With this config an issue must carry **both** `team:alice` **and**
`pipeline:ready` to enter the queue. An issue that carries only `team:alice`
(without `pipeline:ready`) is ignored. An issue that carries only
`pipeline:ready` (without `team:alice`) is also ignored.

**Footgun -- silently empty queue.** Setting a custom `label_filter` without
understanding the AND-logic produces a queue that appears empty even when issues
are labelled correctly. The pipeline starts, finds nothing, and exits without
error. If your queue is unexpectedly empty after setting this key:

1. Confirm the target issue carries both `pipeline:ready` and your filter label.
2. Temporarily set `label_filter: "pipeline:ready"` (the default) to verify
   the queue logic itself is working.

The queue logic is in `scripts/pipeline-vcs.sh`; the key is read via
`pipeline-config.sh issues.label_filter`.

### Who issues are assigned to (`issues.assignee`)

**What it does.** Talos assigns an issue (or Azure DevOps work item) at two
moments: right after `create-issue` opens it, and when `pipeline-status.sh`
moves it to "In progress" (the claim). Both go through the
`pipeline-vcs.sh assign-issue <n>` verb, on `github`, `github-api`, `gitlab`
and `azure`. The `file` provider has no assignee concept and is unaffected.

**Default:** `self`

| Value | Effect |
| --- | --- |
| `self` | The authenticated operator: `gh api user` (github), `GET /user` (github-api), `glab api user` (gitlab), `az account show --query user.name` (azure). |
| any other string | That identity, assigned verbatim: a GitHub login, a GitLab username, an Azure DevOps UPN or display name. |
| `none` | Never assign. Talos behaves as it did before this key existed. It also turns [multi-user claiming](#global-project-and-environment-configuration-and-multi-user-claiming) off, since a claim is an assignment. |
| `assignee: ""` (quoted) | Disables assignment (same as `none`), and each `assign-issue` prints a one-line notice on stderr saying the empty value was read as `none`. A bare `assignee:` (YAML null) is dropped by the config reader and behaves as if unset, resolving to `self`. |

The value is trimmed of leading and trailing whitespace before any of the above comparisons, so `" self "` is `self`, `"NONE "` is `none`, and a whitespace-only value (`"  "`) is `none` (with the same empty-value notice).

```yaml
issues:
  assignee: "alice@example.com"
```

**It never takes a card from a person.** `assign-issue` reads the current
assignee first. If anyone already holds the issue, it leaves it alone. On
GitHub and GitLab, which allow several assignees, it adds the identity only
when the list is empty.

**Failures warn and do not block.** If the identity cannot be resolved or
the provider rejects it, Talos prints a `WARNING` on stderr, leaves the
issue unassigned, and the stage continues. For example, GitHub rejects
non-collaborators, and Azure DevOps rejects identities outside the project.
An `az` login as a service principal also fails, because it resolves to a
GUID rather than a user. After every write Talos reads the field back and
reports `assign-issue: #<n> assigned to <id>` only when the identity is
actually there. If you see the warning, set `issues.assignee` to an identity
the project accepts, or to `none`.

### Choosing an isolation mode (`execution.isolation`)

> **Config format (#526):** the examples below are JSON — config is JSON only,
> in exactly two canonical files. The key path `execution.isolation` and its
> default `worktree` are unchanged.

**What it does.** Selects the working-copy strategy that each stage runs in.
Three values are recognised:

| Value | Behaviour |
|-------|-----------|
| `worktree` | (default) Each issue gets a dedicated git worktree, enabling parallel execution. |
| `branch` | Each stage runs in the main checkout on its own branch. Parallel execution is disabled (see below). |
| `checkout` | Planned but not yet implemented -- the orchestrator refuses this value at startup. |

**Default:** `worktree` (an absent key is identical to `worktree`)

**Worked config example:**

```yaml
execution:
  isolation: branch
```

**Hard constraint -- `branch` forces `max_parallel: 1`.** When `isolation:
branch` is set, the orchestrator refuses to start if `issues.max_parallel` is
greater than 1. This is a hard startup failure, not a warning -- the pipeline
does not degrade gracefully to sequential mode; it exits with an error telling
you to set `max_parallel: 1` explicitly. Add both keys together:

```yaml
execution:
  isolation: branch
issues:
  max_parallel: 1
```

**Why `branch` exists.** Worktrees are the default because they isolate each
issue cleanly. `branch` exists for projects where worktrees cause problems:

- **Submodules** are not populated in a fresh worktree; a project that relies on
  submodule content at build time fails immediately.
- **Ignored-but-required artifacts** (`node_modules/`, `.venv/`, generated
  protobufs) are absent from a clean worktree, so every stage pays a full
  install/build cycle.
- **Absolute paths** in build configs and Docker bind-mounts point at the
  original checkout, not the worktree path -- builds break or silently use
  stale artifacts.
- **Large monorepos** pay real disk and time cost to create and populate a new
  worktree for every issue.

If any of these applies, set `isolation: branch` and `max_parallel: 1`. The
sequential constraint is the price of working in a single checkout.

**Stage identity during `verify:` (`scripts/pipeline-verify.sh`).** A verify
command sometimes needs to know which issue/worktree it is running for (e.g.
to derive a unique compose project name or port range). On the adapter path
(`subagents: false`), `pipeline-agent.sh` exports `TALOS_ISSUE_NUMBER` and
`TALOS_WORKTREE_PATH` as real shell variables automatically. On the native
path (Claude Code subagents), the developer/QA prompts run every `verify:`
command through `bash scripts/pipeline-verify.sh --issue <N> --worktree
<path> -- <cmd>` instead of exporting the vars by hand -- the wrapper
resolves the identity (from `--issue`/`--worktree`, then
`<worktree>/.talos/env` written by `pipeline-worktree.sh create` -- found by
walking up to the worktree's toplevel via `git rev-parse --show-toplevel`,
so it resolves from a subdirectory too -- then the calling environment) and
exports it before running the command, so the mechanism is mechanical
rather than instruction-based (#186).

### Parallel runs and locking: shared local state under `issues.max_parallel > 1` (#180)

**What it does.** Under `isolation: worktree`, each concurrent issue gets its
own working directory, but three pieces of state still live outside that
per-issue isolation, in files/dirs shared by every stage of every issue in the
same repo:

- The notification thread map, `${PIPELINE_THREAD_STATE:-~/.talos/threads.json}`
  -- every `pipeline-notify.sh` call across every concurrent issue reads,
  updates, and rewrites the same file.
- `git worktree add`/`remove` -- every worktree, regardless of which issue it
  belongs to, is metadata inside the *same* repo's `.git` directory.
- `tests/run-tests.sh`'s per-file result cache, `.talos/test-cache/` -- every
  `-j`-parallel test-file worker in every concurrently-running verify writes
  into the same cache directory.

`scripts/pipeline-lock.sh` serializes all three with a portable, `mkdir`-based
advisory lock (macOS ships no `flock(1)`, so this is deliberately not built on
it -- the same lock code runs unmodified on macOS and Linux CI runners). If a
lock can't be acquired within its timeout, the caller proceeds without it and
prints one warning to stderr -- a stuck lock must never deadlock the pipeline.
The test-cache write path additionally uses a write-to-temp-file-then-`mv`
pattern rather than a lock: `mv` within one filesystem is atomic, so two
`-j` workers racing to mark the same cache key done can't produce a corrupt
half-written file.

**What is deliberately left unlocked.** GitHub Project board updates
(`pipeline-status.sh`) are remote and idempotent -- a lost update there just
means a re-read picks up the latest state on the next call, not a corrupted
local file. Locking it would add latency without fixing a real race.

**You don't need to do anything.** This is on by default whenever
`pipeline-lock.sh` is installed (`bash install.sh --global` ships it); no new
config key exists for it.

**Lease maintenance (`talos.sh lease prune`, #522).** `next` holds an issue's
lease in `<git common dir>/talos-lease.ledger` while it works on it. A one-shot
`next` that exits (or a run that crashes) leaves a line whose `pid=` is a dead
process: `next` reclaims such a line on its own once it is older than
`TALOS_LEASE_RECLAIM_S` (default 10 s, an env-only override) instead of waiting
the full TTL, and announces it once on stderr
(`talos.sh next: lease reclaimed from dead holder issue=<N>`). To clear those
lines without editing the ledger by hand, run `bash scripts/talos.sh lease
prune`: under the same advisory lock, it removes every line no reader counts as
a lease (expired, a dead holder past the reclaim guard, a duplicate shadowed by
a later-expiring line), prints one `pruned issue=<N>` line per removed ledger
line, and is a silent no-op (exit 0, the ledger never rewritten) when there is
nothing to remove. A live holder's lease is never touched, and the TTL stays
the bound for a live-but-hung holder.

### Worktree cleanup and the stale-worktree warning (`execution.worktree_warn_threshold`)

**Policy (#240):** a stage's working copy lives exactly as long as the stage
needs it -- every worktree and scratch branch is removed as soon as the PR it
belongs to merges or closes. Anything left behind that doesn't belong to an
issue still in the queue or with an open PR is garbage, removed regardless of
dirty/unpushed state -- dirty scratch is not work in progress; real work lives
on a pushed PR branch.

**What it does.** Under `isolation: worktree` (the default), the developer,
QA, and (when the harness gives them one) reviewer/security/docs stages each
get a disposable `git worktree`. The developer worktree is self-identifying
(`fix|feat/issue-<N>-*` branch); the others are Claude Code harness `agent-*`
worktrees with no issue number in their name, so their own first verb
(`pipeline-criteria.sh qa-run <N> <pr>` for QA, `post-approval <PR> <role>
--issue <N>` for reviewer, security and docs) runs `pipeline-worktree.sh tag
<N>` itself, writing `<worktree>/.talos/env` (the same #186 format `create`
writes) so later verbs can find them:

- `scripts/pipeline-worktree.sh remove <N>` deletes EVERY worktree for issue
  `<N>` -- the developer worktree and any harness worktree tagged to `<N>` --
  plus their local branches, on every merge (Step 4).
- **Step 1 (startup)** runs `pipeline-worktree.sh sweep <queue ids>` as a
  backstop for a run that ended before Step 4 could clean up.
- **Step 5 (end of run)** runs the same `sweep` unconditionally, every run --
  not only as a startup backstop -- passing the queue ids PLUS the issue id of
  every PR still open, so a worktree whose PR is still under review keeps its
  place.

**Safety.** `sweep` preserves ONLY a worktree identified (by naming
convention, or by its tag file) with an id in the list passed to it -- an
untagged or otherwise unidentifiable worktree counts as "not open" and is
removed regardless of dirty/unpushed state. `sweep` also deletes local
branches that are not `main`/`master`/the configured base, do not track a
still-existing remote branch, and are not the head of a currently open PR
(queried from `list-prs` once per sweep, not per branch); if that lookup
itself fails, branch cleanup is skipped entirely for that run rather than
guessed. A worktree whose directory is already gone (git calls this
"prunable") is always reclaimed. `remove <N>` is narrower and keeps the
older, per-issue safety net: it still refuses to delete the ONE worktree it
targets while it has uncommitted changes or commits its upstream doesn't have
yet, listing the reason in its output instead of removing it.

Every `sweep` run ends with a summary line:
`talos:worktree-sweep removed=<n> kept=<n> freed=<size>`.

**`pipeline-worktree.sh status`** prints worktree/dirty/local-branch counts
and the total on-disk size of `.claude/worktrees`, for a quick health check
without wading through `list`'s per-worktree output.

**Default:** `10` (an absent key behaves exactly like `10`)

**Worked config example:**

```yaml
execution:
  worktree_warn_threshold: 15
```

**What the threshold does.** `pipeline-worktree.sh list` counts every
non-active worktree (both categories above, excluding lane homes and the
checkout the command is run from) and, when that count exceeds the threshold,
appends a line: `pipeline-worktree: WARNING: <N> stale worktrees exceed
threshold <T>`. Step 5 relays that line verbatim via `pipeline-notify.sh info`
when present, and says nothing when the count is at or under the threshold.
This is visibility only -- raising or lowering the threshold does not change
what `sweep` removes; it only changes when the warning fires.

### Criteria first: red-first tests (#421)

Acceptance criteria become executable before any implementation exists.

- **PM.** Each criterion in the spec has a stable id and a marker: `- [ ] AC1 an expired token is rejected (test)` or `- [ ] AC2 the README names the flag (prose: doc wording, no harness)`. A spec also has a `Tests:` line naming the test file paths and, optionally, a name filter (plain data, never a runner command: QA runs the files through the repo's configured runner). With no PM stage (`spec:ready`, or an issue body that is already a spec) the ids are the 1-based positions of the issue's checklist and an unmarked criterion is `(test)`.
- **Developer.** The first commit on the branch is the failing tests, one per `(test)` criterion, with the id in the test name (`AC2 rejects an expired token`), made with a plain `git commit` so the body can carry the red run: the command, the exit code and the failing ids. Then red to green, with a checkpoint after each green step. Prose criteria are implemented and listed as prose in the PR body. A red commit is never pushed under an open PR: the PR opens after green, and in a fix round the red-first step stays local and is pushed with its green commit. The full suite still runs once, after the last code change; the red run and each green step run targeted tests only.
- **QA.** Runs the spec's test files by path (`--for <test path>`, which `--strict` never skips), proves they were red at the first branch commit (a test green there is a FAIL, vacuous), runs them at head, and reports one line per id: `AC<n> red@<sha8> green@head`, the failing case, or `AC<n> prose hand-checked`. Required CI is waited on as before.
- **The mapping.** `scripts/pipeline-criteria.sh` reads the runner's assertion labels (`  ok  AC2 ...` or `FAIL  AC2 ...`) and prints `pass`, `fail` or `missing` per id. Deriving the handoff's `criteria_done` from it ships with the handoff work (#419); until then only the naming convention is fixed.

```bash
bash scripts/pipeline-criteria.sh ids spec.md                    # AC1 test / AC2 prose
bash scripts/pipeline-criteria.sh map head.out --spec spec.md    # AC1 pass
bash scripts/pipeline-criteria.sh report --spec spec.md --red red.out --head head.out --red-sha 1a2b3c4d
```

A worked example (a spec with one `(test)` and one `(prose)` criterion and a stub runner) is in `tests/fixtures/criteria-first/`, driven by `tests/test-criteria-first.sh`.

### Checkpoint and handoff

A stage that dies (provider outage, spend limit, a crash) used to leave its work uncommitted in a worktree. `pipeline-worktree.sh checkpoint` saves it and records where the stage was.

```bash
bash scripts/pipeline-worktree.sh checkpoint <N> [--local] [--runner R] [--model M]   # optional JSON on stdin
bash scripts/pipeline-worktree.sh handoff <N>                                          # read-only
```

- **What it does.** Stages everything with `git add -A` (never `.talos/` or `.claude/worktrees/`, and never a path matching the `check-pr-files` default patterns or `merge.forbidden_files`, read from the same list and matched case-insensitively; those are named on stderr, and checkpoint stops with exit 1 if it cannot resolve the list), commits `wip(#<N>): checkpoint`, pushes `HEAD:refs/heads/<branch>` (never forced) and refreshes the handoff. The current branch must match `(fix|feat)/issue-<N>-`, so it works in a worktree and under `isolation: branch`, and can never commit on `main`. Nothing to commit still refreshes the handoff and retries an unpushed commit.
- **Push policy.** A first pass pushes. A fix round passes `--local` (commit only): a push under an open PR starts CI and moves the head the approvals are stamped on. The WIP subjects appear in the squash commit body. The push never runs inside the repo-wide worktree lock.
- **The handoff file.** `<git common dir>/talos/handoff/<N>.json` — the run-state directory, outside every git tree (#517; the old `<repo-root>/.talos/handoff/` was inside the tree in a normal clone): mode 0600 in a 0700 directory, never staged or pushed, so it cannot reach a PR diff or the squash commit, and an agent's `git add -A` can never commit it. Trade-off: it is **this machine only**; failover and resume on one machine work, cross-machine resume does not. Fields: `v` (1), `issue`, `branch`, `head` (the checkpoint commit), `stage`, `criteria_done` and `criteria_remaining` (1-based positions in the spec's acceptance list, integers only), `last_verify` (`cmd`, `rc`, up to 20 failing test names; never output), `decisions` (up to 8 one-line strings), `next_step`, `runner` and `model` (only when given by flag or `TALOS_RUNNER`/`TALOS_MODEL`; never guessed, omitted when absent). State left at the old location is never read, migrated, or cleaned.
- **No secrets.** A string that looks like a credential (`ghp_`, `sk-`, `AKIA...`, `-----BEGIN`, a JWT, `Bearer `, `://user:pass@`, `token=`, any unbroken 32+ character `[A-Za-z0-9_-]` run) or that contains the value of an environment variable whose name has `TOKEN`, `KEY`, `SECRET` or `PASSWORD` is rejected (exit 4, previous file kept, only the field name on stderr), never redacted. Shorten a very long test name if it trips the 32-character rule.
- **Exit codes.** 0 ok; 1 refused (wrong branch, git failure); 2 usage; 3 push failed (commit kept locally, handoff written, nothing reported as pushed); 4 handoff rejected (commit and push done).
- **`handoff <N>`** prints the validated JSON and exits 0, or exits 1 with one line when the file is absent, invalid or stale (the branch is gone, or `head` is not on it, so a re-created branch never inherits an old handoff). It works from any directory of the repo.
- **Lifecycle.** `talos.sh prompt developer` adds a `Checkpoint found:` line to the developer prompt only when `handoff <N>` exits 0 (#550): it names the verb, says to continue from the checkpoint and not restart, and points at `git diff origin/<base>...` for the work already on the branch. `remove <N>` deletes the file with the worktree; `sweep` does not. The runner failover path (`agents.fallback`) calls `checkpoint <N>` when a runner fails with a provider error.
- **Known gap.** `sweep` removes by issue id, and also deletes a local branch that has no `origin/<branch>`; so a worktree whose checkpoint push failed is kept only by `remove <N>` (reason `unpushed`) and by `sweep <N>` listing it, not by a `sweep` that omits it.

### Adding context to every stage prompt (`hooks.pre_dispatch`)

**What it does.** `hooks.pre_dispatch` runs a shell command before every
stage's prompt is built -- validator, PM, developer, QA, reviewer, security,
docs, planner -- on both the native subagent path and the
`pipeline-agent.sh` adapter path. This is how an external tool (a project
memory store, a cost budget, a repo-specific style guide, anything) can hand
a stage extra context without Talos knowing or caring what that tool is.
Disabled by default -- an absent or empty `hooks.pre_dispatch` runs nothing
and changes no prompt.

**Contract.** The command receives this JSON on stdin (`pr` and `files_hint`
are `null`/`[]` when the caller doesn't have them yet, e.g. before a PR
exists). `files_hint` is currently populated only when the caller sets it --
`pipeline-agent.sh` passes through `TALOS_FILES_HINT` (newline-separated
paths) when that env var is set, and `[]` otherwise:

```json
{"role":"developer","issue":42,"pr":57,"repo":"owner/name",
 "base_branch":"main","worktree_path":"/abs/path","files_hint":["a.sh"]}
```

`TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, and `TALOS_WORKTREE_PATH` are also
exported to the command's environment. A non-zero exit, a timeout
(`hooks.timeout_s`, default 30s), or empty stdout is a silent no-op -- the
prompt is left exactly as it would have been with no hook configured -- with
one line on stderr explaining why. It never blocks or delays dispatch beyond
`hooks.timeout_s`. Non-empty stdout is prepended to the prompt verbatim under
a `## Context` heading followed by `---`.

**Worked config example:**

```yaml
hooks:
  pre_dispatch: "my-context-tool"
  timeout_s: 30
```

**Worked hook example** (bash, reads stdin only to discard it, writes to
stdout):

```bash
#!/usr/bin/env bash
cat >/dev/null   # the stdin JSON, unused here
echo "This repo's style guide: 2-space indent, no semicolons."
```

### Subscribing to outcomes (`hooks.post_stage`)

**What it does.** `hooks.post_stage` runs a shell command after every
verdict, approval, block, and merge is known -- the outcome-side counterpart
to `hooks.pre_dispatch` above. It fires from both the role-relay site (right
after each subagent's findings are posted and relayed) and every lifecycle
event (`pr-opened`, `merged`, `blocked`, `issue-closed`). Fire-and-forget,
same never-block contract: disabled by default, and a failure or timeout
never affects the pipeline.

**Contract.** The command receives this JSON on stdin (fields the caller
hasn't supplied yet, e.g. `sha`/`verdict`/`attempt` before they're known,
are `null` rather than omitted):

```json
{"event":"qa","role":"qa","issue":42,"pr":57,"repo":"owner/name",
 "sha":"<40hex or null>","verdict":"PASS","summary":"...","details":"...",
 "attempt":{"stage":"qa","count":1,"total":3},"model":"claude-sonnet-5",
 "runner":"claude","duration_s":312,"ts":"2026-09-07T14:00:00Z"}
```

`model` is read from `agents.roles.<role>.model`, falling back to
`agents.model`; `runner` from `agents.runner`. `duration_s` is `null` unless
the caller explicitly supplies it -- Talos doesn't time stage execution
today. `ts` is UTC, ISO-8601. `TALOS_ROLE` and `TALOS_ISSUE_NUMBER` are
exported to the command's environment. A non-zero exit or a timeout
(`hooks.timeout_s`, shared with `hooks.pre_dispatch`) is a silent no-op with
one line on stderr; there is no stdout contract to honor since nothing
consumes this command's output.

**Worked config example:**

```yaml
hooks:
  post_stage: "my-outcome-sink"
  timeout_s: 30
```

**Worked hook example** (bash, appends every event to a local JSONL file):

```bash
#!/usr/bin/env bash
cat >> "$HOME/.talos-events.jsonl"
```

This is exactly what Talos's built-in events log does out of the box for
every project -- see below -- so a custom `hooks.post_stage` command like
this one is only needed when the destination has to be something other than
the events log at `<git common dir>/talos/events.jsonl` (#517: outside every
git tree) -- a different path, a remote sink, etc.

### One script, both hooks

`hooks.pre_dispatch` and `hooks.post_stage` are independent config keys, but
nothing stops the same shell command from being wired to both -- the two
payload shapes never overlap, so a single script can tell them apart on
stdin and branch accordingly. A pre-dispatch payload always carries a
`files_hint` key (`null`/`[]` when the caller doesn't have one yet); a
post-stage payload always carries `event` and `verdict` keys instead. This
worked example (`scripts/talos-hook.sh` -- adjust the path for your own
project) uses that to serve both roles from one file: it prints context on
stdout for `pre_dispatch`, and appends the outcome to a local log for
`post_stage`.

```bash
#!/usr/bin/env bash
# scripts/talos-hook.sh -- wired to both hooks.pre_dispatch and
# hooks.post_stage (see the config snippet below). Dispatches on the stdin
# JSON's shape: a pre_dispatch payload always has "files_hint"; a post_stage
# payload always has "event" and "verdict".
set -euo pipefail

payload="$(cat)"
kind="$(printf '%s' "$payload" | python3 -I -c '
import json, sys
data = json.load(sys.stdin)
print("post_stage" if "event" in data else "pre_dispatch")
')"

if [ "$kind" = "pre_dispatch" ]; then
  # pre_dispatch: stdout is prepended to the stage prompt under "## Context".
  role="$(printf '%s' "$payload" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["role"])')"
  issue="$(printf '%s' "$payload" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["issue"])')"
  echo "Stage: $role, issue #$issue -- see docs/adr/ for prior decisions."
else
  # post_stage: no stdout contract -- append the outcome to a local log.
  printf '%s\n' "$payload" >> "$HOME/.talos-hook-outcomes.jsonl"
fi
```

**Config snippet (`talos.pipeline.json`):**

```json
{
  "hooks": {
    "pre_dispatch": "scripts/talos-hook.sh",
    "post_stage": "scripts/talos-hook.sh",
    "timeout_s": 30
  }
}
```

To read back what this hook (or the built-in events log below) recorded for
a given issue, prefer `scripts/pipeline-events.sh tail --issue 42` over
grepping the raw file -- it tolerates malformed lines and prints the
outcomes oldest-first.

### The built-in events log (`events.enabled`, `events.path`)

**What it does.** Every `hooks.post_stage` payload (the exact same JSON
schema shown above) is also appended, as one JSON line, to a local audit log
-- independently of whether `hooks.post_stage` itself is configured. Enabled
by default, so every project gets a durable local record of what happened in
a run for free, without wiring up an external sink.

**Dispatch markers (#550).** `talos.sh prompt` also appends one `stage_start`
line (`{"event":"stage_start","role":"orchestrator","stage":"qa","issue":7,"pr":9,"ts":...}`)
each time a stage prompt is rendered, so [the status line](#the-status-line) can show
the stage as running. It is written by `pipeline-hooks.sh stage_start`, which never
runs `hooks.post_stage`, and every `pipeline-events.sh cost` form skips it; `list`
and `tail` show it.

**Where.** The log path (`events.path`, default `talos/events.jsonl`) is
resolved relative to the **git common dir**, via `git rev-parse
--git-common-dir` -- not the current worktree's own `.git` dir, and not the
repo root. Every linked worktree of a repo shares one common dir
(git-common-dir(5)), so a developer/QA/reviewer stage running from inside a
per-issue worktree still appends to the single log file, never a
worktree-local copy. The log lives at `<git common dir>/talos/events.jsonl`,
OUTSIDE every git tree (#517): never staged or pushed, and an agent's
`git add -A` can never commit it. A relative `events.path` is joined onto
the resolved common dir; an absolute one is used as-is (the status line
refuses it). The deliberately in-tree `.talos/` files (the per-worktree
`.talos/env`, `providers.json`) are auto-ignored via
`.git/info/exclude` before their first write -- Talos never edits a tracked
`.gitignore`, and repos with tracked `.talos/` content get one stderr
warning per command and nothing else.

**Concurrency.** Appends are a single `printf '%s\n' >>` -- one `O_APPEND`
write syscall. A JSON event line is well under the POSIX `PIPE_BUF` atomic
threshold, so stages finishing concurrently (`issues.max_parallel` > 1)
interleave whole lines, never partial ones. No lock file is used or needed.

**Failure mode.** A failure to write (path unresolvable, permissions, disk
full) is a stderr note only -- it never changes `pipeline-hooks.sh`'s exit
code or affects the pipeline.

**Worked config example** (disable it, or point it somewhere else):

```yaml
events:
  enabled: true                 # default true
  path: "talos/events.jsonl"    # relative to the git common dir, unless absolute
```

**Reading the log.** Use `scripts/pipeline-events.sh` rather than parsing the
file directly -- it tolerates malformed lines and supports filtering:

```bash
bash scripts/pipeline-events.sh path
bash scripts/pipeline-events.sh list --issue 42 --role qa --last 20
bash scripts/pipeline-events.sh list --json
bash scripts/pipeline-events.sh tail --issue 42
```

`list`/`tail` print one line per matching event, oldest first: a compact
tab-separated table by default (`ts`, `event`, `role`, `issue`, `pr`,
`verdict`, `summary` truncated to 80 chars), or one JSON object per line with
`--json`. A malformed line is skipped, not fatal -- the count of skipped
lines is reported once on stderr.

**Cost accounting (`--tokens`/`--tool-uses`, `pipeline-events.sh cost`).**
`pipeline-hooks.sh post_stage` accepts `--tokens N` and `--tool-uses N`
alongside `--duration-s N`; each is validated as a non-negative integer and
lands in the payload/log line as `tokens`/`tool_uses`, or `null` when
omitted or invalid (one stderr note explains an invalid value). Summarize
the log with `bash scripts/pipeline-events.sh cost [--issue N] [--json]`: a
per-issue, per-role table (`issue`, `role`, `events`, `tokens`, `tool_uses`,
`duration_s`, `unrecorded`, `restamp`) with a `TOTAL` row, where `unrecorded`
counts events whose `tokens` field is `null` so an untracked group reads as
"no data", not a real zero (an explicit `--tokens 0` is a real zero and is
never counted in `unrecorded`). Whether `unrecorded` is expected depends on
the spawn path (see "Spawning" in `skills/pipeline/SKILL.md` and
`skills/pipeline/refs/harness.md`): on the native subagent path,
every stage is spawned so its completion notification carries usage, so an
`unrecorded` native-path event is a playbook bug worth investigating; on
the adapter path (`pipeline-agent.sh`) and pi inline mode, stages run
synchronously with no completion notification, so `unrecorded` there is
expected, not a bug. `restamp` counts events with verdict
`RESTAMP_PASS`/`RESTAMP_FAIL` (#258) — a cheap delta re-review of a PR the
same role already approved — separately from that group's full-stage
events/tokens (see "Stale approvals — cheap delta re-stamp" above). The
per-PR views of the same data (`cost --pr`, `--line`, `--markdown`,
`--summary`), the PR spend comment and the budget guard are in
[Seeing token spend](#seeing-token-spend-334).

### Seeing token spend (#334)

Talos records what each stage run cost (`--tokens`, see "Cost accounting"
above) and shows it in four places while a run is going, plus a status line
for your editor. Everything here reads the local events log, so it works
offline, and none of it blocks the pipeline: every spend call fails open.

**What the harness reports, and what it does not.** The Agent tool's
completion notification carries three numbers: `subagent_tokens`,
`tool_uses` and `duration_ms`, and only for a background or worktree spawn
(see "Spawning" in `skills/pipeline/SKILL.md`). There is no
input/output split, no cache figure, no model and no dollar amount. UNVERIFIED
beyond those observed fields: whether the one token total includes cache
reads. For that reason Talos shows tokens, never a price, and the model it
shows is the **requested model** (the `model:` the playbook passed when it
spawned the stage, recorded with `post_stage ... --model M`), not one the
harness reported back. Without the flag it falls back to the role's model,
then `agents.model`; a stage with none of them shows as `session default`.

**What "unrecorded" means.** A stage run is **unrecorded** when its `tokens`
field is `null` or not a finite non-negative number (see "Cost accounting"
above for when that is expected). It is shown as "unrecorded", never as 0, and
a total carries it as `(+K unrecorded)`: the figure is a floor, not an exact
sum. An explicit `--tokens 0` is a real zero, not unrecorded. Where nothing is
recorded at all, the line says `tokens unrecorded` or `total unrecorded`. One
known wrinkle: the `--markdown` table prints `0` in its tokens cell for a row
that is entirely unrecorded (tracked on #357), so read its `unrecorded` column
instead of the tokens cell.

**1. The harness line.** After each role-relay `post_stage`, the playbook
prints one line, from `bash scripts/pipeline-events.sh cost --issue N [--pr M]
--line`:

```
talos: #770 reviewer done — tokens unrecorded, 1m00s · PR total 1.69M (+1 unrecorded) (dev 1.57M, qa 120k) · budget 84% of 2M
```

The reference is `PR total` when `--pr` is given, otherwise `issue total`. The
` · budget 84% of 2M` tail appears only in the warn and exceeded states and
only when the guard is on. The line is at most 200 characters. With no log or
no events it prints nothing and exits 0.

**2. The PR spend comment.** One comment per PR, edited in place on every
refresh, so a PR never collects a pile of spend comments. It is on by
default, and posted only when `comments.enabled` is true and `spend.comment`
is not `false`; the provider must be `github` or `github-api` (any other
provider silently skips it). **On a public repo the comment is public**: anyone
can read the token totals, model names and durations in it, so set
`spend.comment: false` if that is not something you want to publish. The body is `cost --issue N [--pr M]
--markdown`: the `comments.header` line, a per-stage table (stage, model,
runs, tokens, tool uses, duration, re-stamps, unrecorded), a TOTAL row, a
`This PR (#M)` subtotal, the budget line when the guard is on, and a note on
what the harness reports. It covers the whole issue (it matches `cost
--issue N`); a stage that ran before the PR existed counts only in the issue
total. It is refreshed after each role-relay `post_stage` and once after
`merged`, and it still works on a merged PR.

It is written by `bash scripts/pipeline-vcs.sh upsert-pr-comment <pr>
--marker spend --body-file <path>`: it edits the newest comment by the
authenticated user whose last non-blank line is the marker, writes nothing
when the body is unchanged, and prints `upserted pr=<n>
comment=created|updated|unchanged`. Exit 0 is success; exit 2 is a usage
error, an unknown marker name (a contract marker without the `talos:` prefix),
a bare `-` as a positional argument, or a provider other than the two above
(the playbook treats rc 2 as silent); exit 1 is an unreadable or empty body, a
body over the 65536-character or byte cap, an unresolved authenticated user,
an unreadable comment list or a failed write. It never posts a blind
duplicate; `--dry-run` prints the planned calls.

Two caveats. Under an Actions `GITHUB_TOKEN` or a GitHub App token the
authenticated-user lookup (`GET /user`) fails, so the upsert exits 1: it is
reported once as one line in the run summary, never retried, and never blocks.
And a login that contains `_` (the Enterprise Managed User style, for example
`name_corp`) currently fails closed at the same check and also exits 1; that
is tracked on #357, so do not rely on it there.

**3. The run summary.** Step 5 of the playbook makes one `cost --summary
--issue A [--issue B ...]` call and prints the block: one row per issue and PR
(plus `pre-PR` rows), `Top PRs:` (up to 3), `Per issue:` and `Total:`, at most
20 lines. Each row ends with a `stage models` column: each stage and the
models it ran with, in first-seen order (past 8 stages the rest fold into
`+K more`). "A run" is just the set of issues you pass; there is no run id.


**Which commands exit how.** `cost` exits 0 on success, with no log and when
the formatter module is missing; it exits 2 (usage) for `--line`, `--markdown`
and `--summary` used together, `--line` or `--markdown` without `--issue`,
`--summary` without an `--issue`, an `--issue` or `--pr` that is not digits
only, or a value-taking option with no value. The default `cost` table is
unchanged and still lists the `orchestrator` rows (the budget-blocked marker),
so its TOTAL `unrecorded` can be higher than the figure in the new outputs,
which leave those rows out: the `--line`, `--markdown` and `--summary`
outputs, the status line, the budget guard and the log tag.

#### The budget guard

The guard is **off by default**. It turns on only when
`limits.tokens_per_issue` is set in the repo's config. Keys (all three are
valid in the repo's `talos.pipeline.json` and, to share one budget across
repos, in the user-level file under `~/.talos`):

- `limits.tokens_per_issue`: unset or `0` means the guard is off, silently. A
  positive integer is the per-issue token budget. A negative, boolean,
  fractional or non-numeric value prints one stderr warning and is treated as
  off, as is a value above 10^15.
- `limits.warn_at`: default `0.8`; a number with `0 < x <= 1`. Anything else
  prints one warning and uses `0.8`. At `1` the warn state never shows,
  because exceeded wins first.
- `spend.comment`: default `true`; a strict boolean, anything else warns once
  and uses `true`.

The playbook checks the budget once before each developer fix round: the
merge-base task, the draft fix round, and the QA, reviewer, security and
adversarial rounds, that is fix rounds only. It never checks before a
first-pass stage, a re-stamp or a merge. Only recorded tokens count, so
unrecorded runs are not added up, and the guard cannot trip on an adapter or
pi run. It fails open: no log, no events, a tool error or a crash is
`unknown` and exit 0.

`bash scripts/pipeline-budget.sh check --issue N [--json]` prints one line,
`talos:budget <ok|warn|exceeded> issue=N used=.. limit=.. effective=..
pct=.. unrecorded=..`, or `talos:budget unknown issue=N
reason=<no-events|events-unavailable|error>`; with the guard off it prints
nothing. The exit code is **0** for ok, warn, unknown and guard-off, **1** for
exceeded only, and **2** for a usage error (including a non-numeric `--issue`).
A caller under `set -e` must capture the code rather than test it inline.

- **warn** (at or above `limits.warn_at`) is relayed in the harness at the next
  check and shown in the PR comment's budget line. It stops nothing.
- **exceeded** makes the playbook set `pipeline:blocked` on the PR and the
  issue, record a `budget-blocked` event and post a blocked comment.

To continue, the owner either removes `pipeline:blocked` or raises
`limits.tokens_per_issue`. Removing the label works because each recorded
`budget-blocked` event grants one more full limit: the effective limit is the
limit times (1 + grants). The grant exists as soon as the block is recorded,
so after one block the harness line, the PR comment and the status line show
`of 8M` for a 4M key: each block grants one more limit, and the number shown
is the effective limit, not the key.

#### The status line

`talos-status.sh --line` prints one line for a harness status bar (#385, #550):

```
talos #7 qa ●●●◐○○ 3.41M
```

`<issue> <stage> <dots> <tokens>`. The dots are validator, pm, developer, review
(reviewer, security, adversarial), qa, merge, in that order: `●` done, `◐` running,
`○` pending. A role switched off in the config (`roles.<role>: false`) has no dot,
and neither has a validator or pm stage that never ran once a later stage has
begun. A failing verdict (`FAIL`, `CHANGES`, `FINDINGS`, `BLOCKED`) sends the work
back: the developer shows pending again, and so do the gates after a new developer
push. Tokens are the issue's total so far, formatted like every spend figure
(`pipeline-spend-format.py`). With no active issue (none yet, or the issue merged)
it prints nothing.

It is offline and costs no model tokens. It reads the events log, and it exits 0
on every input (an unknown option, no log, not a git repo): a status bar must
never show an error.

- **Which issue.** The current branch (`fix/issue-<N>-...`, `feat/issue-<N>-...`),
  else the issue of the newest event.
- **Running.** `talos.sh prompt` (the one step the playbook and `talos.sh run` both
  take for every dispatched stage) writes a `stage_start` event through
  `pipeline-hooks.sh stage_start`. A stage is running while that event is newer than
  the role's last finishing event, and for at most 6 hours, so a crashed run never
  stays "running". The event is recorded under role `orchestrator`: no cost or
  spend report counts it, and `hooks.post_stage` does not fire for it.
- **Live tokens.** Claude Code runs the `statusLine` command and passes it a JSON
  object on stdin, including `transcript_path` (the session transcript;
  [Claude Code status line docs](https://code.claude.com/docs/en/statusline)). While
  a stage is running, the line adds the usage written since that stage started:
  input + output + cache-creation tokens, the measure the events record (cache reads
  are not counted), from the transcript and from the subagent transcripts next to it
  (`<transcript minus .jsonl>/subagents/agent-*.jsonl`; that layout is what Claude
  Code writes today, not a documented contract). Each message id counts once. The
  count rises as the agent works; at the stage end the recorded figure from
  `talos.sh done` takes over. Claude Code does not count subagent requests in its own
  `context_window` or `cost` fields, which is why the transcripts are read. Limits:
  only the last 8 MB of a transcript is read, a stage run by `talos.sh run` through
  a CLI runner (`pipeline-agent.sh`) lives in another process's transcript and shows
  up at the stage end, and a `/clear` in the middle of a stage drops the earlier
  part. A harness that passes nothing on stdin gets the recorded total only.
- **Config.** Only `roles.*` and `events.path` are read, as JSON, from the project's
  `talos.pipeline.json` over `${TALOS_HOME:-~/.talos}/talos.pipeline.json`. There is
  no `statusline.yml` any more, and no style, segment or width option.
- **Log limits.** `events.path` must stay under the git common dir (an absolute path,
  a `..` that leaves it, or a symlinked log prints nothing). Only the last 16 MB of
  the log is read and the whole run is cut off after 3 seconds
  (`TALOS_STATUS_TIMEOUT_S`, an integer 1 to 10). `TALOS_STATUS_DEBUG=1` prints a
  stderr note saying why nothing was printed. A 17 MB transcript adds about 190 ms;
  a normal one is far less.

**Claude Code.** `install.sh --global` wires it: when the Claude adapter runs it
sets `statusLine` in `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json`)
to `bash '<TALOS_HOME>/scripts/talos-status.sh' --line`, next to the
`pipeline-spend-format.py` module it imports. The edit is idempotent, keeps every
other key, writes through a symlinked settings file, and never replaces a
`statusLine` that is not Talos's: it prints the existing command and how to chain
the Talos line into it (call the command from yours, keep Claude's JSON on its
stdin, print its output next to yours). A settings file that does not parse is left
alone with a notice. By hand:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.talos/scripts/talos-status.sh --line"
  }
}
```

Claude Code re-runs the command after each assistant message (debounced to 300 ms)
and, with the optional `refreshInterval` (seconds, minimum 1), on a timer; set one
to keep the count moving while only background subagents work.

**Other harnesses.** Call `talos-status.sh --line` from the harness's own status or
footer hook, with the repository as the working directory. pi has no command hook
for its footer (its footer is set by a TypeScript extension through `ctx.ui`), so
nothing is installed for it.

### Notification templates, transpiled per platform

**What it does.** There is **one neutral template per event** -- 14 shipped
files, written once in a small markdown dialect (`**bold**`, `[text](url)`,
`- ` bullets, blank-line paragraphs, at most one leading `### ` heading) --
and a transpiler turns that dialect into each sink's native syntax right
before delivery, so a notification still comes out looking native to Slack,
Discord, Teams, or Buzz without the template author writing four versions of
it. Templates live under `notifications.templates_dir` (default
`templates/notifications`):

```
templates/notifications/
  <event>.md   # e.g. validator.md, qa.md, blocked.md, pr-opened.md, ...
```

**Layout.** Every shipped template is the same three lines:

```
${HEADLINE}

${REF_LINK}

${SUMMARY}
```

`${HEADLINE}` (line 1) is assembled by the script, not the template --
`${ROLE_ICON} **${ROLE_LABEL}** — ${VERDICT or action} · ${REF}`, with `${REF}`
itself linked to the issue/PR URL when one is known (the PR's URL for
`pr-opened`/`merged`, otherwise the issue's) -- so which agent is speaking and
its verdict is always the first thing a reader sees. `${REF_LINK}` (line 2) is
the issue/PR title, once. `${SUMMARY}` is `${MSG}` with its verdict token
(and, for `blocked`, a leading `<stage>:`) stripped off, and is never fenced.

**Root vs. reply.** A post with no thread anchor yet is the root -- the first
message for that issue -- and gets the full card: `${HEADLINE}`, the
`${REF_LINK}` title line, the native metadata construct (fields/FactSet), and,
on Slack/Discord, a `repo · event · ref` context footer (Slack's `context`
block, Discord's embed `footer`). A threaded reply (same issue, an anchor
already on file) drops **both** the title line and the metadata block -- the
root above already carries them -- and renders as just `${HEADLINE}` plus
`${SUMMARY}` as the body; Slack/Discord replies still carry the context
footer, Buzz replies carry neither footer nor metadata, just the headline and
body. This is exactly why `${REF}` inside `${HEADLINE}` is linked: it is a
reply's *only* click-through to the issue/PR. Teams never threads (see
[Environment variables](#environment-variables) above), so every Teams post
is a root card.

**The transpiler.** The formatter in `pipeline-notify.sh` (`to_platform()`, one
dialect table per sink) runs on the rendered text right before each payload
formatter consumes it:

| Sink | Transpiles to |
|------|---------------|
| Slack | mrkdwn -- `**bold**` -> `*bold*`, `[text](url)` -> `<url\|text>`, a heading -> a bold line, `- ` -> `• ` |
| Discord | native CommonMark, unchanged -- bold/links/`- ` render as-is; a heading becomes a bold line (embeds have no heading syntax) |
| Teams | same rules as Discord -- the heading/first line becomes the Adaptive Card's Bolder TextBlock, the rest a wrapping TextBlock; links stay markdown |
| Buzz | pass-through GFM -- Buzz renders `remark-gfm`, so the dialect needs no transpiling |

It also tidies whatever an unavailable variable leaves behind -- an empty
link target, a dangling `·` separator, an empty `**bold**` run -- so a
template never needs a conditional: `[PR ${PR}](${PR_URL})` simply
disappears when there is no PR.

The metadata (PR / Issue / Stage / Repo) is rendered by the sink, not the
template, and **only on root messages** (see "Root vs. reply" above): Block
Kit `fields` on Slack, embed `fields` on Discord, an Adaptive Card `FactSet`
on Teams (always, since Teams has no reply state), one compact
`repo · [PR #n](url)` line on Buzz (in place of a four-row GFM table, since
the role is already on line 1). A sink is "rich" whenever a template resolved
at all -- only `notifications.cmd` (which never gets one) and a project that
has deleted its templates fall back to the shared fenced monospace grid.

**Per-platform files are a valid, optional project override.** Talos ships
none itself, but a project may still drop
`templates/notifications/<platform>/<event>.md` to hand-tune one sink --
useful for a Slack workspace with unusual mrkdwn conventions, say. Resolution
order per platform, first hit wins:

1. `<project>/<templates_dir>/<platform>/<event>.md`
2. `<project>/<templates_dir>/<event>.md`
3. `~/.talos/<templates_dir>/<platform>/<event>.md` (shipped, platform-specific -- none by default)
4. `~/.talos/<templates_dir>/<event>.md` (shipped, neutral)

The project copy wins at **both** layers. An existing single-level
`templates/notifications/<event>.md` override therefore keeps winning over a
shipped platform template -- nothing to migrate, no config change.

**Adding your own.** Create `templates/notifications/<event>.md` (or
`templates/notifications/<platform>/<event>.md` to override one sink only)
in your repo and use only the documented variables (`ICON`, `EVENT`, `MSG`,
`REF`, `ROLE`, `TITLE`, `REF_TITLE`, `PR`, `PR_TITLE`, `PR_REF`, `BOARD`,
`REPO`, `ISSUE_URL`, `PR_URL`, `REF_LINK`, `PR_LINK`, `VERDICT`, `SUMMARY`,
`HEADLINE`, `ROLE_ICON`, `ROLE_LABEL`) -- anything else renders as a literal
`${NAME}`. The shipped `templates/notifications/qa.md`:

```markdown
${HEADLINE}

${REF_LINK}

${SUMMARY}
```

**Previewing without posting.** `--render` resolves the template, renders it,
transpiles it, and prints the exact payload that platform would send, then
exits 0 -- it posts nothing, reads and writes no thread anchors, and ignores
the `notifications.events` filter. It always previews the **root** form
(title line + metadata) -- with no thread state touched, it has no anchor to
treat as an existing thread:

```bash
bash ~/.talos/scripts/pipeline-notify.sh --render buzz qa "#42" "PASS: 3 criteria verified"
```

```
# platform: buzz
# event:    qa
# template: /Users/you/.talos/templates/notifications/qa.md
# rich:     yes

🧪 **QA** — PASS · [#42](https://github.com/acme/widget/issues/42)

[#42 Fix login crash](https://github.com/acme/widget/issues/42)

3 criteria verified

acme/widget
```

`<platform>` is `slack`, `discord`, `teams`, `buzz`, or `default` (the
neutral rendering `notifications.cmd` receives). `rich: no` means no template
resolved at all and the sink will use the monospace-grid fallback.

### A generic notification sink (`notifications.cmd`)

**What it does.** `notifications.cmd` runs a shell command (via `sh -c`) for
every pipeline event that passes the `notifications.events` filter, after
Slack/Discord/Teams/Buzz. This is how a sink Talos doesn't natively support
-- a local desktop notifier, a webhook relay, a log shipper -- gets wired in
without a code change. Disabled by default -- an absent or empty
`notifications.cmd` runs nothing.

**Contract.** The command receives this JSON on stdin:

```json
{"event": "pr-opened", "ref": "#42", "message": "🔀 [talos] pr-opened #42 — ...",
 "thread_key": "42", "fields": [{"label": "PR", "text": "#9", "url": "https://github.com/acme/widget/pull/9"}],
 "repo": "acme/widget", "issue": 42}
```

`message` is the same rendered text every other sink builds its message
from. `fields` is the same platform-neutral metadata table (PR/Issue/Stage/
Repo) Slack/Discord/Teams/Buzz render natively -- each entry carries `label`,
`text`, and `url` (empty string when there's nothing to link). A missing
command, a non-zero exit, or a timeout (`notifications.cmd_timeout_s`,
default 10s) is a silent no-op with one line on stderr -- it never blocks the
pipeline or any other sink, and this script still exits 0.

**Worked config example:**

```yaml
notifications:
  cmd: "my-notify-tool"
  cmd_timeout_s: 10
```

**Worked command example** (bash, writes the message to a local desktop
notification):

```bash
#!/usr/bin/env bash
payload="$(cat)"
msg="$(printf '%s' "$payload" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["message"])')"
terminal-notifier -message "$msg" -title "Talos"
```

### Nightly canary against a real sandbox repo

`bash tests/run-tests.sh` never touches a real API -- `gh`, `curl`, `glab`,
and `az` are all stubbed. `.github/workflows/canary.yml` runs nightly (and
on `workflow_dispatch`) and closes that gap: `tests/canary/run.sh` drives a
minimal issue → PR → approval → merge-gate flow through real `gh`/REST calls
against a dedicated sandbox repository, for both the `github` and
`github-api` providers, then deletes everything it created.

Setup (skip either step and the job is a clean no-op -- it prints
`talos:canary-skipped reason=...` and exits 0):

1. Create a sandbox repository -- not a real project repo -- the canary can
   freely open and close throwaway issues/PRs against. It can start with
   zero labels: the canary run bootstraps the Talos `pipeline:*`/`qa:*`/etc.
   labels into it itself before exercising any flow.
2. On the Talos repo, add repository variable `TALOS_CANARY_REPO`
   (`owner/repo` of the sandbox) and repository secret `TALOS_CANARY_TOKEN`:
   a fine-grained PAT scoped to the sandbox repo with `issues`,
   `pull requests`, and `contents` write access.

See the README's [Tests](../README.md#tests) section for what each of the
canary's two jobs (`base-currency`, `real-api`) checks.

### Recommended CI workflow template

`templates/ci/github-tests.yml` is a **recommendation**, not something Talos
enforces -- your repo's CI cadence and cost are your call. It skips
docs-only pushes, cancels superseded runs on the same branch, runs pull
requests on `ubuntu-latest` only, and runs the full OS matrix on pushes to
the base branch. `/talos:setup` offers to write it to
`.github/workflows/tests.yml` when no existing workflow already runs your
test suite, and it never edits a workflow that already exists -- if one is
already running your tests, it only prints a one-line note about the
`paths-ignore`/`concurrency` knobs it's missing, in case you want to add
them by hand. Talos dogfoods this exact template in its own repo.

If `merge.required_checks` names a job that this template no longer runs on
PRs (macOS, e.g. `test (macos-latest)`), **remove it -- or the merge gate
will wait forever**: QA's CI-wait loop (`pipeline-vcs.sh
pr-checks-required`) will wait for a check that will never appear on the PR
until `verify.ci_wait_s` elapses and it fails closed, on every single PR.
Only `test (ubuntu-latest)` is safe to name under this template. See the
README's [CI](../README.md#ci) section.

## Customizing agent profiles

Each role profile is a markdown file with YAML frontmatter (Claude Code
metadata) and the role's instructions as the body. Where they live — and
whether you should edit them in place — depends on how Talos was installed.

**Vendored install.** The profiles land at `.claude/agents/*.md` and are yours
to edit. `install.sh` never overwrites existing files unless you pass `--force`,
so local customizations survive re-installs (and `--force` wipes them — keep
customized profiles in your repo's git history).

**Plugin install.** The profiles ship inside the plugin at `agents/*.md` and are
copied into `~/.claude/plugins/cache/`, which is replaced wholesale on every
`/plugin update` — edits there are silently lost. Do not edit them in place.

**Global install (`install.sh --global`).** The profiles land at
`~/.claude/agents/*.md` (read by Claude Code's native subagent discovery) and
`~/.talos/agents/*.md` (read by `pipeline-agent.sh` for non-Claude harnesses).
Re-running `--global` overwrites both by default; pass `--no-overwrite` to
preserve local edits. As with a vendored install, a repo-level
`.claude/agents/<role>.md` always wins over the global copy for that role.

To customize a role, add your own `.claude/agents/<role>.md` to the repo. The
orchestrator checks for a repo-level profile before falling back to the plugin's
namespaced `talos:<role>`, so your file wins for that role while the other seven
keep coming from the plugin. Override only what you need, and it stays
version-controlled with the code it reviews.

`pipeline-agent.sh` (the non-Claude harness adapter) resolves a role profile in
this order: `<repo>/.claude/agents/<role>.md`, then the harness-neutral
`<repo>/.agents/talos/agents/<role>.md`, then the install (`~/.talos/agents/`,
or `$TALOS_HOME/agents/`), then the plugin's own layout. The neutral path is for
non-Claude harnesses (the adapter path, `agents.subagents: false`, and pi inline
mode): commit a role override there and it is picked up without a `.claude/`
directory. Native Claude Code subagents still load `.claude/agents/` only, so
`.claude/agents/<role>.md` stays first and the neutral file is never read on that
path. A symlinked neutral file or directory is skipped, and a role name is
`[a-z][a-z0-9-]*` (lowercase, starting with a letter), otherwise the script exits 2. To see which file a role
resolves to, run `pipeline-agent.sh --resolve-profile <role>` (prints one absolute
path; exits 1 listing the locations searched when none exists). `--resolve-all`
warns on stderr when both files exist (the neutral one is shadowed) or when only
the neutral one exists but the role runs natively on Claude. No new config key.

The neutral location is `.agents/talos/agents/`, not `.talos/`, because `.talos/` is
ephemeral state: this repo's own `.gitignore` ignores it, and in a consumer repo it
holds run state such as the events log. An override has to be tracked
and reviewed with the code, so it lives in a directory that is committed.

**Adding skills to a profile (Claude Code):** two supported mechanisms:

```yaml
---
name: reviewer
tools: Bash, Read, Grep, Glob, Skill   # "Skill" lets the agent INVOKE skills at runtime
skills:                                 # preloads full skill content at startup
  - code-review
---
```

- `skills:` — preloads the listed skills' full content into the agent's
  context at startup. Best when the role should *always* apply the skill.
  Skills are referenced by name and must exist in `~/.claude/skills/`,
  `.claude/skills/` (project), or an enabled plugin.
- `Skill` in `tools:` — lets the agent invoke any available skill on demand.
  Best for "use X if available" guidance. Note: when a profile sets a
  restrictive `tools:` list, the agent can only invoke skills if `Skill` is
  in that list — Talos ships QA/reviewer/security with it included, since
  their instructions reference the built-in `verify`/`code-review`/
  `security-review` skills.

Other useful frontmatter fields: `disallowedTools`, `maxTurns`, `memory`.
Do not add `model:` to a role file: Talos agents ship without it so the Talos
config (see [Per-role model selection](#per-role-model-selection-agentsrolesrolemodel))
is the only place a model is set, and `pipeline-agent.sh --resolve-all` warns
about a role file that still carries one. See the
[Claude Code sub-agents docs](https://code.claude.com/docs/en/sub-agents) for
the full list.

**On other harnesses (Codex / Gemini / custom):** frontmatter — including
`skills:` — is Claude Code metadata and is stripped by `pipeline-agent.sh`.
Only the profile **body** reaches the runner. To customize a role there,
write the instructions (or paste the relevant skill content) directly into
the body — it flows into every stage prompt on every harness. Skill packs
published for multiple agent tools can also be installed cross-harness with
[`npx skills add <owner>/<repo>`](https://github.com/vercel-labs/skills).

### Per-role model selection (`agents.roles.<role>.model`)

> **Config format (#526):** config is JSON only, in exactly two canonical files.
> The key paths (`agents.model`, `agents.roles.reviewer.model`, etc.) and their
> defaults are unchanged.

**What it does.** Sets the LLM model for a specific role when the orchestrator
spawns it as a native subagent. This lets you run a cheap global model for
high-volume, machine-verifiable work (implementation, docs) while routing
judgement-heavy roles (reviewer, security) to a higher-quality model.

**Default.** Each role inherits `agents.model`. If `agents.model` is also
absent, the subagent inherits the session model. You only need to set
`agents.roles` for roles where you want to deviate from the global default.

**Set it once for every repo (user-level config).** The Talos config is the
only place a role's model is set (the shipped agent files carry no `model:`
line). Talos reads two config files: this repo's own `talos.pipeline.json` and
the user-level `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json`, and merges the
repo config over the user-level one key by key, so the repo wins wherever both
set the same key.

- Only the `agents.*` subtree is read from the user-level file. Any other key
  there (board, merge, issues, verify, ...) is ignored with one warning naming
  it, because those settings describe a repo, not a user.
- **Every `agents.*` key in the user-level file applies to every repo**, not
  just models: `agents.runner`, `agents.runner_args` and
  `agents.roles.<role>.runner_cmd` are layered the same way, and the adapter
  path executes `runner_cmd` as a shell command. Keep only settings and
  commands you trust in every repo in that file; a repo's own config can
  override a key but cannot remove the file's other keys.
- A missing, unreadable, empty, malformed or non-mapping user-level file
  behaves as absent; malformed content prints one warning and never changes a
  lookup's exit status. The file is parsed as data only, never executed.
- The layer sits under whichever project config is found, including one named
  by `$PIPELINE_CONFIG`.
- Every chain (`restamp_model`, `effort`, `restamp_effort`, per-role `runner`)
  is evaluated on the merged config, so a user-level `agents.model` is also the
  bottom of a repo's re-stamp chain.

```json
// ~/.talos/talos.pipeline.json  (every repo)
{
  "agents": { "model": "sonnet", "roles": { "security": { "model": "opus" } } }
}
```

```json
// <repo>/talos.pipeline.json  (this repo only: qa on haiku, the rest follow the user-level file)
{
  "agents": { "roles": { "qa": { "model": "haiku" } } }
}
```

`/talos:setup` asks once how you want models assigned (one model for every
role, one per role, or leave unset) and writes the answer to the user-level
file, showing a diff and asking for a yes before it changes an existing one.
`install.sh --global` never touches that file; it prints one hint line when no
user-level config sets a model.

**See what every role runs on.**

```
$ bash scripts/pipeline-agent.sh --resolve-all
role=validator model=sonnet restamp_model=sonnet origin=global
...
role=qa model=haiku restamp_model=sonnet origin=project
role=security model=opus restamp_model=sonnet origin=global
```

One line per role: the model, the re-stamp model, and the layer that decided the
model (`project`, `global` for the user-level file, or `session default` when
nothing sets one). It also warns on stderr when `.claude/agents/<role>.md` or
`~/.claude/agents/<role>.md` still carries a `model:` frontmatter line, since
that line would apply whenever the config resolves empty. The columns are
separated by spaces, so a space or `%` inside a value is percent-encoded
(`%20`, `%25`) and a value cannot add a column; a `runner_cmd=` field comes
last, after a TAB, and is printed as is. `--resolve <role>`
keeps its one-line `runner=... model=... effort=...` output.

**Model names.** A value is a full model ID or one of the aliases `opus`,
`sonnet`, `haiku`, passed through as typed. When the harness's Agent tool
accepts only aliases, the orchestrator maps a full ID to its family alias when
it spawns; the config value is never rewritten.

**Upgrading from 0.18.x.** Earlier versions shipped `model: opus` (and `haiku`
for docs) in the agent frontmatter, so a repo with no `agents` block ran eight
roles on Opus. That line is removed: if you never configured models, roles now
run on the session model until you run `/talos:setup` or set
`agents.model` / `agents.roles.<role>.model`. Re-run `install.sh --global` to
refresh the copies under `~/.claude/agents/` and `~/.talos/agents/`.

**Worked config example:**

```yaml
agents:
  model: claude-haiku-4-5-20251001   # default for all roles
  roles:
    reviewer:
      model: claude-opus-5           # upgrade only the reviewer
    security:
      model: claude-opus-5           # and the security auditor
```

This config routes six roles (developer, pm, validator, qa, docs, planner) to
`claude-haiku-4-5-20251001` and two roles (reviewer, security) to
`claude-opus-5`. Two overrides rather than eight entries.

**Footgun -- silent no-op on adapter-path harnesses.** `agents.roles.<role>.model`
is read and applied **only** when the orchestrator spawns native subagents (Claude
Code, `subagents: true` or `agents.subagents: auto` with `runner: claude`). On
the adapter path (`subagents: false`, runner: `codex` / `gemini` / `antigravity`
/ `custom` / `pi`) the `agents.roles` block is never read -- `pipeline-agent.sh`
ignores it entirely and the pipeline produces no warning or error. A user on
`runner: codex` who sets `agents.roles` and sees no change in behaviour has no
discoverable symptom: the pipeline runs normally at whatever model the runner
uses by default.

The model-resolution logic for the native path is in `skills/pipeline/SKILL.md`
("Spawning") and `skills/pipeline/refs/harness.md`: the orchestrator reads
`agents.roles.<role>.model`, falls back to `agents.model`, then omits `model:`
entirely if neither is set.

On adapter-path harnesses, model routing is done by the runner via the
`$TALOS_ROLE` environment variable in `runner_cmd`. State this constraint
explicitly in your config comments to prevent confusion when switching harnesses.

If you are on an adapter-path harness and want per-role model control, set the
model in `runner_cmd` conditional on `$TALOS_ROLE`:

```yaml
agents:
  runner: codex
  runner_cmd: |
    case "$TALOS_ROLE" in
      reviewer|security) MODEL="o3" ;;
      *) MODEL="o4-mini" ;;
    esac
    codex --model "$MODEL" --role "$TALOS_ROLE" -
```

### Per-role reasoning effort (`agents.roles.<role>.effort`, #271)

A finer lever than model swap alone: `agents.effort` / `agents.roles.<role>.effort`
set the reasoning effort (`low` | `medium` | `high` | `max`) with the same
role-first precedence as `agents.model` above. Unlike `agents.roles.<role>.model`,
this key is **not** a silent no-op on the adapter path: `pipeline-agent.sh`
resolves it for every runner and exports it as `TALOS_EFFORT`, so a `runner_cmd`
can map it onto that CLI's own effort/reasoning flag exactly the way `$TALOS_ROLE`
routes by role. On the native path (`claude`), it is advisory only — there is
no per-spawn Agent tool parameter for effort, and the orchestrator never
writes to a role file at spawn time, so the value that actually runs is
whatever `effort:` (if any) is already committed in the role's frontmatter.
A resolved config value that disagrees with the committed frontmatter just
gets a one-line notice from `pipeline-agent.sh --check-effort <role>`, not a rewrite. See the README's
[Per-role reasoning effort](../README.md#per-role-reasoning-effort-agentseffort-and-agentsrolesroleeffort)
section for the full precedence chain, the re-stamp variant
(`agents.restamp_effort`), and a worked config example.

### Per-role runner override (`agents.roles.<role>.runner` / `.runner_cmd`)

**What it does.** Unlike `agents.roles.<role>.model` above, this key is read
on **both** execution paths -- native subagents and the `pipeline-agent.sh`
adapter. `agents.runner` picks one backend for the whole pipeline;
`agents.roles.<role>.runner` overrides it for a single role, resolved
role-first: the role's own key wins when set, else `agents.runner` (default
`claude`). `agents.roles.<role>.runner_cmd` follows the same precedence and
is only read when the resolved runner is `custom`. `agents.runner_args`
stays global-only -- there is no per-role `runner_args` in this release.

**On the native path** (Claude Code, `subagents: true`), the orchestrator
resolves the effective runner for each role *before* deciding how to spawn
it: a role whose effective runner is `claude` still spawns as a native
subagent; a role whose effective runner is anything else is dispatched
through `bash scripts/pipeline-agent.sh <role> -` with the stage prompt on stdin
(a heredoc whose `TALOS_<rand>` delimiter is invented fresh per spawn, because
the prompt carries issue-derived text that could contain a fixed closing line)
instead -- even though the rest of the pipeline is otherwise running
natively. This is the fix for the model footgun described above: a role
routed off `claude` no longer silently keeps using the native path at
whatever default the harness happens to apply -- it is dispatched through
the adapter, which is where `runner_cmd` and `$TALOS_ROLE` routing actually
take effect.

**On the adapter path** (`subagents: false`), `pipeline-agent.sh` already
resolves this precedence internally -- no config or prompt change is needed
to get per-role behaviour there; it is the same lookup either way.

**Check what a role will actually use** without running anything:

```bash
bash scripts/pipeline-agent.sh --resolve reviewer
# runner=custom runner_cmd=my-endpoint model=
```

**Worked example -- second opinion on a local model.** Give one role (here,
`security`) an independent pass through a local model served by llama.cpp,
while every other role keeps running natively on Claude:

```bash
# --jinja enables tool/function calling -- agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

```yaml
agents:
  runner: claude                 # everything else stays native
  roles:
    security:
      runner: custom
      runner_cmd: >-
        OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local
        aider --model openai/local --yes-always --no-auto-commits --message "$(cat)"
```

Only `security` pays the local round trip; the other seven roles are
unaffected. This is the enabling piece for a second, independent review pass
on a different backend, which the dedicated `adversarial` stage below
actually uses.

### Switching providers / profiles (`agents.profile`, `TALOS_PROFILE`, #539)

Moving from Claude (a different subagent model per role) to Ollama Cloud or a
local LLM (one model for every role) used to mean editing `agents.runner`,
`agents.subagents` and `agents.model`, deleting every `agents.roles.*.model`
(a Claude model id left in a role leaks into a pi or Ollama dispatch), and
undoing all of it afterwards. A **profile** is a named bundle of `agents.*`
keys, so the switch is one word:

```json
{
  "agents": {
    "profile": "claude",
    "fallback": ["local"],
    "profiles": {
      "claude": {
        "mode": "native",
        "model": "sonnet",
        "roles": {
          "planner": {"model": "opus"},
          "security": {"model": "opus", "restamp_model": "opus"},
          "adversarial": {"model": "opus", "restamp_model": "opus"}
        }
      },
      "local":  {"runner": "pi", "mode": "inline", "subagents": false, "model": "glm-5.3-flash"},
      "ollama": {"runner": "custom", "mode": "adapter", "subagents": false,
                 "runner_cmd": "ollama-agent --model $TALOS_MODEL", "model": "qwen3-coder:480b-cloud",
                 "stage_timeout_s": 1800}
    }
  }
}
```

Run `TALOS_PROFILE=local` (or edit the one `agents.profile` value) and nothing
else changes. A profile holds any subset of the `agents.*` keys plus `mode`;
profiles may sit in the user-level file (`~/.talos/talos.pipeline.json`) and be
selected from a repo's file. With no profiles configured, nothing changes.

- **Order.** For any `agents.*` key: the environment, then the selected profile,
  then the base `agents.*`, then the table default. The profile's `roles` block
  **replaces** the base `roles` block whole, so put per-role Claude models inside
  the Claude profile (as above); a profile with no `roles` key keeps the base
  roles, and `"roles": {}` clears them.
- **Unknown profile.** `TALOS_PROFILE=nope` (or a typo in `agents.profile`) stops
  the run with one line, `reason=profile-unknown name='nope' origin=env
  valid=claude,local,ollama`, exit 4. It never falls back to the base config.
- **Mode.** `native` is the harness's own subagent tool (Claude Code's Agent),
  `adapter` is one agentic CLI per stage through `pipeline-agent.sh`, and
  `inline` is the orchestrator playing every role itself (weak or local models).
  Unset, the mode follows `agents.subagents` and the runner.
- **Harness.** Talos reads the harness that is orchestrating the run: Claude Code
  from `CLAUDECODE=1`, anything else from `TALOS_HARNESS` (for example `pi` or
  `codex`; it wins over an inherited `CLAUDECODE`). Claude Code provides all
  three modes; any other declared harness provides `adapter` and `inline`; an
  unknown harness is not restricted. `agents.subagents: auto` resolves from the
  harness, not from `agents.runner`.
- **First usable profile.** The candidates are `[profile, ...fallback entries
  that name a profile]`. A profile is usable when the harness provides its mode
  and its runner's CLI is on `PATH` (`custom`: a non-empty `runner_cmd`). The
  first usable one is active; each one passed over is listed once, for example
  `PROFILE_SKIPPED=claude reason=mode-native-unsupported-by-pi`. A fresh session
  started from another tool (`TALOS_HARNESS=pi talos ...`) therefore continues on
  `local` with no config edit. A profile is also passed over while its runner is
  marked down in `.talos/providers.json` (what a provider-error failover records
  for `agents.provider_down_s`): `PROFILE_SKIPPED=claude reason=provider-down
  until=<ts> reason=provider:quota`, so a session started after a quota failure
  picks the fallback by itself; an expired mark, or an unreadable file, counts as
  nothing down. If every harness-usable candidate is down the first is used anyway
  (the mark is advisory). None usable on the harness stops the run with
  `reason=profile-unusable`.
- **Fallback entries.** `agents.fallback` (and `agents.roles.<role>.fallback`) may
  name a profile as well as a runner; a bare runner name behaves exactly as in
  [Runner failover](#runner-failover-agentsfallback-418). A profile entry runs
  with its own runner, `runner_cmd`, `runner_args`, model, effort and
  `stage_timeout_s`, and the runner receives the model as `TALOS_MODEL`. A name
  that is both a profile and a runner is the profile. Failover applies to the
  adapter path only: when Claude itself runs out, the native orchestrator ends
  with it, and the profile switch above is the way on.
- **See it.** `bash scripts/talos.sh env` prints `HARNESS`, `PROFILE`,
  `PROFILE_ORIGIN`, `AGENTS_MODE` and one `PROFILE_INFO` line per profile (mode,
  runner, whether its CLI is installed, usable or not) as soon as profiles are
  configured or `TALOS_HARNESS` is set. `bash scripts/pipeline-agent.sh
  --resolve-all` starts with `profile=<name> profile_origin=<config|env|fallback>
  harness=<h>`, and `bash scripts/pipeline-config.sh --dump` carries the same as
  `sources.profile` / `sources.profile_origin`.

### Runner failover (`agents.fallback`, #418)

A provider outage (HTTP 429, a spent quota or credit balance, an overloaded
API, an auth failure, a dropped network) is not the model's fault, and a fix
round or a `pipeline:blocked` is the wrong answer to it. With a failover chain
configured, `pipeline-agent.sh` reruns the same stage, with the same prompt,
on the next runner. Without one, nothing changes: output and exit code are
exactly the runner's, stderr is the runner's plus the `talos:runner` and
`talos:usage` marker lines, and `.talos/providers.json` is never read or written.

```yaml
agents:
  runner: claude
  fallback: [codex, gemini]     # 1-5 runner names, tried in order
  provider_down_s: 900          # 60-86400, how long a failed provider stays down
  roles:
    docs:
      fallback: [gemini]        # per-role override, role-first like runner
```

Entries are runner names only (`claude | pi | codex | gemini | antigravity |
custom`, no duplicates). A fallback runner uses **its own default model**,
`agents.runner_args` is **not** forwarded to it (those flags were written for
the primary), and a `custom` entry uses the role-first `runner_cmd`. An entry
that cannot start (a `custom` with no `runner_cmd`, or a binary not on `PATH`)
is skipped with one `talos:failover ... reason=unavailable` line and never
marked down. The primary is dropped from its own chain with one stderr note.

**Classes.** Every runner exit is one of three classes:

| Signal | Class | Action |
| --- | --- | --- |
| exit 0 | `ok` | pass through |
| exit 75 (`EX_TEMPFAIL`) from any runner or `runner_cmd` | `provider` | fail over |
| a recognised, **line-anchored** claude error in the last 20 lines of stderr or stdout: `API Error: 429`, `API Error: 5xx` / `overloaded_error`, `Credit balance is too low`, `usage limit reached`, `Invalid API key` / `API Error: 401`, a `getaddrinfo ENOTFOUND` / `ETIMEDOUT` / `ECONNRESET` error line | `provider` | fail over |
| anything else non-zero, including a bare `429` or "rate limit" in the model's prose | `task` | unchanged: exit with the runner's code; the attempt and ceiling logic decides |

A `provider` exit is never recorded as an attempt: it does not call
`record-attempt` and does not count toward `limits.max_fix_attempts` or
`limits.max_total_dispatches`. Unmatched output is always `task` (fail toward
today's behaviour, never toward silently switching providers).

**The stderr patterns are UNVERIFIED.** They are candidates, not captured
from real CLI output. Only claude has any; codex, gemini, antigravity, pi and
`custom` ship **exit-75-only** until patterns are captured from real output.
For a `custom` runner, `exit 75` is the documented contract: have the
wrapper exit 75 when its endpoint is down.

**What happens on a provider exit.** The failed runner is marked down in
`.talos/providers.json` for `agents.provider_down_s` seconds
(`{"<runner>": {"down_until", "reason", "since"}}`), the work is checkpointed
when `pipeline-worktree.sh checkpoint` exists (skipped with one
`talos:failover checkpoint-skipped` note otherwise; the files stay in the
worktree), `talos:failover role=<r> from=<a> to=<b> reason=<class:detail>` is
printed on stderr, and a `failover` event (role `orchestrator`, so it never
counts as an unrecorded stage run) is appended to the events log
(`<git common dir>/talos/events.jsonl`, #517). The next stage, in this
checkout or any worktree of it, skips a runner whose entry has not expired;
after `down_until` it is tried again. `providers.json` stays deliberately
in-tree at `<repo-root>/.talos/providers.json` -- auto-ignored via
`.git/info/exclude` before its first write, never via a tracked
`.gitignore` commit -- is written atomically
under `with_lock`, and a missing, corrupt or unreadable file reads as "nothing
is down" with one warning: bookkeeping never blocks a stage. The stage's
`stage_complete` event names the runner that actually ran (and a null model)
only when it ran on a chain runner.

With a chain, stdout is buffered per attempt: a failed provider attempt's
stdout is discarded and only the final attempt's stdout reaches the caller;
stderr is replayed after every attempt.

**Write guard.** A failover never reruns a stage that already wrote.
`pipeline-agent.sh` exports `TALOS_WRITE_LOG` to the runner; `pipeline-vcs.sh`
appends the verb name (never the body) of each successful `comment-issue`,
`comment-pr`, `create-pr`, `create-issue`, `post-approval`, `approve-pr`,
`merge-pr`, `close-issue` and `record-attempt`. It also snapshots
`git for-each-ref refs/remotes` before the attempt (a push moves a
remote-tracking ref). After a `provider` exit, a non-empty journal or a
changed snapshot means **no rerun**: the provider is marked down,
`talos:failover-refused role=<r> runner=<x> reason=wrote:<verbs|push>` is
printed and the script exits 69. Known gap: a runner that calls raw `gh`
instead of `pipeline-vcs.sh` is not seen (the role profiles forbid it). A
parallel `git fetch` in the same repository also moves `refs/remotes` and reads
as a push, so the failover is refused, never forced.

**Exit codes.** `75` from a runner means provider error. `69` (`EX_UNAVAILABLE`)
is the script's own: the chain is exhausted (one stderr line names the chain
and every reason, bounded by the chain length), every runner is marked down
(nothing is run), or the failover was refused after a write. The orchestrator
then runs no `record-attempt` and no fix round, sets `pipeline:blocked` on the
issue and the PR, and posts blocked.md naming `agents.fallback`. The owner
resumes by removing `pipeline:blocked`; expired `providers.json` entries are
retried. A runner that itself exits 69 is indistinguishable from this code
when no chain is configured.

**Native Claude path.** There `pipeline-agent.sh` is not in the loop, so there
is no automatic re-dispatch. Two verbs help the orchestrator:

```bash
# class of a dead subagent, from the text it returned (advisory, same table)
bash scripts/pipeline-agent.sh --classify claude 1 returned-text.txt   # ok | provider | task
# record the provider as down (agents.provider_down_s)
bash scripts/pipeline-agent.sh --mark-down claude provider:429
```

On `provider` the orchestrator calls no `record-attempt`, runs `--mark-down`,
sets `pipeline:blocked` with a resume note naming the provider, and stops.

`bash scripts/pipeline-agent.sh --resolve <role>` appends `fallback=<a,b>`
only when a chain resolves (so a role without one keeps the exact line);
`--resolve-all` adds `fallback=` and `fallback_origin=` columns the same way.

### Token usage on adapter runs (#420)

Runs through `pipeline-agent.sh` (every runner except the native Claude Code
subagent path and pi inline mode) used to record `tokens: null`, so
`pipeline-events.sh cost` listed them as `unrecorded` and
`limits.tokens_per_issue` never saw them. Each runner attempt now reports its
usage to the stage event.

**Definition.** `tokens` is **input + output + cache-creation tokens, excluding
cache reads**, for every runner, so figures are comparable and re-read context
does not trip the budget guard. A runner that reports input and output
separately is summed into the one integer. Values are integers of at most 15
digits; anything else is `null`, and unknown is never `0`. (The native path's
`subagent_tokens` is composed by the Agent tool and is not guaranteed to match.)

| Runner | Source | `tokens` |
|---|---|---|
| `claude` | `claude -p --output-format json`, added after `agents.runner_args` and before the prompt; the message text is the `result` field and is printed as text mode prints it | `modelUsage` summed over every model (subagents included): `inputTokens + outputTokens + cacheCreationInputTokens`. A run with no `modelUsage` falls back to the top-level `usage`: `input_tokens + output_tokens + cache_creation_input_tokens` (which omits subagent tokens). |
| `custom` | the `TALOS_USAGE_FILE` sidecar | the file's `tokens`, as the runner computed it |
| `codex`, `gemini`, `antigravity`, `pi` | none | `null` (no flag is added; the invocation is unchanged) |

The claude shapes above were taken from Anthropic's documented headless and
cost-tracking output formats, not captured from a live run; the test fixtures in
`tests/fixtures/runner-usage/` follow the same documented shape. If a future CLI
version changes a field name the parse reads as unusable: the raw stdout is
printed, the event records `null`, and the exit code is the runner's.

**Switches.** `agents.capture_usage` (default `true`): `false` leaves the claude
invocation exactly as before. An `--output-format` already in
`agents.runner_args` also skips the capture, so your own choice is never
overridden. Stdout and the exit code are the runner's either way; a failover
classifier reads the extracted message text, so a JSON-mode rate-limit error
still fails over.

**`custom` sidecar.** `TALOS_USAGE_FILE` is exported to `runner_cmd` alongside
`TALOS_ROLE`, `TALOS_ISSUE_NUMBER`, `TALOS_WORKTREE_PATH` and `TALOS_EFFORT`. It
is a path in a fresh `mktemp -d` directory, created per attempt (so one
failover attempt's file is never read as the next one's) and removed when the
attempt ends, including on failure. Write one JSON object; every key is
optional:

```bash
# in the runner_cmd wrapper, after the local model finished
printf '{"tokens": %s, "tool_uses": %s, "model": "qwen2.5-coder"}\n' \
  "$TOTAL_TOKENS" "$TOOL_CALLS" > "$TALOS_USAGE_FILE"
```

`tokens` and `tool_uses` must be JSON integers from 0 to 15 digits (a string,
float, boolean or negative number reads as `null`); `model` must match
`[A-Za-z0-9._:-]{1,100}`. An absent, empty or unparseable file records no usage.
Tokens are never gated on a price: a local model with zero cost records its
count like any other runner.

**Attribution and attempts.** The event names the runner that ran: a role routed
with `agents.roles.<role>.runner`, or the failover runner that finished the
stage. The model is the config-resolved one for the primary runner, and only
what the runner's own output reported for a fallback runner (else `null`). When a
failover happens, a failed attempt that reported usage is recorded as one
`stage_attempt` event (verdict `FAIL`, its own runner and tokens); the final
attempt keeps `stage_complete`. A failed attempt with no usage adds no event.
The `events` count in `pipeline-events.sh cost` includes `stage_attempt` events.
Every attempt prints `talos:usage runner=<r> tokens=<N|null>` on stderr.

**Behaviour change.** Because adapter and failover runs now record tokens,
`pipeline-budget.sh check` counts them toward `limits.tokens_per_issue`; before,
the guard was blind to them. `pipeline-spend-format.py` is unchanged. Relay
events the orchestrator writes for an adapter stage (`talos.sh done`, Rule 2) still carry what the
orchestrator passes; coordinating a single writer is tracked in #422.

### Adversarial pre-merge stage (`roles.adversarial`, #237)

Optional, off by default. When `roles.adversarial: true`, a new stage runs
after security and before the merge gates: it attacks the diff rather than
re-checking what QA/reviewer/security already checked -- vacuous tests,
weak regex/allow-list patterns, secret-shaped strings, and unverified claims
in the PR body. Findings block the merge (`pipeline:blocked` + a PR comment)
exactly like security's do; a clear verdict applies `adversarial:approved`,
which the merge gate then requires. Leaving `roles.adversarial` absent or
`false` is a no-op: no dispatch, and the merge gate never looks for
`adversarial:approved`.

Its profile, `agents/adversarial.md`, carries its own complete method
inline (read the diff, hunt vacuous tests with a revert-in-mind check, stress
every pattern with 3 matching/3 non-matching inputs, scan for secret shapes,
verify every PR-body claim, then verdict) so it works even on a harness with
no skill mechanism -- only a bare `runner_cmd` to a model endpoint lacks one;
every harness Talos supports natively (Claude Code, Codex, Gemini, OpenCode,
Antigravity) ships agent-skills.

**Second opinion on a local model.** The whole point of `adversarial` is that
it is cheap enough (a local model) to run on every PR as a genuinely
independent second opinion -- pair `roles.adversarial: true` with
`agents.roles.adversarial.runner: custom` and a `runner_cmd` wrapper around a
llama.cpp `llama-server` endpoint:

```bash
# --jinja enables tool/function calling -- agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8081 -c 32768 --jinja
```

`runner_cmd` must point at an agentic CLI, not the bare endpoint -- write a
small wrapper that reads the prompt from stdin and forwards it to the
OpenAI-compatible endpoint:

```bash
#!/usr/bin/env bash
# adversarial-runner.sh -- wraps a local llama.cpp endpoint as the agentic
# CLI Talos's `runner_cmd` expects. Receives the full prompt on stdin.
set -euo pipefail
OPENAI_API_BASE=http://localhost:8081/v1 OPENAI_API_KEY=local \
  aider --model openai/local --yes-always --no-auto-commits --message "$(cat)"
```

```yaml
roles:
  adversarial: true              # off by default -- opt in explicitly

agents:
  runner: claude                 # everything else: native Claude subagents
  roles:
    adversarial:
      runner: custom
      runner_cmd: "/path/to/adversarial-runner.sh"
```

Every other role keeps running natively; only `adversarial` pays the local
round trip, and it costs nothing per PR once the endpoint is running
locally. The example config (`talos.pipeline.json.example`) documents this
block in its `_note`.

### Worked example: Addy Osmani's agent-skills pack

Wiring [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)
into the Talos roles:

```
# 1. Install the pack (in a Claude Code session)
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills
```

2. Reference the fitting skill from each role profile:

| Talos profile | agent-skills skill |
|---------------|--------------------|
| `reviewer.md` | `code-review-and-quality` |
| `qa.md` | `test-driven-development` |
| `security.md` | `security-and-hardening` |
| `pm.md` | `spec-driven-development`, `planning-and-task-breakdown` |
| `developer.md` | `incremental-implementation` |
| `docs.md` | `documentation-and-adrs` |

Two wiring styles — pick per role:

```yaml
# a) Preload (always applied). Plain skill names; if a listed skill is
#    missing/disabled Claude Code skips it with a debug-log warning.
---
name: reviewer
tools: Bash, Read, Grep, Glob, Skill
skills:
  - code-review-and-quality
---
```

```markdown
b) On-demand: keep `Skill` in tools: and reference the namespaced skill in
   the profile body, e.g. append to reviewer.md:

   Before posting your verdict, run the `agent-skills:code-review-and-quality`
   skill and apply its five-axis review process.
```

Preload guarantees the skill shapes every run (at the cost of context);
on-demand keeps stages lean and degrades gracefully on machines without the
pack installed.

## Config reference

Config is JSON only (#526): exactly two canonical files exist, the repo's own `talos.pipeline.json` (checked in) and the user-level `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json` shared by every repo (see [The user-level file](#the-user-level-file)); `$PIPELINE_CONFIG` points at an explicit `.json` file when set. Every key is optional and falls back to a sensible default. An unrecognized key (typo, wrong section) prints a one-line `pipeline-config: [warn] unknown config key '...' (did you mean '...'?)` warning to stderr instead of silently doing nothing — set `TALOS_CONFIG_STRICT_KEYS=0` to disable it. Use exactly one filename per layer: a stray `talos.pipeline.yml`/`.yaml` beside the json fails every config read closed (see [A clean config set](#a-clean-config-set)) — the 2026-10-06 dogfood incident that motivated this contract was exactly that: a stray committed `talos.pipeline.yml` silently shadowed `talos.pipeline.json` on main, turned `pr.draft` off (three wasted 21-minute CI runs) and set `verify.qa_mode` to `ci` with empty required checks (one red run), with no warning anywhere.

To see what a repo actually resolves, run `bash scripts/pipeline-config.sh --show`. It prints one tab-separated line per key (`key`, `value`, `layer`) and never prints a secret (see [How config is layered](#how-config-is-layered)).

### How config is layered

Four layers, lowest to highest. Each overrides the one below it key by key: a mapping merges, a scalar replaces, and a list in a higher layer replaces the lower layer's list whole (no union).

1. **Defaults.** One table in `scripts/pipeline-defaults.sh` (key, type, default, derived, env override, scope). It is the only place a default is written: no script passes a fallback of its own, and `tests/test-docs-defaults-vs-table.sh` fails when the key table below or the `talos.pipeline.json.example` `_note` states a different default.
2. **The user-level file.** `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json`, for personal preferences across repos.
3. **The repo file.** `talos.pipeline.json` (or `$PIPELINE_CONFIG` pointing at an explicit `.json` file), checked in, for repo-specific keys and overrides.
4. **Environment variables.** A key's own variable, when it is set and not empty, for a one-off override. Only the variables already documented are read (`PIPELINE_REPO`, `PIPELINE_PROJECT_NUMBER`, `PIPELINE_BOARD_OWNER`, `PIPELINE_STATUS_FIELD`, `PIPELINE_SLACK_CHANNEL`, `PIPELINE_DISCORD_CHANNEL`, `PIPELINE_BUZZ_CHANNEL`, `PIPELINE_BUZZ_RELAY`); there is no generic `TALOS_CFG_*` mapping. See [Environment variables](#environment-variables).

`bash scripts/pipeline-config.sh --show [--origin-only] [KEY-PREFIX]` lists every key of the table, plus any unknown key that is present, as `key<TAB>value<TAB>layer`, where the layer is `default`, `global`, `repo` or `env`. `--origin-only` drops the value column, and a prefix keeps the keys that start with it (`--show agents.`). A list prints its items joined by the two characters `\n`; a control character in a key or value prints as `\xNN`. A secret-typed key, an unknown key whose name reads like a secret, and any value that starts with `env:` print as `env:NAME (set)` or `env:NAME (unset)` (is `NAME` in the environment, the repo `.env` or `~/.talos/.env`) or, for a literal that is not a reference, `<masked>`: never the value. `--show` prints what the layers hold, so a derived default (the Keys table says "falls back to ...") shows empty with layer `default`. It replaces the old `--dump-layers` view of `agents.*`.

`pipeline-config.sh --has KEY` answers a different question: does a config **file** set the key (exit 0 yes, 1 no)? It ignores the environment layer on purpose, because callers use it to decide whether a block exists to edit.` --dump` answers the machine question (NUL-delimited key/value pairs, one python3 spawn) and carries a SOURCES header (#526): `sources.project`, `sources.global`, `sources.env_keys` (the set env-override variable names) and `sources.secrets_path` — one command fully answers "where is talos configured". `pipeline-config.sh --has KEY` answers a different question: does a config **file** set the key (exit 0 yes, 1 no)? It ignores the environment layer on purpose, because callers use it to decide whether a block exists to edit.

### A clean config set

The loader refuses ambiguity instead of guessing (#526). Before any value is
resolved, every read verb (`KEY`, `--has`, `--show`, `--dump`) checks each layer
directory and fails the load closed with ONE stderr line when the config set is
dirty:

- `reason=config-shadowed winner=<json> also-present=<strays> rm <strays>  # or merge them into the winner first` — a `talos.pipeline.yml`/`.yaml` sits beside that layer's `talos.pipeline.json`. The json always wins; the strays are named so you can merge them into it (run `--dump`'s values through the json) or just `rm` them.
- `reason=config-legacy-file <path> -- convert it by hand to <dir>/talos.pipeline.json (the YAML converter is in git history, #553)` — a `talos.pipeline.yml`/`.yaml` with no `talos.pipeline.json` in the same layer directory (a `$PIPELINE_CONFIG` pointer at a `.yml`/`.yaml` file is refused the same way, by name, even before the file's existence matters). There is no YAML parser and no converter any more (`--convert` was removed in #553; it is in git history): write the json by hand.
- **An explicit `$PIPELINE_CONFIG` pointer skips the same-dir stray check.** It is a deliberate human decision — the operator named the winner themselves — so only canonical-path loads (the two default files) get the stray/legacy gate. The pointer itself is still gated: a `.yml`/`.yaml` pointer is refused like any other legacy file, by name, even when the file does not exist. A pointer at a file that does not exist fails closed too (`pipeline-config: reason=config-pointer-missing <path>`, exit 3) instead of silently loading defaults; an empty `$PIPELINE_CONFIG` still means unset.

Every read verb exits 3 on these, and a `talos.sh` run answers `stop reason=config-unreadable` while printing the specific line, so a mid-migration repo is a named state, never a working config. `~/.talos/.env` is unaffected: it is the secrets store, not a config layer.

Why fail closed instead of warn: on 2026-10-06 a stray `talos.pipeline.yml` left on main of a dogfood repo silently shadowed the repo's `talos.pipeline.json` — `pr.draft` flipped off (three full 21-minute CI runs instead of one) and `verify.qa_mode` resolved to `ci` with empty required checks (a red run) — and nothing anywhere warned. A warn that can be missed cost ~40 minutes of CI; ambiguity now never runs.

### The user-level file

`${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json` accepts every key except the repo-only ones, so `pr.draft`, `limits.*`, `spend.*`, `verify.ci_wait_s`, `hooks.*`, `notifications.*` and `agents.*` can be set once for every repo. The repo file overrides it key by key, and a repo list replaces a global list whole.

**Repo-only keys.** A key that describes one repository is honoured only in that repo's own file. A repo-only key found in the user-level file is dropped with one stderr line that names the key and never the value. The list is the table's scope column: `base_branch`, `repo`, `vcs.provider`, `vcs.repo`, `vcs.azure.*`, `vcs.file.source.path`, `board.*` (all of them), `verify`, `verify.commands`, `verify.qa_mode`, `merge.required_checks`, `merge.forbidden_files`, `merge.forbidden_files_replace`, `merge.forbidden_files_allow`, `merge.approval_waiver_paths`, `merge.union_paths`, `issues.label_filter`, `issues.skip_labels`, `markers.trusted_authors` and `markers.verify_authors`. The environment variable of a repo-only key still applies, because the environment is the last layer.

**The file must be trusted.** It drives `hooks.*` and `notifications.cmd`, which run commands, so Talos reads it only when it is a regular file (or a symlink you own pointing at one), owned by you, and neither group- nor world-writable. Otherwise one stderr line names the file and the fix (`chmod go-w <file>`) and the layer is read as absent. A malformed, empty or non-mapping file also reads as absent, with one warning. The file is parsed as data only (JSON), never sourced.

`/talos:setup` writes `agents.model` and `agents.roles.<role>.model` here when you choose a model once for every repo; see [Per-role model selection](#per-role-model-selection-agentsrolesrolemodel).

### Secrets

A secret never lives in a config file. The six keys that hold one are typed `secret` in the table, and their value is a **reference**, `env:NAME`, never the secret itself:

| Key | Documented variable |
|-----|---------------------|
| `notifications.slack.webhook` | `SLACK_WEBHOOK_URL` |
| `notifications.discord.webhook` | `DISCORD_WEBHOOK_URL` |
| `notifications.teams.webhook` | `TEAMS_WEBHOOK_URL` |
| `notifications.slack.bot_token` | `SLACK_BOT_TOKEN` |
| `notifications.discord.bot_token` | `DISCORD_BOT_TOKEN` |
| `notifications.buzz.bot_key` | `BUZZ_BOT_PRIVATE_KEY` |

You never have to write a reference: the documented variables keep working with no config key at all. A reference exists to read the value from a differently named variable, for example `notifications.slack.webhook: env:ACME_SLACK_HOOK`. A webhook reference must resolve to an `https://` URL. A reference that does not resolve ends the lookup (that platform is skipped, with one stderr line); it never falls back to the documented variable. A config value that is not `env:<valid name>` (a literal pasted into the file, `env:` with no name, a name with a space or a `$`) is refused with one stderr line that names the key and never the value.

**Where the value comes from**, first match wins:

1. the exported environment;
2. the repo's `.env` (`<repo>/.env`);
3. the config reference, which renames the variable looked up in steps 1, 2, 4 and 5;
4. `~/.talos/.env` (`$TALOS_HOME/.env`);
5. the legacy `~/.hermes/.env`, with one deprecation line per process.

**`~/.talos/.env`** is a plain `NAME=value` file, one per line, with the notification variables (placeholders here, never a real value):

```
SLACK_WEBHOOK_URL=<your Slack webhook URL>
SLACK_BOT_TOKEN=<your Slack bot token>
TEAMS_WEBHOOK_URL=<your Teams webhook URL>
BUZZ_RELAY_URL=<your relay URL>
BUZZ_BOT_PRIVATE_KEY=<your bot key>
```

Create it with `mkdir -p ~/.talos && touch ~/.talos/.env && chmod 600 ~/.talos/.env`, then edit it. Talos refuses a `.env` that is not **mode 0600**, is not **owned by you**, is a symbolic link, or sits **inside any git work tree** (for example `$HOME` is a dotfiles repository): one stderr line names the file and the fix (`chmod 600 <file>`, or move it outside every repository), and the file is skipped, so the notifications it supplied stop until it is fixed.

**`~/.hermes/.env` is deprecated.** It is still the last fallback, with the same ownership, mode and work-tree checks, and one stderr line says to move your Talos variables to `~/.talos/.env` (copy only the Talos ones; the file belongs to Hermes too). `TALOS_HERMES_ENV=<path>` points the fallback elsewhere, and an empty value switches it off; tests and sandboxed runs set it.

**Which names a `.env` may set.** A `.env` is parsed, never sourced or evaluated: a value is taken literally, one pair of surrounding quotes is stripped, and `$(...)` and backticks stay plain text. The repo `.env` comes from the checkout, which can be a PR branch, so only the notification variables are read from it: `SLACK_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL`, `TEAMS_WEBHOOK_URL`, `SLACK_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `BUZZ_BOT_PRIVATE_KEY`, `BUZZ_RELAY_URL`, `PIPELINE_SLACK_CHANNEL`, `PIPELINE_DISCORD_CHANNEL`, `PIPELINE_BUZZ_CHANNEL` and `PIPELINE_BUZZ_RELAY`. Every other key is ignored, with one stderr line naming it. A hard **deny list** wins even over the allow list: `BASH_ENV`, `ENV`, `PATH`, `IFS`, `HOME`, `SHELL`, `BASH_*`, `LD_*`, `DYLD_*`, `PYTHON*`, `GIT_*`, `TALOS_*`, `*_PROXY`, `GH_*`, `GITHUB_*`, `GITLAB_*`, `AZURE_*`, `ANTHROPIC_*` and `AWS_*` (and a few more shell and runtime variables). An `env:NAME` reference to a denied name is refused before the environment is read, so a config file cannot aim `GH_TOKEN` at a chat webhook. `GITHUB_TOKEN` and `GH_TOKEN` are therefore never read from a `.env`: export them in your shell.

**Secret-shaped values are rejected in every config layer.** On load, a string value in the repo file or the user-level file that looks like a secret is dropped as absent, with one stderr line that names the key, says what it looks like and tells you to move the value to `~/.talos/.env` and reference it. The shapes are: Slack tokens (`xox[abposr]-`) and webhook URLs, Discord and Teams webhook URLs, GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), GitLab tokens (`glpat-`), `sk-` API keys, AWS access keys (`AKIA...`), private-key blocks and Nostr `nsec1` keys. A value that starts with `env:` is always allowed, and `TALOS_CONFIG_STRICT_KEYS` does not affect the check. An ordinary `#channel`, path or `https://hooks.example.com` never matches.

`TEAMS_WEBHOOK_URL` is read from the same `.env` files and config reference as the other platforms. (It used to come from the environment and the repo `.env` only.) Teams has no bot-token path and never threads; see [Per-issue notification threading](../README.md#per-issue-notification-threading).

### Global, project and environment configuration, and multi-user claiming

**Which layer sets what.** Three places hold configuration, lowest to highest ([How config is layered](#how-config-is-layered)):

- **Global**, `~/.talos/talos.pipeline.json` (`$TALOS_HOME`): your personal defaults for every repo, for example `agents.model`, `pr.draft`, `limits.*`, `identity.name`. It accepts every key except the repo-only ones.
- **Project**, `talos.pipeline.json` in the repo, checked in: what describes this repository and wins over the global file key by key.
- **Environment**: a key's own documented variable, last and one-off.

**Repo-only keys** (`vcs.*`, `board.*`, `base_branch`, `verify.*`, `merge.required_checks` and the other forbidden/union/waiver lists, `issues.label_filter`, `issues.skip_labels`, `markers.*_authors`) are honoured only in the repo file; in the global file they are dropped with a note that names the key ([The user-level file](#the-user-level-file) has the full list).

**Secrets never go in either file.** They are `env:NAME` references to variables in your environment or in `~/.talos/.env` ([Secrets](#secrets)).

**Several operators on one repo (`issues.claim`, `identity.name`).** Each person runs their own Talos with their own VCS login; the **assignee is the shared lock**, and no label, service or file is added.

- **Identity.** The login of `issues.assignee` when it names someone, else `identity.name`, else the authenticated login (`current-user`: `gh`, `glab`, `az`). It is resolved once per run. If none resolves (an Actions token, file mode) claiming is off and nothing changes.
- **Claim.** Before the first stage on an unassigned `pipeline:ready` issue, or an unassigned legacy in-flight one, `talos.sh next` assigns it to you (`assign-issue`) and reads the assignees back. If another login appeared at the same moment, the lexicographically lowest login (case-insensitive) keeps the issue and the others unassign themselves (`unassign-issue`) and move on to the next issue. On GitHub and GitLab, which hold several assignees, both writes land and the tie is settled at the read-back. Azure DevOps holds one assignee, so the later write replaces the earlier and the earlier operator sees that at the read-back. `bash scripts/talos.sh claim <N>` runs one claim by hand and prints `claim=taken|owned|lost|unclaimed|off`.
- **Filter.** `collect`, `state`, `next` and `run` act only on issues assigned to you or to nobody, and on pipeline PRs whose issue is yours. Other operators' issues and PRs (ready, in flight or blocked) are never routed; they appear in `talos.sh state --summary` as `theirs: #N (@login)`. Your own `issues.skip_labels` still apply. An issue you already hold is yours even if someone else is added to it later.
- **Leases.** The local lease ledger stays: it keeps two sessions of the same user on one machine apart. The assignee keeps different users apart.
- **Opting out.** `issues.claim: false` restores the behaviour before this key: no filter, no claim. `issues.assignee: none` (or empty) also turns claiming off, because a claim needs an assignment: with no assignment there is nothing to lock on.
- **Cost.** One `list-assignees` read per `collect` (one paginated request on GitHub) and one `current-user` lookup per run; setting `identity.name` removes the lookup.
- **Azure DevOps.** `az account show` prints your UPN (`name@example.com`), which is accepted; if your assignable name differs, set `identity.name`.

### Safety rules

The rules below hold for every part of the config and secrets code, and for every test of it. They are stated here once.

- A secret appears in a config file only as `env:NAME`. A literal secret, or a value shaped like one, is refused or dropped on load.
- A secret value is never printed: not by `--show`, not in a stderr note (a note names the key), not in a log, an events line or a test failure message.
- A `.env` is parsed, never sourced. It is trusted only when it is a regular file you own, mode 0600, outside every git work tree. The user-level config is trusted only when it is a regular file you own that is not group- or world-writable.
- A repo file cannot widen what a `.env` may set: the allow list is fixed, and the deny list wins.
- Tests never set `HOME` and never touch the real `~/.talos`, `~/.claude` or `~/.hermes`: they sandbox `TALOS_HOME` and `TALOS_HERMES_ENV` (`tests/helpers.sh` does it), send no real webhook and make no real GitHub call, and run every `python3` as `python3 -I`.
- A role prompt never contains a shell loop typed into it; a stage runs one plain command per step.

### Upgrading from before v0.19

If your setup predates the config and secrets work (epic #437), check these once. The full text of each is in the README's [Upgrade notes (v0.19+)](../README.md#upgrade-notes-v019).

- A `.env` that is not mode 0600 and owned by you is refused (`chmod 600`), and so is one inside any git work tree: notifications that came from it stop. See [Secrets](#secrets).
- A group- or world-writable global `talos.pipeline.json` is read as absent: `chmod go-w` it. See [The user-level file](#the-user-level-file).
- `TEAMS_WEBHOOK_URL` is now read from the `.env` files, and `~/.hermes/.env` is deprecated in favour of `~/.talos/.env`.
- Secret keys take only `env:NAME`; a secret-shaped value in any config layer is dropped, naming the key.
- Repo-only keys in the global file are dropped with a stderr note; the global file otherwise accepts every key.
- The `.env` deny list (`BASH_ENV`, `PATH`, `LD_*`, `GH_*`, ...) wins over the allow list.
- The environment is a fourth layer, and `pipeline-config.sh --show` prints the resolved result.
- A GitHub Actions or App token logs in as a `[bot]` that is never trusted implicitly: set `markers.trusted_authors`. See [Approval-marker author verification](#approval-marker-author-verification-markersverify_authors).

### Keys

| Key | Default | Description |
|-----|---------|-------------|
| `base_branch` | repo default branch | Branch all PRs target |
| `repo` | auto-detect | Legacy top-level alias for `vcs.repo` — checked first (before `vcs.repo`, before the git remote) by helpers that resolve `owner/repo` (e.g. `pipeline-hooks.sh`). Prefer `vcs.repo` in new configs; both are read for back-compat. |
| `vcs.provider` | `github` | VCS backend: `github`, `gitlab`, `azure`, or `file` |
| `vcs.repo` | auto-detect | `owner/repo` override (required when git remote unavailable) |
| `vcs.token_env` | unset (falls back to `GITHUB_TOKEN`, then `GH_TOKEN`) | Name of the environment variable holding the GitHub token, for the `github-api` provider (token-only, no `gh` CLI). Lets you point Talos at a differently-named secret (e.g. `MY_BOT_TOKEN`) without renaming it to `GITHUB_TOKEN`/`GH_TOKEN`. Also read by `pipeline-status.sh` for Projects v2 board updates when `gh` is absent. No effect on the `github` provider (uses `gh auth`). |
| `vcs.azure.org_url` | — | Azure DevOps org URL (`https://dev.azure.com/MYORG`) |
| `vcs.azure.project` | — | Azure DevOps project name |
| `vcs.azure.work_item_type` | `Product Backlog Item` | Type for `create-issue` (Azure) |
| `vcs.azure.area_path` | project root | Area path new work items land in (Azure) |
| `vcs.file.source.path` | `plan.md` | Markdown checklist file for file mode |
| `board.enabled` | `true` | Enable board updates (GitHub Projects / Azure State). On by default, so with a `board.project_number` set the pipeline moves cards; set `false` to turn updates off (`bootstrap-board.sh` then prints "board disabled"). |
| `board.project_number` | — | Your project board number (GitHub) |
| `board.owner` | repo owner | GitHub org/user owning the board |
| `board.status_field` | `Status` | Single-select field name (GitHub) |
| `board.statuses.*` | see example | Display names for each status option (GitHub) |
| `board.status_map.*` | unset | Optional flat mapping from pipeline status names to the board's actual column names. Example: `{Blocked: "Needs attention"}`. An absent key passes through unchanged; omitting the map entirely is a no-op. Validation and option-ID lookup both run against the mapped name, so a correctly mapped name is treated as present. |
| `board.azure_states.ready` | `New` | ADO work-item State for a ready item (Azure) |
| `board.azure_states.in_progress` | `Committed` | ADO work-item State while a stage works on the item (Azure) |
| `board.azure_states.in_review` | `Committed` | ADO work-item State while the PR is in review (Azure) |
| `board.azure_states.done` | `Done` | ADO work-item State once the PR merged (Azure) |
| `board.azure_states.*` | unset | Any other pipeline status → ADO work-item State (Azure). Leave a value empty to keep the state unchanged. The four rows above are the Scrum defaults. |
| `verify` | `[]` | Shell commands every code subagent must pass. Also accepts a dict form — `verify: {commands: [...], qa_mode: ..., targeted: ..., ci_wait_s: ..., timeout_ms: ...}` (`verify.commands` is then this dict's `commands` list) — so the sibling `verify.*` keys below can live under the same top-level key instead of alongside it. |
| `verify.commands` | `[]` | The command list in the dict form of `verify` above: `verify: {commands: [...]}` is the same as the plain list. Repo-only. |
| `verify.qa_mode` | `local` (`ci` when `merge.required_checks` is non-empty) | `ci`: QA trusts CI (`pr-checks`) as the suite oracle instead of re-running `verify:` locally — CI already runs it on every push. `local`: QA runs the full `verify:` list once itself, as before. An explicit value always wins over the `merge.required_checks`-derived default — **except** an explicit `ci` combined with an empty or absent `merge.required_checks` list, which resolves to `local` instead (with a one-line warning on stderr): trusting CI as the oracle for zero required checks would let QA pass vacuously, without ever running `verify:` or observing a real CI signal. |
| `verify.targeted` | `true` | While iterating, the developer runs only the tests covering the files it changed (`tests/run-tests.sh --for <path>...` or `--changed [<base-ref>]`; see [Tests](../README.md#tests)), then runs the full `verify:` list exactly once, immediately before its final commit and push. Set `false` to run the full `verify:` list on every iteration instead — never zero local runs either way. |
| `verify.ci_wait_s` | `900` | Seconds QA waits in the foreground (no background process, no sleep-polling) for every check named in `merge.required_checks` to go green under `qa_mode: ci`, via `pipeline-vcs.sh pr-checks-required` -- scoped to just those checks, so an unrelated non-required check cannot burn the budget or mask a required check GitHub hasn't scheduled yet. Any required check still failing, missing, or pending when the budget elapses is treated as FAIL (fail closed). Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default) -- it is interpolated unquoted into the CI-wait loop's shell test. |
| `verify.timeout_ms` | `600000` | Milliseconds substituted as `<VERIFY_TIMEOUT_MS>` into the foreground rule placed next to every verify and CI-wait instruction in the developer and QA prompts — the explicit timeout a stage passes to its verify command instead of backgrounding it. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `merge.auto` | `true` | `false` runs every stage and gate (approvals, forbidden-files check, green CI) but leaves the final merge to a human: the orchestrator labels the PR `pipeline:approved`, posts a "ready for human merge" comment, and stops instead of merging. The issue stays open and is closed by the reconciliation sweep after you merge. See [Human-merge mode](#running-the-pipeline) in the user guide. |
| `merge.auto_sync` | `true` | After each successful `merge-pr`, update every OTHER open pipeline PR's branch with the new base (#289): a sibling whose conflicts are entirely covered by `merge.union_paths` resolves mechanically via `pipeline-mergebase.sh`; otherwise `update-branch` (server-side base update — GitHub `PUT .../pulls/{n}/update-branch` with `expected_head_sha`, GitLab `glab mr rebase`; unsupported on azure/file, exit 2) re-checks mergeability, and a still-conflicting sibling gets the developer merge-base dispatch immediately instead of at its own merge time. `false` skips the block entirely. |
| `merge.method` | `squash` | `squash`, `merge`, or `rebase` |
| `merge.required_checks` | `[]` | CI check names required before merge. If your workflow only runs some checks (e.g. a macOS job) on push and not on pull requests -- as `templates/ci/github-tests.yml` does by default -- do not name that check here, or QA's CI-wait loop will wait for a check that never appears on the PR; see [CI](../README.md#ci). |
| `merge.forbidden_files` | see defaults | Glob patterns (matched against filename and full path) for files that must not appear in a PR. Matching is **case-insensitive** (`.ENV` and `Credentials.JSON` are caught). Defaults (30 patterns): `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `credentials.json`, `*-credentials.json`, `*_credentials.json`, `.aws/credentials`, `*/.aws/credentials`, `.docker/config.json`, `*/.docker/config.json` (the last ten, credential files, were added in #436; `*credentials*.json` is deliberately not a default, so `credentials-schema.json` stays allowed). `pipeline-worktree.sh checkpoint` reads the same list through `pipeline-vcs.sh forbidden-files-patterns` and fails closed if it cannot resolve it. Setting this key **adds** to the defaults (union semantics) — the built-in patterns remain active alongside any configured patterns. To replace the defaults entirely, also set `merge.forbidden_files_replace: true` (see below). **Note:** `*id_rsa*` also matches `id_rsa.pub` (a harmless public key) — this is an accepted false positive. If you commit public keys, add `id_rsa.pub` (or the specific filename) to `merge.forbidden_files_allow`. **Note:** `*.keystore` may also block self-signed test keystores committed for CI use — `fnmatch` cannot distinguish a real keystore from a test one. This is expected behaviour; operators who legitimately commit test keystores should add the specific filename to `merge.forbidden_files_allow` (e.g. `["test.keystore", "debug.keystore"]`). **Note:** `.netrc` and `_netrc` are literal patterns (no glob characters). As of #76 (PR #90), literal deny patterns generate canaries and wildcard allow entries that match them are rejected — the deferral that kept `.netrc` out of the defaults is resolved (#78). **Note:** Three extensions were deliberately excluded from the defaults in #78: `*.gpg` (`pass`/SOPS/git-crypt workflows commit GPG-encrypted blobs intentionally — encryption-at-rest is a legitimate reason to put a secret in a repo), `*.asc` (detached signatures and public signing keys are routinely committed as release artifacts), and `*.der` (DER is an encoding used equally by public X.509 certificates and private keys — the extension alone is not a reliable signal). If one of these applies to files that should genuinely never appear in your PRs, add the pattern to `merge.forbidden_files`. **Note:** a `.npmrc` that holds no token (only a registry URL or `engine-strict`) is a common false positive for the `.npmrc` default. Add the exact filename to `merge.forbidden_files_allow` (`[".npmrc"]`); a wildcard entry is rejected. |
| `merge.forbidden_files_replace` | `false` | Set to `true` to restore the pre-v0.13 replacement behaviour: `merge.forbidden_files` will then **replace** the built-in defaults entirely rather than unioning with them. **Security warning:** this suppresses the built-in secret-protection patterns for every PR until the key is removed. A `talos:forbidden-files-defaults-replaced` marker is emitted on stdout on every run so the suppressed state is auditable in the PR record. Keep this `false` unless you have a specific reason to narrow the deny list. |
| `merge.forbidden_files_allow` | `[]` | Explicit exemptions for `merge.forbidden_files`. Globs matched against filename and full path, checked **before** deny patterns. Use this when a deny pattern over-matches a committed template (e.g. allow `.env.example` while keeping `.env.production` blocked). Example: `[".env.example"]`. **Security note:** each entry punches a hole in the secret-protection gate — if a real secret file matches an allow entry it will not be blocked. Keep the allow list minimal and specific. **Literal-override caveat:** the allow-list validation generates canaries from both wildcard and literal deny patterns. A wildcard allow entry (e.g. `*.env`) that matches a canary derived from any deny pattern is rejected. The one permitted exception is an allow entry that is an exact string match for a literal deny pattern (e.g. adding `.env` to allow when `.env` is a deny pattern) — this is treated as a deliberate operator decision to permit that specific file. Keep such overrides intentional and minimal. |
| `merge.approval_waiver_paths` | `["*.md", "docs/**", "CHANGELOG.md", "*.example"]` | Glob patterns for files that, when they are the **only** changes between an approval SHA and the current head, do not invalidate that approval. A docs-only commit pushed after QA approval will therefore carry the approval forward rather than forcing a full re-run. `*.example` covers generated pipeline-config examples (e.g. `talos.pipeline.json.example`, `talos.pipeline.yml.example`) — they are never executed. **Hard-coded non-waivable (cannot be widened by this key):** any path under `scripts/` or `tests/`; agent instructions (a later edit changes what the agents do, and the default `*.md` would otherwise waive them): any path under `agents/`, `skills/` or `templates/prompts/` (Talos's own layout, anchored at the repo root, so `docs/agents/` stays waivable), any path under `.claude/agents/`, `.claude/skills/`, `.claude/commands/`, `.claude/talos/`, `.claude/rules/`, `.agents/`, `.agent/`, `.gemini/`, `.pi/` or `.codex/` at any depth (so `sub/.claude/rules/x.md` counts), and any file named `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `AGENTS.override.md` or `CLAUDE.local.md` at any depth; all matched case-insensitively, and a rename out of one of these paths counts as a change to the old path; and all pipeline config filenames: `talos.pipeline.yml`, `talos.pipeline.yaml`, `talos.pipeline.json`, `.claude-pipeline.yaml`, `.claude-pipeline.json`, `pipeline.yaml`, `pipeline.json` — these are checked first, before the config waiver. A config entry under one of the agent-instruction paths (for example `skills/**`) is accepted but has no effect on those paths, and prints a one-line stderr note. `README.md`, `docs/**`, `CHANGELOG.md` and `templates/comments/**` stay waivable. **Validation:** entries that are too broad (catch-all globs such as `*`, `**`, `*/*`, or any pattern that would match `scripts/`, `tests/` or the pipeline config filenames) are rejected at validation time (exit 1) and will **block the merge** (fail-closed), matching the behaviour of `merge.forbidden_files_allow`. Keep entries minimal and specific. |
| `merge.union_paths` | `["CHANGELOG.md"]` | Glob patterns (matched against filename and full path) for files `pipeline-mergebase.sh` is allowed to resolve mechanically — both sides of the conflict are kept via `git merge-file --union` (PR side first), no developer dispatch (#256). Used by the Step 3c mergeability gate: when a `CONFLICTING` PR's `conflict-files` output is entirely covered by this list, `pipeline-mergebase.sh` resolves and pushes the merge itself; any other conflicting path falls back to the developer merge-base task as before. **Hard-coded non-unionable (cannot be widened by this key):** any path under `scripts/`, any path under `tests/`, and all pipeline config filenames — same enforced-after-config-check set as `merge.approval_waiver_paths`. **Validation:** catch-all or non-unionable-matching entries are rejected at validation time (exit 1, nothing merged), same rule as `merge.approval_waiver_paths`/`merge.forbidden_files_allow`. Keep entries minimal and specific — a union merge blindly concatenates both sides, which is safe for an additive changelog but would corrupt a source file. |
| `issues.label_filter` | `pipeline:ready` | An issue enters the queue when it carries **both** `pipeline:ready` **and** this label. When `label_filter` is `pipeline:ready` (the default), the two conditions collapse to one — existing configs are byte-identical to today. When set to a custom value (e.g. `team:alice`), only issues carrying both labels are queued; issues that carry only the custom label are silently skipped. |
| `issues.skip_labels` | `[pipeline:blocked, wontfix]` | Issues with these are skipped |
| `issues.assignee` | `self` | Who `create-issue` and the "In progress" claim assign an issue to (github, github-api, gitlab, azure; not file). `self` = the authenticated operator; any other value = that identity verbatim; `none` = never assign; `assignee: ""` (QUOTED empty string) = `none`, plus a one-line stderr notice; a bare `assignee:` (YAML null) behaves as if unset, resolving to `self`. The value is trimmed of leading/trailing whitespace before any comparison, so `" self "` and whitespace-only values behave like `self`/`none` respectively. An existing assignee is never overwritten, and an identity the provider rejects is a stderr warning, never a stage failure. See [docs/user-guide.md](#who-issues-are-assigned-to-issuesassignee). |
| `issues.claim` | `true` | Multi-user claiming (#560): several operators can run Talos on one repo without touching each other's work. Before the first stage on an unassigned `pipeline:ready` (or legacy in-flight) issue Talos assigns the issue to the operator and reads the assignees back; if another login appeared, the lexicographically lowest keeps it and the others unassign themselves. `collect`, `state`, `next` and `run` then act only on issues assigned to the operator and on pipeline PRs whose issue is the operator's; other operators' items are listed as `theirs` in `talos.sh state --summary` and are never routed. `false` restores the behaviour before this key: no filter, no claim. Claiming also needs an assignment, so `issues.assignee: none` (or an empty `issues.assignee`) turns it off. See [Global, project and environment configuration](#global-project-and-environment-configuration-and-multi-user-claiming). |
| `identity.name` | unset | The login this operator claims issues under (#560), user-level. Unset: the authenticated login (`current-user`). Set: that name, assigned for `issues.assignee: self` and compared with the assignees when filtering. Needed where the authenticated login is not the assignable one, for example an Azure DevOps UPN. An explicit `issues.assignee` other than `self` wins over it. |
| `issues.max_parallel` | `1` | Max issues in-flight at once. **Concurrency warning:** raising this above `1` requires concurrency-safe `verify:` scripts. Under `isolation: worktree` (the default), Talos provides filesystem isolation (one worktree per issue) but does NOT manage Docker/compose project names, port allocations, or shared scratch directories. Two simultaneous verify runs against a shared compose stack will collide — observed failures include container-recreate races, script overwrites, and green transcripts that describe the wrong worktree. Consuming projects must derive their own isolation from `TALOS_ISSUE_NUMBER` (e.g. `COMPOSE_PROJECT_NAME=talos-$TALOS_ISSUE_NUMBER`). With the integer guard in place, `TALOS_ISSUE_NUMBER` is guaranteed to be digits or empty — never shell-unsafe. **Footgun:** when `TALOS_ISSUE` is not set, `TALOS_ISSUE_NUMBER` is empty and the example yields `COMPOSE_PROJECT_NAME=talos-`, a name shared across all agents; under `max_parallel > 1` this silently undoes isolation. Always set `TALOS_ISSUE=<N>` when running concurrent pipelines. The default (`1`) has no contention and requires no action. **Hard constraint under `isolation: branch`:** `max_parallel > 1` is refused at startup — `pipeline-isolation.sh validate` exits 1 with: `ERROR: isolation: branch requires issues.max_parallel: 1 — two agents cannot safely share one checkout. Set max_parallel: 1 or switch to isolation: worktree.` **Local state is locked, not your responsibility (#180):** the three shared local files/dirs concurrent stages touch — the notification thread map (`~/.talos/threads.json`), `git worktree add/remove` on the shared repo, and `tests/run-tests.sh`'s per-file result cache (`.talos/test-cache/`) — are each serialized with `scripts/pipeline-lock.sh`'s portable `mkdir`-based lock (no `flock(1)` dependency, so macOS works the same as Linux CI runners). A lock that can't be acquired within its timeout is skipped with one stderr warning rather than blocking the pipeline — a stuck lock never causes a deadlock. The board (`pipeline-status.sh`) is intentionally left unlocked: its updates are remote and idempotent. |
| `execution.isolation` | `worktree` | Working-copy strategy for each issue. **Absent key is identical to `worktree` — all existing configs are unaffected.** Three values: `worktree` (default) — each developer and QA stage runs in its own `git worktree`; unchanged from all prior releases. `branch` — stages run in the orchestrator's checkout on a per-issue branch; the checkout is never duplicated. **Cost:** execution is serialized — `max_parallel > 1` is refused at startup (hard failure, not a warning). The orchestrator asserts a clean, level tree (`assert-sync`) before each developer dispatch; a dirty or stale tree blocks the issue. `checkout` — recognised but **refused**: exits 1 with `ERROR: isolation: checkout is not yet implemented. Use isolation: worktree (default) or isolation: branch.` Planned for a future release. Any other value is refused with `ERROR: Unknown isolation mode '<value>'. Valid values: worktree, branch, checkout (checkout not yet implemented).` **Why `branch` exists:** worktrees are not viable in all setups — submodules are not populated in a fresh worktree; ignored-but-required artifacts (`node_modules/`, `.venv/`, generated protobufs) are absent so every stage pays a full install; absolute paths in build configs and Docker bind-mounts point at the original checkout; large monorepos pay real disk and time cost. Use `branch` when your project has any of these constraints and serial execution is acceptable. |
| `execution.worktree_warn_threshold` | `10` | Non-active worktree count (issue-pattern `fix\|feat/issue-*` plus Claude Code harness `worktree-agent-*`, excluding lane homes and the current checkout) above which `pipeline-worktree.sh list` prints a `pipeline-worktree: WARNING: <N> stale worktrees exceed threshold <T>` line. Step 5 (end of run) relays that line via `pipeline-notify.sh info` when present, and says nothing when the count is at or under the threshold. This is a visibility signal only — it does not change what `sweep` removes. |
| `roles.validator` | `true` | Phase-1 gate: confirms issue is real |
| `roles.pm` | `true` | Writes implementation spec |
| `roles.pm_skip_when_spec_present` | `true` | Skips spawning a PM subagent for a `pipeline:confirmed` issue whose body already IS a usable spec — an "acceptance criteria" heading (`## Acceptance criteria` or `**Acceptance criteria**`, case-insensitive) followed by at least one `- [ ]`/`- [x]` item, or the `spec:ready` label. When it fires, the orchestrator posts `**PM:** skipped, issue body is the spec` and advances straight to `pipeline:dev`; the developer's prompt says the spec is the issue body instead of pointing at a PM comment. Set to `false` to always run PM on `pipeline:confirmed` issues, ignoring this shortcut. Has no effect when `roles.pm` is `false` (PM never runs either way). Detection is `pipeline-vcs.sh has-spec <n>` (GitHub only — `github`/`github-api`). |
| `roles.qa` | `true` | Verifies PR satisfies acceptance criteria |
| `roles.reviewer` | `true` | Code-quality review |
| `roles.security` | `true` | Security review |
| `roles.adversarial` | `false` | Optional pre-merge second opinion (#237), off by default — attacks the diff for vacuous tests, weak patterns, secret shapes and unverified claims. Runs after security. Typically paired with `agents.roles.adversarial.runner: custom` + `runner_cmd` pointing at a second, independent backend (e.g. a local model). Zero behaviour change when absent or `false`: no dispatch, and `adversarial:approved` is never required by the merge gate. |
| `roles.docs` | `true` | Updates docs/CHANGELOG; terminal stage |
| `roles.docs_mode` | `auto` | Only relevant when `roles.docs` is `true`. `auto`: `talos.sh docs-gate <pr> --issue <N>` (the Step 3e Phase 1 verb, also used by `talos.sh run`) reads the PR's changed paths (`pipeline-vcs.sh pr-files <pr>`). It dispatches docs only when the PR changes `README.md`, `docs/**` (`docs/CHANGELOG.d/**` fragments excluded) or `scripts/pipeline-defaults.sh`; docs then receives only those paths (`--docs-paths-file`) instead of the full diff. Otherwise no docs subagent runs: the verb stamps `docs:done` with "no docs-relevant changes" and runs `done docs`. A failed `pr-files` read dispatches (never "nothing to check"). The developer owns the CHANGELOG line (or fragment) in its PR. `always`: docs always dispatches and reads the full diff via `diff-pr`. |
| `roles.changelog_fragments` | `false` | Opt-in (#290, part of #287): docs writes one fragment per issue under `docs/CHANGELOG.d/<issue>.md` instead of editing `CHANGELOG.md`, so parallel PRs never touch the same file. After each merge the orchestrator runs `scripts/pipeline-changelog.sh assemble` to fold consumed fragments into `CHANGELOG.md`'s `## [Unreleased]` section on the base branch (newest first, fragments deleted, non-fatal on failure). Default `false` — docs edits `CHANGELOG.md` as before. |
| `roles.planner` | `false` | Epic decomposition (optional, off by default) — detects epics (via `epic` label, ≥ 4 checklist items, or body ≥ 2000 chars) and creates dependency-ordered sub-issues; independent sub-issues enter the queue immediately, dependent sub-issues are unblocked automatically as predecessors close. The auto-close sweep does NOT close an epic once its sub-issues finish if the epic's own body still has unticked `- [ ]` acceptance boxes — it gets `pipeline:epic-children-done` and a comment naming what's outstanding instead, and stays open for a human |
| `comments.enabled` | `true` | Post a stage comment at each handoff (Daedalus parity) |
| `comments.header` | `**Agent:** {role} (talos)` | Header prepended to every stage comment; `{role}` is replaced at runtime |
| `comments.templates_dir` | `templates/comments` | Path (relative to repo root) containing comment templates |
| `notifications.slack_channel` | `""` | Slack channel ID fallback |
| `notifications.discord_channel` | `""` | Discord channel ID fallback |
| `notifications.buzz_channel` | `""` | Buzz channel UUID (Nostr `h` tag target) |
| `notifications.buzz_relay` | `""` | Buzz (Nostr) relay URL. Not a secret — it identifies a deployment the same way `buzz_channel` does, so it belongs in the committed config. Precedence: `BUZZ_RELAY_URL` from the environment or a `.env` file, then `PIPELINE_BUZZ_RELAY`, then this config key. |
| `notifications.slack.webhook` | unset | Secret reference, `env:NAME` (default variable `SLACK_WEBHOOK_URL`). Never a literal: see [Secrets](#secrets). Must resolve to an `https://` URL. |
| `notifications.discord.webhook` | unset | Secret reference, `env:NAME` (default variable `DISCORD_WEBHOOK_URL`). Must resolve to an `https://` URL. |
| `notifications.teams.webhook` | unset | Secret reference, `env:NAME` (default variable `TEAMS_WEBHOOK_URL`). Must resolve to an `https://` URL. Teams is webhook-only and never threads. |
| `notifications.slack.bot_token` | unset | Secret reference, `env:NAME` (default variable `SLACK_BOT_TOKEN`). The bot-token mode threads per issue. |
| `notifications.discord.bot_token` | unset | Secret reference, `env:NAME` (default variable `DISCORD_BOT_TOKEN`). The bot-token mode threads per issue. |
| `notifications.buzz.bot_key` | unset | Secret reference, `env:NAME` (default variable `BUZZ_BOT_PRIVATE_KEY`): the Nostr key the Buzz bot signs with. |
| `notifications.buzz_timeout_s` | `15` | Seconds a single `nak` publish may run before it is killed. Same validation as `notifications.cmd_timeout_s` below (positive integer; anything else falls back to the default). A relay that never answers logs one line on stderr, writes no thread anchor, and never blocks the pipeline. |
| `notifications.templates_dir` | `templates/notifications` | Path to notification message templates; `""` disables templates |
| `notifications.threading` | `true` | Thread all events per issue in one Slack/Discord thread (bot-token mode only) |
| `notifications.events` | all (unset) | Events filter. **Leave unset** — when set, any unlisted event is silently dropped, including all role events that make up the conversation stream. See warning below. |
| `notifications.cmd` | `""` (disabled) | Shell command run (via `sh -c`) for every event that passes `notifications.events`, after Slack/Discord/Teams/Buzz. Receives a JSON payload on stdin (`{event, ref, message, thread_key, fields, repo, issue}`); see [Optional: notifications](../README.md#5-optional-notifications) above for the schema. A missing command, non-zero exit, or timeout is a silent no-op with one line on stderr — never blocks the pipeline or the other sinks. |
| `notifications.cmd_timeout_s` | `10` | Seconds `notifications.cmd` may run before being killed. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `limits.max_fix_attempts` | `3` | Max **consecutive** failures of the **same blocking stage** before `pipeline:blocked` is set. Resets to 1 when a different stage blocks next. **Behaviour change from v0.13:** this key previously counted every developer dispatch; it now counts consecutive same-stage failures only. Operators with existing configs should audit: a value of `3` previously allowed 3 total dispatches; it now allows 2 re-dispatches for the same stage (the third recording exits non-zero and blocks). |
| `limits.max_total_dispatches` | `8` | Absolute ceiling on total developer dispatches per issue, across all stage changes. **Never resets** — not even when the blocking stage changes. Prevents a QA→reviewer→QA ping-pong from exploiting per-stage resets to run indefinitely. When the total reaches this value, `record-attempt` exits non-zero regardless of which stage is blocking. |
| `limits.max_retries` | `5` | Retries per network call after a rate-limit / transient error, on top of the original try — up to 6 total attempts by default (#173). Applies uniformly to every network verb in every provider: `gh`/`glab`/`az` CLI invocations (shadowed once per adapter so no call site needs editing) and the `github-api` provider's `curl` requests. **Retried:** HTTP 429; GitHub 403 responses whose body mentions a secondary rate limit or abuse detection; `gh`/`glab`/`az` errors whose stderr matches a rate-limit pattern. **Not retried (fails immediately, today's behaviour):** 401, 404, 422, and any other error that doesn't match those patterns. **Backoff:** honours a `Retry-After` value when the transport supplies one; otherwise exponential starting at 2s, doubling each attempt, capped at 60s. Each retry logs one line to stderr naming the attempt number and wait duration. `--dry-run` never sleeps or retries — every verb returns before its first network call. `TALOS_RETRY_SLEEP_SCALE` (default `1`) scales every sleep; set to `0` in tests for instant runs. |
| `limits.tokens_per_issue` | unset (guard **off**) | Per-issue token budget for the spend guard (#334). Unset or `0` = off, silently; a negative, boolean, fractional or non-numeric value warns once on stderr and is treated as off. Checked once before each developer fix round (fix rounds only); recorded tokens only, so unrecorded runs are never counted; fails open. At the limit the playbook sets `pipeline:blocked` and records a `budget-blocked` event; the owner removes the label (each block grants one more limit) or raises the key. Valid in the repo file and in the user-level file. See [Seeing token spend](#seeing-token-spend-334). |
| `limits.warn_at` | `0.8` | Fraction of `limits.tokens_per_issue` at which the guard reports `warn` (stops nothing). A number with `0 < x <= 1`; anything else warns once and uses `0.8`. Valid in the repo file and in the user-level file. |
| `spend.comment` | `true` | Post the per-stage spend comment on the PR, one comment per PR edited in place. Only with `comments.enabled: true` and the `github` or `github-api` provider. A strict boolean; anything else warns once and uses `true`. Valid in the repo file and in the user-level file. |
| `markers.verify_authors` | `true` | Whether `check-approval-sha` and `read-attempt` verify the author of every `talos:approval`/`talos:attempt` marker (#187). When `true` (the default), the *effective* trust set is `markers.trusted_authors` (below) **unioned with the currently-authenticated identity** — `gh api user --jq .login` for the `github` provider, `GET /user` for `github-api` — inferred automatically, no config required. Set to `false` to restore the pre-#187 behaviour: author checking is always skipped (fail-open), silently, regardless of `markers.trusted_authors`. See [Marker placement and trusted-author allow-list](#approval-marker-author-verification-markersverify_authors) below for the full enforcement matrix, including the CI-bot caveat. |
| `markers.trusted_authors` | unset | Allowlist of GitHub login strings (YAML list) additionally trusted for `talos:approval`/`talos:attempt` markers, **on top of** the inferred current-user identity described above (union, not replacement) — set this when a second identity (e.g. a CI bot distinct from the one running Talos) also posts markers legitimately. Example: `["talos-bot", "gh-actions-bot"]`. A marker from any login outside the effective trust set is silently skipped — treated as absent by `read-attempt`, or as stale by `check-approval-sha` — and every such skip across an invocation is reported in one aggregated `talos:marker-authors-rejected authors=<comma list>` line on stderr. **Bot logins (`*[bot]`) are never trusted implicitly** — a bot must be the resolved current-user identity or be listed here explicitly. |
| `hooks.pre_dispatch` | `""` (disabled) | Shell command run before every stage's prompt is built (all roles, both the native subagent and `pipeline-agent.sh` adapter paths). Non-empty stdout is prepended to the prompt under a `## Context` heading; a non-zero exit, a timeout, or empty stdout is a silent no-op with one line on stderr — it never blocks dispatch. See [Hooks](../README.md#hooks) below for the stdin JSON schema. |
| `hooks.post_stage` | `""` (disabled) | Shell command run after every verdict, approval, block, and merge — fire-and-forget with the same never-block contract as `hooks.pre_dispatch`. Receives a JSON outcome event on stdin. See [Hooks](../README.md#hooks) below for the schema. |
| `hooks.timeout_s` | `30` | Seconds `hooks.pre_dispatch` / `hooks.post_stage` may run before being killed. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `events.enabled` | `true` | Whether every `hooks.post_stage` payload is also appended, as one JSON line, to the local events log — independently of whether `hooks.post_stage` itself is configured. See [Events log](../README.md#events-log) below. |
| `events.path` | `talos/events.jsonl` | Path to the events log, relative to the **git common dir** (resolved via `git rev-parse --git-common-dir`, so every linked worktree of the same repo appends to the one file and the log lives outside every git tree, #517) unless already absolute (`talos-status.sh` refuses an absolute path or one outside the common dir). |
| `pr.draft` | `true` | Draft PRs, the default since #435 (#332): the developer opens a DRAFT PR, every stage that needs no CI runs while it is a draft, and `ready-pr` triggers the one CI run (see [Draft PRs](../README.md#draft-prs-prdraft-default-332-435)). `false` keeps the ready flow, where every push runs CI. Supported on `github`, `gitlab` and `azure`; `github-api` and `file` cannot open draft PRs and always use the ready flow (`github-api` warns once). On `github`, Step 0 also checks your workflows with `scripts/pipeline-draft-check.sh` and warns when CI does not skip drafts; when a job skips drafts but `ready_for_review` is missing from `on.pull_request.types` and the key is unset, the run uses the ready flow instead, because QA would wait for a run that never starts. |
| `agents.runner` | `claude` | Agent harness for the whole pipeline: `claude` (native subagents), `pi`, `codex`, `gemini`, `antigravity`, or `custom` (with `agents.runner_cmd`). See [Other harnesses](../README.md#other-harnesses-pi-codex-cli-gemini-cli-antigravity-local-models). |
| `agents.subagents` | `auto` | `auto` (true for `claude`, else false), `true`, or `false`. Chooses native parallel subagents vs. the headless `pipeline-agent.sh` adapter. |
| `agents.runner_cmd` | — | Command for `agents.runner: custom` — the prompt arrives on stdin. Global-only; use `agents.roles.<role>.runner_cmd` to override a single role. |
| `agents.runner_args` | — | Extra CLI args passed to the `claude`/`codex`/`gemini` runner. Global-only — there is no `agents.roles.<role>.runner_args`. |
| `agents.model` | session default | Model for all stages not explicitly overridden (native path only). Also settable once for every repo in the user-level `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.*`; the repo config wins per key. See [Per-role model selection](../README.md#per-role-model-selection-agentsmodel-and-agentsrolesrolemodel). |
| `agents.roles.<role>.model` | falls back to `agents.model` | Role-specific model override (native path only), e.g. a cheaper model for volume stages and a stronger one for judgement stages (reviewer, security). |
| `agents.roles.<role>.runner` | falls back to `agents.runner` | Role-specific backend override, on both the native and adapter execution paths — e.g. routing just `security` or `adversarial` through a different (often local) model while the rest of the pipeline stays on the default runner. See [Per-role runner override](#per-role-runner-override-agentsrolesrolerunner--runner_cmd). |
| `agents.roles.<role>.runner_cmd` | falls back to `agents.runner_cmd` | Role-specific command, read only when that role's resolved runner is `custom`. |
| `agents.restamp_model` | falls back to `agents.model` | Model for **re-stamp** dispatches — a cheap delta re-review of a PR the same role already approved (#258). See "Stale approvals — cheap delta re-stamp" under [`pipeline-vcs.sh` verbs](../README.md#scripts-reference) below. |
| `agents.roles.<role>.restamp_model` | falls back to `agents.restamp_model`, then `agents.model` | Role-specific re-stamp model override. Precedence: role restamp model → global restamp model → `agents.model`. |
| `agents.effort` | unset (runner's own default) | Reasoning effort (`low` \| `medium` \| `high` \| `max`) for all stages not explicitly overridden (#271). Applied for real on every adapter-path runner; on the native `claude` path it is advisory only — see [Per-role reasoning effort](../README.md#per-role-reasoning-effort-agentseffort-and-agentsrolesroleeffort). An invalid value is rejected with a stderr warning and treated as unset. |
| `agents.roles.<role>.effort` | falls back to `agents.effort` | Role-specific effort override, e.g. `high` for `developer`, `low` for cheap volume stages. |
| `agents.restamp_effort` | falls back to `agents.effort` | Effort for **re-stamp** dispatches (#271), same chain shape as `agents.restamp_model`. |
| `agents.roles.<role>.restamp_effort` | falls back to `agents.restamp_effort`, then `agents.effort` | Role-specific re-stamp effort override. Precedence: role restamp effort → global restamp effort → `agents.effort`. |
| `agents.fallback` | unset (no chain) | Ordered list of 1-5 entries tried in turn when a runner dies of a **provider** error (exit 75, or a recognised claude rate-limit, quota, overload, auth or network line). An entry is a runner name (`claude`, `pi`, `codex`, `gemini`, `antigravity`, `custom`): that runner uses its own model and does not get `agents.runner_args`; or, since #539, a **profile name**: the attempt runs with that profile's runner, model, mode and `stage_timeout_s`. An invalid value warns once and reads as absent. See [Runner failover](../README.md#runner-failover-agentsfallback). |
| `agents.roles.<role>.fallback` | falls back to `agents.fallback` | Role-specific failover chain. |
| `agents.profile` | unset (no profile) | The named profile from `agents.profiles.<name>` to run on (#539); env `TALOS_PROFILE` overrides it. An unknown name stops the run with one `reason=profile-unknown` line. A fallback entry that names a profile is also a candidate when the harness cannot provide, or the runner CLI is missing for, the requested one. See [Switching providers / profiles](#switching-providers--profiles-agentsprofile-talos_profile-539). |
| `agents.mode` | unset (follows `agents.subagents` and the runner) | `native`, `adapter` or `inline` (#539): the harness's own subagent tool, one agentic CLI per stage through `pipeline-agent.sh`, or the orchestrator playing every role. Meant for a profile (`agents.profiles.<name>.mode`); a mode the current harness cannot provide gets the profile skipped. An invalid value warns once and reads as unset. |
| `agents.provider_down_s` | `900` | Seconds a failed provider stays marked down in `.talos/providers.json` (integer 60-86400). |
| `agents.stage_timeout_s` | unset (no timeout) | Wall-clock bound, in seconds (integer 60-86400), on each `pipeline-agent.sh` runner attempt (#540). On expiry the runner and its child processes are killed, the exit code is `124`, and stderr gets `pipeline-agent: reason=stage-timeout role=<r> after_s=<n>`. A timeout is a `task` failure, never a provider error: it does not fail over to `agents.fallback`, and `hooks.post_stage` sees verdict `FAIL`. Unset means no bound and no behaviour change. Needs `perl` (ships with macOS and Linux) for the process-group kill. An invalid value warns once and reads as unset. |
| `agents.roles.<role>.stage_timeout_s` | falls back to `agents.stage_timeout_s` | Role-specific stage bound, role-first like `agents.roles.<role>.effort`: e.g. a long bound for `developer`, a short one for `qa`. |
| `agents.capture_usage` | `true` | Record each `pipeline-agent.sh` attempt's token usage in its stage event (#420). `claude` is run with `--output-format json` (after `agents.runner_args`, before the prompt) and the message text alone is printed, as before; `false`, or an `--output-format` already in `agents.runner_args`, leaves the invocation alone and the event keeps `tokens: null`. Only a literal `false` turns it off. `custom` runners report usage through the `TALOS_USAGE_FILE` sidecar whatever this key says. See [Token usage on adapter runs](#token-usage-on-adapter-runs-420). |

## Troubleshooting

- **Verify output is too noisy for the developer/QA agent's context** — pass
  `--quiet` to `tests/run-tests.sh` (or set `TALOS_TEST_QUIET=1`) as the
  `verify` key in `talos.pipeline.json`. It prints
  one line per test file (pass/fail/cached) plus full output only for failing
  files, instead of every assertion of every file. The developer and QA
  prompts already prefer summary output for verify commands and are
  instructed to quote only failures — never paste full green output into
  comments or final messages — so `--quiet` (or your own suite's equivalent
  summary flag) keeps that guidance cheap to follow.
- **The suite is slow and you want to know which files make it so** — pass
  `--timings` to `tests/run-tests.sh` (or set `TALOS_TEST_TIMINGS=1`). After
  the per-file report it prints `TIMINGS (seconds, slowest first)`, one
  `<secs>  tests/<name>` line per file (a cached file shows `cached`).
- **A stage ends the run with `verdict-unreadable`** — the agent's final
  message never carried a verdict line, one whose first word is `<WORD>:`
  with WORD on that role's own verdict list (`CONFIRMED:`, `PASS:`,
  `APPROVED:`, `CLEAR:`, ...). Nothing is recorded and the run stops clean —
  this happens
  most often with a weak local model on the `custom` runner that narrates
  instead of answering. The verdict-word role profiles spell the contract
  (verdict word first, then 1-3 lines of findings, nothing before it); if
  your install predates #518, re-run `install.sh` so the installed
  `agents/*.md` carry it, then re-run the stage.
- **Notifications are plain one-liners, not rich cards** — templates missing.
  Re-run `install.sh <repo> --force` (older installs didn't ship
  `templates/`; manual copies often omit them).
- **Slack/Discord thread goes silent after the first message** — you set
  `notifications.events` without the role events. Leave it unset, or copy the
  full list from `talos.pipeline.json.example`.
- **No threading** — a Slack/Discord incoming webhook can't thread; switch to
  a bot token + channel ID. Teams has no bot-token alternative at all, so it
  never threads regardless of config.
- **Test what would be sent**: `PIPELINE_NOTIFY_DEBUG=1 bash
  ~/.talos/scripts/pipeline-notify.sh validator "#1" "test" 1` prints what
  every configured sink would post. To preview ONE platform's template with no
  credentials configured at all, use `--render`:
  `bash ~/.talos/scripts/pipeline-notify.sh --render buzz qa "#42" "PASS"`.
- **A legacy YAML config fails the load closed (#526)** — config is JSON only:
  a `talos.pipeline.yml`/`.yaml` beside `talos.pipeline.json` stops every config
  read with one stderr line (`reason=config-shadowed ... rm <stray>`), and one
  without a json stops with `reason=config-legacy-file ...`.
  Apply the fix the line prints (merge the stray into the json by hand, or
  write the json from `talos.pipeline.json.example`, then remove the legacy
  file). The old `--convert` verb was removed in #553; it is in git history.
- **Board updates fail** — Two paths depending on your provider:
  - **Missing Status option** (e.g. `Blocked`): run
    `bash scripts/bootstrap-board.sh` to provision it — idempotent, safe to
    re-run, and verifies every pre-existing option kept its id afterward.
  - **`github` provider:** `gh auth refresh -s project` (Projects v2 needs the
    `project` scope); verify `board.project_number` and `board.owner`.
  - **`github-api` provider (no `gh` CLI):** board updates use the same
    `GITHUB_TOKEN` / `GH_TOKEN` via GraphQL. Because `gh` is absent, the owner
    cannot be auto-detected — you must set `board.owner` explicitly in
    `talos.pipeline.json` (or `PIPELINE_BOARD_OWNER` env var); without it the
    board step is silently skipped.
  - **Large backlogs / `talos:board-unverified`:** `pipeline-status.sh`
    paginates the board's items() query up to 50 pages (5000 items at
    100/page) by default. Override the cap with `TALOS_BOARD_MAX_PAGES`; an
    invalid (non-positive-integer) value falls back to 50 with a warning on
    stderr. Hitting the cap, or a malformed page from the GraphQL API,
    prints `talos:board-unverified` and exits 0 rather than looping forever
    or failing the pipeline (board failures are warnings by design).
- **Preview any VCS action** without executing:
  `bash ~/.talos/scripts/pipeline-vcs.sh --dry-run <verb> ...`.
- **Approval label lost after a new commit** — when a non-waived file (source code, tests, agent instructions such as `agents/`, `skills/`, `templates/prompts/`, the runner dot-directories (`.claude/agents/`, `.claude/rules/`, `.agents/`, `.agent/`, `.gemini/`, `.pi/`, `.codex/`, at any depth) or any `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`/`AGENTS.override.md`/`CLAUDE.local.md`, protected config) is pushed after an approval, that approval is marked stale; only the affected stages are re-run, and docs approvals whose delta touches only `*.example` or other waived paths are re-stamped without re-dispatch (see `merge.approval_waiver_paths` in README).
- **`pipeline-config: [warn] unknown config key '...'`** — a key in your
  `talos.pipeline.json` doesn't match anything Talos
  reads; the warning names the nearest known key it thinks you meant (e.g.
  `merge.atuo` → `merge.auto`). Fix the typo — an unknown key is otherwise
  silently ignored and the pipeline runs with that key's default. Set
  `TALOS_CONFIG_STRICT_KEYS=0` to silence this check entirely (e.g. while
  intentionally staging a forward-compatible key ahead of the Talos release
  that reads it).

## FAQ

**Does Talos depend on any skill packs or plugins?**
Yes, as of 0.8.0: the plugin declares a hard dependency on
[agent-skills](https://github.com/addyosmani/agent-skills). Installing Talos
pulls it automatically — you do not add anything by hand:

```
/plugin marketplace add benmarte/talos
/plugin install talos@talos            → + 1 dependency: agent-skills
```

The role profiles delegate their methodology to those skills instead of
restating it, which is why the profiles are 20–60 lines rather than several
hundred. Each role names **one** skill it must load (every loaded skill is paid
for on every dispatch, #548) and lists the others as "only if the task needs it":

| Role | Required skill | Only if the task needs it |
|---|---|---|
| validator | `debugging-and-error-recovery` | |
| pm | `spec-driven-development` | `api-and-interface-design` |
| planner | `planning-and-task-breakdown` | |
| developer | `test-driven-development` | `incremental-implementation`, `debugging-and-error-recovery`, `git-workflow-and-versioning`, `code-simplification`, `frontend-ui-engineering`, `deprecation-and-migration` |
| qa | `test-driven-development` | `browser-testing-with-devtools` |
| reviewer | `code-review-and-quality` | `code-simplification`, `performance-optimization` |
| security | `security-and-hardening` | plus `security-review` |
| docs | `documentation-and-adrs` | |
| adversarial | `code-review-and-quality` | `security-and-hardening` |

Skills are still referenced by **bare name**, never by plugin id, so Claude
Code's built-in `code-review` / `security-review` and your own `.claude/skills/`
satisfy the same references.

**agent-skills and the installer.** The plugin declares agent-skills as a
dependency. `install.sh <repo>` fetches it for you into `<repo>/.claude/skills/`
(it needs network and the `git` binary; skip it with `--no-agent-skills`; a failed
fetch never aborts the install). That directory is read by Claude Code (and, per
its docs, Cursor and OpenCode), but not by Codex, Gemini CLI or pi, which read
`.agents/skills`; on those harnesses the roles use their embedded steps. Every
profile carries that fallback: use the skills where they are present, otherwise
follow the embedded steps. The pipeline runs regardless.

**If you already use agent-skills from Addy's marketplace**, you will end up with
it registered twice — `agent-skills@addy-agent-skills` and `agent-skills@talos`.
That is not a mistake and nothing conflicts; plugin dependencies resolve to a
*marketplace-qualified* id, so Talos can only require the copy catalogued in its
own marketplace. Dropping the catalogue entry does not help — Talos then fails to
load outright, even with agent-skills installed:

```
Status: ✘ failed to load
Error: Dependency "agent-skills@talos" is not installed
```

The catalogued entry points at `addyosmani/agent-skills` upstream, unmodified and
identical to the entry in Addy's own marketplace — Talos does not fork or vendor
it. If the duplicate bothers you, disable `agent-skills@addy-agent-skills` and
keep Talos's; they are the same plugin at the same version.

One limit worth knowing: the roles have no `Task` tool, so they cannot spawn
*subagents* — they are subagents themselves. If your repo's `CLAUDE.md` tells
agents to delegate to a named reviewer or test-engineer agent, a Talos stage
does that work itself instead. Skills are reachable; agents are not.

**Does it call LLM APIs directly?** No — the harness supplies the model.
Talos's own scripts only call your VCS CLI (`gh`/`glab`/`az`) and, for
notifications, the Slack/Discord/Teams HTTP APIs.

**Can it run in CI?** No; the supported path is a local orchestrator session.

**Is my repo modified?** Only `.claude/` (plus `talos.pipeline.json` and,
for every harness, a fenced block in `AGENTS.md`; `--no-agents-md` skips it). All state lives in
labels, comments, and `~/.talos/threads.json`.
