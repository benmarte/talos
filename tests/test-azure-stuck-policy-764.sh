#!/usr/bin/env bash
# test-azure-stuck-policy-764.sh -- azure pr-checks-required requeues a Build
# policy evaluation that is queued with no build attached, once per PR,
# evaluation and source commit (#764, slice 4 of #753). Each driver poll is a
# separate process, so the once-state is a marker file under the state dir.
# Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CFG_BASE='"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "merge": {"required_checks": ["CI build"]}'
printf '{%s}\n' "$CFG_BASE" > talos.pipeline.json

PROJ="6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c"
HEAD_SHA="1111111111111111111111111111111111111111"
EVAL_ID="00000001-0000-0000-0000-000000000000"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"status\":\"active\",\"repository\":{\"id\":\"r1\",\"project\":{\"id\":\"$PROJ\"}},\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD_SHA\"}}"

# One Build evaluation: $1 = status, $2 = context JSON (optional).
_rec() {
  local ctx=""
  [ -n "${2:-}" ] && ctx=",\"context\":$2"
  printf '{"configuration":{"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"Build"},"settings":{"displayName":"CI build"}},"status":"%s","evaluationId":"%s"%s}' \
    "$1" "$EVAL_ID" "$ctx"
}
_evals() { printf '{"count":0,"value":[%s]}' "$1"; }
_run() { STUB_AZURE_PR_EVALUATIONS="$(_evals "$1")" bash "$VCS" pr-checks-required 9 2>&1; }
_patches() { grep -c "\[--method\] \[patch\].*policy/evaluations/$EVAL_ID" "$GH_LOG" || true; }
MARKER_DIR="$(git rev-parse --git-common-dir)/talos/azure-requeue"
_markers() { find "$MARKER_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }
_reset() { : > "$GH_LOG"; rm -rf "${MARKER_DIR:?}"; }

# AC1 -- the first stuck read requeues once and stays pending.
_reset
out="$(_run "$(_rec queued)")"; rc=$?
assert_eq "2" "$rc" "AC1 a stuck evaluation exits 2 (pending) on the first read"
assert_eq "1" "$(_patches)" "AC1 exactly one PATCH is sent"
assert_contains "$(cat "$GH_LOG")" "[--url] [https://dev.azure.com/acme/$PROJ/_apis/policy/evaluations/$EVAL_ID?api-version=7.1-preview.1]" \
  "AC1 the PATCH targets the evaluation under the project id"
assert_contains "$out" "pr-checks-required: requeued stuck policy evaluation $EVAL_ID (CI build)" "AC1 prints the requeued line"
assert_eq "1" "$(_markers)" "AC1 one marker is written after the PATCH"

# AC2 -- the second stuck read on the same PR, evaluation and commit.
out="$(_run "$(_rec queued)")"; rc=$?
assert_eq "1" "$rc" "AC2 a second stuck read exits 1"
assert_eq "1" "$(_patches)" "AC2 no second PATCH is sent"
assert_contains "$out" "pr-checks-required: stuck: CI build (queued without a build after one requeue)" "AC2 names the stuck policy"

# AC3 -- queued with a build attached, and running, are plain pending.
_reset
out="$(_run "$(_rec queued '{"buildId":4242}')")"; rc=$?
assert_eq "2" "$rc" "AC3 a queued evaluation with a buildId exits 2"
assert_eq "0" "$(_patches)" "AC3 a queued evaluation with a buildId sends no PATCH"
out="$(_run "$(_rec running)")"; rc=$?
assert_eq "2" "$rc" "AC3 a running evaluation exits 2"
assert_eq "0" "$(_patches)" "AC3 a running evaluation sends no PATCH"
assert_eq "0" "$(_markers)" "AC3 no marker is written for plain pending"

# AC4 -- the config key switches the requeue off.
_reset
printf '{%s, "verify": {"ci_requeue_stuck": false}}\n' "$CFG_BASE" > talos.pipeline.json
out="$(_run "$(_rec queued)")"; rc=$?
assert_eq "2" "$rc" "AC4 verify.ci_requeue_stuck false leaves the stuck evaluation pending"
assert_eq "0" "$(_patches)" "AC4 no PATCH is sent"
assert_not_contains "$out" "stuck:" "AC4 no stuck line"
assert_eq "0" "$(_markers)" "AC4 no marker is written"
out="$(_run "$(_rec queued)")"; rc=$?
assert_eq "2" "$rc" "AC4 a repeat read is still pending, never stuck"

# AC5 -- a failed PATCH exits 1 and writes no marker, so the next call retries.
_reset
printf '{%s}\n' "$CFG_BASE" > talos.pipeline.json
out="$(STUB_AZURE_REQUEUE_FAIL=1 _run "$(_rec queued)")"; rc=$?
assert_eq "1" "$rc" "AC5 a failed requeue exits 1"
assert_contains "$out" "pipeline-vcs: pr-checks-required: requeue of policy evaluation $EVAL_ID failed" "AC5 prints the requeue-failed line"
assert_eq "0" "$(_markers)" "AC5 no marker is written"
out="$(_run "$(_rec queued)")"; rc=$?
assert_eq "2" "$rc" "AC5 the next call tries again and requeues"
assert_eq "2" "$(_patches)" "AC5 the retry sends a second PATCH"

finish
