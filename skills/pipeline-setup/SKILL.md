---
name: pipeline-setup
description: Interactive onboarding for Talos. Detects the repo, asks a few questions, writes talos.pipeline.yml, bootstraps labels, fires a test notification, and leaves the repo ready to run the pipeline (`/pipeline` in Claude Code, or in any other agent Read ~/.talos/skills/pipeline/SKILL.md and follow it).
---

You are the **pipeline setup wizard**. Walk the user through configuring Talos for this repo. Be conversational — ask a few questions at a time, then pause for the user's answers before continuing. Do not ask all questions in a wall of text.

Any agent can run this wizard: `Read ~/.talos/skills/pipeline-setup/SKILL.md and follow it` (Claude Code also has `/pipeline-setup`). Where a step says to ask, ask in plain text and wait for the answer; use a question tool only if your harness has one.

**Script location:** resolve once before anything else, and reuse the answer — every `bash scripts/<name>.sh` below means the directory you resolve here:

```bash
for d in \
  "${TALOS_HOME:+$TALOS_HOME/scripts}" \
  "$HOME/.talos/scripts" \
  "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
  ".claude/talos/scripts" \
  "scripts"; do
  [ -n "$d" ] && [ -f "$d/pipeline-config.sh" ] && { echo "$d"; break; }
done
```

Five cases, in priority order: explicit override ($TALOS_HOME), global install (~/.talos), marketplace plugin, vendored into the repo by install.sh (.claude/talos/scripts), or the Talos source repo. The global install wins when present; the plugin falls back to its bundled copy only when no global install exists. If it prints nothing, Talos is not installed — tell the user and stop.

---

## Step 0 — Detect existing config

Check whether `talos.pipeline.yml` or `pipeline.yaml` already exists in the current directory.

If a config **exists**:
- Read it with `bash scripts/pipeline-config.sh <key> <default>` to show current values.
- Tell the user: "Found an existing config. Here's what's set: ..."
- Ask: "Would you like to update any of these settings, or is this just a re-run to bootstrap labels?"
- If no changes needed: check `bash scripts/pipeline-config.sh status.enabled unset`. If it prints `unset` (no `status:` block yet), ask Step 4b's question once; on yes add ONLY the `status:` block to the existing file (show the lines to add and write only after an explicit yes; never rewrite the rest of the file, per the Idempotency rules), then run Step 7b.
- If no changes needed and `bash scripts/pipeline-config.sh vcs.provider github` prints `github`: check `bash scripts/pipeline-config.sh evidence.enabled unset`. If it prints `unset` (no `evidence:` block yet), ask Step 4c's question once; on anything but "ask me later" add ONLY the `evidence:` block to the existing file (show the lines to add and write only after an explicit yes; never rewrite the rest of the file, per the Idempotency rules). "Ask me later" writes nothing. A config that already has `enabled: false` is never re-asked.
- If no changes needed, in every case (whatever the check above printed): run Step 7c with the harness from `bash scripts/pipeline-config.sh agents.runner claude`, then jump to Step 8 (bootstrap labels) and Step 10 (test notification).

If **no config**: continue to Step 1.

---

## Step 1 — Detect repo and VCS provider

Run these detections (silently, just to have the answers ready):

```bash
# Repo info
git remote get-url origin 2>/dev/null
git branch --show-current 2>/dev/null
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||'  # default branch
```

Detect likely VCS provider from the origin URL:
- Contains `github.com` → "github" (detected)
- Contains `gitlab.com` or `gitlab.` → "gitlab"
- Contains `dev.azure.com` or `visualstudio.com` → "azure"
- No remote or unclear → offer "file" mode as an option

Detect likely verify commands:
- `pytest.ini` or `pyproject.toml` present → `python -m pytest tests/ -x -q`
- `package.json` present → `npm test`
- `Makefile` with a `test` target → `make test`
- `Cargo.toml` present → `cargo test`
- Nothing detected → will ask

---

## Step 2 — Ask: VCS provider and base branch

Present your detections and ask (2 questions):

> "I detected this repo is hosted on **[provider]** and the default branch is **[branch]**. 
>
> 1. Which VCS provider are you using? (github / gitlab / azure / file)
>    [detected: **github**]
> 2. Which branch should PRs target? This is usually your integration branch, not main.
>    [detected: **dev**]"

Wait for answers before continuing.

---

## Step 3 — Ask: verify commands

> "What commands should every code change pass before a PR is opened?
> [detected: `python -m pytest tests/ -x -q`]
> (Enter commands one per line, or 'none' to skip, or press Enter to use the detected ones)"

Wait for answer.

---

## Step 4 — Ask: roles

> "Which review stages should run? (all are on by default except adversarial)
> - validator: Phase-1 gate — confirms the issue is real [on]
> - pm: Writes the implementation spec [on]
> - qa: Verifies the PR satisfies acceptance criteria [on]
> - reviewer: Code-quality review [on]
> - security: Security review [on]
> - docs: Updates README/CHANGELOG [on]
> - adversarial: Optional pre-merge second opinion — attacks the diff for
>   vacuous tests, weak patterns, secret shapes and unverified claims [off]
>
> Type the names of any you want to turn OFF (or, for adversarial, ON), or
> 'none' to keep the defaults."

