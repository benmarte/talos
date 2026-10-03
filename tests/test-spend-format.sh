#!/usr/bin/env bash
# test-spend-format.sh -- scripts/pipeline-spend-format.py and the cost hardening (#393):
#   (a) the module directly: fmt_num / fmt_dur / role_label / role_abbrev /
#       as_count at each boundary, imported by explicit path under `python3 -I`
#   (b) non-finite and non-numeric token values (Infinity, NaN, strings,
#       booleans, negatives) never crash `cost` (table, --json, --line): they
#       are unrecorded, and --json is strict JSON
#   (c) `cost --issue` / `--pr` take digits only; anything else exits 2 with usage
#   (d) `list --json` is still one JSON object per line
#   (e) a missing module degrades silently: `cost --line` prints nothing, exits 0
#   (f) the import writes no __pycache__ next to the module
#   (#383) fmt_compact, model_family / model_summary, md_cell, warn_percent,
#   parse_budget and fmt_budget / fmt_budget_suffix, at their boundaries
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
MODULE_DIR="$TALOS_ROOT/scripts"
LOG="$SANDBOX/.talos/events.jsonl"
mkdir -p "$SANDBOX/.talos"

# fmt EXPR -- evaluate a python expression with the module's functions bound
# as m.<name>, importing by explicit path the way pipeline-events.sh does
# (-I ignores PYTHONPATH and the script dir).
fmt() {
  python3 -I -B -c '
import importlib, sys
sys.path.insert(0, sys.argv[1])
m = importlib.import_module("pipeline-spend-format")
print(eval(sys.argv[2]))' "$MODULE_DIR" "$1"
}

# ── (a) the module, formatter by formatter ─────────────────────────────────
assert_file_exists "$MODULE_DIR/pipeline-spend-format.py" "module: scripts/pipeline-spend-format.py exists"

for pair in "0:0" "999:999" "1000:1k" "1499:1k" "1500:2k" "999499:999k" \
            "999500:1.00M" "999999:1.00M" "1000000:1.00M" "1004999:1.00M" \
            "1005000:1.01M" "3411000:3.41M" "4000000:4.00M" "12345678:12.35M"; do
  assert_eq "${pair#*:}" "$(fmt "m.fmt_num(${pair%%:*})")" "fmt_num(${pair%%:*}) = ${pair#*:}"
done

for pair in "0:0s" "45:45s" "59:59s" "60:1m00s" "125:2m05s" "3599:59m59s" \
            "3600:1h00m" "3720:1h02m" "86400:24h00m"; do
  assert_eq "${pair#*:}" "$(fmt "m.fmt_dur(${pair%%:*})")" "fmt_dur(${pair%%:*}) = ${pair#*:}"
done

assert_eq "dev" "$(fmt 'm.role_abbrev("developer")')" "role_abbrev: developer -> dev"
assert_eq "adv sec rev val plan" \
  "$(fmt '" ".join(m.role_abbrev(r) for r in ("adversarial", "security", "reviewer", "validator", "planner"))')" \
  "role_abbrev: the other abbreviations"
assert_eq "qa" "$(fmt 'm.role_abbrev("qa")')" "role_abbrev: an unlisted role is kept as is"
assert_eq "unknown" "$(fmt 'm.role_label("")')" "role_label: empty -> unknown"
assert_eq "a_b_c" "$(fmt 'm.role_label("a b\nc")')" "role_label: a space and a newline become _"
assert_eq "talos_x" "$(fmt 'm.role_label("talos:x")')" "role_label: a colon cannot form a talos:<word> marker"

assert_eq "None 0 7 7 None None None None None None" \
  "$(fmt '" ".join(str(m.as_count(v)) for v in (None, 0, 7, 7.9, True, False, -1, float("inf"), float("nan"), "abc"))')" \
  "as_count: null, bool, negative, non-finite and string are unrecorded; floats truncate"
assert_eq "None" "$(fmt 'm.as_count(float("-inf"))')" "as_count: -Infinity is unrecorded"
assert_eq "$(python3 -c 'print(10**400)')" "$(fmt 'm.as_count(10**400)')" "as_count: a huge int does not overflow"

