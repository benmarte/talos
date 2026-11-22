#!/usr/bin/env bash
# Tests for the lock claim in scripts/pipeline-lock.sh (#999): on Ubuntu 26.04
# (uutils coreutils) `mkdir` is not an atomic exclusive create, so several
# racers can all see exit 0. The claim must be the O_EXCL create of the pid file
# (bash noclobber), not mkdir's exit status. A fake `mkdir` first on PATH that
# always exits 0 -- even when the directory exists -- reproduces that on any OS.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

# The non-atomic mkdir: creates the directory if missing, always exits 0.
FAKEBIN="$SANDBOX/fakebin"
/bin/mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/mkdir" <<'FAKE_MKDIR_EOF'
#!/bin/sh
for _a in "$@"; do
  case "$_a" in -*) ;; *) /bin/mkdir -p "$_a" 2>/dev/null ;; esac
done
exit 0
FAKE_MKDIR_EOF
chmod +x "$FAKEBIN/mkdir"

# A PID that is certainly not running.
dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# wait_for_files N DIR PREFIX -- spin (max ~10 s) until DIR holds N files PREFIX*.
wait_for_files() {
  local _n=100
  while [ "$_n" -gt 0 ] && [ "$(ls "$2" 2>/dev/null | grep -c "^$3")" -lt "$1" ]; do
    sleep 0.1; _n=$((_n - 1))
  done
}

# ── AC1: 4 workers x 20 with_lock increments, 5 runs, fake mkdir ─────────────
# Each critical section also claims an in-section marker with noclobber and
# removes it on the way out; a failed claim is an overlap of two sections.
ac1_run() {
  local res="$1" err="$2" k pids=""
  for k in 1 2 3 4; do
    (
      PATH="$FAKEBIN:$PATH"
      . "$LOCK_SH"
      i=0
      while [ "$i" -lt 20 ]; do
        with_lock "$res" 120 -- bash -c '
          set -C
          if ! : > "$1.inside" 2>/dev/null; then : >> "$1.overlap"; fi
          set +C
          val=$(cat "$1"); sleep 0.01; printf "%s" "$((val + 1))" > "$1"
          rm -f "$1.inside"' _ "$res"
        i=$((i + 1))
      done
    ) 2>"$err/w$k.err" &
    pids="$pids $!"
  done
  for k in $pids; do wait "$k"; done
}
for run in 1 2 3 4 5; do
  RES1="$SANDBOX/ac1-counter-$run"
  ERR1="$SANDBOX/ac1-err-$run"
  printf '0' > "$RES1"
  /bin/mkdir -p "$ERR1"
  ac1_run "$RES1" "$ERR1"
  assert_eq "ok" "$(lock_contention_verdict "$ERR1" "$(cat "$RES1")" 80)" \
    "AC1 run $run: fake mkdir, counter is exactly 80 and no acquire timed out"
  assert_file_absent "$RES1.overlap" "AC1 run $run: no two critical sections overlapped"
done

# ── AC2: exactly one of 4 concurrent acquires wins, fake mkdir ───────────────
RES2="$SANDBOX/ac2-res"
D2="$SANDBOX/ac2-out"
/bin/mkdir -p "$D2/ready"
GO2="$SANDBOX/ac2-go"
pids2=""
for k in 1 2 3 4; do
  (
    PATH="$FAKEBIN:$PATH"
    . "$LOCK_SH"
    : > "$D2/ready/r$k"
    while [ ! -e "$GO2" ]; do :; done
    rc=0
    _lock_acquire "$RES2" 1 2>/dev/null || rc=$?
    printf '%s\n' "$rc" > "$D2/rc$k"
    # hold past every other waiter's 1 s timeout: nobody wins after a release
    [ "$rc" -eq 0 ] && sleep 3
    exit 0
  ) &
  pids2="$pids2 $!"
done
wait_for_files 4 "$D2/ready" r
: > "$GO2"
for p in $pids2; do wait "$p"; done
winners2="$(cat "$D2"/rc* 2>/dev/null | grep -c '^0$' || true)"
assert_eq "1" "$winners2" "AC2 exactly one of 4 concurrent _lock_acquire calls returns 0 under the fake mkdir"
assert_eq "4" "$(ls "$D2" | grep -c '^rc')" "AC2 all four acquires returned"

