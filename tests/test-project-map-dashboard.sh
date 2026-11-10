#!/usr/bin/env bash
# test-project-map-dashboard.sh -- the project map as a dashboard (#877): the
# page `talos.sh map` renders puts the run's state and what needs the owner at
# the top, from local records only.
#   AC1 order: header with the run pill, five tiles, Next step, <main>, <aside>;
#       an empty section is omitted, In flight says `nothing in flight`
#   AC2 the needs-you tile: the Needs you count, alert style, links to #needs
#   AC3 a Needs you row: stop-kind tag, one `To continue:` line, the owner question
#   AC4 the queued table's why-it-waits column
#   AC5 the stage bar's seven segments, one colour-key line, no Legend section
#   AC6 Merged shows 8 rows then a <details>; Top spend is 5 rows and a total
#   AC7 30 s auto-reload, the 980 px rule, the dark mode rule
#   AC8 no script, no img, no URL but the provider's
# AC9 (390 px, no horizontal scroll), AC10 and AC11 are prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
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
snap() {  # <seconds since the run started | none (an ended run) | norun> <collect JSON> [<priority JSON> [<collect age s, 60>]]
  python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=int(s))).strftime("%Y-%m-%dT%H:%M:%SZ")
run = {} if sys.argv[2] == "norun" else \
    {"active": False, "started": f(30000), "end": "stop at " + f(10) + " done"} if sys.argv[2] == "none" \
    else {"active": True, "started": f(sys.argv[2])}
json.dump({"ts": f(0), "collect_ts": f(sys.argv[5]), "priority": json.loads(sys.argv[4] or "{}"),
           "run": run, "collect": json.loads(sys.argv[3])}, open(sys.argv[1], "w"))' "$STATE/state.json" "$1" "$2" "${3:-}" "${4:-60}"
}
cache_title() { printf '%s\n' "$2" > "$META/acme_widget.issue.$1"; }

# ── The busy run ─────────────────────────────────────────────────────────────
: > "$STATE/events.jsonl"
# 21: QA running 7 min, a PR at qa. 22: developer fix round 2. 23: qa running after a redone dev.
ev validator validator 21 "" CONFIRMED "" "" 3000
ev pm pm 21 "" "" "" "" 2900
ev developer developer 21 31 PR_OPENED 5000 "" 2000
ev reviewer reviewer 21 31 APPROVED 800 "<b>reviewed</b> and fine" 1000
start 21 420 31 qa
ev validator validator 22 "" CONFIRMED "" "" 3000
ev developer developer 22 32 PR_OPENED "" "" 2500
ev qa qa 22 32 FAIL "" "QA FAIL: wrong" 2000
ev reviewer reviewer 22 32 CHANGES "" "needs work" 1500
start 22 300 32 developer
ev developer developer 23 33 PR_OPENED "" "" 6000
ev qa qa 23 33 FAIL "" "QA FAIL" 5500
ev developer developer 23 33 PR_OPENED "" "" 5000
start 23 450 33 qa
# 30: an owner question. 25: the PM proposed a split. 26: every stage done, merge failed. 27: any other block.
ev validator validator 30 "" CONFIRMED "" "" 3000
ev validator validator 25 "" CONFIRMED "" "" 3000
ev pm pm 25 "" BLOCKED "" "PM proposed 4 sub-issues" 1800
ev validator validator 26 "" CONFIRMED "" "" 3000
ev pm pm 26 "" "" "" "" 2900
ev developer developer 26 36 PR_OPENED "" "" 2000
ev reviewer reviewer 26 36 APPROVED "" "" 1500
ev qa qa 26 36 PASS "" "" 1200
ev docs docs 26 36 "" "" "" 540
ev developer developer 27 "" "" "" "" 900
ev blocked orchestrator 27 "" "" "" "need <i>credentials</i>" 600
# 60..69: merged, 1k..10k tokens each, 1 h apart.
for i in 60 61 62 63 64 65 66 67 68 69; do
  ev developer developer "$i" "$((i + 100))" PR_OPENED "$(((i - 59) * 1000))" "" 20000
  ev merged orchestrator "$i" "$((i + 100))" "" "" merged "$(((i - 59) * 3600))"
  cache_title "$i" "Merged $i"
