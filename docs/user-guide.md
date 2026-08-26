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
10. [Running the pipeline](#running-the-pipeline)
11. [Troubleshooting](#troubleshooting)
12. [FAQ](#faq)

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
  `roles.planner: true` in `talos.pipeline.yml`.
- **Provider-agnostic VCS** — GitHub (battle-tested), GitLab, Azure DevOps, or
  **file mode** (a local `plan.md` checklist; no VCS, no network — works fully
  offline).
- **Harness-agnostic execution** — Claude Code with native parallel subagents,
  or any agentic CLI (Codex, Gemini, custom/local) via the
  `pipeline-agent.sh` adapter.
- **Rich notifications** — Slack (Block Kit), Discord (embeds), Teams
  (Adaptive Cards), Buzz (Nostr kind:9 via `nak`). Per-issue threading
  (bot-token mode; NIP-10 replies on Buzz), customizable markdown templates,
  clickable issue/PR links.
- **Stage comments on GitHub** — every role posts its verdict/findings on the
  issue or PR, so the audit trail lives where the code lives.
- **GitHub Projects v2 board** — optional automatic Status column updates.
- **Safety limits** — `max_fix_attempts` before an issue is marked
  `pipeline:blocked` for human attention; human-only gates for destructive
  actions; **forbidden-files gate** blocks merging PRs that touch secret-like
  paths (`.env`, `*.pem`, …; `merge.forbidden_files`).
- **Human-merge mode** — `merge.auto: false` runs every stage and gate but
  stops at `pipeline:approved` and hands the final merge to a human (for
  protected integration branches).
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
| `python3` | config parsing, notify payloads | stdlib only; JSON config (`talos.pipeline.json`) needs no extra dependency — recommended for new projects. YAML config requires PyYAML (`pip install pyyaml`); not installable on some platforms (PEP 668). |
| `curl` | notifications | skip if you don't use notifications |
| `nak` | Buzz notifications only | `brew install nak`; signs/publishes Nostr events — skip unless you use Buzz |

Per VCS provider (pick one):

| Provider | Tool | Auth |
|----------|------|------|
| `github` (default) | [`gh`](https://cli.github.com) | `gh auth login` (or `GH_TOKEN` env var) |
| `github-api` | none | `GITHUB_TOKEN` or `GH_TOKEN` env var — no `gh` CLI needed |
| `gitlab` | [`glab`](https://gitlab.com/gitlab-org/cli) | `glab auth login` |
| `azure` | `az` + azure-devops extension | `az login`; `az extension add --name azure-devops` |
| `file` | none | fully offline |

The `github-api` provider is the recommended choice for **CI/CD environments or minimal containers** where installing `gh` is impractical. Set `GITHUB_TOKEN` (or `GH_TOKEN`) and add `vcs.provider: github-api` to your `talos.pipeline.yml`.

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
| `BUZZ_RELAY_URL` | Buzz relay websocket URL, e.g. `ws://localhost:3000` ([block/buzz](https://github.com/block/buzz); needs `BUZZ_BOT_PRIVATE_KEY` + `notifications.buzz_channel`) |
| `BUZZ_BOT_PRIVATE_KEY` | Nostr key (nsec or hex) the Buzz bot signs kind:9 events with (threading via NIP-10 replies) |
| `GITHUB_TOKEN` | GitHub API token for `github-api` provider (Personal Access Token or Actions token) |
| `GH_TOKEN` | Alternative to `GITHUB_TOKEN`; also accepted by `gh` CLI (`github` provider) |

Where to put them: your shell env (exported variables always win), or a `.env`
file at the **repo root** (`<repo>/.env`). Bot tokens are also picked up from
`~/.hermes/.env` if you run Daedalus/Hermes. Note: the old `.claude/talos/.env`
path is no longer read — move any credentials to the repo root.

**Overrides** (optional; take priority over `talos.pipeline.yml`):

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
# in a Claude Code session:  /pipeline-setup     — writes talos.pipeline.yml, bootstraps labels
gh issue edit 42 --add-label pipeline:ready
# in a Claude Code session:  /pipeline
```

The plugin carries the skills, the eight role agents, the scripts and the
templates. The repo gets one file: `talos.pipeline.yml`. Nothing is vendored,
and upgrading is `/plugin update talos@talos` rather than a re-install per repo.

**Alternative: vendor into the repo.** Use this when the pipeline is driven by a
harness that cannot load a Claude Code plugin (Codex, Gemini, Antigravity — see
the sections below), or when you want the pipeline pinned in-tree and reviewed
alongside your code.

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

What gets installed: `.claude/talos/{scripts,templates}/`,
`.claude/skills/pipeline/SKILL.md` (the command), and `.claude/agents/*.md`
(the role profiles). Nothing outside `.claude/` except an optional
`talos.pipeline.yml` you create.

Both paths can coexist. Scripts resolve plugin root → vendored → source repo, so
where both are present the plugin wins — it is the copy that matches the skill
being run.

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
# 1. Install Talos into the repo
bash talos/install.sh /path/to/your-repo

# 2. Config — inline pi mode
# talos.pipeline.yml:
agents:
  runner: pi
  subagents: false      # or auto — pi has no subagents so auto resolves to false

# 3. Queue work and run the pipeline in a pi session
#    Add 'pipeline:ready' to a GitHub issue (or '- [ ]' to plan.md in file mode),
#    then in the repo start pi and say: run the talos pipeline
```

Register the `pipeline` skill so pi loads it — add this repo's `skills/` (and
`agent-skills`) to pi's skill locations, e.g. in `~/.pi/settings.json`:

```json
{
  "skills": [
    "~/.claude/skills",
    "~/path/to/talos/skills"
  ]
}
```

The canonical playbook's Harness-compatibility section selects inline mode from
`agents.subagents: false` / `agents.runner: pi`. The role profiles'
frontmatter (`model:`, `tools:`, `skills:`) is Claude Code metadata — pi reads
only the body, using its own `read/write/edit/bash` tools.

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
codex "Run the Talos pipeline: follow .claude/skills/pipeline/SKILL.md"
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
gemini "Run the Talos pipeline: follow .claude/skills/pipeline/SKILL.md"
```

## Setup: Google Antigravity

Same model as Codex and Gemini: Antigravity orchestrates by following the
playbook; role stages run through the adapter.

**Orchestrator:** `talos install --harness antigravity` writes a marker-fenced
Talos section into your repo's `AGENTS.md`. Antigravity reads `AGENTS.md`
natively since v1.20.3 — no separate config file is needed. Note: if both
`GEMINI.md` and `AGENTS.md` exist in your project, `GEMINI.md` takes
precedence in Antigravity's context loading.

```bash
# 1. Install with the antigravity harness flag
bash talos/install.sh /path/to/your-repo --harness antigravity
```

**Runner config:** set `agents.runner: antigravity` in `talos.pipeline.yml`
so that role stages are dispatched via `agy -p "<prompt>"` (Antigravity CLI
headless mode):

```yaml
# talos.pipeline.yml
agents:
  runner: antigravity   # stages run via: agy -p "<prompt>"
  # runner_args: []     # optional extra CLI args
```

**Bootstrap and run:**

```bash
# 2. Bootstrap labels, queue an issue (same as Claude Code), then:
agy "Run the Talos pipeline: follow .claude/skills/pipeline/SKILL.md"
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

| Feature | Claude Code | pi | Codex CLI | Gemini CLI | Antigravity | Custom/local |
|---------|:-----------:|:--:|:---------:|:----------:|:-----------:|:------------:|
| Full pipeline (all roles/gates) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Parallel issues (`max_parallel > 1`) | ✅ | ❌ sequential | ❌ sequential | ❌ sequential | ❌ sequential | ❌ sequential |
| Developer worktree isolation | ✅ | ❌ working tree | ❌ working tree | ❌ working tree | ❌ working tree | ❌ working tree |
| Interactive setup wizard (`/pipeline-setup`) | ✅ | manual config | manual config | manual config | manual config | manual config |
| Optional review/verify skill enrichment | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Notifications / comments / board / file mode | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native AGENTS.md orchestration | via CLAUDE.md | skill | ✅ | via GEMINI.md | ✅ (v1.20.3+) | N/A |

(The notifications / comments / board / file mode row is harness-independent — plain bash.)

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

**Human-merge mode:** set `merge.auto: false` in `talos.pipeline.yml` to run the
full pipeline but leave the final merge to a human. Every gate still applies —
approval labels, forbidden-files check, green CI — but instead of merging, the
orchestrator labels the PR `pipeline:approved`, posts a "ready for human merge"
comment, sends the orchestrator notification, and stops. The issue stays open
and is closed by the reconciliation sweep after you merge. Use this on
integration branches whose protection requires a human review the pipeline
can't self-provide (single-account setups). Default is `merge.auto: true`.

**Working with epics:** when `roles.planner: true` is set in `talos.pipeline.yml`,
the pipeline detects large issues as epics (any issue carrying the `epic` label,
containing ≥ 4 checklist items, or whose body is ≥ 2000 characters) and automatically
decomposes them before the PM and developer stages run. The planner subagent produces
a breakdown of up to 10 sub-tasks; the orchestrator creates a GitHub issue for each
one, linking it back to the parent epic with a `Part of #<N>` reference. Independent
sub-issues receive `pipeline:ready` immediately so they enter the queue on the current
or next run. Sub-issues that depend on another sub-issue are held back until their
predecessor closes, at which point the orchestrator's Step 1 reconciliation sweep
automatically adds `pipeline:ready`. The epic itself is labelled
`pipeline:epic-decomposed` and is closed automatically once every sub-issue is
resolved. The planner role is off by default — it adds API calls and is most useful
when you regularly work with multi-task epics.

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

To customize a role, add your own `.claude/agents/<role>.md` to the repo. The
orchestrator checks for a repo-level profile before falling back to the plugin's
namespaced `talos:<role>`, so your file wins for that role while the other seven
keep coming from the plugin. Override only what you need, and it stays
version-controlled with the code it reviews.

`pipeline-agent.sh` (the non-Claude harness adapter) resolves in the same order,
so Codex and Claude pick the same profile: `<repo>/.claude/agents/` first, then
`$CLAUDE_PLUGIN_ROOT/agents/`, then the plugin's own layout.

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

### Per-role model selection (`agents.roles.<role>.model`)

> **Note on config format:** YAML and JSON are equivalent throughout this
> section. The install path now points new users at `talos.pipeline.json`; if
> you arrived from the README install instructions you are using JSON. Translate
> the YAML examples below to JSON by mapping each YAML key/value to its JSON
> equivalent -- the key paths (`agents.model`, `agents.roles.reviewer.model`,
> etc.) and default values are identical in both formats.

**What it does.** Sets the LLM model for a specific role when the orchestrator
spawns it as a native subagent. This lets you run a cheap global model for
high-volume, machine-verifiable work (implementation, docs) while routing
judgement-heavy roles (reviewer, security) to a higher-quality model.

**Default.** Each role inherits `agents.model`. If `agents.model` is also
absent, the Agent SDK inherits the session default. You only need to set
`agents.roles` for roles where you want to deviate from the global default.

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

**Hard constraint -- native path only (`subagents: true`).**
`agents.roles.<role>.model` is read and applied only when the orchestrator
spawns native subagents (Claude Code, `subagents: true` or `agents.subagents:
auto` with `runner: claude`). The model-resolution logic is in
`skills/pipeline/SKILL.md` under the `subagents: true` block (lines 32-42):
the orchestrator reads `agents.roles.<role>.model`, falls back to
`agents.model`, then omits `model:` entirely if neither is set.

On the adapter path (`subagents: false`, runner: `codex` / `gemini` /
`antigravity` / `custom` / `pi`), model routing is done by the runner via the
`$TALOS_ROLE` environment variable in `runner_cmd`. The `agents.roles` block is
never read on this path -- `pipeline-agent.sh` ignores it. **A user on
`runner: codex` who sets `agents.roles` and sees no effect has no current way
to discover why from the pipeline output.** State this constraint explicitly in
your config comments to save future-you a debugging session.

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

### Filtering which issues enter the queue (`issues.label_filter`)

> **Note on config format:** all examples below are YAML (`talos.pipeline.yml`).
> The JSON equivalent (`talos.pipeline.json`) works identically -- rename the
> file and translate the structure to JSON. As of v0.13 the README install path
> points new users at `talos.pipeline.json`, so if you arrived here from the
> README you are using JSON. The key paths and default values are the same in
> both formats.

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

### Choosing an isolation mode (`execution.isolation`)

> **Note on config format:** YAML and JSON are equivalent -- see the note above
> the `issues.label_filter` section. The key path `execution.isolation` and the
> default value `worktree` are the same in both formats.

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
- **YAML config ignored** — PyYAML not installed. JSON config (`talos.pipeline.json`)
  needs no dependency and works on every platform — recommended for new projects.
  To keep YAML: `pip install pyyaml` (may fail on macOS with PEP 668 / Homebrew
  Python; try `pip install --break-system-packages pyyaml` or use `talos.pipeline.json.example`
  as a starting point).
- **Board updates fail** — Two paths depending on your provider:
  - **`github` provider:** `gh auth refresh -s project` (Projects v2 needs the
    `project` scope); verify `board.project_number` and `board.owner`.
  - **`github-api` provider (no `gh` CLI):** board updates use the same
    `GITHUB_TOKEN` / `GH_TOKEN` via GraphQL. Because `gh` is absent, the owner
    cannot be auto-detected — you must set `board.owner` explicitly in
    `talos.pipeline.yml` (or `PIPELINE_BOARD_OWNER` env var); without it the
    board step is silently skipped.
- **Preview any VCS action** without executing:
  `bash .claude/talos/scripts/pipeline-vcs.sh --dry-run <verb> ...`.

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
hundred. Each role now *directs* the model to use them rather than treating them
as optional:

| Role | Skills it reaches for, if available |
|---|---|
| validator | `debugging-and-error-recovery`, `doubt-driven-development` |
| pm | `spec-driven-development`, `api-and-interface-design` |
| planner | `planning-and-task-breakdown` |
| developer | `test-driven-development`, `incremental-implementation`, `debugging-and-error-recovery`, `git-workflow-and-versioning`, `code-simplification`, `frontend-ui-engineering`, `deprecation-and-migration` |
| qa | `test-driven-development`, `browser-testing-with-devtools`, plus `verify`/`run` |
| reviewer | `code-review-and-quality`, `code-simplification`, `performance-optimization`, plus `code-review` |
| security | `security-and-hardening`, plus `security-review` |
| docs | `documentation-and-adrs` |

Skills are still referenced by **bare name**, never by plugin id, so Claude
Code's built-in `code-review` / `security-review` and your own `.claude/skills/`
satisfy the same references.

**Vendored installs do not pull agent-skills.** The dependency belongs to the
plugin; `install.sh` copies files and installs nothing. agent-skills is not
Claude-Code-only — it ships `.gemini/`, `.opencode/`, `.codex-plugin/` and an
`AGENTS.md` covering Antigravity — so install it separately on those harnesses to
get the full behaviour. Every profile carries a fallback either way: use the
skills where they are present, otherwise follow the embedded steps. The pipeline
runs regardless.

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

**Can it run in CI?** An experimental GitHub Actions driver exists in
[`examples/github-actions/`](../examples/github-actions/) (event-driven via
`anthropics/claude-code-action`), but it's unmaintained reference material —
the supported path is a local orchestrator session.

**Is my repo modified?** Only `.claude/` (plus `talos.pipeline.yml` and,
for the codex harness, a fenced section in `AGENTS.md`). All state lives in
labels, comments, and `~/.talos/threads.json`.
