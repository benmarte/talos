#!/usr/bin/env bash
# test-hand-stage-events-897.sh -- a hand-driven run (no TALOS_ROLE, no
# TALOS_RUN_STARTED) logs the role, pr-opened and merged events its verbs prove,
# tagged "source": "hand".
#   AC1  post-approval 12 qa --issue 7 appends one qa event: verdict PASS, issue, pr, sha, source hand
#   AC2  its hand_note carries stage <role> and keeps role orchestrator, for all five roles
#   AC3  the verdict per role: APPROVED, CLEAR, PASS, pass, approve
#   AC4  TALOS_ROLE / TALOS_RUN_STARTED set: no role event
#   AC5  no --issue: the issue comes from the PR's head ref; none there: no role event
#   AC6  pipeline-notify.sh merged writes one merged event, once per PR
#   AC7  draft-pr / ready-pr write pr-opened, once per PR, outside a stage only
#   AC8  talos-map.py shows the stages done and the issue merged from those events alone
#   AC9  an unwritable or escaping events.path, events.enabled false: exit code and stdout unchanged
#   AC10 hand_event / hand_note --role with a bad argument exit 2 and append nothing
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
BASE_CFG='{"vcs": {"provider": "github", "repo": "acme/widget"}}'
printf '%s\n' "$BASE_CFG" > "$PIPELINE_CONFIG"
unset TALOS_ROLE TALOS_RUN_STARTED PIPELINE_PR
git config user.email "test@talos.invalid"
git config user.name "talos-test"
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"
export STUB_CURRENT_USER=bot
export STUB_PR_HEAD_SHA="$STUB_SHA"
CSTORE="$SANDBOX/cs.json"

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
count() { [ -f "$LOG" ] && { grep -c "\"event\": \"$1\"" "$LOG" || true; } || echo 0; }
last() { grep "\"event\": \"$1\"" "$LOG" 2>/dev/null | tail -n 1; }
label_of() {
  case "$1" in
    reviewer) echo '[{"name":"review:approved"}]' ;;
    security) echo '[{"name":"security:approved"}]' ;;
    docs) echo '[{"name":"docs:done"}]' ;;
    adversarial) echo '[{"name":"adversarial:approved"}]' ;;
    *) echo '[{"name":"qa:pass"}]' ;;
  esac
}
approve() {  # <role> <extra args...>: post-approval of PR 12; env as the caller sets it
  local role="$1"; shift
  printf '[]' > "$CSTORE"
  printf 'review text\n' > "$SANDBOX/body.md"
  STUB_COMMENT_STORE="$CSTORE" STUB_PR_LABELS_JSON="$(label_of "$role")" \
    bash "$VCS" post-approval 12 "$role" --body-file "$SANDBOX/body.md" "$@" 2>/dev/null
}

# ── AC1 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(approve qa --issue 7)"; RC=$?
assert_eq "0" "$RC" "AC1 post-approval succeeds"
assert_eq "post-approval: PR #12 qa marker posted and qa:pass label applied; stamp ok" "$OUT" "AC1 stdout is the one result line"
assert_eq "1" "$(count qa)" "AC1 exactly one qa event"
L="$(last qa)"
assert_eq "qa" "$(field "$L" role)" "AC1 role is qa"
assert_eq "PASS" "$(field "$L" verdict)" "AC1 verdict is PASS"
assert_eq "7" "$(field "$L" issue)" "AC1 issue"
assert_eq "12" "$(field "$L" pr)" "AC1 pr"
assert_eq "$STUB_SHA" "$(field "$L" sha)" "AC1 sha is the head the marker stamped"
assert_eq "hand" "$(field "$L" source)" "AC1 source is hand"
case "$(field "$L" ts)" in 20[0-9][0-9]-*T*Z) pass "AC1 ts is a UTC ISO-8601 stamp" ;; *) fail "AC1 ts is a UTC ISO-8601 stamp" "$L" ;; esac

