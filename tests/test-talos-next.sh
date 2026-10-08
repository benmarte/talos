#!/usr/bin/env bash
# test-talos-next.sh -- `scripts/talos.sh next --issue <N>`, the issue-side
# half of `next` (#471, slice 7 of epic #422): the issue queue (sort, filter,
# cap), dependency gating, issue-side routing parity, epic detection, the PM
# spec-present short-circuit, fix-round gating, wait/ask-owner, orphan
# adoption, provider fail-closed, the lease against double dispatch, and the
# sanitiser on every free-text value.
#
#   next --issue <N>   exactly one action for issue #N against the fixed issue
#                      schema: action=dispatch stage=<role> issue=<N> |
#                      action=ask-owner issue=<N> question=<sanitised> |
#                      action=wait reason=<fixed enum> [retry_after_s=<s>] |
#                      stop reason=<fixed enum>.
#   next (no flag)     PR-side first, then the issue queue: the first pickable
#                      queued issue is routed by the same rules (never two
#                      stages in one action, never a dispatch past a ceiling).
#
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
# Free text reaches the stubs only through files or stdin (AC15).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers ──────────────────────
# pipeline-status-file.sh `collect` prints $STUB_DIR/collect.json (rc from
# collect.rc); pipeline-vcs.sh is a verb-level stub whose every answer lives in
# $STUB_DIR (files named <verb>.<arg>.json / .rc / .err, falling back to
# <verb>.json); every call is logged, and any call not listed fails like an
# unsupported provider verb would (AC10 exercises that shape too, via
# STUB_UNSUPPORTED). Everything else stays real (the lease ledger runs against
# the sandbox repo's git common dir).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"

cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusKq9vXr2Lm'
#!/usr/bin/env bash
# stub collect: one JSON file, one rc.
printf '%s' "$(cat "${STUB_DIR:?}/collect.json" 2>/dev/null || echo '{}')"
[ -f "${STUB_DIR}/collect.err" ] && cat "${STUB_DIR}/collect.err" >&2
if [ -f "${STUB_DIR}/collect.rc" ]; then exit "$(cat "${STUB_DIR}/collect.rc")"; fi
exit 0
TALOS_stubstatusKq9vXr2Lm

cat > "$GS/pipeline-vcs.sh" <<'TALOS_stubvcsWp4nTz8Qk'
#!/usr/bin/env bash
# Verb-level provider stub. Answers come from $STUB_DIR: <verb>.<a1>.json holds
# stdout, <verb>.<a1>.rc the exit code (default 0), <verb>.<a1>.err stderr;
# <verb>.json/.rc/.err are the argless fallback. $STUB_DIR/calls.log records
# every call. STUB_UNSUPPORTED lists verbs (space-separated) that must answer
# "not implemented for provider 'stub'" exit 1 (the azure shape, AC10).
FX="${STUB_DIR:?}"
verb="$1"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
fx() {
  if [ -f "$FX/$verb.$1.json" ]; then cat "$FX/$verb.$1.json"
  elif [ -f "$FX/$verb.json" ]; then cat "$FX/$verb.json"; fi
}
frc() {
  if [ -f "$FX/$verb.$1.rc" ]; then cat "$FX/$verb.$1.rc"
  elif [ -f "$FX/$verb.rc" ]; then cat "$FX/$verb.rc"
  else echo 0; fi
}
ferr() {
  if [ -f "$FX/$verb.$1.err" ]; then cat "$FX/$verb.$1.err" >&2
  elif [ -f "$FX/$verb.err" ]; then cat "$FX/$verb.err" >&2; fi
}
case " ${STUB_UNSUPPORTED:-} " in
  *" $verb "*)
    echo "pipeline-vcs: $verb: not implemented for provider 'stub'" >&2
    exit 1 ;;
esac
case "$verb" in
  check-attempt)
    # stdout: the BLOCKED shape of _vcs_shared_attempt_blocked on stderr is in
    # the .err file; exit 1 means "a ceiling is reached" (which ceiling the
    # caller reads from the stderr line).
    ferr "$1"; fx "$1"; exit "$(frc "$1")" ;;
  *)
    ferr "${1:-}"; fx "${1:-}"; exit "$(frc "${1:-}")" ;;
esac
TALOS_stubvcsWp4nTz8Qk
cat > "$GS/pipeline-budget.sh" <<'TALOS_stubbudgetR5wQk8Zn'
#!/usr/bin/env bash
# stub budget guard: `check --issue N` answers from $STUB_DIR ($3 = N).
printf '%s' "$(cat "${STUB_DIR:?}/budget.check.${3:-}.json" 2>/dev/null || true)"
[ -f "${STUB_DIR}/budget.check.${3:-}.rc" ] && exit "$(cat "${STUB_DIR}/budget.check.${3:-}.rc")"
exit 0
TALOS_stubbudgetR5wQk8Zn
TN="$GS/talos.sh"

