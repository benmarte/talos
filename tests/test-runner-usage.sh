#!/usr/bin/env bash
# tests/test-runner-usage.sh -- token usage recorded on adapter-path stages
# (#420, part of epic #423): the claude JSON capture (agents.capture_usage),
# the custom-runner TALOS_USAGE_FILE sidecar, runner/model attribution, the
# per-attempt stage_attempt event, the talos:usage marker, and cost / budget /
# status-line agreement.
#
# Everything runs against the stub runners in tests/stubs/ and the fixtures in
# tests/fixtures/runner-usage/ (documented output shapes, not live captures --
# see the README there). No real model CLI, no real GitHub. The agent script
# runs from a copy of scripts/ whose pipeline-worktree.sh is a stub, so the
# failover checkpoint call never touches a real worktree.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
# Private TMPDIR: the leftover-directory check at the end must not see another
# test file's talos-usage.* directory (the runner executes files in parallel).
mkdir -p "$SANDBOX/tmp"
export TMPDIR="$SANDBOX/tmp"

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
printf '#!/usr/bin/env bash\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh"
AGENT="$INST/scripts/pipeline-agent.sh"
EVENTS_SH="$TALOS_ROOT/scripts/pipeline-events.sh"
BUDGET_SH="$TALOS_ROOT/scripts/pipeline-budget.sh"
STATUS_SH="$TALOS_ROOT/scripts/talos-status.sh"
FIX="$TALOS_ROOT/tests/fixtures/runner-usage"
export RUNNER_LOG="$SANDBOX/runner.log"
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
EVLOG="$SANDBOX/.talos/events.jsonl"
SC_PATHFILE="$SANDBOX/sidecar.path"
export SC_PATHFILE

reset() {
  rm -rf "${SANDBOX:?}/.talos" "${SANDBOX:?}/talos.pipeline.json"
  : > "$RUNNER_LOG"
  unset STUB_CLAUDE_EXIT STUB_CLAUDE_STDERR STUB_CLAUDE_STDOUT STUB_CLAUDE_HOOK \
        STUB_CLAUDE_JSON_FILE STUB_CLAUDE_TEXT_FILE \
        STUB_CODEX_EXIT STUB_CODEX_STDERR STUB_CODEX_STDOUT STUB_CODEX_HOOK \
        SC_BODY SC_ABSENT SC_EXIT TALOS_ISSUE TALOS_USAGE_FILE
}
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# stage [role] -- stdout in $OUT, stderr in $ERR, exit code in $RC (issue 7).
stage() { TALOS_ISSUE=7 bash "$AGENT" "${1:-developer}" "the task text" >"$OUT" 2>"$ERR"; RC=$?; }
# event_field <event> <field> -> JSON of the field of the LAST such event
# (null when the field is null), <none> when there is no such event.
event_field() {
  python3 -I - "$EVLOG" "$1" "$2" <<'PYEOF'
import json, sys
found, val = False, None
try:
    lines = open(sys.argv[1]).read().splitlines()
except OSError:
    lines = []
for line in lines:
    e = json.loads(line)
    if e.get("event") == sys.argv[2]:
        found, val = True, e.get(sys.argv[3])
print(json.dumps(val) if found else "<none>")
PYEOF
}
event_count() { grep -c "\"event\": \"$1\"" "$EVLOG" 2>/dev/null || true; }
claude_argv() { grep '^CLAUDE ARGS' "$RUNNER_LOG" | head -1; }
errtxt() { cat "$ERR"; }

# ═══ 1. claude: JSON capture, tokens, byte-identical stdout ═════════════════
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "0" "$RC" "claude: exit code is the runner's (0)"
assert_contains "$(claude_argv)" "[--setting-sources] [project] [--output-format] [json] [" "claude: --output-format json is added before the prompt"
# the same stub in TEXT mode (no capture) is the reference for the stdout bytes
set_cfg '{"agents": {"capture_usage": false}}'
TALOS_ISSUE=7 bash "$AGENT" developer "the task text" >"$SANDBOX/text-mode.out" 2>/dev/null
rm -f talos.pipeline.json
rm -rf "${SANDBOX:?}/.talos"
stage
if cmp -s "$OUT" "$SANDBOX/text-mode.out" && cmp -s "$OUT" "$FIX/claude-ok.txt"; then
  pass "claude: stdout with the JSON capture is byte-identical to the text-mode stdout"