done
cache_title 21 "Add retry"
cache_title 30 "Owner one"
cache_title 25 "Epic one"
cache_title 26 "Merge one"
cache_title 51 "Queued <b>one</b>"
BUSY='{"prs": [{"n": 31, "issue": 21, "head": "a", "owner": false, "stage": "qa"}, {"n": 32, "issue": 22, "head": "b", "owner": false, "stage": ""}],
       "queued": [53, 51, 52], "inflight": [], "held": [52], "capped": [53],
       "blocked": [["issue", 25], ["issue", 26], ["issue", 27]],
       "owners": [{"n": 30, "status": "unanswered", "question": "Pick <b>A</b> or B?\nSecond & line"}]}'
# The collect was read before the busy stages started (a stage that began before
# its collect, with no lane record, is not running: #881).
snap 19800 "$BUSY" '{"51": 0, "52": 1, "60": 0, "61": 0}' 480

mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
for c in curl glab az; do cp "$SANDBOX/bin/gh" "$SANDBOX/bin/$c"; done
PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "AC1 the map renders" "$(cat "$SANDBOX/err")"
PAGE="$(cat "$MAP" 2>/dev/null)"

pick() {  # <page file> <mode> [<arg>]: a piece of the page, "<none>" when absent
  python3 -I -c '
import re, sys
p, mode = open(sys.argv[1]).read(), sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
secs = re.findall(r"<section.*?</section>", p, re.S)
def first(xs):
    return xs[0] if xs else "<none>"
if mode == "section":      # the first section holding the text
    print(first([s for s in secs if arg in s]))
elif mode == "row":        # the Needs you / In flight row of an issue
    print(first([r for r in re.findall(r"<div class=\"row\">.*?</ol></div>", p, re.S)
                 if "/issues/%s\">#%s</a>" % (arg, arg) in r]))
elif mode == "key":
    m = re.search(r"<div class=\"key\">.*?</div>", p, re.S)
    print(m.group(0) if m else "<none>")
elif mode == "head":
    m = re.search(r"<head>.*?</head>", p, re.S)
    print(m.group(0) if m else "<none>")
elif mode == "order":      # ok when every marker is on the page, in the given order
    at = [p.find(x) for x in arg.split("|")]
    print("ok" if all(a >= 0 for a in at) and at == sorted(at) else "bad %s" % at)
' "$@"
}
piece() {  # <mode> [<arg>]: pick from the current page
  pick "$MAP" "$@"
}
steps_of() {  # <markup>: the segments of a piece of markup
  python3 -I -c '
import re, sys
print(" ".join("%s:%s" % (m.group(2), (m.group(1) or "").strip() or "-")
      for m in re.finditer(r"<li class=\"s( [dfrx])?\">([a-z]+)</li>", sys.stdin.read())))' <<< "$1"
}

