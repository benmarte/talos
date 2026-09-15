#!/usr/bin/env bash
# pipeline-notify.sh — post a pipeline event to Slack, Discord, Teams, and/or Buzz.
#
# Usage: pipeline-notify.sh <event> <ref> <message> [thread_key]
#        pipeline-notify.sh --render <platform> <event> [ref] [message]
#   event       pr-opened | merged | blocked | issue-closed | info
#   ref         issue/PR identifier shown in the message (e.g. "#42")
#   message     free text describing the event
#   thread_key  optional; used to group all events for one issue into a single
#               platform thread. Pass the issue number (e.g. "42"). Defaults to
#               <ref>. Orchestrator should always pass the issue number so PR
#               events and validator events land in the same thread.
#
# Templates (#280, reshaped in #284):
#   ONE neutral template per event, written once in a small markdown dialect
#   (**bold**, [text](url), "- " bullets, blank-line paragraphs, at most one
#   leading "### " heading) and transpiled per sink by _neutral_to_platform():
#     slack   **bold** -> *bold*, [text](url) -> <url|text>, "- " -> "• ",
#             a heading becomes a bold line
#     discord native markdown; a heading becomes a bold line (embeds have none)
#     teams   the heading/first line is the card's Bolder TextBlock, the body a
#             wrapping TextBlock; links stay markdown
#     buzz    pass-through GFM
#   Per-platform files are an OPTIONAL project override for hand-tuning one
#   sink; Talos itself ships none. Resolution per platform, first hit wins:
#     project/<platform>/<event>.md -> project/<event>.md
#       -> install/<platform>/<event>.md -> install/<event>.md
#   The project copy wins at BOTH layers, so a repo that already overrides
#   <templates_dir>/<event>.md keeps winning over a shipped platform file.
#   A sink is "rich" (native metadata instead of the monospace grid) whenever a
#   template resolved at all. The grid remains only for notifications.cmd and
#   for a project that has deleted its templates.
#
#   Layout every template follows (#284):
#     line 1  ${HEADLINE}  — "🧪 **QA** — PASS · #42": which agent, then its
#             verdict (or, with no verdict token, what it did)
#     line 2  ${REF_LINK}  — the title, ONCE; dropped automatically on thread
#             replies, where the root above already carries it
#     body    ${SUMMARY}   — never fenced
#     footer  native fields on slack/discord/teams; one compact
#             "repo · [PR #n](url)" line on buzz
#
#   --render <platform> <event> prints the payload that platform would send and
#   exits 0 without posting or touching thread state. Platform is one of
#   slack | discord | teams | buzz | default (the platform-neutral rendering);
#   anything else is a usage error on stderr with exit 2 -- the one place this
#   script does not exit 0, because a preview is interactive, not delivery.
#
# Delivery order (first match wins per platform):
#   1. Incoming webhook env vars:
#        SLACK_WEBHOOK_URL / DISCORD_WEBHOOK_URL / TEAMS_WEBHOOK_URL
#        (set in env or in <repo>/.env)
#   2. Config file channels + bot tokens from ~/.hermes/.env:
#        SLACK_BOT_TOKEN / DISCORD_BOT_TOKEN posting to configured channels.
#        Channels from talos.pipeline.yml notifications.slack_channel /
#        notifications.discord_channel, overrideable via env vars
#        PIPELINE_SLACK_CHANNEL / PIPELINE_DISCORD_CHANNEL.
#
# Buzz (https://github.com/block/buzz — Nostr/NIP-29 relay, no webhooks):
#   Publishes a signed kind:9 event tagged ["h", <channel-uuid>] via the `nak`
#   CLI (brew install nak), which also answers the relay's NIP-42 AUTH.
#   Requires all three of: BUZZ_RELAY_URL (ws[s]://…), BUZZ_BOT_PRIVATE_KEY
#   (hex or nsec; env, repo .env, or ~/.hermes/.env), and a channel UUID from
#   notifications.buzz_channel / PIPELINE_BUZZ_CHANNEL. Threading uses NIP-10
#   reply tags ["e", <root-id>, "", "reply"] with the anchor persisted as
#   buzz_event_id. The bot key reaches nak through NOSTR_SECRET_KEY, never on
#   argv (`ps` would expose it). Each nak call is bounded by
#   notifications.buzz_timeout_s (default 15s, positive integer) — a relay that
#   never answers logs one stderr line and writes no anchor. If buzz is
#   configured but nak is missing, buzz is skipped with a warning; the pipeline
#   never breaks.
#
# Threading (bot-token mode only; Buzz always threads — it is key-based):
#   When notifications.threading = true (default) and a bot token is in use,
#   all events sharing the same thread_key post as replies to the first message
#   (Slack thread_ts / Discord message_reference). Anchors are persisted in
#   ${PIPELINE_THREAD_STATE:-$HOME/.talos/threads.json}.
#   Webhook mode CANNOT thread — Slack incoming webhooks have no thread_ts
#   and Discord webhooks do not support message_reference. Threading is
#   silently skipped in webhook mode.
#
# Generic command sink (notifications.cmd, #184):
#   Runs an arbitrary shell command (via `sh -c`) for any sink the four
#   platforms above don't cover -- a local desktop notifier, a webhook
#   relay, a log shipper. Disabled by default (empty string). Runs last,
#   after Slack/Discord/Teams/Buzz, and never blocks them or the caller.
#   The command receives a JSON object on stdin:
#     {event, ref, message, thread_key, fields:[{label,text,url}], repo, issue}
#   message is the same rendered text every other sink builds its message
#   from; fields is the same platform-neutral metadata table (PR/Issue/
#   Stage/Repo) the other sinks render natively. Bounded by
#   notifications.cmd_timeout_s (default 10s, positive integer). A missing
#   command, non-zero exit, or timeout logs one line to stderr; this script
#   still exits 0.
#
# Debug mode:
#   PIPELINE_NOTIFY_DEBUG=1 — prints the payload each platform WOULD send
#   without actually posting or updating thread state. Safe for testing.
#
# Event filtering: only events listed in notifications.events (config) are sent.
# Default when no config: all events pass through.
#
# Silent no-op for any platform with no credentials.
# Always exits 0 — a notification failure must never break the pipeline.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pipeline-paths.sh
. "$SCRIPT_DIR/pipeline-paths.sh"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh, so fall back
# to the old per-call cfg() instead of leaving cfg undefined.
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "pipeline: config cache helper missing, falling back to per-call parsing" >&2
fi
# pipeline-lock.sh (#180): portable mkdir-based locking so concurrent
# stages (issues.max_parallel > 1) don't lose entries doing a
# read-modify-write on threads.json at the same time. Guarded the same way
# as pipeline-cfg-cache.sh above: a partial install may not ship it yet, so
# fall back to running unlocked with a warning instead of failing outright.
if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 2; [ "${1:-}" = "--" ] && shift; "$@"; }
  echo "pipeline: lock helper missing, thread-state writes are unsynchronized" >&2
fi

EVENT="${1:-info}"
REF="${2:-}"
MSG="${3:-}"
THREAD_KEY="${4:-$REF}"

# ── --render: preview a template without posting (#280) ──────────────────────
# `pipeline-notify.sh --render <platform> <event> [ref] [message]` resolves the
# template the given platform would use, renders it, and prints the payload
# that platform would send. It exits before any sink runs, so nothing is posted
# and no thread anchor is read or written. Platform "default" previews the
# platform-neutral template (the one notifications.cmd receives).
RENDER_ONLY=""
if [ "$EVENT" = "--render" ]; then
  RENDER_ONLY="${2:-default}"
  EVENT="${3:-info}"
  REF="${4:-#0}"
  MSG="${5:-Sample message body for template preview.}"
  THREAD_KEY="$REF"
fi

# ── Load repo .env if present ─────────────────────────────────────────────────
# NOTE: REPO_ROOT keeps its current meaning (script-relative install dir)
# because line 152 uses it for the bundled template fallback path.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ENV_ROOT" ] && ENV_ROOT="$PWD"
REPO_ENV="$ENV_ROOT/.env"
# Load repo .env with dotenv precedence: exported env vars win over .env values.
# Bash 3.2-compatible — no namerefs, no associative arrays.
if [ -f "$REPO_ENV" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      ""|"#"*) continue ;;  # skip blanks and comments
    esac
    _key="${_line%%=*}"
    _val="${_line#*=}"
    # Strip a single pair of matching surrounding quotes (double or single)
    case "$_val" in
      '"'*'"') _val="${_val#'"'}"; _val="${_val%'"'}" ;;
      "'"*"'") _val="${_val#"'"}"; _val="${_val%"'"}" ;;
    esac
    # Only set if the variable is currently unset
    if [ -z "${!_key+x}" ]; then
      # shellcheck disable=SC2163
      export "$_key=$_val"
    fi
  done < "$REPO_ENV"
  unset _line _key
fi
unset REPO_ENV ENV_ROOT

# ── Event filter (from config) ────────────────────────────────────────────────
CONFIGURED_EVENTS="$(cfg notifications.events "")"
if [ -n "$CONFIGURED_EVENTS" ] && [ -z "$RENDER_ONLY" ]; then
  if ! printf '%s' "$CONFIGURED_EVENTS" | grep -qxF "$EVENT"; then
    exit 0
  fi
fi

# ── Channel config with env var overrides ─────────────────────────────────────
SLACK_CHANNEL="${PIPELINE_SLACK_CHANNEL:-$(cfg notifications.slack_channel "")}"
DISCORD_CHANNEL="${PIPELINE_DISCORD_CHANNEL:-$(cfg notifications.discord_channel "")}"
BUZZ_CHANNEL="${PIPELINE_BUZZ_CHANNEL:-$(cfg notifications.buzz_channel "")}"

