#!/usr/bin/env bash
# tests/test-api-credits.sh -- claude stages run on the plan's monthly API
# credits first and on the plan login second (#616): agents.claude_api_credits,
# the CLAUDE_API_CREDITS_KEY entry of the user-level .env, the one switch on an
# exhausted pool, the `pool` event key and the pool columns of `cost`.
#
#   AC1   credits on: claude starts with ANTHROPIC_API_KEY from the file
#   AC2   no hook, fallback runner or rerun sees the name or the value
#   AC3   only the user-level file is a source
#   AC4   an exhausted pool, nothing written: one rerun on the plan login
#   AC5   an exhausted pool after a write: no rerun, exit 69
#   AC6   any other failure: today's result, one start
#   AC7   a known bool key; off or no usable key equals the option-absent run
#   AC8   post_stage --pool, and the pool on the stage events
#   AC9   cost table and --json pool columns
#   AC10  the Pools line of cost --markdown and cost --summary
#   AC11  the key is in no output, log, argv or posted body
#
# Stub CLIs only (tests/stubs/), a sandbox HOME and TALOS_HOME. The key is
# assembled at run time and never handed to assert_eq / assert_contains, which
# print their arguments on failure: every check on it prints a fixed label.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

AGENT="$TALOS_ROOT/scripts/pipeline-agent.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CONFIG="$TALOS_ROOT/scripts/pipeline-config.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS_SH="$TALOS_ROOT/scripts/pipeline-events.sh"

# The sandbox repo encloses the sandbox HOME, and a user-level .env inside a git
# work tree is refused. Drop that repo and work from a project repo of its own,
# so HOME and TALOS_HOME are outside every work tree (as tests/test-secret-refs.sh).
rm -rf "${SANDBOX:?}/.git"
PROJ="$SANDBOX/proj"
TH="$SANDBOX/th"
mkdir -p "$PROJ" "$TH" "$HOME/.hermes" || exit 1
git -C "$PROJ" init -q
git -C "$PROJ" remote add origin git@github.com:acme/widget.git
cd "$PROJ" || exit 1
export TALOS_HOME="$TH"

# A real stage runs this suite with some of these set: none may answer for Talos.
unset ANTHROPIC_API_KEY CLAUDE_API_CREDITS_KEY CLAUDE_CODE_PROMPT_CACHE_TTL PIPELINE_CONFIG \
      TALOS_WRITE_LOG TALOS_STAGE_TIMEOUT_DIVISOR TALOS_PR TALOS_STAGE_DURATION_S

export RUNNER_LOG="$SANDBOX/runner.log"
OUT_F="$SANDBOX/stage.out"
ERR_F="$SANDBOX/stage.err"
EVENTS="$PROJ/.git/talos/events.jsonl"
PROV="$PROJ/.talos/providers.json"
PRE_ENV="$SANDBOX/pre.env"
POST_ENV="$SANDBOX/post.env"
export CODEX_ENV="$SANDBOX/codex.env"

# The key: fragments, so no secret-shaped literal is in this file.
KEYV="crk$RANDOM$RANDOM$RANDOM-$RANDOM"
OTHER_KEY="callerkey$RANDOM"
export CR_KEY_COPY="$SANDBOX/key.copy"
printf '%s' "$KEYV" > "$CR_KEY_COPY"

# Each claude start keeps its environment and prompt in $CR_ENVS/<n>.env|.prompt.
# CR_FAIL=keyed fails only the start that carries the key, CR_FAIL=always every
# start: CR_WRITE (a write first), CR_SLEEP, then CR_FAIL_JSON or CR_FAIL_TEXT on
# stdout and exit CR_FAIL_RC.
export CR_ENVS="$SANDBOX/claude-envs"
cat > "$SANDBOX/claude-hook.sh" <<'TALOS_HOOKq4Wn8Zt2Lx6B'
_cr_n=$(( $(ls "$CR_ENVS" | grep -c '\.env$') + 1 ))
env > "$CR_ENVS/$_cr_n.env"
printf '%s' "${@: -1}" > "$CR_ENVS/$_cr_n.prompt"
_cr_keyed=0
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ "$ANTHROPIC_API_KEY" = "$(cat "$CR_KEY_COPY")" ]; then _cr_keyed=1; fi
if [ "${CR_FAIL:-}" = "always" ] || { [ "${CR_FAIL:-}" = "keyed" ] && [ "$_cr_keyed" = 1 ]; }; then
  [ -z "${CR_WRITE:-}" ] || eval "$CR_WRITE"
  [ -z "${CR_SLEEP:-}" ] || sleep "$CR_SLEEP"
  if [ -n "${CR_FAIL_JSON:-}" ]; then cat "$CR_FAIL_JSON"; else printf '%s\n' "${CR_FAIL_TEXT:-}"; fi
  exit "${CR_FAIL_RC:-1}"
fi
TALOS_HOOKq4Wn8Zt2Lx6B
export STUB_CLAUDE_HOOK=". '$SANDBOX/claude-hook.sh'"
export STUB_CODEX_HOOK='env > "$CODEX_ENV"'
QUOTA="Credit balance is too low"

