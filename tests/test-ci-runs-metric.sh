#!/usr/bin/env bash
# test-ci-runs-metric.sh -- CI runs per issue (#332, PR 1 of 2):
#   (a) post_stage --ci-runs N lands in the payload and the events log line
#   (b) omitting --ci-runs leaves the payload without a ci_runs key (the
#       pre-#332 payload is unchanged)
#   (c) an invalid --ci-runs value is dropped with one stderr note, exit 0
#   (d) `pipeline-events.sh cost` adds a trailing ci_runs column / field only
#       when at least one matched event carries ci_runs
#   (e) with no such event, the table and --json output are byte-identical to
#       the pre-#332 shape
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF

# ── (a) --ci-runs lands in the log line ──────────────────────────────────────
out="$(bash "$HOOKS" post_stage merged orchestrator 42 --pr 57 --ci-runs 1 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "0" "$rc" "post_stage --ci-runs: exits 0"
assert_eq "" "$out" "post_stage --ci-runs: no stdout"
_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if d.get('ci_runs') == 1 and d.get('event') == 'merged' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "post_stage --ci-runs: the log line carries ci_runs as an integer"

# ── (b) omitted -> no ci_runs key at all ─────────────────────────────────────
rm -f .talos/events.jsonl
bash "$HOOKS" post_stage merged orchestrator 42 --pr 57 >/dev/null 2>"$SANDBOX/err.log"
_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if 'ci_runs' not in d else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "omitted --ci-runs: the payload has no ci_runs key"

# ── (c) invalid value -> dropped, one note, exit 0 ───────────────────────────
rm -f .talos/events.jsonl
bash "$HOOKS" post_stage merged orchestrator 42 --ci-runs abc >/dev/null 2>"$SANDBOX/err.log"; rc=$?
assert_eq "0" "$rc" "invalid --ci-runs: post_stage still exits 0"
assert_contains "$(cat "$SANDBOX/err.log")" "not a non-negative integer" "invalid --ci-runs: one stderr note"
_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if 'ci_runs' not in d else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "invalid --ci-runs: the bad string never reaches the log"

# ── Fixture log: issue 42 has a merged event with ci_runs, issue 43 has none ─
rm -f .talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 100 --tool-uses 2 --duration-s 10 2>/dev/null
bash "$HOOKS" post_stage merged orchestrator 42 --pr 57 --ci-runs 2 2>/dev/null
bash "$HOOKS" post_stage qa qa 43 --verdict PASS --tokens 50 --tool-uses 1 --duration-s 5 2>/dev/null
bash "$HOOKS" post_stage merged orchestrator 43 --pr 58 2>/dev/null

# ── (d) issue 42: ci_runs reported ───────────────────────────────────────────
out="$(bash "$EVENTS" cost --issue 42)"
header="$(printf '%s\n' "$out" | head -1)"
total="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$(printf 'issue\trole\tevents\ttokens\ttool_uses\tduration_s\tunrecorded\trestamp\tci_runs')" "$header" \
  "cost table: ci_runs is a trailing column when an event carries it"
assert_eq "$(printf 'TOTAL\t\t2\t100\t2\t10\t0\t0\t2')" "$total" \
  "cost table: TOTAL row sums ci_runs"
row="$(printf '%s\n' "$out" | grep "orchestrator")"
assert_eq "$(printf '42\torchestrator\t1\t0\t0\t0\t1\t0\t2')" "$row" \
  "cost table: the merged event's row reports ci_runs 2"
row="$(printf '%s\n' "$out" | grep "	qa	")"
assert_eq "$(printf '42\tqa\t1\t100\t2\t10\t0\t0\t0')" "$row" \
  "cost table: a role without the field reads 0"

_check="$(bash "$EVENTS" cost --issue 42 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
orch = [r for r in d['rows'] if r['role'] == 'orchestrator'][0]
print('OK' if orch['ci_runs'] == 2 and d['total']['ci_runs'] == 2 and list(orch)[-1] == 'ci_runs' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "cost --json: ci_runs is a trailing field on rows and total"

# ── (e) issue 43: no ci_runs anywhere -> pre-#332 shape, byte-identical ──────
out="$(bash "$EVENTS" cost --issue 43)"
assert_eq "$(printf 'issue\trole\tevents\ttokens\ttool_uses\tduration_s\tunrecorded\trestamp\n43\torchestrator\t1\t0\t0\t0\t1\t0\n43\tqa\t1\t50\t1\t5\t0\t0\nTOTAL\t\t2\t50\t1\t5\t0\t0')" "$out" \
  "cost table: no ci_runs event -> exactly the pre-#332 columns"
_check="$(bash "$EVENTS" cost --issue 43 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
ok = 'ci_runs' not in d['total'] and all('ci_runs' not in r for r in d['rows'])
print('OK' if ok else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "cost --json: no ci_runs event -> no ci_runs field"

finish
