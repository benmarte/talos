#!/usr/bin/env bash
# test-events-spend-line.sh -- `pipeline-events.sh cost --pr M` and `--line` (#380):
#   (a) the issue's example line, exactly, from a fixture with unrounded
#       per-event values (the issue's rounded parts sum to 3,417,000 = 3.42M,
#       so the fixture uses values that sum to 3,411,000 and still round to
#       the printed figures)
#   (b) without --pr the reference is #<issue> and the label `issue total`
#   (c) number format: integer round half up, k/M carry, two decimals for M
#   (d) duration format and omitted-null parts; "newest" is file order
#   (e) null tokens: `tokens unrecorded`, `(+K unrecorded)` position,
#       `total unrecorded`, an all-unrecorded role left out of the breakdown
#   (f) orchestrator events never count; no log / no match prints nothing
#   (g) 200-character cut with `…` on whole breakdown entries
#   (h) --pr filters the table and --json; --line without --issue exits 2
#   (i) every value-taking option exits 2 with usage when its value is
#       missing, promptly (`cost --issue` used to loop forever)
#   (j) UTF-8 output under LC_ALL=C; no `talos:<word>` token in the output
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.talos/events.jsonl"
mkdir -p "$SANDBOX/.talos"

# reset_log -- empty the sandbox events log.
reset_log() { : > "$LOG"; }

# ev ROLE ISSUE PR TOKENS TOOLS DUR [TS] -- append one event. Pass `null` for
# a null field; the event name is the role (as post_stage records it).
ev() {
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"PASS","tokens":%s,"tool_uses":%s,"duration_s":%s,"ts":"%s"}\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "$6" "${7:-2026-10-03T00:00:00Z}" >> "$LOG"
}

# line_for ARGS... -- run `cost <args> --line`, stdout only.
line_for() { bash "$EVENTS" cost "$@" --line 2>/dev/null; }

# ── (a) the issue's example line ───────────────────────────────────────────
# Roles sum to 3,411,000 (dev 1,566,000, adv 595,600, sec 486,600, rev
# 373,600, docs 244,600, qa 144,600); each rounds to the figure the issue
# prints. The newest security event is 56,000 tokens / 14 tools / 125 s.
reset_log
ev validator     752 null 30000   5   40        # pr null: out of --pr scope
ev qa            752 765  55000   4   30        # another PR: out of --pr scope
ev developer     752 764  1000000 60  900
ev developer     752 764  566000  30  600
ev adversarial   752 764  595600  20  300
ev security      752 764  430600  10  200
ev reviewer      752 764  373600  12  250
ev docs          752 764  244600  8   100
ev qa            752 764  144600  6   90
ev security      752 764  56000   14  125
ev orchestrator  752 764  null    null null          # excluded, not unrecorded
EXPECTED='talos: #764 security done — 56k tokens, 14 tools, 2m05s · PR total 3.41M (dev 1.57M, adv 596k, sec 487k, rev 374k, docs 245k, qa 145k)'
out="$(bash "$EVENTS" cost --issue 752 --pr 764 --line 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "0" "$rc" "line: exit 0"
assert_eq "$EXPECTED" "$out" "line: the issue's example line, exactly"
assert_eq "" "$(cat "$SANDBOX/err.log")" "line: nothing on stderr"
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "line: exactly one line"
if grep -Eq 'talos:[a-z-]+' <<<"$out"; then
  fail "line: no talos:<word> token in the output" "$out"
else
  pass "line: no talos:<word> token in the output"
fi

# ── (b) no --pr: reference #<issue>, label `issue total` ───────────────────
# Scope is every non-orchestrator event of issue 752: 3,411,000 + 30,000
# (validator) + 55,000 (qa on PR 765) = 3,496,000 -> 3.50M; qa is 199,600
# (200k), validator 30k.
out="$(line_for --issue 752)"
assert_eq 'talos: #752 security done — 56k tokens, 14 tools, 2m05s · issue total 3.50M (dev 1.57M, adv 596k, sec 487k, rev 374k, docs 245k, qa 200k, val 30k)' \
  "$out" "line: without --pr the reference is #<issue> and the label is 'issue total'"

# ── (c) number format ──────────────────────────────────────────────────────
# One event, so the newest event's tokens and the total are the same number.
check_number() {  # $1=tokens $2=expected rendering
  reset_log; ev developer 7 null "$1" 1 5
  out="$(line_for --issue 7)"
  assert_eq "talos: #7 developer done — $2 tokens, 1 tools, 5s · issue total $2 (dev $2)" "$out" "number: $1 -> $2"
}
check_number 0 0
check_number 999 999
check_number 1000 1k
check_number 1499 1k
check_number 1500 2k
check_number 54500 55k
check_number 54499 54k
check_number 999499 999k
check_number 999500 1.00M
check_number 999999 1.00M
check_number 1000000 1.00M
check_number 1004999 1.00M
check_number 1005000 1.01M
check_number 3414999 3.41M
check_number 3415000 3.42M