else
  fail "claude: stdout with the JSON capture is byte-identical to the text-mode stdout" "$(od -c "$OUT" | head -3)"
fi
assert_eq "2722" "$(event_field stage_complete tokens)" "claude: tokens = input + output + cache creation (cache reads excluded)"
assert_eq '"claude"' "$(event_field stage_complete runner)" "claude: the event names the runner"
assert_eq '"claude-sonnet-4-5"' "$(event_field stage_complete model)" "claude: with no configured model the reported model is named"
assert_contains "$(errtxt)" "talos:usage runner=claude tokens=2722" "claude: the talos:usage marker names the tokens"
assert_eq "1" "$(event_count stage_complete)" "claude: exactly one stage_complete"

# the model: the config-resolved one for the primary runner
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
set_cfg '{"agents": {"model": "sonnet"}}'
stage
assert_eq '"sonnet"' "$(event_field stage_complete model)" "claude: the primary runner names its config-resolved model"
set_cfg '{"agents": {"model": "sonnet", "roles": {"developer": {"model": "opus"}}}}'
rm -rf "${SANDBOX:?}/.talos"
stage
assert_eq '"opus"' "$(event_field stage_complete model)" "claude: a role model wins over agents.model"

# subagents (modelUsage over several models) are summed; the busiest model is named
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-subagent.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "3162" "$(event_field stage_complete tokens)" "claude: modelUsage is summed across models (subagents included)"
assert_eq '"claude-sonnet-4-5"' "$(event_field stage_complete model)" "claude: with no configured model the busiest reported model is named"

# no modelUsage: the top-level usage object
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-usage-only.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "2722" "$(event_field stage_complete tokens)" "claude: no modelUsage falls back to the top-level usage"
cmp -s "$OUT" "$FIX/claude-ok.txt" && pass "claude: usage-only fixture prints the message text only" \
  || fail "claude: usage-only fixture prints the message text only" "$(cat "$OUT")"

# ═══ 2. claude: nothing usable -> null, raw stdout, runner's exit code ══════
unusable() {  # <label> <stdout-file> <exit>
  reset
  export STUB_CLAUDE_JSON_FILE="$2"
  export STUB_CLAUDE_EXIT="$3"
  stage
  assert_eq "$3" "$RC" "unusable ($1): exit code is the runner's"
  assert_eq "null" "$(event_field stage_complete tokens)" "unusable ($1): tokens is null, never 0"
  assert_contains "$(errtxt)" "talos:usage runner=claude tokens=null" "unusable ($1): marker says null"
  if [ -n "${4:-}" ]; then
    # a result object whose usage is unusable: its message text is still the stdout
    assert_eq "$4" "$(cat "$OUT")" "unusable ($1): the extracted message text is printed"
  elif cmp -s "$OUT" "$2"; then pass "unusable ($1): the runner's raw stdout is printed"
  else fail "unusable ($1): the runner's raw stdout is printed" "$(head -c 200 "$OUT")"; fi
}
BAD="$SANDBOX/bad"
mkdir -p "$BAD"
printf 'plain text, not json\n' > "$BAD/text.out"
printf '{"type":"result","result":"half' > "$BAD/trunc.out"
: > "$BAD/empty.out"
printf '{"type":"result","is_error":false,"result":"done"}\n' > "$BAD/nousage.out"
printf '{"type":"result","result":"done","usage":{"input_tokens":-3,"output_tokens":5}}\n' > "$BAD/negative.out"
printf '{"type":"result","result":"done","usage":{"input_tokens":1.5,"output_tokens":5}}\n' > "$BAD/float.out"
printf '{"type":"result","result":"done","usage":{"input_tokens":true,"output_tokens":5}}\n' > "$BAD/bool.out"
printf '{"type":"result","result":"done","usage":{"input_tokens":"12","output_tokens":5}}\n' > "$BAD/string.out"
printf '{"type":"result","result":"done","usage":{"input_tokens":1000000000000000,"output_tokens":5}}\n' > "$BAD/overcap.out"
printf '{"type":"result","result":"done","modelUsage":{"m":{"inputTokens":4,"outputTokens":null}},"usage":{"input_tokens":4,"output_tokens":5}}\n' > "$BAD/badmodelusage.out"
printf '{"type":"result","usage":{"input_tokens":4,"output_tokens":5}}\n' > "$BAD/noresult.out"
printf '["not","an","object"]\n' > "$BAD/array.out"
unusable "plain text" "$BAD/text.out" 0
unusable "truncated JSON" "$BAD/trunc.out" 0
unusable "empty stdout" "$BAD/empty.out" 0
unusable "no usage field" "$BAD/nousage.out" 0 "done"
unusable "negative count" "$BAD/negative.out" 0 "done"
unusable "float count" "$BAD/float.out" 0 "done"
unusable "boolean count" "$BAD/bool.out" 0 "done"
unusable "string count" "$BAD/string.out" 0 "done"
unusable "16-digit count" "$BAD/overcap.out" 0 "done"
unusable "bad modelUsage entry" "$BAD/badmodelusage.out" 0 "done"
unusable "no result string" "$BAD/noresult.out" 0
unusable "array of strings" "$BAD/array.out" 0
unusable "plain text, runner exit 3" "$BAD/text.out" 3
# a parsed run keeps a non-zero exit code too, with its usage
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_EXIT=4
stage
assert_eq "4" "$RC" "claude: a failing runner with usable JSON keeps its exit code"
assert_eq "2722" "$(event_field stage_complete tokens)" "claude: a failed run that reported usage still records it"
assert_eq '"FAIL"' "$(event_field stage_complete verdict)" "claude: a failing run records FAIL"
# missing usage in a result that has text: the text is still extracted
reset
export STUB_CLAUDE_JSON_FILE="$BAD/nousage.out"
stage
assert_eq "done" "$(cat "$OUT")" "no usage field: the stage message is still the extracted text"
assert_eq "0" "$(grep -c 'needs a value' "$ERR")" "no usage: no value-less flag reaches post_stage"

