#!/usr/bin/env bash
# pipeline-notify.sh — post a pipeline event to Slack, Discord, Teams, and/or Buzz.
#
# Usage: pipeline-notify.sh <event> <ref> <message> [thread_key]
#   event       pr-opened | merged | blocked | issue-closed | info
#   ref         issue/PR identifier shown in the message (e.g. "#42")
#   message     free text describing the event
#   thread_key  optional; used to group all events for one issue into a single
#               platform thread. Pass the issue number (e.g. "42"). Defaults to
#               <ref>. Orchestrator should always pass the issue number so PR
#               events and validator events land in the same thread.
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
#   buzz_event_id. If buzz is configured but nak is missing, buzz is skipped
#   with a warning; the pipeline never breaks.
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
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

EVENT="${1:-info}"
REF="${2:-}"
MSG="${3:-}"
THREAD_KEY="${4:-$REF}"

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
if [ -n "$CONFIGURED_EVENTS" ]; then
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
if [ -n "$TITLE" ]; then REF_TITLE="$REF_DISP: $TITLE"; else REF_TITLE="$REF_DISP"; fi

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
  *)            ICON="ℹ️"  ;;
esac

TEXT="$ICON [talos] $EVENT $REF — $MSG${PRIMARY_URL:+ ($PRIMARY_URL)}"

