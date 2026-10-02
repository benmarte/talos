#!/usr/bin/env bash
# test-setup-draft-ci-check.sh -- the /pipeline-setup pr.draft workflow check (#340).
#
# The check used to be `grep -L ... .github/workflows/*.yml 2>/dev/null`: with no
# workflow file the glob stays literal, grep fails, the error is suppressed, and
# the empty output reads as "nothing missing". The check now reports
# "no workflow files found" as its own outcome. This test extracts the real
# fenced block from skills/pipeline-setup/SKILL.md and runs it in sandboxes, so
# it exercises the text the setup wizard actually shows. It also pins the
# draft-time-success guidance in the README and the setup skill.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

SETUP="${SETUP_FILE:-$TALOS_ROOT/skills/pipeline-setup/SKILL.md}"
README="$TALOS_ROOT/README.md"

# The fenced bash block that scans .github/workflows (the one naming ready_for_review).
awk '/^```bash$/{buf=""; inb=1; next} /^```$/{ if (inb && buf ~ /\.github\/workflows/ && buf ~ /ready_for_review/) printf "%s", buf; inb=0; buf=""; next} inb{buf = buf $0 "\n"}' "$SETUP" > "$SANDBOX/check.sh"
assert_eq "1" "$([ -s "$SANDBOX/check.sh" ] && echo 1 || echo 0)" "the setup skill has a workflow-check block"

run_check() { (cd "$1" && bash "$SANDBOX/check.sh" 2>&1); }
NOWF="no workflow files found in .github/workflows"

# Empty workflows directory: its own outcome.
mkdir -p "$SANDBOX/empty/.github/workflows"
assert_eq "$NOWF" "$(run_check "$SANDBOX/empty")" "empty workflows directory reports no workflow files found, not 'nothing missing'"
# No .github at all.
mkdir -p "$SANDBOX/none"
assert_eq "$NOWF" "$(run_check "$SANDBOX/none")" "no .github/workflows directory reports no workflow files found"
# A directory with no workflow files (only a non-yaml file).
mkdir -p "$SANDBOX/other/.github/workflows"; printf 'x\n' > "$SANDBOX/other/.github/workflows/README.txt"
assert_eq "$NOWF" "$(run_check "$SANDBOX/other")" "a workflows directory with no .yml/.yaml file reports no workflow files found"

# A paired workflow: silent.
mkdir -p "$SANDBOX/ok/.github/workflows"
printf 'on:\n  pull_request:\n    types: [opened, ready_for_review]\njobs:\n  t:\n    if: github.event.pull_request.draft != true\n' > "$SANDBOX/ok/.github/workflows/tests.yml"
assert_eq "" "$(run_check "$SANDBOX/ok")" "a workflow with ready_for_review and the draft guard reports nothing"

# Missing pieces are named per file (.yml and .yaml both scanned).
mkdir -p "$SANDBOX/bad/.github/workflows"
printf 'on: [push]\n' > "$SANDBOX/bad/.github/workflows/a.yml"
printf 'on:\n  pull_request:\n    types: [ready_for_review]\n' > "$SANDBOX/bad/.github/workflows/b.yaml"
out="$(run_check "$SANDBOX/bad")"
assert_contains "$out" "missing ready_for_review: .github/workflows/a.yml" "a workflow without ready_for_review is named"
assert_contains "$out" "missing draft != true guard: .github/workflows/a.yml" "a workflow without the draft guard is named"
assert_contains "$out" "missing draft != true guard: .github/workflows/b.yaml" "a .yaml workflow is scanned too"
assert_not_contains "$out" "missing ready_for_review: .github/workflows/b.yaml" "a .yaml workflow that has ready_for_review is not flagged for it"
assert_not_contains "$out" "$NOWF" "workflow files present: the no-workflow outcome is not printed"

# Control: the old one-liner printed nothing for an empty directory (the false negative).
old="$(cd "$SANDBOX/empty" && { grep -L "ready_for_review" .github/workflows/*.yml 2>/dev/null; grep -L "github.event.pull_request.draft != true" .github/workflows/*.yml 2>/dev/null; })"
assert_eq "" "$old" "control: the old grep -L check is silent on an empty workflows directory"

# The wizard text says to treat it as its own outcome and not write pr.draft.
SN="$(tr '\n' ' ' < "$SETUP" | tr -s ' ')"
assert_contains "$SN" '`no workflow files found` is its own outcome, never "nothing missing"' "setup skill: the no-workflow outcome is spelled out"
assert_contains "$SN" 'do NOT write `pr.draft`' "setup skill: no pr.draft is written without a workflow to check"

# ── Draft-time-success guidance (README + setup skill) ────────────────────────
RN="$(tr '\n' ' ' < "$README" | tr -s ' ')"
for pair in "README:$RN" "setup:$SN"; do
  who="${pair%%:*}"; txt="${pair#*:}"
  assert_contains "$txt" "draft-time run must never report success for a required check" "$who: states a draft-time run must not report success for a required check"
  assert_contains "$txt" "branch protection counts a skipped required check as success" "$who: names the skipped-job-counted-as-success case"
  assert_contains "$txt" "always()" "$who: names the always() aggregate job case"
  assert_contains "$txt" "unverified" "$who: says the GitLab/Azure pairing is unverified"
  assert_contains "$txt" "GitLab and Azure" "$who: addresses GitLab and Azure"
done

finish
