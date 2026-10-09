#!/usr/bin/env bash
# test-talos-status-line.sh -- covers #550: scripts/talos-status.sh, the one-line
# harness status line.
#
#   talos #<issue> <stage> ●●◐○○○ <tokens>
#
# Dots, in order: validator, pm, developer, review (reviewer/security/adversarial),
# qa, merge. ● done, ◐ running (a `stage_start` event newer than the role's last
# completion), ○ pending; a role switched off in the config is left out.
# Tokens are the issue's non-orchestrator total (recorded events) plus, while a
# stage runs, the usage the harness transcript (stdin JSON `transcript_path`)
# and its subagent transcripts show since that stage started.
#   (a) nothing to print: no log, no active issue, merged issue, not a repo, bad input
#   (b) the dots for every stage state, the stage label, fix rounds
#   (c) roles switched off in the config
#   (d) the token total and its formatting (parity with pipeline-spend-format.py)
#   (e) the issue: from the branch, else the newest event
#   (f) live tokens from the transcript and subagent transcripts
#   (g) bounded work: a big log, a stale stage_start, a hostile log path
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

STATUS="$TALOS_ROOT/scripts/talos-status.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
ERR="$SANDBOX/err.txt"
mkdir -p "$SANDBOX/.git/talos"
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/talos-nogit.XXXXXX")" || exit 1
trap '[ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; [ -n "${NOGIT:-}" ] && rm -rf "$NOGIT"' EXIT

export TALOS_HOME="$SANDBOX/.talos-home"
unset COLUMNS NO_COLOR TALOS_STATUS_DEBUG

# ts_ago SECONDS: a UTC timestamp that many seconds in the past.
ts_ago() { python3 -I -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)-d.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
reset_log() { : > "$LOG"; }
# done_ev ROLE ISSUE VERDICT TOKENS AGO -- a finished stage (event = role).
done_ev() {
  local tok="${4:-null}"
  printf '{"event":"%s","role":"%s","issue":%s,"pr":null,"verdict":"%s","tokens":%s,"ts":"%s"}\n' \
    "$1" "$1" "$2" "$3" "$tok" "$(ts_ago "${5:-100}")" >> "$LOG"
}
# start_ev ROLE ISSUE AGO -- the stage_start event talos.sh writes at dispatch.
start_ev() {
  printf '{"event":"stage_start","role":"orchestrator","stage":"%s","issue":%s,"pr":null,"ts":"%s"}\n' \
    "$1" "$2" "$(ts_ago "${3:-50}")" >> "$LOG"
}
# orch_ev EVENT ISSUE AGO -- an orchestrator lifecycle event (merged, ...).
orch_ev() {
  printf '{"event":"%s","role":"orchestrator","issue":%s,"pr":null,"verdict":null,"tokens":null,"ts":"%s"}\n' \
    "$1" "$2" "$(ts_ago "${3:-10}")" >> "$LOG"
}

# run_status [STDIN-TEXT] -- stdout in $OUT, rc in $RC, stderr in $ERR.
run_status() {
  OUT="$(cd "${RUN_DIR:-$SANDBOX}" && printf '%s' "${STDIN_TEXT:-}" | bash "$STATUS" "$@" 2>"$ERR")"
  RC=$?
}
clear_cfg() { rm -f "$SANDBOX/talos.pipeline.json"; rm -rf "$TALOS_HOME"; }
set_cfg() { printf '%s\n' "$1" > "$SANDBOX/talos.pipeline.json"; }

fmt_ref() {
  python3 -I -B - "$TALOS_ROOT/scripts" "$1" <<'PY'
import importlib, sys
sys.path.insert(0, sys.argv[1])
print(importlib.import_module("pipeline-spend-format").fmt_num(int(sys.argv[2])))
PY
}

# ── (a) nothing to print ────────────────────────────────────────────────────
rm -f "$LOG"
run_status --line
assert_eq "" "$OUT" "no log: nothing on stdout"
assert_eq "0" "$RC" "no log: exit 0"
assert_eq "" "$(cat "$ERR")" "no log: stderr silent"

reset_log
run_status --line
assert_eq "" "$OUT" "empty log: nothing"

reset_log
done_ev developer 7 PR_OPENED 1000 200
orch_ev merged 7 100
run_status --line
assert_eq "" "$OUT" "the newest event's issue is merged: no active issue, nothing"