set_cfg() { printf '%s\n' "$1" > "$PROJ/talos.pipeline.json"; }
ON='{"agents": {"claude_api_credits": true}}'
# key_file <content> [mode] -- the user-level .env.
key_file() { printf '%s\n' "$1" > "$TH/.env"; chmod "${2:-600}" "$TH/.env"; }
good_key() { key_file "CLAUDE_API_CREDITS_KEY=$KEYV"; }
# fresh -- no state from an earlier case: no events, no down marks, no failure mode.
fresh() {
  rm -rf "${PROJ:?}/.talos" "${PROJ:?}/.git/talos"
  rm -f "$PRE_ENV" "$POST_ENV" "$CODEX_ENV" "${PROJ:?}/.env" "${HOME:?}/.hermes/.env"
  unset CR_FAIL CR_FAIL_TEXT CR_FAIL_JSON CR_FAIL_RC CR_WRITE CR_SLEEP \
        STUB_CLAUDE_EXIT STUB_CLAUDE_STDOUT STUB_CLAUDE_JSON_FILE STUB_CODEX_EXIT
  good_key
}
# stage [role] -- stdout in $OUT_F, stderr in $ERR_F, exit code in $RC.
stage() {
  rm -rf "${CR_ENVS:?}"; mkdir -p "$CR_ENVS"
  : > "$RUNNER_LOG"; : > "$GH_LOG"
  bash "$AGENT" "${1:-developer}" "the task text" > "$OUT_F" 2> "$ERR_F"; RC=$?
}
starts() { ls "$CR_ENVS" | grep -c '\.env$'; }
runner_calls() { grep -c "^$1 ARGS" "$RUNNER_LOG"; }
# key_state <n> -- what claude start <n> had as ANTHROPIC_API_KEY: file (the
# user-level file's value), other, unset, or not-started. Never the value.
key_state() {
  local _f="$CR_ENVS/$1.env"
  [ -f "$_f" ] || { printf 'not-started'; return; }
  if grep -qxF -- "ANTHROPIC_API_KEY=$KEYV" "$_f"; then printf 'file'
  elif grep -q '^ANTHROPIC_API_KEY=' "$_f"; then printf 'other'
  else printf 'unset'; fi
}
has_key() { [ -f "$1" ] && grep -qF -- "$KEYV" "$1"; }
has_name() { [ -f "$1" ] && grep -q 'CLAUDE_API_CREDITS_KEY' "$1"; }
check() { local _l="$1"; shift; if "$@"; then pass "$_l"; else fail "$_l"; fi; }
check_not() { local _l="$1"; shift; if "$@"; then fail "$_l"; else pass "$_l"; fi; }
# event_field <event> <field> -- of the last such event: the value, <null>, or
# <absent> when the event has no such key (<no-event> when there is none).
event_field() {
  python3 -I - "$EVENTS" "$1" "$2" <<'TALOS_PYev5Kd9Rm3Wq7'
import json, os, sys
path, name, field = sys.argv[1:4]
last = None
if os.path.isfile(path):
    for line in open(path):
        e = json.loads(line)
        if e.get("event") == name:
            last = e
if last is None:
    print("<no-event>")
elif field not in last:
    print("<absent>")
else:
    print("<null>" if last[field] is None else last[field])
TALOS_PYev5Kd9Rm3Wq7
}
event_count() { grep -c "\"event\": \"$1\"" "$EVENTS" 2>/dev/null || true; }
pool_keys() { grep -c '"pool"' "$EVENTS" 2>/dev/null || true; }
claude_down() { [ -f "$PROV" ] && grep -q '"claude"' "$PROV"; }
failover_lines() { grep -c '^talos:failover role=' "$ERR_F"; }
SWITCH="talos:failover role=developer from=claude:api to=claude:plan reason=provider:quota"

# ═══ AC1: credits on, claude starts with the file's key ══════════════════════
fresh
set_cfg '{}'
stage
PLAIN_ARGV="$(cat "$RUNNER_LOG")"
set_cfg "$ON"
stage
assert_eq "file" "$(key_state 1)" "AC1 credits on: claude starts with ANTHROPIC_API_KEY equal to the file's value (JSON capture arm)"
assert_contains "$(cat "$RUNNER_LOG")" "[--output-format] [json]" "AC1 that run took the --output-format json arm"
assert_eq "$PLAIN_ARGV" "$(cat "$RUNNER_LOG")" "AC1 the claude argv equals the option-absent argv"
check_not "AC1 the claude argv never holds the value" has_key "$RUNNER_LOG"
assert_eq "0" "$RC" "AC1 the stage exits 0"

set_cfg '{"agents": {"capture_usage": false}}'
stage
PLAIN_ARGV="$(cat "$RUNNER_LOG")"
set_cfg '{"agents": {"claude_api_credits": true, "capture_usage": false}}'
stage
assert_eq "file" "$(key_state 1)" "AC1 credits on: claude starts with the file's value (agents.capture_usage false arm)"
assert_not_contains "$(cat "$RUNNER_LOG")" "[--output-format]" "AC1 that run took the plain arm"
assert_eq "$PLAIN_ARGV" "$(cat "$RUNNER_LOG")" "AC1 the plain-arm argv equals the option-absent argv"
check_not "AC1 the plain-arm argv never holds the value" has_key "$RUNNER_LOG"

set_cfg "$ON"
ANTHROPIC_API_KEY="$OTHER_KEY" stage
assert_eq "file" "$(key_state 1)" "AC1 a caller-exported ANTHROPIC_API_KEY is replaced by the file's value for that child"