Wait for answer.

If the user turns `adversarial` **on**:
> "Adversarial is usually paired with an independent second backend so it
> isn't grading the same model that wrote the diff. Should it run on the
> same agent harness as everything else, or a different one (e.g. a local
> model via a custom runner)?
> [default: same harness — no extra config needed]"

If they want a different backend, record it the same way as Step 6b's
`custom` harness answer (runner + optional `runner_cmd`); this is written as
`agents.roles.adversarial.runner` (and `runner_cmd` when custom), not the
top-level `agents.runner`, so only adversarial pays for the different
backend.

Also ask (2 more questions, defaults shown, only if the user wants to change them):
> "Two more role toggles, both fine to leave at their defaults:
> - Skip PM when an issue's body is already a usable spec (an acceptance-criteria
>   heading with checklist items, or the `spec:ready` label)? [on — `roles.pm_skip_when_spec_present`]
> - How should docs decide whether to dispatch: `auto` (skip the docs subagent
>   when the developer's diff already covers CHANGELOG + README/docs, or is
>   scripts/tests-only with a CHANGELOG entry) or `always` (docs subagent always
>   runs and reads the full diff)? [auto — `roles.docs_mode`]"

---

## Step 4b — Ask: status file

When `vcs.provider: file`, skip this question with one line ("No status file: file mode has no PRs to log.") and record it as declined. Otherwise ask once:

> "Keep a status file in this repo? It is a short page, `TALOS_STATUS.md`, that records what merged and what is waiting on you, so a stopped run can be resumed later, with any LLM. Note: Talos commits updates to it straight to your base branch, so a protected base branch will not work.
> [default: **yes**]"

On yes: `status.enabled: true` in Step 7, then Step 7b creates the file. On no: the block is written declined, and Step 7b is skipped.

---

## Step 4c — Ask: evidence capture

When `vcs.provider` is `gitlab`, `azure` or `file`, skip this question with one line ("No evidence capture: it posts screenshots to GitHub PRs.") and it writes no evidence: block. Otherwise (github) first check that `gh` can attach files. This tests the machine running setup; the machine running the pipeline needs the same.

```bash
gh pr comment --help 2>&1 | grep -q -- '--attach'
```

If it exits non-zero (no `--attach` in the help, or no `gh`), say "Evidence capture needs gh 2.99.0 or newer (`gh pr comment --attach`); this machine's gh does not have it", offer only "off", and on "off" write the declined block (Step 7). Otherwise detect the repo's test harness, from the repo root, with the same signals `agents/developer.md` uses:

```bash
pw=no; cy=no; e2e=no
for f in playwright.config.*; do [ -e "$f" ] && pw=yes; done
for f in cypress.config.*; do [ -e "$f" ] && cy=yes; done
{ [ -d tests/e2e ] || grep -q '"test:e2e"' package.json 2>/dev/null; } && e2e=yes
echo "playwright=$pw cypress=$cy e2e=$e2e"
```

Propose from the output:
- `playwright=yes cypress=no`: `command: "npx playwright test --grep @evidence"` and `dir: test-results`. Tell the user to set `use: { screenshot: 'on', video: 'on' }` in the Playwright config and to tag the tests to capture `@evidence`.
- `cypress=yes playwright=no`: `dir: cypress/evidence` (the default `cypress/` holds tracked tests), and tell the user to point `screenshotsFolder` and `videosFolder` there. Suggest `npx cypress run` as the command, an editable suggestion only.
- Both: ask which one to use, then propose as above.
- Neither (`e2e=yes` alone is neither: no command can be inferred, so ask for one): offer agent capture or off. Agent capture leaves `command` empty (omitted): QA's browser skill saves screenshots into `dir`, best effort, with no recordings.

A command the user types goes into the config as text only; setup never runs it. Ask once, naming the costs:

> "Attach screenshots or recordings of a user-facing change to its PR, as evidence? Before you say yes:
> - Attachments are public on public repos: anyone can open the file without signing in. On private and internal repos the repo's access rules apply.
> - Screenshots and recordings can contain on-screen secrets (tokens, emails, internal URLs).
> - GitHub's attachment size limits apply: 10 MB images, 10 MB videos on free plans, 100 MB videos on paid plans. It is not verified that `gh --attach` accepts `.webm` recordings (Playwright's video format), so Talos does not promise it; images and videos only.
>
> Proposed: `<command>` into `<dir>`. [default: **off**] (on / off / ask me later)"

On "ask me later" write nothing; the Step 0 re-run asks again. On "off" write the declined block. On "on": use the proposed or a typed `dir`, which is one repo-relative path. `<dir>` goes on a command line, so first check it character for character: 1 to 200 characters, only letters, digits, `.`, `_`, `/` and `-`, not starting with `-` or `/`, no `..` component, no `.git` component. If it fails, say why and ask again; never write it. The two proposed directories are constants and always pass.

