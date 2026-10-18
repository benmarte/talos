#!/usr/bin/env bash
# test-events-scoreboard.sh -- `pipeline-events.sh scoreboard`: the events log
# summarised per repo and per ISO week, read from the log only.
#   AC1 two merged PRs in one week make one row with merged 2; --json agrees
#   AC2 a merged run whose issue has a hand_note is not hands-free
#   AC3 fix rounds (developer events - 1, floored at 0), tokens, tokens_unrecorded
#   AC4 run_end by reason and finding_outcome by stage/outcome, in the event's week
#   AC5 --repo, an event without repo attributed through its issue, --since
#   AC6 a missing, empty or all-malformed log prints the header only, exit 0
#   AC7 a bad --since or an option with no value exits 2 with the usage
#   AC8 no provider call without a merged event (the reverts and fix-forwards
#       reads are in test-events-reverts-fixforwards-800.sh), the log is unchanged
#   AC9 list, tail, cost and note behave as before
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
unset TALOS_ROLE TALOS_RUN_STARTED

HEADER="$(printf 'repo\tweek\tmerged\thands_free\tfix_rounds_per_pr\ttokens_per_pr\trun_ends\tfinding_outcomes\treverts\tfix_forwards')"
W42="2026-10-14T10:00:00Z"   # ISO week 2026-W42 (Mon 2026-10-12 .. Sun 2026-10-18)
W43="2026-10-20T10:00:00Z"   # ISO week 2026-W43

# ev TS EVENT ROLE ISSUE PR REPO [EXTRA-JSON-MEMBERS]: append one event line.
ev() {
  python3 -I -c '
import json, sys
ts, event, role, issue, pr, repo = sys.argv[1:7]
rec = {"ts": ts, "event": event, "role": role,
       "issue": int(issue) if issue else None, "pr": int(pr) if pr else None}
if repo:
    rec["repo"] = repo
if len(sys.argv) > 7:
    rec.update(json.loads(sys.argv[7]))
print(json.dumps(rec))' "$@" >> "$LOG"
}
fresh() { rm -f "$LOG"; mkdir -p "$(dirname "$LOG")"; : > "$LOG"; }
sb() { bash "$EVENTS" scoreboard "$@" 2>"$SANDBOX/err"; }
# jq-ish: jget JSON PYEXPR -> prints the value of the python expression on `d`.
jget() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2])))' "$1" "$2"; }
# row N of the table (1 = first data row), tab-separated.
row() { printf '%s\n' "$1" | sed -n "$(($2 + 1))p"; }
cell() { printf '%s' "$1" | cut -f"$2"; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 1000}'
ev "$W42" merged orchestrator 1 10 acme/widget
ev "$W42" developer developer 2 11 acme/widget '{"tokens": 3000}'
ev "$W42" merged orchestrator 2 11 acme/widget
OUT="$(sb)"; RC=$?
assert_eq "0" "$RC" "AC1 exits 0"
assert_eq "$HEADER" "$(row "$OUT" 0 | sed -n 1p)" "AC1 header"
assert_eq "2" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "AC1 header plus one row"
assert_eq "acme/widget" "$(cell "$(row "$OUT" 1)" 1)" "AC1 row repo"
assert_eq "2026-W42" "$(cell "$(row "$OUT" 1)" 2)" "AC1 row week"
assert_eq "2" "$(cell "$(row "$OUT" 1)" 3)" "AC1 row merged 2"
J="$(sb --json)"; RC=$?
assert_eq "0" "$RC" "AC1 --json exits 0"
assert_eq "1" "$(jget "$J" 'len(d["rows"])')" "AC1 --json one row"
assert_eq "2" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC1 --json merged 2"
assert_eq '"acme/widget"' "$(jget "$J" 'd["rows"][0]["repo"]')" "AC1 --json repo"
assert_eq '"2026-W42"' "$(jget "$J" 'd["rows"][0]["week"]')" "AC1 --json week"
# the same merged event twice counts once
ev "$W42" merged orchestrator 2 11 acme/widget
assert_eq "2" "$(jget "$(sb --json)" 'd["rows"][0]["merged"]')" "AC1 a repeated (issue, pr) merged counts once"

# ── AC2 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" merged orchestrator 1 10 acme/widget
ev "$W42" merged orchestrator 2 11 acme/widget
ev "2026-09-01T00:00:00Z" hand_note orchestrator 1 "" "" '{"kind": "unblocked"}'
J="$(sb --json)"
assert_eq "2" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC2 both runs are merged"
assert_eq "1" "$(jget "$J" 'd["rows"][0]["hands_free"]')" "AC2 the run with a hand_note (any ts) is not hands-free"
assert_eq "1" "$(cell "$(row "$(sb)" 1)" 4)" "AC2 table hands_free"

