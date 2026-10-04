#!/usr/bin/env bash
# tests/test-runner-failover.sh -- runner failover chain with provider-error
# classification (#418, part of epic #423): agents.fallback, _classify_exit,
# .talos/providers.json, the write guard, --classify / --mark-down, the
# failover event, and --resolve / --resolve-all.
#
# Everything runs against the stub runners in tests/stubs/ (env-controlled exit
# code and output) and the stub gh. No real runner, no real GitHub. The agent
# script runs from a copy of scripts/ whose pipeline-worktree.sh is a stub, so
# the checkpoint call never touches a real worktree or remote.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
AGENT="$INST/scripts/pipeline-agent.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CONFIG="$TALOS_ROOT/scripts/pipeline-config.sh"
WT_LOG="$SANDBOX/wt.log"
export RUNNER_LOG="$SANDBOX/runner.log"
export STUB_PROMPT_DIR="$SANDBOX/prompts"
mkdir -p "$STUB_PROMPT_DIR"
ERR="$SANDBOX/err.txt"
PROV="$SANDBOX/.talos/providers.json"
EVENTS="$SANDBOX/.talos/events.jsonl"

# pipeline-worktree.sh stand-ins: absent verb (today's reality), working verb,
# failing verb.
wt_stub() {  # absent | present | failing
  case "$1" in
    absent)  printf '#!/usr/bin/env bash\necho "unknown verb" >&2\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh" ;;
    present) printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$WT_LOG" > "$INST/scripts/pipeline-worktree.sh" ;;
    failing) printf '#!/usr/bin/env bash\nexit 1\n' > "$INST/scripts/pipeline-worktree.sh" ;;
  esac
}

reset() {
  rm -rf "${SANDBOX:?}/.talos" "$STUB_PROMPT_DIR"; mkdir -p "$STUB_PROMPT_DIR"
  : > "$RUNNER_LOG"; : > "$GH_LOG"; : > "$WT_LOG"
  unset STUB_CLAUDE_EXIT STUB_CLAUDE_STDERR STUB_CLAUDE_STDOUT STUB_CLAUDE_HOOK \
        STUB_CODEX_EXIT STUB_CODEX_STDERR STUB_CODEX_STDOUT STUB_CODEX_HOOK \
        STUB_GEMINI_EXIT STUB_GEMINI_STDERR STUB_PI_EXIT TALOS_ISSUE
  wt_stub absent
}
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# stage [role] -- stdout in $OUT, stderr in $ERR, exit code in $RC.
stage() { OUT="$(bash "$AGENT" "${1:-developer}" "the task text" 2>"$ERR")"; RC=$?; }
errtxt() { cat "$ERR"; }
runner_calls() { grep -c "^$1 ARGS" "$RUNNER_LOG"; }
down_until() {  # <runner> -> the down_until value, or empty
  python3 -I - "$PROV" "$1" <<'PYEOF'
import json, sys
try:
    print(json.load(open(sys.argv[1]))[sys.argv[2]]["down_until"])
except Exception:
    pass
PYEOF
}
event_field() {  # <event> <field> -> field of the last such event
  python3 -I - "$EVENTS" "$1" "$2" <<'PYEOF'
import json, sys
val = None
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e.get("event") == sys.argv[2]:
        val = e.get(sys.argv[3])
print("<none>" if val is None else val)
PYEOF
}
event_count() { grep -c "\"event\": \"$1\"" "$EVENTS" 2>/dev/null || true; }

reset
# ═══ 1. Config: known keys and validation ═══════════════════════════════════
set_cfg '{"agents": {"fallback": ["codex", "gemini"], "provider_down_s": 120,
  "roles": {"qa": {"fallback": ["pi"]}}}}'
assert_eq "codex
gemini" "$(bash "$CONFIG" agents.fallback "" 2>"$ERR")" "config: agents.fallback comes back newline-separated"
assert_eq "pi" "$(bash "$CONFIG" agents.roles.qa.fallback "" 2>"$ERR")" "config: agents.roles.<role>.fallback is a known key"
assert_eq "120" "$(bash "$CONFIG" agents.provider_down_s 900 2>"$ERR")" "config: agents.provider_down_s is read"
assert_eq "" "$(errtxt)" "config: valid values and known keys warn about nothing"
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "config: --dump warns about nothing for valid values"

