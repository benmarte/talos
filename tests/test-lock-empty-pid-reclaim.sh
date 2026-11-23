#!/usr/bin/env bash
# Regression tests for the reclaim of a lock whose holder died inside the claim
# window (#1011): a lock dir with no pid file, or an empty one, is reclaimed once
# the dir is over the grace period old, and a stale reclaim gate is cleared by
# one waiter only (an atomic rename, not an rm -rf two waiters can both run).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# ── AC1: no pid file, dir mtime 2 minutes old -> reclaimed ───────────────────
RES1="$SANDBOX/ac1-target"
LOCK1="$RES1.lock.d"
mkdir -p "$LOCK1"
touch -t 202601010000 "$LOCK1"
rc1=0
( . "$LOCK_SH"; _lock_acquire "$RES1" 3 && _lock_release "$RES1" ) >/dev/null 2>&1 || rc1=$?
assert_eq "0" "$rc1" "AC1 a lock dir with no pid file and an old mtime is reclaimed, no timeout"
assert_file_absent "$LOCK1" "AC1 the lock dir is gone after the acquire and release"

# ── AC2: empty pid file, old dir mtime -> reclaimed ──────────────────────────
RES2="$SANDBOX/ac2-target"
LOCK2="$RES2.lock.d"
mkdir -p "$LOCK2"
: > "$LOCK2/pid"
touch -t 202601010000 "$LOCK2"
rc2=0
( . "$LOCK_SH"; _lock_acquire "$RES2" 3 && _lock_release "$RES2" ) >/dev/null 2>&1 || rc2=$?
assert_eq "0" "$rc2" "AC2 a lock dir with an empty pid file and an old mtime is reclaimed, no timeout"
assert_file_absent "$LOCK2" "AC2 the lock dir is gone after the acquire and release"

# ── AC3: no pid file, fresh mtime (inside the grace period) -> waited on ─────
RES3="$SANDBOX/ac3-target"
LOCK3="$RES3.lock.d"
mkdir -p "$LOCK3"
rc3=0
( . "$LOCK_SH"; _lock_acquire "$RES3" 1 ) >/dev/null 2>&1 || rc3=$?
assert_eq "1" "$rc3" "AC3 a fresh lock dir with no pid file is waited on until the timeout"
assert_eq "dir" "$([ -d "$LOCK3" ] && echo dir || echo missing)" "AC3 the fresh lock dir is left alone"
# the same for a fresh dir holding an empty pid file (a holder between create and write)
RES3B="$SANDBOX/ac3b-target"
LOCK3B="$RES3B.lock.d"
mkdir -p "$LOCK3B"
: > "$LOCK3B/pid"
rc3b=0
( . "$LOCK_SH"; _lock_acquire "$RES3B" 1 ) >/dev/null 2>&1 || rc3b=$?
assert_eq "1" "$rc3b" "AC3 a fresh lock dir with an empty pid file is waited on until the timeout"
assert_file_exists "$LOCK3B/pid" "AC3 the fresh empty pid file is left alone"

# ── AC4: a stale gate and two concurrent waiters: one rename clears it ───────
RES4="$SANDBOX/ac4-target"
LOCK4="$RES4.lock.d"
GATE4="$LOCK4.reclaim"
RENAMES4="$SANDBOX/ac4-renames"
mkdir -p "$LOCK4"
printf '%s\n' "$(dead_pid)" > "$LOCK4/pid"
printf '%s\n' "999999" > "$GATE4"
touch -t 202601010000 "$GATE4"
: > "$RENAMES4"
waiter4() {  # $1 = waiter name
  (
    WAITER="$1"
    . "$LOCK_SH"
    _barrier_done=0
    # Both waiters must have read the gate as stale before either clears it.
    find() {
      if [ "$1" = "$GATE4" ] && [ "$_barrier_done" -eq 0 ]; then
        local out i=0
        out="$(command find "$@")"
        _barrier_done=1
        : > "$SANDBOX/ac4-seen.$WAITER"
        while [ "$(ls "$SANDBOX"/ac4-seen.* 2>/dev/null | wc -l)" -lt 2 ] && [ "$i" -lt 50 ]; do
          sleep 0.1; i=$((i + 1))
        done
        [ -n "$out" ] && printf '%s\n' "$out"
        return 0
      fi
      command find "$@"
    }
    # Log every successful rename of the gate itself.
    mv() {
      command mv "$@"; local rc=$?
      if [ "$rc" -eq 0 ] && [ "$1" = "$GATE4" ]; then printf '%s\n' "$WAITER" >> "$RENAMES4"; fi
      return "$rc"
    }
    _lock_acquire "$RES4" 5 && _lock_release "$RES4"
  ) >/dev/null 2>&1
}
waiter4 w1 & P41=$!
waiter4 w2 & P42=$!
wait "$P41" "$P42" 2>/dev/null || true
assert_eq "1" "$(grep -c . "$RENAMES4")" "AC4 exactly one waiter's rename of the stale gate succeeds"
assert_file_absent "$GATE4" "AC4 the stale gate is cleared"
assert_file_absent "$LOCK4" "AC4 the dead holder's lock was reclaimed and released"

# ── AC5 (same: a live holder's lock is never reclaimed) ──────────────────────
RES5="$SANDBOX/ac5-target"
LOCK5="$RES5.lock.d"
mkdir -p "$LOCK5"
printf '%s\n' "$$:1" > "$LOCK5/pid"      # held by this live process
touch -t 202601010000 "$LOCK5"           # an old dir does not make a live holder stale
rc5=0
err5="$( ( . "$LOCK_SH"; _lock_acquire "$RES5" 1 ) 2>&1 )" || rc5=$?
assert_eq "1" "$rc5" "AC5 a live holder's lock is waited on until the timeout"
assert_contains "$err5" "timed out" "AC5 the waiter warns that it timed out"
assert_eq "$$:1" "$(cat "$LOCK5/pid" 2>/dev/null || true)" "AC5 the live holder's token is untouched"

finish
