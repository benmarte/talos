# Talos

> *The bronze automaton that patrols your backlog.*

Talos is an agnostic **issue-to-PR orchestrator**. Label an issue `pipeline:ready` and Talos walks it through validator, spec, developer, QA, review, security, docs and a squash merge, with your own test commands as the gate. It keeps nothing resident: the state lives in labels and comments on the issue and PR, plus a local events log.

It is LLM-driven by default: a Claude Code session runs the playbook (`/talos:pipeline`) and dispatches each stage as a subagent. For local or weak models, `scripts/talos.sh run` is the deterministic orchestrator: code decides the next step, runs the gates, and calls the model only for the stage work itself.

- **Trackers:** GitHub (the `gh` CLI or a token), GitLab, Azure DevOps, or a local `plan.md` checklist.
- **Harnesses:** Claude Code natively; pi, Codex CLI, Gemini CLI, Antigravity, or any agentic CLI (including a local llama.cpp model) as the stage runner.
- **Notifications:** Slack, Discord, Teams, Buzz and a generic command sink.
- **Safe by default:** approvals bound to the PR head SHA, draft PRs with one CI run, a forbidden-files gate, secrets only by reference, and a token budget guard.

## How it works

An issue moves by label: `pipeline:ready` (you queue it), validator, PM spec, developer (opens the PR), then docs, reviewer and security, QA, and the merge. Each stage is a fresh agent that posts its verdict as a comment and an approval label bound to the PR head SHA; code, not an LLM, routes between stages, runs the gates and merges. With draft PRs (the default) review runs on the draft, a single fix round covers all findings, and CI runs once before QA. Every stage except the developer can be switched off with `roles.*`, and only a person queues work, clears a block or merges when `merge.auto` is false.

## Install

Claude Code plugin (installs the required [agent-skills](https://github.com/addyosmani/agent-skills) plugin as a dependency):

```
/plugin marketplace add benmarte/talos
/plugin install talos@talos
```

Any harness, or to share one copy across repos:

```bash
git clone https://github.com/benmarte/talos
bash talos/install.sh --global     # installs to ~/.talos (re-run after git pull)
```

Needs `bash`, `git`, `python3`, and the CLI of your tracker (`gh` for GitHub). Details: [Install and setup](docs/reference.md#install-and-setup).

## Quickstart

```bash
bash talos/install.sh /path/to/repo           # per-repo setup; then copy talos.pipeline.json.example (or run /talos:setup)
bash ~/.talos/scripts/bootstrap-labels.sh     # from inside the repo (needs install.sh --global): creates the pipeline:* labels
gh issue edit 42 --add-label pipeline:ready   # queue an issue
```

Then, in Claude Code, inside the repo:

```
/talos:setup       # once: detects your provider and test command, writes the config
/talos:pipeline    # drives the queue; re-run it to resume after a stop
```

Without Claude Code: `bash ~/.talos/scripts/talos.sh run`, or tell any agentic CLI `Read ~/.talos/skills/pipeline/SKILL.md and follow it`. A minimal config is `{ "base_branch": "main", "verify": ["npm test"] }`; every key is in the [config reference](docs/reference.md#config-key-reference).

## Status line

`install.sh --global` wires Claude Code's status line to `scripts/talos-status.sh` (an existing one is chained, shown above the Talos line, and `--statusline-undo` restores it), which reads the local events log (no network call, no model tokens):

```
talos #7 qa ●●●●◐○ 3.41M
```

One dot per stage (validator, pm, developer, review, qa, merge): done, running, pending, then the tokens spent on the issue so far. Other harnesses can call `talos-status.sh --line` from their footer hook. After a cleared session or an LLM switch, run `/talos:pipeline` (or `talos.sh run`) again: the work is resumed from GitHub labels, the PR and the events log, with no extra file to maintain. See [Hooks, events, spend and the status line](docs/reference.md#hooks-events-spend-and-the-status-line).

## Switching LLMs: profiles

A profile bundles a mode, a runner, a model and per-role overrides under one name. Select one with `agents.profile` or per run with `TALOS_PROFILE`; `agents.fallback` lists what to switch to when a provider is down.

```json
{ "agents": { "profile": "claude", "fallback": ["local"],
  "profiles": {
    "claude": { "mode": "native", "model": "sonnet", "roles": { "security": { "model": "opus" } } },
    "local":  { "runner": "pi", "mode": "inline", "model": "glm-5.3-flash" }
} } }
```

```bash
TALOS_PROFILE=local bash ~/.talos/scripts/talos.sh run
```

An unknown profile name stops the run instead of silently using another one. See [Profiles, runners and fallback](docs/reference.md#profiles-runners-and-fallback).

## Documentation

- [docs/reference.md](docs/reference.md): everything else. How a run works, install per harness, configuration and secrets, the generated config key tables, profiles and runners, providers and the board, isolation and multi-user claims, gates, notifications, hooks and events, troubleshooting.
- [CHANGELOG.md](CHANGELOG.md): one line per change.
- [skills/pipeline/SKILL.md](skills/pipeline/SKILL.md): the orchestrator playbook; [agents/](agents/): the nine stage role profiles.
