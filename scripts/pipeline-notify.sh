#!/usr/bin/env bash
# pipeline-notify.sh — post a pipeline event to Slack, Discord, Teams, Buzz and/or a command.
#
# Usage: pipeline-notify.sh <event> <ref> <message> [thread_key]
#        pipeline-notify.sh --render <platform> <event> [ref] [message]
#   event       pr-opened | merged | blocked | issue-closed | info | <role> ...
#   ref         issue/PR identifier shown in the message (e.g. "#42")
#   message     free text; exactly "-" reads it from stdin (#342), so agent text
#               never has to sit inside shell quotes (pass a heredoc)
#   thread_key  groups all events of one issue into one platform thread; the
#               orchestrator passes the issue number. Defaults to <ref>.
#
# Design (#552): one neutral template per event (**bold**, [text](url), "- "
# bullets, at most one "### " heading) is rendered and transpiled per sink by the
# formatter (_fmt, inline python): each platform is a small formatter, a payload
# shape plus a markdown dialect. Delivery goes through ONE sender, post() (bounded
# curl, secrets on stdin, fail-soft), shared by Slack, Discord and Teams. Buzz
# keeps its own transport (nak) but shares the rendering, the thread state and the
# bounded call (pipeline-bounded.sh). Template resolution per platform, first hit:
#   project/<platform>/<event>.md -> project/<event>.md
#     -> install/<platform>/<event>.md -> install/<event>.md
# Talos ships only the neutral ones; a sink is "rich" (native metadata) whenever a
# template resolved, otherwise it shows the monospace grid. --render <platform>
# (slack|discord|teams|buzz|default) prints the payload without posting or
# touching thread state; an unknown platform is this script's one exit 2.
#
# Delivery per platform, first match wins:
#   1. webhook    SLACK_WEBHOOK_URL / DISCORD_WEBHOOK_URL / TEAMS_WEBHOOK_URL
#   2. bot token  SLACK_BOT_TOKEN / DISCORD_BOT_TOKEN into notifications.slack_channel /
#                 discord_channel (or PIPELINE_SLACK_CHANNEL / PIPELINE_DISCORD_CHANNEL)
# Secrets (#443) come from pipeline-secrets.sh: exported env, repo .env, an
# `env:NAME` config reference, ~/.talos/.env, legacy ~/.hermes/.env. They reach
# curl on stdin (-K -) or nak through its environment, never argv or a log.
#
# Buzz (Nostr/NIP-29, no webhooks): a signed kind:9 event tagged ["h", channel]
# published by the `nak` CLI, which also answers NIP-42 AUTH. Needs BUZZ_RELAY_URL
# (or notifications.buzz_relay), BUZZ_BOT_PRIVATE_KEY and notifications.buzz_channel
# / PIPELINE_BUZZ_CHANNEL. A reply carries the NIP-10 tag ["e", <root>, "", "reply"];
# the key goes in NOSTR_SECRET_KEY (#281); each nak call is bounded by
# notifications.buzz_timeout_s (default 15).
#
# Threading (bot tokens and Buzz; webhooks cannot thread): with
# notifications.threading (default true) every event of one thread_key replies to
# the first message. Anchors live in ${PIPELINE_THREAD_STATE:-~/.talos/threads.json}.
#
# notifications.cmd (#184): any other sink. `sh -c` with {event, ref, message,
# thread_key, fields:[{label,text,url}], repo, issue} JSON on stdin, bounded by
# notifications.cmd_timeout_s (default 10). It runs last.
#
# PIPELINE_NOTIFY_DEBUG=1 prints what each sink would send and posts nothing.
# notifications.events filters events. A sink with no credentials is a no-op.
# Always exits 0 (bar the --render usage error): a notification failure must never
# break the pipeline.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pipeline-paths.sh
. "$SCRIPT_DIR/pipeline-paths.sh"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh: that is fatal
# (no per-call fallback: it would hide the fail-closed exit of a broken table).
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi
# talos_bounded / talos_pos_int (#552), shared with pipeline-hooks.sh.
if [ -f "$SCRIPT_DIR/pipeline-bounded.sh" ]; then
  . "$SCRIPT_DIR/pipeline-bounded.sh"
else
  echo "talos: pipeline-bounded.sh missing; reinstall Talos" >&2
  exit 1
fi
# with_lock (#180) serializes the threads.json read-modify-write; unlocked fallback.
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
RENDER_ONLY=""
if [ "$EVENT" = "--render" ]; then
  RENDER_ONLY="${2:-default}"
  EVENT="${3:-info}"
  REF="${4:-#0}"
  MSG="${5:-Sample message body for template preview.}"
  THREAD_KEY="$REF"
fi

# "-" reads the message from stdin (#342). A closed fd 0 would make "$(cat)" hang
# and a terminal would wait for a human, so both are refused: one stderr line,
# nothing sent, exit 0. (`: <&0` would be a no-op dup, so probe with a dup onto fd 3.)
if [ "$MSG" = "-" ]; then
  if [ -t 0 ] || ! { : 3<&0; } 2>/dev/null; then
    echo "pipeline-notify: message '-' needs text on stdin (a heredoc), but stdin is closed or a terminal; nothing sent" >&2
    exit 0
  fi
  MSG="$(cat)"
fi
case "$RENDER_ONLY" in
  ''|slack|discord|teams|buzz|default) ;;
  *) echo "pipeline-notify: --render: unknown platform '$RENDER_ONLY' (slack|discord|teams|buzz|default)" >&2; exit 2 ;;
esac

# Cap the message before any exec (#342): it travels to python in the environment
# and to curl as one -d argument (JSON-escaped, up to 6x), and Linux fails an exec
# over 128 KiB per string. Cut at a UTF-8 boundary, mark it, say so on stderr.
_NOTIFY_MSG_MAX=16384
_msg_bytes="$(printf '%s' "$MSG" | wc -c | tr -d ' ')"
if [ "${_msg_bytes:-0}" -gt "$_NOTIFY_MSG_MAX" ]; then
  MSG="$(printf '%s' "$MSG" | python3 -I -c '