# ═══ 3. capture is opt-out ═════════════════════════════════════════════════
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
set_cfg '{"agents": {"capture_usage": false}}'
stage
case "$(claude_argv)" in *"--output-format"*) fail "capture_usage false: no capture flag" "$(claude_argv)" ;; *) pass "capture_usage false: no capture flag" ;; esac
assert_eq "null" "$(event_field stage_complete tokens)" "capture_usage false: tokens stay null"
cmp -s "$OUT" "$FIX/claude-ok.txt" && pass "capture_usage false: stdout is the runner's text" || fail "capture_usage false: stdout is the runner's text" "$(cat "$OUT")"
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
set_cfg '{"agents": {"runner_args": ["--output-format", "text"]}}'
stage
assert_eq "1" "$(claude_argv | grep -o '\[--output-format\]' | wc -l | tr -d ' ')" "runner_args --output-format: the capture flag is not added again"
assert_eq "null" "$(event_field stage_complete tokens)" "runner_args --output-format: tokens stay null"
set_cfg '{"agents": {"runner_args": ["--output-format=text"]}}'
: > "$RUNNER_LOG"; stage
assert_eq "0" "$(claude_argv | grep -c -- '\[json\]')" "runner_args --output-format=text: no capture flag either"
# a value other than the literal false leaves capture on
set_cfg '{"agents": {"capture_usage": true}}'
rm -rf "${SANDBOX:?}/.talos"; stage
assert_eq "2722" "$(event_field stage_complete tokens)" "capture_usage true: tokens recorded"

# ═══ 4. attribution: the runner that ran, role-routed or fallback ═══════════
reset
set_cfg '{"agents": {"runner": "claude", "model": "sonnet", "roles": {"qa": {"runner": "codex"}}}}'
stage qa
assert_eq "codex-stub-ok" "$(cat "$OUT")" "role-routed: the codex stub ran"
assert_eq '"codex"' "$(event_field stage_complete runner)" "role-routed: the event names codex, not the global runner"
assert_eq "null" "$(event_field stage_complete tokens)" "role-routed: codex exposes no usage -> null"
assert_contains "$(errtxt)" "talos:usage runner=codex tokens=null" "role-routed: marker names codex"
assert_eq '"sonnet"' "$(event_field stage_complete model)" "role-routed: the config-resolved model is kept (post_stage skips its fallback when --runner is given)"
# a role not routed elsewhere still names the global runner
rm -rf "${SANDBOX:?}/.talos"
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json"
stage developer
assert_eq '"claude"' "$(event_field stage_complete runner)" "an unrouted role names the global runner"