# ── AC1: the order, the omitted sections ─────────────────────────────────────
assert_eq "ok" "$(piece order '<header>|<span class="pill live">|class="kpis"|<b>4</b><span>needs you</span>|<span>in flight</span>|<span>queued</span>|<span>merged · 7 days</span>|<span>tokens · 7 days</span>|<div class="next"><b>Next step</b> · |<main>|<section class="needs" id="needs">|<section id="flight">|<section id="queue">|<h2>Merged|</main>|<aside>|<h2>Activity · this run|<h2>Priority track|<h2>Top spend · 7 days|</aside>')" "AC1 header, run pill, five tiles, Next step bar, then main (Needs you, In flight, Queued, Merged) and aside (Activity, Priority track, Top spend)"
assert_contains "$PAGE" '<header><h1>acme/widget</h1><span class="pill live">' "AC1 the header holds the repository name and the run pill"
assert_contains "$PAGE" 'Run going · started 5 h 30 min ago</span>' "AC1 a run going reads Run going · started <duration> ago"
assert_contains "$PAGE" '<span class="meta">updated ' "AC1 the header says when the page was updated"
assert_contains "$PAGE" ' · reloads every 30 s</span>' "AC1 and that it reloads every 30 s"
assert_not_contains "$PAGE" '<h2>Next step</h2>' "AC1 the Next step is a bar, not a section"
assert_contains "$PAGE" '<div class="next"><b>Next step</b> · ' "AC1 the Next step bar"
assert_not_contains "$PAGE" '<div class="next"><b>Next step</b> · unknown' "AC1 the Next step comes from the snapshot"
FEED="$(piece section '<h2>Activity · this run')"
assert_contains "$FEED" '<ul class="feed"><li><time>' "AC1 Activity is a feed of timed entries"
assert_eq "7" "$(python3 -I -c '
import re, sys
s = sys.stdin.read()
print(len(re.findall(r"<li><time>", s.split("<details>")[0])))' <<< "$FEED")" "AC1 seven Activity entries sit outside the <details>"
assert_contains "$FEED" '<details><summary>Show ' "AC1 the rest of Activity sits in a <details>"
assert_contains "$FEED" 'reviewer <span class="v-ok">APPROVED</span>' "AC1 an approving verdict word is green"
assert_contains "$FEED" 'reviewer <span class="v-bad">CHANGES</span>' "AC1 a failing verdict word is red"
assert_contains "$FEED" 'merged PR #' "AC1 a merge is listed"
assert_eq "ok" "$(python3 -I -c '
import re, sys
s = sys.stdin.read()
ts = re.findall(r"<time>(\d\d:\d\d)</time>", s)
print("ok" if len(ts) > 8 else "few %d" % len(ts))' <<< "$FEED")" "AC1 Activity lists each entry by its HH:MM"
TRACK="$(piece section '<h2>Priority track')"
assert_contains "$TRACK" '<b>p0</b>' "AC1 the Priority track names a tier"
assert_contains "$TRACK" '2 of 3 merged' "AC1 a tier reads N of M merged"
assert_contains "$TRACK" '<div class="meter"><i style="width:66%"></i></div>' "AC1 a tier has a progress bar"
assert_eq "1" "$(grep -o 'you are here' <<< "$TRACK" | wc -l | tr -d ' ')" "AC1 one tier is marked you are here"
assert_contains "$(piece section '<span class="here">')" '<span class="here">you are here</span></span><span class="muted">2 of 3 merged' "AC1 you are here sits beside the current tier"
assert_contains "$TRACK" '0 of 1 merged' "AC1 a tier with nothing merged reads 0 of M"

# ── AC2: the needs-you tile ──────────────────────────────────────────────────
NEEDS="$(piece section 'id="needs"')"
assert_contains "$PAGE" '<a class="kpi alert" href="#needs"><b>4</b><span>needs you</span></a>' "AC2 the needs-you tile counts the issues, has the alert style and links to #needs"
assert_eq "4" "$(grep -o '<div class="row">' <<< "$NEEDS" | wc -l | tr -d ' ')" "AC2 the count is the number of Needs you rows"
assert_contains "$PAGE" '<a class="kpi" href="#flight"><b>3</b><span>in flight</span></a>' "AC2 the in-flight tile links to #flight"
assert_contains "$PAGE" '<a class="kpi" href="#queue"><b>3</b><span>queued</span></a>' "AC2 the queued tile links to #queue"
assert_contains "$PAGE" '<div class="kpi"><b>10</b><span>merged · 7 days</span></div>' "AC2 the merged tile is a plain div"
assert_contains "$PAGE" '<div class="kpi"><b>61k</b><span>tokens · 7 days</span></div>' "AC2 the tokens tile totals the page's issues"

