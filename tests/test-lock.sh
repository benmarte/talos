#!/usr/bin/env bash
# Regression tests for scripts/pipeline-lock.sh (#180): portable mkdir-based
# locking for shared local state when issues.max_parallel > 1.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

# ── AC: two/four concurrent with_lock holders serialize a critical section ──
# 4 workers each incrementing a shared counter file 20 times (80 total) through
# with_lock. Each critical section sleeps 10 ms between its read and its write
# (read old value, write old+1, two workers stomp each other), which makes a
# lost update certain without the lock -- a no-op with_lock ends near 25 of 80
# -- so a few dozen increments prove what 200 racing ones used to, in a
# fraction of the time (the waiters' 0.2 s spin dominated the old run).
COUNTER="$SANDBOX/counter"
printf '0' > "$COUNTER"
INCR_SCRIPT="$SANDBOX/incr.sh"
cat > "$INCR_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
. "$LOCK_SH"
n="\$1"
i=0
while [ "\$i" -lt "\$n" ]; do
  with_lock "$COUNTER" 10 -- bash -c '
    val=\$(cat "$COUNTER")
    sleep 0.01
    printf "%s" "\$((val + 1))" > "$COUNTER"
  '
  i=\$((i + 1))
done
EOF
chmod +x "$INCR_SCRIPT"

pids=""
for w in 1 2 3 4; do
  bash "$INCR_SCRIPT" 20 &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done

final="$(cat "$COUNTER")"
assert_eq "80" "$final" "4 parallel workers x 20 with_lock increments each = exactly 80, no lost updates"
assert_file_absent "$COUNTER.lock.d" "lock dir is cleaned up after all workers finish"

# ── AC: stale lock (dead PID) is reclaimed, not waited out ──────────────────
STALE_RESOURCE="$SANDBOX/stale-target"
STALE_DIR="$STALE_RESOURCE.lock.d"
mkdir -p "$STALE_DIR"
# A PID that is certainly not running: fork a subshell, capture its PID, let
# it exit immediately, then reuse that (now-dead) PID as the stale holder.
( : ) & _dead_pid=$!
wait "$_dead_pid" 2>/dev/null
printf '%s\n' "$_dead_pid" > "$STALE_DIR/pid"

( . "$LOCK_SH"; with_lock "$STALE_RESOURCE" 5 -- bash -c "echo reclaimed > '$SANDBOX/stale.out'" )
[ -f "$SANDBOX/stale.out" ] && pass "stale lock (dead PID) reclaimed instead of waited out" \
  || fail "stale lock (dead PID) reclaimed instead of waited out"

# ── AC: timeout path warns to stderr and proceeds without the lock ──────────
BUSY_RESOURCE="$SANDBOX/busy-target"
BUSY_DIR="${BUSY_RESOURCE:?}.lock.d"
mkdir -p "$BUSY_DIR"
printf '%s\n' "$$" > "$BUSY_DIR/pid"   # held by THIS (alive) process -- never stale

_err="$SANDBOX/timeout.err"
( . "$LOCK_SH"; with_lock "$BUSY_RESOURCE" 1 -- bash -c "echo ran > '$SANDBOX/busy.out'" ) 2>"$_err"
assert_file_exists "$SANDBOX/busy.out" "with_lock runs the command even after timing out (never deadlocks the pipeline)"
assert_contains "$(cat "$_err")" "timed out" "timeout path prints exactly one stderr warning"
rm -rf "$BUSY_DIR"

# ── AC: the lock is released on SIGINT via the composable exit trap ─────────
HOLD_RESOURCE="$SANDBOX/int-target"
HOLD_DIR="$HOLD_RESOURCE.lock.d"
HOLD_SCRIPT="$SANDBOX/hold.sh"
cat > "$HOLD_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
# Backgrounded ("&") non-interactive shells ignore SIGINT by default (POSIX);
# reset it to the default disposition so this process can actually be
# interrupted below -- this is a test-harness artifact of backgrounding, not
# something pipeline-lock.sh callers need to do (a real invocation isn't
# started with "&" from the same script that signals it).
trap - INT
. "$LOCK_SH"
_lock_acquire "$HOLD_RESOURCE" 5
# Hold with a background sleep + wait, not a foreground sleep: bash defers a
# signal until its foreground child exits, so a plain "sleep 30" made this test
# wait the full 30 s for the SIGINT to take effect. wait is interrupted at once.
sleep 30 </dev/null >/dev/null 2>&1 &
printf '%s\n' "\$!" > "$SANDBOX/hold.sleep.pid"
wait "\$!"
EOF
chmod +x "$HOLD_SCRIPT"
# set -m gives the holder its own process group with default signal dispositions:
# a plain "&" from a non-interactive shell starts it with SIGINT IGNORED, which
# "trap - INT" cannot undo, so the signal below used to be a no-op and the lock
# was only ever released by the holder finishing its 30 s sleep.
set -m
bash "$HOLD_SCRIPT" &
_hold_pid=$!
set +m
# Give it a moment to actually acquire the lock before signalling.
# Wait for the pid file, not just the directory: with_lock creates the
# directory first and writes <dir>/pid a moment later, so a check in between
# failed intermittently on fast CI runners.
for _i in $(seq 1 50); do
  [ -s "$HOLD_DIR/pid" ] && break
  sleep 0.1
done
assert_file_exists "$HOLD_DIR/pid" "held lock dir exists before SIGINT"
kill -INT "$_hold_pid" 2>/dev/null
wait "$_hold_pid" 2>/dev/null
assert_file_absent "$HOLD_DIR" "lock released on SIGINT via the composable exit trap"
# The holder's own sleep outlives it (it was only signalled, not its child).
kill "$(cat "$SANDBOX/hold.sleep.pid" 2>/dev/null)" 2>/dev/null || true

echo ""
echo "test-lock: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