Then offer to keep it out of git: "Add `<dir>/` to `.gitignore`? (yes/no)". Run the block below either way, with the checked directory as the first quoted argument (replace `<dir>`) and `<mode>` replaced by `write` on an explicit yes or `check` otherwise (give the heredoc a fresh `TALOS_<rand>` delimiter of 12+ random characters you invent). Only `write` touches `.gitignore`. Both modes re-check the value and write nothing if it fails, and print the normalised directory as `dir=<norm>` (`./` stripped, `//` collapsed, no trailing `/`): that printed value, never the typed text, is what Step 7 writes as `evidence.dir`, so the config and the `.gitignore` line cannot disagree. `write` probes `<dir>/.probe` because a directory that does not exist yet reads as unignored when probed directly, appends one line (`<norm>/`) only when git does not already ignore it, and refuses, writing nothing, when `.gitignore` is a symlink or not a regular file (it prints one line telling you to add `<norm>/` by hand; a missing `.gitignore` is created). Both warn when the directory already holds tracked files (the attach step refuses a tracked directory):

```bash
bash -s -- '<dir>' <mode> <<'TALOS_<rand>'
export LC_ALL=C
die() { echo "rejected: $1" >&2; exit 1; }
d="$1"
case "$d" in ''|-*|/*|*[!A-Za-z0-9._/-]*) die "not a valid evidence dir";; esac
[ "${#d}" -le 200 ] || die "longer than 200 characters"
norm=""
IFS=/ read -ra parts <<< "$d"
for p in "${parts[@]}"; do
  case "$p" in ''|.) continue;; ..) die "a .. component";; esac
  [ "$(printf '%s' "$p" | tr A-Z a-z)" = ".git" ] && die "a .git component"
  norm="${norm:+$norm/}$p"
done
[ -n "$norm" ] || die "no directory left after normalising"
echo "dir=$norm"
cd "$(git rev-parse --show-toplevel)" || exit 1
git check-ignore -q -- "$norm/.probe"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "already ignored: $norm/"
elif [ "$rc" -eq 1 ] && [ "${2:-}" != "write" ]; then
  echo "not ignored: $norm/"
elif [ "$rc" -eq 1 ]; then
  if [ -L .gitignore ] || { [ -e .gitignore ] && [ ! -f .gitignore ]; }; then
    die ".gitignore is a symlink or not a regular file; add $norm/ to it by hand"
  fi
  if [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore)" ]; then echo >> .gitignore; fi
  printf '%s/\n' "$norm" >> .gitignore
  echo "added $norm/ to .gitignore"
else
  die "git check-ignore failed (exit $rc)"
fi
if [ -n "$(git ls-files -- "$norm" | head -n 1)" ]; then
  echo "warning: $norm already holds tracked files; evidence needs an untracked directory" >&2
fi
TALOS_<rand>
```

On a decline (`check` mode), when the block says `already ignored` or when it refuses, `.gitignore` is not touched. Tell the user to commit the `.gitignore` change with the config. On yes to evidence: Step 7 writes `evidence.enabled: true` with `dir` (the `dir=` value above) and `command`. The workflow files are never edited.

---

## Step 5 — Ask: GitHub Project board (skip for non-GitHub or file mode)

Only ask if provider is github:

> "Would you like to track issues on a GitHub Project board? (y/n)
> If yes, I'll need your project number (run `gh project list` to find it)."

If yes:
> "What's the project number and owner?
> Example: project_number: 2, owner: myorg"

If no (or non-GitHub provider): board.enabled = false.

---

## Step 6 — Ask: notifications (optional)

> "Would you like notifications for pipeline events? (y/n)
> Supported: Slack webhook, Discord webhook, Teams webhook, or bot tokens."

If yes:
> "Which platforms? And do you have webhook URLs or bot tokens ready?
> (You can always add these later via env vars: SLACK_WEBHOOK_URL, DISCORD_WEBHOOK_URL, etc.)"

Then ask:
> "Would you like to filter which events trigger notifications, or receive all of them?
> Receiving all is recommended — the role events (validator, developer, qa, reviewer, security, docs, orchestrator) create the per-issue conversation thread in Slack/Discord. Filtering them out silences the thread with no warning."

If the user wants all events: write `notifications:` with **no `events:` key** (unset = all fire).

If the user wants a filter: **automatically include all role events** regardless of what the user asked to exclude — they may only remove lifecycle events. Build the events list as:
```
# Role events (conversation stream — do not remove)
- validator
- developer
- qa
- reviewer
- security
- docs
- orchestrator
# Lifecycle events (remove any you don't want)
- pr-opened
- merged
- blocked
- issue-closed
- info
```
Then remove only the lifecycle events the user said they don't want. Warn explicitly: "I've kept all role events — removing them would silence the per-issue conversation thread."

If none/no config: omit the `events:` key entirely (all events fire; disabling happens by not setting channel/webhook).

---

## Step 6b — Ask: agent harness

> "Which agent harness will run the pipeline?
> - **claude** — Claude Code spawns native subagents; no extra config needed
> - **pi** — pi runs the stages inline in one session (no subagents)
> - **codex** — Codex CLI executes each role stage via scripts/pipeline-agent.sh
> - **gemini** — Gemini CLI executes each role stage via scripts/pipeline-agent.sh
> - **antigravity** — Antigravity executes each role stage via scripts/pipeline-agent.sh
> - **custom** — a custom agentic CLI; you'll be asked for the command
>
> [default in Claude Code: **claude**; no default for any other agent]"

