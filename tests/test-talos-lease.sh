#!/usr/bin/env bash
# test-talos-lease.sh -- the lease ledger's dead-holder reclaim and the `lease`
# verb (#522). Focused ledger/lease-verb file, the tests/test-talos-<verb>.sh
# family (test-talos-next.sh, test-talos-done.sh, test-talos-run.sh).
#
#   reclaim (#522, AC1-AC4)  a line whose `pid=` is a dead process stops being
#          a lease once it is older than TALOS_LEASE_RECLAIM_S (default 10 s,
#          env-only override): `_talos_lease check <N>` answers free (rc 0) and
#          `next --issue <N>` answers its normal action (test-talos-next.sh).
#          Liveness is the primary condition (pipeline-lock.sh:112's staleness
#          rule); the age only breaks PID reuse, so an age alone never reclaims
#          a live holder -- the TTL stays the bound for live-but-hung holders.
#          The decider is `_talos_lease_reclaimable <pid> <held> <now>`: 0 = the
#          holder is gone and the line is old enough. Every malformed field
#          (no/empty/non-numeric pid, missing/non-numeric held, now < held) is
#          fail-closed: never reclaimed; the TTL still frees the line.
#   scan     (#522, AC7) `_talos_lease_read` and `_talos_lease_held_line`
#          consider every `issue=<N>` line and answer the latest-expiring
#          non-reclaimable one -- never the first line, so a reader can never
#          shorten a held lease and `lease prune` only ever removes lines no
#          reader counted.
#   collapse (#522, AC8) `_talos_lease acquire` on a free issue removes every
#          other `issue=<N>` line before appending, under the lock.
#   re-entry (#522, AC9) a line stamped with the reader's own `$$` (or with
#          `$TALOS_RUN_PID` when that matches) answers "own lease" (rc 0, no
#          holder line); `_talos_lease_read` is set -u safe -- it never aborts
#          the caller's shell or prints an empty holder line.
#   verb     (#522, AC11-AC14) `talos.sh lease prune` removes every
#          non-effective line under pipeline-lock.sh, printing one
#          `pruned issue=<N>` line per removed ledger line; nothing to remove
#          is a silent no-op (the ledger is never rewritten); `lease` and
#          `lease bogus` answer `stop reason=usage` (exit 2); a live lock
#          holder times out to a lone `stop reason=lock-timeout` (exit 1) with
#          every ledger line untouched.
#
# Every test runs in a make_sandbox git repo: no GitHub write, no LLM call.
# The lease functions are sourced from talos.sh inside the sandbox repo (the
# sourcing runs talos.sh's own dispatch, so the no-op `help` verb sources the
# definitions and returns; SCRIPT_DIR is then pointed at the real scripts dir,
# which the sandbox copy would not have). A `sleep` child is reaped only after
# the assertions on it.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS="$TALOS_ROOT/scripts/talos.sh"
SCRIPTS="$TALOS_ROOT/scripts"
ERR="$SANDBOX/stderr"
LEASE="$SANDBOX/.git/talos-lease.ledger"
export TALOS_NOW=1000000
unset TALOS_RUN_PID TALOS_LEASE_RECLAIM_S TALOS_LEASE_LOCK_S
# The verb runs `_talos_prepare lease pipeline-lock.sh`, which needs a config.
printf '%s' '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
  > "$SANDBOX/talos.pipeline.json"

# lease_call <fn> [args...]: run <fn> with the sandbox repo as cwd in a bash
# that has sourced talos.sh's functions. OUT = stdout, RC = rc, ERR = stderr.
lease_call() {
  local _fn="$1"; shift
  OUT="$(bash -c '
    set -u
    . "$1" help >/dev/null 2>&1
    SCRIPT_DIR="$2"
    _fn="$3"; shift 3
    "$_fn" "$@"
  ' lease_call "$TALOS" "$SCRIPTS" "$_fn" "$@" 2>"$ERR")"
  RC=$?
}

