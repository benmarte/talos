#!/usr/bin/env bash
# test-hand-note-event.sh -- the `hand_note` event: `pipeline-events.sh note`
# appends one for a hand intervention, and `post-approval` and the removal of
# pipeline:blocked record one when called outside a stage session and a run.
#   AC1 note appends one hand_note per kind: role, kind, issue, pr, body
#   AC2 a bad or missing argument exits 2 with the usage and appends nothing
#   AC3 the body is capped at 500 bytes on a character edge and stored as data
#   AC4 events.enabled false, an escaping, an unwritable and a custom events.path
#   AC5 list --event hand_note and tail show it; no cost form changes
#   AC6 a hand_note after a BLOCKED developer event leaves the issue Stuck
#   AC7 post-approval records approval-posted outside a stage and a run only
#   AC8 label-issue / label-pr --remove pipeline:blocked record unblocked likewise
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
unset TALOS_ROLE TALOS_RUN_STARTED

# field JSON-LINE KEY: one key from a JSON line (python3 -I).
field() {
  python3 -I -c '
import json, sys
try:
    v = json.loads(sys.argv[1]).get(sys.argv[2], "<absent>")
except ValueError:
    v = "<no event>"
print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"
}
lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
notes() { [ -f "$LOG" ] && grep -c '"event": "hand_note"' "$LOG" || echo 0; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
for K in spec-revised approval-posted unblocked relabelled code-pushed; do
  rm -f "$LOG"
  OUT="$(printf 'why %s' "$K" | bash "$EVENTS" note --issue 5 --kind "$K" --body-file - 2>"$SANDBOX/err")"; RC=$?
  assert_eq "0" "$RC" "AC1 $K exits 0"
  assert_eq "" "$OUT" "AC1 $K prints nothing on stdout"
  assert_eq "1" "$(lines)" "AC1 $K appends exactly one line"
  L="$(tail -n 1 "$LOG" 2>/dev/null)"
  assert_eq "hand_note" "$(field "$L" event)" "AC1 $K event is hand_note"
  assert_eq "orchestrator" "$(field "$L" role)" "AC1 $K role is orchestrator"
  assert_eq "$K" "$(field "$L" kind)" "AC1 $K kind"
  assert_eq "5" "$(field "$L" issue)" "AC1 $K issue"
  assert_eq "null" "$(field "$L" pr)" "AC1 $K pr is null without --pr"
  assert_eq "why $K" "$(field "$L" body)" "AC1 $K body from stdin"
  case "$(field "$L" ts)" in 20[0-9][0-9]-*T*Z) pass "AC1 $K ts is a UTC ISO-8601 stamp" ;; *) fail "AC1 $K ts is a UTC ISO-8601 stamp" "$L" ;; esac
done
rm -f "$LOG"
printf 'x' | bash "$EVENTS" note --issue 5 --pr 12 --kind code-pushed --body-file - 2>/dev/null
assert_eq "12" "$(field "$(tail -n 1 "$LOG")" pr)" "AC1 --pr M sets pr"
rm -f "$LOG"
bash "$EVENTS" note --issue 5 --kind unblocked </dev/null 2>/dev/null
assert_eq "null" "$(field "$(tail -n 1 "$LOG")" body)" "AC1 no --body-file gives a null body"

# ── AC2 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
bad() {  # <label> <args...>: exit 2 with the usage, nothing appended
  local label="$1"; shift
  OUT="$(printf 'b' | bash "$EVENTS" note "$@" 2>&1)"; RC=$?
  assert_eq "2" "$RC" "AC2 $label exits 2"
  assert_contains "$OUT" "Usage: pipeline-events.sh" "AC2 $label prints the usage"
  assert_contains "$OUT" "pipeline-events.sh note" "AC2 $label usage lists note"
  assert_eq "0" "$(lines)" "AC2 $label appends nothing"
}
bad "an unknown kind" --issue 5 --kind nope --body-file -
bad "a missing kind" --issue 5 --body-file -
bad "a missing issue" --kind unblocked --body-file -
bad "a non-digit issue" --issue 5x --kind unblocked --body-file -
bad "an empty issue" --issue '' --kind unblocked --body-file -
bad "a non-digit pr" --issue 5 --pr x --kind unblocked --body-file -
bad "--issue with no value" --kind unblocked --issue
bad "--pr with no value" --issue 5 --kind unblocked --pr
bad "--kind with no value" --issue 5 --kind
bad "--body-file with no value" --issue 5 --kind unblocked --body-file

