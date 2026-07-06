#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh rendering — templates, links,
# markdown conversion, fallback, event filtering. Uses the INSTALLED copy so
# the script-relative template fallback path is exercised, with stubbed gh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY=".claude/pipeline/scripts/pipeline-notify.sh"
run_notify() {  # all args forwarded; debug mode, slack bot creds
  PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
    bash "$NOTIFY" "$@" 2>&1
}

# ── Rich template + issue link (Slack) ───────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" run_notify validator "#42" "Confirmed on main." 42)"
assert_contains "$out" "New comment by validator agent on #42: Fix login crash" \
  "validator template renders title with role + issue title"
assert_contains "$out" "<https://github.com/acme/widget/issues/42|#42: Fix login crash>" \
  "slack payload carries clickable issue link"
assert_contains "$out" "Confirmed on main." "message body included"

# ── PR events link to the PR ─────────────────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  run_notify pr-opened "#42" "PR opened" 42)"
assert_contains "$out" "PR #9: fix: guard" "pr-opened template shows PR ref"
assert_contains "$out" "<https://github.com/acme/widget/pull/9|PR #9: fix: guard>" \
  "pr-opened links to the PR, not the issue"

# ── PR number parsed from message when not passed via env ───────────────────
out="$(PIPELINE_ISSUE_TITLE="T" run_notify pr-opened "#42" "PR https://github.com/acme/widget/pull/13 opened" 42)"
assert_contains "$out" "/pull/13" "PR number parsed out of the message text"

# ── Discord payload: markdown link in body + clickable embed url ────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed." 42 2>&1)"
assert_contains "$out" '[#42: Fix login crash](https://github.com/acme/widget/issues/42)' \
  "discord description carries markdown issue link"
assert_contains "$out" '"url": "https://github.com/acme/widget/issues/42"' \
  "discord embed title is clickable (embed url set)"

# ── Slack markdown conversion ────────────────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="T" run_notify dispatched "#42" "ignored" 42)"
assert_contains "$out" "*Issue:*" "**bold** converted to slack *bold*"
assert_not_contains "$out" "**Issue:**" "no CommonMark bold left in slack payload"

# ── Fallback when no template exists: plain text still carries the URL ───────
out="$(PIPELINE_ISSUE_TITLE="T" run_notify some-unknown-event "#42" "hello" 42)"
# NB: json.dumps escapes non-ASCII (the em dash becomes —) — assert around it
assert_contains "$out" "[talos] some-unknown-event #42" "unknown event falls back to plain text"
assert_contains "$out" "https://github.com/acme/widget/issues/42" "fallback text still carries issue URL"

# ── PIPELINE_REPO_URL override beats gh detection ────────────────────────────
out="$(PIPELINE_REPO_URL="https://github.com/other/repo" PIPELINE_ISSUE_TITLE="T" \
  run_notify validator "#5" "m" 5)"
assert_contains "$out" "https://github.com/other/repo/issues/5" "PIPELINE_REPO_URL override respected"

# ── Event filter from config ─────────────────────────────────────────────────
cat > .claude-pipeline.json <<'EOF'
{"notifications": {"events": ["merged", "blocked"]}}
EOF
out="$(PIPELINE_ISSUE_TITLE="T" run_notify validator "#42" "should be filtered" 42)"
assert_eq "" "$out" "event not in notifications.events is dropped"
out="$(PIPELINE_ISSUE_TITLE="T" run_notify merged "#42" "should pass" 42)"
assert_contains "$out" "SLACK" "allowed event passes the filter"
rm .claude-pipeline.json

# ── No credentials at all → silent no-op, exit 0 ─────────────────────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" validator "#42" "m" 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "no credentials exits 0"
assert_eq "" "$out" "no credentials produces no output"

finish
