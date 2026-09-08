#!/usr/bin/env bash
# Regression test for #180: threads.json read-modify-write in
# pipeline-notify.sh's _thread_state() used to run unlocked, so N concurrent
# stages (issues.max_parallel > 1) writing distinct issues could still lose
# entries -- each spawns its own python3 process that loads the whole file,
# adds its key, and writes the whole file back; two overlapping load/save
# cycles clobber each other's write regardless of whether they touch the
# same KEY. This drives 8 real pipeline-notify.sh invocations for 8
# different issues at once and asserts none of the 8 entries are lost.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

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

echo ""
echo "test-notify-threads-concurrent: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
