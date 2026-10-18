# Talos reference

How to install, configure and operate Talos. The [README](../README.md) is the short overview. Every config key is in the generated [Config key reference](#config-key-reference); the sections below say what the keys do.

Paths such as `scripts/talos.sh` are relative to the Talos install (`~/.talos` after `install.sh --global`) or to a checkout of this repository.

**Contents:** [How a run works](#how-a-run-works) | [Install and setup](#install-and-setup) | [Configuration](#configuration) | [Config key reference](#config-key-reference) | [Profiles, runners and fallback](#profiles-runners-and-fallback) | [Providers and the board](#providers-and-the-board) | [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims) | [Gates: verify, QA, CI and merge](#gates-verify-qa-ci-and-merge) | [Notifications](#notifications) | [Hooks, events, spend and the status line](#hooks-events-spend-and-the-status-line) | [Troubleshooting](#troubleshooting)

## How a run works

### Entry points

| Entry | What drives |
| --- | --- |
| `/talos:pipeline` (Claude Code) | Code-driven by default: the session follows [SKILL.md](../skills/pipeline/SKILL.md), starts `talos.sh run` once and acts only on the driver's end line. No stage relay reaches the session's context. |
| `Read ~/.talos/skills/pipeline/SKILL.md and follow it` (any other agent) | The same playbook. |
| `bash scripts/talos.sh run [--issue N] [--max-iterations n]` | The driver itself, with no session around it: code drives, an LLM still does every stage. Without `--issue` it drains the queue; `run --stop` ends it at the top of the next pass. |

**`execution.orchestrator`** (`code`, the default, or `llm`) picks who drives. `llm` is the opt-in for the LLM-per-stage loop: the session calls `next`, `prompt`, `done` and the gates itself, one stage at a time, from `skills/pipeline/refs/llm-loop.md`. `talos.sh env` prints the effective mode as `ORCHESTRATOR=code|llm`; it is `llm` whatever the key says under `vcs.provider: file` and `roles.planner: true`, which the driver cannot run (one stderr line says why), and an unknown value reads as `code`.

**`execution.context_budget_tokens`** (default `150000`, `0` turns it off) is the LLM loop's context budget. When `next` runs under `ORCHESTRATOR=llm` (not inside `talos.sh run`), it reads the session's size from the transcript `TALOS_TRANSCRIPT_PATH` names: the latest call's input, cache read and cache write. At or over the budget, a `next` that would start a queued issue prints `stop reason=context-budget size=<n> budget=<b>` and `resume=/talos:pipeline` instead (exit 0, nothing leased); in-flight work is still answered, so the current issue finishes and no stage stops midway. Start a fresh session with the resume line; the state is on the remote. Without a usable transcript path, `next` prints `warn reason=context-unknown` and goes on.

`scripts/` is the install's scripts directory (`~/.talos/scripts` after `install.sh --global`). Under `ORCHESTRATOR=llm`, read a playbook ref in `skills/pipeline/refs/` only when `talos.sh env` or `next` prints `ref=<topic>`; under `code`, `env` prints none.

`talos.sh run` loops `next` (one routed action), `prompt` (renders the stage prompt), `pipeline-agent.sh` (the configured runner, with `agents.fallback` failover) and `done` (bookkeeping), at most `--max-iterations` passes (default 20; a long drain passes a larger number). It reads each verdict from the first line of the agent's final message that starts with `WORD:` (the word on the role's verdict list; the developer's message is read for its PR URL). An unreadable answer is a dispatch failure and records nothing. On `action=merge` it runs `gate merge`, then `merge-pr` and `post-merge`. Exit 0 on every clean stop (`ask-owner`, a stage block, a `wait`, a non-merge gate verdict, a requested stop, the iteration cap); exit 1 when state cannot be read, a stage dispatch fails (an unreadable answer included), the merge fails or failover is exhausted (`provider-failed`); exit 2 on a usage error. A second QA FAIL at an unchanged PR head blocks and stops. A reviewer, security or adversarial finding gets its developer fix round in the same run, through `gate fix-round`: under `pr.draft` the other enabled review roles with no fresh approval review that head first, then one round covers every finding; a round that pushes nothing blocks and stops (`fix-round-unchanged-head`). Re-run to continue.

**One run drains the queue.** Started once without `--issue`, `talos.sh run` goes on after every merge until something needs a person (`ask-owner`, a block, a `stop reason=`) or nothing is left:

- After `merge-pr`, `post-merge` puts the checkout back on the base branch (`pipeline-worktree.sh to-base <N>`: switch, `git pull --ff-only`, delete the merged issue branch) before it removes the issue's worktrees, and prints `checkout=returned|synced|kept|failed`. It never forces: a tracked change on the issue branch, a refused switch or a pull that is not a fast-forward is `checkout=failed`, and the run ends with `stop merged pr=<M> reason=checkout-return-failed`.
- Then the run prints `merged=pr=<M>`, flushes its output, runs its exit hooks (leases, scratch directory) and execs `talos.sh run` again for the next pass: same PID, nothing left running, and when Talos works on its own repo the merged scripts are the ones loaded.
- `--max-iterations` caps the passes of the whole command, the ones after a merge included (the count crosses the exec in `TALOS_RUN_PASSES=<pid>:<passes>`, which only the process it names honours). The default is 20; pass a larger number for a long drain.
- Issues are worked in one order across validation and development: priority (`p0`, `p1`, `p2`, unlabelled), then issues already in flight (`pipeline:confirmed`, `pipeline:dev`) before ready ones, then the issue number. A p0 is taken to its end before a p2 is validated. Open pipeline PRs still come first, lowest number first.
- `talos.sh run --stop` asks a running run to stop. It writes `<git common dir>/talos/run.stop` and prints `stop=requested`; the run reads the request only at the top of a pass, so the stage it is on is not the boundary: one pass can hold several stages (a QA FAIL and its fix round, or the rest of a draft batch and its fix round). It deletes the request and ends with `stop reason=stop-requested` (exit 0). A request nobody picked up is deleted by the next run that starts.

`run --issue <N>` works one issue and ends after its merge with `stop merged pr=<M>`.

Verbs: `env`, `state [--summary]`, `next [--issue N]`, `prompt`, `done`, `gate fix-round|merge`, `docs-gate`, `post-merge`, `sweep`, `summary`, `claim`, `lease prune`, `map`, `run`.

### Stages

Approval order (`APPROVALS` in `pipeline-next.py`): validator, planner (optional), pm, developer, qa, docs, reviewer, security, adversarial (optional), merge. `talos.sh run` runs one stage at a time in that order; reviewer and security run in parallel only on the LLM loop. With `pr.draft` on, the default, QA moves after the review stages (below). A disabled role is skipped and its approval label is not required at merge.

| Stage | Kind | Toggle | Does and reads |
| --- | --- | --- | --- |
| validator | LLM | `roles.validator` | Reads the issue. Verdict CONFIRMED, ALREADY_FIXED, DUPLICATE, NEEDS_MORE_INFO or SECURITY_THREAT; anything but CONFIRMED sets `pipeline:blocked`. |
| planner | LLM, off | `roles.planner` | Epics only (`epic` label, 4 or more `- [ ]` items, or body of 2000+ characters): at most 10 sub-issues, dependencies via `Depends on:`. The epic gets `pipeline:epic-decomposed`. |
| pm | LLM | `roles.pm` | Posts the spec with numbered acceptance criteria. Skipped by code when `roles.pm_skip_when_spec_present` and the issue body already has an acceptance-criteria heading with a checklist, or carries `spec:ready`. |
| developer | LLM, always | none | Reads the spec. Branch `fix/issue-N-slug` (`feat/` for a `feat` title). Red tests first, runs `verify` once before the final commit, opens the PR. The only stage that writes code. |
| qa | LLM | `roles.qa` | Checks each acceptance criterion; runs targeted tests only, never the full suite; under `verify.qa_mode: ci` waits for required CI. With `pr.ready_gate: qa-local` it runs last on the draft, before CI, and also runs the full `verify:` list once. |
| docs | code gate, LLM only if needed | `roles.docs`, `roles.docs_mode`, `docs.paths` | `docs-gate` stamps `docs:done` itself unless the PR changes a path matching `docs.paths` (shell globs, `*` and `**` match across `/`; default `README.md`, `docs/*`, `scripts/pipeline-defaults.sh`; `roles.docs_mode: always` forces the agent). The code driver puts the diff sections of those files and of `CHANGELOG.md` in the agent's prompt (the whole diff when `docs-gate` names no paths, as under `roles.docs_mode: always`), within the same `TALOS_PROMPT_CHANGE_MAX_BYTES` limit as the reviewer's; over it or on a failed read the prompt is the one without the hunks and the agent reads the change itself. After a fix round that leaves `docs:done` on the PR and stale, `docs-gate` looks only at the docs-relevant paths changed since the approved SHA: when there are none it stamps again, otherwise the agent gets a read-only re-stamp of that delta ([Stale approvals and the delta re-stamp](#stale-approvals-and-the-delta-re-stamp)). |
| reviewer, security | LLM | `roles.reviewer`, `roles.security` | The code driver (`talos.sh run`) hands them the spec and the whole PR diff in the prompt (`talos.sh prompt --embed-change`, up to `TALOS_PROMPT_CHANGE_MAX_BYTES` bytes of data, default 60000; a larger change or a failed read is one line that tells them to read it once), so they fetch neither; the data sits between `----- BEGIN SPEC|DIFF <token> -----` and `----- END ... -----` lines whose token is new for every render. Without it they read `diff-pr --stat`, then the full diff once. On a re-review (the stage's own `talos:reviewed` findings comment or `talos:approval role=<stage>` marker is already on the PR, newest by list order, trusted authors only) the prompt carries instead the diff from that sha to the PR head, limited to the files the PR changes (so a merge of the base branch shows nothing), plus the stage's previous comment, and no spec; with no usable sha (none, an unreadable thread, a rebased or missing commit) it falls back to the whole change after one `Re-review: full diff (<reason>)` line. Every finding is tagged `Important`, `Nit` or `Pre-existing` (the defect is on lines the PR did not change); only `Important` ones block and count, the others go under `**Non-blocking notes:**`, and each `Pre-existing` one (a `PRE-EXISTING: <path>:<line> — <text>` line in the stage's final message) is filed by `talos.sh done` as one follow-up issue of plain bullets per review. Run no tests. A security finding blocks only on an attacker path that does not start from something the user already controls, or on loss or corruption of user data in normal use; the rest go under `**Non-blocking notes:**` in the same comment and are filed as one follow-up issue, never a fix round. |
| adversarial | LLM, off | `roles.adversarial` | Second opinion on another backend. Blocks on the same two grounds as security. |
| merge | code | `merge.auto` | `gate merge` checks every gate; `merge-pr`; `post-merge` closes the issue, sets the board to Done, returns the checkout to the base branch, removes the worktree, notifies. |

Everything except the stage agents is mechanical: routing (`next`), bookkeeping (`done`), gates, sweeps, merge.

With `pr.draft` true (the default; it resolves to false when CI lacks a `ready_for_review` trigger, and for the `github-api` and `file` providers) the order changes: developer opens a draft PR, docs, reviewer and security (and adversarial) review the draft in one batch, one developer fix round covers all findings, `ready-pr` starts the one CI run, then QA, then merge. With `pr.ready_gate: qa-local`, QA runs on the draft before `ready-pr` instead. See [Gates: verify, QA, CI and merge](#gates-verify-qa-ci-and-merge).

### What a run costs

Each stage is a fresh agent. Spend is measured per run ([Hooks, events, spend and the status line](#hooks-events-spend-and-the-status-line)). The levers:

- `roles.*`: drop whole stages. `roles.pm_skip_when_spec_present` and `roles.docs_mode: auto` drop the PM and docs agents when code can decide.
- `verify.qa_mode: ci` (default once `merge.required_checks` is set): QA trusts CI instead of re-running tests. `verify.targeted`: the developer iterates on targeted tests and runs the full `verify` once.
- `pr.draft`: one CI run per PR. `pr.ready_gate: qa-local` also keeps that run off a head QA would reject.
- Re-stamp: after a fix push that leaves approvals stale, a role already approved re-reviews only the delta (`agents.restamp_model`, `agents.restamp_effort`).
- `agents.roles.<role>.model`, `.effort` and `.runner`: route cheap stages to cheap models (the claude runner passes the model as `--model`; the other built-in runners do not) ([Profiles, runners and fallback](#profiles-runners-and-fallback)).
- `limits.tokens_per_issue`: optional hard budget before each fix round.
- Prompt cache: on Claude Code, developer and QA ask for the 1-hour cache, so a wait on the test suite of up to an hour does not rebuild their context. There is no config key; start Talos with `CLAUDE_CODE_PROMPT_CACHE_TTL=5m` to stay on five minutes ([Prompt cache lifetime](#prompt-cache-lifetime)).
- `agents.claude_api_credits`: on a Max or Team plan, claude stages spend the plan's monthly API credits first and the plan's usage limits second, so the stages stop competing with your interactive sessions for the same limit ([Monthly API credits](#monthly-api-credits)).

### Which issues enter the queue

- An issue needs `pipeline:ready`. With `issues.label_filter` set to anything else it also needs that label (AND; a wrong filter gives a silently empty queue).
- Issues carrying a label in `issues.skip_labels` (default `pipeline:blocked`, `wontfix`) are not picked up. Any open issue or PR with `pipeline:blocked`, or any open owner question, also makes `next` answer `action=wait reason=owner`, so no new ready issue starts until it is cleared; only in-flight work moves.
- Order: `p0`, `p1`, `p2`, unlabelled; at the same priority an issue already in flight (`pipeline:confirmed`, `pipeline:dev`) goes before a ready one; then issue number. The ready-queue rules here (the filter, the skip labels, the cap) do not hold back an issue that is already in flight; one another run holds the lease of is skipped for the next issue.
- `issues.max_parallel` caps issues in flight (`next` answers `wait reason=cap`). Above 1 needs `execution.isolation: worktree`; the adapter path runs stages one at a time.
- `issues.assignee` (`self`, a login, or `none`) assigns the issue at creation and when it moves to In progress, and the PR or MR when Talos opens it or resumes it for a fix round (`assign-pr`; Azure DevOps pull requests have no assignee, so it only says so); it never replaces an existing assignee. With `issues.claim` true and an assignee other than `none`, the assignee is the lock between operators: `next` claims an issue before dispatching it and leaves other operators' issues alone (`identity.name` is the login `self` means). See [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims).

### Retries and attempt counting

Every developer fix round goes through `talos.sh gate fix-round <N> <blocking-stage> [--pr M]`. It runs the budget guard, then the same-area check (a reviewer, security or adversarial round on a PR), then `record-attempt` (a `talos:attempt` marker comment, deduplicated per PR head with `--pr`), then clears `pipeline:blocked` if the round may run. It answers `verdict=redispatch`, `verdict=block` or `verdict=ask-owner`. Never count attempts by hand.

| Key | Default | Meaning |
| --- | --- | --- |
| `limits.max_fix_attempts` | 3 | Consecutive attempts at one blocking stage. |
| `limits.max_total_dispatches` | 8 | Developer dispatches per issue; never resets. |
| `limits.max_retries` | 5 | Retries of a rate-limited network call (backoff up to 60 s). |
| `limits.same_area_rounds` | 2 | Rounds running in which one review role's findings cite the same file before the owner is asked (1 to 100). |

The attempt that reaches a ceiling blocks (`verdict=block reason=max-fix-attempts|max-total-dispatches`) instead of re-dispatching. A required CI check that fails is re-run twice per head SHA before `gate merge` answers `ci-failed`.

**The same-area check.** For a reviewer, security or adversarial round on a PR, the gate reads the PR's comments once before it records the attempt. When the newest `limits.same_area_rounds` findings comments of that stage each cite one file as `path:line`, it answers `verdict=ask-owner reason=design-decision` with `stage=`, `rounds=` and `area=` (the shared files), records no attempt, clears no label and parks the question on the PR: a `Design decision needed` comment and `pipeline:needs-owner`, so `list-needs-owner` and the state summary show it as an open owner question. A findings comment ends with `<!-- talos:reviewed sha=<head> -->` (the PR head it reviewed); adjacent findings comments of one head are one round, so a re-review of an unchanged head never asks. A comment with no marker has an unknown head and counts as its own round.

- Only the stage's own findings comments count, from trusted authors (`markers.verify_authors`, `markers.trusted_authors`). Its approval does not count, and neither does a citation under `**Non-blocking notes:**` or in the reviewer's human-attention report.
- To release the round, reply on the PR with the decision, then run `gate fix-round` again (the orchestrator does this when it gets the answer). A reply is a comment by a trusted author that is not empty, holds no Talos marker and does not start with `**Agent:**`; quoting a finding is fine. `pipeline:blocked` stays until then, so `next` keeps answering `wait reason=blocked`, and until the reply exists the gate repeats `ask-owner` (without `rounds=` and `area=`) and writes nothing.
- After the reply the count starts again from the comments below the question, and the unblock also removes `pipeline:needs-owner`.
- The check never stops a round it cannot make: with `comments.enabled: false`, an empty `comments.header`, or a PR thread that cannot be read (`warn reason=area-check-failed`) the round runs as before. A value above `limits.max_fix_attempts` never triggers.

### Blocked work and human-only gates

A stage that cannot proceed sets `pipeline:blocked` and comments `Blocked by: <file>:<quoted line> (explicit|interpreted)`: `explicit` is a hard rule to fix, `interpreted` is the agent's judgment a human may overrule. Talos clears `pipeline:blocked` only right before a fix round; otherwise a human clears it on both the PR and the issue. After a `limits.tokens_per_issue` block, removing the label grants one more limit.

Only a person does these:

- Queue an issue (`pipeline:ready`). Talos never re-queues a blocked issue. To stop work, remove `pipeline:ready` before pickup, or close the issue. `pipeline:blocked` added after pickup stops that issue but also holds every new ready issue (`action=wait reason=owner`) until you clear it.
- Clear a block, including `forbidden-files`, `closing-keyword` and `siblings-capped`, and a `ci-failed` that needs a new commit.
- Merge, when `merge.auto: false`: the PR gets `pipeline:approved` and a hand-off comment; the next `sweep` closes the issue.
- Add `skip-qa`, which waives the approval labels only, never CI or the forbidden-files check.
- Answer a `pipeline:needs-owner` question (`next` answers `ask-owner`).
- Decide the design when `gate fix-round` answers `ask-owner reason=design-decision`: reply on the PR under the `Design decision needed` comment; the next `gate fix-round` continues from the reply. See [Retries and attempt counting](#retries-and-attempt-counting).

There is no switch that removes the CI gate: `gate merge` stops with `reason=ci-unverified` when `merge.required_checks` is empty (on `azure` the PR's blocking policy evaluations stand in, on `gitlab` the MR's head pipeline; see `pr-checks-required`).

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
bash talos/install.sh --global [--harness <list>] [--no-overwrite] [--keep-marketplace | --local-plugin]
bash talos/install.sh [repo-path] [--harness <list>] [--no-agents-md] [--import-agents-md] [--no-agent-skills] [--force]
```

| Flag | Effect |
|------|--------|
| `--global` | install to `${TALOS_HOME:-~/.talos}` |
| `--harness <list>`, `--harness=<list>` | installer glue, comma-separated: `claude codex gemini antigravity pi cursor opencode generic`. Another `[a-z0-9-]+` name becomes `generic`; an empty item, bad characters or a missing value exit 1. It does not set `agents.runner` |
| `--local-plugin` | `--global` only: register the checkout itself as the `talos` marketplace, replacing a GitHub-registered one ([Developing Talos](#developing-talos)). Without `--global` it is ignored, with one notice line |
| `--no-overwrite`, `--force` | skip existing files (global default is overwrite) / overwrite them (per-repo; never `talos.pipeline.json`) |
| `--no-agent-skills` | per-repo: skip copying agent-skills into `<repo>/.claude/skills` |
| `--no-agents-md`, `--import-agents-md` | per-repo: write no `AGENTS.md` block / append `@AGENTS.md` to an existing `CLAUDE.md` and `GEMINI.md` (never creates them) |
| `--no-statusline`, `--statusline-undo` | global: skip the status-line step for every harness / restore the original Claude `statusLine` exactly and remove the chain wrapper (implies `--global`; [The status line](#the-status-line)) |
| `--no-legacy-aliases` | accepted and ignored: no alias is installed since #553, so an old command line still runs |

**Claude adapter.** Writes `~/.claude/agents/<role>.md`, registers the `talos` plugin (`claude plugin marketplace add <checkout>`, `claude plugin install talos@talos`) and wires `statusLine` in `settings.json` to `talos-status.sh --line` (an existing statusLine is chained, not replaced: [The status line](#the-status-line)). With `--harness` it runs only if the list has `claude`; without it, when `CLAUDE_CONFIG_DIR` is set, `${CLAUDE_CONFIG_DIR:-~/.claude}` is a directory, or `claude` is on PATH. A skipped adapter leaves `~/.claude` alone. Without `claude plugin` it prints the two commands to run inside Claude Code. Re-run it after `git pull` to refresh `~/.talos` and the agents (each `--global` run writes `~/.talos/.install-manifest` and removes files under `scripts/`, `templates/` and `skills/<command>/refs/` that an earlier run installed and this one no longer ships; a file of your own is never deleted, #579); the plugin itself Claude Code reads from the checkout (a directory marketplace), at each session start or `/reload-plugins`. A `talos` marketplace from another source is left alone; one pointing at another directory is repointed unless `--keep-marketplace` (or `--no-overwrite`) is given. A marketplace left alone stays the source of `/talos:*`: the success line names it and says edits in the checkout do not reach the plugin.

**Pointer skills.** With `codex`, `pi`, `cursor` or `opencode` in `--harness`, `--global` writes thin pointers `~/.agents/skills/talos-<command>/SKILL.md` (`$TALOS_AGENTS_HOME` moves the root) to the `~/.talos` playbooks; a non-Talos file there is never overwritten.

| Path | Content |
|------|---------|
| `~/.talos/{scripts,agents,templates,skills}` | scripts, nine role profiles (plus `~/.claude/agents/` with the adapter), templates, playbooks `skills/{pipeline,setup}/SKILL.md` with `refs/*.md` |
| `~/.talos/talos.pipeline.json`, `.env` | optional user-level config and secrets, never written by the installer ([Configuration](#configuration)) |
| `<repo>/talos.pipeline.json` | repo config; the installer never writes it (copy `talos.pipeline.json.example` or run the wizard) |
| `<repo>/AGENTS.md` | marker-fenced Talos block, the same for all harnesses. Commit it: untracked, it makes `assert-sync` abort on a dirty tree |

Overrides win over the install: `<repo>/.claude/agents/<role>.md`, then `<repo>/.agents/talos/agents/<role>.md` (adapter and pi paths only). Scripts resolve from `$TALOS_HOME`, `~/.talos`, `$CLAUDE_PLUGIN_ROOT`, `.claude/talos` (old vendored installs), then the source repo (each `/scripts`). Treat `TALOS_HOME` like `PATH`.

### Developing Talos

Public users update the plugin on tagged releases; the version in `plugin.json` stays until a release. If you work on Talos itself and want your machine to run the checkout, install with `bash install.sh --global --local-plugin`. It re-registers the `talos` marketplace from the checkout directory (removing a GitHub-registered one first) and installs `talos@talos`. Claude Code reads a directory marketplace on each session start, so `/talos:*` follows the checkout without a re-run. That makes the checked-out branch live plugin content, skills and hooks, in every Claude Code session on the machine, whichever branch is checked out: switch to a work-in-progress branch and every session runs it. It overrides `--keep-marketplace` and `--no-overwrite` for the marketplace step, and a second run with the checkout already registered only re-installs the plugin. If the removal fails, nothing is changed. If the removal succeeds and the add then fails, the plugin is not registered: the notice says the earlier registration is gone and prints the commands that put it back (`claude plugin marketplace add benmarte/talos`, then `claude plugin install talos@talos`).

Talos runs on bash 3.2 (macOS) and BSD tools, so `tests/test-bash3-lint.sh` runs `scripts/bash3-lint.sh` over `scripts/` and `tests/` and refuses GNU-only or bash 4+ constructs (`sed -i`, `grep -P`, `readlink -f`, `date -d`, `tac`, `declare -A`, `${var,,}`, `mapfile`, `&>>`). It prints `file:line: construct` per hit. A line that needs one anyway ends with `# bash3-ok: <reason>`; comment-only lines are skipped.

To go back to the GitHub release source:

```bash
claude plugin marketplace remove talos
claude plugin marketplace add benmarte/talos
claude plugin install talos@talos
```

### Upgrading from v0.18

For people already on v0.18. Re-run `bash install.sh --global` first (it refreshes `~/.talos`, the role profiles and the plugin registration), then read these.

- **Config is JSON only (#526, #553).** A `talos.pipeline.yml` or `.yaml` beside the json stops every config read with `reason=config-shadowed`. A YAML file with no json beside it stops with `reason=config-legacy-file`. A `PIPELINE_CONFIG` that points at a missing file stops with `reason=config-pointer-missing` (#541). The `.claude-pipeline.*` and `pipeline.*` names are no longer read, and `pipeline-config.sh --convert` is gone. Convert YAML to `talos.pipeline.json` by hand and delete the YAML. Check the result with `bash ~/.talos/scripts/pipeline-config.sh --show`.
- **Removed keys, files and flags (#553, #555, #550).** Gone: the `evidence.*` keys and evidence capture, `merge.delete_branch`, `release_branch`, `roles.changelog_fragments` with `docs/CHANGELOG.d` and `scripts/pipeline-changelog.sh`, the `status.*` keys and `TALOS_STATUS.md`, and `talos.sh done --action-id` (it now ends `stop reason=usage`). A removed key in your config only prints an unknown-key warning. Delete it. The developer now writes its `CHANGELOG.md` line directly, and `merge.union_paths` resolves concurrent edits. The old user guide is merged into `docs/reference.md`.
- **Only `/talos:pipeline` and `/talos:setup` exist (#335, #553).** The `/pipeline` and `/pipeline-setup` aliases are removed. `install.sh --global` deletes the old copies under `~/.claude/skills`, but only when Talos wrote them. `--no-legacy-aliases` is still accepted and does nothing.
- **`install.sh --global` now does more (#335, #550, #579, #587).** It registers this checkout as the `talos` Claude Code plugin (`claude plugin marketplace add`, `claude plugin install talos@talos`). An existing `talos` marketplace from another source is left alone, and `--keep-marketplace` keeps one that points at another directory. It wires the Claude Code `statusLine` to `talos-status.sh --line`, chaining an existing status line instead of replacing it (`--no-statusline` skips this, `--statusline-undo` restores the original). It writes `~/.talos/.install-manifest` and, on the next run, removes files under `scripts/`, `templates/` and `skills/<command>/refs/` that it installed before and no longer ships. The first run after upgrading removes nothing, and a file of your own is never deleted.
- **Role profiles carry no `model:` line (#336).** Roles without a configured model run on the session model. If you relied on the model pinned in the frontmatter, set `agents.model` or `agents.roles.<role>.model` in `talos.pipeline.json` or the user-level `~/.talos/talos.pipeline.json`. Run `bash ~/.talos/scripts/pipeline-agent.sh --resolve-all` to see what each role gets. `--resolve-all` warns when a role file of your own under `.claude/agents/` or `~/.claude/agents/` still has a `model:` line.
- **`/talos:pipeline` runs the code driver by default (#602, #613).** The playbook starts `talos.sh run` once and acts only on its end line, so stage output no longer passes through the orchestrator session. `execution.orchestrator: llm` restores the per-stage loop. `vcs.provider: file` and `roles.planner: true` stay on the loop. `talos.sh env` prints the effective mode as `ORCHESTRATOR=code|llm`. The new `execution.context_budget_tokens` (default 150000, 0 turns it off) applies to the loop only.
- **Draft PRs are the default (`pr.draft`, #435).** On github, gitlab and azure the developer opens a draft PR, the review roles run on the draft, and CI runs once, after `ready-pr`. `pr.draft` falls back to `false` with a warning when your CI workflow has no `ready_for_review` trigger. `github-api` and `file` resolve to `false`. For the old flow set `"pr": {"draft": false}`. `/talos:setup` offers the minimal workflow edit. The new `pr.ready_gate: qa-local` (default `off`) runs QA on the draft before `ready-pr`.
- **The events log and run state moved (#517).** `events.path` now defaults to `talos/events.jsonl` and a relative value resolves against the git common dir, so the log lives at `<git common dir>/talos/events.jsonl`, outside every git tree. The old default was `.talos/events.jsonl`. A relative path that climbs out of the common dir is refused. If you set `events.path` yourself, check where it now points.
- **Secrets (#443, #444, #476).** `~/.hermes/.env` is deprecated: it is still read, with one warning per process, and `${TALOS_HOME:-~/.talos}/.env` is the supported file (regular file, owned by you, mode 0600, outside a git work tree). The six notification secrets (`notifications.slack.webhook`, `.discord.webhook`, `.teams.webhook`, `.slack.bot_token`, `.discord.bot_token`, `.buzz.bot_key`) take only an `env:NAME` reference. A literal secret in either config file is dropped on load with a stderr line that names the key. A `.env` can export only the notification variables, never `PATH`, `BASH_ENV` or `GITHUB_TOKEN`. The user-level `~/.talos/talos.pipeline.json` is ignored with a warning unless it is a regular file you own that is not group- or world-writable.
- **Multi-user claiming is on by default (`issues.claim`, #560).** With `issues.claim: true` (the default) and an assignee other than `none`, `talos.sh next` assigns an unassigned `pipeline:ready` issue to the operator before it dispatches and never acts on an issue assigned to someone else (`state --summary` shows it as `theirs: #N (@login)`). On a shared repo where another person or bot owns the assignee field, set `issues.claim: false`. `identity.name` names the login to claim under when it is not the authenticated one.
- **Markers need a known author on GitHub (#453).** When `GET /user` is refused (a GitHub Actions `GITHUB_TOKEN` or a GitHub App token) and `markers.trusted_authors` is empty, every `talos:approval` and `talos:attempt` marker is rejected (fail closed; `trust-unverified`). Set `markers.trusted_authors` to the logins that post Talos markers, for example `["github-actions[bot]"]`.
- **Tighter merge and approval gates.** The forbidden-files defaults now cover credential files such as `.npmrc`, `.pypirc`, `.netrc`, `*.kdbx`, `*.ovpn` and `.aws/credentials`, matched case-insensitively (#436). A `merge.forbidden_files_allow` entry that would also exempt a denied path, such as `*.json`, fails validation and the gate fails closed. Agent instruction files (`agents/`, `skills/`, `templates/prompts/`, runner dot-directories, `AGENTS.md`, `CLAUDE.md`) are never waivable in `check-approval-sha`, even under the default `*.md` waiver (#428, #431). `post-approval` refuses a reviewer or security approval with no review body, an empty one, or a body file older than the stage's start (#663, #699). A project-level role override must pass `--body-file -` or a fresh file. Reviewer, security and adversarial stages must put the verdict word first in their final message (#518).
- **QA stops where it used to fail or pass (#655, #610, #646, #714, #717, #724).** A spec QA cannot use (unreadable, no criteria checklist, a refused or missing `Tests:` line, a `Tests:` directory) ends `qa-run: verdict BLOCKED spec` and `stop reason=spec-unusable`, with `pipeline:blocked` on the PR and the issue and no developer fix round. A `qa-run` that finds a `Tests:` file changed since the red commit now runs the red version against the head and fails `AC<n> FAIL weakened` unless the change is acknowledged with `--ack-changed <reason>`. A test that fails and then passes on the one re-run is `AC<n> FAIL flaky` and stops the run for the owner (`stop reason=qa-flaky`). A failing `verify.ready` command ends `qa-run: verdict BLOCKED environment` and stops the run `environment`, with no fix round, because the code was not judged. A `(same: <why>)` criterion passes when its tests are green at the red commit and at the head. New opt-ins: `verify.targeted_commands` for non-Talos stacks and `verify.e2e` (repo-only).
- **Headless Claude stages get a scoped permission list (#580).** A claude-runner stage passes `--allowedTools` per role (Read/Glob/Grep, the Talos scripts, read-only git; the developer adds Edit/Write/git and your verify commands) and `--add-dir` for the Talos scripts. If a stage needs a command outside that list, add it with `agents.claude_allowed_tools`. `agents.claude_permission_mode` stays unset unless you choose a mode. `bypassPermissions` removes every guard, so use it only on a sandboxed runner. Under the claude runner a `verify.timeout_ms` above 600000 is clamped in the stage prompts, with a warning, and a QA verify that times out ends `stop reason=verify-timeout` (#675).

Every change is listed in [CHANGELOG.md](../CHANGELOG.md).

### Set up a repo

1. `bash talos/install.sh /path/to/repo`, then copy `talos.pipeline.json.example` to `talos.pipeline.json` and edit it, or run the wizard. Minimal: `{ "base_branch": "dev", "verify": ["npm test"] }`.
2. Wizard: `/talos:setup` in Claude Code; elsewhere `Read ~/.talos/skills/setup/SKILL.md and follow it`. It detects provider, base branch and verify commands, asks about roles, board, notifications, runner and models, writes the config, and offers the `AGENTS.md` block, bootstrap and a test notification. Safe to re-run; a model choice goes to the user-level file after a diff and a yes.
3. `bash ~/.talos/scripts/bootstrap-labels.sh [owner/repo]` creates or updates the `pipeline:*`, approval and control labels (`spec:ready`, `skip-qa`, `epic`, `p0`-`p2`). Idempotent; needs `gh` (GitHub only).
4. `bash ~/.talos/scripts/bootstrap-board.sh [owner/project_number]` adds the missing Status options (In progress, In review, Done, Blocked, Ready) to `board.status_field` (it does not create the field). Azure: validates `board.azure_states.*`; GitLab: checks labels; file provider or `board.enabled: false`: no-op.
5. Queue: `gh issue edit 42 --add-label pipeline:ready`, or a `- [ ] task` line in `plan.md` (file mode).
6. Run: `/talos:pipeline` in Claude Code; any other agent: `Read ~/.talos/skills/pipeline/SKILL.md and follow it`. Without an orchestrator session: `bash ~/.talos/scripts/talos.sh run [--issue <N>] [--max-iterations <n>]` (default 20 passes; a long drain passes a larger number). It loops `talos.sh next`, dispatches stages through `pipeline-agent.sh` and runs the gates in code. Started without `--issue` it drains the queue in priority order: after each merge the checkout is back on the base branch and the next pass runs. Exit codes: 0 on a clean stop (ask-owner, a stage block, a wait, a requested stop, the iteration cap), 1 on an unreadable state and on the stops that need a person's fix (`provider-failed`, `merge-failed`, `worktree-unavailable`, `ready-pr-failed`, and the ones `next` passes through such as `max-fix-attempts` and `budget-exceeded`). Re-run to resume. `talos.sh run --stop` asks a running run to stop at the top of its next pass.

### Per harness

`--harness` is installer glue; `agents.runner` picks the stage CLI. Set `issues.max_parallel: 1` on non-native paths. The "Stages run as" and "Parallel issues" columns describe the LLM loop (`execution.orchestrator: llm`); under the default code driver every harness runs each stage as one headless call to `agents.runner`, one at a time.

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

Code orchestrates by default (`execution.orchestrator: code`), so a weak model never has to follow the per-stage loop: keep that default for a local profile.

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

Repo-only keys: `base_branch`, `repo`, `vcs.provider`, `vcs.repo`, `vcs.azure.*`, `vcs.file.source.path`, `board.*`, `verify` (and `verify.commands`), `verify.qa_mode`, `verify.targeted_commands`, `verify.e2e`, `verify.e2e_artifacts.*`, `verify.guide`, `review.guide`, `verify.ready`, `merge.required_checks`, `merge.forbidden_files`, `merge.forbidden_files_replace`, `merge.forbidden_files_allow`, `merge.approval_waiver_paths`, `merge.union_paths`, `issues.label_filter`, `issues.skip_labels`, `markers.trusted_authors`, `markers.verify_authors`. In the user-level file each is dropped with one stderr note naming the key, not the value. Their environment variables still apply.

The user-level file drives `hooks.*` and `notifications.cmd`, so it is read only if it is a regular file (or your symlink to one) owned by you and not group- or world-writable. Otherwise one stderr line names the fix and the layer reads as absent, as does malformed or non-mapping content.

### Secrets

A config file never holds a secret. Six keys are typed `secret` and take only a reference, `env:NAME`: `notifications.slack.webhook`, `.discord.webhook`, `.teams.webhook`, `.slack.bot_token`, `.discord.bot_token`, `.buzz.bot_key`. Without a reference each reads its documented variable (`SLACK_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL`, `TEAMS_WEBHOOK_URL`, `SLACK_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `BUZZ_BOT_PRIVATE_KEY`). Use a reference only to read a differently named variable (`"notifications.slack.webhook": "env:ACME_HOOK"`); a webhook reference must resolve to an `https://` URL.

Lookup order, first match wins: (1) the exported environment, (2) the repo `.env`, (3) the reference, which renames the variable searched in 1, 2, 4 and 5 (if unresolved, the platform is skipped with one stderr line, with no fallback to the documented name), (4) `${TALOS_HOME:-~/.talos}/.env`, (5) the deprecated `~/.hermes/.env` (`TALOS_HERMES_ENV=<path>` moves it, empty disables it).

- A `.env` is parsed, never sourced. `~/.talos/.env` is used only if it is a regular file (not a symlink) owned by you, mode 0600, outside every git work tree; otherwise one stderr line names the fix and the file is skipped.
- A `.env` may set only the notification variables (the six credentials, `BUZZ_RELAY_URL`, and the `PIPELINE_*` channel and relay overrides); other names are ignored with one stderr line. A deny list wins over that (`PATH`, `BASH_*`, `LD_*`, `GIT_*`, `TALOS_*`, `GH_*`, `GITHUB_*`, `*_PROXY`, ...), and a reference to a denied name is refused. `GITHUB_TOKEN` and `GH_TOKEN` are never read from a `.env`: export them in your shell.
- `CLAUDE_API_CREDITS_KEY` (`agents.claude_api_credits`, [Monthly API credits](#monthly-api-credits)) is the one entry read from `~/.talos/.env` and from nowhere else: the exported environment, the repo `.env` and `~/.hermes/.env` are not sources for it. It takes no `env:` reference, and it reaches only the `claude` child of a stage.
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
| `board.azure_team` | str | - | - | repo |
| `board.azure_board` | str | - | - | repo |
| `board.azure_columns.*` | str | - | - | repo |
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
| `verify.targeted_commands` | list | - | - | repo |
| `verify.e2e` | str | - | - | repo |
| `verify.guide` | str | `VERIFY.md` | - | repo |
| `verify.e2e_artifacts.dir` | str | - | - | repo |
| `verify.e2e_artifacts.include` | list | - | - | repo |
| `verify.e2e_artifacts.max_files` | int | `12` | - | repo |
| `verify.e2e_artifacts.max_mb` | int | `25` | - | repo |
| `verify.ready` | list | - | - | repo |
| `verify.ci_wait_s` | int | `900` | - | any |
| `verify.ci_requeue_stuck` | bool | `true` | - | any |
| `verify.timeout_ms` | int | `600000` | - | any |

#### review.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `review.guide` | str | `REVIEW.md` | - | repo |

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
| `execution.orchestrator` | enum | `code` | - | any |
| `execution.context_budget_tokens` | int | `150000` | - | any |

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

#### docs.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `docs.paths` | list | `README.md, docs/*, scripts/pipeline-defaults.sh` | - | any |

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
| `agents.claude_api_credits` | bool | `false` | - | any |
| `agents.profile` | str | - | `TALOS_PROFILE` | any |
| `agents.mode` | enum | - | - | any |

#### limits.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `limits.max_fix_attempts` | int | `3` | - | any |
| `limits.max_total_dispatches` | int | `8` | - | any |
| `limits.same_area_rounds` | int | `2` | - | any |
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
| `pr.ready_gate` | enum | `off` | - | any |

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

#### map.*

| Key | Type | Default | Env override | Scope |
|---|---|---|---|---|
| `map.enabled` | bool | `true` | - | any |

<!-- config-table:end -->

## Profiles, runners and fallback

Three independent choices: **mode** (who spawns a stage), **runner** (which CLI executes it) and **model/effort**. A **profile** bundles them under one name. Talos never calls a model API itself; every runner must be an agentic CLI (it runs shell commands and edits files).

### Modes and runners

- `native`: the harness's own subagent tool (Claude Code's Agent); parallel issues, worktree isolation.
- `adapter`: one headless CLI call per stage through `scripts/pipeline-agent.sh <role> -`; sequential, set `issues.max_parallel: 1`.
- `inline`: the orchestrating session plays every role itself (pi, weak or local models).

The mode decides who spawns a stage in the LLM loop (`execution.orchestrator: llm`). The default code driver spawns no subagent: `talos.sh run` sends every stage through `pipeline-agent.sh`, one at a time, as the `adapter` line says, whatever the mode is. So the "Adapter" entries under [Per-role model, effort and runner](#per-role-model-effort-and-runner) are the ones that apply by default: the built-in `claude` runner passes the role's model as `--model <m>` (an explicit `--model` in `agents.runner_args` wins), while `pi`, `codex`, `gemini` and `antigravity` take no `model` or `effort` from the config (`agents.runner_args` adds a flag for all roles; a `custom` runner reads `$TALOS_MODEL` and `$TALOS_EFFORT`).

`agents.subagents` is `auto` (default), `true` or `false`: `auto` is `native` on Claude Code (and on an unknown harness when the runner is `claude`), elsewhere `inline` for runner `pi`, else `adapter`; `false` is `inline` for runner `pi`, else `adapter`; `true` is `native`. `agents.mode` (`native|adapter|inline`) sets it directly. The harness is `CLAUDECODE=1` or `TALOS_HARNESS` (for example `pi`; it wins). Claude Code provides all three modes, any other declared harness `adapter` and `inline`.

`agents.runner` is `claude` (default), `pi`, `codex`, `gemini`, `antigravity` or `custom`; `agents.runner_args` (a list, one value for all roles) adds arguments to the built-in ones.

Invocations (the prompt is the last argument): `claude -p --setting-sources project [args]`, `pi -p [args]`, `codex exec [args]`, `gemini [args] -p`, `agy [args] -p`, and for `custom` `sh -c "$runner_cmd"` with the prompt on stdin. The prompt is the role body (frontmatter stripped), a `---` line, then the stage prompt. Per harness: [Install and setup](#install-and-setup). On the native path, a role whose runner is not `claude` goes through `pipeline-agent.sh`; the rest stays native.

### Per-role model, effort and runner

Each key resolves `agents.roles.<role>.<key>`, then `agents.<key>`.

| Key | Effect |
|---|---|
| `model` | Native spawn: full ID or `opus`/`sonnet`/`haiku` (an alias-only harness gets the family alias); unset means the session model. Adapter: the built-in `claude` runner gets `--model <m>`; `pi`, `codex`, `gemini` and `antigravity` ignore it; `custom` gets `$TALOS_MODEL`. |
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

**Exit 69**: chain exhausted, every runner down, or failover refused. `talos.sh run` stops with `stop reason=provider-failed rc=<75|69>` and records nothing. The run sets no label and runs no fix round, and exits 1; a re-run resumes. Native path verbs: `pipeline-agent.sh --classify <runner> <rc> <file|->` and `--mark-down <runner> <class:detail>`.

### Monthly API credits

Max and Team plans include monthly Claude Platform API credits, a pool separate from the plan's usage limits ([Monthly API credits for Max and Team plans](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans)). A headless `claude -p` draws on them only when it runs with an API key; signed in with the plan, the same command draws on the plan's limits. Talos dispatches every claude stage signed in with the plan, so by default the credits go unused. With `agents.claude_api_credits: true` (default `false`) a built-in claude stage starts on the credits and falls back to the plan login when they run out.

**Setup.** Claim the credits as the help article describes; the key comes from the Console organization linked to the plan. Put it in the user-level `.env` (mode 0600, [Secrets](#secrets)) and switch the option on:

```
# ~/.talos/.env ($TALOS_HOME/.env when TALOS_HOME is set)
CLAUDE_API_CREDITS_KEY=<the key>
```

```json
{ "agents": { "claude_api_credits": true } }
```

No other source is read: not the exported environment, not the repo `.env`, not `~/.hermes/.env`. A stage runs "credits on" only when the option is `true`, its runner is the built-in `claude` and the file gives a non-empty value with no control character. Otherwise it is dispatched exactly as without the option; a refused file or a control character adds the usual `pipeline-secrets` line, which names the key and never the value.

| Pool | Event `pool` | The `claude` child gets |
|---|---|---|
| the plan's monthly API credits | `api` | `ANTHROPIC_API_KEY` set to the file's value, replacing one you exported |
| the plan login | `plan` | `ANTHROPIC_API_KEY` unset, also when you exported one |

The key is set for that one child only: it is in no argv, it is never exported from the agent script, and no hook, other runner or rerun inherits it. The stage's own tool calls do inherit it. They run as you and can read the file anyway, so this is documented, not prevented.

**The switch.** When the keyed attempt ends in the `provider` / `quota` class ([Runner fallback](#runner-fallback)) and wrote nothing, the stage is rerun once on the plan login with the same prompt. stderr gets one line, and a `failover` event carries the same summary:

```
talos:failover role=<role> from=claude:api to=claude:plan reason=provider:quota
```

The rerun's stdout and exit code are the stage's, and from there it is an ordinary claude attempt: with `agents.fallback`, a provider error fails over to the next entry as it does today. The runner did not change, so nothing is marked down in `providers.json` and nothing is checkpointed. An exhausted pool is not remembered: each later stage makes one failing attempt on the key, then switches.

- **Write guard.** The rerun follows the write guard above. A keyed attempt that already wrote (a journalled write verb, a moved `refs/remotes` ref, or a missing or unreadable journal) is not rerun: `talos:failover-refused role=<role> runner=claude reason=wrote:<verbs>` (or `reason=write-log-unreadable`) and exit 69. This is the one case where an exhausted pool stops the stage.
- **No fallback on any other failure.** `API Error: 401` (an invalid or revoked key included), `429`, a 5xx, a network error, a task failure and a stage timeout keep today's behaviour: no rerun on the plan login, the same exit code, and with a chain the same failover to the next entry. A wrong key fails the stage; it never runs on the plan silently.
- **Not yet captured.** The error text of an exhausted credit pool has not been captured from a real run. The switch relies on the existing `quota` patterns (`Credit balance is too low`, `usage limit reached`); if the real text differs, the stage fails as `task`, as it does today.
- **Auto-reload bills money.** With auto-reload on, or with purchased credits, in the Console, an exhausted monthly pool does not fail: the requests are billed, Talos never sees an error and never falls back to the plan. Turn auto-reload off to keep the spend at the included credits.
- **Adapter path only.** Only the adapter path (`talos.sh run`, which dispatches each stage through `pipeline-agent.sh`) can use the credits. Native Claude Code subagents and the interactive session run on the plan login. Other runners (`pi`, `codex`, `gemini`, `antigravity`, `custom`, a `runner_cmd` that calls claude) are untouched.

Each stage event names the pool that paid, and `pipeline-events.sh cost` shows the split ([Spend](#spend)).

### Claude permissions on headless stages

`claude -p` cannot answer an approval prompt, so a claude-runner stage in a repo with no allowlist of its own could run nothing. `pipeline-agent.sh` passes `--allowedTools` (a scoped default per role), `--add-dir <the Talos scripts dir>` (skipped when the stage cwd is inside it) and `--disallowedTools Edit/Write` on that dir. Rule grammar: [Claude Code permissions](https://code.claude.com/docs/en/permissions); `Bash(<prefix>:*)` allows the prefix and anything after it, and each subcommand of a compound command must match on its own.

| Role | Default allowlist |
| --- | --- |
| all | `Read`, `Glob`, `Grep`; each `pipeline-*.sh` and `talos.sh` present in the install, by name, as `scripts/X`, `./scripts/X` and `<install dir>/X`; read-only git (`status`, `diff`, `log`, `show`, `rev-parse`, `ls-files`, bare `branch`, `branch --show-current`, `branch --list`) |
| developer | + `Edit`, `Write`, `Bash(git:*)`, the verify commands |
| validator, qa | + the verify commands |
| docs | + `Edit`, `Write` |
| pm, planner, reviewer, security, adversarial | nothing more |

The docs role has no `git add`, `git commit` or `git push` rule: a raw git write acts on whatever branch is checked out, the base branch included. It commits its own edit with `pipeline-worktree.sh commit-docs <pr> -- <file>...` (a script the list already names; the commit message on stdin), which stages only the files it is given, commits with the repo's hooks and pushes, never forced. The verb refuses (exit 1, nothing committed or pushed) unless the current branch is the head branch of PR `<pr>` as the provider reports it (`pipeline-vcs.sh pr-head-ref <pr>`, on GitHub, GitLab and Azure; file mode has no PR, so it refuses) and is not `main`, `master` or the base branch; when the index already has staged changes; when a file is a directory, a symlink, ignored, outside the checkout or matches a forbidden-files pattern; and when `TALOS_ROLE` names a role other than docs. Exit 3 is a failed push (the commit is kept locally). `tests/test-claude-permissions.sh` checks every `git` command a role profile (`agents/*.md`) instructs in backticks against that role's list, so a profile cannot ask for a command its allowlist refuses.

A verify command becomes `Bash(<command>:*)` only when it is plain words (letters, digits, space and `. / _ = : @ % +  -`). Anything with a quote, `$`, `` ` ``, `;`, `&`, `|`, `<`, `>`, `*`, a parenthesis or a backslash cannot be a prefix rule without widening it, so it is skipped with a warning that names its position, not its text; add a rule for it with `agents.claude_allowed_tools`.

- `agents.claude_allowed_tools` (list) adds rules, e.g. `["Bash(npm run lint:*)"]`. `agents.roles.<role>.claude_allowed_tools` replaces the global list for one role. An entry must be `Name` or `Name(args)` with no comma, control character or inner parenthesis; others are dropped with a warning.
- `agents.claude_permission_mode` (`acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`; role override `agents.roles.<role>.claude_permission_mode`) is unset by default and then no `--permission-mode` is passed. **Risk:** issue and PR text is untrusted input and a stage acts on it; `bypassPermissions` removes every guard, so use it only on a sandboxed or ephemeral runner. A broad `claude_allowed_tools` entry such as `Bash` or `Bash(*)` is the same trade.
- Every role is also denied `Edit` and `Write` on the resolved config files that exist (`${TALOS_HOME:-~/.talos}/talos.pipeline.json`, `$PIPELINE_CONFIG` or `./talos.pipeline.json`, the repo's `talos.pipeline.json`). A Bash write is not covered by a deny rule, so `pipeline-agent.sh` also checksums those files before and after any runner's stage: a changed, created or removed file ends the stage with exit 78 and `pipeline-agent: reason=config-mutated role=<role> file=<path>`, `hooks.post_stage` still fires with verdict FAIL, and `talos.sh run` stops with `stop reason=config-mutated role=<role> file=<path>` (exit 1, no verdict read, no label change). The file is not restored.
- Headless `claude -p` refuses every Edit/Write under `.claude/` as a sensitive file; `acceptEdits` and `--allowedTools` do not lift that, only `auto` or `bypassPermissions` do. A repo whose docs live there sets `docs.paths` (for example `[".claude/docs/**"]`) and the docs role needs `claude_permission_mode: auto`; the docs stage warns at startup when `docs.paths` has a `.claude/` entry and its mode is anything else.
- An `--allowedTools` or `--dangerously-skip-permissions` in `agents.runner_args` is the owner's own policy: nothing is added on top of it. A `--permission-mode` there wins over the config key.

A stage whose final message starts with `BLOCKED: <reason>` is a blocked outcome for any role: `talos.sh run` sets `pipeline:blocked` on the issue (and the PR), relays the reason, and stops with `stop reason=stage-blocked role=<r>` (exit 0). QA's `BLOCKED: spec: <why>` is the exception: it stops as `stop reason=spec-unusable issue=<N> pr=<M>`, and `BLOCKED: verify: timed out after <n> ms` stops as `stop reason=verify-timeout role=qa pr=<M>`.

### Token usage on adapter runs

Each attempt reports `tokens` (input + output + cache-creation, no cache reads; else `null`, never `0`) to the stage event, so `pipeline-events.sh cost` and `limits.tokens_per_issue` count it. The claude runner also reports the split: `input_tokens` (fresh, uncached), `output_tokens`, `cache_write_tokens` and `cache_read_tokens`, each summed over every model of the run and left out when the runner output has no valid figure for it. Cache reads are only ever that fourth number: `tokens` and the budget leave them out. Every attempt of every runner prints one line on stderr (`null` = not reported):

```
talos:usage runner=<r> tokens=<N|null> input=<N|null> output=<N|null> cache_write=<N|null> cache_read=<N|null>
```

A failed attempt with usage becomes a `stage_attempt` event carrying the same figures.

- `claude`: `--output-format json` is added after `runner_args`; `modelUsage` is summed over all models, else top-level `usage`.
- `custom`: a JSON sidecar at `$TALOS_USAGE_FILE`, every key optional: `{"tokens": 1234, "tool_uses": 7, "model": "qwen2.5-coder"}`.
- `codex`, `gemini`, `antigravity`, `pi`: `null`.

`agents.capture_usage: false`, or `--output-format` in `runner_args`, leaves the claude call untouched.

### Prompt cache lifetime

Developer and QA wait on a test suite, often for longer than the 5-minute prompt cache lives, and the turn after the wait then rebuilds the whole context. Talos asks Claude Code for the 1-hour cache for those two roles and for no other. Claude Code puts every request in one of two buckets, and the bucket depends on how the stage was dispatched ([Claude Code: prompt caching](https://code.claude.com/docs/en/prompt-caching#cache-lifetime)):

| Dispatch path | Claude Code bucket | TTL with no control set | What Talos adds |
|---|---|---|---|
| Code driver (default, `execution.orchestrator: code`): one `claude -p --setting-sources project` per stage | main conversation | 1 hour on a subscription within plan usage; 5 minutes on an API key, a cloud provider or usage credits | `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` in the environment of the `claude` child of a developer or QA stage |
| LLM loop (`execution.orchestrator: llm`): native subagents | everything else | 5 minutes, on a subscription too | `experimental:` / `cacheTtl: 1h` in the frontmatter of `agents/developer.md` and `agents/qa.md` |
| Any other runner (`pi`, `codex`, `gemini`, `antigravity`, `custom`) | not Claude Code | unchanged | nothing: the frontmatter is stripped from the prompt and the variable is not set |

- **Driver path.** `pipeline-agent.sh` sets the variable for developer and QA only, on the `claude` runner only, and only when the caller's environment does not have it: start Talos with `CLAUDE_CODE_PROMPT_CACHE_TTL=5m` and both roles get that value unchanged. The other seven roles keep the bucket's default. There is no Talos config key for this.
- **Profile overrides.** The driver path goes by the role name, so a repo override of `developer.md` or `qa.md` ([Role profile files](#role-profile-files)) keeps the hour there. On the LLM loop the override's own frontmatter is what Claude Code reads: copy the `experimental:` / `cacheTtl: 1h` lines into it to keep the hour.
- **Version floors.** The settings (`promptCacheTtl` for the main conversation, `subagentPromptCacheTtl` for everything else) and the environment variables need Claude Code v2.1.242 or later; the frontmatter key needs v2.1.248 or later. An older Claude Code ignores what it does not know. On v2.1.242 to v2.1.247 native subagents get the hour only from `"subagentPromptCacheTtl": "1h"` in your own Claude Code settings, which covers every subagent, not just these two; `install.sh --global` prints that recommendation and writes no setting.
- **Precedence**, first match wins: `FORCE_PROMPT_CACHING_5M=1`, then the bucket's environment variable, then the bucket's setting, then the frontmatter `cacheTtl`. So a `subagentPromptCacheTtl` of `5m` beats the two agent files, and `FORCE_PROMPT_CACHING_5M=1` beats everything Talos sets.
- **Usage credits.** Claude Code ignores a frontmatter `1h` while a subscription draws on usage credits. A variable or a setting counts as a TTL you chose yourself and is kept there, so on the driver path the two roles stay on the hour on usage credits, as they do on an API key or a cloud provider.
- **Cost.** 1-hour cache writes cost more than 5-minute ones. The hour pays for itself on a stage that idles past five minutes and costs more on one that never does, which is why only the two roles that wait ask for it. To stay on five minutes, start Talos with `CLAUDE_CODE_PROMPT_CACHE_TTL=5m`.
- **Check.** In the result of `claude -p "hello" --output-format json`, `usage.cache_creation.ephemeral_1h_input_tokens` counts the 1-hour writes and `ephemeral_5m_input_tokens` the 5-minute ones.

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

### Running in a Claude Code cloud session

A Claude Code cloud session (claude.ai/code) can run `talos.sh run` on a GitHub repository. There, GitHub refuses GraphQL (`HTTP 403: GitHub GraphQL is not available from Claude Code sessions`) and serves REST. The adapter's verbs are REST already. `checkout-pr` tries `gh pr checkout` and, when GraphQL is refused, falls back to a REST read of the head ref and a `git fetch` of `refs/pull/<n>/head`. `ready-pr` and `draft-pr` send their GraphQL mutation and, on HTTP 403, use the session's REST routes `pulls/<n>/ccr/ready_for_review` and `pulls/<n>/ccr/convert_to_draft`. On a machine where GraphQL works, nothing changes.

Setup:
- Install the Claude GitHub App on the repository with write access to contents, issues and pull requests, and connect GitHub from claude.ai.
- The developer's branch must be one the session may push: the session's designated branch (`claude/...`), or a `fix/issue-<N>-...` branch once the GitHub App has write access. A refused push ends the developer's checkpoint with one line, `pipeline-worktree: checkpoint: push refused: no push access to origin for <branch>`, and exit 3: the commit stays local, and the developer carries on and reports it in its final message.

Skipped: the project board. Projects v2 has no REST API, so each board move is one `warn reason=board-failed` line, with the note `the board needs GitHub GraphQL, which this session refuses (HTTP 403); move skipped`, and the run goes on. `bootstrap-board.sh` and `bootstrap-labels.sh` need GraphQL: run them on a normal machine once.

Left behind: a merged PR's head branch the session may not delete. `merge-pr` prints one `could not be deleted` line (no `HTTP 403` note), and the run adds `warn reason=branch-left issue=<N> branch=<BRANCH>` per branch, so the run's output lists what to delete by hand.

Not verified: that a session may change a PR's draft state. `ready-pr` and `draft-pr` reach the session's routes, but the one real call, `draft-pr` on a PR that was already a draft, was answered HTTP 403 (`pipeline-vcs: draft-pr: GitHub refused the change for PR #<n>`). With `pr.draft` true, that refusal ends the run with `stop reason=ready-pr-failed` (`draft-pr-failed` after a failed QA). With `pr.draft: false` the run calls neither verb.

Comment footer: the session appends two lines to every comment it posts, a `---` line and `_Generated by [Claude Code](https://claude.ai/code)_`, so a Talos marker is no longer the comment's last line. Markers are read through it: every marker reader (the approval stamp, `talos:spend`, `talos:needs-owner`, the attempt record) skips exactly that one footer, with blank lines around it, and nothing else. Any other text after a marker still makes it no marker, and the author rules are unchanged.

Docs worktree: a fresh session clone is on the base branch, and there is no developer worktree for the PR. The driver runs the docs stage in a worktree of the PR's head branch (`pipeline-worktree.sh pr-worktree <N> <M>`, under `.claude/worktrees/`), so docs edits and `commit-docs` happen on that branch and the driver's checkout stays clean.

Cost: the plan's cloud session credit applies to cloud sessions only; a run on your own machine draws on the plan as before. Whether a stage's nested `claude -p` inside a cloud session is billed to that credit is not verified.

### GitLab

`list-issues`, `view-issue` and `list-prs` print the raw `glab` objects (`--output json`) with the GitHub-shaped keys the router reads added: `number` (from `iid`), `title`, `state`, `body` (from `description`) and `labels` as `[{"name": ...}]` for issues; `number`, `headRefName`, `baseRefName`, `isDraft` and `isCrossRepository` for MRs (`false` only when `source_project_id` equals `target_project_id`, else `true`). Output that is not a JSON array (an object for `view-issue`) exits 1 with nothing on stdout. `view-issue` adds the issue's notes as `comments: [{id, body, author: {login}, createdAt}]` (every page, oldest first, GitLab system notes dropped), and `--spec` and `--since-stage` work as on GitHub; a failed issue or notes read exits 1 with nothing on stdout. `list-issues` and `list-prs` stop at 100 items (`WARNING result capped at 100` on stderr). No board (`pipeline-status.sh` prints `board unsupported for gitlab`). `pr-checks-required` judges the MR's head pipeline (or the named jobs of it; see Required checks), and exits 1 when it cannot read it. `pr-head`, `read-comments` (MR ids), `check-approval-sha` and `post-approval` work on MRs with the same trust rules and markers as GitHub (MR notes through `glab api`, the head sha from `glab mr view`, the label with `glab mr update --label`), and `record-attempt`, `read-attempt`, `check-attempt` and `has-spec` work on issues, with the attempt marker in an issue note.

### Azure DevOps

| Key | Meaning |
|---|---|
| `vcs.azure.org_url`, `vcs.azure.project` | Organization URL, project |
| `vcs.repo` | Azure repository name |
| `vcs.azure.work_item_type` | Type `create-issue` makes (default `Product Backlog Item`) |
| `vcs.azure.area_path` | Area path for new work items |
| `board.azure_states.{ready,in_progress,in_review,done,blocked}` | Work-item State per pipeline status; when set, it wins over the board's column mapping |
| `board.azure_team`, `board.azure_board` | Team and board whose columns are read (default: the team whose default area path is `vcs.azure.area_path`, else the project's default team, and the board of the requirement backlog; the backlogs API answers 404 without a team) |
| `board.azure_columns.{ready,in_progress,in_review,done}` | Column name to look for, for a board whose names are not the defaults (replaces the default names for that status) |

- Labels are Tags. A board move sets the work item State. Defaults are Scrum (`New`, `Committed`, `Committed`, `Done`); `blocked` is unset and leaves the State alone. Set the keys for Agile or CMMI.
- The State of a move comes from the team board, not from a guess (one read-only `az rest` call per run, cached under `PIPELINE_RUN_ID`): the column whose name matches the status (case-insensitive; `ready`: New, Ready, To Do, Proposed; `in_progress`: In Progress, Active, Doing; `in_review`: In Review, Review, Ready for Review, Code Review; `done`: Done, Closed, Resolved, or the one name in `board.azure_columns.<status>`) gives its `stateMappings` entry for `vcs.azure.work_item_type`. Order per status: an explicit `board.azure_states.<status>` in a config file, then the column's State, then the table default when the board cannot be read. `blocked` has no column and uses only `board.azure_states.blocked`. After the update the work item's `System.BoardColumn` is read back: `#N → In progress (ADO state: Approved, column: In Progress)`, without the column when the read fails. Board problems are warnings on stderr and the run goes on: `warn reason=board-states-collide` (two of ready, in_progress, in_review, done resolve to one State, so a move between them cannot change the column; once per run), `warn reason=board-column-unresolved` (no column matched the status; its work item is left unchanged), `warn reason=board-team-unmatched area=<path>` (`vcs.azure.area_path` is the default area of no team, so the project's default team, `defaultTeam.id` of `GET <org>/_apis/projects/<project>`, is used) and `warn reason=board-columns-unavailable step=<step>` (the board could not be read: az missing, no access, bad JSON; the explicit or table State is used; `step` is `teams` for the project or teams lookup or a project with no default team, `backlogs` for the backlogs call or a project with no requirement backlog, `columns` for the columns call; set `board.azure_team` to name the team yourself).
- `list-issues`, `view-issue` and `list-prs` print the raw `az` objects with the GitHub-shaped keys the router reads added: `number`, `title`, `state`, `body` (from `System.Description`) and `labels` as `[{"name": ...}]` (from `System.Tags`) for work items; `number`, `title`, `headRefName`, `baseRefName` (`refs/heads/` stripped), `isDraft` and `isCrossRepository` for PRs. `has-spec` runs on Azure through that `view-issue`.
- Work-item comments are stored as HTML (`comment-issue` converts the markdown, as it does the Description). `view-issue` adds them as `comments: [{author: {login}, body, createdAt}]` (every page, deleted ones skipped, `login` the creator's `uniqueName`) with each body converted back to markdown: `<strong>` to `**x**`, `<em>` to `*x*`, `<code>` to backticks, each `<li>` to a `- ` line (a checkbox, as `[ ]` / `[x]` text, `☐` / `☑` or `<input type="checkbox">`, comes back as `[ ]` / `[x]`), other block tags to newlines, entities unescaped, `<pre>` text kept, other tags dropped, and a `<!-- ... -->` marker (raw or `&lt;!-- ... --&gt;`) kept verbatim. So a PM spec posted through `comment-issue` is what `view-issue --spec`, `--since-stage` and `pipeline-criteria.sh` read. `read-comments <wi> --work-item` and `read-attempt` still return the stored text, unconverted.
- `create-pr` links the work item named by an `issue-<N>` branch with `--transition-work-items true`; that link closes it, not `Closes #N`.
- `close-issue` sets `board.azure_states.done` and strips `pipeline:*` tags. `merge-pr` completes the PR (policies apply) and `create-pr` sets the completion option from `merge.method`: `squash` (the default) passes `--squash true`, and `merge-pr` also sets the squash commit message to the PR title; `merge` passes `--squash false`; `rebase` passes no flag (`az repos pr` has none). `update-branch` exits 2.
- `upsert-pr-comment <pr> --marker <name> --body-file <path|->` keeps one marker comment per PR: it updates the newest comment you authored whose last line is the marker (a PATCH of that thread comment), else starts a new thread, and writes nothing when the body is unchanged. `mark-needs-owner <pr> --body-file <path|->` posts the question as a thread ending in `<!-- talos:needs-owner -->` and adds `pipeline:needs-owner`; `list-needs-owner [--json] [--clear-answered]` lists the active PRs that carry the label (one labels read per active PR) and removes the label from answered ones by label id. Work items are not listed. `gitlab` has the same three verbs on merge requests (an MR note, `glab mr update --label`); an issue iid is not accepted, as GitLab numbers issues and MRs separately.
- `attach-files <pr> <file>...` (#776) uploads the files and keeps one `<!-- talos:qa-evidence -->` comment on the PR (a `QA evidence for <sha8>` heading, an inline image for `.png .jpg .jpeg .gif .webp`, a link for anything else). It posts through `upsert-pr-comment`'s rules, so a later round edits that comment, and prints the comment URL. A file must be a regular file and not a symlink, and `<pr>` a number: otherwise exit 1 before any call. An upload that fails exits 1 and nothing is posted. Uploaded names keep only `A-Z a-z 0-9 _ . -` (a path separator becomes `-`) and are made unique. Azure DevOps: `POST .../pullRequests/<id>/attachments/<sha8>-<name>` as `application/octet-stream` (sent with curl and an `az account get-access-token` token, the token on stdin and not on the command line), linked by the full URL the response returns. GitLab: `POST /projects/:id/uploads` (multipart), using the `markdown` it returns. GitHub: the files are committed through the contents API to the `talos-evidence` branch at `pr-<n>/<sha8>/<name>` and linked as `https://github.com/<owner>/<repo>/blob/talos-evidence/pr-<n>/<sha8>/<name>?raw=true`. `qa-run` calls it when `verify.e2e_artifacts.*` is set.
- `bootstrap-board.sh` checks each configured state against the work item type, exits non-zero on a miss, never creates one.
- Approval gates: `pr-head <pr>` prints the PR's source commit sha, `read-comments <pr>` reads every thread comment (PR ids only, not work items), `check-approval-sha <pr> [--stale-list|--evidence-list]` reads the PR's labels and thread comments with the same trust rules as GitHub, and `post-approval <pr> <role>` posts the marker thread comment and adds the approval label, so `docs-gate` can stamp `docs:done`. `gitlab` has the same four verbs on MR ids.
- Attempt counting: `record-attempt <wi> <stage>`, `read-attempt <wi>` and `check-attempt <wi>` keep the same `<!-- talos:attempt ... -->` marker in work-item comments, with the trust rules and exit codes of GitHub, and `read-comments <wi> --work-item` reads every page of a work item's comments. A comment whose author has no `uniqueName` is never trusted (a display name is not an identity). `gitlab` has the same three verbs, reading the issue's notes, and `has-spec`.

### GitHub-only verbs

Attempt counting (`record-attempt`, `check-attempt`, `read-attempt`; also on Azure and GitLab), `upsert-pr-comment`, `mark-needs-owner` and `list-needs-owner` (also on Azure and, for merge requests, GitLab), `edit-pr-body` (also on GitLab and Azure; Azure refuses a body over 4000 characters, only `file` exits 2), `has-spec` (also on Azure and GitLab), `conflict-files` (also on GitLab and Azure), `attach-files` (on GitLab, Azure and GitHub). Other providers exit non-zero; `talos.sh next` then stops with `unsupported-verb:<verb>`.

### Provider parity

[`tests/test-vcs-provider-parity.sh`](../tests/test-vcs-provider-parity.sh) collects the verbs the stage prompts and scripts call and fails when a provider lacks one that has no recorded `PARITY-EXCEPTION` (in its exceptions table, or on the provider's case arm), or when a recorded exception is stale (the provider now handles the verb, or nothing calls it). Every called verb not listed here is supported by all four providers; `github-api` is `github`.

| Verb | `github` / `github-api` | `gitlab` | `azure` | `file` |
|---|---|---|---|---|
| `edit-pr-body` | yes | yes | yes (refuses a body over 4000 characters) | exception: no PRs |
| `conflict-files` | yes | yes (fetches `refs/merge-requests/<iid>/head`) | yes (fetches the source branch) | exception: no PRs |
| `upsert-pr-comment` | yes | yes (merge requests) | yes | exception: no PRs |
| `attach-files` | yes (commits to the `talos-evidence` branch) | yes (project uploads) | yes (PR attachments) | exception: no PRs |
| `mark-needs-owner` | yes | yes (merge requests) | yes | exception: local-only |
| `list-needs-owner` | yes | yes (merge requests) | yes | exception: local-only |
| `record-attempt`, `read-attempt` | yes | yes | yes | exception: local-only (no comments) |
| `read-comments` | yes | yes | yes | exception: local-only (no comments) |
| `assign-issue` | yes | yes | yes | exception: local-only |
| `assign-pr` | yes | yes (merge requests) | yes (no-op: a pull request has no assignee, its creator is the account user) | exception: local-only |
| `comment-pr`, `pr-head`, `pr-head-ref`, `check-approval-sha` | yes | yes | yes | exception: no PRs |

The file provider supports `list-issues`, `view-issue`, `comment-issue` and `close-issue`.

`diff-pr --stat` is a flag, not a verb, so the test cannot see it. It is supported on `github`, `github-api`, `gitlab` (counted from the merge request's diffs) and `azure` (from `git diff --numstat origin/<target>...origin/<source>`), with one output shape; without it every provider prints the full diff. No provider has a `--files` flag (`pr-files` lists the paths).

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
| `pipeline:epic-decomposed`, `pipeline:epic-children-done` | orchestrator | Epic split: the parent is an index no stage is dispatched onto, and the sweep closes it once its sub-issues are closed and its own `- [ ]` boxes are ticked / all sub-issues closed with boxes still unticked: a human reviews the epic |
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

Talos sets `In progress` (validator confirmed), `In review` (PR opened), `Blocked` and `Done` (merged). `create-issue` also sets `Ready` for a `pipeline:ready` issue. `bootstrap-board.sh` creates all five options. The `gh` transport checks the four it sets (after `status_map`) on a run's first call; the token transport checks only the option it is about to set.

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
- `pipeline-vcs.sh comment-issue <n> | comment-pr <n>`: post a comment. A stage writes its body to `.talos/<role>-*.body` or passes `--body-file -` with a heredoc on stdin; a `--body-file` or stdin body is never read as a path. A positional or `--body` body that is one whitespace-free token naming a readable file (bare, relative or absolute) is refused with "use `--body-file`", so a path is never posted as the comment; any other text is posted as written.
- `talos.sh state --summary`: in flight, waiting, next, other operators' items.
- `talos.sh map`: the project map (below).

### Project map

`talos.sh map` writes `${TALOS_HOME:-~/.talos}/maps/<owner>-<name>.html`, one self-contained HTML page for the repository (no script, no external asset, light and dark, phone width), and `maps/index.html`, which links every repository rendered under that `TALOS_HOME` with its one-line state (`maps/index.json` is its registry). It prints `map=<path>` and `index=<path>`. `talos.sh run` refreshes it after every stage and once at its end, after the run has released its leases; the first failure is `warn reason=map-failed` and the run goes on without the map (one warn per run, so an unwritable `TALOS_HOME` is not one per stage). `map.enabled` (default true) set to `false` turns the run's snapshot and renders off: a run writes no `state.json`, page or index and prints no map warn. The explicit `talos.sh map` command still renders when the key is false. A GitLab page is named by the remote's whole path (`<group>-<subgroup>-<name>.html`) and an Azure DevOps page by `<organisation>-<project>-<repository>.html`; a page keeps the name it was first given, and a repository whose name would equal another's (`a-b/c` and `a/b-c`) gets a short hash of its path added.

It is rendered by code from local records only, with no network or provider call and no tokens, so it is the same whichever runner or harness ran the stages:

- the events log (the stage dots, verdicts, PR numbers, blocked summaries, tokens, the changes since the run started). A relative `events.path` that leaves the git common dir is not read, as it is never written;
- the state snapshot `talos.sh run` writes to `<git common dir>/talos/state.json` each time it reads the state for a pass (queued and in-flight issues, PR stages, blocked items, owner questions, priority, whether the run is going, its end line). It also keeps the priority tier of every issue a read has named, so a merged issue is still counted in its tier. The snapshot keeps that read until the next one, so the page drawn after a stage shows the queue as the pass read it (the header says as of when), and an issue with events since then is judged by them. Stuck means waiting on a person: an unanswered owner question (the card quotes it), a stage that ended `BLOCKED:`, a gate's block or an exhausted attempt ceiling (from the collect). An issue in a fix round (a failing QA, review or security verdict, or a stage started after one) is in progress, with its round number. The snapshot's `run` entry records the run's pid: an entry whose pid is dead, or that nothing has written for 6 hours, shows as an ended run. Without a state read (a repository driven only by the LLM loop, before the first run, or a run that ended before it read the state) the page shows what the events log knows and says so;
- the issue-title cache `pipeline-meta.sh` keeps; an issue with no cached title shows as `#<n>`.

Sections: the header (updated at, the run, merged / in flight / stuck / not started), the track (priority tiers p0, p1, p2 and unlabelled; the current one is the highest with work left), one card per issue in flight, queued, stuck or merged in the last 7 days, the next step (`pipeline-next.py where` over the snapshot), the owner questions, the changes since the last run started, and the spend. Links follow `vcs.provider`: GitHub `/issues/N` and `/pull/N` on the remote's host (`github.com` with no remote), GitLab `/-/issues/N` and `/-/merge_requests/N`, Azure DevOps `<org>/<project>/_workitems/edit/N` and `<org>/<project>/_git/<repository>/pullrequest/N` (from `vcs.azure.org_url`, `vcs.azure.project` and `vcs.repo`, else from the remote, https or ssh). Every value from a record is HTML-escaped.

## Isolation, locking and multi-user claims

### Isolation modes

`execution.isolation` picks the working copy each stage runs in. `pipeline-isolation.sh validate` checks it at startup and exits 1 on a bad value.

| Value | Behaviour |
|---|---|
| `worktree` (default) | The LLM loop gives each stage and issue its own git worktree; allows `issues.max_parallel` above 1. `talos.sh run` creates none for these: it runs the developer, QA, reviewer and security in the driver's own checkout and docs in a `pr-worktree` (below) |
| `branch` | Stages run in the orchestrator's own checkout on a per-issue branch; `issues.max_parallel` above 1 is refused at startup |
| `checkout` | Recognised, refused as not implemented; any other value is refused too |

Only the LLM loop runs `pipeline-vcs.sh assert-sync` (in `branch` mode, before each developer dispatch, and before reviewer and security); `talos.sh run` never calls it. A dirty tree (untracked files count) or a checkout that diverged from `origin/<base_branch>` stops the issue, so commit files such as `AGENTS.md` first. Use `branch` when worktrees break the build: submodules, ignored-but-required artifacts (`node_modules/`), absolute paths into the main checkout, or a monorepo too big to copy per issue.

### Worktree lifecycle and cleanup

Under `talos.sh run` the developer, QA, reviewer and security run in the driver's own checkout (the developer creates `fix|feat/issue-<N>-<slug>` there; QA's `qa-run` checks out the PR) and docs in a `pr-worktree`; no `agent-*` worktree is created. On the LLM loop the developer worktree is `fix|feat/issue-<N>-<slug>` and QA, reviewer, security and docs run in a Claude Code `agent-*` worktree under `.claude/worktrees` with no issue number in its name, so each stage's first verb (`pipeline-criteria.sh qa-run`, `post-approval --issue <N>`) writes `<worktree>/.talos/env` to tag it. `.talos/` is hidden through `.git/info/exclude`. The QA prompt names its checkout on the `Worktree path:` line: `talos.sh prompt qa --worktree <dir>` (an absolute path of an existing directory, else `stop reason=usage`, exit 2) renders `<dir>`, and without the flag the line reads `your working directory (git rev-parse --show-toplevel)`. `talos.sh run` passes its own checkout on every QA dispatch. The docs prompt has the same line: `talos.sh run` runs docs in a worktree of the PR's head branch (`pr-worktree`, below), never in its own checkout, and passes that path.

- `pipeline-worktree.sh pr-worktree <N> <M>` runs before each docs dispatch of `talos.sh run` and prints the path of a worktree on PR M's head branch. A worktree that already holds the branch (the developer's, or the current checkout) is used as it is. Otherwise one is created at `.claude/worktrees/<branch, "/" as "-">` from `origin/<branch>` (fetched first) and tagged for issue N (`.talos/env`), so `remove <N>` deletes it after the merge; `.claude/worktrees/` goes into `.git/info/exclude` when git does not already ignore it. It exits 1 and leaves nothing behind when the head branch cannot be read, origin does not have it, the path exists without that branch, or the local branch has diverged from origin's: the run ends with `stop reason=worktree-unavailable role=docs`.
- `pipeline-worktree.sh to-base <N>` runs after a merge (`talos.sh post-merge`, before `remove`). A checkout left on `fix|feat/issue-<N>-...` with no change to a tracked file is switched to the base branch (`base_branch`, else the default branch), fast-forwarded with `git pull --ff-only`, and the issue branch is deleted: `talos:checkout state=returned`. A detached HEAD is returned to the base branch the same way (since #644). On the base branch it only fast-forwards (`synced`); on any other branch it does nothing (`kept`). It never forces: `state=failed reason=dirty|switch-failed|pull-failed` leaves the rest as it is.
- `pipeline-worktree.sh remove <N>` runs after a merge (`talos.sh post-merge`). It removes every worktree of issue N, their local branches and the handoff file, but keeps one with uncommitted or unpushed work and says why.
- `pipeline-worktree.sh sweep [<id>...]` runs at the start (`talos.sh sweep`, with the run's queue ids) and end (`talos.sh summary`, with those ids plus the issue of every open PR) of a `/talos:pipeline` session; a bare `talos.sh run` calls neither. It removes every other worktree, dirty or not, including any it cannot identify; with no ids that is all of them. It never removes the current checkout or a lane home. It also deletes local `fix|feat/issue-<N>-*` branches that head no open PR (skipped if the PR list is unreadable) and are merged: the tip is reachable from a remote ref, or `find-pr <N> merged` returns that branch with a head commit (`headRefOid`) equal to the local tip. A squash-merged branch is deleted only then: a failed lookup, an unavailable head commit or later local commits keep it. Any other local branch, pushed or not, is left alone. It then prints `talos:worktree-sweep removed=<n> kept=<n> freed=<size> branches_deleted=<n>`, followed by ` branches=<a>,<b>` when n>0.
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
| `issues.assignee` | `self` | Who `create-issue`, the move to `In progress` and `assign-pr` (a PR or MR Talos opens or resumes) assign: `self`, a login, or `none`. An existing assignee is never overwritten |
| `identity.name` | unset | The login you claim under; what `self` means when set |

Identity, resolved once per run: `issues.assignee` when it names a login, else `identity.name`, else the authenticated login (`current-user`). Claiming is off when `issues.claim` is false, `issues.assignee` is `none` or empty, or no login resolves (an Actions token, file mode). Set `identity.name` where the authenticated name is not assignable, such as an Azure DevOps UPN. Keep `self` in a shared config; a fixed login makes everyone claim as that person.

**Claim.** Before the first stage on an issue with no assignee, `talos.sh next` assigns it to you and reads the assignees back. If another login landed at once, the lowest login (case-insensitive) keeps it; the others run `unassign-issue` and move to the next issue. GitHub and GitLab hold several assignees, so both writes land and the read-back settles it; Azure DevOps holds one, so the later write wins. Talos releases a claim only when it loses that tie; a blocked issue stays yours until a human unassigns it.

**What others see.** `collect`, `state`, `next` and `run` act only on issues assigned to you or to nobody, and on pipeline PRs of such issues; an issue you hold stays yours if someone is added. Another operator's issues and PRs are never routed: `talos.sh state --summary` lists them as `theirs: #N (@login)` and `next --issue N` answers `wait reason=theirs`.

`bash scripts/talos.sh claim <N>` claims one issue and prints `claim=taken|owned owner=<me>`, `claim=lost owner=<login>`, `claim=unclaimed reason=not-assignable` (the assignment did not land, nobody holds it) or `claim=off reason=<disabled|assignee-none|identity-unresolved>`. The lease ledger separates two sessions of one user; the assignee separates users.

## Gates: verify, QA, CI and merge

`talos.sh gate merge <PR> <N>` runs every merge gate in this order and answers one verdict; it never merges itself (on `merge`, run `pipeline-vcs.sh merge-pr`).

| # | Gate | Fails as |
|---|---|---|
| 1 | No `pipeline:blocked`; every enabled role's approval label present (a human's `skip-qa` waives only this; a [lost stamp](#approvals-bound-to-the-head-sha) is put back first) | `wait` |
| 2 | `check-approval-sha`: approvals match the head SHA | `redispatch` |
| 3 | `check-pr-files`: forbidden files (`skip-qa` never waives) | `block` |
| 4 | `check-closing-keyword`: closing keyword while sibling PRs are open (`block`); a check that could not look (`talos:closing-keyword-unverified`, `reason=closing-keyword-unverified`: a failed sibling or PR fetch, an unresolved repo, a failed keyword scan) waits and is re-checked next run, with no label and no comment; `siblings-capped` blocks | `block` / `wait` |
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
| `verify.targeted_commands` | none | How to run one test file of a stack Talos does not know, and how to read its result lines. A list of `{ "match", "run", "pass", "fail" }` objects, first match wins; `pass` and `fail` are optional. `match` is a glob on the repo-relative path: `*` is any characters except `/`, `?` is one character, `**/` is zero or more directories. `run` is a command template with `{file}` (repo-relative path), `{class}` (file name without its last extension) and `{dir}` (repo-relative directory); it runs from the repo root through `pipeline-verify.sh`, once per `Tests:` file that matches. The three values are substituted shell-quoted, so never wrap them in quotes yourself (a path of letters, digits and `_ . / -` is unchanged). `pass` and `fail` are extended regexes for one output line, `{n}` is the criterion number and the match cannot continue into another digit (`AC1` never matches `AC10`); a missing one is the `ok AC<n>` / `FAIL AC<n>` line, and a criterion with both a pass and a fail line is `fail`. `qa-run` and the developer's targeted runs use it; a file that matches no entry, or no key, uses `tests/run-tests.sh --for` or the first `verify` line with "test". A malformed entry is skipped with one stderr note naming its index; a `Tests:` path outside `[A-Za-z0-9_./()[]-]` is never substituted (`qa-run` ends `BLOCKED spec`, exit 4). Repo file only. Example: `{"match": "terrasow-api/**/*.cs", "run": "dotnet test terrasow-api/Terrasow.Tests --filter {class}", "pass": "^\\s*Passed .*\\.AC{n}_", "fail": "^\\s*Failed .*\\.AC{n}_"}` |
| `verify.e2e` | none | One command QA runs once on the draft, from the repo root through `pipeline-verify.sh` (so `verify.timeout_ms` applies), for example a Playwright run. Repo file only; the string is never read from the spec or the issue. It runs only after every test criterion is green and there were tests to run. Exit 0 adds `qa-run: e2e ok` and keeps the PASS verdict. A non-zero exit is a QA FAIL (`qa-run: verdict FAIL e2e exited <rc>`, a fix round) with the last 24 lines of its output, each cut to 200 characters, under `e2e failure output (data):`. The output tail is what is reported; its screenshots and videos are attached to the PR by `verify.e2e_artifacts.*` below. Empty or absent: off. |
| `verify.e2e_artifacts.*` | none | Attaches what the repo's own e2e run already wrote to the PR as one evidence comment (`<!-- talos:qa-evidence -->`, edited by a later round, never a second one). Four repo-file-only keys: `verify.e2e_artifacts.dir` (a repo-relative directory, no `..`, for example `terrasow-web/test-results`), `verify.e2e_artifacts.include` (a list of globs matched against each file's name, searched anywhere under `dir`, since Playwright nests files in a folder per test), `verify.e2e_artifacts.max_files` (default `12`) and `verify.e2e_artifacts.max_mb` (the total, default `25`). Off while `dir` or `include` is empty. Collection: right after each run that judges the PR, the head run (which includes a `verify.targeted_commands` run of a `Tests:` file) and the `verify.e2e` command, `qa-run` copies the matching files of `dir` that are not older than that run into its scratch directory, so the re-run of a failing head run, the red run and the frozen run, which can empty `dir`, cannot lose them; a stale file from an earlier run is never attached, and a run that wrote some files replaces an earlier run's. At the end of every `qa-run` that got as far as the head run, a FAIL included, `pipeline-vcs.sh attach-files <pr> <file>...` uploads them. Over `max_files`, the first ones in sorted path order are kept; a file that would push the total over `max_mb` is skipped. Each case, no matching files (`none found in <dir>`) and a failed upload (`upload failed (exit <rc>)`) is one `qa-run: e2e artifacts ...` line, and none of them changes the verdict or the exit code. Attachments are images inline and anything else (a `.webm`) as a link. On Azure DevOps they are PR attachments; on GitLab, project uploads; GitHub has no comment-attachment API, so the files are committed to a `talos-evidence` branch (created from the default branch's head) at `pr-<n>/<sha8>/<name>` and linked with `?raw=true`. |
| `verify.ready` | none | Shell commands `qa-run` runs in order, one at a time, from the repo root through `pipeline-verify.sh` (so `verify.timeout_ms` applies), before every run of the `Tests:` files: the head run, the flaky re-run, the red run (after the checkout of the red commit) and the frozen run. Use it to make the environment fit to test, for example to restart or reload the dev server and wait until it answers, so a checkout that restarts the app does not fail the criterion. Repo file only; the commands are never read from the spec or the issue, and Talos does not retry them. The first one to exit non-zero ends the run as `qa-run: verdict BLOCKED environment: <cmd> exited <N>` ([Criteria first](#criteria-first)). Empty or absent: nothing runs. |
| `verify.qa_mode` | derived | `ci` when `merge.required_checks` is non-empty, else `local`. Explicit `ci` with no required checks becomes `local` (stderr warning). Repo file only. |
| `verify.ci_wait_s` | `900` | CI wait budget, 1 to 86400 s |
| `verify.ci_requeue_stuck` | `true` | Azure only. `pr-checks-required` requeues a Build policy evaluation that is `queued` with no build attached, once per PR, evaluation and source commit, then reports it `stuck` (exit 1) on the next read so the driver stops waiting. `false`: a stuck evaluation stays plain pending. |
| `verify.timeout_ms` | `600000` | Foreground timeout for each verify and CI-wait call, 1 to 86400000. The claude harness stops a foreground command at 600000 ms, so under the claude runner the stage prompts state `min(verify.timeout_ms, 600000)` and `talos.sh prompt` warns on stderr when the configured value is over the cap; other runners get it unchanged. A suite that needs longer goes in several `verify.commands` (for example `bash tests/run-tests.sh --quiet --shard 1/4` to `4/4`) or `qa_mode: ci`. Shards are balanced on `tests/timings.txt`, so a new `tests/test-*.sh` needs an entry there (`bash tests/update-timings.sh`); `tests/test-shard-weights.sh` fails without one |

- Verify runs in the foreground only, through `scripts/pipeline-verify.sh [--issue N] [--worktree P] [-- cmd]`, which exports the stage identity and prints `talos:verify issue=.. worktree=..`.
- QA never runs the full list, except under `pr.ready_gate: qa-local` while the PR is a draft ([Draft PRs](#draft-prs)). `scripts/pipeline-criteria.sh qa-run` runs the spec's test files; other targeted runs use `tests/run-tests.sh --for <path> --strict` (Talos's own runner; exit 3 means no test selected and QA relies on CI). Reviewer, security and docs never run verify.
- Under `ci`, one `pr-checks-required <pr> --wait <B>` waits for CI, `B = min(verify.ci_wait_s, verify.timeout_ms/1000 - 30)`, at most 3600. `next` does not check mergeability, so QA is dispatched into a `CONFLICTING` PR and `qa-run` refuses to run anything there; red required CI re-dispatches the developer instead.

### Required checks

`merge.required_checks` (repo file only) lists check names as the provider reports them (GitHub check-run or status names; Azure policy display names, case-insensitive; GitLab job names of the MR's head pipeline). `pipeline-vcs.sh pr-checks-required <pr> [--wait <s>]` reads only those:

| Exit | Meaning |
|---|---|
| 0 | all passed on the current head |
| 2 | pending or missing (a skipped check is pending, never a pass) |
| 1 | one failed (`pr-checks-required: failed:` on stderr), or the list is empty (never a vacuous pass) |

`--wait` takes digits, at most 3600 (else exit 2). On `github` and `github-api` it polls inside the call at 30 s, 60 s, then 120 s steps; other providers answer once.

On `gitlab` the verb judges the MR's head pipeline (`head_pipeline` of the MR read). An empty `merge.required_checks` is not a refusal: the pipeline's own status stands in (`success` passes; `failed`, `canceled`, `canceling` and an unknown status fail; `created`, `waiting_for_resource`, `preparing`, `pending`, `running`, `scheduled`, `manual` and `skipped` are pending, so a skipped or manual pipeline never passes). With names, each is matched exactly against the pipeline's jobs (every page), and of several jobs with one name (a retry) the highest job id decides; the pipeline's own status is not consulted, and jobs that are not named are ignored. An MR with no head pipeline, or whose head pipeline is for another commit than the MR's `sha`, is pending (exit 2). A failed read or unparseable JSON exits 1.

On `azure` an empty `merge.required_checks` is not a refusal: the verb judges the PR's blocking policy evaluations (`isBlocking` true) instead, with the same exits (`approved` and `notApplicable` pass, `rejected` and `broken` fail, `queued` and `running` are pending). Non-blocking policies are ignored, and a PR with no blocking evaluation is pending (exit 2), never a pass. A policy-only project needs no `merge.required_checks` for this verb.

### Draft PRs

`pr.draft` opens the PR as a draft so docs, review and fixes start no CI. Order: developer (local verify, draft PR), docs, reviewer, security, adversarial (one stage at a time under `talos.sh run`; in parallel only on the LLM loop), one fix round, re-stamps, `ready-pr` (the one CI run), QA, merge. A QA or CI failure runs `draft-pr` first, so a fix costs one run. QA and the CI wait start only when `pr-is-draft` exits 1 with stdout `ready`; `gate merge` reports `ci_runs` (`pr-ci-runs`, GitHub only). When the run marks the PR ready and `qa:pass` is already fresh at the head (after a local QA recovery, say), it skips QA and the CI wait and the next pass goes to `ci` / `merge`; a missing, stale or unreadable `qa:pass` dispatches QA.

**QA pre-CI gate.** `pr.ready_gate: qa-local` (default `off`, which is the flow above, unchanged) makes QA the last stage of the draft window: docs, reviewer, security (+ adversarial), then QA on the draft, then `ready-pr`. QA checks out the PR head, runs the `qa-run` criteria and the full `verify:` list once through `pipeline-verify.sh` (the suite CI would run), never waits for CI, and `post-approval` stamps the head SHA it verified. Only a PASS fires `ready-pr`, so the one CI run is never spent on a head QA rejects; a FAIL runs the normal fix round on the still-draft PR (no `draft-pr`, no CI was ever spent) and QA runs again on the new head. CI stays the merge authority: `gate merge` is unchanged and still needs `pr-checks-required` green on the final head. After `ready-pr` no QA is dispatched and nothing waits inside a QA stage; the next pass is the ordinary `ci` / `merge` stage.

The gate applies only while `pr.draft` resolves true and `roles.qa` is on (`pipeline-draft-check.sh ready-gate` prints the effective value, `talos.sh env` as `READY_GATE`); otherwise it reads `off` with one stderr line. An unknown value reads `off` with a warning. A ready PR without `qa:pass` (a human marked it ready) gets QA after ready as before.

Costs and limits. QA-local cannot guarantee CI green: CI runs on ubuntu while a local run is often macOS (#329), so it only avoids spending the run on a locally red head. The full `verify:` list costs one more suite run per PR, bounded by `verify.timeout_ms`, and QA now runs before CI instead of alongside it: roughly 20 minutes more wall time per PR when everything is green.

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

An approval is a PR comment ending in `<!-- talos:approval sha=<40-hex head SHA> role=<role> -->` plus the role's label. `pipeline-vcs.sh post-approval <pr> <role> --body-file f [--issue n]` (`github`, `github-api` and `azure`) reads the head SHA itself, posts, labels and self-checks (`stamp ok`, or `stamp FAILED` and exit 1); it runs on `gitlab` too. `--body-file` is required for `reviewer` and `security` and optional for the other roles.

For `reviewer` and `security`, `post-approval` refuses (exit 1, nothing posted) when:
- there is no `--body-file`: `pipeline-vcs: post-approval: <role> approval requires --body-file with the review text`;
- the file is empty: `pipeline-vcs: post-approval: --body-file '<f>' is empty; the <role> review text is required`;
- the file is older than the stage's start: `pipeline-vcs: post-approval: --body-file '<f>' is stale (older than this <role> stage's start); write a fresh review for this PR`. The start is the record `talos.sh prompt` writes under the state dir, `stage-start/<role>-pr<N>`. With no record (manual use) there is no staleness check.

After a successful post the reviewer or security body file is removed; the qa and docs bodies are kept. `--recover-only` posts nothing and needs no body.

| Role | Label |
|---|---|
| `qa` | `qa:pass` |
| `reviewer` | `review:approved` |
| `security` | `security:approved` |
| `adversarial` (`roles.adversarial`) | `adversarial:approved` |
| `docs` | `docs:done` |

`check-approval-sha <pr> [--stale-list]` (`github`, `github-api` and `azure`) exits 1 when a present label has no valid marker or its SHA is not the head; `--stale-list` also prints `stale role=<role> label=<label> sha=<marker sha>` per stale role, without `sha=` when the marker gave no SHA that exists in the repository (match the line by its prefix). It runs on `gitlab` too.

**Lost stamps.** An approval label is a fact about one head SHA, read only through `check-approval-sha`. If a label disappears (a hand edit, label churn) while its marker still pins the PR's current head, the stamp is recovered, not re-earned.
- `check-approval-sha <pr> --evidence-list` prints `evidence role=<r> label=<l> state=present|lost|missing` per role. `lost` means the label is absent and the role's newest marker is the exact line `post-approval` writes for the current head; a hand-made marker with other spacing or trailing text is `missing`.
- `gate merge` re-applies each `lost` one through `post-approval <pr> <role> --recover-only`. That mode applies the label only when that exact marker exists at the current head; otherwise it exits 3 with nothing posted. The gate's answer then carries `recovered=<roles>`.
- A label with no such marker is never re-applied. The gate waits with `never_approved=<roles>` beside `missing=`, and the stage re-runs.
- A label in `missing=` whose role is not in `never_approved=` has evidence the gate could not use this time (the re-apply or the evidence read failed). No stage re-runs; the next `gate merge` tries again.
- `next` does not route a lost role as the PR's stage: for a PR that misses an enabled role's label it reads the evidence once, also when no approval label is left on the PR. That covers the draft window's QA gate (`pr.ready_gate`).
- A head change still strips the labels as stale (`reason=stale-approvals`): a stamp is never carried across a head change.

**Author trust.** `markers.verify_authors` (default `true`, repo file only) accepts markers only from the authenticated identity (`gh api user`) plus `markers.trusted_authors`. Rejects print `talos:marker-authors-rejected authors=..` on stderr. Identity unavailable and no `trusted_authors`: markers are accepted and `talos:marker-authors-unverified reader=<verb>` prints. Lookup refused (Actions `GITHUB_TOKEN`, GitHub App token): only `trusted_authors` counts and an empty list rejects all; set e.g. `["github-actions[bot]"]`. `false` skips the check silently.

### Stale approvals and the delta re-stamp

A new commit stales an approval unless every file changed since the marker SHA matches `merge.approval_waiver_paths` (default `*.md`, `docs/**`, `CHANGELOG.md`, `*.example`). Never waivable: `scripts/`, `tests/`, `agents/`, `skills/`, `templates/prompts/`, runner dot-directories (`.claude/{agents,skills,commands,talos,rules}`, `.agents`, `.gemini`, `.pi`, `.codex`), `.agent/`, `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md`, `GEMINI.md`, `REVIEW.md` and `VERIFY.md` at any depth, the paths named by `review.guide` and `verify.guide`, and the pipeline config files (`talos.pipeline.{yml,yaml,json}`, `.claude-pipeline.{yaml,json}`, `pipeline.{yaml,json}`); an entry that would waive them fails the gate.

`gate merge` strips stale labels, comments, answers `redispatch`. Under `talos.sh run` only docs gets `--shape restamp` (below); a stale qa, reviewer or security approval ends the run with `stop verdict=redispatch reason=stale-approvals` and the next run dispatches a full stage. On the LLM loop every role that already approved gets a re-stamp: same role and profile, `talos.sh prompt <role> --shape restamp`, header `**Agent:** <role> (talos) — re-stamp`, delta and targeted tests only. `RESTAMP_PASS` re-confirms through `post-approval`; `RESTAMP_FAIL` strips the label and the next round runs the full stage. Model: `agents.roles.<role>.restamp_model`, then `agents.restamp_model` (defaults to `agents.model`), else the role's normal model; `restamp_effort` follows the same chain. 

Docs is decided by `talos.sh docs-gate <pr> --issue <N>`. With `docs:done` on the PR and a stale docs line that carries `sha=<S>`, it takes the local `git diff <S>..<head>` and keeps the PR's docs-relevant paths (those matching `docs.paths`; default `README.md`, `docs/*`, `scripts/pipeline-defaults.sh`):

- none changed: it stamps `docs:done` again, runs `done docs` and prints `docs=skip reason=no-docs-delta`. No agent runs.
- some changed: `docs=dispatch reason=docs-delta shape=restamp restamp-file=<F>`. `<F>` holds `approved_sha=`, `head_sha=`, those paths and their diff. `talos.sh prompt docs --shape restamp --restamp-file <F>` renders a read-only pass: the agent edits and commits nothing, stamps an accurate delta and starts its final message with `RESTAMP_PASS: `, or stamps nothing and starts it with `RESTAMP_FAIL: ` and what is wrong or missing.

`docs-gate` stops with `stop reason=<r>` when it cannot decide:

| Reason | Meaning and fix |
|---|---|
| `usage` | Missing or unknown argument (exit 2). Pass `<pr> --issue <N>`. |
| `scripts-missing` | `talos.sh` could not read its scripts directory. Reinstall, then run again. |
| `python-missing` | `python3` is not on `PATH`. Install it and run again. |
| `scratch-unavailable` | A scratch file for the paths or the delta could not be written. Fix `TMPDIR` or free space, then run again. |
| `config-unreadable` | The pipeline config could not be read. Fix the file and run again. |
| `stamp-failed` | Deciding `docs=skip` but the `docs:done` stamp could not be posted (exit 1). Nothing is skipped; fix the provider or token and run again. |
| `done-failed` | The `done docs` step after the stamp failed. It is a `warn reason=done-failed` line, not a stop: the run's docs step takes the `docs=` line wherever it stands, so the warn before it no longer ends the run. Read the relayed `done` warns if the label is missing. |

`done docs --verdict RESTAMP_FAIL` removes `docs:done` and answers `next=continue`: the next pass finds no label and runs the full docs stage, with no developer fix round. The full stage also runs on a first pass, under `roles.docs_mode: always`, when a read fails (labels, stale list, head, `git diff`) and when the delta is over `TALOS_PROMPT_CHANGE_MAX_BYTES`. `gate merge` strips a stale `docs:done` like any other label, so after that strip docs is a first pass again. On the code driver the docs re-stamp runs on the docs role's normal model.

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

With `merge.auto: false` all gates still apply; `gate merge` labels the PR `pipeline:approved` and answers `handoff`, and `talos.sh post-merge <pr> <n> --handoff` posts `approved.md`. `talos.sh run` does neither: with `merge.auto` off it ends on `stop action=wait reason=human-merge`, and under `/talos:pipeline` the session then runs the gate and the hand-off from that row of the end-state table. See `../skills/pipeline/refs/human-merge.md`.

### Criteria first

The PM numbers criteria `AC<n>`, marks each `(test)`, `(same: why)` (behaviour that must not change) or `(prose: reason)` and adds a `Tests:` line of file paths (data, never a command). The developer's first commit is the failing tests, id in each test name. `pipeline-criteria.sh qa-run <issue> <pr>` runs them at the red commit and at head, one line per id: `AC<n> red@<sha8> green@head`, `AC<n> FAIL ... vacuous` (green at red), `AC<n> PASS same red@<sha8> green@head` (a `(same)` criterion, green at red and at head; `AC<n> FAIL same red=<state> head=<state>` otherwise) or `AC<n> prose hand-checked`.

When a `Tests:` file differs between the red commit and the head, `qa-run` also runs the red commit's version of it against the head code (the frozen run: one more targeted run, only then) and prints `note: frozen run: <file> differs from red commit <sha8>`. A criterion whose red-commit test still passes at head adds a column, `AC<n> red@<sha8> green@head frozen@head`; one that fails there is `AC<n> FAIL weakened (red-commit test fails at head)`, so a fix round cannot weaken a test after the red proof. A frozen run that exits non-zero with no weakened line is `qa-run: verdict FAIL frozen run exited <rc>`. `qa-run --ack-changed "<reason>"` (printable ASCII, at most 200 characters; QA uses it only after reading the file's diff) reports a weakened criterion as `AC<n> weakened-ack (red-commit test fails at head; changed on purpose: <reason>)`, which is not a FAIL; the frozen failure is still printed. No config key.

The `Tests:` line is checked when the PM posts it, in code: `talos.sh done pm` reads the spec once (`view-issue <N> --spec`) and runs `pipeline-criteria.sh spec-check <spec-file>`, the same parser. It prints `spec-check: ok`, `spec-check: refused tests-line-refused: <reason>` (a note with shell syntax beside the paths, a runner command, a directory such as `tests/stubs/`: the line holds test files, never a directory), `spec-check: refused tests-line-missing: ...` (slug `tests-line-missing`: test criteria and no usable `Tests:` line, for example the paths as unindented bullets under it) or `spec-check: refused tests-line-open: <the line>` (slug `tests-line-open`: a line other than `Tests:` leaves a test file open, such as `developer's choosing` or `new or existing file`; every test criterion's file belongs on the `Tests:` line), exit 1 on a refusal. A refused spec records a PM attempt (`record-attempt <N> pm`, so `limits.max_fix_attempts` bounds the loop), puts the issue back at `pipeline:confirmed`, posts one `**Spec check:**` comment with the reason (even with `comments.enabled: false`) and answers `spec_check=<slug>` and `next=fix-round stage=pm`: the next `next` dispatches the PM again, before any developer work. At the attempt ceiling the issue gets `pipeline:blocked` and the answer is `next=stop`. Nothing is checked for a PM that ended `BLOCKED` or an issue with no PM spec comment; a spec read that failed is `warn reason=spec-check-unread` and the run goes on, with QA's own check behind it.

The developer checks placement before opening the PR: `pipeline-criteria.sh placement <N>`, run from the PR worktree, reads the spec like `qa-run` and checks, as text only (no test runs), that each `(test)` criterion's id is the first word of an assertion label in a file on the `Tests:` line. It prints `placement: ok` (exit 0), or `AC<n> not-in-tests-files` for each missing id and then `placement: GAP <n>` (exit 1), or `placement: BLOCKED spec: <why>` (exit 4, the `spec-usable` reasons). On a gap the developer moves the test into a `Tests:` file.

`pipeline-criteria.sh red-check <N> [<ref>]` checks each criterion's kind against its state at the red commit, before any review stage. It takes the same red proof as `qa-run` (the first commit after the merge-base with the base branch, only when it is tests-only; the same runner, `Tests:` parse and `verify.targeted_commands`) in a throwaway detached worktree, so the caller's checkout, HEAD and branch are never touched; `<ref>` is the branch tip or SHA whose red commit is used (default `HEAD`; the driver passes the PR head). Findings come first, one per line, then one verdict line:

- `kind-mismatch AC<n> want=same`: a `(test)` criterion is `pass` at the red commit, so it is a regression guard. `kind-mismatch AC<n> want=test`: a `(same)` criterion is `fail` there. Only states the run printed count; a `missing` state (no per-id output) is no finding, and `(prose)` is never checked.
- `id-collision AC<n> file=<f>`: pure text, no run. `<f>` is a `Tests:` file that already exists at the merge-base and has `AC<n>` as the first word of an assertion label there (the id belongs to an earlier issue), or `AC<n>` is a label in two `Tests:` files at the red commit (one line per file). The fix is for the PM to name one new file for the criteria tests. A collision between exactly two `Tests:` files, one that exists at the merge-base and one the branch adds, is not a stop: it is the `drop-file` case below. Both files new, both on the base, a lone pre-existing file, or three or more files stay an `id-collision`.
- `drop-file <f> reason=id-collision-with-<g>`: `<f>` exists at the merge-base and shares an id with `<g>`, a file the branch adds. `<f>` is left out of the red run, so its results reach no `kind-mismatch` check. `to-prose AC<n> file=<f>`: a `(test)`/`(same)` criterion labelled at the red commit in a dropped file and in no kept file. No `drop-file` line is printed when any collision remains.
- `red-check: ok` (exit 0); `red-check: MISMATCH <k>` (exit 1, kind-mismatch lines only); `red-check: REVISE <k>` (exit 1; `k` counts the kind-mismatch, `drop-file` and `to-prose` lines, with at least one `drop-file`); `red-check: COLLISION <k>` (exit 4; wins over a mismatch, whose lines are still printed, and over a droppable collision); `red-check: skipped <why>` (exit 0, no test run: no `Tests:` line or no test criteria, no red commit, the red commit is not tests-only, or no test file exists there); `red-check: BLOCKED spec: <why>` (exit 4, the `spec-usable` reasons). A non-numeric issue is usage (exit 2); no usable runner is exit 3.

`talos.sh run` calls it once per PR, right after the first-round developer opens the PR and before reviewer and security (a developer fix round does not). On `MISMATCH` the driver posts a new `**PM spec:**` comment (built by `pipeline-criteria.sh revise-spec <N>` from the findings, body in a file) whose first line reads `**PM spec:** revised by the driver after red-check: AC2 is (same) (green at the red commit), AC10 is (test) (red at the red commit)`; on those criteria's lines only the final kind marker changes (`(test)` becomes `(same: green at the red commit, found by red-check)`, `(same...)` becomes `(test)`), every other byte is unchanged, `spec-usable` is asked again and the run continues to reviewer. On `REVISE` it does the same and also moves each dropped file from the `Tests:` line (a backtick span, or its bullet) to a `**Regression:**` line right after it, rewrites each `to-prose` criterion's final marker to `(prose: <f> must pass at head)`, and names the file and why in the lead note. `qa-run` reads the `**Regression:**` line with the `Tests:` path parse (a missing file counts like a missing Tests file) and runs those files whole at the head, apart from the Tests run: a non-zero exit is `verdict FAIL regression run exited <N>`, and a pass maps no id to any criterion. On `COLLISION` it blocks the PR and the issue and stops `spec-unusable detail=id-collision` ([A run stops](#a-run-stops)); any other exit is relayed and the run continues.

When the head run exits non-zero, `qa-run` runs the same present `Tests:` files once more at the head, before the red run (the whole set: the combined output has no id-to-file map). A `test` or `same` criterion that failed at the head and passed on that re-run is flaky: `AC<n> FAIL flaky (failed at head, passed on re-run)`, and the verdict reads `qa-run: verdict FAIL <n> test criteria FAIL (<k> flaky)`. A flaky failure is noise or a race, not a finding the developer can fix, and a fix round would only teach the agent to retry, so it goes to the owner: when every `AC<n> FAIL` line is flaky the run puts `pipeline:blocked` on the PR and the issue, relays the lines and stops `qa-flaky` (exit 0), with no attempt recorded and no fix round. Flaky lines beside any other FAIL line go to the fix round as before. A criterion that fails in both runs keeps its `head=fail` line. There is one re-run only; the red and frozen runs are not re-run. The owner fixes or removes the flaky test, then removes `pipeline:blocked`.

A broken environment is not a failing change (`verify.ready`). When it is set, `qa-run` runs its commands before every run of the `Tests:` files, so a checkout that restarted the app does not fail the e2e criterion. The first command to exit non-zero ends the run: `qa-run: verdict BLOCKED environment: <cmd> exited <N>` (exit 5, `<cmd>` cut to 120 characters), then `environment failure output (data):` and the last 30 lines of its output (200 characters each). No `AC<n>` line is printed, no `Tests:` file runs and HEAD is back on the PR head. `TALOS_QA_RESULTS` starts `BLOCKED environment: <cmd> exited <N>`; when `qa-run.<pr>` starts so, the run puts `pipeline:blocked` on the PR and the issue, relays the lines and stops `environment` (exit 0), with no gate, no attempt and no developer round: the code is unchanged, so a round cannot help. QA ends its message `BLOCKED: environment: <why>` and the run stops the same way. Output-based detection (a setup step that fails inside a test run) is not done; only a failing `verify.ready` command is an environment fault.

A FAIL or BLOCKED verdict keeps the raw output of its runs: `head.out`, `rerun.out`, `red.out` and `frozen.out` (those that ran) are copied to `<repo root>/.talos/qa-run-<pr>/`, replaced each run, and `qa-run: raw output kept in <path>` is printed before the verdict line. A PASS leaves no such directory. When `verify.targeted_commands` loaded entries, `qa-run: targeted_commands from <path>` names the config file that set them.

A `(test)` criterion that is green at the red commit and at the head (`vacuous`) is a regression guard, not a spec fault, when at least one other `(test)` criterion went red then green (`AC<n> red@<sha8> green@head`) and no other FAIL line exists (`head=`, `same`, `flaky`, `weakened`): `qa-run` reports it as `AC<n> guard green@head (green at red@<sha8>)`, which is not a `FAIL` line, so the verdict is decided by the other criteria, the run does not stop and the PM spec is not rewritten. The QA comment lists the guard lines. A vacuous criterion beside any other FAIL line, or when no criterion went red then green, keeps `AC<n> FAIL vacuous (green at red@<sha8>)`, and a criterion that fails at the head is `head=fail`, never a guard.

A spec QA cannot use is a fault of the spec, not of the PR. `qa-run` then ends with `qa-run: verdict BLOCKED spec: <why>` (exit 4) and runs no test; `<why>` is `unreadable for issue #<N>`, `no criteria checklist`, `Tests: line refused (<reason>)` or `<n> test criteria and no Tests: line`. QA answers `BLOCKED: spec: <why>`, and `pipeline-criteria.sh spec-usable <issue>` makes the same check alone (`spec-usable: ok`, or `spec-usable: BLOCKED spec: <why>` with exit 4; no git command, no test). The driver reads the per-criterion results from `qa-run`'s own output, never from QA's final message: `talos.sh run` sets `TALOS_QA_RESULTS` for the QA stage, `qa-run` writes its `AC<n> ...` lines to that file in the run's scratch, and with no file or an empty one the ordinary fix round runs. `talos.sh run` asks it after every QA `FAIL`, so a spec fault never starts a developer fix round: see `spec-unusable` under [A run stops](#a-run-stops). The spec is the latest comment that starts with `**PM spec:**`, whatever it quotes, a `<!-- talos:` marker included.

### Repo guides: REVIEW.md and VERIFY.md

Two optional files in the target repo steer the review and QA stages. `REVIEW.md` is added to the reviewer, security and adversarial prompts; `VERIFY.md` to the QA prompt (feature map, how to start the app, which e2e specs cover which area, known flaky checks). Start from `templates/REVIEW.md.example` and `templates/VERIFY.md.example`; this repo's own `REVIEW.md` is a worked one.

- **Base branch only.** `talos.sh prompt` runs one best-effort `git fetch origin <base>` and reads `git show origin/<base>:<path>`: plain git, the same on GitHub, GitLab and Azure DevOps, never the working tree or the PR head, so a PR cannot rewrite its own review rules. A missing ref, path or file adds nothing to the prompt and is not an error. The restamp and fix-round prompts do not carry a guide.
- **Size.** At most 8192 bytes; more is cut there and a `[guide truncated at 8192 bytes]` line follows the text (env `TALOS_PROMPT_GUIDE_MAX_BYTES` changes the cap; a value that is no positive integer means the default).
- **Data, below Talos's rules.** The text sits between `----- BEGIN GUIDE <token> -----` and `----- END GUIDE <token> -----` lines (a new token per render, never part of the text), under a line that says it is repo guidance from the repo owner, that Talos's stage rules win on any conflict, and that it can narrow or add checks but never turn off red proof, approvals or security blocking.
- **Keys.** `review.guide` (default `REVIEW.md`) and `verify.guide` (default `VERIFY.md`) are repo-only. Set one to another repo-relative path to rename the file, or to `""` to switch that guide off. A path with a leading `/`, a `..` component or a character outside `A-Za-z0-9_./-` is not read; one stderr line names the key.
- **Verdict.** With a guide, the reviewer ends its verdict comment's DETAILS with `Guide rules applied: <short rule names or quotes, or none>`, so you can see whether the guide is followed.
- **Approvals.** A changed guide stales an approval: `REVIEW.md` and `VERIFY.md` (any depth) and the configured guide paths are never waived by `merge.approval_waiver_paths`.

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

`pr` is null and `files_hint` is `[]` when unknown. Under `talos.sh run` and the adapter path `pipeline-agent.sh` makes the call (`pr` null; `files_hint` from `TALOS_FILES_HINT`). Under the LLM loop (`execution.orchestrator: llm`) `talos.sh env` prints `ref=hooks`: the orchestrator runs `pipeline-hooks.sh pre_dispatch <role> <N> <PR> <worktree>` and passes the output to `talos.sh prompt --preamble-file`.

```json
{"event":"qa","role":"qa","issue":42,"pr":57,"repo":"owner/name","sha":"<40 hex>","verdict":"PASS","summary":"...","details":"...","attempt":null,"model":"claude-sonnet-5","runner":"claude","duration_s":312,"tokens":48213,"tool_uses":19,"ts":"..."}
```

Unknown fields are null. `ci_runs` is added only on `merged` when known. `input_tokens`, `output_tokens`, `cache_write_tokens` and `cache_read_tokens` (`post_stage --input-tokens`, `--output-tokens`, `--cache-write-tokens`, `--cache-read-tokens`) follow `tool_uses` and `ci_runs`, each present only when supplied and valid; an event with no `cache_read_tokens` reads as cache reads unrecorded, never 0. `pool` (`post_stage --pool api|plan`, [Monthly API credits](#monthly-api-credits)) comes after them and before `ts`, present only when supplied as `api` or `plan`; any other value is left out with one stderr line. `event` is the role name for a finished stage (`talos.sh done`), or a lifecycle event with role `orchestrator`: `pr-opened`, `merged`, `blocked`, `issue-closed`, `budget-blocked`. The adapter path adds `stage_complete` (PASS or FAIL from the exit code), `stage_attempt` (a failed attempt before failover) and `failover`.

### The events log

Every `post_stage` payload is also appended as one JSON line to `<git common dir>/talos/events.jsonl`, whether or not `hooks.post_stage` is set. `events.enabled` (default true) turns it off; `events.path` is relative to the git common dir. It is shared by all worktrees and never inside a git tree. A relative path that leaves the common dir is refused. Appends are single writes, so parallel stages never interleave lines; a write failure is a stderr note only.

`talos.sh prompt` also appends a `stage_start` line (role `orchestrator`, field `stage`) per dispatched stage. It runs no hook and no cost view counts it.

`talos.sh run` appends one `run_end` line when it ends, from its exit hook: the stop line as printed, parsed. Role `orchestrator`, plus `ts`, `issue` (the stop line's `issue=`, else the run's `--issue` target, else null), `pr`, `repo`, `verdict`, `reason` and `detail` (the same words of the stop line, null when absent), `stage` (the stop line's `role=`) and `line` (the stop line). A run that continues after a merge writes none; only its final image does, and a run with no stop line writes none. It runs no hook and no cost view counts it; `pipeline-events.sh list --event run_end` shows it.

`pipeline-events.sh note --issue N [--pr M] --kind K [--body-file F|-]` appends one `hand_note` line for a hand intervention (it calls `pipeline-hooks.sh hand_note <kind> [--issue N] [--pr M]`, body on stdin). `--kind` is one of `spec-revised`, `approval-posted`, `unblocked`, `relabelled`, `code-pushed`; `--issue` is required, `--pr` optional, `--body-file -` reads the body from stdin. An unknown or missing kind, a missing or non-digit `--issue`, a non-digit `--pr` or an option with no value exits 2 with the usage and appends nothing. The line is role `orchestrator`, plus `ts`, `kind`, `issue`, `pr` (null when not given) and `body` (null when empty). The body is cut to 500 bytes on a character edge and stored as a JSON string only; nothing in it is run. It follows the same `events.enabled` / `events.path` rules and never blocks. Two call sites record one themselves, when they run with no `TALOS_ROLE` (not in a stage session) and no `TALOS_RUN_STARTED` (not inside `talos.sh run`), and make no provider read for it: a succeeded `pipeline-vcs.sh post-approval` (`approval-posted`, with its `--pr` and `--issue` when passed) and a succeeded `label-issue` / `label-pr --remove pipeline:blocked` (`unblocked`, with the issue or the PR). No cost view or the project map's Stuck state counts it; `pipeline-events.sh list --event hand_note` shows it.

```bash
bash scripts/pipeline-events.sh path
bash scripts/pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
bash scripts/pipeline-events.sh tail [--issue N]    # list --last 20
bash scripts/pipeline-events.sh note --issue N [--pr M] --kind K [--body-file F|-]   # append a hand_note
```

Output is oldest first, tab-separated (`ts`, `event`, `role`, `issue`, `pr`, `verdict`, `summary`) or JSON lines. Malformed lines are skipped.

### Spend

Talos records tokens, never a price. Sources: on the native path the orchestrator passes the completion notification's usage to `talos.sh done --tokens --tool-uses --duration-s [--model]`; on the adapter path `pipeline-agent.sh` records the claude runner's usage (`agents.capture_usage`, default true; input + output + cache creation, cache reads excluded) and a `custom` runner's sidecar file `$TALOS_USAGE_FILE` (`{"tokens":N,"tool_uses":N,"model":"..."}`, every key optional). Other runners report nothing. A missing figure is `unrecorded`, shown as such and never as 0; totals read `(+K unrecorded)`.

`tokens` (and so every total and the budget) is fresh input + output + cache write. Cache reads are not in it: they are their own number, next to the total, on every surface below. Only the claude adapter runner records the split; codex, gemini, antigravity, pi, a sidecar and a native subagent total (`talos.sh done --tokens`) show the cache figures as `unrecorded`.

```bash
bash scripts/pipeline-events.sh cost [--issue N] [--pr M] [--json]   # per issue and role
bash scripts/pipeline-events.sh cost --issue N [--pr M] --line       # one line
bash scripts/pipeline-events.sh cost --issue N [--pr M] --markdown   # PR comment body
bash scripts/pipeline-events.sh cost --summary --issue A [--issue B] # end-of-run block
```

The table has `unrecorded` and `restamp` (delta re-review) columns per issue and role, then `input_tokens`, `output_tokens`, `cache_write_tokens`, `cache_read_tokens` (each the sum over the events that carry it; `unrecorded` in the table and `null` in `--json` when none does) and `cache_unrecorded` (events with no cache read); `ci_runs`, when present, stays last. `--line`, `--markdown` and `--summary` are exclusive (exit 2) and leave out `orchestrator` rows.

With `agents.claude_api_credits` ([Monthly API credits](#monthly-api-credits)) a stage event carries `pool` (`api` or `plan`; `post_stage --pool`). When at least one event in scope has one, the table and every `--json` row and the total gain, after `cache_unrecorded` and before `ci_runs`: `api_tokens`, `api_cache_read_tokens`, `plan_tokens`, `plan_cache_read_tokens` (plain sums over the events of that pool, a missing figure counting 0) and `pool_unrecorded` (events with no pool, or any other value; `orchestrator` rows are left out of the total's count). `--markdown` (after the `This PR` line, or the TOTAL row when there is none) and `--summary` (after `Total:`) then print one line, and `--line` is unchanged:

```
Pools: API credits 1.50M (cache read 48.00M), plan 300k (cache read 2.00M) (+2 unrecorded)
```

`(+K unrecorded)` counts the stage runs with no pool. With no pool-carrying event every form prints exactly what it did.

| Form | Cache reads and writes |
|---|---|
| `--line` | ends ` · cache read <R> (not in total), cache write <W> (in total)`, before any budget suffix; `(not in total, +K unrecorded)` when K events have no cache read; ` · cache reads unrecorded` when none has. The breakdown is cut to keep 200 characters, never this part |
| `--markdown` | `cache write` and `cache read` columns after `tokens` (`<sum>`, `<sum> (+K unrecorded)` or `unrecorded`); `This PR (#M): <T> (<n> tokens, cache reads not included) · cache read <R>, cache write <W>`; the footer says what `tokens` and TOTAL are made of |
| `--summary` | the same two columns; `Total: <T> (cache reads not included) · cache read <R>, cache write <W>`; then the session line |

`cost --summary` ends with the orchestrating session's own usage, read from the transcript that `TALOS_TRANSCRIPT_PATH` names (an absolute path ending `.jsonl`, a regular file, not a symlink; that file only, each message id counted once with its last figures; the last 64 MB of a larger file, marked `(partial: transcript over 64 MB)`):

```
Orchestrator session: 412 calls, cache read 48.20M, cache write 1.20M, output 310k
Orchestrator session: not available
```

The second line is printed when the variable is unset, empty, or names anything else.

Where it shows: the `spend=` line after each stage; one comment per PR, edited in place (marker `<!-- talos:spend -->`), written when `comments.enabled` is true and `spend.comment` is not false, on GitHub and Azure DevOps, public on a public repo; and the `cost=` lines of `talos.sh summary` at the end of a `/talos:pipeline` session (the session line included; a bare `talos.sh run` does not call it). A failed comment write is one `spend-upsert-failed` warning, never retried.

### Budget guard

Off unless `limits.tokens_per_issue` is a positive integer. `limits.warn_at` (default 0.8) sets the warn state. `gate fix-round` checks before each developer fix round (never a first pass, re-stamp or merge); only recorded tokens count, and cache reads never do (`used` is the `tokens` sum).

```bash
bash scripts/pipeline-budget.sh check --issue N [--json]
# talos:budget ok|warn|exceeded issue=N used=.. limit=.. effective=.. pct=.. unrecorded=..
```

Exit 1 means exceeded (0 for ok, warn, unknown and guard off), so a `set -e` caller must capture the code. Exceeded sets `pipeline:blocked` on issue and PR and records `budget-blocked`. Each such event grants one more full limit: effective limit = limit x (1 + grants). Remove the label to continue, or raise the key.

### The status line

`scripts/talos-status.sh --line` prints one line from the events log, offline and free of model tokens, always exit 0, nothing when no issue is active:

```
talos #7 qa ●●●●◐○ 3.41M · cache read 48.20M
```

Fields: issue, running (else first pending) stage, one dot each for validator, pm, developer, review (reviewer, security, adversarial), qa, merge (`●` done, `◐` running, `○` pending), the issue's token total, then the cache reads, which are not part of that total: the `cache_read_tokens` of the issue's events plus, while a stage runs, the transcript's cache reads since it started. With no such figure the ` · cache read` part is absent, never 0. A role turned off in `roles.*` has no dot, nor has a validator or pm that never ran once a later stage has. The issue is the current branch's (`fix|feat/issue-N-...`), else the newest event's; a merged issue prints nothing. A stage runs from its `stage_start` event until its finishing event (6 hours at most). While it runs, the total adds usage read from the harness transcript (`transcript_path` on stdin, plus subagent transcripts). Config read: `roles.*` and `events.path` from `talos.pipeline.json` over `${TALOS_HOME:-~/.talos}/talos.pipeline.json`. The run is cut off after `TALOS_STATUS_TIMEOUT_S` seconds (1 to 10, default 3). `TALOS_STATUS_DEBUG=1` says on stderr why nothing printed.

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
| a command naming `statusline-chain.sh` that is not the wrapper | left unchanged, one notice (reserved) |
| no `command` (not a command status line), or a `settings.json` that does not parse | left unchanged, with a notice |

`--no-statusline` skips the whole step for every harness (one line says so; nothing is written). `--statusline-undo` (implies `--global`, does nothing else) puts `statusLine` back to exactly the saved value, deletes the wrapper and the backup, and says `nothing to undo` when there is nothing Talos-owned. When `statusLine` runs Talos's own command, or the backup is unusable, undo removes the `statusLine` key instead; a reserved command is left as it is.

Talos reads, writes and deletes exactly two files, the wrapper `<TALOS_HOME>/statusline-chain.sh` and the backup `<TALOS_HOME>/statusline-previous.json`; a file or backup anywhere else is never looked at. A `statusLine` command is the wrapper when some word of it (a leading `~`, `$HOME`, `${HOME}`, `$TALOS_HOME` or `${TALOS_HOME}` expanded) resolves to that wrapper path; the interpreter (`bash`, `sh`), `VAR=value` prefixes and extra arguments do not matter, and the command is kept exactly as written. A command that is not the wrapper but contains the text `statusline-chain.sh` anywhere (`bash <wrapper>; x`, `bash -c 'bash <wrapper>'`, `<wrapper>|tail`, your own script of that name, a wrapper under another `TALOS_HOME`) is reserved: install and undo print one notice, change and delete nothing, and it is never chained or saved as the original. Every other command is chained, including a script that merely carries the Talos header text. Talos writes `<TALOS_HOME>/statusline-chain.sh` only when it is missing or has the header; a file of yours there is never touched (a notice names it, and `--statusline-undo` then changes and deletes nothing, the backup included). The backup is used only when its command is an ordinary one, so it can never restore or render a command that names the wrapper. A wrapper started inside a wrapper skips the original (`TALOS_STATUSLINE_CHAIN`) and prints only the Talos line. Both only touch the user-level `settings.json`, never a project's `.claude/settings.json`. `/talos:setup` wires only from the installed copy (`$TALOS_HOME`, `~/.talos` or the plugin); from a project checkout it says to run `install.sh --global`.

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
- Under the LLM loop (`execution.orchestrator: llm`), `next` ends a session that has grown to `execution.context_budget_tokens` with `stop reason=context-budget size=<n> budget=<b>` and `resume=/talos:pipeline`: the issue in flight is finished, no queued one was started. Start a fresh session and run the resume line. The budget needs `TALOS_TRANSCRIPT_PATH` (the same path rules as the session line in [Spend](#spend)); without it `next` prints `warn reason=context-unknown` and the budget is off. It measures the orchestrating session's context, not an issue's spend: that is the [Budget guard](#budget-guard). See [Entry points](#entry-points).
- A run holds a per-issue lease. After a crash `next` answers `wait reason=lease retry_after_s=<s>` until the dead holder's lease is reclaimed (10 s by default); `talos.sh lease prune` removes dead ledger lines.

## Troubleshooting

Start with `bash scripts/pipeline-config.sh --show` (each key, its value and layer) and `bash scripts/talos.sh env` (what a run will do). `pipeline-vcs.sh --dry-run <verb> ...` previews a VCS action.

### Config does not load

- `reason=config-shadowed winner=<json> also-present=<files>` or `reason=config-legacy-file <path>`: config is JSON only. A stray `talos.pipeline.yml`/`.yaml` beside the json stops every config read; merge it into the json by hand, then delete it.
- `stop reason=config-unreadable`: `pipeline-config.sh --dump` failed; the line above names the cause. A profile error shows as `reason=profile-unknown` or `reason=profile-unusable` (see [Profiles, runners and fallback](#profiles-runners-and-fallback)).
- `pipeline-config: [warn] unknown config key 'merge.atuo' (did you mean 'merge.auto'?)`: otherwise the typo is ignored and the default applies. `TALOS_CONFIG_STRICT_KEYS=0` silences the check.

### A run stops

`talos.sh run` ends with a `stop reason=...` line, or a `dispatch-failed role=<r> reason=<why>` line on stderr. Under `/talos:pipeline` the session acts on that end line by the end-state table in [SKILL.md](../skills/pipeline/SKILL.md): one action per line (relay, restart, fix or ask the owner), and a line the table does not know is relayed as it is.

| Line | Meaning and fix |
|---|---|
| `verdict-unreadable` | The final message had no line starting with the role's verdict word and a colon (`PASS:`, `APPROVED:`, `CLEAR:`, ...). Nothing is recorded; common with a weak local model on `custom`. Re-run. |
| `agent-failed rc=<n>` | The runner exited non-zero; `124` is `agents.stage_timeout_s`. |
| `provider-failed rc=75\|69` | Provider error or failover exhausted; nothing is recorded. See [Profiles, runners and fallback](#profiles-runners-and-fallback). |
| `config-mutated role=<role> file=<path>` | The stage changed, created or removed a resolved config file (`pipeline-agent.sh` exit 78). Nothing is recorded and the file is not restored: review the change, then re-run. |
| `action=wait reason=lease` | Another run holds the issue's lease (or the ledger is unavailable). Re-run later; see [Isolation, locking and multi-user claims](#isolation-locking-and-multi-user-claims). |
| `action=wait reason=owner` | An open issue or PR carries `pipeline:blocked`, or an owner question is open (`pipeline:needs-owner`). No new ready issue starts; only in-flight work moves. Answer the question or clear the label, then run again. |
| `action=wait reason=human-merge` | `merge.auto` is off, so the driver never runs the merge gate. Under `/talos:pipeline` the session runs the gate and the hand-off; after a bare `talos.sh run`, run `talos.sh gate merge <PR> <N>` and, on `verdict=handoff`, `talos.sh post-merge <PR> <N> --handoff`. See [Human merge](#human-merge). |
| `action=wait reason=ci pr=<M> issue=<N>` | With `verify.qa_mode: ci`, `talos.sh run --issue <N>` stopped waiting for the PR's required checks because one failed (`warn reason=qa-ci-red` comes first); QA was not dispatched and nothing is blocked. Start the run again once the checks are green. |
| `qa-fail-unchanged-head` | The QA fix round pushed nothing; PR and issue are `pipeline:blocked`. |
| `qa-comment-missing` | QA ended FAIL but left no verdict comment on the PR, and posting one from the stage's final message failed; no fix round ran, so the developer is not sent after a finding it cannot read. Read the QA stage's output, post the verdict by hand and run again. |
| `environment issue=<N> pr=<M>` | A `verify.ready` command failed in QA's `qa-run` (`qa-run: verdict BLOCKED environment: <cmd> exited <N>`), or QA ended `BLOCKED: environment: <why>`: the app was down, restarting or stale, and the code was not judged. PR and issue are `pipeline:blocked`, no fix round ran and no attempt was recorded. Fix the environment (or the `verify.ready` command), then remove `pipeline:blocked`; the raw output is under `.talos/qa-run-<pr>/`. |
| `qa-flaky issue=<N> pr=<M>` | Every FAIL line of QA's `qa-run` is `AC<n> FAIL flaky`: a test failed at the head and passed on the one re-run. PR and issue are `pipeline:blocked`, no fix round ran and no attempt was recorded. The owner decides: fix or remove the flaky test, then run again. |
| `spec-unusable detail=id-collision issue=<N> pr=<M>` | `red-check` (run once after the first-round developer opened the PR, before reviewer) found an id that an earlier issue's `Tests:` file already labels, or that two `Tests:` files label, and neither is the droppable case (one file pre-existing and one the branch adds, which `red-check` drops from the `Tests:` line itself). PR and issue are `pipeline:blocked` and no reviewer ran. The PM must name one new file for the criteria tests on the `Tests:` line; fix the `**PM spec:**` comment, remove the label and run again. |
| `spec-unusable issue=<N> pr=<M>` | QA failed or ended `BLOCKED: spec: <why>` on a spec it cannot use (unreadable, no criteria checklist, a refused or missing `Tests:` line), which is no finding on the PR: no fix round ran; PR and issue are `pipeline:blocked`. It is also the stop for a QA `FAIL` whose `AC<n> FAIL` lines are all `vacuous` (the red commit is the branch's first, so no later commit can turn it red; a vacuous criterion beside a red-then-green one and no other FAIL is a `guard` line, not a stop), and for a repeated `vacuous` / `head=missing` `FAIL` at an unchanged spec (the first one gets one fix round, to move a test file onto the `Tests:` line). `bash scripts/pipeline-criteria.sh spec-usable <N>` prints the fault. Fix the `**PM spec:**` comment, remove the label and run again. |
| `fix-round-unchanged-head pr=<M> issue=<N>` | The fix round after a reviewer, security or adversarial finding pushed nothing; PR and issue are `pipeline:blocked`. Read the findings on the PR, fix or answer them, remove the label and run again. |
| `verdict=block reason=<why>` | `gate fix-round` refused the round (`max-fix-attempts`, `max-total-dispatches`, `budget-exceeded`); PR and issue are `pipeline:blocked`. |
| `verdict=ask-owner reason=design-decision stage=<role>` | The role blocked the same file in `limits.same_area_rounds` rounds running; the question is on the PR. Reply there, then run again. |
| `iterations-exhausted` | The `--max-iterations` cap (default 20) was reached; it counts the passes of the whole command, the ones after a merge included. Run again, with a larger number for a long drain. |
| `same-verdict-same-head role=<role> pr=<M>` | Docs, reviewer, security or adversarial ended with the same verdict at the same PR head as its previous dispatch in this run, and no approval of that role is stamped at that head (its label on the PR, not named by `check-approval-sha --stale-list`), so another pass would only repeat it. Read that stage's last comment on the PR (a missing stamp, a refused `commit-docs`), fix the cause, run again. |
| `worktree-unavailable role=docs` | No worktree of the PR's head branch could be had for docs (`pipeline-worktree.sh pr-worktree <N> <M>` names why: an unreadable head branch, one origin does not have, a local branch that diverged). Docs never runs in the driver's checkout. |
| `stop-requested` | `talos.sh run --stop` was called; the stage that was running finished first. Run again to go on. |
| `merged pr=<M> reason=checkout-return-failed` | The PR merged, but the checkout could not be put back on the base branch (a tracked change on the issue branch, a refused switch, a pull that is not a fast-forward; stderr names which). Nothing was forced. Fix the checkout by hand, then run again. |
| `scripts-missing` | After a merge, `talos.sh` in the scripts directory could not be read, so the next pass could not start. Reinstall, then run again. |
| `usage` | `talos.sh run` got an argument it does not take (exit 2). Fix the command line. |
| `unknown-role` | A role name that is not one of the pipeline's roles reached `run` or `prompt` (exit 2). Fix the role name. |
| `unknown-pr` | The PR the pass needs could not be found or read. Check the PR number (it may be closed or deleted), then run again. |
| `dispatch-failed role=<r> reason=<why>` | A stage could not be started; the line is on stderr and `<why>` names the cause. Fix that cause, then run again. |
| `ready-pr-failed` | With `pr.draft` true, taking the PR out of draft failed (`draft-pr-failed` after a failed QA). See [Running in a Claude Code cloud session](#running-in-a-claude-code-cloud-session) for a session that may not change draft state. Mark the PR ready by hand, then run again. |
| `draft-unverified` | The PR's draft state could not be read, so the pass did not guess. Check the provider and token, then run again. |
| `head-unresolved` | The PR's head commit could not be read; no verdict is recorded without a head. Check the provider and run again. |
| `verify-timeout role=qa pr=<M>` | QA's verify command timed out in the foreground (`BLOCKED: verify: timed out after <n> ms`); the issue and PR are `pipeline:blocked`. Split `verify.commands` so each fits 600000 ms (for example `run-tests.sh --shard i/n`), use `verify.qa_mode: ci`, or shorten the suite, then remove the label and run again. |
| `stage-blocked role=<r>` | The stage ended with `BLOCKED: <reason>`; the issue and PR are `pipeline:blocked`. Read the reason, fix it, remove the label and run again. |
| `merge-failed` | `merge-pr` failed (a conflict, a failed required check, a refused merge). Read the error on stderr, fix the PR and run again. |
| `state-unavailable` | The answer of `next` or of a gate was not one of the shapes the driver knows, usually a transient failure reading the state dir. Nothing is recorded; the next start can simply run again. If it repeats, check the state dir is writable. |
| `python-missing` | `python3` is not on `PATH`. Install it, then run again. |
| `scratch-unavailable` | A scratch file or directory (`TMPDIR`, default `/tmp`) could not be created or written. Free space or fix `TMPDIR`, then run again. |
| `config-unreadable` | The pipeline config file could not be read or parsed. Fix the file (`talos.sh env` prints what it reads) and run again. |
| `map-failed` | Updating the project map failed. It is a `warn` line: the first failure turns the map off for the rest of the run and the run goes on. Run the map verb by hand to see why. |
| `trust-unverified` | The login lookup was refused (an Actions or GitHub App token) and `markers.trusted_authors` is empty, so marker authors cannot be checked. Set `markers.trusted_authors`. |

A `pipeline:blocked` issue or PR is skipped until a human removes the label. After a token-budget block, removing it grants one more limit (or raise `limits.tokens_per_issue`).

### A stage waits about 115 s on each refused tool call

A terminal wrapper that puts a `PermissionRequest` hook on `claude` (cmux does, through `--settings`; `--setting-sources project` does not stop it) makes every refused tool call wait about 115 s for an approval no headless stage can give, and the calls batched with it wait too. The refusal itself is the same with or without the hook; only the wait differs. Talos starts the `claude` child of every claude-runner stage with `CMUX_CLAUDE_HOOKS_DISABLED=1`, unless your environment already sets that variable (any value, including `0`, is kept). Another wrapper's hook is not known to Talos: if stages stall in 115 s steps, look for a `PermissionRequest` hook in the settings `claude` is started with, and switch it off for stage runs. The usual fix for the refusal itself is a rule in [Claude permissions on headless stages](#claude-permissions-on-headless-stages).

### Approvals and merge

- An approval is stale after a new commit that touches a non-waived file; only the affected stages re-run. `bash scripts/pipeline-vcs.sh check-approval-sha <PR> --stale-list` names them, each with the SHA it approved.
- An approval label that went missing while the head stayed the same is put back by `gate merge` (`recovered=<roles>`), with no stage run. `reason=approvals-missing` with `never_approved=<roles>` means no marker pins the head for those roles, so their stages run again. A label in `missing=` whose role is not listed there is a lost stamp the gate could not put back this time: run the gate again. `bash scripts/pipeline-vcs.sh check-approval-sha <PR> --evidence-list` shows each role as `present`, `lost` or `missing` ([Lost stamps](#approvals-bound-to-the-head-sha)).
- `assert-sync` aborts on a dirty tree (an untracked `AGENTS.md` counts), a checkout behind or diverged from `origin/<base>`, or a failed `git fetch`. Commit, stash or `git pull --ff-only`.

### Provider and board

- `github: no authenticated gh CLI and GITHUB_TOKEN or GH_TOKEN required`: run `gh auth login` or export a token (`vcs.token_env` names another variable).
- `github: cannot determine the repository (set vcs.repo)`: the token transport cannot read the git remote; set `vcs.repo` to `owner/repo`.
- Board updates fail: warnings by design, not a stop. `bash scripts/bootstrap-board.sh` adds a missing Status option (idempotent). With `gh`, Projects v2 needs the `project` scope (`gh auth refresh -s project`); check `board.project_number` and `board.owner`.
- `talos:board-unverified` on stdout: a missing Status option, an API error or the item-page cap (`TALOS_BOARD_MAX_PAGES`, default 50) skipped the update. The run continues.
- `pipeline-status: the board needs GitHub GraphQL, which this session refuses (HTTP 403); move skipped`: the run is in a Claude Code cloud session, where the board cannot be moved. The run continues; `board.enabled: false` drops the warning. See [Running in a Claude Code cloud session](#running-in-a-claude-code-cloud-session).
- `pipeline-worktree: checkpoint: push refused: no push access to origin for <branch>` (exit 3): the remote denied the branch and the commit is kept locally. In a cloud session, give the Claude GitHub App write access or use the session's own branch (same section).

### Notifications

- Plain monospace messages instead of rich cards: no template resolved, so `templates/` is missing from the install; re-run `install.sh`.
- Webhooks cannot thread; threading needs a Slack/Discord bot token or Buzz. A thread that goes silent after the first message usually means `notifications.events` omits the role events.
- Preview: `PIPELINE_NOTIFY_DEBUG=1 bash scripts/pipeline-notify.sh validator "#1" "test" 1` posts nothing; `bash scripts/pipeline-notify.sh --render buzz qa "#42" "PASS"` needs no credentials.