bad_fallback() {  # <label> <json value>
  set_cfg "{\"agents\": {\"fallback\": $2}}"
  local v w
  v="$(bash "$CONFIG" agents.fallback DEFAULT 2>"$ERR")"
  assert_eq "DEFAULT" "$v" "config: invalid fallback ($1) reads as absent"
  assert_eq "1" "$(grep -c 'agents.fallback must be a list' "$ERR")" "config: invalid fallback ($1) warns once"
  w="$(bash "$CONFIG" --dump 2>&1 >/dev/null | grep -c 'agents.fallback must be a list')"
  assert_eq "1" "$w" "config: invalid fallback ($1) warns once on the --dump path"
  assert_eq "0" "$(bash "$CONFIG" --dump 2>/dev/null | tr '\0' '\n' | grep -c '^agents.fallback$')" "config: invalid fallback ($1) is dropped from --dump"
}
bad_fallback "unknown runner" '["codex", "nope"]'
bad_fallback "duplicate" '["codex", "codex"]'
bad_fallback "six entries" '["claude","pi","codex","gemini","antigravity","custom"]'
bad_fallback "bare string" '"codex"'
bad_fallback "empty list" '[]'
set_cfg '{"agents": {"roles": {"qa": {"fallback": ["x"]}}}}'
assert_eq "D" "$(bash "$CONFIG" agents.roles.qa.fallback D 2>/dev/null)" "config: an invalid role fallback reads as absent"
for v in 59 86401 abc true 1.5; do
  set_cfg "{\"agents\": {\"provider_down_s\": $v}}"
  assert_eq "900" "$(bash "$CONFIG" agents.provider_down_s 900 2>/dev/null)" "config: provider_down_s $v is rejected"
done
for v in 60 86400; do
  set_cfg "{\"agents\": {\"provider_down_s\": $v}}"
  assert_eq "$v" "$(bash "$CONFIG" agents.provider_down_s 900 2>/dev/null)" "config: provider_down_s $v is accepted"
done

# The validator's id set equals TALOS_RUNNERS (a restated copy, so pin it).
want="$(for e in "${TALOS_RUNNERS[@]}"; do printf '%s\n' "${e%%|*}"; done | sort)"
have="$(sed -n 's/^_FALLBACK_RUNNERS = (\(.*\))$/\1/p' "$CONFIG" | tr -d '" ' | tr ',' '\n' | sort)"
assert_eq "$want" "$have" "config: the fallback validator's runner ids equal TALOS_RUNNERS"
for e in "${TALOS_RUNNERS[@]}"; do
  set_cfg "{\"agents\": {\"fallback\": [\"${e%%|*}\"]}}"
  assert_eq "${e%%|*}" "$(bash "$CONFIG" agents.fallback "" 2>/dev/null)" "config: fallback accepts ${e%%|*}"
done

# The user-level file feeds agents.fallback like the other agents.* keys.
mkdir -p "$SANDBOX/userhome"
printf '{"agents": {"fallback": ["pi"]}}\n' > "$SANDBOX/userhome/talos.pipeline.json"
set_cfg '{"base_branch": "main"}'
assert_eq "pi" "$(TALOS_HOME="$SANDBOX/userhome" bash "$CONFIG" agents.fallback "" 2>/dev/null)" "config: agents.fallback is read from the user-level file"

# ═══ 2. _classify_exit through --classify ═══════════════════════════════════
cls() {  # <runner> <rc> <text> -> class on stdout
  printf '%s\n' "$3" | bash "$AGENT" --classify "$1" "$2" -
}
assert_eq "ok" "$(cls claude 0 'API Error: 429')" "classify: exit 0 is ok, whatever the text says"
assert_eq "provider" "$(cls claude 1 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}')" "classify: 429 is provider"
assert_eq "provider" "$(cls claude 1 'Credit balance is too low')" "classify: credit exhausted is provider"
assert_eq "provider" "$(cls claude 1 'Claude AI usage limit reached|1700000000')" "classify: usage limit reached is provider"
assert_eq "provider" "$(cls claude 1 'API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}')" "classify: overloaded is provider"
assert_eq "provider" "$(cls claude 1 'Invalid API key - Please run /login')" "classify: auth failure is provider"
assert_eq "provider" "$(cls claude 1 'API Error: 401 authentication_error')" "classify: HTTP 401 is provider"
assert_eq "provider" "$(cls claude 1 'API Error: Connection error. (getaddrinfo ENOTFOUND api.anthropic.com)')" "classify: network error is provider"
assert_eq "task" "$(cls claude 1 'Tests failed: 3 of 10')" "classify: a plain task failure is task"
assert_eq "task" "$(cls claude 137 '')" "classify: an unrecognised non-zero exit with no text is task"
assert_eq "task" "$(cls claude 2 'something went wrong that we do not know')" "classify: unrecognised non-zero output is task"
assert_eq "task" "$(cls claude 1 'I added retry code that handles 429 and rate limit responses (ETIMEDOUT too).')" "classify: 429 and rate limits in model prose are task"
assert_eq "task" "$(cls claude 1 '  API Error: 429 indented prose')" "classify: a shape that is not at the line start is task"
assert_eq "task" "$(cls claude 1 "$(printf 'API Error: 429\n'; for i in $(seq 1 25); do echo "line $i"; done)")" "classify: only the last 20 lines are read"
for r in claude pi codex gemini antigravity custom; do
  assert_eq "provider" "$(cls "$r" 75 '')" "classify: exit 75 is provider for $r"
  assert_eq "task" "$(cls "$r" 1 'plain failure')" "classify: a plain failure is task for $r"
  assert_eq "task" "$(cls "$r" 9 '')" "classify: an unrecognised non-zero exit is task for $r"
