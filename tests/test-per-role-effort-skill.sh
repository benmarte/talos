#!/usr/bin/env bash
# Regression tests for per-role reasoning effort config (#271): the
# orchestrator playbook (skills/pipeline/SKILL.md) documents the effort
# resolution chain, how it is applied on each harness path, and the
# restamp_effort variant -- mirroring what test-restamp-dispatch.sh pins
# for agents.restamp_model / restamp dispatch text.
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
assert_contains "$effort_block_flat" "frontmatter" \
  "Per-role effort selection block names the frontmatter application mechanism"
assert_contains "$effort_block_flat" "effort:" \
  "Per-role effort selection block names the frontmatter effort: field"
assert_contains "$effort_block_flat" "do not invent one" \
  "Per-role effort selection block warns against inventing a per-spawn Agent tool parameter"
assert_contains "$effort_block_flat" "repo-override" \
  "Per-role effort selection block scopes frontmatter mutation to a repo-override role"
assert_contains "$effort_block_flat" "never mutates it" \
  "Per-role effort selection block states the plugin/global install is never mutated"

# ── Step 3e re-stamp block references restamp_effort alongside restamp_model ──
restamp_block="$(sed -n '/^\*\*Re-stamp check (fix-round path, #258):\*\*/,/^\*\*Phase 2 —/p' "$SKILL_MD")"
restamp_block_flat="$(printf '%s' "$restamp_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$restamp_block_flat" "agents.restamp_effort" \
  "Step 3e re-stamp block references agents.restamp_effort"
assert_contains "$restamp_block_flat" "agents.roles.<role>.restamp_effort" \
  "Step 3e re-stamp block references the per-role restamp_effort override"

finish
