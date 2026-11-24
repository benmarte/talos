#!/usr/bin/env bash
# test-lease-reset-helper.sh -- a test that calls `next` twice on one issue must not
# depend on a lease expiring (#1068). test-next-collect-call-budget.sh removed
# `.git/talos/lease*`, but the ledger is `<git common dir>/talos-lease.ledger`: the
# dead `next` pid's line stayed until the reclaim age guard (10 s) passed, so a fast
# CI runner got `wait reason=lease` where a Mac got a dispatch.
#   AC1 (test) the shared `reset_leases` helper removes every lease for the sandbox
#       repo (found from git, not hard-coded), and a lease taken by `next` is gone after it
#   AC2 (test) tests/test-next-collect-call-budget.sh passes 20 runs in a row with the
#       lease TTL and the dead-holder reclaim guard raised to 60 s
#   AC3 (same) a second `next --issue N` while a live lease from another pid exists
#       still answers `wait reason=lease`: the lease still protects real runs
# AC4 (changelog) is prose.
#
# The shipped scripts/ run for real; only the provider CLI is stubbed (tests/stubs/gh).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"
N=7
PR=12
OPERATOR="operator1"
export STUB_CURRENT_USER="$OPERATOR"
HEAD_SHA="1111111111111111111111111111111111111111"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "issues": {"max_parallel": 1}}' > "$PIPELINE_CONFIG"

# An open PR with no approval yet: `next --issue N` dispatches its qa stage.
export STUB_ISSUE_LABELS_JSON='[]'
export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"lease\", \"labels\": [], \"assignees\": [{\"login\": \"$OPERATOR\"}], \"body\": \"\"}]"
export STUB_PR_LIST="[{\"number\": $PR, \"state\": \"OPEN\", \"title\": \"fix\", \"headRefName\": \"fix/issue-$N-lease\", \"baseRefName\": \"main\", \"isCrossRepository\": false, \"labels\": []}]"
export STUB_PR_LABELS_JSON='[]'
export STUB_PR_COMMENTS_JSON='[]'
export STUB_PR_HEAD_SHA="$HEAD_SHA"

# The ledger path, from git: the common dir the code itself uses.
COMMON="$(git -C "$SANDBOX" rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$SANDBOX/$COMMON" ;; esac
LEASE="$COMMON/talos-lease.ledger"
nx() { OUT="$(bash "$TALOS" next --issue "$N" 2>"$ERR")"; RC=$?; }
leases_left() { find "$COMMON" -maxdepth 1 -name 'talos-lease.ledger*' | wc -l | tr -d ' '; }
# reset: reset_leases when tests/helpers.sh defines it, else a no-op that
# leaves the lease in place (so a missing helper shows as failed assertions).
reset() { if [ "$(type -t reset_leases)" = function ]; then reset_leases >/dev/null 2>&1; fi; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
assert_eq "function" "$(type -t reset_leases || echo missing)" "AC1 tests/helpers.sh defines reset_leases"
reset
nx
assert_contains "$OUT" "action=dispatch" "AC1 control: next dispatches the issue" "$(cat "$ERR")"
assert_eq "1" "$(grep -c "^issue=$N " "$LEASE" 2>/dev/null || true)" "AC1 control: the dispatch took a lease in the ledger"
reset
assert_eq "0" "$(leases_left)" "AC1 a lease taken by next is gone after reset_leases (no ledger, lock dir or temp file)"
nx
assert_contains "$OUT" "action=dispatch" "AC1 after reset_leases the next dispatch is not held back by the dead pid's lease" "$(cat "$ERR")"
reset
# A stale ledger line, a stale lock dir and a temp file: all go.
printf 'issue=%s held=1 expires=2 pid=1\n' "$N" > "$LEASE"
mkdir -p "$LEASE.lock.d"; : > "$LEASE.tmp.1"
reset
assert_eq "0" "$(leases_left)" "AC1 reset_leases removes the ledger, its lock dir and its temp files"
if [ "$(type -t reset_leases)" = function ]; then
  RC=0; reset_leases "$SANDBOX/no-such-dir" >/dev/null 2>&1 || RC=$?
else
  RC=missing
fi
assert_eq "1" "$RC" "AC1 reset_leases on a directory that is no repo fails instead of removing anything"

# ── AC3 ─────────────────────────────────────────────────────────────────────
# A live holder: this test's own shell, a pid `next` is not.
NOW="$(date +%s)"
printf 'issue=%s held=%s expires=%s pid=%s\n' "$N" "$NOW" "$((NOW + 600))" "$$" > "$LEASE"
nx
assert_contains "$OUT" "action=wait reason=lease" "AC3 a live lease from another pid still answers wait reason=lease" "$(cat "$ERR")"
assert_eq "1" "$(grep -c "^issue=$N " "$LEASE")" "AC3 the live holder's line is untouched"
reset

# ── AC2 ─────────────────────────────────────────────────────────────────────
# A 60 s lease and a 60 s dead-holder guard: the budget test may not lean on expiry.
# Each run has its own sandbox, so ten run side by side (two waves of ten: one run
# alone takes about a minute).
FAILED=0; RUN=0
budget_run() {  # $1=run number: the budget test with a long lease; rc 0 on pass
  TALOS_LEASE_TTL_S=60 TALOS_LEASE_RECLAIM_S=60 bash "$TALOS_ROOT/tests/test-next-collect-call-budget.sh" > "$SANDBOX/budget.$1.out" 2>&1
}
for WAVE in 1 2; do
  for I in 1 2 3 4 5 6 7 8 9 10; do
    RUN=$(( (WAVE - 1) * 10 + I ))
    budget_run "$RUN" &
  done
  wait
done
RUN=0
while [ "$RUN" -lt 20 ]; do
  RUN=$((RUN + 1))
  grep -q ': [0-9]* passed, 0 failed$' "$SANDBOX/budget.$RUN.out" && continue
  FAILED=$((FAILED + 1))
  [ "$FAILED" -gt 1 ] || grep -v '^  ok' "$SANDBOX/budget.$RUN.out" | head -5 >&2
done
assert_eq "0" "$FAILED" "AC2 test-next-collect-call-budget.sh passes 20 runs in a row with a 60 s lease and reclaim guard"

finish
