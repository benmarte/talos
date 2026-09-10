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
| Dashboard / per-project config | `talos.pipeline.json` per repo (YAML also supported when PyYAML installed) |

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

Any stage can set `pipeline:blocked` with a comment. A blocked issue is skipped until a human resolves it and removes the label.

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

---

## VCS providers

All VCS operations are delegated to `scripts/pipeline-vcs.sh`, which wraps each provider's CLI into a uniform verb interface. You never call `gh`, `glab`, or `az` directly from skill prompts.

| Provider | `vcs.provider` | CLI required | Status | Notes |
|----------|---------------|--------------|--------|-------|
| GitHub | `github` | `gh` | **Battle-tested** | Full support. Requires `gh auth login`. `list-issues`/`list-prs` paginate fully via `gh api --paginate` — no cap. |
| GitHub (token-only) | `github-api` | none | **Supported** | All 18 verbs via `curl` + `GITHUB_TOKEN`. No `gh` CLI needed — ideal for CI/containers. Set `GITHUB_TOKEN` or `GH_TOKEN`. Projects v2 board updates also use the token. `list-issues`/`list-prs` paginate fully via Link-header pagination — same no-cap behavior as `github`, so backlogs over 100 items are never silently truncated on either GitHub provider (#171). |
| GitLab | `gitlab` | `glab` | **Best-effort** | Implemented; `glab` version quirks may surface. Requires `glab auth login`. `list-issues`/`list-prs` are capped at 100 items (`glab` has no "fetch every page" flag for these commands) — a result landing exactly on the cap prints a `WARNING result capped at 100` line to stderr rather than truncating silently. |
| Azure DevOps | `azure` | `az` + azure-devops extension | **Supported** | Full issue/board/PR flow — work items, Tags, board State, and PR labels/comments/diff (via `az rest` where `az` has no command). Merges are human-gated when `main` has branch policies. `find-pr`/`check-pr-files`/`rerun-ci` not implemented. Requires `az login` + `az extension add --name azure-devops`. `list-issues`/`list-prs` are capped at 1000 items (`az boards query` has no `--top`/page flag at all; `az repos pr list --top` has one but no further pagination) — a result landing exactly on the cap prints a `WARNING result capped at 1000` line to stderr rather than truncating silently. |
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

Restart the session, then run `/pipeline-setup` in any repo to write `talos.pipeline.json` and bootstrap labels. The plugin carries the skills, all eight role agents, the scripts and the templates; the repo carries nothing but its config.

agent-skills comes with it automatically (`+ 1 dependency: agent-skills`). If you already use Addy's marketplace you will see agent-skills registered twice; that is expected and harmless, see the [user guide](docs/user-guide.md) for why.

**Option B — global install with `install.sh`.** Installs once to `~/.talos/`; every repo and every harness on this machine picks it up.

```bash
git clone https://github.com/benmarte/talos
bash talos/install.sh --global          # installs to ~/.talos/, ~/.claude/skills/, and role profiles to ~/.claude/agents/
bash talos/install.sh /path/to/your-repo  # writes config; no scripts copied into repo
# add --harness codex or --harness antigravity to also write the AGENTS.md section
```

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
# Edit talos.pipeline.json for your project
# JSON needs no PyYAML dependency — recommended for new projects.
# YAML is also supported: cp talos.pipeline.yml.example talos.pipeline.yml (requires PyYAML)
```

Minimum viable config (board and notifications optional):

```yaml
base_branch: dev        # the branch PRs target
verify:
  - python -m pytest tests/ -x -q   # your actual test command
```

### 3. Bootstrap labels (GitHub / GitLab / Azure only)

```bash
bash ~/.talos/scripts/bootstrap-labels.sh          # global install
# or: bash .claude/talos/scripts/bootstrap-labels.sh  # vendored legacy
```

This creates the `pipeline:*`, `spec:ready`, `qa:pass`, `review:approved`, `security:approved`, and `docs:done` labels in your repo (idempotent). Skip this step for file mode — checkboxes replace labels.

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

For anything else — a local desktop notifier, a webhook relay, a log shipper — set `notifications.cmd` to a shell command. It runs (via `sh -c`) after the four sinks above, for every event that passes `notifications.events`, with a JSON object on stdin:

```json
{"event": "pr-opened", "ref": "#42", "message": "🔀 [talos] pr-opened #42 — ...", "thread_key": "42", "fields": [{"label": "PR", "text": "#9", "url": "https://github.com/acme/widget/pull/9"}], "repo": "acme/widget", "issue": 42}
```

`message` is the same rendered text the other sinks build their message from; `fields` is the same platform-neutral metadata table (PR/Issue/Stage/Repo) they render natively. Bounded by `notifications.cmd_timeout_s` (default `10` seconds); a missing command, non-zero exit, or timeout logs one line to stderr and never blocks the pipeline or any other sink.

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

All keys live in `talos.pipeline.json` (or `talos.pipeline.yml` if PyYAML is installed) at your repo root. Every key is optional and falls back to a sensible default. An unrecognized key (typo, wrong section) prints a one-line `pipeline-config: [warn] unknown config key '...' (did you mean '...'?)` warning to stderr instead of silently doing nothing — set `TALOS_CONFIG_STRICT_KEYS=0` to disable it.

| Key | Default | Description |
|-----|---------|-------------|
| `base_branch` | repo default branch | Branch all PRs target |
| `release_branch` | `main` | Production branch (changelog headers) |
| `repo` | auto-detect | Legacy top-level alias for `vcs.repo` — checked first (before `vcs.repo`, before the git remote) by helpers that resolve `owner/repo` (e.g. `pipeline-hooks.sh`). Prefer `vcs.repo` in new configs; both are read for back-compat. |
| `vcs.provider` | `github` | VCS backend: `github`, `gitlab`, `azure`, or `file` |
| `vcs.repo` | auto-detect | `owner/repo` override (required when git remote unavailable) |
| `vcs.token_env` | unset (falls back to `GITHUB_TOKEN`, then `GH_TOKEN`) | Name of the environment variable holding the GitHub token, for the `github-api` provider (token-only, no `gh` CLI). Lets you point Talos at a differently-named secret (e.g. `MY_BOT_TOKEN`) without renaming it to `GITHUB_TOKEN`/`GH_TOKEN`. Also read by `pipeline-status.sh` for Projects v2 board updates when `gh` is absent. No effect on the `github` provider (uses `gh auth`). |
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
| `verify` | `[]` | Shell commands every code subagent must pass. Also accepts a dict form — `verify: {commands: [...], qa_mode: ..., targeted: ..., ci_wait_s: ..., timeout_ms: ...}` (`verify.commands` is then this dict's `commands` list) — so the sibling `verify.*` keys below can live under the same top-level key instead of alongside it. |
| `verify.qa_mode` | `ci` when `merge.required_checks` is non-empty, else `local` | `ci`: QA trusts CI (`pr-checks`) as the suite oracle instead of re-running `verify:` locally — CI already runs it on every push. `local`: QA runs the full `verify:` list once itself, as before. An explicit value always wins over the `merge.required_checks`-derived default — **except** an explicit `ci` combined with an empty or absent `merge.required_checks` list, which resolves to `local` instead (with a one-line warning on stderr): trusting CI as the oracle for zero required checks would let QA pass vacuously, without ever running `verify:` or observing a real CI signal. |
| `verify.targeted` | `true` | While iterating, the developer runs only the tests covering the files it changed (`tests/run-tests.sh --for <path>...` or `--changed [<base-ref>]`; see [Tests](#tests)), then runs the full `verify:` list exactly once, immediately before its final commit and push. Set `false` to run the full `verify:` list on every iteration instead — never zero local runs either way. |
| `verify.ci_wait_s` | `900` | Seconds QA waits in the foreground (no background process, no sleep-polling) for every check named in `merge.required_checks` to go green under `qa_mode: ci`, via `pipeline-vcs.sh pr-checks-required` -- scoped to just those checks, so an unrelated non-required check cannot burn the budget or mask a required check GitHub hasn't scheduled yet. Any required check still failing, missing, or pending when the budget elapses is treated as FAIL (fail closed). Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default) -- it is interpolated unquoted into the CI-wait loop's shell test. |
| `verify.timeout_ms` | `600000` | Milliseconds substituted as `<VERIFY_TIMEOUT_MS>` into the foreground rule placed next to every verify and CI-wait instruction in the developer and QA prompts — the explicit timeout a stage passes to its verify command instead of backgrounding it. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `merge.auto` | `true` | `false` runs every stage and gate (approvals, forbidden-files check, green CI) but leaves the final merge to a human: the orchestrator labels the PR `pipeline:approved`, posts a "ready for human merge" comment, and stops instead of merging. The issue stays open and is closed by the reconciliation sweep after you merge. See [Human-merge mode](docs/user-guide.md#running-the-pipeline) in the user guide. |
| `merge.method` | `squash` | `squash`, `merge`, or `rebase` |
| `merge.required_checks` | `[]` | CI check names required before merge |
| `merge.delete_branch` | `true` | Delete feature branch after merge |
| `merge.forbidden_files` | see defaults | Glob patterns (matched against filename and full path) for files that must not appear in a PR. Defaults (20 patterns): `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.secrets`, `secrets.*`, `*id_rsa*`, `*id_ecdsa*`, `*id_ed25519*`, `*id_dsa*`, `*.ppk`, `*.jks`, `*.keystore`, `*.pkcs12`, `*.kdbx`, `*.ovpn`, `.netrc`, `_netrc`. Setting this key **adds** to the defaults (union semantics) — the built-in patterns remain active alongside any configured patterns. To replace the defaults entirely, also set `merge.forbidden_files_replace: true` (see below). **Note:** `*id_rsa*` also matches `id_rsa.pub` (a harmless public key) — this is an accepted false positive. If you commit public keys, add `id_rsa.pub` (or the specific filename) to `merge.forbidden_files_allow`. **Note:** `*.keystore` may also block self-signed test keystores committed for CI use — `fnmatch` cannot distinguish a real keystore from a test one. This is expected behaviour; operators who legitimately commit test keystores should add the specific filename to `merge.forbidden_files_allow` (e.g. `["test.keystore", "debug.keystore"]`). **Note:** `.netrc` and `_netrc` are literal patterns (no glob characters). As of #76 (PR #90), literal deny patterns generate canaries and wildcard allow entries that match them are rejected — the deferral that kept `.netrc` out of the defaults is resolved (#78). **Note:** Three extensions were deliberately excluded from the defaults in #78: `*.gpg` (`pass`/SOPS/git-crypt workflows commit GPG-encrypted blobs intentionally — encryption-at-rest is a legitimate reason to put a secret in a repo), `*.asc` (detached signatures and public signing keys are routinely committed as release artifacts), and `*.der` (DER is an encoding used equally by public X.509 certificates and private keys — the extension alone is not a reliable signal). If one of these applies to files that should genuinely never appear in your PRs, add the pattern to `merge.forbidden_files`. |
| `merge.forbidden_files_replace` | `false` | Set to `true` to restore the pre-v0.13 replacement behaviour: `merge.forbidden_files` will then **replace** the built-in defaults entirely rather than unioning with them. **Security warning:** this suppresses the built-in secret-protection patterns for every PR until the key is removed. A `talos:forbidden-files-defaults-replaced` marker is emitted on stdout on every run so the suppressed state is auditable in the PR record. Keep this `false` unless you have a specific reason to narrow the deny list. |
| `merge.forbidden_files_allow` | `[]` | Explicit exemptions for `merge.forbidden_files`. Globs matched against filename and full path, checked **before** deny patterns. Use this when a deny pattern over-matches a committed template (e.g. allow `.env.example` while keeping `.env.production` blocked). Example: `[".env.example"]`. **Security note:** each entry punches a hole in the secret-protection gate — if a real secret file matches an allow entry it will not be blocked. Keep the allow list minimal and specific. **Literal-override caveat:** the allow-list validation generates canaries from both wildcard and literal deny patterns. A wildcard allow entry (e.g. `*.env`) that matches a canary derived from any deny pattern is rejected. The one permitted exception is an allow entry that is an exact string match for a literal deny pattern (e.g. adding `.env` to allow when `.env` is a deny pattern) — this is treated as a deliberate operator decision to permit that specific file. Keep such overrides intentional and minimal. |
| `merge.approval_waiver_paths` | `["*.md", "docs/**", "CHANGELOG.md", "*.example"]` | Glob patterns for files that, when they are the **only** changes between an approval SHA and the current head, do not invalidate that approval. A docs-only commit pushed after QA approval will therefore carry the approval forward rather than forcing a full re-run. `*.example` covers generated pipeline-config examples (e.g. `talos.pipeline.json.example`, `talos.pipeline.yml.example`) — they are never executed. **Hard-coded non-waivable (cannot be widened by this key):** any path under `scripts/`, any path under `tests/`, and all pipeline config filenames: `talos.pipeline.yml`, `talos.pipeline.yaml`, `talos.pipeline.json`, `.claude-pipeline.yaml`, `.claude-pipeline.json`, `pipeline.yaml`, `pipeline.json` — these are enforced structurally after the config waiver check. **Validation:** entries that are too broad (catch-all globs such as `*`, `**`, `*/*`, or any pattern that would match the hard-coded non-waivable paths) are rejected at validation time and will **block the merge** (fail-closed), matching the behaviour of `merge.forbidden_files_allow`. Keep entries minimal and specific. |
| `merge.union_paths` | `["CHANGELOG.md"]` | Glob patterns (matched against filename and full path) for files `pipeline-mergebase.sh` is allowed to resolve mechanically — both sides of the conflict are kept via `git merge-file --union` (PR side first), no developer dispatch (#256). Used by the Step 3c mergeability gate: when a `CONFLICTING` PR's `conflict-files` output is entirely covered by this list, `pipeline-mergebase.sh` resolves and pushes the merge itself; any other conflicting path falls back to the developer merge-base task as before. **Hard-coded non-unionable (cannot be widened by this key):** any path under `scripts/`, any path under `tests/`, and all pipeline config filenames — same enforced-after-config-check set as `merge.approval_waiver_paths`. **Validation:** catch-all or non-unionable-matching entries are rejected at validation time (exit 1, nothing merged), same rule as `merge.approval_waiver_paths`/`merge.forbidden_files_allow`. Keep entries minimal and specific — a union merge blindly concatenates both sides, which is safe for an additive changelog but would corrupt a source file. |
| `issues.label_filter` | `pipeline:ready` | An issue enters the queue when it carries **both** `pipeline:ready` **and** this label. When `label_filter` is `pipeline:ready` (the default), the two conditions collapse to one — existing configs are byte-identical to today. When set to a custom value (e.g. `team:alice`), only issues carrying both labels are queued; issues that carry only the custom label are silently skipped. |
| `issues.skip_labels` | `[pipeline:blocked, wontfix]` | Issues with these are skipped |
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
| `roles.docs_mode` | `auto` | Only relevant when `roles.docs` is `true`. `auto`: Step 3e Phase 1 checks the PR's changed paths (`pipeline-vcs.sh pr-files <pr>`) before dispatching docs. No docs subagent is dispatched (the orchestrator stamps `docs:done` directly with "docs verified by developer diff (docs_mode: auto)") when `CHANGELOG.md` is changed AND (`README.md` or a `docs/**` path is also changed), OR every changed path other than `CHANGELOG.md` itself is under `scripts/**` or `tests/**` AND `CHANGELOG.md` is changed. When docs does dispatch under `auto` (the gate above didn't match), its prompt receives only the changed doc-relevant paths and the CHANGELOG hunk (`git diff origin/<base>...HEAD -- CHANGELOG.md`), not the full PR diff, and is told to read source only on demand. `always`: restores the pre-#200 behavior — docs always dispatches and always reads the full diff via `diff-pr`. Filed from a pipeline run where the docs stage spent 26k-108k tokens per PR concluding "no docs changes required" because the developer had already updated docs as part of its own acceptance criteria (#200). |
| `roles.planner` | `false` | Epic decomposition (optional, off by default) — detects epics (via `epic` label, ≥ 4 checklist items, or body ≥ 2000 chars) and creates dependency-ordered sub-issues; independent sub-issues enter the queue immediately, dependent sub-issues are unblocked automatically as predecessors close. The auto-close sweep does NOT close an epic once its sub-issues finish if the epic's own body still has unticked `- [ ]` acceptance boxes — it gets `pipeline:epic-children-done` and a comment naming what's outstanding instead, and stays open for a human |
| `comments.enabled` | `true` | Post a stage comment at each handoff (Daedalus parity) |
| `comments.header` | `**Agent:** {role} (talos)` | Header prepended to every stage comment; `{role}` is replaced at runtime |
| `comments.templates_dir` | `templates/comments` | Path (relative to repo root) containing comment templates |
| `notifications.slack_channel` | `""` | Slack channel ID fallback |
| `notifications.discord_channel` | `""` | Discord channel ID fallback |
| `notifications.buzz_channel` | `""` | Buzz channel UUID (Nostr `h` tag target) |
| `notifications.buzz_relay` | `""` | Buzz (Nostr) relay URL. Not a secret — it identifies a deployment the same way `buzz_channel` does, so it belongs in the committed config. Precedence: exported env (`PIPELINE_BUZZ_RELAY`) > repo/Hermes `.env` > this config key. |
| `notifications.templates_dir` | `templates/notifications` | Path to notification message templates; `""` disables templates |
| `notifications.threading` | `true` | Thread all events per issue in one Slack/Discord thread (bot-token mode only) |
| `notifications.events` | all (unset) | Events filter. **Leave unset** — when set, any unlisted event is silently dropped, including all role events that make up the conversation stream. See warning below. |
| `notifications.cmd` | `""` (disabled) | Shell command run (via `sh -c`) for every event that passes `notifications.events`, after Slack/Discord/Teams/Buzz. Receives a JSON payload on stdin (`{event, ref, message, thread_key, fields, repo, issue}`); see [Optional: notifications](#5-optional-notifications) above for the schema. A missing command, non-zero exit, or timeout is a silent no-op with one line on stderr — never blocks the pipeline or the other sinks. |
| `notifications.cmd_timeout_s` | `10` | Seconds `notifications.cmd` may run before being killed. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `limits.max_fix_attempts` | `3` | Max **consecutive** failures of the **same blocking stage** before `pipeline:blocked` is set. Resets to 1 when a different stage blocks next. **Behaviour change from v0.13:** this key previously counted every developer dispatch; it now counts consecutive same-stage failures only. Operators with existing configs should audit: a value of `3` previously allowed 3 total dispatches; it now allows 2 re-dispatches for the same stage (the third recording exits non-zero and blocks). |
| `limits.max_total_dispatches` | `8` | Absolute ceiling on total developer dispatches per issue, across all stage changes. **Never resets** — not even when the blocking stage changes. Prevents a QA→reviewer→QA ping-pong from exploiting per-stage resets to run indefinitely. When the total reaches this value, `record-attempt` exits non-zero regardless of which stage is blocking. |
| `limits.max_retries` | `5` | Retries per network call after a rate-limit / transient error, on top of the original try — up to 6 total attempts by default (#173). Applies uniformly to every network verb in every provider: `gh`/`glab`/`az` CLI invocations (shadowed once per adapter so no call site needs editing) and the `github-api` provider's `curl` requests. **Retried:** HTTP 429; GitHub 403 responses whose body mentions a secondary rate limit or abuse detection; `gh`/`glab`/`az` errors whose stderr matches a rate-limit pattern. **Not retried (fails immediately, today's behaviour):** 401, 404, 422, and any other error that doesn't match those patterns. **Backoff:** honours a `Retry-After` value when the transport supplies one; otherwise exponential starting at 2s, doubling each attempt, capped at 60s. Each retry logs one line to stderr naming the attempt number and wait duration. `--dry-run` never sleeps or retries — every verb returns before its first network call. `TALOS_RETRY_SLEEP_SCALE` (default `1`) scales every sleep; set to `0` in tests for instant runs. |
| `markers.verify_authors` | `true` | Whether `check-approval-sha` and `read-attempt` verify the author of every `talos:approval`/`talos:attempt` marker (#187). When `true` (the default), the *effective* trust set is `markers.trusted_authors` (below) **unioned with the currently-authenticated identity** — `gh api user --jq .login` for the `github` provider, `GET /user` for `github-api` — inferred automatically, no config required. Set to `false` to restore the pre-#187 behaviour: author checking is always skipped (fail-open), silently, regardless of `markers.trusted_authors`. See [Marker placement and trusted-author allow-list](#marker-placement-and-trusted-author-allow-list) below for the full enforcement matrix, including the CI-bot caveat. |
| `markers.trusted_authors` | unset | Allowlist of GitHub login strings (YAML list) additionally trusted for `talos:approval`/`talos:attempt` markers, **on top of** the inferred current-user identity described above (union, not replacement) — set this when a second identity (e.g. a CI bot distinct from the one running Talos) also posts markers legitimately. Example: `["talos-bot", "gh-actions-bot"]`. A marker from any login outside the effective trust set is silently skipped — treated as absent by `read-attempt`, or as stale by `check-approval-sha` — and every such skip across an invocation is reported in one aggregated `talos:marker-authors-rejected authors=<comma list>` line on stderr. **Bot logins (`*[bot]`) are never trusted implicitly** — a bot must be the resolved current-user identity or be listed here explicitly. |
| `hooks.pre_dispatch` | `""` (disabled) | Shell command run before every stage's prompt is built (all roles, both the native subagent and `pipeline-agent.sh` adapter paths). Non-empty stdout is prepended to the prompt under a `## Context` heading; a non-zero exit, a timeout, or empty stdout is a silent no-op with one line on stderr — it never blocks dispatch. See [Hooks](#hooks) below for the stdin JSON schema. |
| `hooks.post_stage` | `""` (disabled) | Shell command run after every verdict, approval, block, and merge — fire-and-forget with the same never-block contract as `hooks.pre_dispatch`. Receives a JSON outcome event on stdin. See [Hooks](#hooks) below for the schema. |
| `hooks.timeout_s` | `30` | Seconds `hooks.pre_dispatch` / `hooks.post_stage` may run before being killed. Must be a positive integer; a non-integer or non-positive value is rejected (stderr warning, falls back to the default). |
| `events.enabled` | `true` | Whether every `hooks.post_stage` payload is also appended, as one JSON line, to the local events log — independently of whether `hooks.post_stage` itself is configured. See [Events log](#events-log) below. |
| `events.path` | `.talos/events.jsonl` | Path to the events log, relative to the **main repository root** (resolved via `git rev-parse --git-common-dir`, so every linked worktree of the same repo appends to the one file) unless already absolute. |
| `agents.runner` | `claude` | Agent harness for the whole pipeline: `claude` (native subagents), `pi`, `codex`, `gemini`, `antigravity`, or `custom` (with `agents.runner_cmd`). See [Other harnesses](#other-harnesses-pi-codex-cli-gemini-cli-antigravity-local-models). |
| `agents.subagents` | `auto` | `auto` (true for `claude`, else false), `true`, or `false`. Chooses native parallel subagents vs. the headless `pipeline-agent.sh` adapter. |
| `agents.runner_cmd` | — | Command for `agents.runner: custom` — the prompt arrives on stdin. Global-only; use `agents.roles.<role>.runner_cmd` to override a single role. |
| `agents.runner_args` | — | Extra CLI args passed to the `claude`/`codex`/`gemini` runner. Global-only — there is no `agents.roles.<role>.runner_args`. |
| `agents.model` | session default | Model for all stages not explicitly overridden (native path only). See [Per-role model selection](#per-role-model-selection-agentsmodel-and-agentsrolesrolemodel). |
| `agents.roles.<role>.model` | falls back to `agents.model` | Role-specific model override (native path only), e.g. a cheaper model for volume stages and a stronger one for judgement stages (reviewer, security). |
| `agents.roles.<role>.runner` | falls back to `agents.runner` | Role-specific backend override, on both the native and adapter execution paths — e.g. routing just `security` or `adversarial` through a different (often local) model while the rest of the pipeline stays on the default runner. See [Per-role runner override](#per-role-runner-override-agentsrolesrolerunner--runner_cmd). |
| `agents.roles.<role>.runner_cmd` | falls back to `agents.runner_cmd` | Role-specific command, read only when that role's resolved runner is `custom`. |

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

Implemented in `scripts/pipeline-hooks.sh`; wired into the adapter path (`scripts/pipeline-agent.sh`) and the native orchestrator path (`skills/pipeline/SKILL.md`, Harness compatibility section).

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

Implemented in `scripts/pipeline-hooks.sh` (`post_stage`, sharing its watchdog/timeout machinery with `pre_dispatch`); wired into the adapter path (`scripts/pipeline-agent.sh`, once per stage run — event `stage_complete`, verdict from the runner's exit code) and the native orchestrator path (`skills/pipeline/SKILL.md`, Conversation stream protocol, Rule 3).

### Events log

Every `hooks.post_stage` payload (see the JSON schema above) is also appended, as one JSON line, to a local `.talos/events.jsonl` audit log — independently of whether `hooks.post_stage` itself is configured. This gives every run a local, durable record of what happened without depending on an external sink.

Enabled by default (`events.enabled: true`); set it to `false` to disable. The log path (`events.path`, default `.talos/events.jsonl`) is resolved relative to the **main repository root** via `git rev-parse --git-common-dir` — so a developer/QA/reviewer stage running from inside a per-issue worktree still appends to the one log file shared by every worktree of the repo. `.talos/` is gitignored by default.

Appends are a single `printf '%s\n' >>` (one `O_APPEND` write syscall) — a JSON event line is well under the POSIX `PIPE_BUF` atomic-write threshold, so concurrent stages appending at once (e.g. under `issues.max_parallel`) never interleave partial lines. No file lock is used or needed. A failure to write (unresolvable path, permissions, disk full) is a stderr note only — it never affects the pipeline's exit code.

Read the log with `scripts/pipeline-events.sh`:

```
bash scripts/pipeline-events.sh path
bash scripts/pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
bash scripts/pipeline-events.sh tail [--issue N]
```

`list` (and `tail`, shorthand for `list --last 20`) print one line per matching event, oldest first: by default a compact tab-separated table (`ts`, `event`, `role`, `issue`, `pr`, `verdict`, `summary` truncated to 80 chars); `--json` prints one JSON object per line instead. A malformed line in the log is skipped, with the count of skipped lines reported once on stderr — never on stdout, and never fatal.

#### Cost accounting

`post_stage` also accepts `--tokens N` and `--tool-uses N` (validated non-negative integers; an invalid or omitted value is `null` in the payload, with one stderr note for an invalid value), stored alongside `duration_s`. Summarize with `bash scripts/pipeline-events.sh cost [--issue N] [--json]`: a per-issue, per-role table (`issue`, `role`, `events`, `tokens`, `tool_uses`, `duration_s`, `n/a`) with a `TOTAL` row — `n/a` counts events with a null `tokens` field (e.g. adapter-path runs, which record duration only) so an untracked group is visible rather than reading as a real zero.

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
| `epic-acceptance-pending.md` | orchestrator | `${HEADER}`, `${DETAILS}` |
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
| `TALOS_BOARD_MAX_PAGES` | overrides the page cap for `pipeline-status.sh`'s items() pagination loop (default `50`, i.e. 5000 items at 100/page). A non-positive-integer value falls back to the default with a warning on stderr. Hitting the cap, or a malformed page (`hasNextPage=true` with an empty cursor), bails out via `talos:board-unverified` instead of looping forever. |

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
   - **Developer** spawns in an isolated git worktree. It implements, iterates with targeted tests (`verify.targeted`, default `true`), then runs your full `verify` commands exactly once before its final commit, and opens a PR. The worktree is removed (branch and all) right after the PR merges, via `pipeline-worktree.sh remove`; a startup sweep reclaims any orphaned worktree as a backstop.
   - **QA** checks out the PR branch and verifies each acceptance criterion. Under `verify.qa_mode: ci` (the default once `merge.required_checks` is set) it does not re-run `verify:` — it waits for CI to go green and fails closed if it doesn't; under `local` it runs `verify:` once itself.
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
| `scripts/pipeline-config.sh KEY [default]` | Dot-path config reader (YAML/JSON); use `--dump` to print the entire resolved config as NUL-delimited key/value pairs |
| `scripts/pipeline-cfg-cache.sh` | Per-invocation config cache that eliminates redundant python3 parses (sourced by pipeline-*.sh internally) |
| `scripts/pipeline-contract.sh` | Single source of truth for roles, labels, and `talos:` markers (sourced by pipeline-vcs.sh and bootstrap-labels.sh; see "Contract" below) |
| `scripts/pipeline-vcs.sh [--dry-run] <verb> [args...]` | Uniform VCS adapter (github/gitlab/azure/file) |
| `scripts/pipeline-status.sh [--dry-run] <issue> <status>` | Set GitHub Project board status |
| `scripts/pipeline-notify.sh <event> <ref> <message> [thread_key]` | Post event to Slack/Discord/Teams |
| `scripts/bootstrap-labels.sh [owner/repo]` | Create `pipeline:*` labels (idempotent) |

### Contract

`scripts/pipeline-contract.sh` is the single source of truth for every role name, `pipeline:*`/`qa:pass`/`review:approved`/`security:approved`/`docs:done`/`spec:ready`/`skip-qa` label, and `talos:` marker Talos uses (issue #178 -- previously restated across `pipeline-vcs.sh`, `bootstrap-labels.sh`, and the prompts, and drifting silently). It's a plain sourceable bash file (indexed arrays, bash 3.2 compatible) that `pipeline-vcs.sh` and `bootstrap-labels.sh` read instead of hand-duplicating the lists, plus a `talos_contract_json` function that prints the whole contract as JSON. `tests/test-contract.sh` greps `skills/pipeline/SKILL.md`, `agents/*.md`, `templates/**`, `README.md`, and `docs/user-guide.md` for every such string and fails if any is missing from the contract.

### pipeline-vcs.sh verbs

| Verb | Arguments | Description |
|------|-----------|-------------|
| `create-issue` | `<title> <body-file> [--label label]` | Create a new issue; `--label` may be repeated (used by planner to create sub-issues). Exits non-zero if the POST fails. |
| `list-issues` | | List open issues / unchecked plan items |
| `view-issue` | `<id> [--spec]` | Show issue body and metadata. `--spec` (#201) prints the same shape but trims `comments` to at most the latest comment whose body starts with `**PM spec:**`, dropping every `<!-- talos:` marker comment and every stage-verdict comment (body starting with `**Agent:**`) -- also every other comment, including plain human replies, since the spec is the contract each stage implements against. Reuses the paginated `read-comments` fetch, no new request. `github`/`github-api` only (parity); `gitlab`, `azure`, and `file` fall back to the plain full view with a stderr note. |
| `comment-issue` | `<id> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on an issue. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. **Exits 1 if the issue is closed** unless `--allow-closed` is passed (required when GitHub auto-closes via `Closes #N` at merge). Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup (network error), posts (exit 0) and emits `talos:comment-state-unverified target=issue#<N> reason=<short>` on stdout. |
| `close-issue` | `<id> [reason]` | Close an issue |
| `label-issue` | `<id> --add label [--remove label]` | Add/remove labels (or tags for Azure) |
| `check-epic-acceptance` | `<epic-n>` | Scan the epic issue's body for unticked `- [ ] ` checklist boxes (checkboxes inside fenced code blocks count too). Exit 0 with no output when none remain, including bodies with no checkboxes at all. Exit non-zero and print each unticked item's text, one per line, when any remain. GitHub only (#168). Used by the epic auto-close sweep — see docs/user-guide.md's "Working with epics" section for the full flow. |
| `create-pr` | `<branch> <title> <body-file>` | Open a PR targeting base_branch. Exits non-zero if the POST fails. |
| `view-pr` | `<branch>` | Show PR number, URL, status |
| `list-prs` | | List open PRs |
| `diff-pr` | `<pr-number> [--stat]` | Show PR diff (Azure: via `git diff` between refs). `--stat` (#201) prints a `git diff --stat`-style per-file additions/deletions summary instead, derived from the same paginated PR-files endpoint `pr-files` (#200) uses -- no new fetch. `github`/`github-api` only (parity); other providers print the full diff (flag ignored). |
| `checkout-pr` | `<pr-number>` | Check out a PR branch locally |
| `approve-pr` | `<pr-number> [summary]` | Approve a PR |
| `label-pr` | `<pr-number> --add label [--remove label]` `[--require-marker]` | Add/remove PR labels. When an approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) is added and no approval marker exists at the current PR head, a WARNING is printed to stderr and the command exits 0 (non-fatal, so label-then-stamp call sites continue working). Pass `--require-marker` to make this check fatal and pre-apply: the label is not added if no marker is present at the current head (exits 1). `--require-marker` and the post-apply warning are `github` provider only. See **Approval-marker guard** below. |
| `pr-checks` | `<pr-number>` | List CI check statuses |
| `pr-checks-required` | `<pr-number>` | Exit 0 only when every check named in `merge.required_checks` passes on the current head; exit 2 while any is still pending or missing; exit 1 on an explicit failure or when `merge.required_checks` is empty (never a vacuous pass). `github`/`github-api` only -- `gitlab`/`azure` fail closed (exit 1) rather than fail open, since QA's CI-wait loop treats exit 0 as "all required checks passed" (#205); `file` mode fails closed (exit 1) the same way rather than falling into the generic "not applicable" no-op bucket. |
| `merge-pr` | `<pr-number>` | Merge a PR (uses `merge.method` from config) |
| `comment-pr` | `<pr-number> <body> [--allow-closed]` `[--body-file <file>]` | Post a comment on a PR. Pass `--body-file <file>` to read the body from a file (use this for multi-line verdicts). **Passing a readable absolute path as the positional `<body>` argument exits 1** with a `--body-file` hint — use `--body-file` instead. **Exits 1 if the PR is closed without being merged** unless `--allow-closed` is passed. Merged PRs are always commentable without the flag. Prints the comment `html_url` to stdout on success. Exits non-zero if the POST itself fails (see below). On an indeterminate state lookup, posts (exit 0) and emits `talos:comment-state-unverified target=pr#<N> reason=<short>` on stdout. |
| `find-pr` | `<issue-number> [open\|merged\|all]` | Find PRs belonging to an issue (session-recovery adoption) |
| `check-pr-files` | `<pr-number>` | Exit 1 if the PR touches `merge.forbidden_files` patterns |
| `pr-files` | `<pr-number>` | Print the PR's changed paths, one per line — no filtering or exit-1 gate (unlike `check-pr-files`). Fully paginated (`gh api --paginate` / `_ga_fetch_all_pages`, the same #171 pattern as `list-issues`/`list-prs`), so PRs with more than 100 changed files are never silently truncated; a failed page exits non-zero with no partial output. Used by the Step 3e Phase 1 `roles.docs_mode: auto` gate (#200) to decide whether the docs stage needs to dispatch at all. GitHub provider only (`github`/`github-api` parity); `gitlab`, `azure`, and `file` fail open with a stderr warning and empty stdout. |
| `check-closing-keyword` | `<pr-number> <issue-n>` | Exit 1 if the PR body carries a closing keyword (`Closes/Fixes/Resolves #N`, all standard verb forms, case-insensitive, including `owner/repo#N` and full GitHub issue URL forms — both scoped to the current repository — and `GH-N` (case-insensitive)) while other PRs referencing issue `N` are still open. Fail-open: exits 0 and emits `talos:closing-keyword-unverified pr=<N> issue=<N> reason=<literal>` on stdout when PR body or sibling list cannot be fetched or repository cannot be resolved. GitHub provider only; no-op under gitlab, azure, and file. |
| `rerun-ci` | `<pr-number>` | Re-run failed CI runs for the PR head SHA (flaky-CI retry) |
| `pr-head` | `<pr-number>` | Print the current head SHA for a PR. Fail-closed: exits 1 when the SHA cannot be resolved. Used by approval roles to stamp the SHA they approved. |
| `pr-mergeable` | `<pr-number>` | Print exactly one of `MERGEABLE` / `CONFLICTING` / `UNKNOWN` on stdout; exit 0/1/2 respectively (#214). `github`/`github-api`: reads `mergeable` (GitHub computes it lazily) and retries up to 4 times, sleeping a `TALOS_RETRY_SLEEP_SCALE`-scaled 2s between attempts, before giving up and reporting `UNKNOWN`. `gitlab`/`azure`: best-effort off their own merge-status fields; an inconclusive status reports `UNKNOWN` with a stderr note. `file` mode: always `UNKNOWN` (no PR concept). Used before dispatching QA and before QA's CI wait, since a `CONFLICTING` PR gets no `pull_request` CI run to wait for. |
| `conflict-files` | `<pr-number>` | Print the paths that conflict between the PR's head and `origin/<base_branch>`, one per line (#256). Resolved with a throwaway `git merge --no-commit` in a detached temp worktree created outside the caller's own checkout — `git status`/`assert-sync` on the caller's checkout are unaffected, and the worktree is removed on every exit path. Exit 0 with output when conflicting, exit 0 with no output when clean, exit 2 when it cannot be determined (fetch or worktree failure). `github`/`github-api` only, backed by one shared implementation. Used by the Step 3c mergeability gate to decide whether a `CONFLICTING` PR qualifies for `pipeline-mergebase.sh`'s mechanical union merge instead of a developer merge-base dispatch. |
| `check-approval-sha` | `<pr-number> [--stale-list]` | Exit 1 if any approval label (`qa:pass`, `review:approved`, `security:approved`, `docs:done`) was earned against a non-current head SHA whose delta is not fully covered by `merge.approval_waiver_paths`. Pass `--stale-list` to additionally print one greppable stdout line per stale role (`stale role=<role> label=<label>`); stderr and exit codes are unchanged. Fail-closed: unresolvable head SHA, missing marker, invalid waiver config, or `git diff` failure all exit non-zero. |
| `record-attempt` | `<issue-n> <stage> [--pr <pr-n> \| --idempotency-key <token>]` | Record one re-dispatch attempt for the given blocking stage on the issue. Reads prior state, computes the new per-stage count and running total, posts a `<!-- talos:attempt -->` marker comment on the issue, verifies the write landed, and prints `stage=<s> count=<k> total=<t>` on stdout. Exits non-zero when either ceiling (`max_fix_attempts` or `max_total_dispatches`) would be reached by this attempt — callers must check the exit code before re-dispatching the developer. Fail-closed: a corrupt or unparseable marker exits non-zero rather than silently resetting to zero. **`--pr <pr-n>` (#172 follow-up):** derives the idempotency key itself as `<stage>-<pr-head-sha>` by resolving the PR's current head SHA server-side (same call as `pr-head`) — the caller never mints a token by hand, so the exact same command run again in a fresh shell or a fresh orchestrator process recomputes the same key as long as the PR head has not moved, and dedupes correctly. Fails closed (exit 1, nothing posted) if the head SHA cannot be resolved; mutually exclusive with `--idempotency-key`. **`--idempotency-key <token>` (#172):** when the most-recent marker already carries this stage and `key=<token>`, does not post again — reprints the existing (unincremented) counts and exits with the status those counts already imply. `token` must match `[A-Za-z0-9._-]+` (invalid token exits 1 before anything is posted). Intended only for stages with no PR yet (`--pr` is unavailable before a PR exists); prefer `--pr` whenever a PR number is known. Omitted entirely: unchanged back-compat behaviour (always posts). **Limitation:** `--pr` dedupes a retry at the same head across any process, including a fresh orchestrator restart — it cannot distinguish two genuinely separate attempts recorded while the head happens not to have moved. `--idempotency-key` (or no key at all) still only dedupes within the process that minted the token; it cannot detect a retry across a fresh orchestrator process. |
| `read-attempt` | `<issue-n>` | Print the current attempt state (`stage=<s> count=<k> total=<t>`, plus a trailing ` key=<token>` when the marker carries one) from the most-recent attempt marker on the issue. Prints `stage= count=0 total=0` when no marker exists (a new issue). Always exits 0 unless the marker is corrupt (in which case it exits 1, fail-closed). Read-only; does not post a new comment. Internally fetches via `read-comments` (fully paginated, no 100-comment cap). |
| `read-comments` | `<issue-or-pr-n>` | Print every comment on an issue or PR as `{"comments": [...]}`, fully paginated (`gh api --paginate` for `github`, Link-header pagination for `github-api` — no 100-comment cap). Shared reader used internally by `read-attempt` and by `post-approval`'s duplicate-marker check (#172). Fail-closed: prints nothing and exits 1 on any page failure. |
| `check-attempt` | `<issue-n>` | Exit 1 (with reason on stderr) when either ceiling is already reached for the issue. Exit 0 otherwise. Does **not** record a new attempt — use `record-attempt` for that. Fail-closed: propagates a corrupt-marker exit 1 from `read-attempt`. |
| `assert-sync` | | Assert the orchestrator working tree is clean and current with `origin/<base_branch>`. **Dirty tree** (any uncommitted change) — exits 1, names the dirty files, instructs operator to commit or stash; this check runs *before* `git fetch origin` so the tree is never read in a mixed state. **Behind origin** — exits 1, prints both local and remote SHAs plus the commit gap, instructs `Run: git pull --ff-only`. **Diverged** (ahead and behind simultaneously) — exits 1, warns against force-push. **Ahead of origin only** — exits 0 but prints a stderr warning: *"pipeline-vcs: assert-sync: WARNING -- working tree is ahead of origin/<base> by N commit(s); non-isolated stages will read unpushed commits."* **Clean and level** — exits 0, no output. `base_branch` is resolved in order: `talos.pipeline.yml` config key, then `git symbolic-ref refs/remotes/origin/HEAD`, then `main`. Provider-agnostic; runs before the VCS provider dispatch. |
| `has-spec` | `<issue-n>` | Exit 0 when the issue body IS a usable spec (contains an "acceptance criteria" heading with at least one checklist item, or carries the `spec:ready` label); exit 1 otherwise. GitHub only (`github` and `github-api` providers). Used by PM skip-when-spec-present logic to detect when an issue is ready for direct developer dispatch. |
| `slug-for` | `<title>` | Derive a 40-character-or-less branch slug from an issue title (lowercased, non-alphanumeric runs collapsed to `--`, trimmed). Provider-agnostic; used for consistent branch naming in both the PM skip path and developer `fix/issue-<n>-<slug>` / `feat/issue-<n>-<slug>` branches. |
| `post-approval` | `<pr-number> <role> [--body-file <path>]` | Fetch the current head SHA via `pr-head`, construct the `<!-- talos:approval sha=<sha> role=<role> -->` marker, append it as the last line of the comment body (from `--body-file` or an empty body when the flag is omitted), post the comment via `comment-pr`, and apply the role's approval label -- all in one atomic operation. Valid roles: `qa`, `reviewer`, `security`, `docs`; an invalid role exits 1. GitHub and `github-api` providers only; non-GitHub providers exit 1. This is the recommended way for every review stage to close the approval gate -- it eliminates the five failure modes observed when markers were constructed by hand: three missing the `<!-- -->` wrapper, one carrying a placeholder SHA, and one where the label was applied with no marker at all. **Duplicate-marker check (#172):** before posting, fetches every PR comment via `read-comments` (fully paginated) and looks for this exact marker as the last non-whitespace line of any comment. Found at the **same head SHA** — prints a stderr note and exits 0 **without posting again** (the approval label is still applied defensively, since `label-pr` is idempotent). Re-stamping at a **different** head SHA is a different marker string and always posts. The comment fetch itself failing exits 1 with nothing posted (fail-closed) — a partial page set is never mistaken for "no duplicate found". |

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

**Approval-SHA model.** Each approval role stamps `<!-- talos:approval sha=<HEAD_SHA> role=<role> -->` in its verdict comment when posting a pass. At Step 4, `check-approval-sha` compares every present approval label's stamped SHA against the current PR head. If a stamped SHA is older than the current head, the tool runs `git diff <approval-sha>..<current-head>` to collect changed files, then intersects that set with the PR's own file set (computed via `git diff origin/<base>...<current-head>`, a three-dot diff against the base branch) to exclude files that arrived purely from a routine base-branch sync. Every file remaining in the intersection is checked against `merge.approval_waiver_paths`. A file touched by both the sync and the PR stays in the intersection and is evaluated normally. If the three-dot diff cannot be computed, the full two-dot set is used (fail-closed). If any non-waivable file remains after filtering (or the two-dot diff cannot be computed), the gate blocks the merge, strips the stale labels, and the orchestrator re-dispatches the affected stages. A human sees a PR comment listing which labels were stale and why; the fix is to re-run the affected stage (e.g. ask QA to re-approve after a source-code push). Re-dispatch is selective: `check-approval-sha --stale-list` reports only the roles that are actually stale, and the orchestrator re-runs only those — a docs approval whose delta is confined to `*.example` or other waived paths re-stamps `docs:done` against the current head without re-running the docs stage at all.

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

**`post-approval` -- the recommended single-command path.** Use `post-approval <pr> <role> [--body-file <path>]` instead of constructing the marker by hand. It fetches the head SHA, builds the wrapped marker, appends it to the comment body, posts the comment, and applies the label -- all in one step. Before `post-approval` existed, five distinct failure modes were observed: three markers posted without the `<!-- -->` wrapper, one with a placeholder SHA, and one where the label was applied without any marker. Using `post-approval` eliminates all five. Example (qa stage):

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

### Per-role runner override (`agents.roles.<role>.runner` / `.runner_cmd`)

`agents.runner` picks one backend for the whole pipeline. `agents.roles.<role>.runner` (and `.runner_cmd`) overrides it for a single role, on **both** execution paths — resolved role-first: the role's own key wins when set, else `agents.runner` (default `claude`); `runner_cmd` follows the same precedence and is only read when the resolved runner is `custom`. `agents.runner_args` stays global-only — there is no `agents.roles.<role>.runner_args`.

```yaml
agents:
  runner: claude                 # pipeline default, unchanged
  roles:
    qa:
      model: claude-opus-5       # existing per-role model override, unchanged
    reviewer:
      runner: custom             # this role only — everything else stays claude
      runner_cmd: "…"            # required when runner: custom
```

On the native path (Claude Code, `subagents: true`), a role whose effective runner is `claude` still spawns as a native subagent; a role whose effective runner is anything else is dispatched via `bash scripts/pipeline-agent.sh <role> - <<'PROMPT' ... PROMPT` instead — the orchestrator makes this decision per role, so the rest of the pipeline keeps running natively. On the adapter path, `pipeline-agent.sh` already resolves the same precedence internally, so no config change is needed to get the per-role behaviour there.

Run `bash scripts/pipeline-agent.sh --resolve <role>` to see what a role will actually use — it prints `runner=<r> runner_cmd=<c> model=<m>` without running anything, and it is the same resolution the orchestrator and `pipeline-agent.sh` itself use, so it never drifts from the real dispatch.

**Second opinion on a local model:** point one role at a llama.cpp-served model while the rest of the pipeline stays on the default runner — e.g. give `security` (or any single stage) an independent pass through a local model without rerouting everything:

```bash
# --jinja enables tool/function calling — agentic CLIs need it
llama-server -m qwen2.5-coder-32b-instruct-q4_k_m.gguf --port 8080 -c 32768 --jinja
```

```yaml
agents:
  runner: claude                 # everything else: native Claude subagents
  roles:
    security:
      runner: custom
      runner_cmd: >-
        OPENAI_API_BASE=http://localhost:8080/v1 OPENAI_API_KEY=local
        aider --model openai/local --yes-always --no-auto-commits --message "$(cat)"
```

Every other role keeps running natively; only `security` pays the local-model round trip, and it costs nothing per PR since the endpoint is local.

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

## Worktree lifecycle

**Policy:** a stage's working copy lives exactly as long as the stage needs it — every developer, QA, reviewer, security, and docs worktree (and its scratch branch) is removed as soon as the PR it belongs to merges or closes, and anything left behind that doesn't belong to an issue still in the queue or with an open PR is garbage, removed on sight regardless of dirty/unpushed state.

Only the developer worktree identifies itself by naming convention (`fix|feat/issue-<N>-...`); the other stages get a Claude Code harness `agent-*` worktree with no issue number in its name, so QA and docs run `pipeline-worktree.sh tag <N>` as their first step to write `<worktree>/.talos/env` (reviewer and security hold no worktree under normal operation, so they only tag if the harness happens to give them one). `remove <N>` (post-merge) and `sweep [<open-id>...]` (Step 1 startup backstop and Step 5 end-of-run) both use this tag — or the naming convention — to find every worktree for an issue, developer and harness alike; `sweep` additionally deletes local branches that are not main/master/base, don't track a live remote, and aren't the head of an open PR, and prints `talos:worktree-sweep removed=<n> kept=<n> freed=<size>`. `pipeline-worktree.sh status` reports current worktree/dirty/branch counts and total `.claude/worktrees` disk usage.

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
```

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
`tasks/**`, `docs/superpowers/**`, `.github/**`, and `.gitignore` (each
proven, via a `grep -l` sweep of every `tests/test-*.sh`, to be read by no
test) -- touching any other git-tracked file, including `tests/run-tests.sh`
itself, invalidates every cached result. Only tracked files are hashed;
untracked files are ignored by design and cannot invalidate the cache. A
cache hit prints `CACHED tests/<name>.sh` and skips re-running the file; a
failing file is never cached. `--no-cache` ignores the cache entirely (reads
and writes); CI always runs with `--no-cache`. If neither `sha256sum` nor
`shasum` is available, caching is disabled outright (with a warning) rather
than key on a degraded hash.

CI runs the suite on Ubuntu and macOS for every push and PR
(`.github/workflows/tests.yml`). Test sandboxes unset Talos and Claude
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

---

## Credits

Talos is a distillation of [Daedalus](https://github.com/benmarte/daedalus) — a full-featured Hermes plugin with a 9-agent roster, kanban board, dashboard, and per-project config. If you need multi-project management, a dashboard UI, or a long-running daemon, use Daedalus. If you want a drop-in, zero-infrastructure pipeline driven from a Claude Code session — supporting GitHub (battle-tested), GitLab, Azure DevOps, and a local file mode — this is it.
