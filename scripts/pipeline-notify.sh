#!/usr/bin/env bash
# pipeline-notify.sh — post a pipeline event to Slack, Discord, and/or Teams.
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
# Threading (bot-token mode only):
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
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

EVENT="${1:-info}"
REF="${2:-}"
MSG="${3:-}"
THREAD_KEY="${4:-$REF}"

# ── Load repo .env if present ─────────────────────────────────────────────────
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ENV="$REPO_ROOT/.env"
# shellcheck disable=SC1090
[ -f "$REPO_ENV" ] && . "$REPO_ENV"

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

# ── Bot tokens from Hermes env (optional convenience) ─────────────────────────
HERMES_ENV="$HOME/.hermes/.env"
if [ -f "$HERMES_ENV" ]; then
  [ -z "${SLACK_BOT_TOKEN:-}" ]   && SLACK_BOT_TOKEN="$(grep -m1 '^SLACK_BOT_TOKEN='   "$HERMES_ENV" | cut -d= -f2-)"
  [ -z "${DISCORD_BOT_TOKEN:-}" ] && DISCORD_BOT_TOKEN="$(grep -m1 '^DISCORD_BOT_TOKEN=' "$HERMES_ENV" | cut -d= -f2-)"
fi

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

# Board name (owner-repo). Override with PIPELINE_BOARD.
BOARD="${PIPELINE_BOARD:-}"
[ -z "$BOARD" ] && BOARD="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-')"
[ -z "$BOARD" ] && BOARD="$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"

# Issue number + title. Prefer caller-supplied PIPELINE_ISSUE_TITLE; else fetch.
_num="$(printf '%s' "${REF:-$THREAD_KEY}" | tr -cd '0-9')"
TITLE="${PIPELINE_ISSUE_TITLE:-}"
[ -z "$TITLE" ] && [ -n "$_num" ] && TITLE="$(gh issue view "$_num" --json title -q .title 2>/dev/null || true)"
REF_DISP="${REF:-#$_num}"
if [ -n "$TITLE" ]; then REF_TITLE="$REF_DISP: $TITLE"; else REF_TITLE="$REF_DISP"; fi

# PR number + title. Prefer PIPELINE_PR/PIPELINE_PR_TITLE; else parse MSG, then fetch.
PR="${PIPELINE_PR:-}"
[ -z "$PR" ] && PR="$(printf '%s' "$MSG" | grep -oE '(pull/|PR #?)[0-9]+' | grep -oE '[0-9]+' | head -1)"
PR_TITLE="${PIPELINE_PR_TITLE:-}"
[ -z "$PR_TITLE" ] && [ -n "$PR" ] && PR_TITLE="$(gh pr view "$PR" --json title -q .title 2>/dev/null || true)"
if [ -n "$PR" ]; then
  if [ -n "$PR_TITLE" ]; then PR_REF="PR #$PR: $PR_TITLE"; else PR_REF="PR #$PR"; fi
else
  PR_REF="$REF_DISP"
fi

