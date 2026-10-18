#!/usr/bin/env bash
# test-qa-targeted-budget.sh -- run-tests.sh --budget-s bounds a targeted run by
# an estimate from tests/timings.txt and exits 6 without running (#806); QA's
# prompts name the flag and treat exit 6 as "not run", never a block.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

RT="$TALOS_ROOT/tests/run-tests.sh"
TIMINGS="$TALOS_ROOT/tests/timings.txt"
F1="test-blocked-template-resume.sh"
F2="test-run-tests-failed-summary.sh"

# weight_of <basename> -- the timings.txt weight, floor 1, default 8 (as
# run-tests.sh's timings_weights).
weight_of() {
  local w
  w="$(awk -v f="$1" '$2 == f && $1 ~ /^[0-9]+$/ { print $1 }' "$TIMINGS")"
  [ -z "$w" ] && w=8
  [ "$w" -lt 1 ] && w=1
  echo "$w"
}
W1="$(weight_of "$F1")"
W2="$(weight_of "$F2")"
SUM=$((W1 + W2))
MAX=$W1
[ "$W2" -gt "$MAX" ] && MAX=$W2

# run_rt <args...> -- sets out (stdout), err (stderr), rc.
run_rt() {
  local errf="$SANDBOX/err"
  out="$(bash "$RT" "$@" 2>"$errf")"
  rc=$?
  err="$(cat "$errf")"
}

# AC1: over budget -> stderr line, no list, exit 6.
run_rt --list --budget-s 1 -j 1 --for "tests/$F1" "tests/$F2"
assert_eq "6" "$rc" "AC1 over-budget --list exits 6"
assert_contains "$err" "estimated $SUM s over budget 1 s (2 test file(s)); not run" "AC1 prints the estimate line on stderr"
assert_eq "" "$out" "AC1 prints no file list"

# AC2: estimate = sum under -j 1, the heaviest under -j above the file count.
run_rt --list --budget-s 1 -j 1 --for "tests/$F1" "tests/$F2"
assert_contains "$err" "estimated $SUM s over" "AC2 -j 1 estimate is the sum of the weights"
run_rt --list --budget-s 1 -j 50 --for "tests/$F1" "tests/$F2"
assert_contains "$err" "estimated $MAX s over" "AC2 -j 50 estimate is the heavier weight"

# AC3: a budget at or above the estimate lists the same files and exits 0.
run_rt --list -j 1 --for "tests/$F1" "tests/$F2"
base_out="$out"; base_rc=$rc
run_rt --list --budget-s 100000 -j 1 --for "tests/$F1" "tests/$F2"
assert_eq "0" "$rc" "AC3 big budget exits 0"
assert_eq "$base_out" "$out" "AC3 big budget lists the same files as without the flag"
assert_eq "0" "$base_rc" "AC3 baseline --list exits 0"
run_rt --list --budget-s "$SUM" -j 1 --for "tests/$F1" "tests/$F2"
assert_eq "0" "$rc" "AC3 budget equal to the estimate is not over"

# AC4: missing, non-numeric or zero value exits 2 naming the flag.
run_rt --list --budget-s
assert_eq "2" "$rc" "AC4 missing value exits 2"
assert_contains "$err" "--budget-s" "AC4 missing value names the flag"
run_rt --list --budget-s abc --for "tests/$F2"
assert_eq "2" "$rc" "AC4 non-numeric value exits 2"
assert_contains "$err" "--budget-s" "AC4 non-numeric value names the flag"
run_rt --list --budget-s 0 --for "tests/$F2"
assert_eq "2" "$rc" "AC4 zero value exits 2"
assert_contains "$err" "--budget-s" "AC4 zero value names the flag"

# AC6: qa.md step 2.
qa_md="$(cat "$TALOS_ROOT/agents/qa.md")"
assert_contains "$qa_md" "--strict --budget-s <budget-s>" "AC6 qa.md shows the targeted command with --budget-s"
assert_contains "$qa_md" "min(verify.timeout_ms, 600000)/1000 - 60" "AC6 qa.md gives the budget derivation"
assert_contains "$qa_md" "Exit 6 is not a block" "AC6 qa.md says exit 6 is not a block"
assert_contains "$qa_md" "targeted run skipped: estimated <n> s over budget; CI is the full run" "AC6 qa.md gives the CI-oracle wording"
assert_contains "$qa_md" "merge.required_checks" "AC6 qa.md decides the oracle by merge.required_checks"
assert_contains "$qa_md" "not run, not a pass" "AC6 qa.md gives the no-oracle wording"

# AC7: the non-pre-CI prompt body names the flag and exit 6.
ci_md="$(cat "$TALOS_ROOT/templates/prompts/_qa-ci.md")"
assert_contains "$ci_md" "--budget-s" "AC7 _qa-ci.md names --budget-s"
assert_contains "$ci_md" "exit 6" "AC7 _qa-ci.md names exit 6"

finish