# ── AC3 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
BODY='quote " back \ slash `tick` $(touch '"$SANDBOX"'/pwned) $HOME
second line'
printf '%s' "$BODY" | bash "$EVENTS" note --issue 5 --kind spec-revised --body-file - 2>/dev/null
assert_eq "1" "$(lines)" "AC3 a body with newlines and quotes stays one line"
assert_eq "$BODY" "$(field "$(tail -n 1 "$LOG")" body)" "AC3 quotes, backslashes, newlines, \$(...) and backticks are stored verbatim"
assert_file_absent "$SANDBOX/pwned" "AC3 nothing in the body is executed"
rm -f "$LOG"
python3 -I -c 'import sys; sys.stdout.write("a" * 600)' | bash "$EVENTS" note --issue 5 --kind spec-revised --body-file - 2>/dev/null
assert_eq "500" "$(python3 -I -c 'import json, sys; print(len(json.loads(sys.argv[1])["body"].encode()))' "$(tail -n 1 "$LOG")")" "AC3 a long body is cut at 500 bytes"
rm -f "$LOG"
# 499 ASCII bytes then a 3-byte character straddling the cap: the character goes whole.
python3 -I -c 'import sys; sys.stdout.write("a" * 499 + "€" * 3)' | bash "$EVENTS" note --issue 5 --kind spec-revised --body-file - 2>/dev/null
assert_eq "499 False" "$(python3 -I -c '
import json, sys
b = json.loads(sys.argv[1])["body"]
print(len(b.encode()), "�" in b)' "$(tail -n 1 "$LOG")")" "AC3 the cap never leaves a broken UTF-8 character"
rm -f "$LOG"
python3 -I -c 'import sys; sys.stdout.write("a" * 497 + "€" * 3)' | bash "$EVENTS" note --issue 5 --kind spec-revised --body-file - 2>/dev/null
assert_eq "500 False" "$(python3 -I -c '
import json, sys
b = json.loads(sys.argv[1])["body"]
print(len(b.encode()), "�" in b)' "$(tail -n 1 "$LOG")")" "AC3 a character that ends on the cap is kept"

# ── AC4 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
printf '%s' '{"events": {"enabled": false}}' > "$PIPELINE_CONFIG"
printf 'x' | bash "$EVENTS" note --issue 5 --kind unblocked --body-file - 2>/dev/null; RC=$?
assert_eq "0" "$RC" "AC4 events.enabled false: exit 0"
assert_file_absent "$LOG" "AC4 events.enabled false: no file written"
: > "$SANDBOX/afile"
printf '{"events": {"path": "%s/afile/x/events.jsonl"}}' "$SANDBOX" > "$PIPELINE_CONFIG"
printf 'x' | bash "$EVENTS" note --issue 5 --kind unblocked --body-file - >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "AC4 an unwritable events.path: exit 0"
assert_eq "1" "$(wc -l < "$SANDBOX/err" | tr -d ' ')" "AC4 an unwritable events.path: one stderr note"
printf '%s' '{"events": {"path": "../../escaped.jsonl"}}' > "$PIPELINE_CONFIG"
printf 'x' | bash "$EVENTS" note --issue 5 --kind unblocked --body-file - >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "0" "$RC" "AC4 an escaping relative events.path: exit 0"
assert_contains "$(cat "$SANDBOX/err")" "leaves the git common dir" "AC4 an escaping relative events.path is refused with a note"
assert_file_absent "$SANDBOX/../escaped.jsonl" "AC4 nothing is written outside the common dir"
printf '{"events": {"path": "%s/custom.jsonl"}}' "$SANDBOX" > "$PIPELINE_CONFIG"
printf 'x' | bash "$EVENTS" note --issue 5 --kind unblocked --body-file - 2>/dev/null; RC=$?
assert_eq "0" "$RC" "AC4 a custom events.path: exit 0"
assert_eq "hand_note" "$(field "$(tail -n 1 "$SANDBOX/custom.jsonl" 2>/dev/null)" event)" "AC4 a custom events.path is the file appended to"
assert_file_absent "$LOG" "AC4 the default log is untouched under a custom events.path"
rm -f "$SANDBOX/custom.jsonl"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"