done
assert_eq "task" "$(cls codex 1 'exceeded retry limit, last status: 429')" "classify: a runner without captured patterns is exit-75-only (codex)"
assert_eq "task" "$(cls gemini 1 'RESOURCE_EXHAUSTED')" "classify: a runner without captured patterns is exit-75-only (gemini)"
printf 'API Error: 429\n' > "$SANDBOX/cls.txt"
assert_eq "provider" "$(bash "$AGENT" --classify claude 1 "$SANDBOX/cls.txt")" "classify: reads a file argument"
bash "$AGENT" --classify bogus 1 - </dev/null >/dev/null 2>&1; assert_eq "2" "$?" "classify: unknown runner exits 2"
bash "$AGENT" --classify claude x - </dev/null >/dev/null 2>&1; assert_eq "2" "$?" "classify: non-numeric rc exits 2"
bash "$AGENT" --classify claude 1 "$SANDBOX/nope" >/dev/null 2>&1; assert_eq "2" "$?" "classify: unreadable file exits 2"

# ═══ 3. No chain configured: behaviour is the runner's, providers.json untouched
reset
set_cfg '{"agents": {"runner": "claude"}}'
for r in claude pi codex gemini antigravity; do
  reset
  set_cfg "{\"agents\": {\"runner\": \"$r\"}}"
  stage
  assert_eq "0" "$RC" "no chain ($r): exit 0"
  assert_eq "talos:runner role=developer runner=$r
talos:usage runner=$r tokens=null" "$(errtxt)" "no chain ($r): stderr is the runner and usage markers only (#420)"
  assert_contains "$OUT" "-stub-ok" "no chain ($r): stdout is the runner's"
  [ ! -e "$PROV" ] && pass "no chain ($r): providers.json never written" || fail "no chain ($r): providers.json never written"
done
reset
set_cfg '{"agents": {"runner": "claude"}}'
STUB_CLAUDE_EXIT=75 STUB_CLAUDE_STDERR='API Error: 429' stage
assert_eq "75" "$RC" "no chain: a provider-looking failure still exits with the runner's own code"
assert_eq "claude-stub-ok" "$OUT" "no chain: the failed runner's stdout is passed through"
assert_contains "$(errtxt)" "API Error: 429" "no chain: stderr is passed through"
[ ! -e "$PROV" ] && pass "no chain: no providers.json after a provider exit" || fail "no chain: no providers.json after a provider exit"
assert_eq "" "$(grep -c failover "$ERR" | grep -v '^0$')" "no chain: no failover line"
assert_eq "0" "$(event_count failover)" "no chain: no failover event"
assert_eq "claude" "$(event_field stage_complete runner)" "no chain: stage_complete event runner stays agents.runner"

# ═══ 4. Failover on a provider exit ═════════════════════════════════════════
reset
set_cfg '{"agents": {"runner": "claude", "model": "sonnet", "runner_args": ["--primary-only"], "fallback": ["codex", "gemini"]}}'
export TALOS_ISSUE=5
STUB_CLAUDE_EXIT=75 STUB_CLAUDE_STDOUT=claude-partial STUB_CLAUDE_STDERR='claude died' stage
assert_eq "0" "$RC" "failover: the stage ends on the fallback runner's exit code"
assert_eq "codex-stub-ok" "$OUT" "failover: only the final attempt's stdout reaches the caller"
assert_eq "1" "$(runner_calls CLAUDE)" "failover: the primary ran once"
assert_eq "1" "$(runner_calls CODEX)" "failover: the fallback ran once"
assert_eq "0" "$(runner_calls GEMINI)" "failover: the third runner was not needed"
if cmp -s "$STUB_PROMPT_DIR/claude.prompt" "$STUB_PROMPT_DIR/codex.prompt" && [ -s "$STUB_PROMPT_DIR/codex.prompt" ]; then
  pass "failover: the second runner received the byte-identical prompt"
else
  fail "failover: the second runner received the byte-identical prompt"
fi
assert_contains "$(grep '^CLAUDE ARGS' "$RUNNER_LOG")" "[--primary-only]" "failover: runner_args go to the primary"
case "$(grep '^CODEX ARGS' "$RUNNER_LOG")" in
  *--primary-only*) fail "failover: runner_args are not forwarded to a fallback runner" ;;
  *) pass "failover: runner_args are not forwarded to a fallback runner" ;;
esac
assert_contains "$(errtxt)" "talos:failover role=developer from=claude to=codex reason=provider:exit75" "failover: talos:failover on stderr"
assert_contains "$(errtxt)" "claude died" "failover: the failed attempt's stderr is replayed"
case "$(down_until claude)" in 20*Z) pass "failover: providers.json records the primary with an expiry" ;; *) fail "failover: providers.json records the primary with an expiry" "$(cat "$PROV" 2>&1)" ;; esac
assert_eq "" "$(down_until codex)" "failover: the runner that worked is not marked down"
assert_eq "1" "$(event_count failover)" "failover: one failover event"
assert_eq "orchestrator" "$(event_field failover role)" "failover: the event is recorded under role orchestrator"
assert_contains "$(event_field failover summary)" "from=claude to=codex" "failover: the event summary names from and to"
assert_eq "1" "$(event_count stage_complete)" "failover: stage_complete fires once"
assert_eq "codex" "$(event_field stage_complete runner)" "failover: the stage event names the runner that ran"
assert_eq "<none>" "$(event_field stage_complete model)" "failover: the stage event model is null on a fallback runner"
assert_eq "PASS" "$(event_field stage_complete verdict)" "failover: the stage event verdict follows the final outcome"
assert_contains "$(errtxt)" "checkpoint-skipped" "failover: an absent checkpoint verb prints one skip note"
assert_eq "1" "$(grep -c 'checkpoint-skipped' "$ERR")" "failover: exactly one checkpoint note"
assert_eq "" "$(grep -E 'role=developer runner=claude' "$GH_LOG")" "failover: no gh calls"