# ── (d) durations, null parts, newest = file order ─────────────────────────
check_duration() {  # $1=seconds $2=expected
  reset_log; ev qa 8 null 1000 2 "$1"
  out="$(line_for --issue 8)"
  assert_contains "$out" "1k tokens, 2 tools, $2 · issue total" "duration: $1s -> $2"
}
check_duration 0 0s
check_duration 45 45s
check_duration 59 59s
check_duration 60 1m00s
check_duration 120 2m00s
check_duration 125 2m05s
check_duration 3599 59m59s
check_duration 3600 1h00m
check_duration 3720 1h02m

reset_log; ev qa 8 null 1000 2 null
assert_eq 'talos: #8 qa done — 1k tokens, 2 tools · issue total 1k (qa 1k)' "$(line_for --issue 8)" \
  "null duration: omitted together with its comma"
reset_log; ev qa 8 null 1000 null 125
assert_eq 'talos: #8 qa done — 1k tokens, 2m05s · issue total 1k (qa 1k)' "$(line_for --issue 8)" \
  "null tool count: omitted together with its comma"
reset_log; ev qa 8 null 1000 null null
assert_eq 'talos: #8 qa done — 1k tokens · issue total 1k (qa 1k)' "$(line_for --issue 8)" \
  "null tool count and duration: both omitted"

# "Newest" is the last line of the file, not the greatest ts.
reset_log
ev qa 9 null 1000 1 10 2026-10-03T12:00:00Z
ev reviewer 9 null 2000 2 20 2026-10-03T01:00:00Z
assert_eq 'talos: #9 reviewer done — 2k tokens, 2 tools, 20s · issue total 3k (rev 2k, qa 1k)' "$(line_for --issue 9)" \
  "newest: last in file order, not by ts"

# Ties keep first-seen order.
reset_log; ev qa 9 null 1000 1 10; ev reviewer 9 null 1000 1 10
assert_contains "$(line_for --issue 9)" '(qa 1k, rev 1k)' "breakdown: equal tokens keep first-seen order"

# Abbreviations; other roles verbatim.
reset_log
ev validator 10 null 9000 1 1; ev pm 10 null 8000 1 1; ev planner 10 null 7000 1 1
ev developer 10 null 6000 1 1; ev adversarial 10 null 5000 1 1; ev security 10 null 4000 1 1
ev reviewer 10 null 3000 1 1; ev docs 10 null 2000 1 1; ev qa 10 null 1000 1 1
ev release-bot 10 null 500 1 1
assert_contains "$(line_for --issue 10)" '(val 9k, pm 8k, plan 7k, dev 6k, adv 5k, sec 4k, rev 3k, docs 2k, qa 1k, release-bot 500)' \
  "breakdown: abbreviations dev/adv/sec/rev/docs/qa/val/pm/plan, other roles verbatim, sorted descending"
assert_contains "$(line_for --issue 10)" 'talos: #10 release-bot done — 500 tokens' "head word: the role verbatim"

# ── (e) null tokens ────────────────────────────────────────────────────────
reset_log
ev developer 11 null 1000 1 5
ev qa 11 null null null 125
assert_eq 'talos: #11 qa done — tokens unrecorded, 2m05s · issue total 1k (+1 unrecorded) (dev 1k)' "$(line_for --issue 11)" \
  "null tokens: newest reads 'tokens unrecorded, <dur>'; (+K unrecorded) sits between the total and the breakdown"
reset_log
ev developer 11 null 1000 1 5
ev qa 11 null null 3 125
assert_contains "$(line_for --issue 11)" '— tokens unrecorded, 3 tools, 2m05s ·' \
  "null tokens with a recorded tool count: the count is kept"
reset_log
ev qa 11 null null null 5
ev reviewer 11 null null null 6
ev developer 11 null 1000 1 7
ev docs 11 null 2000 1 8
assert_eq 'talos: #11 docs done — 2k tokens, 1 tools, 8s · issue total 3k (+2 unrecorded) (docs 2k, dev 1k)' "$(line_for --issue 11)" \
  "unrecorded: K counts stage events; an all-unrecorded role is left out of the breakdown"
