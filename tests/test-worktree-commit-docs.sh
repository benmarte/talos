#!/usr/bin/env bash
# test-worktree-commit-docs.sh -- `pipeline-worktree.sh commit-docs` (#607): the
# docs stage's one git write. The headless docs role has no `git add`, `git commit`
# or `git push` rule; this verb stages the files it is given, commits them and
# pushes, and only when the checkout is on the head branch of the stage's PR and
# never on the base branch.
# Local bare origin, the gh stub for the PR head (STUB_PR_HEAD_REF_NAME); no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
github_leg gh

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
ORIGIN="$SANDBOX/origin.git"
ERR="$SANDBOX/err"
BR="fix/issue-42-docs"

git config user.email "test@talos"
git config user.name "talos test"
git symbolic-ref HEAD refs/heads/main
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git remote set-url origin "$ORIGIN"
printf '.home/\n*.log\norigin.git/\nerr\nlocal.ignored\n' > .gitignore
mkdir docs
printf 'guide\n' > docs/guide.md
printf 'old\n' > docs/old.md
printf 'code\n' > src.txt
git add .gitignore talos.pipeline.json docs src.txt
git commit -q -m "root"
git push -q origin main
git fetch -q origin

origin_ref() { git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null || echo none; }
# docs_commit <subject|""> <args...>: run the verb with the subject on stdin; exit
# status in $RC, stdout in $OUT, stderr in $ERR.
docs_commit() {
  local _subject="$1"
  shift
  OUT="$(printf '%s' "$_subject" | bash "$WT" commit-docs "$@" 2>"$ERR")"
  RC=$?
}
# untouched <label>: no commit was made and nothing is staged.
untouched() {
  assert_eq "$HEAD_BEFORE" "$(git rev-parse HEAD)" "$1: no commit was made"
  assert_eq "" "$(git diff --cached --name-only)" "$1: nothing is left staged"
}
MAIN_SHA="$(git rev-parse HEAD)"

# ── usage ────────────────────────────────────────────────────────────────────
assert_contains "$(bash "$WT" bogus 2>&1)" "commit-docs <pr> -- <file>..." "AC1 the usage line lists commit-docs"
docs_commit "" ; assert_eq "2" "$RC" "AC1 commit-docs with no <pr> exits 2"
docs_commit "" abc -- docs/guide.md; assert_eq "2" "$RC" "AC1 commit-docs with a non-numeric <pr> exits 2"
docs_commit "" 9; assert_eq "2" "$RC" "AC1 commit-docs with no files exits 2"
docs_commit "" 9 --; assert_eq "2" "$RC" "AC1 commit-docs with an empty file list exits 2"

# ── on the base branch: refused, whatever the provider says the PR head is ───
printf 'edited on base\n' >> docs/guide.md
HEAD_BEFORE="$(git rev-parse HEAD)"
for head in main "$BR"; do
  STUB_PR_HEAD_REF_NAME="$head" docs_commit "docs: on base (#42)" 9 -- docs/guide.md
  assert_eq "1" "$RC" "AC1 on the base branch (PR head '$head'): refused"
  assert_contains "$(cat "$ERR")" "base branch" "AC1 on the base branch (PR head '$head'): the refusal names the base branch"
  untouched "AC1 on the base branch (PR head '$head')"
  assert_eq "$MAIN_SHA" "$(origin_ref main)" "AC1 on the base branch (PR head '$head'): origin's base branch did not move"
done
git checkout -q -- docs/guide.md
# A configured base branch with another name is refused the same way.
git checkout -q -b trunk
github_leg gh ',"base_branch": "trunk"'
printf 'edited on trunk\n' >> docs/guide.md
HEAD_BEFORE="$(git rev-parse HEAD)"
STUB_PR_HEAD_REF_NAME=trunk docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 on the configured base branch (base_branch: trunk): refused"
untouched "AC1 on the configured base branch (base_branch: trunk)"
assert_eq "none" "$(origin_ref trunk)" "AC1 on the configured base branch (base_branch: trunk): nothing was pushed"
git checkout -q -- docs/guide.md talos.pipeline.json
git checkout -q main
git branch -q -D trunk

# ── a branch that is not the PR's head, a detached HEAD, an unreadable PR ────
git checkout -q -b other
printf 'edited on other\n' >> docs/guide.md
HEAD_BEFORE="$(git rev-parse HEAD)"
STUB_PR_HEAD_REF_NAME="$BR" docs_commit "docs: wrong branch (#42)" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 a branch that is not the PR's head: refused"
assert_contains "$(cat "$ERR")" "not the head branch of PR #9" "AC1 a branch that is not the PR's head: the refusal says so"
untouched "AC1 a branch that is not the PR's head"
assert_eq "none" "$(origin_ref other)" "AC1 a branch that is not the PR's head: nothing was pushed"
git checkout -q -- docs/guide.md
git checkout -q --detach
STUB_PR_HEAD_REF_NAME="$BR" docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 a detached HEAD: refused"
git checkout -q -b "$BR" main
git branch -q -D other
printf 'edited\n' >> docs/guide.md
HEAD_BEFORE="$(git rev-parse HEAD)"
STUB_PR_HEAD_REF_NAME="" docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 the PR's head branch cannot be read: refused (fail closed)"
untouched "AC1 the PR's head branch cannot be read"
STUB_GH_API_FAIL=pr docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 the provider call fails: refused (fail closed)"
untouched "AC1 the provider call fails"
export STUB_PR_HEAD_REF_NAME="$BR"

