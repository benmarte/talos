#!/usr/bin/env bash
# test-red-ci-routes-to-gate.sh -- a ready PR with every approval and a red
# required check is routed to the merge gate, which owns the CI re-run and the
# ci-failed handling; only a pending (or missing) check waits on `ci` (#960).
#
#   AC1  every approval + pr-checks-required exit 1 (failed) -> action=merge
#   AC2  every approval + pr-checks-required exit 2 (pending) -> action=wait reason=ci
#   AC3  `talos.sh run` on a red PR reaches `gate merge`, which posts its first
#        CI re-run marker
#
# The shipped scripts/ run for real (the github adapter included); only the
# provider CLI is stubbed (tests/stubs/gh). No sleeps, no network, no LLM call.
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

printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "issues": {"max_parallel": 1}}' > "$PIPELINE_CONFIG"

LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }

# An open non-draft PR with every approval label and marker for its head.
_labels='[{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}]'
_c=""
for _r in qa docs reviewer security; do
  _c="$_c{\"body\": \"<!-- talos:approval sha=$HEAD_SHA role=$_r -->\"},"
done
export STUB_ISSUE_LABELS_JSON='[]'
export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"red ci\", \"labels\": [], \"assignees\": [{\"login\": \"$OPERATOR\"}], \"body\": \"\"}]"
export STUB_PR_LIST="[{\"number\": $PR, \"state\": \"OPEN\", \"title\": \"fix\", \"headRefName\": \"fix/issue-$N-red-ci\", \"baseRefName\": \"main\", \"isCrossRepository\": false, \"labels\": $_labels}]"
export STUB_PR_LABELS_JSON="$_labels"
export STUB_PR_COMMENTS_JSON="[${_c%,}]"
export STUB_PR_HEAD_SHA="$HEAD_SHA"

nx() { LEASE_RESET; OUT="$(bash "$TALOS" next --issue "$N" 2>"$ERR")"; RC=$?; }

# AC1: a failed required check is the merge gate's business.
STUB_PR_CHECKS="$(printf 'test\tfail\t1m\thttps://example/checks')"; export STUB_PR_CHECKS
nx
assert_eq "action=merge pr=$PR issue=$N" "$OUT" "AC1 every approval and a red required check: next routes to the merge stage"
assert_eq "0" "$RC" "AC1 next exits 0"

# AC2: a pending check still waits.
STUB_PR_CHECKS="$(printf 'test\tpending\t0m\thttps://example/checks')"; export STUB_PR_CHECKS
nx
assert_eq "action=wait reason=ci" "$OUT" "AC2 every approval and a pending required check: next answers wait reason=ci"

# AC3: `run` on the red PR reaches `gate merge` and posts its first re-run marker.
STUB_PR_CHECKS="$(printf 'test\tfail\t1m\thttps://example/checks')"; export STUB_PR_CHECKS
export GH_REST_LOG="$SANDBOX/rest.log"
: > "$GH_REST_LOG"
LEASE_RESET
OUT="$(bash "$TALOS" run --issue "$N" --max-iterations 1 2>"$ERR")"; RC=$?
assert_contains "$OUT$(cat "$ERR")" "reason=ci-rerun" "AC3 run on a red PR: the gate answers ci-rerun"
assert_contains "$(grep -F "/issues/$PR/comments" "$GH_REST_LOG")" "talos:ci-rerun $HEAD_SHA" "AC3 the gate posted its first CI re-run marker for the head"

finish
