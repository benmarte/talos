#!/usr/bin/env bash
# test-assert-sync-worktrees.sh — regression test for issue #119.
#
# assert-sync aborted on the orchestrator's own checkout whenever Talos had
# created worktrees, because .claude/worktrees/ was not in .gitignore.
# git status --porcelain reported it as untracked and the dirty-tree guard
# fired, blocking every pipeline run.
#
# Cases tested:
#   1. (REGRESSION) .claude/worktrees/ present and listed in .gitignore
#      — assert-sync exits 0. MUST fail on the old code (without .gitignore
#      entry) to serve as the RED proof.
#   2. Genuinely dirty tree (edited tracked file + unrelated untracked file)
#      — assert-sync exits 1 and names BOTH files. Proves the guard was not
#      weakened by the gitignore fix.
#   3. Clean checkout with no worktrees — exits 0, no output.
#
# MEASUREMENT DISCIPLINE: `out=$(cmd 2>&1); rc=$?` throughout — never pipe.
#
# Fixtures are self-asserting: each case verifies the fixture is in the
# state it claims before running assert-sync, so a broken fixture fails loudly
# here rather than silently masking what is being measured.
set -u
. "$(dirname "$0")/helpers.sh"

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Shared fixture ────────────────────────────────────────────────────────────
# Build a minimal local git repo with a bare "origin" so assert-sync can fetch.
make_sandbox

git config user.email "test@talos.invalid"
git config user.name  "talos-test"

# Write .gitignore that mirrors the repo's actual .gitignore (post-fix).
# Also exclude sandbox infrastructure paths (.home/, origin.git/) so they do
# not pollute git status during the test — matching the pattern used in
# tests/test-assert-sync.sh.
# This is what we are testing — if we removed .claude/worktrees/ from here the
# regression test (T1) would fail as expected, which is the RED proof.
cat > .gitignore <<'EOF'
.env
__pycache__/
*.pyc
.DS_Store
origin.git/
.home/
# Talos-managed ephemeral artifacts — never content, always build output
.claude/worktrees/
EOF

# Write a placeholder config file so the initial commit has a tracked file;
# we rewrite it with the real base branch once we know it.
printf '{"base_branch":"placeholder","vcs":{"provider":"github"}}' > talos.pipeline.json

git add .gitignore talos.pipeline.json
git commit -q -m "root: add gitignore and config"

# Create a bare "origin" and wire it up.
ORIGIN_DIR="$SANDBOX/origin.git"
git clone -q --bare . "$ORIGIN_DIR"
git remote remove origin 2>/dev/null || true
git remote add origin "$ORIGIN_DIR"
git fetch -q origin

# Detect the actual default branch from the bare clone so the fixture is
# platform-independent regardless of init.defaultBranch (main vs master).
BASE="$(git -C "$ORIGIN_DIR" symbolic-ref HEAD 2>/dev/null | sed 's|.*/||')"
[ -z "$BASE" ] && BASE="main"

# Rewrite the config with the detected branch name — JSON, no PyYAML needed.
printf '{"base_branch":"%s","vcs":{"provider":"github"}}' "$BASE" > talos.pipeline.json
git add talos.pipeline.json
git commit -q -m "update config: base_branch=$BASE"

# Push so local and origin are level.
git branch -u "origin/$BASE" "$BASE" 2>/dev/null || true
git push -q origin "$BASE"

# Self-assertion: local must be level with origin/<BASE> before any test runs,
# so a broken fixture fails loudly here rather than silently skewing results.
_setup_ahead="$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo "?")"
assert_eq "0" "$_setup_ahead" "fixture: local is level with origin/$BASE (0 commits ahead)"

# ── Test 1 (REGRESSION): .claude/worktrees/ present — exits 0 ────────────────
# Mutation that makes this test fail: remove `.`.claude/worktrees/` from .gitignore.
#
# Simulate Talos having created a worktree directory.  The content does not
# matter; the path's presence and its gitignore treatment do.
mkdir -p ".claude/worktrees/agent-deadbeef"
touch ".claude/worktrees/agent-deadbeef/talos.pipeline.json"

# Fixture assertion: git status must show the directory as IGNORED (not untracked).
_wt_status="$(git status --porcelain --ignored ".claude/worktrees/" 2>/dev/null)"
case "$_wt_status" in
  *"!! .claude/worktrees/"*)
    pass "T1 fixture: .claude/worktrees/ is ignored by git" ;;
  *"?? .claude/worktrees/"*)
    fail "T1 fixture: .claude/worktrees/ is UNTRACKED (fix did not apply)" \
         "git output: $_wt_status"
    ;;
  *)
    pass "T1 fixture: .claude/worktrees/ absent from untracked output" ;;
esac

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T1: assert-sync exits 0 when only .claude/worktrees/ present"
assert_eq "" "$out" "T1: assert-sync produces no output when only .claude/worktrees/ present"

# Clean up worktrees directory for subsequent tests.
rm -rf ".claude"

# ── Test 2: Genuinely dirty tree — exits 1, names BOTH files ─────────────────
# Mutation that makes this test fail: weakening assert-sync to skip untracked
# files or to filter by path pattern.
#
# Create two distinct dirty conditions:
#   (a) an edited tracked file
#   (b) an unrelated untracked file
echo "modified" >> talos.pipeline.json        # (a) tracked, modified
echo "scratch"  >  untracked-scratch.txt      # (b) untracked

# Fixture assertion: git status must show both files.
_dirty="$(git status --porcelain 2>/dev/null)"
assert_contains "$_dirty" "talos.pipeline.json" "T2 fixture: tracked modified file visible"
assert_contains "$_dirty" "untracked-scratch.txt" "T2 fixture: untracked file visible"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "T2: dirty tree exits 1"
assert_contains "$out" "dirty" "T2: output mentions dirty"
assert_contains "$out" "talos.pipeline.json" "T2: output names modified tracked file"
assert_contains "$out" "untracked-scratch.txt" "T2: output names untracked file"
assert_contains "$out" "commit or stash" "T2: output instructs commit or stash"

# Clean up dirty state.
git checkout -q -- talos.pipeline.json
rm -f untracked-scratch.txt

# ── Test 3: Clean checkout, no worktrees — exits 0, no output ────────────────
# Fixture assertion: tree must be clean.
_clean="$(git status --porcelain 2>/dev/null)"
assert_eq "" "$_clean" "T3 fixture: working tree is clean"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T3: clean checkout, no worktrees — exits 0"
assert_eq "" "$out" "T3: clean checkout produces no output"

finish
