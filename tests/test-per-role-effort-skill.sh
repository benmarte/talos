#!/usr/bin/env bash
# Regression tests for per-role reasoning effort config (#271): the
# orchestrator playbook (skills/pipeline/SKILL.md) documents the effort
# resolution chain, how it is applied on each harness path, and the
# restamp_effort variant -- mirroring what test-restamp-dispatch.sh pins
# for agents.restamp_model / restamp dispatch text.
#
# The native path must have NO working-tree side effects (#271 fix round):
# the orchestrator never rewrites a role file's frontmatter at spawn time.
# Effort on that path comes from whatever `effort:` is already committed in
# the role file; config keys are advisory-only there, surfaced as a notice by
# `pipeline-agent.sh --check-effort <role>` (#445; behaviour pinned in
# tests/test-agent-runner.sh) when they disagree with the committed frontmatter.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
HARNESS="$TALOS_ROOT/skills/pipeline/refs/harness.md"
RESTAMP="$TALOS_ROOT/skills/pipeline/refs/restamp.md"

# ── Step 0 output names effort; the adapter path documents TALOS_EFFORT ──────
skill_flat="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"
assert_contains "$skill_flat" 'agent.<role>.runner|runner_cmd|model|effort|' \
  "SKILL.md Step 0 output lists the per-role runner, model and effort fields (the --resolve answer)"
assert_contains "$(cat "$HARNESS")" "TALOS_EFFORT" \
  "harness ref documents TALOS_EFFORT for the adapter path"

# ── Effort selection (native path): the core relays the notice, the harness ref
# carries the rest ────────────────────────────────────────────────────────────
assert_contains "$skill_flat" 'Effort is advisory: relay `agent.<role>.effort_notice`' \
  "core Spawning paragraph states config effort is advisory and relays the notice"
effort_block="$(sed -n '/^\*\*Native path detail\./p' "$HARNESS")"
if [ -z "$effort_block" ]; then
  fail "harness ref carries the native-path effort statement" "block not found"
else
  pass "harness ref carries the native-path effort statement"
fi
effort_block_flat="$(printf '%s' "$effort_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$effort_block_flat" "pipeline-agent.sh --check-effort <role>" \
  "native-path effort statement calls the --check-effort verb"
assert_contains "$effort_block_flat" "never writes a tracked file" \
  "native-path effort statement says the orchestrator never writes a tracked file"
assert_contains "$effort_block_flat" "advisory" \
  "native-path effort statement says config effort is advisory on the native path"
assert_contains "$effort_block_flat" "TALOS_EFFORT" \
  "native-path effort statement names TALOS_EFFORT for the adapter path"

# The resolution prose lives in the verb; it must not creep back (#445).
assert_not_contains "$effort_block_flat" "pipeline-config.sh agents.roles" \
  "native-path effort statement does not spell out the config resolution steps"
assert_not_contains "$effort_block_flat" "rewrite that file" \
  "native-path effort statement does not rewrite the role file's frontmatter"

# ── The re-stamp dispatch ref references restamp_effort alongside restamp_model ─
restamp_flat="$(tr '\n' ' ' < "$RESTAMP" | tr -s ' ')"
assert_contains "$restamp_flat" "agents.restamp_effort" \
  "re-stamp ref references agents.restamp_effort"
assert_contains "$restamp_flat" "agents.roles.<role>.restamp_effort" \
  "re-stamp ref references the per-role restamp_effort override"

finish