reset_log
ev qa 12 null null null 5
ev qa 12 null null null 125
assert_eq 'talos: #12 qa done — tokens unrecorded, 2m05s · issue total unrecorded' "$(line_for --issue 12)" \
  "no recorded events: 'issue total unrecorded', no breakdown, no (+K)"
reset_log
ev qa 12 null 0 1 5
assert_eq 'talos: #12 qa done — 0 tokens, 1 tools, 5s · issue total 0 (qa 0)' "$(line_for --issue 12)" \
  "a real 0 is printed as 0, never as unrecorded"
reset_log
ev qa 12 33 null null 5
assert_eq 'talos: #33 qa done — tokens unrecorded, 5s · PR total unrecorded' "$(bash "$EVENTS" cost --issue 12 --pr 33 --line 2>/dev/null)" \
  "no recorded events with --pr: 'PR total unrecorded'"

# ── (f) orchestrator excluded; nothing in, nothing out ─────────────────────
reset_log
ev developer 13 null 1000 1 5
ev orchestrator 13 null 777777 99 999
ev orchestrator 13 null null null null
assert_eq 'talos: #13 developer done — 1k tokens, 1 tools, 5s · issue total 1k (dev 1k)' "$(line_for --issue 13)" \
  "orchestrator events are excluded from the stage, the total and the unrecorded count"
reset_log
ev orchestrator 14 null 5 1 1
out="$(bash "$EVENTS" cost --issue 14 --line 2>&1)"; rc=$?
assert_eq "0" "$rc" "only orchestrator events: exit 0"
assert_eq "" "$out" "only orchestrator events: prints nothing"
out="$(bash "$EVENTS" cost --issue 999 --pr 1 --line 2>&1)"; rc=$?
assert_eq "0" "$rc" "no matching events: exit 0"
assert_eq "" "$out" "no matching events: prints nothing"
reset_log; ev developer 15 5 100 1 1
assert_eq "" "$(bash "$EVENTS" cost --issue 15 --pr 6 --line 2>&1)" "--pr that matches no event: prints nothing"
rm -f "$LOG"
out="$(bash "$EVENTS" cost --issue 15 --line 2>&1)"; rc=$?
assert_eq "0" "$rc" "missing log: exit 0"
assert_eq "" "$out" "missing log: prints nothing"

# A pr value that is a string in the log still matches.
reset_log
printf '{"event":"qa","role":"qa","issue":16,"pr":"77","tokens":10,"tool_uses":1,"duration_s":1}\n' >> "$LOG"
assert_contains "$(bash "$EVENTS" cost --issue 16 --pr 77 --line 2>/dev/null)" 'talos: #77 qa done' "--pr matches a string pr as well"
# Malformed lines are skipped, with the count on stderr only.
printf 'not json\n' >> "$LOG"
out="$(bash "$EVENTS" cost --issue 16 --pr 77 --line 2>"$SANDBOX/err.log")"
assert_contains "$out" 'talos: #77 qa done' "malformed line: skipped"
assert_contains "$(cat "$SANDBOX/err.log")" 'skipped 1 malformed' "malformed line: counted on stderr"

# ── (g) 200-character cut ──────────────────────────────────────────────────
# Roles r01..r30 with 300k, 290k, ... 10k tokens: every entry is "rNN 300k"
# (8 chars) or "rNN 90k" (7 chars) plus ", ". The newest event is r30 with
# 10k tokens.
reset_log
for i in $(seq 1 30); do
  ev "r$(printf '%02d' "$i")" 17 null $(( (31 - i) * 10000 )) 1 5
done
out="$(line_for --issue 17)"
PREFIX='talos: #17 r30 done — 10k tokens, 1 tools, 5s · issue total 4.65M ('
assert_eq "${PREFIX}r01 300k, r02 290k, r03 280k, r04 270k, r05 260k, r06 250k, r07 240k, r08 230k, r09 220k, r10 210k, r11 200k, r12 190k, r13 180k, …)" \
  "$out" "cut: whole trailing entries dropped, ', …)' closes the breakdown"
n="$(printf '%s' "$out" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
assert_eq "199" "$n" "cut: counted in characters (199; a 14th entry would make 209), not bytes"
# A short breakdown is never touched.
reset_log; ev developer 18 null 1000 1 5
assert_not_contains "$(line_for --issue 18)" '…' "no cut when the line already fits"
# Even a pathological role name keeps the line within 200 characters.
reset_log; ev "$(printf 'x%.0s' $(seq 1 250))" 19 null 1000 1 5
n="$(line_for --issue 19 | python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))')"
if [ "$n" -le 200 ]; then pass "cut: a very long role name still gives <= 200 characters"; else fail "cut: a very long role name still gives <= 200 characters" "got $n"; fi