# lease_at <now> <fn> [args...]: lease_call at a pinned clock, restoring the
# file-wide TALOS_NOW afterwards.
lease_at() {
  local _now="$1" _rc _out
  shift
  export TALOS_NOW="$_now"
  lease_call "$@"
  _rc=$RC; _out=$OUT
  export TALOS_NOW=1000000
  RC=$_rc; OUT=$_out
}

# dead_pid: a spawned-and-reaped child; its pid answers ESRCH to every later
# reader (the pid a one-shot `next` leaves behind). The child is a subshell
# (not a bare `sleep` job): `wait` on a bare background binary fires the
# sandbox's EXIT trap mid-file, deleting SANDBOX under the running test.
dead_pid() {
  local _p
  ( sleep 30 ) & _p=$!
  kill "$_p" 2>/dev/null
  wait "$_p" 2>/dev/null
  printf '%s' "$_p"
}

# live_pid: a sleeping child, alive until the caller reaps it (only after the
# assertions on it). The child is spawned detached under nohup: a bare
# background job dies with its spawning subshell's exit, and `wait` on a bare
# background binary fires the sandbox's EXIT trap mid-file -- so the pid is an
# orphan the system reaps, never a child of this shell.
live_pid() {
  local _p
  _p="$(bash -c 'nohup sleep 30 >/dev/null 2>&1 & echo $!')"
  printf '%s' "$_p"
}