reset_log
done_ev validator 7 CONFIRMED 100 100
printf 'not json at all\n[1,2]\n{"event":' >> "$LOG"
run_status --line
assert_contains "$OUT" "talos #7 " "malformed lines are skipped, the rest still reads"
assert_eq "0" "$RC" "malformed lines: exit 0"

RUN_DIR="$NOGIT" run_status --line
assert_eq "" "$OUT" "not a git repo: nothing"
assert_eq "0" "$RC" "not a git repo: exit 0"
unset RUN_DIR

run_status --bogus-option
assert_eq "" "$OUT" "an unknown option prints nothing"
assert_eq "0" "$RC" "an unknown option still exits 0"

# --line is the only output: bare invocation prints the same line
reset_log
done_ev validator 7 CONFIRMED 100 100
run_status --line; LINE="$OUT"
run_status
assert_eq "$LINE" "$OUT" "no argument prints the same line as --line"

# ── (b) dots per stage state ────────────────────────────────────────────────
clear_cfg
reset_log
start_ev validator 7 30
run_status --line
assert_eq "talos #7 validator ◐○○○○○" "$OUT" "validator running (stage_start only), no tokens yet"

reset_log
done_ev validator 7 CONFIRMED 30000 300
start_ev pm 7 30
run_status --line
assert_eq "talos #7 pm ●◐○○○○ 30k" "$OUT" "validator done, pm running, tokens so far"

reset_log
done_ev validator 7 CONFIRMED 30000 400
done_ev pm 7 "" 20000 300
done_ev developer 7 PR_OPENED 500000 200
run_status --line
assert_eq "talos #7 reviewer ●●●○○○ 550k" "$OUT" "nothing running: the label is the next pending stage (review comes before qa in the draft order)"

done_ev qa 7 PASS 100000 100
start_ev reviewer 7 20
start_ev security 7 20
run_status --line
assert_eq "talos #7 security ●●●◐●○ 650k" "$OUT" "two stages running: the label is the newest start, the review group is running"

done_ev reviewer 7 APPROVED 40000 15
run_status --line
assert_eq "talos #7 security ●●●◐●○ 690k" "$OUT" "reviewer done, security still running keeps the group running"

done_ev security 7 CLEAR 30000 10
run_status --line
assert_eq "talos #7 merge ●●●●●○ 720k" "$OUT" "all stages done, merge pending"

# A stage that failed is pending again; a new stage_start makes it running.
reset_log
done_ev validator 7 CONFIRMED 100 900
done_ev pm 7 "" 100 800
done_ev developer 7 PR_OPENED 100 700
done_ev qa 7 FAIL 100 600
run_status --line
assert_eq "talos #7 developer ●●○○○○ 400" "$OUT" "a FAIL verdict sends the work back: developer pending again"
start_ev developer 7 400
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 400" "$OUT" "fix round: developer running again, review/qa wait"
start_ev docs 7 300
run_status --line
assert_contains "$OUT" "talos #7 docs " "docs is not a dot but can be the running stage"

# A stage nobody ran (pm skipped, spec already present) is omitted once a later stage has begun.
reset_log
done_ev validator 7 CONFIRMED 100 500
start_ev developer 7 30
run_status --line
assert_eq "talos #7 developer ●◐○○○ 100" "$OUT" "pm never ran but developer has started: the pm dot is omitted"

# ── (c) roles switched off in the config ────────────────────────────────────
reset_log
done_ev validator 7 CONFIRMED 1000 300
done_ev pm 7 "" 0 200
start_ev developer 7 30
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "no config: every default-on role has a dot"
set_cfg '{"roles": {"pm": false}}'
run_status --line
assert_eq "talos #7 developer ●◐○○○ 1k" "$OUT" "roles.pm false: the pm dot is omitted"
set_cfg '{"roles": {"validator": false, "pm": false, "qa": false, "reviewer": false, "security": false}}'
run_status --line
assert_eq "talos #7 developer ◐○ 1k" "$OUT" "validator, pm, qa and the whole review group off: developer and merge remain"
set_cfg '{"roles": {"reviewer": false}}'
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "reviewer off but security on: the review dot stays"
set_cfg '{"roles": {"adversarial": true, "security": false, "reviewer": false}}'
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "adversarial on keeps a review dot"
mkdir -p "$TALOS_HOME"
printf '%s\n' '{"roles": {"pm": false}}' > "$TALOS_HOME/talos.pipeline.json"
rm -f "$SANDBOX/talos.pipeline.json"
run_status --line
assert_eq "talos #7 developer ●◐○○○ 1k" "$OUT" "the global config layer is read too"
set_cfg '{"roles": {"pm": true}}'
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "the project config overrides the global one"
clear_cfg
set_cfg '{not json'
run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "an unreadable config means defaults, never an error"
clear_cfg