# ── AC2 / AC3 ───────────────────────────────────────────────────────────────
for PAIR in reviewer:APPROVED security:CLEAR qa:PASS docs:pass adversarial:approve; do
  R="${PAIR%%:*}"; V="${PAIR#*:}"
  rm -f "$LOG"
  approve "$R" --issue 7 >/dev/null
  assert_eq "$V" "$(field "$(last "$R")" verdict)" "AC3 $R verdict is $V"
  assert_eq "1" "$(count "$R")" "AC3 $R appends one role event"
  N="$(last hand_note)"
  assert_eq "$R" "$(field "$N" stage)" "AC2 $R hand_note carries stage $R"
  assert_eq "orchestrator" "$(field "$N" role)" "AC2 $R hand_note keeps role orchestrator"
  assert_eq "approval-posted" "$(field "$N" kind)" "AC2 $R hand_note kind"
done

# ── AC4 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
TALOS_ROLE=qa approve qa --issue 7 >/dev/null
assert_eq "0" "$(count qa)" "AC4 TALOS_ROLE set: no role event"
assert_eq "0" "$(count hand_note)" "AC4 TALOS_ROLE set: no hand_note, as before"
TALOS_RUN_STARTED=2026-10-18T00:00:00Z approve qa --issue 7 >/dev/null
assert_eq "0" "$(count qa)" "AC4 TALOS_RUN_STARTED set: no role event"
assert_eq "0" "$(count hand_note)" "AC4 TALOS_RUN_STARTED set: no hand_note, as before"
TALOS_ROLE= approve qa --issue 7 >/dev/null
assert_eq "1" "$(count qa)" "AC4 an empty TALOS_ROLE counts as no stage"

# ── AC5 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(STUB_PR_HEAD_REF_NAME=fix/issue-7-x approve qa)"; RC=$?
assert_eq "7" "$(field "$(last qa)" issue)" "AC5 no --issue: the issue is the head ref's (fix/issue-7-x gives 7)"
assert_eq "0" "$RC" "AC5 exit code unchanged"
rm -f "$LOG"
OUT2="$(STUB_PR_HEAD_REF_NAME=feat/no-number approve qa)"; RC2=$?
assert_eq "0" "$(count qa)" "AC5 a head ref with no issue number writes no role event"
assert_eq "0" "$RC2" "AC5 ...and the exit code is unchanged"
assert_eq "$OUT" "$OUT2" "AC5 ...and so is the stdout"
rm -f "$LOG"
STUB_PR_HEAD_REF_NAME=fix/issue-9-x approve qa --issue 7 >/dev/null
assert_eq "7" "$(field "$(last qa)" issue)" "AC5 --issue wins over the head ref"

# ── AC6 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
bash "$NOTIFY" merged '#7' 'PR #12 merged' >/dev/null 2>&1; RC=$?
assert_eq "0" "$RC" "AC6 notify exits 0"
assert_eq "1" "$(count merged)" "AC6 one merged event"
L="$(last merged)"
assert_eq "orchestrator" "$(field "$L" role)" "AC6 role is orchestrator"
assert_eq "7" "$(field "$L" issue)" "AC6 issue"
assert_eq "12" "$(field "$L" pr)" "AC6 pr"
assert_eq "hand" "$(field "$L" source)" "AC6 source is hand"
bash "$NOTIFY" merged '#7' 'PR #12 merged' >/dev/null 2>&1
assert_eq "1" "$(count merged)" "AC6 a second call appends nothing"
bash "$NOTIFY" merged '#7' 'PR #13 merged' >/dev/null 2>&1
assert_eq "2" "$(count merged)" "AC6 another PR gets its own"
rm -f "$LOG"
TALOS_ROLE=orchestrator bash "$NOTIFY" merged '#7' 'PR #12 merged' >/dev/null 2>&1
TALOS_RUN_STARTED=2026-10-18T00:00:00Z bash "$NOTIFY" merged '#7' 'PR #12 merged' >/dev/null 2>&1
assert_eq "0" "$(count merged)" "AC6 TALOS_ROLE / TALOS_RUN_STARTED set: none"
PIPELINE_PR=14 bash "$NOTIFY" merged '#7' 'merged' >/dev/null 2>&1
assert_eq "14" "$(field "$(last merged)" pr)" "AC6 PIPELINE_PR names the PR when the message does not"
rm -f "$LOG"
bash "$NOTIFY" merged '#7' 'merged, no PR number' >/dev/null 2>&1
bash "$NOTIFY" merged 'no-issue' 'PR #12 merged' >/dev/null 2>&1
assert_eq "0" "$(count merged)" "AC6 no issue or no PR: no event"
bash "$NOTIFY" pr-opened '#7' 'PR #12 opened' >/dev/null 2>&1
assert_eq "0" "$(lines)" "AC6 other notify events write nothing"

