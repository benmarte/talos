#!/usr/bin/env bash
# test-hooks-post-stage.sh -- hooks.post_stage (#182): a command run after
# every verdict, approval, block and merge, with a JSON outcome event on
# stdin. Covers:
#   (a) disabled by default (no hooks.post_stage key at all)
#   (b) exact payload fields for a verdict event (qa/PASS) and a lifecycle
#       event (merged) that omits verdict/attempt/duration_s
#   (c) attempt and duration_s are null when the caller does not pass them
#   (d) failing / slow (timeout) commands -- exit 0, one stderr note, no
#       orphaned watchdog process (mirrors test-hooks-pre-dispatch.sh)
#   (e) the adapter path (scripts/pipeline-agent.sh) emits exactly one
#       "stage_complete" event per run, with verdict derived from the stub
#       runner's exit code
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
CAPTURE="$SANDBOX/hook-stdin.json"

# ── (a) Disabled by default: no hooks.post_stage key in config at all ────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "claude"}}
EOF
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "disabled by default: exits 0"
assert_eq "" "$out" "disabled by default: no stdout"
assert_eq "" "$(cat "$SANDBOX/err.log")" "disabled by default: no stderr"
assert_file_absent "$CAPTURE" "disabled by default: hook command never runs"

# ── (b) Verdict event: exact payload fields ───────────────────────────────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "claude", "model": "claude-x", "roles": {"qa": {"model": "claude-qa-model"}}},
 "hooks": {"post_stage": "cat > $CAPTURE", "timeout_s": 5}}
EOF
DETAILS_FILE="$SANDBOX/details.txt"
printf 'criterion 1: pass\ncriterion 2: pass\n' > "$DETAILS_FILE"
: > "$CAPTURE"
out="$(bash "$HOOKS" post_stage qa qa 42 --pr 57 --sha abc123 --verdict PASS \
  --summary "3 criteria verified" --details-file "$DETAILS_FILE" \
  --attempt "qa:1:3" 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "verdict event: exits 0"
assert_eq "" "$(cat "$SANDBOX/err.log")" "verdict event: no stderr note on success"

_check="$(python3 - "$CAPTURE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    d = json.load(f)

checks = [
    (d.get("event") == "qa", "event"),
    (d.get("role") == "qa", "role"),
    (d.get("issue") == 42, "issue"),
    (d.get("pr") == 57, "pr"),
    (d.get("repo") == "acme/widget", "repo"),
    (d.get("sha") == "abc123", "sha"),
    (d.get("verdict") == "PASS", "verdict"),
    (d.get("summary") == "3 criteria verified", "summary"),
    (d.get("details") == "criterion 1: pass\ncriterion 2: pass", "details"),
    (d.get("attempt") == {"stage": "qa", "count": 1, "total": 3}, "attempt"),
    (d.get("model") == "claude-qa-model", "model"),
    (d.get("runner") == "claude", "runner"),
    (d.get("duration_s") is None, "duration_s"),
    (isinstance(d.get("ts"), str) and d["ts"].endswith("Z"), "ts"),
]
bad = [label for ok, label in checks if not ok]
print("OK" if not bad else "BAD:" + ",".join(bad))
PYEOF
)"
assert_eq "OK" "$_check" "verdict event: every payload field matches exactly"

# ── (c) Merge event: verdict/attempt/duration_s omitted -> null ──────────────
: > "$CAPTURE"
out="$(bash "$HOOKS" post_stage merged orchestrator 42 --pr 57 --sha deadbeef \
  --summary "PR #57 merged" 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "merge event: exits 0"

_check="$(python3 - "$CAPTURE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    d = json.load(f)

checks = [
    (d.get("event") == "merged", "event"),
    (d.get("role") == "orchestrator", "role"),
    (d.get("pr") == 57, "pr"),
    (d.get("sha") == "deadbeef", "sha"),
    (d.get("verdict") is None, "verdict is null when not supplied"),
    (d.get("attempt") is None, "attempt is null when not supplied"),
    (d.get("duration_s") is None, "duration_s is null when not supplied"),
    (d.get("summary") == "PR #57 merged", "summary"),
    (d.get("details") == "", "details defaults to empty string"),
]
bad = [label for ok, label in checks if not ok]
print("OK" if not bad else "BAD:" + ",".join(bad))
PYEOF
)"
assert_eq "OK" "$_check" "merge event: verdict/attempt/duration_s are null, not omitted"

# --duration-s, when supplied, is threaded through as an integer.
: > "$CAPTURE"
bash "$HOOKS" post_stage stage_complete developer 42 --verdict PASS --duration-s 312 >/dev/null 2>&1
_dur="$(python3 -c "import json; print(json.load(open('$CAPTURE')).get('duration_s'))")"
assert_eq "312" "$_dur" "--duration-s is threaded through as an integer"