# ── AC3: Needs you rows ──────────────────────────────────────────────────────
ROW30="$(piece row 30)"; ROW25="$(piece row 25)"; ROW26="$(piece row 26)"; ROW27="$(piece row 27)"
assert_contains "$ROW30" '<span class="tag stuck">owner question' "AC3 an owner question's tag names the kind"
assert_contains "$ROW25" '<span class="tag stuck">epic · split proposed · 30 min ago</span>' "AC3 a PM block is an epic split proposed, with the age of its latest event"
assert_contains "$ROW26" '<span class="tag stuck">merge failed · 9 min ago</span>' "AC3 every stage done and blocked is a merge failed"
assert_contains "$ROW27" '<span class="tag stuck">blocked · 10 min ago</span>' "AC3 any other block is blocked"
assert_contains "$ROW30" '<div class="do">To continue: <a href="https://github.com/acme/widget/issues/30">answer on the issue</a>' "AC3 owner question: answer on the issue, linked"
assert_contains "$ROW25" '<div class="do">To continue: <a href="https://github.com/acme/widget/issues/25">approve or edit the split</a>' "AC3 epic: approve or edit the split, linked"
assert_contains "$ROW26" '<div class="do">To continue: rerun the issue. Talos merges main in a fix round.</div>' "AC3 merge failed: rerun the issue"
assert_contains "$ROW27" "<div class=\"do\">To continue: read the issue's latest comment, resolve what it names, then run again.</div>" "AC3 blocked: read the latest comment"
for n in 30 25 26 27; do
  assert_eq "1" "$(grep -o 'To continue:' <<< "$(piece row $n)" | wc -l | tr -d ' ')" "AC3 #$n has one To continue line"
done
assert_contains "$ROW30" '<div class="ask"><b>Question:</b> Pick &lt;b&gt;A&lt;/b&gt; or B?' "AC3 the owner question is in the ask box, escaped"
assert_contains "$ROW30" 'Second &amp; line</div>' "AC3 the whole question is shown, every line"
assert_not_contains "$ROW25" 'class="ask"' "AC3 a row with no owner question has no ask box"
assert_not_contains "$PAGE" '<blockquote>' "AC3 the owner question is no longer a blockquote list"
assert_contains "$ROW27" 'need &lt;i&gt;credentials&lt;/i&gt;' "AC3 a block's reason is shown, escaped"
assert_eq "validator:d pm:d dev:d review:d qa:d docs:d merge:f" "$(steps_of "$ROW26")" "AC3 a merge failed row's stage bar shows the merge as failed"

# ── AC4: why it waits ────────────────────────────────────────────────────────
QUEUE="$(piece section 'id="queue"')"
assert_contains "$QUEUE" '<table>' "AC4 Queued is a table"
assert_contains "$QUEUE" '<tr><td class="nw muted">1</td><td class="nw"><a href="https://github.com/acme/widget/issues/53">#53</a></td><td>(title not cached)</td><td class="nw"><span class="pri">—</span></td><td class="hide-sm muted">next free lane</td></tr>' "AC4 a capped issue waits for the next free lane (position 1, no priority)"
assert_contains "$QUEUE" '<tr><td class="nw muted">2</td><td class="nw"><a href="https://github.com/acme/widget/issues/51">#51</a></td><td>Queued &lt;b&gt;one&lt;/b&gt;</td><td class="nw"><span class="pri p0">p0</span></td><td class="hide-sm muted">next free lane</td></tr>' "AC4 a queued issue waits for the next free lane; its priority is a chip"
assert_contains "$QUEUE" '<td class="nw"><span class="pri p1">p1</span></td><td class="hide-sm muted">waiting on you · pipeline:needs-owner</td></tr>' "AC4 a held issue is waiting on you"
assert_eq "1" "$(grep -o 'waiting on you' <<< "$QUEUE" | wc -l | tr -d ' ')" "AC4 only the held issue is waiting on you"