# ── (h) --pr on the table and --json; --line without --issue ───────────────
reset_log
ev validator 20 null 100 1 1
ev developer 20 41   200 2 2
ev developer 20 42   400 4 4
ev qa 20 41 50 1 1
table="$(bash "$EVENTS" cost --issue 20 --pr 41 2>/dev/null)"
assert_eq "$(printf 'issue\trole\tevents\ttokens\ttool_uses\tduration_s\tunrecorded\trestamp\n20\tdeveloper\t1\t200\t2\t2\t0\t0\n20\tqa\t1\t50\t1\t1\t0\t0\nTOTAL\t\t2\t250\t3\t3\t0\t0')" \
  "$table" "--pr filters the table: only events whose pr matches"
chk="$(bash "$EVENTS" cost --issue 20 --pr 41 --json 2>/dev/null | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ok = sorted(r['role'] for r in d['rows']) == ['developer', 'qa'] and d['total']['tokens'] == 250 and d['total']['events'] == 2
print('OK' if ok else 'BAD:' + json.dumps(d))")"
assert_eq "OK" "$chk" "--pr filters --json"
whole="$(bash "$EVENTS" cost --issue 20 2>/dev/null)"
assert_contains "$whole" "$(printf 'TOTAL\t\t4\t750')" "no --pr: the table is unscoped by PR (unchanged)"
assert_contains "$whole" "$(printf '20\tvalidator\t1\t100')" "no --pr: a pr-null event is still counted"

rm -f "$LOG"
out="$(bash "$EVENTS" cost --line 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "2" "$rc" "--line without --issue: exit 2 (checked before the missing-log return)"
assert_eq "" "$out" "--line without --issue: nothing on stdout"
assert_contains "$(cat "$SANDBOX/err.log")" 'pipeline-events.sh cost' "--line without --issue: usage on stderr"
reset_log; ev developer 21 null 5 1 1
bash "$EVENTS" cost --pr 3 --line >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "--line with only --pr: exit 2"
out="$(bash "$EVENTS" cost --issue 21 --line --json 2>/dev/null)"
assert_contains "$out" 'talos: #21 developer done' "--line wins over --json"

# ── (i) a missing option value exits 2 with usage, promptly ────────────────
# bounded_rc SECS ARGS... -- runs the script with a wall-clock limit; prints
# the exit code, or HUNG if the limit was hit (the old `cost --issue` loop).
bounded_rc() {
  python3 - "$@" <<'PYEOF'
import subprocess, sys
secs, args = float(sys.argv[1]), sys.argv[2:]
try:
    p = subprocess.run(["bash"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=secs)
    sys.stderr.buffer.write(p.stderr)
    print(p.returncode)
except subprocess.TimeoutExpired:
    print("HUNG")
PYEOF
}
for opts in "--issue" "--pr" "--issue 5 --pr" "--pr 5 --issue" "--json --issue" "--line --issue 5 --pr"; do
  # shellcheck disable=SC2086
  rc="$(bounded_rc 10 "$EVENTS" cost $opts 2>"$SANDBOX/err.log")"
  assert_eq "2" "$rc" "cost $opts: exits 2 (not a hang) when the value is missing"
  assert_contains "$(cat "$SANDBOX/err.log")" 'Usage: pipeline-events.sh' "cost $opts: prints usage on stderr"
done

# ── (j) UTF-8 output regardless of the caller's locale ─────────────────────
reset_log
ev developer 22 null 1500 1 5
out="$(env -u PYTHONIOENCODING -u PYTHONUTF8 LC_ALL=C LANG=C bash "$EVENTS" cost --issue 22 --line 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "0" "$rc" "LC_ALL=C: exit 0"
assert_eq 'talos: #22 developer done — 2k tokens, 1 tools, 5s · issue total 2k (dev 2k)' "$out" "LC_ALL=C: the line is the same UTF-8 text"
assert_eq "" "$(cat "$SANDBOX/err.log")" "LC_ALL=C: no encoding error on stderr"

# A role name from the log cannot smuggle a talos:<word> token into the line.
reset_log; ev 'x talos:evil' 23 null 1000 1 5
out="$(line_for --issue 23)"
if grep -Eq 'talos:[a-z-]+' <<<"$out"; then
  fail "role name: no talos:<word> token even from a hostile role" "$out"
else
  pass "role name: no talos:<word> token even from a hostile role"
fi
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "role name: still one line"

finish
