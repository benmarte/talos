#!/usr/bin/env bash
# test-talos-status-line.sh -- covers issue #385 (sub-task 8 of epic #334):
# scripts/talos-status.sh --line / --preview, the shared status-line renderer.
#   (a) default line, every segment, the three styles, --format selection
#   (b) PARITY with pipeline-events.sh cost --json / --line and with the
#       module's formatters (pipeline-spend-format.py) for the same log
#   (c) issue from the branch (also in a linked worktree and from a subdir),
#       else the newest event; "today" is the UTC date of ts
#   (d) config layers (user file, repo override at the git toplevel), the
#       restricted-YAML / JSON readers, and the data-only hardening
#   (e) width: drop from the end, never wrap (60 columns); precedence
#   (f) budget through pipeline-budget.sh, only when the guard is on
#   (g) no log / not a git repo / bad input: nothing on stdout, exit 0, stderr
#       silent unless TALOS_STATUS_DEBUG=1; unrecorded is never printed as 0
#   (h) --preview, sample data labelled (sample)
#   (i) ANSI colour rules (always / auto + TTY + NO_COLOR / never)
#   (j) a 10k-event log answers within CI headroom (budget off)
#   (k) bounded work: oversized, symlinked and FIFO logs, a budget process that
#       never finishes, the hard time limit
#   (l) events.path from the project config, and what it may not point at
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

STATUS="$TALOS_ROOT/scripts/talos-status.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.talos/events.jsonl"
ERR="$SANDBOX/err.txt"
mkdir -p "$SANDBOX/.talos"
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/talos-nogit.XXXXXX")" || exit 1
trap '[ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; [ -n "${NOGIT:-}" ] && rm -rf "$NOGIT"' EXIT

# User-level config lives inside the sandbox, never the real ~/.talos.
export TALOS_HOME="$SANDBOX/.talos-home"
unset COLUMNS NO_COLOR TALOS_STATUS_DEBUG

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YESTERDAY="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
ESC="$(printf '\033')"

reset_log() { : > "$LOG"; }

# ev ROLE ISSUE PR TOKENS VERDICT [MODEL] [TS] -- append one event. PR, TOKENS
# and VERDICT take the literal `null`; the event name is the role.
ev() {
  local verdict model
  case "$5" in null) verdict=null ;; *) verdict="\"$5\"" ;; esac
  case "${6:-null}" in null) model=null ;; *) model="\"$6\"" ;; esac
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":%s,"tokens":%s,"model":%s,"ts":"%s"}\n' \
    "$1" "$1" "$2" "$3" "$verdict" "$4" "$model" "${7:-$NOW}" >> "$LOG"
}

# run_status ARGS... -- stdout in $OUT, rc in $RC, stderr in $ERR. RUN_DIR is
# the working directory (default: the sandbox repo).
run_status() { OUT="$(cd "${RUN_DIR:-$SANDBOX}" && bash "$STATUS" "$@" 2>"$ERR")"; RC=$?; }

set_user_cfg() { mkdir -p "$TALOS_HOME" && printf '%s\n' "$1" > "$TALOS_HOME/statusline.yml"; }
clear_user_cfg() { [ -n "${TALOS_HOME:-}" ] && rm -rf "$TALOS_HOME"; }
set_repo_cfg() { mkdir -p "$SANDBOX/.talos" && printf '%s\n' "$1" > "$SANDBOX/.talos/statusline.yml"; }
clear_repo_cfg() { rm -f "$SANDBOX/.talos/statusline.yml"; }
set_budget_cfg() { printf '%s\n' "{\"limits\": {\"tokens_per_issue\": $1, \"warn_at\": 0.8}}" > "$SANDBOX/talos.pipeline.json"; }
clear_budget_cfg() { rm -f "$SANDBOX/talos.pipeline.json"; }

# fmt_ref NUM -- the module's own fmt_num rendering, the reference for parity.
fmt_ref() {
  python3 -I -B - "$TALOS_ROOT/scripts" "$1" <<'PY'
import importlib, sys
sys.path.insert(0, sys.argv[1])
print(importlib.import_module("pipeline-spend-format").fmt_num(int(sys.argv[2])))
PY
}

# ── (a) segments and styles ────────────────────────────────────────────────
# Issue 752: roles sum to 3,411,000 (dev 1,566,000, adv 595,600, sec 486,600,
# rev 373,600, docs 244,600, qa 144,600) plus a 30,000 validator run with no
# PR = 3,441,000 -> 3.44M. Issue 751 adds 1,000,000 today and 5,000,000
# yesterday, so today = 4,441,000 -> 4.44M.
reset_log
ev developer 751 700 5000000 PASS null "$YESTERDAY"
ev developer 751 700 1000000 PASS
ev validator 752 null 30000 CONFIRMED
ev developer 752 764 1000000 PASS
ev developer 752 764 566000 PASS
ev adversarial 752 764 595600 FINDINGS
ev security 752 764 430600 PASS
ev reviewer 752 764 373600 PASS
ev docs 752 764 244600 PASS
ev qa 752 764 144600 PASS
ev security 752 764 56000 PASS claude-opus-4-1
ev orchestrator 752 764 null null        # excluded everywhere

run_status --line
assert_eq "0" "$RC" "default: exit 0"
assert_eq "#752 · PR #764 · sec ✓ · 3.44M · today 4.44M" "$OUT" \
  "default: issue, pr, stage, issue_tokens, today_tokens (budget off); orchestrator rows excluded"
assert_eq "" "$(cat "$ERR")" "default: stderr silent"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "default: exactly one line"

run_status --line --format stage_tokens,model,breakdown
assert_eq "sec 56k · opus · dev 1.57M · adv 596k · sec 487k" "$OUT" \
  "segments: stage_tokens, model (family) and breakdown (top 3, tokens descending)"

run_status --line --style full
assert_eq "issue #752 · PR #764 · security ✓ · issue 3.44M · today 4.44M" "$OUT" "style full: labelled segments, full role name"

run_status --line --style minimal --format issue,pr,stage,issue_tokens,breakdown
assert_eq "#752 · PR #764 · sec ✓ · 3.44M · dev 1.57M · adv 596k" "$OUT" "style minimal: breakdown keeps the top 2"

run_status --line --style full --format breakdown
assert_eq "dev 1.57M · adv 596k · sec 487k · rev 374k · docs 245k · qa 145k" "$OUT" "style full: breakdown keeps the top 6"

