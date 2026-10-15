#!/usr/bin/env bash
# test-azure-pr-checks-fallback.sh -- azure pr-checks-required with an empty
# merge.required_checks judges the PR's blocking policy evaluations (#686)
# instead of refusing. Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'JSON'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
JSON

PROJ="6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c"
HEAD_SHA="1111111111111111111111111111111111111111"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"status\":\"active\",\"repository\":{\"id\":\"r1\",\"project\":{\"id\":\"$PROJ\"}},\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD_SHA\"}}"

# One evaluation record: $1 = display name ("" = none), $2 = status,
# $3 = isBlocking (true|false), $4 = context JSON (optional).
_rec() {
  local settings='{}' ctx=""
  [ -n "$1" ] && settings="{\"displayName\":\"$1\"}"
  [ -n "${4:-}" ] && ctx=",\"context\":$4"
  printf '{"configuration":{"isBlocking":%s,"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"Build"},"settings":%s},"status":"%s","evaluationId":"00000001-0000-0000-0000-000000000000"%s}' \
    "$3" "$settings" "$2" "$ctx"
}
_evals() { printf '{"count":0,"value":[%s]}' "$1"; }
_run() { STUB_AZURE_PR_EVALUATIONS="$(_evals "$1")" bash "$VCS" pr-checks-required 9 2>&1; }

out="$(_run "$(_rec "CI build" approved true),$(_rec "Reviewers" notApplicable true)")"; rc=$?
assert_eq "0" "$rc" "AC1 blocking approved and notApplicable evaluations pass"
assert_contains "$out" "pr-checks-required: all required checks passed: " "AC1 prints the shared summary line"

out="$(_run "$(_rec "CI build" rejected true),$(_rec "Reviewers" running true)")"; rc=$?
assert_eq "1" "$rc" "AC2 a rejected blocking evaluation fails even beside a running one"
assert_contains "$out" "pr-checks-required: failed: CI build" "AC2 names the failed policy"
assert_not_contains "$out" "merge.required_checks is empty" "AC2 is not the empty-list refusal"
out="$(_run "$(_rec "CI build" approved true),$(_rec "Reviewers" broken true)")"; rc=$?
assert_eq "1" "$rc" "AC2 a broken blocking evaluation fails"

out="$(_run "$(_rec "CI build" approved true),$(_rec "Reviewers" queued true)")"; rc=$?
assert_eq "2" "$rc" "AC3 a queued blocking evaluation is pending"
assert_contains "$out" "pr-checks-required: pending or missing: Reviewers" "AC3 names the pending policy"

out="$(_run "$(_rec "CI build" approved true),$(_rec "lint" rejected false)")"; rc=$?
assert_eq "0" "$rc" "AC4 a rejected non-blocking evaluation is ignored"

out="$(_run "")"; rc=$?
assert_eq "2" "$rc" "AC5 no evaluations at all is pending"
assert_not_contains "$out" "merge.required_checks is empty" "AC5 no evaluations is not the empty-list refusal"
out="$(_run "$(_rec "lint" approved false)")"; rc=$?
assert_eq "2" "$rc" "AC5 no blocking evaluation is pending"

_ctx_exp='{"isExpired":true}'
out="$(_run "$(_rec "CI build" approved true "$_ctx_exp")")"; rc=$?
assert_eq "2" "$rc" "AC6 an expired approval is pending"
_ctx_old='{"isExpired":false,"lastMergeSourceCommitId":"2222222222222222222222222222222222222222"}'
out="$(_run "$(_rec "CI build" approved true "$_ctx_old")")"; rc=$?
assert_eq "2" "$rc" "AC6 an approval for an older source commit is pending"
out="$(_run "$(_rec "" rejected true)")"; rc=$?
assert_eq "1" "$rc" "AC6 a blocking record with no display name is still judged"
out="$(_run "$(_rec "CI build" approved true),$(_rec "" running true)")"; rc=$?
assert_eq "2" "$rc" "AC6 a nameless pending record keeps the PR from passing"

finish
