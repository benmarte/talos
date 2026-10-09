#!/usr/bin/env bash
# test-stage-timeout.sh -- agents.stage_timeout_s / agents.roles.<role>.stage_timeout_s
# (#540): pipeline-agent.sh bounds each runner attempt. On expiry the runner AND
# its children are killed (process group), the exit code is 124, one stderr line
# says why, the attempt is `task` (never a failover) and hooks.post_stage sees
# verdict FAIL. Nothing may outlive the call. Key unset = today's behaviour.
#
# The config floor is 60 s, too long to wait in a test, so the runs below use
# TALOS_STAGE_TIMEOUT_DIVISOR (a test seam in pipeline-agent.sh): the configured
# seconds are divided by it, so `60` with a divisor of 30 is a 2 s bound. The
# validator itself is exercised without the seam.
#
# Leaks are found with pgrep on a unique sentinel (the #314 pattern in
# tests/test-hooks-pre-dispatch.sh): each runner sleeps for 100000+RANDOM
# seconds, a duration no other process on the host shares.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
CONFIG="$HOME/.talos/scripts/pipeline-config.sh"
ERR="$SANDBOX/agent.err"
CAPTURE="$SANDBOX/post-stage.json"
export TALOS_ISSUE=42

set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }

# run_stage <role> -- stdout in $OUT, stderr in $ERR, exit code in $RC, wall
# seconds in $SECS. TALOS_STAGE_TIMEOUT_DIVISOR comes from the caller's env.
# The agent runs in the background in its own process group (set -m) with a 25 s
# guard, so a regression (a timeout that never fires) fails the test instead of
# hanging it: the group is killed and RC is 137.
run_stage() {
  local t0 t1 pid i=0
  t0="$(date +%s)"
  set -m
  bash "$AGENT" "${1:-developer}" "the task text" >"$SANDBOX/agent.out" 2>"$ERR" </dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 125 ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- -"$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    RC=137
  else
    wait "$pid"; RC=$?
  fi
  OUT="$(cat "$SANDBOX/agent.out")"
  t1="$(date +%s)"
  SECS=$((t1 - t0))
}

# A runner that spawns a child and a grandchild, all carrying the sentinel.
SENT=$((100000 + RANDOM))
HANG_CMD="sleep $SENT & sh -c 'sleep $SENT' & sleep $SENT"
leaked() { pgrep -f "sleep $SENT" 2>/dev/null || true; }
# shellcheck disable=SC2086  # several pids, word splitting intended
cleanup_leak() { local p; p="$(leaked)"; [ -z "$p" ] || kill -KILL $p 2>/dev/null; }
trap 'cleanup_leak; rm -rf "$SANDBOX"' EXIT

# ── 1. Validation: 60-86400, rejected the way the other bounded ints are ─────
for bad in 59 86401 0 -1 '"abc"' 1.5 true; do
  set_cfg "{\"agents\": {\"stage_timeout_s\": $bad}}"
  assert_eq "" "$(bash "$CONFIG" agents.stage_timeout_s 2>/dev/null)" "config: stage_timeout_s $bad is rejected (reads as unset)"
  assert_contains "$(bash "$CONFIG" agents.stage_timeout_s 2>&1 >/dev/null)" "pipeline-config: agents.stage_timeout_s must be" "config: stage_timeout_s $bad warns and names the key"
  set_cfg "{\"agents\": {\"roles\": {\"qa\": {\"stage_timeout_s\": $bad}}}}"
  assert_eq "" "$(bash "$CONFIG" agents.roles.qa.stage_timeout_s 2>/dev/null)" "config: roles.qa.stage_timeout_s $bad is rejected"
done
for good in 60 86400; do
  set_cfg "{\"agents\": {\"stage_timeout_s\": $good}}"
  assert_eq "$good" "$(bash "$CONFIG" agents.stage_timeout_s 2>/dev/null)" "config: stage_timeout_s $good is accepted"
  set_cfg "{\"agents\": {\"roles\": {\"qa\": {\"stage_timeout_s\": $good}}}}"
  assert_eq "$good" "$(bash "$CONFIG" agents.roles.qa.stage_timeout_s 2>/dev/null)" "config: roles.qa.stage_timeout_s $good is accepted"
