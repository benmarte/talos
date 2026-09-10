#!/usr/bin/env bash
# test-mergebase.sh -- unit tests for scripts/pipeline-mergebase.sh (#256).
#
# Contract:
#   exit 0  resolved and pushed a mechanical union merge; both entries
#           present (PR entry first), no conflict markers left.
#   exit 3  a conflicting path is not covered by merge.union_paths -- not
#           mechanically resolvable, nothing pushed.
#   exit 1  setup/config/git error, nothing pushed.
#
# Uses a local bare-repo fixture as the `origin` remote (no network) --
# same fixture shape as test-conflict-files.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
MB="$TALOS_ROOT/scripts/pipeline-mergebase.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

UPSTREAM_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-mb-origin.XXXXXX")"
UPSTREAM="$UPSTREAM_PARENT/upstream.git"
git init -q --bare "$UPSTREAM"
trap 'rm -rf "$SANDBOX" "$UPSTREAM_PARENT"' EXIT

git remote set-url origin "$UPSTREAM"

cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]
### Added
- existing entry
EOF
git add CHANGELOG.md
git commit -q -m "seed changelog"
git branch -M main
git push -q origin main

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF

# make_pr_branch <branch> <pr-n> <mutator-python-snippet-on-CHANGELOG.md>
# Branches off the CURRENT origin/main, applies the mutation, pushes the
# branch and its refs/pull/<n>/head, and configures the gh stub's view-pr
# response for that PR number.
make_pr_branch() {
  local branch="$1" mutator="$2"
  git fetch -q origin main
  git checkout -q -b "$branch" origin/main
  python3 -c "$mutator"
  git commit -aqm "pr: $branch"
  git push -q origin "$branch"
  git push -q origin "$branch:refs/pull/${3}/head"
  git checkout -q main
  git branch -D "$branch" >/dev/null 2>&1 || true
}

# ── (a) CHANGELOG-only conflict -> exit 0, both entries kept, PR first ──────
make_pr_branch "pr-50" "
p = 'CHANGELOG.md'
c = open(p).read()
open(p, 'w').write(c.replace('- existing entry', '- existing entry\n- PR bullet'))
" 50
# Advance main with a conflicting bullet at the same spot.
python3 -c "
p = 'CHANGELOG.md'
c = open(p).read()
open(p, 'w').write(c.replace('- existing entry', '- existing entry\n- base bullet'))
"
git commit -aqm "base: add changelog bullet"
git push -q origin main

out="$(STUB_PR_HEAD_REF_NAME="pr-50" bash "$MB" 50 2>&1)"; rc=$?
assert_eq "0" "$rc" "mergebase: exits 0 for a CHANGELOG-only conflict"
assert_contains "$out" "pushed" "mergebase: reports success"

# Fetch the pushed result and inspect it.
git fetch -q origin pr-50
merged_content="$(git show origin/pr-50:CHANGELOG.md)"
assert_contains "$merged_content" "PR bullet" "mergebase: kept the PR's own entry"
assert_contains "$merged_content" "base bullet" "mergebase: kept the base's entry too (union)"
assert_not_contains "$merged_content" "<<<<<<<" "mergebase: no conflict markers remain"
# PR side first = newest first: the PR bullet line must appear before the
# base bullet line in the resolved file.
pr_line="$(printf '%s\n' "$merged_content" | grep -n 'PR bullet' | head -1 | cut -d: -f1)"
base_line="$(printf '%s\n' "$merged_content" | grep -n 'base bullet' | head -1 | cut -d: -f1)"
assert_eq "1" "$([ "$pr_line" -lt "$base_line" ] && echo 1 || echo 0)" "mergebase: PR entry appears before the base entry (newest first)"

# Commit message names the mechanical union (#256).
commit_msg="$(git log -1 --format=%s origin/pr-50)"
assert_contains "$commit_msg" "mechanical union" "mergebase: commit message names the mechanical union"
assert_contains "$commit_msg" "CHANGELOG.md" "mergebase: commit message names CHANGELOG.md"

