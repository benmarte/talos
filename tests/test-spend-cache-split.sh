#!/usr/bin/env bash
# tests/test-spend-cache-split.sh -- cache reads and cache writes as their own
# numbers on every spend surface (#604, part C of #598). `tokens` keeps its
# meaning (fresh input + output + cache write, cache reads left out); the four
# new event fields are input_tokens, output_tokens, cache_write_tokens and
# cache_read_tokens, and an event without a valid cache_read_tokens is
# "cache-unrecorded", never 0.
#
# One block per acceptance criterion, every assertion label starting with its
# id (AC1 .. AC14; AC15 is prose). The runner blocks (AC1-AC4, AC14) drive
# scripts/pipeline-agent.sh against the stub runners in tests/stubs/, from a
# copy of scripts/ whose pipeline-worktree.sh is a stub; the report blocks write
# their own events log. No real model CLI, no real GitHub.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
mkdir -p "$SANDBOX/tmp"
export TMPDIR="$SANDBOX/tmp"
export TALOS_HOME="$SANDBOX/talos-home"   # an owner's user-level config cannot leak in
unset TALOS_TRANSCRIPT_PATH

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
printf '#!/usr/bin/env bash\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh"
AGENT="$INST/scripts/pipeline-agent.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
BUDGET="$TALOS_ROOT/scripts/pipeline-budget.sh"
STATUS="$TALOS_ROOT/scripts/talos-status.sh"
FIX="$TALOS_ROOT/tests/fixtures/runner-usage"
export RUNNER_LOG="$SANDBOX/runner.log"
OUT_F="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
LOG="$SANDBOX/.git/talos/events.jsonl"
GEN="$SANDBOX/gen"
mkdir -p "$GEN"