run_status --line --format issue,bogus,pr,issue
assert_eq "#752 · PR #764" "$OUT" "--format: unknown names are dropped, a repeated name shows once"

run_status --line --format=issue --style=full
assert_eq "issue #752" "$OUT" "--opt=value form"

# The stage mark is documented in the script header: PASS-like ✓, FAIL-like ✗,
# BLOCK-like ⚠, anything else (or null) `done`.
mark_for() {  # $1=verdict
  reset_log; ev qa 9 null 1000 "$1"
  run_status --line --format stage
  printf '%s' "$OUT"
}
assert_eq "qa ✓" "$(mark_for PASS)" "mark: PASS"
assert_eq "qa ✓" "$(mark_for APPROVED)" "mark: APPROVED"
assert_eq "qa ✓" "$(mark_for RESTAMP_PASS)" "mark: RESTAMP_PASS"
assert_eq "qa ✗" "$(mark_for FAIL)" "mark: FAIL"
assert_eq "qa ✗" "$(mark_for FINDINGS)" "mark: FINDINGS"
assert_eq "qa ✗" "$(mark_for CHANGES)" "mark: CHANGES"
assert_eq "qa ✗" "$(mark_for RESTAMP_FAIL)" "mark: RESTAMP_FAIL"
assert_eq "qa ⚠" "$(mark_for BLOCKED)" "mark: BLOCKED"
assert_eq "qa done" "$(mark_for null)" "mark: null verdict reads done"
assert_eq "qa done" "$(mark_for WHATEVER)" "mark: unknown verdict reads done"

# model: null reads `session default`; an unknown id is cut and control-stripped.
reset_log; ev qa 9 null 1000 PASS null
run_status --line --format model
assert_eq "session default" "$OUT" "model: null reads session default"
reset_log; ev qa 9 null 1000 PASS "gpt-5.5"
run_status --line --format model
assert_eq "gpt-5.5" "$OUT" "model: other ids are shown as is"

# ── (b) parity with cost and the module formatters ─────────────────────────
for n in 0 1 999 1000 1499 1500 999499 999500 1000000 3411000 12345678 999999999; do
  reset_log; ev developer 7 null "$n" PASS
  run_status --line --format issue_tokens
  ref="$(fmt_ref "$n")"
  cost_fig="$(bash "$EVENTS" cost --issue 7 --line 2>/dev/null | sed -E 's/.*done — ([^ ]+) tokens.*/\1/')"
  assert_eq "$ref" "$OUT" "parity: issue_tokens $n equals the module's fmt_num"
  assert_eq "$cost_fig" "$OUT" "parity: issue_tokens $n equals the figure in cost --line"
done

# A mixed log: recorded, unrecorded (null, string, negative), orchestrator.
reset_log
ev developer 801 81 40000 PASS
ev developer 800 80 1000000 PASS
ev developer 800 80 null PASS
ev security 800 80 560000 PASS
ev qa 800 80 -5 PASS
ev qa 800 80 '"12"' PASS
ev orchestrator 800 80 777777 null      # newest event: selects issue 800, counts nowhere
run_status --line --format issue_tokens,today_tokens,breakdown
cost_json="$(bash "$EVENTS" cost --issue 800 --json)"
expect="$(python3 -I -B - "$TALOS_ROOT/scripts" "$cost_json" <<'PY'
import importlib, json, sys
sys.path.insert(0, sys.argv[1])
fmt = importlib.import_module("pipeline-spend-format")
rows = [r for r in json.loads(sys.argv[2])["rows"] if r["role"] != "orchestrator"]
tokens = fmt.as_count(sum(r["tokens"] for r in rows))
unrec = sum(r["unrecorded"] for r in rows)
print("%s (+%d unrecorded)" % (fmt.fmt_num(tokens), unrec))
PY
)"
assert_eq "1.56M (+3 unrecorded) · today 1.60M (+3 unrecorded) · dev 1.00M · sec 560k" "$OUT" \
  "parity fixture: the line carries the unrecorded count and the breakdown"
assert_eq "$expect" "$(printf '%s' "$OUT" | sed -E 's/ · today.*//')" \
  "parity: issue_tokens and the unrecorded count equal the non-orchestrator totals of cost --issue 800 --json"
cost_line="$(bash "$EVENTS" cost --issue 800 --line 2>/dev/null)"
assert_contains "$cost_line" "issue total 1.56M (+3 unrecorded) (dev 1.00M, sec 560k)" "parity: cost --line prints the same total, unrecorded count and breakdown figures"

# ── all-unrecorded: never 0 ────────────────────────────────────────────────
reset_log
ev developer 9 null null PASS
ev qa 9 null null PASS
run_status --line --format issue_tokens,stage_tokens,today_tokens,breakdown
assert_eq "unrecorded · qa unrecorded · today unrecorded" "$OUT" "unrecorded: null tokens read unrecorded, never 0; breakdown omits empty roles"

# ── (c) which issue ────────────────────────────────────────────────────────
reset_log
ev developer 752 764 1000 PASS
ev developer 600 650 2000 PASS         # newest event
run_status --line --format issue,pr
assert_eq "#600 · PR #650" "$OUT" "issue: no branch match -> the newest event"
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/feat/issue-752-status-line
run_status --line --format issue,pr,issue_tokens
assert_eq "#752 · PR #764 · 1k" "$OUT" "issue: feat/issue-<N> branch wins over the newest event"
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/fix/issue-752
run_status --line --format issue
assert_eq "#752" "$OUT" "issue: fix/issue-<N> branch"
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/chore/issue-752
run_status --line --format issue
assert_eq "#600" "$OUT" "issue: chore/ branch does not match"
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/feat/issue-5-nothing-here
run_status --line --format issue,pr,stage,issue_tokens,today_tokens
assert_eq "#5 · today 3k" "$OUT" "issue: a branch issue with no events shows only the issue and today"

# today: the UTC date of ts, orchestrator rows excluded
reset_log
ev developer 1 null 1000 PASS null "$YESTERDAY"
ev developer 1 null 2000 PASS null "2020-01-01T00:00:00Z"
ev developer 1 null 4000 PASS null "${NOW%%T*}T00:00:00Z"
ev developer 2 null 8000 PASS null "${NOW%%T*}T23:59:59Z"
ev orchestrator 2 null 99000 null
ev developer 1 null 16000 PASS null "garbage"
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/master
run_status --line --format today_tokens
assert_eq "today 12k" "$OUT" "today: only events whose ts date is today (UTC) count"

