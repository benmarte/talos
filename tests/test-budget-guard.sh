#!/usr/bin/env bash
# test-budget-guard.sh -- covers issue #382 (sub-task 5 of epic #334):
# scripts/pipeline-budget.sh check, the opt-in per-issue token guard.
#   (a) limit unset / 0 / invalid / out of range -> no output, exit 0, and the
#       events log is never read (stub pipeline-events.sh + marker file; a
#       chmod 000 log as a second check, skipped as root)
#   (b) ok / warn / exceeded thresholds against limit 4000000, warn_at 0.8
#   (c) a budget-blocked event grants one more full limit; the marker event is
#       not counted in unrecorded
#   (d) no log / no events for N / events tool failure -> unknown, exit 0
#   (e) usage errors exit 2 (non-numeric or empty N, unknown args)
#   (f) --json fields, warn_at parsed as a float (1.0, 1e-05), leading zeros
#   (g) read-only (log byte-identical), never calls pipeline-vcs.sh, -I python
#   (h) a 10k-event log answers well under CI headroom
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BUDGET="$TALOS_ROOT/scripts/pipeline-budget.sh"
ERR="$SANDBOX/err.txt"

set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# reset_log -- empty the sandbox events log (guarded: only ever the sandbox's).
reset_log() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX/.talos"; }
# seed ISSUE ROLE TOKENS [EVENT] -- append one event line (TOKENS "null" = unrecorded).
seed() {
  mkdir -p .talos
  python3 - "$1" "$2" "$3" "${4:-qa}" <<'PY' >> .talos/events.jsonl
import json, sys
issue, role, tokens, event = sys.argv[1:5]
print(json.dumps({"ts": "2026-10-03T00:00:00Z", "event": event, "role": role,
                  "issue": int(issue), "pr": None, "verdict": "PASS",
                  "tokens": None if tokens == "null" else int(tokens),
                  "tool_uses": None, "duration_s": None}))
PY
}
# run_check <args...> -- stdout in $OUT, rc in $RC, stderr in $ERR.
run_check() { OUT="$(bash "$BUDGET" "$@" 2>"$ERR")"; RC=$?; }

set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'

# ── (b) thresholds ──────────────────────────────────────────────────────────
reset_log; seed 7 dev 3100000
run_check check --issue 7
assert_eq "talos:budget ok issue=7 used=3100000 limit=4000000 effective=4000000 pct=77 unrecorded=0" "$OUT" "3.1M: ok line"
assert_eq "0" "$RC" "3.1M: exit 0"

reset_log; seed 7 dev 3300000
run_check check --issue 7
assert_eq "talos:budget warn issue=7 used=3300000 limit=4000000 effective=4000000 pct=82 unrecorded=0" "$OUT" "3.3M: warn line"
assert_eq "0" "$RC" "3.3M: exit 0"

reset_log; seed 7 dev 3200000
run_check check --issue 7
assert_contains "$OUT" "talos:budget warn" "exactly warn_at x effective (3.2M) is warn"

reset_log; seed 7 dev 4000000
run_check check --issue 7
assert_eq "talos:budget exceeded issue=7 used=4000000 limit=4000000 effective=4000000 pct=100 unrecorded=0" "$OUT" "4.0M: exceeded line"
assert_eq "1" "$RC" "4.0M: exit 1"

# Tokens sum across roles and rows; other issues are not counted.
reset_log; seed 7 dev 1000000; seed 7 qa 1000000; seed 8 dev 9000000
run_check check --issue 7
assert_contains "$OUT" "used=2000000 " "used sums every role for the issue only"

# ── (c) grants ──────────────────────────────────────────────────────────────
reset_log; seed 7 dev 4000000; seed 7 orchestrator null budget-blocked
run_check check --issue 7
assert_eq "talos:budget ok issue=7 used=4000000 limit=4000000 effective=8000000 pct=50 unrecorded=0" "$OUT" "one budget-blocked grant: 4.0M is ok against 8M (marker not in unrecorded)"
assert_eq "0" "$RC" "one grant: exit 0"

