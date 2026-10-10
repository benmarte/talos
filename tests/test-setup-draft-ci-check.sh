#!/usr/bin/env bash
# test-setup-draft-ci-check.sh -- the /pipeline-setup pr.draft workflow check
# (#340, reworked by #435).
#
# The check used to be a shell loop typed into the setup skill, and with no
# workflow file its empty output read as "nothing missing". It is now one call,
# `bash scripts/pipeline-draft-check.sh`, which prints `none` for "no workflow
# with a pull_request trigger" as its own status, never `ok`. This test runs
# that call in sandboxes (the statuses themselves are covered by
# tests/test-draft-check.sh), checks the setup skill's text, and pins the
# draft-time-success guidance in the setup skill.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

SETUP="${SETUP_FILE:-$TALOS_ROOT/skills/setup/SKILL.md}"
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

# The setup text calls the script, types no loop, and keeps its outcomes.
SN="$(tr '\n' ' ' < "$SETUP" | tr -s ' ')"
assert_contains "$SN" 'bash scripts/pipeline-draft-check.sh' "setup skill: runs the check script"
assert_not_contains "$SN" 'for f in .github/workflows' "setup skill: no shell loop over the workflows"
assert_contains "$SN" 'ask the user to check the requirements below by hand' "setup skill: an unknown status goes to the user"
assert_contains "$SN" 'bash scripts/pipeline-draft-check.sh edit <file>` (`<file>` is a workflow the check read). It prints the exact diff and writes nothing' "setup skill: the edit is proposed as a diff first"
assert_contains "$SN" 'Show the user the diff and the manual lines verbatim' "setup skill: the user sees the exact diff"
assert_contains "$SN" 'Only after an explicit yes run the same command with `--write`' "setup skill: a workflow is written only after an explicit yes"
assert_contains "$SN" 'It refuses a symlink or non-regular file' "setup skill: a symlink or non-regular file is refused"
assert_contains "$SN" 'An existing job `if:` is never edited' "setup skill: an existing job if: is reported, never edited"
assert_contains "$SN" 'for the user to apply by hand' "setup skill: the combined condition is left to the user"
assert_not_contains "$SN" 'mirroring `templates/ci/github-tests.yml`' "setup skill: no invitation to copy more of the template"
assert_contains "$SN" 'only when the user picks the ready flow (the non-default); never write `draft: true`' "setup skill: only the non-default is written"

# ── Draft-time-success guidance (setup skill) ─────────────────────────────────
for pair in "setup:$SN"; do
  who="${pair%%:*}"; txt="${pair#*:}"
  assert_contains "$txt" "draft-time run must never report success for a required check" "$who: states a draft-time run must not report success for a required check"
  assert_contains "$txt" "branch protection counts a skipped required check as success" "$who: names the skipped-job-counted-as-success case"
  assert_contains "$txt" "always()" "$who: names the always() aggregate job case"
  assert_contains "$txt" "unverified" "$who: says the GitLab/Azure pairing is unverified"
  assert_contains "$txt" "GitLab and Azure" "$who: addresses GitLab and Azure"
done

finish
