#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh Buzz delivery — nak invocation shape,
# NIP-10 reply threading, stale-anchor recovery, missing-nak degradation.
# Runs LIVE against the nak stub (not debug mode) so thread-state writes are
# exercised, modeled on test-notify-threading.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY=".claude/talos/scripts/pipeline-notify.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

DEFAULT_ID="aaaa000000000000000000000000000000000000000000000000000000000001"

live_notify() {
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-uuid-1 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" "$@" 2>&1
}

# ── Root post: kind:9 with h tag, no reply tag, anchor persisted ─────────────
live_notify dispatched "#42" "kickoff" 42 >/dev/null
first_call="$(head -1 "$NAK_LOG")"
assert_contains "$first_call" "event --auth --sec deadbeef -k 9" "nak publishes a signed kind:9 event with auth"
assert_contains "$first_call" "h=chan-uuid-1" "root post carries the channel h tag"
assert_contains "$first_call" "ws://localhost:3000" "root post targets the configured relay"
assert_not_contains "$first_call" ";;reply" "root post has no NIP-10 reply tag"
assert_file_exists "$PIPELINE_THREAD_STATE" "thread state file created"
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" '"acme-widget:42"' "anchor keyed by repo slug + issue"
assert_contains "$state" "\"buzz_event_id\": \"$DEFAULT_ID\"" "root event id persisted as anchor"

# ── Second event replies to the anchor via NIP-10 e tag ──────────────────────
live_notify validator "#42" "confirmed" 42 >/dev/null
second_call="$(tail -1 "$NAK_LOG")"
assert_contains "$second_call" "e=$DEFAULT_ID;;reply" "follow-up posts as NIP-10 reply to the root"

# ── Different issue gets its own root ────────────────────────────────────────
live_notify dispatched "#43" "other issue" 43 >/dev/null
third_call="$(tail -1 "$NAK_LOG")"
assert_not_contains "$third_call" ";;reply" "different issue starts a new root post"

# ── Stale anchor recovery: reply rejected → clear, repost as root ────────────
NEW_ID="bbbb000000000000000000000000000000000000000000000000000000000002"
printf '%s\n%s\n' "fail" "{\"id\":\"$NEW_ID\",\"kind\":9}" > "$NAK_QUEUE"
live_notify qa "#42" "qa passed" 42 >/dev/null
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" "\"buzz_event_id\": \"$NEW_ID\"" "stale anchor replaced after recovery repost"
retry_call="$(tail -1 "$NAK_LOG")"
assert_not_contains "$retry_call" ";;reply" "recovery repost is a fresh root (no stale reply tag)"

# ── threading disabled via config ────────────────────────────────────────────
rm -f "$PIPELINE_THREAD_STATE"; : > "$NAK_LOG"
cat > talos.pipeline.json <<'EOF'
{"notifications": {"threading": false}}
EOF
live_notify dispatched "#50" "kickoff" 50 >/dev/null
live_notify validator "#50" "confirmed" 50 >/dev/null
assert_not_contains "$(tail -1 "$NAK_LOG")" ";;reply" "threading=false never adds a reply tag"
[ -f "$PIPELINE_THREAD_STATE" ] \
  && fail "threading=false writes no state file" \
  || pass "threading=false writes no state file"
rm talos.pipeline.json

# ── nak missing from PATH → warning on stderr, still exit 0 ──────────────────
out="$(PATH="/usr/bin:/bin" BUZZ_RELAY_URL=ws://localhost:3000 \
  BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_BUZZ_CHANNEL=chan-uuid-1 \
  PIPELINE_ISSUE_TITLE="T" bash "$NOTIFY" info "#1" "no nak" 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "missing nak exits 0"
assert_contains "$out" "'nak' CLI not found" "missing nak warns on stderr"

finish