# A recognised claude error line (not exit 75) fails over too, on stderr or on stdout.
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=1 STUB_CLAUDE_STDERR='API Error: 429 {"type":"error"}' stage
assert_eq "0" "$RC" "pattern: a claude 429 line on stderr fails over"
assert_contains "$(errtxt)" "from=claude to=codex reason=provider:429" "pattern: the reason carries the class detail"
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=1 STUB_CLAUDE_STDOUT='Credit balance is too low' stage
assert_eq "0" "$RC" "pattern: an error line on stdout fails over"
assert_eq "codex-stub-ok" "$OUT" "pattern: the failed attempt's stdout is discarded"
assert_contains "$(errtxt)" "reason=provider:quota" "pattern: quota detail"

# A stage that did not fail over keeps its event as it was (runner = agents.runner, model = agents.model).
reset
set_cfg '{"agents": {"runner": "claude", "model": "sonnet", "fallback": ["codex"]}}'
export TALOS_ISSUE=5
stage
assert_eq "claude" "$(event_field stage_complete runner)" "no failover with a chain set: stage event runner unchanged"
assert_eq "sonnet" "$(event_field stage_complete model)" "no failover with a chain set: stage event model unchanged"
assert_eq "0" "$(event_count failover)" "no failover with a chain set: no failover event"
[ ! -e "$PROV" ] && pass "no failover with a chain set: providers.json not written" || fail "no failover with a chain set: providers.json not written"
assert_eq "1" "$(runner_calls CLAUDE)" "no failover with a chain set: the primary ran once"

# pre_dispatch runs once, not again for the rerun.
reset
set_cfg "{\"agents\": {\"fallback\": [\"codex\"]}, \"hooks\": {\"pre_dispatch\": \"echo x >> $SANDBOX/pre.log; echo ctx\"}}"
rm -f "$SANDBOX/pre.log"
STUB_CLAUDE_EXIT=75 stage
assert_eq "1" "$(wc -l < "$SANDBOX/pre.log" | tr -d ' ')" "failover: pre_dispatch ran once, not again for the rerun"

# ═══ 5. Task failure: no failover ═══════════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=1 STUB_CLAUDE_STDERR='Tests failed: 3 of 10' STUB_CLAUDE_STDOUT=claude-report stage
assert_eq "1" "$RC" "task: the exit code is the runner's"
assert_eq "claude-report" "$OUT" "task: the runner's stdout reaches the caller"
assert_contains "$(errtxt)" "Tests failed" "task: stderr is replayed"
assert_eq "0" "$(runner_calls CODEX)" "task: the fallback was not tried"
[ ! -e "$PROV" ] && pass "task: nothing marked down" || fail "task: nothing marked down"
assert_eq "0" "$(grep -c 'talos:failover' "$ERR")" "task: no failover line"
assert_eq "FAIL" "$(event_field stage_complete verdict)" "task: stage_complete is FAIL"
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=1 STUB_CLAUDE_STDERR='I handled 429 and rate limit replies in retry.go' stage
assert_eq "1" "$RC" "task: prose about 429 / rate limits does not fail over"
assert_eq "0" "$(runner_calls CODEX)" "task: prose about 429 does not try the fallback"

# A provider exit never touches record-attempt (it is a verb nobody calls here).
assert_eq "0" "$(grep -c 'record-attempt' "$GH_LOG")" "provider exit: record-attempt is never called"

# ═══ 6. Down-cache: skip while down, retry after expiry ═════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=75 stage
: > "$RUNNER_LOG"
stage
assert_eq "0" "$RC" "down-cache: the second stage succeeds"
assert_eq "0" "$(runner_calls CLAUDE)" "down-cache: a runner marked down is not tried"
assert_eq "1" "$(runner_calls CODEX)" "down-cache: the next runner runs"
assert_contains "$(errtxt)" "talos:failover role=developer from=claude to=codex reason=down-cached" "down-cache: logged with reason=down-cached"
assert_eq "codex" "$(event_field stage_complete runner)" "down-cache: the stage event names the fallback runner"
# expire the entry: claude is tried again
python3 -I - "$PROV" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["claude"]["down_until"] = "2000-01-01T00:00:00Z"
json.dump(d, open(sys.argv[1], "w"))
PYEOF
: > "$RUNNER_LOG"
stage
assert_eq "1" "$(runner_calls CLAUDE)" "down-cache: after expiry the runner is tried again"
assert_eq "0" "$(runner_calls CODEX)" "down-cache: after expiry the primary succeeds, no fallback"
# the write pruned nothing wrongly: a later provider exit rewrites the entry with a fresh expiry
STUB_CLAUDE_EXIT=75 stage
case "$(down_until claude)" in 2000-*) fail "down-cache: a fresh provider exit refreshes the expiry" ;; *) pass "down-cache: a fresh provider exit refreshes the expiry" ;; esac