done
rm -f talos.pipeline.json
assert_eq "" "$(bash "$CONFIG" agents.stage_timeout_s 2>/dev/null)" "config: the default is empty (no timeout)"
set_cfg '{"agents": {"stage_timeout_s": 600, "roles": {"qa": {"stage_timeout_s": 90}}}}'
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "config: both keys are known keys (no unknown-key warning)"
assert_eq "90" "$(bash "$CONFIG" agents.roles.qa.stage_timeout_s 2>/dev/null)" "config: the role value is read through the nested path"

# ── 2. Global key: a hung runner is killed, with its children ───────────────
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"$HANG_CMD\", \"stage_timeout_s\": 60},
 \"hooks\": {\"post_stage\": \"cat > $CAPTURE\", \"timeout_s\": 5}}"
rm -f "$CAPTURE"
TALOS_STAGE_TIMEOUT_DIVISOR=30 run_stage developer
assert_eq "124" "$RC" "global key: a hung runner exits 124"
if [ "$SECS" -le 12 ]; then pass "global key: returned within ~12 s (took ${SECS}s)"; else fail "global key: returned within ~12 s" "took ${SECS}s"; fi
assert_contains "$(cat "$ERR")" "pipeline-agent: reason=stage-timeout role=developer after_s=2" "global key: the reason line names the role and the bound"
assert_eq "1" "$(grep -c '^pipeline-agent: reason=stage-timeout ' "$ERR")" "global key: exactly one reason line"
sleep 1
assert_eq "" "$(leaked)" "global key: no runner process (child or grandchild) survives"
assert_contains "$(cat "$CAPTURE" 2>/dev/null)" '"verdict": "FAIL"' "global key: hooks.post_stage gets verdict FAIL"

# ── 3. The role key beats the global one, in both directions ─────────────────
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"$HANG_CMD\", \"stage_timeout_s\": 600,
 \"roles\": {\"developer\": {\"stage_timeout_s\": 60}}}}"
TALOS_STAGE_TIMEOUT_DIVISOR=30 run_stage developer
assert_eq "124" "$RC" "role key: a short role bound fires although the global one is long"
assert_contains "$(cat "$ERR")" "role=developer after_s=2" "role key: the role value (2 s after the seam) is the one applied"
sleep 1
assert_eq "" "$(leaked)" "role key: no runner process survives"

set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sleep 4; echo done-ok\", \"stage_timeout_s\": 60,
 \"roles\": {\"developer\": {\"stage_timeout_s\": 600}}}}"
TALOS_STAGE_TIMEOUT_DIVISOR=30 run_stage developer
assert_eq "0" "$RC" "role key: a long role bound wins over a short global one (the 4 s runner is not killed)"
assert_contains "$OUT" "done-ok" "role key: the runner's output reaches the caller"

# A runner (and its children) that ignore TERM are still gone: KILL follows.
set_cfg "{\"agents\": {\"runner\": \"custom\", \"stage_timeout_s\": 60,
 \"runner_cmd\": \"trap '' TERM; sleep $SENT & sleep $SENT\"}}"
TALOS_STAGE_TIMEOUT_DIVISOR=30 run_stage developer
assert_eq "124" "$RC" "TERM-proof runner: exits 124"
if [ "$SECS" -le 18 ]; then pass "TERM-proof runner: returned within ~18 s (took ${SECS}s)"; else fail "TERM-proof runner: returned within ~18 s" "took ${SECS}s"; fi
sleep 1
assert_eq "" "$(leaked)" "TERM-proof runner: nothing survives the KILL"

# ── 4. A fast runner under a timeout is unaffected ───────────────────────────
set_cfg '{"agents": {"runner": "custom", "runner_cmd": "cat >/dev/null; echo fast-out; echo fast-err >&2; exit 3", "stage_timeout_s": 600}}'
run_stage developer
assert_eq "3" "$RC" "fast runner: its own exit code passes through"
assert_eq "fast-out" "$OUT" "fast runner: stdout is untouched"
assert_contains "$(cat "$ERR")" "fast-err" "fast runner: stderr is untouched"
assert_not_contains "$(cat "$ERR")" "reason=stage-timeout" "fast runner: no timeout line"
# The supervisor itself adds nothing to stderr: perl's compile-time warning for
# a statement after exec() would land on every bounded stage (#540 review).
assert_not_contains "$(cat "$ERR")" "Statement unlikely to be reached" "fast runner: the supervisor prints no perl warning"

