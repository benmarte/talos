#!/usr/bin/env bash
# test-events-spend-report.sh -- `pipeline-events.sh cost --markdown` and
# `cost --summary` (#383, sub-task 6 of epic #334), and the `python3 -I`
# hardening of pipeline-events.sh:
#   (a) --markdown layout: header, heading, table, TOTAL, `This PR`, note,
#       orchestrator footnote, no marker
#   (b) per-role numbers and TOTAL equal `cost --json` (programmatic)
#   (c) model column: family, mixed `sonnet ×3, opus ×1`, null `session default`,
#       raw value cut at 30; role/model cells are escaped
#   (d) budget line (ok / warn / exceeded), `--line` suffix only at
#       warn/exceeded, guard off = byte-identical, unknown/garbage = no line
#   (e) comments.header read with `{role}` -> orchestrator
#   (f) --summary rows, pre-PR rows, Top PRs, per-issue and grand totals,
#       <= 20 lines for 10 issues, the empty message
#   (g) empty/missing log, missing module, usage errors
#   (h) a json.py planted in $PWD is never imported; a non-finite sum never
#       reaches --json; list --json is unchanged
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
export TALOS_HOME="$SANDBOX/talos-home"   # an owner's user-level config cannot leak in
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C

EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.talos/events.jsonl"
mkdir -p "$SANDBOX/.talos"

reset_log() { : > "$LOG"; }
set_cfg() { printf '%s\n' "$1" > "$SANDBOX/talos.pipeline.json"; }
clear_cfg() { rm -f "$SANDBOX/talos.pipeline.json"; }

# ev ROLE ISSUE PR TOKENS TOOLS DUR MODEL [VERDICT] -- append one event. Pass
# `null` for a null number; MODEL is a raw JSON value ('"sonnet"', 'null') or
# empty for no model key (an event recorded before #379).
ev() {
  local model=""
  [ -n "$7" ] && model="\"model\":$7,"
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"%s",%s"tokens":%s,"tool_uses":%s,"duration_s":%s,"ts":"2026-10-03T00:00:00Z"}\n' \
    "$1" "$1" "$2" "$3" "${8:-PASS}" "$model" "$4" "$5" "$6" >> "$LOG"
}
blocked() {
  printf '{"event":"budget-blocked","role":"orchestrator","issue":%s,"pr":null,"verdict":"BLOCKED","tokens":null,"tool_uses":null,"duration_s":null,"ts":"2026-10-03T00:00:00Z"}\n' "$1" >> "$LOG"
}

# base_fixture -- issue 7, PR 9: 1.9M tokens recorded, one unrecorded run.
base_fixture() {
  reset_log
  ev validator 7 null 100000 5 60 '"sonnet"'
  ev developer 7 9 900000 20 600 '"claude-sonnet-4-5"'
  ev developer 7 9 300000 10 300 '"sonnet"'
  ev developer 7 9 200000 5 100 '"claude-3-5-sonnet"'
  ev developer 7 9 100000 2 50 '"opus"'
  ev reviewer 7 9 150000 4 90 '"sonnet"'
  ev reviewer 7 9 50000 1 20 '"sonnet"' RESTAMP_PASS
  ev reviewer 7 9 null null 30 ''
  ev qa 7 9 100000 3 45 '"gpt-5-turbo-experimental-long-name-ABCDEFGH"'
  # an orchestrator lifecycle row that is NOT a budget grant
  printf '{"event":"stage-start","role":"orchestrator","issue":7,"pr":null,"verdict":"OK","tokens":null,"tool_uses":null,"duration_s":null,"ts":"2026-10-03T00:00:00Z"}\n' >> "$LOG"
  ev developer 8 11 777 1 1 '"haiku"'
}
md() { bash "$EVENTS" cost --issue "$1" --pr "$2" --markdown 2>"$SANDBOX/err.log"; }

# ── (a) layout ─────────────────────────────────────────────────────────────
base_fixture
OUT="$(md 7 9)"; RC=$?
assert_eq "0" "$RC" "markdown: exit 0"
assert_eq "### Token spend — #7" "$(printf '%s\n' "$OUT" | sed -n 1p)" "markdown: no comments.header -> the heading is the first line"
assert_contains "$OUT" "| stage | model | runs | tokens | tool uses | duration | re-stamps | unrecorded |" "markdown: table header"
assert_contains "$OUT" "| TOTAL |" "markdown: a TOTAL row"
assert_contains "$OUT" "This PR (#9): " "markdown: This PR line"
assert_contains "$OUT" "Tokens as reported by the harness: one total per run, no input/output split, no dollar cost; unrecorded = runs with no usage reported (adapter and pi paths)" "markdown: the note, verbatim"
assert_contains "$OUT" "Orchestrator lifecycle rows" "markdown: the orchestrator footnote"
assert_eq "0" "$(printf '%s' "$OUT" | grep -c 'talos:')" "markdown: no marker (upsert-pr-comment adds it)"
assert_eq "0" "$(printf '%s' "$OUT" | grep -c '^| orchestrator')" "markdown: no orchestrator row"
# order: heading < table header < TOTAL < This PR < note < footnote
ORDER="$(printf '%s\n' "$OUT" | grep -n -e '^### Token spend' -e '^| stage ' -e '^| TOTAL' -e '^This PR' -e '^Tokens as reported' -e '^Orchestrator lifecycle' | cut -d: -f1 | tr '\n' ' ')"
SORTED="$(printf '%s' "$ORDER" | tr ' ' '\n' | grep . | sort -n | tr '\n' ' ')"
assert_eq "$SORTED" "$ORDER" "markdown: sections appear in the specified order"
assert_eq "6" "$(printf '%s' "$ORDER" | wc -w | tr -d ' ')" "markdown: all six sections present once"
# rows are sorted like cost --json (by role)
assert_eq "developer qa reviewer validator" \
  "$(printf '%s\n' "$OUT" | grep '^| .[a-z]' | grep -v '^| stage' | sed 's/^| .\([a-z]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//')" \
  "markdown: one row per stage role, sorted"