# ═══ 7. Chain exhausted / everything down: exit 69 ══════════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
STUB_CLAUDE_EXIT=75 STUB_CODEX_EXIT=75 stage
assert_eq "69" "$RC" "exhausted: exit 69"
assert_eq "" "$OUT" "exhausted: no stdout from the failed attempts"
assert_contains "$(errtxt)" "provider chain exhausted role=developer chain=claude,codex" "exhausted: one stderr line names the chain"
assert_contains "$(errtxt)" "claude:provider:exit75" "exhausted: the line names every reason (claude)"
assert_contains "$(errtxt)" "codex:provider:exit75" "exhausted: the line names every reason (codex)"
assert_eq "1" "$(runner_calls CLAUDE)" "exhausted: bounded by the chain length (claude once)"
assert_eq "1" "$(runner_calls CODEX)" "exhausted: bounded by the chain length (codex once)"
assert_eq "FAIL" "$(event_field stage_complete verdict)" "exhausted: stage_complete is FAIL"
: > "$RUNNER_LOG"
stage
assert_eq "69" "$RC" "all down: exit 69 without running a runner"
assert_eq "0" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" "all down: no runner was invoked"
assert_contains "$(errtxt)" "claude:down-cached" "all down: the reasons say down-cached"

# ═══ 8. Write guard ═════════════════════════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
export STUB_CLAUDE_HOOK="bash '$VCS' comment-issue 5 'progress note' >/dev/null"
STUB_CLAUDE_EXIT=75 stage
assert_eq "69" "$RC" "write guard: a provider exit after comment-issue exits 69"
assert_eq "0" "$(runner_calls CODEX)" "write guard: no rerun after a write"
assert_contains "$(errtxt)" "talos:failover-refused role=developer runner=claude reason=wrote:comment-issue" "write guard: names the verb"
case "$(down_until claude)" in 20*Z) pass "write guard: the provider is still marked down" ;; *) fail "write guard: the provider is still marked down" ;; esac
assert_eq "0" "$(grep -c 'talos:failover role=' "$ERR")" "write guard: no failover switch is announced"

reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
git init -q --bare "$SANDBOX/origin.git"
git remote set-url origin "$SANDBOX/origin.git"
git commit -q --allow-empty -m base
export STUB_CLAUDE_HOOK="git commit -q --allow-empty -m work && git push -q origin HEAD:refs/heads/work"
STUB_CLAUDE_EXIT=75 stage
assert_eq "69" "$RC" "write guard: a provider exit after git push exits 69"
assert_eq "0" "$(runner_calls CODEX)" "write guard: no rerun after a push"
assert_contains "$(errtxt)" "reason=wrote:push" "write guard: names the push"

# A failing verb does not count as a write; a read verb does not either.
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
export STUB_CLAUDE_HOOK="bash '$VCS' read-comments 5 >/dev/null 2>&1; bash '$VCS' --dry-run comment-issue 5 x >/dev/null 2>&1; true"
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "write guard: read verbs and --dry-run do not block a failover"
assert_eq "1" "$(runner_calls CODEX)" "write guard: the fallback ran after read-only verbs"
unset STUB_CLAUDE_HOOK

# The journal itself: only with TALOS_WRITE_LOG, only successful write verbs.
J="$SANDBOX/journal"
: > "$J"
bash "$VCS" comment-issue 5 'hello' >/dev/null 2>&1
assert_eq "0" "$(wc -c < "$J" | tr -d ' ')" "journal: unset TALOS_WRITE_LOG writes nothing"
TALOS_WRITE_LOG="$J" bash "$VCS" comment-issue 5 'hello' >/dev/null 2>&1
assert_eq "comment-issue" "$(cat "$J")" "journal: a successful comment-issue appends its verb name"
TALOS_WRITE_LOG="$J" bash "$VCS" read-comments 5 >/dev/null 2>&1
TALOS_WRITE_LOG="$J" bash "$VCS" --dry-run comment-issue 5 'hello' >/dev/null 2>&1
assert_eq "comment-issue" "$(cat "$J")" "journal: read verbs and --dry-run append nothing"

