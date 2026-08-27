#!/usr/bin/env bash
# Regression tests for the PM role event (issue #29).
#
# PM used to be the one enabled role that sent no notification, so the channel
# thread read `validator -> [silence] -> developer` and a long spec was
# indistinguishable from a dead pipeline. pipeline-notify.sh already mapped
# `pm -> project-manager`; what was missing was the template and the SKILL.md
# relay instruction. These tests pin the transport half so it cannot regress.
#
# Runs LIVE against the curl stub (not debug mode) so the rendered payload and
# the thread-state write are both exercised, modeled on test-notify-threading.sh.
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

PM_MSG="stop parseToken() dereferencing a null claim — 3 acceptance criteria, branch fix/issue-42-parsetoken-null"

# ── The pm event is delivered at all (the actual bug) ────────────────────────
live_notify pm "#42" "$PM_MSG" 42 >/dev/null
assert_file_exists "$CURL_LOG" "pm event reaches the transport"
pm_payload="$(tail -1 "$CURL_LOG" | cut -f2)"
assert_contains "$pm_payload" "acceptance criteria" "pm summary body is delivered"
assert_contains "$pm_payload" "fix/issue-42-parsetoken-null" "pm message carries the branch name"

# ── Rendered through templates/notifications/pm.md, not the verbatim fallback ─
# The template's distinguishing header. Without pm.md the script posts the bare
# summary, which would not contain this string.
assert_contains "$pm_payload" "Spec ready" "pm.md template controls the format"
assert_contains "$pm_payload" "project-manager" "pm maps to the project-manager role name"

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

finish
