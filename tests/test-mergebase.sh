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

# ── (d2) merge.union_paths cross-checked against merge.forbidden_files ─────
# (#262 security-review follow-up) Widening union_paths to a glob that
# overlaps merge.forbidden_files must never let forbidden-shaped content get
# union-merged and pushed unreviewed. Rejected at validation time (before
# any fetch), exit 3 -- not exit 1 like the hard-coded scripts/**/tests/**
# case above, since the forbidden-files list is operator-configurable (not
# a structural invariant) and a rejection here is closer in kind to "this
# conflict isn't mechanically resolvable" than to "the config itself is
# malformed".
out="$(bash "$MB" 51 --union-paths '*.env' 2>&1)"; rc=$?
assert_eq "3" "$rc" "mergebase: rejects a *.env union-paths override (matches merge.forbidden_files)"
assert_contains "$out" "forbidden" "mergebase: names the forbidden-files rejection reason"

out="$(bash "$MB" 51 --union-paths '.env' 2>&1)"; rc=$?
assert_eq "3" "$rc" "mergebase: rejects a .env union-paths override (exact forbidden-files match)"
assert_contains "$out" "forbidden" "mergebase: names the forbidden-files rejection reason (.env)"

# End-to-end: a PR that actually conflicts on .env, widened to allow it.
git fetch -q origin main
git checkout -q -b pr-53 origin/main
echo "SECRET=pr-value" > .env
git add .env
git commit -qm "pr: add .env"
git push -q origin pr-53
git push -q origin pr-53:refs/pull/53/head
git checkout -q main
git branch -D pr-53 >/dev/null 2>&1 || true

echo "SECRET=base-value" > .env
git add .env
git commit -qm "base: add .env"
git push -q origin main

pr53_sha_before="$(git rev-parse origin/pr-53)"

# Default union_paths (CHANGELOG.md only) does not cover .env -- already the
# generic non-union-path behaviour, exercised here with the secrets-shaped
# file the security review was scoped to.
out="$(STUB_PR_HEAD_REF_NAME="pr-53" bash "$MB" 53 2>&1)"; rc=$?
assert_eq "3" "$rc" "mergebase: a real .env conflict is exit 3 under the default union_paths"

# Explicitly widening union_paths to .env is rejected at validation --
# before pipeline-mergebase.sh ever fetches or looks at the actual conflict.
out="$(STUB_PR_HEAD_REF_NAME="pr-53" bash "$MB" 53 --union-paths '.env' 2>&1)"; rc=$?
assert_eq "3" "$rc" "mergebase: widening union_paths to .env is still exit 3 for a real .env conflict"
assert_contains "$out" "forbidden" "mergebase: names the forbidden-files rejection reason for the real conflict"
git fetch -q origin pr-53
assert_eq "$pr53_sha_before" "$(git rev-parse origin/pr-53)" "mergebase: nothing pushed for the .env conflict, override or not"

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

# ── (h) git worktree add is serialized with with_lock (#262 review) ────────
# Dynamic proof the SAME resource key pipeline-worktree.sh's create/remove/
# sweep use (<git-common-dir>/talos-worktree) actually blocks
# pipeline-mergebase.sh's `git worktree add`, the same technique
# test-conflict-files.sh uses for _vcs_shared_conflict_files: hold the lock
# with a LIVE pid (so staleness reclaim cannot skip the wait), release it
# after ~1s from a background job, and confirm the call took at least that
# long before succeeding.
git fetch -q origin main
git checkout -q -b pr-55 origin/main
echo "pr version" > lockcheck.txt
git add lockcheck.txt
git commit -qm "pr: add lockcheck.txt"
git push -q origin pr-55
git push -q origin pr-55:refs/pull/55/head
git checkout -q main
git branch -D pr-55 >/dev/null 2>&1 || true

# main must diverge too (an unrelated, non-conflicting file), otherwise
# merging origin/main into pr-55 is a no-op fast-forward with nothing to
# commit -- pipeline-mergebase.sh would fail at the commit step regardless
# of locking, unrelated to what this test is checking.
echo "base extra" > lockcheck-base.txt
git add lockcheck-base.txt
git commit -qm "base: unrelated file"
git push -q origin main

_lock_resource="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"
_lock_dir="${_lock_resource}.lock.d"
rm -rf "$_lock_dir"
mkdir -p "$_lock_dir"
printf '%s:1\n' "$$" > "$_lock_dir/pid"
( sleep 1; rm -rf "$_lock_dir" ) &
_release_pid=$!

_lock_start="$(date +%s)"
out="$(STUB_PR_HEAD_REF_NAME="pr-55" bash "$MB" 55 2>&1)"; rc=$?
_lock_end="$(date +%s)"
_lock_elapsed=$((_lock_end - _lock_start))

wait "$_release_pid" 2>/dev/null
assert_eq "0" "$rc" "mergebase: still succeeds once the held lock is released"
assert_eq "1" "$([ "$_lock_elapsed" -ge 1 ] && echo 1 || echo 0)" "mergebase: git worktree add waited on the held lock (with_lock is actually wired in)"
assert_file_absent "$_lock_dir" "mergebase: lock dir is released, not left behind"

# ── (i) the cleanup trap's git worktree remove also routes through with_lock ─
# A pure timing test cannot isolate the cleanup trap's own with_lock call
# from the (already-locked, pre-#262) `git worktree add` a few lines above
# it in the same process -- both serialize on the identical resource, so
# holding the lock once around the whole invocation cannot tell them apart.
# Assert it structurally instead: the exact review-flagged gap was
# `_mb_cleanup`'s `git worktree remove --force` NOT going through with_lock.
_cleanup_body="$(awk '/^_mb_cleanup\(\) \{/,/^\}/' "$MB")"
assert_contains "$_cleanup_body" "with_lock" "mergebase: _mb_cleanup's git worktree remove is wrapped in with_lock"

rm -f talos.pipeline.json

finish