# linked worktree and subdirectory resolve the main repo's log
git -C "$SANDBOX" commit --allow-empty -q -m init
reset_log
ev developer 752 764 1000 PASS
ev developer 701 705 2000 PASS
git -C "$SANDBOX" worktree add -q "$SANDBOX/wt" -b feat/issue-701-wt
RUN_DIR="$SANDBOX/wt" run_status --line --format issue,pr
assert_eq "#701 · PR #705" "$OUT" "worktree: branch issue from the worktree, log from the main repo"
git -C "$SANDBOX/wt" checkout -q --detach
RUN_DIR="$SANDBOX/wt" run_status --line --format issue
assert_eq "#701" "$OUT" "detached HEAD: the newest event's issue (701 is newest)"
mkdir -p "$SANDBOX/sub/dir"
RUN_DIR="$SANDBOX/sub/dir" run_status --line --format issue,pr
assert_eq "#701 · PR #705" "$OUT" "subdirectory: log found from below the repo root"

# ── (d) config ─────────────────────────────────────────────────────────────
reset_log
ev developer 752 764 56000 PASS claude-sonnet-5
git -C "$SANDBOX" symbolic-ref HEAD refs/heads/master
DEFAULT_LINE="#752 · PR #764 · dev ✓ · 56k · today 56k"

set_user_cfg 'statusline:
  segments: [issue, stage_tokens, model]   # comment
  separator: " | "
  style: full
  color: never
  max_width: 80
  placement: prepend'
run_status --line
assert_eq "issue #752 | developer 56k | model sonnet" "$OUT" "config: user file (flow list, separator, style, color, max_width; placement ignored)"

set_user_cfg 'statusline:
  segments:
    - pr
    - issue
  style: compact'
run_status --line
assert_eq "PR #764 · #752" "$OUT" "config: block list order is kept"

set_user_cfg '{"statusline": {"segments": ["pr"], "separator": "|"}}'
run_status --line
assert_eq "PR #764" "$OUT" "config: a JSON file is read as data"

set_user_cfg 'statusline:
  segments: [issue, pr]
  separator: " | "'
set_repo_cfg 'statusline:
  segments: [pr, issue]'
run_status --line
assert_eq "PR #764 | #752" "$OUT" "config: the repo override wins per key, other keys come from the user file"
RUN_DIR="$SANDBOX/sub/dir" run_status --line
assert_eq "PR #764 | #752" "$OUT" "config: the repo override is found at the git toplevel from a subdirectory"
RUN_DIR="$SANDBOX/wt" run_status --line
assert_eq "PR #764 | #752" "$OUT" "config: a worktree also reads the main repo's .talos/statusline.yml"
clear_repo_cfg
clear_user_cfg
run_status --line
assert_eq "$DEFAULT_LINE" "$OUT" "config: missing files -> defaults"

# malformed / hostile configs fall back to defaults and never fail
check_defaults() {  # $1=label
  run_status --line
  assert_eq "$DEFAULT_LINE" "$OUT" "$1"
  assert_eq "0" "$RC" "$1: exit 0"
  assert_eq "" "$(cat "$ERR")" "$1: stderr silent"
}
set_user_cfg 'statusline: ['
check_defaults "config: malformed YAML -> defaults"
set_user_cfg '- just
- a list'
check_defaults "config: a non-mapping document -> defaults"
set_user_cfg 'statusline: oops'
check_defaults "config: statusline is not a mapping -> defaults"
set_user_cfg 'statusline:
  segments: [bogus, "$(touch PWNED_MARKER)", 3]
  style: bogus
  color: bogus
  max_width: true'
check_defaults "config: only whitelisted segment names and valid values count"
python3 -I -c 'import sys; sys.stdout.write("statusline:\n  separator: \"" + "x" * 70000 + "\"\n")' > "$TALOS_HOME/statusline.yml"
check_defaults "config: a file over 64 KB is ignored"
python3 -I -c 'import sys; sys.stdout.write("[" * 30000)' > "$TALOS_HOME/statusline.yml"
check_defaults "config: deeply nested JSON (recursion) -> defaults"
printf '\000\001\377\376garbage' > "$TALOS_HOME/statusline.yml"
check_defaults "config: binary garbage -> defaults"
# Aliases are refused by the built-in reader and there is no PyYAML fallback,
# so an alias bomb is just an unreadable file -> defaults.
python3 -I -c '
print("statusline:")
print("  segments: &a [issue, issue]")
for i in range(1, 30):
    print("  k%d: &b%d [%s]" % (i, i, ", ".join(["*a" if i == 1 else "*b%d" % (i - 1)] * 9)))
print("  separator: *b29")
' > "$TALOS_HOME/statusline.yml"
check_defaults "config: an alias bomb -> defaults"
set_user_cfg 'statusline:
  segments: !!python/object/apply:os.system ["touch PWNED_TAG"]'
check_defaults "config: a YAML tag is refused (nothing is constructed or run)"
assert_file_absent "$SANDBOX/PWNED_TAG" "config: a YAML tag never runs anything"
set_user_cfg 'statusline:
  separator: *a'
check_defaults "config: a bare alias -> defaults"
rm -rf "$TALOS_HOME"; mkdir -p "$TALOS_HOME"; mkfifo "$TALOS_HOME/statusline.yml"
check_defaults "config: a FIFO in place of the file is never opened"
rm -rf "$TALOS_HOME"
assert_file_absent "$SANDBOX/PWNED_MARKER" "config: segment text is never executed"

# separator: control characters stripped, capped at 10 characters
set_user_cfg '{"statusline": {"segments": ["issue", "pr"], "separator": "\u001b[31mX\u001b[0m\nZZZZZZZZZZZZ"}}'
run_status --line
assert_not_contains "$OUT" "$ESC" "separator: no escape character from config"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "separator: a newline from config never splits the line"
assert_eq "#752[31mX[0mZZ" "$(printf '%s' "$OUT" | sed 's/PR #764//')" "separator: controls stripped, then capped at 10 characters"
set_user_cfg '{"statusline": {"segments": ["issue", "pr"], "separator": ""}}'
run_status --line
assert_eq "#752 · PR #764" "$OUT" "separator: empty -> the default"