# ── AC7 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
OUT="$(bash "$VCS" draft-pr 12 --issue 7 2>/dev/null)"; RC=$?
assert_eq "0" "$RC" "AC7 draft-pr succeeds"
assert_eq "PR #12 is a draft again" "$OUT" "AC7 draft-pr stdout is unchanged"
assert_eq "1" "$(count pr-opened)" "AC7 draft-pr appends one pr-opened"
L="$(last pr-opened)"
assert_eq "orchestrator" "$(field "$L" role)" "AC7 role is orchestrator"
assert_eq "7" "$(field "$L" issue)" "AC7 issue"
assert_eq "12" "$(field "$L" pr)" "AC7 pr"
assert_eq "hand" "$(field "$L" source)" "AC7 source is hand"
OUT="$(bash "$VCS" ready-pr 12 --issue 7 2>/dev/null)"; RC=$?
assert_eq "PR #12 is ready for review" "$OUT" "AC7 ready-pr stdout is unchanged"
assert_eq "1" "$(count pr-opened)" "AC7 the second of the two appends nothing"
rm -f "$LOG"
bash "$VCS" ready-pr 12 --issue 7 >/dev/null 2>&1
assert_eq "1" "$(count pr-opened)" "AC7 ready-pr writes it too"
rm -f "$LOG"
TALOS_ROLE=developer bash "$VCS" ready-pr 12 --issue 7 >/dev/null 2>&1
TALOS_RUN_STARTED=2026-10-18T00:00:00Z bash "$VCS" draft-pr 12 --issue 7 >/dev/null 2>&1
assert_eq "0" "$(count pr-opened)" "AC7 TALOS_ROLE / TALOS_RUN_STARTED set: none"
FAILBIN="$SANDBOX/failbin"; mkdir -p "$FAILBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/gh"; chmod +x "$FAILBIN/gh"
PATH="$FAILBIN:$PATH" bash "$VCS" ready-pr 12 --issue 7 >/dev/null 2>&1; RC=$?
assert_eq "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "AC7 a failed call exits non-zero"
assert_eq "0" "$(count pr-opened)" "AC7 a failed call appends nothing"
rm -f "$LOG"
STUB_PR_HEAD_REF_NAME=fix/issue-8-x bash "$VCS" ready-pr 12 >/dev/null 2>&1
assert_eq "8" "$(field "$(last pr-opened)" issue)" "AC7 without --issue the head ref names it"

