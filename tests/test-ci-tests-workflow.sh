#!/usr/bin/env bash
# Regression tests for the recommended CI workflow template (#260):
#   1. templates/ci/github-tests.yml exists, is valid YAML, and has the
#      documented structure (paths-ignore, concurrency, PR-vs-push matrix
#      split, draft-PR skip, stable "test" job id).
#   2. This repo's own .github/workflows/tests.yml (dogfooding) matches --
#      same structure, same "test" job id so "test (ubuntu-latest)" stays a
#      stable required-check name across PR and push runs.
#   3. skills/pipeline-setup/SKILL.md's CI step: offers the template only
#      when no existing workflow runs the test suite, and never edits an
#      existing workflow (prompt text assertions).
set -u
. "$(dirname "$0")/helpers.sh"

TEMPLATE="$TALOS_ROOT/templates/ci/github-tests.yml"
REPO_WORKFLOW="$TALOS_ROOT/.github/workflows/tests.yml"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Template: exists, valid YAML, documented structure.
# ─────────────────────────────────────────────────────────────────────────────
assert_file_exists "$TEMPLATE" "templates/ci/github-tests.yml exists"

check_workflow_structure() {  # $1=file $2=label prefix
  local file="$1" label="$2"
  if python3 -c "import yaml" 2>/dev/null; then
    local out
    out="$(python3 -c "
import yaml
with open('$file') as f:
    doc = yaml.safe_load(f)
# PyYAML 1.1 parses the bare 'on:' key as the boolean True -- handle both.
triggers = doc.get('on', doc.get(True, {})) or {}
push = triggers.get('push', {}) or {}
pr = triggers.get('pull_request', {}) or {}
jobs = doc.get('jobs', {}) or {}
test_job = jobs.get('test', {}) or {}
concurrency = doc.get('concurrency', {}) or {}
ok = (
    'paths-ignore' in push
    and '**.md' in push['paths-ignore']
    and concurrency.get('cancel-in-progress') is True
    and 'ready_for_review' in pr.get('types', [])
    and 'draft' in str(test_job.get('if', ''))
    and 'pull_request' in str(test_job.get('strategy', ''))
    and 'macos-latest' in str(test_job.get('strategy', ''))
    and 'ubuntu-latest' in str(test_job.get('strategy', ''))
)
print('OK' if ok else 'STRUCTURE_MISMATCH')
" 2>&1)"
    assert_eq "OK" "$out" "$label: PyYAML structural check"
  else
    echo "  skip: PyYAML not installed -- falling back to a structural grep"
    local content
    content="$(cat "$file")"
    assert_contains "$content" "paths-ignore:" "$label: push has paths-ignore"
    assert_contains "$content" "cancel-in-progress: true" "$label: concurrency cancels in-progress runs"
    assert_contains "$content" "ready_for_review" "$label: pull_request types include ready_for_review"
    assert_contains "$content" "draft != true" "$label: draft PRs are skipped"
    assert_contains "$content" "ubuntu-latest" "$label: matrix mentions ubuntu-latest"
    assert_contains "$content" "macos-latest" "$label: matrix mentions macos-latest"
  fi
}

check_workflow_structure "$TEMPLATE" "template"

template_content="$(cat "$TEMPLATE")"
assert_contains "$template_content" "job id stays" \
  "template: header explains the job id stays \"test\" across PR and push"
assert_contains "$template_content" "merge.required_checks" \
  "template: header documents the merge.required_checks caveat"
assert_contains "$template_content" "test (macos-latest)" \
  "template: header names the unsafe required-check example explicitly"
assert_contains "$template_content" "jobs:" "template: has a jobs section"
assert_contains "$template_content" "  test:" "template: job id is \"test\" (required-check name stability)"
assert_contains "$template_content" "tests/run-tests.sh" "template: runs tests/run-tests.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Dogfooding: this repo's own tests.yml matches the template's structure.
# ─────────────────────────────────────────────────────────────────────────────
assert_file_exists "$REPO_WORKFLOW" ".github/workflows/tests.yml exists"
check_workflow_structure "$REPO_WORKFLOW" ".github/workflows/tests.yml"

repo_content="$(cat "$REPO_WORKFLOW")"
assert_contains "$repo_content" "  test:" ".github/workflows/tests.yml: job id is \"test\""
assert_contains "$repo_content" "tests/run-tests.sh" ".github/workflows/tests.yml: runs tests/run-tests.sh"
assert_contains "$repo_content" "github-tests.yml" \
  ".github/workflows/tests.yml: points back at the template it dogfoods"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Setup skill: offers the template only when absent, never edits an
#    existing workflow.
# ─────────────────────────────────────────────────────────────────────────────
SETUP_SKILL="$TALOS_ROOT/skills/pipeline-setup/SKILL.md"
assert_file_exists "$SETUP_SKILL" "skills/pipeline-setup/SKILL.md exists"

setup_content="$(cat "$SETUP_SKILL")"
assert_contains "$setup_content" "templates/ci/github-tests.yml" \
  "pipeline-setup SKILL.md references the CI template"
assert_contains "$setup_content" "run-tests.sh" \
  "pipeline-setup SKILL.md checks for an existing workflow running the test suite"
assert_contains "$setup_content" "never edit it" \
  "pipeline-setup SKILL.md states it never edits an existing workflow"
assert_contains "$setup_content" "No workflow runs your test suite yet" \
  "pipeline-setup SKILL.md only offers the template when no workflow runs the suite"

finish