# ── (a2) fmt_compact: fmt_num with trailing zero decimals trimmed (#383) ───
for pair in "0:0" "999:999" "1000:1k" "250000:250k" "999499:999k" "999500:1M" \
            "1000000:1M" "1500000:1.5M" "4000000:4M" "4500000:4.5M" "4120000:4.12M" \
            "4004999:4M" "4005000:4.01M" "10000000:10M" "100000000:100M" "12345678:12.35M"; do
  assert_eq "${pair#*:}" "$(fmt "m.fmt_compact(${pair%%:*})")" "fmt_compact(${pair%%:*}) = ${pair#*:}"
done

# ── (a3) model_family / model_summary (#383) ───────────────────────────────
for pair in "claude-opus-4-1:opus" "OPUS:opus" "sonnet:sonnet" "claude-3-5-Sonnet-20241022:sonnet" \
            "haiku:haiku" "claude-haiku-4-5:haiku" "gpt-5:gpt-5" "sonnet[1m]:sonnet"; do
  assert_eq "${pair#*:}" "$(fmt "m.model_family('${pair%%:*}')")" "model_family(${pair%%:*}) = ${pair#*:}"
done
assert_eq "session default" "$(fmt 'm.model_family(None)')" "model_family: null is session default"
assert_eq "session default" "$(fmt 'm.model_family("")')" "model_family: empty is session default"
assert_eq "session default" "$(fmt 'm.model_family("\x00\x07")')" "model_family: only control characters is session default"
assert_eq "opus" "$(fmt 'm.model_family("opus-sonnet")')" "model_family: the family named first wins"
assert_eq "30" "$(fmt 'len(m.model_family("x" * 31))')" "model_family: a raw value is cut at 30 characters"
assert_eq "29" "$(fmt 'len(m.model_family("x" * 29))')" "model_family: 29 characters stay"
assert_eq "30" "$(fmt 'len(m.model_family("y" * 30))')" "model_family: exactly 30 characters stay"
assert_eq "gpt-5" "$(fmt 'm.model_family("gp\x07t\n-5")')" "model_family: control characters and newlines are removed from a raw value"
assert_eq "sonnet" "$(fmt 'm.model_summary(["sonnet"])')" "model_summary: one model"
assert_eq "sonnet" "$(fmt 'm.model_summary(["sonnet", "claude-sonnet-4", "SONNET"])')" "model_summary: one family, no count"
assert_eq "sonnet ×3, opus ×1" "$(fmt 'm.model_summary(["opus", "sonnet", "sonnet", "sonnet"])')" "model_summary: mixed, count descending"
assert_eq "opus ×1, sonnet ×1" "$(fmt 'm.model_summary(["opus", "sonnet"])')" "model_summary: ties keep first-seen order"
assert_eq "sonnet ×2, session default ×1" "$(fmt 'm.model_summary([None, "sonnet", "sonnet"])')" "model_summary: null counts as session default"
assert_eq "session default" "$(fmt 'm.model_summary([None, None])')" "model_summary: all null"
assert_eq "" "$(fmt 'm.model_summary([])')" "model_summary: no events is empty"

# ── (a4) md_cell, warn_percent (#383) ──────────────────────────────────────
assert_eq 'a\|b' "$(fmt 'm.md_cell("a|b")')" "md_cell: a pipe is escaped"
assert_eq 'a\\\|b' "$(fmt 'm.md_cell("a\\|b")')" "md_cell: a backslash before a pipe cannot unescape it"
assert_eq "a b" "$(fmt 'm.md_cell("a\nb")')" "md_cell: a newline becomes a space"
assert_eq "a b" "$(fmt 'm.md_cell("a\r\nb")')" "md_cell: CRLF becomes one space"
assert_eq "ab" "$(fmt 'm.md_cell("a\x00\x1b\x7fb")')" "md_cell: control characters are stripped"
assert_eq "ab" "$(fmt 'm.md_cell("a‮b")')" "md_cell: a bidi override is stripped"
assert_eq "80" "$(fmt 'm.warn_percent("0.8")')" "warn_percent: 0.8 -> 80"
assert_eq "100" "$(fmt 'm.warn_percent("1.0")')" "warn_percent: 1.0 -> 100"
assert_eq "100" "$(fmt 'm.warn_percent("1")')" "warn_percent: 1 -> 100"
assert_eq "0.001" "$(fmt 'm.warn_percent("1e-05")')" "warn_percent: 1e-05 -> 0.001"
assert_eq "75.5" "$(fmt 'm.warn_percent("0.755")')" "warn_percent: 0.755 -> 75.5"
assert_eq "57" "$(fmt 'm.warn_percent("0.57")')" "warn_percent: 0.57 -> 57, no float artefact"
for bad in "" "0" "-1" "1.5" "abc" "nan" "inf" "1e-400"; do
  assert_eq "80" "$(fmt "m.warn_percent('$bad')")" "warn_percent: '$bad' falls back to 80"
