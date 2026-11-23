#!/usr/bin/env bash
# test-checks-newer-run-pending.sh -- #1054: a required check whose newest check
# run is cancelled or skipped is PENDING, not failed, while a newer workflow run
# of the same workflow for the same head sha is queued or in progress (a
# `needs:` aggregate job such as `test (ubuntu-latest)` has no check run in the
# newer run until its shards finish). pr-checks-required and ref-checks-required
# answer the same. Uses the gh stub (check runs and workflow runs); no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA="1111111111111111111111111111111111111111"
ERR="$SANDBOX/err.txt"
NAME="test (ubuntu-latest)"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "merge": {"required_checks": ["%s"]}}\n' "$NAME" > talos.pipeline.json
export STUB_GH_COMMIT_SHA="$SHA" STUB_PR_HEAD_SHA="$SHA"

# _wf <id> <check_suite_id> <workflow_id> <status> <conclusion|null>: one workflow run.
_wf() {
  local c="\"$5\""; [ "$5" = null ] && c=null
  printf '{"id":%s,"check_suite_id":%s,"workflow_id":%s,"head_sha":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3" "$SHA" "$4" "$c"
}
# _runs <wf run>...: one page of workflow runs.
_runs() {
  local body="" sep="" r total=$#
  for r in "$@"; do body="$body$sep$r"; sep=","; done
  printf '{"total_count":%s,"workflow_runs":[%s]}' "$total" "$body"
}
# _check <state> <check_suite_id>: the stub's check row (name state elapsed url suite).
_check() { printf '%s\t%s\t1m\thttps://ci/run\t%s' "$NAME" "$1" "$2"; }

# _pr / _ref: set RC and ERRS.
_pr()  { bash "$VCS" pr-checks-required 42 >/dev/null 2>"$ERR"; RC=$?; ERRS="$(cat "$ERR")"; }
_ref() { bash "$VCS" ref-checks-required "$SHA" >/dev/null 2>"$ERR"; RC=$?; ERRS="$(cat "$ERR")"; }
_reads() { grep -c 'actions/runs' "$GH_LOG.rest" 2>/dev/null; }

SKIPPED_DRAFT="$(_wf 100 10 7 completed skipped)"
CANCELLED="$(_wf 101 11 7 completed cancelled)"
NEWER_LIVE="$(_wf 102 12 7 in_progress null)"
NEWER_QUEUED="$(_wf 102 12 7 queued null)"
NEWER_OTHER_WF="$(_wf 102 12 8 in_progress null)"
NEWER_DONE="$(_wf 102 12 7 completed success)"

for leg in pr ref; do
  run="_$leg"
  # AC1: cancelled newest check run, a newer run in progress: pending.
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$SKIPPED_DRAFT" "$CANCELLED" "$NEWER_LIVE")" $run
  assert_eq "2" "$RC" "AC1 $leg: a cancelled check with a newer run in progress exits 2"
  assert_contains "$ERRS" "pending or missing: $NAME" "AC1 $leg: the check is named as pending"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_QUEUED")" $run
  assert_eq "2" "$RC" "AC1 $leg: a newer queued run is pending too"

  # AC2: no newer run: a cancelled check is still a failure.
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$SKIPPED_DRAFT" "$CANCELLED")" $run
  assert_eq "1" "$RC" "AC2 $leg: a cancelled check with no newer run exits 1"
  assert_contains "$ERRS" "failed: $NAME" "AC2 $leg: the failed line names the check"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_DONE")" $run
  assert_eq "1" "$RC" "AC2 $leg: a newer run that already finished does not make it pending"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_OTHER_WF")" $run
  assert_eq "1" "$RC" "AC2 $leg: a newer run of another workflow does not make it pending"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$NEWER_LIVE")" $run
  assert_eq "1" "$RC" "AC2 $leg: a check whose run is not in the listing stays failed"

  # AC3: a skipped (draft) run followed by an in-progress run: pending.
  STUB_PR_CHECKS="$(_check skipping 10)" STUB_GH_RUNS_RAW="$(_runs "$SKIPPED_DRAFT" "$CANCELLED" "$NEWER_LIVE")" $run
  assert_eq "2" "$RC" "AC3 $leg: a skipped check with a newer run in progress exits 2"
  assert_contains "$ERRS" "pending or missing: $NAME" "AC3 $leg: the skipped check is named as pending"

  # AC5: a green newest check run passes exactly as today, and reads no runs.
  : > "$GH_LOG.rest"
  STUB_PR_CHECKS="$(_check pass 12)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_LIVE")" $run
  assert_eq "0" "$RC" "AC5 $leg: a green newest check run exits 0"
  assert_eq "0" "$(_reads)" "AC5 $leg: a green check reads no workflow runs"

  # One read of the workflow runs per judgement, for the head sha.
  : > "$GH_LOG.rest"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_LIVE")" $run
  assert_eq "1" "$(_reads)" "AC4 $leg: the workflow runs are read once"
  assert_contains "$(cat "$GH_LOG.rest")" "actions/runs?head_sha=$SHA" "AC4 $leg: the runs are those of the head sha"

  # An unreadable run listing never turns a cancelled check into a pass.
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_API_FAIL=runs $run
  if [ "$leg" = pr ]; then
    assert_eq "2" "$RC" "AC4 $leg: an unreadable run listing reads as nothing reported (exit 2)"
  else
    assert_eq "3" "$RC" "AC4 $leg: an unreadable run listing exits 3"
  fi
done

finish