assert_contains "$OUT" "This PR (#9): 1.80M (1800000 tokens) (+1 unrecorded)" "markdown: This PR is the PR-scoped sum, with its unrecorded runs"
# without --pr there is no This PR line
OUT_NOPR="$(bash "$EVENTS" cost --issue 7 --markdown 2>/dev/null)"
assert_eq "0" "$(printf '%s' "$OUT_NOPR" | grep -c '^This PR')" "markdown: no --pr, no This PR line"
# a PR with no events
assert_contains "$(md 7 99)" "This PR (#99): no events recorded" "markdown: a PR with no events says so"

# ── (b) numbers equal cost --json ──────────────────────────────────────────
# Tokens and duration cells are compact (fmt_num / fmt_dur), computed from the
# very integers `cost --json` reports: each cell must equal the module's
# formatter applied to the json value; the other columns are exact.
bash "$EVENTS" cost --issue 7 --json > "$SANDBOX/cost.json" 2>/dev/null
printf '%s\n' "$OUT" > "$SANDBOX/md.txt"
CMP="$(python3 -I -B - "$SANDBOX/cost.json" "$SANDBOX/md.txt" "$TALOS_ROOT/scripts" <<'PYEOF'
import importlib, json, sys
sys.path.insert(0, sys.argv[3])
m = importlib.import_module("pipeline-spend-format")
data = json.load(open(sys.argv[1]))
cells = {}
for line in open(sys.argv[2], encoding="utf-8"):
    if line.startswith("| ") and not line.startswith("| stage") and not line.startswith("|---"):
        c = [x.strip() for x in line.strip().strip("|").split(" | ")]
        cells[c[0].strip(chr(96))] = c
def want(events, tokens, tools, dur, restamp, unrecorded):
    return [str(events), m.fmt_num(m.as_count(tokens)), str(tools), m.fmt_dur(m.as_count(dur)), str(restamp), str(unrecorded)]
bad = []
sums = [0] * 6
for r in data["rows"]:
    if r["role"] == "orchestrator":
        if "orchestrator" in cells:
            bad.append("orchestrator row present")
        continue
    exp = want(r["events"], r["tokens"], r["tool_uses"], r["duration_s"], r["restamp"], r["unrecorded"])
    if cells[r["role"]][2:] != exp:
        bad.append("%s: %s != %s" % (r["role"], cells[r["role"]][2:], exp))
    sums = [a + b for a, b in zip(sums, [r["events"], r["tokens"], r["tool_uses"], r["duration_s"], r["restamp"], r["unrecorded"]])]
if cells["TOTAL"][2:] != want(*sums):
    bad.append("TOTAL %s != %s" % (cells["TOTAL"][2:], want(*sums)))
t = data["total"]
if [cells["TOTAL"][i] for i in (3, 4, 5)] != [m.fmt_num(m.as_count(t["tokens"])), str(t["tool_uses"]), m.fmt_dur(m.as_count(t["duration_s"]))]:
    bad.append("TOTAL tokens/tools/duration differ from the --json total")
print("OK" if not bad else "; ".join(bad))
PYEOF
)"
assert_eq "OK" "$CMP" "numbers: every role row and TOTAL equal cost --json through the formatters (orchestrator excluded)"
# a few cells, literally
assert_contains "$OUT" '| `developer` | `sonnet ×3, opus ×1` | 4 | 1.50M | 37 | 17m30s | 0 | 0 |' "cells: the developer row, compact tokens and duration"
assert_contains "$OUT" '| `reviewer` | `sonnet ×2, session default ×1` | 3 | 200k | 5 | 2m20s | 1 | 1 |' "cells: the reviewer row (re-stamp and unrecorded stay integers)"
assert_contains "$OUT" '| TOTAL |  | 9 | 1.90M | 50 | 21m35s | 1 | 1 |' "cells: TOTAL, compact"

