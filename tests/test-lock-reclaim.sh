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
      rm -rf "${LOCK1:?}"
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
assert_eq "" "$(ls -d "$LOCK1".reclaim* 2>/dev/null || true)" "AC1 no reclaim dir or gate left behind"
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
  ls -d "$LOCK3".reclaim* 2>/dev/null
  _lock_release "$RES3"
  [ -e "$LOCK3" ] && echo "lock-still-present"
  exit 0
) 2>&1 )" || rc3=$?
assert_eq "0" "$rc3" "AC2 a dead-holder lock that is still unchanged is reclaimed and acquired"
assert_eq "" "$out3" "AC3 no <lockdir>.reclaim* left behind and the lock is absent after release"
assert_eq "" "$(ls -d "$LOCK3".reclaim* 2>/dev/null || true)" "AC3 no reclaim dir or gate on disk afterwards"
assert_file_absent "$LOCK3" "AC3 lock dir absent after release"

# ── AC4: the timeout path still warns once and runs the command ──────────────
RES4="$SANDBOX/ac4-target"
LOCK4="$RES4.lock.d"
mkdir -p "$LOCK4"
printf '%s\n' "$$:1" > "$LOCK4/pid"   # held by this live process
err4="$( ( . "$LOCK_SH"; with_lock "$RES4" 1 -- bash -c "echo ran > '$SANDBOX/ac4.out'" ) 2>&1 >/dev/null )"
assert_eq "1" "$(printf '%s\n' "$err4" | grep -c 'timed out')" "AC4 the timeout path warns exactly once"
assert_file_exists "$SANDBOX/ac4.out" "AC4 the timeout path still runs the command"
assert_eq "$$:1" "$(cat "$LOCK4/pid" 2>/dev/null || true)" "AC4 the live holder lock is left untouched"

# ── AC5 (#923): the lock dir is never absent while a live process holds it ───
# AC1's hand-off plus a third waiter W that mkdirs the lock the instant it is
# missing (a `mv`/`rm` shadow does it right after the real call). Moving the
# live lock away, even to restore it, lets W in beside the holder Z and drops
# Z's lock: the lost updates test-lock.sh saw after #871.
RES5="$SANDBOX/ac5-target"
LOCK5="$RES5.lock.d"
mkdir -p "$LOCK5"
printf '%s\n' "$(dead_pid)" > "$LOCK5/pid"
sleep 30 & LIVE5=$!
sleep 30 & W5=$!
rc5=0
err5="$( (
  . "$LOCK_SH"
  _hijacked=0 _armed=0
  kill() {
    if [ "$_hijacked" -eq 0 ] && [ "$1" = "-0" ]; then
      _hijacked=1
      command rm -rf "${LOCK5:?}"
      command mkdir "$LOCK5"
      printf '%s\n' "$LIVE5:1" > "$LOCK5/pid"
      _armed=1
    fi
    builtin kill "$@"
  }
  # W (a live process): the first time the lock dir goes missing, take it.
  _w_takes() {
    [ "$_armed" -eq 1 ] && [ ! -e "$LOCK5" ] || return 0
    _armed=0
    command mkdir "$LOCK5" && printf '%s\n' "$W5:1" > "$LOCK5/pid"
  }
  mv() { command mv "$@"; local rc=$?; _w_takes; return "$rc"; }
  rm() { command rm "$@"; local rc=$?; _w_takes; return "$rc"; }
  _lock_acquire "$RES5" 1
) 2>&1 )" || rc5=$?
assert_eq "1" "$rc5" "AC5 the waiter times out behind the live holder"
assert_eq "$LIVE5:1" "$(cat "$LOCK5/pid" 2>/dev/null || true)" "AC5 the live holder still owns the lock: no third process got in"
assert_not_contains "$err5" "No such file" "AC5 the holder's pid file is never written into a moved lock dir"
assert_eq "" "$(ls -d "$LOCK5".reclaim* 2>/dev/null || true)" "AC5 no reclaim dir or gate left behind"
kill "$LIVE5" "$W5" 2>/dev/null || true
wait "$LIVE5" "$W5" 2>/dev/null || true

# ── AC6 (#923): a reclaim gate left by a crashed reclaimer does not block ─────
# reclaiming for good: a gate over a minute old is cleared.
RES6="$SANDBOX/ac6-target"
LOCK6="$RES6.lock.d"
mkdir -p "$LOCK6" "$LOCK6.reclaim"
printf '%s\n' "$(dead_pid)" > "$LOCK6/pid"
touch -t 202601010000 "$LOCK6.reclaim"
rc6=0
( . "$LOCK_SH"; _lock_acquire "$RES6" 2 && _lock_release "$RES6" ) >/dev/null 2>&1 || rc6=$?
assert_eq "0" "$rc6" "AC6 a stale reclaim gate is cleared and the dead holder's lock reclaimed"
assert_file_absent "$LOCK6.reclaim" "AC6 the stale gate is gone"

# AC7 a fresh gate (another reclaimer at work) is left alone and the waiter waits.
RES7="$SANDBOX/ac7-target"
LOCK7="$RES7.lock.d"
mkdir -p "$LOCK7" "$LOCK7.reclaim"
printf '%s\n' "$(dead_pid)" > "$LOCK7/pid"
rc7=0
( . "$LOCK_SH"; _lock_acquire "$RES7" 1 ) >/dev/null 2>&1 || rc7=$?
assert_eq "1" "$rc7" "AC7 with a fresh gate held the waiter does not reclaim on its own"
assert_file_exists "$LOCK7/pid" "AC7 the lock is left for the gate holder"

finish