# Issue/PR URLs so messages can link back to GitHub. Override with PIPELINE_REPO_URL.
REPO_URL="${PIPELINE_REPO_URL:-}"
[ -z "$REPO_URL" ] && REPO_URL="$(gh repo view --json url -q .url 2>/dev/null || true)"
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
  # Absolute path: use as-is. Relative: caller's cwd first, then the
  # Talos repo's bundled templates as fallback.
  case "$TMPL_DIR_CFG" in
    /*) TMPL_FILE="$TMPL_DIR_CFG/$EVENT.md" ;;
    *)  TMPL_FILE="$PWD/$TMPL_DIR_CFG/$EVENT.md"
        [ -f "$TMPL_FILE" ] || TMPL_FILE="$REPO_ROOT/$TMPL_DIR_CFG/$EVENT.md" ;;
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

_slack_payload() {  # $1=thread_ts (may be empty) $2=mode: bot|webhook
  NTITLE="$NTITLE" NBODY="$NBODY" NCTX="$NCONTEXT" NCOLOR="$NCOLOR" \
  NCHANNEL="$SLACK_CHANNEL" NTHREAD="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
raw_title = os.environ['NTITLE']
title = re.sub(r'[*_`]', '', raw_title).strip()   # plain text for notification/fallback
body  = os.environ['NBODY']
# Daedalus-style: one cohesive markdown message, NOT a heavy Slack header block.
full = raw_title
if body and body.strip() and body.strip() != raw_title.strip():
    full = raw_title + "\n\n" + body
# Slack mrkdwn uses *single* asterisks for bold and <url|text> links.
# Templates author in daedalus/CommonMark style (**bold**, [text](url)); convert.
full = re.sub(r'\*\*([^*\n]+)\*\*', r'*\1*', full)          # **bold** -> *bold*
full = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<\2|\1>', full)  # [text](url) -> <url|text>
p = {
    "text": title,
    "blocks": [
        {"type": "section", "text": {"type": "mrkdwn", "text": full[:3000]}},
        {"type": "context", "elements": [{"type": "mrkdwn", "text": os.environ['NCTX']}]},
    ],
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
  NTITLE="$NTITLE" NBODY="$NBODY" NCTX="$NCONTEXT" NCOLOR_INT="$NCOLOR_INT" \
  NURL="$PRIMARY_URL" NANCHOR="$1" NMODE="$2" python3 - <<'PY'
import json, os, re
title = re.sub(r'[*_`]', '', os.environ['NTITLE']).strip()
# Discord bold is **…**; templates use Slack-style single *…* — upconvert.
body = re.sub(r'(?<!\*)\*([^*\n]+)\*(?!\*)', r'**\1**', os.environ['NBODY'])
p = {
    "embeds": [{
        "title": title[:256],
        "description": body[:3900],
        "color": int(os.environ['NCOLOR_INT']),
        "footer": {"text": os.environ['NCTX'][:2048]},
    }],
}
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
  # Bot-token mode — threading via message_reference
  DISCORD_ANCHOR=""
  if [ "$THREADING_ENABLED" = "true" ]; then
    DISCORD_ANCHOR="$(_thread_state get discord_msg_id)"
  fi

  # fail_if_not_exists:false (in the builder) means Discord silently falls back
  # to a top-level message if the referenced anchor was deleted.
  DISCORD_PAYLOAD="$(_discord_payload "$DISCORD_ANCHOR" bot)"

  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] DISCORD (bot) state_key=$STATE_KEY"
    echo "[pipeline-notify DEBUG] DISCORD thread_anchor=${DISCORD_ANCHOR:-(none — root post)}"
    echo "[pipeline-notify DEBUG] DISCORD payload=$DISCORD_PAYLOAD"
  else
    resp="$(post "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
      "$DISCORD_PAYLOAD" discord "Authorization: Bot $DISCORD_BOT_TOKEN" 2>/dev/null)"

    case "$resp" in
      *'"id"'*)
        # Store message id as anchor for the first (root) post
        if [ "$THREADING_ENABLED" = "true" ] && [ -z "$DISCORD_ANCHOR" ]; then
          NEW_ID="$(_extract_json_field "$resp" id)"
          [ -n "$NEW_ID" ] && _thread_state set discord_msg_id "$NEW_ID"
        fi
        ;;
      *) echo "pipeline-notify: discord api delivery failed: $(printf '%s' "$resp" | head -c 200)" >&2 ;;
    esac
  fi
fi

# ── Teams (webhook only — no threading) ──────────────────────────────────────
if [ -n "${TEAMS_WEBHOOK_URL:-}" ]; then
  if [ "${PIPELINE_NOTIFY_DEBUG:-}" = "1" ]; then
    echo "[pipeline-notify DEBUG] TEAMS (webhook, no threading): $TEXT"
  else
    post "$TEAMS_WEBHOOK_URL" "{
      \"type\": \"message\",
      \"attachments\": [{
        \"contentType\": \"application/vnd.microsoft.card.adaptive\",
        \"content\": {
          \"type\": \"AdaptiveCard\", \"version\": \"1.4\",
          \"body\": [{\"type\": \"TextBlock\", \"wrap\": true, \"text\": $PAYLOAD_TEXT}]
        }
      }]
    }" teams >/dev/null 2>&1 || echo "pipeline-notify: teams webhook delivery failed" >&2
  fi
fi

exit 0