# ── (c) the model column ───────────────────────────────────────────────────
assert_contains "$OUT" '| `developer` | `sonnet ×3, opus ×1` | 4 |' "model: mixed families, count descending"
assert_contains "$OUT" '| `reviewer` | `sonnet ×2, session default ×1` | 3 |' "model: a missing model key reads session default"
assert_contains "$OUT" '| `validator` | `sonnet` | 1 |' "model: one family, no count"
assert_contains "$OUT" '| `qa` | `gpt-5-turbo-experimental-long-` | 1 |' "model: an unknown value is cut at 30 characters"
reset_log
ev developer 7 9 10 1 1 'null'
ev qa 7 9 10 1 1 '"haiku"'
ev security 7 9 10 1 1 '"CLAUDE-OPUS-4"'
OUT2="$(md 7 9)"
assert_contains "$OUT2" '| `developer` | `session default` | 1 |' "model: null is session default"
assert_contains "$OUT2" '| `qa` | `haiku` | 1 |' "model: haiku"
assert_contains "$OUT2" '| `security` | `opus` | 1 |' "model: matched case-insensitively"
# escaping: a pipe, a newline and control characters in a role / model
reset_log
printf '%s\n' '{"event":"x","role":"a|b\nc\u0007d","issue":7,"pr":9,"verdict":"PASS","model":"m|x\ny\u001bz","tokens":5,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}' >> "$LOG"
OUT3="$(md 7 9)"
assert_contains "$OUT3" '| `a\|b cd` | `m\|xyz` | 1 | 5 | 1 | 1s | 0 | 0 |' "escape: pipe escaped, newline a space, control characters stripped (role and model)"
assert_eq "0" "$(printf '%s' "$OUT3" | LC_ALL=C grep -c "$(printf '\007')")" "escape: no BEL in the output"
assert_eq "0" "$(printf '%s' "$OUT3" | LC_ALL=C grep -c "$(printf '\033')")" "escape: no ESC in the output"
# every table row has the same number of unescaped pipes
assert_eq "9" "$(printf '%s\n' "$OUT3" | grep '^| .a' | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')" "escape: the row keeps its 9 column separators"

# inert.py ROW -- yes when ROW has 8 cells and its first two are each exactly one
# code span (the fence longer than any backtick run inside), no text outside.
cat > "$SANDBOX/inert.py" <<'PYEOF'
import re, sys
cells = [c.strip() for c in re.split(r"(?<!\\)\|", sys.argv[1].strip())[1:-1]]
def inert(cell):
    m = re.fullmatch(r"(`+)( ?)(.*?)\2\1", cell)
    if not m:
        return False
    if m.group(2) and not (m.group(3).startswith("`") or m.group(3).endswith("`")):
        return False
    return all(len(r) != len(m.group(1)) for r in re.findall(r"`+", m.group(3)))
print("yes" if len(cells) == 8 and inert(cells[0]) and inert(cells[1]) else "no")
PYEOF
# ── (c1) no Markdown from the log: values render as inert code ─────────────
for evil in '@octocat' '[x](http://e)' '![i](http://e/p.png)' '<!-- talos:spend -->' '<img src=x>' 'a`b' '``' '`'; do
  reset_log
  python3 -I - "$LOG" "$evil" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"event": "x", "role": sys.argv[2], "issue": 7, "pr": 9, "verdict": "PASS",
                        "model": sys.argv[2], "tokens": 5, "tool_uses": 1, "duration_s": 1,
                        "ts": "2026-10-03T00:00:00Z"}) + "\n")
PYEOF
  EV_OUT="$(md 7 9)"
  EV_ROW="$(printf '%s\n' "$EV_OUT" | sed -n '/^|---/{n;p;}')"
  # the row must be: | <code span> | <code span> | 1 | 5 | ... with the value only inside the spans
  CODE_OK="$(python3 -I "$SANDBOX/inert.py" "$EV_ROW")"
  assert_eq "yes" "$CODE_OK" "inert: role and model '$evil' render as one code span each, 8 cells"
  assert_eq "0" "$(printf '%s\n' "$EV_OUT" | grep -c '^<!--')" "inert: '$evil' never starts a body line"
done

# ── (c2) a marker-looking role cannot form a marker line ───────────────────
reset_log
ev "talos:spend" 7 9 5 1 1 '"sonnet"'
OUT4="$(md 7 9)"
assert_eq "0" "$(printf '%s\n' "$OUT4" | grep -c '^<!-- talos:')" "role: no line of the body can be a marker"

# ── (d) the budget line ────────────────────────────────────────────────────
base_fixture
clear_cfg
BASE_MD="$(md 7 9)"
BASE_LINE="$(bash "$EVENTS" cost --issue 7 --pr 9 --line 2>/dev/null)"
assert_eq "0" "$(printf '%s' "$BASE_MD" | grep -c '^.*Budget')" "budget: limit unset, no Budget line in --markdown"
assert_eq "0" "$(printf '%s' "$BASE_LINE" | grep -c 'budget')" "budget: limit unset, no suffix on --line"

set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.8}}'
assert_eq "0" "$(md 7 9 | grep -c 'paused')" "budget: 47% is not exceeded"
assert_contains "$(md 7 9)" "Budget: 47% of 4M (warn at 80%)" "budget: ok line"
assert_eq "0" "$(md 7 9 | grep -c '⚠')" "budget: no warning mark at ok"
assert_eq "$BASE_LINE" "$(bash "$EVENTS" cost --issue 7 --pr 9 --line 2>/dev/null)" "budget: --line has no suffix at ok"

