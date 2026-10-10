#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh threading — anchor persistence,
# reply threading, stale-anchor recovery. Runs LIVE against the curl stub
# (not debug mode) so thread-state writes are exercised. One sandbox serves:
#   (1) Slack/Discord anchor persistence and recovery
#   (2) the PM role event (#29): delivered, role-mapped, threaded under the
#       issue's anchor
#   (3) #180: concurrent writers of threads.json lose no entry
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
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
cat > talos.pipeline.json <<'EOF'
{"notifications": {"threading": false}}
EOF
live_notify dispatched "#50" "kickoff" 50 >/dev/null
live_notify validator "#50" "confirmed" 50 >/dev/null
assert_not_contains "$(tail -1 "$CURL_LOG" | cut -f2)" "thread_ts" \
  "threading=false never adds thread_ts"
[ -f "$PIPELINE_THREAD_STATE" ] \
  && fail "threading=false writes no state file" \
  || pass "threading=false writes no state file"
rm talos.pipeline.json

# ── Corrupt state file never crashes ─────────────────────────────────────────
echo "{ corrupt" > "$PIPELINE_THREAD_STATE"
out="$(live_notify validator "#42" "still works" 42)"; rc=$?
assert_eq "0" "$rc" "corrupt thread state exits 0"

# ── Discord uses REAL threads, not inline replies ────────────────────────────
# message_reference only renders a "replying to" header and leaves every stage
# in the main channel, so a busy pipeline still floods it. The root message must
# spawn an actual thread and later events must post INTO that thread channel.
discord_notify() {
  DISCORD_BOT_TOKEN=bot-test PIPELINE_DISCORD_CHANNEL=C0DISCORD \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" "$@" 2>&1
}
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"; : > "$CURL_QUEUE"
discord_notify dispatched "#70" "kickoff" 70 >/dev/null
assert_contains "$(cut -f1 "$CURL_LOG")" \
  "https://discord.com/api/v10/channels/C0DISCORD/messages" "root posts to the channel"
assert_contains "$(cut -f1 "$CURL_LOG")" \
  "/messages/900000000000000001/threads" "root message spawns a real thread"
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" '"discord_thread_id"' "thread id persisted"

# The follow-up must target the THREAD channel, and must not carry a
# message_reference — that would draw a redundant reply header inside a thread.
: > "$CURL_LOG"
discord_notify qa "#70" "qa passed" 70 >/dev/null
assert_contains "$(tail -1 "$CURL_LOG" | cut -f1)" \
  "channels/900000000000000001/messages" "reply posts into the thread channel"
assert_not_contains "$(tail -1 "$CURL_LOG" | cut -f2)" "message_reference" \
  "no redundant reply header inside the thread"

# ── Thread creation denied → inline-reply fallback, never a lost message ─────
# The usual cause is a bot without CREATE_PUBLIC_THREADS. Losing the whole
# notification over a missing permission would be worse than a flat reply.
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"
printf '%s\n%s\n' '{"id":"900000000000000002"}' '{"message":"Missing Permissions","code":50013}' > "$CURL_QUEUE"
out="$(discord_notify dispatched "#71" "kickoff" 71)"; rc=$?
assert_eq "0" "$rc" "thread creation failure still exits 0"
assert_contains "$out" "falling back to inline replies" "thread failure warns on stderr"
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_not_contains "$state" '"discord_thread_id"' "no thread id stored when creation failed"
assert_contains "$state" '"discord_msg_id"' "message anchor still stored for the fallback"
: > "$CURL_LOG"; : > "$CURL_QUEUE"
discord_notify qa "#71" "qa passed" 71 >/dev/null
assert_contains "$(tail -1 "$CURL_LOG" | cut -f2)" "message_reference" \
  "falls back to an inline reply off the stored message anchor"

# ── PM role event (#29) ──────────────────────────────────────────────────────
# PM used to be the one enabled role that sent no notification, so the channel
# thread read `validator -> [silence] -> developer` and a long spec was
# indistinguishable from a dead pipeline. These pin the transport half.
# Fresh Slack state: nothing above anchors #42 or #77.
rm -f "$PIPELINE_THREAD_STATE" talos.pipeline.json; : > "$CURL_LOG"; : > "$CURL_QUEUE"
PM_MSG="stop parseToken() dereferencing a null claim — 3 acceptance criteria, branch fix/issue-42-parsetoken-null"

