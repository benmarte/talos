#!/usr/bin/env bash
# Regression tests for pipeline-notify.sh rendering — the neutral template,
# per-sink transpile, links, markdown conversion, fallback, event filtering.
# Uses the INSTALLED copy so the script-relative template fallback path is
# exercised, with stubbed gh.
# Per-platform template RESOLUTION has its own file: test-notify-templates.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
run_notify() {  # all args forwarded; debug mode, slack bot creds
  PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
    bash "$NOTIFY" "$@" 2>&1
}

# ── Rich template + issue link (Slack) ───────────────────────────────────────
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" run_notify validator "#42" "Confirmed on main." 42)"
# ${HEADLINE} (#284) is assembled by the script itself, not a per-role
# template file: role icon + bold role label + verdict-or-action + ref — in
# Slack mrkdwn (single-asterisk bold), not the generic "New comment by" body
# every role used to share.
# NB: json.dumps escapes non-ASCII, so the role icon and the em dash appear as
# \uXXXX in the payload -- assert on the ASCII part of the headline.
assert_contains "$out" "*Validator*" \
  "validator slack headline renders the per-role bold label"
# The title line is "#42 Fix login crash" -- no colon (#284): now that the
# title appears exactly once, a colon reads as a label separator against the
# verdict-first headline above it.
assert_contains "$out" "#42 Fix login crash" \
  "validator slack title line carries the issue ref and title, colon-free"
assert_not_contains "$out" "#42: Fix login crash" \
  "the old colon-joined ref:title form is gone"
# The link lives in the Block Kit `fields` section, so the label is the bare
# ref rather than the full title — but it must still be a clickable
# Slack-syntax link, which is the point here.
assert_contains "$out" '"*Issue*' "slack metadata renders as a Block Kit field"
assert_contains "$out" "<https://github.com/acme/widget/issues/42|#42>" \
  "slack payload carries clickable issue link"
assert_contains "$out" "Confirmed on main." "message body included"

# ── PR events: PR title as body, PR ref in native metadata ──────────────────
# The title/body LINE is always ${REF_LINK} — the issue, which is what the
# thread is anchored to (#284: "Keep the first template line free of...";
# README). A PR event instead swaps its ${SUMMARY} for the PR title, and the
# PR itself surfaces only through the native metadata (Block Kit field here),
# not through a second link line.
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  run_notify pr-opened "#42" "PR opened" 42)"
assert_contains "$out" "fix: guard" "pr-opened body shows the PR title instead of the raw URL"
assert_contains "$out" '"*PR*\n<https://github.com/acme/widget/pull/9|#9>"' \
  "pr-opened surfaces the PR ref as a native Slack field, clickable to the PR"
assert_contains "$out" "<https://github.com/acme/widget/issues/42|#42 Fix login crash>" \
  "pr-opened title line still anchors to the issue the thread is keyed on"

# ── PR number parsed from message when not passed via env ───────────────────
out="$(PIPELINE_ISSUE_TITLE="T" run_notify pr-opened "#42" "PR https://github.com/acme/widget/pull/13 opened" 42)"
assert_contains "$out" "/pull/13" "PR number parsed out of the message text"

# ── ${HEADLINE}'s own ref is a link (PRIMARY_URL), degrades to plain text ────
# The ref inside ${HEADLINE} (line 1, "· #42") is itself a clickable link to
# PRIMARY_URL -- the PR for pr-opened/merged, otherwise the issue -- so a
# THREAD REPLY (which carries neither ${REF_LINK} nor the metadata block) is
# never left with no route back to the PR/issue at all. Built in bash, not in
# the neutral text, because _neutral_to_platform() deletes " · [text]()"
# outright when a variable is empty -- the ref must degrade to plain text
# instead of vanishing.
out="$(PIPELINE_ISSUE_TITLE="Fix login crash" PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  run_notify pr-opened "#42" "PR opened" 42)"
assert_contains "$out" "<https://github.com/acme/widget/pull/9|#42>" \
  "pr-opened's headline ref links to the PR (PRIMARY_URL), not the issue"
