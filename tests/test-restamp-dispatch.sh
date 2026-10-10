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
# #547: the check, its trigger and the RESTAMP_FAIL rule are one core paragraph;
# the dispatch recipe (prompt, model, effort) is skills/pipeline/refs/restamp.md.
# The block under test is both.
RESTAMP_REF="$TALOS_ROOT/skills/pipeline/refs/restamp.md"
restamp_block="$(sed -n '/^\*\*Re-stamp check (fix-round path):\*\*/,/^\*\*Phase 2 —/p' "$SKILL_MD"; cat "$RESTAMP_REF")"

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
# The delta-only instruction moved into templates/prompts/restamp.md (#468): the
# playbook calls `talos.sh prompt ... --shape restamp`, the template carries the rest.
restamp_tmpl_flat="$(tr '\n' ' ' < "$TALOS_ROOT/templates/prompts/restamp.md" | tr -s ' ')"
assert_contains "$restamp_block_flat" "--shape restamp" \
  "Step 3e re-stamp block renders the prompt with --shape restamp"
assert_contains "$restamp_tmpl_flat" "--for" \
  "re-stamp prompt template references --for (targeted tests)"
assert_contains "$restamp_tmpl_flat" "--strict" \
  "re-stamp prompt template runs targeted tests with --strict"
assert_contains "$restamp_tmpl_flat" "Review only the delta since your prior approval" \
  "re-stamp prompt template: delta-only review"
assert_contains "$restamp_block_flat" "diff-pr" \
  "Step 3e re-stamp block references diff-pr --stat"
assert_contains "$restamp_block_flat" "agents.restamp_model" \
  "Step 3e re-stamp block references agents.restamp_model"
assert_contains "$restamp_block_flat" "agents.roles.<role>.restamp_model" \
  "Step 3e re-stamp block references the per-role restamp_model override"
assert_contains "$restamp_block_flat" "**Agent:** <role> (talos) — re-stamp" \
  "Step 3e re-stamp block states the re-stamp comment header format"
assert_contains "$restamp_tmpl_flat" "post-approval {{PR}} {{ROLE}}" \
  "re-stamp prompt template instructs post-approval when the verdict is unchanged"
assert_contains "$restamp_block_flat" "RESTAMP_PASS" \
  "Step 3e re-stamp block names the RESTAMP_PASS verdict"
assert_contains "$restamp_block_flat" "RESTAMP_FAIL" \
  "Step 3e re-stamp block names the RESTAMP_FAIL verdict"

# ── Review finding (PR #265): a RESTAMP_FAIL must strip the stale label,
# or the next pass finds the role stale again and re-stamps forever. The strip
# moved from the playbook's prose into `talos.sh done` (#469): the playbook says
# the verb does it first, and the verb takes the label from the contract ────
assert_contains "$restamp_block_flat" "on \`RESTAMP_FAIL\` the verb first strips the stale label" \
  "Step 3e re-stamp block: on RESTAMP_FAIL the verb strips the stale label first"
assert_contains "$restamp_block_flat" "done <role> ... --verdict RESTAMP_PASS" \
  "Step 3e re-stamp block reports through talos.sh done"
done_fn="$(sed -n '/^_talos_done() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
strip_line="$(grep -n 'label-pr "$_pr" --remove "$_label"' <<< "$done_fn" | head -n 1 | cut -d: -f1)"
relay_line="$(grep -n '_talos_notify "$_role"' <<< "$done_fn" | head -n 1 | cut -d: -f1)"
[ -n "$strip_line" ] && [ -n "$relay_line" ] && [ "$strip_line" -lt "$relay_line" ]
assert_eq "0" "$?" "talos.sh done strips the stale label before it relays, not after"
assert_contains "$done_fn" '_label="$(_talos_label_of "$_role")"' \
  "talos.sh done takes the label from the contract, never a guessed <role>:approved pattern"
assert_contains "$restamp_block_flat" "stale role=<role> label=<label>" \
  "Step 3e re-stamp block still names --stale-list's own output"

# ── Trigger condition is explicit: label present AND stale, absent -> full
# stage (review finding: make this unambiguous, not implied) ───────────────
assert_contains "$restamp_block_flat" "**Trigger:**" \
  "Step 3e re-stamp block states its trigger condition explicitly"
assert_contains "$restamp_block_flat" "present on the PR AND \`--stale-list\` reports it stale" \
  "Step 3e re-stamp block's trigger requires the label present AND stale"
assert_contains "$restamp_block_flat" "label is absent" \
  "Step 3e re-stamp block: an absent label always gets the full dispatch"

# ── Non-blocking review note: the re-stamp dispatch spawns per the same
# usage-reporting spawn form as every other dispatch prompt ────────────────
assert_contains "$restamp_block_flat" "spawned per the Spawning paragraph" \
  "re-stamp dispatch ref points at the usage-reporting spawn form (the core Spawning paragraph)"

# ── Phase 3 (adversarial) points back at the same re-stamp check ───────────
phase3_block="$(cat "$TALOS_ROOT/skills/pipeline/refs/adversarial.md")"
assert_contains "$phase3_block" "re-stamp check" \
  "Phase 3 (adversarial) references the re-stamp check"

# ── Step 4's stale-approval handling dispatches a re-stamp, not a full
# stage, for every role check-approval-sha --stale-list names ──────────────
step4_block="$(sed -n '/^## Step 4 — Merge when ready/,/^## Step 5/p' "$SKILL_MD")"
step4_block_flat="$(printf '%s' "$step4_block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$step4_block_flat" "already has a prior approval on this PR" \
  "Step 4 stale handling explains every --stale-list role has a prior approval"
assert_contains "$step4_block_flat" "refs/restamp.md" \
  "Step 4 stale handling points at the shared re-stamp dispatch ref"
assert_contains "$step4_block_flat" "RESTAMP_FAIL" \
  "Step 4 stale handling explains a RESTAMP_FAIL escalates to a full re-dispatch"

# A regression back to the pre-#258 wording ("re-dispatch reviewer (Step 3e
# phase 2)" with no re-stamp mention at all) is exactly the bug #258 fixes.
if grep -q 're-dispatch reviewer (Step 3e phase 2)\.$' <<<"$step4_block"; then
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
