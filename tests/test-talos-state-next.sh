#!/usr/bin/env bash
# test-talos-state-next.sh -- `scripts/talos.sh state` and `next` (#470, slice 6
# of epic #422): the normalised run state, the one-action answer for PR-side
# stages, and the lease ledger.
#
#   state  one `state=<JSON>` line, the same JSON pipeline-status-file.sh
#          collect writes (same inputs, same shape, no duplicated collection
#          logic); an unreadable state fails closed: a lone `stop reason=`
#          line, no partial JSON.
#   next   exactly one action validated against the fixed action schema:
#          action=dispatch stage=<role> pr=<M> issue=<N> | action=merge pr=<M>
#          issue=<N> | action=wait reason=<fixed enum>. Issue-side routing is
#          #471 (tests/test-talos-next.sh); this file pins that a queued issue
#          the stubs cannot answer fails closed, never a guessed dispatch.
#
#          A dispatch/merge answer acquires the issue's lease first (AC4): a
#          lease held by another run answers `action=wait reason=lease`, never
#          a takeover; a timed-out lock is a wait too.
#   lease  <git common dir>/talos-lease.ledger guarded by pipeline-lock.sh;
#          TTL = verify.timeout_ms/1000 + verify.ci_wait_s, floor 30 minutes
#          (TALOS_LEASE_TTL_S / TALOS_NOW override both in tests); an expired
#          lease is free.
#   help   documents state and next (AC5); a missing provider verb fails closed
#          with `stop reason=unsupported-verb:<verb>`.
#
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
# A copy of the scripts directory in which pipeline-status-file.sh is a stub
# whose `collect` prints the JSON of $STUB_DIR/collect.json (rc from
# collect.rc): `state` and `next` consume only that, so the action schema and
# the lease are tested without any GitHub read. Everything else stays real
# (the lease helpers run against the sandbox repo's git common dir).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusQv7Lm2Xw'
#!/usr/bin/env bash
# Stub: `collect` answers from $STUB_DIR, everything else fails (never called).
d="${STUB_DIR:?}"
case "${1:-}" in
  collect)
    printf 'stub collect\n' >> "$d/journal"
    if [ -f "$d/collect.rc" ]; then exit "$(cat "$d/collect.rc")"; fi
    [ -f "$d/collect.err" ] && cat "$d/collect.err" >&2
    cat "$d/collect.json" 2>/dev/null || printf '{}'
    exit 0 ;;
  *) printf 'stub: unexpected verb %s\n' "${1:-}" >&2; exit 99 ;;
esac
TALOS_stubstatusQv7Lm2Xw
TN="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' > "$SANDBOX/talos.pipeline.json"
}
# state JSON: prs (n, issue, head, owner, stage), pr_total, ignored, blocked,
# queued, held, owners, capped -- the shape pipeline-status-file.sh collect
# writes (the stub prints it verbatim).
set_state() { printf '%s' "$1" > "$STUB_DIR/collect.json"; }
st() { OUT="$(bash "$TN" "$@" 2>"$ERR")"; RC=$?; }
line_of() { printf '%s\n' "$OUT" | sed -n "s/^$1//p" | head -n 1; }

# ── AC1: state ───────────────────────────────────────────────────────────────
reset_stubs
set_state '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [7], "held": [], "owners": [], "capped": []}'
st state
assert_eq "0" "$RC" "state: exits 0"
assert_eq 'state={"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [7], "held": [], "owners": [], "capped": []}' \
  "$OUT" "state: the collect JSON under one state= line"
assert_eq "" "$(cat "$ERR")" "state: no stderr"

# A multi-PR state round-trips byte for byte.
_state2='{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "qa"}, {"n": 13, "issue": 35, "head": "b7c1", "owner": true, "stage": "merge"}], "pr_total": 2, "ignored": 1, "blocked": [["issue", 35]], "queued": [34, 35], "held": [35], "owners": [], "capped": ["list-prs"]}'
set_state "$_state2"
st state
assert_eq "state=$_state2" "$OUT" "state: the full multi-PR JSON round-trips"

