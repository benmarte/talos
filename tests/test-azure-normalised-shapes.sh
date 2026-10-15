#!/usr/bin/env bash
# test-azure-normalised-shapes.sh -- the azure adapter's list-issues,
# view-issue and list-prs add the GitHub-shaped keys pipeline-next.py reads
# (number, title, state, body, labels[{name}], headRefName, ...) and keep the
# raw azure keys; has-spec runs on azure through the normalised view-issue.
# Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'TALOS_cfgAz683xQ'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
TALOS_cfgAz683xQ

# _field <json> <python expr over d>: print one value from a JSON document.
_field() { printf '%s' "$1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null; }

# ── AC1 list-issues ──────────────────────────────────────────────────────────
export STUB_AZURE_WORKITEM_LIST='[{"id":327,"fields":{"System.Title":"Add login","System.State":"New","System.Tags":"pipeline:ready; bug ;; p1"}},{"id":328,"fields":{"System.Title":"No tags","System.State":"Active"}}]'
out="$(bash "$VCS" list-issues 2>/dev/null)"
assert_eq "327" "$(_field "$out" 'd[0]["number"]')" "AC1 list-issues adds number from id"
assert_eq "Add login" "$(_field "$out" 'd[0]["title"]')" "AC1 list-issues adds title"
assert_eq "New" "$(_field "$out" 'd[0]["state"]')" "AC1 list-issues adds state"
assert_eq "pipeline:ready,bug,p1" "$(_field "$out" '",".join(l["name"] for l in d[0]["labels"])')" "AC1 list-issues splits System.Tags into labels, trimmed, empties dropped"
assert_eq "[]" "$(_field "$out" 'd[1]["labels"]')" "AC1 list-issues gives an untagged row empty labels"
assert_eq "327 Add login" "$(_field "$out" 'str(d[0]["id"]) + " " + d[0]["fields"]["System.Title"]')" "AC1 list-issues keeps the raw id and fields"
unset STUB_AZURE_WORKITEM_LIST

# ── AC2 view-issue ───────────────────────────────────────────────────────────
export STUB_AZURE_WORKITEM_JSON='{"id":42,"fields":{"System.Title":"Epic","System.State":"Active","System.Tags":"spec:ready; p2","System.Description":"Body text"}}'
out="$(bash "$VCS" view-issue 42 2>/dev/null)"
assert_eq "42" "$(_field "$out" 'd["number"]')" "AC2 view-issue adds number"
assert_eq "Epic" "$(_field "$out" 'd["title"]')" "AC2 view-issue adds title"
assert_eq "Active" "$(_field "$out" 'd["state"]')" "AC2 view-issue adds state"
assert_eq "Body text" "$(_field "$out" 'd["body"]')" "AC2 view-issue adds body from System.Description"
assert_eq "spec:ready,p2" "$(_field "$out" '",".join(l["name"] for l in d["labels"])')" "AC2 view-issue adds labels from System.Tags"
assert_eq "42 Epic" "$(_field "$out" 'str(d["id"]) + " " + d["fields"]["System.Title"]')" "AC2 view-issue keeps the raw keys"
unset STUB_AZURE_WORKITEM_JSON

# ── AC3 list-prs ─────────────────────────────────────────────────────────────
export STUB_AZURE_PR_LIST='[{"pullRequestId":9,"title":"fix: guard","status":"active","isDraft":true,"sourceRefName":"refs/heads/fix/issue-327-guard","targetRefName":"refs/heads/main"}]'
out="$(bash "$VCS" list-prs 2>/dev/null)"
assert_eq "9" "$(_field "$out" 'd[0]["number"]')" "AC3 list-prs adds number from pullRequestId"
assert_eq "fix: guard" "$(_field "$out" 'd[0]["title"]')" "AC3 list-prs adds title"
assert_eq "fix/issue-327-guard" "$(_field "$out" 'd[0]["headRefName"]')" "AC3 list-prs strips refs/heads/ from the head"
assert_eq "main" "$(_field "$out" 'd[0]["baseRefName"]')" "AC3 list-prs strips refs/heads/ from the base"
assert_eq "True" "$(_field "$out" 'd[0]["isDraft"]')" "AC3 list-prs carries isDraft"
assert_eq "False" "$(_field "$out" 'd[0]["isCrossRepository"]')" "AC3 list-prs adds isCrossRepository"
assert_eq "9 refs/heads/fix/issue-327-guard" "$(_field "$out" 'str(d[0]["pullRequestId"]) + " " + d[0]["sourceRefName"]')" "AC3 list-prs keeps the raw keys"
unset STUB_AZURE_PR_LIST

# ── AC4 pipeline-next.py queues the work item ────────────────────────────────
export STUB_AZURE_WORKITEM_LIST='[{"id":327,"fields":{"System.Title":"Add login","System.State":"New","System.Tags":"pipeline:ready"}}]'
state="$(python3 -I "$TALOS_ROOT/scripts/pipeline-next.py" collect --vcs "$VCS" --roles "" --me "" \
  --merge-auto "" --required-checks "" --pr-draft "" --ready-gate "" \
  --talos-labels "pipeline:ready,pipeline:dev,pipeline:confirmed" --base-branch main </dev/null 2>&1)"
assert_eq "327" "$(_field "$state" 'd["queued"][0] if d.get("queued") else "empty"')" "AC4 pipeline-next.py collect queues the azure work item tagged pipeline:ready"
unset STUB_AZURE_WORKITEM_LIST

# ── AC5 has-spec ─────────────────────────────────────────────────────────────
export STUB_AZURE_WORKITEM_DESCRIPTION="$(printf '## Acceptance criteria\n- [ ] AC1 it works\n')"
bash "$VCS" has-spec 42 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC5 has-spec exits 0 on an azure work item whose description is a spec"
export STUB_AZURE_WORKITEM_DESCRIPTION="just prose, no criteria"
bash "$VCS" has-spec 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC5 has-spec exits 1 on an azure work item without a spec"
unset STUB_AZURE_WORKITEM_DESCRIPTION

finish