reset() {
  rm -rf "${SANDBOX:?}/.talos" "${SANDBOX:?}/.git/talos" "${SANDBOX:?}/talos.pipeline.json"
  mkdir -p "$SANDBOX/.git/talos"
  : > "$RUNNER_LOG"
  unset STUB_CLAUDE_EXIT STUB_CLAUDE_STDERR STUB_CLAUDE_STDOUT STUB_CLAUDE_JSON_FILE STUB_CLAUDE_TEXT_FILE \
        STUB_CODEX_EXIT STUB_CODEX_STDERR STUB_CODEX_STDOUT TALOS_ISSUE TALOS_USAGE_FILE
}
set_cfg() { printf '%s\n' "$1" > "$SANDBOX/talos.pipeline.json"; }
# stage [role] -- one adapter stage for issue 7; stderr in $ERR, exit code in $RC.
stage() { TALOS_ISSUE=7 bash "$AGENT" "${1:-developer}" "the task text" >"$OUT_F" 2>"$ERR"; RC=$?; }
# ev_field <event> <field> -> JSON of the field on the LAST such event,
# <absent> when that event has no such key, <none> when there is no such event.
ev_field() {
  python3 -I - "$LOG" "$1" "$2" <<'PYEOF'
import json, sys
last = None
try:
    lines = open(sys.argv[1]).read().splitlines()
except OSError:
    lines = []
for line in lines:
    e = json.loads(line)
    if e.get("event") == sys.argv[2]:
        last = e
if last is None:
    print("<none>")
elif sys.argv[3] not in last:
    print("<absent>")
else:
    print(json.dumps(last[sys.argv[3]]))
PYEOF
}
# ev_split <event> -> "input output cache_write cache_read" of the last such event.
ev_split() {
  printf '%s %s %s %s' "$(ev_field "$1" input_tokens)" "$(ev_field "$1" output_tokens)" \
    "$(ev_field "$1" cache_write_tokens)" "$(ev_field "$1" cache_read_tokens)"
}
# last_keys -> the key names of the log's last line, comma-separated, in order.
last_keys() { tail -n 1 "$LOG" | python3 -I -c 'import json,sys; print(",".join(json.loads(sys.stdin.read()).keys()))'; }
# usage_marker <runner> -> that runner's talos:usage line(s) from the stage's stderr.
usage_marker() { grep "^talos:usage runner=$1 " "$ERR"; }
# cev ROLE ISSUE PR TOKENS [IN OUT CACHE_WRITE CACHE_READ] -- append one finished
# stage. Without the last four the event has none of the cache keys.
cev() {
  local extra=""
  [ $# -ge 8 ] && extra="\"input_tokens\":$5,\"output_tokens\":$6,\"cache_write_tokens\":$7,\"cache_read_tokens\":$8,"
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"PASS","model":"sonnet","tokens":%s,"tool_uses":1,"duration_s":20,%s"ts":"2026-10-03T00:00:00Z"}\n' \
    "$1" "$1" "$2" "$3" "$4" "$extra" >> "$LOG"
}
# recorded: every run of issue 7 / PR 9 carries the four fields.
recorded() {
  reset
  cev developer 7 9 1000 100 200 700 50000
  cev reviewer 7 9 300 10 20 270 4000
}
# mixed: the same plus a sidecar run (tokens, no cache data) and a codex run (nothing).
mixed() {
  recorded
  cev developer 7 9 500
  cev qa 7 9 null
}
# no_cache: runs with no cache data at all.
no_cache() {
  reset
  cev developer 7 9 500
  cev qa 7 9 null
}
squeeze() { tr -s ' '; }
char_len() { python3 -I -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").rstrip("\n")))'; }

# ═══ AC1: the four fields on stage_complete, modelUsage then top-level usage ═
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-subagent.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "52 310 2800 14900" "$(ev_split stage_complete)" "AC1 modelUsage: input, output, cache write and cache read are per-field sums over every model"
assert_eq "3162" "$(ev_field stage_complete tokens)" "AC1 modelUsage: tokens is what main records (cache reads left out)"
assert_eq '"claude-sonnet-4-5"' "$(ev_field stage_complete model)" "AC1 modelUsage: model is what main records (the busiest model)"
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-usage-only.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "12 210 2500 14000" "$(ev_split stage_complete)" "AC1 no modelUsage: the four fields come from the top-level usage"
assert_eq "2722" "$(ev_field stage_complete tokens)" "AC1 no modelUsage: tokens is what main records"
assert_eq "null" "$(ev_field stage_complete model)" "AC1 no modelUsage: model is what main records (null)"

# ═══ AC2: a missing or invalid cache figure drops only its own field ════════
printf '%s\n' '{"type":"result","result":"done","modelUsage":{"m1":{"inputTokens":4,"outputTokens":5,"cacheCreationInputTokens":6,"cacheReadInputTokens":7},"m2":{"inputTokens":1,"outputTokens":1,"cacheCreationInputTokens":1}}}' > "$GEN/no-cache-read.json"
printf '%s\n' '{"type":"result","result":"done","usage":{"input_tokens":4,"output_tokens":5,"cache_creation_input_tokens":6,"cache_read_input_tokens":"many"}}' > "$GEN/bad-cache-read.json"
printf '%s\n' '{"type":"result","result":"done","modelUsage":{"m1":{"inputTokens":4,"outputTokens":5,"cacheCreationInputTokens":6,"cacheReadInputTokens":7},"m2":{"inputTokens":1,"outputTokens":1,"cacheReadInputTokens":2}}}' > "$GEN/no-cache-write.json"
reset
export STUB_CLAUDE_JSON_FILE="$GEN/no-cache-read.json"
stage
assert_eq "<absent>" "$(ev_field stage_complete cache_read_tokens)" "AC2 no cacheReadInputTokens in one model: the event has no cache_read_tokens key"
assert_eq "18" "$(ev_field stage_complete tokens)" "AC2 no cacheReadInputTokens in one model: tokens is still what main records"
assert_eq "5 6 7" "$(ev_field stage_complete input_tokens) $(ev_field stage_complete output_tokens) $(ev_field stage_complete cache_write_tokens)" "AC2 no cacheReadInputTokens in one model: the other three fields are kept"
reset
export STUB_CLAUDE_JSON_FILE="$GEN/bad-cache-read.json"
stage
assert_eq "4 5 6 <absent>" "$(ev_split stage_complete)" "AC2 a cache read that is not a count: only cache_read_tokens is left out"
assert_eq "15" "$(ev_field stage_complete tokens)" "AC2 a cache read that is not a count: tokens is still what main records"
reset
export STUB_CLAUDE_JSON_FILE="$GEN/no-cache-write.json"
stage
assert_eq "5 6 <absent> 9" "$(ev_split stage_complete)" "AC2 no cacheCreationInputTokens in one model: only cache_write_tokens is left out"
assert_eq "17" "$(ev_field stage_complete tokens)" "AC2 no cacheCreationInputTokens in one model: tokens is still what main records"

# ═══ AC3: the talos:usage line of every attempt of every runner ═════════════
reset
export STUB_CLAUDE_JSON_FILE="$FIX/claude-ok.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "talos:usage runner=claude tokens=2722 input=12 output=210 cache_write=2500 cache_read=14000" "$(usage_marker claude)" "AC3 claude: tokens= unchanged, then input, output, cache_write, cache_read in that order"
reset
set_cfg '{"agents": {"runner": "codex"}}'
stage
assert_eq "talos:usage runner=codex tokens=null input=null output=null cache_write=null cache_read=null" "$(usage_marker codex)" "AC3 codex: every figure is null"
reset
SIDECAR="$SANDBOX/sidecar-runner.sh"
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s" "${SC_BODY:-}" > "$TALOS_USAGE_FILE"\necho custom-ok\nexit "${SC_EXIT:-0}"\n' > "$SIDECAR"
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sh $SIDECAR\"}}"
SC_BODY='{"tokens": 1234, "tool_uses": 7}' stage
assert_eq "talos:usage runner=custom tokens=1234 input=null output=null cache_write=null cache_read=null" "$(usage_marker custom)" "AC3 custom sidecar: tokens, and null for the four it cannot report"
reset
export STUB_CLAUDE_JSON_FILE="$GEN/no-cache-read.json"
stage
assert_eq "talos:usage runner=claude tokens=18 input=5 output=6 cache_write=7 cache_read=null" "$(usage_marker claude)" "AC3 a missing cache read prints cache_read=null"

# ═══ AC4: a flushed stage_attempt carries its own four fields, no carry-over ═
python3 -I - "$FIX/claude-429.json" "$GEN/claude-429-cache.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["usage"].update({"input_tokens": 5, "output_tokens": 0, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 700})
d["modelUsage"] = {"claude-sonnet-4-5": {"inputTokens": 5, "outputTokens": 0, "cacheCreationInputTokens": 30, "cacheReadInputTokens": 700}}
json.dump(d, open(sys.argv[2], "w"))
PYEOF
reset
export STUB_CLAUDE_JSON_FILE="$GEN/claude-429-cache.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-429.txt" STUB_CLAUDE_EXIT=1
set_cfg '{"agents": {"fallback": ["codex"]}}'
stage
assert_eq "35" "$(ev_field stage_attempt tokens)" "AC4 claude->codex: the failed attempt is flushed as a stage_attempt with its tokens"
assert_eq "5 0 30 700" "$(ev_split stage_attempt)" "AC4 claude->codex: the stage_attempt carries the four fields its attempt reported"
assert_eq "<absent> <absent> <absent> <absent>" "$(ev_split stage_complete)" "AC4 claude->codex: nothing carries over into the final stage_complete"
assert_eq "talos:usage runner=codex tokens=null input=null output=null cache_write=null cache_read=null" "$(usage_marker codex)" "AC4 claude->codex: the next attempt's marker starts from null"
reset
DOWN="$SANDBOX/provider-down.sh"
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s" '"'"'{"tokens": 321}'"'"' > "$TALOS_USAGE_FILE"\nexit 75\n' > "$DOWN"
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sh $DOWN\", \"fallback\": [\"claude\"]}}"
export STUB_CLAUDE_JSON_FILE="$FIX/claude-subagent.json" STUB_CLAUDE_TEXT_FILE="$FIX/claude-ok.txt"
stage
assert_eq "321 <absent> <absent> <absent> <absent>" "$(ev_field stage_attempt tokens) $(ev_split stage_attempt)" "AC4 custom->claude: the sidecar attempt has its tokens and none of the four keys"
assert_eq "52 310 2800 14900" "$(ev_split stage_complete)" "AC4 custom->claude: the stage_complete carries the final attempt's four fields"

# ═══ AC5: post_stage flags ══════════════════════════════════════════════════
MAIN_KEYS="event,role,issue,pr,repo,sha,verdict,summary,details,attempt,model,runner,duration_s,tokens,tool_uses"
reset
bash "$HOOKS" post_stage qa qa 7 --pr 9 --verdict PASS --tokens 10 --tool-uses 2 \
  --input-tokens 1 --output-tokens 2 --cache-write-tokens 3 --cache-read-tokens 4 2>"$ERR"
assert_eq "$MAIN_KEYS,input_tokens,output_tokens,cache_write_tokens,cache_read_tokens,ts" "$(last_keys)" "AC5 the four keys follow tool_uses, ts stays last"
assert_eq "1 2 3 4" "$(ev_split qa)" "AC5 the four flags land as integers"
assert_eq "" "$(cat "$ERR")" "AC5 valid values: stderr is silent"
reset
bash "$HOOKS" post_stage merged orchestrator 7 --pr 9 --ci-runs 3 --cache-read-tokens 4 --input-tokens 1 2>/dev/null
assert_eq "$MAIN_KEYS,ci_runs,input_tokens,cache_read_tokens,ts" "$(last_keys)" "AC5 with ci_runs the keys follow it; only the supplied ones are present"
reset
bash "$HOOKS" post_stage qa qa 7 --tokens 10 --cache-read-tokens 4x --cache-write-tokens 3 2>"$ERR"; RC=$?
assert_eq "0" "$RC" "AC5 an invalid value never fails post_stage"
assert_eq "<absent> 3" "$(ev_field qa cache_read_tokens) $(ev_field qa cache_write_tokens)" "AC5 an invalid value is dropped, a valid one next to it is kept"
assert_eq "1" "$(grep -c -- '--cache-read-tokens' "$ERR")" "AC5 an invalid value gives one stderr note naming the flag"
reset
bash "$HOOKS" post_stage qa qa 7 --pr 9 --verdict PASS --tokens 10 --tool-uses 2 2>/dev/null
assert_eq "$MAIN_KEYS,ts" "$(last_keys)" "AC5 without the flags the payload has exactly main's keys"
bash "$HOOKS" post_stage qa qa 7 --input-tokens >/dev/null 2>&1; RC=$?
assert_eq "2" "$RC" "AC5 a flag with no value is a usage error, like --tokens"

# ═══ AC6: cost table and cost --json ════════════════════════════════════════
# cost_json <python expression over d> -- d is the `cost --issue 7 --json` object.
cost_json() {
  bash "$EVENTS" cost --issue 7 --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
row = lambda role: [r for r in d["rows"] if r["role"] == role][0]
split = lambda r: [r.get(k, "<absent>") for k in ("input_tokens", "output_tokens", "cache_write_tokens", "cache_read_tokens", "cache_unrecorded")]
old = lambda r: [r[k] for k in ("events", "tokens", "tool_uses", "duration_s", "unrecorded", "restamp")]
print(json.dumps(eval(sys.argv[1])))' "$1"
}
mixed
printf '{"event":"budget-blocked","role":"orchestrator","issue":7,"pr":null,"verdict":"BLOCKED","tokens":null,"tool_uses":null,"duration_s":null,"ts":"2026-10-03T00:00:00Z"}\n' >> "$LOG"
ROW_KEYS='["issue", "role", "events", "tokens", "tool_uses", "duration_s", "unrecorded", "restamp", "input_tokens", "output_tokens", "cache_write_tokens", "cache_read_tokens", "cache_unrecorded"]'
assert_eq "$ROW_KEYS" "$(cost_json 'list(row("developer").keys())')" "AC6 --json: a row gains the five fields after restamp"
assert_eq "${ROW_KEYS#*, \"role\", }" "$(cost_json 'list(d["total"].keys())' | sed 's/^\[//')" "AC6 --json: the total gains the same five fields after restamp"
assert_eq "[100, 200, 700, 50000, 1]" "$(cost_json 'split(row("developer"))')" "AC6 --json: a field is the sum over the events that carry it; cache_unrecorded counts the ones without a cache read"
assert_eq "[null, null, null, null, 1]" "$(cost_json 'split(row("qa"))')" "AC6 --json: a group where no event carries a field reads null, never 0"
assert_eq "[10, 20, 270, 4000, 0]" "$(cost_json 'split(row("reviewer"))')" "AC6 --json: a fully recorded group has cache_unrecorded 0"
assert_eq "[110, 220, 970, 54000, 2]" "$(cost_json 'split(d["total"])')" "AC6 --json: the total sums the rows (orchestrator rows are not cache-unrecorded stage runs)"
assert_eq "[2, 1500, 2, 40, 0, 0] [1, 0, 1, 20, 1, 0] [5, 1800, 4, 80, 1, 0]" "$(cost_json 'old(row("developer"))') $(cost_json 'old(row("qa"))') $(cost_json 'old(d["total"])')" "AC6 --json: every field main has keeps main's value"
TABLE="$(bash "$EVENTS" cost --issue 7 2>/dev/null)"
TAB="$(printf '\t')"
assert_eq "issue${TAB}role${TAB}events${TAB}tokens${TAB}tool_uses${TAB}duration_s${TAB}unrecorded${TAB}restamp${TAB}input_tokens${TAB}output_tokens${TAB}cache_write_tokens${TAB}cache_read_tokens${TAB}cache_unrecorded" "$(printf '%s\n' "$TABLE" | sed -n 1p)" "AC6 table: the header gains the five columns after restamp"
assert_eq "7${TAB}developer${TAB}2${TAB}1500${TAB}2${TAB}40${TAB}0${TAB}0${TAB}100${TAB}200${TAB}700${TAB}50000${TAB}1" "$(printf '%s\n' "$TABLE" | grep "^7${TAB}developer")" "AC6 table: a recorded row"
assert_eq "7${TAB}qa${TAB}1${TAB}0${TAB}1${TAB}20${TAB}1${TAB}0${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}1" "$(printf '%s\n' "$TABLE" | grep "^7${TAB}qa")" "AC6 table: a null field prints unrecorded"
assert_eq "TOTAL${TAB}${TAB}5${TAB}1800${TAB}4${TAB}80${TAB}1${TAB}0${TAB}110${TAB}220${TAB}970${TAB}54000${TAB}2" "$(printf '%s\n' "$TABLE" | grep '^TOTAL')" "AC6 table: the TOTAL row"
printf '{"event":"merged","role":"orchestrator","issue":7,"pr":9,"verdict":null,"tokens":null,"tool_uses":null,"duration_s":null,"ci_runs":3,"ts":"2026-10-03T00:00:00Z"}\n' >> "$LOG"
assert_eq '["cache_unrecorded", "ci_runs"]' "$(cost_json 'list(row("developer").keys())[-2:]')" "AC6 --json: ci_runs, when present, stays last"
assert_eq "cache_unrecorded${TAB}ci_runs" "$(bash "$EVENTS" cost --issue 7 2>/dev/null | sed -n 1p | cut -f 13-)" "AC6 table: ci_runs, when present, stays the last column"

# ═══ AC7: the budget counts exactly what it counts today ════════════════════
reset
set_cfg '{"limits": {"tokens_per_issue": 2000}}'
bash "$HOOKS" post_stage developer developer 7 --pr 9 --verdict PASS --tokens 1000 \
  --input-tokens 100 --output-tokens 200 --cache-write-tokens 700 --cache-read-tokens 900000000 2>/dev/null
bash "$HOOKS" post_stage qa qa 7 --pr 9 --verdict PASS --tokens 800 \
  --input-tokens 50 --output-tokens 50 --cache-write-tokens 700 --cache-read-tokens 800000000 2>/dev/null
assert_eq "900000000 800000000" "$(ev_field developer cache_read_tokens) $(ev_field qa cache_read_tokens)" "AC7 the log under test carries large cache_read_tokens"
WITH="$(bash "$BUDGET" check --issue 7 --json 2>/dev/null)"; WITH_RC=$?
python3 -I - "$LOG" <<'PYEOF'
import json, sys
out = []
for line in open(sys.argv[1]):
    e = json.loads(line)
    for k in ("input_tokens", "output_tokens", "cache_write_tokens", "cache_read_tokens"):
        e.pop(k, None)
    out.append(json.dumps(e))
open(sys.argv[1], "w").write("".join(l + "\n" for l in out))
PYEOF
WITHOUT="$(bash "$BUDGET" check --issue 7 --json 2>/dev/null)"; WITHOUT_RC=$?
assert_eq "$WITHOUT $WITHOUT_RC" "$WITH $WITH_RC" "AC7 budget check --json is the same with the four fields as without them"
assert_contains "$WITH" '"status": "warn"' "AC7 the status is the one the tokens give (1800 of 2000)"
assert_contains "$WITH" '"used": 1800' "AC7 used leaves the cache reads out"

# ═══ AC8: cost --line ═══════════════════════════════════════════════════════
line() { bash "$EVENTS" cost --issue 7 "$@" --line 2>/dev/null; }
recorded
assert_eq "talos: #7 reviewer done — 300 tokens, 1 tools, 20s · issue total 1k (dev 1k, rev 300) · cache read 54k (not in total), cache write 970 (in total)" "$(line)" "AC8 the cache segment follows the breakdown"
assert_contains "$(line --pr 9)" "PR total 1k (dev 1k, rev 300) · cache read 54k (not in total), cache write 970 (in total)" "AC8 the same with --pr"
mixed
assert_contains "$(line)" "issue total 2k (+1 unrecorded) (dev 2k, rev 300) · cache read 54k (not in total, +2 unrecorded), cache write 970 (in total)" "AC8 cache-unrecorded events next to recorded ones are counted in the segment"
no_cache
assert_eq "talos: #7 qa done — tokens unrecorded, 1 tools, 20s · issue total 500 (+1 unrecorded) (dev 500) · cache reads unrecorded" "$(line)" "AC8 no event with a cache read: cache reads unrecorded"
recorded
set_cfg '{"limits": {"tokens_per_issue": 1500}}'
case "$(line)" in
  *"cache write 970 (in total) · budget 86% of 2k") pass "AC8 the budget suffix comes after the cache segment" ;;
  *) fail "AC8 the budget suffix comes after the cache segment" "$(line)" ;;
