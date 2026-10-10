# Talos reference

How to install, configure and operate Talos. The [README](../README.md) is the short overview. Every config key is in the generated [Config key reference](#config-key-reference); the sections below say what the keys do.

Paths such as `scripts/talos.sh` are relative to the Talos install (`~/.talos` after `install.sh --global`) or to a checkout of this repository.

**Contents:** [How a run works](#how-a-run-works) | [Install and setup](#install-and-setup) | [Configuration](#configuration) | [Config key reference](#config-key-reference) | [Profiles, runners and fallback](#profiles-runners-and-fallback) | [Providers and the board](#providers-and-the-board) | [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims) | [Gates: verify, QA, CI and merge](#gates-verify-qa-ci-and-merge) | [Notifications](#notifications) | [Hooks, events, spend and the status line](#hooks-events-spend-and-the-status-line) | [Troubleshooting](#troubleshooting)

## How a run works

### Entry points

| Entry | What drives |
| --- | --- |
| `/talos:pipeline` (Claude Code) | An LLM orchestrator follows [SKILL.md](../skills/pipeline/SKILL.md) and calls `talos.sh` verbs. |
| `Read ~/.talos/skills/pipeline/SKILL.md and follow it` (any other agent) | The same playbook. |
| `bash scripts/talos.sh run [--issue N] [--max-iterations n]` | Code drives; an LLM still does every stage. For local and weak-model profiles. |

`scripts/` is the install's scripts directory (`~/.talos/scripts` after `install.sh --global`). Read a playbook ref in `skills/pipeline/refs/` only when `talos.sh env` or `next` prints `ref=<topic>`.

`talos.sh run` loops `next` (one routed action), `prompt` (renders the stage prompt), `pipeline-agent.sh` (the configured runner, with `agents.fallback` failover) and `done` (bookkeeping), at most `--max-iterations` passes (default 20). It reads each verdict from the first line of the agent's final message that starts with `WORD:` (the word on the role's verdict list; the developer's message is read for its PR URL). An unreadable answer is a dispatch failure and records nothing. On `action=merge` it runs `gate merge`, then `merge-pr` and `post-merge`. Exit 0 on every clean stop (`ask-owner`, a stage block, a `wait`, a non-merge gate verdict, the iteration cap); exit 1 when state cannot be read, a stage dispatch fails (an unreadable answer included), the merge fails or failover is exhausted (`provider-failed`); exit 2 on a usage error. A second QA FAIL at an unchanged PR head blocks and stops. Re-run to continue.

Verbs: `env`, `state [--summary]`, `next [--issue N]`, `prompt`, `done`, `gate fix-round|merge`, `docs-gate`, `post-merge`, `sweep`, `summary`, `claim`, `lease prune`, `run`.

### Stages

Default order: validator, planner (optional), pm, developer, qa, docs, reviewer and security (parallel), adversarial (optional), merge. A disabled role is skipped and its approval label is not required at merge.

| Stage | Kind | Toggle | Does and reads |
| --- | --- | --- | --- |
| validator | LLM | `roles.validator` | Reads the issue. Verdict CONFIRMED, ALREADY_FIXED, DUPLICATE, NEEDS_MORE_INFO or SECURITY_THREAT; anything but CONFIRMED sets `pipeline:blocked`. |
| planner | LLM, off | `roles.planner` | Epics only (`epic` label, 4 or more `- [ ]` items, or body of 2000+ characters): at most 10 sub-issues, dependencies via `Depends on:`. The epic gets `pipeline:epic-decomposed`. |
| pm | LLM | `roles.pm` | Posts the spec with numbered acceptance criteria. Skipped by code when `roles.pm_skip_when_spec_present` and the issue body already has an acceptance-criteria heading with a checklist, or carries `spec:ready`. |
| developer | LLM, always | none | Reads the spec. Branch `fix/issue-N-slug` (`feat/` for a `feat` title). Red tests first, runs `verify` once before the final commit, opens the PR. The only stage that writes code. |
| qa | LLM | `roles.qa` | Checks each acceptance criterion; runs targeted tests only, never the full suite; under `verify.qa_mode: ci` waits for required CI. |
| docs | code gate, LLM only if needed | `roles.docs`, `roles.docs_mode` | `docs-gate` stamps `docs:done` itself unless the PR changes `README.md`, `docs/**` or `scripts/pipeline-defaults.sh` (`roles.docs_mode: always` forces the agent). |
| reviewer, security | LLM | `roles.reviewer`, `roles.security` | Read `diff-pr --stat`, then the files that matter. Run no tests. |
| adversarial | LLM, off | `roles.adversarial` | Second opinion on another backend. |
| merge | code | `merge.auto` | `gate merge` checks every gate; `merge-pr`; `post-merge` closes the issue, sets the board to Done, removes the worktree, notifies. |

Everything except the stage agents is mechanical: routing (`next`), bookkeeping (`done`), gates, sweeps, merge.

With `pr.draft` true (the default; it resolves to false when CI lacks a `ready_for_review` trigger, and for the `github-api` and `file` providers) the order changes: developer opens a draft PR, docs, reviewer and security (and adversarial) review the draft in one batch, one developer fix round covers all findings, `ready-pr` starts the one CI run, then QA, then merge. See [Gates: verify, QA, CI and merge](#gates-verify-qa-ci-and-merge).

### What a run costs

Each stage is a fresh agent. Spend is measured per run ([Hooks, events, spend and the status line](#hooks-events-spend-and-the-status-line)). The levers:

- `roles.*`: drop whole stages. `roles.pm_skip_when_spec_present` and `roles.docs_mode: auto` drop the PM and docs agents when code can decide.
- `verify.qa_mode: ci` (default once `merge.required_checks` is set): QA trusts CI instead of re-running tests. `verify.targeted`: the developer iterates on targeted tests and runs the full `verify` once.
- `pr.draft`: one CI run per PR.
- Re-stamp: after a fix push that leaves approvals stale, a role already approved re-reviews only the delta (`agents.restamp_model`, `agents.restamp_effort`).
- `agents.roles.<role>.model`, `.effort` and `.runner`: route cheap stages to cheap models ([Profiles, runners and fallback](#profiles-runners-and-fallback)).
- `limits.tokens_per_issue`: optional hard budget before each fix round.

### Which issues enter the queue

- An issue needs `pipeline:ready`. With `issues.label_filter` set to anything else it also needs that label (AND; a wrong filter gives a silently empty queue).
- Issues carrying a label in `issues.skip_labels` (default `pipeline:blocked`, `wontfix`) are skipped.
- Order: `p0`, `p1`, `p2`, unlabelled, then issue number.
- `issues.max_parallel` caps issues in flight (`next` answers `wait reason=cap`). Above 1 needs `execution.isolation: worktree`; the adapter path runs stages one at a time.
- `issues.assignee` (`self`, a login, or `none`) assigns the issue at creation and when it moves to In progress; it never replaces an existing assignee. With `issues.claim` true and an assignee other than `none`, the assignee is the lock between operators: `next` claims an issue before dispatching it and leaves other operators' issues alone (`identity.name` is the login `self` means). See [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims).

### Retries and attempt counting

Every developer fix round goes through `talos.sh gate fix-round <N> <blocking-stage> [--pr M]`. It runs the budget guard, then `record-attempt` (a `talos:attempt` marker comment, deduplicated per PR head with `--pr`), then clears `pipeline:blocked` if the round may run. Never count attempts by hand.

| Key | Default | Meaning |
| --- | --- | --- |
| `limits.max_fix_attempts` | 3 | Consecutive attempts at one blocking stage. |
| `limits.max_total_dispatches` | 8 | Developer dispatches per issue; never resets. |
| `limits.max_retries` | 5 | Retries of a rate-limited network call (backoff up to 60 s). |

The attempt that reaches a ceiling blocks (`verdict=block reason=max-fix-attempts|max-total-dispatches`) instead of re-dispatching. A required CI check that fails is re-run twice per head SHA before `gate merge` answers `ci-failed`.

### Blocked work and human-only gates

A stage that cannot proceed sets `pipeline:blocked` and comments `Blocked by: <file>:<quoted line> (explicit|interpreted)`: `explicit` is a hard rule to fix, `interpreted` is the agent's judgment a human may overrule. Talos clears `pipeline:blocked` only right before a fix round; otherwise a human clears it on both the PR and the issue. After a `limits.tokens_per_issue` block, removing the label grants one more limit.

Only a person does these:

- Queue an issue (`pipeline:ready`). Talos never re-queues a blocked issue. To stop work, remove `pipeline:ready` before pickup, add `pipeline:blocked` after, or close the issue.
- Clear a block, including `forbidden-files`, `closing-keyword` and `siblings-capped`, and a `ci-failed` that needs a new commit.
- Merge, when `merge.auto: false`: the PR gets `pipeline:approved` and a hand-off comment; the next `sweep` closes the issue.
- Add `skip-qa`, which waives the approval labels only, never CI or the forbidden-files check.
- Answer a `pipeline:needs-owner` question (`next` answers `ask-owner`).

There is no switch that removes the CI gate: `gate merge` stops with `reason=ci-unverified` when `merge.required_checks` is empty.

## Install and setup

### Prerequisites

Required: `bash`, `git`, `python3`. Optional: `curl` (notifications, token transport), `nak` (Buzz), `gh` with the `project` scope for a Projects v2 board.

| `vcs.provider` | Tool and auth |
|----------------|---------------|
| `github` (default) | `gh` (`gh auth login`), else `GITHUB_TOKEN` / `GH_TOKEN` over `curl` (`vcs.token_env` renames it) |
| `github-api` | the same client pinned to the `curl` token transport |
| `gitlab` | `glab auth login` |
| `azure` | `az login` and `az extension add --name azure-devops` |
| `file` | none; `plan.md` checklist items are the work items |

### Install

**Claude Code plugin** (once per machine; also installs the `agent-skills` plugin as a dependency):

```
/plugin marketplace add benmarte/talos
/plugin install talos@talos
```

**Global install** (any harness; update by `git pull` and re-running it):

```bash
git clone https://github.com/benmarte/talos
bash talos/install.sh --global [--harness <list>] [--no-overwrite] [--keep-marketplace]
bash talos/install.sh [repo-path] [--harness <list>] [--no-agents-md] [--import-agents-md] [--no-agent-skills] [--force]
```

| Flag | Effect |
|------|--------|
| `--global` | install to `${TALOS_HOME:-~/.talos}` |
| `--harness <list>`, `--harness=<list>` | installer glue, comma-separated: `claude codex gemini antigravity pi cursor opencode generic`. Another `[a-z0-9-]+` name becomes `generic`; an empty item, bad characters or a missing value exit 1. It does not set `agents.runner` |
| `--no-overwrite`, `--force` | skip existing files (global default is overwrite) / overwrite them (per-repo; never `talos.pipeline.json`) |
| `--no-agent-skills` | per-repo: skip copying agent-skills into `<repo>/.claude/skills` |
| `--no-agents-md`, `--import-agents-md` | per-repo: write no `AGENTS.md` block / append `@AGENTS.md` to an existing `CLAUDE.md` and `GEMINI.md` (never creates them) |
| `--no-statusline`, `--statusline-undo` | global: skip the status-line step for every harness / restore the original Claude `statusLine` exactly and remove the chain wrapper (implies `--global`; [The status line](#the-status-line)) |

**Claude adapter.** Writes `~/.claude/agents/<role>.md`, registers the `talos` plugin (`claude plugin marketplace add <checkout>`, `claude plugin install talos@talos`) and wires `statusLine` in `settings.json` to `talos-status.sh --line` (an existing statusLine is chained, not replaced: [The status line](#the-status-line)). With `--harness` it runs only if the list has `claude`; without it, when `CLAUDE_CONFIG_DIR` is set, `${CLAUDE_CONFIG_DIR:-~/.claude}` is a directory, or `claude` is on PATH. A skipped adapter leaves `~/.claude` alone. Without `claude plugin` it prints the two commands to run inside Claude Code. Re-run it after `git pull` (Claude Code caches the plugin). A `talos` marketplace from another source is left alone; one pointing at another directory is repointed unless `--keep-marketplace` (or `--no-overwrite`) is given.

**Pointer skills.** With `codex`, `pi`, `cursor` or `opencode` in `--harness`, `--global` writes thin pointers `~/.agents/skills/talos-<command>/SKILL.md` (`$TALOS_AGENTS_HOME` moves the root) to the `~/.talos` playbooks; a non-Talos file there is never overwritten.

| Path | Content |
|------|---------|
| `~/.talos/{scripts,agents,templates,skills}` | scripts, nine role profiles (plus `~/.claude/agents/` with the adapter), templates, playbooks `skills/{pipeline,setup}/SKILL.md` with `refs/*.md` |
| `~/.talos/talos.pipeline.json`, `.env` | optional user-level config and secrets, never written by the installer ([Configuration](#configuration)) |
| `<repo>/talos.pipeline.json` | repo config; the installer never writes it (copy `talos.pipeline.json.example` or run the wizard) |
| `<repo>/AGENTS.md` | marker-fenced Talos block, the same for all harnesses. Commit it: untracked, it makes `assert-sync` abort on a dirty tree |

Overrides win over the install: `<repo>/.claude/agents/<role>.md`, then `<repo>/.agents/talos/agents/<role>.md` (adapter and pi paths only). Scripts resolve from `$TALOS_HOME`, `~/.talos`, `$CLAUDE_PLUGIN_ROOT`, `.claude/talos` (old vendored installs), then the source repo (each `/scripts`). Treat `TALOS_HOME` like `PATH`.

### Set up a repo

1. `bash talos/install.sh /path/to/repo`, then copy `talos.pipeline.json.example` to `talos.pipeline.json` and edit it, or run the wizard. Minimal: `{ "base_branch": "dev", "verify": ["npm test"] }`.
2. Wizard: `/talos:setup` in Claude Code; elsewhere `Read ~/.talos/skills/setup/SKILL.md and follow it`. It detects provider, base branch and verify commands, asks about roles, board, notifications, runner and models, writes the config, and offers the `AGENTS.md` block, bootstrap and a test notification. Safe to re-run; a model choice goes to the user-level file after a diff and a yes.
3. `bash ~/.talos/scripts/bootstrap-labels.sh [owner/repo]` creates or updates the `pipeline:*`, approval and control labels (`spec:ready`, `skip-qa`, `epic`, `p0`-`p2`). Idempotent; needs `gh` (GitHub only).
4. `bash ~/.talos/scripts/bootstrap-board.sh [owner/project_number]` adds the missing Status options (In progress, In review, Done, Blocked, Ready) to `board.status_field` (it does not create the field). Azure: validates `board.azure_states.*`; GitLab: checks labels; file provider or `board.enabled: false`: no-op.
5. Queue: `gh issue edit 42 --add-label pipeline:ready`, or a `- [ ] task` line in `plan.md` (file mode).
6. Run: `/talos:pipeline` in Claude Code; any other agent: `Read ~/.talos/skills/pipeline/SKILL.md and follow it`. Without an orchestrator session: `bash ~/.talos/scripts/talos.sh run [--issue <N>] [--max-iterations <n>]` (default 20 passes). It loops `talos.sh next`, dispatches stages through `pipeline-agent.sh` and runs the gates in code. A stop or ask-owner wait exits 0; an unreadable state exits 1. Re-run to resume.

### Per harness

`--harness` is installer glue; `agents.runner` picks the stage CLI. Set `issues.max_parallel: 1` on non-native paths.

| Harness | `agents.runner` | Stages run as | Parallel issues | Start |
|---------|-----------------|---------------|-----------------|-------|
| Claude Code | `claude` | native subagents | yes | `/talos:pipeline` |
| pi | `pi` and `agents.subagents: false` | inline, one session plays each role | no | start line, said in pi |
| Codex CLI | `codex` | `codex exec` | no | `codex "<start line>"` |
| Gemini CLI | `gemini` | `gemini -p` | no | `gemini "<start line>"` |
| Antigravity | `antigravity` | `agy -p` | no | `agy "<start line>"` |
| other (Cursor, OpenCode, ...) | `custom` | `agents.runner_cmd`, prompt on stdin | no | start line |

Start line: `Read ~/.talos/skills/pipeline/SKILL.md and follow it`. Gemini CLI confines file tools to the workspace, so the start line probably fails (unverified). Claude Code reads `AGENTS.md` only when no `CLAUDE.md` exists, and Gemini only via `context.fileName`: use `--import-agents-md` for either.

**Local models (llama.cpp).** Talos needs an agentic CLI, not a bare endpoint. Serve with tool calling (`--jinja`), point the CLI at it, register it as the runner (`agents.runner: custom`, `agents.runner_cmd: "my-agentic-cli --model local"`):

```bash
llama-server -m model.gguf --port 8080 -c 32768 --jinja
```

Weak models drop playbook steps: use `talos.sh run` so code orchestrates.

## Configuration

### Layers

Config is JSON only, in two files: the repo's `./talos.pipeline.json` (working directory; `PIPELINE_CONFIG` names another `.json` file instead) and the user-level `${TALOS_HOME:-~/.talos}/talos.pipeline.json`. Layers, lowest to highest:

1. the table default in `scripts/pipeline-defaults.sh`, the only place a default is written ([Config key reference](#config-key-reference));
2. the user-level file;
3. the repo file;
4. the key's environment variable, when set and non-empty: `PIPELINE_REPO` (`vcs.repo`), `PIPELINE_PROJECT_NUMBER`, `PIPELINE_BOARD_OWNER`, `PIPELINE_STATUS_FIELD` (`board.*`), `PIPELINE_SLACK_CHANNEL`, `PIPELINE_DISCORD_CHANNEL`, `PIPELINE_BUZZ_CHANNEL`, `PIPELINE_BUZZ_RELAY` (`notifications.*`) and `TALOS_PROFILE` (`agents.profile`). No other variable maps to a key.

A higher layer overrides a lower one key by key: mappings merge, scalars replace, a list replaces the lower list whole. Every key is optional.

### User-level file and repo-only keys

The user-level file accepts every key except the repo-only ones (scope `repo` in the table).

Repo-only keys: `base_branch`, `repo`, `vcs.provider`, `vcs.repo`, `vcs.azure.*`, `vcs.file.source.path`, `board.*`, `verify` (and `verify.commands`), `verify.qa_mode`, `merge.required_checks`, `merge.forbidden_files`, `merge.forbidden_files_replace`, `merge.forbidden_files_allow`, `merge.approval_waiver_paths`, `merge.union_paths`, `issues.label_filter`, `issues.skip_labels`, `markers.trusted_authors`, `markers.verify_authors`. In the user-level file each is dropped with one stderr note naming the key, not the value. Their environment variables still apply.

The user-level file drives `hooks.*` and `notifications.cmd`, so it is read only if it is a regular file (or your symlink to one) owned by you and not group- or world-writable. Otherwise one stderr line names the fix and the layer reads as absent, as does malformed or non-mapping content.

### Secrets

A config file never holds a secret. Six keys are typed `secret` and take only a reference, `env:NAME`: `notifications.slack.webhook`, `.discord.webhook`, `.teams.webhook`, `.slack.bot_token`, `.discord.bot_token`, `.buzz.bot_key`. Without a reference each reads its documented variable (`SLACK_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL`, `TEAMS_WEBHOOK_URL`, `SLACK_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `BUZZ_BOT_PRIVATE_KEY`). Use a reference only to read a differently named variable (`"notifications.slack.webhook": "env:ACME_HOOK"`); a webhook reference must resolve to an `https://` URL.

Lookup order, first match wins: (1) the exported environment, (2) the repo `.env`, (3) the reference, which renames the variable searched in 1, 2, 4 and 5 (if unresolved, the platform is skipped with one stderr line, with no fallback to the documented name), (4) `${TALOS_HOME:-~/.talos}/.env`, (5) the deprecated `~/.hermes/.env` (`TALOS_HERMES_ENV=<path>` moves it, empty disables it).

- A `.env` is parsed, never sourced. `~/.talos/.env` is used only if it is a regular file (not a symlink) owned by you, mode 0600, outside every git work tree; otherwise one stderr line names the fix and the file is skipped.
- A `.env` may set only the notification variables (the six credentials, `BUZZ_RELAY_URL`, and the `PIPELINE_*` channel and relay overrides); other names are ignored with one stderr line. A deny list wins over that (`PATH`, `BASH_*`, `LD_*`, `GIT_*`, `TALOS_*`, `GH_*`, `GITHUB_*`, `*_PROXY`, ...), and a reference to a denied name is refused. `GITHUB_TOKEN` and `GH_TOKEN` are never read from a `.env`: export them in your shell.
- A string in either config file shaped like a secret (webhook URLs, Slack, GitHub and GitLab tokens, API keys, AWS keys, private keys, Nostr `nsec`) is dropped as absent on load, with one stderr line naming the key. `env:` values are always allowed.

### Inspect the effective config

```bash
bash ~/.talos/scripts/pipeline-config.sh --show [--origin-only] [KEY-PREFIX]
bash ~/.talos/scripts/pipeline-config.sh KEY [default]
bash ~/.talos/scripts/pipeline-config.sh --has KEY
```

- `--show` prints `key<TAB>value<TAB>layer` for every table key plus any unknown key present; layer is `default`, `global`, `repo` or `env`. `--origin-only` drops the value; a prefix filters (`--show agents.`). A secret-typed key or `env:` value prints `env:NAME (set|unset|denied)`; a literal there prints `<masked>`. Validators are not applied, and a derived default shows empty.
- `KEY` prints the config value, else the `default` argument, else the table default. `--has KEY` exits 0 if a config file sets it, 1 if not, 3 if one cannot be parsed; it ignores the env layer.
- `pipeline-agent.sh --resolve-all` shows each role's model and deciding layer.

### Unknown keys and fail-closed behaviour

An unrecognised key prints `pipeline-config: [warn] unknown config key 'x' (did you mean 'y'?)` to stderr and is ignored; `TALOS_CONFIG_STRICT_KEYS=0` silences it.

Ambiguity stops the load. Every read verb exits 3 with one stderr line, and a `talos.sh` run stops with `reason=config-unreadable`:

- `reason=config-shadowed winner=<json> also-present=<strays>`: a `talos.pipeline.yml` or `.yaml` sits beside a layer's json. Merge it in, delete it.
- `reason=config-legacy-file <path>`: a YAML file with no json beside it. Write the json by hand (no YAML parser).
- `reason=config-pointer-missing <path>`: `PIPELINE_CONFIG` names a missing file. A `.yml`/`.yaml` pointer is refused as legacy; a valid pointer skips the stray check.
- An unknown or unusable LLM profile exits 4 ([Profiles, runners and fallback](#profiles-runners-and-fallback)).
- If `pipeline-defaults.sh` is missing or truncated, a security-relevant key with no caller default (`merge.auto`, `limits.*`, `hooks.*`, `roles.qa|reviewer|security`, the forbidden-file and waiver lists, `markers.*`) stops the script rather than guess.

An invalid value of a validated key (positive integers such as `verify.timeout_ms`, `hooks.timeout_s`) warns once and reads as absent, so the default applies. `verify.qa_mode: ci` with empty `merge.required_checks` resolves to `local` with a warning.

## Config key reference

Every config key, generated from `scripts/pipeline-defaults.sh`, the only place a default is written. Regenerate after changing that table with `python3 tests/gen-config-table.py --write docs/reference.md`; `tests/test-docs-config-table.sh` fails while the two disagree. What a key does is described in the section named by its prefix; an unknown key warns and is ignored ([Configuration](#configuration)).

- **Type:** `str`, `path`, `int`, `float`, `bool`, `enum`, `list`, or `secret` (holds an `env:NAME` reference, never a value).
- **Default:** what `pipeline-config.sh KEY` prints when no layer sets the key. `-` is empty. `derived` means the value is computed (below).
- **Env override:** a non-empty variable of this name beats both files.
- **Scope:** `any` can be set in the user-level file; `repo` only in the repo's `talos.pipeline.json`.
- `*` in a key stands for a dynamic segment (a role name, a status name, a profile name).

Derived defaults: `base_branch`, `repo`, `vcs.repo` and `board.owner` come from the git remote or `gh`; `agents.restamp_model`, `agents.restamp_effort` and every `agents.roles.<role>.<key>` fall back role, then global, then `agents.model` / `agents.effort`; `merge.forbidden_files` is a built-in pattern list; `merge.approval_waiver_paths` defaults to `*.md`, `docs/**`, `CHANGELOG.md`, `*.example` and `merge.union_paths` to `CHANGELOG.md`; `board.statuses.*` and `board.status_map.*` take the pipeline's own status names; `pr.draft` is resolved by `scripts/pipeline-draft-check.sh` ([Gates: verify, QA, CI and merge](#gates-verify-qa-ci-and-merge)). `verify.qa_mode` is `ci` when `merge.required_checks` is set, else `local`.

<!-- config-table:start (generated by tests/gen-config-table.py; do not edit) -->

#### (top level)

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `base_branch` | str | derived | - | repo |
| `repo` | str | derived | - | repo |
| `verify` | list | - | - | repo |

#### vcs.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `vcs.provider` | enum | `github` | - | repo |
| `vcs.repo` | str | derived | `PIPELINE_REPO` | repo |
| `vcs.token_env` | str | - | - | any |
| `vcs.azure.org_url` | str | - | - | repo |
| `vcs.azure.project` | str | - | - | repo |
| `vcs.azure.work_item_type` | str | `Product Backlog Item` | - | repo |
| `vcs.azure.area_path` | str | - | - | repo |
| `vcs.file.source.path` | path | `plan.md` | - | repo |

#### board.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `board.enabled` | bool | `true` | - | repo |
| `board.project_number` | int | - | `PIPELINE_PROJECT_NUMBER` | repo |
| `board.owner` | str | derived | `PIPELINE_BOARD_OWNER` | repo |
| `board.status_field` | str | `Status` | `PIPELINE_STATUS_FIELD` | repo |
| `board.statuses.*` | str | derived | - | repo |
| `board.status_map.*` | str | derived | - | repo |
| `board.azure_states.ready` | str | `New` | - | repo |
| `board.azure_states.in_progress` | str | `Committed` | - | repo |
| `board.azure_states.in_review` | str | `Committed` | - | repo |
| `board.azure_states.done` | str | `Done` | - | repo |
| `board.azure_states.*` | str | derived | - | repo |

#### verify.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `verify.commands` | list | - | - | repo |
| `verify.qa_mode` | enum | `local` | - | repo |
| `verify.targeted` | bool | `true` | - | any |
| `verify.ci_wait_s` | int | `900` | - | any |
| `verify.timeout_ms` | int | `600000` | - | any |

#### merge.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `merge.auto` | bool | `true` | - | any |
| `merge.method` | enum | `squash` | - | any |
| `merge.required_checks` | list | - | - | repo |
| `merge.forbidden_files` | list | derived | - | repo |
| `merge.forbidden_files_replace` | bool | `false` | - | repo |
| `merge.forbidden_files_allow` | list | - | - | repo |
| `merge.approval_waiver_paths` | list | derived | - | repo |
| `merge.union_paths` | list | derived | - | repo |
| `merge.auto_sync` | bool | `true` | - | any |

#### issues.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `issues.label_filter` | str | `pipeline:ready` | - | repo |
| `issues.skip_labels` | list | `pipeline:blocked, wontfix` | - | repo |
| `issues.max_parallel` | int | `1` | - | any |
| `issues.assignee` | str | `self` | - | any |
| `issues.claim` | bool | `true` | - | any |

#### identity.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `identity.name` | str | - | - | any |

#### execution.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `execution.isolation` | enum | `worktree` | - | any |
| `execution.worktree_warn_threshold` | int | `10` | - | any |

#### roles.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `roles.validator` | bool | `true` | - | any |
| `roles.pm` | bool | `true` | - | any |
| `roles.pm_skip_when_spec_present` | bool | `true` | - | any |
| `roles.qa` | bool | `true` | - | any |
| `roles.reviewer` | bool | `true` | - | any |
| `roles.security` | bool | `true` | - | any |
| `roles.adversarial` | bool | `false` | - | any |
| `roles.docs` | bool | `true` | - | any |
| `roles.docs_mode` | enum | `auto` | - | any |
| `roles.planner` | bool | `false` | - | any |

#### comments.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `comments.enabled` | bool | `true` | - | any |
| `comments.header` | str | `**Agent:** {role} (talos)` | - | any |
| `comments.templates_dir` | path | `templates/comments` | - | any |

#### notifications.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `notifications.slack_channel` | str | - | `PIPELINE_SLACK_CHANNEL` | any |
| `notifications.discord_channel` | str | - | `PIPELINE_DISCORD_CHANNEL` | any |
| `notifications.buzz_channel` | str | - | `PIPELINE_BUZZ_CHANNEL` | any |
| `notifications.buzz_relay` | str | - | `PIPELINE_BUZZ_RELAY` | any |
| `notifications.buzz_timeout_s` | int | `15` | - | any |
| `notifications.slack.webhook` | secret | - | - | any |
| `notifications.discord.webhook` | secret | - | - | any |
| `notifications.teams.webhook` | secret | - | - | any |
| `notifications.slack.bot_token` | secret | - | - | any |
| `notifications.discord.bot_token` | secret | - | - | any |
| `notifications.buzz.bot_key` | secret | - | - | any |
| `notifications.templates_dir` | path | `templates/notifications` | - | any |
| `notifications.threading` | bool | `true` | - | any |
| `notifications.events` | list | - | - | any |
| `notifications.cmd` | str | - | - | any |
| `notifications.cmd_timeout_s` | int | `10` | - | any |

#### agents.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `agents.runner` | enum | `claude` | - | any |
| `agents.subagents` | enum | `auto` | - | any |
| `agents.runner_args` | str | - | - | any |
| `agents.runner_cmd` | str | - | - | any |
| `agents.claude_allowed_tools` | list | - | - | any |
| `agents.claude_permission_mode` | enum | - | - | any |
| `agents.model` | str | - | - | any |
| `agents.restamp_model` | str | derived | - | any |
| `agents.effort` | enum | - | - | any |
| `agents.restamp_effort` | enum | derived | - | any |
| `agents.roles.*.model` | str | derived | - | any |
| `agents.roles.*.runner` | enum | derived | - | any |
| `agents.roles.*.runner_cmd` | str | derived | - | any |
| `agents.roles.*.claude_allowed_tools` | list | derived | - | any |
| `agents.roles.*.claude_permission_mode` | enum | derived | - | any |
| `agents.roles.*.restamp_model` | str | derived | - | any |
| `agents.roles.*.effort` | enum | derived | - | any |
| `agents.roles.*.restamp_effort` | enum | derived | - | any |
| `agents.fallback` | list | - | - | any |
| `agents.roles.*.fallback` | list | derived | - | any |
| `agents.provider_down_s` | int | `900` | - | any |
| `agents.stage_timeout_s` | int | - | - | any |
| `agents.roles.*.stage_timeout_s` | int | derived | - | any |
| `agents.capture_usage` | bool | `true` | - | any |
| `agents.profile` | str | - | `TALOS_PROFILE` | any |
| `agents.mode` | enum | - | - | any |

#### limits.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `limits.max_fix_attempts` | int | `3` | - | any |
| `limits.max_total_dispatches` | int | `8` | - | any |
| `limits.max_retries` | int | `5` | - | any |
| `limits.tokens_per_issue` | int | - | - | any |
| `limits.warn_at` | float | `0.8` | - | any |

#### spend.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `spend.comment` | bool | `true` | - | any |

#### pr.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `pr.draft` | bool | derived | - | any |

#### markers.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `markers.trusted_authors` | list | - | - | repo |
| `markers.verify_authors` | bool | `true` | - | repo |

#### hooks.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `hooks.pre_dispatch` | str | - | - | any |
| `hooks.post_stage` | str | - | - | any |
| `hooks.timeout_s` | int | `30` | - | any |

#### events.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `events.enabled` | bool | `true` | - | any |
| `events.path` | path | `talos/events.jsonl` | - | any |

<!-- config-table:end -->

## Profiles, runners and fallback

Three independent choices: **mode** (who spawns a stage), **runner** (which CLI executes it) and **model/effort**. A **profile** bundles them under one name. Talos never calls a model API itself; every runner must be an agentic CLI (it runs shell commands and edits files).

### Modes and runners

- `native`: the harness's own subagent tool (Claude Code's Agent); parallel issues, worktree isolation.
- `adapter`: one headless CLI call per stage through `scripts/pipeline-agent.sh <role> -`; sequential, set `issues.max_parallel: 1`.
- `inline`: the orchestrating session plays every role itself (pi, weak or local models).

`agents.subagents` is `auto` (default), `true` or `false`: `auto` is `native` on Claude Code (and on an unknown harness when the runner is `claude`), elsewhere `inline` for runner `pi`, else `adapter`; `false` is `inline` for runner `pi`, else `adapter`; `true` is `native`. `agents.mode` (`native|adapter|inline`) sets it directly. The harness is `CLAUDECODE=1` or `TALOS_HARNESS` (for example `pi`; it wins). Claude Code provides all three modes, any other declared harness `adapter` and `inline`.

`agents.runner` is `claude` (default), `pi`, `codex`, `gemini`, `antigravity` or `custom`; `agents.runner_args` (a list, one value for all roles) adds arguments to the built-in ones.

Invocations (the prompt is the last argument): `claude -p --setting-sources project [args]`, `pi -p [args]`, `codex exec [args]`, `gemini [args] -p`, `agy [args] -p`, and for `custom` `sh -c "$runner_cmd"` with the prompt on stdin. The prompt is the role body (frontmatter stripped), a `---` line, then the stage prompt. Per harness: [Install and setup](#install-and-setup). On the native path, a role whose runner is not `claude` goes through `pipeline-agent.sh`; the rest stays native.

### Per-role model, effort and runner

Each key resolves `agents.roles.<role>.<key>`, then `agents.<key>`.

| Key | Effect |
|---|---|
| `model` | Native spawn: full ID or `opus`/`sonnet`/`haiku` (an alias-only harness gets the family alias); unset means the session model. Adapter: built-in runners ignore it, `custom` gets `$TALOS_MODEL`. |
| `effort` (`low\|medium\|high\|max`) | Adapter: exported as `$TALOS_EFFORT`. Native: advisory; commit `effort:` in the role file, `pipeline-agent.sh --check-effort <role>` flags a mismatch. |
| `runner`, `runner_cmd` | Both paths; `runner_cmd` is read only for `custom`. No per-role `runner_args`. |
| `restamp_model`, `restamp_effort` | Delta re-review of a stale approval: role restamp, global restamp, then `model` / `effort`. |

The user-level file `${TALOS_HOME:-~/.talos}/talos.pipeline.json` applies to every repo and accepts every key except the repo-only ones; a `runner_cmd` there runs in every repo, so keep only trusted values in it.

See the result with `bash scripts/pipeline-agent.sh --resolve <role>` (`runner= runner_cmd= model= effort=`) and `--resolve-all` (one row per role with `origin=project|global|session default`).

Shipped `agents/*.md` carry no `model:` line: the Talos config is the only place a model is set, and `--resolve-all` warns when a role file under `.claude/agents/` or `${CLAUDE_CONFIG_DIR:-~/.claude}/agents/` has one.

### Profiles

`agents.profiles.<name>` holds any subset of `agents.*` plus `mode`; `agents.profile` or env `TALOS_PROFILE` selects one (names: 1-32 characters of `A-Za-z0-9_-`, starting with a letter or digit).

```json
{ "agents": { "profile": "claude", "fallback": ["local"],
  "profiles": {
    "claude": { "mode": "native", "model": "sonnet", "roles": { "security": { "model": "opus" } } },
    "local":  { "runner": "pi", "mode": "inline", "model": "glm-5.3-flash" }
} } }
```

- Order per key: environment, selected profile, base `agents.*`, default. A profile's `roles` replaces the base `roles` whole (`"roles": {}` clears them).
- An unknown name stops the run: `reason=profile-unknown name='x' origin=env valid=...` (exit 4), never a silent fallback to the base config.
- A profile is usable when the harness provides its mode and its runner CLI is on `PATH` (`custom`: a non-empty `runner_cmd`); with more than one candidate, a runner marked down in `providers.json` is passed over too (a lone candidate is used anyway). Candidates are `[profile, ...fallback entries naming a profile]`; the first usable is active, each one passed over is `PROFILE_SKIPPED=<name> reason=<why>`. None usable: `reason=profile-unusable` (exit 4).
- `bash scripts/talos.sh env` prints `HARNESS`, `PROFILE`, `PROFILE_ORIGIN`, `HARNESS_ORIGIN`, `AGENTS_MODE`, `PROFILE_SKIPPED` and a `PROFILE_INFO` per profile once profiles are configured or `TALOS_PROFILE` / `TALOS_HARNESS` is set.

### Custom runner contract

`runner_cmd` runs as `sh -c` in the worktree with the prompt on stdin.

- Environment: `TALOS_ROLE`, `TALOS_ISSUE_NUMBER` (the caller's integer `TALOS_ISSUE`, else empty), `TALOS_WORKTREE_PATH`, `TALOS_EFFORT`, `TALOS_MODEL` (unset when none), `TALOS_USAGE_FILE`.
- stdout is the final message. Under `talos.sh run` it needs a line starting with the role's verdict word and a colon (`CONFIRMED:`, `PASS:`, `APPROVED:`, `CLEAR:`); the developer's carries the PR URL.
- Exit `0` ok, `75` provider error (fail over), `124` stage timeout, other non-zero a task failure.

`agents.stage_timeout_s` (60-86400, per-role override, unset = none) bounds each attempt: the runner and its children are killed, exit 124, stderr `pipeline-agent: reason=stage-timeout role=<r> after_s=<n>`. A timeout is a task failure, never a failover. Needs `perl`.

### Runner fallback

`agents.fallback` (also `agents.roles.<role>.fallback`, role first) is 1-5 distinct entries, each a runner or a profile name (a name that is both is the profile); `provider_down_s` is 60-86400. A bare runner uses its default model and no `runner_args`; a profile entry brings its own runner, `runner_cmd`, `runner_args`, model, effort and `stage_timeout_s`. Failover applies to the adapter path; when native Claude Code itself runs out, switch profile.

An attempt is `ok` (exit 0), `provider` (exit 75, or a line-anchored claude error in the last 20 lines: `API Error: 429|5xx|401`, `Credit balance is too low`, `usage limit reached`, `You've hit your ... limit`, a network error) or `task` (anything else, a bare `429` in prose, a timeout). Only the `hit your ... limit` line was captured from a real run; `codex`, `gemini`, `antigravity`, `pi` and `custom` classify by exit 75 only.

A `provider` exit is not counted as an attempt (`limits.max_fix_attempts`, `limits.max_total_dispatches`). The runner is marked down in `<repo-root>/.talos/providers.json` for `provider_down_s` seconds, `talos:failover role=<r> from=<a> to=<b> reason=<class:detail>` goes to stderr, work is checkpointed and a `failover` event is logged.

**Write guard.** A stage that already wrote is never rerun. `pipeline-vcs.sh` journals each successful write verb (comments, `create-pr`, `create-issue`, `post-approval`, `approve-pr`, `merge-pr`, `close-issue`, `record-attempt`) to `$TALOS_WRITE_LOG`; a moved `refs/remotes` ref counts as a push. Either one after a provider exit prints `talos:failover-refused role=<r> runner=<x> reason=wrote:<verbs|push>`.

**Exit 69**: chain exhausted, every runner down, or failover refused. `talos.sh run` stops with `stop reason=provider-failed rc=<75|69>` and records nothing. The playbook sets `pipeline:blocked` and runs no fix round; remove the label to resume. Native path verbs: `pipeline-agent.sh --classify <runner> <rc> <file|->` and `--mark-down <runner> <class:detail>`.

### Claude permissions on headless stages

`claude -p` cannot answer an approval prompt, so a claude-runner stage in a repo with no allowlist of its own could run nothing. `pipeline-agent.sh` passes `--allowedTools` (a scoped default per role), `--add-dir <the Talos scripts dir>` (skipped when the stage cwd is inside it) and `--disallowedTools Edit/Write` on that dir. Rule grammar: [Claude Code permissions](https://code.claude.com/docs/en/permissions); `Bash(<prefix>:*)` allows the prefix and anything after it, and each subcommand of a compound command must match on its own.

| Role | Default allowlist |
| --- | --- |
| all | `Read`, `Glob`, `Grep`; each `pipeline-*.sh` and `talos.sh` present in the install, by name, as `scripts/X`, `./scripts/X` and `<install dir>/X`; read-only git (`status`, `diff`, `log`, `show`, `rev-parse`, `ls-files`, bare `branch`, `branch --show-current`, `branch --list`) |
| developer | + `Edit`, `Write`, `Bash(git:*)`, the verify commands |
| validator, qa | + the verify commands |
| docs | + `Edit`, `Write` |

A verify command becomes `Bash(<command>:*)` only when it is plain words (letters, digits, space and `. / _ = : @ % +  -`). Anything with a quote, `$`, `` ` ``, `;`, `&`, `|`, `<`, `>`, `*`, a parenthesis or a backslash cannot be a prefix rule without widening it, so it is skipped with a warning that names its position, not its text; add a rule for it with `agents.claude_allowed_tools`.

- `agents.claude_allowed_tools` (list) adds rules, e.g. `["Bash(npm run lint:*)"]`. `agents.roles.<role>.claude_allowed_tools` replaces the global list for one role. An entry must be `Name` or `Name(args)` with no comma, control character or inner parenthesis; others are dropped with a warning.
- `agents.claude_permission_mode` (`acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`; role override `agents.roles.<role>.claude_permission_mode`) is unset by default and then no `--permission-mode` is passed. **Risk:** issue and PR text is untrusted input and a stage acts on it; `bypassPermissions` removes every guard, so use it only on a sandboxed or ephemeral runner. A broad `claude_allowed_tools` entry such as `Bash` or `Bash(*)` is the same trade.
- An `--allowedTools` or `--dangerously-skip-permissions` in `agents.runner_args` is the owner's own policy: nothing is added on top of it. A `--permission-mode` there wins over the config key.

A stage whose final message starts with `BLOCKED: <reason>` is a blocked outcome for any role: `talos.sh run` sets `pipeline:blocked` on the issue (and the PR), relays the reason, and stops with `stop reason=stage-blocked role=<r>` (exit 0).

### Token usage on adapter runs

Each attempt reports `tokens` (input + output + cache-creation, no cache reads; else `null`, never `0`) to the stage event, so `pipeline-events.sh cost` and `limits.tokens_per_issue` count it. Every attempt prints `talos:usage runner=<r> tokens=<N|null>` on stderr; a failed attempt with usage becomes a `stage_attempt` event.

- `claude`: `--output-format json` is added after `runner_args`; `modelUsage` is summed over all models, else top-level `usage`.
- `custom`: a JSON sidecar at `$TALOS_USAGE_FILE`, every key optional: `{"tokens": 1234, "tool_uses": 7, "model": "qwen2.5-coder"}`.
- `codex`, `gemini`, `antigravity`, `pi`: `null`.

`agents.capture_usage: false`, or `--output-format` in `runner_args`, leaves the claude call untouched.

### Local models and a second backend

Serve the model, point an agentic CLI at it, use it as `custom`:

```bash
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja   # --jinja: tool calls
```

```json
{ "agents": { "runner": "custom",
  "runner_cmd": "OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local aider --model openai/local --yes-always --no-auto-commits --message \"$(cat)\"" } }
```

For an independent review on another backend, set `roles.adversarial: true` (off by default; runs after security and gates the merge on `adversarial:approved`) and give only that role a runner: `"agents": {"roles": {"adversarial": {"runner": "custom", "runner_cmd": "/path/to/wrapper.sh"}}}`.

### Role profile files

`pipeline-agent.sh` resolves `agents/<role>.md` in this order: `<repo>/.claude/agents/<role>.md`, `<repo>/.agents/talos/agents/<role>.md` (committed; symlinks skipped), the install (`$TALOS_HOME/agents`, `~/.talos/agents`), the plugin copy. Native subagents load `.claude/agents/` only. `--resolve-profile <role>` prints the winner. Frontmatter is Claude Code metadata; other runners get the body only.

## Providers and the board

Every VCS call goes through [`scripts/pipeline-vcs.sh`](../scripts/pipeline-vcs.sh). Select the backend with `vcs.provider` (repo file only); an unknown value exits 1.

### Providers and prerequisites

| `vcs.provider` | Needs | Auth and setup |
|---|---|---|
| `github` (default) | `gh`, or no CLI | `gh auth login`, or export `GITHUB_TOKEN` / `GH_TOKEN` |
| `github-api` | nothing (curl) | export `GITHUB_TOKEN` / `GH_TOKEN` |
| `gitlab` | `glab` | `glab auth login` |
| `azure` | `az` + azure-devops extension | `az login`; `az extension add --name azure-devops`; `vcs.azure.org_url` + `vcs.azure.project`, or `az devops configure --defaults organization=<url> project=<name>` |
| `file` | nothing | none, fully offline |

### GitHub transport

`github` and `github-api` are one REST client with two transports. `github` uses `gh api` when `gh` is on PATH and `gh auth token` succeeds, else curl with a token. `github-api` always uses curl and never calls `gh` (CI, containers).

Token lookup: the variable named by `vcs.token_env`, else `GITHUB_TOKEN`, then `GH_TOKEN`. Export it in the shell; `GH_*` and `GITHUB_*` are never read from a `.env` file. With neither, the client exits 1.

The token transport needs `owner/repo`: set `vcs.repo` if the origin remote lacks it.

`github-api` ignores `pr.draft` (ready-PR flow, one warning); `github` without `gh` installed uses the same transport and keeps draft PRs. The board scripts use curl GraphQL when the provider is `github-api` or `gh` is not on PATH; they do not detect an installed but logged-out `gh`.

### GitLab

`list-issues` and `list-prs` stop at 100 items (`WARNING result capped at 100` on stderr). No board (`pipeline-status.sh` prints `board unsupported for gitlab`). `pr-checks-required` fails closed.

### Azure DevOps

| Key | Meaning |
|---|---|
| `vcs.azure.org_url`, `vcs.azure.project` | Organization URL, project |
| `vcs.repo` | Azure repository name |
| `vcs.azure.work_item_type` | Type `create-issue` makes (default `Product Backlog Item`) |
| `vcs.azure.area_path` | Area path for new work items |
| `board.azure_states.{ready,in_progress,in_review,done,blocked}` | Work-item State per pipeline status |

- Labels are Tags. A board move sets the work item State. Defaults are Scrum (`New`, `Committed`, `Committed`, `Done`); `blocked` is unset and leaves the State alone. Set the keys for Agile or CMMI.
- `create-pr` links the work item named by an `issue-<N>` branch with `--transition-work-items true`; that link closes it, not `Closes #N`.
- `close-issue` sets `board.azure_states.done` and strips `pipeline:*` tags. `merge-pr` completes the PR (policies apply; `merge.method` is not passed). `update-branch` exits 2.
- `bootstrap-board.sh` checks each configured state against the work item type, exits non-zero on a miss, never creates one.

### GitHub-only verbs

Attempt counting (`record-attempt`, `check-attempt`, `read-attempt`), approval markers (`post-approval`, `check-approval-sha`), `read-comments`, `upsert-pr-comment`, `edit-pr-body`, `has-spec`, `mark-needs-owner`, `conflict-files`. Other providers exit non-zero; `talos.sh next` then stops with `unsupported-verb:<verb>`.

### File mode and chat mode

`vcs.provider: file` uses a markdown checklist as issue list and board; `vcs.file.source.path` names it (default `plan.md`). Each `- [ ] Title` line is a work item, tagged `<!-- id: N -->` on the first `list-issues`; indented lines are its detail; `close-issue` ticks it. No PRs, labels, board, QA, review, security or docs: the validator and developer run and the developer commits to a branch. See [`file-mode.md`](../skills/pipeline/refs/file-mode.md).

Chat mode: with no issues or plan file, describe the tasks to the orchestrator; it writes `plan.md` and sets `vcs.provider: file` in `talos.pipeline.json`.

### Labels

`bash ~/.talos/scripts/bootstrap-labels.sh [owner/repo]` creates or updates these labels (idempotent) with `gh label create`, so it needs `gh`. Not needed for file mode or Azure.

| Label | Set by | Meaning |
|---|---|---|
| `pipeline:ready` | you | Queued; the validator takes it |
| `pipeline:confirmed` | validator | In scope; the PM writes the spec |
| `pipeline:dev` | PM | Spec ready; the developer implements |
| `pipeline:review` | developer, on the PR | PR open; QA and reviews follow |
| `qa:pass`, `review:approved`, `security:approved`, `docs:done`, `adversarial:approved` | stages | Per-role approvals on the PR head SHA |
| `pipeline:approved` | `talos.sh gate merge` | Gates passed, `merge.auto` false: a human merges |
| `pipeline:blocked` | stages | Halted; a human must act and remove it |
| `pipeline:needs-owner` | stages | Waiting on an owner decision |
| `pipeline:epic-decomposed`, `pipeline:epic-children-done` | orchestrator | Epic split; all sub-issues closed |
| `epic` | you | Marks an epic for the planner |
| `spec:ready` | you | Body is already a spec; skips the PM |
| `skip-qa` | you | Skips QA, review, security, docs; CI and forbidden-files still run |
| `p0`, `p1`, `p2` | you | Dispatch order, p0 first |

### GitHub Project board

A Projects v2 board with a single-select `Status` field mirrors progress. Keys (repo file only):


| Key | Meaning |
|---|---|
| `board.enabled` | `false` turns board updates off |
| `board.project_number` | Required; unset skips updates (`PIPELINE_PROJECT_NUMBER`) |
| `board.owner` | Project owner, default the repo owner (`PIPELINE_BOARD_OWNER`) |
| `board.status_field` | Field name (`PIPELINE_STATUS_FIELD`) |
| `board.status_map.<status>` | Map a pipeline status to your column |

Talos sets `In progress` (validator confirmed), `In review` (PR opened), `Blocked` and `Done` (merged). Create all four options; `Ready` is conventional and never set. The `gh` transport checks all four (after `status_map`) on a run's first call; the token transport checks only the option it is about to set.

A missing option never stops the run: the issue is still added in the default column and `pipeline-status.sh` prints `talos:board-unverified project=<N>` on stdout, names the options on stderr and exits 0.

```json
{ "board": { "enabled": true, "project_number": 4, "owner": "myorg",
             "status_map": { "Blocked": "Needs attention" } } }
```

`bash scripts/bootstrap-board.sh [owner/project_number]` adds the missing options. GitHub's update replaces the whole option list, so it resends every existing option and fails loudly if one changed id. `gh` needs the `project` scope (`gh auth refresh -s project`). With `board.enabled: false` or `file` it prints `board disabled`; on GitLab it only checks that `pipeline:blocked` exists.

### Commands to run by hand

From `~/.talos/scripts` (or `scripts/` in a checkout); `--dry-run` prints the call instead.

- `pipeline-vcs.sh list-issues | list-prs | view-issue <n> | view-pr <n>`: read as JSON.
- `pipeline-vcs.sh label-issue <n> --add pipeline:ready`: queue an issue (`--remove` drops a label).
- `pipeline-vcs.sh current-user | assert-sync`: your login; checkout clean and level.
- `talos.sh state --summary`: in flight, waiting, next, other operators' items.

## Isolation, locking and multi-user claims

### Isolation modes

`execution.isolation` picks the working copy each stage runs in. `pipeline-isolation.sh validate` checks it at startup and exits 1 on a bad value.

| Value | Behaviour |
|---|---|
| `worktree` (default) | One git worktree per stage and issue; allows `issues.max_parallel` above 1 |
| `branch` | Stages run in the orchestrator's own checkout on a per-issue branch; `issues.max_parallel` above 1 is refused at startup |
| `checkout` | Recognised, refused as not implemented; any other value is refused too |

In `branch` mode the orchestrator runs `pipeline-vcs.sh assert-sync` before each developer dispatch, and before reviewer and security. A dirty tree (untracked files count) or a checkout that diverged from `origin/<base_branch>` stops the issue, so commit files such as `AGENTS.md` first. Use `branch` when worktrees break the build: submodules, ignored-but-required artifacts (`node_modules/`), absolute paths into the main checkout, or a monorepo too big to copy per issue.

### Worktree lifecycle and cleanup

The developer worktree is `fix|feat/issue-<N>-<slug>`. QA, reviewer, security and docs get a Claude Code `agent-*` worktree under `.claude/worktrees` with no issue number in its name, so each stage's first verb (`pipeline-criteria.sh qa-run`, `post-approval --issue <N>`) writes `<worktree>/.talos/env` to tag it. `.talos/` is hidden through `.git/info/exclude`.

- `pipeline-worktree.sh remove <N>` runs after a merge (`talos.sh post-merge`). It removes every worktree of issue N, their local branches and the handoff file, but keeps one with uncommitted or unpushed work and says why.
- `pipeline-worktree.sh sweep [<id>...]` runs at the start (`talos.sh sweep`, with the run's queue ids) and end (`talos.sh summary`, with those ids plus the issue of every open PR) of a run. It removes every other worktree, dirty or not, including any it cannot identify; with no ids that is all of them. It never removes the current checkout or a lane home. It also deletes local branches that are not `main`, `master` or `base_branch`, have no remote and head no open PR (skipped if the PR list is unreadable), then prints `talos:worktree-sweep removed=<n> kept=<n> freed=<size>`.
- `pipeline-worktree.sh status` prints worktree, dirty and branch counts and the size of `.claude/worktrees`. `list` adds `pipeline-worktree: WARNING: <N> stale worktrees exceed threshold <T>` when more than `execution.worktree_warn_threshold` are stale; the run summary relays it. The threshold changes the warning only.

### Parallel runs and locking

`issues.max_parallel` caps the issues in flight: `talos.sh next` counts the leases other runs hold and answers `action=wait reason=cap` at the cap.

**Leases.** Before `next` answers a dispatch or merge it records the issue in `<git common dir>/talos-lease.ledger`. A second run on that issue gets `wait reason=lease retry_after_s=<s>` and never takes over. `done`, `post-merge` and the end of the run release it. A lease lasts `verify.timeout_ms/1000 + verify.ci_wait_s` seconds, at least 30 minutes; a line whose process is gone is reclaimed after 10 s (`TALOS_LEASE_RECLAIM_S`). `bash scripts/talos.sh lease prune` deletes dead and expired lines.

**Locks.** `mkdir`-based advisory locks (`<resource>.lock.d`, no `flock`) serialise worktree metadata (`create`, `remove`, `sweep`, `tag`, the temporary worktrees of `conflict-files` and `pipeline-mergebase.sh`) and the notification thread map. A lock whose holder died is reclaimed. One not acquired within 5 or 10 s prints a warning and the call proceeds, so a stuck lock never deadlocks a run (the lease ledger's lock is the exception: it answers `wait reason=lease` or stops with `lock-timeout`). Board updates are idempotent and not locked.

Talos manages no Docker project names, ports or scratch directories. With `max_parallel` above 1, make `verify` commands safe side by side, for example `COMPOSE_PROJECT_NAME=talos-$TALOS_ISSUE_NUMBER` (`pipeline-verify.sh` supplies `TALOS_ISSUE_NUMBER`).

### Multi-lane repos

Several lanes (say `main` and an experiment branch, each with its own config) can share one remote. Two operations are repo-wide:

- `list-prs`: each lane's `base_branch` is passed to the GitHub `list-prs`, so a lane sees only PRs aimed at its base.
- `sweep`: it would delete an inline runner's lane-home checkout. Mark each home once: `touch <lane-home>/.talos-lane-home` (untracked). `sweep` and `remove` never delete a marked directory. With more than one marker in the repo, `sweep` does nothing (exit 0) unless `TALOS_SWEEP_ALL_LANES=1`; `remove <N>` is unaffected. With one marker the sweep still runs repo-wide and spares only that home; mark every lane home (two or more markers make `sweep` a no-op) or none.

### Multi-user claims

Several people can run Talos on one repo, each with their own login. The issue assignee is the lock; no label or file is added.

| Key | Default | Meaning |
|---|---|---|
| `issues.claim` | `true` | `false` turns claiming and the filter off |
| `issues.assignee` | `self` | Who `create-issue` and the move to `In progress` assign: `self`, a login, or `none`. An existing assignee is never overwritten |
| `identity.name` | unset | The login you claim under; what `self` means when set |

Identity, resolved once per run: `issues.assignee` when it names a login, else `identity.name`, else the authenticated login (`current-user`). Claiming is off when `issues.claim` is false, `issues.assignee` is `none` or empty, or no login resolves (an Actions token, file mode). Set `identity.name` where the authenticated name is not assignable, such as an Azure DevOps UPN. Keep `self` in a shared config; a fixed login makes everyone claim as that person.

**Claim.** Before the first stage on an issue with no assignee, `talos.sh next` assigns it to you and reads the assignees back. If another login landed at once, the lowest login (case-insensitive) keeps it; the others run `unassign-issue` and move to the next issue. GitHub and GitLab hold several assignees, so both writes land and the read-back settles it; Azure DevOps holds one, so the later write wins. Talos releases a claim only when it loses that tie; a blocked issue stays yours until a human unassigns it.

**What others see.** `collect`, `state`, `next` and `run` act only on issues assigned to you or to nobody, and on pipeline PRs of such issues; an issue you hold stays yours if someone is added. Another operator's issues and PRs are never routed: `talos.sh state --summary` lists them as `theirs: #N (@login)` and `next --issue N` answers `wait reason=theirs`.

`bash scripts/talos.sh claim <N>` claims one issue and prints `claim=taken|owned owner=<me>`, `claim=lost owner=<login>`, `claim=unclaimed reason=not-assignable` (the assignment did not land, nobody holds it) or `claim=off reason=<disabled|assignee-none|identity-unresolved>`. The lease ledger separates two sessions of one user; the assignee separates users.

## Gates: verify, QA, CI and merge

`talos.sh gate merge <PR> <N>` runs every merge gate in this order and answers one verdict; it never merges itself (on `merge`, run `pipeline-vcs.sh merge-pr`).

| # | Gate | Fails as |
|---|---|---|
| 1 | No `pipeline:blocked`; every enabled role's approval label present (a human's `skip-qa` waives only this) | `wait` |
| 2 | `check-approval-sha`: approvals match the head SHA | `redispatch` |
| 3 | `check-pr-files`: forbidden files (`skip-qa` never waives) | `block` |
| 4 | `check-closing-keyword`: closing keyword while sibling PRs are open | `block` |
| 5 | Not a draft (only when `pr.draft` resolves true) | `redispatch` |
| 6 | `pr-checks-required`; a red check is re-run at most twice per head SHA (`talos:ci-rerun` markers) | `wait` / `redispatch` |
| 7 | Stale base: `pipeline-mergebase.sh`, then `update-branch` (`merge.auto_sync`), then a developer merge-base task | `wait` / `redispatch` |
| 8 | `merge.auto` | `merge` / `handoff` |

An unreadable gate answers `stop reason=<r>` (fail closed). Gates 3 and 4 set `pipeline:blocked`; only a human clears it.

### Verify once, QA trusts CI

| Key | Default | Meaning |
|---|---|---|
| `verify.commands` | none | Shell commands run in order, first failure stops. Repo file only. |
| `verify.targeted` | `true` | `true`: while iterating the developer runs only tests covering changed files; `false`: the full list after each change. Both run the full list once, after the last change. |
| `verify.qa_mode` | derived | `ci` when `merge.required_checks` is non-empty, else `local`. Explicit `ci` with no required checks becomes `local` (stderr warning). Repo file only. |
| `verify.ci_wait_s` | `900` | CI wait budget, 1 to 86400 s |
| `verify.timeout_ms` | `600000` | Foreground timeout for each verify and CI-wait call, 1 to 86400000 |

- Verify runs in the foreground only, through `scripts/pipeline-verify.sh [--issue N] [--worktree P] [-- cmd]`, which exports the stage identity and prints `talos:verify issue=.. worktree=..`.
- QA never runs the full list. `scripts/pipeline-criteria.sh qa-run` runs the spec's test files; other targeted runs use `tests/run-tests.sh --for <path> --strict` (Talos's own runner; exit 3 means no test selected and QA relies on CI). Reviewer, security and docs never run verify.
- Under `ci`, one `pr-checks-required <pr> --wait <B>` waits for CI, `B = min(verify.ci_wait_s, verify.timeout_ms/1000 - 30)`, at most 3600. QA is not dispatched into a `CONFLICTING` PR; red required CI re-dispatches the developer instead.

### Required checks

`merge.required_checks` (repo file only) lists check names as the provider reports them (GitHub check-run or status names; Azure policy display names, case-insensitive). `pipeline-vcs.sh pr-checks-required <pr> [--wait <s>]` reads only those:

| Exit | Meaning |
|---|---|
| 0 | all passed on the current head |
| 2 | pending or missing (a skipped check is pending, never a pass) |
| 1 | one failed (`pr-checks-required: failed:` on stderr), or the list is empty (never a vacuous pass) |

`--wait` takes digits, at most 3600 (else exit 2). On `github` and `github-api` it polls inside the call at 30 s, 60 s, then 120 s steps; other providers answer once. GitLab is not implemented and exits 1.

### Draft PRs

`pr.draft` opens the PR as a draft so docs, review and fixes start no CI. Order: developer (local verify, draft PR), docs, reviewer + security + adversarial in parallel, one fix round, re-stamps, `ready-pr` (the one CI run), QA, merge. A QA or CI failure runs `draft-pr` first, so a fix costs one run. QA and the CI wait start only when `pr-is-draft` exits 1 with stdout `ready`; `gate merge` reports `ci_runs` (`pr-ci-runs`, GitHub only).

`pipeline-draft-check.sh resolve` sets the effective value: explicit `false` is the ready flow; `file` mode and `github-api` never use drafts (`github-api` says so on stderr); `gitlab` and `azure` do unless `false`; `github` also runs the CI check. `pipeline-draft-check.sh check` prints one status (always exit 0):

| Status | Meaning |
|---|---|
| `ok` | PR workflows skip drafts and list `ready_for_review` in `types` |
| `no-skip` | nothing skips drafts: CI runs every push (saving lost) |
| `no-ready-trigger` | a job skips drafts but `ready_for_review` is missing, so marking ready starts no run. `pr.draft` unset: ready flow; `true`: warning only |
| `none`, `unknown` | no PR workflow, or unreadable |

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  test:
    if: github.event.pull_request.draft != true   # on every job
```

Only `!= true`, `== false` or `!draft` (alone or `&&`-combined) counts as a skip. `pipeline-draft-check.sh edit <file> [--write]` prints or applies the minimal diff and never edits an existing job `if:`. Example: `../templates/ci/github-tests.yml`.

### Approvals bound to the head SHA

An approval is a PR comment ending in `<!-- talos:approval sha=<40-hex head SHA> role=<role> -->` plus the role's label. `pipeline-vcs.sh post-approval <pr> <role> [--body-file f] [--issue n]` (`github` and `github-api` only) reads the head SHA itself, posts, labels and self-checks (`stamp ok`, or `stamp FAILED` and exit 1).

| Role | Label |
|---|---|
| `qa` | `qa:pass` |
| `reviewer` | `review:approved` |
| `security` | `security:approved` |
| `adversarial` (`roles.adversarial`) | `adversarial:approved` |
| `docs` | `docs:done` |

`check-approval-sha <pr> [--stale-list]` (`github` and `github-api` only) exits 1 when a present label has no valid marker or its SHA is not the head; `--stale-list` also prints `stale role=<role> label=<label>`.

**Author trust.** `markers.verify_authors` (default `true`, repo file only) accepts markers only from the authenticated identity (`gh api user`) plus `markers.trusted_authors`. Rejects print `talos:marker-authors-rejected authors=..` on stderr. Identity unavailable and no `trusted_authors`: markers are accepted and `talos:marker-authors-unverified reader=<verb>` prints. Lookup refused (Actions `GITHUB_TOKEN`, GitHub App token): only `trusted_authors` counts and an empty list rejects all; set e.g. `["github-actions[bot]"]`. `false` skips the check silently.

### Stale approvals and the delta re-stamp

A new commit stales an approval unless every file changed since the marker SHA matches `merge.approval_waiver_paths` (default `*.md`, `docs/**`, `CHANGELOG.md`, `*.example`). Never waivable: `scripts/`, `tests/`, `agents/`, `skills/`, `templates/prompts/`, runner dot-directories (`.claude/{agents,skills,commands,talos,rules}`, `.agents`, `.gemini`, `.pi`, `.codex`), `.agent/`, `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md`, `GEMINI.md`, and the pipeline config files (`talos.pipeline.{yml,yaml,json}`, `.claude-pipeline.{yaml,json}`, `pipeline.{yaml,json}`); an entry that would waive them fails the gate.

`gate merge` strips stale labels, comments, answers `redispatch`. A role that already approved gets a re-stamp: same role and profile, `talos.sh prompt <role> --shape restamp`, header `**Agent:** <role> (talos) — re-stamp`, delta and targeted tests only. `RESTAMP_PASS` re-confirms through `post-approval`; `RESTAMP_FAIL` strips the label and the next round runs the full stage. Model: `agents.roles.<role>.restamp_model`, then `agents.restamp_model` (defaults to `agents.model`), else the role's normal model; `restamp_effort` follows the same chain. 

### Merge settings

| Key | Default | Meaning |
|---|---|---|
| `merge.auto` | `true` | `false`: human merge |
| `merge.method` | `squash` | `squash`, `merge` or `rebase` |
| `merge.auto_sync` | `true` | `update-branch` on a stale base; sync sibling PRs after a merge |
| `merge.union_paths` | `["CHANGELOG.md"]` | paths `pipeline-mergebase.sh` may union-merge |

When `conflict-files <pr>` lists only `merge.union_paths` entries, `scripts/pipeline-mergebase.sh <pr>` resolves them with `git merge-file --union` (both sides kept, the PR's first) in a throwaway worktree and pushes, with no developer dispatch. Exit 0 pushed, 3 a path is not unionable (developer merge-base task), 1 setup error. Entries matching `scripts/**`, `tests/**`, pipeline config or forbidden patterns are rejected.

### Forbidden-files gate

`check-pr-files <pr>` fails when a changed path (basename or path, case-insensitive) matches a deny pattern. Built-ins: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `credentials.json`, `*-credentials.json`, `*_credentials.json`, `.aws/credentials`, `.docker/config.json`.

| Key | Effect |
|---|---|
| `merge.forbidden_files` | patterns added to the built-ins |
| `merge.forbidden_files_replace` | `true` with a non-empty `forbidden_files`: only your patterns apply (weakens the gate) |
| `merge.forbidden_files_allow` | exempt paths such as `.env.example`; an entry that would also exempt a denied path (e.g. `*.json`) fails validation and the gate fails closed |

Every run prints `talos:forbidden-files-active patterns=N defaults=in-force|replaced`, plus `talos:forbidden-files-defaults-replaced patterns=N` when replaced.

### Human merge

With `merge.auto: false` all gates still apply; `gate merge` labels the PR `pipeline:approved` and answers `handoff`, and `talos.sh post-merge <pr> <n> --handoff` posts `approved.md`. See `../skills/pipeline/refs/human-merge.md`.

### Criteria first

The PM numbers criteria `AC<n>`, marks each `(test)` or `(prose: reason)` and adds a `Tests:` line of file paths (data, never a command). The developer's first commit is the failing tests, id in each test name. `pipeline-criteria.sh qa-run <issue> <pr>` runs them at the red commit and at head, one line per id: `AC<n> red@<sha8> green@head`, `AC<n> FAIL ... vacuous` (green at red) or `AC<n> prose hand-checked`.

### Comment templates

`comments.enabled` (`true`), `comments.header` (`**Agent:** {role} (talos)`; empty posts nothing) and `comments.templates_dir` (`templates/comments`). `templates/comments/` holds one `string.Template` file per stage comment (`qa-verdict`, `review-signoff`, `security-signoff`, `blocked`, `approved`, `needs-owner`, ...) using `${HEADER}`, `${SUMMARY}`, `${DETAILS}`, `${VERDICT}`, `${PR}`, `${BLOCKED_BY}`, `${ATTENTION_REPORT}`. A missing template falls back to an inline body.

## Notifications

[`scripts/pipeline-notify.sh`](../scripts/pipeline-notify.sh) posts pipeline events to Slack, Discord, Teams, Buzz and/or a custom command.

```
pipeline-notify.sh <event> <ref> <message> [thread_key]
pipeline-notify.sh --render <platform> <event> [ref] [message]
```

`ref` is the label shown (`#42`). `message` is free text; `-` reads it from stdin (capped at 16384 bytes). `thread_key` groups one issue's events into a thread; the orchestrator passes the issue number, default `ref`. Sinks run independently in the order Slack, Discord, Teams, Buzz, `notifications.cmd`; a sink without credentials is skipped.

### Credentials and setup

A config file never holds a secret. The secret keys hold an `env:NAME` reference; a literal value is refused. Env-var overrides of channel keys: `PIPELINE_SLACK_CHANNEL`, `PIPELINE_DISCORD_CHANNEL`, `PIPELINE_BUZZ_CHANNEL`, `PIPELINE_BUZZ_RELAY`.

| Platform | Variable | Reference key | Also needs |
|----------|----------|---------------|------------|
| Slack webhook | `SLACK_WEBHOOK_URL` | `notifications.slack.webhook` | - |
| Slack bot | `SLACK_BOT_TOKEN` | `notifications.slack.bot_token` | `notifications.slack_channel` |
| Discord webhook | `DISCORD_WEBHOOK_URL` | `notifications.discord.webhook` | - |
| Discord bot | `DISCORD_BOT_TOKEN` | `notifications.discord.bot_token` | `notifications.discord_channel` |
| Teams webhook | `TEAMS_WEBHOOK_URL` | `notifications.teams.webhook` | - |
| Buzz | `BUZZ_BOT_PRIVATE_KEY` | `notifications.buzz.bot_key` | `notifications.buzz_channel`, relay: `BUZZ_RELAY_URL` or `notifications.buzz_relay` |

A webhook wins over a bot token for the same platform. A reference-resolved webhook URL must start with `https://`. Teams has webhooks only (a Power Automate Workflows webhook), so it never threads.

Lookup order, first hit wins: exported environment, repo `.env`, the `env:NAME` reference (NAME is searched in the environment, repo `.env`, `~/.talos/.env`, `~/.hermes/.env`; an unresolved reference does not fall back), `~/.talos/.env` (`$TALOS_HOME/.env`), then `~/.hermes/.env` (deprecated; `TALOS_HERMES_ENV=<path>` moves it, empty disables it).

- `.env` files are parsed, never sourced. The repo `.env` can be a PR branch, so only the variables above and the four `PIPELINE_*` overrides are read from it; other keys are ignored with a stderr line.
- `~/.talos/.env` is ignored unless it is a regular file you own, mode `0600`, outside every git work tree (`chmod 600 ~/.talos/.env`).

Buzz (self-hosted Nostr/NIP-29, no webhooks):

- Install the `nak` CLI (`brew install nak`); without it Buzz is skipped with a stderr line.
- `notifications.buzz_channel` is the group id, sent as the `h` tag. Admit the bot's pubkey to the relay first (`restricted: not a relay member` otherwise).
- Talos publishes a signed kind 9 event with `nak event --auth` (answers NIP-42 AUTH). The key goes through `NOSTR_SECRET_KEY`, never argv. Each call is bounded by `notifications.buzz_timeout_s`.
- `nak` exits 0 even on relay rejection, so Talos reads its stderr for failure.

Generic sink: `notifications.cmd` runs with `sh -c` after the other sinks, for every event that passes the filter, bounded by `notifications.cmd_timeout_s`. JSON on stdin:

```json
{"event": "pr-opened", "ref": "#42", "message": "...", "thread_key": "42",
 "fields": [{"label": "PR", "text": "#9", "url": "https://github.com/acme/widget/pull/9"}],
 "repo": "acme/widget", "issue": 42}
```

`message` is the neutral rendering (platform `default`); `fields` is the PR / Issue / Stage / Repo metadata (`url` empty when none); `issue` is null when unknown.

### Events and the filter

| Event | Sent when |
|-------|-----------|
| `validator`, `pm`, `developer`, `qa`, `reviewer`, `security`, `adversarial`, `docs` | A stage returns through `talos.sh done`; the message is its summary. These form the per-issue conversation. |
| `pr-opened` | The developer opens the PR. |
| `blocked` | A stage fails, or a gate needs a human. |
| `orchestrator` | All stages passed: merged and closed, or ready for human merge. |
| `merged`, `issue-closed` | After a merge. |
| `info` | Merge-base sync, blocked-backlog count, worktree warning, epic decomposed, setup test. |

`dispatched.md` ships but nothing emits `dispatched`.

`notifications.events` is a list of event names. Unset or empty means all fire. If set, other events are dropped silently, so a lifecycle-only list also silences the role events and the thread. `--render` ignores the filter.

### Threading

`notifications.threading` (default `true`): the first event of a `thread_key` posts a root card, later events reply with headline and body only.

| Platform | Threading |
|----------|-----------|
| Slack bot | `thread_ts` of the root. |
| Discord bot | A Discord thread is started from the root; later events post into it. If the bot cannot create threads, inline replies. |
| Buzz | NIP-10 `e` reply tag on the root event. |
| Webhooks, Teams | Cannot thread; each event is a new message. |

Anchors live in `${PIPELINE_THREAD_STATE:-~/.talos/threads.json}` keyed `<owner>-<repo>:<thread_key>` (`slack_ts`, `discord_msg_id`, `discord_thread_id`, `buzz_event_id`), written under a lock. A refused anchor (Slack `thread_not_found`, a failed Buzz reply) is cleared and the event reposted once as a new root; a Buzz timeout does not repost.

### Templates

One neutral template per event, in a small markdown dialect (`**bold**`, `[text](url)`, `- ` bullets, at most one `### ` heading) with `${NAME}` placeholders, transpiled per sink: Slack mrkdwn in Block Kit, Discord embed, Teams Adaptive Card, Buzz GFM verbatim (a root adds a `repo · PR #n` footer). Empty placeholders are tidied out, so templates need no conditionals.

Lookup per platform, first hit wins: `<project>/<templates_dir>/<platform>/<event>.md`, `<project>/<templates_dir>/<event>.md`, then the same two under the Talos install (`~/.talos`). An absolute `notifications.templates_dir` names one root. Talos ships neutral files only: `validator pm developer qa reviewer security docs orchestrator pr-opened merged blocked issue-closed dispatched info`. An event with no template (`adversarial`, `planner`) renders a monospace grid.
Placeholders (anything else stays literal): `ICON EVENT MSG REF ROLE ROLE_ICON ROLE_LABEL TITLE REF_TITLE PR PR_TITLE PR_REF ISSUE_URL PR_URL REF_LINK PR_LINK BOARD REPO VERDICT SUMMARY HEADLINE`.

- `VERDICT` is a leading token of `MSG` (`PASS FAIL DONE CLEAR CLOSED MERGED BLOCKED CHANGES FINDINGS APPROVED CONFIRMED RESTAMP_PASS RESTAMP_FAIL`) followed by `:`, ` - ` or an em dash.
- `SUMMARY` is `MSG` without it (for `blocked`, also without a leading `<stage>:`); for `pr-opened`, `merged` and `issue-closed` it is the PR title when known.
- `HEADLINE` is built by the script: icon, bold role, verdict or action, `REF` linked to the PR or issue.
- Titles and URLs come from GitHub. Export `PIPELINE_ISSUE_TITLE`, `PIPELINE_PR`, `PIPELINE_PR_TITLE`, `PIPELINE_REPO_URL`, `PIPELINE_REPO` or `PIPELINE_BOARD` to skip the lookups.

### Preview and test

```bash
bash ~/.talos/scripts/pipeline-notify.sh --render slack qa "#42" "PASS: 3 criteria verified"
PIPELINE_NOTIFY_DEBUG=1 bash ~/.talos/scripts/pipeline-notify.sh info "setup" "test" 0
bash ~/.talos/scripts/pipeline-notify.sh info "setup" "Talos is configured and ready" 0
```

`--render <platform>` (`slack`, `discord`, `teams`, `buzz`, `default`; others exit 2) prints the resolved template path, `rich: yes|no` and the root payload, posting nothing and touching no thread state. `PIPELINE_NOTIFY_DEBUG=1` prints each sink's payload and posts nothing. The third command sends a real test message. There is no `talos.sh` notify verb.

### Failure behaviour

A notification failure never blocks the pipeline: delivery problems (credentials, rejected publish, missing `nak`, timeouts, a failing `notifications.cmd`) log one stderr line and exit 0. The only non-zero exits are an unknown `--render` platform (2) and a partial install missing `pipeline-cfg-cache.sh` or `pipeline-bounded.sh` (1; reinstall). If `talos.sh` sees a non-zero exit it records a `notify-failed` warning and continues.

## Hooks, events, spend and the status line

### Hooks

Both keys hold a shell command (`sh -c`), disabled when empty. `hooks.timeout_s` (default 30) bounds each run. A non-zero exit, a timeout or (pre_dispatch) empty stdout is a no-op with one stderr line; a hook never blocks the pipeline. Both get `TALOS_ROLE` and `TALOS_ISSUE_NUMBER` in the environment.

| Key | Runs | Stdin and effect |
| --- | --- | --- |
| `hooks.pre_dispatch` | Before every stage prompt is built | JSON below. Stdout is prepended to the prompt as `## Context`, the text, `---`. |
| `hooks.post_stage` | After every verdict, approval, block and merge is known | Outcome JSON below. Fire-and-forget; output ignored. |

```json
{"role":"developer","issue":42,"pr":57,"repo":"owner/name","base_branch":"main","worktree_path":"/abs/path","files_hint":["a.sh"]}
```

`pr` is null and `files_hint` is `[]` when unknown. Under `talos.sh run` and the adapter path `pipeline-agent.sh` makes the call (`pr` null; `files_hint` from `TALOS_FILES_HINT`). Under an LLM orchestrator `talos.sh env` prints `ref=hooks`: the orchestrator runs `pipeline-hooks.sh pre_dispatch <role> <N> <PR> <worktree>` and passes the output to `talos.sh prompt --preamble-file`.

```json
{"event":"qa","role":"qa","issue":42,"pr":57,"repo":"owner/name","sha":"<40 hex>","verdict":"PASS","summary":"...","details":"...","attempt":null,"model":"claude-sonnet-5","runner":"claude","duration_s":312,"tokens":48213,"tool_uses":19,"ts":"..."}
```

Unknown fields are null. `ci_runs` is added only on `merged` when known. `event` is the role name for a finished stage (`talos.sh done`), or a lifecycle event with role `orchestrator`: `pr-opened`, `merged`, `blocked`, `issue-closed`, `budget-blocked`. The adapter path adds `stage_complete` (PASS or FAIL from the exit code), `stage_attempt` (a failed attempt before failover) and `failover`.

### The events log

Every `post_stage` payload is also appended as one JSON line to `<git common dir>/talos/events.jsonl`, whether or not `hooks.post_stage` is set. `events.enabled` (default true) turns it off; `events.path` is relative to the git common dir. It is shared by all worktrees and never inside a git tree. A relative path that leaves the common dir is refused. Appends are single writes, so parallel stages never interleave lines; a write failure is a stderr note only.

`talos.sh prompt` also appends a `stage_start` line (role `orchestrator`, field `stage`) per dispatched stage. It runs no hook and no cost view counts it.

```bash
bash scripts/pipeline-events.sh path
bash scripts/pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
bash scripts/pipeline-events.sh tail [--issue N]    # list --last 20
```

Output is oldest first, tab-separated (`ts`, `event`, `role`, `issue`, `pr`, `verdict`, `summary`) or JSON lines. Malformed lines are skipped.

### Spend

Talos records tokens, never a price. Sources: on the native path the orchestrator passes the completion notification's usage to `talos.sh done --tokens --tool-uses --duration-s [--model]`; on the adapter path `pipeline-agent.sh` records the claude runner's usage (`agents.capture_usage`, default true; input + output + cache creation, cache reads excluded) and a `custom` runner's sidecar file `$TALOS_USAGE_FILE` (`{"tokens":N,"tool_uses":N,"model":"..."}`, every key optional). Other runners report nothing. A missing figure is `unrecorded`, shown as such and never as 0; totals read `(+K unrecorded)`.

```bash
bash scripts/pipeline-events.sh cost [--issue N] [--pr M] [--json]   # per issue and role
bash scripts/pipeline-events.sh cost --issue N [--pr M] --line       # one line
bash scripts/pipeline-events.sh cost --issue N [--pr M] --markdown   # PR comment body
bash scripts/pipeline-events.sh cost --summary --issue A [--issue B] # end-of-run block
```

The table has `unrecorded` and `restamp` (delta re-review) columns per issue and role. `--line`, `--markdown` and `--summary` are exclusive (exit 2) and leave out `orchestrator` rows.

Where it shows: the `spend=` line after each stage; one comment per PR, edited in place (marker `<!-- talos:spend -->`), written when `comments.enabled` is true and `spend.comment` is not false, GitHub only, public on a public repo; and the `cost=` lines of `talos.sh summary` at run end. A failed comment write is one `spend-upsert-failed` warning, never retried.

### Budget guard

Off unless `limits.tokens_per_issue` is a positive integer. `limits.warn_at` (default 0.8) sets the warn state. `gate fix-round` checks before each developer fix round (never a first pass, re-stamp or merge); only recorded tokens count.

```bash
bash scripts/pipeline-budget.sh check --issue N [--json]
# talos:budget ok|warn|exceeded issue=N used=.. limit=.. effective=.. pct=.. unrecorded=..
```

Exit 1 means exceeded (0 for ok, warn, unknown and guard off), so a `set -e` caller must capture the code. Exceeded sets `pipeline:blocked` on issue and PR and records `budget-blocked`. Each such event grants one more full limit: effective limit = limit x (1 + grants). Remove the label to continue, or raise the key.

### The status line

`scripts/talos-status.sh --line` prints one line from the events log, offline and free of model tokens, always exit 0, nothing when no issue is active:

```
talos #7 qa ●●●●◐○ 3.41M
```

Fields: issue, running (else first pending) stage, one dot each for validator, pm, developer, review (reviewer, security, adversarial), qa, merge (`●` done, `◐` running, `○` pending), the issue's token total. A role turned off in `roles.*` has no dot, nor has a validator or pm that never ran once a later stage has. The issue is the current branch's (`fix|feat/issue-N-...`), else the newest event's; a merged issue prints nothing. A stage runs from its `stage_start` event until its finishing event (6 hours at most). While it runs, the total adds usage read from the harness transcript (`transcript_path` on stdin, plus subagent transcripts). Config read: `roles.*` and `events.path` from `talos.pipeline.json` over `${TALOS_HOME:-~/.talos}/talos.pipeline.json`. The run is cut off after `TALOS_STATUS_TIMEOUT_S` seconds (1 to 10, default 3). `TALOS_STATUS_DEBUG=1` says on stderr why nothing printed.

`install.sh --global` with the Claude adapter sets `statusLine` in `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json`) to `bash <TALOS_HOME>/scripts/talos-status.sh --line` (shell-quoted when the path needs it). `/talos:setup` runs the same `scripts/talos-statusline.sh wire`. By hand:

```json
{"statusLine": {"type": "command", "command": "bash ~/.talos/scripts/talos-status.sh --line"}}
```

**An existing status line is chained, not replaced.** Claude Code has one `statusLine` slot (a plugin cannot set it), so with a foreign `statusLine` command the installer:

- saves the original `statusLine` object verbatim to `${TALOS_HOME:-~/.talos}/statusline-previous.json`;
- writes `${TALOS_HOME:-~/.talos}/statusline-chain.sh` (mode 0700, like the backup: it embeds your original command) and sets `statusLine.command` to `bash <that file>`; `type`, `padding` and every other field stay.

The wrapper reads Claude's JSON from stdin once and runs your original command (`sh -c`) and `talos-status.sh --line` side by side with that same JSON. Claude Code shows every output line as a row ([status line docs](https://code.claude.com/docs/en/statusline), "Display multiple lines"), so it prints your original rows and the Talos line as the last row. Each part has its own timeout, `TALOS_STATUSLINE_TIMEOUT_S` seconds (1 to 10, default 2), and its own failure: a part that fails, hangs or prints nothing is left out and the other still shows; the wrapper always exits 0.

| Starting `statusLine` | `install.sh --global` does |
|---|---|
| none | wires `talos-status.sh --line` directly |
| Talos's own command | unchanged, or pointed at the installed copy |
| your command | chains it (above) |
| the chain wrapper | rewrites the wrapper from the backup in place; `settings.json` and the backup are not touched, nothing is wrapped twice |
| no `command` (not a command status line), or a `settings.json` that does not parse | left unchanged, with a notice |

`--no-statusline` skips the whole step for every harness (one line says so; nothing is written). `--statusline-undo` (implies `--global`, does nothing else) puts `statusLine` back to exactly the saved value, deletes the wrapper and the backup, and says `nothing to undo` when there is nothing Talos-owned. A command counts as the Talos wrapper only when it is `bash <absolute path>` to `statusline-chain.sh` under `TALOS_HOME` or to a file carrying the Talos header; a script of your own that is merely named `statusline-chain.sh` is a foreign status line (chained, never deleted or overwritten). Both only touch the user-level `settings.json`, never a project's `.claude/settings.json`.

Per-harness support. `install.sh --global --harness <list>` prints one `not supported by <harness>` line, with the manual command, for each selected harness that has no command status hook:

| Harness | Talos line | How |
|---|---|---|
| claude | yes | `statusLine` in `settings.json`, chained when one exists |
| codex, gemini, antigravity, cursor, opencode, generic | not supported | no command status hook the installer owns; run `bash <TALOS_HOME>/scripts/talos-status.sh --line` from your own prompt or footer, with the repo as working directory |
| pi | not supported | needs a TS extension; same manual command |

### Resume

There is no status file. A cleared session, a token limit or a switch to another LLM resumes the same way: start the pipeline again (`/talos:pipeline`, `Read ~/.talos/skills/pipeline/SKILL.md and follow it`, or `bash scripts/talos.sh run`). State lives on the remote (labels, PRs, comments, attempt markers; approvals are bound to the PR head SHA) and in the local events log, so the run continues at the first missing stage. To change the LLM, set `TALOS_PROFILE` or `agents.profile` ([Profiles, runners and fallback](#profiles-runners-and-fallback)).

- `talos.sh state --summary` (read-only, run by Step 0) prints three lines: `where=in flight: ...`, `where=waiting: ...`, `where=next: ...`. With multi-user claiming on and other operators' work present it adds a fourth, `where=theirs: #N (@login)`; that work is never routed.
- A developer re-dispatched on an issue with a checkpoint is told so and continues. `pipeline-worktree.sh checkpoint <N>` WIP-commits and pushes the issue branch and writes `<git common dir>/talos/handoff/<N>.json` (mode 0600, this machine only, outside every git tree); `handoff <N>` prints it. Provider failover writes it automatically. Exit 1 from `handoff` means absent, invalid or stale.
- A run holds a per-issue lease. After a crash `next` answers `wait reason=lease retry_after_s=<s>` until the dead holder's lease is reclaimed (10 s by default); `talos.sh lease prune` removes dead ledger lines.

## Troubleshooting

Start with `bash scripts/pipeline-config.sh --show` (each key, its value and layer) and `bash scripts/talos.sh env` (what a run will do). `pipeline-vcs.sh --dry-run <verb> ...` previews a VCS action.

### Config does not load

- `reason=config-shadowed winner=<json> also-present=<files>` or `reason=config-legacy-file <path>`: config is JSON only. A stray `talos.pipeline.yml`/`.yaml` beside the json stops every config read; merge it into the json by hand, then delete it.
- `stop reason=config-unreadable`: `pipeline-config.sh --dump` failed; the line above names the cause. A profile error shows as `reason=profile-unknown` or `reason=profile-unusable` (see [Profiles, runners and fallback](#profiles-runners-and-fallback)).
- `pipeline-config: [warn] unknown config key 'merge.atuo' (did you mean 'merge.auto'?)`: otherwise the typo is ignored and the default applies. `TALOS_CONFIG_STRICT_KEYS=0` silences the check.

### A run stops

`talos.sh run` ends with a `stop reason=...` line, or a `dispatch-failed role=<r> reason=<why>` line on stderr.

| Line | Meaning and fix |
|---|---|
| `verdict-unreadable` | The final message had no line starting with the role's verdict word and a colon (`PASS:`, `APPROVED:`, `CLEAR:`, ...). Nothing is recorded; common with a weak local model on `custom`. Re-run. |
| `agent-failed rc=<n>` | The runner exited non-zero; `124` is `agents.stage_timeout_s`. |
| `provider-failed rc=75\|69` | Provider error or failover exhausted; nothing is recorded. See [Profiles, runners and fallback](#profiles-runners-and-fallback). |
| `action=wait reason=lease` | Another run holds the issue's lease (or the ledger is unavailable). Re-run later; see [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims). |
| `qa-fail-unchanged-head` | The QA fix round pushed nothing; PR and issue are `pipeline:blocked`. |
| `iterations-exhausted` | The `--max-iterations` cap (default 20) was reached; run again. |
| `trust-unverified` | The login lookup was refused (an Actions or GitHub App token) and `markers.trusted_authors` is empty, so marker authors cannot be checked. Set `markers.trusted_authors`. |

A `pipeline:blocked` issue or PR is skipped until a human removes the label. After a token-budget block, removing it grants one more limit (or raise `limits.tokens_per_issue`).

### Approvals and merge

- An approval is stale after a new commit that touches a non-waived file; only the affected stages re-run. `bash scripts/pipeline-vcs.sh check-approval-sha <PR> --stale-list` names them.
- `assert-sync` aborts on a dirty tree (an untracked `AGENTS.md` counts), a checkout behind or diverged from `origin/<base>`, or a failed `git fetch`. Commit, stash or `git pull --ff-only`.

### Provider and board

- `github: no authenticated gh CLI and GITHUB_TOKEN or GH_TOKEN required`: run `gh auth login` or export a token (`vcs.token_env` names another variable).
- `github: cannot determine the repository (set vcs.repo)`: the token transport cannot read the git remote; set `vcs.repo` to `owner/repo`.
- Board updates fail: warnings by design, not a stop. `bash scripts/bootstrap-board.sh` adds a missing Status option (idempotent). With `gh`, Projects v2 needs the `project` scope (`gh auth refresh -s project`); check `board.project_number` and `board.owner`.
- `talos:board-unverified` on stdout: a missing Status option, an API error or the item-page cap (`TALOS_BOARD_MAX_PAGES`, default 50) skipped the update. The run continues.

### Notifications

- Plain monospace messages instead of rich cards: no template resolved, so `templates/` is missing from the install; re-run `install.sh`.
- Webhooks cannot thread; threading needs a Slack/Discord bot token or Buzz. A thread that goes silent after the first message usually means `notifications.events` omits the role events.
- Preview: `PIPELINE_NOTIFY_DEBUG=1 bash scripts/pipeline-notify.sh validator "#1" "test" 1` posts nothing; `bash scripts/pipeline-notify.sh --render buzz qa "#42" "PASS"` needs no credentials.
