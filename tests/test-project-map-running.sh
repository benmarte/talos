#!/usr/bin/env bash
# test-project-map-running.sh -- the project map's `running` set (#881): a stage
# that finished is not running, and a summary-only BLOCKED: is Stuck.
#   AC1 stage_start -> stage_complete -> role event (verdict None), collect does
#       not list the issue: not In flight, not on the in-flight tile
#   AC2 an open start newer than the collect, no lane record: still running
#   AC3 an open start older than the collect, no lane record: not running
#   AC4 an open start with a dead or stale lane record is not running; a live
#       lane record keeps it running
#   AC5 a role event whose summary starts BLOCKED: / **BLOCKED: with no verdict
#       is Stuck (Needs you), reason = summary's first line, PM/planner = epic
#   AC6 the exact event shape of the closed epics #598, #687, #753, #790 leaves
#       all four out of In flight
# AC7 is prose: it is about these tests' fixtures (they carry stage_start and
# stage_complete events).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}}\n' > "$PIPELINE_CONFIG"
TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
META="$HOME/.cache/talos/meta"
mkdir -p "$STATE" "$META"

ev() {  # <event> <role> <issue> <pr> <verdict> <summary> <seconds ago> [<stage>]
  python3 -I -c '
import datetime, json, sys
a = sys.argv
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(a[7]))
e = {"event": a[1], "role": a[2], "issue": int(a[3]), "pr": int(a[4]) if a[4] else None,
     "verdict": a[5] or None, "summary": a[6], "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ")}
if len(a) > 8:
    e["stage"] = a[8]
print(json.dumps(e))' "$@" >> "$STATE/events.jsonl"
}
snap() {  # <run started seconds ago | none> <collect JSON | none> [<run pid>]
  python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=int(s))).strftime("%Y-%m-%dT%H:%M:%SZ")
run = {} if sys.argv[2] == "none" else {"active": True, "started": f(sys.argv[2]), "end": ""}
if len(sys.argv) > 4 and sys.argv[4]:
    run["pid"] = int(sys.argv[4])
snap = {"ts": f(0), "priority": {}, "run": run, "collect": {}}
if sys.argv[3] != "none":
    snap["collect"], snap["collect_ts"] = json.loads(sys.argv[3]), f(600)
json.dump(snap, open(sys.argv[1], "w"))' "$STATE/state.json" "$1" "$2" "${3:-}"
}
lane() {  # <name> <issue> <role> <stage age s> <pid> <record age s>: a hand-written lane record
  mkdir -p "$STATE/lanes"
  python3 -I -c '
import datetime, json, sys
a = sys.argv
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=int(s))).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"worktree": "/work/" + a[2], "issue": int(a[3]), "role": a[4], "stage_start": f(a[5]), "ts": f(a[7]), "pid": int(a[6])},
          open("%s/lanes/%s.json" % (a[1], a[2]), "w"))' "$STATE" "$@"
}
render() { bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; cat "$MAP" 2>/dev/null; }
tile() {  # <page> <label>: the number on a tile
  python3 -I -c '
import re, sys
m = re.search(r"<b>(\d+)</b><span>%s</span>" % sys.argv[2], sys.argv[1])
print(m.group(1) if m else "<none>")' "$1" "$2"
}
section() {  # <page> <section id>: the section's HTML, or <none>
  python3 -I -c '
import re, sys
m = re.search(r"<section[^>]*id=\"%s\"[^>]*>.*?</section>" % sys.argv[2], sys.argv[1], re.S)
print(m.group(0) if m else "<none>")' "$1" "$2"
}
in_flight() {  # <page> <issue>: yes when the issue has a row in the In flight section
  python3 -I -c '
import re, sys
m = re.search(r"<section id=\"flight\">.*?</section>", sys.argv[1], re.S)
print("yes" if m and (">#%s</a>" % sys.argv[2]) in m.group(0) else "no")' "$1" "$2"
}
DEAD="$(sh -c 'echo $$')"
COLLECT='{"prs": [], "queued": [], "inflight": [], "held": [], "blocked": [], "owners": [], "capped": []}'

finished() {  # <issue> <role> <seconds ago the stage started> [<summary>]: a whole finished stage
  local done_at=$(( $3 - 5 )) said_at=$(( $3 - 10 ))
  ev stage_start orchestrator "$1" "" "" "" "$3" "$2"
  ev stage_complete "$2" "$1" "" PASS "" "$done_at"
  ev "$2" "$2" "$1" "" "" "${4:-}" "$said_at"
}

# ── AC1: a finished stage is not running ─────────────────────────────────────
: > "$STATE/events.jsonl"
# 50: the events all pre-date the collect; 51: they follow it.
ev validator validator 50 "" CONFIRMED "" 3100
finished 50 pm 3000 "spec posted"
ev validator validator 51 "" CONFIRMED "" 400
finished 51 pm 300 "spec posted"
snap 5000 "$COLLECT"
PAGE="$(render)"
assert_eq "no" "$(in_flight "$PAGE" 50)" "AC1 a finished pm stage (verdict None) before the collect is not In flight" "$(section "$PAGE" flight)"
assert_eq "no" "$(in_flight "$PAGE" 51)" "AC1 a finished pm stage (verdict None) after the collect is not In flight" "$(section "$PAGE" flight)"
assert_eq "0" "$(tile "$PAGE" 'in flight')" "AC1 the in-flight tile does not count a finished stage"

