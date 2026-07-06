#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh threading — anchor persistence,
# reply threading, stale-anchor recovery. Runs LIVE against the curl stub
# (not debug mode) so thread-state writes are exercised.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY=".claude/pipeline/scripts/pipeline-notify.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

live_notify() {
  SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" "$@" 2>&1
}

# ── Root post stores the thread anchor ───────────────────────────────────────
live_notify dispatched "#42" "kickoff" 42 >/dev/null
assert_file_exists "$PIPELINE_THREAD_STATE" "thread state file created"
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" '"acme-widget:42"' "anchor keyed by repo slug + issue"
assert_contains "$state" '"slack_ts": "1111.2222"' "root post ts persisted as anchor"
first_payload="$(head -1 "$CURL_LOG" | cut -f2)"
assert_not_contains "$first_payload" "thread_ts" "root post has no thread_ts"

# ── Second event threads under the anchor ────────────────────────────────────
live_notify validator "#42" "confirmed" 42 >/dev/null
second_payload="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_contains "$second_payload" '"thread_ts": "1111.2222"' "follow-up posts as thread reply"

# ── Different issue gets its own root ────────────────────────────────────────
live_notify dispatched "#43" "other issue" 43 >/dev/null
third_payload="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_not_contains "$third_payload" "thread_ts" "different issue starts a new root post"

# ── Stale anchor recovery: thread_not_found → clear, repost as root ──────────
printf '%s\n%s\n' '{"ok":false,"error":"thread_not_found"}' '{"ok":true,"ts":"3333.4444"}' > "$CURL_QUEUE"
live_notify qa "#42" "qa passed" 42 >/dev/null
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" '"slack_ts": "3333.4444"' "stale anchor replaced after recovery repost"
retry_payload="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_not_contains "$retry_payload" "thread_ts" "recovery repost is a fresh root (no stale thread_ts)"

# ── threading disabled via config ────────────────────────────────────────────
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"
cat > .claude-pipeline.json <<'EOF'
{"notifications": {"threading": false}}
EOF
live_notify dispatched "#50" "kickoff" 50 >/dev/null
live_notify validator "#50" "confirmed" 50 >/dev/null
assert_not_contains "$(tail -1 "$CURL_LOG" | cut -f2)" "thread_ts" \
  "threading=false never adds thread_ts"
[ -f "$PIPELINE_THREAD_STATE" ] \
  && fail "threading=false writes no state file" \
  || pass "threading=false writes no state file"
rm .claude-pipeline.json

# ── Corrupt state file never crashes ─────────────────────────────────────────
echo "{ corrupt" > "$PIPELINE_THREAD_STATE"
out="$(live_notify validator "#42" "still works" 42)"; rc=$?
assert_eq "0" "$rc" "corrupt thread state exits 0"

finish