# #449: `create-pr --draft` returns through the draft-gate dispatcher, which exits
# itself, and used to skip the journal: a failover after the PR was opened as a
# draft would open a second one.
: > "$J"
printf 'pr body\n' > "$SANDBOX/pr-body.md"
TALOS_WRITE_LOG="$J" bash "$VCS" create-pr feat/x "title" "$SANDBOX/pr-body.md" >/dev/null 2>&1
assert_eq "create-pr" "$(cat "$J")" "journal: a successful create-pr appends its verb name"
: > "$J"
TALOS_WRITE_LOG="$J" bash "$VCS" create-pr feat/x "title" "$SANDBOX/pr-body.md" --draft >/dev/null 2>&1
assert_eq "create-pr" "$(cat "$J")" "journal: a successful create-pr --draft appends its verb name (#449)"
: > "$J"
TALOS_WRITE_LOG="$J" bash "$VCS" --dry-run create-pr feat/x "title" "$SANDBOX/pr-body.md" --draft >/dev/null 2>&1
assert_eq "0" "$(wc -c < "$J" | tr -d ' ')" "journal: create-pr --draft --dry-run appends nothing"
# github-api refuses --draft (exit 2): a failed create-pr --draft journals nothing.
set_cfg '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}'
GITHUB_TOKEN=t TALOS_WRITE_LOG="$J" bash "$VCS" create-pr feat/x "title" "$SANDBOX/pr-body.md" --draft >/dev/null 2>&1; _449_rc=$?
assert_eq "2" "$_449_rc" "journal: control, github-api create-pr --draft is exit 2"
assert_eq "0" "$(wc -c < "$J" | tr -d ' ')" "journal: a failed create-pr --draft appends nothing"
set_cfg '{"agents": {"fallback": ["codex"]}}'

# ═══ 9. Checkpoint ══════════════════════════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
export TALOS_ISSUE=7
wt_stub present
STUB_CLAUDE_EXIT=75 stage
assert_eq "checkpoint 7" "$(cat "$WT_LOG")" "checkpoint: pipeline-worktree.sh checkpoint <N> runs before the rerun"
assert_eq "0" "$(grep -c 'checkpoint-skipped' "$ERR")" "checkpoint: no skip note when the verb works"
assert_eq "0" "$RC" "checkpoint: the failover continues"
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
export TALOS_ISSUE=7
wt_stub failing
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "checkpoint: a failing verb does not stop the failover"
assert_contains "$(errtxt)" "talos:failover checkpoint-skipped" "checkpoint: a failing verb prints the skip note"
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
wt_stub present
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$(wc -c < "$WT_LOG" | tr -d ' ')" "checkpoint: skipped when TALOS_ISSUE is unset"
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
export TALOS_ISSUE=7
wt_stub present
export STUB_CLAUDE_HOOK="bash '$VCS' comment-issue 7 note >/dev/null"
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$(wc -c < "$WT_LOG" | tr -d ' ')" "checkpoint: not called when the write guard refuses the failover"
unset STUB_CLAUDE_HOOK

# ═══ 10. Chain entries that cannot start ════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["custom", "codex"]}}'
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "unavailable: a custom entry with no runner_cmd is skipped, the next runner runs"
assert_contains "$(errtxt)" "talos:failover role=developer from=custom to=codex reason=unavailable" "unavailable: reason=unavailable line"
assert_eq "" "$(down_until custom)" "unavailable: the skipped runner is never marked down"
reset
set_cfg '{"agents": {"fallback": ["gemini", "codex"]}}'
mkdir -p "$SANDBOX/bin"
for b in claude codex; do ln -sf "$STUBS_DIR/$b" "$SANDBOX/bin/$b"; done
OUT="$(PATH="$SANDBOX/bin:/usr/bin:/bin" STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "the task text" 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "unavailable: a binary not on PATH is skipped"
assert_contains "$(errtxt)" "from=gemini to=codex reason=unavailable" "unavailable: gemini skipped with reason=unavailable"
assert_eq "" "$(down_until gemini)" "unavailable: a missing binary is never marked down"
# custom as a fallback with a runner_cmd works, and its prompt comes on stdin.
reset
set_cfg "{\"agents\": {\"fallback\": [\"custom\"], \"runner_cmd\": \"cat > $SANDBOX/custom.stdin\"}}"
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "custom fallback: runs with the role-first runner_cmd"
assert_eq "$(cat "$STUB_PROMPT_DIR/claude.prompt")" "$(cat "$SANDBOX/custom.stdin")" "custom fallback: same prompt as the primary got"
# custom primary exiting 75 fails over; its own exit code is the contract.
reset
set_cfg '{"agents": {"runner": "custom", "runner_cmd": "exit 75", "fallback": ["codex"]}}'
stage
assert_eq "0" "$RC" "custom primary: exit 75 from runner_cmd is a provider error"
assert_eq "codex-stub-ok" "$OUT" "custom primary: the fallback's output is the stage output"
# the primary is dropped from its own chain with one note
reset
set_cfg '{"agents": {"fallback": ["claude", "codex"]}}'
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "primary in chain: still fails over to the others"
assert_eq "1" "$(grep -c "lists the primary runner 'claude'" "$ERR")" "primary in chain: one note, entry dropped"
assert_eq "1" "$(runner_calls CLAUDE)" "primary in chain: the primary is not retried"