# ── AC2: an open start newer than the collect is running ─────────────────────
: > "$STATE/events.jsonl"
ev validator validator 52 "" CONFIRMED "" 400
ev stage_start orchestrator 52 "" "" "" 50 pm
snap 5000 "$COLLECT"
PAGE="$(render)"
assert_eq "yes" "$(in_flight "$PAGE" 52)" "AC2 an open start newer than the collect, no lane record, is In flight"
assert_contains "$(section "$PAGE" flight)" '<span class="tag run">pm · running' "AC2 the stage shows as running now, with its age"
assert_eq "1" "$(tile "$PAGE" 'in flight')" "AC2 the in-flight tile counts it"

# ── AC3: an open start older than the collect is not running ─────────────────
: > "$STATE/events.jsonl"
ev validator validator 53 "" CONFIRMED "" 3100
ev stage_start orchestrator 53 "" "" "" 3000 dev
snap 5000 "$COLLECT"
PAGE="$(render)"
assert_eq "no" "$(in_flight "$PAGE" 53)" "AC3 an open start older than the collect, no lane record, leaves In flight" "$(section "$PAGE" flight)"
assert_eq "0" "$(tile "$PAGE" 'in flight')" "AC3 the in-flight tile does not count it"

# ── AC4: the lane record decides when there is one ───────────────────────────
: > "$STATE/events.jsonl"
for n in 54 55 56; do
  ev validator validator "$n" "" CONFIRMED "" 400
  ev stage_start orchestrator "$n" "" "" "" 100 dev
done
snap 5000 "$COLLECT" "$$"
lane lane-4 54 developer 100 "$DEAD" 100
lane lane-5 55 developer 100 "$$" 100
lane lane-6 56 developer 100 "$$" 25000
PAGE="$(render)"
assert_eq "no" "$(in_flight "$PAGE" 54)" "AC4 an open start whose lane record's pid is dead is not running" "$(section "$PAGE" flight)"
assert_eq "yes" "$(in_flight "$PAGE" 55)" "AC4 an open start with a live lane record is running and In flight"
assert_eq "no" "$(in_flight "$PAGE" 56)" "AC4 an open start whose lane record is stale is not running" "$(section "$PAGE" flight)"
rm -rf "${STATE:?}/lanes"

# ── AC5: a summary-only BLOCKED: is Stuck ────────────────────────────────────
: > "$STATE/events.jsonl"
ev validator validator 57 "" CONFIRMED "" 400
finished 57 pm 300 '**BLOCKED: #57 is an epic, so I posted a decomposition proposal'
ev validator validator 58 "" CONFIRMED "" 400
finished 58 planner 300 'BLOCKED: the epic needs a split'
ev validator validator 59 "" CONFIRMED "" 400
finished 59 developer 300 'BLOCKED: spec names a file that does not exist'
ev validator validator 60 "" CONFIRMED "" 400
finished 60 developer 300 'implemented, not BLOCKED: anything'
COLLECT_L='{"prs": [], "queued": [], "inflight": [57, 58, 59, 60], "held": [], "blocked": [], "owners": [], "capped": []}'
snap 5000 "$COLLECT_L"
PAGE="$(render)"
NEEDS="$(section "$PAGE" needs)"
assert_contains "$NEEDS" '>#57</a>' "AC5 a **BLOCKED: summary with no verdict puts the issue in Needs you" "$PAGE"
assert_contains "$NEEDS" '>#58</a>' "AC5 a BLOCKED: summary with no verdict puts a planner issue in Needs you"
assert_contains "$NEEDS" '>#59</a>' "AC5 a BLOCKED: summary on a developer event puts the issue in Needs you"
assert_not_contains "$NEEDS" '>#60</a>' "AC5 a summary that only contains BLOCKED: later is not a block"
assert_contains "$NEEDS" '#57 is an epic, so I posted a decomposition proposal' "AC5 the row's reason is the summary"
assert_contains "$NEEDS" 'the epic needs a split' "AC5 the planner row's reason is the summary"
assert_eq "2" "$(grep -o 'epic · split proposed' <<< "$NEEDS" | wc -l | tr -d ' ')" "AC5 a PM or planner stop reads as the epic kind, and no other"
assert_contains "$NEEDS" 'spec names a file that does not exist' "AC5 a developer stop shows its summary"
assert_eq "3" "$(tile "$PAGE" 'needs you')" "AC5 the needs-you tile counts the three"

# ── AC6: the closed epics' exact event shape ─────────────────────────────────
: > "$STATE/events.jsonl"
for n in 598 687 753 790; do
  ev stage_start orchestrator "$n" "" "" "" 4000 validator
  ev stage_complete validator "$n" "" PASS "" 3990
  ev validator validator "$n" "" CONFIRMED "real" 3985
  ev stage_start orchestrator "$n" "" "" "" 3900 pm
  ev stage_complete pm "$n" "" PASS "" 3800
  ev pm pm "$n" "" "" "**BLOCKED: #$n is an epic, so I posted a decomposition proposal and stopped." 3790
done
snap 5000 "$COLLECT"
PAGE="$(render)"
for n in 598 687 753 790; do
  assert_eq "no" "$(in_flight "$PAGE" "$n")" "AC6 closed epic #$n is not In flight" "$(section "$PAGE" flight)"
done
assert_eq "0" "$(tile "$PAGE" 'in flight')" "AC6 the in-flight tile counts none of the closed epics"

finish
