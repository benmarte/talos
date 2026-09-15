#!/usr/bin/env bash
# test-notify-templates.sh -- neutral, transpiled notification templates (#284).
#
# #280/#283 shipped 48 per-platform template files (templates/notifications/
# <platform>/<event>.md) plus a platform-neutral fallback, each sink rendering
# its own file and its own metadata construct. #284 replaced that with ONE
# neutral rich template per event (templates/notifications/<event>.md, 14
# files) and a single transpiler, _neutral_to_platform(), that turns the
# neutral dialect (**bold**, [text](url), "- " bullets, one leading "### "
# heading) into Slack mrkdwn, Discord/Teams markdown, or pass-through GFM for
# Buzz. Per-platform files remain a valid OPTIONAL project override.
#
# Covers:
#   (a) resolution order: project/<platform>/<event>.md -> project/<event>.md
#       -> shipped neutral <event>.md, with each layer winning only for its
#       own platform
#   (b) every shipped neutral template exists (14 files), no shipped
#       per-platform files remain
#   (c) an event with no template anywhere degrades to the plain-text line
#   (d) --render prints a rendering without posting or touching thread state,
#       each platform in its own payload shape, and rejects a typo'd platform
#   (e) the transpiler: one neutral source rendering as Slack mrkdwn, as
#       Discord/Teams markdown, and as Buzz pass-through GFM
#   (f) ${HEADLINE} carries the right per-role icon/label, and "🤖 Talos" for
#       lifecycle events
#   (g) the blocked-event "<stage>:" -> "blocked by <stage>" lift
#   (h) the >160-char semicolon-summary -> bullets transformation
#   (i) SECURITY (#283): only documented variables substitute, so a template
#       naming an exported secret renders the literal ${NAME}, never the
#       value; every SHIPPED template references only documented variables
#   (j) the fallback monospace grid still defuses a triple-backtick run in a
#       field value
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

# ── (a) Resolution order ──────────────────────────────────────────────────────
# With no project overrides, every platform resolves the shipped neutral file.
out="$(render slack validator)"
assert_contains "$out" "templates/notifications/validator.md" \
  "no override -> the shipped neutral template resolves"
assert_not_contains "$out" "/slack/validator.md" \
  "no shipped platform file exists to resolve"
assert_contains "$out" "# rich:     yes" \
  "a resolved template (neutral or override) marks the sink rich"

# A project-level neutral override beats the shipped neutral template.
mkdir -p "$SANDBOX/templates/notifications"
printf 'PROJECT-NEUTRAL ${REF_TITLE}\n' > "$SANDBOX/templates/notifications/validator.md"
out="$(render slack validator)"
assert_contains "$out" "PROJECT-NEUTRAL #42 Fix login crash" \
  "project neutral override beats the shipped neutral template"
assert_not_contains "$out" "$HOME/.talos/templates" \
  "the shipped template path is not the one resolved once overridden"

# A project platform-specific override beats the project's own neutral one --
# and only for its own platform.
mkdir -p "$SANDBOX/templates/notifications/slack"
printf 'PROJECT-SLACK ${REF_TITLE}\n' > "$SANDBOX/templates/notifications/slack/validator.md"
out="$(render slack validator)"
assert_contains "$out" "PROJECT-SLACK #42 Fix login crash" \
  "project platform override beats the project neutral override"
assert_contains "$out" "/templates/notifications/slack/validator.md" \
  "the resolved template path names the platform override"
assert_not_contains "$out" "$HOME/.talos" \
  "the resolved path is the project override, not the shipped install"

out="$(render discord validator)"
assert_contains "$out" "PROJECT-NEUTRAL #42 Fix login crash" \
  "a slack/ override does not leak into the discord sink"
assert_not_contains "$out" "PROJECT-SLACK" \
  "discord never sees another platform's override"

rm -rf "$SANDBOX/templates"

# ── (b) Every shipped neutral template exists; no shipped platform files ─────
for _ev in blocked developer dispatched docs info issue-closed merged \
           orchestrator pm pr-opened qa reviewer security validator; do
  assert_file_exists "$TALOS_ROOT/templates/notifications/$_ev.md" \
    "shipped neutral template exists: $_ev.md"
done
for _pl in slack discord teams buzz; do
  assert_file_absent "$TALOS_ROOT/templates/notifications/$_pl" \
    "no shipped per-platform directory remains: $_pl/"
