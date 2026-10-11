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
#   AC9 `talos.sh run` writes the snapshot and the map at its end; a map failure warns
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
EARLY="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"

ev() {  # one event line: event role issue pr verdict tokens summary
  python3 -I -c '
import json, sys
e = {"event": sys.argv[1], "role": sys.argv[2], "issue": int(sys.argv[3]),
     "pr": int(sys.argv[4]) if sys.argv[4] else None, "verdict": sys.argv[5] or None,
     "tokens": int(sys.argv[6]) if sys.argv[6] else None, "summary": sys.argv[7], "ts": sys.argv[8]}
print(json.dumps(e))' "$@" "$NOW" >> "$STATE/events.jsonl"
}
ev validator validator 11 "" CONFIRMED 1000 ""
ev developer developer 11 21 PR_OPENED 5000 ""
ev qa qa 11 21 PASS 2000 ""
ev merged orchestrator 11 21 "" "" "merged"
ev developer developer 12 22 PR_OPENED 3000 ""
ev reviewer reviewer 12 22 CHANGES 1000 '<script>alert(1)</script> needs "onload= work'
ev blocked orchestrator 12 22 "" "" '<script>alert(1)</script> needs "onload= work'
ev developer developer 13 23 PR_OPENED 4000 ""
python3 -I -c '
import json, sys
json.dump({"ts": sys.argv[2], "run": {"active": False, "started": sys.argv[3], "end": "stop merged pr=21"},
           "collect": {"prs": [{"n": 23, "issue": 13, "head": "a1", "owner": False, "stage": "qa"}],
                       "queued": [14], "inflight": [], "held": [], "blocked": [["issue", 12]],
                       "owners": [{"n": 15, "status": "unanswered", "question": "Pick A or B? <img src=x onerror=alert(1)>"}],
                       "priority": {"14": 0}}}, open(sys.argv[1], "w"))' "$STATE/state.json" "$NOW" "$EARLY"
mkdir -p "$HOME/.cache/talos/meta"
printf 'Add a <b>bold</b> title\n' > "$HOME/.cache/talos/meta/acme_widget.issue-title.13"

# AC5: a gh that fails and logs every call, first on PATH; no provider script is reachable.
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\necho "$*" >> "%s/gh.calls"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/gh"
chmod +x "$SANDBOX/bin/gh"
cp "$SANDBOX/bin/gh" "$SANDBOX/bin/curl"

OUT="$(PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC1 talos.sh map exits 0" "$(cat "$SANDBOX/err")"
assert_eq "map=$MAP
index=$TH/maps/index.html" "$OUT" "AC1 map= and index= name the files under TALOS_HOME"
assert_file_exists "$MAP" "AC1 the repository's page is written"
assert_file_exists "$TH/maps/index.html" "AC1 the index is written"
PAGE="$(cat "$MAP" 2>/dev/null)"
assert_file_absent "$SANDBOX/gh.calls" "AC5 rendering made no gh or curl call"
assert_file_exists "$MAP" "AC5 the page is written with every gh and curl call failing"

# AC2: the cards.
card() { python3 -I -c '
import re, sys
m = re.search(r"<article class=\"card ([a-z]+)\"><h3><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>(.*?)</article>" % (sys.argv[2], sys.argv[2]), open(sys.argv[1]).read(), re.S)
print(m.group(1) if m else "<none>")' "$MAP" "$1"; }
assert_eq "done" "$(card 11)" "AC2 a merged issue is Done"
assert_eq "stuck" "$(card 12)" "AC2 a blocked issue is Stuck"
assert_eq "inprogress" "$(card 13)" "AC2 an issue with an open PR is In progress"
assert_eq "notstarted" "$(card 14)" "AC2 a queued issue is Not started"
assert_contains "$PAGE" '<a href="https://github.com/acme/widget/pull/23">#23</a>' "AC2 the in-flight card links its PR"
assert_contains "$PAGE" '<p class="why">&lt;script&gt;alert(1)&lt;/script&gt; needs &quot;onload= work</p>' "AC2 the stuck card says why, escaped"
assert_contains "$PAGE" 'Add a &lt;b&gt;bold&lt;/b&gt; title' "AC2 a cached title is shown, escaped"

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

# AC6: no snapshot.
mv "$STATE/state.json" "$STATE/state.json.saved"
OUT="$(bash "$TALOS" map 2>/dev/null)"
assert_eq "1" "$(grep -c 'No run state yet' "$MAP")" "AC6 without a snapshot the page says so once"
assert_eq "inprogress" "$(card 13)" "AC6 the events log alone still gives the cards"
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
git remote set-url origin https://dev.azure.com/org/proj/_git/widget
printf '{"vcs": {"provider": "azure"}}\n' > "$PIPELINE_CONFIG"
bash "$TALOS" map >/dev/null 2>&1
P="$(cat "$TH/maps/_git-widget.html" 2>/dev/null)"
assert_contains "$P" 'https://dev.azure.com/org/proj/_git/widget/_workitems/edit/13' "AC8 an Azure DevOps work item link"
assert_contains "$P" 'https://dev.azure.com/org/proj/_git/widget/pullrequest/23' "AC8 an Azure DevOps pull request link"
git remote set-url origin git@github.com:acme/widget.git
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"

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

finish
