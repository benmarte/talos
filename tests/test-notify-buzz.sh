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

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
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
assert_contains "$first_call" "event --auth -k 9" "nak publishes a signed kind:9 event with auth"
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

# ── Rich card: bold role headline + compact footer (#284) ───────────────────
# #284 replaced the per-platform buzz/ templates and their four-row GFM table
# with ONE neutral template — now shipped for every event, so NRICH is true
# on every call below — rendered straight through remark-gfm (Buzz needs no
# transpiling), plus a single compact "repo · [PR #n](url)" metadata line in
# place of the old table. Inspect the real argv via debug mode rather than the
# space-flattened log, so line structure is actually observable.
buzz_card() {  # $@ = notify args; prints the rendered kind:9 body
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-uuid-1 PIPELINE_ISSUE_TITLE="Fix login crash" \
  PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" "$@" 2>&1 \
    | sed -n '/BUZZ relay/,$p' | sed 's/.*kind=9 text=//'
}

card="$(buzz_card qa "#80" "PASS: 9/9 criteria met" 80)"
printf '%s' "$card" | grep -q '^### ' \
  && fail "headline is bold, not a GFM heading" \
  || pass "headline is bold, not a GFM heading"
assert_contains "$card" "🧪 **QA** — PASS · [#80](https://github.com/acme/widget/issues/80)" \
  "headline carries the per-role icon/label, the lifted verdict, and a clickable ref"
assert_contains "$card" "[#80 Fix login crash](https://github.com/acme/widget/issues/80)" \
  "CommonMark links pass through to buzz unconverted"
assert_contains "$card" "9/9 criteria met" "the verdict body survives into the card"
assert_not_contains "$card" '```' "no monospace grid once a template has resolved"

# When no URL is resolvable at all, the ref in the headline degrades to plain
# text rather than an empty, dangling link -- "[#87]()" would defeat the
# _neutral_to_platform tidy-up that is supposed to catch exactly this.
card_nourl="$(GH_FAIL_STDERR="rate limited" buzz_card qa "#87" "PASS: all good" 87)"
assert_contains "$card_nourl" "🧪 **QA** — PASS · #87" \
  "ref in headline stays plain text when no URL is resolvable"
assert_not_contains "$card_nourl" "[#87]" \
  "ref never renders as a dangling [ref]() with an empty URL"

# Issue-only event: PR is not resolvable, so the footer is the repo alone —
# no dangling "· [PR #n]" left behind by an empty variable.
if printf '%s' "$card" | grep -qx 'acme/widget'; then
  pass "footer degrades to a repo-only line when there is no PR"
else
  fail "footer degrades to a repo-only line when there is no PR"
fi
assert_not_contains "$card" "PR #" "no PR reference when there is no PR"

# Event with a resolvable PR: the footer appends "· [PR #n](url)".
card_pr="$(PIPELINE_PR=90 buzz_card pr-opened "#86" "opened" 86)"
assert_contains "$card_pr" "acme/widget · [PR #90](https://github.com/acme/widget/pull/90)" \
  "footer appends repo · [PR #n](url) when a PR is resolvable"

# ── Long, semicolon-joined summary becomes a lead sentence + bullets ────────
# A wall of a single 200-char line is unreadable in a chat client; only a
# long, single-line, multi-clause summary is restructured — a short one reads
# fine as a sentence and a multi-line one is already structured by its author.
long_msg="FINDINGS: first clause here with some words to pad it out nicely and further; second clause also has plenty of words to pad it out nicely too; third clause finishes off the list with even more padding words added"
card_long="$(buzz_card qa "#85" "$long_msg" 85)"
assert_eq "2" "$(printf '%s' "$card_long" | grep -c '^- ')" \
  "long semicolon-joined summary becomes a lead sentence plus bullets"

