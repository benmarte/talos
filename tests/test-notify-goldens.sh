#!/usr/bin/env bash
# test-notify-goldens.sh -- characterization goldens for every notification
# platform (#552). One transcript is built by running the REAL pipeline-notify.sh
# against the curl and nak stubs and compared byte for byte with
# tests/fixtures/notify-goldens.txt, so a refactor of the sender or the
# formatters cannot change what Slack, Discord, Teams, Buzz or notifications.cmd
# receive: the URL, the auth field, the exact JSON payload (or nak argv), the
# stored thread state and the stderr lines.
#
# Regenerate after an INTENDED payload change only:
#   TALOS_UPDATE_GOLDENS=1 bash tests/test-notify-goldens.sh
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
GOLDEN="$TALOS_ROOT/tests/fixtures/notify-goldens.txt"
OUT="$SANDBOX/transcript.txt"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
export PIPELINE_ISSUE_TITLE="Fix login crash"
unset SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL TEAMS_WEBHOOK_URL SLACK_BOT_TOKEN DISCORD_BOT_TOKEN \
      BUZZ_RELAY_URL BUZZ_BOT_PRIVATE_KEY PIPELINE_PR PIPELINE_PR_TITLE
: > "$OUT"

reset_state() { rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"; : > "$NAK_LOG"; : > "$CURL_QUEUE"; : > "$NAK_QUEUE"; }

# sink PLATFORM -- the env that selects one delivery path.
sink() {
  case "$1" in
    slack-webhook)   echo "SLACK_WEBHOOK_URL=https://hooks.slack.test/T/B/X" ;;
    slack-bot)       echo "SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST" ;;
    discord-webhook) echo "DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/1/abc" ;;
    discord-bot)     echo "DISCORD_BOT_TOKEN=dtok PIPELINE_DISCORD_CHANNEL=D0TEST" ;;
    teams)           echo "TEAMS_WEBHOOK_URL=https://teams.test/webhook/1" ;;
    buzz)            echo "BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_BUZZ_CHANNEL=chan-uuid-1" ;;
  esac
}

# run PLATFORM ARGS... -- one live notify invocation, then what the stubs saw.
run() {
  local _p="$1"; shift
  # shellcheck disable=SC2046
  env $(sink "$_p") bash "$NOTIFY" "$@" 2>&1; echo "rc=$?"
  if [ -s "$CURL_LOG" ]; then
    echo "-- curl (url, payload, auth, method)"; cat "$CURL_LOG"; : > "$CURL_LOG"
  fi
  if [ -s "$NAK_LOG" ]; then
    echo "-- nak argv"; cat "$NAK_LOG"; : > "$NAK_LOG"
  fi
}

scenario() {  # NAME -- the body is the function's stdin-free remaining commands
  printf '\n### %s\n' "$1" >> "$OUT"
}

state() { [ -f "$PIPELINE_THREAD_STATE" ] && { echo "-- thread state"; cat "$PIPELINE_THREAD_STATE"; echo; } || true; }

LONG="CONFIRMED: reproduced on main; the null guard in login.ts is missing; add a regression test for the empty-password case; fix it behind the existing validator; run the full suite afterwards"

# ── A. Every event on every platform, a fresh root each time ─────────────────
for ev in validator pr-opened blocked merged info issue-closed dispatched qa docs pm security; do
  case "$ev" in
    validator)    msg="$LONG" ;;
    pr-opened)    msg="PR https://github.com/acme/widget/pull/9 opened" ;;
    blocked)      msg="qa: 2 of 5 criteria failed" ;;
    merged)       msg="merged PR #9" ;;
    qa)           msg="PASS: 5/5 criteria verified" ;;
    security)     msg="FINDINGS — High: unsanitised input in <b>login</b> & \"quotes\" é ✓" ;;
    info)         msg='fence ``` inside `code` and **bold** and [link](https://x.test/a) and
- a bullet
second line' ;;
    *)            msg="$ev happened" ;;
  esac
  for p in slack-webhook slack-bot discord-webhook discord-bot teams buzz; do
    reset_state
    scenario "event=$ev platform=$p"
    PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" run "$p" "$ev" "#42" "$msg" 42 >> "$OUT"
    state >> "$OUT"
  done
done

# ── B. Threading: root then reply, per threaded sink ─────────────────────────
for p in slack-bot discord-bot buzz; do
  reset_state
  scenario "thread $p: root, reply, reply"
  { run "$p" dispatched "#7" "kickoff" 7
    run "$p" validator "#7" "CONFIRMED: ok" 7
    PIPELINE_PR=3 run "$p" pr-opened "#7" "PR opened" 7
    state; } >> "$OUT"
done

# Discord real thread: root, thread creation, then posts go into the thread.
reset_state
scenario "discord thread id stored: later posts go to the thread channel"
printf '%s\n%s\n' '{"id":"700"}' '{"id":"800"}' > "$CURL_QUEUE"
{ run discord-bot dispatched "#8" "kickoff" 8
  printf '%s\n' '{"id":"701"}' > "$CURL_QUEUE"
  run discord-bot qa "#8" "PASS: fine" 8
  state; } >> "$OUT"

# Discord thread creation refused: falls back to inline replies.
reset_state
scenario "discord thread creation fails: inline reply fallback"
printf '%s\n%s\n' '{"id":"710"}' '{"message":"Missing Permissions","code":50013}' > "$CURL_QUEUE"
{ run discord-bot dispatched "#9" "kickoff" 9
  run discord-bot qa "#9" "PASS: fine" 9
  state; } >> "$OUT"

