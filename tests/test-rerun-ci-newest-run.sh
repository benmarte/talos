#!/usr/bin/env bash
# test-rerun-ci-newest-run.sh -- `pipeline-vcs.sh rerun-ci` (PR form and --sha)
# re-runs only each workflow's newest run on the head (highest run_number, then
# highest id); an older run is never re-run, whatever its conclusion (#1077).
# Uses the curl stub (CURL_LOG + CURL_QUEUE): no network. Tests are named by the
# spec's criterion id.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export GITHUB_TOKEN="test-secret-token-1077"
export TALOS_RETRY_SLEEP_SCALE=0
export STUB_CURRENT_USER="bot"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

SHA="0123456789abcdef0123456789abcdef01234567"
PR_JSON="{\"number\":9,\"head\":{\"sha\":\"$SHA\",\"ref\":\"fix/issue-42-guard\"},\"title\":\"fix: guard\"}"

# run_rerun <pr|sha> <runs-json>: sets out, rc and log (the curl log of the call).
run_rerun() {
  : > "$CURL_LOG"
  if [ "$1" = "pr" ]; then
    printf '%s\n%s\n{}\n{}\n' "$PR_JSON" "$2" > "$CURL_QUEUE"
    out="$(bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
  else
    printf '%s\n{}\n{}\n' "$2" > "$CURL_QUEUE"
    out="$(bash "$VCS" rerun-ci --sha "$SHA" 2>&1)"; rc=$?
  fi
  log="$(cat "$CURL_LOG")"
}

# AC1: an old cancelled run and a newer in-progress run of one workflow.
R1='{"total_count":2,"workflow_runs":[{"id":900,"workflow_id":7,"run_number":3,"status":"completed","conclusion":"cancelled"},{"id":905,"workflow_id":7,"run_number":4,"status":"in_progress","conclusion":null}]}'
run_rerun pr "$R1"
assert_eq "0" "$rc" "AC1 PR form exits 0 while the newest run is in progress"
assert_not_contains "$log" "rerun-failed-jobs" "AC1 PR form POSTs no rerun-failed-jobs"
assert_contains "$out" "are still in progress; nothing to re-run yet" "AC1 PR form prints the still-in-progress message"
run_rerun sha "$R1"
assert_eq "2" "$rc" "AC1 --sha exits 2 while the newest run is in progress"
assert_not_contains "$log" "rerun-failed-jobs" "AC1 --sha POSTs no rerun-failed-jobs"

# AC2: an old cancelled run and a newer failed run: only the newer one is re-run.
R2='{"total_count":2,"workflow_runs":[{"id":950,"workflow_id":7,"run_number":3,"status":"completed","conclusion":"cancelled"},{"id":940,"workflow_id":7,"run_number":4,"status":"completed","conclusion":"failure"}]}'
for form in pr sha; do
  run_rerun "$form" "$R2"
  assert_eq "0" "$rc" "AC2 $form form exits 0 after a re-run"
  assert_contains "$log" "/actions/runs/940/rerun-failed-jobs" "AC2 $form form re-runs the newer failed run"
  assert_not_contains "$log" "/actions/runs/950/rerun-failed-jobs" "AC2 $form form leaves the older cancelled run alone"
done

# AC3: an old failed run and a newer successful run: nothing is re-run.
R3='{"total_count":2,"workflow_runs":[{"id":960,"workflow_id":7,"run_number":3,"status":"completed","conclusion":"failure"},{"id":961,"workflow_id":7,"run_number":4,"status":"completed","conclusion":"success"}]}'
run_rerun pr "$R3"
assert_eq "0" "$rc" "AC3 PR form exits 0 with nothing to re-run"
assert_contains "$out" "no failed runs found" "AC3 PR form says no failed runs were found"
assert_not_contains "$log" "rerun-failed-jobs" "AC3 PR form re-runs nothing"
run_rerun sha "$R3"
assert_eq "1" "$rc" "AC3 --sha exits 1 with nothing to re-run"
assert_not_contains "$log" "rerun-failed-jobs" "AC3 --sha re-runs nothing"

# The run_number decides before the id: a higher id of an older number is not newest.
R3B='{"total_count":2,"workflow_runs":[{"id":999,"workflow_id":7,"run_number":3,"status":"completed","conclusion":"failure"},{"id":961,"workflow_id":7,"run_number":4,"status":"completed","conclusion":"success"}]}'
run_rerun sha "$R3B"
assert_eq "1" "$rc" "AC3 the highest run_number is newest, not the highest id"
assert_not_contains "$log" "rerun-failed-jobs" "AC3 the older run with the higher id is not re-run"

# AC4: two workflows, each with a failed newest run: both are re-run.
R4='{"total_count":3,"workflow_runs":[{"id":970,"workflow_id":7,"run_number":5,"status":"completed","conclusion":"failure"},{"id":971,"workflow_id":8,"run_number":2,"status":"completed","conclusion":"timed_out"},{"id":972,"workflow_id":8,"run_number":1,"status":"completed","conclusion":"failure"}]}'
for form in pr sha; do
  run_rerun "$form" "$R4"
  assert_eq "0" "$rc" "AC4 $form form exits 0 after the re-runs"
  assert_contains "$log" "/actions/runs/970/rerun-failed-jobs" "AC4 $form form re-runs the first workflow's newest run"
  assert_contains "$log" "/actions/runs/971/rerun-failed-jobs" "AC4 $form form re-runs the second workflow's newest run"
  assert_not_contains "$log" "/actions/runs/972/rerun-failed-jobs" "AC4 $form form skips the second workflow's older run"
done

# AC5 (same: a single failed run per workflow is re-run as before).
R5='{"total_count":1,"workflow_runs":[{"id":980,"workflow_id":7,"run_number":1,"status":"completed","conclusion":"failure"}]}'
run_rerun pr "$R5"
assert_eq "0" "$rc" "AC5 PR form: a single failed run exits 0"
assert_eq "rerun-ci: re-ran failed runs for PR #9 ($SHA)" "$out" "AC5 PR form: the output is unchanged"
assert_contains "$log" "/actions/runs/980/rerun-failed-jobs" "AC5 PR form: the failed run is re-run"
run_rerun sha "$R5"
assert_eq "0" "$rc" "AC5 --sha: a single failed run exits 0"
assert_eq "rerun-ci: re-ran failed runs for commit $SHA ($SHA)" "$out" "AC5 --sha: the output is unchanged"
assert_contains "$log" "/actions/runs/980/rerun-failed-jobs" "AC5 --sha: the failed run is re-run"

# AC6 (prose: docs and changelog) has no test.
finish
