#!/usr/bin/env bash
# test-conflict-files.sh -- unit tests for the `conflict-files` verb (#256).
#
# Contract: prints the paths that conflict between a PR's head and
# origin/<base_branch>, one per line. Exit 0 with output when conflicting,
# exit 0 with no output when clean, exit 2 when it cannot be determined.
# Never touches the caller's own checkout (no branch of the caller's
# checkout is created or moved, and `git status`/`assert-sync` on the
# caller's checkout are unaffected).
#
# Uses a local bare-repo fixture as the `origin` remote (no network) -- the
# merge attempt itself is a real git operation, not a mocked one, since the
# whole point of the verb is a real merge-conflict detection.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

# ── Local bare-repo fixture (no network) ──────────────────────────────────────
UPSTREAM_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-cf-origin.XXXXXX")"
UPSTREAM="$UPSTREAM_PARENT/upstream.git"
git init -q --bare "$UPSTREAM"
# make_sandbox's own EXIT trap only removes $SANDBOX -- extend it to also
# remove the sibling bare-repo fixture.
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

# PR #42: a CHANGELOG-only conflict with main.
git checkout -q -b pr-branch-42
python3 -c "
p = 'CHANGELOG.md'
c = open(p).read()
open(p, 'w').write(c.replace('- existing entry', '- existing entry\n- PR bullet'))
"
git commit -aqm "pr: add changelog bullet"
git push -q origin pr-branch-42
git push -q origin pr-branch-42:refs/pull/42/head

git checkout -q main
python3 -c "
p = 'CHANGELOG.md'
c = open(p).read()
open(p, 'w').write(c.replace('- existing entry', '- existing entry\n- base bullet'))
"
git commit -aqm "base: add changelog bullet"
git push -q origin main

# PR #43: a non-conflicting change (different file) -- clean merge.
git checkout -q main
git checkout -q -b pr-branch-43
echo "clean" > other-file.txt
git add other-file.txt
git commit -qm "pr: unrelated file"
git push -q origin pr-branch-43
git push -q origin pr-branch-43:refs/pull/43/head

# PR #44: conflicts in a non-CHANGELOG path too, to prove conflict-files
# lists whatever actually conflicts, not just CHANGELOG.md.
git checkout -q main
mkdir -p scripts
echo "base version" > scripts/x.sh
git add scripts/x.sh
git commit -qm "base: add scripts/x.sh"
git push -q origin main

git checkout -q -b pr-branch-44 "$(git rev-parse main~1)"
mkdir -p scripts
echo "pr version" > scripts/x.sh
git add scripts/x.sh
git commit -qm "pr: add conflicting scripts/x.sh"
git push -q origin pr-branch-44
git push -q origin pr-branch-44:refs/pull/44/head

git checkout -q main
git branch -D pr-branch-42 pr-branch-43 pr-branch-44 >/dev/null 2>&1 || true

cat > talos.pipeline.json <<EOF
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF

_clean_status="$(git status --porcelain)"
_branch_count_before="$(git branch --list | wc -l | tr -d ' ')"
# Baseline assert-sync verdict BEFORE any conflict-files call -- the sandbox
# itself carries untracked stub logs/config (use_stubs, talos.pipeline.json),
# so assert-sync is not expected to report "clean and level" here; the point
# is that conflict-files must not CHANGE this verdict.
_sync_before_out="$(bash "$VCS" assert-sync 2>&1)"; _sync_before_rc=$?

# ── (a) CHANGELOG-only conflict -> exit 0, prints exactly CHANGELOG.md ──────
out="$(bash "$VCS" conflict-files 42)"; rc=$?
assert_eq "0" "$rc" "conflict-files: exits 0 for a CHANGELOG-only conflict"
assert_eq "CHANGELOG.md" "$out" "conflict-files: prints exactly CHANGELOG.md"

# ── (b) clean PR -> exit 0, no output ────────────────────────────────────────
out="$(bash "$VCS" conflict-files 43)"; rc=$?
assert_eq "0" "$rc" "conflict-files: exits 0 for a clean PR"
assert_eq "" "$out" "conflict-files: prints nothing for a clean PR"

