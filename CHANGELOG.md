# Changelog

## [Unreleased]

### Added

- **`_is_lane_home` guard in `pipeline-worktree.sh`.** `remove <N>` and `sweep` now refuse to delete a worktree that contains a `.talos-lane-home` marker file. The file is placed by the operator in every long-lived lane home (never committed); it never propagates to disposable per-issue worktrees. Prevents a sweep run from one lane from deleting another lane's working directory.

- **`_is_self` guard in `pipeline-worktree.sh`.** `remove <N>` and `sweep` now refuse to delete the checkout they are running from. In inline harnesses (`agents.runner: pi`) the developer stage works directly in the orchestrator's own checkout, which can match the per-issue branch pattern; removing it would destroy the running session. In subagent mode the guard is a no-op.

- **Multi-lane sweep interlock.** When more than one `.talos-lane-home` marker exists among a repo's worktrees, `sweep` exits 0 without touching anything (safe no-op). Set `TALOS_SWEEP_ALL_LANES=1` to override. The per-issue `remove <N>` verb is always unaffected. Prevents cross-lane sweep collisions in repos that share one remote across multiple pipeline lanes.

- **Lane-scoped `list-prs`.** `pipeline-vcs.sh list-prs` now passes `--base "$BASE_BRANCH"` (from `base_branch` config) to `gh pr list` and includes `baseRefName` in the `--json` field list. Without lane scoping, Step 1 reconciliation in a multi-lane repo can adopt another lane's open PR and merge it into the wrong base. This happened: the qwen-lane sweep merged a canonical-lane PR (base `main`) into `qwen`.

- **`merge.forbidden_files_allow` config key.** An explicit allow-list checked **before** the deny patterns in `check-pr-files`. Glob-matched against filename and full path. Solves the case where a deny pattern (e.g. `.env.*`) over-matches a committed template (`.env.example`) that cannot simply be renamed. See README for usage.

### Security

- **Semantic canary validation in `merge.forbidden_files_allow`.** Allow-list entries are now validated by testing them against canary paths derived from the active deny patterns using the same `fnmatch` rule the gate uses (basename AND full path). An entry is rejected if it would exempt any canary. This replaces the previous character-stripping approach, which caught `*` and `**` but was bypassed by `*/*`, `**/*`, `*[!x]*`, `[a-z]*`, and `config/*`. The validator generates three canary forms per deny pattern (root, nested `sub/dir/<name>`, and prefixed `config/<name>`) so it catches both basename-level and path-level bypasses. The gate fails closed on any invalid entry, naming the entry and the canary it would have exempted.

## [0.13.0] - 2026-08-15

### Fixed

- **The Buzz sink reported success for events the relay rejected.** `_buzz_publish` ran `nak` with `2>/dev/null` and branched on the exit code — but `nak` exits **0 even when the relay refuses the event**, and still prints the locally-signed JSON on stdout (it signs before publishing). So neither the exit code nor stdout distinguished delivered from dropped: a rejected post was recorded as sent and its id persisted as a thread anchor, leaving `~/.talos/threads.json` pointing at an event that was never stored.

  The failure is invisible in exactly the situation you most need it: a bot key that is unadmitted, revoked, or removed from a private channel produces a clean run and a silent channel. Found while configuring a fresh bot against a live relay — the sink "worked" through the entire setup while nothing had ever been delivered. The relay's verdict is only on stderr, so it is now captured and matched (`auth error` / `failed:` / `CLOSED:`), the reason is echoed, and a rejection no longer writes an anchor. Delivery still degrades softly: the script exits 0 regardless.

- **Tests were not hermetic and read the developer's real `~/.hermes/.env`.** `pipeline-notify.sh` scrapes that file for bot credentials, so on a machine with Buzz configured the suite picked up a real relay URL and bot key — inverting credential-absence assertions ("buzz without private key produces no buzz output" started finding a key) and making results depend on whose laptop ran them. `make_sandbox` now exports a sandbox-local `HOME`, seeded with a gitconfig so suites that commit still resolve an identity.

### Added