# Fail closed: a failed collect is a lone stop line, no partial JSON.
printf '1' > "$STUB_DIR/collect.rc"
printf 'pipeline-status-file: list-prs failed\n' > "$STUB_DIR/collect.err"
set_state '{"prs": ['
st state
assert_eq "1" "$RC" "state: a failed collect exits non-zero"
assert_eq "stop reason=state-unavailable" "$OUT" "state: fails closed with one stop line, no partial JSON"
rm -f "$STUB_DIR/collect.rc" "$STUB_DIR/collect.err"

# Non-JSON output fails closed too (never an empty or partial state= line).
printf 'not json at all' > "$STUB_DIR/collect.json"
st state
assert_eq "stop reason=state-unavailable" "$OUT" "state: non-JSON collect output is a stop"

# Usage.
reset_stubs
st state --bogus
assert_eq "stop reason=usage" "$OUT" "state: an argument is usage"
assert_eq "2" "$RC" "state: usage exits 2"

# ── AC2: the extraction ───────────────────────────────────────────────────────
# next_stage lives in pipeline-next-stage.py (its one implementation), and
# pipeline-status-file.sh loads it; the stage-of-PR tests stay in
# tests/test-status-file-refresh.sh (the byte-identical pin, #454 note).
assert_file_exists "$TALOS_ROOT/scripts/pipeline-next-stage.py" "AC2: pipeline-next-stage.py exists"
grep -q "def next_stage(n, labels, issue_labels, enabled):" "$TALOS_ROOT/scripts/pipeline-next-stage.py"
assert_eq "0" "$?" "AC2: the module defines next_stage"
grep -q "pipeline-next-stage.py" "$TALOS_ROOT/scripts/pipeline-status-file.sh"
assert_eq "0" "$?" "AC2: pipeline-status-file.sh loads the module"
grep -q "def next_stage(" "$TALOS_ROOT/scripts/pipeline-status-file.sh"
assert_eq "1" "$?" "AC2: no copy of next_stage stays in pipeline-status-file.sh"
# python3 -I, the repo convention for every embedded program.
grep -q "python3 -I -c \"\$SF_PYS\"" "$TALOS_ROOT/scripts/pipeline-status-file.sh"
assert_eq "0" "$?" "AC2: the collect/refresh modes run under python3 -I"

# The action schema, as a checker: one line, exactly one of the four shapes,
# fixed-enum reasons, nothing untrusted. The draft wait is key-carrying (#516):
# it names the PR and the issue so the run loop can continue the Draft stage
# order from it; every other reason stays bare.
check_action() {  # $1 = file with the output
  python3 -I -c '
import re, sys
data = open(sys.argv[1], "rb").read()
if re.search(rb"[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]", data):
    sys.exit(1)
lines = data.decode("utf-8").split("\n")
if lines and lines[-1] == "":
    lines.pop()
if len(lines) != 1:
    sys.exit(1)
ln = lines[0]
if re.fullmatch(r"action=dispatch stage=(qa|docs|reviewer|security|adversarial) pr=[0-9]+ issue=[0-9]+", ln):
    sys.exit(0)
if re.fullmatch(r"action=merge pr=[0-9]+ issue=[0-9]+", ln):
    sys.exit(0)
if re.fullmatch(r"action=wait reason=(ci|human-merge|blocked|owner|lease|none)", ln):
    sys.exit(0)
if re.fullmatch(r"action=wait reason=draft pr=[0-9]+ issue=[0-9]+", ln):
    sys.exit(0)
sys.exit(1)
' "$1"
}
assert_action() {
  printf '%s\n' "$OUT" > "$SANDBOX/out.next"
  check_action "$SANDBOX/out.next"
  assert_eq "0" "$?" "$1: the action satisfies the fixed schema"
}

# ── AC3: next -- the action schema ────────────────────────────────────────────
# The lease of every dispatch test is reset first: a held lease from one case
# must not turn the next case's dispatch into a wait.
LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
LEASE_RESET

reset_stubs
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
st next
assert_eq "0" "$RC" "next (qa stage): exits 0"
assert_eq "action=dispatch stage=qa pr=12 issue=34" "$OUT" "next (qa stage): dispatch the first missing PR-side stage"
assert_action "next (qa stage)"