# ── a headless role other than docs: refused ─────────────────────────────────
for r in qa reviewer security validator pm adversarial planner; do
  TALOS_ROLE="$r" docs_commit "" 9 -- docs/guide.md
  assert_eq "1" "$RC" "AC2 $r: commit-docs is the docs role's alone (refused)"
  untouched "AC2 $r"
done
assert_eq "none" "$(origin_ref "$BR")" "AC2 no read-only role pushed anything"

# ── only the files it is given, only files ───────────────────────────────────
printf 'x\n' > local.ignored
printf 'KEY=1\n' > .env
ln -s docs/guide.md docs/link.md
for p in local.ignored .env docs/link.md docs . -A -f --force docs/missing.md; do
  docs_commit "" 9 -- docs/guide.md "$p"
  assert_eq "1" "$RC" "AC1 '$p' beside a real file: refused"
  untouched "AC1 '$p' beside a real file"
done
for flag in -f --force --no-verify -A --amend; do
  docs_commit "" 9 "$flag" -- docs/guide.md
  assert_eq "2" "$RC" "AC1 the flag $flag before --: usage error"
  untouched "AC1 the flag $flag before --"
done
assert_eq "none" "$(origin_ref "$BR")" "AC1 no refused call pushed anything"
rm -f local.ignored .env docs/link.md

# Something already staged is not this stage's edit: refused, and left as it was.
printf 'changed\n' >> src.txt
git add src.txt
docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 an index that already has staged changes: refused"
assert_eq "src.txt" "$(git diff --cached --name-only)" "AC1 an index that already has staged changes: left as it was"
git reset -q

# The repo's own commit hook runs (no --no-verify); a refusing hook leaves no commit.
mkdir -p .git/hooks
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
docs_commit "" 9 -- docs/guide.md
assert_eq "1" "$RC" "AC1 a refusing pre-commit hook: no commit (hooks are not skipped)"
untouched "AC1 a refusing pre-commit hook"
rm -f .git/hooks/pre-commit

# ── the docs commit: the named files, the given subject, pushed ──────────────
printf 'new page\n' > docs/new.md
rm -f docs/old.md
printf 'scratch\n' > scratch.txt
TALOS_ROLE=docs docs_commit "docs: explain the guide (#42)" 9 -- docs/guide.md docs/new.md docs/old.md
assert_eq "0" "$RC" "AC1 on the PR's head branch: commit-docs exits 0"
assert_contains "$OUT" "pushed" "AC1 on the PR's head branch: it reports the push"
assert_eq "docs: explain the guide (#42)" "$(git log -1 --format=%s)" "AC1 the commit subject is the line given on stdin"
assert_eq "docs/guide.md docs/new.md docs/old.md" "$(git show --name-only --format= HEAD | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
  "AC1 the commit holds exactly the files given (edited, new, deleted)"
assert_eq "$(git rev-parse HEAD)" "$(origin_ref "$BR")" "AC1 the PR's head branch is on origin at the docs commit"
assert_eq "$MAIN_SHA" "$(origin_ref main)" "AC1 origin's base branch did not move"
assert_contains "$(git status --porcelain)" " M src.txt" "AC1 a changed file that was not given stays uncommitted"
assert_contains "$(git status --porcelain)" "?? scratch.txt" "AC1 an untracked file that was not given stays untracked"

# No subject on stdin: a default one. Nothing changed: no commit, exit 0.
printf 'more\n' >> docs/guide.md
OUT="$(bash "$WT" commit-docs 9 -- docs/guide.md </dev/null 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "AC1 no subject on stdin: commit-docs exits 0"
assert_eq "docs: update docs (#9)" "$(git log -1 --format=%s)" "AC1 no subject on stdin: the default subject"
HEAD_BEFORE="$(git rev-parse HEAD)"
docs_commit "docs: nothing (#42)" 9 -- docs/guide.md
assert_eq "0" "$RC" "AC1 a file with no change: exits 0"
assert_contains "$OUT" "nothing to commit" "AC1 a file with no change: it says nothing to commit"
untouched "AC1 a file with no change"

# ── never forced: a head branch that moved on origin keeps origin's commit ───
git clone -q "$ORIGIN" "$SANDBOX/.home/other-clone"
git -C "$SANDBOX/.home/other-clone" checkout -q "$BR"
printf 'theirs\n' > "$SANDBOX/.home/other-clone/theirs.txt"
git -C "$SANDBOX/.home/other-clone" add theirs.txt
git -C "$SANDBOX/.home/other-clone" -c user.name=o -c user.email=o@talos commit -q -m "theirs"
git -C "$SANDBOX/.home/other-clone" push -q origin "$BR"
THEIRS="$(origin_ref "$BR")"
printf 'mine\n' >> docs/guide.md
docs_commit "docs: mine (#42)" 9 -- docs/guide.md
assert_eq "3" "$RC" "AC1 the head branch moved on origin: the push fails (exit 3), never forced"
assert_eq "$THEIRS" "$(origin_ref "$BR")" "AC1 the head branch moved on origin: origin keeps its commit"
assert_eq "docs: mine (#42)" "$(git log -1 --format=%s)" "AC1 the head branch moved on origin: the commit is kept locally"

finish
