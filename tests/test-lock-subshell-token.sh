#!/usr/bin/env bash
# Regression tests for #990: pipeline-lock.sh built its ownership token from `$$`,
# which in a subshell is the PARENT shell's pid. Sibling subshell workers then
# handed out identical tokens, so one worker's exit hook deleted a live sibling's
# lock, and a dead subshell's lock named a living parent and was never reclaimed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

assert_ne() {  # $1=unexpected $2=actual $3=label
  if [ "$1" != "$2" ]; then pass "$3"; else fail "$3" "did not expect: $1"; fi
}

# own_pid:the pid of the (sub)shell that runs it, with no BASHPID (bash 3.2 safe).
own_pid() { printf '%s' "$(exec sh -c 'echo "$PPID"')"; }

# AC1: two sibling subshells acquire the same resource; each token carries its own pid.
RES1="$SANDBOX/ac1-target"
OUT1="$SANDBOX/ac1-out"
mkdir -p "$OUT1"
for k in 1 2; do
  (
    . "$LOCK_SH"
    _lock_acquire "$RES1" 5 || exit 9
    printf '%s\n' "$(cat "$RES1.lock.d/pid")" > "$OUT1/token$k"
    own_pid > "$OUT1/pid$k"
    _lock_release "$RES1"
  )
done
T1="$(cat "$OUT1/token1")"; T2="$(cat "$OUT1/token2")"
assert_ne "$T1" "$T2" "AC1 sibling subshells record different tokens"
assert_eq "$(cat "$OUT1/pid1")" "${T1%%:*}" "AC1 subshell 1's token pid is its own pid"
assert_eq "$(cat "$OUT1/pid2")" "${T2%%:*}" "AC1 subshell 2's token pid is its own pid"
assert_ne "$$" "${T1%%:*}" "AC1 the token pid is not the parent's \$\$"

# AC2: worker A acquires and releases, then exits while sibling B holds the lock.
# A's exit hook (registered with A's token) must not remove B's lock.
RES2="$SANDBOX/ac2-target"
LOCK2="$RES2.lock.d"
(
  . "$LOCK_SH"
  _lock_acquire "$RES2" 5 || exit 9
  _lock_release "$RES2"
  n=0
  while [ ! -e "$SANDBOX/ac2-b-holds" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
) &
A2=$!
(
  . "$LOCK_SH"
  # Wait for A to have released, then take the lock and hold it past A's exit.
  _lock_acquire "$RES2" 5 || exit 9
  : > "$SANDBOX/ac2-b-holds"
  n=0
  while kill -0 "$A2" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  sleep 0.5
  [ -d "$LOCK2" ] && : > "$SANDBOX/ac2-b-still-holds"
  _lock_release "$RES2"
) &
B2=$!
wait "$A2" 2>/dev/null || true
wait "$B2" 2>/dev/null || true
assert_file_exists "$SANDBOX/ac2-b-still-holds" "AC2 a worker's exit does not remove a sibling's live lock"

# AC3: 4 subshell workers x 20 with_lock increments, 5 runs, exactly 80 and no timeout.
for run in 1 2 3 4 5; do
  RES="$SANDBOX/ac3-counter-$run"
  ERR="$SANDBOX/ac3-err-$run"
  printf '0' > "$RES"
  mkdir -p "$ERR"
  lock_contention_run "$RES" 4 20 120 "$ERR"
  v="$(lock_contention_verdict "$ERR" "$(cat "$RES")" 80)"
  assert_eq "ok" "$v" "AC3 run $run: counter is exactly 80 and no acquire timed out"
done

# AC4: a lock held by a subshell that exited (parent still alive) is reclaimed.
RES4="$SANDBOX/ac4-target"
( . "$LOCK_SH"; _lock_acquire "$RES4" 5 || exit 9; exec true )
assert_file_exists "$RES4.lock.d/pid" "AC4 the exited subshell left its lock behind"
rc4=0
err4="$( ( . "$LOCK_SH"; _lock_acquire "$RES4" 5 ) 2>&1 )" || rc4=$?
assert_eq "0" "$rc4" "AC4 the next waiter reclaims the dead subshell's lock"
assert_not_contains "$err4" "timed out" "AC4 the reclaim does not time out"

# AC5: with no BASHPID (bash 3.2) the pid is still the subshell's own.
RES5="$SANDBOX/ac5-target"
OUT5="$SANDBOX/ac5-out"
(
  . "$LOCK_SH"
  unset BASHPID
  _lock_acquire "$RES5" 5 || exit 9
  cat "$RES5.lock.d/pid" > "$OUT5.token"
  own_pid > "$OUT5.pid"
  _lock_release "$RES5"
)
T5="$(cat "$OUT5.token")"
assert_eq "$(cat "$OUT5.pid")" "${T5%%:*}" "AC5 the fallback pid lookup records the subshell's own pid"
assert_ne "$$" "${T5%%:*}" "AC5 the fallback does not record the parent's \$\$"

# AC6: a lock whose pid names a live process is left in place by a waiter.
RES6="$SANDBOX/ac6-target"
mkdir -p "$RES6.lock.d"
sleep 30 </dev/null >/dev/null 2>&1 & LIVE6=$!
printf '%s:1\n' "$LIVE6" > "$RES6.lock.d/pid"
rc6=0
( . "$LOCK_SH"; _lock_acquire "$RES6" 1 ) >/dev/null 2>&1 || rc6=$?
assert_eq "1" "$rc6" "AC6 a waiter times out behind a live holder"
assert_eq "$LIVE6:1" "$(cat "$RES6.lock.d/pid" 2>/dev/null || true)" "AC6 the live holder's lock is left in place"
kill "$LIVE6" 2>/dev/null || true
wait "$LIVE6" 2>/dev/null || true

finish
