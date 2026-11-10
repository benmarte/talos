#!/usr/bin/env bash
# test-project-map-skill.sh -- the project map for a run the /talos:pipeline skill
# drives (#887): `next`, `state` and `done` outside `talos.sh run` feed the map.
#   AC1 `next` writes state.json with the collect and collect_ts; `map` renders it
#   AC2 `state` and `state --summary` write the same snapshot
#   AC3 such a snapshot claims no live run: no `Run going` pill
#   AC4 `done` redraws the page
#   AC5 map.enabled false: no snapshot, no page, no index
#   AC6 a failing render in `done` is one warn; the next line and exit status hold
# AC7 and AC8 are the run driver's (tests/test-project-map*.sh). AC9 is prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg() { printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}%s}\n' "${1:-}" > "$PIPELINE_CONFIG"; }
cfg
TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
SNAP="$STATE/state.json"
mkdir -p "$STATE"
unset TALOS_COLLECT_CACHE TALOS_RUN_PID TALOS_RUN_STARTED

# A scripts dir whose collect answers one queued issue and whose vcs, notify,
# hooks, status and events are silent stubs: nothing here reaches a provider.
GS="$SANDBOX/gs"
mkdir -p "$GS"
cp "$TALOS_ROOT"/scripts/* "$GS/"
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done
cat > "$GS/pipeline-status-file.sh" <<'TALOS_k4v9q2mzx7pw'
#!/usr/bin/env bash
printf '%s' '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [["issue", 41]], "queued": [], "held": [], "inflight": [], "owners": [], "capped": [], "priority": {}}'
TALOS_k4v9q2mzx7pw
TALOS="$GS/talos.sh"
SUM="$SANDBOX/summary.txt"
printf 'one line\n' > "$SUM"

snap_field() {  # <python expr over snap>: a field of the snapshot, <none> when it is missing
  python3 -I -c '
import json, sys
try:
    snap = json.load(open(sys.argv[1]))
    print(eval(sys.argv[2]))
except Exception:
    print("<none>")' "$SNAP" "$1"
}
reset() { rm -rf "${STATE:?}/state.json" "${TH:?}/maps"; }
do_done() { OUT="$(bash "$TALOS" done validator --issue 42 --verdict CONFIRMED --summary-file "$SUM" 2>"$SANDBOX/err" </dev/null)"; RC=$?; }
has_ts() { [ "$(snap_field 'snap["collect_ts"]')" != "<none>" ] && echo yes || echo no; }

# ── AC1: next ─────────────────────────────────────────────────────────────────
reset
OUT="$(bash "$TALOS" next 2>"$SANDBOX/err" </dev/null)"; RC=$?
assert_eq "0" "$RC" "AC1 next exits 0 outside run" "$OUT"
assert_file_exists "$SNAP" "AC1 next writes state.json outside run"
assert_eq "[['issue', 41]]" "$(snap_field 'snap["collect"]["blocked"]')" "AC1 the snapshot holds the collect"
assert_eq "yes" "$(has_ts)" "AC1 the snapshot holds a collect_ts"
bash "$TALOS" map >/dev/null 2>&1
assert_contains "$(cat "$MAP" 2>/dev/null)" ">#41<" "AC1 map renders the collect's blocked issue"

# ── AC2: state, plain and --summary ───────────────────────────────────────────
reset
OUT="$(bash "$TALOS" state 2>"$SANDBOX/err" </dev/null)"; RC=$?
assert_eq "0" "$RC" "AC2 state exits 0" "$OUT"
assert_eq "[['issue', 41]]" "$(snap_field 'snap["collect"]["blocked"]')" "AC2 state writes the snapshot"
reset
OUT="$(bash "$TALOS" state --summary 2>"$SANDBOX/err" </dev/null)"; RC=$?
assert_eq "0" "$RC" "AC2 state --summary exits 0" "$OUT"
assert_eq "[['issue', 41]]" "$(snap_field 'snap["collect"]["blocked"]')" "AC2 state --summary writes the snapshot"
assert_eq "yes" "$(has_ts)" "AC2 state --summary stamps collect_ts"

# ── AC3: no claim of a live run ───────────────────────────────────────────────
reset
bash "$TALOS" next >/dev/null 2>&1 </dev/null
assert_file_exists "$SNAP" "AC3 the snapshot to judge exists"
assert_eq "no" "$([ "$(snap_field 'snap["run"].get("active")')" = True ] && echo yes || echo no)" "AC3 run.active is not true in a skill-driven snapshot"
bash "$TALOS" map >/dev/null 2>&1
assert_not_contains "$(cat "$MAP" 2>/dev/null)" "Run going" "AC3 the map shows no Run going pill"

# ── AC4: done redraws ─────────────────────────────────────────────────────────
reset
do_done
assert_eq "0" "$RC" "AC4 done exits 0" "$OUT"
assert_file_exists "$MAP" "AC4 done redraws the page outside run"

# ── AC5: map.enabled false ────────────────────────────────────────────────────
cfg ', "map": {"enabled": false}'
reset
bash "$TALOS" next >/dev/null 2>&1 </dev/null
bash "$TALOS" state >/dev/null 2>&1 </dev/null
bash "$TALOS" state --summary >/dev/null 2>&1 </dev/null
do_done
assert_file_absent "$SNAP" "AC5 map.enabled false: no snapshot"
assert_file_absent "$MAP" "AC5 map.enabled false: no page"
assert_file_absent "$TH/maps/index.html" "AC5 map.enabled false: no index"

# ── AC6: a failing render ─────────────────────────────────────────────────────
cfg
reset
do_done
GOOD_OUT="$OUT"; GOOD_RC="$RC"
reset
printf 'import sys\nsys.exit(1)\n' > "$GS/talos-map.py"
do_done
assert_eq "$GOOD_RC" "$RC" "AC6 a failing render leaves done's exit status"
assert_eq "$(grep '^next' <<< "$GOOD_OUT")" "$(grep '^next' <<< "$OUT")" "AC6 a failing render leaves done's next line"
assert_eq "1" "$(grep -c 'warn reason=map-failed' <<< "$OUT"$'\n'"$(cat "$SANDBOX/err")")" "AC6 a failing render is one warn"
cp "$TALOS_ROOT/scripts/talos-map.py" "$GS/talos-map.py"

finish