# ═══ 5. failover: JSON-mode 429 still fails over; one event per attempt ═════
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-429.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-429.txt" STUB_CLAUDE_EXIT=1
set_cfg '{"agents": {"fallback": ["codex"]}}'
stage
assert_eq "0" "$RC" "failover: the fallback runner's exit code is returned"
assert_eq "codex-stub-ok" "$(cat "$OUT")" "failover: a JSON-mode claude 429 is classified provider and fails over"
assert_contains "$(errtxt)" "talos:failover role=developer from=claude to=codex reason=provider:429" "failover: reason is provider:429"
assert_contains "$(errtxt)" "talos:usage runner=claude tokens=5" "failover: the failed attempt's marker carries its usage"
assert_contains "$(errtxt)" "talos:usage runner=codex tokens=null" "failover: the final attempt's marker"
assert_eq "1" "$(event_count stage_attempt)" "failover: the failed attempt that reported usage gets one stage_attempt"
assert_eq "5" "$(event_field stage_attempt tokens)" "failover: the stage_attempt carries the failed attempt's tokens"
assert_eq '"claude"' "$(event_field stage_attempt runner)" "failover: the stage_attempt names the failed runner"
assert_eq '"FAIL"' "$(event_field stage_attempt verdict)" "failover: the stage_attempt verdict is FAIL"
assert_eq '"developer"' "$(event_field stage_attempt role)" "failover: the stage_attempt is under the stage role"
assert_eq '"codex"' "$(event_field stage_complete runner)" "failover: the stage_complete names the fallback runner"
assert_eq "null" "$(event_field stage_complete tokens)" "failover: the fallback's tokens are null (codex exposes none)"
assert_eq "null" "$(event_field stage_complete model)" "failover: a fallback runner's model is null"
assert_eq "1" "$(event_count stage_complete)" "failover: exactly one stage_complete"
# the same 429 as TEXT classifies the same way (the extracted text equals text mode)
reset
export STUB_CLAUDE_EXIT=1 STUB_CLAUDE_STDERR='' STUB_CLAUDE_TEXT_FILE="$FIX/claude-429.txt"
set_cfg '{"agents": {"fallback": ["codex"], "capture_usage": false}}'
stage
assert_contains "$(errtxt)" "reason=provider:429" "failover: text mode classifies the same 429"
assert_eq "0" "$(event_count stage_attempt)" "failover: no usage captured -> no stage_attempt event"
# a failed attempt with unusable output: no stage_attempt, still fails over by exit 75
reset
export STUB_CLAUDE_EXIT=75 STUB_CLAUDE_JSON_FILE="$BAD/text.out"
set_cfg '{"agents": {"fallback": ["codex"]}}'
stage
assert_eq "0" "$(event_count stage_attempt)" "failover: a failed attempt without usage adds no event"
assert_eq "1" "$(event_count stage_complete)" "failover: still one stage_complete"

# ═══ 6. custom runner: the TALOS_USAGE_FILE sidecar ═════════════════════════
WRAP="$SANDBOX/sidecar-runner.sh"
cat > "$WRAP" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' "${TALOS_USAGE_FILE:-}" > "$SC_PATHFILE"
if [ -n "${TALOS_USAGE_FILE:-}" ] && [ -z "${SC_ABSENT:-}" ]; then
  printf '%s' "${SC_BODY:-}" > "$TALOS_USAGE_FILE"
