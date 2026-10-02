# Spec: single source of truth for per-role models

Status: approved by Ben 2026-10-02 (decisions recorded at the end). Built through Talos.

## Objective

A Talos user sets which model each role runs on in exactly one kind of place: the Talos config. Today there are two sources that can disagree, and no way to set models once for every repo.

**What exists today**

| Source | Where | When it applies |
|---|---|---|
| Project config | `agents.model`, `agents.roles.<role>.model`, `agents.restamp_model`, `agents.roles.<role>.restamp_model` in the repo's `talos.pipeline.*` | Pipeline dispatch. The orchestrator passes the resolved value as the Agent spawn `model:`, which beats frontmatter. |
| Agent frontmatter | `model:` in `agents/<role>.md`, copied verbatim to `~/.claude/agents/` and `~/.talos/agents/` by `install.sh --global`, and shipped in the plugin | Whenever the config resolves empty, and whenever a role agent is spawned outside the pipeline. Ships as `opus` for eight roles and `haiku` for docs. |

**Problems**

1. The frontmatter is a second source. A repo with no `agents` block silently runs eight roles on Opus, whatever the user intended.
2. Config lookup is `$PIPELINE_CONFIG` or the repo's own file. There is no user-level file, so a preferred routing must be copied into every repo.
3. README says that with no model at either level the role "inherits the session default". That is false today: the frontmatter `model:` wins.
4. Finding out what a role will actually run on means reading two files per role and knowing the precedence.

**Users:** anyone running Talos on the native Claude Code path; first of all Ben, who runs it across several repos.

**Success looks like:** Ben writes his routing table once in a user-level Talos config, every repo follows it, a repo can still override a single role, and one command shows what each role resolves to and which file decided it.

## Design

### 1. User-level config layer

