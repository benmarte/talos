#!/usr/bin/env bash
# test-events-cost.sh -- per-stage cost accounting (#202, #259):
#   (a) post_stage --tokens/--tool-uses/--duration-s land in the payload and
#       the events log line, unchanged
#   (b) omitting them -> null in both
#   (c) an invalid --tokens value -> null + one stderr note, post_stage still
#       exits 0
#   (d) `pipeline-events.sh cost` sums tokens/tool_uses/duration_s and counts
#       events correctly, grouped by (issue, role), across two issues and
#       four roles
#   (e) --issue filters the cost summary to one issue
#   (f) --json parses and matches the table
#   (g) a null-tokens event is counted in the unrecorded column, not silently
#       folded into a real 0
#   (h) an explicit --tokens 0 event is a real zero, not counted as
#       unrecorded -- a fixture proves null and 0 read differently
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF

# ── (a) --tokens/--tool-uses/--duration-s land in payload + log line ───────
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 1234 --tool-uses 7 --duration-s 12 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "valid tokens/tool-uses: post_stage exits 0"
assert_eq "" "$out" "valid tokens/tool-uses: no stdout"

_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') == 1234 and d.get('tool_uses') == 7 and d.get('duration_s') == 12 else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "valid tokens/tool-uses: the log line carries tokens/tool_uses/duration_s"

# ── (b) Omitted -> null in both ─────────────────────────────────────────────
rm -f .talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') is None and d.get('tool_uses') is None else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "omitted tokens/tool-uses: null in the log line"

# ── (c) Invalid --tokens -> null + one stderr note, still exits 0 ──────────
rm -f .talos/events.jsonl
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens abc 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "invalid --tokens: post_stage still exits 0"
assert_contains "$(cat "$SANDBOX/err.log")" "not a non-negative integer" \
  "invalid --tokens: one stderr note explains the fallback"
_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') is None else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "invalid --tokens: null in the log line, not the bad string"

# ── Fixture log for the cost summary: two issues, four roles, one explicit
# zero-tokens event (validator on issue 42) distinct from the null-tokens
# event (developer on issue 43) ─────────────────────────────────────────────
rm -f .talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 100 --tool-uses 5 --duration-s 10 >/dev/null 2>&1
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 50 --tool-uses 2 --duration-s 5 >/dev/null 2>&1
bash "$HOOKS" post_stage reviewer reviewer 42 --verdict PASS --tokens 200 --tool-uses 1 --duration-s 20 >/dev/null 2>&1
bash "$HOOKS" post_stage validator validator 42 --verdict CONFIRMED --tokens 0 --tool-uses 0 --duration-s 3 >/dev/null 2>&1
bash "$HOOKS" post_stage developer developer 43 --verdict PASS --duration-s 30 >/dev/null 2>&1

# ── (d) cost sums correctly across two issues and four roles ───────────────
out="$(bash "$EVENTS" cost 2>"$SANDBOX/err.log")"
assert_contains "$out" "$(printf '42\tqa\t2\t150\t7\t15\t0')" "cost: issue 42 / qa row sums two events"
assert_contains "$out" "$(printf '42\treviewer\t1\t200\t1\t20\t0')" "cost: issue 42 / reviewer row"
assert_contains "$out" "$(printf '42\tvalidator\t1\t0\t0\t3\t0')" \
  "cost: issue 42 / validator row (explicit --tokens 0 is a real zero, not unrecorded)"
assert_contains "$out" "$(printf '43\tdeveloper\t1\t0\t0\t30\t1')" "cost: issue 43 / developer row (null tokens summed as 0, flagged unrecorded)"
assert_contains "$out" "$(printf 'TOTAL\t\t5\t350\t8\t68\t1')" "cost: TOTAL row sums every group"

# ── Header uses the `unrecorded` column name, not the old `n/a` ────────────
assert_contains "$out" "$(printf 'issue\trole\tevents\ttokens\ttool_uses\tduration_s\tunrecorded')" \
  "cost: table header names the unrecorded column"

# ── (e) --issue filters ─────────────────────────────────────────────────────
out="$(bash "$EVENTS" cost --issue 42 2>"$SANDBOX/err.log")"
assert_not_contains "$out" "developer" "cost --issue 42: excludes issue 43's developer row"
assert_contains "$out" "$(printf 'TOTAL\t\t4\t350\t8\t38\t0')" "cost --issue 42: TOTAL row scoped to issue 42 only"

# ── (f) --json parses and matches the table ─────────────────────────────────
out="$(bash "$EVENTS" cost --json 2>"$SANDBOX/err.log")"
_check="$(printf '%s' "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read().strip())
rows = {(r['issue'], r['role']): r for r in d['rows']}
r42qa = rows.get((42, 'qa'))
r42validator = rows.get((42, 'validator'))
ok = (
    r42qa is not None
    and r42qa['events'] == 2 and r42qa['tokens'] == 150
    and r42qa['tool_uses'] == 7 and r42qa['duration_s'] == 15
    and r42validator is not None
    and r42validator['tokens'] == 0 and r42validator['unrecorded'] == 0
    and d['total']['events'] == 5 and d['total']['tokens'] == 350
    and d['total']['unrecorded'] == 1
)
print('OK' if ok else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "cost --json: parses and matches the table's rows and total, using the unrecorded key"

# ── (g) unrecorded is counted, not silently folded into a real 0 ───────────
out="$(bash "$EVENTS" cost 2>"$SANDBOX/err.log")"
_unrecorded_line="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "43" && $2 == "developer" { print }')"
_unrecorded_count="$(printf '%s' "$_unrecorded_line" | awk -F'\t' '{ print $NF }')"
assert_eq "1" "$_unrecorded_count" "cost: the null-tokens event is flagged in the unrecorded column"

# ── (h) an explicit zero is not flagged as unrecorded ───────────────────────
_zero_line="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "42" && $2 == "validator" { print }')"
_zero_unrecorded_count="$(printf '%s' "$_zero_line" | awk -F'\t' '{ print $NF }')"
assert_eq "0" "$_zero_unrecorded_count" "cost: an explicit --tokens 0 event is not flagged as unrecorded"

finish