# ── AC5: the stage bar and its key ───────────────────────────────────────────
FLIGHT="$(piece section 'id="flight"')"
assert_eq "validator:d pm:d dev:d review:d qa:r docs:- merge:-" "$(steps_of "$(piece row 21)")" "AC5 seven segments, each with a state class and its name: qa is running now, docs and merge are not reached"
assert_eq "validator:d pm:- dev:r review:f qa:f docs:- merge:-" "$(steps_of "$(piece row 22)")" "AC5 failed gates are f, the developer they sent back is running"
assert_eq "validator:- pm:- dev:x review:- qa:r docs:- merge:-" "$(steps_of "$(piece row 23)")" "AC5 a developer redone after a failing QA is x"
assert_contains "$(piece row 21)" '<ol class="steps"><li class="s d">validator</li>' "AC5 the bar is an ordered list of li.s segments"
assert_eq "1" "$(grep -o '<div class="key">' <<< "$PAGE" | wc -l | tr -d ' ')" "AC5 one colour key"
for w in done 'running now' failed redone 'not reached'; do
  assert_contains "$(piece key)" "$w" "AC5 the key names $w in words"
done
assert_eq "ok" "$(piece order '<section id="flight">|<div class="key">|</span></div><div class="row">')" "AC5 the key sits above the In flight rows"
assert_not_contains "$PAGE" 'class="legend"' "AC5 no Legend section"
assert_not_contains "$PAGE" '<h2>Legend</h2>' "AC5 and no Legend heading"
assert_not_contains "$PAGE" 'class="step ' "AC5 no per-card text chips"
assert_contains "$FLIGHT" '<span class="tag run">QA · running 7 min</span>' "AC5 an in-flight row's tag names the stage and its age"
assert_contains "$FLIGHT" 'PR <a href="https://github.com/acme/widget/pull/31">#31</a> · stage qa' "AC5 the row links its PR and gives the collect's stage"
assert_contains "$(piece row 22)" 'fix round 2' "AC5 a fix round is in the row"
assert_not_contains "$(piece row 21)" 'fix round' "AC5 a first-round row has none"
assert_contains "$(piece row 21)" '<div class="why">Last: &lt;b&gt;reviewed&lt;/b&gt; and fine</div>' "AC5 the latest summary is the Last line, escaped"

# ── AC6: Merged and Top spend ────────────────────────────────────────────────
MERGED="$(piece section '<h2>Merged')"
assert_eq "2" "$(grep -o '<table>' <<< "$MERGED" | wc -l | tr -d ' ')" "AC6 Merged is a table and a second table in the <details>"
assert_eq "8" "$(python3 -I -c '
import sys
s = sys.stdin.read().split("<details>")[0]
print(s.count("<td class=\"nw\"><a href=\"https://github.com/acme/widget/issues/"))' <<< "$MERGED")" "AC6 eight Merged rows sit outside the <details>"
assert_eq "2" "$(python3 -I -c '
import sys
s = sys.stdin.read().split("<details>")[-1]
print(s.count("<td class=\"nw\"><a href=\"https://github.com/acme/widget/issues/"))' <<< "$MERGED")" "AC6 the rest are inside it"
assert_contains "$MERGED" '<details><summary>Show 2 more</summary>' "AC6 the summary counts the rest"
assert_contains "$MERGED" '<span class="tok"><i style="width:' "AC6 a Merged row's tokens come with a bar"
assert_contains "$MERGED" '<a href="https://github.com/acme/widget/pull/160">#160</a>' "AC6 a Merged row links its PR"
SPEND="$(piece section '<h2>Top spend')"
assert_eq "5" "$(grep -o '<tr><td><a href=' <<< "$SPEND" | wc -l | tr -d ' ')" "AC6 Top spend has five rows"
assert_eq "1" "$(grep -o '<tr class="total">' <<< "$SPEND" | wc -l | tr -d ' ')" "AC6 and one total row"
assert_contains "$SPEND" '<tr class="total"><td class="muted">total</td><td class="num"><b>61k</b></td></tr>' "AC6 the total covers every issue, not only the five"
assert_eq "69 68 67 66 65" "$(grep -o 'issues/[0-9]*"' <<< "$SPEND" | tr -dc '0-9\n' | tr '\n' ' ' | sed 's/ $//')" "AC6 the five with the most tokens, most first"
assert_not_contains "$PAGE" '<h2>Spend</h2>' "AC6 the full Spend table is gone"

