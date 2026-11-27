#!/usr/bin/env bash
# test-live-holder-fixture-1106.sh -- a test's foreign lease/lock holder lives
# until the test stops it (#1106). A `sleep 30 &` holder could die under load
# before the second `next` read its lease, and a dead holder answers
# retry_after_s=<reclaim guard>, not the lease's remaining TTL.
#   AC1 (test) start_live_holder / stop_live_holder (tests/helpers.sh): a live
#       process with no lifetime of its own, killed and reaped by the stop
#   AC2 (test) tests/talos-run-sections.sh starts no fixed-lifetime holder
#   AC3 (same) `talos.sh next` answers the TTL for a live holder and the reclaim
#       guard for a dead one
# AC4 (prose) is the unchanged AC10 assertions in tests/talos-run-sections.sh.
#
# The shipped scripts/ run for real; only the provider CLI is stubbed (tests/stubs/gh).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

# ── AC1: the holder helper pair ───────────────────────────────────────────────
HOLDER=""
start_live_holder HOLDER
kill -0 "${HOLDER:-none}" 2>/dev/null
assert_eq "0" "$?" "AC1 start_live_holder gives the caller the pid of a live process"
CMD="$(ps -o command= -p "${HOLDER:-none}" 2>/dev/null)"
if [ -n "$CMD" ] && ! grep -qE '^([^ ]*/)?sleep +[0-9.]+[smhd]? *$' <<<"$CMD"; then
  pass "AC1 the holder is not a bounded sleep"
else
  fail "AC1 the holder is not a bounded sleep" "command line: ${CMD:-<no process>}"
fi
STOPPED="$HOLDER"
stop_live_holder "${HOLDER:-}"
assert_eq "0" "$?" "AC1 stop_live_holder succeeds"
if [ -n "$STOPPED" ] && ! kill -0 "$STOPPED" 2>/dev/null; then
  pass "AC1 after stop_live_holder the pid is gone (killed and reaped)"
else
  fail "AC1 after stop_live_holder the pid is gone (killed and reaped)" "pid: ${STOPPED:-<none>}"
fi

# ── AC2: no fixed-lifetime holder in the run sections ─────────────────────────
SECTIONS="$TALOS_ROOT/tests/talos-run-sections.sh"
assert_eq "" "$(grep -nE 'sleep [0-9]+ *&' "$SECTIONS")" "AC2 no foreign holder with a fixed lifetime"
STARTED="$(sed -n 's/^ *start_live_holder \([A-Za-z_][A-Za-z0-9_]*\)$/\1/p' "$SECTIONS")"
STOPPED_VARS="$(sed -n 's/^ *stop_live_holder "\$\([A-Za-z_][A-Za-z0-9_]*\)"$/\1/p' "$SECTIONS")"
assert_eq "4" "$(grep -c . <<<"$STARTED")" "AC2 the four holder sites use start_live_holder"
assert_eq "$STARTED" "$STOPPED_VARS" "AC2 each section stops the holder it started"

# ── AC3: why the holder must live ─────────────────────────────────────────────
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"
N=9
export STUB_CURRENT_USER="operator1"
unset TALOS_RUN_PID TALOS_LEASE_PID TALOS_LEASE_RECLAIM_S TALOS_TRANSCRIPT_PATH

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "issues": {"max_parallel": 3}}' > "$PIPELINE_CONFIG"

export STUB_ISSUE_LABELS_JSON='[]'
export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"lease\", \"labels\": [], \"assignees\": [{\"login\": \"$STUB_CURRENT_USER\"}], \"body\": \"\"}]"
export STUB_PR_LIST="[{\"number\": 12, \"state\": \"OPEN\", \"title\": \"fix\", \"headRefName\": \"fix/issue-$N-lease\", \"baseRefName\": \"main\", \"isCrossRepository\": false, \"labels\": []}]"
export STUB_PR_LABELS_JSON='[]'
export STUB_PR_COMMENTS_JSON='[]'
export STUB_PR_HEAD_SHA="1111111111111111111111111111111111111111"

COMMON="$(git -C "$SANDBOX" rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$SANDBOX/$COMMON" ;; esac
LEASE="$COMMON/talos-lease.ledger"

# held_next <pid>: one `next` at the clock the lease was taken (AC10's numbers),
# against another holder's lease line carrying <pid>.
held_next() {
  reset_leases
  printf 'issue=%s held=15000 expires=16800 pid=%s\n' "$N" "$1" > "$LEASE"
  OUT="$(TALOS_NOW=15000 TALOS_LEASE_TTL_S=1800 bash "$TALOS" next --issue "$N" 2>"$ERR")"
}

lease_wait() { grep -o 'action=wait reason=lease retry_after_s=[0-9]*' <<<"$OUT"; }

HOLDER=""
start_live_holder HOLDER
# Control: a pid that is no number also answers 1800 (the fail-closed TTL shape).
kill -0 "${HOLDER:-none}" 2>/dev/null
assert_eq "0" "$?" "AC3 control: the lease line's pid is a live process"
held_next "${HOLDER:-none}"
assert_eq "action=wait reason=lease retry_after_s=1800" "$(lease_wait)" \
  "AC3 a live holder's lease answers the remaining TTL"
stop_live_holder "${HOLDER:-}"

sh -c ':' & DEAD=$!
wait "$DEAD" 2>/dev/null
held_next "$DEAD"
assert_eq "action=wait reason=lease retry_after_s=10" "$(lease_wait)" \
  "AC3 a dead holder's lease answers the reclaim guard, not the TTL"

finish
