#!/usr/bin/env bash
# test-run-end-event.sh -- the `run_end` event: `talos.sh run` appends one to the
# events log when it ends, carrying the stop line parsed into fields.
#   AC1 pipeline-hooks.sh run_end: one line, the fields of the stop line
#   AC2 absent words are null; detail= lands in detail
#   AC3 pipeline-events.sh list --event run_end shows it
#   AC4 events.enabled false, an unwritable and an escaping events.path
#   AC5 a real run that ends on a stop line leaves exactly one, output unchanged
#   AC6 a run that continues writes none; only the final image does
#   AC7 a run_end after a BLOCKED stage leaves the issue Stuck in the map
#   AC8 no cost view and no status line counts it
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
STATUS="$TALOS_ROOT/scripts/talos-status.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"

# field JSON-LINE KEY: one key from a JSON line (python3 -I).
field() {
  python3 -I -c '
import json, sys
try:
    v = json.loads(sys.argv[1]).get(sys.argv[2], "<absent>")
except ValueError:
    v = "<no event>"
print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"
}
lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
run_ends() { [ -f "$LOG" ] && grep -c '"event": "run_end"' "$LOG" || echo 0; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(bash "$HOOKS" run_end 'stop verdict=block reason=qa-fail role=qa issue=5 pr=7' 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC1 run_end exits 0"
assert_eq "" "$OUT" "AC1 run_end prints nothing on stdout"
assert_eq "1" "$(lines)" "AC1 exactly one line is appended"
L="$(tail -n 1 "$LOG" 2>/dev/null)"
assert_eq "run_end" "$(field "$L" event)" "AC1 event is run_end"
assert_eq "orchestrator" "$(field "$L" role)" "AC1 role stays orchestrator"
assert_eq "block" "$(field "$L" verdict)" "AC1 verdict"
assert_eq "qa-fail" "$(field "$L" reason)" "AC1 reason"
assert_eq "qa" "$(field "$L" stage)" "AC1 the stop line's role= goes to stage"
assert_eq "5" "$(field "$L" issue)" "AC1 issue"
assert_eq "7" "$(field "$L" pr)" "AC1 pr"
case "$(field "$L" ts)" in 20[0-9][0-9]-*T*Z) pass "AC1 ts is a UTC ISO-8601 stamp" ;; *) fail "AC1 ts is a UTC ISO-8601 stamp" "$L" ;; esac

# ── AC2 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
bash "$HOOKS" run_end 'stop reason=iterations-exhausted max=2' 2>/dev/null
L="$(tail -n 1 "$LOG" 2>/dev/null)"
assert_eq "null" "$(field "$L" verdict)" "AC2 no verdict= gives a null verdict"
assert_eq "null" "$(field "$L" detail)" "AC2 no detail= gives a null detail"
assert_eq "null" "$(field "$L" pr)" "AC2 no pr= gives a null pr"
assert_eq "iterations-exhausted" "$(field "$L" reason)" "AC2 reason"
assert_eq "stop reason=iterations-exhausted max=2" "$(field "$L" line)" "AC2 line is the stop line as printed"
bash "$HOOKS" run_end 'stop verdict=block reason=spec-unusable detail=id-collision' 2>/dev/null
L="$(tail -n 1 "$LOG" 2>/dev/null)"
assert_eq "id-collision" "$(field "$L" detail)" "AC2 detail=id-collision lands in detail"
bash "$HOOKS" run_end 'stop reason=x' --issue 9 2>/dev/null
L="$(tail -n 1 "$LOG" 2>/dev/null)"
assert_eq "9" "$(field "$L" issue)" "AC2 no issue= in the line: the run's --issue target"
bash "$HOOKS" run_end 'stop reason=x issue=4' --issue 9 2>/dev/null
L="$(tail -n 1 "$LOG" 2>/dev/null)"
assert_eq "4" "$(field "$L" issue)" "AC2 the stop line's issue= wins over the run's --issue"

# ── AC3 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
bash "$HOOKS" run_end 'stop verdict=block reason=qa-fail role=qa issue=5 pr=7' 2>/dev/null
LIST="$(bash "$EVENTS" list --event run_end 2>&1)"
assert_contains "$LIST" "run_end" "AC3 list --event run_end prints the event"
assert_contains "$LIST" "orchestrator" "AC3 the listed row is the orchestrator's"

# ── AC4 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
printf '%s' '{"events": {"enabled": false}}' > "$PIPELINE_CONFIG"
bash "$HOOKS" run_end 'stop reason=x' 2>/dev/null; RC=$?
assert_eq "0" "$RC" "AC4 events.enabled false: exit 0"
assert_file_absent "$LOG" "AC4 events.enabled false: no file written"
: > "$SANDBOX/afile"
printf '{"events": {"path": "%s/afile/x/events.jsonl"}}' "$SANDBOX" > "$PIPELINE_CONFIG"
bash "$HOOKS" run_end 'stop reason=x' >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "AC4 an unwritable events.path: exit 0"
assert_eq "1" "$(wc -l < "$SANDBOX/err" | tr -d ' ')" "AC4 an unwritable events.path: one stderr note"
printf '%s' '{"events": {"path": "../../escaped.jsonl"}}' > "$PIPELINE_CONFIG"
bash "$HOOKS" run_end 'stop reason=x' >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "AC4 an escaping relative events.path: exit 0"
assert_contains "$(cat "$SANDBOX/err")" "leaves the git common dir" "AC4 an escaping relative events.path is refused with a note"
assert_file_absent "$SANDBOX/../escaped.jsonl" "AC4 nothing is written outside the common dir"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"

