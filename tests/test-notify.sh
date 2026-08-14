#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh rendering — templates, links,
# markdown conversion, fallback, event filtering. Uses the INSTALLED copy so
# the script-relative template fallback path is exercised, with stubbed gh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY=".claude/talos/scripts/pipeline-notify.sh"
run_notify() {  # all args forwarded; debug mode, slack bot creds
  PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
    bash "$NOTIFY" "$@" 2>&1
}

# ── Rich template + issue link (Slack) ───────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" run_notify validator "#42" "Confirmed on main." 42)"
assert_contains "$out" "New comment by validator agent on #42: Fix login crash" \
  "validator template renders title with role + issue title"
# The link moved from the body's trailing "🔗 …" line into the Block Kit
# `fields` section, so the label is the bare ref rather than the full title —
# but it must still be a clickable Slack-syntax link, which is the point here.
assert_contains "$out" "<https://github.com/acme/widget/issues/42|Issue #42>" \
  "slack payload carries clickable issue link"
assert_contains "$out" "Confirmed on main." "message body included"

# ── PR events link to the PR ─────────────────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  run_notify pr-opened "#42" "PR opened" 42)"
assert_contains "$out" "PR #9: fix: guard" "pr-opened template shows PR ref"
assert_contains "$out" "<https://github.com/acme/widget/pull/9|PR #9>" \
  "pr-opened links to the PR, not the issue"

# ── PR number parsed from message when not passed via env ───────────────────
out="$(PIPELINE_ISSUE_TITLE="T" run_notify pr-opened "#42" "PR https://github.com/acme/widget/pull/13 opened" 42)"
assert_contains "$out" "/pull/13" "PR number parsed out of the message text"

# ── Discord payload: markdown link in body + clickable embed url ────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed." 42 2>&1)"
assert_contains "$out" '[Issue #42](https://github.com/acme/widget/issues/42)' \
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
cat > talos.pipeline.json <<'EOF'
{"notifications": {"events": ["merged", "blocked"]}}
EOF
out="$(PIPELINE_ISSUE_TITLE="T" run_notify validator "#42" "should be filtered" 42)"
assert_eq "" "$out" "event not in notifications.events is dropped"
out="$(PIPELINE_ISSUE_TITLE="T" run_notify merged "#42" "should pass" 42)"
assert_contains "$out" "SLACK" "allowed event passes the filter"
rm talos.pipeline.json

# ── Buzz debug payload: rendered template, relay + channel ───────────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 BUZZ_RELAY_URL=ws://localhost:3000 \
  BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_BUZZ_CHANNEL=chan-uuid-1 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed." 42 2>&1)"
assert_contains "$out" "BUZZ relay=ws://localhost:3000 channel=chan-uuid-1 kind=9" \
  "buzz debug carries relay, channel, and kind"
assert_contains "$out" "New comment by validator agent on #42: Fix login crash" \
  "buzz text is the rendered template"
# The link moved from the template's trailing "🔗 …" line into the card's
# metadata table (which is why the label is now the bare issue ref rather than
# the full title), but it must still be emitted as unconverted CommonMark —
# Buzz renders GFM, so there is no per-platform link syntax to translate to.
assert_contains "$out" "[Issue #42](https://github.com/acme/widget/issues/42)" \
  "buzz keeps CommonMark links unconverted"

# ── Buzz partial config (no private key) → silent skip ───────────────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 BUZZ_RELAY_URL=ws://localhost:3000 \
  PIPELINE_BUZZ_CHANNEL=chan-uuid-1 bash "$NOTIFY" validator "#42" "m" 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "buzz partial config exits 0"
assert_not_contains "$out" "BUZZ" "buzz without private key produces no buzz output"

# ── No credentials at all → silent no-op, exit 0 ─────────────────────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" validator "#42" "m" 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "no credentials exits 0"
assert_eq "" "$out" "no credentials produces no output"

