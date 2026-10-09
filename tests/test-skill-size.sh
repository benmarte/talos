#!/usr/bin/env bash
# test-skill-size.sh -- the size ratchet for skills/pipeline/SKILL.md (#465, epic
# #422: the playbook moves into scripts/talos.sh verbs and shrinks to a ceiling).
#
# One constant, SKILL_MAX_BYTES, is the only SKILL.md byte ceiling in the suite
# (no other test carries one). Two assertions:
#   1. size <= SKILL_MAX_BYTES                 the playbook does not grow back
#   2. SKILL_MAX_BYTES - size <= SKILL_SLACK   the cap is not left loose, so each
#                                              slice that shrinks the playbook
#                                              lowers the constant in the same PR
# When a change moves the size, edit the SKILL_MAX_BYTES line below to a value
# in [size, size + SKILL_SLACK]; a failure prints the size and that line.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MAX_BYTES=50700
SKILL_SLACK=500

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

finish
