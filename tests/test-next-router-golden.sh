#!/usr/bin/env bash
# test-next-router-golden.sh -- the router and the map page keep their answers
# while their code is split into one function per stage (#1021, behaviour
# does not change). The goldens in tests/fixtures/next-router-golden/ were
# captured from main before the split; golden.py replays the same fixtures.
#   AC1 (same) pipeline-next.py: issue-side over a table of fixtures (ready queue,
#       cap, owner wait, fix round, named issue, dependency gate, batched, overlap
#       ordering, read failures), where, pr-side and collect print the same lines,
#       and call the same provider verbs in the same order
#   AC2 (same) talos-map.py renders the same page, registry and index
#   AC3 (same) the fixtures also cover the cases the existing next and map test
#       files assert (the case names below)
# AC4 (the split, the 80-line bound, the changelog line) is prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

FX="$TALOS_ROOT/tests/fixtures/next-router-golden"
OUT="$SANDBOX/out"
mkdir -p "$OUT"

# same <mode> <golden>: replay the fixtures and compare with the captured transcript
replay() { python3 -I "$FX/golden.py" "$TALOS_ROOT" "$1" "$OUT/$1.txt" 2>"$OUT/$1.err"; }
differs() {  # <golden> <actual>: empty when equal, else the first differing lines
  diff "$1" "$2" | head -8
}

replay next
D1="$(differs "$FX/next.golden" "$OUT/next.txt")"
assert_eq "" "$D1" "AC1 pipeline-next.py answers every issue-side, where, pr-side and collect fixture as main did" "$(cat "$OUT/next.err")"

replay map
D2="$(differs "$FX/map.golden" "$OUT/map.txt")"
assert_eq "" "$D2" "AC2 talos-map.py renders the same page, registry and index as main" "$(cat "$OUT/map.err")"

# AC3: the fixtures cover the cases the existing files assert.
for CASE in ready-queue-validator ready-queue-priority-order cap-reached owner-wait-blocked-issue held-ask-owner named-ask-owner \
    named-theirs named-unassigned fix-round-ok fix-round-max-fix fix-round-max-total fix-round-record-failed fix-round-budget-exceeded \
    confirmed-pm confirmed-pm-skip-spec confirmed-planner-epic-label threat-needed threat-done dep-open dep-closed batched-open-lead \
    batched-closed-lead named-adopt-queued named-adopt-merge walk-inflight-busy-skipped overlap-demoted overlap-migrations-share-a-slot \
    view-issue-unsupported view-issue-rate-limited where-busy collect-basic collect-me collect-required-when collect-owners \
    collect-past-the-cap; do
  if grep -q "^## $CASE\$" "$FX/next.golden"; then pass "AC3 the golden holds the case $CASE"; else fail "AC3 the golden holds the case $CASE"; fi
done
for PART in 'Needs you' 'In flight' 'Queued' 'Merged' 'Next step' 'Priority track' 'Top spend' 'Lanes' 'owner question' 'merge failed' \
    'epic · split proposed' 'stalled since' 'merged elsewhere' 'Idle'; do
  if grep -qF -- "$PART" "$FX/map.golden"; then pass "AC3 the map golden shows $PART"; else fail "AC3 the map golden shows $PART"; fi
done

# Positive control: the comparison fails on a changed line, so a green AC1/AC2 is not vacuous.
sed 's/^out: action=dispatch stage=validator issue=3$/out: action=dispatch stage=validator issue=4/' "$FX/next.golden" > "$OUT/next.mutated"
D3="$(differs "$OUT/next.mutated" "$OUT/next.txt")"
if [ -n "$D3" ]; then pass "AC1 control: a changed answer line is reported as a difference"; else fail "AC1 control: a changed answer line is reported as a difference"; fi
sed 's/<section id="flight">/<section id="flightx">/' "$FX/map.golden" > "$OUT/map.mutated"
D4="$(differs "$OUT/map.mutated" "$OUT/map.txt")"
if [ -n "$D4" ]; then pass "AC2 control: a changed page is reported as a difference"; else fail "AC2 control: a changed page is reported as a difference"; fi

finish