- **pi harness support — inline one-agent-per-turn mode.** Talos now runs on
  **pi** (a minimal single-agent coding harness) without subagents and without
  `pipeline-agent.sh`. New config `agents.subagents` (`auto` | `true` | `false`)
  selects the execution mode: `true` = native parallel subagents (Claude Code),
  `false` + `agents.runner: pi` = the pi session acts as each stage role itself
  (validator → pm → developer → qa → reviewer/security/docs → merge), one role
  per turn, waterfall handoff. `auto` = true when the runner is `claude`, else
  false. The canonical `pipeline` skill's Harness-compatibility section now
  spells out the inline rule (read the role profile body, act inline, post the
  handoff, relay, continue) so pi can follow it directly. Everything else —
  VCS, notifications, boards, skills, agent profiles — was already
  harness-agnostic plain bash/markdown.

- **`agents.runner: pi` case in `pipeline-agent.sh`.** Runs a single stage
  headlessly via `pi -p <prompt>` (print mode) when explicitly requested; the
  pi inline mode is the default for pi and does not call the adapter.

- **`notifications.buzz_relay` config key.** The relay URL is a hostname, not a secret, and identifies a deployment exactly the way `buzz_channel` does — but it was readable only from the environment, grouped in with the bot tokens, with no `cfg` lookup and no `PIPELINE_*` override. A repo therefore could not describe its own Buzz setup: a clone got the channel from the committed config and no relay, which (before the fix above) then failed silently. Precedence is env > repo/hermes `.env` > config, and `PIPELINE_BUZZ_RELAY` overrides. The bot **key** stays env-only — it is a full Nostr signing identity and must never enter a git-tracked file.

- **Buzz messages carry the context trailer.** Slack renders `$NCONTEXT` as a context block and Discord as an embed footer; Buzz sent bare template text, losing the `repo · role · #ref` provenance line. It is now appended as an italic CommonMark trailer, which `kind:9` renders. Colour has no `kind:9` equivalent and is still Slack/Discord only.

## [0.12.0] - 2026-08-13

### Fixed

- **Azure DevOps work items showed raw markdown as jibberish.** The `azure` adapter piped GitHub-flavored markdown bodies straight into a work item's `System.Description` — but that field (and work-item comments) render **HTML**, not markdown. So `# Heading`, `**bold**`, `- [ ]`, and pipe tables displayed as literal source on the board. This hit the planner hardest: every sub-issue it creates goes through `create-issue`, so an epic decomposition produced a board full of unreadable items.

  The mismatch is provider-specific and easy to miss because everything else in the pipeline is GitHub-first, where issue bodies *are* markdown and the host renders them. Azure was behaving correctly; the adapter was feeding the wrong format.

### Added

- **`_md_to_html` conversion in the azure adapter**, applied to `create-issue` descriptions and work-item comments (`comment-issue` / `close-issue`). It prefers `pandoc`, then the python `markdown` library, then a self-contained python3 converter (python3 is already a hard dependency of this adapter) covering headings, bold/italic, inline + fenced code, links, ordered/unordered lists, GFM checkboxes (☐/☑), and pipe tables. Bodies that already look like HTML pass through untouched, so it is safe to double-apply.

- **PR comment threads are deliberately left as markdown.** Azure PR threads *do* render markdown, so `comment-pr` is not converted — only the two work-item HTML fields are. The `comment-issue` dry-run now echoes the real (converted) body instead of a `<body>` placeholder, so the conversion is visible and testable.

- **Planner tags every sub-issue `epic:<N>`.** When an epic is decomposed, each created sub-issue now carries an `epic:<epic-number>` label (independent *and* dependent), so a human can filter the board to one epic and review its sub-tasks as a group. The existing `Part of #<N>` body line still drives the epic auto-close sweep; the tag is purely for human grouping/filtering.

## [0.11.0] - 2026-08-11

### Fixed

- **`comment-issue` / `comment-pr` silently discarded the body when given `--body-file`.** The provider branches took `"$2"` as the body verbatim, so `comment-issue 42 --body-file verdict.md` ran `gh issue comment 42 --body "--body-file"` — a comment whose entire content was the literal flag, the real text dropped, **and exit 0**. Nothing failed and nothing warned. Three subagent verdicts were lost in a single pipeline run (two validators and one QA), and they were only caught because two later agents read the issue and found the verdicts missing.

  The trap is in the verb list itself: `comment-issue <n> <body>` sits four lines from `create-pr <branch> <title> <body-file>`. One takes inline text, its sibling takes a path — so an agent composing a multi-KB markdown verdict reaches for `--body-file` by analogy, with this script's own siblings and with `gh`. Treating that as agent error misses the point; the interface invited it.

  Wanting a file is legitimate rather than lazy, which is why the fix accepts it instead of only rejecting it: long markdown is hostile as a shell argument (backticks, `$`, quotes, newlines), and a body containing raw URLs can be refused outright by a permission rule, leaving a file as the only route.