# ── .env loading: root-env-loaded ────────────────────────────────────────────
# Write a repo-root .env with a Slack bot token and channel; run notify from a
# nested subdir to prove git rev-parse resolves to the repo root.
printf 'SLACK_BOT_TOKEN=xoxb-from-dotenv\nPIPELINE_SLACK_CHANNEL=C_FROM_DOTENV\n' > "$SANDBOX/.env"
mkdir -p "$SANDBOX/subdir"
out="$(cd "$SANDBOX/subdir" && PIPELINE_NOTIFY_DEBUG=1 bash "$SANDBOX/$NOTIFY" \
  info "#1" "dotenv test" 1 2>&1)"
assert_contains "$out" "SLACK" \
  "root .env loaded from nested subdir (bot token picked up)"
# Cleanup .env before next tests
rm -f "$SANDBOX/.env"

# ── .env loading: env-var-precedence ─────────────────────────────────────────
# Export PIPELINE_SLACK_CHANNEL=C_ENV and put C_FILE in the root .env;
# the exported value must win.
printf 'SLACK_BOT_TOKEN=xoxb-test\nPIPELINE_SLACK_CHANNEL=C_FILE\n' > "$SANDBOX/.env"
out="$(PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C_ENV \
  bash "$NOTIFY" info "#1" "precedence test" 1 2>&1)"
assert_contains "$out" '"channel": "C_ENV"' \
  "exported PIPELINE_SLACK_CHANNEL beats .env value"
assert_not_contains "$out" '"channel": "C_FILE"' \
  ".env channel value is not used when env var is already set"
# Cleanup .env
rm -f "$SANDBOX/.env"

# ── .env loading: absence safety ─────────────────────────────────────────────
# No .env anywhere — should exit 0 with no crash or error output on stderr.
out="$(PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" info "#1" "no dotenv" 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "no .env anywhere exits 0"

# ── .env loading: quoted values are stripped ──────────────────────────────────
# Double-quoted channel value must be stored without the surrounding quotes.
printf 'SLACK_BOT_TOKEN=xoxb-test\nPIPELINE_SLACK_CHANNEL="C_QUOTED"\n' > "$SANDBOX/.env"
out="$(PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" info "#1" "quote strip test" 1 2>&1)"
assert_contains "$out" '"channel": "C_QUOTED"' \
  "double-quoted .env value stripped — channel stored without quotes"
assert_not_contains "$out" 'C_QUOTED\"' \
  "no literal quote chars inside channel value"
rm -f "$SANDBOX/.env"

# ── One shared monospace grid across every platform ──────────────────────────
# Slack mrkdwn has no table syntax, so a pipe table would post as literal pipes.
# A fixed-width block is the only construct that renders as the same aligned
# grid on all four sinks, so the SAME text must appear in each payload — this
# asserts the shared string, unlike the per-platform link syntax below it.
# Uses its own variable: `out` is reused by assertions above.
shared_out="$(PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-1 TEAMS_WEBHOOK_URL=https://teams.invalid/hook \
  PIPELINE_ISSUE_TITLE="Fix login crash" \
  PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  bash "$NOTIFY" pr-opened "#42" "PR opened" 42 2>&1)"
# One grid row per sink: Slack, Discord, Buzz and Teams each embed the same text.
assert_eq "4" "$(printf '%s' "$shared_out" | grep -c 'Stage    pr-opened')" \
  "every platform embeds the identical monospace grid"
assert_contains "$shared_out" 'Repo     acme/widget' \
  "grid repo row uses owner/name, not the state-key slug"
assert_contains "$shared_out" 'Comment  PR opened' "grid leads with the comment"
assert_contains "$shared_out" '"fontType": "Monospace"' \
  "teams uses a Monospace TextBlock (adaptive cards cannot render code fences)"
# Links live outside the grid — no platform makes a URL clickable in a code block.
assert_contains "$shared_out" '<https://github.com/acme/widget/pull/9|PR #9>' \
  "slack link row uses slack link syntax"
assert_contains "$shared_out" '[PR #9](https://github.com/acme/widget/pull/9)' \
  "discord/buzz/teams link rows use markdown link syntax"

finish