esac
reset
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
  cev "stage-with-a-long-name-$i" 7 9 "1${i}000" 1 1 1 2000000
done
LONG="$(line)"
[ "$(printf '%s' "$LONG" | char_len)" -le 200 ] && pass "AC8 a long breakdown: the line stays within 200 characters" \
  || fail "AC8 a long breakdown: the line stays within 200 characters" "$(printf '%s' "$LONG" | char_len): $LONG"
case "$LONG" in
  *"…) · cache read 40.00M (not in total), cache write 20 (in total)") pass "AC8 a long breakdown: the breakdown is cut, the cache segment is whole" ;;
  *) fail "AC8 a long breakdown: the breakdown is cut, the cache segment is whole" "$LONG" ;;
esac

# ═══ AC9: cost --markdown ═══════════════════════════════════════════════════
md() { bash "$EVENTS" cost --issue 7 --pr 9 --markdown 2>/dev/null; }
mixed
MD="$(md)"
assert_contains "$MD" "| stage | model | runs | tokens | cache write | cache read | tool uses | duration | re-stamps | unrecorded |" "AC9 the table gains cache write and cache read right after tokens"
assert_contains "$MD" "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|" "AC9 the alignment row has the two new columns"
assert_contains "$MD" '| `developer` | `sonnet` | 2 | 2k | 700 (+1 unrecorded) | 50k (+1 unrecorded) | 2 | 40s | 0 | 0 |' "AC9 a row with some cache-unrecorded runs: the sum, then (+K unrecorded)"
assert_contains "$MD" '| `reviewer` | `sonnet` | 1 | 300 | 270 | 4k | 1 | 20s | 0 | 0 |' "AC9 a fully recorded row: the compact sums"
assert_contains "$MD" '| `qa` | `sonnet` | 1 | unrecorded | unrecorded | unrecorded | 1 | 20s | 0 | 1 |' "AC9 a row whose runs are all cache-unrecorded: unrecorded"
assert_contains "$MD" "| TOTAL |  | 4 | 2k | 970 (+2 unrecorded) | 54k (+2 unrecorded) | 4 | 1m20s | 0 | 1 |" "AC9 TOTAL carries the two columns"
assert_not_contains "$MD" "no input/output split" "AC9 the footer no longer says no input/output split"
assert_contains "$MD" "fresh input + output + cache write" "AC9 the footer says what tokens and TOTAL are made of"
assert_contains "$(printf '%s\n' "$MD" | grep 'fresh input')" "cache reads not included" "AC9 the footer says cache reads are not included"
recorded
assert_contains "$(md)" "This PR (#9): 1k (1300 tokens, cache reads not included) · cache read 54k, cache write 970" "AC9 This PR: the figure says cache reads are not included and names them next to it"
no_cache
assert_contains "$(md)" "This PR (#9): 500 (500 tokens, cache reads not included) (+1 unrecorded) · cache reads unrecorded" "AC9 This PR with no cache data: cache reads unrecorded"