# ── Bot tokens from Hermes env (optional convenience) ─────────────────────────
HERMES_ENV="$HOME/.hermes/.env"
if [ -f "$HERMES_ENV" ]; then
  [ -z "${SLACK_BOT_TOKEN:-}" ]   && SLACK_BOT_TOKEN="$(grep -m1 '^SLACK_BOT_TOKEN='   "$HERMES_ENV" | cut -d= -f2-)"
  [ -z "${DISCORD_BOT_TOKEN:-}" ] && DISCORD_BOT_TOKEN="$(grep -m1 '^DISCORD_BOT_TOKEN=' "$HERMES_ENV" | cut -d= -f2-)"
  [ -z "${BUZZ_RELAY_URL:-}" ]        && BUZZ_RELAY_URL="$(grep -m1 '^BUZZ_RELAY_URL='        "$HERMES_ENV" | cut -d= -f2-)"
  [ -z "${BUZZ_BOT_PRIVATE_KEY:-}" ]  && BUZZ_BOT_PRIVATE_KEY="$(grep -m1 '^BUZZ_BOT_PRIVATE_KEY=' "$HERMES_ENV" | cut -d= -f2-)"
fi

# The Buzz relay URL is NOT a secret — it is a hostname, and it identifies a
# deployment the same way buzz_channel does. Unlike the bot key (a full Nostr
# signing identity, which must never enter a git-tracked file) it belongs in
# the committed config, so a clone can describe its Buzz setup completely.
# Precedence: exported env > repo/hermes .env > config file.
[ -z "${BUZZ_RELAY_URL:-}" ] && BUZZ_RELAY_URL="${PIPELINE_BUZZ_RELAY:-$(cfg notifications.buzz_relay "")}"

# ── API fallback for gh metadata lookups ──────────────────────────────────────
# When gh is absent and a GitHub token is available, fetch issue/PR titles and
# repo URL via REST. When both are absent, leaves variables empty (graceful).
_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
_api_lookup_gh_metadata() {
  # $1=type (issue|pr|repo), $2=number (for issue/pr), $3=repo (owner/name)
  local _type="$1" _num="${2:-}" _repo="${3:-}"
  [ -z "$_API_TOKEN" ] && return
  [ -z "$_repo" ] && return
  local _url
  case "$_type" in
    issue) _url="https://api.github.com/repos/$_repo/issues/$_num" ;;
    pr)    _url="https://api.github.com/repos/$_repo/pulls/$_num" ;;
    repo)  _url="https://api.github.com/repos/$_repo" ;;
    *)     return ;;
  esac
  curl -sS -m 5 \
    -H "Authorization: Bearer $_API_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$_url" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    t = '$_type'
    if t == 'repo':
        print(d.get('html_url',''))
    else:
        print(d.get('title',''))
except Exception:
    pass
" 2>/dev/null || true
}

# ── Enrich context for Daedalus-style templates (best-effort; empty on failure) ─
# Role label — mirrors daedalus core/notify_templates._ROLE_LABELS.
case "$EVENT" in
  validator)          ROLE="validator" ;;
  pm)                 ROLE="project-manager" ;;
  developer)          ROLE="developer" ;;
  qa)                 ROLE="qa" ;;
  reviewer)           ROLE="reviewer" ;;
  security)           ROLE="security-analyst" ;;
  docs|documentation) ROLE="documentation" ;;
  orchestrator)       ROLE="orchestrator" ;;
  *)                  ROLE="$EVENT" ;;
esac

# Detect repo slug for API fallback (owner/name without .git)
_NOTIFY_REPO="${PIPELINE_REPO:-}"
if [ -z "$_NOTIFY_REPO" ]; then
  _NOTIFY_REPO="$(git -C "$PWD" remote get-url origin 2>/dev/null \
    | sed 's|.*github\.com[:/]||; s|\.git$||' || true)"
fi

# Repo slug: namespaces thread anchors so multiple repos don't collide, and is
# the fallback for ${REPO} when the owner/name lookup finds nothing. Derived
# here rather than further down because the template layer (#284) needs it.
REPO_SLUG="$(git -C "$PWD" remote get-url origin 2>/dev/null \
  | python3 -c "
import sys, re
url = sys.stdin.read().strip()
url = re.sub(r'\.git$', '', url)
url = re.sub(r'^https?://(www\.)?', '', url)
url = re.sub(r'^git@([^:]+):', r'\1/', url)
parts = [p for p in url.split('/') if p]
print('-'.join(parts[-2:]) if len(parts) >= 2 else url.replace('/', '-'))
" 2>/dev/null)" || true
[ -z "${REPO_SLUG:-}" ] && REPO_SLUG="default"

# ${REPO} (#284): the owner/name a human recognises, for the compact footer.
REPO="${_NOTIFY_REPO:-$REPO_SLUG}"

# Board name (owner-repo). Override with PIPELINE_BOARD.
BOARD="${PIPELINE_BOARD:-}"
[ -z "$BOARD" ] && BOARD="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-')"
[ -z "$BOARD" ] && BOARD="$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"

# Issue number + title. Prefer caller-supplied PIPELINE_ISSUE_TITLE; else fetch.
_num="$(printf '%s' "${REF:-$THREAD_KEY}" | tr -cd '0-9')"
TITLE="${PIPELINE_ISSUE_TITLE:-}"
if [ -z "$TITLE" ] && [ -n "$_num" ]; then
  if command -v gh >/dev/null 2>&1; then
    TITLE="$(gh issue view "$_num" --json title -q .title 2>/dev/null || true)"
  elif [ -n "$_API_TOKEN" ] && [ -n "$_NOTIFY_REPO" ]; then
    TITLE="$(_api_lookup_gh_metadata issue "$_num" "$_NOTIFY_REPO")"
  fi
fi
REF_DISP="${REF:-#$_num}"
# "#42 Fix login crash", not "#42: Fix login crash" (#284): the title line is
# read as one phrase now that it appears exactly once, and the colon read as a
# label separator against the verdict-first headline above it.
if [ -n "$TITLE" ]; then REF_TITLE="$REF_DISP $TITLE"; else REF_TITLE="$REF_DISP"; fi

# PR number + title. Prefer PIPELINE_PR/PIPELINE_PR_TITLE; else parse MSG, then fetch.
PR="${PIPELINE_PR:-}"
[ -z "$PR" ] && PR="$(printf '%s' "$MSG" | grep -oE '(pull/|PR #?)[0-9]+' | grep -oE '[0-9]+' | head -1)"
PR_TITLE="${PIPELINE_PR_TITLE:-}"
if [ -z "$PR_TITLE" ] && [ -n "$PR" ]; then
  if command -v gh >/dev/null 2>&1; then
    PR_TITLE="$(gh pr view "$PR" --json title -q .title 2>/dev/null || true)"
  elif [ -n "$_API_TOKEN" ] && [ -n "$_NOTIFY_REPO" ]; then
    PR_TITLE="$(_api_lookup_gh_metadata pr "$PR" "$_NOTIFY_REPO")"
  fi
fi
if [ -n "$PR" ]; then
  if [ -n "$PR_TITLE" ]; then PR_REF="PR #$PR: $PR_TITLE"; else PR_REF="PR #$PR"; fi
else
  PR_REF="$REF_DISP"
fi

# Issue/PR URLs so messages can link back to GitHub. Override with PIPELINE_REPO_URL.
REPO_URL="${PIPELINE_REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  if command -v gh >/dev/null 2>&1; then
    REPO_URL="$(gh repo view --json url -q .url 2>/dev/null || true)"
  elif [ -n "$_API_TOKEN" ] && [ -n "$_NOTIFY_REPO" ]; then
    REPO_URL="$(_api_lookup_gh_metadata repo "" "$_NOTIFY_REPO")"
  fi
fi
ISSUE_URL=""
[ -n "$REPO_URL" ] && [ -n "$_num" ] && ISSUE_URL="$REPO_URL/issues/$_num"
PR_URL=""
[ -n "$REPO_URL" ] && [ -n "$PR" ] && PR_URL="$REPO_URL/pull/$PR"

# Linked variants for templates: [#42: Title](url). Plain text when no URL.
REF_LINK="$REF_TITLE"
[ -n "$ISSUE_URL" ] && REF_LINK="[$REF_TITLE]($ISSUE_URL)"
PR_LINK="$PR_REF"
[ -n "$PR_URL" ] && PR_LINK="[$PR_REF]($PR_URL)"

# URL the whole message should point at: PR for PR events, issue otherwise.
case "$EVENT" in
  pr-opened|merged) PRIMARY_URL="${PR_URL:-$ISSUE_URL}" ;;
  *)                PRIMARY_URL="${ISSUE_URL:-$PR_URL}" ;;
esac

# ── Build message text ────────────────────────────────────────────────────────
case "$EVENT" in
  merged)       ICON="✅" ;;
  pr-opened)    ICON="🔀" ;;
  blocked)      ICON="🛑" ;;
  issue-closed) ICON="🏁" ;;
  # Per-role icons (#280): role events used to all resolve to the generic
  # ℹ️, so a template could not tell validator from security via ${ICON}.
  validator)    ICON="🔎" ;;
  pm)           ICON="📋" ;;
  developer)    ICON="🛠" ;;
  qa)           ICON="🧪" ;;
  reviewer)     ICON="👀" ;;
  security)     ICON="🔐" ;;
  docs)         ICON="📚" ;;
  orchestrator) ICON="🤖" ;;
  dispatched)   ICON="🧵" ;;
  *)            ICON="ℹ️"  ;;
esac

TEXT_PLAIN="$ICON [talos] $EVENT $REF — $MSG${PRIMARY_URL:+ ($PRIMARY_URL)}"

# $MSG is caller-supplied, and when no template resolves this line is what the
# sinks render: on Slack/Discord immediately above the monospace grid's literal
# triple-backtick fence, on Buzz inside the "### " heading directly above it.
# A bare 3+ backtick run in it therefore closes that fence early and renders
# everything after as arbitrary markdown -- the same break-out that
# _build_grid's cell() and _tmpl_render()'s defuse() already close for every
# other value, left open on the one path meant to be the safe default. Split
# the run with zero-width spaces: it reads the same and no longer delimits.
# Written \x60 because a literal backtick inside $( … ) is command
# substitution to bash and breaks the parse of the whole file.
TEXT_PLAIN="$(TP="$TEXT_PLAIN" python3 -c 'import os,re,sys; sys.stdout.write(re.sub(r"\x60{3,}", lambda m: chr(0x200b).join(m.group(0)), os.environ["TP"]))' 2>/dev/null || printf '%s' "$TEXT_PLAIN")"

