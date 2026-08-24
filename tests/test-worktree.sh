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

# ── Lane-safety guards (new tests — existing 15 above must stay green) ────────
#
# Setup: create worktrees for issues 101-104 used only by the new tests.
git worktree add -q -b fix/issue-101-lane-home "$SANDBOX/wt/101" >/dev/null 2>&1
git worktree add -q -b fix/issue-102-self-test "$SANDBOX/wt/102" >/dev/null 2>&1

# ── remove refuses a lane home ────────────────────────────────────────────────
touch "$SANDBOX/wt/101/.talos-lane-home"
out="$(bash "$WT" remove 101)"; rc=$?
assert_eq "0" "$rc" "remove lane home exits 0"
assert_contains "$out" "refusing to remove lane home" "remove refuses a lane home"
# marker and directory must survive
assert_file_exists "$SANDBOX/wt/101/.talos-lane-home" "remove lane home leaves the marker file intact"

# ── remove refuses the current checkout (_is_self) ────────────────────────────
out="$(cd "$SANDBOX/wt/102" && bash "$WT" remove 102)"; rc=$?
assert_eq "0" "$rc" "remove self exits 0"
assert_contains "$out" "refusing to remove the current checkout" "remove refuses the current checkout"
# directory must still be there
[ -d "$SANDBOX/wt/102" ] \
  && pass "remove self leaves the directory intact" \
  || fail "remove self leaves the directory intact" "directory was deleted"

# ── sweep refuses a lane home ─────────────────────────────────────────────────
# wt/101 is a lane home; wt/102 is not (and is not self here). Run from SANDBOX.
out="$(bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a lane home exits 0"
assert_contains "$out" "refusing to sweep lane home" "sweep refuses a lane home"
assert_file_exists "$SANDBOX/wt/101/.talos-lane-home" "sweep leaves lane home marker intact"
# wt/102 was not a lane home and not self when run from SANDBOX — must be swept
assert_file_absent "$SANDBOX/wt/102" "sweep removes non-lane-home worktrees normally"

# ── sweep refuses the current checkout (_is_self) ────────────────────────────
git worktree add -q -b fix/issue-103-self-sweep "$SANDBOX/wt/103" >/dev/null 2>&1
out="$(cd "$SANDBOX/wt/103" && bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep from a worktree exits 0"
assert_contains "$out" "refusing to sweep the current checkout" "sweep refuses the current checkout"
[ -d "$SANDBOX/wt/103" ] \
  && pass "sweep self leaves the directory intact" \
  || fail "sweep self leaves the directory intact" "directory was deleted"

# ── multi-lane interlock: sweep no-ops when >1 lane home exists ───────────────
# The main checkout ($SANDBOX) plus wt/101 already have .talos-lane-home —
# that gives a count of 2 once we mark the main checkout too.
touch "$SANDBOX/.talos-lane-home"
# Create a disposable issue worktree so there IS something to sweep if the guard fails.
git worktree add -q -b fix/issue-105-orphan "$SANDBOX/wt/105" >/dev/null 2>&1
out="$(bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "multi-lane sweep exits 0"
assert_contains "$out" "lanes share this repo" "multi-lane interlock prints lane count message"
assert_contains "$out" "skipping sweep" "multi-lane interlock says it is skipping"
# The orphan must NOT be removed because the interlock fired.
[ -d "$SANDBOX/wt/105" ] \
  && pass "multi-lane interlock leaves disposable worktree intact" \
  || fail "multi-lane interlock leaves disposable worktree intact" "interlock did not fire — orphan was swept"

# ── TALOS_SWEEP_ALL_LANES=1 bypasses the interlock ──────────────────────────
git worktree add -q -b fix/issue-106-orphan "$SANDBOX/wt/106" >/dev/null 2>&1
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "TALOS_SWEEP_ALL_LANES=1 sweep exits 0"
# Orphaned worktrees (105, 106) must be swept when the override is active.
assert_file_absent "$SANDBOX/wt/105" "TALOS_SWEEP_ALL_LANES=1 sweeps orphaned worktrees"
assert_file_absent "$SANDBOX/wt/106" "TALOS_SWEEP_ALL_LANES=1 sweeps all orphaned worktrees"
# Lane home (wt/101) must still be protected by the per-worktree guard.
assert_file_exists "$SANDBOX/wt/101/.talos-lane-home" "TALOS_SWEEP_ALL_LANES=1 still respects the per-worktree lane-home guard"

finish
