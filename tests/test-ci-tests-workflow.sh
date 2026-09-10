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
#   4. talos.pipeline.json's merge.required_checks is a subset of the job
#      names .github/workflows/tests.yml actually runs on pull_request --
#      naming a push-only check (e.g. "test (macos-latest)") hangs QA's
#      CI-wait loop on every PR forever (found live on this PR: #261).
#   5. Both files declare permissions: { contents: read } (least privilege --
#      security review finding on #261) and cancel-in-progress is NOT
#      unconditionally true -- it must be scoped to pull_request only, or a
#      second push-to-main merge cancels the first merge's still-running
#      macOS job and silently loses that coverage (reviewer finding on #261).
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
cancel = concurrency.get('cancel-in-progress')
permissions = doc.get('permissions', {}) or {}
ok = (
    'paths-ignore' in push
    and '**.md' in push['paths-ignore']
    # cancel-in-progress must NOT be the unconditional boolean True -- an
    # in-flight push-to-main run (e.g. the macOS job) must survive a second
    # merge landing on top of it. It must instead be an expression scoped
    # to pull_request.
    and cancel is not True
    and 'pull_request' in str(cancel)
    and 'ready_for_review' in pr.get('types', [])
    and 'draft' in str(test_job.get('if', ''))
    and 'pull_request' in str(test_job.get('strategy', ''))
    and 'macos-latest' in str(test_job.get('strategy', ''))
    and 'ubuntu-latest' in str(test_job.get('strategy', ''))
    and permissions == {'contents': 'read'}
)
print('OK' if ok else 'STRUCTURE_MISMATCH')
" 2>&1)"
    assert_eq "OK" "$out" "$label: PyYAML structural check"
  else
    echo "  skip: PyYAML not installed -- falling back to a structural grep"
    local content
    content="$(cat "$file")"
    assert_contains "$content" "paths-ignore:" "$label: push has paths-ignore"
    assert_not_contains "$content" "cancel-in-progress: true" \
      "$label: cancel-in-progress is not the unconditional boolean true"
    assert_contains "$content" "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
      "$label: cancel-in-progress is scoped to pull_request"
    assert_contains "$content" "ready_for_review" "$label: pull_request types include ready_for_review"
    assert_contains "$content" "draft != true" "$label: draft PRs are skipped"
    assert_contains "$content" "ubuntu-latest" "$label: matrix mentions ubuntu-latest"
    assert_contains "$content" "macos-latest" "$label: matrix mentions macos-latest"
    assert_contains "$content" "permissions:" "$label: has a permissions block"
    assert_contains "$content" "contents: read" "$label: permissions is contents: read"
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
assert_contains "$template_content" "wait forever" \
  "template: header states explicitly the merge gate will wait forever if not removed"
assert_contains "$template_content" "jobs:" "template: has a jobs section"
assert_contains "$template_content" "  test:" "template: job id is \"test\" (required-check name stability)"
assert_contains "$template_content" "tests/run-tests.sh" "template: runs tests/run-tests.sh"
assert_contains "$template_content" "permissions:" "template: declares a permissions block"
assert_contains "$template_content" "contents: read" "template: permissions is contents: read (least privilege)"
assert_not_contains "$template_content" "cancel-in-progress: true" \
  "template: cancel-in-progress is not unconditionally true"

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
assert_contains "$repo_content" "permissions:" ".github/workflows/tests.yml: declares a permissions block"
assert_contains "$repo_content" "contents: read" \
  ".github/workflows/tests.yml: permissions is contents: read (least privilege)"
assert_not_contains "$repo_content" "cancel-in-progress: true" \
  ".github/workflows/tests.yml: cancel-in-progress is not unconditionally true"

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
assert_contains "$setup_content" "merge.required_checks" \
  "pipeline-setup SKILL.md checks merge.required_checks after writing the template"
assert_contains "$setup_content" "test (macos-latest)" \
  "pipeline-setup SKILL.md names the unsafe required-check example"
assert_contains "$setup_content" "wait forever" \
  "pipeline-setup SKILL.md warns the merge gate will wait forever if not removed"

# ─────────────────────────────────────────────────────────────────────────────
# 4. talos.pipeline.json's merge.required_checks must be a subset of the job
#    names this repo's own tests.yml actually runs on pull_request -- a name
#    the workflow only produces on push (e.g. "test (macos-latest)") hangs
#    QA's CI-wait loop on every PR forever. This is the dogfooding gap that
#    made #261's own merge gate hang.
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_JSON="$TALOS_ROOT/talos.pipeline.json"
if [ -f "$CONFIG_JSON" ] && python3 -c "import yaml" 2>/dev/null; then
  out="$(python3 -c "
import json, re, yaml

with open('$CONFIG_JSON') as f:
    cfg = json.load(f)
required = set(cfg.get('merge', {}).get('required_checks', []) or [])

with open('$REPO_WORKFLOW') as f:
    wf = yaml.safe_load(f)
matrix_os = str(wf['jobs']['test']['strategy']['matrix']['os'])

# The matrix os expression is:
#   \${{ github.event_name == 'pull_request' && fromJSON('[...]') || fromJSON('[...]') }}
# The FIRST fromJSON(...) is the value used when the expression's condition
# (github.event_name == 'pull_request') is true -- i.e. what actually runs
# on a PR push. Extract it without evaluating GHA expression syntax.
m = re.search(r\"fromJSON\('(\[[^]]*\])'\)\", matrix_os)
pr_os = json.loads(m.group(1)) if m else []
pr_checks = {'test (%s)' % os for os in pr_os}

missing = required - pr_checks
print('OK' if not missing else 'HANGS_ON_PR: ' + ', '.join(sorted(missing)))
" 2>&1)"
  assert_eq "OK" "$out" \
    "talos.pipeline.json merge.required_checks only names checks that actually run on pull_request"
else
  echo "  skip: talos.pipeline.json or PyYAML not available"
fi

finish