# Per-role fallback beats the global chain.
reset
set_cfg '{"agents": {"fallback": ["codex"], "roles": {"qa": {"fallback": ["gemini"]}}}}'
STUB_CLAUDE_EXIT=75 stage qa
assert_eq "1" "$(runner_calls GEMINI)" "per-role: the role's chain wins"
assert_eq "0" "$(runner_calls CODEX)" "per-role: the global chain is not used for that role"

# ═══ 11. providers.json bookkeeping ═════════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["codex"]}}'
mkdir -p "$SANDBOX/.talos"
printf '{ this is not json' > "$PROV"
stage
assert_eq "0" "$RC" "corrupt providers.json: the stage runs"
assert_eq "1" "$(runner_calls CLAUDE)" "corrupt providers.json: reads as nothing down"
assert_eq "1" "$(grep -c 'unreadable or corrupt' "$ERR")" "corrupt providers.json: exactly one warning"
STUB_CLAUDE_EXIT=75 stage
assert_eq "0" "$RC" "corrupt providers.json: failover still works"
case "$(down_until claude)" in 20*Z) pass "corrupt providers.json: rewritten atomically as valid JSON" ;; *) fail "corrupt providers.json: rewritten atomically as valid JSON" ;; esac
assert_eq "0" "$(ls "$SANDBOX/.talos" | grep -c '\.tmp\.')" "providers.json: no temp file left behind"
assert_eq "0" "$(ls "$SANDBOX/.talos" | grep -c 'lock\.d')" "providers.json: lock released"
# --mark-down
reset
bash "$AGENT" --mark-down codex "provider:429"; assert_eq "0" "$?" "mark-down: exits 0"
case "$(down_until codex)" in 20*Z) pass "mark-down: records the runner with an expiry" ;; *) fail "mark-down: records the runner with an expiry" ;; esac
assert_contains "$(cat "$PROV")" "provider:429" "mark-down: the reason is recorded"
bash "$AGENT" --mark-down bogus "x" >/dev/null 2>&1; assert_eq "2" "$?" "mark-down: unknown runner exits 2"
bash "$AGENT" --mark-down codex >/dev/null 2>&1; assert_eq "2" "$?" "mark-down: missing reason exits 2"
# the same file from a worktree and from the main checkout
reset
git worktree add -q "$SANDBOX/wt" -b wt-branch
( cd "$SANDBOX/wt" && bash "$AGENT" --mark-down pi "provider:exit75" )
case "$(down_until pi)" in 20*Z) pass "providers.json: a worktree writes the main checkout's file" ;; *) fail "providers.json: a worktree writes the main checkout's file" ;; esac
git worktree remove --force "$SANDBOX/wt"
# no git repository: warns, never blocks
NOREPO="$(mktemp -d "${TMPDIR:-/tmp}/talos-norepo.XXXXXX")" || exit 1
out="$(cd "$NOREPO" && bash "$AGENT" --mark-down pi "provider:x" 2>&1)"; rc=$?
rmdir "$NOREPO"
assert_eq "0" "$rc" "no repo: --mark-down still exits 0"
assert_contains "$out" "not in a git repository" "no repo: --mark-down warns"

# ═══ 12. Prompt delivery is unchanged ═══════════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["gemini", "pi", "antigravity"]}}'
STUB_CLAUDE_EXIT=75 STUB_GEMINI_EXIT=75 STUB_PI_EXIT=75 stage
assert_eq "0" "$RC" "argv shapes: the chain walks claude, gemini, pi, antigravity"
assert_contains "$(grep '^GEMINI ARGS' "$RUNNER_LOG")" "[-p]" "argv shapes: gemini keeps -p <prompt>"
assert_contains "$(grep '^PI ARGS' "$RUNNER_LOG")" "[-p]" "argv shapes: pi keeps -p <prompt>"
assert_contains "$(grep '^CLAUDE ARGS' "$RUNNER_LOG")" "[--setting-sources] [project]" "argv shapes: claude keeps --setting-sources project"
for r in gemini pi agy; do
  cmp -s "$STUB_PROMPT_DIR/claude.prompt" "$STUB_PROMPT_DIR/$r.prompt" && pass "prompt identical across the chain ($r)" || fail "prompt identical across the chain ($r)"
done