# ── AC5, AC6: a run, and a run that continues ───────────────────────────────
# The real talos.sh in a copy of the scripts dir, with the stage machinery
# swapped for a one-pass `run`: it emits the stop line the loop would and exits
# through the real exit hooks; CONTINUE=1 goes through the real
# _talos_run_continue, whose exec lands on this same file for the final image.
DS="$SANDBOX/ds"
mkdir -p "$DS"
cp "$TALOS_ROOT"/scripts/* "$DS/" 2>/dev/null
python3 -I - "$DS/talos.sh" <<'TALOS_runendpatchK7vQx2Zm'
import re, sys
p = sys.argv[1]
src = open(p).read()
driver = '''
_talos_test_run() {
  local _max=2
  [ "${1:-}" != "--issue" ] || { _TALOS_RUN_ISSUE="$2"; shift 2; }
  _talos_prepare run pipeline-config.sh pipeline-cfg-cache.sh pipeline-hooks.sh
  _TALOS_EXIT_HOOKS=("_talos_run_end_hook" ${_TALOS_EXIT_HOOKS[@]+"${_TALOS_EXIT_HOOKS[@]}"})
  case "${TALOS_RUN_PASSES:-}" in
    "$$:"*) _talos_emit stop "reason=iterations-exhausted max=$_max"; _talos_flush; exit 0 ;;
  esac
  if [ -n "${CONTINUE:-}" ]; then _talos_run_continue 3 1; fi
  _talos_emit stop "reason=iterations-exhausted max=$_max"
  _talos_flush
  exit 0
}
'''
src = src.replace('\nverb="${1:-}"\n', driver + '\nverb="${1:-}"\n', 1)
src, n = re.subn(r'^  run\) _talos_run_loop "\$@" ;;$', '  run) _talos_test_run "$@" ;;', src, flags=re.M)
assert n == 1
open(p, "w").write(src)
TALOS_runendpatchK7vQx2Zm

rm -f "$LOG"
OUT="$(bash "$DS/talos.sh" run --issue 9 --max-iterations 2 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC5 the run exits as before"
assert_eq "stop reason=iterations-exhausted max=2" "$OUT" "AC5 the run's stdout is unchanged"
assert_eq "1" "$(run_ends)" "AC5 exactly one run_end event"
L="$(grep '"event": "run_end"' "$LOG" 2>/dev/null | tail -n 1)"
assert_eq "iterations-exhausted" "$(field "$L" reason)" "AC5 reason matches the printed stop line"
assert_eq "9" "$(field "$L" issue)" "AC5 issue is the run's --issue target"
assert_eq "acme/widget" "$(field "$L" repo)" "AC5 repo"

rm -f "$LOG"
OUT="$(CONTINUE=1 bash "$DS/talos.sh" run --max-iterations 3 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC6 the continued run exits 0"
assert_eq "1" "$(run_ends)" "AC6 only the final image of a continued run writes a run_end"
L="$(grep '"event": "run_end"' "$LOG" 2>/dev/null | tail -n 1)"
assert_eq "iterations-exhausted" "$(field "$L" reason)" "AC6 the event is the final image's"

# ── AC7: the map ────────────────────────────────────────────────────────────
STATE="$SANDBOX/.git/talos"
MAP="$HOME/.talos/maps/acme-widget.html"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$LOG"
python3 -I -c '
import json, sys
print(json.dumps({"event": "developer", "role": "developer", "issue": 12, "pr": 22, "verdict": "BLOCKED",
                  "tokens": 100, "summary": "BLOCKED: spec: no criteria", "ts": sys.argv[1]}))' "$NOW" >> "$LOG"
card() {  # <issue>: the state class of the issue's card
  python3 -I -c '
import re, sys
m = re.search(r"<article class=\"card ([a-z]+)\"><h3><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>(.*?)</article>" % (sys.argv[2], sys.argv[2]), open(sys.argv[1]).read(), re.S)
print(m.group(1) if m else "<none>")' "$MAP" "$1"
}
# The event is written by hand: this is the map's reading of the log, whatever wrote it.
python3 -I -c '
import json, sys
print(json.dumps({"event": "run_end", "role": "orchestrator", "stage": "developer", "issue": 12, "pr": 22,
                  "verdict": None, "reason": "stage-blocked", "detail": None, "ts": sys.argv[1]}))' "$NOW" >> "$LOG"
bash "$TALOS_ROOT/scripts/talos.sh" map >/dev/null 2>"$SANDBOX/err"
assert_eq "stuck" "$(card 12)" "AC7 a run_end after a BLOCKED developer event leaves the issue Stuck"

# ── AC8: no cost view counts it ─────────────────────────────────────────────
rm -f "$LOG"
printf '{"event":"developer","role":"developer","issue":5,"pr":7,"verdict":"PR_OPENED","tokens":1000,"tool_uses":3,"duration_s":9,"ts":"2026-10-01T00:00:00Z"}\n' > "$LOG"
C_JSON="$(bash "$EVENTS" cost --json 2>&1)"
C_LINE="$(bash "$EVENTS" cost --issue 5 --line 2>&1)"
S_LINE="$(bash "$STATUS" --line 2>&1 </dev/null)"
bash "$HOOKS" run_end 'stop verdict=block reason=qa-fail role=qa issue=5 pr=7' 2>/dev/null
assert_eq "2" "$(lines)" "AC8 the run_end is in the log"
assert_eq "$C_JSON" "$(bash "$EVENTS" cost --json 2>&1)" "AC8 cost --json is unchanged by a run_end"
assert_eq "$C_LINE" "$(bash "$EVENTS" cost --issue 5 --line 2>&1)" "AC8 cost --line is unchanged by a run_end"
assert_eq "$S_LINE" "$(bash "$STATUS" --line 2>&1 </dev/null)" "AC8 talos-status.sh --line is unchanged by a run_end"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-run-end-event: %d passed\n' "$_PASS"
