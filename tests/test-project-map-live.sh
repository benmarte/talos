#!/usr/bin/env bash
# test-project-map-live.sh -- the project map during a run (#878): redrawn when
# a stage starts, closed issues leave In flight, one run record per lane.
#   AC1 the map is redrawn after a stage's stage_start is logged (the agent
#       already sees the issue's stage as running now, with its age)
#   AC2 with a collect, an issue it does not list and with no running stage
#       leaves In flight and the in-flight tile
#   AC3 with no collect, In flight is built from the events log as today
#   AC4 two runs in two worktrees each keep a lane record; state.json's run stays
#   AC5 the Lanes panel: one row per live lane, `lane <n> · #<issue>`, `<role> · <age>`
#   AC6 a dead or stale lane record shows no row; the pill counts live lanes
#   AC7 Merged and Queued cells but the title and why-it-waits carry a no-wrap class
# AC8 is pinned by tests/test-project-map.sh (AC5, AC9); AC9 is prose.
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
cache_title() { printf '%s\n' "$2" > "$META/acme_widget.issue.$1"; }
render() { bash "$TALOS" map >/dev/null 2>"$SANDBOX/err"; cat "$MAP" 2>/dev/null; }
tile() {  # <page> <label>: the number on a tile
  python3 -I -c '
import re, sys
m = re.search(r"<b>(\d+)</b><span>%s</span>" % sys.argv[2], sys.argv[1])
print(m.group(1) if m else "<none>")' "$1" "$2"
}
in_flight() {  # <page> <issue>: yes when the issue has a row in the In flight section
  python3 -I -c '
import re, sys
m = re.search(r"<section id=\"flight\">.*?</section>", sys.argv[1], re.S)
print("yes" if m and (">#%s</a>" % sys.argv[2]) in m.group(0) else "no")' "$1" "$2"
}
DEAD="$(sh -c 'echo $$')"

# ── AC2 and AC3: In flight comes from the collect ────────────────────────────
: > "$STATE/events.jsonl"
# 40: finished a stage after the collect was read, then nothing: closed by hand later.
ev validator validator 40 "" CONFIRMED "" 3000
ev pm pm 40 "" "" "" 100
# 41: a stage running now, which the collect does not list.
ev validator validator 41 "" CONFIRMED "" 3000
ev stage_start orchestrator 41 "" "" "" 50 pm
# 42: in the collect's in-flight list, nothing newer than the collect.
ev validator validator 42 "" CONFIRMED "" 4000
# 43: held by the collect, events after it.
ev validator validator 43 "" CONFIRMED "" 100
COLLECT='{"prs": [], "queued": [], "inflight": [42], "held": [43], "blocked": [], "owners": [], "capped": []}'
snap 5000 "$COLLECT"
PAGE="$(render)"
assert_eq "no" "$(in_flight "$PAGE" 40)" "AC2 an issue with only old events and no collect listing leaves In flight"
assert_eq "yes" "$(in_flight "$PAGE" 41)" "AC2 an issue with a running stage stays in flight"
assert_eq "yes" "$(in_flight "$PAGE" 42)" "AC2 an issue the collect lists as in flight stays in flight"
assert_eq "3" "$(tile "$PAGE" 'in flight')" "AC2 the in-flight tile counts only the live ones" "$PAGE"
snap 5000 none
PAGE="$(render)"
assert_eq "yes" "$(in_flight "$PAGE" 40)" "AC3 with no collect, In flight comes from the events log"
assert_eq "4" "$(tile "$PAGE" 'in flight')" "AC3 with no collect, the tile counts the events log's issues"