done
assert_eq "80" "$(fmt 'm.warn_percent(None)')" "warn_percent: None falls back to 80"

# ── (a5) parse_budget / fmt_budget / fmt_budget_suffix (#383) ──────────────
# budget JSON EXPR -- evaluate EXPR with the module as m and the parsed JSON as b.
budget() {
  python3 -I -B -c '
import importlib, sys
sys.path.insert(0, sys.argv[1])
m = importlib.import_module("pipeline-spend-format")
b = m.parse_budget(sys.argv[2])
print(eval(sys.argv[3]), end="")' "$MODULE_DIR" "$1" "$2"
}
B_OK='{"status":"ok","issue":7,"pct":77,"effective":4000000}'
B_WARN='{"status":"warn","issue":7,"pct":82,"effective":4000000}'
B_EXC='{"status":"exceeded","issue":7,"pct":100,"effective":4000000}'
assert_eq "ok 77 4000000" "$(budget "$B_OK" '" ".join(str(b[k]) for k in ("status", "pct", "effective"))')" "parse_budget: an ok object"
assert_eq "exceeded 100 8000000" \
  "$(budget '{"status":"exceeded","pct":100,"effective":8000000,"used":9}' '" ".join(str(b[k]) for k in ("status", "pct", "effective"))')" \
  "parse_budget: extra fields are ignored"
for bad in '' '   ' 'not json' '[]' '{}' '{"status":"unknown","issue":7,"reason":"error"}' \
           '{"status":"unknown","issue":7,"reason":"no-events"}' \
           '{"status":"weird","pct":1,"effective":2}' '{"status":"ok","pct":"1","effective":2}' \
           '{"status":"ok","pct":1,"effective":0}' '{"status":"ok","pct":-1,"effective":5}' \
           '{"status":"ok","pct":true,"effective":5}' '{"status":"warn","pct":1.5,"effective":5}' \
           '{"status":"warn","pct":81,"effective":NaN}' '{"status":["ok"],"pct":1,"effective":2}'; do
  assert_eq "None" "$(budget "$bad" 'b')" "parse_budget: '$bad' is None"
done
assert_eq "Budget: 77% of 4M (warn at 80%)" "$(budget "$B_OK" 'm.fmt_budget(b, "0.8")')" "fmt_budget: ok"
assert_eq "⚠ Budget: 82% of 4M (warn at 80%)" "$(budget "$B_WARN" 'm.fmt_budget(b, "0.8")')" "fmt_budget: warn has the warning mark first"
assert_eq "Budget: 100% of 4M (warn at 80%) · ⛔ fix rounds paused for owner OK" "$(budget "$B_EXC" 'm.fmt_budget(b, "0.8")')" "fmt_budget: exceeded names the pause"
assert_eq "Budget: 77% of 4M (warn at 0.001%)" "$(budget "$B_OK" 'm.fmt_budget(b, "1e-05")')" "fmt_budget: warn_at 1e-05"
assert_eq "Budget: 77% of 4M (warn at 100%)" "$(budget "$B_OK" 'm.fmt_budget(b, "1.0")')" "fmt_budget: warn_at 1.0"
assert_eq "" "$(budget "$B_OK" 'm.fmt_budget_suffix(b)')" "fmt_budget_suffix: ok has none"
assert_eq " · budget 82% of 4M" "$(budget "$B_WARN" 'm.fmt_budget_suffix(b)')" "fmt_budget_suffix: warn"
assert_eq " · budget 100% of 4M" "$(budget "$B_EXC" 'm.fmt_budget_suffix(b)')" "fmt_budget_suffix: exceeded"
assert_eq "" "$(budget '' 'm.fmt_budget_suffix(b)')" "fmt_budget_suffix: no budget"
assert_eq "" "$(budget '' 'm.fmt_budget(b, "0.8")')" "fmt_budget: no budget"

# ── (f) importing writes no bytecode next to the module ────────────────────
assert_eq "no" "$([ -d "$MODULE_DIR/__pycache__" ] && echo yes || echo no)" \
  "module: no __pycache__ written next to the module"

