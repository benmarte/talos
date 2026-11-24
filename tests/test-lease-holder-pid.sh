#!/usr/bin/env bash
# test-lease-holder-pid.sh -- TALOS_LEASE_PID: which process keeps a lease alive,
# apart from which run owns it (#1076). In the LLM loop every `talos.sh next` is a
# fresh shell, so the `$$` it stamps is dead on return and the lease is reclaimed
# after TALOS_LEASE_RECLAIM_S while a background subagent still works.
#   AC1 (test) a live TALOS_LEASE_PID is the lease line's pid, and the lease
#       survives the reclaim guard
#   AC2 (test) the same TALOS_LEASE_PID is not the lease's owner: the issue is held
#       in flight until `done` releases it
#   AC3 (test) a dead TALOS_LEASE_PID is reclaimed like any dead holder
#   AC4 (test) execution.orchestrator llm outside `run`: a dispatch with no live
#       TALOS_LEASE_PID prints `warn reason=lease-holder-unset`; never under `run`
#   AC5 (same) TALOS_RUN_PID (alone or with TALOS_LEASE_PID) is the line's pid, the
#       lease is re-entrant for that run and the context budget is skipped
# AC6 (docs, changelog) is prose.
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
unset TALOS_RUN_PID TALOS_LEASE_PID TALOS_LEASE_RECLAIM_S TALOS_TRANSCRIPT_PATH

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "execution": {"orchestrator": "llm", "context_budget_tokens": 100000},' \
  ' "issues": {"max_parallel": 3}}' > "$PIPELINE_CONFIG"

# An open PR with no approval yet: `next --issue N` dispatches its qa stage.
export STUB_ISSUE_LABELS_JSON='[]'
export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"lease\", \"labels\": [], \"assignees\": [{\"login\": \"$OPERATOR\"}], \"body\": \"\"}]"
export STUB_PR_LIST="[{\"number\": $PR, \"state\": \"OPEN\", \"title\": \"fix\", \"headRefName\": \"fix/issue-$N-lease\", \"baseRefName\": \"main\", \"isCrossRepository\": false, \"labels\": []}]"
export STUB_PR_LABELS_JSON='[]'
export STUB_PR_COMMENTS_JSON='[]'
export STUB_PR_HEAD_SHA="$HEAD_SHA"

COMMON="$(git -C "$SANDBOX" rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$SANDBOX/$COMMON" ;; esac
LEASE="$COMMON/talos-lease.ledger"
T0=1000000
GUARD=10
# nx <now> [VAR=value ...]: one `next --issue N` at a pinned clock, with the given
# environment on that call only. OUT = stdout, ERR = stderr.
nx() {
  local _now="$1"; shift
  OUT="$(env TALOS_NOW="$_now" "$@" bash "$TALOS" next --issue "$N" 2>"$ERR")"; RC=$?
}
# own_check [VAR=value ...]: `_talos_lease check N` (the re-entrancy test) in a
# bash that sourced talos.sh's functions; rc=0 = the lease is the caller's own,
# rc=1 = another holder's live lease. live= lists the in-flight issues.
own_check() {
  OUT="$(env TALOS_NOW="$((T0 + 1))" "$@" bash -c '
    set -u
    . "$1" help >/dev/null 2>&1
    SCRIPT_DIR="$2"
    _talos_lease check "$3" >/dev/null; echo "rc=$?"
    echo "live=$(_talos_lease_live_issues)"
  ' own_check "$TALOS" "$TALOS_ROOT/scripts" "$N" 2>/dev/null)"
}
line_pid() { sed -n "s/^issue=$N .* pid=\([0-9]*\).*/\1/p" "$LEASE" 2>/dev/null | head -1; }

# A live pid for the whole file; a dead one (spawned, killed, reaped).
sleep 300 & LIVE=$!
trap 'kill "$LIVE" 2>/dev/null' EXIT
( sleep 30 ) & DEAD=$!
kill "$DEAD" 2>/dev/null
wait "$DEAD" 2>/dev/null

# ── AC1: a live TALOS_LEASE_PID keeps the lease past the reclaim guard ────────
reset_leases
nx "$T0" TALOS_LEASE_PID="$LIVE"
assert_contains "$OUT" "action=dispatch" "AC1 control: next dispatches the issue" "$(cat "$ERR")"
assert_eq "$LIVE" "$(line_pid)" "AC1 the lease line carries TALOS_LEASE_PID"
nx "$((T0 + GUARD + 50))" TALOS_LEASE_PID="$LIVE"
assert_not_contains "$(cat "$ERR")" "lease reclaimed" "AC1 a second next after the reclaim guard does not reclaim"
assert_contains "$OUT" "action=wait reason=lease" "AC1 the lease still holds after the reclaim guard"
assert_eq "$LIVE" "$(line_pid)" "AC1 the line is untouched"

