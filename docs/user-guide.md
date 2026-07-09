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
5. [Setup: Codex CLI](#setup-codex-cli)
6. [Setup: Gemini CLI](#setup-gemini-cli)
7. [Setup: local models (llama.cpp, Ollama)](#setup-local-models-llamacpp-ollama)
8. [Harness feature matrix](#harness-feature-matrix)
9. [Running the pipeline](#running-the-pipeline)
10. [Troubleshooting](#troubleshooting)
11. [FAQ](#faq)

---

## Features

- **Full issue→PR lifecycle** — validator, PM (spec), developer, QA, reviewer,
  security, docs, and orchestrator roles, each with its own agent definition
  and quality gate. Label state machine (`pipeline:ready` → … → merged) tracks
  progress on the issue itself.
- **Provider-agnostic VCS** — GitHub (battle-tested), GitLab, Azure DevOps, or
  **file mode** (a local `plan.md` checklist; no VCS, no network — works fully
  offline).
- **Harness-agnostic execution** — Claude Code with native parallel subagents,
  or any agentic CLI (Codex, Gemini, custom/local) via the
  `pipeline-agent.sh` adapter.
- **Rich notifications** — Slack (Block Kit), Discord (embeds), Teams
  (Adaptive Cards). Per-issue threading (bot-token mode), customizable
  markdown templates, clickable issue/PR links.
- **Stage comments on GitHub** — every role posts its verdict/findings on the
  issue or PR, so the audit trail lives where the code lives.
- **GitHub Projects v2 board** — optional automatic Status column updates.
- **Safety limits** — `max_fix_attempts` before an issue is marked
  `pipeline:blocked` for human attention; human-only gates for destructive
  actions; **forbidden-files gate** blocks merging PRs that touch secret-like
  paths (`.env`, `*.pem`, …; `merge.forbidden_files`).
- **Session recovery** — on startup the orchestrator adopts PRs left by an
  interrupted session, heals merged-but-open issues, sweeps orphaned
  worktrees, and reports stale blocked work.
- **Backlog controls** — `p0`/`p1`/`p2` priority labels order dispatch;
  `skip-qa` (human-applied) bypasses review gates for docs-only/emergency
  changes (CI and forbidden-files still enforced); flaky CI is retried up to
  2× per head SHA before waiting on a human.
- **Offline test suite** — 140+ assertions, zero credentials needed, CI on
  Ubuntu + macOS.

## Prerequisites

Core (all setups):

| Tool | Needed for | Notes |
|------|-----------|-------|
| `bash` | everything | macOS/Linux; Windows via WSL or Git Bash |
| `git` | everything | |
| `python3` | config parsing, notify payloads | stdlib only; PyYAML optional — without it use a JSON config (`talos.pipeline.json`) |
| `curl` | notifications | skip if you don't use notifications |

Per VCS provider (pick one):

| Provider | Tool | Auth |
|----------|------|------|
| `github` (default) | [`gh`](https://cli.github.com) | `gh auth login` (or `GH_TOKEN` env var) |
| `gitlab` | [`glab`](https://gitlab.com/gitlab-org/cli) | `glab auth login` |
| `azure` | `az` + azure-devops extension | `az login`; `az extension add --name azure-devops` |
| `file` | none | fully offline |

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
| `TEAMS_WEBHOOK_URL` | Teams via incoming webhook |
| `GH_TOKEN` | alternative to `gh auth login` (CI-friendly) |

Where to put them: your shell env, or a `.env` file next to the pipeline
install — `<repo>/.claude/talos/.env` for installed repos. Bot tokens are
also picked up from `~/.hermes/.env` if you run Daedalus/Hermes.

**Overrides** (optional; take priority over `talos.pipeline.yml`):

| Variable | Overrides |
|----------|-----------|
| `PIPELINE_CONFIG` | path to the config file |
| `PIPELINE_SLACK_CHANNEL` / `PIPELINE_DISCORD_CHANNEL` | notification channels |
| `PIPELINE_PROJECT_NUMBER` / `PIPELINE_BOARD_OWNER` / `PIPELINE_STATUS_FIELD` | board settings |
| `PIPELINE_REPO` | detected `owner/repo` |
| `PIPELINE_REPO_URL` | repo URL used for issue/PR links |
| `PIPELINE_ISSUE_TITLE` / `PIPELINE_PR` / `PIPELINE_PR_TITLE` | notification context (skips `gh` lookups) |
| `PIPELINE_THREAD_STATE` | thread anchor file (default `~/.talos/threads.json`) |
| `PIPELINE_NOTIFY_DEBUG` | `1` = print payloads instead of posting |

Nothing is strictly *required*: with no credentials at all, notifications are
a silent no-op and the pipeline still runs.

## Setup: Claude Code

The first-class harness — native parallel subagents, worktree isolation for
the developer role.

```bash
# 1. Install into your repo
git clone https://github.com/benmarte/talos
bash talos/install.sh /path/to/your-repo

# 2. Configure (interactive — or copy talos.pipeline.yml.example manually)
cd /path/to/your-repo
# in a Claude Code session:  /pipeline-setup

# 3. Bootstrap the label state machine (GitHub/GitLab/Azure only)
bash .claude/talos/scripts/bootstrap-labels.sh

# 4. Queue work and run
gh issue edit 42 --add-label pipeline:ready
# in a Claude Code session:  /pipeline
```

What gets installed: `.claude/talos/{scripts,skills,templates}/` and
`.claude/agents/*.md` (the role profiles). Nothing outside `.claude/` except
an optional `talos.pipeline.yml` you create.

## Setup: Codex CLI

Codex has no native subagents, so role stages run headlessly through
`pipeline-agent.sh`.

```bash
# 1. Install with the codex harness flag
bash talos/install.sh /path/to/your-repo --harness codex
```

This installs everything above **plus** a marker-fenced Talos section in your
repo's `AGENTS.md` that teaches Codex to act as the orchestrator and run each
stage via the adapter. Existing `AGENTS.md` content is preserved; re-installs
don't duplicate the section.

```yaml
# 2. talos.pipeline.yml — route role stages through codex
agents:
  runner: codex
  # runner_args: [--full-auto]
```

```bash
# 3. Bootstrap labels, queue an issue (same as Claude Code), then:
codex "Run the Talos pipeline: follow .claude/talos/skills/pipeline/SKILL.md"
```

Set `issues.max_parallel: 1` — without native subagents, stages run
sequentially in the working tree.

## Setup: Gemini CLI

Same model as Codex: Gemini orchestrates by following the playbook, stages run
through the adapter.

```yaml
# talos.pipeline.yml
agents:
  runner: gemini        # stages run via: gemini -p "<prompt>"
```

Install with `--harness codex` to get the `AGENTS.md` section (Gemini CLI can
be pointed at `AGENTS.md` via its `contextFileName` setting, or copy the
fenced section into `GEMINI.md`). Then:

```bash
gemini "Run the Talos pipeline: follow .claude/talos/skills/pipeline/SKILL.md"
```

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

```yaml
# talos.pipeline.yml — e.g. Aider against the local endpoint
agents:
  runner: custom
  runner_cmd: >-
    OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local
    aider --model openai/local --yes-always --no-auto-commits --message "$(cat)"
```

The `custom` runner pipes the assembled role prompt to `runner_cmd` on stdin.
Any agentic CLI works the same way (Ollama-backed agents, Goose, OpenCode, …).

**Fully offline:** combine a local runner with `vcs.provider: file` — work
items are checklist entries in `plan.md`, no `gh`, no network at all (skip
notification credentials and nothing is posted).

**Model guidance:** pick a function-calling-capable coder model (Qwen
coder-class 32B+ recommended for the developer role). Small models will drop
playbook steps; the orchestrator role is the most demanding — QA/review gates
catch bad stage output, but nothing gates the orchestrator itself.

## Harness feature matrix

| Feature | Claude Code | Codex CLI | Gemini CLI | Custom/local |
|---------|:-----------:|:---------:|:----------:|:------------:|
| Full pipeline (all roles/gates) | ✅ | ✅ | ✅ | ✅ |
| Parallel issues (`max_parallel > 1`) | ✅ | ❌ sequential | ❌ sequential | ❌ sequential |
| Developer worktree isolation | ✅ | ❌ working tree | ❌ working tree | ❌ working tree |
| Interactive setup wizard (`/pipeline-setup`) | ✅ | manual config | manual config | manual config |
| Optional review/verify skill enrichment | ✅ | ❌ | ❌ | ❌ |
| Notifications / comments / board / file mode | ✅ | ✅ | ✅ | ✅ |

(The bottom row is harness-independent — plain bash.)

## Running the pipeline

1. Add `pipeline:ready` to an issue (or add a `- [ ]` item to `plan.md` in
   file mode).
2. Start the orchestrator in your harness (`/pipeline` in Claude Code; the
   playbook prompt shown above elsewhere).
3. The pipeline advances the label state machine:
   `pipeline:ready` → `pipeline:confirmed` (validator) → `pipeline:dev`
   (spec written) → `pipeline:review` (PR open) → `pipeline:approved` →
   merged + closed. Any failure sets `pipeline:blocked` with a comment
   explaining what a human must do.
4. Watch progress: issue/PR comments from each role, one Slack/Discord thread
   per issue, board column updates — or run
   `bash .claude/talos/scripts/pipeline-status.sh --dry-run <n> "In progress"`
   style commands manually.

## Customizing agent profiles

The role profiles installed at `.claude/agents/*.md` are yours to edit — each
is a markdown file with YAML frontmatter (Claude Code metadata) and the role's
instructions as the body. `install.sh` never overwrites existing files unless
you pass `--force`, so local customizations survive re-installs (and `--force`
wipes them — keep customized profiles in your repo's git history).

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

Other useful frontmatter fields: `model` (per-role model override),
`disallowedTools`, `maxTurns`, `memory`. See the
[Claude Code sub-agents docs](https://code.claude.com/docs/en/sub-agents) for
the full list.

**On other harnesses (Codex / Gemini / custom):** frontmatter — including
`skills:` — is Claude Code metadata and is stripped by `pipeline-agent.sh`.
Only the profile **body** reaches the runner. To customize a role there,
write the instructions (or paste the relevant skill content) directly into
the body — it flows into every stage prompt on every harness. Skill packs
published for multiple agent tools can also be installed cross-harness with
[`npx skills add <owner>/<repo>`](https://github.com/vercel-labs/skills).

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

## Troubleshooting

- **Notifications are plain one-liners, not rich cards** — templates missing.
  Re-run `install.sh <repo> --force` (older installs didn't ship
  `templates/`; manual copies often omit them).
- **Slack/Discord thread goes silent after the first message** — you set
  `notifications.events` without the role events. Leave it unset, or copy the
  full list from `talos.pipeline.yml.example`.
- **No threading** — webhooks can't thread; use a bot token + channel ID.
- **Test what would be sent**: `PIPELINE_NOTIFY_DEBUG=1 bash
  .claude/talos/scripts/pipeline-notify.sh validator "#1" "test" 1`.
- **YAML config ignored** — PyYAML not installed. `pip install pyyaml`, or
  rename your config to `talos.pipeline.json` and use JSON.
- **Board updates fail** — `gh auth refresh -s project` (Projects v2 needs the
  `project` scope); verify `board.project_number` and `board.owner`.
- **Preview any VCS action** without executing:
  `bash .claude/talos/scripts/pipeline-vcs.sh --dry-run <verb> ...`.

## FAQ

**Does Talos depend on any skill packs or plugins (e.g. agent-skills)?**
No. The role profiles in `.claude/agents/*.md` are fully self-contained — each
embeds its complete instructions. Three profiles (QA, reviewer, security)
mention Claude Code's built-in `verify` / `code-review` / `security-review`
skills as *optional* enrichment ("if available"); on any other harness, or a
Claude Code install without them, the roles simply follow their embedded
instructions. Nothing to install.

**Does it call LLM APIs directly?** No — the harness supplies the model.
Talos's own scripts only call your VCS CLI (`gh`/`glab`/`az`) and, for
notifications, the Slack/Discord/Teams HTTP APIs.

**Can it run in CI?** An experimental GitHub Actions driver exists in
[`examples/github-actions/`](../examples/github-actions/) (event-driven via
`anthropics/claude-code-action`), but it's unmaintained reference material —
the supported path is a local orchestrator session.

**Is my repo modified?** Only `.claude/` (plus `talos.pipeline.yml` and,
for the codex harness, a fenced section in `AGENTS.md`). All state lives in
labels, comments, and `~/.talos/threads.json`.