Wait for the answer. If you are Claude Code, an empty answer means `claude`. Any other agent has no default: ask again until the user names one of the six. A runner id is the `agents.runner` value, not an `install.sh --harness` value.

If the user answers **claude** (or, in Claude Code, presses Enter): record harness = `claude`. No `agents:` block will be written.

If the user answers **pi**, **codex**, **gemini** or **antigravity**: record harness = that value.

If the user answers **custom**:
> "What command should the pipeline call? The prompt will arrive on stdin.
> (Example: `my-agent-cli --model local`)"
Wait for the `runner_cmd` value.

---

## Step 6c — Ask: models

A role's model is set in exactly one kind of place: the Talos config. The shipped agent files carry no `model:` line, so a role you do not configure inherits the session model. Ask once, and write the answer where it applies to every repo.

First look at what is already routed:

```bash
bash scripts/pipeline-agent.sh --resolve-all
```

It prints one line per role: `role=<r> model=<m> restamp_model=<m> origin=<project|global|session default>`. `global` is the user-level file `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json}`; `project` is this repo's config.

**When a routing already exists** (any role with `origin=global` or `origin=project`), show the table and ask:

> "Models are already routed (table above). What would you like to do?
> 1. **Keep** it [default]
> 2. **Change** it (in the user-level file, for every repo)
> 3. **Override for this repo only** (written to this repo's `agents:` block)"

On Keep, skip the rest of this step and write nothing. On Override for this repo only, ask the question below and record the answer for Step 7's `agents:` block instead of the user-level file.

**When nothing is routed yet, or the user chose Change or Override**, ask:

> "How do you want models assigned to roles?
> 1. **One model for every role** — you name one model.
> 2. **Per role** — you name a model for each role enabled in this setup; anything you skip uses the one-model fallback if you also name one.
> 3. **Leave unset** — every role inherits the session model.
>
> A model is the alias opus, sonnet or haiku, or a full model ID; it is stored exactly as typed."

When Step 6b did not answer `claude`, say that a model applies only to roles whose effective runner is `claude` (`agents.roles.<role>.runner: claude`); for the others the model is chosen in that CLI or its `runner_cmd`. Offer **Leave unset** as the default.

Record the answer:
- **One model for every role** — `agents.model: <model>`.
- **Per role** — walk the roles enabled in this setup (Step 4's answers, plus `developer`, which always runs) one at a time and write `agents.roles.<role>.model: <model>` for each. Offer an `agents.model` fallback for the rest; write it if the user names one.
- **Leave unset** — writes nothing, no `agents.model` and no role keys. Every role inherits the session model. An existing user-level file is left as it is.

**Where it is written.** By default into the user-level file, `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.yml` (or `.json` when PyYAML is not importable, or whichever extension already exists there), so the question is asked once and applies to every repo. Only `agents.*` keys are read from that file; never put board, merge, issue or verify settings in it.

- **No user-level file yet** — create it with just the `agents:` keys recorded above.
- **A user-level file exists** — never overwrite it blindly. Build the new content in a scratch file (keep every key already there; change only `agents.model` and `agents.roles.<role>.model`), show `diff -u <existing> <new>`, and write only after an explicit yes. On anything but yes, leave the file untouched and say so. Never overwrite an existing user-level file without showing the diff and getting that yes.

Afterwards run `bash scripts/pipeline-agent.sh --resolve-all` again and show the table so the user can see what each role resolves to and which file decided it.

---

## Step 7 — Write talos.pipeline.yml

Based on the collected answers, write `talos.pipeline.yml` in the current directory using this template (fill in the collected values, comment out sections not configured):

```yaml
# Generated by /pipeline-setup on <date>
# Start the pipeline with `/pipeline` in Claude Code; in any other agent: Read ~/.talos/skills/pipeline/SKILL.md and follow it
base_branch: <BASE_BRANCH>
release_branch: main

vcs:
  provider: <PROVIDER>          # github | gitlab | azure | file
  # repo: <OWNER/REPO>          # omit to auto-detect from git remote

# ── Board (GitHub only) ──────────────────────────────────────────────────────
board:
  enabled: <true|false>
  # project_number: <N>
  # owner: <OWNER>
  status_field: Status
  statuses:
    ready: "Ready"
    in_progress: "In progress"
    in_review: "In review"
    done: "Done"
    blocked: "Blocked"
  # status_map: optional — map pipeline status names to your board's column names.
  # Use this when your project uses different column names than the defaults above.
  # An absent key passes through unchanged; omitting status_map entirely is safe.
  # Example: if your board uses "Needs attention" instead of "Blocked":
  # status_map:
  #   Blocked: "Needs attention"

# ── Verify commands ───────────────────────────────────────────────────────────
verify:
  <VERIFY_COMMANDS — one per line, or empty list>

# ── Merge ─────────────────────────────────────────────────────────────────────
merge:
  method: squash
  required_checks: []
  delete_branch: true
  # forbidden_files:           # PR paths matching these glob patterns block the
  #   - ".env"                 # merge for human review (defaults shown; basename
  #   - ".env.*"               # and full path are both matched)
  #   - "*.pem"
  #   - "*.key"
  #   - "*.p12"
  #   - "*.pfx"
  #   - "*.secrets"
  #   - "secrets.*"
<IF_EXTRA_FORBIDDEN_PATTERNS>
  forbidden_files:
    - ".env"
    - ".env.*"
    - "*.pem"
    - "*.key"
    - "*.p12"
    - "*.pfx"
    - "*.secrets"
    - "secrets.*"
<EXTRA_FORBIDDEN_PATTERNS — one per line, indented>
</IF_EXTRA_FORBIDDEN_PATTERNS>

# ── Issue selection ───────────────────────────────────────────────────────────
issues:
  label_filter: "pipeline:ready"
  skip_labels:
    - "pipeline:blocked"
    - "wontfix"
  max_parallel: 1

# ── Roles ─────────────────────────────────────────────────────────────────────
roles:
  validator: <true|false>
  pm: <true|false>
  qa: <true|false>
  reviewer: <true|false>
  security: <true|false>
  docs: <true|false>
  adversarial: <true|false>   # optional pre-merge second opinion, off by default (#237)
  # pm_skip_when_spec_present: true  # default; set false to always run PM
  # docs_mode: auto                  # auto (default) | always

# ── Status file (Step 4b) ─────────────────────────────────────────────────────
status:
  enabled: <true|false>
  # file: "TALOS_STATUS.md"
  # fragments_dir: "docs/status.d"   # must be a tracked directory
  # log_days: 30
  # log_max: 50
  # resume_max_lines: 40

# ── Evidence (Step 4c) ────────────────────────────────────────────────────────
evidence:
  enabled: <true|false>
<IF_EVIDENCE_ACCEPTED>
  dir: <EVIDENCE_DIR>             # the normalised dir= value printed by Step 4c
  command: "<EVIDENCE_COMMAND>"   # omit this line on the agent-capture path
</IF_EVIDENCE_ACCEPTED>

# ── Comments ──────────────────────────────────────────────────────────────────
comments:
  enabled: true
  header: "**Agent:** {role} (talos)"
  templates_dir: "templates/comments"

# ── Notifications ─────────────────────────────────────────────────────────────
notifications:
  slack_channel: "<SLACK_CHANNEL_OR_EMPTY>"
  discord_channel: "<DISCORD_CHANNEL_OR_EMPTY>"
  templates_dir: "templates/notifications"
  threading: true
  # events: leave unset to fire all events (recommended).
  # WARNING: if you set a list you MUST include the role events
  # (validator/developer/qa/reviewer/security/docs/orchestrator) or the
  # conversation stream is silently killed. See talos.pipeline.yml.example.
<IF_USER_REQUESTED_FILTER>
  events:
<EVENTS_LIST_WITH_ALL_ROLE_EVENTS_PLUS_CHOSEN_LIFECYCLE_EVENTS>
</IF_USER_REQUESTED_FILTER>

# ── Limits ────────────────────────────────────────────────────────────────────
limits:
  max_fix_attempts: 3

<IF_NON_CLAUDE_HARNESS>
# ── Agent runner (non-Claude-Code harnesses only) ─────────────────────────────
# Claude Code spawns native subagents and ignores this section. Harnesses
# without subagents (Codex CLI, headless runners) execute role stages through
# scripts/pipeline-agent.sh, which uses:
agents:
  runner: <HARNESS>            # claude (default) | pi | codex | gemini | antigravity | custom
  # runner_args:               # extra CLI args for the claude/pi/codex/gemini/antigravity runner
  #   - --full-auto
<IF_CUSTOM_HARNESS>
  runner_cmd: "<RUNNER_CMD>"   # runner: custom — prompt arrives on stdin.
                               # Must be an AGENTIC CLI (executes shell/edits
                               # files); use one backed by a local model
                               # (e.g. Ollama) for fully local pipelines.
</IF_CUSTOM_HARNESS>
</IF_NON_CLAUDE_HARNESS>
```

When writing the file:
- Status file (Step 4b): accepted writes the block above with `enabled: true`; declined (or skipped for `vcs.provider: file`) writes the whole block commented out, `# status:` with `#   enabled: false` under it, so the keys stay visible. A JSON config has no comments: accepted writes `"status": { "enabled": true }` (the other keys keep their defaults), declined and skipped omit the `status` key. The status file is NOT added to `merge.union_paths` (fragments replace union merging).
- Evidence (Step 4c): accepted writes the block above with `enabled: true`, `dir` (the normalised `dir=` value Step 4c printed, never the typed text) and `command` (a typed command is written as a YAML double-quoted string, escaping `\` and `"`; on the agent-capture path omit `command`); the other `evidence.*` keys keep their defaults and `store` is not written (`attach` is the only value). Declined, "off" and "off" after the newer-gh message write an ACTIVE block, `evidence:` with `enabled: false` and nothing else, never a commented one: a commented block reads as unset, so every re-run would ask again. A JSON config gets `"evidence": { "enabled": true, "dir": "<dir>", "command": "<command>" }` when accepted and `"evidence": { "enabled": false }` when declined. "Ask me later" and a skipped provider (`gitlab`, `azure`, `file`) write no `evidence` key.
- If harness = `claude`: omit the `agents:` block entirely (Claude Code spawns native subagents and ignores it).
- Models: a per-repo override chosen in Step 6c goes into this repo's `agents:` block (`model:` and `roles.<role>.model`), even when harness = `claude`. A user-level answer is written by Step 6c itself, not here.
- If harness = `pi`: write the active `agents:` block with `runner: pi` and `subagents: false` (`agents.subagents: false`: pi runs the stages inline).
- If harness = `codex`, `gemini` or `antigravity`: write the active `agents:` block with the chosen `runner` value (for example `runner: antigravity`); omit `runner_cmd`.
- If harness = `custom`: write the active `agents:` block with `runner: custom` and `runner_cmd: "<value the user provided>"`.
- If `roles.adversarial: true` AND the user asked for a different backend for it (Step 4): write (or extend) the `agents:` block with a `roles: { adversarial: { runner: ..., runner_cmd: ... } }` sub-block — same shape as the `docs/user-guide.md` "Second opinion on a local model" example — even when the top-level harness is `claude`, since only `adversarial` is opting out of the native default.

Also ask before writing:
> "The merge gate blocks PRs that touch sensitive file patterns (.env, *.pem, *.key, …). Would you like to add any extra patterns beyond the defaults?"

If yes: write an active `forbidden_files:` list (defaults + the user's extras) in place of the commented-out block.
If no: leave the defaults commented out as shown in the template.

Tell the user: "Written `talos.pipeline.yml`. Here's a summary of what's configured: ..."

---

## Step 7b — Create the status file (only if Step 4b was accepted)

Skip when Step 4b was declined or skipped (`vcs.provider: file`). Otherwise, from the repo root:

```bash
bash scripts/pipeline-status-file.sh init
```

It prints `created`, `appended` (an existing file was missing a heading) or `already has both headings`, and exits 0; it never overwrites an existing file and it does not commit. Tell the user: "Commit `talos.pipeline.yml` and the status file together, so the first run starts from a base that has both." If it exits non-zero, show its message and carry on without the file (`status.enabled` stays true; `init` is safe to re-run).

---

## Step 7c — Offer the AGENTS.md block

`<harness>` must be exactly one of `claude`, `pi`, `codex`, `gemini`, `antigravity`, `custom`: the Step 6b answer or, on the re-run path, the `agents.runner` value read in Step 0. Compare it with those six, character for character; never put any other value on a command line. If it is not exactly one of them (or is empty), ask Step 6b's question again, or skip Step 7c and say why. Show the block:

```bash
bash scripts/pipeline-instructions.sh print
```

Ask once: "Add this to `AGENTS.md` so any agent in this repo finds the Talos playbooks? An existing `AGENTS.md` keeps all its other text: the block is appended, or replaced only between its two markers. (yes/no)" On anything but an explicit yes, write nothing and go to Step 8. On yes:

```bash
bash scripts/pipeline-instructions.sh write . --harness <harness>
```

`write` exits 0 even when it skips, so read its output before saying it worked:
- A stderr line ending `left unchanged`, or a line saying `symlink` or `not a regular file`: nothing was written. Say so, relay the line, and do not claim success.
- Otherwise it prints `created`, `added`, `updated` or `up to date`. Tell the user to commit `AGENTS.md`.
- Relay any Claude Code or Gemini notice. The Talos block is never written into `CLAUDE.md` or `GEMINI.md`. Ask a second question only when `./CLAUDE.md` or `./GEMINI.md` exists and the notice offers `--import-agents-md`: "Add a one-line `@AGENTS.md` import to it? (yes/no)". On yes, re-run the same `write` command with `--import-agents-md` appended (not `install.sh`, whatever the notice says; never on the first run); only a fenced one-line `@AGENTS.md` import is added, and the user commits that file too. For `.claude/CLAUDE.md`, `CLAUDE.local.md`, a file above the repo, or the Gemini notice with no `GEMINI.md`, relay the line to add by hand and ask nothing.

---

## Step 8 — Bootstrap labels (non-file providers)

If provider is NOT "file":
```bash
bash scripts/bootstrap-labels.sh
```

Report which labels were created vs already existed. It is safe to re-run, and a repo that already has Talos labels needs the re-run to get `pipeline:needs-owner`.

If provider is "file": skip labels, tell the user "File mode uses checkboxes for state — no repo labels needed."

---

## Step 8a — Offer to bootstrap the board (when board.enabled is true)

Only ask if `board.enabled` is `true` AND `board.project_number` is already set (i.e. Step 5 recorded an *existing* project). A brand-new project created in Step 9 below doesn't exist yet at this point in the flow — Step 9 offers this same script right after creating it, so skip the prompt here and don't ask twice.

> "Would you like me to provision your board's Status options now?
> (checks/creates the In progress, In review, Done, Blocked, and Ready columns) (y/n)"

If yes:
```bash
bash scripts/bootstrap-board.sh
```
Show its output to the user. Never run this silently or without an explicit yes — a mistaken run against the wrong project number/owner would touch a real board.

If no: skip, tell the user they can run it later with `bash scripts/bootstrap-board.sh`.

If `board.enabled` is `false`, or `board.project_number` isn't set yet: skip this step entirely, no prompt.

---

## Step 8b — Recommended CI workflow (github only)

Only run this step if provider is "github". Skip silently for gitlab/azure/file.

Check whether any workflow under `.github/workflows/*.yml` already runs
`tests/run-tests.sh` (or, if this repo's `verify:` commands name a different
test entry point, that command):

```bash
grep -l "run-tests.sh" .github/workflows/*.yml 2>/dev/null
```

**If a matching workflow already exists: never edit it.** This step only
ever offers to write a brand-new file — it does not modify, append to, or
overwrite an existing workflow under any circumstance. Instead, check
whether that workflow already has `paths-ignore` and `concurrency` keys; if
either is missing, print one line noting that `templates/ci/github-tests.yml`
documents both as CI-cost recommendations, and move on. Do not offer to
apply the template.

**If no workflow runs the test suite:** offer to write one.

> "No workflow runs your test suite yet. Talos ships a recommended CI
> template (`templates/ci/github-tests.yml`) that skips docs-only pushes,
> cancels superseded runs on the same branch, and runs the full OS matrix
> only on merges to your base branch (pull requests run the cheap OS only).
> This is a recommendation, not something Talos enforces — want me to write
> it to `.github/workflows/tests.yml`? (y/n)"

If yes: copy `templates/ci/github-tests.yml` to `.github/workflows/tests.yml`,
substituting the test command for this repo's actual `verify:` command(s) if
they differ from `bash tests/run-tests.sh --no-cache`, and the base branch
name for `main` if this repo's base branch differs. Tell the user it was
written and that the header comments in the file explain each knob.

**Check `merge.required_checks` before finishing this step.** If the
existing (or about-to-be-written) `talos.pipeline.yml`/`.json` names a job
this template only runs on push, not on PRs — most commonly
`test (macos-latest)` — warn explicitly: "your `merge.required_checks`
names `test (macos-latest)`, which this template no longer runs on pull
requests. If you don't remove it, the merge gate will wait forever on every
PR (QA's CI-wait loop waits for a check that will never appear, until
`verify.ci_wait_s` elapses, then fails closed). Remove it from
`merge.required_checks`, or add `macos-latest` back to the `pull_request`
matrix in the workflow you just wrote." This check applies whether the
config was written earlier in this same run (Step 7) or already existed
before setup started.

If no: skip, no file is written.

**Draft PRs (`pr.draft`, on by default, #332, #435).** Offer this only after the
workflow question above is settled. Explain in two lines: by default the
developer opens a DRAFT PR, docs and review run on the draft, and CI runs once,
when the PR is marked ready (one run per issue instead of one per push). The
trade-off: reviewers see the code before CI has proven it; the developer's
local `verify:` run covers most of that risk, and a CI failure the local run
missed costs one extra run.

It only saves anything when the repo's CI pairs with it. Check the workflows
(this only reads; it always exits 0 and prints one status):

```bash
bash scripts/pipeline-draft-check.sh
```

- `ok`: a workflow runs on `pull_request`, lists `ready_for_review` in `types`
  and skips drafts. Nothing to do.
- `no-skip`: PR workflows exist but none skips drafts, so CI still runs on every
  push and nothing is saved. Offer the change below.
- `no-ready-trigger`: a job skips drafts but `ready_for_review` is not in
  `on.pull_request.types`. Marking a PR ready then fires no event, no run ever
  starts, and QA waits for one until `verify.ci_wait_s` expires. Say so plainly
  and offer the change below.
- `none`: no workflow has a `pull_request` trigger, so there is no pairing to
  check. Report it; the workflow question above is the fix.
- `unknown`: the workflows could not be read with confidence. Say so, and ask
  the user to check the requirements below by hand.

For `no-skip` and `no-ready-trigger`, offer a minimal workflow change with
`bash scripts/pipeline-draft-check.sh edit <file>` (`<file>` is a workflow the
check read). It prints the exact diff and writes nothing. It only appends
`ready_for_review` to `on.pull_request.types` and adds `if:
github.event.pull_request.draft != true` to a job that has no `if:`. An existing
job `if:` is never edited: the output lists `manual: job <name>: ...` with the
combined condition `(<existing>) && github.event.pull_request.draft != true`, for
the user to apply by hand. It refuses a symlink or non-regular file (a line
starting `refused:`: relay it and leave the file for the user). Show the user
the diff and the manual lines verbatim and ask "Apply this to `<file>`? (y/n)".
Only after an explicit yes run the same command with `--write`; never edit a
workflow any other way, and leave every workflow you did not offer alone. If the
user says no, ask whether to keep the draft flow anyway (it still works, it just
saves nothing, and on `no-ready-trigger` Step 0 falls back to the ready flow while
`pr.draft` is unset) or to use the ready flow.

- `on.pull_request.types` must include `ready_for_review`. Without it, marking
  a PR ready fires no event, no run ever starts, and QA waits for one until
  `verify.ci_wait_s` expires.
- Each job needs `if: github.event.pull_request.draft != true`. Without it,
  every push to the draft still runs CI and nothing is saved.
- A draft-time run must never report success for a required check. On GitHub
  two cases break this: a required job that is merely skipped (branch
  protection counts a skipped required check as success), and an `always()`
  aggregate "all checks passed" job (it runs when `test` was skipped and goes
  green on a draft push). Give the aggregate job the same `draft != true`
  guard instead of `always()`, or make it fail unless `needs.test.result ==
  'success'`. Ask the user to confirm their required checks cannot go green on a
  draft.
- GitLab and Azure DevOps: the pairing is unverified. The principle is the
  same (the required pipeline or build policy must not pass on a draft, and must
  start when the PR is marked ready); say plainly that Talos has not checked
  those providers' trigger and policy settings, and leave it to the user.

Write `pr:\n  draft: false` to the config written in Step 7 only when the user picks
the ready flow (the non-default); never write `draft: true`, it is the default.
If the provider is `github-api` or `file`, say draft PRs are unsupported there
(the ready flow is used whatever the key says) and write nothing.

---

## Step 9 — GitHub Project setup (optional, github only)

If board.enabled = true AND the user said they don't have a project yet:

Offer to create one:
```bash
gh project create --owner <OWNER> --title "talos" --format json
```

Record the returned project number as `board.project_number` (and the owner as `board.owner`) in `talos.pipeline.yml`, then offer to provision its Status options with the same script Step 8a uses:
```bash
bash scripts/bootstrap-board.sh
```
Show its output — it creates the In progress, In review, Done, Blocked, and Ready options on the field named `board.status_field` (default `Status`; if that field doesn't exist yet, tell the user to add it via the GitHub UI first, the script only manages a field's options, not the field itself).

If the project already exists (Step 5) or the user prefers manual setup: print the five required status names and tell them to add them via the GitHub UI, or run `bash scripts/bootstrap-board.sh` themselves later.

---

## Step 10 — Test notification (optional)

If any notification channel is configured:
```bash
bash scripts/pipeline-notify.sh info "setup" "Talos is configured and ready" 0
```

Report success or failure. If failure, give the user a troubleshooting hint (check env vars, channel IDs, token scopes).

---

## Step 11 — Summary

Print a checklist of everything that was set up:

```
Talos setup complete!

Config:       talos.pipeline.yml
Provider:     <PROVIDER>
Base branch:  <BASE_BRANCH>
Verify:       <commands or "none">
Roles:        validator pm developer qa reviewer security docs [adversarial]
Board:        <enabled/disabled>
Notifications: <configured platforms or "none">
Harness:      <claude (native subagents) | pi | codex | gemini | antigravity | custom>
Status file:  <status.file path, e.g. TALOS_STATUS.md, or "disabled">
Evidence:     <evidence.dir, or "off" / "not asked">

Control labels (created by bootstrap-labels.sh in Step 8):
  p0        — dispatched first (highest priority)
  p1        — high priority
  p2        — low priority (dispatched after p1; unlabeled issues are dispatched last, after p2)
  skip-qa   — bypasses the QA, reviewer, security, and docs gates for this issue
              (CI checks and forbidden-files protection are ALWAYS enforced)
  pipeline:needs-owner — parked waiting on your decision; reply on the issue or PR and the next run clears it
              (never clears pipeline:blocked)

Next steps:
  1. Add the 'pipeline:ready' label to a GitHub issue (or a '- [ ] task' in plan.md for file mode)
  2. Start the pipeline with `/pipeline` in Claude Code; in any other agent: Read ~/.talos/skills/pipeline/SKILL.md and follow it
  3. For GitHub Projects, make sure the Status field has: Ready, In progress, In review, Done, Blocked
     (if your board uses different column names, configure board.status_map to remap them — see the
     example in the config template above; pipeline-status.sh will emit talos:board-unverified on
     stdout and warn to stderr when any required option is missing, so mis-configuration is visible)
  4. Use p0/p1/p2 labels to control dispatch order; use skip-qa to fast-track low-risk issues
```

---

## Idempotency rules

- Never overwrite an existing `talos.pipeline.yml` without the user's explicit confirmation.
- An existing status file is never overwritten: `init` leaves it alone and appends only a missing heading.
- The evidence re-run adds only the `evidence:` block, after an explicit yes; the workflow files are never edited, and `.gitignore` gets one appended line only after its own explicit yes.
- If `bootstrap-labels.sh` reports a label already exists, that is not an error — say "already up to date".
- Running setup a second time on a configured repo should be safe and produce no surprises.

---

## File mode special instructions

If the user chooses `vcs.provider: file`:

1. Ask for the plan file path (default: `plan.md`).
2. If the file doesn't exist, offer to create a starter template:
   ```markdown
   # Project Plan
   
   - [ ] First task
   - [ ] Second task
   ```
3. Explain: "In file mode, `- [ ] Task` items are your work items. The pipeline processes unchecked items, commits changes to a branch, and checks the box when done. No PRs are opened — the developer commits directly."
4. No label bootstrap needed.
5. No board setup needed (the file IS the board).