# ── (d) token total ─────────────────────────────────────────────────────────
reset_log
done_ev developer 7 PR_OPENED 3000000 500
done_ev qa 7 PASS 411000 400
done_ev qa 7 PASS null 300
orch_ev merged 8 10   # another issue merged: does not hide #7 (newest event is #8's)
done_ev reviewer 7 APPROVED 100 5
printf '{"event":"budget-blocked","role":"orchestrator","issue":7,"tokens":9999999,"ts":"%s"}\n' "$(ts_ago 4)" >> "$LOG"
run_status --line
assert_contains "$OUT" " $(fmt_ref 3411100)" "tokens = the sum of non-orchestrator events, in pipeline-spend-format.py's form (3.41M)"
reset_log
done_ev developer 7 PR_OPENED 999 50
run_status --line
assert_contains "$OUT" " 999" "a small total prints as is"
reset_log
done_ev developer 7 PR_OPENED null 50
run_status --line
case "$OUT" in *" 0") fail "unrecorded tokens are never printed as 0" "$OUT" ;; *) pass "unrecorded tokens are never printed as 0" ;; esac
reset_log
printf '{"event":"developer","role":"developer","issue":7,"tokens":"12","ts":"%s"}\n' "$(ts_ago 5)" >> "$LOG"
printf '{"event":"developer","role":"developer","issue":7,"tokens":-5,"ts":"%s"}\n' "$(ts_ago 5)" >> "$LOG"
run_status --line
case "$OUT" in *" 0"|*" 12"|*" -5") fail "a string or negative token value is unrecorded" "$OUT" ;; *) pass "a string or negative token value is unrecorded" ;; esac

# ── (e) which issue ─────────────────────────────────────────────────────────
reset_log
done_ev developer 5 PR_OPENED 100 500
done_ev developer 9 PR_OPENED 200 100
run_status --line
assert_contains "$OUT" "talos #9 " "no matching branch: the newest event's issue"
BRANCH0="$(git -C "$SANDBOX" symbolic-ref --short HEAD)"
git -C "$SANDBOX" checkout -q -b fix/issue-5-thing
run_status --line
assert_contains "$OUT" "talos #5 " "branch fix/issue-5-...: that issue, even when another event is newer"
git -C "$SANDBOX" checkout -q -b feat/issue-9-x 2>/dev/null
run_status --line
assert_contains "$OUT" "talos #9 " "branch feat/issue-9-...: that issue"
git -C "$SANDBOX" worktree add -q "$SANDBOX/wt5" -b fix/issue-5-wt 2>/dev/null
RUN_DIR="$SANDBOX/wt5" run_status --line
assert_contains "$OUT" "talos #5 " "a linked worktree reads the common log and its own branch"
mkdir -p "$SANDBOX/wt5/sub"
RUN_DIR="$SANDBOX/wt5/sub" run_status --line
assert_contains "$OUT" "talos #5 " "a subdirectory works too"
unset RUN_DIR
git -C "$SANDBOX" checkout -q "$BRANCH0"

