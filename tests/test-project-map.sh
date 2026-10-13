#!/usr/bin/env bash
# test-project-map.sh -- the project map (#614): `talos.sh map` renders one
# self-contained HTML page per repository and an index from local records only
# (the events log, the run's state snapshot, the title cache), and `talos.sh
# run` refreshes it.
#   AC1 the files and the map=/index= lines
#   AC2 one card per issue, in the right state
#   AC3 owner question, next step, changes since the run started, spend
#   AC4 every record value escaped, no script, no foreign link
#   AC5 no network or provider call
#   AC6 no snapshot: the events log alone, and one note saying so
#   AC7 the index lists every repository rendered under TALOS_HOME
#   AC8 GitLab and Azure DevOps link shapes
#   AC9 `talos.sh run` writes the snapshot each pass and the map at each stage end
#       and at its end; a map failure warns
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
mkdir -p "$STATE"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EARLY="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"  # bash3-ok: GNU date -d, with the BSD -v form as its fallback

ev() {  # one event line: event role issue pr verdict tokens summary
  python3 -I -c '
import json, sys
e = {"event": sys.argv[1], "role": sys.argv[2], "issue": int(sys.argv[3]),
     "pr": int(sys.argv[4]) if sys.argv[4] else None, "verdict": sys.argv[5] or None,
     "tokens": int(sys.argv[6]) if sys.argv[6] else None, "summary": sys.argv[7], "ts": sys.argv[8]}
print(json.dumps(e))' "$@" "$NOW" >> "$STATE/events.jsonl"
}
ev validator validator 11 "" CONFIRMED 1000 ""
ev pm pm 11 "" "" "" ""   # pm finishes with no verdict
ev developer developer 11 21 PR_OPENED 5000 ""
ev qa qa 11 21 PASS 2000 ""
ev merged orchestrator 11 21 "" "" "merged"
ev developer developer 12 22 PR_OPENED 3000 ""
ev reviewer reviewer 12 22 CHANGES 1000 '<script>alert(1)</script> needs "onload= work'
ev blocked orchestrator 12 22 "" "" '<script>alert(1)</script> needs "onload= work'
ev developer developer 13 23 PR_OPENED 4000 ""
# The snapshot's own `priority` holds every tier a collect has named: the
# collect's covers the queued and in-flight issues only, so #11 (merged) is in
# the first and not in the second.
python3 -I -c '
import json, sys
json.dump({"ts": sys.argv[2], "run": {"active": False, "started": sys.argv[3], "end": "stop merged pr=21"},
           "priority": {"11": 0, "14": 0},
           "collect": {"prs": [{"n": 23, "issue": 13, "head": "a1", "owner": False, "stage": "qa"}],
                       "queued": [14], "inflight": [], "held": [], "blocked": [["issue", 12]],
                       "owners": [{"n": 15, "status": "unanswered", "question": "Pick A or B? <img src=x onerror=alert(1)>"}],
                       "priority": {"14": 0}}}, open(sys.argv[1], "w"))' "$STATE/state.json" "$NOW" "$EARLY"
# The title cache, named as pipeline-meta.sh names it: <owner>_<name>.issue.<n>.
mkdir -p "$HOME/.cache/talos/meta"
printf 'Add a <b>bold</b> title\n' > "$HOME/.cache/talos/meta/acme_widget.issue.13"

