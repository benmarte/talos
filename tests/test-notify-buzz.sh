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

# ── Relay REJECTION (nak exits 0) must not be read as success ───────────────
# The bug this guards: nak returns 0 and prints the locally-signed event even
# when the relay refuses it, so branching on $? or scraping stdout records a
# phantom success and persists an anchor for an event that was never stored.
rm -f "$PIPELINE_THREAD_STATE"; : > "$NAK_LOG"
printf 'reject\n' > "$NAK_QUEUE"
out="$(live_notify dispatched "#60" "rejected post" 60)"
assert_contains "$out" "buzz relay rejected publish" "relay rejection surfaces on stderr"
assert_contains "$out" "not a relay member" "rejection message includes the relay's reason"
[ -f "$PIPELINE_THREAD_STATE" ] \
  && fail "rejected publish persists no thread anchor" \
  || pass "rejected publish persists no thread anchor"

# A rejection is still a soft failure — never break the pipeline.
printf 'reject\n' > "$NAK_QUEUE"
live_notify dispatched "#61" "rejected post" 61 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "rejected publish still exits 0"

# ── A rejected REPLY drives stale-anchor recovery, same as an exit-1 fail ────
rm -f "$PIPELINE_THREAD_STATE"; : > "$NAK_LOG"; : > "$NAK_QUEUE"
live_notify dispatched "#62" "root" 62 >/dev/null            # anchor established
RECOVER_ID="cccc000000000000000000000000000000000000000000000000000000000003"
printf '%s\n%s\n' "reject" "{\"id\":\"$RECOVER_ID\",\"kind\":9}" > "$NAK_QUEUE"
live_notify qa "#62" "qa passed" 62 >/dev/null
state="$(cat "$PIPELINE_THREAD_STATE")"
assert_contains "$state" "\"buzz_event_id\": \"$RECOVER_ID\"" "rejected reply triggers recovery repost"
assert_not_contains "$(tail -1 "$NAK_LOG")" ";;reply" "recovery repost after rejection is a fresh root"

# ── Relay URL resolves from the config file, not just env ───────────────────
rm -f "$PIPELINE_THREAD_STATE"; : > "$NAK_LOG"; : > "$NAK_QUEUE"
cat > talos.pipeline.json <<'EOF'
{"notifications": {"buzz_relay": "ws://config-relay:3000", "buzz_channel": "chan-from-config"}}
EOF
BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_ISSUE_TITLE="T" \
  bash "$NOTIFY" dispatched "#70" "from config" 70 >/dev/null 2>&1
cfg_call="$(tail -1 "$NAK_LOG")"
assert_contains "$cfg_call" "ws://config-relay:3000" "relay URL read from notifications.buzz_relay"
assert_contains "$cfg_call" "h=chan-from-config" "channel read from config alongside it"

# Exported env still wins over the config value.
: > "$NAK_LOG"
BUZZ_RELAY_URL=ws://env-relay:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_ISSUE_TITLE="T" \
  bash "$NOTIFY" dispatched "#71" "env override" 71 >/dev/null 2>&1
assert_contains "$(tail -1 "$NAK_LOG")" "ws://env-relay:3000" "env BUZZ_RELAY_URL overrides config"
rm talos.pipeline.json

# ── GFM card: heading + body + metadata table ────────────────────────────────
# Buzz renders remark-gfm, so the sink emits headings and a table — neither of
# which Slack's mrkdwn supports. Inspect the real argv via debug mode rather
# than the space-flattened log, so line structure is actually observable.
buzz_card() {  # $@ = notify args; prints the rendered kind:9 body
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-uuid-1 PIPELINE_ISSUE_TITLE="Fix login crash" \
  PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" "$@" 2>&1 \
    | sed -n '/BUZZ relay/,$p' | sed 's/.*kind=9 text=//'
}

card="$(buzz_card pr-opened "#80" "body text" 80)"
printf '%s' "$card" | grep -q '^### ' \
  && pass "title line rendered as a GFM heading" \
  || fail "title line rendered as a GFM heading"
assert_contains "$card" "Stage    pr-opened" "monospace grid emitted"
assert_contains "$card" "Repo     acme/widget" "repo row uses owner/name, not the state-key slug"
assert_contains "$card" "Comment  body text" "grid leads with the comment"
assert_contains "$card" "[Issue #80](" "link row appended below the grid"

# Links must stay OUT of the fenced block — no client makes a URL clickable
# inside a code fence, so a link there would render as dead text.
printf '%s' "$card" | awk '/^```$/{f=!f; next} f' | grep -q 'http' \
  && fail "no links inside the code fence" \
  || pass "no links inside the code fence"

# The link row carries the links, so the template's trailing "🔗 …" line — which
# repeats the title already in the heading — must not survive into the card.
printf '%s' "$card" | grep -q '^🔗 ' \
  && fail "template link line dropped once the link row carries it" \
  || pass "template link line dropped once the link row carries it"

# An issue-only event has no PR: the row must be omitted, not rendered blank.
card_issue="$(buzz_card validator "#81" "confirmed" 81)"
assert_contains "$card_issue" "Issue    #81" "issue-only event still gets an issue row"
printf '%s' "$card_issue" | grep -qE '^PR +#' \
  && fail "PR row omitted entirely when there is no PR" \
  || pass "PR row omitted entirely when there is no PR"

# A long comment wraps onto continuation lines aligned under the value column
# rather than being truncated — agent verdicts carry the actual finding.
long="$(buzz_card validator "#82" "$(printf 'x%.0s' $(seq 1 140))" 82)"
printf '%s' "$long" | grep -qE '^ +x+$' \
  && pass "long comment wraps instead of truncating" \
  || fail "long comment wraps instead of truncating"

finish