# ── Verdict-first headline (#284) ────────────────────────────────────────────
# Agents open their message with a verdict token ("PASS: 9/9 criteria…",
# "FINDINGS — High: …"). Buried mid-paragraph it is unreadable in a channel, so
# the token is lifted out of ${MSG} into ${VERDICT} and the remainder becomes
# ${SUMMARY}. When nothing matches, ${VERDICT} is empty and ${SUMMARY} is the
# whole message, unchanged.
#
# WHO said it comes first: in a thread carrying eight stages, the reader's
# first question is which agent is speaking, and a bare verdict token does not
# answer it. ${ROLE_ICON}/${ROLE_LABEL} are a fixed per-role pair so the same
# agent always looks the same; every lifecycle event is Talos itself speaking.
case "$EVENT" in
  validator)          ROLE_ICON="🔎"; ROLE_LABEL="Validator" ;;
  pm)                 ROLE_ICON="📝"; ROLE_LABEL="PM" ;;
  developer)          ROLE_ICON="🛠"; ROLE_LABEL="Developer" ;;
  qa)                 ROLE_ICON="🧪"; ROLE_LABEL="QA" ;;
  reviewer)           ROLE_ICON="👀"; ROLE_LABEL="Reviewer" ;;
  security)           ROLE_ICON="🔐"; ROLE_LABEL="Security" ;;
  docs|documentation) ROLE_ICON="📚"; ROLE_LABEL="Docs" ;;
  planner)            ROLE_ICON="🗺"; ROLE_LABEL="Planner" ;;
  adversarial)        ROLE_ICON="😈"; ROLE_LABEL="Adversarial" ;;
  *)                  ROLE_ICON="🤖"; ROLE_LABEL="Talos" ;;
esac

# What that agent DID, used when the message carries no verdict token.
case "$EVENT" in
  pr-opened)          NACTION="PR opened" ;;
  merged)             NACTION="merged" ;;
  blocked)            NACTION="blocked" ;;
  issue-closed)       NACTION="issue closed" ;;
  dispatched)         NACTION="dispatched" ;;
  info)               NACTION="info" ;;
  pm)                 NACTION="spec posted" ;;
  docs|documentation) NACTION="docs updated" ;;
  *)                  NACTION="update" ;;
esac

# Emits the verdict on line 1 and the summary (which may itself be multi-line)
# from line 2 on.
_VERDICT_SPLIT="$(MSG="$MSG" python3 - <<'PY'
import os, re

TOKENS = (
    'RESTAMP_PASS', 'RESTAMP_FAIL', 'CONFIRMED', 'APPROVED', 'FINDINGS',
    'CHANGES', 'BLOCKED', 'MERGED', 'CLOSED', 'CLEAR', 'PASS', 'FAIL', 'DONE',
)
msg = os.environ.get('MSG', '')
# Separator set is deliberately narrow: ":" (optionally spaced), " — ", " - ".
# "PASSING the baton" must not read as a PASS verdict, and neither must
# "FAIL-safe defaults" — hence the required space around the dashes.
m = re.match(
    r'^[ \t]*(' + '|'.join(TOKENS) + r')(?:[ \t]*:|[ \t]+[—-])[ \t]*(.*)$',
    msg, re.S | re.I)
if m:
    verdict, summary = m.group(1).upper(), m.group(2)
else:
    verdict, summary = '', msg
summary = summary.strip()

# Readability: one unbroken 200-character line of semicolon-joined clauses is a
# wall of text in a chat client. Long, single-line, multi-clause summaries only
# — a short one reads fine as a sentence and a multi-line one is already
# structured by its author.
if '\n' not in summary and len(summary) > 160 and summary.count('; ') >= 2:
    lead, _, rest = summary.partition('; ')
    summary = lead + '\n\n' + '\n'.join('- ' + s for s in rest.split('; '))

print(verdict)
print(summary)
PY
)"
VERDICT="$(printf '%s\n' "$_VERDICT_SPLIT" | head -1)"
SUMMARY="$(printf '%s\n' "$_VERDICT_SPLIT" | tail -n +2)"
unset _VERDICT_SPLIT

# "blocked" is posted by the orchestrator on behalf of whichever stage stopped,
# and that stage is the single most useful word in the message. The convention
# is a leading "<stage>: " in MSG; lift it into the headline and out of the body.
if [ "$EVENT" = "blocked" ] && [ -z "$VERDICT" ]; then
  _BLOCKER="$(SUMMARY="$SUMMARY" python3 - <<'PY'
import os, re
STAGES = ('validator', 'pm', 'developer', 'qa', 'reviewer', 'security',
          'docs', 'planner', 'adversarial', 'orchestrator')
m = re.match(r'^[ \t]*(' + '|'.join(STAGES) + r')[ \t]*:[ \t]*(.*)$',
             os.environ.get('SUMMARY', ''), re.S | re.I)
print(m.group(1).lower() if m else '')
print(m.group(2).strip() if m else os.environ.get('SUMMARY', ''))
PY
)"
  _BLOCKER_STAGE="$(printf '%s\n' "$_BLOCKER" | head -1)"
  if [ -n "$_BLOCKER_STAGE" ]; then
    NACTION="blocked by $_BLOCKER_STAGE"
    SUMMARY="$(printf '%s\n' "$_BLOCKER" | tail -n +2)"
  fi
  unset _BLOCKER _BLOCKER_STAGE
fi

# A PR event's message is boilerplate ("PR https://…/pull/282 opened"); the PR
# title is the line a human actually reads. The URL keeps its place in the
# footer/fields, so nothing is lost. No title resolved => keep the message.
case "$EVENT" in
  pr-opened|merged|issue-closed) [ -n "$PR_TITLE" ] && SUMMARY="$PR_TITLE" ;;
esac

# ${HEADLINE} is line 1, assembled here rather than in each template: the
# verdict-or-action branch is exactly the kind of thing 14 template files would
# get subtly wrong.
#
# The ref carries the link. ${REF_LINK} is a title line and so belongs to the
# thread root only, and a reply also drops the metadata block — which together
# left a "PR opened"/"merged" reply with no route to the PR at all. Linking the
# ref restores click-through on every message without adding a line.
#
# Built here rather than as "[$REF]($PRIMARY_URL)" in the neutral text because
# _neutral_to_platform() DELETES " · [text]()" outright (that is what makes an
# absent ${PR} vanish cleanly from a template); the ref must degrade to plain
# text instead of disappearing, so the empty-URL case never reaches the tidier.
if [ -n "$PRIMARY_URL" ]; then
  HEADLINE_REF="[$REF]($PRIMARY_URL)"
else
  HEADLINE_REF="$REF"
fi
HEADLINE="$ROLE_ICON **$ROLE_LABEL** — ${VERDICT:-$NACTION}${REF:+ · $HEADLINE_REF}"