# ── AC5 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
printf '{"event":"developer","role":"developer","issue":5,"pr":7,"verdict":"PR_OPENED","tokens":1000,"tool_uses":3,"duration_s":9,"ts":"2026-10-01T00:00:00Z"}\n' > "$LOG"
cost_forms() {
  bash "$EVENTS" cost 2>&1
  bash "$EVENTS" cost --json 2>&1
  bash "$EVENTS" cost --issue 5 --line 2>&1
  bash "$EVENTS" cost --issue 5 --markdown 2>&1
  bash "$EVENTS" cost --summary --issue 5 2>&1
}
BEFORE="$(cost_forms)"
printf 'x' | bash "$EVENTS" note --issue 5 --pr 7 --kind approval-posted --body-file - 2>/dev/null
assert_eq "1" "$(notes)" "AC5 the hand_note is in the log"
assert_contains "$(bash "$EVENTS" list --event hand_note 2>&1)" "hand_note" "AC5 list --event hand_note shows it"
assert_contains "$(bash "$EVENTS" tail --issue 5 2>&1)" "hand_note" "AC5 tail shows it"
assert_eq "$BEFORE" "$(cost_forms)" "AC5 no cost form changes after a hand_note"

# ── AC6: the map ────────────────────────────────────────────────────────────
MAP="$HOME/.talos/maps/acme-widget.html"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$LOG"
python3 -I -c '
import json, sys
print(json.dumps({"event": "developer", "role": "developer", "issue": 12, "pr": 22, "verdict": "BLOCKED",
                  "tokens": 100, "summary": "BLOCKED: spec: no criteria", "ts": sys.argv[1]}))' "$NOW" >> "$LOG"
card() {  # <issue>: the state class of the issue's card
  python3 -I -c '
import re, sys
m = re.search(r"<article class=\"card ([a-z]+)\"><h3><a href=\"https://github.com/acme/widget/issues/%s\">#%s</a>(.*?)</article>" % (sys.argv[2], sys.argv[2]), open(sys.argv[1]).read(), re.S)
print(m.group(1) if m else "<none>")' "$MAP" "$1"
}
printf 'spec fixed' | bash "$EVENTS" note --issue 12 --pr 22 --kind spec-revised --body-file - 2>/dev/null
bash "$TALOS_ROOT/scripts/talos.sh" map >/dev/null 2>"$SANDBOX/err"
assert_eq "stuck" "$(card 12)" "AC6 a hand_note after a BLOCKED developer event leaves the issue Stuck"