# ── AC7, AC8: the document ───────────────────────────────────────────────────
HEAD="$(piece head)"
assert_contains "$HEAD" '<meta http-equiv="refresh" content="30">' "AC7 the page reloads every 30 s"
assert_contains "$PAGE" 'max-width:980px' "AC7 a single-column rule at 980 px"
assert_contains "$PAGE" 'prefers-color-scheme:dark' "AC7 a dark mode rule"
assert_contains "$PAGE" 'minmax(0,1fr) 340px' "AC7 two columns on a wide screen"
LOWER="$(printf '%s' "$PAGE" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$LOWER" '<script' "AC8 the page has no script"
assert_not_contains "$LOWER" '<img' "AC8 the page has no img"
assert_eq "" "$(grep -oE 'https?://[^"<> ]+' <<< "$PAGE" | grep -v '^https://github.com/acme/widget/' || true)" "AC8 the only URLs are the provider's"
assert_contains "$PAGE" "content=\"default-src 'none'; style-src 'unsafe-inline'\"" "AC8 the CSP meta is kept"

# ── The idle run: the same page with the empty sections left out ─────────────
: > "$STATE/events.jsonl"
ev developer developer 60 160 PR_OPENED "" "" 20000
ev merged orchestrator 60 160 "" "" merged 7200
snap none '{"prs": [], "queued": [], "inflight": [], "held": [], "blocked": [], "owners": [], "capped": []}'
bash "$TALOS" map >/dev/null 2>&1
IDLE="$(cat "$MAP" 2>/dev/null)"
assert_contains "$IDLE" '<span class="pill idle">' "AC1 with no run going the pill is idle"
assert_contains "$IDLE" 'Idle · last run ended: <code>stop at ' "AC1 and carries the end line"
assert_contains "$IDLE" '<p class="muted">nothing in flight</p>' "AC1 In flight says so when empty"
assert_contains "$IDLE" '<section id="flight">' "AC1 In flight stays"
assert_not_contains "$IDLE" 'id="needs"' "AC1 no Needs you section when nothing needs the owner"
assert_not_contains "$IDLE" 'id="queue"' "AC1 no Queued section when nothing is queued"
assert_not_contains "$IDLE" '<h2>Top spend' "AC1 no empty Top spend"
assert_contains "$IDLE" '<h2>Merged' "AC1 Merged stays when something merged"
assert_contains "$IDLE" '<a class="kpi" href="#needs"><b>0</b><span>needs you</span></a>' "AC2 at 0 the tile is plain kpi, still a link"
assert_not_contains "$IDLE" 'kpi alert' "AC2 and has no alert style"
assert_not_contains "$IDLE" '<details>' "AC6 nothing is folded away when there is no more to show"
assert_eq "ok" "$(pick "$MAP" order '<header>|class="kpis"|<div class="next"><b>Next step</b>|<main>|<section id="flight">|<h2>Merged|</main>|<aside>')" "AC1 the idle page keeps the order"
snap norun '{}'
rm -f "$STATE/events.jsonl"
bash "$TALOS" map >/dev/null 2>&1
BARE="$(cat "$MAP" 2>/dev/null)"
assert_contains "$BARE" '<span class="pill idle"><span class="dot"></span>Idle · no run recorded' "AC1 with no run at all the pill says no run recorded"
assert_not_contains "$BARE" '<div class="next">' "AC1 with no collect there is no Next step bar"
assert_contains "$BARE" 'No run state yet' "AC1 and one note says so"

finish
