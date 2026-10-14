#!/usr/bin/env bash
# tests/test-claude-runner-model.sh -- the built-in claude runner passes the
# attempt's resolved model as `--model <m>` (#668). A stubbed claude binary
# records argv; the agent script runs from a copy of scripts/.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
mkdir -p "$SANDBOX/tmp"
export TMPDIR="$SANDBOX/tmp"

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
printf '#!/usr/bin/env bash\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh"
AGENT="$INST/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
FIX="$TALOS_ROOT/tests/fixtures/runner-usage"
EVLOG="$SANDBOX/.git/talos/events.jsonl"

# run <config-json> [role]: one stage; the claude child's argv lands in $ARGV.
run() {
  rm -rf "${SANDBOX:?}/.talos" "${SANDBOX:?}/.git/talos"
  : > "$RUNNER_LOG"
  printf '%s\n' "$1" > talos.pipeline.json
  TALOS_ISSUE=7 bash "$AGENT" "${2:-developer}" "the task text" >"$SANDBOX/out.txt" 2>"$SANDBOX/err.txt"
  ARGV="$(grep '^CLAUDE ARGS' "$RUNNER_LOG" | head -1)"
}
# count_model: how many --model / --model=<x> flags $ARGV carries.
count_model() { printf '%s\n' "$ARGV" | grep -o '\[--model[^]]*\]' | wc -l | tr -d ' '; }
event_model() {
  python3 -I - "$EVLOG" <<'PYEOF'
import json, sys
m = None
for l in open(sys.argv[1]).read().splitlines():
    e = json.loads(l)
    if e.get("event") == "stage_complete":
        m = e.get("model")
print(m)
PYEOF
}

for _mode in json plain; do
  if [ "$_mode" = json ]; then
    export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
    _cap=true
  else
    unset STUB_CLAUDE_JSON_FILE STUB_CLAUDE_TEXT_FILE
    _cap=false
  fi
  run '{"agents": {"capture_usage": '"$_cap"', "roles": {"developer": {"model": "opus"}}}}'
  assert_contains "$ARGV" "[--model] [opus]" "AC1 role model is passed ($_mode)"
  case "$ARGV" in
    *"[--model] [opus]"*"[--] ["*) pass "AC1 --model comes before -- ($_mode)" ;;
    *) fail "AC1 --model comes before -- ($_mode)" "$ARGV" ;;
  esac
  run '{"agents": {"capture_usage": '"$_cap"', "model": "sonnet"}}'
  assert_contains "$ARGV" "[--model] [sonnet]" "AC2 global model is passed ($_mode)"
done
run '{"agents": {"model": "sonnet", "roles": {"developer": {"model": "opus"}}}}'
assert_contains "$ARGV" "[--model] [opus]" "AC2 the role key wins over the global key"
assert_eq "1" "$(count_model)" "AC2 exactly one --model when both are set"

run '{"agents": {"model": "opus"}}'
assert_contains "$ARGV" "[--model] [opus]" "AC3 an alias is passed unchanged"
run '{"agents": {"model": "claude-opus-4-1"}}'
assert_contains "$ARGV" "[--model] [claude-opus-4-1]" "AC3 a full ID is passed unchanged"

run '{"agents": {"model": "sonnet", "runner_args": ["--model", "haiku"]}}'
assert_eq "1" "$(count_model)" "AC4 one --model with --model <x> in runner_args"
assert_contains "$ARGV" "[--model] [haiku]" "AC4 the user's --model wins"
assert_eq "haiku" "$(event_model)" "AC4 the stage event names the user's model"
run '{"agents": {"model": "sonnet", "runner_args": ["--model=haiku"]}}'
assert_eq "1" "$(count_model)" "AC4 one --model with --model=<x> in runner_args"
assert_contains "$ARGV" "[--model=haiku]" "AC4 the user's --model=<x> is kept"
assert_eq "haiku" "$(event_model)" "AC4 the stage event names the --model=<x> model"

# Guards (AC5, AC6): green on main, kept as regression tests.
run '{"agents": {}}'
assert_eq "0" "$(count_model)" "AC5 no model set means no --model"
run '{"agents": {"model": "bad model"}}'
assert_eq "0" "$(count_model)" "AC6 a model with a space is never passed"
run '{"agents": {"model": "bad\u0001m"}}'
assert_eq "0" "$(count_model)" "AC6 a model with a control character is never passed"

finish