done

# ── (c) No template anywhere degrades to the plain-text line ─────────────────
out="$(render slack some-unknown-event)"
assert_contains "$out" "# template: (none" "unknown event resolves no template"
assert_contains "$out" "# rich:     no" "an unresolved template is never marked rich"
assert_contains "$out" "[talos] some-unknown-event" "unknown event falls back to plain text"

# ── (d) --render posts nothing and mutates no thread state ───────────────────
rm -f "$PIPELINE_THREAD_STATE"; : > "$CURL_LOG"; : > "$NAK_LOG"
out="$(SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
  BUZZ_RELAY_URL=ws://localhost:3000 BUZZ_BOT_PRIVATE_KEY=deadbeef \
  PIPELINE_BUZZ_CHANNEL=chan-1 PIPELINE_ISSUE_TITLE="Fix login crash" \
  bash "$NOTIFY" --render slack qa "#42" "PASS: 3 criteria verified" 2>&1)"; rc=$?
assert_eq "0" "$rc" "--render exits 0"
assert_contains "$out" "3 criteria verified" "--render substitutes the message"
assert_contains "$out" '"type": "section"' "--render prints the real slack payload"
assert_eq "" "$(cat "$CURL_LOG")" "--render posts nothing over curl"
assert_eq "" "$(cat "$NAK_LOG")" "--render publishes nothing over nak"
assert_file_absent "$PIPELINE_THREAD_STATE" "--render writes no thread anchor"

# Each platform renders in its own payload shape.
assert_contains "$(render discord qa)" '"embeds"' "--render discord prints an embed payload"
assert_contains "$(render teams qa)" '"AdaptiveCard"' "--render teams prints an adaptive card"
buzz_out="$(render buzz qa)"
assert_contains "$buzz_out" "acme/widget" \
  "--render buzz appends the compact repo footer"
assert_not_contains "$buzz_out" '| Field | Value |' \
  "buzz no longer renders a GFM metadata table (#284 removed _gfm_table)"

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

# ── (e) The transpiler: one neutral source, per-sink syntax ──────────────────
mkdir -p "$SANDBOX/templates/notifications"
printf '### Heading text\n\n**Bold text** and [a link](https://example.com/x)\n\n- bullet one\n- bullet two\n' \
  > "$SANDBOX/templates/notifications/info.md"

slack_out="$(render slack info)"
assert_contains "$slack_out" "*Heading text*" "slack: a heading becomes a bold line"
assert_contains "$slack_out" "*Bold text*" "slack: **bold** becomes *bold*"
assert_contains "$slack_out" "<https://example.com/x|a link>" "slack: [text](url) becomes <url|text>"
assert_contains "$slack_out" "• bullet one" "slack: a \"- \" bullet becomes \"• \""
assert_not_contains "$slack_out" "###" "slack never sees a literal markdown heading"

discord_out="$(render discord info)"
assert_contains "$discord_out" "**Bold text**" "discord: bold stays CommonMark **bold**"
assert_contains "$discord_out" "[a link](https://example.com/x)" "discord: links stay markdown"
assert_contains "$discord_out" "- bullet one" "discord: \"- \" bullets are kept verbatim"
assert_not_contains "$discord_out" "###" "discord never renders the raw heading marker"

teams_out="$(render teams info)"
assert_contains "$teams_out" "**Heading text**" "teams: a heading becomes a bold TextBlock line"
assert_contains "$teams_out" "**Bold text**" "teams: bold stays CommonMark **bold**"
assert_contains "$teams_out" "[a link](https://example.com/x)" "teams: links stay markdown"

buzz_out="$(render buzz info)"
assert_contains "$buzz_out" "### Heading text" "buzz: the real GFM heading passes through unchanged"
assert_contains "$buzz_out" "**Bold text**" "buzz: bold passes through unchanged"
assert_contains "$buzz_out" "[a link](https://example.com/x)" "buzz: links pass through unchanged"
assert_contains "$buzz_out" "- bullet one" "buzz: bullets pass through unchanged"

rm -rf "$SANDBOX/templates"