# The top-level Slack "text" field is the notification/fallback preview and
# renders no markup at all -- it must unwrap the link back to plain "#42"
# rather than show raw "<url|#42>" in a push notification.
assert_contains "$out" '"text": "🤖 Talos — PR opened · #42"' \
  "slack's plain-text preview field unwraps the headline ref link"

out="$(PIPELINE_ISSUE_TITLE="Fix login crash" run_notify validator "#42" "Confirmed." 42)"
assert_contains "$out" "<https://github.com/acme/widget/issues/42|#42>" \
  "a non-PR event's headline ref links to the issue instead"

# No PR and no issue number resolvable at all -> no URL to link to -> the ref
# in the headline stays plain text, never a dangling "[#42]()".
out="$(PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" info "no-digits-ref" "just a message" "no-digits-thread" 2>&1)"
assert_contains "$out" "info · no-digits-ref" \
  "with no resolvable URL the headline ref degrades to plain text"
assert_not_contains "$out" "[no-digits-ref](" \
  "a ref with no URL never renders as a dangling markdown link"

# Discord's embed "title" is likewise plain text (no clickable links inside an
# embed title), so it must unwrap the same way Slack's "text" field does.
out="$(PIPELINE_NOTIFY_DEBUG=1 DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  PIPELINE_ISSUE_TITLE="Fix login crash" PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  bash "$NOTIFY" pr-opened "#42" "PR opened" 42 2>&1)"
assert_contains "$out" '"title": "🤖 Talos — PR opened · #42"' \
  "discord's embed title unwraps the headline ref link to plain text"
assert_contains "$out" '"description": "[#42 Fix login crash]' \
  "discord's embed description keeps the (separate) title-line link"

# Discord thread names are plain text too, and capped at 100 chars: a linked
# ref must not spend that budget on the URL. Real (non-debug) posting mode is
# needed here since the create-thread call only fires after a live root post
# — which also means it persists a real thread anchor, so it uses a thread_key
# ("9042") no other assertion in this file touches, to avoid turning a LATER
# debug-mode discord/#42 call into a (fields-dropping) reply by accident.
: > "$CURL_LOG"
DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 PIPELINE_ISSUE_TITLE="Fix login crash" \
  PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  bash "$NOTIFY" pr-opened "#42" "PR opened" 9042 >/dev/null 2>&1
thread_call="$(grep '/threads' "$CURL_LOG" || true)"
assert_contains "$thread_call" '"name": "#42' \
  "the discord thread-creation call names the thread after the ref"
assert_not_contains "$thread_call" "https://github.com" \
  "the discord thread name never spends its 100-char budget on the URL"

# ── Discord payload: markdown link in body + clickable embed url ────────────
out="$(PIPELINE_NOTIFY_DEBUG=1 DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed." 42 2>&1)"
assert_contains "$out" '"name": "Issue"' "discord metadata renders as an embed field"
assert_contains "$out" '[#42](https://github.com/acme/widget/issues/42)' \
  "discord embed field carries the markdown issue link"
assert_contains "$out" '"url": "https://github.com/acme/widget/issues/42"' \
  "discord embed title is clickable (embed url set)"

# ── Slack markdown conversion ────────────────────────────────────────────────
# ${HEADLINE} is assembled in bash as "**${ROLE_LABEL}**" (CommonMark bold);
# the Slack transpile step must turn it into single-asterisk mrkdwn before it
# ever reaches a payload.
out="$(PIPELINE_ISSUE_TITLE="T" run_notify dispatched "#42" "ignored" 42)"
assert_contains "$out" "*Talos*" "**bold** converted to slack *bold*"
assert_not_contains "$out" "**Talos**" "no CommonMark bold left in slack payload"

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