# ── Fallback card: no template resolves → the shared monospace grid ────────
# NRICH now means "a template resolved" — every shipped event has one, so the
# grid only shows for a project that has deleted/misconfigured its templates
# (or notifications.cmd). Force that by pointing templates_dir somewhere empty.
cat > talos.pipeline.json <<'EOF'
{"notifications": {"templates_dir": "templates/notifications-missing"}}
EOF
fb="$(buzz_card info "#83" "kickoff" 83)"
printf '%s' "$fb" | grep -q '^### ' \
  && pass "fallback card keeps the GFM heading (no template resolved)" \
  || fail "fallback card keeps the GFM heading (no template resolved)"
assert_contains "$fb" "Stage    info" "fallback card emits the monospace grid"
assert_contains "$fb" "Repo     acme/widget" \
  "fallback grid repo row uses owner/name, not the state-key slug"
assert_contains "$fb" "[Issue #83](" "fallback link row appended below the grid"
if printf '%s' "$fb" | grep -q '^PR '; then
  fail "fallback grid omits the PR row when there is no PR"
else
  pass "fallback grid omits the PR row when there is no PR"
fi

# Links must stay OUT of the fenced block — no client makes a URL clickable
# inside a code fence, so a link there would render as dead text.
if printf '%s' "$fb" | awk '/^```$/{f=!f; next} f' | grep -q 'http'; then
  fail "no links inside the code fence"
else
  pass "no links inside the code fence"
fi

# A long comment wraps onto continuation lines aligned under the value column
# rather than being truncated — agent verdicts carry the actual finding. This
# is the OLD grid's own wrapping (unchanged by #284), exercised here only
# because the fallback path is what still uses it.
long_grid="$(buzz_card info "#84" "$(printf 'x%.0s' $(seq 1 140))" 84)"
if printf '%s' "$long_grid" | grep -qE '^ +x+$'; then
  pass "long comment wraps instead of truncating in the fallback grid"
else
  fail "long comment wraps instead of truncating in the fallback grid"
fi
rm talos.pipeline.json

# ── Unresponsive relay is bounded, not a hang (#281) ─────────────────────────
# A relay that never answers used to hang the $(nak …) command substitution
# forever, blocking the orchestrator's whole post-merge chain.
rm -f "$PIPELINE_THREAD_STATE"; : > "$NAK_LOG"
cat > talos.pipeline.json <<'EOF'
{"notifications": {"buzz_timeout_s": 1}}
EOF
printf 'hang\n' > "$NAK_QUEUE"
t0="$(date +%s)"
out="$(NAK_HANG_S=20 live_notify dispatched "#90" "relay went dark" 90)"; rc=$?
elapsed=$(( $(date +%s) - t0 ))
assert_eq "0" "$rc" "timed-out buzz publish still exits 0"
[ "$elapsed" -lt 10 ] \
  && pass "timed-out buzz publish returns within the configured bound" \
  || fail "timed-out buzz publish returns within the configured bound (took ${elapsed}s)"
assert_contains "$out" "buzz relay timed out" "timeout is reported as a timeout"
assert_not_contains "$out" "rejected publish" "timeout is not reported as a relay rejection"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'pipeline-notify: buzz')" \
  "timeout logs exactly one stderr line"
[ -f "$PIPELINE_THREAD_STATE" ] \
  && fail "timed-out publish persists no thread anchor" \
  || pass "timed-out publish persists no thread anchor"
rm talos.pipeline.json
: > "$NAK_QUEUE"

# ── The bot key travels in the environment, never on argv (#281) ─────────────
# argv is world-readable through `ps` for the life of the process.
: > "$NAK_LOG"; : > "$NAK_ENV_LOG"; rm -f "$PIPELINE_THREAD_STATE"
live_notify dispatched "#91" "key hygiene" 91 >/dev/null
last_call="$(tail -1 "$NAK_LOG")"
assert_not_contains "$last_call" "deadbeef" "bot key never appears in nak argv"
assert_not_contains "$last_call" "--sec" "no --sec flag on the nak command line"
assert_contains "$(cat "$NAK_ENV_LOG")" "NOSTR_SECRET_KEY=deadbeef" \
  "bot key reaches nak via NOSTR_SECRET_KEY"

finish
