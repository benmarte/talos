#!/usr/bin/env bash
# test-skill-size.sh -- the size ratchet for skills/pipeline/SKILL.md (#465, epic
# #422; reset by #547, epic #558). SKILL.md is the playbook the orchestrator
# carries every turn, so it is small by design: what applies only sometimes lives
# in skills/pipeline/refs/<topic>.md, read when `talos.sh env` or `next` names it.
#
# One constant, SKILL_MAX_BYTES, is the only SKILL.md byte ceiling in the suite
# (no other test carries one). Two assertions:
#   1. size <= SKILL_MAX_BYTES                 the playbook does not grow back
#   2. SKILL_MAX_BYTES - size <= SKILL_SLACK   the cap is not left loose
# SKILL_SLACK is 10% of the cap: a change that moves the size by less than that
# edits nothing here (no churn); a change that shrinks the core by more lowers the
# constant in the same PR. A failure prints the size and the line to edit.
#
# Refs are checked loosely: each one stays under REF_MAX_BYTES, so a ref cannot
# quietly become the next 50 KB playbook (a ref is read whole, in one go).
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MAX_BYTES=24600
SKILL_SLACK=2400
REF_MAX_BYTES=8000

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
# wc -c < file prints the byte count on BSD and GNU alike (BSD pads it).
size="$(wc -c < "$SKILL_MD" | tr -d ' ')"

under_cap() { [ "$1" -le "$SKILL_MAX_BYTES" ]; }
cap_is_tight() { [ $((SKILL_MAX_BYTES - $1)) -le "$SKILL_SLACK" ]; }
hint() {
  printf '      SKILL.md is %s bytes; the cap is %s (slack allowed: %s).\n' "$1" "$SKILL_MAX_BYTES" "$SKILL_SLACK" >&2
  printf '      Edit the line `SKILL_MAX_BYTES=%s` in tests/test-skill-size.sh to a value from %s to %s.\n' "$SKILL_MAX_BYTES" "$1" "$(($1 + SKILL_SLACK))" >&2
}

if under_cap "$size"; then
  pass "SKILL.md is within the cap ($size <= $SKILL_MAX_BYTES bytes)"
else
  fail "SKILL.md is within the cap" "$size bytes > $SKILL_MAX_BYTES"
  hint "$size"
fi
if cap_is_tight "$size"; then
  pass "the cap is tight (cap - size = $((SKILL_MAX_BYTES - size)) <= $SKILL_SLACK)"
else
  fail "the cap is tight" "cap - size = $((SKILL_MAX_BYTES - size)) > $SKILL_SLACK"
  hint "$size"
fi

# Positive controls: the two checks are not vacuous.
under_cap $((SKILL_MAX_BYTES + 1)); assert_eq "1" "$?" "control: one byte over the cap turns the cap check red"
under_cap "$SKILL_MAX_BYTES"; assert_eq "0" "$?" "control: exactly the cap passes"
cap_is_tight $((SKILL_MAX_BYTES - SKILL_SLACK - 1)); assert_eq "1" "$?" "control: a cap more than the slack above the size turns the tightness check red"
cap_is_tight $((SKILL_MAX_BYTES - SKILL_SLACK)); assert_eq "0" "$?" "control: a cap exactly the slack above the size passes"

# The refs: present, and each within REF_MAX_BYTES.
n_refs=0
for ref in "$TALOS_ROOT"/skills/pipeline/refs/*.md; do
  [ -f "$ref" ] || continue
  n_refs=$((n_refs + 1))
  rsize="$(wc -c < "$ref" | tr -d ' ')"
  if [ "$rsize" -le "$REF_MAX_BYTES" ]; then
    pass "ref $(basename "$ref") is within the ref cap ($rsize <= $REF_MAX_BYTES bytes)"
  else
    fail "ref $(basename "$ref") is within the ref cap" "$rsize bytes > $REF_MAX_BYTES; split it or move prose out"
  fi
done
[ "$n_refs" -ge 1 ]; assert_eq "0" "$?" "skills/pipeline/refs/ holds the on-demand refs"

finish