# ── (d) Failing hook -- exit 0, one stderr note, hook command still ran ──────
cat > talos.pipeline.json <<EOF
{"hooks": {"post_stage": "cat > $CAPTURE; exit 1", "timeout_s": 5}}
EOF
: > "$CAPTURE"
err="$(bash "$HOOKS" post_stage qa qa 42 --verdict FAIL 2>&1 >/dev/null)"
rc=$?
assert_eq "0" "$rc" "failing hook: pipeline-hooks.sh still exits 0"
assert_contains "$err" "pipeline-hooks:" "failing hook: one stderr note is printed"
assert_file_exists "$CAPTURE" "failing hook: the command still ran (received stdin)"

# ── (d) Slow hook (exceeds hooks.timeout_s) -- exit 0, killed at the timeout,
# no orphaned watchdog process ─────────────────────────────────────────────
# The sleep duration is a unique, unlikely-to-collide value (not the plain
# "sleep 3" test-hooks-pre-dispatch.sh's own slow-hook case also spawns as a
# child of its compound hook command) -- pgrep -f matches on the exec'd
# command line, which is indistinguishable from any other "sleep 3" process
# running anywhere on the box, including a sibling test file's own
# not-yet-killed hook when both run concurrently (-j > 1) or just close
# together in time. A generic pattern here previously produced a false
# "leak" by catching that unrelated, legitimately-still-running process.
cat > talos.pipeline.json <<EOF
{"hooks": {"post_stage": "sleep 3.194717", "timeout_s": 1}}
EOF
_start=$(date +%s)
err="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS 2>&1 >/dev/null)"
rc=$?
_elapsed=$(( $(date +%s) - _start ))
assert_eq "0" "$rc" "slow hook: pipeline-hooks.sh still exits 0"
assert_contains "$err" "pipeline-hooks:" "slow hook: one stderr note is printed"
if [ "$_elapsed" -le 3 ]; then
  pass "slow hook: killed at hooks.timeout_s (1s), not left to run its full 3s sleep"
else
  fail "slow hook: killed at hooks.timeout_s (1s), not left to run its full 3s sleep" \
    "elapsed: ${_elapsed}s"
fi
# Bounded retry: tolerate up to ~0.5s beyond the watchdog's own kill
# deadline for the SIGKILL follow-up to be reflected in the process table
# under a noisy CI scheduler, without weakening the assertion -- it still
# fails if the process is genuinely still there after every retry.
_leaked=""
for _i in 1 2 3 4 5; do
  _leaked="$(pgrep -f 'sleep 3\.194717$' || true)"
  [ -z "$_leaked" ] && break
  sleep 0.1
done
assert_eq "" "$_leaked" "slow hook: no orphaned sleep left running"

# ── (e) Adapter path: exactly one stage_complete event per run ───────────────
install_talos
AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
ADAPTER_CAPTURE="$SANDBOX/adapter-hook-stdin.json"

cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > /dev/null; exit 0"},
 "hooks": {"post_stage": "cat >> $ADAPTER_CAPTURE; echo >> $ADAPTER_CAPTURE", "timeout_s": 5}}
EOF
: > "$ADAPTER_CAPTURE"
TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec." >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "adapter (success runner): pipeline-agent.sh exits 0"

_line_count="$(grep -c . "$ADAPTER_CAPTURE" 2>/dev/null || true)"
assert_eq "1" "$_line_count" "adapter (success runner): hooks.post_stage invoked exactly once"

_check="$(python3 -c "
import json
d = json.load(open('$ADAPTER_CAPTURE'))
print('OK' if d.get('event') == 'stage_complete' and d.get('role') == 'developer' and d.get('verdict') == 'PASS' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "adapter (success runner): stage_complete event, role developer, verdict PASS"

# Failing runner -> verdict FAIL, still exactly one event.
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > /dev/null; exit 7"},
 "hooks": {"post_stage": "cat >> $ADAPTER_CAPTURE; echo >> $ADAPTER_CAPTURE", "timeout_s": 5}}
EOF
: > "$ADAPTER_CAPTURE"
TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec." >/dev/null 2>&1
rc=$?
assert_eq "7" "$rc" "adapter (failing runner): pipeline-agent.sh still exits with the runner's own code"

_line_count="$(grep -c . "$ADAPTER_CAPTURE" 2>/dev/null || true)"
assert_eq "1" "$_line_count" "adapter (failing runner): hooks.post_stage invoked exactly once"

_check="$(python3 -c "
import json
d = json.load(open('$ADAPTER_CAPTURE'))
print('OK' if d.get('event') == 'stage_complete' and d.get('verdict') == 'FAIL' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "adapter (failing runner): stage_complete event, verdict FAIL"

finish
