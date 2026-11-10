#!/usr/bin/env bash
# test-project-map-readable.sh -- the project map during a live run (#875): the
# page `talos.sh map` renders is readable at a glance, from local records only.
#   AC1  pipeline-hooks.sh stage_start caches the issue's title; the map shows it
#   AC3  a title, or `#N (title not cached)`
#   AC4  the header's one-sentence run status
#   AC5  an in-flight card names its current stage and how long it has run
#   AC6  a developer stage after a failing verdict is `developer, fix round K`
#   AC7  the in-flight card's PR and stage, and the last event's one line
#   AC8  section order: Next step, Needs you, In flight, Queued, Merged, then the side column
#   AC9  Merged is a table (#877 folds only the rows past the eighth)
#   AC10 one timestamp format, with a relative age
#   AC11 no recorded tokens shows an em dash
#   AC12 labelled stage steps with five states
#   AC13 a visible colour key (one line; #877 dropped the Legend section)
# The page is laid out as a dashboard since #877: tests/test-project-map-dashboard.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
META="$HOME/.cache/talos/meta"
mkdir -p "$STATE" "$META"

# ev <event> <role> <issue> <pr> <verdict> <tokens> <summary> <seconds ago> [<stage>]
ev() {
  python3 -I -c '
import datetime, json, sys
a = sys.argv
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(a[8]))
e = {"event": a[1], "role": a[2], "issue": int(a[3]), "pr": int(a[4]) if a[4] else None,
     "verdict": a[5] or None, "tokens": int(a[6]) if a[6] else None, "summary": a[7],
     "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ")}
if len(a) > 9:
    e["stage"] = a[9]
print(json.dumps(e))' "$@" >> "$STATE/events.jsonl"
}
start() { ev stage_start orchestrator "$1" "${3:-}" "" "" "" "$2" "$4"; }   # <issue> <seconds ago> [<pr>] <stage>
snap() {  # <seconds since the run started> <collect JSON>
  python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=int(s))).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"ts": f(0), "collect_ts": f(18000), "priority": {},
           "run": {"active": True, "started": f(sys.argv[2])}, "collect": json.loads(sys.argv[3])},
          open(sys.argv[1], "w"))' "$STATE/state.json" "$1" "$2"
}
cache_title() { printf '%s\n' "$2" > "$META/acme_widget.issue.$1"; }

: > "$STATE/events.jsonl"
LONG="$(python3 -I -c 'print("x" * 200)')"
# 21: QA running for 12 min, a PR the collect says is at qa, a long last summary.
ev validator validator 21 "" CONFIRMED 100 "" 3000
ev pm pm 21 "" "" "" "" 2900
ev developer developer 21 31 PR_OPENED 5000 "" 2000
ev reviewer reviewer 21 31 APPROVED 800 "<b>reviewed</b> $LONG" 1000
start 21 750 31 qa
# 22: a developer fix round 2 (a failing QA and a failing review), no title, no tokens.
ev validator validator 22 "" CONFIRMED "" "" 3000
ev developer developer 22 32 PR_OPENED "" "" 2500
ev qa qa 22 32 FAIL "" "QA FAIL: wrong" 2000
ev reviewer reviewer 22 32 CHANGES "" "needs work" 1500
start 22 300 32 developer
# 23: dev redone after a failing QA, QA running 75 min; a recorded 0 tokens.
ev developer developer 23 33 PR_OPENED 0 "" 6000
ev qa qa 23 33 FAIL "" "QA FAIL" 5500
ev developer developer 23 33 PR_OPENED "" "" 5000
start 23 4500 33 qa
# 24: in flight, its one stage already finished: no stage running.
start 24 900 "" qa
ev docs docs 24 "" "" "" "" 850
ev qa qa 24 "" PASS 100 "" 800
# 31: a reviewer started 20 s ago.
start 31 20 "" reviewer
# 25: stuck on a BLOCKED stage; 30: stuck on an owner question.
ev developer developer 25 "" BLOCKED 100 "BLOCKED: need credentials" 600
# 28 and 29: merged 4 h ago (29 recorded no tokens, no title).
ev developer developer 28 41 PR_OPENED 3000 "" 15000
ev merged orchestrator 28 41 "" "" merged 14400
ev developer developer 29 42 PR_OPENED "" "" 15000
ev merged orchestrator 29 42 "" "" merged 14500
cache_title 21 "Add retry"
cache_title 24 "Quiet one"
cache_title 26 "Queued one"
cache_title 28 "Done one"
cache_title 30 "Owner one"
snap 860 '{"prs": [{"n": 31, "issue": 21, "head": "a", "owner": false, "stage": "qa"}, {"n": 32, "issue": 22, "head": "b", "owner": false, "stage": ""}],
          "queued": [26, 27], "inflight": [24], "held": [], "blocked": [], "capped": [],
          "owners": [{"n": 30, "status": "unanswered", "question": "Pick A or B?"}]}'

