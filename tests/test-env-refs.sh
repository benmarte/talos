#!/usr/bin/env bash
# test-env-refs.sh -- `talos.sh env` names the playbook ref that applies (#547).
#
# skills/pipeline/SKILL.md is the core the orchestrator carries every turn; what
# applies only sometimes lives in skills/pipeline/refs/<topic>.md. `env` prints
# one `ref=<topic>` line per topic that applies to the run, so the orchestrator
# reads a ref exactly when it is needed:
#   (a) a run with nothing special names no ref except draft-order (pr.draft is
#       on by default; pr.draft false names none)
#   (b) each trigger names its ref: draft-order, planner, adversarial,
#       human-merge, ci-gate, evidence, file-mode, hooks and harness (a global
#       non-claude runner, a role runner, subagents false, a fallback chain)
#   (c) every ref= topic env can print is a file in skills/pipeline/refs/, and
#       the core playbook names every file there
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
REFS="$TALOS_ROOT/skills/pipeline/refs"
SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0

# refs_for <project JSON>: the ref= topics of `env` under that config, space-joined.
refs_for() {
  rm -rf "${HOME:?}/.talos" "${SANDBOX:?}"/talos.pipeline.*
  printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"
  bash "$TALOS" env 2>/dev/null | sed -n 's/^ref=//p' | tr '\n' ' ' | sed 's/ $//'
}
# nd <members>: a github config with pr.draft off, so draft-order is not in the way.
nd() { printf '{"vcs": {"provider": "github"}, "pr": {"draft": false}, %s}' "$1"; }

R="$(refs_for '{"vcs": {"provider": "github"}}')"
assert_eq "draft-order" "$R" "default: only draft-order (pr.draft is on)"
R="$(refs_for '{"vcs": {"provider": "github"}, "pr": {"draft": false}}')"
assert_eq "" "$R" "pr.draft false: no ref at all"
R="$(refs_for "$(nd '"roles": {"planner": true}')")"
assert_eq "planner" "$R" "roles.planner names planner"
R="$(refs_for "$(nd '"roles": {"adversarial": true}')")"
assert_eq "adversarial" "$R" "roles.adversarial names adversarial"
R="$(refs_for "$(nd '"merge": {"auto": false}')")"
assert_eq "human-merge" "$R" "merge.auto false names human-merge"
R="$(refs_for "$(nd '"merge": {"required_checks": ["ci / test"]}')")"
assert_eq "ci-gate" "$R" "required checks make qa_mode ci, which names ci-gate"
R="$(refs_for "$(nd '"evidence": {"enabled": true, "when": "always", "command": "echo x"}')")"
assert_eq "evidence" "$R" "evidence on names evidence"
R="$(refs_for '{"vcs": {"provider": "file"}, "pr": {"draft": false}}')"
assert_eq "file-mode" "$R" "the file provider names file-mode"
R="$(refs_for "$(nd '"hooks": {"pre_dispatch": "echo hi"}')")"
assert_eq "hooks" "$R" "hooks.pre_dispatch names hooks"
R="$(refs_for "$(nd '"agents": {"runner": "codex"}')")"
assert_eq "harness" "$R" "a non-claude global runner names harness"
R="$(refs_for "$(nd '"agents": {"roles": {"qa": {"runner": "codex"}}}')")"
assert_eq "harness" "$R" "a non-claude role runner names harness"
R="$(refs_for "$(nd '"agents": {"subagents": false}')")"
assert_eq "harness" "$R" "agents.subagents false names harness"
R="$(refs_for "$(nd '"agents": {"fallback": ["codex"]}')")"
assert_eq "harness" "$R" "a fallback chain names harness"
# A profile-aware run (#539) in a non-native mode needs the harness ref (the
# harness is set here, so the run is profile-aware: AGENTS_MODE is printed).
R="$(TALOS_HARNESS=pi refs_for "$(nd '"agents": {"runner": "claude"}')")"
assert_eq "harness" "$R" "AGENTS_MODE adapter (a pi harness running claude) names harness"
R="$(TALOS_HARNESS=claude-code refs_for "$(nd '"agents": {"runner": "claude"}')")"
assert_eq "" "$R" "AGENTS_MODE native (Claude Code) names no harness ref"
R="$(refs_for '{"vcs": {"provider": "github"}, "roles": {"planner": true}, "agents": {"runner": "codex"}}')"
assert_eq "draft-order planner harness" "$R" "several triggers print one line each, in a fixed order"

# (c) the topics env can print are files, and the core names every ref file.
for t in draft-order planner adversarial human-merge ci-gate evidence file-mode hooks harness; do
  assert_file_exists "$REFS/$t.md" "ref file for env topic $t exists"
done
core="$(cat "$SKILL")"
for f in "$REFS"/*.md; do
  t="$(basename "$f" .md)"
  assert_contains "$core" "\`$t\`" "SKILL.md names the ref $t"
done

finish