ev developer 7 9 1380000 1 1 '"sonnet"'      # 3.28M = 82%
WARN_MD="$(md 7 9)"
assert_contains "$WARN_MD" "⚠ Budget: 82% of 4M (warn at 80%)" "budget: warn line with the warning mark"
assert_eq "0" "$(printf '%s' "$WARN_MD" | grep -c 'paused')" "budget: warn does not pause"
WARN_LINE="$(bash "$EVENTS" cost --issue 7 --pr 9 --line 2>/dev/null)"
assert_eq "talos: #9 developer done — 1.38M tokens, 1 tools, 1s · PR total 3.18M (+1 unrecorded) (dev 2.88M, rev 200k, qa 100k) · budget 82% of 4M" "$WARN_LINE" "budget: --line gains ' · budget 82% of 4M' at warn, nothing else changes"
assert_eq "1" "$(printf '%s\n' "$WARN_LINE" | wc -l | tr -d ' ')" "budget: --line is still one line"
assert_eq "yes" "$([ "${#WARN_LINE}" -le 200 ] && echo yes || echo no)" "budget: --line with suffix is <= 200 characters"

ev developer 7 9 1000000 1 1 '"sonnet"'      # 4.28M >= 4M
EXC_MD="$(md 7 9)"
assert_contains "$EXC_MD" "⛔ fix rounds paused for owner OK" "budget: exceeded line"
assert_contains "$EXC_MD" "Budget: 107% of 4M" "budget: exceeded also gives the percentage"
EXC_LINE="$(bash "$EVENTS" cost --issue 7 --pr 9 --line 2>/dev/null)"
case "$EXC_LINE" in *" · budget 107% of 4M") pass "budget: --line gains the suffix at exceeded" ;;
  *) fail "budget: --line gains the suffix at exceeded" "got: $EXC_LINE" ;; esac

# a granted block raises the effective limit: the percentage is of what applies
blocked 7
assert_contains "$(md 7 9)" "Budget: 53% of 8M (warn at 80%)" "budget: a budget-blocked grant doubles the limit shown"

# the budget is per issue: the markdown for issue 8 is not judged by issue 7's total
ev developer 8 11 10 1 1 '"haiku"'
assert_contains "$(md 8 11)" "Budget: 0% of 4M" "budget: judged per issue"

# warn_at parsed numerically
base_fixture
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 1}}'
assert_contains "$(md 7 9)" "(warn at 100%)" "warn_at 1 prints as 100%"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.00001}}'
assert_contains "$(md 7 9)" "(warn at 0.001%)" "warn_at 1e-05 prints as 0.001%"
assert_contains "$(md 7 9)" "⚠ Budget: 47% of 4M" "warn_at 1e-05: used is past the threshold -> warn"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 0.755}}'
assert_contains "$(md 7 9)" "(warn at 75.5%)" "warn_at 0.755 prints as 75.5%"
set_cfg '{"limits": {"tokens_per_issue": 4000000, "warn_at": 5}}'
assert_contains "$(md 7 9)" "(warn at 80%)" "warn_at outside (0, 1] falls back to 80%"

# a stub budget script: empty, garbage, unknown (any reason), crash -> no line, never a failure
cp -R "$TALOS_ROOT/scripts" "$SANDBOX/scripts-stub"
set_cfg '{"limits": {"tokens_per_issue": 4000000}}'
for body in 'exit 0' 'echo "not json"' 'echo "{"' 'echo "[]"' \
            'echo "{\"status\": \"unknown\", \"issue\": 7, \"reason\": \"error\"}"' \
            'echo "{\"status\": \"unknown\", \"issue\": 7, \"reason\": \"no-events\"}"' \
            'echo "{\"status\": \"unknown\", \"issue\": 7, \"reason\": \"events-unavailable\"}"' \
            'echo "{\"status\": \"ok\", \"pct\": \"x\", \"effective\": 5}"' \
            'echo boom >&2; exit 7'; do
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$SANDBOX/scripts-stub/pipeline-budget.sh"
  S_MD="$(bash "$SANDBOX/scripts-stub/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>/dev/null)"; RC=$?
  assert_eq "0" "$RC" "budget stub ($body): --markdown exits 0"
  assert_eq "0" "$(printf '%s' "$S_MD" | grep -c -i 'budget\|unknown')" "budget stub ($body): no Budget line, never the word unknown"
  assert_eq "$BASE_MD" "$S_MD" "budget stub ($body): output equals the no-guard output"
  S_LINE="$(bash "$SANDBOX/scripts-stub/pipeline-events.sh" cost --issue 7 --pr 9 --line 2>/dev/null)"; RC=$?
  assert_eq "0" "$RC" "budget stub ($body): --line exits 0"
  assert_eq "$BASE_LINE" "$S_LINE" "budget stub ($body): --line has no suffix"
done
# the exit code of budget (1 = exceeded) is never trusted
printf '#!/usr/bin/env bash\necho "{\\"status\\": \\"exceeded\\", \\"issue\\": 7, \\"pct\\": 120, \\"effective\\": 4000000}"\nexit 1\n' > "$SANDBOX/scripts-stub/pipeline-budget.sh"
S_MD="$(bash "$SANDBOX/scripts-stub/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>/dev/null)"; RC=$?
assert_eq "0" "$RC" "budget stub exit 1 (exceeded): --markdown still exits 0"
assert_contains "$S_MD" "Budget: 120% of 4M" "budget stub exit 1: the verdict is read from the JSON"
# a missing budget script is no budget
rm -f "$SANDBOX/scripts-stub/pipeline-budget.sh"
assert_eq "$BASE_MD" "$(bash "$SANDBOX/scripts-stub/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>/dev/null)" "budget script missing: no Budget line"
# the budget script is called with --issue only (the budget is per issue) and only the --json check
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$SANDBOX/budget-calls.log" > "$SANDBOX/scripts-stub/pipeline-budget.sh"
: > "$SANDBOX/budget-calls.log"
bash "$SANDBOX/scripts-stub/pipeline-events.sh" cost --issue 7 --pr 9 --markdown >/dev/null 2>&1
assert_eq "check --issue 7 --json" "$(cat "$SANDBOX/budget-calls.log")" "budget: called once as check --issue N --json"