# Slack stale anchor.
reset_state
scenario "slack thread_not_found: clear the anchor and repost as a root"
printf '{"stale": 1}' > /dev/null
mkdir -p "$(dirname "$PIPELINE_THREAD_STATE")"
printf '{"acme-widget:11": {"slack_ts": "1.1"}}' > "$PIPELINE_THREAD_STATE"
printf '%s\n%s\n' '{"ok":false,"error":"thread_not_found"}' '{"ok":true,"ts":"9.9"}' > "$CURL_QUEUE"
{ run slack-bot qa "#11" "PASS: fine" 11; state; } >> "$OUT"

reset_state
scenario "slack api error: one stderr line, no anchor"
printf '%s\n' '{"ok":false,"error":"channel_not_found"}' > "$CURL_QUEUE"
{ run slack-bot qa "#12" "PASS: fine" 12; state; } >> "$OUT"

reset_state
scenario "webhook transport failure: one stderr line"
{ STUB_CURL_FAIL_RC=7 run teams info "#13" "m" 13; STUB_CURL_FAIL_RC=7 run slack-webhook info "#13" "m" 13; } >> "$OUT"

# Buzz recovery paths.
reset_state
scenario "buzz: reply rejected -> clear anchor, repost as root"
printf '{"acme-widget:14": {"buzz_event_id": "cccc"}}' > "$PIPELINE_THREAD_STATE"
printf '%s\n%s\n' reject '{"id":"bbbb000000000000000000000000000000000000000000000000000000000002","kind":9}' > "$NAK_QUEUE"
{ run buzz qa "#14" "PASS: fine" 14; state; } >> "$OUT"

reset_state
scenario "buzz: publish failure on a root"
printf '%s\n' fail > "$NAK_QUEUE"
{ run buzz qa "#15" "PASS: fine" 15; state; } >> "$OUT"

reset_state
scenario "buzz: unresponsive relay is cut at buzz_timeout_s"
printf '{"notifications": {"buzz_timeout_s": 1}}' > talos.pipeline.json
printf '%s\n' hang > "$NAK_QUEUE"
{ NAK_HANG_S=4 run buzz qa "#16" "PASS: fine" 16; state; } >> "$OUT"
rm -f talos.pipeline.json

reset_state
scenario "buzz: key travels in NOSTR_SECRET_KEY, never argv"
: > "$NAK_ENV_LOG"
{ run buzz qa "#17" "PASS: fine" 17; echo "-- nak env"; sed 's/^\(NOSTR_SECRET_KEY\)=.*/\1=<set>/' "$NAK_ENV_LOG"; } >> "$OUT"

# ── C. Template-less fallback (monospace grid) and --render ──────────────────
printf '{"notifications": {"templates_dir": "no-such-templates"}}' > talos.pipeline.json
for p in slack-bot discord-bot teams buzz; do
  reset_state
  scenario "no templates: platform=$p (grid fallback)"
  { PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" run "$p" qa "#42" "PASS: 5/5 criteria verified" 42
    PIPELINE_PR=9 run "$p" qa "#42" "PASS: again" 42; } >> "$OUT"
done
rm -f talos.pipeline.json

for p in slack discord teams buzz default; do
  scenario "--render $p"
  { PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" bash "$NOTIFY" --render "$p" validator "#42" "$LONG" 2>&1; echo "rc=$?"; } >> "$OUT"
done
scenario "--render unknown platform"
{ bash "$NOTIFY" --render nope info "#1" m 2>&1; echo "rc=$?"; } >> "$OUT"

# ── D. Debug mode and truncation ─────────────────────────────────────────────
scenario "PIPELINE_NOTIFY_DEBUG=1: nothing posted, payloads printed"
reset_state
{ for p in slack-webhook slack-bot discord-webhook discord-bot teams buzz; do
    # shellcheck disable=SC2046
    env $(sink "$p") PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" qa "#42" "PASS: debug" 42 2>&1
  done
  echo "-- curl calls: $(wc -l < "$CURL_LOG" | tr -d ' ')"; state; } >> "$OUT"

scenario "message over the byte cap is truncated with a marker"
reset_state
big="$(python3 -c 'print("x" * 20000)')"
{ run slack-webhook info "#1" "$big" 1 | cut -c1-200 | sed 's/x\{40,\}/xxxx.../'; } >> "$OUT"

# ── E. notifications.cmd: the stdin JSON ─────────────────────────────────────
scenario "notifications.cmd stdin payload"
printf '{"notifications": {"cmd": "cat > %s/cmd-in.json"}}' "$SANDBOX" > talos.pipeline.json
{ PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" bash "$NOTIFY" pr-opened "#42" "PR opened" 42 2>&1; echo "rc=$?"
  cat "$SANDBOX/cmd-in.json"; echo
  bash "$NOTIFY" info "#5" "x" 2>&1; cat "$SANDBOX/cmd-in.json"; echo; } >> "$OUT"
rm -f talos.pipeline.json

# ── compare ──────────────────────────────────────────────────────────────────
sed "s#[^ ]*/talos-test\.[A-Za-z0-9]*#<SB>#g" "$OUT" > "$OUT.norm"
if [ -n "${TALOS_UPDATE_GOLDENS:-}" ]; then
  cp "$OUT.norm" "$GOLDEN"
  echo "golden rewritten: $GOLDEN ($(wc -l < "$GOLDEN" | tr -d ' ') lines)"
fi
if [ -f "$GOLDEN" ] && diff -u "$GOLDEN" "$OUT.norm" > "$SANDBOX/golden.diff"; then
  pass "every platform's payloads, thread state and stderr match the golden transcript"
else
  fail "every platform's payloads, thread state and stderr match the golden transcript" \
    "$(head -c 1500 "$SANDBOX/golden.diff" 2>/dev/null || echo 'no golden file')"
fi

finish