# AC5: a gh, curl, glab and az that fail and log every call, first on PATH, and
# a copied scripts dir with no pipeline-vcs.sh: no provider script is reachable.
mkdir -p "$SANDBOX/bin" "$SANDBOX/ns"
printf '#!/bin/sh\necho "$0 $*" >> "%s/provider.calls"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/gh"
chmod +x "$SANDBOX/bin/gh"
for c in curl glab az; do cp "$SANDBOX/bin/gh" "$SANDBOX/bin/$c"; done
cp "$TALOS_ROOT"/scripts/* "$SANDBOX/ns/" 2>/dev/null
rm -f "$SANDBOX/ns/pipeline-vcs.sh"

OUT="$(PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/ns/talos.sh" map 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC1 talos.sh map exits 0" "$(cat "$SANDBOX/err")"
assert_eq "map=$MAP
index=$TH/maps/index.html" "$OUT" "AC1 map= and index= name the files under TALOS_HOME"
assert_file_exists "$MAP" "AC1 the repository's page is written"
assert_file_exists "$TH/maps/index.html" "AC1 the index is written"
PAGE="$(cat "$MAP" 2>/dev/null)"
assert_file_absent "$SANDBOX/provider.calls" "AC5 rendering made no gh, curl, glab or az call"
assert_file_exists "$MAP" "AC5 the page is written with no pipeline-vcs.sh and every provider command failing"

# AC2: the cards.
card() {  # <issue> [<page>]: the state class of the issue's card
  python3 -I -c '
import re, sys
m = re.search(r"<article class=\"card ([a-z]+)\"><h3><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>(.*?)</article>" % (sys.argv[2], sys.argv[2]), open(sys.argv[1]).read(), re.S)
print(m.group(1) if m else "<none>")' "${2:-$MAP}" "$1"
}
assert_eq "done" "$(card 11)" "AC2 a merged issue is Done"
assert_eq "stuck" "$(card 12)" "AC2 a blocked issue is Stuck"
assert_eq "inprogress" "$(card 13)" "AC2 an issue with an open PR is In progress"
assert_eq "notstarted" "$(card 14)" "AC2 a queued issue is Not started"
assert_contains "$PAGE" '<a href="https://github.com/acme/widget/pull/23">#23</a>' "AC2 the in-flight card links its PR"
assert_contains "$PAGE" '<p class="why">&lt;script&gt;alert(1)&lt;/script&gt; needs &quot;onload= work</p>' "AC2 the stuck card says why, escaped"
assert_contains "$PAGE" 'Add a &lt;b&gt;bold&lt;/b&gt; title' "AC2 a cached title is shown, escaped"
assert_contains "$PAGE" '#11</a> </h3><p class="dots" title="validator pm developer review qa merge">●●●○●●</p>' \
  "AC2 a stage that finishes with no verdict fills its dot, as on the status line"
# The track: each tier's merged / in flight / queued counts. A merged issue is
# counted in the tier it had while it was queued.
assert_contains "$PAGE" '<li class="here"><b>p0</b> 1 merged · 0 in flight · 1 queued <span class="you">you are here</span></li>' \
  "AC2 the track counts a merged issue in its own tier and marks the current one"
assert_contains "$PAGE" '<li class=""><b>unlabelled</b> 0 merged · 3 in flight · 0 queued</li>' \
  "AC2 the track's unlabelled tier holds only the issues with no tier (the owner question's issue is Stuck)"

# AC3: owner question, next step, changes, spend.
assert_contains "$PAGE" 'Pick A or B? &lt;img src=x onerror=alert(1)&gt;' "AC3 the owner question is quoted, escaped"
assert_contains "$PAGE" '<h2>Next step</h2><p>' "AC3 the next step section is there"
assert_not_contains "$PAGE" '<h2>Next step</h2><p>unknown</p>' "AC3 the next step comes from the snapshot"
assert_contains "$PAGE" 'merged PR #21' "AC3 the merge since the run started is listed"
assert_contains "$PAGE" 'reviewer CHANGES' "AC3 the verdict since the run started is listed"
assert_contains "$PAGE" '<tr class="total"><td>total</td><td>16k</td></tr>' "AC3 the spend total sums the issues shown"

# AC4: escaping, no script, no foreign link.
assert_contains "$PAGE" '&lt;script&gt;alert(1)&lt;/script&gt;' "AC4 a record's script tag appears escaped"
assert_not_contains "$(printf '%s' "$PAGE" | tr '[:upper:]' '[:lower:]')" '<script' "AC4 the page carries no script tag"
assert_not_contains "$PAGE" '<img' "AC4 a record's markup never reaches the page as markup"
FOREIGN="$(grep -oE 'https?://[^"<> ]+' "$MAP" | grep -v '^https://github.com/acme/widget/' || true)"
assert_eq "" "$FOREIGN" "AC4 the only links are the provider's"

# Two renders at once (two repositories under one TALOS_HOME, two runs in one
# repository): a render writes through names of its own, so a file another
# render has half written is neither overwritten nor moved into place.
printf 'half' > "$TH/maps/index.json.tmp"
printf 'half' > "$STATE/state.json.collect.json"
bash "$TALOS" map >/dev/null 2>&1
assert_eq "half" "$(cat "$TH/maps/index.json.tmp" 2>/dev/null)" "AC7 a render leaves another render's temp file of the registry alone"
assert_eq "half" "$(cat "$STATE/state.json.collect.json" 2>/dev/null)" "AC3 the next step's scratch file is the render's own"

# AC6: no snapshot.
mv "$STATE/state.json" "$STATE/state.json.saved"
OUT="$(bash "$TALOS" map 2>/dev/null)"
assert_eq "1" "$(grep -c 'No run state yet' "$MAP")" "AC6 without a snapshot the page says so once"
assert_eq "inprogress" "$(card 13)" "AC6 the events log alone still gives the cards"
# A relative events.path that leaves the git common dir is no log: the writer
# refuses it, and so does the map.
printf '{"event": "developer", "role": "developer", "issue": 77, "pr": null, "verdict": "PR_OPENED", "ts": "%s"}\n' "$NOW" > "$SANDBOX/escape.jsonl"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "events": {"path": "../escape.jsonl"}}\n' > "$PIPELINE_CONFIG"
bash "$TALOS" map >/dev/null 2>&1
assert_eq "<none>" "$(card 77)" "AC6 an events.path that leaves the git common dir is not read"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
# A snapshot with no collect in it (a run that ended before it read the state)
# is no queue view either: never "nothing queued".
python3 -I -c '
import json, sys
json.dump({"ts": sys.argv[2], "collect": {},
           "run": {"active": False, "started": "", "end": "stop reason=state-unavailable"}}, open(sys.argv[1], "w"))' "$STATE/state.json" "$NOW"
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$MAP" 2>/dev/null)"
assert_eq "1" "$(grep -c 'No run state yet' "$MAP")" "AC6 a snapshot with an empty collect says the queue view needs a run, once"
assert_not_contains "$P" '<h2>Next step</h2>' "AC6 an empty collect is never shown as an empty queue"
assert_not_contains "$P" 'Nothing waits on you' "AC6 an empty collect is never shown as no owner question"
assert_contains "$P" 'stop reason=state-unavailable' "AC6 the run's end line still shows without a collect"
mv "$STATE/state.json.saved" "$STATE/state.json"

# AC7: a second repository under the same TALOS_HOME.
R2="$SANDBOX/other"
mkdir -p "$R2"
( cd "$R2" && git init -q && git remote add origin git@github.com:acme/gadget.git \
  && PIPELINE_CONFIG="$R2/cfg.json" && printf '{"vcs": {"provider": "github"}}\n' > "$R2/cfg.json" \
  && PIPELINE_CONFIG="$R2/cfg.json" bash "$TALOS" map >/dev/null 2>&1 )
IDX="$(cat "$TH/maps/index.html" 2>/dev/null)"
assert_contains "$IDX" '<a href="acme-widget.html">acme/widget</a>' "AC7 the index links the first repository's map"
assert_contains "$IDX" '<a href="acme-gadget.html">acme/gadget</a>' "AC7 the index links the second repository's map"
assert_contains "$IDX" 'stuck' "AC7 each entry carries its one-line state"

# AC8: provider link shapes.
git remote set-url origin git@gitlab.example.com:grp/widget.git
printf '{"vcs": {"provider": "gitlab"}}\n' > "$PIPELINE_CONFIG"
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$TH/maps/grp-widget.html" 2>/dev/null)"
assert_contains "$P" 'https://gitlab.example.com/grp/widget/-/issues/13' "AC8 a GitLab issue link"
assert_contains "$P" 'https://gitlab.example.com/grp/widget/-/merge_requests/23' "AC8 a GitLab merge request link"
git remote set-url origin git@gitlab.example.com:grp/sub/widget.git
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$TH/maps/grp-sub-widget.html" 2>/dev/null)"
assert_contains "$P" 'https://gitlab.example.com/grp/sub/widget/-/issues/13' "AC8 a GitLab subgroup keeps its whole path"
# Azure DevOps: work items belong to the project and pull requests to the
# repository; the page is named by organisation, project and repository.
azure_page() {  # <file> <case> <project URL> <repository>
  P="$(cat "$TH/maps/$1" 2>/dev/null)"
  assert_contains "$P" "href=\"$3/_workitems/edit/13\"" "AC8 an Azure DevOps work item link ($2)"
  assert_contains "$P" "href=\"$3/_git/$4/pullrequest/23\"" "AC8 an Azure DevOps pull request link ($2)"
  assert_not_contains "$P" "_git/$4/_workitems" "AC8 no work item link under the repository ($2)"
}
printf '{"vcs": {"provider": "azure"}}\n' > "$PIPELINE_CONFIG"
git remote set-url origin https://dev.azure.com/org/proj/_git/widget
bash "$TALOS" map >/dev/null 2>&1
azure_page org-proj-widget.html "https remote" https://dev.azure.com/org/proj widget
git remote set-url origin git@ssh.dev.azure.com:v3/org/other/widget
bash "$TALOS" map >/dev/null 2>&1
azure_page org-other-widget.html "ssh remote, the same repository name in another project" https://dev.azure.com/org/other widget
printf '{"vcs": {"provider": "azure", "repo": "gadget", "azure": {"org_url": "https://dev.azure.com/acme/", "project": "Web Shop"}}}\n' > "$PIPELINE_CONFIG"
bash "$TALOS" map >/dev/null 2>&1
azure_page acme-Web-Shop-gadget.html "vcs.azure.org_url and vcs.azure.project" https://dev.azure.com/acme/Web%20Shop gadget
assert_file_absent "$TH/maps/_git-widget.html" "AC8 no Azure DevOps page is named after the _git path segment"
# GitHub on another host (GitHub Enterprise): the links go to the remote's host.
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
git remote set-url origin git@ghe.example.com:acme/widget.git
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$MAP" 2>/dev/null)"
assert_contains "$P" 'href="https://ghe.example.com/acme/widget/issues/13"' "AC8 a GitHub issue link on the remote's own host"
assert_contains "$P" 'href="https://ghe.example.com/acme/widget/pull/23"' "AC8 a GitHub pull request link on the remote's own host"
git remote set-url origin git@github.com:acme/widget.git

# AC9: the driver. A copied scripts dir whose collect answers an empty queue:
# the run ends at its first wait; its exit hook writes the snapshot and the map.
GS="$SANDBOX/gs"
mkdir -p "$GS"
cp "$TALOS_ROOT"/scripts/* "$GS/"
printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"prs\": [], \"pr_total\": 0, \"ignored\": 0, \"blocked\": [], \"queued\": [], \"held\": [], \"inflight\": [], \"owners\": [], \"capped\": []}'" > "$GS/pipeline-status-file.sh"
rm -f "$MAP" "$STATE/state.json"
OUT="$(bash "$GS/talos.sh" run --max-iterations 1 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC9 the drained run exits 0" "$OUT"
assert_contains "$(cat "$STATE/state.json" 2>/dev/null)" '"end": "stop action=wait reason=none"' "AC9 the run's end line is in the snapshot"
assert_file_exists "$MAP" "AC9 the run refreshed the map at its end"
printf 'import sys\nsys.exit(1)\n' > "$GS/talos-map.py"
OUT="$(bash "$GS/talos.sh" run --max-iterations 1 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC9 a map failure never fails the run"
assert_contains "$(cat "$SANDBOX/err")" "warn reason=map-failed" "AC9 a map failure is one warn line"

# AC9: one dispatched stage. `done` empties the run's collect copy, so the
# refresh after it works from the collect the pass read: the page still shows
# the queue and the owner question, and the stage's own issue as in flight.
# The provider stub keeps the page as the second pass finds it (page.mid).
use_stubs
DS="$SANDBOX/ds"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR MAP
mkdir -p "$DS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$DS/" 2>/dev/null
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/"
cat > "$DS/pipeline-vcs.sh" <<'TALOS_stubvcsH4tNw8Zq'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
case "$1" in
  view-issue)
    [ -f "$d/page.mid" ] || [ ! -f "$MAP" ] || cp "$MAP" "$d/page.mid"
    cat "$d/view-issue" ;;
  list-*) printf '[]' ;;
esac
exit 0
TALOS_stubvcsH4tNw8Zq
printf '#!/usr/bin/env bash\nexit 0\n' > "$DS/pipeline-notify.sh"
cp "$DS/pipeline-notify.sh" "$DS/pipeline-budget.sh"
printf '#!/usr/bin/env bash\ncat > /dev/null\necho "CONFIRMED: real, reproducible, in scope"\n' > "$DS/pipeline-agent.sh"
printf '#!/usr/bin/env bash\ncat "%s/collect.json"\n' "$STUB_DIR" > "$DS/pipeline-status-file.sh"
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9, 14], "held": [], "inflight": [], "owners": [{"n": 15, "status": "unanswered", "question": "Ship it?"}], "capped": [], "priority": {"14": 0}}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}}\n' > "$PIPELINE_CONFIG"
rm -f "$MAP" "$STATE/state.json"
OUT="$(CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$DS/talos.sh" run --issue 9 --max-iterations 2 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC9 the run with a dispatched stage exits 0" "$OUT $(cat "$SANDBOX/err")"
MID="$STUB_DIR/page.mid"
assert_file_exists "$MID" "AC9 the run refreshed the map when the stage ended"
PM="$(cat "$MID" 2>/dev/null)"
assert_eq "notstarted" "$(card 14 "$MID")" "AC9 after a stage the page still shows the queued issue"
assert_contains "$PM" 'Ship it?' "AC9 after a stage the page still shows the owner question"
assert_not_contains "$PM" 'No run state yet' "AC9 after a stage the page has its queue view"
assert_eq "inprogress" "$(card 9 "$MID")" "AC9 the issue whose stage just ended is In progress, whatever the queue read before it said"
assert_contains "$PM" 'a run is going' "AC9 during the run the page says a run is going"
SNAP="$(cat "$STATE/state.json" 2>/dev/null)"
assert_contains "$SNAP" '"queued": [9, 14]' "AC9 the snapshot keeps the pass's collect after the stage and at the end"
assert_contains "$SNAP" '"end": "stop reason=iterations-exhausted max=2"' "AC9 the end line of a run that stops after a stage is in the snapshot"

# AC9: the snapshot's tiers outlive the collect that named them. The collect
# lists a tier only while its issue is queued or in flight; the next run's
# collect (here an empty queue) replaces the stored one and the tier stays.
snap_priority() {
  python3 -I -c '
import json, sys
try:
    print(json.dumps(json.load(open(sys.argv[1])).get("priority"), sort_keys=True))
except (OSError, ValueError):
    print("<unreadable>")' "$STATE/state.json"
}
assert_eq '{"14": 0}' "$(snap_priority)" "AC9 the snapshot records the tier of each issue the collect names"
bash "$GS/talos.sh" run --max-iterations 1 >/dev/null 2>&1
assert_contains "$(cat "$STATE/state.json" 2>/dev/null)" '"queued": []' "AC9 the next run's collect replaces the stored one"
assert_eq '{"14": 0}' "$(snap_priority)" "AC9 the snapshot keeps an issue's tier after it leaves the queue"

# ── follow-ups (#641): the AC ids below are that issue's ─────────────────────
cp "$TALOS_ROOT/scripts/talos-map.py" "$GS/talos-map.py"
cp "$STATE/events.jsonl" "$SANDBOX/events.saved"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
EMPTY_COLLECT='{"prs": [], "queued": [], "inflight": [], "held": [], "blocked": [], "owners": [], "capped": []}'
snap() {  # <collect JSON> <run JSON> [<snapshot time>]: the snapshot the render reads
  python3 -I -c '
import json, sys
json.dump({"ts": sys.argv[6], "collect_ts": sys.argv[3], "priority": {},
           "run": json.loads(sys.argv[5]), "collect": json.loads(sys.argv[4])}, open(sys.argv[1], "w"))' \
    "$STATE/state.json" "$NOW" "$EARLY" "$1" "$2" "${3:-$NOW}"
}
ENDED_RUN="{\"active\": false, \"started\": \"$EARLY\", \"end\": \"stop x\"}"
: > "$STATE/events.jsonl"
# AC1: a fix round whose stage is running is In progress, with its round number.
ev developer developer 31 41 PR_OPENED 100 ""
ev qa qa 31 41 FAIL 100 "QA FAIL: wrong"
ev blocked orchestrator 31 41 "" "" "QA FAIL: wrong"
ev stage_start orchestrator 31 41 "" "" ""
# AC2: an unanswered owner question is Stuck, the question its reason.
ev developer developer 32 42 PR_OPENED 100 ""
# AC3: a stage that ended BLOCKED:, and a gate's block, are Stuck.
ev developer developer 33 "" BLOCKED 100 "BLOCKED: need credentials"
snap '{"prs": [{"n": 41, "issue": 31, "head": "a", "owner": false, "stage": "developer"}, {"n": 44, "issue": 34, "head": "b", "owner": false, "stage": "qa"}],
       "queued": [], "inflight": [], "held": [], "blocked": [["issue", 31], ["issue", 34]],
       "owners": [{"n": 32, "status": "unanswered", "question": "Which API?"}], "capped": []}' "$ENDED_RUN"
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$MAP" 2>/dev/null)"
assert_eq "inprogress" "$(card 31)" "AC1 a running stage newer than the last failing verdict is In progress, not Stuck"
assert_contains "$P" 'fix round 1' "AC1 the card carries the fix round number"
assert_eq "stuck" "$(card 32)" "AC2 an unanswered owner question is Stuck"
assert_contains "$P" '<p class="why">Which API?</p>' "AC2 the card's reason is the question"
assert_eq "stuck" "$(card 33)" "AC3 a stage that ended BLOCKED: is Stuck"
assert_contains "$P" '<p class="why">BLOCKED: need credentials</p>' "AC3 the card says the BLOCKED: reason"
assert_eq "stuck" "$(card 34)" "AC3 an issue the gate blocked is Stuck"
ev stage_start orchestrator 33 "" "" "" ""
bash "$TALOS" map >/dev/null 2>&1
assert_eq "inprogress" "$(card 33)" "AC3 a BLOCKED: stage followed by a new stage_start is In progress"
cp "$SANDBOX/events.saved" "$STATE/events.jsonl"

# AC4: the key off. The dispatching copy runs two passes with a stage between.
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}, "map": {"enabled": false}}\n' > "$PIPELINE_CONFIG"
rm -rf "${TH:?}/maps"
rm -f "$STATE/state.json"
OUT="$(CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$DS/talos.sh" run --issue 9 --max-iterations 2 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC4 the run with the map off exits 0" "$OUT"
assert_file_absent "$STATE/state.json" "AC4 with map.enabled false the run writes no snapshot"
assert_file_absent "$TH/maps" "AC4 with map.enabled false the run writes no page or index"
assert_not_contains "$OUT" "map-failed" "AC4 with map.enabled false the run prints no map warn"

# AC5: an unwritable TALOS_HOME (a file where the directory should be).
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}}\n' > "$PIPELINE_CONFIG"
printf 'a file, not a directory' > "$SANDBOX/home-file"
OUT="$(CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_HOME="$SANDBOX/home-file" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$DS/talos.sh" run --issue 9 --max-iterations 2 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC5 the run with an unwritable TALOS_HOME exits 0" "$OUT"
assert_eq "1" "$(grep -c 'map-failed' <<< "$OUT")" "AC5 a multi-stage run prints one map warn in total" "$OUT"

# AC6: the render stub records whether the run's lease release has run; the
# release is marked in a copy of talos.sh.
LS="$SANDBOX/ls"
rm -rf "${LS:?}"; mkdir -p "$LS"
cp "$DS"/* "$LS/" 2>/dev/null
awk '{ print } /^_talos_lease_release_run_all\(\) \{/ { print "  echo released >> \"$SANDBOX_MARK\"" }' "$LS/talos.sh" > "$LS/talos.sh.new" && mv "$LS/talos.sh.new" "$LS/talos.sh"
cat > "$LS/talos-map.py" <<'TALOS_stubmapQk3Rt7Wx'
import os
open(os.environ["SANDBOX_LOG"], "a").write("render after-release=%s\n" % os.path.exists(os.environ["SANDBOX_MARK"]))
TALOS_stubmapQk3Rt7Wx
export SANDBOX_MARK="$SANDBOX/release.mark" SANDBOX_LOG="$SANDBOX/render.log"
rm -f "$SANDBOX_MARK" "$SANDBOX_LOG"
CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$LS/talos.sh" run --issue 9 --max-iterations 2 >/dev/null 2>&1
assert_eq "render after-release=True" "$(tail -n 1 "$SANDBOX_LOG" 2>/dev/null)" "AC6 the end-of-run render starts after the lease release (normal exit)"
# A signal exit: the dispatched agent waits, the run gets SIGTERM.
rm -f "$SANDBOX_MARK" "$SANDBOX_LOG" "$SANDBOX/agent.started"
printf '#!/usr/bin/env bash\ncat > /dev/null\ntouch "%s/agent.started"\nsleep 2\necho "CONFIRMED: ok"\n' "$SANDBOX" > "$LS/pipeline-agent.sh"
CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$LS/talos.sh" run --issue 9 --max-iterations 2 >/dev/null 2>&1 &
RUNPID=$!
for _i in $(seq 1 50); do [ -f "$SANDBOX/agent.started" ] && break; sleep 0.2; done
kill -TERM "$RUNPID" 2>/dev/null
wait "$RUNPID" 2>/dev/null
assert_eq "render after-release=True" "$(tail -n 1 "$SANDBOX_LOG" 2>/dev/null)" "AC6 the end-of-run render starts after the lease release (signal exit)"

# AC7: a run entry whose pid is dead, or that is too old, is an ended run.
DEADPID="$(sh -c 'echo $$')"
snap "$EMPTY_COLLECT" "{\"active\": true, \"started\": \"$NOW\", \"end\": \"\", \"pid\": $DEADPID}"
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$MAP" 2>/dev/null)"
assert_contains "$P" 'last run ended' "AC7 an active run entry whose pid is dead renders as an ended run"
assert_not_contains "$P" 'a run is going' "AC7 a dead pid is never a run going"
snap "$EMPTY_COLLECT" "{\"active\": true, \"started\": \"$NOW\", \"end\": \"\", \"pid\": $$}"
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP" 2>/dev/null)" 'a run is going' "AC7 an active run entry whose pid is alive is a run going"
snap "$EMPTY_COLLECT" "{\"active\": true, \"started\": \"2020-01-01T00:00:00Z\", \"end\": \"\", \"pid\": $$}" 2020-01-01T00:00:00Z
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP" 2>/dev/null)" 'last run ended' "AC7 an active run entry older than a stage could take renders as ended"
rm -f "$STATE/state.json"
bash "$GS/talos.sh" run --max-iterations 1 >/dev/null 2>&1
assert_contains "$(cat "$STATE/state.json" 2>/dev/null)" '"pid": ' "AC7 the snapshot's run entry records the pid"

# GUARD (not a red-to-green case): a three-segment vcs.repo (a GitLab subgroup) already
# rendered before #641, so AC8 of #641 needed no code change. Kept so it stays that way.
printf '{"vcs": {"provider": "gitlab", "repo": "grp/sub/widget"}}\n' > "$PIPELINE_CONFIG"
git remote set-url origin git@gitlab.example.com:grp/sub/widget.git
bash "$TALOS" map >/dev/null 2>&1
assert_file_exists "$TH/maps/grp-sub-widget.html" "GUARD a three-segment vcs.repo renders"
assert_contains "$(cat "$TH/maps/grp-sub-widget.html" 2>/dev/null)" 'https://gitlab.example.com/grp/sub/widget/-/issues/' "GUARD its links keep the whole path"
git remote remove origin
rm -f "$TH/maps/grp-sub-widget.html"
bash "$TALOS" map >/dev/null 2>&1
assert_file_exists "$TH/maps/grp-sub-widget.html" "GUARD a three-segment vcs.repo renders with no remote"
git remote add origin git@gitlab.example.com:grp/sub/widget.git

# AC9: names that differ only by where the dash and the slash sit.
printf '{"vcs": {"provider": "github", "repo": "a-b/c"}}\n' > "$PIPELINE_CONFIG"
git remote set-url origin git@github.com:a-b/c.git
bash "$TALOS" map >/dev/null 2>&1
printf '{"vcs": {"provider": "github", "repo": "a/b-c"}}\n' > "$PIPELINE_CONFIG"
git remote set-url origin git@github.com:a/b-c.git
bash "$TALOS" map >/dev/null 2>&1
IDX="$(cat "$TH/maps/index.html" 2>/dev/null)"
F1="$(sed -n 's|.*<a href="\([^"]*\)">a-b/c</a>.*|\1|p' <<< "$IDX")"
F2="$(sed -n 's|.*<a href="\([^"]*\)">a/b-c</a>.*|\1|p' <<< "$IDX")"
assert_eq "1" "$([ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && echo 1 || echo 0)" "AC9 a-b/c and a/b-c get different pages" "$F1 $F2"
assert_file_exists "$TH/maps/$F1" "AC9 the index links a-b/c to its own page"
assert_file_exists "$TH/maps/$F2" "AC9 the index links a/b-c to its own page"
git remote set-url origin git@github.com:acme/widget.git

finish