# stdin still reaches the runner (custom runners read the prompt on stdin)
RECEIVED="$SANDBOX/received.txt"
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"cat > $RECEIVED\", \"stage_timeout_s\": 600}}"
run_stage developer
assert_eq "0" "$RC" "stdin: the runner exits 0"
assert_contains "$(cat "$RECEIVED")" "the task text" "stdin: the prompt still reaches a runner under a timeout"

# ── 5. Key unset: today's behaviour ──────────────────────────────────────────
set_cfg '{"agents": {"runner": "custom", "runner_cmd": "cat >/dev/null; echo plain-out; exit 7"}}'
run_stage developer
assert_eq "7" "$RC" "unset: the runner's exit code passes through"
assert_eq "plain-out" "$OUT" "unset: stdout is the runner's"
assert_not_contains "$(cat "$ERR")" "stage-timeout" "unset: no timeout line"
# a runner exiting 124 on its own is not a stage timeout
set_cfg '{"agents": {"runner": "custom", "runner_cmd": "cat >/dev/null; exit 124"}}'
run_stage developer
assert_eq "124" "$RC" "unset: a runner's own 124 passes through"
assert_not_contains "$(cat "$ERR")" "reason=stage-timeout" "unset: a runner's own 124 prints no timeout line"

# ── 6. A timeout never fails over ────────────────────────────────────────────
# The primary (claude) prints a rate-limit line, then hangs: that line alone is a
# provider error that would start the fallback, but the stage timed out, so the
# fallback runner must NOT be started.
FB_MARK="$SANDBOX/fallback-ran"
STUBBIN="$SANDBOX/fbbin"
mkdir -p "$STUBBIN"
printf '#!/bin/sh\necho ran > "%s"\nexit 0\n' "$FB_MARK" > "$STUBBIN/codex"
printf '#!/bin/sh\necho "API Error: 429 rate limited" >&2\nsleep %s &\nsh -c "sleep %s" &\nsleep %s\n' "$SENT" "$SENT" "$SENT" > "$STUBBIN/claude"
chmod +x "$STUBBIN/codex" "$STUBBIN/claude"
set_cfg '{"agents": {"runner": "claude", "fallback": ["codex"], "stage_timeout_s": 60}}'
rm -f "$FB_MARK"
PATH="$STUBBIN:$PATH" TALOS_STAGE_TIMEOUT_DIVISOR=30 run_stage developer
assert_eq "124" "$RC" "failover chain: a timeout exits 124"
assert_file_absent "$FB_MARK" "failover chain: a timeout does not start the fallback runner"
assert_contains "$(cat "$ERR")" "pipeline-agent: reason=stage-timeout role=developer after_s=2" "failover chain: the reason line is replayed"
assert_eq "1" "$(grep -c '^pipeline-agent: reason=stage-timeout ' "$ERR")" "failover chain: exactly one reason line"
assert_not_contains "$(cat "$ERR")" "talos:failover" "failover chain: no failover marker"
sleep 1
assert_eq "" "$(leaked)" "failover chain: no runner process survives"
# Control: the same rate-limit line WITHOUT a timeout does fail over, so the
# assertions above are not passing for an unrelated reason.
printf '#!/bin/sh\necho "API Error: 429 rate limited" >&2\nexit 1\n' > "$STUBBIN/claude"
rm -f "$FB_MARK"
PATH="$STUBBIN:$PATH" run_stage developer
assert_file_exists "$FB_MARK" "control: without a timeout the same line does fail over"

# --classify: the reason line wins over a quota-looking line
printf 'API Error: 429 rate limited\npipeline-agent: reason=stage-timeout role=developer after_s=2\n' > "$SANDBOX/cls.txt"
assert_eq "task" "$(bash "$AGENT" --classify claude 124 "$SANDBOX/cls.txt")" "classify: rc 124 with the reason line is task, not provider"
assert_eq "provider" "$(bash "$AGENT" --classify claude 1 "$SANDBOX/cls.txt")" "classify: the same text without rc 124 still classifies as before"

finish