# ═══ AC10: cost --summary ═══════════════════════════════════════════════════
sm() { bash "$EVENTS" cost --summary "$@" 2>/dev/null; }
recorded
SM="$(sm --issue 7)"
assert_eq "issue PR tokens cache write cache read unrecorded stage models" "$(printf '%s\n' "$SM" | sed -n 2p | squeeze)" "AC10 the table gains cache write and cache read right after tokens"
assert_eq "#7 #9 1k 970 54k 0 dev sonnet · rev sonnet" "$(printf '%s\n' "$SM" | sed -n 3p | squeeze)" "AC10 a fully recorded row"
assert_eq "Total: 1k (cache reads not included) · cache read 54k, cache write 970" "$(printf '%s\n' "$SM" | grep '^Total: ')" "AC10 the Total line says cache reads are not included and names them"
mixed
SM="$(sm --issue 7)"
assert_eq "#7 #9 2k 970 (+2 unrecorded) 54k (+2 unrecorded) 1 dev sonnet · rev sonnet · qa sonnet" "$(printf '%s\n' "$SM" | sed -n 3p | squeeze)" "AC10 a row with some cache-unrecorded runs"
assert_eq "Total: 2k (+1 unrecorded) (cache reads not included) · cache read 54k (+2 unrecorded), cache write 970" "$(printf '%s\n' "$SM" | grep '^Total: ')" "AC10 (+K unrecorded) stays right after the total"
no_cache
SM="$(sm --issue 7)"
assert_eq "#7 #9 500 unrecorded unrecorded 1 dev sonnet · qa sonnet" "$(printf '%s\n' "$SM" | sed -n 3p | squeeze)" "AC10 a row with no cache data reads unrecorded"
assert_eq "Total: 500 (+1 unrecorded) (cache reads not included) · cache reads unrecorded" "$(printf '%s\n' "$SM" | grep '^Total: ')" "AC10 the Total line with no cache data"
reset
MANY=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  cev developer "$i" "$((100 + i))" "${i}000" 1 1 1 1
  MANY="$MANY --issue $i"
