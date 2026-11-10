#!/usr/bin/env bash
# Regression tests for the dead-holder reclaim in scripts/pipeline-lock.sh (#871).
#
# The reclaim used to be check-then-`rm -rf`: a waiter read the holder, found it
# dead, then deleted the lock dir -- even when a live process had taken the lock
# between the read and the delete. These tests force that interleaving with a
# `kill` shadow instead of relying on timing.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

# A PID that is certainly not running.
dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# ── AC1: a lock that changed hands after the holder was checked survives ─────
RES1="$SANDBOX/ac1-target"
LOCK1="$RES1.lock.d"
mkdir -p "$LOCK1"
printf '%s\n' "$(dead_pid)" > "$LOCK1/pid"
sleep 30 & LIVE_PID=$!
rc1=0
err1="$( (
  . "$LOCK_SH"
  _hijacked=0
  # On the first liveness check of the dead holder, hand the lock to a live
  # process Y (remove, recreate, write the token of Y), as another waiter would.
  kill() {
    if [ "$_hijacked" -eq 0 ] && [ "$1" = "-0" ]; then
      _hijacked=1
      rm -rf "$LOCK1"
      mkdir "$LOCK1"
      printf '%s\n' "$LIVE_PID:1" > "$LOCK1/pid"
    fi
    builtin kill "$@"
  }
  _lock_acquire "$RES1" 1
) 2>&1 )" || rc1=$?
assert_eq "1" "$rc1" "AC1 reclaim of a changed-hands lock returns 1 (timed out), not 0"
assert_contains "$err1" "timed out" "AC1 the waiter warns that it timed out"
assert_eq "$LIVE_PID:1" "$(cat "$LOCK1/pid" 2>/dev/null || true)" "AC1 the live holder's token is still in the lock dir"
assert_eq "" "$(ls -d "$LOCK1".reclaim.* 2>/dev/null || true)" "AC1 no reclaim dir left after restoring the lock"
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true

# ── AC3: a successful reclaim leaves no reclaim dir; release removes the lock ─
RES3="$SANDBOX/ac3-target"
LOCK3="$RES3.lock.d"
mkdir -p "$LOCK3"
printf '%s\n' "$(dead_pid)" > "$LOCK3/pid"
rc3=0
out3="$( (
  . "$LOCK_SH"
  _lock_acquire "$RES3" 5 || exit 9
  ls -d "$LOCK3".reclaim.* 2>/dev/null
  _lock_release "$RES3"
  [ -e "$LOCK3" ] && echo "lock-still-present"
  exit 0
) 2>&1 )" || rc3=$?
assert_eq "0" "$rc3" "AC3 a dead-holder lock is reclaimed and acquired"
assert_eq "" "$out3" "AC3 no <lockdir>.reclaim.* left behind and the lock is absent after release"
assert_eq "" "$(ls -d "$LOCK3".reclaim.* 2>/dev/null || true)" "AC3 no reclaim dir on disk afterwards"
assert_file_absent "$LOCK3" "AC3 lock dir absent after release"

finish
