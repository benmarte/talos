#!/usr/bin/env bash
# test-project-map-stalled.sh -- the project map never shows an old, unfinished
# stage as running (#888): past its stage timeout it reads `stalled since <date>`.
#   AC1 an open start older than its role's timeout (role key, else the global
#       key, else 6 h) renders `stalled since <YYYY-MM-DD>`, no running segment
#   AC2 an open start younger than the timeout still renders `running <dur>`
#   AC3 an activity row from before today shows the date and the time; today's
#       row shows only the time
#   AC4 no recorded run: the heading is `Activity · latest`; with one, `this run`
#   AC5 talos.sh passes the resolved timeouts to talos-map.py; the map still
#       renders when the flag is absent
#   AC6 a stalled render makes no gh, curl, glab or az call (map.enabled false is
#       pinned by tests/test-project-map.sh)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg_with() {  # <agents JSON>
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}, "agents": %s}\n' "$1" > "$PIPELINE_CONFIG"
}
cfg_with '{}'
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
snap() {  # <run started seconds ago | none> <collect JSON | none>
  python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
f = lambda s: (now - datetime.timedelta(seconds=int(s))).strftime("%Y-%m-%dT%H:%M:%SZ")
run = {} if sys.argv[2] == "none" else {"active": True, "started": f(sys.argv[2]), "end": ""}
snap = {"ts": f(0), "priority": {}, "run": run, "collect": {}}
if sys.argv[3] != "none":
    snap["collect"], snap["collect_ts"] = json.loads(sys.argv[3]), f(600)
json.dump(snap, open(sys.argv[1], "w"))' "$STATE/state.json" "$1" "$2"
}
render() { bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; cat "$MAP" 2>/dev/null; }
tile() {  # <page> <label>: the number on a tile
  python3 -I -c '
import re, sys
m = re.search(r"<b>(\d+)</b><span>%s</span>" % sys.argv[2], sys.argv[1])
print(m.group(1) if m else "<none>")' "$1" "$2"
}
flight_row() {  # <page> <issue>: the issue's row in the In flight section, or <none>
  python3 -I -c '
import re, sys
m = re.search(r"<section id=\"flight\">.*?</section>", sys.argv[1], re.S)
rows = re.split(r"(?=<div class=\"row\">)", m.group(0)) if m else []
row = next((r for r in rows if ">#%s</a>" % sys.argv[2] in r), None)
print(row if row else "<none>")' "$1" "$2"
}
running_segments() {  # <row>: how many bar segments carry the running class
  python3 -I -c '
import re, sys
print(len(re.findall(r"<li class=\"s r\">", sys.argv[1])))' "$1"
}
secs_to_date() {  # <seconds ago>: the UTC date then
  python3 -I -c '
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%d"))' "$1"
}
H=3600
open_start() {  # <issue> <role> <age s>: an open start, no collect (then the start counts)
  : > "$STATE/events.jsonl"
  ev validator validator "$1" "" CONFIRMED "" $(( $3 + 100 ))
  ev stage_start orchestrator "$1" "" "" "" "$3" "$2"
  snap none none
}

# ── AC1: an old open start is stalled, not running ───────────────────────────
cfg_with '{}'
open_start 70 qa $(( 7 * H ))
PAGE="$(render)"
ROW="$(flight_row "$PAGE" 70)"
assert_contains "$ROW" "stalled since $(secs_to_date $(( 7 * H )))" "AC1 a start older than the 6 h default reads stalled since its date" "$ROW"
assert_not_contains "$ROW" "running" "AC1 a stalled stage is not marked running"
assert_eq "0" "$(running_segments "$ROW")" "AC1 no segment of a stalled issue's stage bar is running" "$ROW"
# the role's own key beats the global one; the global one beats 6 h
cfg_with '{"stage_timeout_s": 43200, "roles": {"qa": {"stage_timeout_s": 3600}}}'
open_start 71 qa $(( 2 * H ))
ROW="$(flight_row "$(render)" 71)"
assert_contains "$ROW" "stalled since" "AC1 a role's stage_timeout_s (1 h) stalls a 2 h old start, though the global key says 12 h" "$ROW"
open_start 72 developer $(( 2 * H ))
ROW="$(flight_row "$(render)" 72)"
assert_contains "$ROW" "running" "AC1 a role with no key of its own uses the global 12 h: a 2 h start still runs" "$ROW"
cfg_with '{"stage_timeout_s": 3600}'
open_start 73 pm $(( 2 * H ))
ROW="$(flight_row "$(render)" 73)"
assert_contains "$ROW" "stalled since" "AC1 the global stage_timeout_s stalls a start older than it" "$ROW"