# cfg <extra JSON members>: the sandbox config (github provider, all issue-side
# roles on, max_parallel 1 by default).
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg() {  # $1 = issues object, $2 = roles object, $3 = limits object, $4 = extra members
  printf '{"vcs": {"provider": "github"}, "issues": %s, "roles": %s, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}%s%s}' \
    "${1:-{\}}" "${2:-{\}}" "${3:+, \"limits\": $3}" "${4:+, $4}" > "$SANDBOX/talos.pipeline.json"
}

# ── fixture helpers ───────────────────────────────────────────────────────────
# issue <n> <labels,|-> <body-file> : register issue #n's view-issue answer.
issue() {  # $1=n $2=labels (, separated, - = none) $3=body file (optional)
  local _labels="[]"
  [ "$2" = "-" ] || _labels="$(printf '%s' "$2" | python3 -I -c "
import sys, json
print(json.dumps([{'name': x} for x in sys.argv[1].split(',')]))" "$2")"
  python3 -I -c "
import json, sys
print(json.dumps({'number': int(sys.argv[1]), 'title': 'issue ' + sys.argv[1],
                  'labels': json.loads(sys.argv[2]), 'body': sys.argv[3]}))" \
    "$1" "$_labels" "$(cat "${3:-/dev/null}")" > "$STUB_DIR/view-issue.$1.json"
}
# dep <n> <open-issue> : issue #n's body depends on the (open) issue #<m>.
dep() {  # $1=n $2=dependency
  printf 'Depends on: #%s\n' "$2" > "$STUB_DIR/view-issue.$1.body"
  issue "$1" "pipeline:ready" "$STUB_DIR/view-issue.$1.body"
}
# open_state <prs-json> <queued-ids...> : the collect stub's state.
open_state() {  # $1 = prs JSON array, rest = queued issue numbers
  local _prs="$1" _q="" _n
  shift
  for _n in "$@"; do _q="$_q$_n, "; done
  _q="${_q%, }"
  printf '{"prs": %s, "pr_total": %s, "ignored": 0, "blocked": [], "queued": [%s], "held": [], "owners": [], "capped": []}' \
    "$_prs" "$(printf '%s' "$_prs" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')" \
    "$_q" > "$STUB_DIR/collect.json"
}
reset_stubs() { rm -f "$STUB_DIR"/*.json "$STUB_DIR"/*.rc "$STUB_DIR"/*.err "$STUB_DIR/calls.log"; }
LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
nx() { OUT="$(bash "$TN" next "$@" 2>"$ERR")"; RC=$?; }
nxi() { OUT="$(bash "$TN" next --issue "$@" 2>"$ERR")"; RC=$?; }

# ── AC1: the issue queue ──────────────────────────────────────────────────────
reset_stubs
cfg '{"max_parallel": 2}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
# The collect's queued list is already sorted (p0 < p1 < p2 < unlabeled, then
# ID ascending -- the shared sort, tests/test-status-file-*.sh pins it); next
# applies label_filter collapse, skip_labels and the max_parallel cap.
issue 11 "pipeline:ready,p0" /dev/null
issue 3 "pipeline:ready,p1" /dev/null
issue 5 "pipeline:ready,p2" /dev/null
issue 7 "pipeline:ready" /dev/null
issue 9 "pipeline:ready,wontfix" /dev/null        # skip_labels
open_state '[]' 11 3 5 7 9
LEASE_RESET
nx
assert_eq "action=dispatch stage=validator issue=11" "$OUT" "AC1: the p0 issue is chosen before p1, p2 and unlabeled"
assert_eq "0" "$RC" "AC1: the queue pick exits 0"

# p0 gone: p1 before p2 before unlabeled, and #9 (wontfix) is never chosen.
LEASE_RESET
rm "$STUB_DIR/view-issue.11.json"
open_state '[]' 3 5 7 9
nx
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC1: p1 sorts before p2 and unlabeled; skip_labels is skipped"
LEASE_RESET
rm "$STUB_DIR/view-issue.3.json"
open_state '[]' 5 7 9
nx
assert_eq "action=dispatch stage=validator issue=5" "$OUT" "AC1: p2 sorts before unlabeled"

# max_parallel: with max_parallel 1 and #11 in flight (its lease held from the
# dispatch above), the answer is wait reason=cap -- never a second dispatch.
LEASE_RESET
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 11 "pipeline:ready,p0" /dev/null
issue 3 "pipeline:ready,p1" /dev/null
open_state '[]' 11 3
_now="$(date +%s)"
nx
assert_eq "action=dispatch stage=validator issue=11" "$OUT" "AC1: max_parallel 1 still picks the p0 issue"
# #11 in flight: the dispatch above holds its lease, capacity 0: cap.
printf 'issue=11 held=%s expires=%s pid=1\n' "$_now" "$((_now + 1800))" >> "$LEASE"
nx
assert_eq "action=wait reason=cap" "$OUT" "AC1: with max_parallel 1 and one issue in flight the answer is wait reason=cap"
nx
assert_eq "action=wait reason=cap" "$OUT" "AC1: the in-flight lease holds the last capacity slot (max_parallel 1)"
# The lease frees (the done path): 11 is no longer queued, and the capacity
# slot passes to the next queued issue.
LEASE_RESET
rm "$STUB_DIR/view-issue.11.json"
open_state '[]' 3
nx
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC1: a freed lease reopens the capacity"

# label_filter collapse: filter == pipeline:ready behaves as the default.
cfg '{"max_parallel": 1, "label_filter": "pipeline:ready"}' '{"validator": true}'
issue 3 "pipeline:ready,p1" /dev/null
open_state '[]' 3
LEASE_RESET
nx
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC1: label_filter equal to pipeline:ready collapses, one filter"

# ── AC2: dependency gating (roles.planner = true only) ────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
dep 3 42
printf '{"number": 42, "title": "dep", "labels": [], "body": "", "state": "open"}' > "$STUB_DIR/view-issue.42.json"
issue 7 "pipeline:ready" /dev/null
# A dep-gated issue is not chosen: the walk moves on to the next candidate.
open_state '[]' 3 7
LEASE_RESET
nx
assert_eq "action=dispatch stage=validator issue=7" "$OUT" "AC2: a queued issue blocked on an open issue is not chosen (planner on)"
# Alone on the queue, the dep-gated issue answers wait reason=dependency.
rm "$STUB_DIR/view-issue.7.json"
open_state '[]' 3
LEASE_RESET
nx
assert_eq "action=wait reason=dependency" "$OUT" "AC2: nothing pickable behind a dependency gate is wait reason=dependency"
# The dependency issue closed: the gate opens.
printf '{"number": 42, "title": "dep", "labels": [], "body": "", "state": "closed"}' > "$STUB_DIR/view-issue.42.json"
LEASE_RESET
nx
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC2: the gate opens once the dependency is closed"
# roles.planner = false: the check is skipped entirely -- #3 is chosen even
# though its dependency is open again.
printf '{"number": 42, "title": "dep", "labels": [], "body": "", "state": "open"}' > "$STUB_DIR/view-issue.42.json"
cfg '{"max_parallel": 1}' '{"validator": true, "planner": false, "pm": true, "developer": true}'
LEASE_RESET
nx
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC2: planner off skips the dependency check entirely"

# ── AC3: issue-side routing parity (golden label states) ──────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 21 "pipeline:ready" /dev/null
printf -- '- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d\n' > "$STUB_DIR/epic.body"
issue 22 "pipeline:confirmed,epic" "$STUB_DIR/epic.body"
issue 23 "pipeline:confirmed,epic-decomposed" /dev/null
issue 24 "pipeline:dev" /dev/null
issue 25 "pipeline:epic-decomposed" /dev/null
open_state '[]' 21
nxi 21
assert_eq "action=dispatch stage=validator issue=21" "$OUT" "AC3: pipeline:ready routes to validator"
LEASE_RESET
nxi 22
assert_eq "action=dispatch stage=planner issue=22" "$OUT" "AC3: pipeline:confirmed epic routes to planner when enabled"
# planner disabled: the same issue passes through to PM (skip-when-spec off,
# so the has-spec stub is not consulted).
cfg '{"max_parallel": 1}' '{"validator": true, "planner": false, "pm": true, "developer": true, "pm_skip_when_spec_present": false}'
LEASE_RESET
printf 'short body\n' > "$STUB_DIR/s.body"
issue 22 "pipeline:confirmed" "$STUB_DIR/s.body"
nxi 22
assert_eq "action=dispatch stage=pm issue=22" "$OUT" "AC3: with the planner off, pipeline:confirmed routes to PM"
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 23 "pipeline:confirmed" /dev/null
open_state '[]' 23
nxi 23
assert_eq "action=dispatch stage=developer issue=23" "$OUT" "AC3: pipeline:epic-decomposed routes to developer (one stage only)"
LEASE_RESET
nxi 24
assert_eq "action=dispatch stage=developer issue=24" "$OUT" "AC3: pipeline:dev routes to developer"
LEASE_RESET
nxi 25
assert_eq "action=dispatch stage=developer issue=25" "$OUT" "AC3: a bare pipeline:epic-decomposed epic routes to developer"
# Never two stages in one action: the line holds exactly one stage= pair.
nxi 22
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'stage=')" "AC3: exactly one stage per action, never two"
# Validator off: a pipeline:ready issue is not dispatched anywhere else.
cfg '{"max_parallel": 1}' '{"validator": false, "planner": true, "pm": true, "developer": true}'
issue 21 "pipeline:ready" /dev/null
nxi 21
assert_eq "action=wait reason=none" "$OUT" "AC3: with the validator off, a pipeline:ready issue waits (no fallback dispatch)"

# ── AC4: epic detection feeds routing ─────────────────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": false, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": false}'
open_state '[]'
# Epic by label.
issue 31 "pipeline:confirmed,epic" /dev/null
LEASE_RESET
nxi 31
assert_eq "action=dispatch stage=planner issue=31" "$OUT" "AC4: the epic label routes the planner dispatch"
# Epic by >= 4 checklist items.
printf -- '- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d\n' > "$STUB_DIR/e.body"
issue 32 "pipeline:confirmed" "$STUB_DIR/e.body"
LEASE_RESET
nxi 32
assert_eq "action=dispatch stage=planner issue=32" "$OUT" "AC4: >= 4 checklist items routes the planner dispatch"
# Epic by body length (>= 2000 chars), not otherwise epic-shaped.
{ for i in 1 2 3 4 5 6 7 8 9 10; do printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10; done; printf '\n'; } > /dev/null  # noqa
python3 -I -c "print('x' * 2000)" > "$STUB_DIR/long.body"
issue 33 "pipeline:confirmed" "$STUB_DIR/long.body"
LEASE_RESET
nxi 33
assert_eq "action=dispatch stage=planner issue=33" "$OUT" "AC4: a >= 2000-char body routes the planner dispatch"
# Below all three thresholds: a non-epic passes through to PM.
printf 'short body\n' > "$STUB_DIR/s.body"
issue 34 "pipeline:confirmed" "$STUB_DIR/s.body"
LEASE_RESET
nxi 34
assert_eq "action=dispatch stage=pm issue=34" "$OUT" "AC4: a non-epic passes the planner through to PM"
# Sub-issue creation stays in the act/done path: next never calls create-issue
# or label-issue (write verbs are not even stubbed -- a call would fail the run).
! grep -q "^create-issue \|^label-issue \|^comment-issue " "$STUB_DIR/calls.log" 2>/dev/null
assert_eq "0" "$?" "AC4: next never creates sub-issues or advances labels itself"

# ── AC5: the PM skip-when-spec-present short-circuit ───────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": true}'
open_state '[]'
printf 'short body\n' > "$STUB_DIR/s.body"
# has-spec exits 0: PM never fires; the developer is next (the skip comment and
# the pipeline:dev advance happen in the done path, not here).
printf '' > "$STUB_DIR/has-spec.22.json"; printf 0 > "$STUB_DIR/has-spec.22.rc"
issue 22 "pipeline:confirmed" "$STUB_DIR/s.body"
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC5: has-spec exits 0 -- PM never dispatches, developer is next"
# has-spec exits 1 (no usable spec): PM fires as usual.
printf 1 > "$STUB_DIR/has-spec.22.rc"
LEASE_RESET
nxi 22
assert_eq "action=dispatch stage=pm issue=22" "$OUT" "AC5: has-spec exits 1 -- PM dispatches as usual"
# roles.pm_skip_when_spec_present = false: PM fires even when has-spec exits 0.
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": false}'
printf 0 > "$STUB_DIR/has-spec.22.rc"
LEASE_RESET
LEASE_RESET
nxi 22
assert_eq "action=dispatch stage=pm issue=22" "$OUT" "AC5: the toggle off dispatches PM even with a spec present"
# has-spec exits 0 via the spec:ready label: still no PM (same scan, no re-impl).
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": true}'
printf 0 > "$STUB_DIR/has-spec.22.rc"
issue 26 "pipeline:confirmed,spec:ready" /dev/null
LEASE_RESET
nxi 26
assert_eq "action=dispatch stage=developer issue=26" "$OUT" "AC5: spec:ready short-circuits PM the same way"

# ── AC6: fix-round gating before a developer fix round ────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}' '{"max_fix_attempts": 3, "max_total_dispatches": 8}'
# A pipeline:dev issue WITH an open PR is a developer fix round: next composes
# the gate fix-round outcome before dispatching. First the ceilings are fine.
printf 'stage=qa count=1 total=2\n' > "$STUB_DIR/check-attempt.41.json"
printf 'talos:budget ok issue=41 used=10 limit=1000 effective=1000 pct=1 unrecorded=0\n' > "$STUB_DIR/budget.check.41.json"
issue 41 "pipeline:dev" /dev/null
open_state '[{"n": 12, "issue": 41, "head": "a4f9", "owner": false, "stage": "qa"}]'
nxi 41
assert_eq "action=dispatch stage=developer issue=41" "$OUT" "AC6: a developer fix round under every ceiling dispatches"

# max_fix_attempts reached (consecutive: the blocking stage count).
printf 'stage=qa count=3 total=2\n' > "$STUB_DIR/check-attempt.41.json"
printf 'pipeline-vcs: check-attempt: BLOCKED — qa consecutive attempts (3) >= max_fix_attempts (3)\n' > "$STUB_DIR/check-attempt.41.err"
printf 1 > "$STUB_DIR/check-attempt.41.rc"
LEASE_RESET
nxi 41
assert_eq "1" "$RC" "AC6: a fix round past max_fix_attempts exits non-zero"
assert_eq "stop reason=max-fix-attempts" "$OUT" "AC6: the stop reason names the consecutive-attempt ceiling"

# max_total_dispatches reached (the total count, even with the per-stage count reset).
printf 'stage=pm count=1 total=8\n' > "$STUB_DIR/check-attempt.41.json"
printf 'pipeline-vcs: check-attempt: BLOCKED — total dispatches (8) >= max_total_dispatches (8)\n' > "$STUB_DIR/check-attempt.41.err"
LEASE_RESET
nxi 41
assert_eq "stop reason=max-total-dispatches" "$OUT" "AC6: the stop reason names the total-dispatch ceiling"

# Budget exceeded: stop reason=budget-exceeded.
printf 0 > "$STUB_DIR/check-attempt.41.rc"
printf 'stage=qa count=1 total=2\n' > "$STUB_DIR/check-attempt.41.json"
printf 'talos:budget exceeded issue=41 used=2000 limit=1000 effective=1000 pct=200 unrecorded=0\n' > "$STUB_DIR/budget.check.41.json"
printf 1 > "$STUB_DIR/budget.check.41.rc"
printf 'pipeline-budget: budget exceeded\n' > "$STUB_DIR/budget.check.41.err"
LEASE_RESET
nxi 41
assert_eq "stop reason=budget-exceeded" "$OUT" "AC6: a budget stop names budget-exceeded"

# The same budget stop with STATUS_ENABLED = true: ask-owner instead of a stop.
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}' '{"max_fix_attempts": 3, "max_total_dispatches": 8}' '"status": {"enabled": true}'
LEASE_RESET
nxi 41
case "$OUT" in
  "action=ask-owner issue=41 question="*) pass "AC6: a budget stop with status on asks the owner instead" ;;
  *) fail "AC6: a budget stop with status on asks the owner instead" "got: $OUT" ;;
esac

# A first developer dispatch (no open PR) never runs the gate: no ceilings.
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}' '{"max_fix_attempts": 3, "max_total_dispatches": 8}'
reset_stubs
issue 42 "pipeline:dev" /dev/null
open_state '[]' 42
nxi 42
assert_eq "action=dispatch stage=developer issue=42" "$OUT" "AC6: a first dispatch (no PR) skips the fix-round gate"
! grep -q "^check-attempt \|^budget " "$STUB_DIR/calls.log"
assert_eq "0" "$?" "AC6: no gate verb ran for the first dispatch"

# ── AC7: wait, fixed-enum reasons, retry_after_s ──────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
open_state '[]' 21
# A lease held by another run: wait reason=lease with retry_after_s (never a
# second dispatch of the same action).
LEASE_RESET
issue 21 "pipeline:ready" /dev/null
printf 'issue=21 held=1000000 expires=1000900 pid=1\n' > "$LEASE"
TALOS_NOW=1000000 nxi 21
case "$OUT" in
  "action=wait reason=lease retry_after_s="*) pass "AC7: a held lease waits with a retry_after_s" ;;
  *) fail "AC7: a held lease waits with a retry_after_s" "got: $OUT" ;;
esac
# The reason enum is fixed: every wait names a reason from the enum.
TALOS_NOW=1000000 nxi 21
case "$OUT" in
  reason=draft*|*reason=ci*|*reason=human-merge*|*reason=blocked*|*reason=owner*|*reason=lease*|*reason=none*|*reason=dependency*|*reason=cap*) assert_eq "0" "0" "AC7: the wait reason comes from the fixed enum" ;;
  *) assert_eq "enum" "other" "AC7: the wait reason comes from the fixed enum" ;;
esac

# ── AC8: ask-owner ────────────────────────────────────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}' '{"max_fix_attempts": 3, "max_total_dispatches": 8}' '"status": {"enabled": true}'
# A queued issue carrying the needs-owner marker (held in the state, question
# in owners) routes to ask-owner.
issue 51 "pipeline:ready,pipeline:needs-owner" /dev/null
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [51], "held": [51], "owners": [{"n": 51, "status": "unanswered", "question": "which token limit applies?"}], "capped": []}' > "$STUB_DIR/collect.json"
nxi 51
case "$OUT" in
  "action=ask-owner issue=51 question="*) pass "AC8: a needs-owner issue routes to ask-owner" ;;
  *) fail "AC8: a needs-owner issue routes to ask-owner" "got: $OUT" ;;
esac
assert_contains "$OUT" "question=which token limit applies?" "AC8: the question is carried, sanitised"

# ── AC9: orphan adoption ──────────────────────────────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
# A queued issue with an open pipeline PR is adopted: the PR's blocking stage is
# the answer (the PR-side helper), never a fresh developer dispatch.
issue 61 "pipeline:ready" /dev/null
open_state '[{"n": 15, "issue": 61, "head": "a4f9", "owner": false, "stage": "qa"}]' 61
LEASE_RESET
nxi 61
assert_eq "action=dispatch stage=qa pr=15 issue=61" "$OUT" "AC9: an orphaned PR is adopted and resumed at its blocking stage"
LEASE_RESET
nx
assert_eq "action=dispatch stage=qa pr=15 issue=61" "$OUT" "AC9: the queue pick adopts the same PR, never re-dispatches developer"
# A blocked PR is never dispatched.
open_state '[{"n": 15, "issue": 61, "head": "a4f9", "owner": false, "stage": "blocked"}]' 61
nx
assert_eq "action=wait reason=blocked" "$OUT" "AC9: a blocked PR is never dispatched"
# A blocked issue is never dispatched either.
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [["issue", 61]], "queued": [61], "held": [], "owners": [], "capped": []}' > "$STUB_DIR/collect.json"
nx
assert_eq "action=wait reason=owner" "$OUT" "AC9: a blocked issue is never dispatched"

# ── AC10: provider gaps fail closed ───────────────────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": true}'
issue 22 "pipeline:confirmed" "$STUB_DIR/s.body"
open_state '[]' 22
# has-spec missing on this provider (the azure shape): never a guess.
STUB_UNSUPPORTED="has-spec" nxi 22
assert_eq "1" "$RC" "AC10: a missing provider verb exits non-zero"
assert_eq "stop reason=unsupported-verb:has-spec" "$OUT" "AC10: the stop names the missing verb, never guesses"
# check-attempt missing (a fix round needs it): same fail-closed shape.
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}' '{"max_fix_attempts": 3, "max_total_dispatches": 8}'
printf 'stage=qa count=1 total=2\n' > "$STUB_DIR/check-attempt.41.json"
issue 41 "pipeline:dev" /dev/null
open_state '[{"n": 12, "issue": 41, "head": "a4f9", "owner": false, "stage": "qa"}]'
STUB_UNSUPPORTED="check-attempt" nxi 41
assert_eq "stop reason=unsupported-verb:check-attempt" "$OUT" "AC10: a missing check-attempt fails closed too"

# ── AC11: the lease against double dispatch ───────────────────────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 21 "pipeline:ready" /dev/null
open_state '[]' 21
LEASE_RESET
# Two callers, one after the other: the first dispatches and holds the lease;
# the second (concurrent, same issue) waits -- never the same dispatch twice.
TALOS_NOW=1000000 nxi 21
assert_eq "action=dispatch stage=validator issue=21" "$OUT" "AC11: the first caller dispatches"
assert_contains "$(cat "$LEASE")" "issue=21 held=1000000" "AC11: the dispatch holds the issue's lease"
# The holder the second caller sees is a LIVE foreign process (#522 re-pin: the
# first call's own pid is a dead one-shot by now -- age 100 >= the reclaim
# guard -- and a dead holder's line is not a lease, so the old seed only ever
# proved the bug-free case by accident).
( sleep 30 ) & _ac11_lpid=$!
printf 'issue=21 held=1000000 expires=1000900 pid=%s\n' "$_ac11_lpid" > "$LEASE"
TALOS_NOW=1000100 nxi 21
case "$OUT" in
  "action=wait reason=lease retry_after_s="*) pass "AC11: the second caller waits, never a second dispatch" ;;
  *) fail "AC11: the second caller waits, never a second dispatch" "got: $OUT" ;;
esac
kill "$_ac11_lpid" 2>/dev/null
# The lease expires (TTL): a dead worker's action is re-issued.
printf 'issue=21 held=1000000 expires=1000900 pid=1\n' > "$LEASE"
TALOS_NOW=2000000 nxi 21
assert_eq "action=dispatch stage=validator issue=21" "$OUT" "AC11: an expired lease frees the issue for a re-issue"

# ── AC12: free text never reaches reason/question unsanitised ──────────────────
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true, "pm_skip_when_spec_present": true}' '' '"status": {"enabled": true}'
# A planted $(touch) and an ANSI escape in a needs-owner question: the output
# carries them sanitised (control bytes as \xNN) and the touch never runs.
PWN="$SANDBOX/pwned-marker"
rm -f "$PWN"
_q="$(printf 'which limit applies to \033[31mred\x24\x28\x74\x6f\x75\x63\x68\x20%s\x29 text' "$PWN")"
printf '%s' "$_q" > "$STUB_DIR/q.body"
# The question goes into the collect JSON python-escaped (a raw control byte
# is not legal inside a JSON string); the stub hands it back byte for byte,
# so next still sees the raw ESC and the sanitiser has to neutralise it.
_qj="$(python3 -I -c "import json,sys; print(json.dumps(sys.argv[1]))" "$(cat "$STUB_DIR/q.body")")"
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [71], "held": [71], "owners": [{"n": 71, "status": "unanswered", "question": %s}], "capped": []}' \
  "$_qj" > "$STUB_DIR/collect.json"
issue 71 "pipeline:ready,pipeline:needs-owner" /dev/null
nxi 71
[ ! -e "$PWN" ]
assert_eq "0" "$?" "AC12: the planted \$(touch) in a question never runs"
case "$OUT" in
  *"\\x1b"*) pass "AC12: the ANSI escape is sanitised (\\x1b, no raw control byte)" ;;
  *) fail "AC12: the ANSI escape is sanitised" "got: $OUT" ;;
esac
# No raw control byte reaches stdout at all.
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"
assert_eq "1" "$?" "AC12: no raw ESC byte in the output"

# ── AC1/AC3/AC5/AC6/AC10: the dead-holder lease end-to-end (#522) ─────────────
# The ledger's reclaim: a line whose `pid=` is a dead process stops being a
# lease once it is older than TALOS_LEASE_RECLAIM_S (default 10 s). `next`
# answers the normal action, announces the reclaim once on stderr and derives
# the age-guard wait's retry from the seconds until reclaimable. The cap's
# live-lease count skips reclaimable lines and counts each issue once.

# AC1: the dead-holder dispatch. A reaped child stands for the pid a one-shot
# `next` leaves behind.
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 61 "pipeline:ready" /dev/null
open_state '[]' 61
LEASE_RESET
( sleep 30 ) & _d61=$!
kill "$_d61" 2>/dev/null; wait "$_d61" 2>/dev/null
printf 'issue=61 held=999985 expires=1001800 pid=%s\n' "$_d61" > "$LEASE"
TALOS_NOW=1000000 nxi 61
case "$OUT" in
  "action=dispatch stage="*" issue=61") pass "AC1: a dead-pid lease answers the normal dispatch, never a wait" ;;
  *) fail "AC1: a dead-pid lease answers the normal dispatch, never a wait" "got: $OUT" ;;
esac

# AC3: a live foreign holder is still a lease; the TTL is the bound for a
# live-but-hung holder, and age alone never reclaims it (the holder is reaped
# only after the assertion).
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 62 "pipeline:ready" /dev/null
open_state '[]' 62
LEASE_RESET
( sleep 30 ) & _l62=$!
printf 'issue=62 held=999000 expires=1000900 pid=%s\n' "$_l62" > "$LEASE"
TALOS_NOW=1000000 nxi 62
case "$OUT" in
  "action=wait reason=lease retry_after_s=900") pass "AC3: a live foreign holder waits with the full remaining TTL, never the guard" ;;
  *) fail "AC3: a live foreign holder waits with the full remaining TTL, never the guard" "got: $OUT" ;;
esac
kill "$_l62" 2>/dev/null

# AC5: a wait that exists only because of the age guard reports the seconds
# until reclaimable, never the full remaining TTL.
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 63 "pipeline:ready" /dev/null
open_state '[]' 63
LEASE_RESET
( sleep 30 ) & _d63=$!
kill "$_d63" 2>/dev/null; wait "$_d63" 2>/dev/null
printf 'issue=63 held=999995 expires=1001800 pid=%s\n' "$_d63" > "$LEASE"
TALOS_NOW=1000000 nxi 63
case "$OUT" in
  "action=wait reason=lease retry_after_s=5") pass "AC5: the guard wait's retry is the seconds until reclaimable, never the TTL" ;;
  *) fail "AC5: the guard wait's retry is the seconds until reclaimable, never the TTL" "got: $OUT" ;;
esac

# AC6: the reclaim is announced exactly once on stderr; stdout carries only
# the action line; nothing is announced when nothing was reclaimed.
reset_stubs
cfg '{"max_parallel": 1}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 64 "pipeline:ready" /dev/null
open_state '[]' 64
LEASE_RESET
( sleep 30 ) & _d64=$!
kill "$_d64" 2>/dev/null; wait "$_d64" 2>/dev/null
printf 'issue=64 held=999985 expires=1001800 pid=%s\n' "$_d64" > "$LEASE"
TALOS_NOW=1000000 nxi 64
case "$OUT" in
  "action=dispatch stage="*" issue=64") pass "AC6: the reclaimed dispatch still answers on stdout" ;;
  *) fail "AC6: the reclaimed dispatch still answers on stdout" "got: $OUT" ;;
esac
assert_eq "1" "$(grep -c "lease reclaimed from dead holder issue=64" "$ERR")" "AC6: the reclaim note is on stderr exactly once"
assert_eq "talos.sh next: lease reclaimed from dead holder issue=64" "$(grep "lease reclaimed from dead holder issue=64" "$ERR")" "AC6: the note is the one convention line"
assert_not_contains "$OUT" "lease reclaimed" "AC6: stdout carries only the action line"
reset_stubs
issue 65 "pipeline:ready" /dev/null
open_state '[]' 65
LEASE_RESET
( sleep 30 ) & _l65=$!
printf 'issue=65 held=999985 expires=1001800 pid=%s\n' "$_l65" > "$LEASE"
TALOS_NOW=1000000 nxi 65
case "$OUT" in
  "action=wait reason=lease"*) pass "AC6: a genuine live-holder wait still answers" ;;
  *) fail "AC6: a genuine live-holder wait still answers" "got: $OUT" ;;
esac
assert_not_contains "$(cat "$ERR")" "lease reclaimed" "AC6: no stderr note when nothing was reclaimed"
kill "$_l65" 2>/dev/null

# AC10: the live-lease cap counts each issue at most once and skips
# reclaimable lines: two dead-pid lines never cap the queue, two live foreign
# pids do, and two live lines for one issue are one in-flight issue.
reset_stubs
cfg '{"max_parallel": 2}' '{"validator": true, "planner": true, "pm": true, "developer": true}'
issue 71 "pipeline:ready" /dev/null
issue 72 "pipeline:ready" /dev/null
issue 73 "pipeline:ready" /dev/null
LEASE_RESET
( sleep 30 ) & _d71=$!
kill "$_d71" 2>/dev/null; wait "$_d71" 2>/dev/null
( sleep 30 ) & _d72=$!
kill "$_d72" 2>/dev/null; wait "$_d72" 2>/dev/null
open_state '[]' 71 72 73
printf 'issue=71 held=999985 expires=1001800 pid=%s\n' "$_d71" > "$LEASE"
printf 'issue=72 held=999985 expires=1001800 pid=%s\n' "$_d72" >> "$LEASE"
TALOS_NOW=1000000 nx
case "$OUT" in
  "action=dispatch stage="*" issue="*) pass "AC10: two dead-pid lines never cap the queue" ;;
  *) fail "AC10: two dead-pid lines never cap the queue" "got: $OUT" ;;
esac
( sleep 30 ) & _l71=$!
( sleep 30 ) & _l72=$!
printf 'issue=71 held=999985 expires=1001800 pid=%s\n' "$_l71" > "$LEASE"
printf 'issue=72 held=999985 expires=1001800 pid=%s\n' "$_l72" >> "$LEASE"
TALOS_NOW=1000000 nx
case "$OUT" in
  "action=wait reason=cap") pass "AC10: two live foreign pids cap the queue" ;;
  *) fail "AC10: two live foreign pids cap the queue" "got: $OUT" ;;
esac
rm "$STUB_DIR/view-issue.71.json" "$STUB_DIR/view-issue.72.json"
open_state '[]' 73
printf 'issue=73 held=999985 expires=1001800 pid=%s\n' "$_l71" > "$LEASE"
printf 'issue=73 held=999985 expires=1000900 pid=%s\n' "$_l72" >> "$LEASE"
TALOS_NOW=1000000 nx
case "$OUT" in
  "action=wait reason=cap") fail "AC10: two live lines for one issue are one in-flight, never a cap" "got: $OUT" ;;
  "action=dispatch stage="*" issue=73"*|"action=wait reason=lease"*) pass "AC10: two live lines for one issue are one in-flight, never a cap" ;;
  *) fail "AC10: two live lines for one issue are one in-flight, never a cap" "got: $OUT" ;;
esac
kill "$_l71" "$_l72" 2>/dev/null

finish