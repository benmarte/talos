#!/usr/bin/env bash
# Regression tests for clearing a stale reclaim gate in scripts/pipeline-lock.sh
# (#1105). A waiter that clears a stale gate from an old reading must not move or
# remove a gate that a live reclaimer has taken since: putting it back afterwards
# can leave a gate no process owns, and while the path is empty a second
# reclaimer gets in. The order is forced with function overrides in the waiter
# subshells and marker-file barriers, never with timing.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# _await FILE -- wait up to 10 s for a marker file; a barrier that times out is
# logged, so a run whose order was not forced fails instead of passing by luck.
_await() {
  local _n=100
  while [ ! -e "$1" ]; do
    if [ "$_n" -le 0 ]; then printf '%s\n' "$1" >> "$SYNC/barrier-timeouts"; return 1; fi
    sleep 0.1; _n=$((_n - 1))
  done
}

# new_case NAME -- a dead holder's lock plus a reclaim gate over a minute old.
new_case() {
  RES="$SANDBOX/$1-target"
  LOCK="$RES.lock.d"
  GATE="$LOCK.reclaim"
  SYNC="$SANDBOX/$1-sync"
  DEAD="$(dead_pid):1"
  mkdir -p "$LOCK" "$SYNC"
  printf '%s\n' "$DEAD" > "$LOCK/pid"
  printf '%s\n' "999999" > "$GATE"
  touch -t 202601010000 "$GATE"
}

# _load_lock -- source the lock script in a waiter and keep its real gated
# removal callable as _real_remove_dir.
_load_lock() {
  . "$LOCK_SH"
  eval "_real_remove_dir() $(declare -f _lock_remove_dir | sed 1d)"
}

# _barrier_on_gate_age MINE THEN -- shadow `find`: after this waiter's first age
# reading of the gate, write marker MINE and hold the reading until THEN exists.
_barrier_on_gate_age() {
  _AGE_MINE="$1" _AGE_THEN="$2" _AGE_DONE=0
  find() {
    if [ "$1" = "$GATE" ] && [ "$_AGE_DONE" -eq 0 ]; then
      local _out
      _out="$(command find "$@")"
      _AGE_DONE=1
      : > "$_AGE_MINE"
      _await "$_AGE_THEN"
      [ -n "$_out" ] && printf '%s\n' "$_out"
      return 0
    fi
    command find "$@"
  }
}

# _in_gated_section -- true when this removal is a gated reclaim of the dead
# holder's lock (and not the release of a lock this waiter holds).
_in_gated_section() {
  [ "$1" = "$LOCK" ] && [ "$(command cat "$LOCK/pid" 2>/dev/null || true)" = "$DEAD" ]
}

# ── the forced interleaving ──────────────────────────────────────────────────
# W1 and W2 both read the old gate as stale. W1 clears it, takes a new gate and
# pauses inside the reclaim. W2 then makes its clear attempt from the old
# reading; W1 releases before that attempt returns.
waiter1() {  # $1 = 1 to start W3 while inside the gate
  (
    _load_lock
    _barrier_on_gate_age "$SYNC/w1-seen" "$SYNC/w2-seen"
    _lock_remove_dir() {
      if ! _in_gated_section "$1"; then _real_remove_dir "$@"; return; fi
      printf 'enter w1\n' >> "$SYNC/section"
      command cat "$GATE" > "$SYNC/w1-gate" 2>/dev/null
      : > "$SYNC/w1-inside"
      _await "$SYNC/w2-acted"
      if [ -f "$GATE" ] && [ "$(command cat "$GATE" 2>/dev/null)" = "$(command cat "$SYNC/w1-gate")" ]; then
        printf 'own\n' > "$SYNC/w1-view"
      elif [ -e "$GATE" ]; then
        printf 'foreign\n' > "$SYNC/w1-view"
      else
        printf 'absent\n' > "$SYNC/w1-view"
      fi
      if [ "$1" = "$LOCK" ] && [ "$W3_ON" -eq 1 ]; then
        : > "$SYNC/w3-go"
        _await "$SYNC/w3-done"
      fi
      : > "$SYNC/w1-leaving"
      printf 'exit w1\n' >> "$SYNC/section"
      _real_remove_dir "$@"
    }
    W3_ON="$1"
    _rc=0
    _lock_acquire "$RES" 5 || _rc=$?
    _lock_release "$RES"
    printf '%s\n' "$_rc" > "$SYNC/rc-w1"
    : > "$SYNC/w1-released"
  ) >/dev/null 2>&1
}

