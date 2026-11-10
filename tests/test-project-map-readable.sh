#!/usr/bin/env bash
# test-project-map-readable.sh -- the project map during a live run (#875): the
# page `talos.sh map` renders is readable at a glance, from local records only.
#   AC1  pipeline-hooks.sh stage_start caches the issue's title; the map shows it
#   AC3  a title, or `#N (title not cached)`
#   AC4  the header's one-sentence run status
#   AC5  an in-flight card names its current stage and how long it has run
#   AC6  a developer stage after a failing verdict is `developer, fix round K`
#   AC7  the in-flight card's PR and stage, and the last event's one line
#   AC8  section order: Needs you, In flight, Queued, Done, then the rest
#   AC9  Done is a collapsed <details> table
#   AC10 one timestamp format, with a relative age
#   AC11 no recorded tokens shows an em dash
#   AC12 labelled stage steps with five states
#   AC13 a visible legend
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

art() {  # <issue> [<page>]: the issue's card markup
  python3 -I -c '
import re, sys
n = sys.argv[2]
m = re.search(r"<article class=\"card [a-z]+( wide)?\"><h3><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>.*?</article>" % (n, n),
              open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "${2:-$MAP}" "$1"
}
section() {  # <class>: the markup of <section class="..."> up to its end
  python3 -I -c '
import re, sys
m = re.search(r"<section class=\"%s\">.*?</section>" % sys.argv[2], open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "$MAP" "$1"
}

# ── AC1: stage_start caches the title; the map shows it with no provider call ──
export STUB_REPO=acme/widget STUB_ISSUE_TITLE="Hooked title"
rm -f "$META/acme_widget.issue.41"
OUT="$(bash "$HOOKS" stage_start developer 41 2>/dev/null)"; RC=$?
assert_eq "0" "$RC" "AC1 stage_start exits 0"
assert_eq "Hooked title" "$(cat "$META/acme_widget.issue.41" 2>/dev/null)" "AC1 stage_start caches the issue's title"
PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(art 41)" '#41</a> Hooked title</h3>' "AC1 a dispatched issue's card shows its title, read from the cache"

# ── AC3: titles ────────────────────────────────────────────────────────────────
assert_contains "$(art 21)" '#21</a> Add retry</h3>' "AC3 a cached title follows the issue link"
assert_contains "$(art 22)" '#22</a> (title not cached)</h3>' "AC3 a card with no cached title says so, never a bare #N"
assert_contains "$PAGE" '<li><a href="https://github.com/acme/widget/issues/27">#27</a> (title not cached)</li>' "AC3 a queued row with no title says so"
assert_contains "$PAGE" '<li><a href="https://github.com/acme/widget/issues/26">#26</a> Queued one</li>' "AC3 a queued row shows the title"
printf '<b>x</b> & "q"\n' > "$META/acme_widget.issue.26"
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP")" '&lt;b&gt;x&lt;/b&gt; &amp; &quot;q&quot;' "AC3 a title is escaped"
cache_title 26 "Queued one"
bash "$TALOS" map >/dev/null 2>&1
PAGE="$(cat "$MAP")"

# ── AC4: the run line ──────────────────────────────────────────────────────────
assert_contains "$PAGE" '<p class="runline">Run going for 14 min, 6 issues in flight, 2 stuck' "AC4 the run line is one sentence from the run's start"
snap 5000 '{"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}'
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP")" 'Run going for 1 h 23 min, ' "AC4 an hour or more reads <H> h <M> min"
python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"ts": f(0), "collect_ts": f(18000), "run": {"active": False, "started": f(3000), "end": "stop at " + f(10) + " done"},
           "collect": {"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}},
          open(sys.argv[1], "w"))' "$STATE/state.json"
bash "$TALOS" map >/dev/null 2>&1
ENDED="$(cat "$MAP")"
assert_contains "$ENDED" '<p class="runline">No run going' "AC4 with no run going the line reads No run going"
assert_contains "$ENDED" 'last run ended: <code>stop at ' "AC4 and keeps the end line's text"
assert_not_contains "$ENDED" 'Run going for' "AC4 an ended run is not a run going"
snap 600 '{"prs": [], "queued": [], "inflight": [24], "held": [], "blocked": [], "owners": [], "capped": []}'
mv "$STATE/events.jsonl" "$STATE/events.full"
: > "$STATE/events.jsonl"
ev developer developer 24 "" PR_OPENED 10 "" 30
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP")" 'Run going for 10 min, 1 issue in flight, 0 stuck' "AC4 one issue reads 1 issue in flight"
mv "$STATE/events.full" "$STATE/events.jsonl"
snap 860 '{"prs": [{"n": 31, "issue": 21, "head": "a", "owner": false, "stage": "qa"}, {"n": 32, "issue": 22, "head": "b", "owner": false, "stage": ""}],
          "queued": [26, 27], "inflight": [24], "held": [], "blocked": [], "capped": [],
          "owners": [{"n": 30, "status": "unanswered", "question": "Pick A or B?"}]}'
bash "$TALOS" map >/dev/null 2>&1
PAGE="$(cat "$MAP")"

# ── AC5, AC6, AC7: the in-flight cards ─────────────────────────────────────────
INFLIGHT="$(section inflight)"
assert_contains "$INFLIGHT" '<h2>In flight</h2>' "AC5 the In flight section"
for n in 21 22 23 24 31; do
  assert_contains "$INFLIGHT" "<article class=\"card inprogress wide\"><h3><a href=\"https://github.com/acme/widget/issues/$n\">#$n</a>" "AC5 #$n is a wide in-progress card in the In flight section"
done
assert_not_contains "$INFLIGHT" '/issues/25"' "AC5 a stuck issue is not in the In flight section"
assert_contains "$(art 21)" '<p class="stage">QA · running 12 min</p>' "AC5 a qa stage reads QA and its age in minutes"
assert_contains "$(art 31)" '<p class="stage">reviewer · running <1 min</p>' "AC5 a stage under a minute reads <1 min"
assert_contains "$(art 23)" '<p class="stage">QA · running 1 h 15 min</p>' "AC5 an hour or more reads <H> h <M> min"
assert_contains "$(art 24)" '<p class="stage">no stage running</p>' "AC5 a start with a later finishing event is no running stage"
assert_contains "$(art 22)" '<p class="stage">developer, fix round 2 · running 5 min</p>' "AC6 a developer stage after failing verdicts reads fix round K"
assert_not_contains "$(art 21)" 'fix round' "AC6 a first-round stage has no fix round"
assert_contains "$(art 21)" 'PR <a href="https://github.com/acme/widget/pull/31">#31</a> · stage qa' "AC7 the card links its PR and gives the collect's stage"
assert_not_contains "$(art 22)" '· stage' "AC7 with no collect stage there is no stage text, never a draft or ready guess"
assert_not_contains "$INFLIGHT" 'draft' "AC7 no draft or ready guess on an in-flight card"
LAST="$(python3 -I -c '
import html, re, sys
m = re.search(r"<p class=\"last\">(.*?)</p>", sys.stdin.read(), re.S)
t = html.unescape(m.group(1)) if m else "<none>"
print("%d %s" % (len(t), t[:20]))' <<< "$(art 21)")"
assert_eq "120 <b>reviewed</b> xxxx" "$LAST" "AC7 the last event's summary is cut to 120 characters"
assert_contains "$(art 21)" '<p class="last">&lt;b&gt;reviewed&lt;/b&gt; xxx' "AC7 the last summary is escaped"

# ── AC8: order; AC9: Done; Needs you ───────────────────────────────────────────
ORDER="$(python3 -I -c '
import sys
p = open(sys.argv[1]).read()
heads = ["<h2>Needs you</h2>", "<h2>In flight</h2>", "<h2>Queued</h2>", "<h2>Done</h2>", "<h2>Track</h2>",
         "<h2>Next step</h2>", "<h2>Changed since", "<h2>Spend</h2>"]
at = [p.find(h) for h in heads]
print("ok" if all(a >= 0 for a in at) and at == sorted(at) else "bad %s" % at)
done = p.find("<h2>Done</h2>")
print("late" if ("class=\"card inprogress" in p[done:] or "class=\"card stuck" in p[done:]) else "none")' "$MAP")"
assert_eq "ok
none" "$ORDER" "AC8 the sections come in order and no in-flight or needs-you card follows Done"
assert_contains "$PAGE" 'Pick A or B?' "AC8 Needs you quotes the owner question"
NEEDS="$(python3 -I -c '
import re, sys
p = open(sys.argv[1]).read()
a, b = p.find("<h2>Needs you</h2>"), p.find("<h2>In flight</h2>")
print(p[a:b])' "$MAP")"
assert_contains "$NEEDS" '<article class="card stuck"><h3><a href="https://github.com/acme/widget/issues/25">#25</a>' "AC8 a stuck card is under Needs you"
assert_contains "$NEEDS" '<blockquote>Pick A or B?' "AC8 the owner question is under Needs you"
assert_not_contains "$PAGE" 'Needs your call' "AC8 the old Needs your call heading is gone"
assert_not_contains "$PAGE" 'Nothing waits on you' "AC8 so is its empty text"
assert_contains "$(section queued)" '<ul class="queued">' "AC8 Queued is a list"
DONE="$(python3 -I -c '
import re, sys
m = re.search(r"<details class=\"done\"[^>]*>.*?</details>", open(sys.argv[1]).read(), re.S)
print(m.group(0) if m else "<none>")' "$MAP")"
assert_contains "$DONE" '<details class="done">' "AC9 Done is a <details> with no open attribute"
assert_contains "$DONE" '<table>' "AC9 holding a table"
assert_contains "$DONE" '<tr class="done"><td><a href="https://github.com/acme/widget/issues/28">#28</a></td><td>Done one</td><td><a href="https://github.com/acme/widget/pull/41">#41</a></td><td>3k</td><td>' "AC9 a Done row: issue, title, PR, tokens, merged"
assert_contains "$DONE" '<tr class="done"><td><a href="https://github.com/acme/widget/issues/29">#29</a></td><td>(title not cached)</td><td><a href="https://github.com/acme/widget/pull/42">#42</a></td><td>—</td>' "AC9 a Done row with no title and no tokens"
assert_eq "2" "$(grep -o '<tr class="done">' <<< "$DONE" | wc -l | tr -d ' ')" "AC9 one row per Done issue"
assert_contains "$DONE" 'UTC (4 h ago)' "AC9 merged-when is the timestamp, then the relative age"

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
assert_contains "$PAGE" '<tr class="total"><td>total</td><td>' "AC11 the Spend table keeps its total row"

# ── AC12: stage steps ──────────────────────────────────────────────────────────
steps() {  # <issue>: the card's steps as "name:class" words
  python3 -I -c '
import re, sys
print(" ".join("%s:%s:%s" % (m.group(2), m.group(1), m.group(3)) for m in
      re.finditer(r"<li class=\"step ([a-z]+)\"><b>([a-z]+)</b> ([a-z ]+)</li>", sys.stdin.read())))' <<< "$1"
}
assert_contains "$(art 21)" '<ol class="steps">' "AC12 the steps are an ordered list"
assert_eq "validator:done:done pm:done:done dev:done:done review:done:done qa:running:running now docs:notreached:not reached merge:notreached:not reached" "$(steps "$(art 21)")" "AC12 a pm that finishes with no verdict is done; qa is running now; docs and merge are not reached"
assert_eq "validator:done:done pm:notreached:not reached dev:running:running now review:failed:failed qa:failed:failed docs:notreached:not reached merge:notreached:not reached" "$(steps "$(art 22)")" "AC12 failing gates are failed, the developer they sent back is running now"
assert_eq "validator:notreached:not reached pm:notreached:not reached dev:redone:redone review:notreached:not reached qa:running:running now docs:notreached:not reached merge:notreached:not reached" "$(steps "$(art 23)")" "AC12 a developer redone after a failing QA is redone"
assert_contains "$(steps "$NEEDS")" 'dev:failed:failed' "AC12 a Needs-you card has steps (a BLOCKED developer is failed)"
assert_contains "$(steps "$(art 24)")" 'qa:done:done docs:done:done' "AC12 docs is read from docs events"

# ── AC13: the legend ───────────────────────────────────────────────────────────
LEGEND="$(section legend)"
for w in validator pm dev review qa docs merge done 'running now' failed redone 'not reached'; do
  assert_contains "$LEGEND" "$w" "AC13 the legend names $w"
done
assert_contains "$LEGEND" 'a gate sent the work back' "AC13 the legend says what failed and redone mean"
assert_not_contains "$LEGEND" 'title=' "AC13 the legend is text, not a title attribute"

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
assert_contains "$PAGE" '<ol class="track">' "AC17 the Track list keeps its markup"
assert_contains "$PAGE" '<tr class="total"><td>total</td><td>' "AC17 the Spend total row keeps its markup"

finish
