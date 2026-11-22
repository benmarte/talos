#!/usr/bin/env bash
# Contention tests for scripts/pipeline-lock.sh (#978): a waiter that starves
# (its acquire times out and with_lock proceeds WITHOUT the lock, by design) must
# be reported as a starved waiter, never as a lost update -- the two have
# different causes (a loaded runner vs. a broken exclusion).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

# AC1: one acquire times out under forced contention -> reported as starved.
# A live process holds the lock for the whole run, so the worker's single
# acquire (1 s timeout) must give up and run its increment without the lock.
S_RES="$SANDBOX/ac1-counter"
S_ERR="$SANDBOX/ac1-err"
printf '0' > "$S_RES"
mkdir -p "$S_ERR" "$S_RES.lock.d"
sleep 30 </dev/null >/dev/null 2>&1 & S_HOLDER=$!
printf '%s:1\n' "$S_HOLDER" > "$S_RES.lock.d/pid"
lock_contention_run "$S_RES" 1 1 1 "$S_ERR"
# AC3: with_lock still proceeds without the lock after its timeout, with one
# warning, and leaves the live holder's lock alone (the existing lock tests,
# placed here because tests/test-lock.sh is not on the spec's Tests: line).
assert_eq "1" "$(cat "$S_RES")" "AC3 with_lock runs the command after its acquire timed out"
assert_eq "1" "$(cat "$S_ERR"/*.err | grep -c 'timed out after')" "AC3 a timed-out acquire prints exactly one warning"
assert_file_exists "$S_RES.lock.d/pid" "AC3 a timed-out waiter does not release the live holder's lock"
kill "$S_HOLDER" 2>/dev/null || true
rm -rf "${S_RES:?}.lock.d"
verdict="$(lock_contention_verdict "$S_ERR" "$(cat "$S_RES")" 1)"
assert_contains "$verdict" "a waiter timed out (starved), 1 of 1" \
  "AC1 a timed-out acquire is reported as a starved waiter"
assert_not_contains "$verdict" "lost update" \
  "AC1 a timed-out acquire is not reported as a lost update"

# Positive control: no timeout line and a short counter is the exclusion bug.
mkdir -p "$SANDBOX/ac1-clean"
v2="$(lock_contention_verdict "$SANDBOX/ac1-clean" 79 80)"
assert_contains "$v2" "lost update with no timeout, 79 of 80" \
  "AC1 a short counter with no timeout is reported as a lost update"
v3="$(lock_contention_verdict "$SANDBOX/ac1-clean" 80 80)"
assert_eq "ok" "$v3" "AC1 an exact counter with no timeout is ok"

# AC2: 4 workers x 20 increments, 120 s timeout, 5 back-to-back runs.
for run in 1 2 3 4 5; do
  RES="$SANDBOX/ac2-counter-$run"
  ERR="$SANDBOX/ac2-err-$run"
  printf '0' > "$RES"
  mkdir -p "$ERR"
  lock_contention_run "$RES" 4 20 120 "$ERR"
  v="$(lock_contention_verdict "$ERR" "$(cat "$RES")" 80)"
  assert_eq "ok" "$v" "AC2 run $run: counter is exactly 80 and no acquire timed out"
  assert_file_absent "$RES.lock.d" "AC2 run $run: lock dir is cleaned up"
done

finish