fi
echo "custom-ok"
exit "${SC_EXIT:-0}"
EOF
set_custom() { set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sh $WRAP\"}}"; }
sidecar() {  # <label> <body> <expected tokens JSON>
  reset; set_custom
  SC_BODY="$2" stage
  assert_eq "$3" "$(event_field stage_complete tokens)" "sidecar ($1): tokens"
  assert_eq "0" "$RC" "sidecar ($1): exit code is the runner's"
  assert_eq "custom-ok" "$(cat "$OUT")" "sidecar ($1): stdout untouched"
}
sidecar "valid" '{"tokens": 1234, "tool_uses": 7, "model": "qwen2.5-coder"}' 1234
assert_eq "7" "$(event_field stage_complete tool_uses)" "sidecar (valid): tool_uses recorded"
assert_eq '"qwen2.5-coder"' "$(event_field stage_complete model)" "sidecar (valid): model recorded"
assert_eq '"custom"' "$(event_field stage_complete runner)" "sidecar (valid): the event names the custom runner"
assert_contains "$(errtxt)" "talos:usage runner=custom tokens=1234" "sidecar (valid): marker"
sidecar "explicit zero" '{"tokens": 0}' 0
sidecar "tokens only" '{"tokens": 55}' 55
assert_eq "null" "$(event_field stage_complete tool_uses)" "sidecar (tokens only): tool_uses is null"
sidecar "empty object" '{}' null
sidecar "empty file" '' null
sidecar "invalid JSON" '{tokens: 3' null
sidecar "negative" '{"tokens": -5}' null
sidecar "float" '{"tokens": 1.5}' null
sidecar "string" '{"tokens": "12"}' null
sidecar "boolean" '{"tokens": true}' null
sidecar "null value" '{"tokens": null}' null
sidecar "16 digits" '{"tokens": 1000000000000000}' null
sidecar "15 digits" '{"tokens": 999999999999999}' 999999999999999
sidecar "array" '[1, 2]' null
sidecar "bad model charset" '{"tokens": 9, "model": "a b;c"}' 9
assert_eq "null" "$(event_field stage_complete model)" "sidecar (bad model): an invalid model reads as null"
sidecar "bad tool_uses" '{"tokens": 9, "tool_uses": -1}' 9
assert_eq "null" "$(event_field stage_complete tool_uses)" "sidecar (bad tool_uses): negative reads as null"
reset; set_custom; SC_ABSENT=1 stage
assert_eq "null" "$(event_field stage_complete tokens)" "sidecar (absent file): tokens null"
assert_eq "0" "$RC" "sidecar (absent file): exit 0"
# a local model with no cost still records its tokens: nothing in the contract mentions price
reset; set_custom
SC_BODY='{"tokens": 777, "model": "llama-3.1-8b-q4"}' stage
assert_eq "777" "$(event_field stage_complete tokens)" "local runner stub with zero cost records its tokens"
# the sidecar directory is private to the attempt and removed afterwards
reset; set_custom
SC_BODY='{"tokens": 5}' stage
SIDE="$(cat "$SC_PATHFILE")"
case "$SIDE" in /*/usage.json) pass "sidecar: TALOS_USAGE_FILE is an absolute path to usage.json" ;; *) fail "sidecar: TALOS_USAGE_FILE is an absolute path to usage.json" "$SIDE" ;; esac
[ -e "$(dirname "$SIDE")" ] && fail "sidecar: its directory is removed after the stage" "$SIDE" || pass "sidecar: its directory is removed after the stage"
# ...also when the runner fails
reset; set_custom
SC_BODY='{"tokens": 6}' SC_EXIT=9 stage
assert_eq "9" "$RC" "sidecar (failing runner): exit code is the runner's"
assert_eq "6" "$(event_field stage_complete tokens)" "sidecar (failing runner): usage still recorded"
SIDE="$(cat "$SC_PATHFILE")"
[ -e "$(dirname "$SIDE")" ] && fail "sidecar (failing runner): its directory is removed" "$SIDE" || pass "sidecar (failing runner): its directory is removed"
# an inherited TALOS_USAGE_FILE never reaches the runner
reset; set_custom
TALOS_USAGE_FILE=/nonexistent/inherited SC_BODY='{"tokens": 8}' stage
assert_eq "8" "$(event_field stage_complete tokens)" "sidecar: an inherited TALOS_USAGE_FILE is replaced"
# stale file: a runner that writes nothing never inherits an earlier attempt's number
reset; set_custom
SC_BODY='{"tokens": 11}' stage
SC_ABSENT=1 stage
assert_eq "null" "$(event_field stage_complete tokens)" "sidecar: a second attempt with no file is null, not the earlier number"

# ═══ 7. custom -> claude failover: each attempt under its own runner ════════
reset
WRAP2="$SANDBOX/provider-down.sh"
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s" '"'"'{"tokens": 321}'"'"' > "$TALOS_USAGE_FILE"\nexit 75\n' > "$WRAP2"
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sh $WRAP2\", \"fallback\": [\"claude\"]}}"
export STUB_CLAUDE_JSON_FILE="$FIX/claude-subagent.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "0" "$RC" "custom->claude: the fallback's exit code is returned"
assert_eq "321" "$(event_field stage_attempt tokens)" "custom->claude: the failed custom attempt is recorded with its tokens"
assert_eq '"custom"' "$(event_field stage_attempt runner)" "custom->claude: ...under the custom runner"
assert_eq "3162" "$(event_field stage_complete tokens)" "custom->claude: the final attempt's tokens are on stage_complete"
assert_eq '"claude"' "$(event_field stage_complete runner)" "custom->claude: ...under claude"
assert_eq '"claude-sonnet-4-5"' "$(event_field stage_complete model)" "custom->claude: a fallback runner names the model its output reported"
cmp -s "$OUT" "$FIX/claude-ok.txt" && pass "custom->claude: stdout is the final attempt's text only" || fail "custom->claude: stdout is the final attempt's text only" "$(cat "$OUT")"

# ═══ 8. cost, budget and the status line agree ══════════════════════════════
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
set_cfg '{"limits": {"tokens_per_issue": 10000}}'
# before: a null-token adapter run counts as unrecorded
STUB_CLAUDE_JSON_FILE="$BAD/text.out" stage qa
BEFORE="$(bash "$EVENTS_SH" cost --issue 7 --json 2>/dev/null)"
assert_eq "1" "$(printf '%s' "$BEFORE" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["total"]["unrecorded"])')" "cost: an unparseable adapter run is unrecorded"
BUD_BEFORE="$(bash "$BUDGET_SH" check --issue 7 2>/dev/null)"
assert_contains "$BUD_BEFORE" "used=0 " "budget: nothing used before"
stage developer
AFTER="$(bash "$EVENTS_SH" cost --issue 7 --json 2>/dev/null)"
assert_eq "1" "$(printf '%s' "$AFTER" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["total"]["unrecorded"])')" "cost: the recorded run adds no unrecorded row"
assert_eq "2722" "$(printf '%s' "$AFTER" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["total"]["tokens"])')" "cost: the recorded tokens are counted"
BUD_AFTER="$(bash "$BUDGET_SH" check --issue 7 2>/dev/null)"
assert_contains "$BUD_AFTER" "used=2722 " "budget: used goes up by the recorded tokens"
assert_contains "$BUD_AFTER" "unrecorded=1" "budget: the unparseable run is still the only unrecorded one"
COST_LINE="$(bash "$EVENTS_SH" cost --issue 7 --line 2>/dev/null)"
STATUS_LINE="$(cd "$SANDBOX" && bash "$STATUS_SH" --line --format issue,issue_tokens 2>/dev/null)"
assert_contains "$COST_LINE" "issue total 3k (+1 unrecorded)" "cost --line shows the recorded tokens"
assert_contains "$STATUS_LINE" "3k (+1 unrecorded)" "talos-status --line agrees with cost --line"
# a stage_attempt event counts in cost
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_JSON_FILE="$FIX/claude-429.json" STUB_CLAUDE_EXIT=1 stage developer
CJ="$(bash "$EVENTS_SH" cost --issue 7 --json 2>/dev/null)"
assert_eq "5" "$(printf '%s' "$CJ" | python3 -I -c 'import json,sys; r=[x for x in json.load(sys.stdin)["rows"] if x["role"]=="developer"][0]; print(r["tokens"])')" "cost: a stage_attempt's tokens count under the stage role"
assert_eq "2" "$(printf '%s' "$CJ" | python3 -I -c 'import json,sys; r=[x for x in json.load(sys.stdin)["rows"] if x["role"]=="developer"][0]; print(r["events"])')" "cost: the events count includes the stage_attempt"

# ═══ 9. hygiene ════════════════════════════════════════════════════════════
if grep -n 'python3' "$TALOS_ROOT/scripts/pipeline-agent.sh" | grep -v 'python3 -I' | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
  fail "hygiene: every python3 call in pipeline-agent.sh is -I"
else
  pass "hygiene: every python3 call in pipeline-agent.sh is -I"
fi
LEFT="$(find "$TMPDIR" -maxdepth 1 -name 'talos-usage.*' 2>/dev/null | head -1)"
assert_eq "" "$LEFT" "hygiene: no talos-usage temp directory is left behind"

finish