# ── (b) bad token values in the log ────────────────────────────────────────
# The raw lines are written by hand: Infinity/NaN are not valid JSON but
# Python's json module reads them, which is how they reach `cost`.
reset_log() { : > "$LOG"; }
raw() { printf '%s\n' "$1" >> "$LOG"; }
good='{"event":"developer","role":"developer","issue":5,"pr":9,"verdict":"PASS","tokens":1500,"tool_uses":3,"duration_s":60,"ts":"2026-10-03T00:00:00Z"}'

# strict_json -- exit 0 only when stdin is strict JSON (no NaN/Infinity).
strict_json() {
  python3 -c '
import json, sys
def bad(c):
    raise ValueError(c)
json.loads(sys.stdin.read(), parse_constant=bad)'
}

for bad in 'Infinity' '-Infinity' 'NaN' '"abc"' 'true' 'false' '-5' '[1]' '{"a":1}' '1e999'; do
  reset_log
  raw "$good"
  raw "{\"event\":\"qa\",\"role\":\"qa\",\"issue\":5,\"pr\":9,\"verdict\":\"PASS\",\"tokens\":$bad,\"tool_uses\":2,\"duration_s\":10,\"ts\":\"2026-10-03T00:00:01Z\"}"

  json="$(bash "$EVENTS" cost --issue 5 --json 2>"$SANDBOX/err.log")"; rc=$?
  assert_eq "0" "$rc" "tokens $bad: cost --json exits 0"
  assert_eq "" "$(grep -c Traceback "$SANDBOX/err.log" | sed 's/^0$//')" "tokens $bad: cost --json prints no traceback"
  printf '%s' "$json" | strict_json 2>/dev/null && ok=1 || ok=0
  assert_eq "1" "$ok" "tokens $bad: cost --json is strict JSON"
  assert_eq "1500 1" \
    "$(printf '%s' "$json" | python3 -c 'import json,sys; t=json.load(sys.stdin)["total"]; print(t["tokens"], t["unrecorded"])')" \
    "tokens $bad: counted as unrecorded, adds 0 tokens"

  table="$(bash "$EVENTS" cost --issue 5 2>"$SANDBOX/err.log")"; rc=$?
  assert_eq "0" "$rc" "tokens $bad: cost table exits 0"
  assert_contains "$table" "TOTAL		2	1500	5	70	1	0" "tokens $bad: table total ignores the bad value"

  line="$(bash "$EVENTS" cost --issue 5 --line 2>"$SANDBOX/err.log")"; rc=$?
  assert_eq "0" "$rc" "tokens $bad: cost --line exits 0"
  assert_eq "" "$(grep -c Traceback "$SANDBOX/err.log" | sed 's/^0$//')" "tokens $bad: cost --line prints no traceback"
  assert_eq "talos: #5 qa done — tokens unrecorded, 2 tools, 10s · issue total 2k (+1 unrecorded) (dev 2k)" "$line" \
    "tokens $bad: cost --line reads it as unrecorded"
done

# bad tool_uses / duration_s are dropped the same way and never crash
reset_log
raw "$good"
raw '{"event":"qa","role":"qa","issue":5,"pr":9,"verdict":"PASS","tokens":10,"tool_uses":"x","duration_s":NaN,"ts":"2026-10-03T00:00:01Z"}'
json="$(bash "$EVENTS" cost --issue 5 --json 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "tool_uses/duration_s junk: cost --json exits 0"
printf '%s' "$json" | strict_json 2>/dev/null && ok=1 || ok=0
assert_eq "1" "$ok" "tool_uses/duration_s junk: cost --json is strict JSON"
assert_eq "3 60" \
  "$(printf '%s' "$json" | python3 -c 'import json,sys; t=json.load(sys.stdin)["total"]; print(t["tool_uses"], t["duration_s"])')" \
  "tool_uses/duration_s junk: adds 0"

# valid logs keep their exact shape (floats stay floats, nothing else moves)
reset_log
raw '{"event":"developer","role":"developer","issue":5,"pr":null,"verdict":"PASS","tokens":100,"tool_uses":1,"duration_s":1.5,"ts":"2026-10-03T00:00:00Z"}'
assert_eq '{"rows": [{"issue": 5, "role": "developer", "events": 1, "tokens": 100, "tool_uses": 1, "duration_s": 1.5, "unrecorded": 0, "restamp": 0}], "total": {"events": 1, "tokens": 100, "tool_uses": 1, "duration_s": 1.5, "unrecorded": 0, "restamp": 0}}' \
  "$(bash "$EVENTS" cost --issue 5 --json 2>/dev/null)" "valid log: cost --json shape unchanged"

