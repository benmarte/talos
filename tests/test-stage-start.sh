#!/usr/bin/env bash
# test-stage-start.sh -- covers #550: the `stage_start` event that makes the
# harness status line show a running stage.
#   (a) pipeline-hooks.sh stage_start <role> <issue> [--pr N]: one event line in
#       the events log (role orchestrator, so no cost/spend report counts it),
#       never the hooks.post_stage command, nothing when events.enabled is false
#   (b) talos.sh prompt <role> ...: the one dispatch point (the playbook and
#       `talos.sh run` both render the stage prompt there) writes it
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
TALOS="$TALOS_ROOT/scripts/talos.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"

# field FILE-LINE KEY: one key from a JSON line (python3 -I).
field() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2], "<absent>"); print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"; }
lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

# ── (a) the writer ──────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(bash "$HOOKS" stage_start developer 5 --pr 7 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "stage_start exits 0"
assert_eq "" "$OUT" "stage_start prints nothing on stdout"
assert_eq "1" "$(lines)" "one line appended"
L="$(tail -n 1 "$LOG")"
assert_eq "stage_start" "$(field "$L" event)" "event is stage_start"
assert_eq "orchestrator" "$(field "$L" role)" "role is orchestrator (never a stage row in cost reports)"
assert_eq "developer" "$(field "$L" stage)" "the dispatched stage is recorded"
assert_eq "5" "$(field "$L" issue)" "issue"
assert_eq "7" "$(field "$L" pr)" "pr"
case "$(field "$L" ts)" in 20[0-9][0-9]-*T*Z) pass "ts is a UTC ISO-8601 stamp" ;; *) fail "ts is a UTC ISO-8601 stamp" "$L" ;; esac

bash "$HOOKS" stage_start validator 5 2>/dev/null
L="$(tail -n 1 "$LOG")"
assert_eq "null" "$(field "$L" pr)" "no --pr: pr is null"

# Never the hooks.post_stage command: that one is for finished stages.
printf '%s' "{\"hooks\": {\"post_stage\": \"touch $SANDBOX/hook-ran\"}}" > "$SANDBOX/talos.pipeline.json"
bash "$HOOKS" stage_start qa 5 --pr 7 2>/dev/null
assert_file_absent "$SANDBOX/hook-ran" "hooks.post_stage is not run for stage_start"
assert_eq "3" "$(lines)" "the event is still logged with a hook configured"

printf '%s' '{"events": {"enabled": false}}' > "$SANDBOX/talos.pipeline.json"
bash "$HOOKS" stage_start qa 5 2>/dev/null; RC=$?
assert_eq "0" "$RC" "events.enabled false: still exit 0"
assert_eq "3" "$(lines)" "events.enabled false: nothing appended"
rm -f "$SANDBOX/talos.pipeline.json"

bash "$HOOKS" stage_start developer abc >/dev/null 2>&1; RC=$?
assert_eq "2" "$RC" "a non-numeric issue is a usage error"
bash "$HOOKS" stage_start >/dev/null 2>&1; RC=$?
assert_eq "2" "$RC" "no arguments is a usage error"
bash "$HOOKS" stage_start 'dev;rm' 5 >/dev/null 2>&1; RC=$?
assert_eq "2" "$RC" "a role that is not [a-z-] is a usage error"
assert_eq "3" "$(lines)" "usage errors append nothing"

# Reports ignore it: the cost figures do not change.
rm -f "$LOG"
printf '{"event":"developer","role":"developer","issue":5,"pr":7,"verdict":"PR_OPENED","tokens":1000,"tool_uses":3,"duration_s":9,"ts":"2026-10-01T00:00:00Z"}\n' > "$LOG"
BEFORE="$(bash "$EVENTS" cost --issue 5 --json)"
LINE_BEFORE="$(bash "$EVENTS" cost --issue 5 --line)"
bash "$HOOKS" stage_start developer 5 --pr 7 2>/dev/null
assert_eq "$BEFORE" "$(bash "$EVENTS" cost --issue 5 --json)" "cost --json is unchanged by a stage_start"
assert_eq "$LINE_BEFORE" "$(bash "$EVENTS" cost --issue 5 --line)" "cost --line is unchanged by a stage_start"

# ── (b) talos.sh prompt is the dispatch point ───────────────────────────────
rm -f "$LOG"
bash "$TALOS" prompt developer --issue 5 > "$SANDBOX/out" 2>"$SANDBOX/err"; RC=$?
PF="$(sed -n 's/^prompt_file=//p' "$SANDBOX/out")"; [ -z "$PF" ] || rm -f "${PF:?}"
assert_eq "0" "$RC" "prompt developer renders"
assert_eq "prompt_file=$PF" "$(cat "$SANDBOX/out")" "prompt's stdout is still only the prompt_file line"
assert_eq "" "$(cat "$SANDBOX/err")" "and its stderr stays empty"
assert_eq "1" "$(lines)" "prompt wrote one event"
L="$(tail -n 1 "$LOG")"
assert_eq "stage_start" "$(field "$L" event)" "prompt developer: stage_start"
assert_eq "developer" "$(field "$L" stage)" "prompt developer: stage developer"
assert_eq "5" "$(field "$L" issue)" "prompt developer: issue"

bash "$TALOS" prompt qa --issue 5 --pr 9 > "$SANDBOX/out" 2>/dev/null
PF="$(sed -n 's/^prompt_file=//p' "$SANDBOX/out")"; [ -z "$PF" ] || rm -f "${PF:?}"
L="$(tail -n 1 "$LOG")"
assert_eq "qa" "$(field "$L" stage)" "prompt qa: stage qa"
assert_eq "9" "$(field "$L" pr)" "prompt qa --pr 9: pr recorded"

N="$(lines)"
bash "$TALOS" prompt nonsense --issue 5 >/dev/null 2>&1; RC=$?
assert_eq "2" "$RC" "an unknown role is still a usage stop"
bash "$TALOS" prompt developer >/dev/null 2>&1
assert_eq "$N" "$(lines)" "a prompt that does not render writes no stage_start"

# A scripts dir without the hooks script still renders (an old partial install).
mkdir -p "$SANDBOX/t-nohooks"
cp -R "$TALOS_ROOT/scripts" "$SANDBOX/t-nohooks/scripts"
cp -R "$TALOS_ROOT/templates" "$SANDBOX/t-nohooks/templates"
rm -f "$SANDBOX/t-nohooks/scripts/pipeline-hooks.sh"
bash "$SANDBOX/t-nohooks/scripts/talos.sh" prompt developer --issue 5 > "$SANDBOX/out" 2>"$SANDBOX/err"; RC=$?
PF="$(sed -n 's/^prompt_file=//p' "$SANDBOX/out")"; [ -z "$PF" ] || rm -f "${PF:?}"
assert_eq "0" "$RC" "no pipeline-hooks.sh: prompt still renders"
assert_eq "" "$(cat "$SANDBOX/err")" "no pipeline-hooks.sh: silently"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-stage-start: %d passed\n' "$_PASS"