### Added

- **`comment-issue <n> --body-file <path>` and `comment-pr <n> --body-file <path>`** now work, alongside an explicit `--body <text>` form. Normalisation happens before provider dispatch, so github, github-api, gitlab, azure and file mode all inherit it. The verb list documents both spellings.

- **A body that is still a bare flag is refused with exit 1** and a usage message naming both accepted forms, rather than being posted. An unreadable `--body-file` path also exits 1 and names the path. A body that merely *starts* with a single dash — a markdown bullet — is still a body, and is asserted as such.

- 13 assertions in `tests/test-vcs.sh` covering both spellings, both refusals, the leading-dash case, and a regression check that non-comment verbs keep their own flag handling.

## [0.10.0] - 2026-08-11

Azure DevOps goes from **best-effort to a first-class provider**. The adapter was
exercised end-to-end against a live `dev.azure.com` org and every verb the
pipeline actually calls now works, plus GitHub-Projects-style board tracking.
`az`-CLI gaps are worked around with `az rest` against the ADO REST API.

### Fixed (Azure adapter — every one was a hard failure on a real org)

- **`list-issues` called `az boards work-item list`, which does not exist** — the
  pipeline's primary work-item discovery verb errored out. Now uses a WIQL query
  via `az boards query`, excluding ADO's terminal states (Done/Removed/Closed,
  not just Closed). (#45)
- **`create-pr` omitted `--repository`**, which `az repos pr create` requires — a
  live PR create failed. Now passes it. (#45)
- **`label-issue` used a nonexistent `--tags` flag.** Its `--fields System.Tags=`
  alternative *appends* (ADO merges tags on a json-patch "add"), so it could add
  but never remove. Rewritten to PATCH `System.Tags` with a json-patch "replace"
  via `az rest`. (#45)
- **`comment-issue` used `az boards work-item comment add`, which does not exist.**
  Now posts to the work-item comments REST endpoint via `az rest`.
- **`approve-pr` used `az repos pr comment add`, which does not exist.** Its
  optional comment now posts as a PR thread; the self-approve vote failure stays
  ignorable (the `review:approved` label is the gate).

### Added (Azure adapter — parity with the GitHub provider)

- **`create-issue` now opens a work item on ADO** (`az boards work-item create`),
  of the configured type in the configured area path, with `--label`s mapped to
  Tags. Previously it errored "not implemented — use the web UI". New config:
  `vcs.azure.work_item_type` (default `Product Backlog Item`) and
  `vcs.azure.area_path` (so pipeline-created items land on the right board).
- **Board status tracking on ADO.** `pipeline-status.sh` gained an Azure branch:
  a work item's **State** drives its Kanban column (ADO has no separate
  GitHub-Projects status field), so the pipeline moves the card as it progresses.
  Mapping is configurable via `board.azure_states.{ready,in_progress,in_review,done,blocked}`
  with Scrum defaults (New / Committed / Committed / Done / unchanged).
- **`label-pr` on ADO** (PR labels via `az rest`; `az` has no command for it).
  Remove resolves the label name to its id first — ADO rejects `:` in a URL path,
  and every pipeline label contains one.
- **`comment-pr` on ADO** posts a PR comment thread via `az rest`.
- **`diff-pr` on ADO** — resolves the PR's source/target refs and runs
  `git diff origin/<target>...origin/<source>`, reading the change without
  touching the working tree (safe for the non-worktree reviewer/security stages).
  Previously unsupported.
- **`checkout-pr` on ADO** now detaches (`git checkout --detach FETCH_HEAD`)
  instead of checking out the branch by name, which failed with "already checked
  out" while the developer worktree still held the branch.
- **`tests/test-providers.sh`** grew coverage for all of the above (create-issue,
  the az-rest comment/label paths, diff-pr, checkout-pr, and the status→State
  mapping), and the `az` stub honors `-o tsv` ref queries.

### Notes

- **Merges on ADO are human-gated by design.** A repo whose `main` has branch
  policies (minimum reviewers, build validation) cannot be auto-merged by an
  agent; run with `merge.auto: false` and let a human complete the PR. The
  pipeline still runs every stage and labels the PR `pipeline:approved`.
- **Still not implemented on ADO:** `find-pr`, `check-pr-files`, `rerun-ci`.

## [0.9.0] - 2026-08-07

### Added

- **`install.sh` now installs agent-skills too.** Since 0.8.0 the pack has been a hard requirement — the role profiles delegate their methodology to it rather than restating it — but only the *plugin* got it automatically. The vendored path printed a note and left the user to it, so the same product behaved differently depending on how you installed it, and the vendored install degraded silently if you skipped the note. It is now fetched into `<target>/.claude/skills/` by default; `--no-agent-skills` opts out and says what you give up. (#44, fixes #43)

  Only `skills/` is vendored — the roles invoke skills, never agents (they have no `Task` tool), so agent-skills' own agents would be dead weight in the target repo. `LICENSE` ships alongside as `AGENT-SKILLS-LICENSE`, since this is third-party MIT content landing in a user's repo, copied unmodified from upstream.

  Never fatal: no `git`, or an unreachable source, degrades the install with a clear message rather than aborting. The pipeline still runs; roles fall back to their embedded instructions. `TALOS_AGENT_SKILLS_REPO` overrides the source.

- **`tests/test-skill-names.sh`** — asserts every skill named in `agents/*.md` actually exists in agent-skills. Nothing else caught a typo'd or renamed skill: the role simply never invokes it and quietly falls back, with no error anywhere. This is the only test that needs the network, and it skips rather than fails when offline. All 15 current references verified.

- 11 assertions in `tests/test-install.sh` covering the vendoring, the licence, the opt-out, and graceful degradation on an unreachable source — run against a local fixture repo so the suite stays hermetic.

### Changed

- README gains a single note that Talos installs agent-skills for you, rather than a requirements section — the point is that it is never a manual step.

## [0.8.1] - 2026-08-07

### Fixed

- **Corrected a false claim about other harnesses.** 0.8.0 told every role that Codex, Gemini and Antigravity have no skill support. That is wrong: agent-skills ships `.gemini/commands`, `.opencode/skills`, a `.codex-plugin/` manifest and an `AGENTS.md` explicitly covering Claude Code, Cursor, Copilot and Antigravity. It is not Claude-Code-only, and it was the load-bearing argument in 0.7.0's case for *not* making it a dependency — an argument that should not have been made without checking. (#42, fixes #41)

  The fallback clause in all eight profiles now states the accurate condition: the dependency belongs to the **plugin** install, a vendored `install.sh` copy pulls nothing, and if the skills are absent the role follows its embedded steps. No harness is named as skill-less.

- `install.sh` now tells vendored users that the roles delegate to agent-skills, links upstream, and notes it supports Claude Code, Codex, Gemini, OpenCode and Antigravity — previously they were left to discover the degraded behaviour themselves.

### Added

- Assertions that no profile repeats the 0.8.0 claim, alongside the existing fallback check. 16 fail against 0.8.0.

## [0.8.0] - 2026-08-07

### Changed

- **`agent-skills` is now a required dependency of the plugin.** The role profiles delegate their methodology to those skills instead of restating it — which is why they are 20–60 lines rather than several hundred — so 0.7.0's "use it if available" left the pipeline's actual guidance up to chance. Installing Talos now pulls agent-skills automatically (`+ 1 dependency: agent-skills`); nothing to add by hand. (#40, closes #39)

  Two halves make this work, and they are only correct together: `dependencies: ["agent-skills"]` in `plugin.json`, and an `agent-skills` entry in Talos's `marketplace.json` sourced from `addyosmani/agent-skills`. Plugin dependencies resolve to a **marketplace-qualified id** — `agent-skills@talos` — so without the catalogue entry Talos fails to load outright, *even when agent-skills is already installed from Addy's marketplace*:

  ```
  Status: ✘ failed to load
  Error: Dependency "agent-skills@talos" is not installed
  ```

  The catalogue entry is byte-identical to the one in Addy's own marketplace and points upstream at `addyosmani/agent-skills` (MIT), unmodified. Talos does not fork or vendor it.

  **Known consequence:** anyone already using Addy's marketplace ends up with agent-skills registered twice, as `agent-skills@addy-agent-skills` and `agent-skills@talos`. Verified side by side — same version, no conflict, nothing errors. It is unavoidable for a cross-marketplace hard dependency; disable either one if the duplicate bothers you.

- **Every role now directs the model to use its skills** rather than treating them as optional, and the mapping widened from 9 skills to 16: `validator` adds `doubt-driven-development`; `developer` adds `git-workflow-and-versioning`, `code-simplification`, `frontend-ui-engineering`, `deprecation-and-migration`; `qa` adds `browser-testing-with-devtools`; `reviewer` adds `code-simplification`, `performance-optimization`. Skills are still named bare, so Claude Code built-ins and a repo's own `.claude/skills/` satisfy the same references.

- **Codex, Gemini and Antigravity are unaffected.** They install via `install.sh`, never the plugin, so the dependency does not reach them. Every profile carries an explicit fallback — use the skills where the harness has them, otherwise follow the embedded steps — and a test asserts all eight say so, because a mandate with no fallback would be a dead end on three of the four advertised harnesses.

### Added

- 9 more assertions in `tests/test-plugin-install.sh` (51 total): every role carries a mandatory skills clause, every role names the non-Claude fallback, the manifest declares the dependency, the marketplace catalogues it, and the catalogue entry points upstream rather than at a vendored copy. 19 fail against 0.7.0.

## [0.7.0] - 2026-08-07

### Fixed

- **All eight roles can now use skills.** Only `qa`, `reviewer` and `security` carried the `Skill` tool; `validator`, `pm`, `developer`, `docs` and `planner` did not. Any installed skill pack was therefore unreachable from five of the eight stages *no matter what the profile said* — including Claude Code's own `code-review` / `security-review`. The blocker was never a missing dependency; it was the tool grant. (#38, fixes #37)

### Added

- **Every role now names the skills it would benefit from**, guarded on availability: `validator` → `debugging-and-error-recovery`; `pm` → `spec-driven-development`, `api-and-interface-design`; `planner` → `planning-and-task-breakdown`; `developer` → `test-driven-development`, `incremental-implementation`, `debugging-and-error-recovery`; `qa` → adds `test-driven-development` to the existing `verify`/`run`; `reviewer` → adds `code-review-and-quality`; `security` → adds `security-and-hardening`; `docs` → `documentation-and-adrs`.

  Skills are referenced by **bare name, never by plugin**, so any provider satisfies them — a Claude Code built-in, a pack such as [agent-skills](https://github.com/addyosmani/agent-skills), or the repo's own `.claude/skills/`. Absent one, the role follows its embedded instructions silently.

- `developer` now states explicitly that it cannot spawn subagents, and should do the work itself where a repo's `CLAUDE.md`/`AGENTS.md` instructs delegating to a named agent. Talos roles *are* subagents and have no `Task` tool, so such a mandate would otherwise degrade silently.

- 18 new assertions in `tests/test-plugin-install.sh` (42 total): every role can invoke skills, every skill reference carries an availability guard, no role names a specific third-party plugin, and the manifest declares no `dependencies`. The five tool-grant assertions fail against 0.6.0.

### Changed

- The user guide's dependency FAQ is rewritten: still no dependency, and now explicit about *why* — a hard `dependencies` entry (a real manifest field that auto-enables what it names) would misrepresent Talos on the Codex, Gemini and Antigravity harnesses it advertises, where Claude Code skill packs cannot exist. Adds the per-role skill table and documents the `Task` limitation.

## [0.6.0] - 2026-08-07

### Fixed

- **The marketplace plugin now works at all.** 0.5.0 fixed the vendored install; the plugin path had never been functional. Four independent breaks (#36, fixes #35):

  1. **The plugin shipped none of the role agents.** Talos kept them in `.claude/agents/`; Claude Code loads plugin-shipped agents from `agents/` **at the plugin root**, and the manifest carried no `agents` override. A marketplace install therefore provided `/pipeline` and zero of the eight subagents it spawns. Role definitions moved to `agents/`, with `.claude/agents` left as a symlink so the Talos repo can still dogfood itself.
  2. **The scripts were unreachable.** `SKILL.md` resolved only `.claude/talos/scripts/` and `scripts/`; under a plugin install the repo has neither, since the scripts live in `~/.claude/plugins/cache/`. Both skills now resolve `$CLAUDE_PLUGIN_ROOT/scripts` → `.claude/talos/scripts` → `scripts`, and `pipeline-agent.sh` resolves role files the same way.
  3. **`"scripts": "scripts/"` was a no-op.** Not a recognized manifest field — Claude Code ignores unrecognized top-level fields. It read like it wired the scripts up, which is plausibly why break 2 went unnoticed. Removed.
  4. **The manifest failed schema validation.** `claude plugin validate` reported `plugins[0] plugin.json → skills: Invalid input`. The `skills` field names *directories to scan* for `<name>/SKILL.md`, not individual skill directories, and `skills/` is the default scan path regardless. Removed, along with adding the `author` and marketplace `description` the validator warned about. The shipped manifests now validate clean, and `tests/test-install.sh` asserts it.

  Two things already worked and are now covered by tests so they stay working: `pipeline-notify.sh` derives its template directory from the script's own location, so templates resolve to `<plugin>/templates/`; and `pipeline-config.sh` resolves `talos.pipeline.yml` from the cwd, so a plugin install reads the *user's* config rather than inheriting Talos's own.

### Added

- **Per-repo role overrides.** A repo-level `.claude/agents/<role>.md` now takes precedence over the plugin's `talos:<role>`, per role — override `developer` and keep the other seven from the plugin, without forking Talos. The orchestrator playbook and `pipeline-agent.sh` resolve in the same order so Claude and Codex pick the same profile.
- `tests/test-plugin-install.sh` — 24 assertions modelling a real marketplace layout: a plugin cache directory holding the Talos tree, and a target repo containing nothing but `talos.pipeline.yml`. Covers agent shipping, script resolution with and without `$CLAUDE_PLUGIN_ROOT`, role override precedence, loud failure on an unknown role, template resolution, and config staying per-repo. 13 of them fail against 0.5.0.

### Changed

- README and user guide lead with the plugin install; `install.sh` is documented as the path for harnesses that cannot load a Claude Code plugin (Codex, Gemini, Antigravity) or for pinning the pipeline in-tree. Both paths remain supported and can coexist — the plugin wins where both are present, since it is the copy that matches the skill being run.
- Agent-profile customization guidance now distinguishes the two installs: vendored profiles are yours to edit, plugin profiles live in a cache that `/plugin update` replaces wholesale and must be overridden per-repo instead.

## [0.5.0] - 2026-08-07

### Changed

- **`install.sh` now registers `/pipeline` itself** — the orchestrator skill installs to `<target>/.claude/skills/pipeline/SKILL.md` instead of `<target>/.claude/talos/skills/pipeline/SKILL.md`. Claude Code discovers skills at `<repo>/.claude/skills/<name>/SKILL.md` and `~/.claude/skills/<name>/SKILL.md` and does **not** recurse, so every install before this one shipped a skill that nothing scanned: a repo could have correct scripts, templates, all eight agents, a valid config, bootstrapped labels and an issue at `pipeline:ready`, and still have no `/pipeline` command. `docs/user-guide.md` already documented the right locations; the installer disagreed with the docs. The skill body probes for `.claude/talos/scripts/` vs `scripts/` to find its scripts, so relocating it changes nothing about how it runs. (#34, fixes #33)

  **Upgrading:** re-run `install.sh` against your repo. It relocates the file and deletes the stale `.claude/talos/skills/pipeline/SKILL.md`, which is not merely tidiness — the AGENTS.md block written for the codex/antigravity harnesses pointed at that path, so a stale playbook there stays live for non-Claude runners after an upgrade. Only the file Talos wrote is removed; unrelated files you kept in that directory survive, and so do their parent dirs. Then **restart any Claude Code session already open in the repo** — skills are enumerated at startup.

- **The marketplace plugin is no longer load-bearing for `/pipeline`** — it remains useful for `/pipeline-setup` and for repos where `install.sh` has not run. #32's plugin-detection messaging is removed along with its `CLAUDE_CONFIG_DIR` probe: it existed to explain why a correct install had no command, and that premise is gone. The one surviving form of #31 — a session open *before* the install, holding a stale skill list, where `/pipeline` can still fuzzy-match an unrelated skill — is now the explicit closing note of the installer, along with the path the skill was registered at. README gains an Option A (installer), demotes the plugin to Option C, and states the discovery rule inline. (#34)

### Added

- `assert_file_absent` test helper. `tests/test-install.sh` grows to 37 assertions covering the new location, the absence of the old one, the upgrade migration, preservation of unrelated user files in the old directory, and plugin-independent guidance in both config states. Nine of them fail against 0.4.0's `install.sh`. (#34)

## [0.4.0] - 2026-08-07

### Added

- **Buzz notification sink** — `pipeline-notify.sh` can now post pipeline events to a [Buzz](https://github.com/block/buzz) (Nostr/NIP-29) channel by publishing signed `kind:9` events via the `nak` CLI (`--auth` answers NIP-42). Configure `notifications.buzz_channel` (or `PIPELINE_BUZZ_CHANNEL`) plus `BUZZ_RELAY_URL` / `BUZZ_BOT_PRIVATE_KEY` (env, repo `.env`, or `~/.hermes/.env`). Per-issue threading via NIP-10 reply tags with stale-anchor recovery; graceful skip with a warning when `nak` is missing. New `tests/stubs/nak` + `tests/test-notify-buzz.sh` regression suite. (0c321db)

### Fixed

- **PM stage now relays a notification** — PM was the only enabled role that sent nothing, so the channel thread read `validator → [silence] → developer`. Since PM is typically the longest-running stage, a long spec was indistinguishable from a dead pipeline. `pipeline-notify.sh` already mapped `pm → project-manager`; missing were the template, the relay instruction, and `pm` in the Rule 2 role vocabulary. The original rationale is preserved — the relay is a *pointer* to the spec comment (goal line, acceptance-criteria count, branch name), never a fabricated pass/fail, because PM emits a document rather than a verdict. New `templates/notifications/pm.md` + `tests/test-notify-pm.sh` (7 assertions, incl. that a `pm` event threads under the issue's existing anchor instead of starting a second root). (#30, fixes #29)

- **`install.sh` no longer promises a command it does not register** — it ended with "run: `/pipeline`", but writes the orchestrator skill to `.claude/talos/skills/`, which Claude Code does not scan; the command comes from the marketplace plugin. The failure was silent rather than loud: an unresolvable `/pipeline` gets fuzzy-matched to the nearest registered skill containing the word, so users landed in an unrelated plugin's wizard with no error. The installer now detects whether a talos entry exists in the resolved Claude config and prints either the plain instruction or the marketplace command plus an explicit "once per machine, not per repo" note and the path it checked. Honours `CLAUDE_CONFIG_DIR` — non-default profiles are exactly the case that triggered the report. (#32, fixes #31)

## [0.3.0] - 2026-07-23

### Added

- **`merge.auto` toggle (human-merge mode)** — default `true`; when `false` the orchestrator runs every stage and gate (approval labels, `skip-qa` rules, forbidden files, CI) but stops at `pipeline:approved` with a "ready for human merge" PR comment instead of merging. The issue stays open and closes via the reconciliation sweep after the human merges. New `templates/comments/approved.md` template; documented in `talos.pipeline.yml.example` and the user guide. (9ddeba6)
- **Antigravity harness support** — named runner (`agy -p`) and `--harness antigravity` install support. (a460990)
- **Provider coverage tests** — regression suite now exercises every verb in the gitlab and azure adapters and all three Teams notification paths (debug, real AdaptiveCard post, silent no-op) via new `tests/test-providers.sh` + extended `tests/stubs/glab` + new `tests/stubs/az`. (3ec23f3)

### Fixed

- **Developer test-type mandate** — the developer stage now requires unit/component tests, a failing-first regression test on bug fixes, and an e2e test for user-facing changes when the repo has an e2e harness (`playwright.config.*` / `cypress.config.*` / `tests/e2e/` / `test:e2e` detection); the PR body must list test types added or skipped-with-reason. (11e4321)
- **Azure**: split org_arg into separate argv elements in the label-issue subprocess call so `az` receives `--org` and the URL as distinct arguments. (76d8041)
- **Self-run hardening** — SKILL.md rule + reviewer/security prompts prohibit `git checkout` in shared repo; re-approval paths clear `pipeline:blocked`; CHANGELOG serialization guard in Step 4; developer stage drops self-reported test counts; same-account `gh pr review --approve` failure documented as ignorable; `github-api` provider logs `X-RateLimit-Reset` on HTTP 429. (a315600)

## [0.2.0] - 2026-07-09

### Breaking Changes

- **Install layout moved to `.claude/talos/`** (was `.claude/pipeline/`). Re-run `install.sh` or move your directory manually. (8654d69)
- **`pipeline-notify.sh` now loads `.env` from repo root only** (`<repo-root>/.env` via `git rev-parse --show-toplevel`). Move any credentials from `.claude/talos/.env` (or `.claude/pipeline/.env`) to your repository root `.env`. Dotenv precedence: exported env vars always win over `.env` values. (1e27cbb)

### Added

- **Multi-harness support**: Codex CLI, Gemini CLI, and custom/local runners configurable in `pipeline-agent.sh` — Talos is no longer Claude-only. (9fa4c61)
- **Optional planner role**: new `roles.planner` toggle (default `false`). When enabled, a planner stage decomposes epics into dependency-ordered sub-issues before the PM/developer stages. Epics are detected by label, checklist count (>= 4), or body length (>= 2000 chars). (3e1a0a7)
- **Offline regression suite + e2e pipeline simulation** with stubbed `gh`/`curl` — full test coverage with no network dependency. (903527a)
- **Linked rich notifications**: messages now link to their GitHub issue/PR; notification templates are shipped automatically by `install.sh`. (e7de0d5)
- **Daedalus-style Talos-branded notifications** with install and label fixes. (848fcf5)
- **`github-api` provider**: token-only GitHub mode — all 18 VCS verbs via `curl + GITHUB_TOKEN` (REST + GraphQL for Projects v2). No `gh` CLI dependency required. (39e80d2)
- **Plugin marketplace manifest** (`.claude-plugin/marketplace.json`) — enables `/plugin marketplace add benmarte/talos` install flow. (7e66974)
- **Session-hardening batch**: recovery/reconciliation, find-pr, forbidden-files gate, priority handling, skip-qa flag, and CI retry support. (8a0fee4)

### Fixed

- Grant `Skill` tool access to `qa`, `reviewer`, and `security` role profiles — these roles were previously missing the tool permission. (9404d43)
- Dry-run variants and GitLab fail-open test coverage for all hardening verbs. (38b2d3a)

### Changed

- **Config renamed to `talos.pipeline.yml`** — legacy `.claude-pipeline.yaml`/`pipeline.yaml` are still honored; `talos.pipeline.yml` wins when both exist. No migration required for v0.1.0 configs. (f99eb97)
- **`/pipeline-setup` wizard** now prompts for agent harness (claude/codex/gemini/custom), emits `forbidden_files` defaults, and covers control labels in the generated `talos.pipeline.yml` template. (593f040)
- **Docs**: user guide expanded with per-harness setup, prerequisites, env vars, feature matrix, llama.cpp local-model recipe, and a worked example wiring `addyosmani/agent-skills` into role profiles. (40bc1c8, 88700d2, 21e5dd6)

## [0.1.0] - 2026-07-04

Initial release — autonomous issue-to-PR pipeline orchestrated by Claude Code.

### Added

- Orchestrator (`pipeline-orchestrator.sh`) driving validator -> PM -> developer -> QA -> reviewer -> security -> docs stages via labelled GitHub issues.
- Worktree-isolated developer subagent with per-issue git worktrees.
- VCS abstraction (`pipeline-vcs.sh`) with `github`, `gitlab`, `azure`, and `file` providers.
- Notification system (`pipeline-notify.sh`) with Hermes/ntfy/Slack adapters.
- Pipeline status dashboard (`pipeline-status.sh`).
- Setup wizard (`/pipeline-setup` skill).
- Claude Code plugin manifest (`.claude-plugin/plugin.json`) for marketplace install.