import sys
b = sys.stdin.buffer.read()
n = int(sys.argv[1])
while n > 0 and (b[n] & 0xC0) == 0x80:
    n -= 1
sys.stdout.buffer.write(b[:n] + ("\n[message truncated to %d bytes]" % n).encode())
' "$_NOTIFY_MSG_MAX")"
  echo "pipeline-notify: message was $_msg_bytes bytes; truncated to at most $_NOTIFY_MSG_MAX bytes" >&2
fi
unset _msg_bytes

# Secrets: pipeline-secrets.sh parses the repo .env (never sources it) and exports
# only its allow-listed notification variables (#476): the checkout can be a PR
# branch, so its .env is not trusted to set anything else.
if [ -f "$SCRIPT_DIR/pipeline-secrets.sh" ]; then
  # shellcheck source=pipeline-secrets.sh
  . "$SCRIPT_DIR/pipeline-secrets.sh"
else
  echo "pipeline-notify: pipeline-secrets.sh missing; reinstall Talos (secrets are read from the exported environment only)" >&2
  talos_secret_load() { return 1; }
  talos_dotenv_load() { return 0; }
fi
ENV_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
talos_dotenv_load "${ENV_ROOT:-$PWD}/.env" "repo .env"
unset ENV_ROOT

CONFIGURED_EVENTS="$(cfg notifications.events)"
if [ -n "$CONFIGURED_EVENTS" ] && [ -z "$RENDER_ONLY" ] && ! grep -qxF "$EVENT" <<<"$CONFIGURED_EVENTS"; then
  exit 0
fi

SLACK_CHANNEL="${PIPELINE_SLACK_CHANNEL:-$(cfg notifications.slack_channel)}"
DISCORD_CHANNEL="${PIPELINE_DISCORD_CHANNEL:-$(cfg notifications.discord_channel)}"
BUZZ_CHANNEL="${PIPELINE_BUZZ_CHANNEL:-$(cfg notifications.buzz_channel)}"

if [ -z "$RENDER_ONLY" ]; then  # --render posts nothing, so it resolves nothing
  talos_secret_load SLACK_WEBHOOK_URL    notifications.slack.webhook url
  talos_secret_load DISCORD_WEBHOOK_URL  notifications.discord.webhook url
  talos_secret_load TEAMS_WEBHOOK_URL    notifications.teams.webhook url
  talos_secret_load SLACK_BOT_TOKEN      notifications.slack.bot_token
  talos_secret_load DISCORD_BOT_TOKEN    notifications.discord.bot_token
  talos_secret_load BUZZ_BOT_PRIVATE_KEY notifications.buzz.bot_key
  talos_secret_load BUZZ_RELAY_URL
fi
# The relay URL is a hostname, not a secret, so it may live in the committed
# config. Precedence: exported env > .env > config.
[ -z "${BUZZ_RELAY_URL:-}" ] && BUZZ_RELAY_URL="${PIPELINE_BUZZ_RELAY:-$(cfg notifications.buzz_relay)}"

# ── The sender ───────────────────────────────────────────────────────────────
# A webhook URL is a bearer credential and an auth header holds a bot token: both
# reach curl as a config on stdin (-K -), never argv, where `ps` shows them to
# every local user (#443). A control character could add lines to that config, so
# it is refused; backslash and double quote, the two characters a curl config
# string treats specially, are escaped.
_cfg_q() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
_curl() {  # $1=url $2=auth header (may be empty) [curl args...]
  local url="$1" auth="$2"
  shift 2
  case "$url$auth" in *[[:cntrl:]]*) echo "pipeline-notify: a credential holds a control character; not sending" >&2; return 1 ;; esac
  { printf 'url = "%s"\n' "$(_cfg_q "$url")"
    [ -z "$auth" ] || printf 'header = "%s"\n' "$(_cfg_q "$auth")"
  } | curl -sS -K - "$@"
}
post() {  # $1=url $2=json body [$3=auth header]; prints the response
  _curl "$1" "${3:-}" -m 10 -H 'Content-Type: application/json' -d "$2"
}

# ── Context (lookups only; every string transform lives in the formatter) ─────
_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
_meta() {  # $1=issue|pr|repo $2=number -> its title (repo: its url), from gh else REST
  if command -v gh >/dev/null 2>&1; then
    case "$1" in
      repo) gh repo view --json url -q .url ;;
      *)    gh "$1" view "$2" --json title -q .title ;;
    esac 2>/dev/null || true
    return 0
  fi
  [ -n "$_API_TOKEN" ] && [ -n "$_NOTIFY_REPO" ] || return 0
  local path="repos/$_NOTIFY_REPO"
  case "$1" in issue) path="$path/issues/$2" ;; pr) path="$path/pulls/$2" ;; esac
  _curl "https://api.github.com/$path" "Authorization: Bearer $_API_TOKEN" -m 5 -H "Accept: application/vnd.github+json" 2>/dev/null \
    | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("html_url" if sys.argv[1] == "repo" else "title", ""))
except Exception:
    pass' "$1" 2>/dev/null || true
}
_slug() {  # remote url -> "owner-name": namespaces thread anchors per repo
  local u="${1%.git}" IFS=/ n=0 a="" b="" p h
  case "$u" in http://*|https://*) u="${u#*://}"; u="${u#www.}" ;; esac
  case "$u" in git@*:*) h="${u#git@}"; u="${h%%:*}/${h#*:}" ;; esac
  set -f
  for p in $u; do [ -n "$p" ] && { a="$b"; b="$p"; n=$((n + 1)); }; done
  set +f
  if [ "$n" -ge 2 ]; then printf '%s-%s' "$a" "$b"; else printf '%s' "${u//\//-}"; fi
}