# ── (f) live tokens ─────────────────────────────────────────────────────────
TR="$SANDBOX/session.jsonl"
mkdir -p "$SANDBOX/session/subagents"
# tr_line FILE ID INPUT OUTPUT CACHE_CREATE CACHE_READ AGO
tr_line() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$(ts_ago "$7")" "$2" "$3" "$4" "$5" "$6" >> "$1"
}
: > "$TR"
reset_log
done_ev validator 7 CONFIRMED 1000 600
done_ev pm 7 "" 0 500
start_ev developer 7 120
tr_line "$TR" before 9000 9000 9000 0 500        # before the stage began: not this stage
tr_line "$TR" m1 10 100 5000 0 100
tr_line "$TR" m1 10 300 5000 99999 100           # same message id again (streamed): counted once, last wins; cache reads are not counted
tr_line "$TR" m2 2 200 0 40000 60
printf '{"type":"user","timestamp":"%s","message":{"content":"hi"}}\n' "$(ts_ago 59)" >> "$TR"
: > "$SANDBOX/session/subagents/agent-a.jsonl"
tr_line "$SANDBOX/session/subagents/agent-a.jsonl" s1 1 700 4000 0 80
tr_line "$SANDBOX/session/subagents/agent-a.jsonl" s2 1 300 0 0 40
# live = m1 (10+300+5000) + m2 (2+200) + s1 (1+700+4000) + s2 (1+300) = 10514 ; recorded 1000
STDIN_TEXT="{\"transcript_path\":\"$TR\",\"session_id\":\"s\"}" run_status --line
assert_eq "talos #7 developer ●●◐○○○ $(fmt_ref 11514)" "$OUT" "recorded + main transcript + subagent transcripts since stage_start"
tr_line "$TR" m3 0 1000 0 0 5
STDIN_TEXT="{\"transcript_path\":\"$TR\"}" run_status --line
assert_eq "talos #7 developer ●●◐○○○ $(fmt_ref 12514)" "$OUT" "the count rises as the transcript grows"
STDIN_TEXT="{\"transcript_path\":\"$SANDBOX/missing.jsonl\"}" run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "a transcript that does not exist: recorded tokens only"
STDIN_TEXT='{not json' run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "garbage on stdin: recorded tokens only"
STDIN_TEXT="{\"transcript_path\":\"relative/../x\"}" run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "a relative transcript path is ignored"
STDIN_TEXT="{\"transcript_path\":[1]}" run_status --line
assert_eq "talos #7 developer ●●◐○○○ 1k" "$OUT" "a non-string transcript path is ignored"
# No stage running: the transcript is not this issue's, so it is not added.
done_ev developer 7 PR_OPENED 5000 1
STDIN_TEXT="{\"transcript_path\":\"$TR\"}" run_status --line
assert_eq "talos #7 reviewer ●●●○○○ 6k" "$OUT" "no stage running: transcript usage is not added"

# ── (g) bounded work ────────────────────────────────────────────────────────
reset_log
python3 -I - "$LOG" "$(ts_ago 3000)" <<'PY'
import json, sys
log, ts = sys.argv[1:3]
with open(log, "w") as f:
    for i in range(10000):
        f.write(json.dumps({"event": "developer", "role": "developer", "issue": 3 + i % 4,
                            "tokens": 10, "verdict": "PASS", "ts": ts}) + "\n")
PY
start_ev qa 3 5
S0="$(python3 -I -c 'import time; print(time.time())')"
run_status --line
S1="$(python3 -I -c 'import time; print(time.time())')"
assert_contains "$OUT" "talos #3 " "a 10k-event log answers"
FAST="$(python3 -I -c 'import sys; print(1 if float(sys.argv[2])-float(sys.argv[1]) < 2.0 else 0)' "$S0" "$S1")"
assert_eq "1" "$FAST" "a 10k-event log answers well inside a status-line budget"

reset_log
done_ev developer 7 PR_OPENED 100 100
start_ev developer 7 $((60 * 60 * 24))   # a crashed run's marker, a day old
run_status --line
assert_not_contains "$OUT" "◐" "a stage_start older than the stale limit is not running"

rm -f "$LOG"; ln -s /dev/zero "$LOG"
run_status --line
assert_eq "" "$OUT" "a symlinked log is not read"
rm -f "$LOG"
set_cfg '{"events": {"path": "../outside.jsonl"}}'
printf '{"event":"developer","role":"developer","issue":7,"tokens":1,"ts":"%s"}\n' "$(ts_ago 5)" > "$SANDBOX/outside.jsonl"
run_status --line
assert_eq "" "$OUT" "an events.path that leaves the git common dir is refused"
set_cfg '{"events": {"path": "custom/ev.jsonl"}}'
mkdir -p "$SANDBOX/.git/custom"
printf '{"event":"developer","role":"developer","issue":7,"tokens":2000,"verdict":"PASS","ts":"%s"}\n' "$(ts_ago 5)" > "$SANDBOX/.git/custom/ev.jsonl"
run_status --line
assert_eq "talos #7 reviewer ●○○○ 2k" "$OUT" "events.path is honoured under the git common dir"
clear_cfg

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-talos-status-line: %d passed\n' "$_PASS"
