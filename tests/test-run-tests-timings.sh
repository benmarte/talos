#!/usr/bin/env bash
# test-run-tests-timings.sh -- run-tests.sh --timings (or TALOS_TEST_TIMINGS=1)
# prints a "TIMINGS" block with one "<secs>  tests/<name>" line per file,
# slowest first, before the RESULT line; without it the output has no such
# block (#483). Lets a slow suite be traced to the files that make it slow.
#
# Fixture: a COPY of run-tests.sh in a throwaway tests/ dir (see
# test-run-tests-parallel.sh), so TALOS_ROOT and the result cache stay isolated.
#
# Mutations that make this RED: drop the TIMINGS block (every assertion), sort
# ascending (the order assertion), or print it without the flag (the
# "off by default" assertion).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

FD="$SANDBOX/fx"
mkdir -p "$FD/tests/stubs"
cp "$TALOS_ROOT/tests/run-tests.sh" "$FD/tests/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/test-aaa-fast.sh"
printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$FD/tests/test-zzz-slow.sh"

out_off="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet 2>&1)"; rc_off=$?
out_flag="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet --timings 2>&1)"; rc_flag=$?
out_env="$(TALOS_TEST_TIMINGS=1 bash "$FD/tests/run-tests.sh" --no-cache --quiet 2>&1)"; rc_env=$?

assert_exit_code 0 "$rc_off" "default: run passes"
assert_exit_code 0 "$rc_flag" "--timings: run passes"
assert_exit_code 0 "$rc_env" "TALOS_TEST_TIMINGS=1: run passes"
assert_not_contains "$out_off" "TIMINGS" "default: no timings block"

for mode in flag env; do
  eval "o=\$out_$mode"
  assert_contains "$o" "TIMINGS (seconds, slowest first):" "$mode: the timings block is printed"
  block="$(printf '%s\n' "$o" | sed -n '/^TIMINGS/,/^RESULT/p' | grep 'tests/test-')"
  assert_eq "2" "$(printf '%s\n' "$block" | grep -c .)" "$mode: one line per file"
  assert_eq "tests/test-zzz-slow.sh" "$(printf '%s\n' "$block" | head -n 1 | awk '{print $2}')" "$mode: the slowest file is listed first"
  slow_secs="$(printf '%s\n' "$block" | head -n 1 | awk '{print $1}')"
  case "$slow_secs" in
    ''|*[!0-9]*) fail "$mode: the slow file's seconds is a whole number" "got: '$slow_secs'" ;;
    *) if [ "$slow_secs" -ge 2 ]; then pass "$mode: the slow file shows at least its 2s sleep"; else fail "$mode: the slow file shows at least its 2s sleep" "got: ${slow_secs}s"; fi ;;
  esac
  assert_contains "$(printf '%s\n' "$o" | tail -n 1)" "RESULT: all 2 test file(s) passed" "$mode: RESULT is still the last line"
done

finish