done
# shellcheck disable=SC2086
SM="$(sm $MANY)"
assert_eq "20" "$(printf '%s\n' "$SM" | wc -l | tr -d ' ')" "AC10 30 rows: the report is 20 lines, the session line included"
assert_contains "$SM" "+17 more rows: " "AC10 30 rows: the smallest rows fold into one line"
assert_contains "$(printf '%s\n' "$SM" | tail -n 1)" "Orchestrator session: " "AC10 30 rows: the session line is still the last one"

# ═══ AC11: the status line ══════════════════════════════════════════════════
ts_ago() { python3 -I -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)-d.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# sev ROLE VERDICT TOKENS AGO [CACHE_READ] -- a finished stage of issue 7.
sev() {
  local extra=""
  [ -n "${5:-}" ] && extra="\"cache_read_tokens\":$5,"
  printf '{"event":"%s","role":"%s","issue":7,"pr":null,"verdict":"%s","tokens":%s,%s"ts":"%s"}\n' \
    "$1" "$1" "$2" "$3" "$extra" "$(ts_ago "$4")" >> "$LOG"
}
start_dev() { printf '{"event":"stage_start","role":"orchestrator","stage":"developer","issue":7,"pr":null,"ts":"%s"}\n' "$(ts_ago 120)" >> "$LOG"; }
# tr_line FILE ID INPUT OUTPUT CACHE_CREATE CACHE_READ AGO
tr_line() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$(ts_ago "$7")" "$2" "$3" "$4" "$5" "$6" >> "$1"
}
status() { (cd "$SANDBOX" && printf '%s' "${1:-}" | bash "$STATUS" --line 2>/dev/null); }
TR="$SANDBOX/session.jsonl"
mkdir -p "$SANDBOX/session/subagents"
: > "$TR"
tr_line "$TR" before 9000 9000 9000 7 500      # before the stage began: not this stage
tr_line "$TR" m1 10 100 5000 0 100
tr_line "$TR" m1 10 300 5000 99999 100         # the same message id again: counted once, last wins
tr_line "$TR" m2 2 200 0 40000 60
printf '{"type":"user","timestamp":"%s","message":{"content":"hi"}}\n' "$(ts_ago 59)" >> "$TR"
: > "$SANDBOX/session/subagents/agent-a.jsonl"
tr_line "$SANDBOX/session/subagents/agent-a.jsonl" s1 1 700 4000 1 80
tr_line "$SANDBOX/session/subagents/agent-a.jsonl" s2 1 300 0 0 40
STDIN_TR="{\"transcript_path\":\"$TR\"}"
reset
sev validator CONFIRMED 1000 600 20000
sev pm "" 0 500
start_dev
assert_eq "talos #7 developer ●●◐○○○ 1k · cache read 20k" "$(status)" "AC11 recorded cache reads follow the running total"
# live tokens 10514 (as before #604) + 1000 recorded; cache reads 20000 + 99999 + 40000 + 1 + 0
assert_eq "talos #7 developer ●●◐○○○ 12k · cache read 160k" "$(status "$STDIN_TR")" "AC11 a running stage adds the transcript's cache reads since it started (deduped, subagents included); the total is unchanged"
reset
sev validator CONFIRMED 1000 600
sev pm "" 0 500
start_dev
assert_eq "talos #7 developer ●●◐○○○ 12k · cache read 140k" "$(status "$STDIN_TR")" "AC11 no event carries the field: the transcript figure alone"
assert_eq "talos #7 developer ●●◐○○○ 1k" "$(status)" "AC11 no event carries the field and no transcript: no cache segment, never cache read 0"
reset
sev validator CONFIRMED 1000 600 20000
printf '{"event":"failover","role":"orchestrator","issue":7,"pr":null,"verdict":null,"tokens":null,"cache_read_tokens":777777,"ts":"%s"}\n' "$(ts_ago 550)" >> "$LOG"
sev pm "" 0 500
assert_eq "talos #7 developer ●●○○○○ 1k · cache read 20k" "$(status)" "AC11 orchestrator events are left out of the cache reads, like the total"