# max_width is clamped to 20..500
set_user_cfg 'statusline:
  max_width: 5'
run_status --line --format issue,pr,stage
assert_eq "#752 · PR #764" "$OUT" "max_width: 5 is clamped to 20"
set_user_cfg 'statusline:
  max_width: 100000'
run_status --line --format issue,pr,stage
assert_eq "#752 · PR #764 · dev ✓" "$OUT" "max_width: a huge value is clamped (no failure)"
clear_user_cfg

# data only: a json.py / yaml.py planted in the working directory never runs
for mod in json yaml; do
  printf 'import os\nopen(os.path.join(os.path.dirname(__file__), "PLANTED_%s"), "w").close()\n' "$mod" > "$SANDBOX/$mod.py"
done
set_user_cfg 'statusline: ['      # not JSON, not the YAML subset
run_status --line
assert_eq "$DEFAULT_LINE" "$OUT" "planted modules: the line is unaffected"
assert_file_absent "$SANDBOX/PLANTED_json" "planted json.py is never imported"
assert_file_absent "$SANDBOX/PLANTED_yaml" "planted yaml.py is never imported"
rm -f "$SANDBOX/json.py" "$SANDBOX/yaml.py"
clear_user_cfg

# ── (e) width ──────────────────────────────────────────────────────────────
reset_log
ev developer 752 764 1000000 PASS
ev security 752 764 2441000 PASS
ev qa 751 700 1000000 PASS
ev security 752 764 1000 PASS
run_status --line --style full
WIDE="$OUT"
assert_eq "issue #752 · PR #764 · security ✓ · issue 3.44M · today 4.44M" "$WIDE" "width: the unconstrained full line"
run_status --line --style full --width 60
assert_eq "issue #752 · PR #764 · security ✓ · issue 3.44M" "$OUT" "width: 60 columns drops segments from the end, never wraps"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "width: still one line at 60"
run_status --line --style full --width 20
assert_eq "issue #752 · PR #764" "$OUT" "width: 20 columns keeps what fits"
run_status --line --style full --width 9
assert_eq "" "$OUT" "width: nothing fits -> nothing printed"
assert_eq "0" "$RC" "width: nothing fits -> exit 0"
# charlen TEXT -- characters, not bytes (bash counts bytes in a C locale)
charlen() { printf '%s' "$1" | python3 -I -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8")))'; }
for w in 21 33 40 47 52 58 60 61 79; do
  run_status --line --style full --width "$w"
  n="$(charlen "$OUT")"
  [ "$n" -le "$w" ] && pass "width: $w columns, the line is $n characters" || fail "width: $w columns" "$n characters: $OUT"
done
# precedence: --width > config max_width > COLUMNS > 80
set_user_cfg 'statusline:
  style: full
  max_width: 30'
run_status --line
assert_eq "issue #752 · PR #764" "$OUT" "precedence: config max_width 30"
run_status --line --width 60
assert_eq "issue #752 · PR #764 · security ✓ · issue 3.44M" "$OUT" "precedence: --width beats config max_width"
OUT="$(cd "$SANDBOX" && COLUMNS=15 bash "$STATUS" --line 2>/dev/null)"
assert_eq "issue #752 · PR #764" "$OUT" "precedence: config max_width (30) beats COLUMNS (15)"
clear_user_cfg
OUT="$(cd "$SANDBOX" && COLUMNS=60 bash "$STATUS" --line --style full 2>/dev/null)"
assert_eq "issue #752 · PR #764 · security ✓ · issue 3.44M" "$OUT" "precedence: COLUMNS is used when nothing else sets a width"
OUT="$(cd "$SANDBOX" && COLUMNS=abc bash "$STATUS" --line --style full 2>/dev/null)"
assert_eq "$WIDE" "$OUT" "precedence: a bad COLUMNS is ignored (default 80)"

# ── (f) budget ─────────────────────────────────────────────────────────────
# The real pipeline-budget.sh takes about 1 s on a fast machine and more than
# the 2 s default call timeout on a loaded CI runner (it then reads as absent
# and the segment vanishes), so these runs get the full 10 s hard limit.
export TALOS_STATUS_TIMEOUT_S=10
reset_log
ev developer 900 70 3120000 PASS        # 78% of 4M
set_budget_cfg 4000000
run_status --line --format issue,budget
assert_eq "#900 · 78% of 4M" "$OUT" "budget: ok -> '78% of 4M'"
run_status --line --format budget --style full
assert_eq "budget 78% of 4M" "$OUT" "budget: full style labels it"
run_status --line --format budget --style minimal
assert_eq "78%" "$OUT" "budget: minimal style is the percentage"
ev developer 900 70 180000 PASS         # 3.3M = 82%
run_status --line --format budget
assert_eq "⚠ 82% of 4M" "$OUT" "budget: warn gets a mark even without colour"
ev developer 900 70 800000 PASS         # 4.1M = 102%
run_status --line --format issue,budget
assert_eq "0" "$RC" "budget: exceeded is a signal, never a failure of the line"
assert_eq "#900 · ⛔ 102% of 4M" "$OUT" "budget: exceeded"
set_budget_cfg 0
run_status --line --format issue,budget
assert_eq "#900" "$OUT" "budget: guard off (0) -> no budget segment"
clear_budget_cfg
run_status --line --format issue,budget
assert_eq "#900" "$OUT" "budget: limit unset -> no budget segment"
set_budget_cfg 4000000
reset_log
run_status --line --format issue,budget
assert_eq "" "$OUT" "budget: no events -> nothing at all"
clear_budget_cfg
# colour: warn is yellow, exceeded red (only with colour on)
ev developer 900 70 3300000 PASS
set_budget_cfg 4000000
set_user_cfg 'statusline:
  segments: [budget]
  color: always'
run_status --line
assert_eq "${ESC}[33m⚠ 82% of 4M${ESC}[0m" "$OUT" "budget colour: warn is yellow"
ev developer 900 70 900000 PASS
run_status --line
assert_eq "${ESC}[31m⛔ 105% of 4M${ESC}[0m" "$OUT" "budget colour: exceeded is red"
clear_user_cfg
clear_budget_cfg

# the budget is found from a subdirectory (the budget script runs in the git toplevel)
reset_log; ev developer 900 70 3120000 PASS
set_budget_cfg 4000000
RUN_DIR="$SANDBOX/sub/dir" run_status --line --format budget
assert_eq "78% of 4M" "$OUT" "budget: a status line started from a subdirectory still sees the limit"
clear_budget_cfg
unset TALOS_STATUS_TIMEOUT_S

# the budget process is skipped (a pre-filter, ~30 ms) unless a project config names the limit
STUBS="$SANDBOX/stubscripts"
mkdir -p "$STUBS"
cp "$STATUS" "$TALOS_ROOT/scripts/pipeline-spend-format.py" "$STUBS/"
cat > "$STUBS/pipeline-budget.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BUDGET_STUB_LOG:?}"
printf '%s\n' '{"status":"ok","issue":900,"used":1,"limit":4000000,"effective":4000000,"pct":78,"unrecorded":0}'
STUB
export BUDGET_STUB_LOG="$SANDBOX/budget-stub.log"
: > "$BUDGET_STUB_LOG"
OUT="$(cd "$SANDBOX" && bash "$STUBS/talos-status.sh" --line --format budget 2>/dev/null)"
assert_eq "" "$OUT" "budget pre-filter: no config -> no budget segment"
assert_eq "" "$(cat "$BUDGET_STUB_LOG")" "budget pre-filter: no config -> pipeline-budget.sh is not run"
printf '%s\n' '{"agents": {"model": "x"}}' > "$SANDBOX/talos.pipeline.json"
OUT="$(cd "$SANDBOX" && bash "$STUBS/talos-status.sh" --line --format budget 2>/dev/null)"
assert_eq "" "$(cat "$BUDGET_STUB_LOG")" "budget pre-filter: a config without the limit -> not run"
set_budget_cfg 4000000
OUT="$(cd "$SANDBOX" && bash "$STUBS/talos-status.sh" --line --format budget 2>/dev/null)"
assert_eq "78% of 4M" "$OUT" "budget pre-filter: the limit is named -> the stub's answer is shown"
assert_eq "check --issue 900 --json" "$(cat "$BUDGET_STUB_LOG")" "budget pre-filter: run once, as check --issue N --json"
clear_budget_cfg
: > "$BUDGET_STUB_LOG"
printf '%s\n' '{"limits": {"tokens_per_issue": 5}}' > "$SANDBOX/custom-config.json"
OUT="$(cd "$SANDBOX" && PIPELINE_CONFIG="$SANDBOX/custom-config.json" bash "$STUBS/talos-status.sh" --line --format budget 2>/dev/null)"
assert_eq "78% of 4M" "$OUT" "budget pre-filter: PIPELINE_CONFIG is honoured"
rm -f "$SANDBOX/custom-config.json"
unset BUDGET_STUB_LOG

# ── (g) no data, bad input, debug ──────────────────────────────────────────
rm -f "$LOG"
run_status --line
assert_eq "" "$OUT" "no log: nothing on stdout"
assert_eq "0" "$RC" "no log: exit 0"
assert_eq "" "$(cat "$ERR")" "no log: stderr silent"
: > "$LOG"
run_status --line
assert_eq "" "$OUT" "empty log: nothing"
printf 'not json\n[1,2]\n"str"\n{"issue": 3}\n\n' > "$LOG"
run_status --line --format issue,issue_tokens
assert_eq "0" "$RC" "garbage lines: exit 0"
assert_eq "#3 · unrecorded" "$OUT" "garbage lines: skipped silently, a bare object still counts (unrecorded)"
assert_eq "" "$(cat "$ERR")" "garbage lines: stderr silent"
RUN_DIR="$NOGIT" run_status --line
assert_eq "" "$OUT" "not a git repo: nothing on stdout"
assert_eq "0" "$RC" "not a git repo: exit 0"
assert_eq "" "$(cat "$ERR")" "not a git repo: stderr silent"

reset_log; ev developer 752 764 1000 PASS
for bad in "--bogus" "" "--line --style bogus" "--line --width abc" "--line --width" "--line --width 0" \
           "--line --format" "--line --format ," "--line --format nonsense" "--line extra"; do
  # shellcheck disable=SC2086
  run_status $bad
  if [ -z "$OUT" ] && [ "$RC" = "0" ] && [ -z "$(cat "$ERR")" ]; then
    pass "bad input '$bad': nothing on stdout, exit 0, stderr silent"
  else
    fail "bad input '$bad'" "rc=$RC out=$OUT err=$(cat "$ERR")"
  fi
done
OUT="$(cd "$SANDBOX" && TALOS_STATUS_DEBUG=1 bash "$STATUS" --bogus 2>&1 >/dev/null)"
[ -n "$OUT" ] && pass "debug: TALOS_STATUS_DEBUG=1 explains bad input on stderr" || fail "debug: stderr stays empty under TALOS_STATUS_DEBUG=1"
assert_not_contains "$OUT" "Traceback" "debug: no traceback even in debug"

# role text from the log is one safe token
reset_log
printf '{"event":"x","role":"se\\u001b[2Jc\\nmarker","issue":4,"pr":5,"verdict":"PASS","tokens":10,"ts":"%s"}\n' "$NOW" >> "$LOG"
run_status --line --format stage,stage_tokens,breakdown
assert_not_contains "$OUT" "$ESC" "role: control characters from the log never reach the line"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "role: a newline in a role never splits the line"

# the shared module missing: nothing, exit 0, a note only in debug
mkdir -p "$SANDBOX/lone" && cp "$STATUS" "$SANDBOX/lone/talos-status.sh"
reset_log; ev developer 752 764 1000 PASS
OUT="$(cd "$SANDBOX" && bash "$SANDBOX/lone/talos-status.sh" --line 2>"$ERR")"; RC=$?
assert_eq "" "$OUT" "module missing: nothing on stdout"
assert_eq "0" "$RC" "module missing: exit 0"
assert_eq "" "$(cat "$ERR")" "module missing: stderr silent"
OUT="$(cd "$SANDBOX" && TALOS_STATUS_DEBUG=1 bash "$SANDBOX/lone/talos-status.sh" --line 2>&1 >/dev/null)"
assert_contains "$OUT" "pipeline-spend-format" "module missing: debug names the module"

# invoked through a symlink on PATH, the module is still found next to the real script
mkdir -p "$SANDBOX/bin" && ln -s "$STATUS" "$SANDBOX/bin/talos-status"
OUT="$(cd "$SANDBOX" && "$SANDBOX/bin/talos-status" --line 2>/dev/null)"
assert_eq "#752 · PR #764 · dev ✓ · 1k · today 1k" "$OUT" "symlink: resolves the scripts directory through the link"

# ── (h) --preview ──────────────────────────────────────────────────────────
rm -f "$LOG"
run_status --preview
assert_eq "0" "$RC" "preview (no log): exit 0"
assert_contains "$OUT" "(sample)" "preview (no log): sample data is labelled (sample)"
assert_eq "6" "$(printf '%s\n' "$OUT" | grep -c 'columns:')" "preview: three styles at two widths"
assert_contains "$OUT" "60 columns:" "preview: includes the 60-column rendering"
assert_contains "$OUT" "78% of 4M" "preview (sample): the budget segment shows sample data"
for st in compact full minimal; do
  assert_eq "2" "$(printf '%s\n' "$OUT" | grep -c "^$st,")" "preview: $st appears at both widths"
done
too_wide="$(printf '%s\n' "$OUT" | python3 -I -c '
import sys
lines = sys.stdin.read().split("\n")
for i, l in enumerate(lines):
    if l.endswith("60 columns:") and len(lines[i + 1].strip()) > 60:
        print(lines[i + 1])
')"
assert_eq "" "$too_wide" "preview: the 60-column lines are at most 60 characters"
RUN_DIR="$NOGIT" run_status --preview
assert_contains "$OUT" "(sample)" "preview: works outside a git repo (sample)"
reset_log; ev developer 752 764 56000 PASS
run_status --preview
assert_not_contains "$OUT" "(sample)" "preview (real events): not labelled sample"
assert_contains "$OUT" "#752" "preview (real events): uses the log"
assert_contains "$OUT" "56k" "preview (real events): real figures"

# ── (i) colour ─────────────────────────────────────────────────────────────
tty_run() {  # run the script with stdout on a pseudo-terminal; prints what it wrote
  python3 -I - "$STATUS" "$@" <<'PY'
import os, pty, select, subprocess, sys
master, slave = pty.openpty()
proc = subprocess.Popen(["bash", sys.argv[1]] + sys.argv[2:], stdout=slave,
                        stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, cwd=os.getcwd())
os.close(slave)
data = b""
# read while the child runs: macOS drops unread pty data once the slave closes
while select.select([master], [], [], 10)[0]:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
proc.wait()
sys.stdout.write(data.decode("utf-8", "replace"))
PY
}
reset_log; ev developer 752 764 56000 FAIL
run_status --line --format stage
assert_eq "dev ✗" "$OUT" "colour: auto without a TTY prints no escapes"
set_user_cfg 'statusline:
  color: always'
run_status --line --format stage
assert_eq "dev ${ESC}[31m✗${ESC}[0m" "$OUT" "colour: always colours the stage mark (fail = red)"
stripped="$(printf '%s' "$OUT" | sed "s/${ESC}\[[0-9;]*m//g")"
assert_eq "dev ✗" "$stripped" "colour: removing the escapes leaves the plain line"
OUT="$(cd "$SANDBOX" && NO_COLOR=1 bash "$STATUS" --line --format stage 2>/dev/null)"
assert_contains "$OUT" "$ESC" "colour: always wins over NO_COLOR"
run_status --line --format stage,issue --width 9
assert_eq "dev ${ESC}[31m✗${ESC}[0m" "$OUT" "colour: width counts characters without the escapes (dev ✗ · #752 is 12, so only dev ✗ fits 9)"
set_user_cfg 'statusline:
  color: never'
OUT="$(cd "$SANDBOX" && tty_run --line --format stage)"
assert_not_contains "$OUT" "$ESC" "colour: never prints no escapes even on a TTY"
clear_user_cfg
OUT="$(cd "$SANDBOX" && tty_run --line --format stage)"
assert_contains "$OUT" "$ESC" "colour: auto on a TTY colours"
OUT="$(cd "$SANDBOX" && NO_COLOR=1 tty_run --line --format stage)"
assert_not_contains "$OUT" "$ESC" "colour: auto on a TTY with NO_COLOR set prints no escapes"
reset_log; ev developer 752 764 56000 PASS
set_user_cfg 'statusline:
  color: always'
run_status --line --format stage
assert_eq "dev ${ESC}[32m✓${ESC}[0m" "$OUT" "colour: pass = green"
reset_log; ev developer 752 764 56000 BLOCKED
run_status --line --format stage
assert_eq "dev ${ESC}[33m⚠${ESC}[0m" "$OUT" "colour: block = yellow"
clear_user_cfg

# ── (j) 10k events ─────────────────────────────────────────────────────────
python3 -I - "$LOG" "$NOW" <<'PY'
import json, sys
roles = ["developer", "adversarial", "security", "reviewer", "docs", "qa", "validator"]
with open(sys.argv[1], "w") as f:
    for i in range(10000):
        f.write(json.dumps({"event": roles[i % 7], "role": roles[i % 7], "issue": 1 + i // 50,
                            "pr": 1000 + i // 50, "verdict": "PASS", "tokens": 1000 + i,
                            "tool_uses": 3, "duration_s": 30, "model": "claude-sonnet-5",
                            "ts": sys.argv[2]}) + "\n")
PY
timings="$(python3 -I - "$STATUS" "$SANDBOX" <<'PY'
import statistics, subprocess, sys, time
samples = []
for _ in range(5):
    t = time.perf_counter()
    subprocess.run(["bash", sys.argv[1], "--line", "--format", "issue,pr,stage,issue_tokens,today_tokens"],
                   cwd=sys.argv[2], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    samples.append((time.perf_counter() - t) * 1000)
print("%d %d" % (statistics.median(samples), max(samples)))
PY
)"
MEDIAN_MS="${timings% *}"; MAX_MS="${timings#* }"
printf '  info: 10k-event log, default segments minus budget: median %s ms, max %s ms (target 50 ms; CI bound 500 ms)\n' "$MEDIAN_MS" "$MAX_MS"
[ "$MAX_MS" -lt 500 ] && pass "10k events: every run is under the 500 ms CI bound (budget off)" || fail "10k events: slow" "max ${MAX_MS} ms"
run_status --line --format issue,pr,stage,issue_tokens,today_tokens
# newest event i=9999: issue 200, PR 1199, role reviewer; issue 200 sums
# 548,725 tokens; every event is today and the whole log sums 59,995,000.
assert_eq "#200 · PR #1199 · rev ✓ · 549k · today 60.00M" "$OUT" "10k events: the right figures from a large log"

# ── (k) bounded work: oversized / symlinked / special logs, slow budget ────
# The repo is untrusted and the status line redraws constantly: it must never
# hang, whatever .talos/events.jsonl is.
STUBS="$SANDBOX/stubscripts"
# run_timed SCRIPT ARGS... -- run `bash SCRIPT ARGS` from the sandbox; sets OUT,
# RC and ELAPSED_MS (stderr dropped).
run_timed() {
  local res rest
  res="$(cd "$SANDBOX" && python3 -I - "$@" <<'PY'
import subprocess, sys, time
t = time.perf_counter()
p = subprocess.run(["bash"] + sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
print(int((time.perf_counter() - t) * 1000), p.returncode, p.stdout.decode().strip())
PY
)"
  ELAPSED_MS="${res%% *}"; rest="${res#* }"; RC="${rest%% *}"; OUT="${rest#* }"
}

reset_log; ev developer 752 764 1000 PASS
run_timed "$STATUS" --line --format issue
assert_eq "#752" "$OUT" "bounded: the sane log prints (control)"

# a log over the 32 MB cap is not read at all (sparse file: no real I/O)
python3 -I -c 'import sys
line = b"{\"event\":\"developer\",\"role\":\"developer\",\"issue\":752,\"tokens\":1}\n"
f = open(sys.argv[1], "wb"); f.write(line); f.truncate(33 * 1024 * 1024); f.close()' "$LOG"
run_timed "$STATUS" --line --format issue
assert_eq "" "$OUT" "bounded: a log over the cap prints nothing"
assert_eq "0" "$RC" "bounded: a log over the cap -> exit 0"
[ "$ELAPSED_MS" -lt 2000 ] && pass "bounded: a log over the cap returns promptly (${ELAPSED_MS} ms)" || fail "bounded: oversized log was slow" "${ELAPSED_MS} ms"
# exactly at the cap is still read
python3 -I -c 'import sys
line = b"{\"event\":\"developer\",\"role\":\"developer\",\"issue\":752,\"tokens\":1}\n"
f = open(sys.argv[1], "wb"); f.write(line); f.write(b"\n" * (32 * 1024 * 1024 - len(line))); f.close()' "$LOG"
run_timed "$STATUS" --line --format issue
assert_eq "#752" "$OUT" "bounded: a log of exactly the cap is read"

# a symlinked log is refused, inside or outside the repository
mkdir -p "$NOGIT/outside"
reset_log; ev developer 752 764 1000 PASS
mv "$LOG" "$NOGIT/outside/real.jsonl"
ln -s "$NOGIT/outside/real.jsonl" "$LOG"
run_timed "$STATUS" --line --format issue
assert_eq "" "$OUT" "symlink: a log symlinked to a file outside the repo prints nothing"
assert_eq "0" "$RC" "symlink: exit 0"
rm -f "$LOG"
ev developer 752 764 1000 PASS
mv "$LOG" "$SANDBOX/real-inside.jsonl"
ln -s "$SANDBOX/real-inside.jsonl" "$LOG"
run_timed "$STATUS" --line --format issue
assert_eq "" "$OUT" "symlink: a log symlinked within the repo is refused too"
rm -f "$LOG" "$SANDBOX/real-inside.jsonl"
# a symlinked .talos directory leading outside the repo
reset_log; ev developer 752 764 1000 PASS
mv "$SANDBOX/.talos" "$NOGIT/outside/dottalos"
ln -s "$NOGIT/outside/dottalos" "$SANDBOX/.talos"
run_timed "$STATUS" --line --format issue
assert_eq "" "$OUT" "symlink: a .talos directory symlinked outside the repo prints nothing"
rm -f "$SANDBOX/.talos"
mv "$NOGIT/outside/dottalos" "$SANDBOX/.talos"
# a FIFO in place of the log: no block
rm -f "$LOG"; mkfifo "$LOG"
run_timed "$STATUS" --line --format issue
assert_eq "" "$OUT" "special file: a FIFO log prints nothing"
[ "$ELAPSED_MS" -lt 2000 ] && pass "special file: a FIFO log does not block (${ELAPSED_MS} ms)" || fail "special file: FIFO blocked" "${ELAPSED_MS} ms"
rm -f "$LOG"

# a budget process that never finishes: killed with its children, the line still prints
mkdir -p "$STUBS"
cp "$STATUS" "$TALOS_ROOT/scripts/pipeline-spend-format.py" "$STUBS/"
cat > "$STUBS/pipeline-budget.sh" <<'STUB'
#!/usr/bin/env bash
sleep 30 &
printf '%s\n' "$!" > "${BUDGET_SLEEP_PID:?}"
wait
STUB
export BUDGET_SLEEP_PID="$SANDBOX/sleeper.pid"
reset_log; ev developer 900 70 1000 PASS
set_budget_cfg 4000000
alive() { kill -0 "$1" 2>/dev/null; }
wait_dead() {  # $1=pid; bounded: up to ~3 s
  local i=0
  while alive "$1" && [ "$i" -lt 30 ]; do i=$((i + 1)); python3 -I -c 'import time; time.sleep(0.1)'; done
  alive "$1" && return 1 || return 0
}
rm -f "$BUDGET_SLEEP_PID"
run_timed "$STUBS/talos-status.sh" --line --format issue,budget
assert_eq "#900" "$OUT" "slow budget: the line prints without the budget segment"
assert_eq "0" "$RC" "slow budget: exit 0"
[ "$ELAPSED_MS" -lt 6000 ] && pass "slow budget: gave up promptly (${ELAPSED_MS} ms)" || fail "slow budget: took too long" "${ELAPSED_MS} ms"
SLEEPER="$(cat "$BUDGET_SLEEP_PID" 2>/dev/null)"
[ -n "$SLEEPER" ] && wait_dead "$SLEEPER" && pass "slow budget: the whole process group was killed (no leftover child)" \
  || fail "slow budget: a child of the budget script is still running" "pid ${SLEEPER:-none}"
[ -n "$SLEEPER" ] && alive "$SLEEPER" && kill "$SLEEPER" 2>/dev/null

# the hard time limit: nothing printed, exit 0, the budget group killed too
rm -f "$BUDGET_SLEEP_PID"
OUT="$(cd "$SANDBOX" && TALOS_STATUS_TIMEOUT_S=1 python3 -I - "$STUBS/talos-status.sh" <<'PY'
import subprocess, sys, time
t = time.perf_counter()
p = subprocess.run(["bash", sys.argv[1], "--line", "--format", "issue,budget"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
print(int((time.perf_counter() - t) * 1000), p.returncode, repr(p.stdout.decode()))
PY
)"
set -- $OUT
assert_eq "0" "$2" "time limit: exit 0 when the alarm fires"
assert_eq "''" "$3" "time limit: nothing printed when the alarm fires"
[ "$1" -lt 1900 ] && pass "time limit: stopped at the 1 s limit (${1} ms)" || fail "time limit: ran past the limit" "${1} ms"
SLEEPER="$(cat "$BUDGET_SLEEP_PID" 2>/dev/null)"
[ -n "$SLEEPER" ] && wait_dead "$SLEEPER" && pass "time limit: the budget process group was killed" \
  || fail "time limit: a child of the budget script is still running" "pid ${SLEEPER:-none}"
[ -n "$SLEEPER" ] && alive "$SLEEPER" && kill "$SLEEPER" 2>/dev/null

# the budget call's timeout follows the hard limit (limit - 1 s, never under 2 s):
# a 3 s budget answer is dropped at the default and shown when the limit is 5
cat > "$STUBS/pipeline-budget.sh" <<'STUB'
#!/usr/bin/env bash
sleep 3
printf '%s\n' '{"status":"ok","issue":900,"used":1,"limit":4000000,"effective":4000000,"pct":78,"unrecorded":0}'
STUB
OUT="$(cd "$SANDBOX" && bash "$STUBS/talos-status.sh" --line --format issue,budget 2>/dev/null)"
assert_eq "#900" "$OUT" "budget timeout: a 3 s budget answer is dropped at the default limit"
OUT="$(cd "$SANDBOX" && TALOS_STATUS_TIMEOUT_S=5 bash "$STUBS/talos-status.sh" --line --format issue,budget 2>/dev/null)"
assert_eq "#900 · 78% of 4M" "$OUT" "budget timeout: raising TALOS_STATUS_TIMEOUT_S lets a slow budget answer through"
clear_budget_cfg
unset BUDGET_SLEEP_PID

# ── (l) events.path ────────────────────────────────────────────────────────
mkdir -p "$SANDBOX/data" "$NOGIT/outside"
DEFAULT_LOG="$LOG"
reset_log; ev developer 111 1 1000 PASS                    # the default log: a decoy
LOG="$SANDBOX/data/ev.jsonl"; : > "$LOG"; ev developer 752 764 56000 PASS
cp "$LOG" "$NOGIT/outside/ev.jsonl"
set_ep_json() { printf '%s\n' "{\"events\": {\"path\": \"$1\"}, \"agents\": {\"model\": \"x\"}}" > "$SANDBOX/talos.pipeline.json"; }
rm -f "$SANDBOX/talos.pipeline.json" "$SANDBOX/talos.pipeline.yml"
run_status --line --format issue
assert_eq "#111" "$OUT" "events.path: no config -> the default log"
set_ep_json "data/ev.jsonl"
run_status --line --format issue,issue_tokens
assert_eq "#752 · 56k" "$OUT" "events.path: a relocated log (JSON config)"
RUN_DIR="$SANDBOX/sub/dir" run_status --line --format issue
assert_eq "#752" "$OUT" "events.path: found from a subdirectory (config at the git toplevel)"
set_ep_json "data/../data/ev.jsonl"
run_status --line --format issue
assert_eq "#752" "$OUT" "events.path: a .. that stays inside the root is normalised"
for bad in "$NOGIT/outside/ev.jsonl" "../outside/ev.jsonl" "data/../../outside/ev.jsonl" ".."; do
  set_ep_json "$bad"
  run_status --line --format issue
  assert_eq "" "$OUT" "events.path: '$bad' is refused (absolute or leaves the repo) -> nothing"
done
ln -s "$NOGIT/outside" "$SANDBOX/linkdir"
set_ep_json "linkdir/ev.jsonl"
run_status --line --format issue
assert_eq "" "$OUT" "events.path: a directory symlink that leads outside the repo is refused"
rm -f "$SANDBOX/linkdir" "$SANDBOX/talos.pipeline.json"
set_ep_json "data/ev.jsonl"
printf '%s\n' '{"agents": {"model": "x"}}' > "$SANDBOX/talos.pipeline.json"
run_status --line --format issue
assert_eq "#111" "$OUT" "events.path: a config that does not mention events -> the default log"
rm -f "$SANDBOX/talos.pipeline.json"
printf '%s\n' \
  'board:' \
  '  labels: {a: b}' \
  'agents:' \
  '  note: |' \
  '    text' \
  'events:' \
  '  other: 1' \
  '  path: data/ev.jsonl   # relocated' \
  'limits:' \
  '  path: nonsense' > "$SANDBOX/talos.pipeline.yml"
run_status --line --format issue
assert_eq "#752" "$OUT" "events.path: a YAML config, unrelated syntax around it does not matter"
printf '%s\n' 'events:' '  path: /etc/passwd' > "$SANDBOX/talos.pipeline.yml"
run_status --line --format issue
assert_eq "" "$OUT" "events.path: an absolute path in YAML is refused"
printf '%s\n' 'events:' '  path: 5' > "$SANDBOX/talos.pipeline.yml"
run_status --line --format issue
assert_eq "#111" "$OUT" "events.path: a non-string value -> the default log"
rm -f "$SANDBOX/talos.pipeline.yml"
LOG="$DEFAULT_LOG"

# ── static guards ──────────────────────────────────────────────────────────
assert_file_exists "$STATUS" "script exists"
[ -x "$STATUS" ] && pass "script is executable" || fail "script is executable"
bare="$(grep -n 'python3' "$STATUS" | grep -vE ':[0-9]*:?[[:space:]]*#|command -v python3|python3 -I' || true)"
assert_eq "" "$bare" "every python3 call in the script runs with -I"
assert_eq "" "$(grep -nE '\bHOME=' "$STATUS" || true)" "the script never sets HOME"

printf '\n%s passed, %s failed\n' "$_PASS" "$_FAIL"
[ "$_FAIL" -eq 0 ]