# ── AC2: a young open start still runs ───────────────────────────────────────
cfg_with '{}'
open_start 74 qa $(( 2 * H ))
PAGE="$(render)"
ROW="$(flight_row "$PAGE" 74)"
assert_contains "$ROW" '<span class="tag run">QA · running' "AC2 a start younger than the timeout still reads running" "$ROW"
assert_eq "1" "$(running_segments "$ROW")" "AC2 its bar segment is running" "$ROW"
assert_not_contains "$ROW" "stalled" "AC2 a young start is not stalled"
assert_eq "1" "$(tile "$PAGE" 'in flight')" "AC2 the in-flight tile counts it"

# ── AC3: dated activity rows ─────────────────────────────────────────────────
cfg_with '{}'
: > "$STATE/events.jsonl"
ev merged orchestrator 75 80 "" "" $(( 3 * 86400 ))
ev merged orchestrator 76 81 "" "" 20
snap none none
PAGE="$(render)"
OLD="$(python3 -I -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=3 * 86400)).strftime("%Y-%m-%d %H:%M"))')"
assert_contains "$PAGE" "<time>$OLD</time>" "AC3 a row from before today shows the date and the time" "$PAGE"
NEW_ROW="$(grep -o '<time>[^<]*</time><span><a[^>]*>#76' <<< "$PAGE" | head -1)"
assert_contains "$NEW_ROW" "<time>" "AC3 the row from today is on the page" "$PAGE"
assert_not_contains "$NEW_ROW" "$(secs_to_date 0)" "AC3 a row from today shows only the time" "$NEW_ROW"

# ── AC4: the heading says what the feed is ───────────────────────────────────
snap none none
PAGE="$(render)"
assert_contains "$PAGE" "Activity · latest" "AC4 with no recorded run the heading is Activity · latest" "$PAGE"
assert_not_contains "$PAGE" "Activity · this run" "AC4 no recorded run: not this run"
snap 5000 none
PAGE="$(render)"
assert_contains "$PAGE" "Activity · this run" "AC4 with a recorded run the heading stays Activity · this run" "$PAGE"

# ── AC5: talos.sh passes the timeouts, and the map renders without them ──────
cfg_with '{"stage_timeout_s": 7200, "roles": {"qa": {"stage_timeout_s": 600}}}'
assert_contains "$(sed -n '/^_talos_map_render() {/,/^}/p' "$TALOS")" "--stage-timeouts" "AC5 _talos_map_render passes --stage-timeouts to talos-map.py"
open_start 78 qa 3000
ROW="$(flight_row "$(render)" 78)"
assert_contains "$ROW" "stalled since" "AC5 the configured role timeout (600 s) reaches the map: a 50 min start is stalled" "$ROW"
open_start 79 pm 3000
ROW="$(flight_row "$(render)" 79)"
assert_contains "$ROW" "running" "AC5 the configured global timeout (7200 s) reaches the map: a 50 min pm start runs" "$ROW"
# talos-map.py run by hand without the flag: renders, 6 h default
: > "$STATE/events.jsonl"
ev stage_start orchestrator 80 "" "" "" $(( 7 * H )) developer
ev stage_start orchestrator 81 "" "" "" 600 developer
snap none none
printf 'https://github.com/acme/widget.git\n' | python3 -I "$TALOS_ROOT/scripts/talos-map.py" --events "$STATE/events.jsonl" \
  --state "$STATE/state.json" --home "$TH" --provider github --repo acme/widget --scripts "$TALOS_ROOT/scripts" --titles "$META" > "$SANDBOX/out" 2>"$SANDBOX/err"
assert_eq "0" "$?" "AC5 talos-map.py renders without the flag" "$(cat "$SANDBOX/err")"
PAGE="$(cat "$MAP")"
assert_contains "$(flight_row "$PAGE" 80)" "stalled since" "AC5 without the flag a 7 h start is stalled (6 h default)"
assert_contains "$(flight_row "$PAGE" 81)" "running" "AC5 without the flag a 10 min start is running"

# ── AC6: no provider call ────────────────────────────────────────────────────
mkdir -p "$SANDBOX/bin6"
printf '#!/bin/sh\necho "$0 $*" >> "%s/provider.calls"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin6/gh"
chmod +x "$SANDBOX/bin6/gh"
for c in curl glab az; do cp "$SANDBOX/bin6/gh" "$SANDBOX/bin6/$c"; done
open_start 82 qa $(( 9 * H ))
PATH="$SANDBOX/bin6:$PATH" bash "$TALOS" map >/dev/null 2>&1
PAGE="$(cat "$MAP" 2>/dev/null)"
assert_contains "$(flight_row "$PAGE" 82)" "stalled since" "AC6 a stalled stage renders with every provider command failing" "$PAGE"
assert_file_absent "$SANDBOX/provider.calls" "AC6 the stalled render made no gh, curl, glab or az call"

finish