LEASER() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
stat_of() { python3 -I -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1"; }

# ── AC1: a dead holder's line past the guard is not a lease ──────────────────
DPID="$(dead_pid)"
printf 'issue=42 held=999985 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC1: check on a dead-pid line old enough answers free (rc 0)"
assert_eq "" "$OUT" "AC1: no holder line is printed for a reclaimable line"
assert_eq "" "$(cat "$ERR")" "AC1: the free answer is silent on stderr"

# ── AC2: the PID-reuse age guard, both directions, and its default ────────────
DPID="$(dead_pid)"
export TALOS_LEASE_RECLAIM_S=3
lease_call _talos_lease_reclaim_s
assert_eq "3" "$OUT" "AC2: TALOS_LEASE_RECLAIM_S overrides the guard"
# age = guard - 1: still a lease (the holder line is printed).
printf 'issue=42 held=999998 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC2: a dead holder one second inside the guard is still a lease"
assert_eq "issue=42 held=999998 expires=1001800 pid=$DPID" "$OUT" "AC2: the young dead line's holder line is printed"
# age = guard: reclaimed.
printf 'issue=42 held=999997 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC2: a dead holder exactly at the guard is reclaimed"
# The default is 10 s when the variable is unset, blank or non-numeric.
unset TALOS_LEASE_RECLAIM_S
printf 'issue=42 held=999990 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC2: the unset guard defaults to 10 s (age 10 is reclaimed)"
export TALOS_LEASE_RECLAIM_S=""
lease_call _talos_lease_reclaim_s
assert_eq "10" "$OUT" "AC2: the blank guard falls back to 10"
printf 'issue=42 held=999990 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC2: the blank guard's age 10 is reclaimed"
export TALOS_LEASE_RECLAIM_S="abc"
lease_call _talos_lease_reclaim_s
assert_eq "10" "$OUT" "AC2: the non-numeric guard falls back to 10"
printf 'issue=42 held=999990 expires=1001800 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC2: the non-numeric guard's age 10 is reclaimed"
unset TALOS_LEASE_RECLAIM_S
lease_call _talos_lease_reclaim_s
assert_eq "10" "$OUT" "AC2: the unset guard's default value is 10"

# ── AC3: age alone never reclaims a live holder (the TTL is the bound) ───────
LPID="$(live_pid)"
lease_call _talos_lease_reclaimable "$LPID" 999000 1000000
assert_exit_code "1" "$RC" "AC3: a live holder's line is never reclaimable, whatever its age"
kill "$LPID" 2>/dev/null

# ── AC4: the single decider is fail-closed on every malformed field ───────────
DPID="$(dead_pid)"
lease_call _talos_lease_reclaimable "$DPID" 999985 1000000
assert_exit_code "0" "$RC" "AC4: the decider's rc 0 is the holder-gone-and-old-enough answer"
lease_call _talos_lease_reclaimable "" 999985 1000000
assert_exit_code "1" "$RC" "AC4: an empty pid field is never reclaimed"
lease_call _talos_lease_reclaimable "abc" 999985 1000000
assert_exit_code "1" "$RC" "AC4: a non-numeric pid field is never reclaimed"
lease_call _talos_lease_reclaimable "$DPID" 1001000 1000000
assert_exit_code "1" "$RC" "AC4: now < held (a stepped-back clock) is never reclaimed"
lease_call _talos_lease_reclaimable "$DPID" "" 1000000
assert_exit_code "1" "$RC" "AC4: a missing held field is never reclaimed"
lease_call _talos_lease_reclaimable "$DPID" "oops" 1000000
assert_exit_code "1" "$RC" "AC4: a malformed held field is never reclaimed"
# The same fail-closed answers through the scan: a malformed-pid line is a
# lease until the TTL frees it.
printf 'issue=42 held=999985 expires=1001800 pid=abc\n' > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC4: a non-numeric pid is a lease until the TTL (via check)"
printf 'issue=42 held=999985 expires=1001800\n' > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC4: a line with no pid field is a lease until the TTL"
printf 'issue=42 held=999985 expires=1001800 pid=\n' > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC4: an empty pid field is a lease until the TTL"
printf 'issue=42 held=1001000 expires=1002000 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC4: now < held is a lease (fail-closed)"
printf 'issue=42 held=999985 expires=999000 pid=abc\n' > "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "0" "$RC" "AC4: the TTL still frees a malformed-pid line"

# ── AC5: the guard wait's retry, the TTL wait's retry, and acquire's rc-1 ─────
DPID="$(dead_pid)"
LPID="$(live_pid)"
lease_call _talos_lease_retry_s "issue=42 held=999995 expires=1001800 pid=$DPID" 1000000
assert_eq "5" "$OUT" "AC5: a young dead holder's wait is the seconds until reclaimable"
lease_call _talos_lease_retry_s "issue=42 held=999995 expires=1001800 pid=$LPID" 1000000
assert_eq "1800" "$OUT" "AC5: a live holder's wait is the full remaining TTL (expires-now)"
lease_call _talos_lease_retry_s "issue=42 held=999985 expires=1000900 pid=$DPID" 1000100
assert_eq "1" "$OUT" "AC5: the seconds-until-reclaimable is floored at 1"
lease_call _talos_lease_retry_s "issue=42 held= expires=1000900 pid=$DPID" 1000000
assert_eq "900" "$OUT" "AC5: a held-less line's wait is the remaining TTL (fail-closed)"
lease_call _talos_lease_retry_s "issue=42 held=999985 pid=$DPID" 1000000
assert_eq "1" "$OUT" "AC5: an expires-less line's wait is floored at 1 (fail-closed)"
# acquire's rc-1 stdout stays byte-identically the holder line.
printf 'issue=42 held=999985 expires=1001800 pid=%s\n' "$LPID" > "$LEASE"
lease_call _talos_lease acquire 42 900
assert_exit_code "1" "$RC" "AC5: acquire on a live holder's line is held (rc 1)"
assert_eq "issue=42 held=999985 expires=1001800 pid=$LPID" "$OUT" "AC5: acquire's rc-1 stdout is the holder line, byte-identically"
kill "$LPID" 2>/dev/null

# ── AC7: the scan weighs every line; the answer is the latest-expiring ────────
LPID1="$(live_pid)"
LPID2="$(live_pid)"
printf 'issue=42 held=999985 expires=1000900 pid=%s\n' "$LPID1" > "$LEASE"
printf 'issue=42 held=999985 expires=1001800 pid=%s\n' "$LPID2" >> "$LEASE"
lease_call _talos_lease check 42
assert_exit_code "1" "$RC" "AC7: two live lines answer held (rc 1)"
assert_eq "issue=42 held=999985 expires=1001800 pid=$LPID2" "$OUT" "AC7: the latest-expiring line wins, never the first"
lease_call _talos_lease_held_line "$LEASE" 42 1000000
assert_exit_code "0" "$RC" "AC7: held_line returns rc 0 for a live lease"
assert_eq "issue=42 held=999985 expires=1001800 pid=$LPID2" "$OUT" "AC7: held_line's answer is the latest-expiring line"
# The reproduction: a dead line above a live one must not grant a free answer.
DPID="$(dead_pid)"
printf 'issue=43 held=999985 expires=1000900 pid=%s\n' "$DPID" > "$LEASE"
printf 'issue=43 held=999985 expires=1001800 pid=%s\n' "$LPID2" >> "$LEASE"
lease_call _talos_lease check 43
assert_exit_code "1" "$RC" "AC7: a dead line above a live one still answers held (the live line is the lease)"
assert_eq "issue=43 held=999985 expires=1001800 pid=$LPID2" "$OUT" "AC7: the live line's holder is the answer, not the dead one"
assert_contains "$(cat "$LEASE")" "expires=1001800" "AC7: the reader never shortened the held lease (the live line survives)"
# An expired line above a live one: same -- and the live line survives the
# best-effort prune.
printf 'issue=44 held=999985 expires=999000 pid=1\n' > "$LEASE"
printf 'issue=44 held=999985 expires=1001800 pid=%s\n' "$LPID2" >> "$LEASE"
lease_call _talos_lease check 44
assert_exit_code "1" "$RC" "AC7: an expired line above a live one still answers held"
assert_eq "issue=44 held=999985 expires=1001800 pid=$LPID2" "$OUT" "AC7: the expired line's answer names the live holder"
assert_contains "$(cat "$LEASE")" "expires=1001800" "AC7: the best-effort prune never removed a reader-counted line"
kill "$LPID1" "$LPID2" 2>/dev/null

# ── AC8: one line per issue; malformed expires stays rc 2 ─────────────────────
DPID="$(dead_pid)"
printf 'issue=42 held=999985 expires=1000900 pid=%s\n' "$DPID" > "$LEASE"
lease_call _talos_lease acquire 42 1
assert_exit_code "0" "$RC" "AC8: acquire on a free issue writes the line (rc 0)"
lease_at 1000002 _talos_lease acquire 42 1
assert_exit_code "0" "$RC" "AC8: the second acquire re-arms after the first line expired"
assert_eq "1" "$(grep -c "^issue=42 " "$LEASE")" "AC8: two consecutive acquires leave exactly one line"
_line="$(sed 's/pid=[0-9]*/pid=/' "$LEASE")"
assert_eq "issue=42 held=1000002 expires=1000003 pid=" "$_line" "AC8: the surviving line is the second acquire's"
# A malformed expires is ledger-unavailable, unchanged, and nothing is written.
printf 'issue=44 held=1 expires=oops pid=1\n' > "$LEASE"
lease_call _talos_lease acquire 44 900
assert_exit_code "2" "$RC" "AC8: a malformed expires stays rc 2 (ledger unavailable)"
assert_eq "" "$OUT" "AC8: nothing is printed on the unavailable answer"
assert_contains "$(cat "$LEASE")" "expires=oops" "AC8: the malformed ledger is untouched"

# ── AC9: re-entrancy fixed, and set -u safe ───────────────────────────────────
# A line stamped with the reader's own $$ (the probe's own pid, stamped by its
# own acquire) answers "own lease" with TALOS_RUN_PID unset, never aborts the
# caller's set -u shell and never prints an empty holder line.
AC9PROBE="$SANDBOX/ac9-probe.sh"
cat > "$AC9PROBE" <<'TALOS_probeAc9K7xR2mQv'
set -u
. "$TALOS_SH" help >/dev/null 2>&1
SCRIPT_DIR="$SCRIPTS_DIR"
unset TALOS_RUN_PID
TALOS_NOW=1000000 _talos_lease acquire 42 900 >/dev/null 2>&1
_out="$(TALOS_NOW=1000000 _talos_lease check 42)"
echo "sub-own rc=$? out=<${_out}>"
TALOS_NOW=1000000 _talos_lease check 42
echo "direct-own rc=$?"
echo "after"
TALOS_probeAc9K7xR2mQv
OUT="$(TALOS_SH="$TALOS" SCRIPTS_DIR="$SCRIPTS" bash "$AC9PROBE" 2>"$ERR")"; RC=$?
assert_contains "$OUT" "sub-own rc=0 out=<>" "AC9: the probe's own-$$ line answers own lease (rc 0, nothing printed)"
assert_contains "$OUT" "direct-own rc=0" "AC9: the direct check answers own lease too"
assert_contains "$OUT" "after" "AC9: _talos_lease_read never aborts the caller's set -u shell"
assert_contains "$OUT" "out=<>" "AC9: an own lease never prints an empty holder line"
rm -f "$AC9PROBE"
# A line stamped with $TALOS_RUN_PID answers own lease when that matches, and
# a foreign live pid is still held by another.
export TALOS_RUN_PID=$$
printf 'issue=44 held=999985 expires=1001800 pid=%s\n' "$$" > "$LEASE"
lease_call _talos_lease check 44
assert_exit_code "0" "$RC" "AC9: a line stamped with TALOS_RUN_PID answers own lease"
assert_eq "" "$OUT" "AC9: an own lease prints no holder line"
LPID="$(live_pid)"
printf 'issue=45 held=999985 expires=1001800 pid=%s\n' "$LPID" > "$LEASE"
lease_call _talos_lease check 45
assert_exit_code "1" "$RC" "AC9: a foreign live pid is still held by another"
assert_eq "issue=45 held=999985 expires=1001800 pid=$LPID" "$OUT" "AC9: the foreign holder line is printed"
unset TALOS_RUN_PID
kill "$LPID" 2>/dev/null

# ── AC11: `lease prune` removes every non-effective line ──────────────────────
DPID="$(dead_pid)"
LP11="$(live_pid)"
LP13A="$(live_pid)"
LP13B="$(live_pid)"
LP14="$(live_pid)"
DP15="$(dead_pid)"
printf 'issue=11 held=999985 expires=1000000 pid=%s\n' "$DPID" > "$LEASE"
printf 'issue=11 held=999985 expires=1001800 pid=%s\n' "$LP11" >> "$LEASE"
printf 'issue=12 held=999985 expires=1001800 pid=%s\n' "$DPID" >> "$LEASE"
printf 'issue=13 held=999985 expires=1000900 pid=%s\n' "$LP13A" >> "$LEASE"
printf 'issue=13 held=999985 expires=1001800 pid=%s\n' "$LP13B" >> "$LEASE"
printf 'issue=14 held=999985 expires=1001800 pid=%s\n' "$LP14" >> "$LEASE"
printf 'issue=15 held=999998 expires=1001800 pid=%s\n' "$DP15" >> "$LEASE"
OUT="$(bash "$TALOS" lease prune 2>"$ERR")"; RC=$?
assert_exit_code "0" "$RC" "AC11: the prune succeeds (exit 0)"
assert_eq "$(printf 'pruned issue=11\npruned issue=12\npruned issue=13')" "$OUT" \
  "AC11: one pruned issue=<N> line per removed ledger line, nothing for the issues it leaves alone"
_g="$(cat "$LEASE")"
assert_eq "4" "$(grep -c "^issue=" <<<"$_g")" "AC11: only the effective lines survive"
assert_contains "$_g" "expires=1001800 pid=$LP11" "AC11: issue 11's live effective line survives"
assert_not_contains "$_g" "expires=1000000 " "AC11: issue 11's expired line is gone (the TTL bound)"
assert_not_contains "$_g" "issue=12 " "AC11: issue 12's dead-holder line is gone (the reclaim guard)"
assert_not_contains "$_g" "expires=1000900 pid=$LP13A" "AC11: issue 13's shadowed duplicate is gone"
assert_contains "$_g" "expires=1001800 pid=$LP13B" "AC11: issue 13's later-expiring live line survives"
assert_contains "$_g" "expires=1001800 pid=$LP14" "AC11: issue 14's live effective line is never removed"
assert_contains "$_g" "expires=1001800 pid=$DP15" "AC11: a dead holder's effective line is never removed (inside the guard)"
kill "$LP11" "$LP13A" "$LP13B" "$LP14" 2>/dev/null

# ── AC12: nothing to remove is a silent no-op ─────────────────────────────────
LP12="$(live_pid)"
printf 'issue=42 held=999985 expires=1001800 pid=%s\n' "$LP12" > "$LEASE"
_before="$(cat "$LEASE")"
_before_stat="$(stat_of "$LEASE")"
OUT="$(bash "$TALOS" lease prune 2>"$ERR")"; RC=$?
assert_exit_code "0" "$RC" "AC12: the no-op prune exits 0"
assert_eq "" "$OUT" "AC12: the no-op prune prints nothing"
assert_eq "$_before" "$(cat "$LEASE")" "AC12: the ledger is byte-identical"
assert_eq "$_before_stat" "$(stat_of "$LEASE")" "AC12: the ledger keeps its inode and mtime (never rewritten)"
kill "$LP12" 2>/dev/null
# A ledger that does not exist is a silent no-op too.
rm -f "$LEASE"
OUT="$(bash "$TALOS" lease prune 2>"$ERR")"; RC=$?
assert_exit_code "0" "$RC" "AC12: a missing ledger is a silent no-op (exit 0)"
assert_eq "" "$OUT" "AC12: a missing ledger prints nothing"
assert_file_absent "$LEASE" "AC12: a missing ledger stays absent"

# ── AC13: `lease` is a dispatch arm, and the usage shape is the gate's ────────
OUT="$(bash "$TALOS" lease 2>"$ERR")"; RC=$?
assert_exit_code "2" "$RC" "AC13: a bare lease exits 2"
assert_eq "stop reason=usage" "$OUT" "AC13: a bare lease answers usage"
OUT="$(bash "$TALOS" lease bogus 2>"$ERR")"; RC=$?
assert_exit_code "2" "$RC" "AC13: a bogus sub-verb exits 2"
assert_eq "stop reason=usage" "$OUT" "AC13: a bogus sub-verb answers usage"
grep -q "  lease) _talos_lease_verb" "$TALOS"
assert_eq "0" "$?" "AC13: lease is an arm of the dispatch table routing to _talos_lease_verb"
grep -q "_talos_prepare lease pipeline-lock.sh" "$TALOS"
assert_eq "0" "$?" "AC13: lease prune runs _talos_prepare lease pipeline-lock.sh"
grep -q "^# lease-reasons:" "$TALOS"
assert_eq "0" "$?" "AC13: the header names the lease verb's own stop reasons once"
HELP_OUT="$(bash "$TALOS" help)"
assert_contains "$HELP_OUT" "  lease " "AC13: help lists the lease verb"
assert_contains "$HELP_OUT" "prune" "AC13: help documents the prune sub-verb"

# ── AC14: the lock is honoured; a live holder token times out, untouched ──────
printf 'issue=42 held=999985 expires=1001800 pid=1\n' > "$LEASE"
_before="$(cat "$LEASE")"
mkdir -p "$LEASE.lock.d"
printf '%s:1\n' "$$" > "$LEASE.lock.d/pid"
export TALOS_LEASE_LOCK_S=1
OUT="$(bash "$TALOS" lease prune 2>"$ERR")"; RC=$?
unset TALOS_LEASE_LOCK_S
assert_exit_code "1" "$RC" "AC14: a live lock holder times out the prune (exit 1)"
assert_eq "stop reason=lock-timeout" "$OUT" "AC14: the answer is a lone stop line"
assert_eq "$_before" "$(cat "$LEASE")" "AC14: every ledger line is untouched"
rm -rf "${LEASE:?}.lock.d"

finish