# ── AC2: the same TALOS_LEASE_PID is not the owner ────────────────────────────
reset_leases
nx "$T0" TALOS_LEASE_PID="$LIVE"
nx "$((T0 + 1))" TALOS_LEASE_PID="$LIVE"
assert_not_contains "$OUT" "action=dispatch" "AC2 a second next with the same TALOS_LEASE_PID does not dispatch the issue again"
assert_contains "$OUT" "action=wait reason=lease" "AC2 the issue is held as in flight"
# The live lease counts toward the issue-side walk too (no --issue): never re-offered.
OUT="$(env TALOS_NOW="$((T0 + 2))" TALOS_LEASE_PID="$LIVE" bash "$TALOS" next 2>"$ERR")"
assert_not_contains "$OUT" "action=dispatch" "AC2 next without --issue does not re-offer the leased issue"
own_check TALOS_LEASE_PID="$LIVE"
assert_contains "$OUT" "rc=1" "AC2 the same TALOS_LEASE_PID is another holder's live lease, never re-entrant"
assert_eq "live=$N" "$(printf '%s\n' "$OUT" | grep '^live=')" "AC2 the lease counts as in flight"
# `done` releases it; the issue can be routed again.
printf 'PASS\n' | env TALOS_NOW="$((T0 + 3))" TALOS_LEASE_PID="$LIVE" bash "$TALOS" done qa --issue "$N" --pr "$PR" --verdict PASS --summary-file - >/dev/null 2>"$ERR"
assert_eq "" "$(grep "^issue=$N " "$LEASE" 2>/dev/null)" "AC2 done releases the lease" "$(cat "$ERR")"
nx "$((T0 + 4))" TALOS_LEASE_PID="$LIVE"
assert_contains "$OUT" "action=dispatch" "AC2 after done the issue can be routed" "$(cat "$ERR")"

# ── AC3: a dead TALOS_LEASE_PID is reclaimed like any dead holder ─────────────
reset_leases
nx "$T0" TALOS_LEASE_PID="$DEAD"
assert_eq "$DEAD" "$(line_pid)" "AC3 control: the dead pid is the line's pid"
nx "$((T0 + GUARD + 50))" TALOS_LEASE_PID="$DEAD"
assert_contains "$(cat "$ERR")" "lease reclaimed from dead holder issue=$N" "AC3 the dead holder's lease is reclaimed after the guard"
assert_contains "$OUT" "action=dispatch" "AC3 the reclaimed issue is dispatched"

# ── AC4: warn reason=lease-holder-unset ───────────────────────────────────────
reset_leases
nx "$T0"
assert_contains "$OUT" "warn reason=lease-holder-unset" "AC4 a dispatch with TALOS_LEASE_PID unset warns"
assert_contains "$OUT" "action=dispatch" "AC4 the warn sits beside the dispatch answer"
reset_leases
nx "$T0" TALOS_LEASE_PID="$LIVE"
assert_not_contains "$OUT" "lease-holder-unset" "AC4 a live TALOS_LEASE_PID does not warn"
reset_leases
nx "$T0" TALOS_LEASE_PID="$DEAD"
assert_contains "$OUT" "warn reason=lease-holder-unset" "AC4 a TALOS_LEASE_PID naming no live process warns"
reset_leases
nx "$T0" TALOS_RUN_PID="$LIVE"
assert_not_contains "$OUT" "lease-holder-unset" "AC4 under run (TALOS_RUN_PID set) it never warns"
reset_leases
nx "$T0" TALOS_RUN_PID="$LIVE" TALOS_LEASE_PID="$DEAD"
assert_not_contains "$OUT" "lease-holder-unset" "AC4 under run it never warns, even with a dead TALOS_LEASE_PID"

# ── AC5: the run driver's lease is unchanged ──────────────────────────────────
reset_leases
nx "$T0" TALOS_RUN_PID="$LIVE"
assert_eq "$LIVE" "$(line_pid)" "AC5 the lease line carries TALOS_RUN_PID"
assert_not_contains "$OUT" "context-unknown" "AC5 the context budget check is skipped under TALOS_RUN_PID"
own_check TALOS_RUN_PID="$LIVE"
assert_contains "$OUT" "rc=0" "AC5 the lease is re-entrant for that run"
assert_eq "live=" "$(printf '%s\n' "$OUT" | grep '^live=')" "AC5 the run's own lease is not in flight"
reset_leases
nx "$T0" TALOS_RUN_PID="$LIVE" TALOS_LEASE_PID="$$"
assert_eq "$LIVE" "$(line_pid)" "AC5 with both set, the lease line carries TALOS_RUN_PID"
own_check TALOS_RUN_PID="$LIVE" TALOS_LEASE_PID="$$"
assert_contains "$OUT" "rc=0" "AC5 with both set, the lease is re-entrant for the run"
reset_leases
nx "$T0" TALOS_LEASE_PID="$LIVE"
assert_contains "$OUT" "warn reason=context-unknown" "AC5 TALOS_LEASE_PID alone leaves the context budget check on"

finish