for stage in docs reviewer security adversarial; do
  LEASE_RESET
  set_state "{\"prs\": [{\"n\": 12, \"issue\": 34, \"head\": \"a4f9\", \"owner\": false, \"stage\": \"$stage\"}], \"pr_total\": 1, \"ignored\": 0, \"blocked\": [], \"queued\": [], \"held\": [], \"owners\": [], \"capped\": []}"
  st next
  assert_eq "action=dispatch stage=$stage pr=12 issue=34" "$OUT" "next: dispatches a PR at stage $stage"
  assert_action "next ($stage)"
done

set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "merge"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
LEASE_RESET
st next
assert_eq "action=merge pr=12 issue=34" "$OUT" "next (merge): names the PR to merge"
assert_action "next (merge)"

# AC1 (#516): the draft wait names the PR and the issue, so the run loop can
# continue the Draft stage order from it; every other reason stays bare.
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "ready"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
LEASE_RESET
st next
assert_eq "action=wait reason=draft pr=12 issue=34" "$OUT" "AC1: the ready stage's draft wait names the PR and the issue"
assert_action "next (stage ready, key-carrying draft)"

for reason in ci:ci human-merge:human-merge blocked:blocked; do
  r="${reason%%:*}"; s="${reason#*:}"
  set_state "{\"prs\": [{\"n\": 12, \"issue\": 34, \"head\": \"a4f9\", \"owner\": false, \"stage\": \"$s\"}], \"pr_total\": 1, \"ignored\": 0, \"blocked\": [], \"queued\": [], \"held\": [], \"owners\": [], \"capped\": []}"
  LEASE_RESET
  st next
  assert_eq "action=wait reason=$r" "$OUT" "next (stage $s): wait reason=$r (bare)"
  assert_action "next ($s)"
done

# The lowest PR wins.
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "merge"}, {"n": 9, "issue": 8, "head": "c0d1", "owner": false, "stage": "reviewer"}], "pr_total": 2, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
LEASE_RESET
st next
assert_eq "action=dispatch stage=reviewer pr=9 issue=8" "$OUT" "next: the lowest-numbered PR's action wins"

# Owner-blocked PRs are never dispatched; owner lines / blocked entries wait on the owner.
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": true, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [{"n": 34, "status": "unanswered", "question": "q"}], "capped": []}'
st next
assert_eq "action=wait reason=owner" "$OUT" "next: a PR waiting on its owner is never dispatched"
set_state '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [["issue", 42]], "queued": [], "held": [], "owners": [], "capped": []}'
st next
assert_eq "action=wait reason=owner" "$OUT" "next: blocked work without a PR waits on the owner"

# Nothing queued, nothing in flight.
set_state '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
st next
assert_eq "action=wait reason=none" "$OUT" "next: an empty state waits with reason=none"

# A failed state read fails closed, never a guess.
printf '1' > "$STUB_DIR/collect.rc"
set_state '{"prs": ['
st next
assert_eq "1" "$RC" "next: a failed collect exits non-zero"
assert_eq "stop reason=state-unavailable" "$OUT" "next: a failed collect is a stop, never a guessed action"
rm -f "$STUB_DIR/collect.rc"

# An unknown stage in the state never becomes a dispatch (fail closed).
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "nonsense"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
st next
assert_eq "1" "$RC" "next: an unknown stage exits non-zero"
assert_eq "stop reason=unsupported-verb:nonsense" "$OUT" "next: an unknown stage is stop reason=unsupported-verb:<stage>, never a guess"

# Issue-side stages are #471: a queued issue with no PR-side action now routes
# through the issue queue (tests/test-talos-next.sh owns the routing parity).
# The stub gh answers view-issue for any issue with no pipeline label, so the
# issue-side walk finds no stage: a wait, never a guessed dispatch.
LEASE_RESET
set_state '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [42], "held": [], "owners": [], "capped": []}'
st next
assert_eq "0" "$RC" "next (issue queued): exits 0 when the issue has no stage"
assert_eq "action=wait reason=none" "$OUT" "next (issue queued): an unlabeled queued issue is a wait, never a guessed dispatch"

