#!/usr/bin/env bash
# test-map-usage-elsewhere-914.sh -- the project map counts the `usage` events of
# an issue the provider merged with no local `merged` event (#914). Tests are
# named by the spec's id.
#   AC1 two usage events (1000 + 500) of a merged-elsewhere issue: the tokens
#       tile, tiles.tokens_7d and Top spend count 1500
#   AC2 plus a stage_complete (9000): still 1500
#   AC3 merged-elsewhere issues with no usage event: "not recorded", null
#   AC4 an issue with a local merged event sums stage and usage events (9500);
#       an orchestrator event stays excluded
#   AC5 the merged-elsewhere row keeps its label and shows no token bar
# AC6, AC7 and AC8 are prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID TALOS_COLLECT_CACHE
git config user.email "test@talos.invalid"
git config user.name "talos-test"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}}\n' > "$PIPELINE_CONFIG"

TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
INDEX="$TH/maps/index.json"
STATE="$SANDBOX/.git/talos"
SNAP="$STATE/state.json"
mkdir -p "$STATE" "$HOME/.cache/talos/meta"

# evtok <event> <role> <issue> <tokens> <days ago>: one event line with a token figure.
evtok() {
  python3 -I -c '
import datetime, json, sys
a = sys.argv
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(a[5]))
print(json.dumps({"event": a[1], "role": a[2], "issue": int(a[3]), "tokens": int(a[4]),
                  "summary": "", "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$@" >> "$STATE/events.jsonl"
}
# snapshot <issue>...: a state.json whose merged_remote lists one PR per issue, merged 2 days ago.
snapshot() {
  python3 -I -c '
import datetime, json, sys
t = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
prs = [{"number": 100 + int(n), "issue": int(n), "title": "feat: issue %s" % n, "mergedAt": t} for n in sys.argv[2:]]
json.dump({"ts": t, "priority": {}, "collect": {}, "run": {}, "merged_remote": prs,
           "merged_remote_ts": t}, open(sys.argv[1], "w"))' "$SNAP" "$@"
}
fixture() { rm -rf "${TH:?}/maps"; : > "$STATE/events.jsonl"; }
render() { OUT="$(bash "$TALOS_ROOT/scripts/talos.sh" map 2>"$SANDBOX/err" </dev/null)"; RC=$?; PAGE="$(cat "$MAP" 2>/dev/null)"; }
tokens_tile() {  # <page>: the tokens tile's figure and its caption
  python3 -I -c '
import re, sys
m = re.search(r"<b>([^<]*)</b><span>(tokens[^<]*)</span>", sys.argv[1])
print("%s|%s" % (m.group(1), m.group(2)) if m else "<none>")' "$1"
}
tokens_7d() { python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["acme/widget"]["tiles"]["tokens_7d"]))' "$INDEX" 2>/dev/null || echo "<none>"; }
spend_row() {  # <page> <issue>: the Top spend row of the issue
  python3 -I -c '
import re, sys
s = re.search(r"<h2>Top spend.*?</section>", sys.argv[1], re.S)
for r in re.findall(r"<tr><td>.*?</tr>", s.group(0) if s else "", re.S):
    if (">#%s<" % sys.argv[2]) in r:
        print(r); break' "$1" "$2"
}
row_of() {  # <page> <needle>: the merged-table row holding the needle
  python3 -I -c '
import re, sys
for r in re.findall(r"<tr>.*?</tr>", sys.argv[1], re.S):
    if sys.argv[2] in r:
        print(r); break' "$1" "$2"
}

# ── AC1: usage events of a merged-elsewhere issue ────────────────────────────
fixture
snapshot 13
evtok usage developer 13 1000 3
evtok usage developer 13 500 3
render
assert_eq "0" "$RC" "AC1 the map renders"
assert_contains "$PAGE" "merged elsewhere" "AC1 fixture: #13 is a merged-elsewhere issue"
assert_eq "2k|tokens · 7 days" "$(tokens_tile "$PAGE")" "AC1 the tokens tile counts the two usage events (1500 reads 2k)"
assert_eq "1500" "$(tokens_7d)" "AC1 tiles.tokens_7d is 1500"
assert_contains "$(spend_row "$PAGE" 13)" "2k" "AC1 Top spend lists #13 with its 1500"

# ── AC2: stage events stay excluded ──────────────────────────────────────────
evtok stage_complete developer 13 9000 3
render
assert_eq "2k|tokens · 7 days" "$(tokens_tile "$PAGE")" "AC2 the tile still counts 1500, not 10500"
assert_eq "1500" "$(tokens_7d)" "AC2 tiles.tokens_7d is still 1500"
assert_contains "$(spend_row "$PAGE" 13)" "2k" "AC2 Top spend still lists #13 at 1500"

# ── AC5: the row keeps its label, no bar ─────────────────────────────────────
ROW13="$(row_of "$PAGE" ">#13<")"
assert_contains "$ROW13" "merged elsewhere" "AC5 the row keeps the merged elsewhere label"
assert_not_contains "$ROW13" 'class="bar' "AC5 the row shows no token bar"

# ── AC3: no usage event: no figure, never 0 ──────────────────────────────────
fixture
snapshot 13 14
evtok stage_complete developer 13 9000 3
render
assert_eq "—|tokens · 7 days · not recorded" "$(tokens_tile "$PAGE")" "AC3 the tile reads — / not recorded"
assert_eq "null" "$(tokens_7d)" "AC3 tiles.tokens_7d is null"

# ── AC4: a locally merged issue sums stage and usage events ──────────────────
fixture
snapshot 13
evtok merged orchestrator 20 0 1
evtok stage_complete developer 20 9000 3
evtok usage developer 20 500 3
evtok stage_complete orchestrator 20 7000 3
render
assert_eq "9500" "$(tokens_7d)" "AC4 a locally merged issue counts its stage and usage events, not the orchestrator's"

finish
