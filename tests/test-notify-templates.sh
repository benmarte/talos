#!/usr/bin/env bash
# test-notify-templates.sh -- per-platform notification templates (#280).
#
# Covers:
#   (a) resolution order: project/<platform> -> project/<event> ->
#       install/<platform> -> install/<event>
#   (b) fallback to the platform-neutral template when a platform ships none
#   (c) the pre-#280 single-level project override still wins over a shipped
#       platform template, with no config change
#   (d) --render prints a rendering without posting or touching thread state
#   (e) every SHIPPED template references only documented variables
#   (f) an undocumented variable -- notably an exported secret -- renders
#       as a literal ${NAME} and never leaks its value (#283 security)
#   (g) pipes/newlines in GFM table cells are escaped, not injected
#   (h) a triple-backtick run can't break out of the fallback grid's fence
#
# Hermetic: make_sandbox exports a sandbox-local HOME, so nothing here reads a
# developer's real ~/.hermes/.env (see CHANGELOG ~line 427).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

render() {  # $1=platform $2=event [$3=ref] [$4=message]
  PIPELINE_ISSUE_TITLE="Fix login crash" \
    bash "$NOTIFY" --render "$1" "$2" "${3:-#42}" "${4:-a message}" 2>&1
}

# ── (a) Platform-specific template wins for its own platform ─────────────────
out="$(render buzz validator)"
assert_contains "$out" "templates/notifications/buzz/validator.md" \
  "buzz resolves the shipped buzz/ template"
assert_contains "$out" "# rich:     yes" "a platform template marks the sink rich"
assert_contains "$out" "### " "buzz template uses a real GFM heading"

out="$(render slack validator)"
assert_contains "$out" "templates/notifications/slack/validator.md" \
  "slack resolves the shipped slack/ template"

# Every platform ships every role and lifecycle event.
for _ev in validator pm developer qa reviewer security docs \
           pr-opened blocked merged issue-closed; do
  for _pl in slack discord teams buzz; do
    assert_file_exists "$TALOS_ROOT/templates/notifications/$_pl/$_ev.md" \
      "shipped template exists: $_pl/$_ev.md"
  done
done

# ── (b) Fallback to the platform-neutral template ────────────────────────────
# `dispatched` ships only a top-level template, so every platform falls back.
out="$(render slack dispatched)"
assert_contains "$out" "templates/notifications/dispatched.md" \
  "no platform file -> platform-neutral template"
assert_not_contains "$out" "/slack/dispatched.md" \
  "the fallback is not silently attributed to the platform dir"
assert_contains "$out" "# rich:     no" "a neutral fallback is not marked rich"

# An event with no template at all degrades to the plain-text line.
out="$(render slack some-unknown-event)"
assert_contains "$out" "# template: (none" "unknown event resolves no template"
assert_contains "$out" "[talos] some-unknown-event" "unknown event falls back to plain text"

# ── (c) Project override precedence ──────────────────────────────────────────
# The pre-#280 single-level layout: a repo-local templates/notifications/<event>.md
# must keep winning over the SHIPPED slack/<event>.md, with no config change.
mkdir -p "$SANDBOX/templates/notifications"
printf 'PROJECT-NEUTRAL ${REF_TITLE}\n' > "$SANDBOX/templates/notifications/validator.md"
out="$(render slack validator)"
assert_contains "$out" "PROJECT-NEUTRAL" \
  "project single-level override beats the shipped platform template"
assert_contains "$out" "# rich:     no" \
  "a neutral project override does not claim to be a platform template"

# A project platform template beats the project's own neutral one.
mkdir -p "$SANDBOX/templates/notifications/slack"
printf 'PROJECT-SLACK ${REF_TITLE}\n' > "$SANDBOX/templates/notifications/slack/validator.md"
out="$(render slack validator)"
assert_contains "$out" "PROJECT-SLACK" \
  "project platform override beats the project neutral override"
assert_contains "$out" "# rich:     yes" "a project platform template marks the sink rich"

# ...and only for its own platform: discord still falls through to the project
# neutral override, never to another platform's file.
out="$(render discord validator)"
assert_contains "$out" "PROJECT-NEUTRAL" \
  "a slack/ override does not leak into the discord sink"

rm -rf "$SANDBOX/templates"

# ── (d) --render posts nothing and mutates no thread state ───────────────────
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"; : > "$NAK_LOG"
out="$(SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-1 PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render slack qa "#42" "PASS: 3 criteria verified" 2>&1)"; rc=$?
assert_eq "0" "$rc" "--render exits 0"
assert_contains "$out" "PASS: 3 criteria verified" "--render substitutes the message"
assert_contains "$out" '"type": "section"' "--render prints the real slack payload"
assert_eq "" "$(cat "$CURL_LOG")" "--render posts nothing over curl"
assert_eq "" "$(cat "$NAK_LOG")" "--render publishes nothing over nak"
assert_file_absent "$PIPELINE_THREAD_STATE" "--render writes no thread anchor"

# Each platform renders in its own payload shape.
assert_contains "$(render discord qa)" '"embeds"' "--render discord prints an embed payload"
assert_contains "$(render teams qa)" '"AdaptiveCard"' "--render teams prints an adaptive card"
assert_contains "$(render buzz qa)" '| Field | Value |' "--render buzz prints the GFM card"

# A typo must not quietly preview the neutral template and look like an answer.
out="$(bash "$NOTIFY" --render slak validator "#42" "m" 2>&1)"; rc=$?
assert_eq "2" "$rc" "--render rejects an unknown platform"
assert_contains "$out" "unknown platform 'slak'" "--render names the bad platform"

