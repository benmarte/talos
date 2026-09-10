#!/usr/bin/env bash
# Cheap delta re-stamp for stale approvals (#258).
#
# On 2026-09-09 PR #249 needed QA/security three full stage re-runs each
# because two reviewer rounds each moved the head -- every re-run was a
# full review of a PR the same role had already approved, at full-stage
# token cost. Pins in place that skills/pipeline/SKILL.md's Step 3e
# fix-round path and Step 4 stale-approval handling both describe
# dispatching a cheap **re-stamp** (agents.restamp_model tier, delta-only
# review, targeted tests only) instead of a full stage re-run whenever a
# role's approval is merely stale, not a first-time review.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

# ── Extract the Step 3e re-stamp block (Re-stamp check + Re-stamp dispatch,
# bounded by the Sync guard above and Phase 2's heading below) ─────────────
restamp_block="$(sed -n '/^\*\*Re-stamp check (fix-round path, #258):\*\*/,/^\*\*Phase 2 —/p' "$SKILL_MD")"

if [ -z "$restamp_block" ]; then
  fail "SKILL.md Step 3e carries a Re-stamp check block" "block not found"
else
  pass "SKILL.md Step 3e carries a Re-stamp check block"
fi

restamp_block_flat="$(printf '%s' "$restamp_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$restamp_block_flat" "check-approval-sha" \
  "Step 3e re-stamp block references check-approval-sha"
assert_contains "$restamp_block_flat" "--stale-list" \
  "Step 3e re-stamp block references --stale-list"
assert_contains "$restamp_block_flat" "--for" \
  "Step 3e re-stamp block references --for (targeted tests)"
assert_contains "$restamp_block_flat" "diff-pr" \
  "Step 3e re-stamp block references diff-pr --stat"
assert_contains "$restamp_block_flat" "agents.restamp_model" \
  "Step 3e re-stamp block references agents.restamp_model"
assert_contains "$restamp_block_flat" "agents.roles.<role>.restamp_model" \
  "Step 3e re-stamp block references the per-role restamp_model override"
assert_contains "$restamp_block_flat" "**Agent:** <role> (talos) — re-stamp" \
  "Step 3e re-stamp block states the re-stamp comment header format"
assert_contains "$restamp_block_flat" "post-approval" \
  "Step 3e re-stamp block instructs post-approval when the verdict is unchanged"
assert_contains "$restamp_block_flat" "RESTAMP_PASS" \
  "Step 3e re-stamp block names the RESTAMP_PASS verdict"
assert_contains "$restamp_block_flat" "RESTAMP_FAIL" \
  "Step 3e re-stamp block names the RESTAMP_FAIL verdict"

# ── Review finding (PR #265): a RESTAMP_FAIL must strip the stale label,
# or the next pass finds the role stale again and re-stamps forever ────────
assert_contains "$restamp_block_flat" "label-pr <PR_NUMBER> --remove <label>" \
  "Step 3e re-stamp block strips the stale label on RESTAMP_FAIL"
assert_contains "$restamp_block_flat" "before relaying" \
  "Step 3e re-stamp block strips the label before relaying, not after"
assert_contains "$restamp_block_flat" "stale role=<role> label=<label>" \
  "Step 3e re-stamp block sources the exact label from --stale-list's own output"
assert_contains "$restamp_block_flat" "never guess a \`<role>:approved\` pattern" \
  "Step 3e re-stamp block warns against guessing a <role>:approved label name"

# ── Trigger condition is explicit: label present AND stale, absent -> full
# stage (review finding: make this unambiguous, not implied) ───────────────
assert_contains "$restamp_block_flat" "Trigger, explicit" \
  "Step 3e re-stamp block states its trigger condition explicitly"
assert_contains "$restamp_block_flat" "present on the PR AND \`--stale-list\` reports it stale" \
  "Step 3e re-stamp block's trigger requires the label present AND stale"
assert_contains "$restamp_block_flat" "label is absent" \
  "Step 3e re-stamp block: an absent label always gets the full dispatch"

# ── Non-blocking review note: the re-stamp dispatch spawns per the same
# usage-reporting spawn form as every other dispatch prompt ────────────────
assert_contains "$restamp_block_flat" "spawn per the usage-reporting spawn form above" \
  "Step 3e re-stamp dispatch block points at the usage-reporting spawn form"

# ── Phase 3 (adversarial) points back at the same re-stamp check ───────────
phase3_block="$(sed -n '/^\*\*Phase 3 — Adversarial/,/^\*\*Adversarial\*\* (if/p' "$SKILL_MD")"
assert_contains "$phase3_block" "re-stamp check above" \
  "Phase 3 (adversarial) references the Phase 2 re-stamp check"

# ── Step 4's stale-approval handling dispatches a re-stamp, not a full
# stage, for every role check-approval-sha --stale-list names ──────────────
step4_block="$(sed -n '/^## Step 4 — Merge when ready/,/^## Step 5/p' "$SKILL_MD")"
step4_block_flat="$(printf '%s' "$step4_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$step4_block_flat" "already has a prior approval on this PR" \
  "Step 4 stale handling explains every --stale-list role has a prior approval"
assert_contains "$step4_block_flat" "Re-stamp dispatch block" \
  "Step 4 stale handling points at Step 3e's shared Re-stamp dispatch block"
assert_contains "$step4_block_flat" "RESTAMP_FAIL" \
  "Step 4 stale handling explains a RESTAMP_FAIL escalates to a full re-dispatch"

# A regression back to the pre-#258 wording ("re-dispatch reviewer (Step 3e
# phase 2)" with no re-stamp mention at all) is exactly the bug #258 fixes.
if printf '%s' "$step4_block" | grep -q 're-dispatch reviewer (Step 3e phase 2)\.$'; then
  fail "Step 4 no longer describes a bare full-stage re-dispatch for a stale reviewer approval" \
    "found the pre-#258 bare re-dispatch wording"
else
  pass "Step 4 no longer describes a bare full-stage re-dispatch for a stale reviewer approval"
fi

# ── agents.restamp_model / agents.roles.<role>.restamp_model are known keys
# (a regression here would make pipeline-config.sh warn on every lookup) ───
_dump_out="$(bash "$CFG_SH" --dump 2>&1 >/dev/null)"
assert_eq "" "$_dump_out" "pipeline-config.sh --dump warns on nothing with no config present"

finish