# ═══ AC2: no hook, fallback runner or rerun sees the name or the value ═══════
fresh
set_cfg "{\"agents\": {\"claude_api_credits\": true, \"fallback\": [\"codex\"]},
 \"hooks\": {\"pre_dispatch\": \"env > $PRE_ENV; echo ctx\", \"post_stage\": \"env >> $POST_ENV; cat > /dev/null\", \"timeout_s\": 5}}"
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_EXIT=75
stage
assert_eq "file" "$(key_state 1)" "AC2 the first claude start ran with the key"
assert_eq "unset" "$(key_state 2)" "AC2 the plan-login rerun has no ANTHROPIC_API_KEY"
assert_eq "1" "$(runner_calls CODEX)" "AC2 the later agents.fallback runner ran"
for pair in "pre_dispatch hook:$PRE_ENV" "post_stage hook:$POST_ENV" "fallback runner:$CODEX_ENV" "plan-login rerun:$CR_ENVS/2.env"; do
  what="${pair%%:*}"; f="${pair#*:}"
  assert_file_exists "$f" "AC2 the environment of the $what was recorded"
  check_not "AC2 the value is not in the environment of the $what" has_key "$f"
  check_not "AC2 CLAUDE_API_CREDITS_KEY is not in the environment of the $what" has_name "$f"
done
check_not "AC2 CLAUDE_API_CREDITS_KEY is not in the environment of the claude child either" has_name "$CR_ENVS/1.env"

# The same run when the caller exports the shell names the key passes through:
# an assignment to an inherited export stays exported.
fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_EXIT=75
_CR_KEY=inherited _TS_VAL=inherited _TS_V=inherited _TS_K=inherited stage
assert_eq "file unset 1" "$(key_state 1) $(key_state 2) $(runner_calls CODEX)" \
  "AC2 inherited exports: the switch and the fallback runner ran as before"
for pair in "post_stage hook:$POST_ENV" "fallback runner:$CODEX_ENV" "plan-login rerun:$CR_ENVS/2.env"; do
  what="${pair%%:*}"; f="${pair#*:}"
  assert_file_exists "$f" "AC2 inherited exports: the environment of the $what was recorded"
  check_not "AC2 inherited exports: the value is not in the environment of the $what" has_key "$f"
done

# ═══ AC3: only the user-level file is a source ══════════════════════════════
fresh
set_cfg "$ON"
stage
assert_eq "file" "$(key_state 1)" "AC3 control: the name in the user-level file is used"
assert_eq "api" "$(event_field stage_complete pool)" "AC3 control: that stage is recorded on the api pool"

fresh; rm -f "$TH/.env"
CLAUDE_API_CREDITS_KEY="$KEYV" stage
assert_eq "unset" "$(key_state 1)" "AC3 the name only in the exported environment is not used"
assert_eq "<absent>" "$(event_field stage_complete pool)" "AC3 exported environment only: the stage runs as credits off (no pool)"

fresh; rm -f "$TH/.env"
printf 'CLAUDE_API_CREDITS_KEY=%s\n' "$KEYV" > "$PROJ/.env"
stage
assert_eq "unset" "$(key_state 1)" "AC3 the name only in the repo .env is not used"
assert_eq "<absent>" "$(event_field stage_complete pool)" "AC3 repo .env only: the stage runs as credits off (no pool)"

fresh; rm -f "$TH/.env"
printf 'CLAUDE_API_CREDITS_KEY=%s\n' "$KEYV" > "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
stage
assert_eq "unset" "$(key_state 1)" "AC3 the name only in ~/.hermes/.env is not used"
assert_eq "<absent>" "$(event_field stage_complete pool)" "AC3 ~/.hermes/.env only: the stage runs as credits off (no pool)"
assert_eq "0" "$(grep -c 'pipeline-secrets' "$ERR_F")" "AC3 ~/.hermes/.env is not even read (no deprecation line)"

# ═══ AC4: an exhausted pool, nothing written: one rerun on the plan login ════
fresh
set_cfg "$ON"
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_STDOUT="plan-result"
stage
assert_eq "2" "$(starts)" "AC4 an exhausted pool with nothing written: claude starts twice"
assert_eq "file" "$(key_state 1)" "AC4 the first start ran with the key"
assert_eq "unset" "$(key_state 2)" "AC4 the rerun has ANTHROPIC_API_KEY unset"
if [ -f "$CR_ENVS/2.prompt" ] && cmp -s "$CR_ENVS/1.prompt" "$CR_ENVS/2.prompt"; then
  pass "AC4 the rerun gets the same prompt byte for byte"
else
  fail "AC4 the rerun gets the same prompt byte for byte"
fi
assert_eq "plan-result" "$(cat "$OUT_F")" "AC4 stage stdout is the rerun's only"
assert_eq "0" "$RC" "AC4 the exit code is the rerun's"
assert_eq "1" "$(failover_lines)" "AC4 stderr has exactly one talos:failover line"
assert_eq "1" "$(grep -cxF -- "$SWITCH" "$ERR_F")" "AC4 that line is $SWITCH"
assert_eq "1" "$(event_count failover)" "AC4 one failover event is recorded"
assert_eq "${SWITCH#talos:failover }" "$(event_field failover summary)" "AC4 the failover event carries that summary"
check_not "AC4 providers.json gains no claude entry" claude_down
assert_eq "0" "$(grep -c 'provider chain exhausted' "$ERR_F")" "AC4 works with no agents.fallback (no chain message)"

fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_STDOUT="plan-result"
ANTHROPIC_API_KEY="$OTHER_KEY" stage
assert_eq "file unset" "$(key_state 1) $(key_state 2)" "AC4 a caller-exported ANTHROPIC_API_KEY: the key first, then unset in the rerun"

fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_STDOUT="plan-failed" STUB_CLAUDE_EXIT=3
stage
assert_eq "2" "$(starts)" "AC4 a failed rerun: claude still starts at most twice"
assert_eq "3" "$RC" "AC4 a failed rerun: the exit code is the rerun's"
assert_eq "plan-failed" "$(cat "$OUT_F")" "AC4 a failed rerun: stdout is the rerun's"
check_not "AC4 a failed rerun with no chain leaves providers.json alone" claude_down

fresh
set_cfg '{"agents": {"claude_api_credits": true, "fallback": ["codex"]}}'
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" STUB_CLAUDE_EXIT=75
stage
assert_eq "2 1" "$(starts) $(runner_calls CODEX)" "AC4 with a chain: a rerun that dies on a provider error fails over like a claude attempt today"
assert_eq "0" "$RC" "AC4 with a chain: the fallback runner's exit code is used"
assert_eq "1" "$(grep -cxF -- "$SWITCH" "$ERR_F")" "AC4 with a chain: the switch line is printed once"
assert_contains "$(cat "$ERR_F")" "talos:failover role=developer from=claude to=codex reason=provider:exit75" "AC4 with a chain: the rerun's failover names the plain runner"
check "AC4 with a chain: the failed rerun marks claude down, as today" claude_down

# ═══ AC5: an exhausted pool after a write: no rerun, exit 69 ═════════════════
refused() {  # <label> <reason>
  assert_eq "69" "$RC" "AC5 $1: exit 69"
  assert_eq "1" "$(starts)" "AC5 $1: claude started once"
  assert_eq "file" "$(key_state 1)" "AC5 $1: that start ran with the key"
  assert_eq "1" "$(grep -cxF -- "talos:failover-refused role=developer runner=claude reason=$2" "$ERR_F")" \
    "AC5 $1: stderr has talos:failover-refused role=developer runner=claude reason=$2"
  assert_eq "0" "$(failover_lines)" "AC5 $1: no switch is announced"
  check_not "AC5 $1: no claude entry in providers.json" claude_down
}
fresh
set_cfg "$ON"
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" CR_WRITE="bash '$VCS' comment-issue 5 'progress note' >/dev/null"
stage
refused "a write verb in the journal" "wrote:comment-issue"

fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" CR_WRITE='rm -f "$TALOS_WRITE_LOG"'
stage
refused "a missing journal" "write-log-unreadable"

fresh
set_cfg '{"agents": {"claude_api_credits": true, "fallback": ["codex"]}}'
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" CR_WRITE="bash '$VCS' comment-issue 5 'progress note' >/dev/null"
stage
refused "a write, with a chain" "wrote:comment-issue"
assert_eq "0" "$(runner_calls CODEX)" "AC5 a write, with a chain: the fallback runner is not started"

fresh
set_cfg "$ON"
git init -q --bare "$SANDBOX/origin.git"
git remote set-url origin "$SANDBOX/origin.git"
git commit -q --allow-empty -m base
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" CR_WRITE="git commit -q --allow-empty -m work && git push -q origin HEAD:refs/heads/work"
stage
refused "a moved refs/remotes ref" "wrote:push"
git remote set-url origin git@github.com:acme/widget.git

# ═══ AC6: any other failure keeps today's result ═════════════════════════════
# other_failure <label> <option-absent agents JSON members> -- the failure mode
# is in the environment; runs it without the option, then with credits on.
other_failure() {
  local _l="$1" _base="$2" _rc _out _fo _codex
  rm -rf "${PROJ:?}/.talos" "${PROJ:?}/.git/talos"
  set_cfg "{\"agents\": {$_base}}"
  stage
  _rc="$RC"; _out="$(cat "$OUT_F")"; _codex="$(runner_calls CODEX)"
  _fo="$(grep '^talos:failover' "$ERR_F")"
  rm -rf "${PROJ:?}/.talos" "${PROJ:?}/.git/talos"
  set_cfg "{\"agents\": {\"claude_api_credits\": true${_base:+, $_base}}}"
  stage
  assert_eq "file" "$(key_state 1)" "AC6 $_l: the attempt ran with the key"
  assert_eq "1" "$(starts)" "AC6 $_l: claude started once, no rerun"
  assert_eq "$_rc" "$RC" "AC6 $_l: the exit code equals the option-absent one"
  assert_eq "$_out" "$(cat "$OUT_F")" "AC6 $_l: stdout equals the option-absent one"
  assert_eq "$_fo" "$(grep '^talos:failover' "$ERR_F")" "AC6 $_l: the failover lines equal the option-absent ones"
  assert_eq "$_codex" "$(runner_calls CODEX)" "AC6 $_l: the next chain entry runs exactly as without the option"
}
fresh
export CR_FAIL=always
for shape in "401:API Error: 401 authentication failed" "429:API Error: 429 rate limited" \
             "5xx:API Error: 529 overloaded" "network:API Error: request failed ECONNRESET" \
             "task failure:the tests did not pass"; do
  export CR_FAIL_TEXT="${shape#*:}"
  other_failure "${shape%%:*}" ""