# ── Template rendering ────────────────────────────────────────────────────────
TMPL_DIR_CFG="$(cfg notifications.templates_dir "templates/notifications")"
if [ -n "$TMPL_DIR_CFG" ]; then
  # Absolute path: use as-is. Relative: caller's cwd first, then delegate to
  # _resolve_talos_dir() (sourced from pipeline-paths.sh above) which implements
  # the canonical 5-location probe and returns the scripts dir. Templates live
  # one level up from scripts, so we cd to the parent.
  case "$TMPL_DIR_CFG" in
    /*) TMPL_FILE="$TMPL_DIR_CFG/$EVENT.md" ;;
    *)  TMPL_FILE="$PWD/$TMPL_DIR_CFG/$EVENT.md"
        if [ ! -f "$TMPL_FILE" ]; then
          _tmpl_scripts="$(_resolve_talos_dir pipeline-notify.sh 2>/dev/null || true)"
          if [ -n "$_tmpl_scripts" ]; then
            TMPL_FILE="$(cd "$_tmpl_scripts/.." && pwd)/$TMPL_DIR_CFG/$EVENT.md"
          else
            TMPL_FILE="$REPO_ROOT/$TMPL_DIR_CFG/$EVENT.md"
          fi
        fi ;;
  esac
  if [ -f "$TMPL_FILE" ]; then
    RENDERED="$(ICON="$ICON" REF="$REF" MSG="$MSG" EVENT="$EVENT" \
      ROLE="$ROLE" TITLE="$TITLE" REF_TITLE="$REF_TITLE" \
      PR="$PR" PR_TITLE="$PR_TITLE" PR_REF="$PR_REF" BOARD="$BOARD" \
      ISSUE_URL="$ISSUE_URL" PR_URL="$PR_URL" \
      REF_LINK="$REF_LINK" PR_LINK="$PR_LINK" \
      python3 -c "
import os, string, sys
try:
    with open(sys.argv[1]) as f:
        t = string.Template(f.read())
    result = t.safe_substitute(os.environ).strip()
    if result:
        print(result)
except Exception:
    pass
" "$TMPL_FILE" 2>/dev/null)"
    [ -n "$RENDERED" ] && TEXT="$RENDERED"
  fi
fi

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
PAYLOAD_TEXT="$(json_escape "$TEXT")"

# ── Threading setup ───────────────────────────────────────────────────────────
THREADING_ENABLED="$(cfg notifications.threading "true")"
STATE_FILE="${PIPELINE_THREAD_STATE:-$HOME/.talos/threads.json}"

# Repo slug: namespaces thread anchors so multiple repos don't collide.
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

STATE_KEY="${REPO_SLUG}:${THREAD_KEY}"

# Python helper for thread anchor state. Uses env vars STATE_FILE and STATE_KEY
# to avoid quoting issues. Never crashes on corrupt/missing state files.
_thread_state() {
  STATE_FILE="$STATE_FILE" STATE_KEY="$STATE_KEY" python3 - "$@" <<'PYEOF'
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
# First line of the rendered text = title; remaining lines = body.
NTITLE="$(printf '%s\n' "$TEXT" | head -1)"
NBODY="$(printf '%s\n' "$TEXT" | tail -n +2 | sed '/./,$!d')"
[ -z "$NBODY" ] && NBODY="$NTITLE"
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

# Two body variants, because only the card carries the metadata.
#
# NBODY keeps the template's trailing "🔗 …" line and is used for thread
# REPLIES, where that link is the only one in the message. NBODY_CARD drops it
# and is used for ROOT posts, where it would merely repeat the PR/issue link
# already in the fields. Each template spells the line exactly "🔗 ${PR_LINK}"
# or "🔗 ${REF_LINK}", so matching the prefix is a defined rule, not a guess.
NBODY_CARD="$(printf '%s\n' "$NBODY" | grep -v '^🔗 ' | sed '/./,$!d')"
[ -z "$NBODY_CARD" ] && NBODY_CARD="$NTITLE"

# ── Shared monospace grid ────────────────────────────────────────────────────
# One pre-aligned plain-text grid, reused verbatim by every sink. Slack mrkdwn
# has no table syntax — a pipe table posts as literal pipes — so a fixed-width
# block inside a code fence (a Monospace TextBlock on Teams) is the only
# construct that renders as the same aligned grid on all four platforms.
#
# The comment is wrapped onto continuation lines aligned under the value column
# rather than truncated: agent verdicts carry the actual finding, and a card
# that silently drops half of one is worse than a slightly tall card. Links are
# NOT put in here — no platform makes a URL clickable inside a code block — so
# each sink appends its own link line underneath in its own syntax.
NGRID="$(NFIELDS="$NFIELDS" NBODY_CARD="$NBODY_CARD" python3 - <<'PY'
import json, os, re, textwrap
rows = []
comment = re.sub(r'\s*\n+\s*', ' ', os.environ.get('NBODY_CARD', '')).strip()
if comment:
    rows.append(("Comment", comment))
for f in json.loads(os.environ.get('NFIELDS') or '[]'):
    rows.append((f["label"], f["text"]))
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

_slack_payload() {  # $1=thread_ts (may be empty) $2=mode: bot|webhook
  NTITLE="$NTITLE" NBODY="$NBODY" NBODY_CARD="$NBODY_CARD" NCTX="$NCONTEXT" NCOLOR="$NCOLOR" \
  NFIELDS="$NFIELDS" NGRID="$NGRID" \
  NCHANNEL="$SLACK_CHANNEL" NTHREAD="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
raw_title = os.environ['NTITLE']
title = re.sub(r'[*_`]', '', raw_title).strip()   # plain text for notification/fallback
# A post with no thread anchor is the first message for this issue — the root —
# and carries the full metadata card. Replies stay light so a thread does not
# repeat the same PR/Issue/Repo block on every stage. Recovery reposts pass an
# empty anchor and are correctly treated as new roots.
is_root = not os.environ['NTHREAD']
body  = os.environ['NBODY_CARD'] if is_root else os.environ['NBODY']
# Daedalus-style: one cohesive markdown message, NOT a heavy Slack header block.
full = raw_title
if body and body.strip() and body.strip() != raw_title.strip():
    full = raw_title + "\n\n" + body
# Slack mrkdwn uses *single* asterisks for bold and <url|text> links.
# Templates author in daedalus/CommonMark style (**bold**, [text](url)); convert.
full = re.sub(r'\*\*([^*\n]+)\*\*', r'*\1*', full)          # **bold** -> *bold*
full = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<\2|\1>', full)  # [text](url) -> <url|text>
# Root: title, the shared monospace grid (which already carries the comment),
# then a clickable link row — URLs are inert inside a code block, so they live
# underneath it. Replies keep the plain title+body rendering.
grid = os.environ.get('NGRID', '')
if is_root and grid:
    parts = [raw_title, "```\n" + grid + "\n```"]
    links = [
        "<{}|{} {}>".format(f["url"], f["label"], f["text"])
        for f in json.loads(os.environ.get('NFIELDS') or '[]') if f.get("url")
    ]
    if links:
        parts.append(" · ".join(links))
    full = "\n".join(parts)
    full = re.sub(r'\*\*([^*\n]+)\*\*', r'*\1*', full)
blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": full[:3000]}}]
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
print(json.dumps(p))
PY
}

_discord_payload() {  # $1=anchor msg id (may be empty) $2=mode: bot|webhook
  NTITLE="$NTITLE" NBODY="$NBODY" NBODY_CARD="$NBODY_CARD" NCTX="$NCONTEXT" NCOLOR_INT="$NCOLOR_INT" \
  NFIELDS="$NFIELDS" NGRID="$NGRID" \
  NURL="$PRIMARY_URL" NANCHOR="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
title = re.sub(r'[*_`]', '', os.environ['NTITLE']).strip()
# No anchor => first message for this issue => full metadata card; replies light.
is_root = not os.environ['NANCHOR']
_raw_body = os.environ['NBODY_CARD'] if is_root else os.environ['NBODY']
# Discord bold is **…**; templates use Slack-style single *…* — upconvert.
body = re.sub(r'(?<!\*)\*([^*\n]+)\*(?!\*)', r'**\1**', _raw_body)
p = {
    "embeds": [{
        "title": title[:256],
        "description": body[:3900],
        "color": int(os.environ['NCOLOR_INT']),
        "footer": {"text": os.environ['NCTX'][:2048]},
    }],
}
# Root: the same monospace grid every other sink shows, with a clickable link
# row beneath it (URLs are inert inside a code block). Embed fields are
# deliberately unused — they would render a second, differently-shaped copy of
# the metadata already in the grid.
_grid = os.environ.get('NGRID', '')
if is_root and _grid:
    _links = " · ".join(
        "[{} {}]({})".format(f["label"], f["text"], f["url"])
        for f in json.loads(os.environ.get('NFIELDS') or '[]') if f.get("url")
    )
    _desc = "```\n" + _grid + "\n```"
    if _links:
        _desc += "\n" + _links
    p["embeds"][0]["description"] = _desc[:3900]
if os.environ.get('NURL'):
    p["embeds"][0]["url"] = os.environ['NURL']
if os.environ['NMODE'] == 'bot' and os.environ['NANCHOR']:
    p["message_reference"] = {"message_id": os.environ['NANCHOR'], "fail_if_not_exists": False}
print(json.dumps(p))
PY
}

# ── Slack ─────────────────────────────────────────────────────────────────────
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  # Webhook mode — threading not supported (Slack incoming webhooks have no thread_ts)
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] SLACK (webhook, no threading): $TEXT"
  else
    post "$SLACK_WEBHOOK_URL" "$(_slack_payload "" webhook)" slack >/dev/null 2>&1 \
      || echo "pipeline-notify: slack webhook delivery failed" >&2
  fi
elif [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "$SLACK_CHANNEL" ]; then
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
  # Webhook mode — threading not supported (Discord webhooks cannot target message threads)
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] DISCORD (webhook, no threading): $TEXT"
  else
    post "$DISCORD_WEBHOOK_URL" "$(_discord_payload "" webhook)" discord >/dev/null 2>&1 \
      || echo "pipeline-notify: discord webhook delivery failed" >&2
  fi
elif [ -n "${DISCORD_BOT_TOKEN:-}" ] && [ -n "$DISCORD_CHANNEL" ]; then
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
            _dc_name="$(printf '%s' "${REF:-$EVENT}${NTITLE:+ — $NTITLE}" | tr '\n' ' ' | cut -c1-95)"
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
  # Built with python3 rather than shell interpolation so the FactSet — the
  # Adaptive Card equivalent of the Buzz table and Slack/Discord fields — is
  # assembled as real JSON. Facts render as an aligned label/value grid.
  # Built unconditionally so debug mode can print the real payload rather than
  # a text approximation; Teams cannot thread, so every post is a root card.
  TEAMS_PAYLOAD="$(NTITLE="$NTITLE" NGRID="$NGRID" NCTX="$NCONTEXT" NFIELDS="$NFIELDS" python3 - <<'PY'
import json, os
# Same card as every other sink: title, monospace grid, link row, context.
# Adaptive Cards do not render markdown code fences, so the grid goes in a
# TextBlock with fontType Monospace — the Teams equivalent of a fenced block.
# (No literal fence characters in this comment: this heredoc sits inside a
# $( … ), where bash scans for the closing paren and an odd number of
# backticks silently breaks the parse of the whole file.)
body = [{"type": "TextBlock", "wrap": True, "weight": "Bolder", "size": "Medium",
         "text": os.environ['NTITLE']}]
grid = os.environ.get('NGRID', '')
if grid:
    body.append({"type": "TextBlock", "wrap": True, "fontType": "Monospace",
                 "text": grid})
links = " · ".join(
    "[{} {}]({})".format(f["label"], f["text"], f["url"])
    for f in json.loads(os.environ.get('NFIELDS') or '[]') if f.get("url")
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
}))
PY
)"
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] TEAMS payload=$TEAMS_PAYLOAD"
  else
    post "$TEAMS_WEBHOOK_URL" "$TEAMS_PAYLOAD" teams >/dev/null 2>&1 \
      || echo "pipeline-notify: teams webhook delivery failed" >&2
  fi
fi

# ── Buzz (Nostr kind:9 via nak — key-based, threads via NIP-10 replies) ──────
if [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_BOT_PRIVATE_KEY:-}" ] && [ -n "$BUZZ_CHANNEL" ]; then
  BUZZ_ANCHOR=""
  if [ "$THREADING_ENABLED" = "true" ]; then
    BUZZ_ANCHOR="$(_thread_state get buzz_event_id)"
  fi

  # Buzz renders GitHub-Flavored Markdown (remark-gfm + remark-breaks), so it
  # supports headings and tables — neither of which Slack's mrkdwn can do. The
  # sink builds a card: heading, body, then a metadata table carrying the links.
  #
  # The table replaces the template's trailing "🔗 …" line, which would
  # otherwise repeat the PR/issue title already shown in the heading. Every
  # template spells that line exactly "🔗 ${PR_LINK}" or "🔗 ${REF_LINK}", so
  # dropping lines with that prefix is well-defined rather than a guess.
  #
  # Rows are emitted only when they have a value — a fixed row set would render
  # empty cells for issue-only events, which have no PR. Severity stays in the
  # per-event emoji the templates already carry: GFM has no colour, and
  # spelling out BLOCKED would only duplicate 🚫.
  # Root posts get the full card; replies stay light so a thread does not repeat
  # the same PR/Issue/Repo block under every stage. The anchor is the signal:
  # absent => this is the first message for the issue.
  if [ -z "$BUZZ_ANCHOR" ]; then
    # Buzz could render a real GFM table, but it deliberately shows the same
    # monospace grid as everywhere else — the point is one identical card across
    # all four platforms, and Slack/Discord/Teams cannot do tables at all.
    _buzz_links="$(NFIELDS="$NFIELDS" python3 - <<'PY'
import json, os
print(" · ".join(
    "[{} {}]({})".format(f["label"], f["text"], f["url"])
    for f in json.loads(os.environ.get('NFIELDS') or '[]') if f.get("url")
))
PY
)"
    # The fence lives in a variable: a literal ``` inside $( … ) is parsed as
    # legacy backtick command substitution and breaks the file.
    _fence='```'
    BUZZ_TEXT="$(
      printf '### %s\n' "$NTITLE"
      [ -n "$NGRID" ] && printf '\n%s\n%s\n%s\n' "$_fence" "$NGRID" "$_fence"
      [ -n "$_buzz_links" ] && printf '\n%s\n' "$_buzz_links"
    )"
  else
    # Light reply: the rendered template as-is, keeping its "🔗 …" line, which
    # is the only link a reply carries.
    BUZZ_TEXT="$TEXT"
  fi

  # nak exits 0 even when the relay REJECTS the event, and prints the
  # locally-signed JSON to stdout regardless (it signs before publishing). So
  # neither the exit code nor stdout distinguishes success from failure — an id
  # parsed from that stdout can be an event the relay never stored, which then
  # gets persisted as a thread anchor and makes a dead sink look healthy.
  # The relay's actual verdict is only on stderr, so capture and inspect it.
  _buzz_publish() {  # $1=anchor event id (may be empty); prints nak stdout, non-zero on rejection
    _buzz_err="$(mktemp)"
    if [ -n "$1" ]; then
      _buzz_out="$(nak event --auth --sec "$BUZZ_BOT_PRIVATE_KEY" -k 9 -c "$BUZZ_TEXT" \
        -t "h=$BUZZ_CHANNEL" -t "e=$1;;reply" "$BUZZ_RELAY_URL" 2>"$_buzz_err")"
    else
      _buzz_out="$(nak event --auth --sec "$BUZZ_BOT_PRIVATE_KEY" -k 9 -c "$BUZZ_TEXT" \
        -t "h=$BUZZ_CHANNEL" "$BUZZ_RELAY_URL" 2>"$_buzz_err")"
    fi
    _buzz_rc=$?
    _buzz_msg="$(cat "$_buzz_err" 2>/dev/null)"
    rm -f "$_buzz_err"
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
    if resp="$(_buzz_publish "$BUZZ_ANCHOR")"; then
      # Store the root event id as the thread anchor for the first post
      if [ "$THREADING_ENABLED" = "true" ] && [ -z "$BUZZ_ANCHOR" ]; then
        NEW_ID="$(_buzz_event_id "$resp")"
        [ -n "$NEW_ID" ] && _thread_state set buzz_event_id "$NEW_ID"
      fi
    elif [ -n "$BUZZ_ANCHOR" ]; then
      # Reply rejected (Buzz rejects replies to unknown parents) — clear the
      # stale anchor and repost as a fresh root, mirroring Slack recovery.
      _thread_state clear buzz_event_id
      if resp2="$(_buzz_publish "")"; then
        if [ "$THREADING_ENABLED" = "true" ]; then
          NEW_ID="$(_buzz_event_id "$resp2")"
          [ -n "$NEW_ID" ] && _thread_state set buzz_event_id "$NEW_ID"
        fi
      else
        echo "pipeline-notify: buzz retry (stale anchor recovery) failed" >&2
      fi
    else
      echo "pipeline-notify: buzz publish failed" >&2
    fi
  fi
fi

exit 0