# notifications.events must not silence a preview -- a filtered pipeline still
# has to be able to inspect its templates.
cat > talos.pipeline.json <<'EOF'
{"notifications": {"events": ["merged"]}}
EOF
assert_contains "$(render slack validator)" "Validator" \
  "--render ignores the notifications.events filter"
rm talos.pipeline.json

# ── (e) Shipped templates reference only documented variables ────────────────
# The README "Notification templates" table is the contract; a template that
# reaches outside it renders a literal ${NAME} into a real notification.
undocumented_vars() {  # $1=dir holding templates/notifications; prints offenders
  SCAN_ROOT="$1" python3 - <<'PY'
import os
import pathlib
import re

# Mirrors the env vars _tmpl_render() exports in pipeline-notify.sh and the
# README "Notification templates" variable table.
allowed = {
    "ICON", "EVENT", "MSG", "REF", "ROLE", "TITLE", "REF_TITLE",
    "PR", "PR_TITLE", "PR_REF", "BOARD", "ISSUE_URL", "PR_URL",
    "REF_LINK", "PR_LINK",
}
root = pathlib.Path(os.environ["SCAN_ROOT"]) / "templates" / "notifications"
bad = []
for f in sorted(root.rglob("*.md")):
    for name in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", f.read_text()):
        if name not in allowed:
            bad.append("{}:${{{}}}".format(f.relative_to(root), name))
print(" ".join(sorted(set(bad))))
PY
}

assert_eq "" "$(undocumented_vars "$TALOS_ROOT")" \
  "every shipped notification template uses only documented variables"

# The guard itself must be able to fail: a template with a bogus variable is
# caught. (Written into the sandbox copy of the shipped set, not the repo.)
printf 'bad ${NOT_A_REAL_VARIABLE}\n' > "$HOME/.talos/templates/notifications/slack/_probe.md"
assert_contains "$(undocumented_vars "$HOME/.talos")" 'slack/_probe.md:${NOT_A_REAL_VARIABLE}' \
  "the variable guard actually fails on an undocumented variable"
rm -f "$HOME/.talos/templates/notifications/slack/_probe.md"

# ── (f) Only documented variables substitute; secrets stay literal ───────────
# A project override template is untrusted input: it must not be able to name
# an exported secret and have its value rendered into an outbound message.
mkdir -p "$SANDBOX/templates/notifications"
printf 'SECRETS ${SLACK_WEBHOOK_URL} ${GITHUB_TOKEN} ok=${REF_TITLE}\n' \
  > "$SANDBOX/templates/notifications/validator.md"
out="$(SLACK_WEBHOOK_URL=https://hooks.example/SUPERSECRETHOOK \
  GITHUB_TOKEN=ghp_SUPERSECRETTOKEN PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render slack validator "#42" "a message" 2>&1)"
assert_not_contains "$out" "SUPERSECRETHOOK" \
  "an exported webhook secret is never substituted into the rendering"
assert_not_contains "$out" "SUPERSECRETTOKEN" \
  "an exported API token is never substituted into the rendering"
assert_contains "$out" '${SLACK_WEBHOOK_URL}' \
  "an undocumented variable renders as the literal \${NAME} the docs promise"
assert_contains "$out" "Fix login crash" \
  "documented variables still substitute"
rm -rf "$SANDBOX/templates"

# ── (g) GFM table cells escape pipes and newlines ────────────────────────────
# Cell values carry repo/issue metadata; a "|" or newline in one would inject
# extra cells/rows and let that text spoof the metadata a reviewer reads.
out="$(PIPELINE_REPO='ow|ner/re|po' PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render buzz qa "#42" "PASS" 2>&1)"
assert_contains "$out" '| Field | Value |' "the buzz card is still a GFM table"
assert_contains "$out" 'ow\|ner/re\|po' "a pipe in a cell value is escaped"
assert_not_contains "$out" '| ow|ner/re|po |' "a pipe never injects extra cells"

out="$(PIPELINE_REPO='owner/repo
INJECTED | row' PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render buzz qa "#42" "PASS" 2>&1)"
assert_contains "$out" 'owner/repo INJECTED \| row' \
  "a newline in a cell value collapses instead of ending the row"
assert_not_contains "$out" 'INJECTED | row' "a newline never injects an extra row"

# ── (h) The monospace grid fallback cannot break out of its code fence ───────
# Slack/Discord/Buzz wrap the fallback grid in a literal ``` fence. A triple-
# backtick run in the comment or in a field value would close that fence early
# and let the rest render as arbitrary markdown in the pipeline's own stream.
_fence='```'
mkdir -p "$SANDBOX/templates/notifications"
# A neutral project template -> rich:no -> the grid fallback, with a clean
# title line so every fence left in the payload belongs to the grid itself.
printf 'Grid probe\n\n${MSG}\n' > "$SANDBOX/templates/notifications/info.md"
for _pl in slack discord buzz; do
  out="$(PIPELINE_REPO="ow${_fence}ner/repo" PIPELINE_ISSUE_TITLE="Fix login crash" \
    bash "$NOTIFY" --render "$_pl" info "#42" "closing ${_fence} then # PWNED" 2>&1)"
  assert_eq "2" "$(printf '%s' "$out" | grep -o -- "$_fence" | wc -l | tr -d ' ')" \
    "$_pl grid keeps exactly one opening and one closing fence"
  assert_not_contains "$out" "closing ${_fence}" \
    "$_pl grid comment cannot close the fence"
  assert_not_contains "$out" "ow${_fence}ner" \
    "$_pl grid field value cannot close the fence"
  assert_contains "$out" "PWNED" "$_pl grid still carries the comment text"
done
rm -rf "$SANDBOX/templates"

finish