# ── AC3 ─────────────────────────────────────────────────────────────────────
fresh
# PR 10: three developer events (2 fix rounds), tokens 100+200+50 from non-orchestrator, orchestrator tokens left out
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 100}'
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 200}'
ev "$W42" developer developer 1 10 acme/widget '{"tokens": null}'
ev "$W42" qa qa 1 10 acme/widget '{"tokens": 50}'
ev "$W42" stage_attempt developer 1 10 acme/widget '{"tokens": 7}'
ev "$W42" merged orchestrator 1 10 acme/widget '{"tokens": 999999}'
# PR 11: one developer event (0 fix rounds), tokens 400
ev "$W42" developer developer 2 11 acme/widget '{"tokens": 400}'
ev "$W42" merged orchestrator 2 11 acme/widget
# PR 12: no developer event (floored at 0), no non-null tokens
ev "$W42" qa qa 3 12 acme/widget '{"tokens": null}'
ev "$W42" merged orchestrator 3 12 acme/widget
J="$(sb --json)"
assert_eq "3" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC3 three merged PRs"
assert_eq "2" "$(jget "$J" 'd["rows"][0]["fix_rounds"]')" "AC3 fix rounds: developer events minus 1, floored at 0"
assert_eq "757" "$(jget "$J" 'd["rows"][0]["tokens"]')" "AC3 tokens: non-orchestrator sum (stage_attempt counted, merged not)"
assert_eq "1" "$(jget "$J" 'd["rows"][0]["tokens_unrecorded"]')" "AC3 the PR with no non-null tokens is unrecorded"
T="$(row "$(sb)" 1)"
assert_eq "0.7" "$(cell "$T" 5)" "AC3 table fix_rounds_per_pr one decimal"
assert_eq "252" "$(cell "$T" 6)" "AC3 table tokens_per_pr whole number"
fresh
ev "$W42" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
T="$(row "$(sb)" 1)"
assert_eq "-" "$(cell "$T" 5)" "AC3 fix_rounds_per_pr is - with no merged PR"
assert_eq "-" "$(cell "$T" 6)" "AC3 tokens_per_pr is - with no merged PR"

# ── AC4 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
ev "$W42" run_end orchestrator 2 "" acme/widget '{"reason": "idle"}'
ev "$W42" run_end orchestrator 3 "" acme/widget '{"reason": "blocked"}'
ev "$W42" run_end orchestrator 4 "" acme/widget '{"reason": null}'
ev "$W42" finding_outcome orchestrator 1 10 acme/widget '{"stage": "reviewer", "outcome": "fixed"}'
ev "$W42" finding_outcome orchestrator 1 10 acme/widget '{"stage": "reviewer", "outcome": "fixed"}'
ev "$W42" finding_outcome orchestrator 1 10 acme/widget '{"stage": "security", "outcome": "wrong"}'
ev "$W43" run_end orchestrator 5 "" acme/widget '{"reason": "idle"}'
ev "$W43" finding_outcome orchestrator 5 11 acme/widget '{"stage": "reviewer", "outcome": "unclassified"}'
J="$(sb --json)"
assert_eq "2" "$(jget "$J" 'len(d["rows"])')" "AC4 two ISO weeks make two rows"
assert_eq '["2026-W42", "2026-W43"]' "$(jget "$J" '[r["week"] for r in d["rows"]]')" "AC4 rows sorted by week"
assert_eq '{"blocked": 1, "idle": 2, "none": 1}' "$(jget "$J" 'd["rows"][0]["run_ends"]')" "AC4 run_end by reason, null reads none"
assert_eq '{"reviewer": {"fixed": 2}, "security": {"wrong": 1}}' "$(jget "$J" 'd["rows"][0]["finding_outcomes"]')" "AC4 finding_outcome by stage then outcome"
assert_eq '{"idle": 1}' "$(jget "$J" 'd["rows"][1]["run_ends"]')" "AC4 second week run_ends"
assert_eq '{"reviewer": {"unclassified": 1}}' "$(jget "$J" 'd["rows"][1]["finding_outcomes"]')" "AC4 second week finding_outcomes"
assert_eq "0" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC4 a row with no merged run has merged 0"
OUT="$(sb)"
assert_eq "blocked:1,idle:2,none:1" "$(cell "$(row "$OUT" 1)" 7)" "AC4 table run_ends"
assert_eq "reviewer/fixed:2,security/wrong:1" "$(cell "$(row "$OUT" 1)" 8)" "AC4 table finding_outcomes"
# an empty run_ends / finding_outcomes cell is -
fresh
ev "$W42" merged orchestrator 1 10 acme/widget
T="$(row "$(sb)" 1)"
assert_eq "-" "$(cell "$T" 7)" "AC4 empty run_ends is -"
assert_eq "-" "$(cell "$T" 8)" "AC4 empty finding_outcomes is -"