# ── The pm event is delivered at all (the actual bug) ────────────────────────
live_notify pm "#42" "$PM_MSG" 42 >/dev/null
assert_file_exists "$CURL_LOG" "pm event reaches the transport"
pm_payload="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_contains "$pm_payload" "acceptance criteria" "pm summary body is delivered"
assert_contains "$pm_payload" "fix/issue-42-parsetoken-null" "pm message carries the branch name"

# ── Rendered through the pm template, not the verbatim fallback ─────────────
# The headline's role label, built by the script from ${ROLE_LABEL} (#284).
# Without the pm template the script posts the bare summary, which would carry
# no headline at all. "PM" is the display label -- shortened from #283's
# "Project Manager" when the labels were aligned with daedalus _ROLE_LABELS --
# and is distinct from the ${ROLE} slug asserted below.
assert_contains "$pm_payload" "*PM*" "the pm template controls the format"
# The pm -> project-manager role mapping is what ${ROLE} resolves to. No
# shipped template spells ${ROLE} out any more (they are built from ${HEADLINE}
# /${REF_LINK}/${SUMMARY}), so render a project override that uses the variable
# directly: this pins the MAPPING, which is what matters, rather than a
# particular template happening to print it.
mkdir -p "$SANDBOX/templates/notifications"
printf 'ROLE=${ROLE}\n' > "$SANDBOX/templates/notifications/pm.md"
role_render="$(cd "$SANDBOX" && PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render default pm "#42" "$PM_MSG" 2>&1)"
rm -f "$SANDBOX/templates/notifications/pm.md"
assert_contains "$role_render" "ROLE=project-manager" "pm maps to the project-manager role name"

# ── Threads under the same anchor as every other role event ─────────────────
# A pm event that started its own root would split the issue's thread in two.
live_notify validator "#77" "confirmed" 77 >/dev/null
root_ts="$(python3 -c "
import json,sys
print(json.load(open('$PIPELINE_THREAD_STATE'))['acme-widget:77']['slack_ts'])
")"
live_notify pm "#77" "$PM_MSG" 77 >/dev/null
pm_threaded="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_contains "$pm_threaded" "\"thread_ts\": \"$root_ts\"" "pm replies in the issue thread, not a new root"

# ── Does not disturb the anchor for following stages ─────────────────────────
live_notify developer "#77" "PR opened" 77 >/dev/null
dev_threaded="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_contains "$dev_threaded" "\"thread_ts\": \"$root_ts\"" "developer still threads under the same root after pm"

# ── #180: concurrent writers of threads.json ────────────────────────────────
# threads.json read-modify-write in _thread_state() used to run unlocked, so N
# concurrent stages (issues.max_parallel > 1) writing distinct issues could
# still lose entries -- each spawns its own python3 that loads the whole file,
# adds its key and writes it back. This drives 8 real invocations for 8
# different issues at once and asserts none of the 8 entries is lost.
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"; : > "$CURL_QUEUE"
# Default curl stub response (queue left empty) is a constant Slack
# ok+ts -- fine here, the assertion is "all 8 keys survive", not "each ts is
# unique".
pids=""
for n in 1 2 3 4 5 6 7 8; do
  ( SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
    PIPELINE_ISSUE_TITLE="issue $n" \
    bash "$NOTIFY" dispatched "#$n" "kickoff $n" "$n" >/dev/null 2>&1 ) &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done

assert_file_exists "$PIPELINE_THREAD_STATE" "threads.json created by concurrent writers"
state="$(cat "$PIPELINE_THREAD_STATE")"

for n in 1 2 3 4 5 6 7 8; do
  assert_contains "$state" "\"acme-widget:$n\"" "entry for issue #$n survives 8-way concurrent write"
done

# The file must also still be valid JSON -- a lost/interleaved write under
# the old unlocked code path could truncate or corrupt it, not just drop a
# key.
python3 -c "
import json, sys
with open('$PIPELINE_THREAD_STATE') as f:
    d = json.load(f)
sys.exit(0 if len(d) == 8 else 1)
" && pass "threads.json is valid JSON with exactly 8 entries" \
  || fail "threads.json is valid JSON with exactly 8 entries" "$state"

finish