# ── (e) comments.header ────────────────────────────────────────────────────
base_fixture
clear_cfg
set_cfg '{"comments": {"header": "**Agent:** {role} (talos)"}}'
H_MD="$(md 7 9)"
assert_eq "**Agent:** orchestrator (talos)" "$(printf '%s\n' "$H_MD" | sed -n 1p)" "header: {role} becomes orchestrator, first line"
assert_eq "" "$(printf '%s\n' "$H_MD" | sed -n 2p)" "header: a blank line follows"
assert_eq "### Token spend — #7" "$(printf '%s\n' "$H_MD" | sed -n 3p)" "header: then the heading"
assert_eq "0" "$(printf '%s' "$H_MD" | grep -c '{role}')" "header: no unreplaced {role}"
set_cfg '{"comments": {"header": "Plain header"}}'
assert_eq "Plain header" "$(md 7 9 | sed -n 1p)" "header: a header without {role} is kept"
clear_cfg

# ── (f) --summary ──────────────────────────────────────────────────────────
reset_log
ev validator 7 null 100000 1 1 '"sonnet"'
ev developer 7 9 900000 1 1 '"sonnet"'
ev developer 7 9 100000 1 1 '"opus"'
ev reviewer 7 9 null 1 1 '"sonnet"'
ev developer 8 11 500000 1 1 '"haiku"'
ev developer 8 12 300000 1 1 '"sonnet"'
ev developer 8 13 200000 1 1 '"sonnet"'
ev developer 8 14 50000 1 1 '"sonnet"'
ev planner 8 null null 1 1 ''
blocked 7
ev developer 9 21 999 1 1 '"sonnet"'
SUM="$(bash "$EVENTS" cost --summary --issue 7 --issue 8 2>"$SANDBOX/err.log")"; RC=$?
assert_eq "0" "$RC" "summary: exit 0"
assert_contains "$SUM" "#7 " "summary: issue 7 listed"
assert_eq "0" "$(printf '%s\n' "$SUM" | grep -c '#21')" "summary: an issue not asked for is left out"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c '^#7 .*#9 .*1.00M .*1 .*dev sonnet ×1, opus ×1 · rev sonnet$')" "summary: the PR row (issue, PR, tokens, unrecorded, per-stage models)"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c '^#7 .*pre-PR .*val sonnet$')" "summary: the pre-PR row lists its stage"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c '^#8 .*pre-PR .*plan session default$')" "summary: a null-model stage shows session default"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c 'stage models$')" "summary: the column header is stage models"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c '^#7 .*pre-PR .*100k .*0 .*sonnet')" "summary: a pre-PR row for the null-pr events of issue 7"
assert_eq "1" "$(printf '%s\n' "$SUM" | grep -c '^#8 .*pre-PR .*0 .*1 .*session default')" "summary: pre-PR row with unrecorded tokens and no model"
assert_eq "4" "$(printf '%s\n' "$SUM" | grep -c '^#8 .*#1[1-4] ')" "summary: one row per PR"
assert_eq "0" "$(printf '%s\n' "$SUM" | grep -c 'orchestrator')" "summary: orchestrator events never count"
assert_eq "Top PRs: #9 1.00M, #11 500k, #12 300k" "$(printf '%s\n' "$SUM" | grep '^Top PRs:')" "summary: Top PRs, up to 3, by tokens"
assert_eq "Per issue: #7 1.10M, #8 1.05M" "$(printf '%s\n' "$SUM" | grep '^Per issue:')" "summary: per-issue totals"
assert_eq "Total: 2.15M (+2 unrecorded)" "$(printf '%s\n' "$SUM" | grep '^Total:')" "summary: grand total with unrecorded runs"
assert_eq "yes" "$([ "$(printf '%s\n' "$SUM" | wc -l)" -le 20 ] && echo yes || echo no)" "summary: at most 20 lines"
# --pr does not narrow a summary; --issue order does not matter
assert_eq "$SUM" "$(bash "$EVENTS" cost --summary --issue 8 --issue 7 2>/dev/null)" "summary: the issue order does not change the report"
assert_eq "$SUM" "$(bash "$EVENTS" cost --issue 8 --summary --issue 7 2>/dev/null)" "summary: --summary may sit between the --issue options"
assert_eq "yes" "$(printf '%s\n' "$SUM" | grep -q '·\|—' && echo yes || echo no)" "summary: UTF-8 under LC_ALL=C"