_remote="$(git -C "$PWD" remote get-url origin 2>/dev/null)"
_NOTIFY_REPO="${PIPELINE_REPO:-$(printf '%s' "$_remote" | sed 's|.*github\.com[:/]||; s|\.git$||')}"
REPO_SLUG="$(_slug "$_remote")"
[ -z "$REPO_SLUG" ] && REPO_SLUG="default"

BOARD="${PIPELINE_BOARD:-}"
[ -z "$BOARD" ] && BOARD="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-')"
[ -z "$BOARD" ] && BOARD="$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"

_num="$(printf '%s' "${REF:-$THREAD_KEY}" | tr -cd '0-9')"
TITLE="${PIPELINE_ISSUE_TITLE:-}"
[ -z "$TITLE" ] && [ -n "$_num" ] && TITLE="$(_meta issue "$_num")"
PR="${PIPELINE_PR:-}"
[ -z "$PR" ] && PR="$(printf '%s' "$MSG" | grep -oE '(pull/|PR #?)[0-9]+' | grep -oE '[0-9]+' | sed -n 1p)"
PR_TITLE="${PIPELINE_PR_TITLE:-}"
[ -z "$PR_TITLE" ] && [ -n "$PR" ] && PR_TITLE="$(_meta pr "$PR")"
REPO_URL="${PIPELINE_REPO_URL:-}"
[ -z "$REPO_URL" ] && REPO_URL="$(_meta repo)"