# ── Per-role headline: icon + label differ per role, lifecycle is Talos ─────
out_qa="$(PIPELINE_ISSUE_TITLE="T" PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" qa "#42" "PASS: 3 criteria verified" 42 2>&1)"
out_sec="$(PIPELINE_ISSUE_TITLE="T" PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" security "#42" "FINDINGS: high sev issue" 42 2>&1)"
out_merged="$(PIPELINE_ISSUE_TITLE="T" PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" merged "#42" "m" 42 2>&1)"
assert_contains "$out_qa" "*QA*" "qa role gets its own bold label"
assert_contains "$out_qa" "PASS ·" "a leading verdict token is lifted into the headline"
assert_contains "$out_sec" "*Security*" "security role gets its own bold label"
assert_contains "$out_sec" "FINDINGS ·" "a different verdict token is lifted the same way"
assert_contains "$out_merged" "*Talos*" "a lifecycle event (merged) speaks as Talos"
assert_not_contains "$out_merged" "*Security*" "lifecycle events don't borrow a role label"

# ── blocked: leading "<stage>: " is lifted into "blocked by <stage>" ────────
out="$(PIPELINE_ISSUE_TITLE="T" PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" blocked "#42" "qa: flaky test in ci" 42 2>&1)"
assert_contains "$out" "blocked by qa" \
  "blocked lifts the leading stage prefix into the headline"
assert_contains "$out" "flaky test in ci" "the rest of the message survives as the body"
assert_not_contains "$out" "qa: flaky test in ci" \
  "the stage prefix is not duplicated in the body"

# ── Long semicolon-joined summary becomes a lead sentence + bullets ─────────
LONG_MSG="PASS: alpha did one thing that was fine and dandy; beta did another thing that also worked well and cleanly; gamma verified the last remaining bit of the acceptance criteria thoroughly and signed off"
out="$(PIPELINE_ISSUE_TITLE="T" PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  bash "$NOTIFY" qa "#42" "$LONG_MSG" 42 2>&1)"
assert_contains "$out" "alpha did one thing that was fine and dandy" \
  "long summary keeps its lead clause as a plain sentence"
assert_contains "$out" "• beta did another thing that also worked well and cleanly" \
  "long summary's remaining clauses become bullets"
assert_contains "$out" "• gamma verified the last remaining bit of the acceptance criteria thoroughly and signed off" \
  "every remaining clause gets its own bullet"

# ── Buzz: rendered neutral template, relay + channel, role headline ─────────
out="$(PIPELINE_NOTIFY_DEBUG=1 BUZZ_RELAY_URL=ws://localhost:3000 \
  BUZZ_BOT_PRIVATE_KEY=deadbeef PIPELINE_BUZZ_CHANNEL=chan-uuid-1 \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$NOTIFY" validator "#42" "Confirmed." 42 2>&1)"
assert_contains "$out" "BUZZ relay=ws://localhost:3000 channel=chan-uuid-1 kind=9" \
  "buzz debug carries relay, channel, and kind"
# Buzz is a pass-through sink (#284): the neutral dialect goes out verbatim,
# bold run and all -- not the generic "New comment by" body every role used
# to share.
assert_contains "$out" "🔎 **Validator** — update" \
  "buzz text is the rendered neutral template, with its role headline intact"
# The link lives in the neutral body, emitted as unconverted CommonMark —
# Buzz renders GFM, so there is no link syntax to translate to.
assert_contains "$out" "[#42 Fix login crash](https://github.com/acme/widget/issues/42)" \
  "buzz keeps CommonMark links unconverted"
assert_not_contains "$out" "###" \
  "a rich buzz post (template resolved) carries no GFM heading -- that's the grid-fallback shape"

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
out="$(cd "$SANDBOX/subdir" && PIPELINE_NOTIFY_DEBUG=1 bash "$NOTIFY" \
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

