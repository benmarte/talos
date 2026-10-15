#!/usr/bin/env bash
# test-azure-repo-name.sh -- on azure, vcs.repo "project/name" (the shape the git
# remote gives) is reduced to the ADO repository name (its last path segment)
# in every git REST base URL and every --repository argument (#705); ADO 404s on
# "agmd/terrasow". label-pr and comment-pr also fail loudly instead of dropping
# a write. Uses the tests/stubs/az stub; no credentials needed. Tests are named by
# the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"

# write_cfg <vcs.repo> [with-org]: azure config; without "with-org" there is no
# org or project, so the git base cannot be resolved.
write_cfg() {
  if [ "${2:-}" = "with-org" ]; then
    printf '{"vcs": {"provider": "azure", "repo": "%s", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}\n' "$1" > talos.pipeline.json
  else
    printf '{"vcs": {"provider": "azure", "repo": "%s"}}\n' "$1" > talos.pipeline.json
  fi
}

PR='{"pullRequestId":9,"title":"t","status":"active","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
LABELS='{"count":1,"value":[{"id":"1","name":"pipeline:review","active":true}]}'
STATE="$SANDBOX/azstate"
mkdir -p "$STATE"
printf 'body\n' > "$SANDBOX/body.md"

# ── AC1: project/name reads the labels from .../repositories/terrasow ────────
write_cfg "agmd/terrasow" with-org
: > "$GH_LOG"
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS="$LABELS" bash "$VCS" view-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 view-pr exits 0"
assert_contains "$(cat "$GH_LOG")" "[https://dev.azure.com/acme/proj/_apis/git/repositories/terrasow/pullRequests/9/labels?" \
  "AC1 view-pr reads the labels from repositories/terrasow"
assert_not_contains "$(cat "$GH_LOG")" "repositories/agmd/" "AC1 no az rest URL holds repositories/agmd/"

# ── AC2: a bare name gives the same URL ──────────────────────────────────────
write_cfg "terrasow" with-org
: > "$GH_LOG"
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS="$LABELS" bash "$VCS" view-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2 view-pr exits 0 for a bare repo name"
assert_contains "$(cat "$GH_LOG")" "[https://dev.azure.com/acme/proj/_apis/git/repositories/terrasow/pullRequests/9/labels?" \
  "AC2 a bare repo name reads the same labels URL"

# ── AC3: create-pr, find-pr and check-closing-keyword pass --repository terrasow
write_cfg "agmd/terrasow" with-org
: > "$GH_LOG"
bash "$VCS" create-pr fix/issue-42-x "t" "$SANDBOX/body.md" >/dev/null 2>&1
assert_contains "$(grep 'AZ ARGS: \[repos\] \[pr\] \[create\]' "$GH_LOG")" "[--repository] [terrasow]" \
  "AC3 create-pr passes --repository terrasow"
: > "$GH_LOG"
bash "$VCS" find-pr 42 >/dev/null 2>&1
assert_contains "$(grep 'AZ ARGS: \[repos\] \[pr\] \[list\]' "$GH_LOG")" "[--repository] [terrasow]" \
  "AC3 find-pr passes --repository terrasow"
_rel() { printf '[%s]' "$(for _p in "$@"; do printf '{"rel":"ArtifactLink","url":"vstfs:///Git/PullRequestId/p1%%2Fr1%%2F%s"},' "$_p"; done | sed 's/,$//')"; }
: > "$GH_LOG"
STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9)" \
  STUB_AZURE_PR_LIST='[{"pullRequestId":9,"status":"active","sourceRefName":"refs/heads/fix/issue-42-a"}]' \
  bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1
assert_contains "$(grep 'AZ ARGS: \[repos\] \[pr\] \[list\]' "$GH_LOG")" "[--repository] [terrasow]" \
  "AC3 check-closing-keyword passes --repository terrasow"
assert_not_contains "$(cat "$GH_LOG")" "agmd/terrasow" "AC3 no az argv holds agmd/terrasow"

# ── AC4: label-pr and comment-pr POST to .../repositories/terrasow ───────────
: > "$GH_LOG"
STUB_AZURE_STATE_DIR="$STATE" bash "$VCS" label-pr 9 --add pipeline:review >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC4 label-pr exits 0"
assert_contains "$(cat "$GH_LOG")" "[https://dev.azure.com/acme/proj/_apis/git/repositories/terrasow/pullRequests/9/labels?" \
  "AC4 label-pr POSTs to repositories/terrasow"
: > "$GH_LOG"
STUB_AZURE_STATE_DIR="$STATE" bash "$VCS" comment-pr 9 "hello" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC4 comment-pr exits 0"
assert_contains "$(cat "$GH_LOG")" "[https://dev.azure.com/acme/proj/_apis/git/repositories/terrasow/pullRequests/9/threads?" \
  "AC4 comment-pr POSTs to repositories/terrasow"

# ── AC5: label-pr fails when the add fails, and when the base is unresolved ──
out="$(STUB_AZURE_STATE_DIR="$STATE" STUB_AZURE_POST_FAIL=1 bash "$VCS" label-pr 9 --add pipeline:review 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC5 label-pr exits 1 when the label-add REST call fails"
assert_contains "$out" "label-pr add 'pipeline:review' failed on PR #9" "AC5 label-pr still names the failed label"
write_cfg "agmd/terrasow"
out="$(bash "$VCS" label-pr 9 --add pipeline:review 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC5 label-pr exits 1 when the git base cannot be resolved"
assert_contains "$out" "azure label-pr needs org/project/repo" "AC5 label-pr prints its diagnostic when the base is unresolved"

# ── AC6: comment-pr fails when the base is unresolved ────────────────────────
out="$(bash "$VCS" comment-pr 9 "hello" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 comment-pr exits 1 when the git base cannot be resolved"
assert_contains "$out" "azure comment-pr needs org/project/repo" "AC6 comment-pr prints its diagnostic when the base is unresolved"

# ── AC7: comment-pr already fails when its REST POST fails (guard) ───────────
write_cfg "agmd/terrasow" with-org
STUB_AZURE_STATE_DIR="$STATE" STUB_AZURE_POST_FAIL=1 bash "$VCS" comment-pr 9 "hello" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC7 comment-pr exits non-zero when the REST POST fails"

finish