# Template roots (#280): the caller's project dir (an override) before the Talos
# install dir (the shipped defaults). An absolute notifications.templates_dir
# names exactly one root.
TMPL_ROOTS=""
_td="$(cfg notifications.templates_dir)"
case "$_td" in
  '') ;;
  /*) TMPL_ROOTS="$_td" ;;
  *)  _ts="$(_resolve_talos_dir pipeline-notify.sh 2>/dev/null || true)"
      if [ -n "$_ts" ]; then _ti="$(cd "$_ts/.." && pwd)/$_td"; else _ti="$(cd "$SCRIPT_DIR/.." && pwd)/$_td"; fi
      TMPL_ROOTS="$PWD/$_td"
      [ "$_ti" != "$TMPL_ROOTS" ] && TMPL_ROOTS="$TMPL_ROOTS
$_ti" ;;
esac
unset _td _ts _ti

# ── The formatter ────────────────────────────────────────────────────────────
# _fmt MODE [ARGS...] prints what one sink needs; the context travels as data in
# the environment (untrusted text never touches a shell or a python string).
#   payload <slack|discord|teams|buzz> <bot|bot_in_thread|webhook> <anchor>
#   dcthread   the body that starts a Discord thread from the root message
#   cmd        the notifications.cmd stdin JSON
#   text <p>   the transpiled message (debug)    render <label> <p>   --render
_fmt() {
  EVENT="$EVENT" REF="$REF" MSG="$MSG" THREAD_KEY="$THREAD_KEY" NUM="$_num" TITLE="$TITLE" \
  PR="$PR" PR_TITLE="$PR_TITLE" REPO_URL="$REPO_URL" REPO_SLUG="$REPO_SLUG" NOTIFY_REPO="$_NOTIFY_REPO" \
  BOARD="$BOARD" TMPL_ROOTS="$TMPL_ROOTS" SLACK_CHANNEL="$SLACK_CHANNEL" python3 -I - "$@" <<'PY'
import json, os, re, string, sys, textwrap
from types import SimpleNamespace

env = lambda k: os.environ.get(k, '')
event, ref, msg = env('EVENT'), env('REF'), env('MSG')
title, pr, pr_title, num = env('TITLE'), env('PR'), env('PR_TITLE'), env('NUM')
repo_url, slug, nrepo = env('REPO_URL'), env('REPO_SLUG'), env('NOTIFY_REPO')
repo = nrepo or slug
ZWSP = '​'


def defuse(v):
    # A run of 3+ backticks opens or closes a code fence. Externally influenced
    # text (titles, agent verdicts, repo names) must not be able to close the
    # fence a grid sits in, so split the run with zero-width spaces: it reads the
    # same and no longer delimits.
    return re.sub(r'`{3,}', lambda m: ZWSP.join(m.group(0)), v)


# ── Per-event tables ─────────────────────────────────────────────────────────
ICONS = {'merged': '✅', 'pr-opened': '🔀', 'blocked': '🛑', 'issue-closed': '🏁',
         'validator': '🔎', 'pm': '📋', 'developer': '🛠', 'qa': '🧪', 'reviewer': '👀',
         'security': '🔐', 'docs': '📚', 'orchestrator': '🤖', 'dispatched': '🧵'}
ROLES = {'validator': ('🔎', 'Validator'), 'pm': ('📝', 'PM'), 'developer': ('🛠', 'Developer'),
         'qa': ('🧪', 'QA'), 'reviewer': ('👀', 'Reviewer'), 'security': ('🔐', 'Security'),
         'docs': ('📚', 'Docs'), 'documentation': ('📚', 'Docs'), 'planner': ('🗺', 'Planner'),
         'adversarial': ('😈', 'Adversarial')}
ACTIONS = {'pr-opened': 'PR opened', 'merged': 'merged', 'blocked': 'blocked',
           'issue-closed': 'issue closed', 'dispatched': 'dispatched', 'info': 'info',
           'pm': 'spec posted', 'docs': 'docs updated', 'documentation': 'docs updated'}
ROLE_NAMES = {'pm': 'project-manager', 'security': 'security-analyst', 'documentation': 'documentation',
              'docs': 'documentation'}
GREEN, RED = ('#2ecc71', 3066993), ('#e74c3c', 15158332)
COLORS = {'merged': GREEN, 'issue-closed': GREEN, 'qa': GREEN, 'blocked': RED,
          'security': ('#e67e22', 15105570), 'reviewer': ('#9b59b6', 10181046)}
VERDICTS = ('RESTAMP_PASS', 'RESTAMP_FAIL', 'CONFIRMED', 'APPROVED', 'FINDINGS', 'CHANGES',
            'BLOCKED', 'MERGED', 'CLOSED', 'CLEAR', 'PASS', 'FAIL', 'DONE')
STAGES = ('validator', 'pm', 'developer', 'qa', 'reviewer', 'security', 'docs', 'planner',
          'adversarial', 'orchestrator')

# ── Context ──────────────────────────────────────────────────────────────────
icon = ICONS.get(event, 'ℹ️')
role_icon, role_label = ROLES.get(event, ('🤖', 'Talos'))
ref_disp = ref or '#' + num
ref_title = ref_disp + ' ' + title if title else ref_disp
pr_ref = ('PR #%s: %s' % (pr, pr_title) if pr_title else 'PR #' + pr) if pr else ref_disp
issue_url = repo_url + '/issues/' + num if repo_url and num else ''
pr_url = repo_url + '/pull/' + pr if repo_url and pr else ''
ref_link = '[%s](%s)' % (ref_title, issue_url) if issue_url else ref_title
pr_link = '[%s](%s)' % (pr_ref, pr_url) if pr_url else pr_ref
# The URL the whole message points at: the PR for PR events, the issue otherwise.
primary = (pr_url or issue_url) if event in ('pr-opened', 'merged') else (issue_url or pr_url)
text_plain = defuse('%s [talos] %s %s — %s%s' % (icon, event, ref, msg, ' (%s)' % primary if primary else ''))

# Agents open their message with a verdict token ("PASS: 9/9 criteria…"); lift it
# out of the body into the headline. The separator set is narrow on purpose
# (":", " — ", " - "): "PASSING the baton" and "FAIL-safe" are not verdicts.
m = re.match(r'^[ \t]*(' + '|'.join(VERDICTS) + r')(?:[ \t]*:|[ \t]+[—-])[ \t]*(.*)$', msg, re.S | re.I)
verdict, summary = (m.group(1).upper(), m.group(2)) if m else ('', msg)
summary = summary.strip()
# One unbroken line of semicolon-joined clauses is a wall of text in a chat client.
if '\n' not in summary and len(summary) > 160 and summary.count('; ') >= 2:
    lead, _, rest = summary.partition('; ')
    summary = lead + '\n\n' + '\n'.join('- ' + s for s in rest.split('; '))
action = ACTIONS.get(event, 'update')
# "blocked" is posted on behalf of whichever stage stopped, by convention as a
# leading "<stage>: ": lift that into the headline.
if event == 'blocked' and not verdict:
    m = re.match(r'^[ \t]*(' + '|'.join(STAGES) + r')[ \t]*:[ \t]*(.*)$', summary, re.S | re.I)
    if m:
        action, summary = 'blocked by ' + m.group(1).lower(), m.group(2).strip()
# A PR event's message is boilerplate; the PR title is what a human reads.
if event in ('pr-opened', 'merged', 'issue-closed') and pr_title:
    summary = pr_title
# The headline's ref carries the link so a thread reply (no title line, no
# metadata block) still has a route to the PR/issue.
headline = '%s **%s** — %s%s' % (role_icon, role_label, verdict or action,
                                 ' · ' + ('[%s](%s)' % (ref, primary) if primary else ref) if ref else '')

DOCUMENTED = {  # README "Notification templates"; anything else stays a literal ${NAME}
    'ICON': icon, 'REF': ref, 'MSG': msg, 'EVENT': event, 'ROLE': ROLE_NAMES.get(event, event),
    'TITLE': title, 'REF_TITLE': ref_title, 'PR': pr, 'PR_TITLE': pr_title, 'PR_REF': pr_ref,
    'BOARD': env('BOARD'), 'ISSUE_URL': issue_url, 'PR_URL': pr_url, 'REF_LINK': ref_link,
    'PR_LINK': pr_link, 'VERDICT': verdict, 'SUMMARY': summary, 'HEADLINE': headline,
    'ROLE_ICON': role_icon, 'ROLE_LABEL': role_label, 'REPO': repo}

# Metadata, one platform-neutral set each sink renders natively (a GFM table does
# not exist on Slack). Empty values are dropped here, not in each renderer.
fields = [{'label': l, 'text': t, 'url': u} for l, t, u in (
    ('PR', '#' + pr if pr else '', pr_url), ('Issue', '#' + num if num else '', issue_url),
    ('Stage', event, ''), ('Repo', repo, '')) if t]
color, color_int = COLORS.get(event, ('#3498db', 3447003))
context = '%s · %s%s' % (slug, event, ' · ' + ref if ref else '')


# ── Template layer ───────────────────────────────────────────────────────────
def resolve(platform):
    for root in env('TMPL_ROOTS').split('\n'):
        if root:
            for path in (['%s/%s/%s.md' % (root, platform, event)] if platform else []) + ['%s/%s.md' % (root, event)]:
                if os.path.isfile(path):
                    return path
    return ''


def render(path):
    # Only DOCUMENTED names substitute: handing safe_substitute() os.environ would
    # render any exported secret a (project-supplied, untrusted) template names.
    try:
        with open(path, encoding='utf-8') as f:
            return string.Template(f.read()).safe_substitute({k: defuse(v) for k, v in DOCUMENTED.items()}).strip()
    except Exception:
        return ''


# The neutral dialect becomes each sink's native syntax: (pattern, replacement)
# rules applied in order. Slack has no headings, no CommonMark bold or links and
# no "- " lists; Discord and Teams render everything but a heading inside an
# embed / Adaptive Card; Buzz renders GFM as is.
HEADING = (r'(?m)^[ \t]*#{1,6}[ \t]+(.*)$', r'**\1**')
DIALECTS = {
    'slack': [(r'(?m)^[ \t]*#{1,6}[ \t]+(.*)$', r'*\1*'), (r'\*\*([^*\n]+)\*\*', r'*\1*'),
              (r'\[([^\]\n]+)\]\(([^)\n]+)\)', r'<\2|\1>'), (r'(?m)^([ \t]*)[-*][ \t]+', r'\1• ')],
    'discord': [HEADING], 'teams': [HEADING],
}


def to_platform(platform, text):
    # First tidy what an empty variable leaves behind (an empty link target, a
    # dangling " · ", an empty bold run), so a template needs no conditionals.
    for pat, rep in ((r'\[[ \t]+', '['), (r'[ \t]+\]\(', ']('),
                     (r'[ \t]*·[ \t]*\[[^\]\n]*\]\([ \t]*\)', ''), (r'\[[^\]\n]*\]\([ \t]*\)[ \t]*·[ \t]*', ''),
                     (r'\[[ \t]*\]\([^)\n]*\)', ''), (r'\[([^\]\n]*)\]\([ \t]*\)', r'\1'), (r'\*\*[ \t]*\*\*', '')):
        text = re.sub(pat, rep, text)
    lines = [re.sub(r'^[ \t]*(?:·[ \t]*)+', '', re.sub(r'(?:[ \t]*·)+[ \t]*$', '', l.rstrip())) for l in text.split('\n')]
    text = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()
    for pat, rep in DIALECTS.get(platform, []):
        text = re.sub(pat, rep, text)
    return text


def cell(s):  # one grid row cell: no newline, no fence-closing run
    return defuse(re.sub(r'\s*[\r\n]+\s*', ' ', str(s)).strip())


def prepare(platform):
    """Render the one neutral template for this sink; derive what its builder reads."""
    path = resolve(platform)
    text = render(path) if path else ''
    s = SimpleNamespace(path=path, rich=bool(text))
    s.text = to_platform(platform, text or text_plain)
    lines = s.text.split('\n')
    s.title = lines[0]
    s.body = '\n'.join(lines[1:]).lstrip('\n') or s.title
    # A reply drops the title line: the root above it already carries it.
    drop = set()
    for link in (ref_link, pr_link):
        t = to_platform(platform, link)
        if t:
            drop.update(t.split('\n'))
    reply = [l for l in s.body.split('\n') if l not in drop]
    s.reply = '\n'.join(reply).lstrip('\n').rstrip('\n') or s.title
    s.text_reply = s.title if s.reply == s.title else s.title + '\n\n' + s.reply
    # The grid is the template-less fallback; a comment ends in the script's own
    # " (<primary url>)" suffix, which would put an inert URL inside the fence.
    comment = re.sub(r'\s*\(' + re.escape(primary) + r'\)\s*$', '', s.reply) if primary else s.reply
    rows = ([('Comment', cell(comment))] if cell(comment) else []) + [(cell(f['label']), cell(f['text'])) for f in fields]
    w = max([len(l) for l, _ in rows] or [0])
    out = []
    for label, val in rows:
        chunks = textwrap.wrap(val, 58) or ['']
        out.append('{}  {}'.format(label.ljust(w), chunks[0]))
        out.extend(' ' * (w + 2) + c for c in chunks[1:])
    s.grid = '\n'.join(out)
    return s


def link_row(sep, fmt):
    return sep.join(fmt % (f['label'], f['text'], f['url']) for f in fields if f['url'])


# ── Payload formatters: one small function per platform ─────────────────────
def slack(s, anchor, mode):
    # The notification preview renders no markup: unwrap <url|text> and emphasis.
    plain = re.sub(r'[*_`]', '', re.sub(r'<[^|>\s]+\|([^>]*)>', r'\1', s.title)).strip()
    root = not anchor  # a post with no anchor is the thread root: full metadata card
    body = s.body if root else s.reply
    full = s.title
    if body.strip() and body.strip() != s.title.strip():
        full = s.title + '\n\n' + body
    if root and s.rich:
        blocks = [{'type': 'section', 'text': {'type': 'mrkdwn', 'text': full[:3000]}}]
        fl = [{'type': 'mrkdwn', 'text': '*{}*\n{}'.format(f['label'], '<{}|{}>'.format(f['url'], f['text']) if f['url'] else f['text'])}
              for f in fields][:10]  # Block Kit caps a section at 10 fields
        if fl:
            blocks.append({'type': 'section', 'fields': fl})
    else:
        if root and s.grid:
            links = ' · '.join('<{}|{} {}>'.format(f['url'], f['label'], f['text']) for f in fields if f['url'])
            full = '\n'.join([s.title, '```\n' + s.grid + '\n```'] + ([links] if links else []))
        blocks = [{'type': 'section', 'text': {'type': 'mrkdwn', 'text': full[:3000]}}]
    blocks.append({'type': 'context', 'elements': [{'type': 'mrkdwn', 'text': context}]})
    p = {'text': plain, 'blocks': blocks, 'attachments': [{'color': color, 'fallback': plain}]}
    if mode == 'bot':
        p['channel'] = env('SLACK_CHANNEL')
        if anchor:
            p['thread_ts'] = anchor
    return json.dumps(p, ensure_ascii=False)


def discord(s, anchor, mode):
    # An embed title is plain text: it renders neither bold nor links.
    plain = re.sub(r'[*_`]', '', re.sub(r'\[([^\]\n]*)\]\([^)\n]*\)', r'\1', s.title)).strip()
    root = not anchor
    emb = {'title': plain[:256], 'description': (s.body if root else s.reply)[:3900],
           'color': color_int, 'footer': {'text': context[:2048]}}
    if root and s.rich:
        fl = [{'name': f['label'], 'value': '[{}]({})'.format(f['text'], f['url']) if f['url'] else f['text'],
               'inline': True} for f in fields][:25]  # an embed holds at most 25 fields
        if fl:
            emb['fields'] = fl
    elif root and s.grid:
        desc = '```\n' + s.grid + '\n```'
        row = link_row(' · ', '[%s %s](%s)')
        emb['description'] = (desc + ('\n' + row if row else ''))[:3900]
    if primary:
        emb['url'] = primary
    p = {'embeds': [emb]}
    if mode == 'bot' and anchor:
        p['message_reference'] = {'message_id': anchor, 'fail_if_not_exists': False}
    return json.dumps(p, ensure_ascii=False)


def teams(s, anchor, mode):
    # Teams cannot thread, so every post is a root card. Adaptive Cards render no
    # code fence: the grid goes in a Monospace TextBlock.
    body = [{'type': 'TextBlock', 'wrap': True, 'weight': 'Bolder', 'size': 'Medium', 'text': s.title}]
    if s.rich:
        if s.body and s.body.strip() != s.title.strip():
            body.append({'type': 'TextBlock', 'wrap': True, 'text': s.body})
        facts = [{'title': f['label'], 'value': '[{}]({})'.format(f['text'], f['url']) if f['url'] else f['text']}
                 for f in fields]
        if facts:
            body.append({'type': 'FactSet', 'facts': facts})
    else:
        if s.grid:
            body.append({'type': 'TextBlock', 'wrap': True, 'fontType': 'Monospace', 'text': s.grid})
        row = link_row(' · ', '[%s %s](%s)')
        if row:
            body.append({'type': 'TextBlock', 'wrap': True, 'text': row})
    body.append({'type': 'TextBlock', 'wrap': True, 'isSubtle': True, 'spacing': 'Small', 'text': context})
    return json.dumps({'type': 'message', 'attachments': [{
        'contentType': 'application/vnd.microsoft.card.adaptive',
        'content': {'type': 'AdaptiveCard', 'version': '1.4', 'body': body}}]}, ensure_ascii=False)


def buzz(s, anchor, mode):
    # Buzz renders GFM, so the neutral dialect goes out verbatim. A root is that
    # text plus one compact "repo · PR #n" footer; a reply carries neither the title
    # nor the footer. Without a template: heading + grid + link row.
    if anchor:
        return s.text_reply
    if s.rich:
        def md(v):
            return str(v).replace('\\', '\\\\').replace('|', '\\|').replace('`', "'")
        parts = [md(re.sub(r'\s*[\r\n]+\s*', ' ', repo).strip())]
        if pr:
            label = 'PR #' + md(pr)
            parts.append('[{}]({})'.format(label, md(pr_url).replace(' ', '%20')) if pr_url else label)
        footer = ' · '.join(p for p in parts if p)
        return s.text + '\n' + ('\n' + footer + '\n' if footer else '')
    out = '### %s\n' % s.title
    if s.grid:
        out += '\n```\n%s\n```\n' % s.grid
    row = link_row(' · ', '[%s %s](%s)')
    return out + ('\n%s\n' % row if row else '')


FORMATTERS = {'slack': slack, 'discord': discord, 'teams': teams, 'buzz': buzz}

# ── Entry points ─────────────────────────────────────────────────────────────
mode, args = sys.argv[1], sys.argv[2:]
if mode == 'payload':
    sys.stdout.write(FORMATTERS[args[0]](prepare(args[0]), args[2], args[1]))
elif mode == 'dcthread':
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', prepare('discord').title)
    # A thread name is plain text, capped at 100 characters by Discord.
    name = ((ref or event) + (' — ' + t if t else '')).replace('\n', ' ')[:95]
    sys.stdout.write(json.dumps({'name': name, 'auto_archive_duration': 1440}))
elif mode == 'text':
    sys.stdout.write(prepare(args[0]).text)
elif mode == 'cmd':
    try:
        issue = int(num.strip()) if num.strip() else None
    except ValueError:
        issue = num.strip()
    s = prepare('')
    json.dump({'event': event, 'ref': ref, 'message': s.text, 'thread_key': env('THREAD_KEY'),
               'fields': fields, 'repo': nrepo, 'issue': issue}, sys.stdout)
elif mode == 'render':
    label, platform = args[0], '' if args[0] == 'default' else args[0]
    s = prepare(platform)
    sys.stdout.write('# platform: %s\n# event:    %s\n# template: %s\n# rich:     %s\n\n' % (
        label, event, s.path or '(none — plain-text fallback)', 'yes' if s.rich else 'no'))
    sys.stdout.write(FORMATTERS[platform](s, '', 'bot') if platform else s.text)
    if platform != 'buzz':
        sys.stdout.write('\n')
PY
}

# ── Thread state ─────────────────────────────────────────────────────────────
THREADING_ENABLED="$(cfg notifications.threading)"
STATE_FILE="${PIPELINE_THREAD_STATE:-$HOME/.talos/threads.json}"
STATE_KEY="${REPO_SLUG}:${THREAD_KEY}"
DEBUG="${PIPELINE_NOTIFY_DEBUG:-}"

# _thread_state get|set|clear FIELD [VALUE]. Each call is its own read-modify-write,
# so it runs under the lock (#180): two stages (issues.max_parallel > 1) racing on
# the file would otherwise each load the old state and lose the other's entry. On
# lock timeout it proceeds unlocked with a warning rather than block the pipeline.
_thread_state() {
  STATE_FILE="$STATE_FILE" STATE_KEY="$STATE_KEY" with_lock "$STATE_FILE" 5 -- python3 -I - "$@" <<'PYEOF'
import json, os, sys
cmd, field = sys.argv[1], sys.argv[2]
sf, key = os.environ['STATE_FILE'], os.environ['STATE_KEY']
try:
    with open(sf) as f:
        state = json.load(f)
except Exception:
    state = {}
if not isinstance(state, dict):
    state = {}
if cmd == 'get':
    print(state.get(key, {}).get(field, ''), end='')
    sys.exit()
if cmd == 'set':
    state.setdefault(key, {})[field] = sys.argv[3]
elif key in state:
    state[key].pop(field, None)
    if not state[key]:
        del state[key]
else:
    sys.exit()
try:
    os.makedirs(os.path.dirname(os.path.abspath(sf)), exist_ok=True)
    with open(sf, 'w') as f:
        json.dump(state, f, indent=2)
except Exception:
    pass
PYEOF
}

_json_field() {  # $1=json $2=field
  python3 -I -c '
import json, sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], ""), end="")
except Exception:
    pass' "$1" "$2" 2>/dev/null
}

_dbg() { echo "[pipeline-notify DEBUG] $*"; }

# ── Sinks ────────────────────────────────────────────────────────────────────
# Webhooks cannot thread and share one flow: format, post, one stderr line on failure.
_webhook_sink() {  # $1=slack|discord|teams $2=url
  local payload
  payload="$(_fmt payload "$1" webhook "")"
  if [ "$DEBUG" = 1 ]; then
    case "$1" in
      teams) _dbg "TEAMS payload=$payload" ;;
      *)     _dbg "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]') (webhook, no threading): $(_fmt text "$1")" ;;
    esac
  else
    post "$2" "$payload" >/dev/null 2>&1 || echo "pipeline-notify: $1 webhook delivery failed" >&2
  fi
}

# The thread-anchor flow Slack's bot mode and Buzz share. A send function takes the
# anchor, posts once and sets _S_RC (0 delivered, 1 failed, 2 nothing to do or
# already reported: debug, timeout), _S_ID (the new message id), _S_STALE (the
# platform refused the anchor) and _S_ERR. A refused anchor is cleared and the
# message reposted as a new root, so a deleted thread never loses a notification.
_anchored() {  # $1=name $2=state field $3=send function
  local anchor=""
  [ "$THREADING_ENABLED" = "true" ] && anchor="$(_thread_state get "$2")"
  _S_STALE=0; _S_ID=""
  "$3" "$anchor"
  if [ "$_S_RC" -eq 1 ] && [ "$_S_STALE" = 1 ] && [ -n "$anchor" ]; then
    _thread_state clear "$2"
    anchor=""
    "$3" ""
    [ "$_S_RC" -ne 1 ] || echo "pipeline-notify: $1 retry (stale anchor recovery) failed" >&2
  elif [ "$_S_RC" -eq 1 ]; then
    echo "pipeline-notify: $_S_ERR" >&2
  fi
  if [ "$_S_RC" -eq 0 ] && [ "$THREADING_ENABLED" = "true" ] && [ -z "$anchor" ] && [ -n "$_S_ID" ]; then
    _thread_state set "$2" "$_S_ID"
  fi
}

# shellcheck disable=SC2329  # the send functions run through _anchored / talos_bounded
_send_slack() {  # $1=anchor (thread_ts)
  local payload resp
  payload="$(_fmt payload slack bot "$1")"
  _S_RC=2
  if [ "$DEBUG" = 1 ]; then
    _dbg "SLACK (bot) state_key=$STATE_KEY"; _dbg "SLACK thread_anchor=${1:-(none — root post)}"; _dbg "SLACK payload=$payload"
    return 0
  fi
  resp="$(post https://slack.com/api/chat.postMessage "$payload" "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null)"
  _S_RC=1; _S_STALE=0
  _S_ERR="slack api delivery failed: $(printf '%s' "$resp" | head -c 200)"
  case "$resp" in
    *'"ok":true'*) _S_RC=0; _S_ID="$(_json_field "$resp" ts)" ;;
    *'"error":"thread_not_found"'*) _S_STALE=1 ;;
  esac
}

# Discord bot mode threads for real: the root goes to the channel, then
# POST …/messages/{id}/threads starts a thread from it and later events post
# straight into that thread (a message_reference reply would leave every stage in
# the main channel). Where the bot cannot create threads it falls back to inline
# replies off the root, and the fallback settles: thread creation is only tried on
# the root post, never once per later event.
_discord_bot() {
  local thread="" anchor="" target="$DISCORD_CHANNEL" mode=bot payload resp id tresp auth="Authorization: Bot $DISCORD_BOT_TOKEN"
  if [ "$THREADING_ENABLED" = "true" ]; then
    thread="$(_thread_state get discord_thread_id)"
    anchor="$(_thread_state get discord_msg_id)"
  fi
  # Inside a thread channel the anchor would render a redundant reply header.
  [ -z "$thread" ] || { target="$thread"; mode=bot_in_thread; }
  payload="$(_fmt payload discord "$mode" "$anchor")"
  if [ "$DEBUG" = 1 ]; then
    _dbg "DISCORD (bot) state_key=$STATE_KEY"; _dbg "DISCORD thread=${thread:-(none — will create from root)}"; _dbg "DISCORD payload=$payload"
    return 0
  fi
  resp="$(post "https://discord.com/api/v10/channels/$target/messages" "$payload" "$auth" 2>/dev/null)"
  case "$resp" in
    *'"id"'*)
      if [ "$THREADING_ENABLED" = "true" ] && [ -z "$thread" ] && [ -z "$anchor" ]; then
        id="$(_json_field "$resp" id)"
        if [ -n "$id" ]; then
          _thread_state set discord_msg_id "$id"
          tresp="$(post "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages/$id/threads" "$(_fmt dcthread)" "$auth" 2>/dev/null)"
          case "$tresp" in
            *'"id"'*) _thread_state set discord_thread_id "$(_json_field "$tresp" id)" ;;
            *) echo "pipeline-notify: discord thread creation failed, falling back to inline replies: $(printf '%s' "$tresp" | head -c 200)" >&2 ;;
          esac
        fi
      fi ;;
    *) echo "pipeline-notify: discord api delivery failed: $(printf '%s' "$resp" | head -c 200)" >&2 ;;
  esac
}

# ── Buzz ─────────────────────────────────────────────────────────────────────
# nak exits 0 even when the relay REJECTS an event and prints the locally signed
# JSON regardless (it signs before publishing), so neither its exit code nor its
# stdout separates success from failure: an id parsed from stdout could be an event
# the relay never stored, persisted as an anchor that makes a dead sink look
# healthy. The relay's verdict is only on stderr, so that is inspected.
# shellcheck disable=SC2329
_nak() {  # $1=anchor. The key travels in the environment, never argv (#281).
  local reply=()
  [ -z "$1" ] || reply=(-t "e=$1;;reply")
  NOSTR_SECRET_KEY="$BUZZ_BOT_PRIVATE_KEY" nak event --auth -k 9 -c "$BUZZ_TEXT" \
    -t "h=$BUZZ_CHANNEL" ${reply[@]+"${reply[@]}"} "$BUZZ_RELAY_URL"
}
# shellcheck disable=SC2329
_send_buzz() {  # $1=anchor event id
  # Rendered per call: a repost after a refused anchor is a root, so it takes the
  # root form (title and footer), not the reply form of the first attempt (#570).
  BUZZ_TEXT="$(_fmt payload buzz bot "$1")"
  _S_RC=2
  if [ "$DEBUG" = 1 ]; then
    _dbg "BUZZ state_key=$STATE_KEY"; _dbg "BUZZ thread_anchor=${1:-(none — root post)}"
    _dbg "BUZZ relay=$BUZZ_RELAY_URL channel=$BUZZ_CHANNEL kind=9 text=$BUZZ_TEXT"
    return 0
  fi
  if ! command -v nak >/dev/null 2>&1; then
    echo "pipeline-notify: buzz configured but 'nak' CLI not found — skipping (brew install nak)" >&2
    return 0
  fi
  local res err out msg
  res="$(mktemp)"; err="$(mktemp)"
  talos_bounded "$BUZZ_TIMEOUT_S" _nak "$1" >"$res" 2>"$err"
  out="$(cat "$res" 2>/dev/null)"; msg="$(cat "$err" 2>/dev/null)"
  rm -f "$res" "$err"
  # A timeout says nothing about the anchor, so it is not "stale": no repost.
  if [ "$_BOUNDED_TIMED_OUT" = 1 ]; then
    echo "pipeline-notify: buzz relay timed out after ${BUZZ_TIMEOUT_S}s: $BUZZ_RELAY_URL" >&2
    return 0
  fi
  _S_RC=1; _S_STALE=1; _S_ERR="buzz publish failed"  # Buzz rejects replies to unknown parents
  # Failure markers, verified against a rejected publish: an unadmitted key yields
  # "auth error: msg: restricted: not a relay member. failed: msg: auth-required".
  if [ "$_BOUNDED_RC" -ne 0 ] || grep -qE 'auth error|failed:|CLOSED:' <<<"$msg"; then
    [ -z "$msg" ] || echo "pipeline-notify: buzz relay rejected publish: $msg" >&2
    return 0
  fi
  _S_RC=0; _S_ID="$(_json_field "$(printf '%s' "$out" | sed -n 1p)" id)"
}

# ── --render: preview and stop ───────────────────────────────────────────────
if [ -n "$RENDER_ONLY" ]; then
  _fmt render "$RENDER_ONLY"
  exit 0
fi

# ── Deliver ──────────────────────────────────────────────────────────────────
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  _webhook_sink slack "$SLACK_WEBHOOK_URL"
elif [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "$SLACK_CHANNEL" ]; then
  _anchored slack slack_ts _send_slack
fi
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  _webhook_sink discord "$DISCORD_WEBHOOK_URL"
elif [ -n "${DISCORD_BOT_TOKEN:-}" ] && [ -n "$DISCORD_CHANNEL" ]; then
  _discord_bot
fi
[ -z "${TEAMS_WEBHOOK_URL:-}" ] || _webhook_sink teams "$TEAMS_WEBHOOK_URL"
if [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_BOT_PRIVATE_KEY:-}" ] && [ -n "$BUZZ_CHANNEL" ]; then
  # Seconds one nak call may run (#281): a relay that never answers sends no RST
  # and never issues the NIP-42 challenge, so an unbounded nak would hang the
  # orchestrator's whole post-merge chain.
  BUZZ_TIMEOUT_S="$(talos_pos_int "$(cfg notifications.buzz_timeout_s)" 15)"
  _anchored buzz buzz_event_id _send_buzz
fi

# ── notifications.cmd (#184) ─────────────────────────────────────────────────
CMD_SINK="$(cfg notifications.cmd)"
if [ -n "$CMD_SINK" ]; then
  CMD_TIMEOUT_S="$(talos_pos_int "$(cfg notifications.cmd_timeout_s)" 10)"
  CMD_PAYLOAD="$(_fmt cmd)"
  if [ "$DEBUG" = 1 ]; then
    _dbg "CMD cmd=$CMD_SINK timeout_s=$CMD_TIMEOUT_S payload=$CMD_PAYLOAD"
  elif ! CMD_IN_FILE="$(mktemp "${TMPDIR:-/tmp}/talos-notify-cmd-in.XXXXXX" 2>/dev/null)"; then
    echo "pipeline-notify: notifications.cmd skipped (mktemp failed)" >&2
  else
    printf '%s' "$CMD_PAYLOAD" > "$CMD_IN_FILE"
    talos_bounded "$CMD_TIMEOUT_S" sh -c "$CMD_SINK" < "$CMD_IN_FILE" >/dev/null 2>&1
    rm -f "$CMD_IN_FILE"
    # A real failure and a kill at the timeout are treated alike: one note, move on.
    [ "$_BOUNDED_RC" -eq 0 ] || echo "pipeline-notify: notifications.cmd exited non-zero or timed out (rc=$_BOUNDED_RC) -- skipping" >&2
  fi
fi

exit 0