done
export CR_FAIL_TEXT="API Error: 429 rate limited"
other_failure "429 with a chain" '"fallback": ["codex"]'
assert_eq "1" "$(runner_calls CODEX)" "AC6 429 with a chain: the fallback runner did run"
export CR_SLEEP=30 TALOS_STAGE_TIMEOUT_DIVISOR=60 CR_FAIL_TEXT="never printed"
other_failure "stage timeout" '"stage_timeout_s": 60'
assert_eq "124" "$RC" "AC6 stage timeout: the exit code is 124"
unset TALOS_STAGE_TIMEOUT_DIVISOR

# ═══ AC7: a known bool key; off or unusable equals the option-absent run ═════
fresh
rm -f "$PROJ/talos.pipeline.json"
assert_eq "false" "$(bash "$CONFIG" agents.claude_api_credits 2>/dev/null)" "AC7 agents.claude_api_credits defaults to false"
set_cfg "$ON"
assert_eq "true" "$(bash "$CONFIG" agents.claude_api_credits 2>"$ERR_F")" "AC7 agents.claude_api_credits true is read"
assert_eq "" "$(cat "$ERR_F")" "AC7 reading the key warns about nothing"
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "AC7 no unknown-key warning on the --dump path"

# snapshot <dir> -- everything AC7 compares, after one stage run.
snapshot() {
  mkdir -p "$1"
  cp "$RUNNER_LOG" "$1/argv"
  grep -v '^_=' "$CR_ENVS/1.env" | LC_ALL=C sort > "$1/env"
  cp "$OUT_F" "$1/out"; cp "$ERR_F" "$1/err"; printf '%s\n' "$RC" > "$1/rc"
  sed 's/"ts": "[^"]*"//' "$EVENTS" > "$1/events"
}
same_run() {  # <label> <dir> [err]: equal to the option-absent run; err skips stderr
  local _f
  for _f in argv env out rc events; do
    if cmp -s "$BASE/$_f" "$2/$_f"; then pass "AC7 $1: $_f equals the option-absent run"
    else fail "AC7 $1: $_f equals the option-absent run"; fi
  done
  [ "${3:-}" = "err" ] && return 0
  if cmp -s "$BASE/err" "$2/err"; then pass "AC7 $1: stderr equals the option-absent run"
  else fail "AC7 $1: stderr equals the option-absent run"; fi
}
BASE="$SANDBOX/snap-base"
fresh; set_cfg '{}'; stage; snapshot "$BASE"
fresh; set_cfg '{}'; stage; snapshot "$SANDBOX/snap-again"
check "AC7 control: two option-absent runs compare equal" cmp -s "$BASE/env" "$SANDBOX/snap-again/env"
check "AC7 control: their stderr compares equal too" cmp -s "$BASE/err" "$SANDBOX/snap-again/err"
assert_eq "0" "$(grep -c '"pool"' "$BASE/events")" "AC7 the option-absent events have no pool key"

fresh; set_cfg '{"agents": {"claude_api_credits": false}}'; stage; snapshot "$SANDBOX/snap-off"
same_run "false with a key in the file" "$SANDBOX/snap-off"

fresh; rm -f "$TH/.env"; set_cfg "$ON"; stage; snapshot "$SANDBOX/snap-nofile"
same_run "true with no file" "$SANDBOX/snap-nofile"

fresh; key_file "SOME_OTHER_NAME=x"; set_cfg "$ON"; stage; snapshot "$SANDBOX/snap-noname"
same_run "true with the name absent" "$SANDBOX/snap-noname"

fresh; key_file "CLAUDE_API_CREDITS_KEY="; set_cfg "$ON"; stage; snapshot "$SANDBOX/snap-empty"
same_run "true with an empty value" "$SANDBOX/snap-empty"

# added_line <label> <dir> -- stderr is the option-absent stderr plus exactly one
# pipeline-secrets line, which never holds the value.
added_line() {
  if grep -v '^pipeline-secrets: ' "$2/err" | cmp -s - "$BASE/err"; then pass "AC7 $1: stderr adds nothing but pipeline-secrets lines"
  else fail "AC7 $1: stderr adds nothing but pipeline-secrets lines"; fi
  assert_eq "1" "$(grep -c '^pipeline-secrets: ' "$2/err")" "AC7 $1: exactly one pipeline-secrets line is added"
  check_not "AC7 $1: that line never holds the value" has_key "$2/err"
}
fresh; key_file "CLAUDE_API_CREDITS_KEY=$KEYV" 644; set_cfg "$ON"; stage; snapshot "$SANDBOX/snap-refused"
same_run "true with a refused file" "$SANDBOX/snap-refused" err
added_line "true with a refused file" "$SANDBOX/snap-refused"
assert_contains "$(grep '^pipeline-secrets: ' "$SANDBOX/snap-refused/err")" "refusing .env" "AC7 true with a refused file: the line is the trust check's"