waiter2() {
  (
    _load_lock
    _barrier_on_gate_age "$SYNC/w2-seen" "$SYNC/w1-inside"
    # After each file operation of W2 while W1 is inside, the gate path must
    # still hold the gate W1 took.
    _probe_gate() {
      [ -e "$SYNC/w1-inside" ] && [ ! -e "$SYNC/w1-leaving" ] || return 0
      if [ ! -f "$GATE" ] || [ "$(command cat "$GATE" 2>/dev/null)" != "$(command cat "$SYNC/w1-gate")" ]; then
        printf '%s\n' "$1" >> "$SYNC/gate-violations"
      fi
    }
    mv() { command mv "$@"; local _rc=$?; _probe_gate "mv"; return "$_rc"; }
    rm() { command rm "$@"; local _rc=$?; _probe_gate "rm"; return "$_rc"; }
    rmdir() { command rmdir "$@"; local _rc=$?; _probe_gate "rmdir"; return "$_rc"; }
    # A put-back of the gate by `ln` is held until W1 has released.
    ln() {
      local _last
      for _last in "$@"; do :; done
      if [ "$_last" = "$GATE" ]; then : > "$SYNC/w2-acted"; _await "$SYNC/w1-released"; fi
      command ln "$@"
    }
    # The clear attempt acts, then does not return until W1 has released.
    eval "_real_clear_gate() $(declare -f _lock_clear_stale_gate | sed 1d)"
    _CLEARS=0
    _lock_clear_stale_gate() {
      local _rc=0
      _real_clear_gate "$@" || _rc=$?
      _CLEARS=$((_CLEARS + 1))
      if [ "$_CLEARS" -eq 1 ]; then
        printf '%s\n' "$_rc" > "$SYNC/w2-clear-rc"
        : > "$SYNC/w2-acted"
        _await "$SYNC/w1-released"
      fi
      return "$_rc"
    }
    _rc=0
    _lock_acquire "$RES" 5 || _rc=$?
    _lock_release "$RES"
    printf '%s\n' "$_rc" > "$SYNC/rc-w2"
  ) >/dev/null 2>&1
}

waiter3() {
  (
    _load_lock
    _lock_remove_dir() {
      if ! _in_gated_section "$1"; then _real_remove_dir "$@"; return; fi
      printf 'enter w3\n' >> "$SYNC/section"
      _real_remove_dir "$@"
      printf 'exit w3\n' >> "$SYNC/section"
    }
    _await "$SYNC/w3-go"
    _lock_acquire "$RES" 1 && _lock_release "$RES"
    : > "$SYNC/w3-done"
  ) >/dev/null 2>&1
}

# run_interleaving NAME W3 -- set up the case and run the waiters to the end.
run_interleaving() {
  local _p1 _p2 _p3=""
  new_case "$1"
  : > "$SYNC/section"
  if [ "$2" -eq 1 ]; then waiter3 & _p3=$!; fi
  waiter1 "$2" & _p1=$!
  waiter2 & _p2=$!
  wait "$_p1" "$_p2" ${_p3:+"$_p3"} 2>/dev/null || true
}

# overlaps FILE -- the number of gated-section entries made while another
# waiter was still inside.
overlaps() { awk '$1 == "enter" { if (n > 0) o++; n++ } $1 == "exit" { n-- } END { print o + 0 }' "$1"; }

# ── AC1 and AC2: two waiters ─────────────────────────────────────────────────
run_interleaving ac12 0
assert_file_absent "$SYNC/barrier-timeouts" "AC1 the interleaving was forced: no barrier timed out"
assert_file_exists "$SYNC/w2-acted" "AC1 W2 made its clear attempt while W1 was inside the gate"
assert_eq "0" "$(command cat "$SYNC/rc-w1" 2>/dev/null)" "AC1 W1 acquires the lock"
assert_eq "0" "$(command cat "$SYNC/rc-w2" 2>/dev/null)" "AC1 W2 acquires the lock"
assert_eq "" "$(ls -d "$GATE"* 2>/dev/null || true)" "AC1 no reclaim gate is left on disk after both waiters finish"
printf '%s\n' "$(dead_pid):2" > "$SANDBOX/ac1-dead"
mkdir -p "$LOCK"
cp "$SANDBOX/ac1-dead" "$LOCK/pid"
rc1=0
( . "$LOCK_SH"; _lock_acquire "$RES" 2 && _lock_release "$RES" ) >/dev/null 2>&1 || rc1=$?
assert_eq "0" "$rc1" "AC1 a new dead holder's lock on the same resource is reclaimed with no grace-period wait"