# ── AC8: the map ────────────────────────────────────────────────────────────
rm -f "$LOG"
approve reviewer --issue 7 >/dev/null
approve qa --issue 7 >/dev/null
approve docs --issue 7 >/dev/null
MAP="$HOME/.talos/maps/acme-widget.html"
bash "$TALOS_ROOT/scripts/talos.sh" map >/dev/null 2>"$SANDBOX/err"
card_of() {  # <issue>: the id of the section the issue's card sits in
  python3 -I -c '
import re, sys
html = open(sys.argv[1]).read()
link = "issues/%s\">#%s</a>" % (sys.argv[2], sys.argv[2])
for m in re.finditer(r"<section([^>]*)>(.*?)</section>", html, re.S):
    if link in m.group(2):
        i = re.search(r"id=\"(\w+)\"", m.group(1))
        h = re.search(r"<h2>(\w+)", m.group(2))
        print(i.group(1) if i else h.group(1).lower() if h else "<unnamed>"); break
else:
    print("<none>")' "$MAP" "$1"
}
bar_of() {  # <issue>: the stage bar of the issue's card, "<step>=<d|-> ..." (d: done)
  python3 -I -c '
import re, sys
html = open(sys.argv[1]).read()
i = html.find("issues/%s\">#%s</a>" % (sys.argv[2], sys.argv[2]))
m = re.search(r"<ol class=\"steps\">(.*?)</ol>", html[i:], re.S) if i >= 0 else None
print(" ".join("%s=%s" % (n, "d" if "d" in c.split() else "-") for c, n in re.findall(r"<li class=\"s([^\"]*)\">(\w+)</li>", m.group(1))) if m else "<none>")' "$MAP" "$1"
}
merge_step() {  # the merge step state for issue 7, from the map own steps() over the log
  python3 -I -B -c '
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("talos_map", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
evs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
print(dict(m.steps([e for e in evs if e.get("issue") == 7], {}))["merge"])' "$TALOS_ROOT/scripts/talos-map.py" "$LOG"
}
assert_eq "flight" "$(card_of 7)" "AC8 without merged the issue is in flight, not in the merged tier"
S="$(bar_of 7)"
assert_contains "$S" "review=d" "AC8 review step done"
assert_contains "$S" "qa=d" "AC8 qa step done"
assert_contains "$S" "docs=d" "AC8 docs step done"
assert_contains "$S" "merge=-" "AC8 merge step not done before merged"
assert_eq "notreached" "$(merge_step)" "AC8 steps() leaves merge not reached without merged"
bash "$NOTIFY" merged '#7' 'PR #12 merged' >/dev/null 2>&1
bash "$TALOS_ROOT/scripts/talos.sh" map >/dev/null 2>"$SANDBOX/err"
assert_eq "done" "$(merge_step)" "AC8 merge step done after merged"
assert_eq "merged" "$(card_of 7)" "AC8 the issue is in the merged tier"

# ── AC9 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
run_all() {  # the four verbs, stdout and exit codes on one stream
  approve qa --issue 7; echo "rc=$?"
  bash "$VCS" draft-pr 12 --issue 7 2>/dev/null; echo "rc=$?"
  bash "$VCS" ready-pr 12 --issue 7 2>/dev/null; echo "rc=$?"
  bash "$NOTIFY" merged '#7' 'PR #12 merged' 2>/dev/null; echo "rc=$?"
}
GOOD="$(run_all)"
: > "$SANDBOX/afile"
for CFG in \
  '{"vcs": {"provider": "github", "repo": "acme/widget"}, "events": {"enabled": false}}' \
  "{\"vcs\": {\"provider\": \"github\", \"repo\": \"acme/widget\"}, \"events\": {\"path\": \"$SANDBOX/afile/x/events.jsonl\"}}" \
  '{"vcs": {"provider": "github", "repo": "acme/widget"}, "events": {"path": "../../escaped.jsonl"}}'; do
  printf '%s\n' "$CFG" > "$PIPELINE_CONFIG"
  rm -f "$LOG"
  assert_eq "$GOOD" "$(run_all)" "AC9 stdout and exit codes match a writable log: $CFG"
done
assert_file_absent "$SANDBOX/../escaped.jsonl" "AC9 nothing is written outside the common dir"
printf '%s\n' "$BASE_CFG" > "$PIPELINE_CONFIG"

# ── AC10 ────────────────────────────────────────────────────────────────────
rm -f "$LOG"
bad() {  # <label> <args...>: exit 2 with the usage, nothing appended
  local label="$1"; shift
  OUT="$(bash "$HOOKS" "$@" 2>&1 </dev/null)"; RC=$?
  assert_eq "2" "$RC" "AC10 $label exits 2"
  assert_contains "$OUT" "Usage: pipeline-hooks.sh" "AC10 $label prints the usage"
  assert_eq "0" "$(lines)" "AC10 $label appends nothing"
}
bad "a bad event" hand_event nope qa 7
bad "a bad role" hand_event qa nope 7
bad "a missing issue" hand_event qa qa
bad "a non-digit issue" hand_event qa qa 7x
bad "a non-digit pr" hand_event qa qa 7 --pr x
bad "hand_note --role outside the five" hand_note approval-posted --role orchestrator
bad "hand_note --role with no value" hand_note approval-posted --role
bash "$HOOKS" hand_event qa qa 7 --pr 12 --sha "$STUB_SHA" --verdict PASS >/dev/null 2>&1; RC=$?
assert_eq "0" "$RC" "AC10 a good hand_event exits 0"
L="$(last qa)"
assert_eq "hand" "$(field "$L" source)" "AC10 hand_event writes source hand"
assert_eq "PASS" "$(field "$L" verdict)" "AC10 hand_event verdict"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-hand-stage-events-897: %d passed\n' "$_PASS"