# ── Native per-platform metadata from the SAME neutral template (#284) ──────
# With a template in play (every real event ships one now), each sink renders
# the PR / Issue / Stage / Repo metadata in its own native construct: Block
# Kit `fields` on Slack, embed `fields` on Discord, a FactSet on Teams, and on
# Buzz a compact "repo · [PR #n](url)" footer — NOT the four-row GFM table
# the old per-platform design used. Uses its own variable: `out` is reused by
# assertions above.
rich_out="$(PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-1 TEAMS_WEBHOOK_URL=https://teams.invalid/hook \
  PIPELINE_ISSUE_TITLE="Fix login crash" \
  PIPELINE_PR=9 PIPELINE_PR_TITLE="fix: guard" \
  bash "$NOTIFY" pr-opened "#42" "PR opened" 42 2>&1)"
assert_contains "$rich_out" '{"type": "section", "fields": [' \
  "slack renders metadata as a Block Kit fields section"
assert_contains "$rich_out" '{"name": "Stage", "value": "pr-opened", "inline": true}' \
  "discord renders metadata as embed fields"
assert_contains "$rich_out" '"type": "FactSet"' \
  "teams renders metadata as an Adaptive Card FactSet"
assert_contains "$rich_out" "acme/widget · [PR #9](https://github.com/acme/widget/pull/9)" \
  "buzz renders the compact repo · [PR #n](url) footer, not a GFM table"
assert_not_contains "$rich_out" '| Stage | pr-opened |' \
  "the old four-row GFM metadata table is gone from buzz"
# The monospace grid is gone from every rich sink — that is the whole point.
assert_not_contains "$rich_out" 'Stage    pr-opened' \
  "no sink falls back to the monospace grid when a template has resolved"
assert_not_contains "$rich_out" '"fontType": "Monospace"' \
  "teams drops the Monospace TextBlock once it has a FactSet"
# Links keep each platform's own syntax.
assert_contains "$rich_out" '<https://github.com/acme/widget/pull/9|#9>' \
  "slack fields use slack link syntax"
assert_contains "$rich_out" '[#9](https://github.com/acme/widget/pull/9)' \
  "discord/teams fields use markdown link syntax"

# ── Monospace grid remains the no-template fallback ──────────────────────────
# NRICH now means "a template resolved" (#284), and Talos ships a neutral
# template for every real event — so exercising the grid fallback for a real
# event takes a project that resolves NONE: point notifications.templates_dir
# at a directory that doesn't exist anywhere (project or install root). This
# is the "project with no template" case the grid is still the true fallback
# for; the shared fenced grid — not a pipe table — is still the right
# construct because Slack mrkdwn has no table syntax and would post one as
# literal pipes.
cat > talos.pipeline.json <<'EOF'
{"notifications": {"templates_dir": "no/such/templates/dir"}}
EOF
plain_out="$(PIPELINE_NOTIFY_DEBUG=1 SLACK_BOT_TOKEN=t PIPELINE_SLACK_CHANNEL=C1 \
  DISCORD_BOT_TOKEN=t PIPELINE_DISCORD_CHANNEL=123 \
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-1 TEAMS_WEBHOOK_URL=https://teams.invalid/hook \
  PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" dispatched "#42" "kickoff" 42 2>&1)"
rm talos.pipeline.json
assert_eq "4" "$(printf '%s' "$plain_out" | grep -c 'Stage    dispatched')" \
  "every platform embeds the identical monospace grid when no template resolves"
assert_contains "$plain_out" 'Repo     acme/widget' \
  "grid repo row uses owner/name, not the state-key slug"
assert_contains "$plain_out" '"fontType": "Monospace"' \
  "teams falls back to a Monospace TextBlock (adaptive cards cannot render code fences)"
assert_contains "$plain_out" '### 🧵 [talos] dispatched #42' \
  "buzz grid fallback (unlike a rich post) still opens with a real GFM heading"
# Links live outside the grid — no platform makes a URL clickable in a code block.
assert_contains "$plain_out" '<https://github.com/acme/widget/issues/42|Issue #42>' \
  "slack fallback link row uses slack link syntax"
assert_contains "$plain_out" '[Issue #42](https://github.com/acme/widget/issues/42)' \
  "discord/buzz/teams fallback link rows use markdown link syntax"

finish