# ═══ AC12: the orchestrator session line ════════════════════════════════════
# The transcript above: m1 (last figures) + m2 + before = 3 message ids.
recorded
SM="$(TALOS_TRANSCRIPT_PATH="$TR" bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"; RC=$?
assert_eq "Orchestrator session: 3 calls, cache read 140k, cache write 14k, output 10k" "$(printf '%s\n' "$SM" | tail -n 1)" "AC12 the summary ends with the session line: one call per message id with its last figures, this file only"
assert_eq "0" "$RC" "AC12 exit 0"
assert_contains "$SM" "Total: 1k (cache reads not included)" "AC12 the spend report is still printed before it"
BIG="$SANDBOX/big.jsonl"
python3 -I - "$BIG" <<'PYEOF'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b'{"message":{"id":"early","usage":{"input_tokens":1,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n')
    f.seek(64 * 1024 * 1024 + 4096)   # a hole: the file is over the read cap
    f.write(b'\n{"message":{"id":"late","usage":{"input_tokens":1,"output_tokens":7,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000}}}\n')
PYEOF
assert_eq "Orchestrator session: 1 calls, cache read 3k, cache write 2k, output 7 (partial: transcript over 64 MB)" "$(TALOS_TRANSCRIPT_PATH="$BIG" bash "$EVENTS" cost --summary --issue 7 2>/dev/null | tail -n 1)" "AC12 a transcript over the read cap is read from its end and marked partial"
rm -f "$BIG"
# talos.sh summary relays the line: real pipeline-events.sh, the VCS / worktree / notify scripts stubbed.
GS="$SANDBOX/gs"
mkdir -p "$GS"
cp "$TALOS_ROOT"/scripts/* "$GS/"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "list-prs" ] && echo "[]"\nexit 0\n' > "$GS/pipeline-vcs.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/pipeline-worktree.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/pipeline-notify.sh"
set_cfg '{"vcs": {"provider": "github"}}'
RELAY="$(CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_TRANSCRIPT_PATH="$TR" bash "$GS/talos.sh" summary 7 2>/dev/null)"
assert_contains "$RELAY" "cost=Orchestrator session: 3 calls, cache read 140k, cache write 14k, output 10k" "AC12 talos.sh summary relays the session line as a cost= line"

# ═══ AC13: no usable transcript ═════════════════════════════════════════════
recorded
# na <label> -- TALOS_TRANSCRIPT_PATH as exported by the caller (or unset).
na() {
  local out rc
  out="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"; rc=$?
  assert_eq "Orchestrator session: not available 0" "$(printf '%s\n' "$out" | tail -n 1) $rc" "AC13 $1: the line is exactly 'not available', exit 0"
  assert_contains "$out" "Total: 1k (cache reads not included)" "AC13 $1: the report still prints"
}
na "unset"
ln -s "$TR" "$SANDBOX/link.jsonl"
cp "$TR" "$SANDBOX/session.txt"
mkdir -p "$SANDBOX/dir.jsonl"
cp "$TR" "$SANDBOX/locked.jsonl"; chmod 000 "$SANDBOX/locked.jsonl"
TALOS_TRANSCRIPT_PATH="" na "empty"
TALOS_TRANSCRIPT_PATH="session.jsonl" na "a relative path"   # the cwd is $SANDBOX: the file is there
TALOS_TRANSCRIPT_PATH="$SANDBOX/session.txt" na "a path not ending .jsonl"
TALOS_TRANSCRIPT_PATH="$SANDBOX/link.jsonl" na "a symlink"
TALOS_TRANSCRIPT_PATH="$SANDBOX/dir.jsonl" na "a directory"
TALOS_TRANSCRIPT_PATH="$SANDBOX/missing.jsonl" na "a missing file"
if [ "$(id -u)" != "0" ]; then
  TALOS_TRANSCRIPT_PATH="$SANDBOX/locked.jsonl" na "an unreadable file"
fi
chmod 600 "$SANDBOX/locked.jsonl"

# ═══ AC14: runners with no cache data ═══════════════════════════════════════
reset
set_cfg '{"agents": {"runner": "codex"}}'
stage qa
assert_eq "null <absent> <absent> <absent> <absent>" "$(ev_field stage_complete tokens) $(ev_split stage_complete)" "AC14 a codex attempt: none of the four keys"
set_cfg "{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"sh $SIDECAR\"}}"
SC_BODY='{"tokens": 1234, "tool_uses": 7, "cache_read_tokens": 99, "input_tokens": 5}' stage developer
assert_eq "1234 <absent> <absent> <absent> <absent>" "$(ev_field stage_complete tokens) $(ev_split stage_complete)" "AC14 a custom runner's sidecar: tokens, none of the four keys (no new sidecar keys)"
rm -f "$SANDBOX/talos.pipeline.json"
# the call talos.sh done makes for a native subagent total
bash "$HOOKS" post_stage reviewer reviewer 7 --pr 9 --verdict APPROVED --tokens 4000 --tool-uses 3 --duration-s 9 --model sonnet 2>/dev/null
assert_eq "4000 <absent> <absent> <absent> <absent>" "$(ev_field reviewer tokens) $(ev_split reviewer)" "AC14 a native subagent total (done --tokens): none of the four keys"
assert_eq "0" "$(grep -c -- '--cache-read-tokens\|--cache-write-tokens\|--input-tokens\|--output-tokens' "$TALOS_ROOT/scripts/talos.sh")" "AC14 talos.sh done passes none of the four flags"
assert_eq "[null, null, null, null, 3]" "$(cost_json 'split(d["total"])')" "AC14 cost --json: null for the four, every run cache-unrecorded"
assert_contains "$(bash "$EVENTS" cost --issue 7 2>/dev/null | grep '^TOTAL')" "unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}unrecorded${TAB}3" "AC14 cost table: unrecorded"
case "$(line)" in
  *" · cache reads unrecorded") pass "AC14 cost --line: cache reads unrecorded" ;;
  *) fail "AC14 cost --line: cache reads unrecorded" "$(line)" ;;
esac
MD="$(bash "$EVENTS" cost --issue 7 --pr 9 --markdown 2>/dev/null)"
assert_contains "$MD" "| TOTAL |  | 3 | 5k | unrecorded | unrecorded |" "AC14 cost --markdown: unrecorded in both cache columns"
assert_contains "$MD" "· cache reads unrecorded" "AC14 cost --markdown: This PR says cache reads unrecorded"
assert_contains "$(sm --issue 7 | grep '^Total: ')" "(cache reads not included) · cache reads unrecorded" "AC14 cost --summary: cache reads unrecorded"
printf '{"event":"stage_start","role":"orchestrator","stage":"qa","issue":7,"pr":9,"ts":"%s"}\n' "$(ts_ago 30)" >> "$LOG"
assert_not_contains "$(status)" "cache read" "AC14 the status line shows no cache segment"
assert_contains "$(status)" "talos #7 " "AC14 the status line still prints"

finish
