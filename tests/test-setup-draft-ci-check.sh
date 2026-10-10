#!/usr/bin/env bash
# test-setup-draft-ci-check.sh -- the /pipeline-setup pr.draft workflow check
# (#340, reworked by #435).
#
# The check used to be a shell loop typed into the setup skill, and with no
# workflow file its empty output read as "nothing missing". It is now one call,
# `bash scripts/pipeline-draft-check.sh`, which prints `none` for "no workflow
# with a pull_request trigger" as its own status, never `ok`. This test runs
# that call in sandboxes (the statuses themselves are covered by
# tests/test-draft-check.sh).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

DC="$TALOS_ROOT/scripts/pipeline-draft-check.sh"

run_check() { (cd "$1" && bash "$DC" 2>&1); }

# No workflow files is its own outcome (none), never ok.
mkdir -p "$SANDBOX/empty/.github/workflows"
assert_eq "none" "$(run_check "$SANDBOX/empty")" "empty workflows directory reports none, not ok"
mkdir -p "$SANDBOX/absent"
assert_eq "none" "$(run_check "$SANDBOX/absent")" "no .github/workflows directory reports none"
mkdir -p "$SANDBOX/other/.github/workflows"; printf 'x\n' > "$SANDBOX/other/.github/workflows/README.txt"
assert_eq "none" "$(run_check "$SANDBOX/other")" "a workflows directory with no .yml/.yaml file reports none"

# A paired workflow is ok; a half-paired one is named by status.
mkdir -p "$SANDBOX/ok/.github/workflows"
printf 'on:\n  pull_request:\n    types: [opened, ready_for_review]\njobs:\n  t:\n    if: github.event.pull_request.draft != true\n' > "$SANDBOX/ok/.github/workflows/tests.yml"
assert_eq "ok" "$(run_check "$SANDBOX/ok")" "a workflow with ready_for_review and the draft guard is ok"
mkdir -p "$SANDBOX/bad/.github/workflows"
printf 'on:\n  pull_request:\n    types: [ready_for_review]\njobs:\n  t:\n    runs-on: x\n' > "$SANDBOX/bad/.github/workflows/b.yaml"
assert_eq "no-skip" "$(run_check "$SANDBOX/bad")" "a .yaml workflow without the draft guard is no-skip"

finish