# a stage on several models (incl. null) shows the mix for that stage only, stages in first-seen order
reset_log
ev developer 5 50 1000 1 1 '"sonnet"'
ev qa 5 50 1000 1 1 '"sonnet"'
ev qa 5 50 1000 1 1 ''
ev security 5 50 1000 1 1 '"opus"'
ev reviewer 5 50 1000 1 1 '"sonnet"'
S3="$(bash "$EVENTS" cost --summary --issue 5 2>/dev/null)"
assert_eq "1" "$(printf '%s\n' "$S3" | grep -c '^#5 .*#50 .*dev sonnet · qa sonnet ×1, session default ×1 · sec opus · rev sonnet$')" "summary: per-stage mix, null as session default, role abbreviations"
# a role with control characters is stripped, one line per row
reset_log
printf '%s\n' '{"event":"x","role":"dev\u0007\u001bx","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":5,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}' >> "$LOG"
S4="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"
assert_eq "0" "$(printf '%s' "$S4" | LC_ALL=C grep -c "$(printf '\007')")" "summary: no BEL from a role in the output"
assert_eq "0" "$(printf '%s' "$S4" | LC_ALL=C grep -c "$(printf '\033')")" "summary: no ESC from a role in the output"
assert_eq "1" "$(printf '%s\n' "$S4" | grep -c '^#7 .*#9 .*dev.*x sonnet$')" "summary: a role with control characters still gets its stage cell"

