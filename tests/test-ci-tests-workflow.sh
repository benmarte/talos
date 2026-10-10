#!/usr/bin/env bash
# Regression tests for the recommended CI workflow template (#260):
#   1. templates/ci/github-tests.yml exists, is valid YAML, and has the
#      documented structure (paths-ignore, concurrency, PR-vs-push matrix
#      split, draft-PR skip, stable "test" job id).
#   2. This repo's own .github/workflows/tests.yml (dogfooding) matches --
#      same structure, same "test" job id so "test (ubuntu-latest)" stays a
#      stable required-check name across PR and push runs.
#   3. (removed, #556: it grepped the setup skill's prose)
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
# 3. Sharding (#556): the suite runs as parallel shards and the one required
#    status, job "test" (check name "test (ubuntu-latest)"), aggregates them.
# ─────────────────────────────────────────────────────────────────────────────
if python3 -c "import yaml" 2>/dev/null; then
  out="$(python3 -c "
import yaml
with open('$REPO_WORKFLOW') as f:
    jobs = yaml.safe_load(f)['jobs']
test, shard, count = jobs.get('test', {}), jobs.get('shard', {}), jobs.get('count', {})
needs = test.get('needs') or []
problems = []
if sorted(needs) != ['count', 'shard']:
    problems.append('test must need exactly count and shard, got %r' % (needs,))
if 'always()' not in str(test.get('if', '')):
    problems.append('test must run with always() so a failed shard fails it instead of skipping it')
if str(test.get('name', '')) != 'test (\${{ matrix.os }})':
    problems.append('test must be named test (<os>)')
if shard.get('strategy', {}).get('fail-fast') is not False:
    problems.append('shards must not fail-fast')
shards = shard.get('strategy', {}).get('matrix', {}).get('shard', [])
if sorted(s.split('/')[1] for s in shards) != ['4'] * 4 or sorted(s.split('/')[0] for s in shards) != ['1', '2', '3', '4']:
    problems.append('shards must be exactly 1/4..4/4, got %r' % (shards,))
steps = ' '.join(str(s.get('run', '')) for s in shard.get('steps', []))
if '--shard' not in steps:
    problems.append('shard job must run run-tests.sh --shard')
if '--count-only' not in ' '.join(str(s.get('run', '')) for s in count.get('steps', [])):
    problems.append('count job must run run-tests.sh --count-only')
print('OK' if not problems else '; '.join(problems))
" 2>&1)"
  assert_eq "OK" "$out" ".github/workflows/tests.yml: shards + count feed the single required job"
fi

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