# ── AC5 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 100}'
ev "$W42" merged orchestrator 1 10 acme/widget
ev "$W42" developer developer 2 20 acme/other '{"tokens": 100}'
ev "$W42" merged orchestrator 2 20 acme/other
# no repo of its own: takes the repo of issue 2's other events
ev "$W42" finding_outcome orchestrator 2 20 "" '{"stage": "reviewer", "outcome": "fixed"}'
# no event of issue 9 carries a repo: attributed to -
ev "$W42" finding_outcome orchestrator 9 30 "" '{"stage": "qa", "outcome": "fixed"}'
J="$(sb --json)"
assert_eq '["-", "acme/other", "acme/widget"]' "$(jget "$J" '[r["repo"] for r in d["rows"]]')" "AC5 rows sorted by repo; unknown repo is -"
assert_eq '{"reviewer": {"fixed": 1}}' "$(jget "$J" '[r for r in d["rows"] if r["repo"] == "acme/other"][0]["finding_outcomes"]')" "AC5 an event without repo takes its issue's repo"
J="$(sb --json --repo acme/widget)"
assert_eq '["acme/widget"]' "$(jget "$J" '[r["repo"] for r in d["rows"]]')" "AC5 --repo keeps one repo's rows"
assert_eq "1" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC5 --repo row counts"
assert_eq '[]' "$(jget "$(sb --json --repo acme/wid)" 'd["rows"]')" "AC5 --repo matches exactly"
# --since drops earlier merged / run_end / finding_outcome, not the lookups
fresh
ev "2026-10-01T10:00:00Z" developer developer 1 10 acme/widget '{"tokens": 100}'
ev "2026-10-01T10:00:00Z" developer developer 1 10 acme/widget '{"tokens": 100}'
ev "2026-10-02T10:00:00Z" merged orchestrator 1 10 acme/widget
ev "2026-10-14T10:00:00Z" developer developer 2 11 acme/widget '{"tokens": 500}'
ev "2026-10-14T10:00:00Z" developer developer 2 11 acme/widget '{"tokens": 500}'
ev "2026-10-15T10:00:00Z" merged orchestrator 2 11 acme/widget
ev "2026-10-01T10:00:00Z" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
ev "2026-10-01T10:00:00Z" finding_outcome orchestrator 1 10 acme/widget '{"stage": "reviewer", "outcome": "fixed"}'
ev "2026-10-01T10:00:00Z" hand_note orchestrator 2 "" "" '{"kind": "unblocked"}'
ev "2026-10-14T10:00:00Z" run_end orchestrator 2 "" acme/widget '{"reason": "blocked"}'
J="$(sb --json --since 2026-10-14)"
assert_eq '["2026-W42"]' "$(jget "$J" '[r["week"] for r in d["rows"]]')" "AC5 --since drops the earlier week"
assert_eq "1" "$(jget "$J" 'd["rows"][0]["merged"]')" "AC5 --since keeps the later merged"
assert_eq '{"blocked": 1}' "$(jget "$J" 'd["rows"][0]["run_ends"]')" "AC5 --since drops the earlier run_end"
assert_eq '{}' "$(jget "$J" 'd["rows"][0]["finding_outcomes"]')" "AC5 --since drops the earlier finding_outcome"
assert_eq "1" "$(jget "$J" 'd["rows"][0]["fix_rounds"]')" "AC5 --since leaves the developer-event lookup unfiltered"
assert_eq "0" "$(jget "$J" 'd["rows"][0]["hands_free"]')" "AC5 --since leaves the hand_note lookup unfiltered"
assert_eq "1000" "$(jget "$J" 'd["rows"][0]["tokens"]')" "AC5 --since leaves the token lookup unfiltered"
assert_eq "2" "$(jget "$(sb --json --since 2026-10-01)" 'sum(r["merged"] for r in d["rows"])')" "AC5 --since on the date itself keeps it"