seed 7 orchestrator null budget-blocked
seed 7 dev 8000000
run_check check --issue 7
assert_contains "$OUT" "talos:budget exceeded issue=7 used=12000000 limit=4000000 effective=12000000" "two grants: effective is limit x 3"
assert_eq "1" "$RC" "two grants, used at effective: exit 1"

reset_log; seed 7 dev 100; seed 8 orchestrator null budget-blocked
run_check check --issue 7
assert_contains "$OUT" "effective=4000000" "another issue's grant does not count"

# unrecorded counts null-token events, not the orchestrator marker.
reset_log; seed 7 dev 500; seed 7 reviewer null; seed 7 security null; seed 7 orchestrator null budget-blocked
run_check check --issue 7
assert_contains "$OUT" "unrecorded=2" "unrecorded=2 (two null stage events, marker excluded)"

# ── (d) unknown ─────────────────────────────────────────────────────────────
reset_log
run_check check --issue 7
assert_eq "talos:budget unknown issue=7 reason=no-events" "$OUT" "no log: unknown"
assert_eq "0" "$RC" "no log: exit 0"

seed 8 dev 500
run_check check --issue 7
assert_eq "talos:budget unknown issue=7 reason=no-events" "$OUT" "no events for N: unknown"

reset_log; seed 7 orchestrator null budget-blocked
run_check check --issue 7
assert_eq "talos:budget unknown issue=7 reason=no-events" "$OUT" "only a budget-blocked marker reads as no-events"
assert_eq "0" "$RC" "marker-only: exit 0"

run_check check --issue 7 --json
assert_eq "unknown" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" "unknown --json status"

# Events tool failing (outside a git repo) never blocks.
NOGIT="$SANDBOX/nogit"; mkdir -p "$NOGIT"
cp talos.pipeline.json "$NOGIT/talos.pipeline.json"
OUT="$(cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$SANDBOX" bash "$BUDGET" check --issue 7 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "not a git repo: exit 0"
assert_contains "$OUT" "talos:budget unknown issue=7" "not a git repo: unknown"

# ── (e) usage ───────────────────────────────────────────────────────────────
for bad in "" "abc" "7x" "-1" "1.5" "--json"; do
  run_check check --issue "$bad"
  assert_eq "2" "$RC" "usage: --issue '$bad' exits 2"
  assert_eq "" "$OUT" "usage: --issue '$bad' prints nothing on stdout"
done
run_check check;                       assert_eq "2" "$RC" "usage: missing --issue exits 2"
run_check check --issue;               assert_eq "2" "$RC" "usage: --issue without value exits 2"
run_check;                             assert_eq "2" "$RC" "usage: no subcommand exits 2"
run_check bogus --issue 7;             assert_eq "2" "$RC" "usage: unknown subcommand exits 2"
run_check check --issue 7 --bogus;     assert_eq "2" "$RC" "usage: unknown option exits 2"
# A usage error is reported even when the guard is off.
set_cfg '{"agents": {"runner": "claude"}}'
run_check check --issue abc
assert_eq "2" "$RC" "usage error exits 2 with the guard off"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'

# ── (f) --json, warn_at parsing, leading zeros ──────────────────────────────
reset_log; seed 7 dev 3300000; seed 7 reviewer null
run_check check --issue 7 --json
assert_eq "0" "$RC" "--json warn: exit 0"
J="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["status"], d["issue"], d["used"], d["limit"], d["effective"], d["pct"], d["unrecorded"])')"
assert_eq "warn 7 3300000 4000000 4000000 82 1" "$J" "--json carries the same fields as the line"
reset_log; seed 7 dev 4000000
run_check check --issue 7 --json
assert_eq "1" "$RC" "--json exceeded: exit 1"

