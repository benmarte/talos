#!/usr/bin/env bash
# test-worktree.sh — pipeline-worktree.sh lifecycle against real git worktrees.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"

# make_sandbox git-inits and cds into $SANDBOX. Give it an identity + a commit
# so we can branch worktrees off HEAD.
git config user.email "test@talos"
git config user.name "talos test"
git commit -q --allow-empty -m "root"

# Create developer-style worktrees for three issues.
git worktree add -q -b fix/issue-42-add-widget  "$SANDBOX/wt/42" >/dev/null 2>&1
git worktree add -q -b feat/issue-99-new-flow   "$SANDBOX/wt/99" >/dev/null 2>&1
git worktree add -q -b fix/issue-7-tweak        "$SANDBOX/wt/7"  >/dev/null 2>&1

# ── list ──────────────────────────────────────────────────────────────────────
listing="$(bash "$WT" list)"
assert_contains "$listing" "42" "list reports issue 42 worktree"
assert_contains "$listing" "99" "list reports issue 99 worktree"
assert_contains "$listing" "fix/issue-42-add-widget" "list includes the branch name"

# ── remove <n> ────────────────────────────────────────────────────────────────
out="$(bash "$WT" remove 42)"; rc=$?
assert_eq "0" "$rc" "remove exits 0"
assert_contains "$out" "removed worktree for issue #42" "remove reports what it removed"
assert_file_absent "$SANDBOX/wt/42" "remove deletes the worktree directory"
assert_not_contains "$(git worktree list)" "wt/42" "remove drops the worktree from git"
assert_eq "" "$(git branch --list fix/issue-42-add-widget)" "remove deletes the merged local branch"
# untouched siblings survive
assert_contains "$(git worktree list)" "wt/99" "remove leaves other issues' worktrees intact"

# ── remove is idempotent ──────────────────────────────────────────────────────
out="$(bash "$WT" remove 42)"; rc=$?
assert_eq "0" "$rc" "remove on an already-clean issue still exits 0"
assert_contains "$out" "already clean" "remove is a no-op when nothing matches"

# ── sweep keeps the queue, removes the rest ──────────────────────────────────
# Queue keeps 99; issue 7's worktree should be swept.
bash "$WT" sweep 99 >/dev/null
assert_file_absent "$SANDBOX/wt/7" "sweep removes worktrees not in the keep list"
assert_contains "$(git worktree list)" "wt/99" "sweep keeps worktrees in the keep list"
# sweep leaves the branch (may be unmerged)
# `git branch --list` prefixes a worktree-checked-out branch with "+"; strip it.
assert_eq "feat/issue-99-new-flow" "$(git branch --list feat/issue-99-new-flow | tr -d ' *+')" "sweep does not delete kept branches"

# ── sweep with no keep list reclaims everything ──────────────────────────────
bash "$WT" sweep >/dev/null
assert_file_absent "$SANDBOX/wt/99" "sweep with empty keep list removes all issue worktrees"

finish