# A gh, curl, glab and az that fail: rendering makes no call (the cache is read).
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
for c in curl glab az; do cp "$SANDBOX/bin/gh" "$SANDBOX/bin/$c"; done
PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "the map renders" "$(cat "$SANDBOX/err")"
PAGE="$(cat "$MAP" 2>/dev/null)"

art() {  # <issue> [<page>]: the issue's row markup (#877: a row of the Needs you or In flight section)
  python3 -I -c '
import re, sys
n = sys.argv[2]
m = re.search(r"<div class=\"row\"><div><div class=\"t\"><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>.*?</ol></div>" % (n, n),
              open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "${2:-$MAP}" "$1"
}
section() {  # <id>: the markup of <section id="..."> up to its end
  python3 -I -c '
import re, sys
m = re.search(r"<section[^>]*id=\"%s\"[^>]*>.*?</section>" % sys.argv[2], open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "$MAP" "$1"
}

# ── AC1: stage_start caches the title; the map shows it with no provider call ──
export STUB_REPO=acme/widget STUB_ISSUE_TITLE="Hooked title"
rm -f "$META/acme_widget.issue.41"
OUT="$(bash "$HOOKS" stage_start developer 41 2>/dev/null)"; RC=$?
assert_eq "0" "$RC" "AC1 stage_start exits 0"
assert_eq "Hooked title" "$(cat "$META/acme_widget.issue.41" 2>/dev/null)" "AC1 stage_start caches the issue's title"
PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(art 41)" '#41</a> Hooked title</div>' "AC1 a dispatched issue's card shows its title, read from the cache"

# ── AC3: titles ────────────────────────────────────────────────────────────────
assert_contains "$(art 21)" '#21</a> Add retry</div>' "AC3 a cached title follows the issue link"
assert_contains "$(art 22)" '#22</a> (title not cached)</div>' "AC3 a card with no cached title says so, never a bare #N"
assert_contains "$PAGE" '<td><a href="https://github.com/acme/widget/issues/27">#27</a> (title not cached)</td>' "AC3 a queued row with no title says so"
assert_contains "$PAGE" '<td><a href="https://github.com/acme/widget/issues/26">#26</a> Queued one</td>' "AC3 a queued row shows the title"
printf '<b>x</b> & "q"\n' > "$META/acme_widget.issue.26"
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP")" '&lt;b&gt;x&lt;/b&gt; &amp; &quot;q&quot;' "AC3 a title is escaped"
cache_title 26 "Queued one"
bash "$TALOS" map >/dev/null 2>&1
PAGE="$(cat "$MAP")"

# ── AC4: the run line ──────────────────────────────────────────────────────────
assert_contains "$PAGE" 'Run going · started 14 min ago</span>' "AC4 the run pill reads from the run's start"
assert_contains "$PAGE" '<a class="kpi" href="#flight"><b>6</b><span>in flight</span></a>' "AC4 the tiles count the issues in flight"
assert_contains "$PAGE" '<a class="kpi alert" href="#needs"><b>2</b><span>needs you</span></a>' "AC4 and the stuck ones"
snap 5000 '{"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}'
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP")" 'Run going · started 1 h 23 min ago' "AC4 an hour or more reads <H> h <M> min"
python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"ts": f(0), "collect_ts": f(18000), "run": {"active": False, "started": f(3000), "end": "stop at " + f(10) + " done"},
           "collect": {"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}},
          open(sys.argv[1], "w"))' "$STATE/state.json"
bash "$TALOS" map >/dev/null 2>&1
ENDED="$(cat "$MAP")"
assert_contains "$ENDED" '<span class="pill idle"><span class="dot"></span>Idle · ' "AC4 with no run going the pill reads Idle"
assert_contains "$ENDED" 'last run ended: <code>stop at ' "AC4 and keeps the end line's text"
assert_not_contains "$ENDED" 'Run going' "AC4 an ended run is not a run going"
snap 600 '{"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}'
mv "$STATE/events.jsonl" "$STATE/events.full"
: > "$STATE/events.jsonl"
ev developer developer 24 "" PR_OPENED 10 "" 30
bash "$TALOS" map >/dev/null 2>&1
P1="$(cat "$MAP")"
assert_contains "$P1" 'Run going · started 10 min ago' "AC4 the pill of a run of 10 min"
assert_contains "$P1" '<a class="kpi" href="#flight"><b>1</b><span>in flight</span></a>' "AC4 one issue in flight"
assert_contains "$P1" '<a class="kpi" href="#needs"><b>0</b><span>needs you</span></a>' "AC4 and none stuck"
mv "$STATE/events.full" "$STATE/events.jsonl"
snap 860 '{"prs": [{"n": 31, "issue": 21, "head": "a", "owner": false, "stage": "qa"}, {"n": 32, "issue": 22, "head": "b", "owner": false, "stage": ""}],
          "queued": [26, 27], "inflight": [24], "held": [], "blocked": [], "capped": [],
          "owners": [{"n": 30, "status": "unanswered", "question": "Pick A or B?"}]}'
bash "$TALOS" map >/dev/null 2>&1
PAGE="$(cat "$MAP")"

# ── AC5, AC6, AC7: the in-flight cards ─────────────────────────────────────────
INFLIGHT="$(section flight)"
assert_contains "$INFLIGHT" '<h2>In flight <span class="n">6</span></h2>' "AC5 the In flight section"
for n in 21 22 23 24 31; do
  assert_contains "$INFLIGHT" "<div class=\"row\"><div><div class=\"t\"><a href=\"https://github.com/acme/widget/issues/$n\">#$n</a>" "AC5 #$n is a row in the In flight section"
done
assert_not_contains "$INFLIGHT" '/issues/25"' "AC5 a stuck issue is not in the In flight section"
assert_contains "$(art 21)" '<span class="tag run">QA · running 12 min</span>' "AC5 a qa stage reads QA and its age in minutes"
assert_contains "$(art 31)" '<span class="tag run">reviewer · running &lt;1 min</span>' "AC5 a stage under a minute reads <1 min (escaped)"
assert_contains "$(art 23)" '<span class="tag run">QA · running 1 h 15 min</span>' "AC5 an hour or more reads <H> h <M> min"
assert_not_contains "$(art 24)" 'class="tag run"' "AC5 a start with a later finishing event is no running stage"
assert_contains "$(art 22)" '<span class="tag run">developer · running 5 min</span>' "AC6 a developer stage after failing verdicts names the stage and its age"
assert_contains "$(art 22)" 'fix round 2' "AC6 and the fix round K"
assert_not_contains "$(art 21)" 'fix round' "AC6 a first-round stage has no fix round"
assert_contains "$(art 21)" 'PR <a href="https://github.com/acme/widget/pull/31">#31</a> · stage qa' "AC7 the card links its PR and gives the collect's stage"
assert_not_contains "$(art 22)" '· stage' "AC7 with no collect stage there is no stage text, never a draft or ready guess"
assert_not_contains "$INFLIGHT" 'draft' "AC7 no draft or ready guess on an in-flight card"
LAST="$(python3 -I -c '
import html, re, sys
m = re.search(r"<div class=\"why\">Last: (.*?)</div>", sys.stdin.read(), re.S)
t = html.unescape(m.group(1)) if m else "<none>"
print("%d %s" % (len(t), t[:20]))' <<< "$(art 21)")"
assert_eq "120 <b>reviewed</b> xxxx" "$LAST" "AC7 the last event's summary is cut to 120 characters"
assert_contains "$(art 21)" '<div class="why">Last: &lt;b&gt;reviewed&lt;/b&gt; xxx' "AC7 the last summary is escaped"

# ── AC8: order; AC9: Done; Needs you ───────────────────────────────────────────
ORDER="$(python3 -I -c '
import sys
p = open(sys.argv[1]).read()
heads = ["<div class=\"next\">", "<h2>Needs you <span", "<h2>In flight <span", "<h2>Queued <span", "<h2>Merged",
         "<h2>Activity", "<h2>Priority track</h2>", "<h2>Top spend"]
at = [p.find(h) for h in heads]
print("ok" if all(a >= 0 for a in at) and at == sorted(at) else "bad %s" % at)
done = p.find("<h2>Merged")
print("late" if "<div class=\"row\">" in p[done:] else "none")' "$MAP")"
assert_eq "ok
none" "$ORDER" "AC8 the sections come in order and no in-flight or needs-you row follows Merged"
assert_contains "$PAGE" 'Pick A or B?' "AC8 Needs you quotes the owner question"
NEEDS="$(python3 -I -c '
import re, sys
p = open(sys.argv[1]).read()
a, b = p.find("<h2>Needs you <span"), p.find("<h2>In flight <span")
print(p[a:b])' "$MAP")"
assert_contains "$NEEDS" '<div class="row"><div><div class="t"><a href="https://github.com/acme/widget/issues/25">#25</a>' "AC8 a stuck card is under Needs you"
assert_contains "$NEEDS" '<div class="ask"><b>Question:</b> Pick A or B?' "AC8 the owner question is under Needs you"
assert_not_contains "$PAGE" 'Needs your call' "AC8 the old Needs your call heading is gone"
assert_not_contains "$PAGE" 'Nothing waits on you' "AC8 so is its empty text"
assert_contains "$(section queue)" '<table>' "AC8 Queued is a table"
# #877: Merged shows its first 8 rows in the open (the #875 collapsed <details> is gone).
DONE="$(python3 -I -c '
import re, sys
m = re.search(r"<section><h2>Merged.*?</section>", open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "$MAP")"
assert_not_contains "$DONE" '<details' "AC9 two Merged rows sit in the open, with no <details>"
assert_contains "$DONE" '<table>' "AC9 as a table"
assert_contains "$DONE" '<tr><td><a href="https://github.com/acme/widget/issues/28">#28</a></td><td>Done one</td><td class="hide-sm"><a href="https://github.com/acme/widget/pull/41">#41</a></td><td class="hide-sm muted">4 h ago</td><td class="num"><span class="tok"><i style="width:60px"></i>3k</span></td></tr>' "AC9 a Merged row: issue, title, PR, how long ago, tokens with a bar"
assert_contains "$DONE" '<tr><td><a href="https://github.com/acme/widget/issues/29">#29</a></td><td>(title not cached)</td><td class="hide-sm"><a href="https://github.com/acme/widget/pull/42">#42</a></td><td class="hide-sm muted">4 h ago</td><td class="num">—</td></tr>' "AC9 a Merged row with no title and no tokens"
assert_eq "2" "$(grep -o '<tr><td><a href=' <<< "$DONE" | wc -l | tr -d ' ')" "AC9 one row per merged issue"

# ── AC10: one timestamp format ─────────────────────────────────────────────────
assert_eq "" "$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' <<< "$PAGE$ENDED" | head -n 1)" "AC10 no ISO timestamp is on the page, an end line's included"
assert_contains "$PAGE" ' UTC (' "AC10 a timestamp carries a relative age"
assert_eq "" "$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}( UTC)?' <<< "$PAGE" | grep -v ' UTC$' | head -n 1)" "AC10 every timestamp reads YYYY-MM-DD HH:MM UTC"
assert_contains "$ENDED" 'stop at ' "AC10 an end line's own stamp is kept, reformatted"
assert_contains "$ENDED" ' UTC done' "AC10 the reformatted stamp is in the same format"

# ── AC11: tokens ───────────────────────────────────────────────────────────────
assert_contains "$(art 22)" 'tokens —' "AC11 an issue with no recorded tokens shows an em dash"
assert_not_contains "$(art 22)" '0 tokens' "AC11 and never 0 tokens"
assert_contains "$(art 23)" ' · 0 tokens' "AC11 a recorded 0 shows 0 tokens"
assert_contains "$(art 21)" '6k tokens' "AC11 a recorded total shows formatted"
assert_contains "$PAGE" '<tr class="total"><td class="muted">total</td><td class="num"><b>' "AC11 the Top spend table keeps its total row"

# ── AC12: stage steps ──────────────────────────────────────────────────────────
steps() {  # <markup>: the steps as "name:state" words (#877: the state is the segment's class)
  python3 -I -c '
import re, sys
word = {"d": "done", "r": "running", "f": "failed", "x": "redone", "": "notreached"}
print(" ".join("%s:%s" % (m.group(2), word[(m.group(1) or "").strip()]) for m in
      re.finditer(r"<li class=\"s( [dfrx])?\">([a-z]+)</li>", sys.stdin.read())))' <<< "$1"
}
assert_contains "$(art 21)" '<ol class="steps">' "AC12 the steps are an ordered list"
assert_eq "validator:done pm:done dev:done review:done qa:running docs:notreached merge:notreached" "$(steps "$(art 21)")" "AC12 a pm that finishes with no verdict is done; qa is running now; docs and merge are not reached"
assert_eq "validator:done pm:notreached dev:running review:failed qa:failed docs:notreached merge:notreached" "$(steps "$(art 22)")" "AC12 failing gates are failed, the developer they sent back is running now"
assert_eq "validator:notreached pm:notreached dev:redone review:notreached qa:running docs:notreached merge:notreached" "$(steps "$(art 23)")" "AC12 a developer redone after a failing QA is redone"
assert_contains "$(steps "$NEEDS")" 'dev:failed' "AC12 a Needs-you card has steps (a BLOCKED developer is failed)"
assert_contains "$(steps "$(art 24)")" 'qa:done docs:done' "AC12 docs is read from docs events"

# ── AC13: the colour key (#877 replaces the Legend section with one line) ──────
KEY="$(python3 -I -c '
import re, sys
m = re.search(r"<div class=\"key\">.*?</div>", open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "$MAP")"
for w in done 'running now' failed redone 'not reached'; do
  assert_contains "$KEY" "$w" "AC13 the key names $w"
done
assert_not_contains "$KEY" 'title=' "AC13 the key is text, not a title attribute"
assert_not_contains "$PAGE" 'class="legend"' "AC13 the Legend section is gone"

# ── AC2: a failed title read never blocks the hook ─────────────────────────────
rm -f "$STATE/events.jsonl" "$META/acme_widget.issue.51"
OUT="$(PATH="$SANDBOX/bin:$PATH" bash "$HOOKS" stage_start developer 51 2>/dev/null)"; RC=$?
assert_eq "0" "$RC" "AC2 with the title read failing, stage_start still exits 0"
assert_eq "" "$OUT" "AC2 and prints nothing on stdout"
assert_eq "1" "$(wc -l < "$STATE/events.jsonl" | tr -d ' ')" "AC2 and appends its one stage_start event"

# ── AC14: the page stays static; AC17: the markup the old suite pins is kept ───
PAGE="$(cat "$MAP")"
LOWER="$(printf '%s' "$PAGE" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$LOWER" '<script' "AC14 the page has no script"
assert_not_contains "$LOWER" '<img' "AC14 the page has no img"
assert_eq "" "$(grep -oE 'https?://[^"<> ]+' <<< "$PAGE" | grep -v '^https://github.com/acme/widget/' || true)" "AC14 the only URLs are the provider's"
assert_contains "$PAGE" "content=\"default-src 'none'; style-src 'unsafe-inline'\"" "AC14 the CSP meta is kept"
assert_contains "$PAGE" 'prefers-color-scheme:dark' "AC14 the dark mode rule is kept"
assert_contains "$PAGE" '<div class="meter"><i style="width:' "AC17 the priority track has its progress bars"
assert_contains "$PAGE" '<tr class="total"><td class="muted">total</td><td class="num"><b>' "AC17 the Top spend total row keeps its markup"

finish