# ── AC5 and AC6: the Lanes panel and the pill ────────────────────────────────
: > "$STATE/events.jsonl"
snap 600 "$COLLECT" "$$"
lane lane-1 9 qa 125 "$$" 125
lane lane-2 10 developer 3700 "$$" 60
lane lane-3 11 pm 100 "$DEAD" 100
lane lane-4 12 pm 100 "$$" 25000
PAGE="$(render)"
LANES="$(python3 -I -c '
import re, sys
m = re.search(r"<section[^>]*id=\"lanes\"[^>]*>.*?</section>", sys.argv[1], re.S)
print(m.group(0) if m else "<none>")' "$PAGE")"
assert_contains "$LANES" 'lane 1 · <a href="https://github.com/acme/widget/issues/9">#9</a>' "AC5 a lane row names the lane and the issue"
assert_contains "$LANES" 'lane 2 · <a href="https://github.com/acme/widget/issues/10">#10</a>' "AC5 the second lane has its own row"
assert_contains "$LANES" 'qa · 2 min' "AC5 a lane row names the role and the stage age"
assert_contains "$LANES" 'developer · 1 h 1 min' "AC5 the second lane's role and age"
assert_contains "$PAGE" '<aside><section id="lanes">' "AC5 the Lanes panel opens the side column"
assert_not_contains "$LANES" '#11' "AC6 a lane whose pid is dead has no row"
assert_not_contains "$LANES" '#12' "AC6 a lane record the run has not touched for a stage-less age has no row"
assert_contains "$PAGE" 'Run going · 2 lanes · started' "AC6 the pill counts the two live lanes, not the dead or stale ones"
rm -f "$STATE/lanes/lane-2.json"
PAGE="$(render)"
assert_not_contains "$PAGE" 'lanes ·' "AC6 one live lane keeps today's pill text"
assert_contains "$PAGE" 'Run going · started' "AC6 one live lane says Run going · started"
rm -f "$STATE/lanes/lane-1.json"
PAGE="$(render)"
assert_not_contains "$PAGE" 'Run going' "AC6 with no live lane the run is not going"
assert_not_contains "$PAGE" 'id="lanes"' "AC6 with no live lane there is no Lanes panel"
rm -rf "${STATE:?}/lanes"
snap 600 "$COLLECT" "$$"
assert_contains "$(render)" 'Run going · started' "AC6 with no lane record the legacy run entry decides"

# ── AC7: the no-wrap class ───────────────────────────────────────────────────
: > "$STATE/events.jsonl"
ev developer developer 70 170 PR_OPENED "" 20000
ev merged orchestrator 70 170 "" merged 3600
cache_title 70 "A merged title that is long enough to wrap in a narrow column"
cache_title 71 "A queued title"
snap 600 '{"prs": [], "queued": [71], "inflight": [], "held": [], "blocked": [], "owners": [], "capped": [], "priority": {"71": 1}}'
PAGE="$(render)"
assert_contains "$PAGE" '.nw{white-space:nowrap}' "AC7 the page's CSS has a no-wrap class"
cells() {  # <page> <section marker>: for each data row, the class of each cell, title and why cells as "T"
  python3 -I -c '
import re, sys
sec = re.search(sys.argv[2] + r".*?</section>", sys.argv[1], re.S)
out = []
for row in re.findall(r"<tr>(.*?)</tr>", sec.group(0), re.S) if sec else []:
    cells = re.findall(r"<td([^>]*)>(.*?)</td>", row, re.S)
    if not cells:
        continue
    out.append(" ".join(("nw" if "nw" in (re.search(r"class=\"([^\"]*)\"", a) or [0, ""])[1].split() else "plain") for a, _ in cells))
print("|".join(out) if out else "<none>")' "$1" "$2"
}
assert_eq "nw plain nw nw nw" "$(cells "$PAGE" '<section><h2>Merged')" "AC7 a Merged row: issue, title, PR, age and tokens never wrap; only the title can"
assert_eq "nw nw plain nw plain" "$(cells "$PAGE" '<section id="queue">')" "AC7 a Queued row: position, issue, priority never wrap; title and why-it-waits can"

# ── AC1 and AC4: the driver ──────────────────────────────────────────────────
DS="$SANDBOX/ds"
mkdir -p "$DS" "$SANDBOX/stub" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$DS/" 2>/dev/null
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/"
cat > "$DS/pipeline-vcs.sh" <<'TALOS_stubvcsLv7Xq2Bn'
#!/usr/bin/env bash
case "$1" in
  view-issue) printf '{"number": %s, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' "${2:-9}" ;;
  list-*) printf '[]' ;;
esac
exit 0
TALOS_stubvcsLv7Xq2Bn
printf '#!/usr/bin/env bash\nexit 0\n' > "$DS/pipeline-notify.sh"
cp "$DS/pipeline-notify.sh" "$DS/pipeline-budget.sh"
printf '#!/usr/bin/env bash\ncat "%s/stub/collect.json"\n' "$SANDBOX" > "$DS/pipeline-status-file.sh"
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9, 10], "held": [], "inflight": [], "owners": [], "capped": []}' > "$SANDBOX/stub/collect.json"
# The agent: records what the map file and the state dir hold while it runs, then
# waits for the test's `go` file (the two-lane run) before it answers.
cat > "$DS/pipeline-agent.sh" <<'TALOS_stubagentWk5Rp9Ty'
#!/usr/bin/env bash
cat > /dev/null
me="$(basename "$PWD")"
[ ! -f "$MAP" ] || cp "$MAP" "$SANDBOX/at-agent.$me.html"
ls "$STATE/lanes" > "$SANDBOX/lanes.$me" 2>/dev/null
: > "$SANDBOX/agent.started.$me"
if [ -n "${WAIT_FOR_GO:-}" ]; then
  for _i in $(seq 1 100); do [ -f "$SANDBOX/go" ] && break; sleep 0.2; done
