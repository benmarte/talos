#!/usr/bin/env bash
# test-project-map-stale-open-894.sh -- an old, unfinished stage start reads
# `stalled since <date>` on every map row, also when the issue is in a fix round
# and its events carry a `blocked` after the start (#894):
#   AC1 the #870 event shape (old open `security` start, then reviewer CHANGES,
#       blocked, qa PASS, reviewer APPROVED) is stalled in In flight, no running segment
#   AC2 the same shape with a young start still reads running, one running segment
#   AC3 a Needs you row with an old open start then a BLOCKED event shows no
#       running segment (the row reads the same rule as the In flight row)
#   AC4 a plain open start (no blocked) keeps its #888 behaviour
#   AC5 the issue-state classification is unchanged (tiles, section membership)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}, "agents": {}}\n' > "$PIPELINE_CONFIG"
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
snap() {  # no collect, no run record: an open start then counts
  python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
json.dump({"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "priority": {}, "run": {}, "collect": {}}, open(sys.argv[1], "w"))' "$STATE/state.json"
}
render() { bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; cat "$MAP" 2>/dev/null; }
section_row() {  # <page> <section id> <issue>: the issue's row in that section, or <none>
  python3 -I -c '
import re, sys
m = re.search(r"<section[^>]*id=\"%s\">.*?</section>" % sys.argv[2], sys.argv[1], re.S)
rows = re.split(r"(?=<div class=\"row\">)", m.group(0)) if m else []
row = next((r for r in rows if ">#%s</a>" % sys.argv[3] in r), None)
print(row if row else "<none>")' "$1" "$2" "$3"
}
running_segments() {  # <row>: how many bar segments carry the running class
  python3 -I -c '
import re, sys
print(len(re.findall(r"<li class=\"s r\">", sys.argv[1])))' "$1"
}
tile() {  # <page> <label>: the number on a tile
  python3 -I -c '
import re, sys
m = re.search(r"<b>(\d+)</b><span>%s</span>" % sys.argv[2], sys.argv[1])
print(m.group(1) if m else "<none>")' "$1" "$2"
}
secs_to_date() {  # <seconds ago>: the UTC date then
  python3 -I -c '
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%d"))' "$1"
}
H=3600
fix_round() {  # <issue> <security start age s>: the #870 shape, no collect, no lane record
  : > "$STATE/events.jsonl"
  ev validator validator "$1" "" CONFIRMED "" $(( $2 + 4000 ))
  ev stage_start orchestrator "$1" "" "" "" $(( $2 + 1 )) reviewer
  ev stage_start orchestrator "$1" "" "" "" "$2" security
  ev reviewer reviewer "$1" 871 CHANGES "needs a change" 150
  ev blocked orchestrator "$1" 871 "" "fix round" 145
  ev qa qa "$1" 871 PASS "ok" 100
  ev reviewer reviewer "$1" 871 APPROVED "ok" 60
  snap
}
needs() {  # <issue> <start age s>: an open start, then a BLOCKED event as the last said event
  : > "$STATE/events.jsonl"
  ev validator validator "$1" "" CONFIRMED "" $(( $2 + 4000 ))
  ev stage_start orchestrator "$1" "" "" "" "$2" developer
  ev blocked orchestrator "$1" "" BLOCKED "needs a decision" 60
  snap
}
plain() {  # <issue> <age s>: an open start, nothing after it
  : > "$STATE/events.jsonl"
  ev validator validator "$1" "" CONFIRMED "" $(( $2 + 100 ))
  ev stage_start orchestrator "$1" "" "" "" "$2" qa
  snap
}

# ── AC1: the fix-round row of an old open start is stalled ───────────────────
fix_round 870 $(( 7 * H ))
PAGE="$(render)"
ROW="$(section_row "$PAGE" flight 870)"
assert_contains "$ROW" "stalled since $(secs_to_date $(( 7 * H )))" "AC1 a fix-round issue with a 7 h old open start reads stalled since its date" "$ROW"
assert_contains "$ROW" "fix round 1" "AC1 the row is the fix-round row" "$ROW"
assert_not_contains "$ROW" "running" "AC1 the stalled row has no running text"
assert_eq "0" "$(running_segments "$ROW")" "AC1 no stage-bar segment of the row is running" "$ROW"

# ── AC2: the same shape, a young start, still runs ───────────────────────────
fix_round 871 600
PAGE="$(render)"
ROW="$(section_row "$PAGE" flight 871)"
assert_contains "$ROW" '<span class="tag run">security · running' "AC2 a 10 min old open start still reads security · running" "$ROW"
assert_not_contains "$ROW" "stalled" "AC2 a young start is not stalled"
assert_eq "1" "$(running_segments "$ROW")" "AC2 one segment is running" "$ROW"

# ── AC3: a Needs you row reads the same rule ─────────────────────────────────
needs 872 $(( 7 * H ))
PAGE="$(render)"
ROW="$(section_row "$PAGE" needs 872)"
assert_not_contains "$ROW" "<none>" "AC3 the issue is a Needs you row" "$PAGE"
assert_eq "0" "$(running_segments "$ROW")" "AC3 an old open start followed by BLOCKED shows no running segment" "$ROW"
needs 873 600
ROW="$(section_row "$(render)" needs 873)"
assert_not_contains "$ROW" "<none>" "AC3 the young one is a Needs you row"
assert_eq "1" "$(running_segments "$ROW")" "AC3 a young open start keeps its running segment in the row" "$ROW"

# ── AC4: the plain open start ────────────────────────────────────────────────
plain 874 $(( 7 * H ))
ROW="$(section_row "$(render)" flight 874)"
assert_contains "$ROW" "stalled since $(secs_to_date $(( 7 * H )))" "AC4 an old open start with no blocked reads stalled since its date" "$ROW"
assert_eq "0" "$(running_segments "$ROW")" "AC4 and has no running segment" "$ROW"
plain 875 $(( 2 * H ))
ROW="$(section_row "$(render)" flight 875)"
assert_contains "$ROW" "QA · running" "AC4 a young plain open start reads running" "$ROW"

# ── AC5: classification is unchanged ─────────────────────────────────────────
fix_round 876 $(( 7 * H ))
PAGE="$(render)"
assert_not_contains "$(section_row "$PAGE" flight 876)" "<none>" "AC5 the stalled fix-round issue stays In progress" "$PAGE"
assert_eq "1" "$(tile "$PAGE" 'in flight')" "AC5 the in-flight tile counts it" "$PAGE"
assert_eq "<none>" "$(section_row "$PAGE" needs 876)" "AC5 and it is not a Needs you row" "$PAGE"
needs 877 $(( 7 * H ))
assert_eq "1" "$(tile "$(render)" 'needs you')" "AC5 the BLOCKED issue still counts as stuck" "$(cat "$SANDBOX/err")"

finish
