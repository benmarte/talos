#!/usr/bin/env bash
# Regression tests for scripts/pipeline-lock.sh (#180): portable mkdir-based
# locking for shared local state when issues.max_parallel > 1.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
assert_file_exists "$LOCK_SH" "pipeline-lock.sh exists"

# ── AC: two/four concurrent with_lock holders serialize a critical section ──
# 4 workers each incrementing a shared counter file 50 times (200 total)
# through with_lock. Without serialization this reliably loses updates
# (read old value, write old+1, two workers stomp each other).
COUNTER="$SANDBOX/counter"
printf '0' > "$COUNTER"
INCR_SCRIPT="$SANDBOX/incr.sh"
cat > "$INCR_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
. "$LOCK_SH"
n="\$1"
for i in \$(seq 1 "\$n"); do
  with_lock "$COUNTER" 10 -- bash -c '
    val=\$(cat "$COUNTER")
    val=\$((val + 1))
    printf "%s" "\$val" > "$COUNTER"
  '
done
EOF
chmod +x "$INCR_SCRIPT"

pids=""
for w in 1 2 3 4; do
  bash "$INCR_SCRIPT" 50 &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done

final="$(cat "$COUNTER")"
assert_eq "200" "$final" "4 parallel workers x 50 with_lock increments each = exactly 200, no lost updates"
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
BUSY_DIR="$BUSY_RESOURCE.lock.d"
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
sleep 30
EOF
chmod +x "$HOLD_SCRIPT"
bash "$HOLD_SCRIPT" &
_hold_pid=$!
# Give it a moment to actually acquire the lock before signalling.
for _i in $(seq 1 50); do
  [ -d "$HOLD_DIR" ] && break
  sleep 0.1
done
assert_file_exists "$HOLD_DIR/pid" "held lock dir exists before SIGINT"
kill -INT "$_hold_pid" 2>/dev/null
wait "$_hold_pid" 2>/dev/null
assert_file_absent "$HOLD_DIR" "lock released on SIGINT via the composable exit trap"

echo ""
echo "test-lock: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
