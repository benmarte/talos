#!/usr/bin/env bash
# test-worktree-to-base-842.sh -- pipeline-worktree.sh to-base when another
# worktree already holds the base branch (a lane home, #842): fetch, detach at
# origin/<base>, delete the merged issue branch.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
TB="$SANDBOX/tb842"
tb_id() { git -C "$1" config user.email "test@talos"; git -C "$1" config user.name "talos test"; }
tb_fixture() {  # remote + seed + clone (holds main) + $TB/lane, a worktree on $1 (a new branch off main); cwd = the lane
  cd "$SANDBOX" || exit 1
  rm -rf "${TB:?}"; mkdir -p "$TB"
  git init -q --bare "$TB/remote.git"
  git --git-dir="$TB/remote.git" symbolic-ref HEAD refs/heads/main
  git init -q "$TB/seed"
  git -C "$TB/seed" symbolic-ref HEAD refs/heads/main
  tb_id "$TB/seed"
  printf 'one\n' > "$TB/seed/file.txt"
  git -C "$TB/seed" add file.txt
  git -C "$TB/seed" commit -q -m "root"
  git -C "$TB/seed" push -q "$TB/remote.git" main
  git clone -q "$TB/remote.git" "$TB/clone"
  tb_id "$TB/clone"
  git -C "$TB/clone" worktree add -q -b "$1" "$TB/lane" main
  cd "$TB/lane" || exit 1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -q -m "work"
}
tb_remote_advance() {  # one more commit on the remote's main (the merged PR), not fetched yet
  printf '%s\n' "$1" > "$TB/seed/merged.$1"
  git -C "$TB/seed" add "merged.$1"
  git -C "$TB/seed" commit -q -m "merge $1"
  git -C "$TB/seed" push -q "$TB/remote.git" main
}
tb() { OUT="$(bash "$WT" to-base "$@" 2>"$SANDBOX/tb842.err")"; RC=$?; }
tb_branch() { git symbolic-ref -q --short HEAD 2>/dev/null || echo "<detached>"; }

# AC1-AC3: the base is held by the clone; the lane is returned by a detach.
tb_fixture fix/issue-842-x
tb_remote_advance pr842
tb 842
assert_eq "0" "$RC" "AC1 to-base in a held-base worktree exits 0"
assert_eq "talos:checkout state=returned" "$OUT" "AC1 to-base in a held-base worktree prints state=returned"
assert_eq "<detached> $(git --git-dir="$TB/remote.git" rev-parse main)" "$(tb_branch) $(git rev-parse HEAD)" \
  "AC2 HEAD is detached at the commit origin/main points to after the fetch"
assert_eq "" "$(git branch --list fix/issue-842-x)" "AC3 the merged issue branch no longer exists"

# AC4: a tracked change, unstaged then staged, is left alone.
tb_fixture fix/issue-842-dirty
_tb_head="$(git rev-parse HEAD)"
printf 'edited\n' >> file.txt
_tb_status="$(git status --porcelain)"
tb 842
assert_eq "0 talos:checkout state=failed reason=dirty" "$RC $OUT" "AC4 an unstaged change in a held-base worktree is state=failed reason=dirty"
assert_eq "fix/issue-842-dirty $_tb_head $_tb_status" "$(tb_branch) $(git rev-parse HEAD) $(git status --porcelain)" "AC4 the dirty worktree keeps its branch, HEAD and change"
git add file.txt
_tb_status="$(git status --porcelain)"
tb 842
assert_eq "0 talos:checkout state=failed reason=dirty" "$RC $OUT" "AC4 a staged change in a held-base worktree is state=failed reason=dirty"
assert_eq "fix/issue-842-dirty $_tb_head $_tb_status" "$(tb_branch) $(git rev-parse HEAD) $(git status --porcelain)" "AC4 the staged change keeps its branch, HEAD and index"

# AC5: another branch is kept, untouched.
tb_fixture feature/other
_tb_head="$(git rev-parse HEAD)"
tb 842
assert_eq "0 talos:checkout state=kept" "$RC $OUT" "AC5 a held-base worktree on another branch is state=kept"
assert_eq "feature/other $_tb_head" "$(tb_branch) $(git rev-parse HEAD)" "AC5 the kept worktree is not touched"

# AC6: the base is not held elsewhere: the old path (switch, fast-forward).
tb_fixture fix/issue-842-free
git -C "$TB/clone" checkout -q --detach
tb_remote_advance free
tb 842
assert_eq "0 talos:checkout state=returned" "$RC $OUT" "AC6 a base not held elsewhere is still state=returned"
assert_eq "main $(git --git-dir="$TB/remote.git" rev-parse main)" "$(tb_branch) $(git rev-parse HEAD)" "AC6 a base not held elsewhere is switched to and fast-forwarded"
# AC6: a refused switch (an untracked file in the way) is still switch-failed.
tb_fixture fix/issue-842-refused
git -C "$TB/clone" checkout -q --detach
tb_remote_advance clash
git fetch -q origin
git branch -q -f main origin/main
printf 'mine\n' > merged.clash
tb 842
assert_eq "0 talos:checkout state=failed reason=switch-failed" "$RC $OUT" "AC6 a refused switch is still state=failed reason=switch-failed"
assert_eq "fix/issue-842-refused" "$(tb_branch)" "AC6 a refused switch keeps the branch"

# AC7: a fetch that fails keeps the branch and HEAD.
tb_fixture fix/issue-842-nofetch
_tb_head="$(git rev-parse HEAD)"
git remote set-url origin "$TB/missing.git"
tb 842
assert_eq "0 talos:checkout state=failed reason=pull-failed" "$RC $OUT" "AC7 a failed fetch is state=failed reason=pull-failed"
assert_eq "fix/issue-842-nofetch $_tb_head" "$(tb_branch) $(git rev-parse HEAD)" "AC7 a failed fetch keeps the issue branch and HEAD"

cd "$SANDBOX" || exit 1
finish