- File: `${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json}`, same formats and the same lookup order among extensions as the project file.
- `pipeline-config.sh` loads it and deep-merges the project config over it, leaf by leaf. Project wins per key.
- Only the `agents.*` subtree is read from the user-level file. Every other key there is ignored with one stderr warning naming the key. Board, merge, issue and verify settings describe a repo, not a user.
- The layer sits under whichever project config is found, including one named by `$PIPELINE_CONFIG`.
- A missing, unreadable or malformed user-level file behaves as absent. Malformed prints one stderr warning. It never crashes, matching the existing "never crashes" contract.
- All existing chains (`restamp_model`, `effort`, `restamp_effort`, per-role `runner`) are evaluated on the merged config, so they layer with no extra rules.
- `pipeline-config.sh` currently has its load-and-walk logic twice (the `--dump` block and the lookup block). The merge goes into one shared loader used by both, so `cfg()` (`pipeline-cfg-cache.sh`, which answers from one `--dump` per script invocation) sees the merged values and still costs a single `python3` spawn (#169).

### 2. Frontmatter stops carrying a model

- Remove the `model:` line from all nine shipped `agents/*.md`. `tools:`, `name:`, `description:` and any `effort:` stay.
- Resolution becomes what the README already documents: role key → `agents.model` → omit `model:` and inherit the session model.
- Nothing is seeded silently. The setup wizard (`skills/pipeline-setup`) asks the user how they want models assigned:
  1. **One model for every role** → writes `agents.model`.
  2. **Per role** → walks the roles enabled in this setup and writes `agents.roles.<role>.model` for each, with `agents.model` as the fallback for the rest.
  3. **Leave unset** → writes nothing; every role inherits the session model.
- The wizard writes the answer to the user-level file by default, so it is asked once and applies to every repo. When a user-level routing already exists, the wizard shows it (the `--resolve-all` table) and offers to keep it (default), change it, or override it for this repo only.
- The wizard never overwrites an existing user-level file without showing the diff and getting a yes.
- `install.sh --global` stays non-interactive. When no user-level model config exists it prints one line pointing at the setup wizard.
- Upgrade effect: a user who never configured models moves from the old frontmatter routing (Opus ×8, Haiku for docs) to the session model until they run setup. This goes in the CHANGELOG upgrade notes.

### 3. One command to see the routing

- `pipeline-agent.sh --resolve-all` prints one line per role: role, model, re-stamp model, and origin (`project`, `global`, or `session default`).
- It warns when a role file Claude Code would load (`.claude/agents/<role>.md`, `~/.claude/agents/<role>.md`) still carries a `model:` line, since that line applies whenever the config resolves empty.
- `pipeline-agent.sh --resolve <role>` keeps its current one-line output byte for byte.

### 4. Model aliases

- Config values may be full IDs or the aliases `opus`, `sonnet`, `haiku`. Values pass through unchanged, as today.
- `skills/pipeline/SKILL.md` gains one rule: when the harness's Agent tool accepts only aliases, map a full ID to its family alias before spawning. Today the skill's examples pass full IDs, which this harness rejects (`tasks/lessons.md`, 2026-09).

## Non-goals

- Applying the config model on the adapter path (`subagents: false`). That path keeps routing through `$TALOS_ROLE` in `runner_cmd`.
- Making `effort` a single source on the native path. It still needs frontmatter because the Agent tool has no per-spawn effort parameter.
- Layering non-`agents` keys from the user-level file.
- A version bump, tag or release section.

## Tech stack

Bash (`set -u`) with embedded Python 3 heredocs, JSON always, YAML when PyYAML is importable. No new dependencies.

## Commands

```
Test (full):   bash tests/run-tests.sh --quiet
Test (one):    bash tests/test-config.sh
Resolve role:  bash scripts/pipeline-agent.sh --resolve <role>
Resolve all:   bash scripts/pipeline-agent.sh --resolve-all        # new
Read a key:    bash scripts/pipeline-config.sh agents.roles.qa.model ""
Dump config:   bash scripts/pipeline-config.sh --dump
Install:       bash install.sh --global
```

## Project structure

```
scripts/pipeline-config.sh   → user-level layer + merge (shared loader)
scripts/pipeline-agent.sh    → --resolve-all
agents/*.md                  → drop the model: line
install.sh                   → hint when no user-level model config exists
skills/pipeline/SKILL.md     → resolution text, alias rule
skills/pipeline-setup/       → model question (one for all / per role / unset), writes the user-level file
README.md, docs/user-guide.md, talos.pipeline.*.example → document the layer
CHANGELOG.md                 → Unreleased entry + upgrade note
tests/test-config.sh         → layering cases
tests/test-agent-runner.sh   → --resolve-all, frontmatter assertion
tests/test-global-install.sh → hint line, existing user-level file untouched
tests/test-config-cache.sh   → merged dump still one python3 spawn
```

## Code style

Match the existing tests: sandboxed `HOME`, config written with a heredoc, one assertion per behaviour with a message.

```bash
mkdir -p "$HOME/.talos"
cat > "$HOME/.talos/talos.pipeline.json" <<'EOF'
{"agents": {"model": "sonnet", "roles": {"security": {"model": "opus"}}}}
EOF
cat > talos.pipeline.json <<'EOF'
{"agents": {"roles": {"qa": {"model": "haiku"}}}}
EOF
assert_eq "opus"   "$(bash "$CFG_SH" agents.roles.security.model "")" "user-level role model applies"
assert_eq "haiku"  "$(bash "$CFG_SH" agents.roles.qa.model "")"       "project role model overrides"
assert_eq "sonnet" "$(bash "$CFG_SH" agents.model "")"                "user-level global model applies"
```

## Testing strategy

Failing test first for each criterion below, in the existing bash suite. `make_sandbox` already points `HOME` at a temp dir and unsets `TALOS_HOME`, so a developer's real user-level config cannot leak into a run; the first task confirms that with a test.

## Success criteria

1. User-level file only, repo has no config: `agents.model` and `agents.roles.<role>.model` return the user-level values, and `--resolve <role>` shows them.
2. Project file sets one role: that role returns the project value, every other role still returns the user-level value.
3. `$PIPELINE_CONFIG` and `$TALOS_HOME` are both honoured, each with a test.
4. A non-`agents` key in the user-level file is ignored, with exactly one warning naming it.
5. A malformed user-level file: lookups return project values or defaults, exit status unchanged, one warning.
6. `agents.roles.<role>.restamp_model` resolves role re-stamp → global re-stamp → `agents.model` across both layers.
7. No file in `agents/` contains a `model:` frontmatter line; a test fails if one is added back. The frontmatter-stripping test in `tests/test-agent-runner.sh` asserts on a line that still exists.
8. The setup wizard asks the model question with the three answers above and writes the result to the user-level file; an existing user-level file is changed only after the diff is shown and confirmed. `install.sh --global` leaves an existing user-level file byte-identical and prints the setup hint when none has model keys.
9. `--resolve-all` lists all nine roles with model, re-stamp model and origin, and warns on a leftover `model:` line.
10. `--resolve <role>` output is unchanged.
11. With no user-level file and no `agents` block, every existing test passes unchanged apart from the two that assert on the removed line.
12. README, user guide, example configs, both skills and the CHANGELOG describe the layer, the precedence and the upgrade note.

## Boundaries

- **Always:** failing test first; full suite green before PR; keep `--resolve <role>` output stable; CHANGELOG entry under Unreleased.
- **Ask first:** reading anything beyond `agents.*` from the user-level file; touching adapter-path model handling.
- **Never:** write a tracked file at spawn time; overwrite an existing user-level config; hand-edit the plugin cache; bump the version or cut a release.

## Rollout for Ben's machine

After the change merges and `install.sh --global` is re-run:

1. Put the 2026-10-02 routing table in `~/.talos/talos.pipeline.json`.
2. Remove the model keys from this repo's `talos.pipeline.json` so the user-level file governs here too.
3. Confirm with `--resolve-all` in this repo and one other.

## Decisions (Ben, 2026-10-02)

1. The user-level file layers `agents.*` only.
2. No shipped default routing. Setup asks whether the user wants one model for every role or a model per role.
3. Single source of truth always: once the user-level file exists, this repo's `talos.pipeline.json` drops its model keys.
4. Built by filing an issue and running it through Talos.
