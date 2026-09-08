#!/usr/bin/env bash
# test-notify-cmd.sh -- notifications.cmd (#184): a generic command sink in
# pipeline-notify.sh for any platform Slack/Discord/Teams/Buzz don't cover.
# Covers:
#   (a) disabled by default (no notifications.cmd key at all)
#   (b) the command receives the documented JSON payload on stdin
#   (c) event filtering (notifications.events) applies to the cmd sink too
#   (d) a failing command is a no-op -- pipeline-notify.sh still exits 0
#   (e) a slow command is killed at notifications.cmd_timeout_s, still exits 0
#   (f) no orphaned process survives a timeout
#   (g) the cmd sink runs alongside another sink (stub Slack webhook) in the
#       same invocation without either one blocking the other
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
CMD_OUT="$SANDBOX/cmd-stdin.json"

# ── (a) Disabled by default: no notifications.cmd key in config at all ───────
rm -f talos.pipeline.json "$CMD_OUT"
out="$(bash "$NOTIFY" validator "#42" "hello" 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "disabled by default: pipeline-notify.sh still exits 0"
assert_file_absent "$CMD_OUT" \
  "disabled by default: cmd is never invoked when notifications.cmd is unset"

# ── (b) Payload fields exact ──────────────────────────────────────────────────
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT", "cmd_timeout_s": 5}}
EOF
rm -f "$CMD_OUT"
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed on main." 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "payload test: pipeline-notify.sh exits 0"
assert_file_exists "$CMD_OUT" "payload test: cmd received stdin"

_payload_check="$(python3 - "$CMD_OUT" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

checks = [
    (data.get("event") == "validator", "event"),
    (data.get("ref") == "#42", "ref"),
    ("Confirmed on main." in (data.get("message") or ""), "message"),
    (data.get("thread_key") == "42", "thread_key"),
    (isinstance(data.get("fields"), list) and len(data["fields"]) > 0, "fields"),
    (data.get("repo") == "acme/widget", "repo"),
    (data.get("issue") == 42, "issue"),
]
missing = [label for ok, label in checks if not ok]
print("OK" if not missing else "MISSING:" + ",".join(missing))
PYEOF
)"
assert_eq "OK" "$_payload_check" \
  "payload test: event/ref/message/thread_key/fields/repo/issue all present and correct"

# fields carries the same {label,text,url} shape the other sinks render.
_fields_check="$(python3 -c "
import json
d = json.load(open('$CMD_OUT'))
f = d['fields']
print('OK' if all(set(row) >= {'label','text','url'} for row in f) else 'BAD')
")"
assert_eq "OK" "$_fields_check" "payload test: fields entries carry label/text/url"

# ── (c) Event filter applies to the cmd sink exactly as to the others ───────
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT", "events": ["merged"]}}
EOF
rm -f "$CMD_OUT"
bash "$NOTIFY" validator "#42" "should be filtered" 42 >/dev/null 2>&1
assert_file_absent "$CMD_OUT" \
  "event filter: cmd is not invoked for an event outside notifications.events"
bash "$NOTIFY" merged "#42" "should pass" 42 >/dev/null 2>&1
assert_file_exists "$CMD_OUT" \
  "event filter: cmd is invoked for an event inside notifications.events"

# ── (d) Failing command: no-op, pipeline-notify.sh still exits 0 ────────────
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "exit 7"}}
EOF
ERRFILE="$SANDBOX/notify.stderr"
out="$(bash "$NOTIFY" info "#1" "m" 1 2>"$ERRFILE")"; rc=$?
assert_eq "0" "$rc" "failing cmd: pipeline-notify.sh still exits 0"
assert_contains "$(cat "$ERRFILE")" "pipeline-notify: notifications.cmd" \
  "failing cmd: one stderr note is printed"

# ── (e) Slow command: killed at notifications.cmd_timeout_s, still exits 0 ──
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "sleep 5; echo too-late", "cmd_timeout_s": 1}}
EOF
: > "$ERRFILE"
_start=$(date +%s)
out="$(bash "$NOTIFY" info "#1" "m" 1 2>"$ERRFILE")"; rc=$?
_elapsed=$(( $(date +%s) - _start ))
assert_eq "0" "$rc" "slow cmd: pipeline-notify.sh still exits 0"
assert_contains "$(cat "$ERRFILE")" "pipeline-notify: notifications.cmd" \
  "slow cmd: one stderr note is printed"
if [ "$_elapsed" -le 4 ]; then
  pass "slow cmd: killed at notifications.cmd_timeout_s (1s), not left to run its full 5s sleep"
else
  fail "slow cmd: killed at notifications.cmd_timeout_s (1s), not left to run its full 5s sleep" \
    "elapsed: ${_elapsed}s"
fi

# ── (f) No orphaned process after a timeout ───────────────────────────────────
# Unique sleep duration so pgrep can't match any other sleep started elsewhere.
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "sleep 137", "cmd_timeout_s": 1}}
EOF
bash "$NOTIFY" info "#1" "m" 1 >/dev/null 2>&1
sleep 1
_leaked="$(pgrep -f 'sleep 137$' || true)"
assert_eq "" "$_leaked" \
  "timeout: no orphaned 'sleep 137' process survives"

# ── (g) cmd sink runs alongside a stub Slack webhook sink ────────────────────
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT"}}
EOF
rm -f "$CMD_OUT"
: > "$CURL_LOG"
out="$(SLACK_WEBHOOK_URL=https://slack.invalid/hook bash "$NOTIFY" info "#1" "both sinks" 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "combined run: pipeline-notify.sh exits 0"
assert_file_exists "$CMD_OUT" "combined run: cmd sink still fires"
assert_contains "$(cat "$CURL_LOG")" "slack.invalid" \
  "combined run: slack webhook sink is unaffected by the cmd sink"

finish