# ── (b) conflict in a non-union path -> exit 3, nothing pushed ─────────────
git fetch -q origin main
git checkout -q -b pr-51 origin/main
mkdir -p scripts
echo "pr version" > scripts/x.sh
git add scripts/x.sh
git commit -qm "pr: add scripts/x.sh"
git push -q origin pr-51
git push -q origin pr-51:refs/pull/51/head
git checkout -q main
git branch -D pr-51 >/dev/null 2>&1 || true

mkdir -p scripts
echo "base version" > scripts/x.sh
git add scripts/x.sh
git commit -qm "base: add scripts/x.sh"
git push -q origin main

pr51_sha_before="$(git rev-parse origin/pr-51)"
out="$(STUB_PR_HEAD_REF_NAME="pr-51" bash "$MB" 51 2>&1)"; rc=$?
assert_eq "3" "$rc" "mergebase: exits 3 when a conflict is outside merge.union_paths"
assert_contains "$out" "not covered" "mergebase: names why (not covered by merge.union_paths)"
git fetch -q origin pr-51
assert_eq "$pr51_sha_before" "$(git rev-parse origin/pr-51)" "mergebase: nothing pushed on the non-union path"

# ── (c) --union-paths override widens what's mechanically resolvable ───────
# Uses a fresh PR/path (notes.txt) rather than pr-51/scripts/x.sh above --
# scripts/** is hard-coded non-unionable (see (d) below) and can never be
# widened by --union-paths, so proving the override actually works needs a
# path outside that hard-coded set.
git fetch -q origin main
git checkout -q -b pr-52 origin/main
echo "pr version" > notes.txt
git add notes.txt
git commit -qm "pr: add notes.txt"
git push -q origin pr-52
git push -q origin pr-52:refs/pull/52/head
git checkout -q main
git branch -D pr-52 >/dev/null 2>&1 || true

echo "base version" > notes.txt
git add notes.txt
git commit -qm "base: add notes.txt"
git push -q origin main

out="$(STUB_PR_HEAD_REF_NAME="pr-51" bash "$MB" 51 2>&1)"; rc=$?
# Sanity: pr-51 (scripts/x.sh) is still unresolvable without an override --
# unaffected by main's later notes.txt commit.
assert_eq "3" "$rc" "mergebase: pr-51 is still exit 3 without an override"

out="$(STUB_PR_HEAD_REF_NAME="pr-52" bash "$MB" 52 --union-paths 'notes.txt' 2>&1)"; rc=$?
assert_eq "0" "$rc" "mergebase: --union-paths override resolves an otherwise-blocked conflict"
git fetch -q origin pr-52
merged_notes="$(git show origin/pr-52:notes.txt)"
assert_contains "$merged_notes" "pr version" "mergebase: --union-paths override kept the PR's own content"
assert_contains "$merged_notes" "base version" "mergebase: --union-paths override kept the base's content too"

# ── (d) hard-coded non-unionable prefix rejected even via override ─────────
out="$(bash "$MB" 51 --union-paths 'scripts/**' 2>&1)"; rc=$?
assert_eq "1" "$rc" "mergebase: rejects a scripts/** union-paths override"
assert_contains "$out" "non-unionable" "mergebase: names the rejection reason"
git fetch -q origin pr-51
assert_eq "$pr51_sha_before" "$(git rev-parse origin/pr-51)" "mergebase: nothing pushed when the override itself is rejected"

# ── (e) worktree removed on every exit path ─────────────────────────────────
wt_before="$(git worktree list | wc -l | tr -d ' ')"
STUB_PR_HEAD_REF_NAME="pr-50" bash "$MB" 50 >/dev/null 2>&1  # already merged -> harmless re-run
assert_eq "$wt_before" "$(git worktree list | wc -l | tr -d ' ')" "mergebase: leaves no worktree behind"

# ── (f) missing PR number -> exit 1 ─────────────────────────────────────────
out="$(bash "$MB" 2>&1)"; rc=$?
assert_eq "1" "$rc" "mergebase: exits 1 with no PR number"

# ── (g) unresolvable PR -> exit 1 ───────────────────────────────────────────
out="$(STUB_PR_HEAD_REF_NAME="" bash "$MB" 999999 2>&1)"; rc=$?
assert_eq "1" "$rc" "mergebase: exits 1 when the PR's head branch cannot be resolved"

rm -f talos.pipeline.json

finish