# ── (c) conflict in a non-CHANGELOG path -> still exit 0, lists that path ──
out="$(bash "$VCS" conflict-files 44)"; rc=$?
assert_eq "0" "$rc" "conflict-files: exits 0 for a non-CHANGELOG conflict"
assert_eq "scripts/x.sh" "$out" "conflict-files: lists whatever path actually conflicts"

# ── Never touches the caller's own checkout ─────────────────────────────────
assert_eq "$_clean_status" "$(git status --porcelain)" "conflict-files: caller's git status is unchanged"
assert_eq "$_branch_count_before" "$(git branch --list | wc -l | tr -d ' ')" "conflict-files: no new local branch created in the caller's checkout"
sync_out="$(bash "$VCS" assert-sync 2>&1)"; sync_rc=$?
assert_eq "$_sync_before_rc" "$sync_rc" "conflict-files: assert-sync's verdict is unchanged afterward"
assert_eq "$_sync_before_out" "$sync_out" "conflict-files: assert-sync's output is unchanged afterward"

# ── (d) unresolvable PR number -> exit 2 ────────────────────────────────────
out="$(bash "$VCS" conflict-files 9999 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "conflict-files: exits 2 when the PR ref cannot be resolved"
assert_eq "" "$out" "conflict-files: prints nothing when it cannot determine"

# ── (e) missing PR number -> exit 1 ─────────────────────────────────────────
out="$(bash "$VCS" conflict-files 2>&1)"; rc=$?
assert_eq "1" "$rc" "conflict-files: exits 1 with no PR number"
assert_contains "$out" "missing PR number" "conflict-files: names the missing argument"

# ── (f) non-integer PR number -> exit 1 ─────────────────────────────────────
out="$(bash "$VCS" conflict-files abc 2>&1)"; rc=$?
assert_eq "1" "$rc" "conflict-files: exits 1 for a non-integer PR number"

# ── (g) --dry-run: exits 0, no git worktree created ─────────────────────────
wt_before="$(git worktree list | wc -l | tr -d ' ')"
out="$(bash "$VCS" --dry-run conflict-files 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "conflict-files: --dry-run exits 0"
assert_contains "$out" "[dry-run]" "conflict-files: --dry-run prints a marker"
assert_eq "$wt_before" "$(git worktree list | wc -l | tr -d ' ')" "conflict-files: --dry-run creates no worktree"

# ── (i) git worktree add/remove are serialized with with_lock (#262 review) ─
# Same resource key pipeline-worktree.sh's create/remove/sweep use:
# <git-common-dir>/talos-worktree. Hold it with a LIVE pid (so with_lock's
# staleness check cannot reclaim it immediately) via a background holder
# that releases it after ~1s -- if _vcs_shared_conflict_files really routes
# its `git worktree add` through with_lock, the call blocks until the
# holder releases (a plain unlocked `git worktree add` would ignore the
# directory entirely and return almost instantly).
_lock_resource="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"
_lock_dir="${_lock_resource}.lock.d"
rm -rf "$_lock_dir"
mkdir -p "$_lock_dir"
printf '%s:1\n' "$$" > "$_lock_dir/pid"
( sleep 1; rm -rf "$_lock_dir" ) &
_release_pid=$!

_lock_start="$(date +%s)"
out="$(bash "$VCS" conflict-files 42 2>&1)"; rc=$?
_lock_end="$(date +%s)"
_lock_elapsed=$((_lock_end - _lock_start))

wait "$_release_pid" 2>/dev/null
assert_eq "0" "$rc" "conflict-files: still succeeds once the held lock is released"
assert_eq "CHANGELOG.md" "$out" "conflict-files: still produces the correct result after waiting on the lock"
assert_eq "1" "$([ "$_lock_elapsed" -ge 1 ] && echo 1 || echo 0)" "conflict-files: git worktree add waited on the held lock (with_lock is actually wired in)"
assert_file_absent "$_lock_dir" "conflict-files: lock dir is released, not left behind"

# ── (h) unsupported provider -> exit 1 ──────────────────────────────────────
cat > talos.pipeline.json <<EOF
{"vcs": {"provider": "gitlab"}, "base_branch": "main"}
EOF
out="$(bash "$VCS" conflict-files 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "conflict-files: exits 1 for an unsupported provider"
assert_contains "$out" "not implemented" "conflict-files: names the unsupported provider"

rm -f talos.pipeline.json

finish