fresh; key_file "CLAUDE_API_CREDITS_KEY=${KEYV}$(printf '\t')tail"; set_cfg "$ON"; stage; snapshot "$SANDBOX/snap-ctl"
same_run "true with a control character" "$SANDBOX/snap-ctl" err
added_line "true with a control character" "$SANDBOX/snap-ctl"
assert_eq "pipeline-secrets: the value for CLAUDE_API_CREDITS_KEY holds a control character; ignoring it" \
  "$(grep '^pipeline-secrets: ' "$SANDBOX/snap-ctl/err" | sed "s/$KEYV/<the value>/")" "AC7 true with a control character: the line names the key"

# ═══ AC8: post_stage --pool, and the pool on the stage events ════════════════
fresh
rm -f "$PROJ/talos.pipeline.json"
last_keys() {  # the keys of the last event, in order
  tail -n 1 "$EVENTS" | python3 -I -c 'import json, sys; print(" ".join(json.loads(sys.stdin.read())))'
}
USAGE_FLAGS="--verdict PASS --tokens 6 --input-tokens 1 --output-tokens 2 --cache-write-tokens 3 --cache-read-tokens 4"
KEYS_NO_POOL="event role issue pr repo sha verdict summary details attempt model runner duration_s tokens tool_uses input_tokens output_tokens cache_write_tokens cache_read_tokens ts"
KEYS_POOL="${KEYS_NO_POOL% ts} pool ts"
# shellcheck disable=SC2086
bash "$HOOKS" post_stage stage_complete developer 7 $USAGE_FLAGS 2>"$ERR_F"
assert_eq "$KEYS_NO_POOL" "$(last_keys)" "AC8 without --pool the event is unchanged"
for p in api plan; do
  # shellcheck disable=SC2086
  bash "$HOOKS" post_stage stage_complete developer 7 $USAGE_FLAGS --pool "$p" 2>"$ERR_F"
  assert_eq "$KEYS_POOL" "$(last_keys)" "AC8 --pool $p writes \"pool\" after the #604 keys and before ts"
  assert_eq "$p" "$(event_field stage_complete pool)" "AC8 --pool $p records $p"
  assert_eq "" "$(cat "$ERR_F")" "AC8 --pool $p prints nothing on stderr"
done
# shellcheck disable=SC2086
bash "$HOOKS" post_stage stage_complete developer 7 $USAGE_FLAGS --pool credits 2>"$ERR_F"
assert_eq "$KEYS_NO_POOL" "$(last_keys)" "AC8 another --pool value leaves the key out"
assert_eq "1" "$(wc -l < "$ERR_F" | tr -d ' ')" "AC8 another --pool value prints one stderr line"

fresh
set_cfg "$ON"
stage
assert_eq "api" "$(event_field stage_complete pool)" "AC8 credits on: stage_complete of a stage that finished on the key has pool api"

