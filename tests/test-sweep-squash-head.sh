#!/usr/bin/env bash
# test-sweep-squash-head.sh -- #680: the squash-merge path of `sweep` deletes a
# local pipeline branch only when its tip equals the merged PR's head commit.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos"
git config user.name "talos test"
git checkout -q -B main
git commit -q --allow-empty -m "root"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
github_leg gh
export TALOS_RETRY_SLEEP_SCALE=0
# REST queue, in call order: sweep's open-PR read, then one `find-pr <N> merged`.
_queue() { : > "$CURL_QUEUE"; for _q in "$@"; do printf '%s\n' "$_q" >> "$CURL_QUEUE"; done; }
_branch() {
  git checkout -q -b "$1" main
  git commit -q --allow-empty -m "unique work on $1"
  git checkout -q main
}
_state() { if git show-ref --verify --quiet "refs/heads/$1"; then echo survives; else echo deleted; fi; }
# _closed <issue> <branch> <head-sha> -- a merged PR whose head.sha is <head-sha>.
_closed() {
  printf '[{"number":70,"state":"closed","merged_at":"2026-10-01T00:00:00Z","title":"x","head":{"ref":"%s","sha":"%s"},"body":"Closes #%s"}]' "$2" "$3" "$1"
}

OPEN='[{"number":99,"title":"unrelated","head":{"ref":"scratch/other"},"base":{"ref":"main"},"labels":[]}]'

# AC1: find-pr merged carries headRefOid beside the existing keys.
_queue "$(_closed 1 feat/issue-1-a abc123)"
out="$(bash "$VCS" find-pr 1 merged 2>&1)"
assert_contains "$out" '"headRefOid": "abc123"' "AC1 find-pr merged prints headRefOid"
assert_contains "$out" '"headRefName": "feat/issue-1-a"' "AC1 find-pr merged still prints headRefName"

# AC2: tip equals the merged head -> deleted.
_branch feat/issue-2-b
tip="$(git rev-parse refs/heads/feat/issue-2-b)"
_queue "$OPEN" "$(_closed 2 feat/issue-2-b "$tip")"
out="$(bash "$WT" sweep 2>&1)"
assert_eq "deleted" "$(_state feat/issue-2-b)" "AC2 a branch at the merged head is deleted"

# AC3: one extra local commit beyond the merged head -> kept, not counted.
_branch feat/issue-3-c
merged_head="$(git rev-parse refs/heads/feat/issue-3-c)"
git checkout -q feat/issue-3-c
git commit -q --allow-empty -m "later local work"
git checkout -q main
_queue "$OPEN" "$(_closed 3 feat/issue-3-c "$merged_head")"
out="$(bash "$WT" sweep 2>&1)"
assert_eq "survives" "$(_state feat/issue-3-c)" "AC3 a branch with commits beyond the merged head survives"
assert_contains "$out" "branches_deleted=0" "AC3 the kept branch is not counted"

# AC4: no usable headRefOid (missing, null, empty) -> kept.
_branch feat/issue-4-d
PR_HEAD='"title":"x","head":{"ref":"feat/issue-4-d"'
PR_TAIL='},"body":"Closes #4"}]'
PR_HEAD='[{"number":73,"state":"closed","merged_at":"2026-10-01T00:00:00Z",'"$PR_HEAD"
for variant in missing null empty; do
  case "$variant" in
    missing) sha='' ;;
    null)    sha=',"sha":null' ;;
    empty)   sha=',"sha":""' ;;
  esac
  _queue "$OPEN" "$PR_HEAD$sha$PR_TAIL"
  out="$(bash "$WT" sweep 2>&1)"
  assert_eq "survives" "$(_state feat/issue-4-d)" "AC4 a find-pr answer with $variant headRefOid keeps the branch"
done