# ── Template resolution (#280) ───────────────────────────────────────────────
# Templates live in two layers under <templates_dir>:
#   <templates_dir>/<platform>/<event>.md  — platform-specific, rich syntax
#   <templates_dir>/<event>.md             — platform-neutral fallback
# and in two ROOTS: the caller's project dir (an override) and the Talos
# install dir (the shipped defaults). Resolution order for platform P:
#   1. project/<P>/<event>.md   2. project/<event>.md
#   3. install/<P>/<event>.md   4. install/<event>.md
# Project before install at BOTH layers, so a repo that already overrides
# <templates_dir>/<event>.md keeps winning over a shipped platform file — the
# pre-#280 single-level layout must not break when Talos starts shipping
# <platform>/ dirs underneath it.
TMPL_DIR_CFG="$(cfg notifications.templates_dir "templates/notifications")"
TMPL_ROOTS=""
if [ -n "$TMPL_DIR_CFG" ]; then
  case "$TMPL_DIR_CFG" in
    # Absolute path names exactly one root — there is no install-relative
    # counterpart to fall back to.
    /*) TMPL_ROOTS="$TMPL_DIR_CFG" ;;
    # Relative: caller's cwd first, then delegate to _resolve_talos_dir()
    # (sourced from pipeline-paths.sh above) which implements the canonical
    # 5-location probe and returns the scripts dir. Templates live one level
    # up from scripts, so we cd to the parent.
    *)  _tmpl_scripts="$(_resolve_talos_dir pipeline-notify.sh 2>/dev/null || true)"
        if [ -n "$_tmpl_scripts" ]; then
          _tmpl_install="$(cd "$_tmpl_scripts/.." && pwd)/$TMPL_DIR_CFG"
        else
          _tmpl_install="$REPO_ROOT/$TMPL_DIR_CFG"
        fi
        TMPL_ROOTS="$PWD/$TMPL_DIR_CFG"
        [ "$_tmpl_install" != "$TMPL_ROOTS" ] && TMPL_ROOTS="$TMPL_ROOTS
$_tmpl_install"
        unset _tmpl_scripts _tmpl_install ;;
  esac
fi

_tmpl_resolve() {  # $1=platform ("" = neutral only); prints path, rc 1 if none
  [ -n "$TMPL_ROOTS" ] || return 1
  while IFS= read -r _tr_root; do
    [ -n "$_tr_root" ] || continue
    if [ -n "${1:-}" ] && [ -f "$_tr_root/$1/$EVENT.md" ]; then
      printf '%s' "$_tr_root/$1/$EVENT.md"; return 0
    fi
    if [ -f "$_tr_root/$EVENT.md" ]; then
      printf '%s' "$_tr_root/$EVENT.md"; return 0
    fi
  done <<EOF
$TMPL_ROOTS
EOF
  return 1
}

# Substitutes the documented variable set (README "Notification templates").
# A template referencing anything outside it renders the literal ${NAME},
# which is why tests/test-notify-templates.sh pins the list against every
# shipped file.
_tmpl_render() {  # $1=template path; prints the rendered text
  ICON="$ICON" REF="$REF" MSG="$MSG" EVENT="$EVENT" \
    ROLE="$ROLE" TITLE="$TITLE" REF_TITLE="$REF_TITLE" \
    PR="$PR" PR_TITLE="$PR_TITLE" PR_REF="$PR_REF" BOARD="$BOARD" \
    ISSUE_URL="$ISSUE_URL" PR_URL="$PR_URL" \
    REF_LINK="$REF_LINK" PR_LINK="$PR_LINK" \
    VERDICT="$VERDICT" SUMMARY="$SUMMARY" HEADLINE="$HEADLINE" \
    ROLE_ICON="$ROLE_ICON" ROLE_LABEL="$ROLE_LABEL" REPO="$REPO" \
    python3 -c "
import os, re, string, sys
# Only the documented variables (README 'Notification templates' table) are
# substituted. Handing safe_substitute() the whole of os.environ would render
# any exported secret a template happens to name -- \${SLACK_WEBHOOK_URL},
# \${NOSTR_SECRET_KEY}, \${GITHUB_TOKEN} -- straight into an outbound message,
# and a project-supplied override template is untrusted input. Anything
# outside this list stays the literal \${NAME} the docs promise.
DOCUMENTED = (
    'ICON', 'REF', 'MSG', 'EVENT', 'ROLE', 'TITLE', 'REF_TITLE',
    'PR', 'PR_TITLE', 'PR_REF', 'BOARD', 'ISSUE_URL', 'PR_URL',
    'REF_LINK', 'PR_LINK', 'VERDICT', 'SUMMARY', 'HEADLINE',
    'ROLE_ICON', 'ROLE_LABEL', 'REPO',
)


def defuse(v):
    # Values carry externally-influenced text (issue titles, agent verdicts).
    # A run of 3+ backticks at the head of a line opens or closes a fence, so a
    # title carrying one could swallow the rest of the message -- or escape the
    # fence the monospace-grid fallback still puts it in -- and render as
    # arbitrary markdown in the pipeline's own stream. Split the run with
    # zero-width spaces: it reads the same and no longer delimits. Written
    # \x60 because a literal backtick inside this double-quoted string is
    # command substitution to bash.
    return re.sub(r'\x60{3,}', lambda m: '​'.join(m.group(0)), v)


try:
    with open(sys.argv[1]) as f:
        t = string.Template(f.read())
    result = t.safe_substitute(
        {k: defuse(os.environ.get(k, '')) for k in DOCUMENTED}).strip()
    if result:
        print(result)
except Exception:
    pass
" "$1" 2>/dev/null
}

# _render_template <platform> — sets NTMPL (resolved path, empty if none),
# NTEXT (rendered text; plain-text fallback when nothing renders) and NRICH.
#
# NRICH means "a template resolved" (#284) — neutral or per-platform override —
# not "a platform-specific file was hit". One neutral template now renders rich
# on every sink, so every sink with a template gets native metadata; only a
# project that has deleted its templates falls back to the monospace grid.
_render_template() {  # $1=platform ("" = neutral)
  NTMPL="$(_tmpl_resolve "${1:-}")" || NTMPL=""
  NRICH=0
  NTEXT=""
  if [ -n "$NTMPL" ]; then
    NTEXT="$(_tmpl_render "$NTMPL")"
    [ -n "$NTEXT" ] && NRICH=1
  fi
  [ -n "$NTEXT" ] || NTEXT="$TEXT_PLAIN"
}

# _neutral_to_platform <platform> <text> — the transpiler (#284).
#
# Templates are authored once in a small neutral dialect; this is the single
# place it becomes each sink's native syntax. Applied to the rendered text
# right before a payload builder consumes it, and to ${REF_LINK}/${PR_LINK} so
# _prepare_sink can recognise the title line it must drop on replies.
#
# It also tidies what an unavailable variable leaves behind — an empty link
# target, a dangling " · " separator, an empty bold run — so a template needs
# no conditionals: "[PR ${PR}](${PR_URL})" simply disappears when there is no
# PR, and "${REF_LINK}" degrades to plain text when no URL was detectable.
_neutral_to_platform() {  # $1=platform ("" = neutral pass-through), $2=text
  NP_PLATFORM="${1:-}" NP_TEXT="$2" python3 - <<'PY'
import os
import re

text = os.environ.get('NP_TEXT', '')
platform = os.environ.get('NP_PLATFORM', '')

# ── tidy up after empty variables ───────────────────────────────────────────
text = re.sub(r'\[[ \t]+', '[', text)
text = re.sub(r'[ \t]+\]\(', '](', text)
text = re.sub(r'[ \t]*·[ \t]*\[[^\]\n]*\]\([ \t]*\)', '', text)
text = re.sub(r'\[[^\]\n]*\]\([ \t]*\)[ \t]*·[ \t]*', '', text)
text = re.sub(r'\[[ \t]*\]\([^)\n]*\)', '', text)
text = re.sub(r'\[([^\]\n]*)\]\([ \t]*\)', r'\1', text)   # no URL -> plain text
text = re.sub(r'\*\*[ \t]*\*\*', '', text)                 # empty bold run
lines = []
for line in text.split('\n'):
    line = re.sub(r'(?:[ \t]*·)+[ \t]*$', '', line.rstrip())
    line = re.sub(r'^[ \t]*(?:·[ \t]*)+', '', line)
    lines.append(line)
text = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()

# ── per-sink syntax ─────────────────────────────────────────────────────────
if platform == 'slack':
    # Slack mrkdwn: single-asterisk bold, <url|text> links, no headings, no
    # markdown list syntax (a literal "- " renders as a dash).
    text = re.sub(r'(?m)^[ \t]*#{1,6}[ \t]+(.*)$', r'*\1*', text)
    text = re.sub(r'\*\*([^*\n]+)\*\*', r'*\1*', text)
    text = re.sub(r'\[([^\]\n]+)\]\(([^)\n]+)\)', r'<\2|\1>', text)
    text = re.sub(r'(?m)^([ \t]*)[-*][ \t]+', r'\1• ', text)
elif platform in ('discord', 'teams'):
    # Both render CommonMark bold, links and "- " lists natively; neither
    # renders a heading inside an embed / Adaptive Card TextBlock.
    text = re.sub(r'(?m)^[ \t]*#{1,6}[ \t]+(.*)$', r'**\1**', text)
# discord/teams/buzz keep the rest verbatim; buzz renders the dialect as-is.

print(text)
PY
}

# TEXT is the platform-NEUTRAL rendering and stays fixed for the whole run:
# notifications.cmd receives it verbatim, and it is what any sink falls back
# to when no template resolves at all.
_render_template ""
TEXT="$(_neutral_to_platform "" "$NTEXT")"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
PAYLOAD_TEXT="$(json_escape "$TEXT")"

# ── Threading setup ───────────────────────────────────────────────────────────
THREADING_ENABLED="$(cfg notifications.threading "true")"
STATE_FILE="${PIPELINE_THREAD_STATE:-$HOME/.talos/threads.json}"

STATE_KEY="${REPO_SLUG}:${THREAD_KEY}"

# Python helper for thread anchor state. Uses env vars STATE_FILE and STATE_KEY
# to avoid quoting issues. Never crashes on corrupt/missing state files.
#
# Locked (#180): each call is its own read-whole-file/modify/write-whole-file
# python3 process, so two concurrent stages (issues.max_parallel > 1) racing
# on the same STATE_FILE can each load the pre-update state and then clobber
# each other's write, losing an entry. with_lock serializes every get/set/
# clear against STATE_FILE (reads too, so a reader never sees a half-written
# file); on timeout it proceeds unlocked with a warning rather than block
# the pipeline.
_thread_state() {
  STATE_FILE="$STATE_FILE" STATE_KEY="$STATE_KEY" with_lock "$STATE_FILE" 5 -- python3 - "$@" <<'PYEOF'
import json, sys, os

cmd   = sys.argv[1]          # get | set | clear
field = sys.argv[2]          # slack_ts | discord_msg_id
sf    = os.environ['STATE_FILE']
key   = os.environ['STATE_KEY']

def load():
    try:
        with open(sf) as f:
            return json.load(f)
    except Exception:
        return {}

def save(state):
    try:
        d = os.path.dirname(os.path.abspath(sf))
        os.makedirs(d, exist_ok=True)
        with open(sf, 'w') as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass

if cmd == 'get':
    print(load().get(key, {}).get(field, ''), end='')
elif cmd == 'set':
    val   = sys.argv[3]
    state = load()
    state.setdefault(key, {})[field] = val
    save(state)
elif cmd == 'clear':
    state = load()
    if key in state:
        state[key].pop(field, None)
        if not state[key]:
            del state[key]
        save(state)
PYEOF
}

_extract_json_field() {  # $1=json-string $2=field-name
  python3 -c "
import json, sys
try: print(json.loads(sys.argv[1]).get(sys.argv[2], ''), end='')
except: pass
" "$1" "$2" 2>/dev/null
}

post() {  # $1=url $2=json-body $3=platform [$4=auth-header]
  if [ -n "${4:-}" ]; then
    curl -sS -m 10 -H 'Content-Type: application/json' -H "$4" -d "$2" "$1"
  else
    curl -sS -m 10 -H 'Content-Type: application/json' -d "$2" "$1"
  fi
}

# ── Rich payload builders (Daedalus-style Block Kit / embeds) ─────────────────
# The rendered text is now per-sink (#280) — see _prepare_sink() below, which
# each sink calls immediately before building its payload. What stays shared is
# the colour, the context line, and the metadata field set.
case "$EVENT" in
  merged|issue-closed|qa) NCOLOR="#2ecc71"; NCOLOR_INT=3066993  ;;
  blocked)                NCOLOR="#e74c3c"; NCOLOR_INT=15158332 ;;
  security)               NCOLOR="#e67e22"; NCOLOR_INT=15105570 ;;
  reviewer)               NCOLOR="#9b59b6"; NCOLOR_INT=10181046 ;;
  *)                      NCOLOR="#3498db"; NCOLOR_INT=3447003  ;;
esac
NCONTEXT="${REPO_SLUG} · ${EVENT}${REF:+ · $REF}"

# ── Shared metadata fields ───────────────────────────────────────────────────
# One platform-neutral field set, rendered natively by each sink: a GFM table
# on Buzz, Block Kit `fields` on Slack, embed `fields` on Discord, an Adaptive
# Card FactSet on Teams. Emitting the same markdown table everywhere would not
# work — Slack mrkdwn has no table syntax and would print literal pipes.
#
# Rows carry an optional url so each renderer can apply its own link syntax
# (<url|text> on Slack, [text](url) elsewhere). Fields with no value are
# dropped here rather than in each renderer, so issue-only events (validator,
# pm, docs — most of the pipeline's traffic) never show an empty PR cell.
NFIELDS="$(
  NF_PR="${PR:-}" NF_PR_URL="${PR_URL:-}" NF_NUM="${_num:-}" \
  NF_ISSUE_URL="${ISSUE_URL:-}" NF_EVENT="${EVENT:-}" \
  NF_REPO="${_NOTIFY_REPO:-${REPO_SLUG:-}}" python3 - <<'PY'
import json, os
e = os.environ
f = []
if e['NF_PR']:
    f.append({"label": "PR", "text": "#" + e['NF_PR'], "url": e['NF_PR_URL']})
if e['NF_NUM']:
    f.append({"label": "Issue", "text": "#" + e['NF_NUM'], "url": e['NF_ISSUE_URL']})
if e['NF_EVENT']:
    f.append({"label": "Stage", "text": e['NF_EVENT'], "url": ""})
if e['NF_REPO']:
    f.append({"label": "Repo", "text": e['NF_REPO'], "url": ""})
print(json.dumps(f))
PY
)"

# ── Per-sink rendering ───────────────────────────────────────────────────────
# Two body variants, because the title belongs to the thread ROOT only (#284).
#
# NBODY is the root form and carries the title line. NBODY_REPLY drops it: a
# reply lands under a root that already shows "#42 Fix login crash", and
# repeating it on every stage is what made a live thread unreadable. The title
# line is spelled exactly "${REF_LINK}" (or "${PR_LINK}") in every template, so
# matching the rendered value of those variables is a defined rule, not a guess.

# _build_grid — the shared monospace grid. Since #280 it is the FALLBACK
# rendering: it is what notifications.cmd sees, and what a sink shows when no
# template exists for its platform. One pre-aligned plain-text grid: Slack
# mrkdwn has no table syntax — a pipe table posts as literal pipes — so a
# fixed-width block inside a code fence (a Monospace TextBlock on Teams) is the
# only construct that renders as the same aligned grid on all four platforms.
#
# The comment is wrapped onto continuation lines aligned under the value column
# rather than truncated: agent verdicts carry the actual finding, and a card
# that silently drops half of one is worse than a slightly tall card. Links are
# NOT put in here — no platform makes a URL clickable inside a code block — so
# each sink appends its own link line underneath in its own syntax.
_build_grid() {
  NGRID="$(NFIELDS="$NFIELDS" NBODY_REPLY="$NBODY_REPLY" NPRIMARY_URL="$PRIMARY_URL" python3 - <<'PY'
import json, os, re, textwrap


def cell(s):
    # Every row lands inside the literal triple-backtick fence the three
    # markdown sinks wrap this grid in, and inside a fence a backslash
    # escapes nothing. Only two things can break out: a run of 3+ backticks,
    # which closes the fence early and lets the rest of an issue title or
    # agent message render as arbitrary markdown, and a raw newline, which
    # ends the row. Lone backticks are harmless in a fence and common in
    # agent verdicts, so only the closing run is defused -- split by
    # zero-width spaces, which reads the same but no longer delimits.
    # Written \x60 because a literal backtick (and, for bash, a literal
    # apostrophe) inside the enclosing $( … ) breaks the file -- see
    # _bt_fence below.
    s = re.sub(r'\s*[\r\n]+\s*', ' ', str(s)).strip()
    return re.sub(r'\x60{3,}', lambda m: '\u200b'.join(m.group(0)), s)


rows = []
# On the template-less path the comment IS ${TEXT_PLAIN}, which the script
# builds with a trailing " (<primary url>)". That would put a URL inside the
# fence -- inert there, and already repeated as the clickable link line each
# sink appends underneath -- breaking the no-links invariant of this block
# using text the script itself generated rather than anything a caller sent.
# Strip exactly that suffix. A URL an agent wrote into its own message is left
# alone, since dropping part of a verdict is the failure this grid refuses to
# make. (No apostrophes in this block: a literal one inside the enclosing
# $( ... ) breaks the parse of the whole file -- see _bt_fence below.)
_comment = os.environ.get('NBODY_REPLY', '')
_purl = os.environ.get('NPRIMARY_URL', '')
if _purl:
    _comment = re.sub(r'\s*\(' + re.escape(_purl) + r'\)\s*$', '', _comment)
comment = cell(_comment)
if comment:
    rows.append(("Comment", comment))
for f in json.loads(os.environ.get('NFIELDS') or '[]'):
    rows.append((cell(f["label"]), cell(f["text"])))
if rows:
    w = max(len(l) for l, _ in rows)
    out = []
    for label, val in rows:
        chunks = textwrap.wrap(val, 58) or [""]
        out.append("{}  {}".format(label.ljust(w), chunks[0]))
        out.extend(" " * (w + 2) + c for c in chunks[1:])
    print("\n".join(out))
PY
)"
}

# _buzz_footer — the compact metadata line Buzz gets instead of a table (#284).
#
# A "| Field | Value |" table for four short values is a heavy construct in a
# chat client; the same information reads as one dim line under the message.
# Slack/Discord/Teams keep their native field blocks, which lay out on their
# own. Values are externally influenced, so pipes/backticks/newlines are
# neutralised exactly as the table's cell() did — GFM is still GFM.
_buzz_footer() {
  NF_REPO="$REPO" NF_PR="${PR:-}" NF_PR_URL="${PR_URL:-}" \
    python3 - <<'PY'
import os
import re


def cell(s):
    s = re.sub(r'\s*[\r\n]+\s*', ' ', str(s)).strip()
    return s.replace('\\', '\\\\').replace('|', '\\|').replace('\x60', "'")


e = os.environ
# The role is on line 1 now, so the footer is just where the work lives.
parts = [p for p in (cell(e['NF_REPO']),) if p]
if e['NF_PR']:
    pr = 'PR #' + cell(e['NF_PR'])
    url = cell(e['NF_PR_URL']).replace(' ', '%20')
    parts.append('[{}]({})'.format(pr, url) if url else pr)
if parts:
    print(' \u00b7 '.join(parts))
PY
}

# _prepare_sink <platform> — resolve and render the ONE neutral template,
# transpile it for this sink, and derive every N* variable its payload builder
# reads. Called once per sink. Pass "" for the platform-neutral rendering
# (which is what notifications.cmd receives).
_prepare_sink() {
  _render_template "${1:-}"
  NTEXT="$(_neutral_to_platform "${1:-}" "$NTEXT")"
  NTITLE="$(printf '%s\n' "$NTEXT" | head -1)"
  NBODY="$(printf '%s\n' "$NTEXT" | tail -n +2 | sed '/./,$!d')"
  [ -z "$NBODY" ] && NBODY="$NTITLE"
  # Thread replies drop the title line: the root already carries it. The line
  # is exactly the rendered ${REF_LINK} / ${PR_LINK}, transpiled the same way,
  # so this is an equality test rather than a heuristic.
  _ps_ref="$(_neutral_to_platform "${1:-}" "$REF_LINK")"
  _ps_pr="$(_neutral_to_platform "${1:-}" "$PR_LINK")"
  NBODY_REPLY="$(printf '%s\n' "$NBODY" \
    | { [ -n "$_ps_ref" ] && grep -vxF "$_ps_ref" || cat; } \
    | { [ -n "$_ps_pr" ] && grep -vxF "$_ps_pr" || cat; } \
    | sed '/./,$!d')"
  [ -z "$NBODY_REPLY" ] && NBODY_REPLY="$NTITLE"
  NTEXT_REPLY="$NTITLE"
  [ "$NBODY_REPLY" != "$NTITLE" ] && NTEXT_REPLY="$NTITLE

$NBODY_REPLY"
  unset _ps_ref _ps_pr
  _build_grid
}

# Baseline state: the platform-neutral rendering. Every sink re-prepares with
# its own platform when it actually runs; this call guarantees the N*
# variables are defined even when no sink is configured (set -u).
_prepare_sink ""

_slack_payload() {  # $1=thread_ts (may be empty) $2=mode: bot|webhook
  NTITLE="$NTITLE" NBODY="$NBODY" NBODY_REPLY="$NBODY_REPLY" NCTX="$NCONTEXT" NCOLOR="$NCOLOR" \
  NFIELDS="$NFIELDS" NGRID="$NGRID" NRICH="$NRICH" \
  NCHANNEL="$SLACK_CHANNEL" NTHREAD="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
raw_title = os.environ['NTITLE']
# Plain text for the notification preview and the attachment fallback. The
# headline's ref is a link by the time it gets here, and neither field renders
# markup, so unwrap <url|text> to text before stripping emphasis — otherwise a
# push notification reads "... · <https://github.com/o/r/pull/9|#42>".
title = re.sub(r'<[^|>\s]+\|([^>]*)>', r'\1', raw_title)
title = re.sub(r'[*_`]', '', title).strip()
# A post with no thread anchor is the first message for this issue — the root —
# and carries the full metadata card. Replies stay light so a thread does not
# repeat the same PR/Issue/Repo block on every stage. Recovery reposts pass an
# empty anchor and are correctly treated as new roots.
is_root = not os.environ['NTHREAD']
# The title line belongs to the root only (#284); a reply drops it.
body = os.environ['NBODY'] if is_root else os.environ['NBODY_REPLY']
# Daedalus-style: one cohesive markdown message, NOT a heavy Slack header block.
# Already transpiled to mrkdwn by _neutral_to_platform().
full = raw_title
if body and body.strip() and body.strip() != raw_title.strip():
    full = raw_title + "\n\n" + body
# Root with a template: its own mrkdwn, then the metadata as a native Block Kit
# `fields` section — a two-column label/value grid Slack lays out itself, with
# each link in Slack's <url|text> syntax. Root WITHOUT one: the shared
# monospace grid (which already carries the comment), then a clickable link row
# — URLs are inert inside a code block, so they live underneath it. Replies
# keep the plain title+body rendering.
rich = os.environ.get('NRICH') == '1'
grid = os.environ.get('NGRID', '')
fields = json.loads(os.environ.get('NFIELDS') or '[]')
blocks = []
if is_root and rich:
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": full[:3000]}})
    # Block Kit caps a section at 10 fields; the metadata set is 4 at most.
    field_blocks = [
        {"type": "mrkdwn", "text": "*{}*\n{}".format(
            f["label"],
            "<{}|{}>".format(f["url"], f["text"]) if f.get("url") else f["text"])}
        for f in fields
    ][:10]
    if field_blocks:
        blocks.append({"type": "section", "fields": field_blocks})
else:
    if is_root and grid:
        parts = [raw_title, "```\n" + grid + "\n```"]
        links = [
            "<{}|{} {}>".format(f["url"], f["label"], f["text"])
            for f in fields if f.get("url")
        ]
        if links:
            parts.append(" · ".join(links))
        full = "\n".join(parts)
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": full[:3000]}})
blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": os.environ['NCTX']}]})
p = {
    "text": title,
    "blocks": blocks,
    "attachments": [{"color": os.environ['NCOLOR'], "fallback": title}],
}
if os.environ['NMODE'] == 'bot':
    p["channel"] = os.environ['NCHANNEL']
    if os.environ['NTHREAD']:
        p["thread_ts"] = os.environ['NTHREAD']
print(json.dumps(p, ensure_ascii=False))
PY
}

_discord_payload() {  # $1=anchor msg id (may be empty) $2=mode: bot|webhook
  NTITLE="$NTITLE" NBODY="$NBODY" NBODY_REPLY="$NBODY_REPLY" NCTX="$NCONTEXT" NCOLOR_INT="$NCOLOR_INT" \
  NFIELDS="$NFIELDS" NGRID="$NGRID" NRICH="$NRICH" \
  NURL="$PRIMARY_URL" NANCHOR="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
# A Discord embed `title` is plain text -- it renders neither bold nor links --
# so unwrap [text](url) to text before stripping emphasis, or the linked ref
# would show as raw markdown in the title.
title = re.sub(r'\[([^\]\n]*)\]\([^)\n]*\)', r'\1', os.environ['NTITLE'])
title = re.sub(r'[*_`]', '', title).strip()
# No anchor => first message for this issue => full metadata card; replies light.
is_root = not os.environ['NANCHOR']
# The title line belongs to the root only (#284); a reply drops it.
body = os.environ['NBODY'] if is_root else os.environ['NBODY_REPLY']
p = {
    "embeds": [{
        "title": title[:256],
        "description": body[:3900],
        "color": int(os.environ['NCOLOR_INT']),
        "footer": {"text": os.environ['NCTX'][:2048]},
    }],
}
# Root with a discord/ template (#280): the description stays the template's
# own markdown and the metadata goes into native embed `fields`, which Discord
# lays out as inline chips under the body. Root WITHOUT one falls back to the
# monospace grid with a clickable link row beneath it (URLs are inert inside a
# code block).
_rich = os.environ.get('NRICH') == '1'
_grid = os.environ.get('NGRID', '')
_fields = json.loads(os.environ.get('NFIELDS') or '[]')
if is_root and _rich:
    # Discord caps an embed at 25 fields; the metadata set is 4 at most.
    _fl = [
        {"name": f["label"],
         "value": "[{}]({})".format(f["text"], f["url"]) if f.get("url") else f["text"],
         "inline": True}
        for f in _fields
    ][:25]
    if _fl:
        p["embeds"][0]["fields"] = _fl
elif is_root and _grid:
    _links = " · ".join(
        "[{} {}]({})".format(f["label"], f["text"], f["url"])
        for f in _fields if f.get("url")
    )
    _desc = "```\n" + _grid + "\n```"
    if _links:
        _desc += "\n" + _links
    p["embeds"][0]["description"] = _desc[:3900]
if os.environ.get('NURL'):
    p["embeds"][0]["url"] = os.environ['NURL']
if os.environ['NMODE'] == 'bot' and os.environ['NANCHOR']:
    p["message_reference"] = {"message_id": os.environ['NANCHOR'], "fail_if_not_exists": False}
print(json.dumps(p, ensure_ascii=False))
PY
}

# _teams_payload — built with python3 rather than shell interpolation so the
# FactSet — the Adaptive Card equivalent of the Buzz table and the Slack/
# Discord field sets — is assembled as real JSON. Facts render as an aligned
# label/value grid. Built unconditionally so debug mode can print the real
# payload rather than a text approximation; Teams cannot thread, so every post
# is a root card.
_teams_payload() {
  NTITLE="$NTITLE" NBODY="$NBODY" NGRID="$NGRID" NRICH="$NRICH" \
  NCTX="$NCONTEXT" NFIELDS="$NFIELDS" python3 - <<'PY'
import json, os
# With a teams/ template (#280): title, body, then the metadata as a native
# FactSet. Without one: the same monospace grid every other fallback sink
# shows, plus a link row. Adaptive Cards do not render markdown code fences, so
# the grid goes in a TextBlock with fontType Monospace — the Teams equivalent
# of a fenced block. (No literal fence characters in this comment: this heredoc
# sits inside a $( … ), where bash scans for the closing paren and an odd
# number of backticks silently breaks the parse of the whole file.)
rich = os.environ.get('NRICH') == '1'
fields = json.loads(os.environ.get('NFIELDS') or '[]')
title = os.environ['NTITLE']
body = [{"type": "TextBlock", "wrap": True, "weight": "Bolder", "size": "Medium",
         "text": title}]
if rich:
    text = os.environ.get('NBODY', '')
    if text and text.strip() != title.strip():
        body.append({"type": "TextBlock", "wrap": True, "text": text})
    facts = [
        {"title": f["label"],
         "value": "[{}]({})".format(f["text"], f["url"]) if f.get("url") else f["text"]}
        for f in fields
    ]
    if facts:
        body.append({"type": "FactSet", "facts": facts})
else:
    grid = os.environ.get('NGRID', '')
    if grid:
        body.append({"type": "TextBlock", "wrap": True, "fontType": "Monospace",
                     "text": grid})
    links = " · ".join(
        "[{} {}]({})".format(f["label"], f["text"], f["url"])
        for f in fields if f.get("url")
    )
    if links:
        body.append({"type": "TextBlock", "wrap": True, "text": links})
body.append({"type": "TextBlock", "wrap": True, "isSubtle": True,
             "spacing": "Small", "text": os.environ['NCTX']})
print(json.dumps({
    "type": "message",
    "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {"type": "AdaptiveCard", "version": "1.4", "body": body},
    }],
}, ensure_ascii=False))
PY
}

# _buzz_text <anchor> — the kind:9 body Buzz publishes.
#
# Buzz renders GitHub-Flavored Markdown (remark-gfm + remark-breaks), so the
# neutral dialect goes out verbatim — bold, links and "- " bullets all render.
# With a template in play the root post is that rendering plus one compact
# footer line (#284: a four-row "| Field | Value |" table was a heavy construct
# for four short values); without one it falls back to the monospace grid every
# other template-less sink shows.
#
# Root posts get the footer; replies stay light — they carry neither the title
# line nor the footer, because the root above them already does. The anchor is
# the signal: absent => this is the first message for the issue.
_buzz_text() {  # $1=anchor event id (may be empty)
  if [ -n "${1:-}" ]; then
    printf '%s' "$NTEXT_REPLY"
    return 0
  fi
  if [ "$NRICH" = "1" ]; then
    _bt_footer="$(_buzz_footer)"
    printf '%s\n' "$NTEXT"
    [ -n "$_bt_footer" ] && printf '\n%s\n' "$_bt_footer"
    return 0
  fi
  _bt_links="$(NFIELDS="$NFIELDS" python3 - <<'PY'
import json, os
print(" · ".join(
    "[{} {}]({})".format(f["label"], f["text"], f["url"])
    for f in json.loads(os.environ.get('NFIELDS') or '[]') if f.get("url")
))
PY
)"
  # The fence lives in a variable: a literal triple-backtick inside $( … ) is
  # parsed as legacy backtick command substitution and breaks the file.
  _bt_fence='```'
  printf '### %s\n' "$NTITLE"
  [ -n "$NGRID" ] && printf '\n%s\n%s\n%s\n' "$_bt_fence" "$NGRID" "$_bt_fence"
  [ -n "$_bt_links" ] && printf '\n%s\n' "$_bt_links"
  return 0
}

# ── --render: preview and exit (#280) ────────────────────────────────────────
# Everything below this point talks to a network or to threads.json. The render
# path stops here: it resolves and renders the template, prints the payload the
# platform would send, and exits 0 without posting or touching thread state.
if [ -n "$RENDER_ONLY" ]; then
  _render_platform="$RENDER_ONLY"
  # A typo must not quietly preview the neutral template and look like an
  # answer. This is an interactive preview, not a delivery path, so it is the
  # one place the script reports a usage error instead of exiting 0.
  case "$_render_platform" in
    slack|discord|teams|buzz) ;;
    default) _render_platform="" ;;
    *) echo "pipeline-notify: --render: unknown platform '$RENDER_ONLY' (slack|discord|teams|buzz|default)" >&2
       exit 2 ;;
  esac
  _prepare_sink "$_render_platform"
  printf '# platform: %s\n' "$RENDER_ONLY"
  printf '# event:    %s\n' "$EVENT"
  printf '# template: %s\n' "${NTMPL:-(none — plain-text fallback)}"
  if [ "$NRICH" = "1" ]; then printf '# rich:     yes\n'; else printf '# rich:     no\n'; fi
  printf '\n'
  case "$_render_platform" in
    slack)   _slack_payload "" bot ;;
    discord) _discord_payload "" bot ;;
    teams)   _teams_payload ;;
    buzz)    _buzz_text "" ;;
    *)       printf '%s\n' "$NTEXT" ;;
  esac
  exit 0
fi

# ── Slack ─────────────────────────────────────────────────────────────────────
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  _prepare_sink slack
  # Webhook mode — threading not supported (Slack incoming webhooks have no thread_ts)
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] SLACK (webhook, no threading): $NTEXT"
  else
    post "$SLACK_WEBHOOK_URL" "$(_slack_payload "" webhook)" slack >/dev/null 2>&1 \
      || echo "pipeline-notify: slack webhook delivery failed" >&2
  fi
elif [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "$SLACK_CHANNEL" ]; then
  _prepare_sink slack
  # Bot-token mode — threading supported
  SLACK_ANCHOR=""
  if [ "$THREADING_ENABLED" = "true" ]; then
    SLACK_ANCHOR="$(_thread_state get slack_ts)"
  fi

  SLACK_PAYLOAD="$(_slack_payload "$SLACK_ANCHOR" bot)"

  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] SLACK (bot) state_key=$STATE_KEY"
    echo "[pipeline-notify DEBUG] SLACK thread_anchor=${SLACK_ANCHOR:-(none — root post)}"
    echo "[pipeline-notify DEBUG] SLACK payload=$SLACK_PAYLOAD"
  else
    resp="$(post "https://slack.com/api/chat.postMessage" "$SLACK_PAYLOAD" \
      slack "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null)"

    case "$resp" in
      *'"ok":true'*)
        # Store ts as anchor for the first (root) post
        if [ "$THREADING_ENABLED" = "true" ] && [ -z "$SLACK_ANCHOR" ]; then
          NEW_TS="$(_extract_json_field "$resp" ts)"
          [ -n "$NEW_TS" ] && _thread_state set slack_ts "$NEW_TS"
        fi
        ;;
      *'"error":"thread_not_found"'*)
        # Stale anchor — clear it, retry as a fresh root thread
        _thread_state clear slack_ts
        FRESH_PAYLOAD="$(_slack_payload "" bot)"
        resp2="$(post "https://slack.com/api/chat.postMessage" "$FRESH_PAYLOAD" \
          slack "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null)"
        case "$resp2" in
          *'"ok":true'*)
            if [ "$THREADING_ENABLED" = "true" ]; then
              NEW_TS="$(_extract_json_field "$resp2" ts)"
              [ -n "$NEW_TS" ] && _thread_state set slack_ts "$NEW_TS"
            fi
            ;;
          *) echo "pipeline-notify: slack retry (thread_not_found recovery) failed" >&2 ;;
        esac
        ;;
      *) echo "pipeline-notify: slack api delivery failed: $(printf '%s' "$resp" | head -c 200)" >&2 ;;
    esac
  fi
fi

# ── Discord ───────────────────────────────────────────────────────────────────
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  _prepare_sink discord
  # Webhook mode — threading not supported (Discord webhooks cannot target message threads)
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] DISCORD (webhook, no threading): $NTEXT"
  else
    post "$DISCORD_WEBHOOK_URL" "$(_discord_payload "" webhook)" discord >/dev/null 2>&1 \
      || echo "pipeline-notify: discord webhook delivery failed" >&2
  fi
elif [ -n "${DISCORD_BOT_TOKEN:-}" ] && [ -n "$DISCORD_CHANNEL" ]; then
  _prepare_sink discord
  # Bot-token mode — real threads, matching Slack and Buzz.
  #
  # message_reference (the previous approach) is an inline REPLY, not a thread:
  # every stage stays in the main channel with a small "replying to" header, so
  # a busy pipeline still floods the channel. A real thread collapses the whole
  # issue into one expandable entry. Two steps: post the root to the channel,
  # then POST …/messages/{id}/threads to start a thread anchored to it; later
  # events post straight into that thread channel.
  DISCORD_THREAD=""
  DISCORD_ANCHOR=""
  if [ "$THREADING_ENABLED" = "true" ]; then
    DISCORD_THREAD="$(_thread_state get discord_thread_id)"
    DISCORD_ANCHOR="$(_thread_state get discord_msg_id)"
  fi

  # A message posted into a thread channel needs no message_reference — passing
  # the anchor would render a redundant reply header inside the thread. The
  # anchor is still passed when no thread exists, so the inline-reply fallback
  # below keeps working on servers where the bot cannot create threads.
  if [ -n "$DISCORD_THREAD" ]; then
    DISCORD_TARGET="$DISCORD_THREAD"
    DISCORD_PAYLOAD="$(_discord_payload "$DISCORD_ANCHOR" bot_in_thread)"
  else
    DISCORD_TARGET="$DISCORD_CHANNEL"
    DISCORD_PAYLOAD="$(_discord_payload "$DISCORD_ANCHOR" bot)"
  fi

  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] DISCORD (bot) state_key=$STATE_KEY"
    echo "[pipeline-notify DEBUG] DISCORD thread=${DISCORD_THREAD:-(none — will create from root)}"
    echo "[pipeline-notify DEBUG] DISCORD payload=$DISCORD_PAYLOAD"
  else
    resp="$(post "https://discord.com/api/v10/channels/$DISCORD_TARGET/messages" \
      "$DISCORD_PAYLOAD" discord "Authorization: Bot $DISCORD_BOT_TOKEN" 2>/dev/null)"

    case "$resp" in
      *'"id"'*)
        # Root post only: both anchors empty. Retrying thread creation on every
        # later event would fire a failing API call per stage on a server where
        # the bot lacks CREATE_PUBLIC_THREADS — the fallback must settle, not
        # keep probing.
        if [ "$THREADING_ENABLED" = "true" ] && [ -z "$DISCORD_THREAD" ] && [ -z "$DISCORD_ANCHOR" ]; then
          NEW_ID="$(_extract_json_field "$resp" id)"
          if [ -n "$NEW_ID" ]; then
            _thread_state set discord_msg_id "$NEW_ID"
            # Start the thread from the root message. Thread names are capped at
            # 100 chars by Discord and rejected outright if longer.
            # A Discord thread name is plain text, capped at 100 chars. Unwrap
            # [text](url) first so a linked ref spends the budget on the ref,
            # not on the URL.
            _dc_title="$(printf '%s' "$NTITLE" | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g')"
            _dc_name="$(printf '%s' "${REF:-$EVENT}${_dc_title:+ — $_dc_title}" | tr '\n' ' ' | cut -c1-95)"
            _dc_body="$(NAME="$_dc_name" python3 -c 'import json,os; print(json.dumps({"name": os.environ["NAME"], "auto_archive_duration": 1440}))')"
            tresp="$(post "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages/$NEW_ID/threads" \
              "$_dc_body" discord "Authorization: Bot $DISCORD_BOT_TOKEN" 2>/dev/null)"
            case "$tresp" in
              *'"id"'*) _thread_state set discord_thread_id "$(_extract_json_field "$tresp" id)" ;;
              # Missing CREATE_PUBLIC_THREADS is the common cause. Warn once and
              # leave discord_thread_id unset: later events fall back to inline
              # replies off discord_msg_id rather than losing the notification.
              *) echo "pipeline-notify: discord thread creation failed, falling back to inline replies: $(printf '%s' "$tresp" | head -c 200)" >&2 ;;
            esac
          fi
        fi
        ;;
      *) echo "pipeline-notify: discord api delivery failed: $(printf '%s' "$resp" | head -c 200)" >&2 ;;
    esac
  fi
fi

# ── Teams (webhook only — no threading) ──────────────────────────────────────
if [ -n "${TEAMS_WEBHOOK_URL:-}" ]; then
  _prepare_sink teams
  TEAMS_PAYLOAD="$(_teams_payload)"
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] TEAMS payload=$TEAMS_PAYLOAD"
  else
    post "$TEAMS_WEBHOOK_URL" "$TEAMS_PAYLOAD" teams >/dev/null 2>&1 \
      || echo "pipeline-notify: teams webhook delivery failed" >&2
  fi
fi

# ── Buzz (Nostr kind:9 via nak — key-based, threads via NIP-10 replies) ──────
if [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_BOT_PRIVATE_KEY:-}" ] && [ -n "$BUZZ_CHANNEL" ]; then
  _prepare_sink buzz
  BUZZ_ANCHOR=""
  if [ "$THREADING_ENABLED" = "true" ]; then
    BUZZ_ANCHOR="$(_thread_state get buzz_event_id)"
  fi

  BUZZ_TEXT="$(_buzz_text "$BUZZ_ANCHOR")"

  # Seconds a single nak call may run before it is killed (#281). A relay that
  # never answers sends no RST, never closes, and never issues the NIP-42 AUTH
  # challenge, so an unbounded nak hangs this script — and with it the
  # orchestrator's whole post-merge chain — indefinitely.
  BUZZ_TIMEOUT_S="$(cfg notifications.buzz_timeout_s "15")"
  case "$BUZZ_TIMEOUT_S" in
    ''|*[!0-9]*) BUZZ_TIMEOUT_S=15 ;;
  esac
  [ "$BUZZ_TIMEOUT_S" -gt 0 ] 2>/dev/null || BUZZ_TIMEOUT_S=15

  # nak exits 0 even when the relay REJECTS the event, and prints the
  # locally-signed JSON to stdout regardless (it signs before publishing). So
  # neither the exit code nor stdout distinguishes success from failure — an id
  # parsed from that stdout can be an event the relay never stored, which then
  # gets persisted as a thread anchor and makes a dead sink look healthy.
  # The relay's actual verdict is only on stderr, so capture and inspect it.
  _buzz_publish() {  # $1=anchor event id (may be empty); prints nak stdout
    # rc 0 = published, 1 = rejected/failed, 2 = timed out. A timeout is its
    # own code because it says nothing about the anchor: the caller must not
    # read it as "stale anchor" and burn a second timeout on a recovery repost.
    _buzz_err="$(mktemp)"; _buzz_res="$(mktemp)"; _buzz_expired="$(mktemp)"

    # Portable timeout: no timeout(1) on macOS by default, so nak runs as its
    # own process group (set -m) with a background watchdog that sends SIGTERM,
    # then SIGKILL, to that group once BUZZ_TIMEOUT_S elapses — the same
    # pattern pipeline-hooks.sh's _hooks_run and the notifications.cmd sink use.
    # The bot key travels in NOSTR_SECRET_KEY, which nak documents as the source
    # for --sec (`nak event --help`, GLOBAL OPTIONS), instead of on argv, where
    # `ps` exposes it to every local user for the life of the process.
    set -m
    if [ -n "$1" ]; then
      NOSTR_SECRET_KEY="$BUZZ_BOT_PRIVATE_KEY" nak event --auth -k 9 -c "$BUZZ_TEXT" \
        -t "h=$BUZZ_CHANNEL" -t "e=$1;;reply" "$BUZZ_RELAY_URL" >"$_buzz_res" 2>"$_buzz_err" &
    else
      NOSTR_SECRET_KEY="$BUZZ_BOT_PRIVATE_KEY" nak event --auth -k 9 -c "$BUZZ_TEXT" \
        -t "h=$BUZZ_CHANNEL" "$BUZZ_RELAY_URL" >"$_buzz_res" 2>"$_buzz_err" &
    fi
    _buzz_pid=$!
    set +m

    # The watchdog gets its own process group too: killing it below must reap
    # the `sleep` it already forked, not orphan it for BUZZ_TIMEOUT_S.
    set -m
    ( sleep "$BUZZ_TIMEOUT_S"
      printf 'timeout' > "$_buzz_expired"
      kill -TERM -"$_buzz_pid" 2>/dev/null
      sleep 0.2
      kill -KILL -"$_buzz_pid" 2>/dev/null
    ) &
    _buzz_wd=$!
    set +m

    wait "$_buzz_pid" 2>/dev/null
    _buzz_rc=$?
    kill -- -"$_buzz_wd" 2>/dev/null
    wait "$_buzz_wd" 2>/dev/null

    _buzz_out="$(cat "$_buzz_res" 2>/dev/null)"
    _buzz_msg="$(cat "$_buzz_err" 2>/dev/null)"
    _buzz_timed_out=0
    [ -s "$_buzz_expired" ] && _buzz_timed_out=1
    rm -f "$_buzz_err" "$_buzz_res" "$_buzz_expired"

    if [ "$_buzz_timed_out" -eq 1 ]; then
      printf 'pipeline-notify: buzz relay timed out after %ss: %s\n' \
        "$BUZZ_TIMEOUT_S" "$BUZZ_RELAY_URL" >&2
      return 2
    fi
    # Failure markers, verified against a rejected publish: an unadmitted key
    # yields "auth error: msg: restricted: not a relay member. failed: msg:
    # auth-required: not authenticated" with rc=0. Success prints only
    # "connecting… ok." / "publishing… success.", neither of which matches.
    if [ "$_buzz_rc" -ne 0 ] || printf '%s' "$_buzz_msg" | grep -qE 'auth error|failed:|CLOSED:'; then
      [ -n "$_buzz_msg" ] && printf 'pipeline-notify: buzz relay rejected publish: %s\n' "$_buzz_msg" >&2
      return 1
    fi
    printf '%s' "$_buzz_out"
  }

  _buzz_event_id() {  # $1=nak stdout — event JSON on the first line
    _extract_json_field "$(printf '%s' "$1" | head -1)" id
  }

  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] BUZZ state_key=$STATE_KEY"
    echo "[pipeline-notify DEBUG] BUZZ thread_anchor=${BUZZ_ANCHOR:-(none — root post)}"
    echo "[pipeline-notify DEBUG] BUZZ relay=$BUZZ_RELAY_URL channel=$BUZZ_CHANNEL kind=9 text=$BUZZ_TEXT"
  elif ! command -v nak >/dev/null 2>&1; then
    echo "pipeline-notify: buzz configured but 'nak' CLI not found — skipping (brew install nak)" >&2
  else
    # rc 2 (timed out) already logged its one stderr line and is no evidence
    # the anchor is stale, so it skips both the recovery repost and the generic
    # failure line below.
    resp="$(_buzz_publish "$BUZZ_ANCHOR")"; BUZZ_RC=$?
    if [ "$BUZZ_RC" -eq 0 ]; then
      # Store the root event id as the thread anchor for the first post
      if [ "$THREADING_ENABLED" = "true" ] && [ -z "$BUZZ_ANCHOR" ]; then
        NEW_ID="$(_buzz_event_id "$resp")"
        [ -n "$NEW_ID" ] && _thread_state set buzz_event_id "$NEW_ID"
      fi
    elif [ "$BUZZ_RC" -eq 1 ] && [ -n "$BUZZ_ANCHOR" ]; then
      # Reply rejected (Buzz rejects replies to unknown parents) — clear the
      # stale anchor and repost as a fresh root, mirroring Slack recovery.
      _thread_state clear buzz_event_id
      resp2="$(_buzz_publish "")"; BUZZ_RETRY_RC=$?
      if [ "$BUZZ_RETRY_RC" -eq 0 ]; then
        if [ "$THREADING_ENABLED" = "true" ]; then
          NEW_ID="$(_buzz_event_id "$resp2")"
          [ -n "$NEW_ID" ] && _thread_state set buzz_event_id "$NEW_ID"
        fi
      elif [ "$BUZZ_RETRY_RC" -eq 1 ]; then
        echo "pipeline-notify: buzz retry (stale anchor recovery) failed" >&2
      fi
    elif [ "$BUZZ_RC" -eq 1 ]; then
      echo "pipeline-notify: buzz publish failed" >&2
    fi
  fi
fi

# ── Generic command sink (notifications.cmd, #184) ───────────────────────────
# For any sink Slack/Discord/Teams/Buzz don't cover (a local desktop
# notifier, a webhook relay, a log shipper): run an arbitrary shell command
# with a JSON payload on stdin. Disabled by default (empty string). Same
# always-exit-0 contract as every sink above -- a missing command, a
# non-zero exit, or a timeout logs one line to stderr and this script still
# exits 0; it never blocks the sinks above (it runs last) or the caller.
CMD_SINK="$(cfg notifications.cmd "")"
if [ -n "$CMD_SINK" ]; then
  CMD_TIMEOUT_S="$(cfg notifications.cmd_timeout_s "10")"
  case "$CMD_TIMEOUT_S" in
    ''|*[!0-9]*) CMD_TIMEOUT_S=10 ;;
  esac
  [ "$CMD_TIMEOUT_S" -gt 0 ] 2>/dev/null || CMD_TIMEOUT_S=10

  # Stdin payload: {event, ref, message, thread_key, fields, repo, issue}.
  # message is the same rendered TEXT every other sink builds its message
  # from; fields reuses NFIELDS (already built as a JSON array above).
  CMD_PAYLOAD="$(
    NC_EVENT="$EVENT" NC_REF="$REF" NC_MSG="$TEXT" NC_THREAD="$THREAD_KEY" \
    NC_FIELDS="$NFIELDS" NC_REPO="${_NOTIFY_REPO:-}" NC_ISSUE="${_num:-}" \
    python3 -c '
import json
import os
import sys


def _int_or_none(raw):
    raw = (raw or "").strip()
    if raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        return raw


try:
    fields = json.loads(os.environ.get("NC_FIELDS") or "[]")
except Exception:
    fields = []

payload = {
    "event": os.environ.get("NC_EVENT", ""),
    "ref": os.environ.get("NC_REF", ""),
    "message": os.environ.get("NC_MSG", ""),
    "thread_key": os.environ.get("NC_THREAD", ""),
    "fields": fields,
    "repo": os.environ.get("NC_REPO", ""),
    "issue": _int_or_none(os.environ.get("NC_ISSUE")),
}
json.dump(payload, sys.stdout)
'
  )"

  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] CMD cmd=$CMD_SINK timeout_s=$CMD_TIMEOUT_S payload=$CMD_PAYLOAD"
  else
    # Portable timeout: the command runs as its own process group (set -m)
    # and a background watchdog subshell sends it SIGTERM, then SIGKILL
    # shortly after, once CMD_TIMEOUT_S elapses -- the same pattern
    # pipeline-hooks.sh's hooks.pre_dispatch uses (#219/#181). Not reused
    # directly: that logic lives inline inside pre_dispatch(), interleaved
    # with hook-specific JSON building, and isn't exposed as a standalone
    # sourceable function, so this mirrors the pattern instead of calling
    # into pipeline-hooks.sh. `wait` on the command's pid returns non-zero
    # for both a real command failure and a kill-by-timeout, and both are
    # treated identically here -- one stderr note, continue.
    CMD_IN_FILE="$(mktemp "${TMPDIR:-/tmp}/talos-notify-cmd-in.XXXXXX" 2>/dev/null)"
    if [ -z "$CMD_IN_FILE" ]; then
      echo "pipeline-notify: notifications.cmd skipped (mktemp failed)" >&2
    else
      printf '%s' "$CMD_PAYLOAD" > "$CMD_IN_FILE"

      set -m
      sh -c "$CMD_SINK" < "$CMD_IN_FILE" >/dev/null 2>&1 &
      CMD_PID=$!
      set +m

      set -m
      ( sleep "$CMD_TIMEOUT_S"
        kill -TERM -"$CMD_PID" 2>/dev/null
        sleep 0.2
        kill -KILL -"$CMD_PID" 2>/dev/null
      ) &
      CMD_WATCHDOG_PID=$!
      set +m

      CMD_RC=0
      wait "$CMD_PID" 2>/dev/null
      CMD_RC=$?

      # Kill the watchdog's whole process group so its "sleep
      # $CMD_TIMEOUT_S" child is reaped too, not just the subshell leader.
      kill -- -"$CMD_WATCHDOG_PID" 2>/dev/null
      wait "$CMD_WATCHDOG_PID" 2>/dev/null

      rm -f "$CMD_IN_FILE"

      if [ "$CMD_RC" -ne 0 ]; then
        echo "pipeline-notify: notifications.cmd exited non-zero or timed out (rc=$CMD_RC) -- skipping" >&2
      fi
    fi
  fi
fi

exit 0
