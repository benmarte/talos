#!/usr/bin/env bash
# test-stage-usage-rows.sh -- one spend row per stage, with a real duration (#532).
#   AC1 pipeline-agent.sh times the stage itself: stage_complete carries duration_s >= 1
#   AC3 cost folds `done`'s usage-less verdict event into the stage_complete before it
#   AC4 the code driver's pair and the LLM loop's single event give the same row
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
mkdir -p "$SANDBOX/tmp"
export TMPDIR="$SANDBOX/tmp"
export TALOS_HOME="$SANDBOX/talos-home"
unset TALOS_TRANSCRIPT_PATH TALOS_STAGE_DURATION_S TALOS_ISSUE TALOS_PR

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
printf '#!/usr/bin/env bash\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh"
AGENT="$INST/scripts/pipeline-agent.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"

# ── AC1: the agent times the stage ───────────────────────────────────────────
mkdir -p "$SANDBOX/.git/talos"
: > "$LOG"
printf '{"agents": {"runner": "custom", "runner_cmd": "cat > /dev/null; sleep 1; exit 0"}}\n' > "$SANDBOX/talos.pipeline.json"
TALOS_ISSUE=42 bash "$AGENT" qa "Check the criteria." >/dev/null 2>&1
DUR="$(python3 -I -c '
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sc = [e for e in ev if e.get("event") == "stage_complete"]
print(sc[-1].get("duration_s") if sc else "<none>")' "$LOG")"
case "$DUR" in
  ''|*[!0-9]*) fail "AC1 stage_complete carries the measured duration_s (>= 1)" "duration_s: $DUR" ;;
  *) [ "$DUR" -ge 1 ] && pass "AC1 stage_complete carries the measured duration_s (>= 1)" \
       || fail "AC1 stage_complete carries the measured duration_s (>= 1)" "duration_s: $DUR" ;;
esac

# ── AC3, AC4: one row per stage ──────────────────────────────────────────────
row() {  # the `cost --issue 42 --json` qa row: events tokens duration_s unrecorded
  bash "$EVENTS" cost --issue 42 --json 2>/dev/null | python3 -I -c '
import json, sys
r = [r for r in json.load(sys.stdin)["rows"] if r["role"] == "qa"][0]
print(r["events"], r["tokens"], r["duration_s"], r["unrecorded"])'
}
printf '%s\n' \
  '{"event":"stage_complete","role":"qa","issue":42,"pr":9,"verdict":"PASS","tokens":1000,"tool_uses":null,"duration_s":30,"ts":"2026-10-11T10:00:00Z"}' \
  '{"event":"qa","role":"qa","issue":42,"pr":9,"verdict":"PASS","tokens":null,"tool_uses":null,"duration_s":null,"ts":"2026-10-11T10:00:05Z"}' > "$LOG"
PAIR="$(row)"
assert_eq "1 1000 30 0" "$PAIR" "AC3 the driver's stage_complete and done's verdict event are one recorded run"
printf '%s\n' \
  '{"event":"qa","role":"qa","issue":42,"pr":9,"verdict":"PASS","tokens":1000,"tool_uses":null,"duration_s":30,"ts":"2026-10-11T10:00:05Z"}' > "$LOG"
assert_eq "$PAIR" "$(row)" "AC4 the LLM loop's single event gives the same row as the driver's pair"

finish