# ── (c) digits-only --issue / --pr ─────────────────────────────────────────
reset_log
raw "$good"
for args in "--issue 5;x" "--issue -5" "--issue 5.0" "--issue abc" "--issue 5 --pr 9x" "--pr \$(id)" \
            "--issue ٥" "--issue 5 --pr 1e3"; do
  for mode in "" "--json" "--line"; do
    # shellcheck disable=SC2086
    set -- $args
    case "$mode:$*" in --line:--pr*) set -- --issue 5 "$@" ;; esac
    out="$(bash "$EVENTS" cost "$@" $mode 2>"$SANDBOX/err.log")"; rc=$?
    assert_eq "2" "$rc" "digits-only: cost $args $mode exits 2"
    assert_eq "" "$out" "digits-only: cost $args $mode prints nothing on stdout"
    assert_contains "$(cat "$SANDBOX/err.log")" "Usage: pipeline-events.sh" "digits-only: cost $args $mode prints usage"
  done
done
# values with spaces or newlines, which the loop above cannot word-split
for bad in "5 6" "5
6" ""; do
  out="$(bash "$EVENTS" cost --issue "$bad" --line 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "digits-only: --issue with a space, newline or empty value exits 2"
done
bash "$EVENTS" cost --issue 5 --pr "" --json >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "digits-only: an empty --pr exits 2"
bash "$EVENTS" cost --issue 5 --pr 9 --json >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "digits-only: plain digits still pass"
bash "$EVENTS" cost --json >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "digits-only: omitting both options still works"

# ── (d) list --json: one object per line ───────────────────────────────────
reset_log
for i in 1 2 3; do
  raw "{\"event\":\"budget-blocked\",\"role\":\"orchestrator\",\"issue\":5,\"pr\":null,\"verdict\":\"BLOCKED\",\"tokens\":null,\"tool_uses\":null,\"duration_s\":null,\"ts\":\"2026-10-03T00:00:0${i}Z\"}"
done
out="$(bash "$EVENTS" list --issue 5 --event budget-blocked --json 2>/dev/null)"
assert_eq "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "list --json: one line for each event"
assert_eq "3" "$(printf '%s\n' "$out" | python3 -c 'import json,sys; print(sum(1 for l in sys.stdin if isinstance(json.loads(l), dict)))')" \
  "list --json: every line is one JSON object"

# ── (e) a missing module degrades silently ─────────────────────────────────
reset_log
raw "$good"
cp -R "$TALOS_ROOT/scripts" "$SANDBOX/scripts-nomod"
rm -f "$SANDBOX/scripts-nomod"/*.py
out="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost --issue 5 --line 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "0" "$rc" "module missing: cost --line exits 0"
assert_eq "" "$out" "module missing: cost --line prints nothing on stdout"
assert_eq "" "$(grep -c Traceback "$SANDBOX/err.log" | sed 's/^0$//')" "module missing: no traceback"
assert_eq "1" "$(grep -c . "$SANDBOX/err.log")" "module missing: one note on stderr"
json="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost --issue 5 --json 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "module missing: cost --json still works"
assert_contains "$json" '"tokens": 1500' "module missing: cost --json still reports the tokens"
out="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" list --issue 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "module missing: list still works"

# an unreadable/broken module degrades the same way
printf 'raise RuntimeError("boom")\n' > "$SANDBOX/scripts-nomod/pipeline-spend-format.py"
out="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost --issue 5 --line 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "0" "$rc" "module broken: cost --line exits 0"
assert_eq "" "$out" "module broken: cost --line prints nothing on stdout"
assert_eq "" "$(grep -c Traceback "$SANDBOX/err.log" | sed 's/^0$//')" "module broken: no traceback"

# the copy under the sandbox must not have grown a __pycache__ either
assert_eq "no" "$([ -d "$SANDBOX/scripts-nomod/__pycache__" ] && echo yes || echo no)" \
  "module broken: no __pycache__ written"
assert_eq "no" "$([ -d "$MODULE_DIR/__pycache__" ] && echo yes || echo no)" \
  "cost --line: no __pycache__ written into the real scripts dir"

finish