assert_eq "own" "$(command cat "$SYNC/w1-view" 2>/dev/null)" "AC2 W1, inside the gate after W2's attempt, still sees its own gate"
assert_eq "" "$(command cat "$SYNC/gate-violations" 2>/dev/null || true)" "AC2 no operation of W2 left the gate path absent or holding other content"

# ── AC3: a third waiter while W2's attempt is in flight ──────────────────────
run_interleaving ac3 1
assert_file_absent "$SYNC/barrier-timeouts" "AC3 the interleaving was forced: no barrier timed out"
assert_file_exists "$SYNC/w3-done" "AC3 the third waiter ran while W1 was inside the gate"
assert_eq "1" "$(grep -c '^enter w1$' "$SYNC/section")" "AC3 W1 entered the gated reclaim once"
assert_eq "0" "$(overlaps "$SYNC/section")" "AC3 no second reclaimer entered the gated section while W1 was inside"

# ── AC4 (same: #1011): two stale readers, no forced order ────────────────────
new_case ac4
waiter4() {  # $1 = this waiter, $2 = the other one
  (
    . "$LOCK_SH"
    _barrier_on_gate_age "$SYNC/seen.$1" "$SYNC/seen.$2"
    _rc=0
    _lock_acquire "$RES" 5 || _rc=$?
    _lock_release "$RES"
    printf '%s\n' "$_rc" > "$SYNC/rc-$1"
  ) >/dev/null 2>&1
}
waiter4 a b & PA=$!
waiter4 b a & PB=$!
wait "$PA" "$PB" 2>/dev/null || true
assert_eq "0 0" "$(command cat "$SYNC/rc-a" 2>/dev/null) $(command cat "$SYNC/rc-b" 2>/dev/null)" "AC4 both waiters that read one stale gate acquire the lock"
assert_file_absent "$LOCK" "AC4 the dead holder's lock was reclaimed and released"
assert_eq "" "$(ls -d "$GATE"* 2>/dev/null || true)" "AC4 no reclaim path is left on disk"

# ── AC5 (same: #923): fresh gate waited on, old directory gate cleared ───────
new_case ac5-fresh
touch "$GATE"
rc5=0
( . "$LOCK_SH"; _lock_acquire "$RES" 1 ) >/dev/null 2>&1 || rc5=$?
assert_eq "1" "$rc5" "AC5 a fresh gate is waited on until the timeout"
assert_eq "999999" "$(command cat "$GATE" 2>/dev/null)" "AC5 the fresh gate is left on disk"

new_case ac5-dir
rm -f "${GATE:?}"
mkdir "$GATE"
touch -t 202601010000 "$GATE"
rc5d=0
( . "$LOCK_SH"; _lock_acquire "$RES" 3 && _lock_release "$RES" ) >/dev/null 2>&1 || rc5d=$?
assert_eq "0" "$rc5d" "AC5 an old directory gate from an older version is cleared"
assert_eq "" "$(ls -d "$GATE"* 2>/dev/null || true)" "AC5 no reclaim path is left after the directory gate"

# A waiter that died while clearing leaves its claim on that gate behind; once
# that claim is old too, the gate is still cleared.
new_case ac5-dead-clearer
printf '%s\n' "999998" > "$GATE.clear.999999.0"
touch -t 202601010000 "$GATE.clear.999999.0"
rc5c=0
( . "$LOCK_SH"; _lock_acquire "$RES" 3 && _lock_release "$RES" ) >/dev/null 2>&1 || rc5c=$?
assert_eq "0" "$rc5c" "AC5 a stale gate whose earlier clearer died is still cleared"
assert_file_absent "$GATE" "AC5 the stale gate is gone after a dead clearer"

finish
