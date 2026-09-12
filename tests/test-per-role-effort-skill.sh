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
# the role file; config keys are advisory-only there, surfaced as a logged
# notice when they disagree with the committed frontmatter.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"

# ── --resolve line names effort, and the adapter path documents TALOS_EFFORT ──
harness_section="$(sed -n '/^\*\*Harness compatibility\*\*/,/^\*\*Subagent names/p' "$SKILL_MD" 2>/dev/null)"
[ -n "$harness_section" ] || harness_section="$(cat "$SKILL_MD")"

assert_contains "$harness_section" "model=<m> effort=<e>" \
  "SKILL.md --resolve reference line includes effort=<e>"
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

assert_contains "$effort_block_flat" "agents.roles.<role>.effort" \
  "Per-role effort selection block references agents.roles.<role>.effort"
assert_contains "$effort_block_flat" "agents.effort" \
  "Per-role effort selection block references the global agents.effort fallback"
assert_contains "$effort_block_flat" "committed frontmatter" \
  "Per-role effort selection block states effort comes from the role's committed frontmatter on the native path"
assert_contains "$effort_block_flat" "do not invent a mutation mechanism" \
  "Per-role effort selection block warns against inventing a file-mutation mechanism"
assert_contains "$effort_block_flat" "never write to a tracked file at spawn time" \
  "Per-role effort selection block states the orchestrator never writes to a tracked file at spawn time"
assert_contains "$effort_block_flat" "notice" \
  "Per-role effort selection block names the advisory-notice mechanism"
assert_contains "$effort_block_flat" "advisory" \
  "Per-role effort selection block states the config keys are advisory on the native path"
assert_contains "$effort_block_flat" "no file writes" \
  "Per-role effort selection block confirms the working tree stays clean"

# ── Old file-mutation mechanism must be gone ────────────────────────────────
assert_not_contains "$effort_block_flat" "rewrite that file" \
  "Per-role effort selection block no longer rewrites the role file's frontmatter"
assert_not_contains "$effort_block_flat" "Talos never mutates it" \
  "Per-role effort selection block no longer describes a mutation it skips for plugin/global roles"

# ── Step 3e re-stamp block references restamp_effort alongside restamp_model ──
restamp_block="$(sed -n '/^\*\*Re-stamp check (fix-round path, #258):\*\*/,/^\*\*Phase 2 —/p' "$SKILL_MD")"
restamp_block_flat="$(printf '%s' "$restamp_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$restamp_block_flat" "agents.restamp_effort" \
  "Step 3e re-stamp block references agents.restamp_effort"
assert_contains "$restamp_block_flat" "agents.roles.<role>.restamp_effort" \
  "Step 3e re-stamp block references the per-role restamp_effort override"

finish