fresh
cat > "$SANDBOX/quota.json" <<'TALOS_JSONr6Tm2Xv9Kd4P'
{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":7,"output_tokens":5}}
TALOS_JSONr6Tm2Xv9Kd4P
export CR_FAIL=keyed CR_FAIL_JSON="$SANDBOX/quota.json" STUB_CLAUDE_JSON_FILE="$TALOS_ROOT/tests/fixtures/runner-usage/claude-ok.json"
stage
assert_eq "2" "$(starts)" "AC8 a switch whose failed attempt reported usage: claude starts twice"
assert_eq "api" "$(event_field stage_attempt pool)" "AC8 after a switch the failed attempt's stage_attempt event has pool api"
assert_eq "15" "$(event_field stage_attempt tokens)" "AC8 that stage_attempt event carries the failed attempt's usage"
assert_eq "plan" "$(event_field stage_complete pool)" "AC8 after a switch stage_complete has pool plan"

fresh
set_cfg '{"agents": {"claude_api_credits": true, "runner": "codex"}}'
stage
assert_eq "<absent>" "$(event_field stage_complete pool)" "AC8 another runner's event has no pool key"
assert_eq "1" "$(runner_calls CODEX)" "AC8 that stage ran on the other runner"
fresh
set_cfg '{}'
stage
assert_eq "0" "$(pool_keys)" "AC8 a credits-off stage writes no pool key"

# ═══ AC9 / AC10: the cost forms ══════════════════════════════════════════════
fresh
rm -f "$PROJ/talos.pipeline.json"
mkdir -p "$PROJ/.git/talos"
cat > "$EVENTS" <<'TALOS_LOGw3Hc7Np5Zr8J'
{"event":"stage_attempt","role":"developer","issue":7,"pr":9,"verdict":"FAIL","model":"sonnet","tokens":1200000,"tool_uses":1,"duration_s":10,"cache_read_tokens":48000000,"pool":"api","ts":"2026-10-11T00:00:01Z"}
{"event":"stage_complete","role":"developer","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":300000,"tool_uses":1,"duration_s":10,"cache_read_tokens":2000000,"pool":"plan","ts":"2026-10-11T00:00:02Z"}
{"event":"stage_complete","role":"developer","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":300000,"tool_uses":1,"duration_s":10,"pool":"api","ts":"2026-10-11T00:00:03Z"}
{"event":"stage_complete","role":"qa","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":30000,"tool_uses":1,"duration_s":10,"cache_read_tokens":3000,"ts":"2026-10-11T00:00:04Z"}
{"event":"stage_complete","role":"qa","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":40000,"tool_uses":1,"duration_s":10,"pool":"bogus","ts":"2026-10-11T00:00:05Z"}
{"event":"failover","role":"orchestrator","issue":7,"pr":null,"summary":"x","ts":"2026-10-11T00:00:06Z"}
{"event":"merged","role":"orchestrator","issue":7,"pr":9,"ci_runs":2,"ts":"2026-10-11T00:00:07Z"}
{"event":"stage_complete","role":"developer","issue":8,"pr":11,"verdict":"PASS","model":"sonnet","tokens":5000,"cache_read_tokens":100,"ts":"2026-10-11T00:00:08Z"}
TALOS_LOGw3Hc7Np5Zr8J
TAB="$(printf '\t')"
POOL_COLS="api_tokens${TAB}api_cache_read_tokens${TAB}plan_tokens${TAB}plan_cache_read_tokens${TAB}pool_unrecorded"

# ── AC9: the table and --json ───────────────────────────────────────────────
table="$(bash "$EVENTS_SH" cost --issue 7 2>/dev/null)"
assert_eq "issue${TAB}role${TAB}events${TAB}tokens${TAB}tool_uses${TAB}duration_s${TAB}unrecorded${TAB}restamp${TAB}input_tokens${TAB}output_tokens${TAB}cache_write_tokens${TAB}cache_read_tokens${TAB}cache_unrecorded${TAB}${POOL_COLS}${TAB}ci_runs" \
  "$(printf '%s\n' "$table" | sed -n 1p)" "AC9 the table header gains the pool columns after cache_unrecorded and before ci_runs"
assert_eq "7${TAB}developer${TAB}3${TAB}1800000${TAB}3${TAB}30${TAB}0${TAB}0${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}50000000${TAB}1${TAB}1500000${TAB}48000000${TAB}300000${TAB}2000000${TAB}0${TAB}0" \
  "$(printf '%s\n' "$table" | grep "^7${TAB}developer")" "AC9 the developer row sums each pool (a missing cache read counts 0)"
assert_eq "7${TAB}qa${TAB}2${TAB}70000${TAB}2${TAB}20${TAB}0${TAB}0${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}3000${TAB}1${TAB}0${TAB}0${TAB}0${TAB}0${TAB}2${TAB}0" \
  "$(printf '%s\n' "$table" | grep "^7${TAB}qa")" "AC9 a missing pool and any other pool value are unrecorded"
assert_eq "1500000${TAB}48000000${TAB}300000${TAB}2000000${TAB}2${TAB}2" \
  "$(printf '%s\n' "$table" | grep '^TOTAL' | cut -f14-)" "AC9 the TOTAL row sums the pools and leaves orchestrator rows out of pool_unrecorded"

json_check="$(bash "$EVENTS_SH" cost --issue 7 --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
tail = ["cache_unrecorded", "api_tokens", "api_cache_read_tokens", "plan_tokens", "plan_cache_read_tokens", "pool_unrecorded", "ci_runs"]
bad = []
for name, row in [(r["role"], r) for r in d["rows"]] + [("total", d["total"])]:
    if list(row)[-7:] != tail:
        bad.append("%s keys end %s" % (name, list(row)[-7:]))
want = {"developer": (1500000, 48000000, 300000, 2000000, 0), "orchestrator": (0, 0, 0, 0, 2),
        "qa": (0, 0, 0, 0, 2), "total": (1500000, 48000000, 300000, 2000000, 2)}
rows = {r["role"]: r for r in d["rows"]}
rows["total"] = d["total"]
for name, vals in want.items():
    got = tuple(rows.get(name, {}).get(k) for k in tail[1:6])
    if got != vals:
        bad.append("%s is %s" % (name, got))
print("; ".join(bad) or "ok")
' 2>&1)"
assert_eq "ok" "$json_check" "AC9 --json: every row and the total gain the five pool fields, in order, with the right sums"

assert_eq "issue${TAB}role${TAB}events${TAB}tokens${TAB}tool_uses${TAB}duration_s${TAB}unrecorded${TAB}restamp${TAB}input_tokens${TAB}output_tokens${TAB}cache_write_tokens${TAB}cache_read_tokens${TAB}cache_unrecorded
8${TAB}developer${TAB}1${TAB}5000${TAB}0${TAB}0${TAB}0${TAB}0${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}100${TAB}0
TOTAL${TAB}${TAB}1${TAB}5000${TAB}0${TAB}0${TAB}0${TAB}0${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}100${TAB}0" \
  "$(bash "$EVENTS_SH" cost --issue 8 2>/dev/null)" "AC9 with no pool event in scope the table is byte-identical to today's"
assert_eq '{"rows": [{"issue": 8, "role": "developer", "events": 1, "tokens": 5000, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "input_tokens": null, "output_tokens": null, "cache_write_tokens": null, "cache_read_tokens": 100, "cache_unrecorded": 0}], "total": {"events": 1, "tokens": 5000, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "input_tokens": null, "output_tokens": null, "cache_write_tokens": null, "cache_read_tokens": 100, "cache_unrecorded": 0}}' \
  "$(bash "$EVENTS_SH" cost --issue 8 --json 2>/dev/null)" "AC9 with no pool event in scope --json is byte-identical to today's"

# ── AC10: the Pools line ────────────────────────────────────────────────────
POOLS="Pools: API credits 1.50M (cache read 48.00M), plan 300k (cache read 2.00M) (+2 unrecorded)"
# after <pattern> -- the first non-empty line after the first line matching it.
after() { awk -v p="$1" 'found && NF { print; exit } index($0, p) == 1 { found = 1 }'; }
md="$(bash "$EVENTS_SH" cost --issue 7 --pr 9 --markdown 2>/dev/null)"
assert_eq "$POOLS" "$(printf '%s\n' "$md" | after 'This PR (#9)')" "AC10 --markdown: the Pools line follows the This PR line"
assert_eq "1" "$(printf '%s\n' "$md" | grep -c '^Pools: ')" "AC10 --markdown prints one Pools line"
md="$(bash "$EVENTS_SH" cost --issue 7 --markdown 2>/dev/null)"
assert_eq "$POOLS" "$(printf '%s\n' "$md" | after '| TOTAL |')" "AC10 --markdown without --pr: the Pools line follows the TOTAL row"
sm="$(bash "$EVENTS_SH" cost --summary --issue 7 2>/dev/null)"
assert_eq "$POOLS" "$(printf '%s\n' "$sm" | after 'Total: ')" "AC10 --summary: the Pools line follows the Total: line"
assert_eq "1" "$(printf '%s\n' "$sm" | grep -c '^Pools: ')" "AC10 --summary prints one Pools line"
assert_eq "0" "$(bash "$EVENTS_SH" cost --issue 8 --pr 11 --markdown 2>/dev/null | grep -c 'Pools:')" "AC10 no pool-carrying event: --markdown has no Pools line"
assert_eq "0" "$(bash "$EVENTS_SH" cost --summary --issue 8 2>/dev/null | grep -c 'Pools:')" "AC10 no pool-carrying event: --summary has no Pools line"

with_pool="$(bash "$EVENTS_SH" cost --issue 7 --pr 9 --line 2>/dev/null)"
cp "$EVENTS" "$SANDBOX/events.keep"
sed 's/"pool":"[a-z]*",//' "$SANDBOX/events.keep" > "$EVENTS"
assert_eq "0" "$(grep -c '"pool"' "$EVENTS")" "AC10 control: the pool keys were stripped from the copy"
assert_eq "$with_pool" "$(bash "$EVENTS_SH" cost --issue 7 --pr 9 --line 2>/dev/null)" "AC10 --line is unchanged by the pool key"
assert_contains "$with_pool" "talos: #9" "AC10 control: --line printed its line"

: > "$EVENTS"
i=1
while [ "$i" -le 20 ]; do
  printf '{"event":"stage_complete","role":"developer","issue":20,"pr":%d,"verdict":"PASS","model":"sonnet","tokens":%d,"cache_read_tokens":10,"pool":"api","ts":"2026-10-11T00:00:00Z"}\n' "$((100 + i))" "$((i * 1000))" >> "$EVENTS"
  i=$((i + 1))
done
sm="$(bash "$EVENTS_SH" cost --summary --issue 20 2>/dev/null)"
assert_eq "1" "$(printf '%s\n' "$sm" | grep -c '^Pools: API credits 210k (cache read 200), plan 0 (cache read 0)$')" "AC10 --summary of 20 rows still prints the Pools line"
assert_eq "20" "$(printf '%s\n' "$sm" | wc -l | tr -d ' ')" "AC10 --summary with a Pools line stays at 20 lines"
assert_contains "$sm" "more rows" "AC10 control: the smallest rows folded"

# ═══ AC11: the key is in no output, log, argv or posted body ═════════════════
# leaks -- the files under the sandbox that hold the key, minus where it belongs:
# the user-level file, this test's copy, and the environment of the one claude
# start that ran with it.
leaks() {
  grep -rlF -- "$KEYV" "$SANDBOX" 2>/dev/null \
    | grep -vxF -e "$TH/.env" -e "$CR_KEY_COPY" -e "$CR_ENVS/1.env"
}
fresh
set_cfg "$ON"
stage
assert_eq "file" "$(key_state 1)" "AC11 a stage that finishes on the key ran with it"
assert_eq "" "$(leaks)" "AC11 a stage that finishes on the key: the key is in no output, log or argv"

fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA"
stage
assert_eq "file unset" "$(key_state 1) $(key_state 2)" "AC11 a switch ran on the key, then on the plan login"
assert_eq "" "$(leaks)" "AC11 a switch: the key is in no output, log or argv"

fresh
export CR_FAIL=keyed CR_FAIL_TEXT="$QUOTA" CR_WRITE="bash '$VCS' comment-issue 5 'progress note' >/dev/null"
stage
assert_eq "69 file" "$RC $(key_state 1)" "AC11 a refused switch ran on the key and was refused"
assert_contains "$(cat "$GH_LOG")" "progress note" "AC11 control: the body posted through pipeline-vcs.sh is in the gh log"
assert_eq "" "$(leaks)" "AC11 a refused switch: the key is in no output, log, argv or posted body"

fresh
key_file "CLAUDE_API_CREDITS_KEY=$KEYV" 644
stage
assert_eq "1" "$(grep -c '^pipeline-secrets: refusing' "$ERR_F")" "AC11 a refused file is reported"
assert_eq "" "$(grep -rlF -- "$KEYV" "$SANDBOX" 2>/dev/null | grep -vxF -e "$TH/.env" -e "$CR_KEY_COPY")" \
  "AC11 a refused file: the key is in no output, log, argv or child environment"

finish