# ── AC7: post-approval ──────────────────────────────────────────────────────
git config user.email "test@talos.invalid"
git config user.name "talos-test"
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"
export STUB_CURRENT_USER=bot
CSTORE="$SANDBOX/cs.json"
LBL_QA='[{"name":"qa:pass"}]'
approve() {  # <extra args...>: a successful qa post-approval of PR 9; env as the caller sets it
  printf '[]' > "$CSTORE"
  STUB_COMMENT_STORE="$CSTORE" STUB_PR_HEAD_SHA="$STUB_SHA" STUB_PR_LABELS_JSON="$LBL_QA" \
    bash "$VCS" post-approval 9 qa "$@" >/dev/null 2>&1
}
rm -f "$LOG"; : > "$GH_LOG"
approve; RC=$?
assert_eq "0" "$RC" "AC7 post-approval succeeds with no stage role"
assert_eq "1" "$(notes)" "AC7 one hand_note is appended"
GH_PLAIN="$(wc -l < "$GH_LOG" | tr -d ' ')"
L="$(grep '"event": "hand_note"' "$LOG" | tail -n 1)"
assert_eq "approval-posted" "$(field "$L" kind)" "AC7 kind is approval-posted"
assert_eq "9" "$(field "$L" pr)" "AC7 pr is the PR"
assert_eq "null" "$(field "$L" issue)" "AC7 issue is null without --issue"
assert_eq "orchestrator" "$(field "$L" role)" "AC7 role is orchestrator"
rm -f "$LOG"
approve --issue 5
assert_eq "5" "$(field "$(grep '"event": "hand_note"' "$LOG" | tail -n 1)" issue)" "AC7 --issue sets issue"
rm -f "$LOG"; : > "$GH_LOG"
TALOS_ROLE= approve
assert_eq "1" "$(notes)" "AC7 an empty TALOS_ROLE counts as no stage"
rm -f "$LOG"; : > "$GH_LOG"
TALOS_ROLE=qa approve; RC=$?
assert_eq "0" "$RC" "AC7 post-approval still succeeds in a stage session"
assert_eq "0" "$(notes)" "AC7 TALOS_ROLE set: none appended"
assert_eq "$GH_PLAIN" "$(wc -l < "$GH_LOG" | tr -d ' ')" "AC7 the note costs no provider read"
rm -f "$LOG"
TALOS_RUN_STARTED=2026-10-18T00:00:00Z approve
assert_eq "0" "$(notes)" "AC7 TALOS_RUN_STARTED set: none appended"
rm -f "$LOG"
printf '[]' > "$CSTORE"
STUB_COMMENT_STORE="$CSTORE" STUB_PR_HEAD_SHA="$STUB_SHA" STUB_PR_LABELS_JSON="$LBL_QA" STUB_GH_API_FAIL=comments \
  bash "$VCS" post-approval 9 qa >/dev/null 2>&1; RC=$?
assert_eq "1" "$RC" "AC7 a failed post-approval exits 1"
assert_eq "0" "$(notes)" "AC7 a failed post-approval appends none"

# ── AC8: label-issue / label-pr --remove pipeline:blocked ──────────────────
FAILBIN="$SANDBOX/failbin"; mkdir -p "$FAILBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/gh"; chmod +x "$FAILBIN/gh"
for V in label-issue label-pr; do
  FIELD=issue; [ "$V" = label-pr ] && FIELD=pr
  OTHER=pr; [ "$V" = label-pr ] && OTHER=issue
  rm -f "$LOG"
  bash "$VCS" "$V" 7 --remove pipeline:blocked >/dev/null 2>&1; RC=$?
  assert_eq "0" "$RC" "AC8 $V --remove pipeline:blocked succeeds"
  assert_eq "1" "$(notes)" "AC8 $V appends one hand_note"
  L="$(grep '"event": "hand_note"' "$LOG" | tail -n 1)"
  assert_eq "unblocked" "$(field "$L" kind)" "AC8 $V kind is unblocked"
  assert_eq "7" "$(field "$L" "$FIELD")" "AC8 $V sets $FIELD"
  assert_eq "null" "$(field "$L" "$OTHER")" "AC8 $V leaves $OTHER null"
  rm -f "$LOG"
  bash "$VCS" "$V" 7 --add pipeline:dev --remove pipeline:blocked >/dev/null 2>&1
  assert_eq "1" "$(notes)" "AC8 $V notes a removal beside an add"
  rm -f "$LOG"
  TALOS_ROLE=developer bash "$VCS" "$V" 7 --remove pipeline:blocked >/dev/null 2>&1
  assert_eq "0" "$(notes)" "AC8 $V under a stage role: none"
  TALOS_RUN_STARTED=2026-10-18T00:00:00Z bash "$VCS" "$V" 7 --remove pipeline:blocked >/dev/null 2>&1
  assert_eq "0" "$(notes)" "AC8 $V inside a run: none"
  PATH="$FAILBIN:$PATH" bash "$VCS" "$V" 7 --remove pipeline:blocked >/dev/null 2>&1; RC=$?
  assert_eq "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "AC8 $V fails when the provider call fails"
  assert_eq "0" "$(notes)" "AC8 $V failed call: none"
  bash "$VCS" "$V" 7 --remove pipeline:review >/dev/null 2>&1
  bash "$VCS" "$V" 7 --add pipeline:blocked >/dev/null 2>&1
  assert_eq "0" "$(notes)" "AC8 $V not removing pipeline:blocked: none"
done

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-hand-note-event: %d passed\n' "$_PASS"