# ── (f) ${HEADLINE}: per-role icon/label, and lifecycle events speak as Talos ─
# Rendered via buzz, which passes the neutral dialect through unchanged, so the
# double-asterisk bold from HEADLINE's own assembly is visible verbatim. The
# gh stub always resolves a repo URL, so with a numeric ref (#42) the ref
# itself is a link -- see the dedicated link-vs-plain-degrade block below for
# that behavior in isolation.
assert_contains "$(render buzz validator)" \
  "🔎 **Validator** — update · [#42](https://github.com/acme/widget/issues/42)" \
  "validator headline: role icon + label"
assert_contains "$(render buzz pm)" \
  "📝 **PM** — spec posted · [#42](https://github.com/acme/widget/issues/42)" \
  "pm headline: role icon + label, action fallback"
assert_contains "$(render buzz developer)" \
  "🛠 **Developer** — update · [#42](https://github.com/acme/widget/issues/42)" \
  "developer headline: role icon + label"
assert_contains "$(render buzz qa)" \
  "🧪 **QA** — update · [#42](https://github.com/acme/widget/issues/42)" \
  "qa headline: role icon + label"
assert_contains "$(render buzz reviewer)" \
  "👀 **Reviewer** — update · [#42](https://github.com/acme/widget/issues/42)" \
  "reviewer headline: role icon + label"
assert_contains "$(render buzz security)" \
  "🔐 **Security** — update · [#42](https://github.com/acme/widget/issues/42)" \
  "security headline: role icon + label"
assert_contains "$(render buzz docs)" \
  "📚 **Docs** — docs updated · [#42](https://github.com/acme/widget/issues/42)" \
  "docs headline: role icon + label, action fallback"
assert_contains "$(render buzz dispatched)" \
  "🤖 **Talos** — dispatched · [#42](https://github.com/acme/widget/issues/42)" \
  "lifecycle event (dispatched) speaks as 🤖 Talos, not a role"
assert_contains "$(render buzz merged)" "🤖 **Talos**" \
  "lifecycle event (merged) speaks as 🤖 Talos"

# The headline's ref link is assembled in bash and transpiled like any other
# link: Slack gets <url|text>, discord/teams/buzz keep [text](url).
assert_contains "$(render slack validator)" \
  "· <https://github.com/acme/widget/issues/42|#42>" \
  "slack transpiles the headline ref to <url|text>"
assert_contains "$(render teams validator)" \
  "· [#42](https://github.com/acme/widget/issues/42)" \
  "teams keeps the headline ref as [text](url)"

# When no URL is resolvable, the ref degrades to PLAIN text -- never an empty
# link "[ref]()". HEADLINE_REF is assembled before _neutral_to_platform() runs
# specifically so the ref does not fall into the " · [text]()" pattern that
# tidier deletes outright (the same deletion that makes an absent ${PR}
# vanish cleanly from a template). A ref with no digits has no issue/PR
# number to link, so PRIMARY_URL is empty.
out="$(render buzz validator none "a message")"
assert_contains "$out" "🔎 **Validator** — update · none" \
  "no resolvable URL -> the ref degrades to plain text"
assert_not_contains "$out" "[none](" "an unresolvable ref never renders an empty link"
assert_not_contains "$out" "· [none]" "an unresolvable ref never renders bracketed at all"

# ── (g) blocked: a leading "<stage>: " is lifted into "blocked by <stage>" ───
out="$(render buzz blocked "#42" "qa: three test cases fail on staging")"
assert_contains "$out" \
  "blocked by qa · [#42](https://github.com/acme/widget/issues/42)" \
  "blocked headline names the blocking stage"
assert_contains "$out" "three test cases fail on staging" \
  "the stage prefix is stripped from the body"
assert_not_contains "$out" "qa: three test cases fail" \
  "the raw \"<stage>: \" prefix does not survive in the body"

# ── (h) A long, single-line, semicolon-joined summary becomes bullets ────────
LONG_MSG="PASS: Verified login flow end to end successfully; Checked token refresh path thoroughly under sustained load; Confirmed session invalidation works correctly on logout; Regression suite is fully green across all supported browsers"
out="$(render buzz qa "#42" "$LONG_MSG")"
assert_contains "$out" "Verified login flow end to end successfully" \
  "the lead clause stays a plain sentence"
assert_contains "$out" "- Checked token refresh path thoroughly under sustained load" \
  "later clauses become \"- \" bullets"
assert_contains "$out" "- Confirmed session invalidation works correctly on logout" \
  "every later clause gets its own bullet"