fi
echo "CONFIRMED: real, reproducible, in scope"
TALOS_stubagentWk5Rp9Ty
export MAP STATE SANDBOX
: > "$STATE/events.jsonl"
rm -rf "${STATE:?}/lanes" "$STATE/state.json" "$MAP"
OUT="$(CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$DS/talos.sh" run --issue 9 --max-iterations 1 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC1 the run with a dispatched stage exits 0" "$OUT $(cat "$SANDBOX/err")"
SEEN="$(cat "$SANDBOX/at-agent.$(basename "$SANDBOX").html" 2>/dev/null)"
assert_file_exists "$SANDBOX/at-agent.$(basename "$SANDBOX").html" "AC1 the map file exists when the stage's agent starts"
assert_contains "$SEEN" '<span class="tag run">validator · running' "AC1 the page already shows the stage running now, with its age"
assert_eq "yes" "$(in_flight "$SEEN" 9)" "AC1 the dispatched issue is in flight on that page"
assert_eq "0" "$(ls "$STATE/lanes" 2>/dev/null | wc -l | tr -d ' ')" "AC4 a finished run removes its own lane record"
assert_contains "$(cat "$STATE/state.json" 2>/dev/null)" '"end": ' "AC4 the shared run entry is still written"

# AC4 and AC5: two runs in two worktrees of the sandbox repository.
git -C "$SANDBOX" config user.email t@example.com
git -C "$SANDBOX" config user.name t
git -C "$SANDBOX" worktree add -q "$SANDBOX/wt/lane-1" -b lane-one 2>/dev/null
git -C "$SANDBOX" worktree add -q "$SANDBOX/wt/lane-2" -b lane-two 2>/dev/null
rm -rf "${STATE:?}/lanes" "$STATE/state.json" "$SANDBOX/go" "$SANDBOX"/agent.started.* "$MAP"
: > "$STATE/events.jsonl"
export WAIT_FOR_GO=1
for L in 1 2; do
  n=$((8 + L))
  ( cd "$SANDBOX/wt/lane-$L" && CLAUDE_CONFIG_DIR="$SANDBOX/cc$L" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 \
      bash "$DS/talos.sh" run --issue "$n" --max-iterations 1 >/dev/null 2>"$SANDBOX/err$L" ) &
done
for _i in $(seq 1 100); do
  [ -f "$SANDBOX/agent.started.lane-1" ] && [ -f "$SANDBOX/agent.started.lane-2" ] && break
  sleep 0.2
done
assert_eq "2" "$(ls "$STATE/lanes" 2>/dev/null | wc -l | tr -d ' ')" "AC4 two runs keep two lane records, neither overwrote the other" "$(cat "$SANDBOX/err1" "$SANDBOX/err2" 2>/dev/null)"
LR="$(cat "$STATE"/lanes/*.json 2>/dev/null)"
assert_contains "$LR" '"issue": 9' "AC4 the first run's record names its issue"
assert_contains "$LR" '"issue": 10' "AC4 the second run's record names its issue"
assert_contains "$(cat "$STATE/state.json" 2>/dev/null)" '"run": {"active": true' "AC4 state.json's shared run entry is still written"
PAGE="$(render)"
assert_contains "$PAGE" 'lane 1 · <a href="https://github.com/acme/widget/issues/9">#9</a>' "AC5 the page lists lane 1 with its issue"
assert_contains "$PAGE" 'lane 2 · <a href="https://github.com/acme/widget/issues/10">#10</a>' "AC5 the page lists lane 2 with its issue"
assert_contains "$PAGE" 'validator · ' "AC5 each lane row names its role and age"
assert_contains "$PAGE" 'Run going · 2 lanes' "AC6 the pill counts the two running lanes"
: > "$SANDBOX/go"
wait
assert_eq "0" "$(ls "$STATE/lanes" 2>/dev/null | wc -l | tr -d ' ')" "AC4 both runs removed their records at the end"

finish