reset_log; seed 7 dev 3999999
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 1}}'
run_check check --issue 7
assert_contains "$OUT" "talos:budget ok " "warn_at 1 (prints 1.0): just under the limit is ok"
reset_log; seed 7 dev 4000000
run_check check --issue 7
assert_contains "$OUT" "talos:budget exceeded " "warn_at 1: at the limit is exceeded"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.00001}}'
reset_log; seed 7 dev 40
run_check check --issue 7
assert_contains "$OUT" "talos:budget warn " "warn_at 1e-05 parsed as a number"
set_cfg '{"limits": {"tokens_per_issue": 4000000}}'
reset_log; seed 7 dev 3200000
run_check check --issue 7
assert_contains "$OUT" "talos:budget warn " "warn_at unset defaults to 0.8"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 5}}'
run_check check --issue 7
assert_contains "$OUT" "talos:budget warn " "invalid warn_at falls back to 0.8"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'

reset_log; seed 7 dev 3300000
run_check check --issue 007
assert_contains "$OUT" "talos:budget warn issue=7 " "leading zeros normalise (007 -> 7)"

# ── (a) guard off: silent no-op that never reads the log ────────────────────
STUBDIR="$SANDBOX/scripts-copy"
cp -R "$TALOS_ROOT/scripts" "$STUBDIR"
MARKER="$SANDBOX/events-called"
cat > "$STUBDIR/pipeline-events.sh" <<STUB
#!/usr/bin/env bash
: > "$MARKER"
exit 0
STUB
chmod +x "$STUBDIR/pipeline-events.sh"

off_case() {  # $1=label $2=config json
  set_cfg "$2"; rm -f "$MARKER"
  OUT="$(bash "$STUBDIR/pipeline-budget.sh" check --issue 7 2>"$ERR")"; RC=$?
  assert_eq "" "$OUT" "$1: no stdout"
  assert_eq "0" "$RC" "$1: exit 0"
  if [ -e "$MARKER" ]; then fail "$1: events log was not read" "marker exists"; else pass "$1: events log was not read"; fi
}
off_case "limit unset" '{"agents": {"runner": "claude"}}'
off_case "limit 0" '{"limits": {"tokens_per_issue": 0}}'
off_case "limit invalid (negative)" '{"limits": {"tokens_per_issue": -5}}'
off_case "limit invalid (string)" '{"limits": {"tokens_per_issue": "lots"}}'
off_case "limit out of range (1e300)" '{"limits": {"tokens_per_issue": 1e300}}'
assert_contains "$(cat "$ERR")" "tokens_per_issue" "out of range: one warning names the key"
assert_eq "1" "$(wc -l < "$ERR" | tr -d ' ')" "out of range: exactly one warning line"
off_case "limit just above the cap" '{"limits": {"tokens_per_issue": 1000000000000001}}'
OUT="$(bash "$STUBDIR/pipeline-budget.sh" check --issue 7 --json 2>/dev/null)"
assert_eq "" "$OUT" "guard off with --json: still no output"

set_cfg '{"limits": {"tokens_per_issue": 1000000000000000}}'; rm -f "$MARKER"
bash "$STUBDIR/pipeline-budget.sh" check --issue 7 >/dev/null 2>&1
if [ -e "$MARKER" ]; then pass "limit at the cap (10^15) is a valid limit"; else fail "limit at the cap (10^15) is a valid limit"; fi
set_cfg '{"limits": {"tokens_per_issue": 4000000}}'; rm -f "$MARKER"
bash "$STUBDIR/pipeline-budget.sh" check --issue 7 >/dev/null 2>&1
if [ -e "$MARKER" ]; then pass "limit set: the events tool is consulted"; else fail "limit set: the events tool is consulted"; fi

# Second check: an unreadable log with the guard off. Skipped as root.
set_cfg '{"agents": {"runner": "claude"}}'
reset_log; seed 7 dev 1
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 .talos/events.jsonl
  run_check check --issue 7
  assert_eq "" "$OUT" "chmod 000 log, guard off: no stdout"
  assert_eq "0" "$RC" "chmod 000 log, guard off: exit 0"
  assert_eq "" "$(cat "$ERR")" "chmod 000 log, guard off: no stderr"
  chmod 644 .talos/events.jsonl
else
  pass "chmod 000 check skipped (running as root)"
fi

