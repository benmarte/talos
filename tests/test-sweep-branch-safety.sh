#!/usr/bin/env bash
# test-sweep-branch-safety.sh -- #677: `pipeline-worktree.sh sweep` deletes
# only merged, Talos-created fix|feat/issue-<N>-* local branches.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"

git config user.email "test@talos"
git config user.name "talos test"
git checkout -q -B main
git commit -q --allow-empty -m "root"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json

# _branch <name> -- a local branch with one commit found on no other ref.
_branch() {
  git checkout -q -b "$1" main
  git commit -q --allow-empty -m "unique work on $1"
  git checkout -q main
}
_state() { if git show-ref --verify --quiet "refs/heads/$1"; then echo survives; else echo deleted; fi; }

OPEN='[{"number":99,"title":"unrelated","head":{"ref":"scratch/other"},"base":{"ref":"main"},"labels":[]}]'

_branch chore/x
_branch feat/issue-8-y
out="$(STUB_GH_PRS_RAW="$OPEN" bash "$WT" sweep 2>&1)"
assert_eq "survives" "$(_state chore/x)" "AC1 an unpushed non-pipeline branch survives sweep"
assert_eq "survives" "$(_state feat/issue-8-y)" "AC2 an unpushed pipeline branch with no merged PR survives sweep"
assert_contains "$out" "branches_deleted=0" "AC5 nothing deleted ends branches_deleted=0"
assert_not_contains "$out" "branches=" "AC5 nothing deleted prints no branches= field"

# AC3: squash-merged PR, tip on no remote ref, find-pr returns it as merged.
_branch feat/issue-7-x
CLOSED='[{"number":70,"state":"closed","merged_at":"2026-10-01T00:00:00Z","title":"feat: x","head":{"ref":"feat/issue-7-x"},"body":"Closes #7"}]'
out="$(STUB_GH_CLOSED_PRS_RAW="$CLOSED" STUB_GH_PRS_RAW="$OPEN" bash "$WT" sweep 2>&1)"
assert_eq "deleted" "$(_state feat/issue-7-x)" "AC3 a squash-merged pipeline branch is deleted by sweep"
assert_contains "$out" "branches_deleted=1 branches=feat/issue-7-x" "AC5 summary counts and names the deleted branch"
assert_contains "$out" "talos:worktree-sweep removed=0 kept=0 freed=" "AC5 summary keeps the removed/kept/freed fields first"

# AC4: tip reachable from origin/main -- no merged-PR lookup needed (it fails here).
git checkout -q -b fix/issue-5-z main
git commit -q --allow-empty -m "merged work"
git update-ref refs/remotes/origin/main HEAD
git checkout -q main
_branch feat/issue-6-w
out="$(STUB_GH_API_FAIL=closed-prs STUB_GH_PRS_RAW="$OPEN" bash "$WT" sweep 2>&1)"
assert_eq "deleted" "$(_state fix/issue-5-z)" "AC4 a pipeline branch reachable from origin/<base> is deleted without the PR lookup"
assert_contains "$out" "branches=fix/issue-5-z" "AC5 summary names the branch deleted by reachability"

# AC6: merged-PR lookup fails, tip not on a remote ref -> kept.
assert_eq "survives" "$(_state feat/issue-6-w)" "AC6 a pipeline branch survives when the merged-PR lookup fails"