# ═══ 13. --resolve / --resolve-all ══════════════════════════════════════════
reset
set_cfg '{"agents": {"runner": "claude"}}'
assert_eq "runner=claude runner_cmd= model= effort=" "$(bash "$AGENT" --resolve developer)" "resolve: no chain keeps the exact line"
set_cfg '{"agents": {"fallback": ["codex", "gemini"], "roles": {"qa": {"fallback": ["pi"]}}}}'
assert_eq "runner=claude runner_cmd= model= effort= fallback=codex,gemini" "$(bash "$AGENT" --resolve developer)" "resolve: fallback= appended when a chain is set"
assert_eq "runner=claude runner_cmd= model= effort= fallback=pi" "$(bash "$AGENT" --resolve qa)" "resolve: the role chain wins"
set_cfg '{"agents": {"runner": "codex", "fallback": ["codex", "gemini"]}}'
assert_eq "runner=codex runner_cmd= model= effort= fallback=gemini" "$(bash "$AGENT" --resolve developer 2>/dev/null)" "resolve: the primary is dropped from the shown chain"
set_cfg '{"agents": {"fallback": ["codex"], "roles": {"qa": {"fallback": ["pi"]}}}}'
all="$(bash "$AGENT" --resolve-all 2>/dev/null)"
assert_contains "$(printf '%s\n' "$all" | grep '^role=developer ')" "fallback=codex fallback_origin=project" "resolve-all: fallback and fallback_origin columns"
assert_contains "$(printf '%s\n' "$all" | grep '^role=qa ')" "fallback=pi fallback_origin=project" "resolve-all: the role chain and its origin"
set_cfg '{"agents": {"runner": "custom", "runner_cmd": "echo hi", "fallback": ["codex"]}}'
line="$(bash "$AGENT" --resolve-all 2>/dev/null | grep '^role=developer ')"
assert_eq "runner_cmd=echo hi" "$(printf '%s\n' "$line" | cut -f2-)" "resolve-all: runner_cmd stays last, after its TAB"
assert_contains "$(printf '%s\n' "$line" | cut -f1)" "fallback=codex fallback_origin=project" "resolve-all: the new columns sit before the TAB"
set_cfg '{"agents": {"model": "m"}}'
assert_eq "" "$(bash "$AGENT" --resolve-all 2>/dev/null | grep -c fallback | grep -v '^0$')" "resolve-all: no chain, no new columns"

# ═══ 14. Markers and the events / budget scripts are unaffected ═════════════
m=0; for e in "${TALOS_MARKERS[@]}"; do [ "$e" = "talos:failover" ] && m=1; done
assert_eq "1" "$m" "contract: talos:failover is a TALOS_MARKERS member"
m=0; for e in "${TALOS_MARKERS[@]}"; do [ "$e" = "talos:failover-refused" ] && m=1; done
assert_eq "1" "$m" "contract: talos:failover-refused is a TALOS_MARKERS member"

reset
set_cfg '{"limits": {"tokens_per_issue": 4000000}}'
mkdir -p .talos
printf '%s\n' '{"ts": "2026-10-03T00:00:00Z", "event": "qa", "role": "qa", "issue": 7, "pr": null, "verdict": "PASS", "tokens": 1000, "tool_uses": null, "duration_s": null}' \
  '{"ts": "2026-10-03T00:00:01Z", "event": "qa", "role": "dev", "issue": 7, "pr": null, "verdict": "PASS", "tokens": null, "tool_uses": null, "duration_s": null}' > "$EVENTS"
cost_before="$(bash "$TALOS_ROOT/scripts/pipeline-events.sh" cost --issue 7 --line 2>&1)"
budget_before="$(bash "$TALOS_ROOT/scripts/pipeline-budget.sh" check --issue 7 2>&1)"
bash "$TALOS_ROOT/scripts/pipeline-hooks.sh" post_stage failover orchestrator 7 --summary "role=developer from=claude to=codex reason=provider:exit75"
assert_eq "1" "$(event_count failover)" "events: the failover event was appended"
assert_eq "$cost_before" "$(bash "$TALOS_ROOT/scripts/pipeline-events.sh" cost --issue 7 --line 2>&1)" "events: the cost line (totals, unrecorded) is identical with and without the failover event"
assert_eq "$budget_before" "$(bash "$TALOS_ROOT/scripts/pipeline-budget.sh" check --issue 7 2>&1)" "budget: used and unrecorded are identical with and without the failover event"
# post_stage --runner: names the runner, model null; without the flag nothing changes.
set_cfg '{"agents": {"runner": "claude", "model": "sonnet"}}'
bash "$TALOS_ROOT/scripts/pipeline-hooks.sh" post_stage stage_complete developer 7 --verdict PASS
assert_eq "claude" "$(event_field stage_complete runner)" "hooks: without --runner the event names agents.runner"
assert_eq "sonnet" "$(event_field stage_complete model)" "hooks: without --runner the model chain is unchanged"
bash "$TALOS_ROOT/scripts/pipeline-hooks.sh" post_stage stage_complete developer 7 --verdict PASS --runner codex
assert_eq "codex" "$(event_field stage_complete runner)" "hooks: --runner names the runner that ran"
assert_eq "<none>" "$(event_field stage_complete model)" "hooks: --runner without --model records a null model"
bash "$TALOS_ROOT/scripts/pipeline-hooks.sh" post_stage stage_complete developer 7 --verdict PASS --runner codex --model gpt-x
assert_eq "gpt-x" "$(event_field stage_complete model)" "hooks: --runner with --model records that model"

# ═══ 15. Source hygiene ═════════════════════════════════════════════════════
if grep -nE 'python3 +-[a-zA-Z]*c |python3 +-( |$)|python3 +<<' "$TALOS_ROOT/scripts/pipeline-agent.sh" | grep -v 'python3 -I' >/dev/null; then
  fail "hygiene: every python3 call in pipeline-agent.sh is -I"
else
  pass "hygiene: every python3 call in pipeline-agent.sh is -I"
fi

finish
