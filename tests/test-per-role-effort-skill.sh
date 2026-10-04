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

# ── --resolve line names effort, and the adapter path documents TALOS_EFFORT ──
harness_section="$(sed -n '/^\*\*Harness compatibility\*\*/,/^\*\*Subagent names/p' "$SKILL_MD" 2>/dev/null)"
[ -n "$harness_section" ] || harness_section="$(cat "$SKILL_MD")"

assert_contains "$harness_section" 'agent.<role>.runner|runner_cmd|model|effort|' \
  "SKILL.md Step 0 output lists the per-role runner, model and effort fields (the --resolve answer)"
assert_contains "$harness_section" "TALOS_EFFORT" \
  "SKILL.md harness-compatibility section documents TALOS_EFFORT for the adapter path"

# ── Per-role effort selection block (native path) ───────────────────────────
effort_block="$(sed -n '/^  \*\*Per-role effort selection (native path/,/^- \*\*`subagents: false` + `runner: pi`/p' "$SKILL_MD")"

if [ -z "$effort_block" ]; then
  fail "SKILL.md carries a Per-role effort selection block" "block not found"
else
  pass "SKILL.md carries a Per-role effort selection block"
fi

effort_block_flat="$(printf '%s' "$effort_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$effort_block_flat" "pipeline-agent.sh --check-effort <role>" \
  "Per-role effort selection block calls the --check-effort verb"
assert_contains "$effort_block_flat" "never writes a tracked file" \
  "Per-role effort selection block states the orchestrator never writes a tracked file"
assert_contains "$effort_block_flat" "advisory" \
  "Per-role effort selection block states config effort is advisory on the native path"
assert_contains "$effort_block_flat" "TALOS_EFFORT" \
  "Per-role effort selection block names TALOS_EFFORT for the adapter path"

# The resolution prose moved into the verb; it must not creep back (#445).
assert_not_contains "$effort_block_flat" "pipeline-config.sh agents.roles" \
  "Per-role effort selection block no longer spells out the config resolution steps"
assert_not_contains "$effort_block_flat" "rewrite that file" \
  "Per-role effort selection block no longer rewrites the role file's frontmatter"

# Byte-count ceiling (#445): the effort block stays small. The whole-file size
# cap lives in one place, tests/test-skill-size.sh (#465).
effort_block_bytes="$(printf '%s' "$effort_block" | wc -c | tr -d ' ')"
if [ "$effort_block_bytes" -lt 900 ]; then
  pass "Per-role effort selection block stays under 900 bytes ($effort_block_bytes)"
else
  fail "Per-role effort selection block stays under 900 bytes" "$effort_block_bytes bytes"
fi

# ── Step 3e re-stamp block references restamp_effort alongside restamp_model ──
restamp_block="$(sed -n '/^\*\*Re-stamp check (fix-round path, #258):\*\*/,/^\*\*Phase 2 —/p' "$SKILL_MD")"
restamp_block_flat="$(printf '%s' "$restamp_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$restamp_block_flat" "agents.restamp_effort" \
  "Step 3e re-stamp block references agents.restamp_effort"
assert_contains "$restamp_block_flat" "agents.roles.<role>.restamp_effort" \
  "Step 3e re-stamp block references the per-role restamp_effort override"

finish