# ── AC3: the reclaim gate admits one reclaimer, fake mkdir ───────────────────
# Two waiters both find the dead holder. Every removal of the lock that still
# holds the dead token is logged (before it is done) and held at a two-party
# barrier, so two reclaimers inside the gate would both get through.
RES3="$SANDBOX/ac3-res"
LOCK3="$RES3.lock.d"
D3="$SANDBOX/ac3-out"
/bin/mkdir -p "$D3/arr" "$LOCK3"
DEAD3="$(dead_pid):1"
printf '%s\n' "$DEAD3" > "$LOCK3/pid"
pids3=""
for k in 1 2; do
  (
    PATH="$FAKEBIN:$PATH"
    . "$LOCK_SH"
    _probe() {
      local _a _hit=0
      for _a in "$@"; do [ "$_a" = "$LOCK3" ] && _hit=1; done
      [ "$_hit" -eq 1 ] && [ "$(command cat "$LOCK3/pid" 2>/dev/null || true)" = "$DEAD3" ] || return 0
      : > "$D3/arr/w$k"
      local _n=10
      while [ "$_n" -gt 0 ] && [ "$(ls "$D3/arr" | wc -l | tr -d ' ')" -lt 2 ]; do
        sleep 0.1; _n=$((_n - 1))
      done
    }
    rm() { _probe "$@"; command rm "$@"; }
    mv() { _probe "$@"; command mv "$@"; }
    _lock_acquire "$RES3" 3 2>/dev/null && _lock_release "$RES3"
    exit 0
  ) &
  pids3="$pids3 $!"
done
for p in $pids3; do wait "$p"; done
assert_eq "1" "$(ls "$D3/arr" | wc -l | tr -d ' ')" "AC3 exactly one waiter removed the dead holder's lock under the fake mkdir"

# ── AC4: the caller's noclobber setting is left as it was ────────────────────
nc_state() { case $- in *C*) printf 'on' ;; *) printf 'off' ;; esac; }
for want in on off; do
  RES4="$SANDBOX/ac4-$want"
  got="$(
    PATH="$FAKEBIN:$PATH"
    . "$LOCK_SH"
    if [ "$want" = on ]; then set -C; else set +C; fi
    _lock_acquire "$RES4" 2 >/dev/null 2>&1
    a="$(nc_state)"
    _lock_release "$RES4"
    with_lock "$RES4" 2 -- true >/dev/null 2>&1
    w="$(nc_state)"
    # lost claim: a live holder owns the lock, the fake mkdir still exits 0
    sleep 30 </dev/null >/dev/null 2>&1 & hp=$!
    /bin/mkdir -p "$SANDBOX/ac4-held.lock.d"
    printf '%s:1\n' "$hp" > "$SANDBOX/ac4-held.lock.d/pid"
    _lock_acquire "$SANDBOX/ac4-held" 1 >/dev/null 2>&1
    l="$(nc_state)"
    kill "$hp" 2>/dev/null
    printf '%s %s %s' "$a" "$w" "$l"
  )"
  assert_eq "$want $want $want" "$got" "AC4 noclobber $want is the same after _lock_acquire, with_lock and a lost claim"
done

# ── AC5 (same): the existing reclaim and wait behaviour, real mkdir ──────────
RES5="$SANDBOX/ac5-dead"
LOCK5="$RES5.lock.d"
/bin/mkdir -p "$LOCK5"
printf '%s:1\n' "$(dead_pid)" > "$LOCK5/pid"
rc5=0
( . "$LOCK_SH"; _lock_acquire "$RES5" 5 && _lock_release "$RES5" ) >/dev/null 2>&1 || rc5=$?
assert_eq "0" "$rc5" "AC5 a dead holder's lock is still reclaimed with the real mkdir"
assert_file_absent "$LOCK5" "AC5 the reclaimed lock is gone after release"

RES5B="$SANDBOX/ac5-live"
LOCK5B="$RES5B.lock.d"
/bin/mkdir -p "$LOCK5B"
sleep 30 </dev/null >/dev/null 2>&1 & LIVE5=$!
printf '%s:1\n' "$LIVE5" > "$LOCK5B/pid"
rc5b=0
err5b="$( ( . "$LOCK_SH"; _lock_acquire "$RES5B" 1 ) 2>&1 )" || rc5b=$?
assert_eq "1" "$rc5b" "AC5 a live holder's lock is still waited on until the timeout"
assert_contains "$err5b" "timed out" "AC5 the waiter still warns that it timed out"
assert_eq "$LIVE5:1" "$(cat "$LOCK5B/pid" 2>/dev/null || true)" "AC5 the live holder's token is untouched"
kill "$LIVE5" 2>/dev/null || true
wait "$LIVE5" 2>/dev/null || true

finish
