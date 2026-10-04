#!/usr/bin/env bash
# test-run-tests-failed-summary.sh -- run-tests.sh ends a failing run with one
# "FAILED: tests/<name>" line per failing file next to the RESULT line, in
# normal and --quiet mode, and --quiet adds the first failing assertion (#448).
# A `tail` of a quiet run is all a person reads, so the summary must live there.
#
# Fixture: a COPY of run-tests.sh in a throwaway tests/ dir (see
# test-run-tests-parallel.sh), so TALOS_ROOT and the result cache stay isolated.
#
# Mutations that make this RED: drop the FAILED_SUMMARY printf before the
# RESULT line (every assertion below), or drop the --quiet first-failure block
# (the "first failure" assertions).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

FD="$SANDBOX/fx"
mkdir -p "$FD/tests/stubs"
cp "$TALOS_ROOT/tests/run-tests.sh" "$FD/tests/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/test-good.sh"
# Same output shape helpers.sh produces: "FAIL  <label>" then a detail line.
printf '#!/usr/bin/env bash\necho "  ok  fine" \nprintf "FAIL  first bad assertion\\n" >&2\nprintf "FAIL  second bad assertion\\n" >&2\nexit 1\n' > "$FD/tests/test-bad-one.sh"
printf '#!/usr/bin/env bash\necho "died before any assertion"\nexit 3\n' > "$FD/tests/test-bad-two.sh"
git -C "$SANDBOX" add -A "$FD" >/dev/null 2>&1 || true

out_n="$(bash "$FD/tests/run-tests.sh" --no-cache 2>&1)"; rc_n=$?
out_q="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet 2>&1)"; rc_q=$?

assert_exit_code 1 "$rc_n" "normal: a failing run exits 1"
assert_exit_code 1 "$rc_q" "quiet: a failing run exits 1"

for mode in n q; do
  eval "o=\$out_$mode"
  tail2="$(printf '%s\n' "$o" | tail -n 6)"
  assert_eq "1" "$(printf '%s\n' "$o" | grep -c '^FAILED: tests/test-bad-one.sh$')" "$mode: one FAILED line for test-bad-one.sh"
  assert_eq "1" "$(printf '%s\n' "$o" | grep -c '^FAILED: tests/test-bad-two.sh$')" "$mode: one FAILED line for test-bad-two.sh"
  assert_eq "0" "$(printf '%s\n' "$o" | grep -c '^FAILED: tests/test-good.sh')" "$mode: no FAILED line for a passing file"
  assert_contains "$tail2" "FAILED: tests/test-bad-one.sh" "$mode: the FAILED lines are in the tail, next to RESULT"
  assert_eq "RESULT: 2 of 3 test file(s) FAILED" "$(printf '%s\n' "$o" | tail -n 1)" "$mode: RESULT is still the last line"
done

assert_contains "$out_q" "  first failure: FAIL  first bad assertion" "quiet: the first failing assertion is shown"
assert_not_contains "$(printf '%s\n' "$out_q" | tail -n 5)" "second bad assertion" "quiet: only the first assertion is in the summary"
assert_contains "$out_q" "  first failure: died before any assertion" "quiet: a file that died before any assertion shows its last line"
assert_not_contains "$out_n" "first failure:" "normal: no first-failure line (the full log is already printed)"

# A fully green run prints no FAILED line.
rm -f "$FD/tests/test-bad-one.sh" "$FD/tests/test-bad-two.sh"
out_g="$(bash "$FD/tests/run-tests.sh" --no-cache 2>&1)"; rc_g=$?
assert_exit_code 0 "$rc_g" "green: a passing run exits 0"
assert_not_contains "$out_g" "FAILED:" "green: no FAILED line"

finish