# ── (i) a crash or malformed data never blocks (exit 0, unknown line) ───────
# stub_cost <json> -- the copied events script answers `cost` with <json> and
# `list` with nothing, so the guard sees structurally odd data.
stub_cost() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1" = cost ]; then cat <<'"'"'COSTJSON'"'"'' "$1" 'COSTJSON' 'fi' 'exit 0' \
    > "$STUBDIR/pipeline-events.sh"
}
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'
stub_cost '{"rows": [{"role": "dev", "events": "many", "tokens": 5, "unrecorded": 0}]}'
OUT="$(bash "$STUBDIR/pipeline-budget.sh" check --issue 7 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "internal crash (bad events field): exit 0, not exceeded"
assert_eq "talos:budget unknown issue=7 reason=error" "$OUT" "internal crash: unknown line with reason=error"
OUT="$(bash "$STUBDIR/pipeline-budget.sh" check --issue 7 --json 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "internal crash with --json: exit 0"
assert_eq "unknown error" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["reason"])')" "internal crash with --json: unknown object"

# Negative or non-finite token counts are never added; they read as unrecorded.
stub_cost '{"rows": [{"role": "dev", "events": 1, "tokens": 1000, "unrecorded": 0}, {"role": "qa", "events": 2, "tokens": -999999999, "unrecorded": 0}, {"role": "reviewer", "events": 1, "tokens": NaN, "unrecorded": 0}]}'
OUT="$(bash "$STUBDIR/pipeline-budget.sh" check --issue 7 2>"$ERR")"; RC=$?
assert_eq "talos:budget ok issue=7 used=1000 limit=4000000 effective=4000000 pct=0 unrecorded=3" "$OUT" "negative and non-finite tokens: not added, counted as unrecorded"
assert_eq "0" "$RC" "negative tokens: exit 0"

# ── (g) read-only, no vcs calls, python -I ──────────────────────────────────
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'
reset_log; seed 7 dev 3300000; seed 7 orchestrator null budget-blocked
BEFORE="$(cksum < .talos/events.jsonl)"
run_check check --issue 7
run_check check --issue 7 --json
assert_eq "$BEFORE" "$(cksum < .talos/events.jsonl)" "the events log is byte-identical after a check"

NOCODE="$(grep -v '^[[:space:]]*#' "$BUDGET")"
case "$NOCODE" in *pipeline-vcs.sh*) fail "never calls pipeline-vcs.sh" "found in code";; *) pass "never calls pipeline-vcs.sh";; esac
if printf '%s\n' "$NOCODE" | grep -E 'python3( |$)' | grep -v 'python3 -I' >/dev/null; then
  fail "every python3 call uses -I"
else
  pass "every python3 call uses -I"
fi
case "$NOCODE" in *'set -e'*) fail "no set -e (exit 1 is the signal)";; *) pass "no set -e (exit 1 is the signal)";; esac
if [ -x "$BUDGET" ]; then pass "script is executable"; else fail "script is executable"; fi

# ── (h) 10k-event log under CI headroom ─────────────────────────────────────
reset_log; mkdir -p .talos
python3 - <<'PY' > .talos/events.jsonl
import json
for i in range(10000):
    print(json.dumps({"ts": "2026-10-03T00:00:00Z", "event": "qa", "role": "qa" if i % 2 else "dev",
                      "issue": 7 if i % 10 == 0 else 100 + i % 50, "pr": None, "verdict": "PASS",
                      "tokens": 1000, "tool_uses": 1, "duration_s": 1}))
PY
T0="$(python3 -c 'import time; print(time.time())')"
run_check check --issue 7
T1="$(python3 -c 'import time; print(time.time())')"
ELAPSED="$(python3 -c "print('%.2f' % ($T1 - $T0))")"
assert_contains "$OUT" "talos:budget ok issue=7 used=1000000 " "10k-event log: correct answer"
if python3 -c "import sys; sys.exit(0 if $T1 - $T0 < 5 else 1)"; then
  pass "10k-event log answers in ${ELAPSED}s (< 5s CI headroom; spec target < 1s)"
else
  fail "10k-event log answers in time" "took ${ELAPSED}s"
fi

finish