# ── AC6 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(sb)"; RC=$?
assert_eq "0" "$RC" "AC6 missing log exits 0"
assert_eq "$HEADER" "$OUT" "AC6 missing log prints the header only"
assert_eq '{"rows": []}' "$(sb --json)" "AC6 missing log --json"
fresh
OUT="$(sb)"; RC=$?
assert_eq "0" "$RC" "AC6 empty log exits 0"
assert_eq "$HEADER" "$OUT" "AC6 empty log prints the header only"
assert_eq '{"rows": []}' "$(sb --json)" "AC6 empty log --json"
printf 'not json\n[1, 2]\n{"ts": \n' > "$LOG"
OUT="$(sb)"; RC=$?
assert_eq "0" "$RC" "AC6 all-malformed log exits 0"
assert_eq "$HEADER" "$OUT" "AC6 all-malformed log prints the header only"
assert_eq '{"rows": []}' "$(sb --json)" "AC6 all-malformed log --json"
assert_contains "$(cat "$SANDBOX/err")" "skipped" "AC6 one stderr note for the malformed lines"
fresh
ev "$W42" merged orchestrator 1 10 acme/widget
printf 'broken line\n' >> "$LOG"
OUT="$(sb)"
assert_eq "1" "$(cell "$(row "$OUT" 1)" 3)" "AC6 a malformed line among good ones is skipped"
assert_eq "1" "$(grep -c skipped "$SANDBOX/err")" "AC6 skipped lines are reported once"

# ── AC7 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" merged orchestrator 1 10 acme/widget
bad() {  # <label> <args...>: exit 2 with the usage, nothing on stdout
  local label="$1"; shift
  OUT="$(bash "$EVENTS" scoreboard "$@" 2>"$SANDBOX/err")"; RC=$?
  assert_eq "2" "$RC" "AC7 $label exits 2"
  assert_eq "" "$OUT" "AC7 $label prints nothing on stdout"
  assert_contains "$(cat "$SANDBOX/err")" "Usage: pipeline-events.sh" "AC7 $label prints the usage"
  assert_contains "$(cat "$SANDBOX/err")" "pipeline-events.sh scoreboard" "AC7 $label usage lists scoreboard"
}
bad "a non-date --since" --since yesterday
bad "an impossible date" --since 2026-13-45
bad "a short date" --since 2026-10
bad "a trailing-junk date" --since 2026-10-14x
bad "an empty --since" --since ''
bad "--since with no value" --since
bad "--repo with no value" --repo
bad "--json then --since with no value" --json --since

# ── AC8 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
ev "$W42" finding_outcome orchestrator 1 10 acme/widget '{"stage": "reviewer", "outcome": "fixed"}'
BEFORE="$(cksum < "$LOG")"
: > "$GH_LOG"; : > "$CURL_LOG"
sb >/dev/null; sb --json --since 2026-10-01 --repo acme/widget >/dev/null
assert_eq "$BEFORE" "$(cksum < "$LOG")" "AC8 the log is unchanged"
assert_eq "0" "$(wc -c < "$GH_LOG" | tr -d ' ')" "AC8 no gh call"
assert_eq "0" "$(wc -c < "$CURL_LOG" | tr -d ' ')" "AC8 no curl call"

# ── AC9 ─────────────────────────────────────────────────────────────────────
fresh
ev "$W42" merged orchestrator 1 10 acme/widget
ev "$W42" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
OUT="$(bash "$EVENTS" list --event merged 2>/dev/null)"
assert_contains "$OUT" "merged" "AC9 list still prints events"
assert_eq "2" "$(bash "$EVENTS" tail 2>/dev/null | wc -l | tr -d ' ')" "AC9 tail still prints events"
bash "$EVENTS" cost --json >"$SANDBOX/cost.out" 2>/dev/null; RC=$?
assert_eq "0" "$RC" "AC9 cost --json still exits 0"
assert_eq "true" "$(python3 -I -c 'import json, sys; print(str("rows" in json.load(open(sys.argv[1]))).lower())' "$SANDBOX/cost.out")" "AC9 cost --json still has its rows"
printf 'x' | bash "$EVENTS" note --issue 5 --kind unblocked --body-file - 2>/dev/null
assert_eq "1" "$(grep -c '"event": "hand_note"' "$LOG")" "AC9 note still appends a hand_note"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-events-scoreboard: %d passed\n' "$_PASS"