# Usage.
st next --bogus
assert_eq "stop reason=usage" "$OUT" "next: an unknown flag is usage"
assert_eq "2" "$RC" "next: usage exits 2"

# ── AC4: the lease ledger ─────────────────────────────────────────────────────
reset_stubs
set_state '{"prs": [{"n": 12, "issue": 34, "head": "a4f9", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'

# A dispatch acquires the lease (a fresh ledger is created under the git
# common dir) and the answer is the dispatch.
rm -f "$LEASE" "${LEASE:?}.lock.d"
st next
assert_eq "action=dispatch stage=qa pr=12 issue=34" "$OUT" "lease: a free issue is dispatched and its lease written"
assert_contains "$(cat "$LEASE")" "issue=34 held=" "lease: the ledger holds issue 34 under the git common dir"
assert_contains "$(cat "$LEASE")" "expires=" "lease: the line carries an expiry"

# TTL: verify.timeout_ms/1000 + verify.ci_wait_s, floor 30 minutes.
cfg_json '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
rm -f "$LEASE" "${LEASE:?}.lock.d"
TALOS_NOW=1000000 st next
_line="$(sed "s/pid=[0-9]*/pid=/" "$LEASE")"
assert_eq "issue=34 held=1000000 expires=1001800 pid=" "$_line" \
  "lease: TTL = verify timeout + CI wait (600 + 900 = 1500 s) is floored at 30 minutes"
cfg_json '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 600000, "ci_wait_s": 2000}}'
rm -f "$LEASE" "${LEASE:?}.lock.d"
TALOS_NOW=1000000 st next
_line="$(sed "s/pid=[0-9]*/pid=/" "$LEASE")"
assert_eq "issue=34 held=1000000 expires=1002600 pid=" "$_line" \
  "lease: TTL above the floor is verify timeout + CI wait (600 + 2000 = 2600 s)"

cfg_json '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 1000, "ci_wait_s": 0}}'
rm -f "$LEASE" "${LEASE:?}.lock.d"
TALOS_NOW=1000000 st next
_line="$(sed "s/pid=[0-9]*/pid=/" "$LEASE")"
assert_eq "issue=34 held=1000000 expires=1001800 pid=" "$_line" \
  "lease: a short verify+CI horizon is floored at 30 minutes (1800 s)"
cfg_json '{"vcs": {"provider": "github"}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'

# A timed-out lock is a wait, never a force-acquire (stubbed lock timeout).
rm -f "$LEASE" "${LEASE:?}.lock.d"
mkdir -p "$LEASE.lock.d"
printf 'issue=99 held=1 expires=9999999999 pid=%s\n' "$$" > "$LEASE.lock.d/pid"  # a live holder token
printf 'issue=34 held=1 expires=9999999999 pid=%s\n' "$$" > "$LEASE"
TALOS_LEASE_LOCK_S=1 st next
assert_contains "$OUT" "action=wait reason=lease retry_after_s=" "lease (lock timeout): a lock that cannot be held is a wait with the holder's TTL, never a force-acquire"
assert_contains "$(cat "$LEASE")" "expires=9999999999" "lease (lock timeout): the holder's line is untouched"
rm -rf "${LEASE:?}.lock.d"

# ── AC5: help documents state and next (issue-side: #471) ─────────────────────
HELP_OUT="$(bash "$TN" help)"
assert_contains "$HELP_OUT" "  state " "help: lists the state verb"
assert_contains "$HELP_OUT" "state=<JSON>" "help: says what state prints"
assert_contains "$HELP_OUT" "  next " "help: lists the next verb"
assert_contains "$HELP_OUT" "action=dispatch" "help: documents the dispatch action"
assert_contains "$HELP_OUT" "action=wait" "help: documents the wait action"
assert_contains "$HELP_OUT" "action=ask-owner" "help: documents the ask-owner action"

# The header documents both verbs' reason enums (the fixed contract).
for _h in "state-reasons:" "next-reasons:"; do
  grep -q "^# $_h" "$TALOS"
  assert_eq "0" "$?" "talos.sh header: has the ${_h%:} enum line"
done

finish