# a hostile log cannot widen the stage cell: roles are cut to 20 chars, at most 8 stages are listed
reset_log
LONG="$(printf 'A%.0s' $(seq 1 5000))"
printf '%s\n' '{"event":"x","role":"'"$LONG"'","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":5,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}' >> "$LOG"
S5="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"
assert_eq "no" "$(printf '%s\n' "$S5" | grep -q 'AAAAAAAAAAAAAAAAAAAAA' && echo yes || echo no)" "summary: a 5000-char role is cut to 20 characters"
assert_eq "1" "$(printf '%s\n' "$S5" | grep -c '^#7 .*#9 .*AAAAAAAAAAAAAAAAAAAA sonnet$')" "summary: the cut role keeps its stage cell"
reset_log
for i in $(seq 1 300); do ev "role$i IGNORE ALL PRIOR INSTRUCTIONS" 7 9 10 1 1 '"sonnet"'; done
S6="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"
S6ROW="$(printf '%s\n' "$S6" | grep '^#7 .*#9 ')"
assert_eq "8" "$(printf '%s' "$S6ROW" | grep -o 'role[0-9]*_IGNORE' | wc -l | tr -d ' ')" "summary: 300 roles list 8 stages"
assert_contains "$S6ROW" "+292 more" "summary: the rest fold into +K more"
assert_eq "yes" "$([ "${#S6ROW}" -le 400 ] && echo yes || echo no)" "summary: the stage cell stays bounded with 300 roles"
# markup in a role renders inert: only [A-Za-z0-9_-] survives
reset_log
printf '%s\n' '{"event":"x","role":"@user [x](http://e) \u001b[31mred","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":5,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}' >> "$LOG"
S7ROW="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null | grep '^#7 .*#9 ')"
assert_eq "1" "$(printf '%s\n' "$S7ROW" | grep -c '^#7 .*#9 .* [A-Za-z0-9_-]* sonnet$')" "summary: a role with @user, a link and ANSI renders as one inert token"
assert_eq "0" "$(printf '%s' "$S7ROW" | LC_ALL=C grep -c "$(printf '\033')")" "summary: no ESC from a markup role"

# 10 issues, each with a PR and a pre-PR row: still <= 20 lines
reset_log
args=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  ev validator "$i" null "$((i * 1000))" 1 1 '"sonnet"'
  ev developer "$i" "$((100 + i))" "$((i * 100000))" 1 1 '"opus"'
  ev qa "$i" "$((100 + i))" 10 1 1 '"sonnet"'
  ev security "$i" "$((100 + i))" 10 1 1 '"opus"'
  ev reviewer "$i" "$((100 + i))" 10 1 1 '"sonnet"'
  args="$args --issue $i"
done
# shellcheck disable=SC2086
BIG="$(bash "$EVENTS" cost --summary $args 2>/dev/null)"
assert_eq "yes" "$([ "$(printf '%s\n' "$BIG" | wc -l)" -le 20 ] && echo yes || echo no)" "summary: 10 issues with 2 rows each fit in 20 lines"
assert_contains "$BIG" "Top PRs: #110 1.00M, #109 900k, #108 800k" "summary: Top PRs survive the row cap"
assert_contains "$BIG" "dev opus · qa sonnet · sec opus · rev sonnet" "summary: the stage list is on the PR row, not a second line"
assert_contains "$BIG" "Total: 5.56M" "summary: the grand total counts every row, even folded ones"
assert_eq "1" "$(printf '%s\n' "$BIG" | grep -c 'more row')" "summary: folded rows are announced once"
assert_eq "10" "$(printf '%s\n' "$BIG" | grep '^Per issue:' | grep -o '#[0-9]* ' | wc -l | tr -d ' ')" "summary: per-issue totals list all 10 issues"
# role/model/pr strings from the log are sanitised in the summary too
reset_log
printf '%s\n' '{"event":"x","role":"developer","issue":7,"pr":"9\u0007x","verdict":"PASS","model":"m\u001bz","tokens":5,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}' >> "$LOG"
S2="$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)"
assert_eq "0" "$(printf '%s' "$S2" | LC_ALL=C grep -c "$(printf '\007')")" "summary: no BEL in the output"
assert_eq "0" "$(printf '%s' "$S2" | LC_ALL=C grep -c "$(printf '\033')")" "summary: no ESC in the output"

# ── (g) empty / missing log, module, usage ─────────────────────────────────
rm -f "$LOG"
OUT="$(bash "$EVENTS" cost --issue 7 --pr 9 --markdown 2>"$SANDBOX/err.log")"; RC=$?
assert_eq "0" "$RC" "missing log: --markdown exits 0"
assert_eq "" "$OUT" "missing log: --markdown prints nothing"
OUT="$(bash "$EVENTS" cost --summary --issue 7 2>"$SANDBOX/err.log")"; RC=$?
assert_eq "0" "$RC" "missing log: --summary exits 0"
assert_eq "no events recorded for this run" "$OUT" "missing log: --summary says so"
: > "$LOG"
assert_eq "" "$(bash "$EVENTS" cost --issue 7 --pr 9 --markdown 2>/dev/null)" "empty log: --markdown prints nothing"
assert_eq "no events recorded for this run" "$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)" "empty log: --summary says so"
reset_log
blocked 7
assert_eq "" "$(bash "$EVENTS" cost --issue 7 --pr 9 --markdown 2>/dev/null)" "only orchestrator events: --markdown prints nothing"
assert_eq "no events recorded for this run" "$(bash "$EVENTS" cost --summary --issue 7 2>/dev/null)" "only orchestrator events: --summary says so"
base_fixture
assert_eq "" "$(bash "$EVENTS" cost --issue 99 --pr 9 --markdown 2>/dev/null)" "no event for the issue: --markdown prints nothing"
assert_eq "no events recorded for this run" "$(bash "$EVENTS" cost --summary --issue 99 2>/dev/null)" "no event for the issue: --summary says so"

# a missing / broken module: one note on stderr, empty stdout, exit 0; cost and list still work
rm -rf "$SANDBOX/scripts-nomod"; cp -R "$TALOS_ROOT/scripts" "$SANDBOX/scripts-nomod"
rm -f "$SANDBOX/scripts-nomod"/*.py
for mode in "--issue 7 --pr 9 --markdown" "--summary --issue 7"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost $mode 2>"$SANDBOX/err.log")"; RC=$?
  assert_eq "0" "$RC" "module missing: cost $mode exits 0"
  assert_eq "" "$OUT" "module missing: cost $mode prints nothing on stdout"
  assert_eq "1" "$(grep -c . "$SANDBOX/err.log")" "module missing: cost $mode prints one note on stderr"
  assert_eq "0" "$(grep -c Traceback "$SANDBOX/err.log")" "module missing: cost $mode prints no traceback"
done
assert_contains "$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost --issue 7 --json 2>/dev/null)" '"tokens"' "module missing: cost --json still works"
printf 'raise RuntimeError("boom")\n' > "$SANDBOX/scripts-nomod/pipeline-spend-format.py"
OUT="$(bash "$SANDBOX/scripts-nomod/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>"$SANDBOX/err.log")"; RC=$?
assert_eq "0" "$RC" "module broken: --markdown exits 0"
assert_eq "" "$OUT" "module broken: --markdown prints nothing"
assert_eq "0" "$(grep -c Traceback "$SANDBOX/err.log")" "module broken: no traceback"
assert_eq "no" "$([ -d "$SANDBOX/scripts-nomod/__pycache__" ] && echo yes || echo no)" "module broken: no __pycache__"
assert_eq "no" "$([ -d "$TALOS_ROOT/scripts/__pycache__" ] && echo yes || echo no)" "no __pycache__ written into the real scripts dir"

# usage errors: exit 2 with usage, nothing on stdout
for args in "--markdown" "--pr 9 --markdown" "--summary" "--summary --pr 9" "--markdown --line --issue 7" \
            "--markdown --summary --issue 7" "--issue 7 --summary --line" "--issue 7x --markdown" \
            "--summary --issue 7 --issue 8y" "--markdown --issue" "--summary --issue"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$EVENTS" cost $args 2>"$SANDBOX/err.log")"; RC=$?
  assert_eq "2" "$RC" "usage: cost $args exits 2"
  assert_eq "" "$OUT" "usage: cost $args prints nothing on stdout"
  assert_contains "$(cat "$SANDBOX/err.log")" "Usage: pipeline-events.sh" "usage: cost $args prints usage"
done
assert_contains "$(bash "$EVENTS" bogus 2>&1)" "--markdown" "usage text names --markdown"
assert_contains "$(bash "$EVENTS" bogus 2>&1)" "--summary" "usage text names --summary"

# ── (h) hardening ──────────────────────────────────────────────────────────
# a json.py (or any stdlib name) planted in $PWD must never run: every
# embedded python in pipeline-events.sh is `python3 -I`.
base_fixture
mkdir -p "$SANDBOX/plant"
for mod in json math decimal unicodedata importlib; do
  printf 'import os\nopen(os.environ["PLANT_MARK"], "a").write("%s imported\\n")\n' "$mod" > "$SANDBOX/plant/$mod.py"
done
export PLANT_MARK="$SANDBOX/planted.log"
: > "$PLANT_MARK"
for mode in "list --issue 7" "list --issue 7 --json" "tail --issue 7" "cost --issue 7" "cost --issue 7 --json" \
            "cost --issue 7 --pr 9" "cost --issue 7 --pr 9 --line" "cost --issue 7 --pr 9 --markdown" \
            "cost --summary --issue 7" "path"; do
  # shellcheck disable=SC2086
  ( cd "$SANDBOX/plant" && bash "$EVENTS" $mode >/dev/null 2>&1 )
done
assert_eq "0" "$(wc -l < "$PLANT_MARK" | tr -d ' ')" "hardening: no planted module in \$PWD is imported by any pipeline-events.sh verb"
# and with the repo root itself as the PWD
cp "$SANDBOX/plant/json.py" "$SANDBOX/json.py"
bash "$EVENTS" cost --issue 7 --json >/dev/null 2>&1
bash "$EVENTS" cost --issue 7 --pr 9 --markdown >/dev/null 2>&1
bash "$EVENTS" list --issue 7 >/dev/null 2>&1
assert_eq "0" "$(wc -l < "$PLANT_MARK" | tr -d ' ')" "hardening: a json.py in the working directory is not imported"
rm -f "$SANDBOX/json.py"
# static: no embedded python3 without -I
assert_eq "0" "$(grep -E '^[[:space:]]*(out=\$\(|[a-z_]+=\$\()?python3 ' "$EVENTS" | grep -vc -e 'python3 -I')" "hardening: every python3 call in pipeline-events.sh uses -I"

# a non-finite sum never reaches --json
reset_log
ev developer 7 9 1e308 1e308 1e308 '"sonnet"'
ev developer 7 9 1e308 1e308 1e308 '"sonnet"'
J="$(bash "$EVENTS" cost --issue 7 --json 2>"$SANDBOX/err.log")"; RC=$?
assert_eq "0" "$RC" "overflow: cost --json exits 0"
assert_eq "0" "$(printf '%s' "$J" | grep -c -i 'infinity\|nan')" "overflow: --json has no Infinity or NaN"
assert_eq "0" "$(grep -c Traceback "$SANDBOX/err.log")" "overflow: no traceback"
assert_eq "OK" "$(printf '%s' "$J" | python3 -I -c '
import json, math, sys
def bad(c):
    raise ValueError(c)
d = json.loads(sys.stdin.read(), parse_constant=bad)
ok = all(math.isfinite(v) for v in d["total"].values()) and all(math.isfinite(v) for r in d["rows"] for k, v in r.items() if isinstance(v, (int, float)))
print("OK" if ok else "NOT FINITE")')" "overflow: every number in --json is finite"
assert_eq "0" "$(bash "$EVENTS" cost --issue 7 2>&1 | grep -c -i 'inf\|nan')" "overflow: the table has no inf or nan"
bash "$EVENTS" cost --issue 7 --pr 9 --markdown >/dev/null 2>"$SANDBOX/err.log"; RC=$?
assert_eq "0" "$RC" "overflow: --markdown exits 0"
assert_eq "0" "$(grep -c Traceback "$SANDBOX/err.log")" "overflow: --markdown has no traceback"
# a huge integer next to a float cannot overflow int -> float
reset_log
printf '{"event":"developer","role":"developer","issue":7,"pr":9,"verdict":"PASS","tokens":%s,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}\n' "1$(printf '0%.0s' $(seq 1 400))" >> "$LOG"
ev developer 7 9 1.5 1 1 '"sonnet"'
bash "$EVENTS" cost --issue 7 --json >/dev/null 2>"$SANDBOX/err.log"; RC=$?
assert_eq "0" "$RC" "overflow: a 400-digit integer plus a float exits 0"
assert_eq "0" "$(grep -c Traceback "$SANDBOX/err.log")" "overflow: a 400-digit integer plus a float prints no traceback"

# list --json is byte-identical to json.dumps of each record (the budget guard counts its lines)
reset_log
python3 -I - "$LOG" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(3):
        f.write(json.dumps({"ts": "2026-10-03T00:00:0%dZ" % i, "event": "budget-blocked", "role": "orchestrator",
                            "issue": 7, "pr": None, "verdict": "BLOCKED", "tokens": None}) + "\n")
PYEOF
cp "$LOG" "$SANDBOX/expected.jsonl"
bash "$EVENTS" list --issue 7 --event budget-blocked --json > "$SANDBOX/actual.jsonl" 2>/dev/null
assert_eq "same" "$(cmp -s "$SANDBOX/expected.jsonl" "$SANDBOX/actual.jsonl" && echo same || echo different)" "list --json: byte-identical, one object per line"

# default / --json / --line output is unchanged for a valid log (--markdown and --summary add nothing to them)
base_fixture
assert_contains "$(bash "$EVENTS" cost --issue 7 2>/dev/null | head -1)" "issue	role	events	tokens	tool_uses	duration_s	unrecorded	restamp" "default table header unchanged"
assert_eq "TOTAL		10	1900000	50	1295	2	1" "$(bash "$EVENTS" cost --issue 7 2>/dev/null | tail -1)" "default table total unchanged (orchestrator row included)"

finish