assert_contains "$out" "- Regression suite is fully green across all supported browsers" \
  "the final clause is bulleted too"
assert_not_contains "$out" "end to end successfully; Checked token refresh" \
  "the semicolon-joined single line does not survive the split"

# A short summary with only one "; " is left as one line even past 160 chars.
SHORT_MSG="PASS: short summary; another clause that is reasonably long to pad the length past one hundred sixty characters total for this check to be meaningful"
out="$(render buzz qa "#42" "$SHORT_MSG")"
assert_contains "$out" "short summary; another clause that is reasonably long" \
  "fewer than two \"; \" separators is not enough to trigger bulleting"
assert_not_contains "$out" $'\n- another clause' \
  "a single-separator summary is never bulleted"

# ── (i) Only documented variables substitute; secrets stay literal ───────────
# The set of variables _tmpl_render() actually exports (pipeline-notify.sh);
# this is the contract shipped templates and this guard are both held to.
undocumented_vars() {  # $1=dir holding templates/notifications; prints offenders
  SCAN_ROOT="$1" python3 - <<'PY'
import os
import pathlib
import re

allowed = {
    "ICON", "REF", "MSG", "EVENT", "ROLE", "TITLE", "REF_TITLE",
    "PR", "PR_TITLE", "PR_REF", "BOARD", "ISSUE_URL", "PR_URL",
    "REF_LINK", "PR_LINK", "VERDICT", "SUMMARY", "HEADLINE",
    "ROLE_ICON", "ROLE_LABEL", "REPO",
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
# caught. (Written into the sandbox copy of the shipped set, not the repo --
# #284 ships no per-platform subdirectory, so the probe lives at the top level.)
printf 'bad ${NOT_A_REAL_VARIABLE}\n' > "$HOME/.talos/templates/notifications/_probe.md"
assert_contains "$(undocumented_vars "$HOME/.talos")" '_probe.md:${NOT_A_REAL_VARIABLE}' \
  "the variable guard actually fails on an undocumented variable"
rm -f "$HOME/.talos/templates/notifications/_probe.md"

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

# ── (j) The fallback monospace grid still defuses a triple-backtick run ──────
# Slack/Discord/Buzz wrap the fallback grid in a literal ``` fence, used when
# no template resolves for an event at all. A triple-backtick run in a field
# value (here: the repo, attacker/agent-influenced via PIPELINE_REPO) would
# close that fence early and let the rest render as arbitrary markdown in the
# pipeline's own stream.
_fence='```'
for _pl in slack discord buzz; do
  out="$(PIPELINE_REPO="ow${_fence}ner/repo" PIPELINE_ISSUE_TITLE="Fix login crash" \
    bash "$NOTIFY" --render "$_pl" some-unknown-event "#42" \
    "no backticks in this comment, just PWNED text" 2>&1)"
  assert_eq "2" "$(printf '%s' "$out" | grep -o -- "$_fence" | wc -l | tr -d ' ')" \
    "$_pl grid keeps exactly one opening and one closing fence"
  assert_not_contains "$out" "ow${_fence}ner" \
    "$_pl grid field value cannot close the fence"
  assert_contains "$out" "PWNED" "$_pl grid still carries the comment text"
done

# The plain-text fallback line itself (built from MSG as TEXT_PLAIN) sits
# right next to the grid's fence on Slack/Discord, and inside the Buzz
# "### " heading directly above it -- so a fence-breaking MSG is the other
# half of this threat model, previously unguarded: TEXT_PLAIN was never
# defused, only the grid's own cell() values were. Now fixed at TEXT_PLAIN's
# construction; pin it so it cannot regress.
for _pl in slack discord buzz; do
  out="$(PIPELINE_ISSUE_TITLE="Fix login crash" \
    bash "$NOTIFY" --render "$_pl" some-unknown-event "#42" \
    "closing ${_fence} then # PWNED" 2>&1)"
  assert_eq "2" "$(printf '%s' "$out" | grep -o -- "$_fence" | wc -l | tr -d ' ')" \
    "$_pl plain-text fallback (MSG) cannot break out of the grid's own fence"
  assert_not_contains "$out" "closing ${_fence} then" \
    "$_pl the raw MSG fence run is defused, not left literal"
  assert_contains "$out" "PWNED" "$_pl still carries the MSG text after defusal"
done

finish
