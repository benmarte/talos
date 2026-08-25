#!/usr/bin/env bash
# test-assert-sync.sh — regression tests for `pipeline-vcs.sh assert-sync`.
#
# Builds a self-contained local git fixture (a bare "origin" and a local clone)
# so every case is tested without network access.  The fixture stays inside
# SANDBOX and is cleaned up on exit by make_sandbox's trap.
#
# Cases tested:
#   1. Clean and level with origin/<base> — exits 0, no output.
#      (Exit-zero proof: a crashing precondition looks like correct strictness.)
#   2. Behind origin/<base> — exits 1, clear message naming both SHAs and gap.
#   3. Dirty working tree — exits 1, names dirty files, no git-fetch attempted.
#   4. Diverged (ahead AND behind) — exits 1, warns against force-push.
#   5. Ahead of origin/<base> only — exits 0 (ahead is not stale).
#   6. Non-main base branch — exits 0 when level on a non-main branch.
#
# MEASUREMENT DISCIPLINE: `out=$(cmd 2>&1); rc=$?` throughout — never pipe.
#
# NOTE: SKILL.md call sites are not unit-testable.  A grep inventory confirming
#       both SKILL.md call sites carry the `assert-sync` call is provided in the
#       PR description instead.
set -u
. "$(dirname "$0")/helpers.sh"

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Fixture setup ────────────────────────────────────────────────────────────
# make_sandbox creates a temp dir, git-inits it, and cds into it.
# We build a bare "origin" and a local clone so fetch/push work without network.
make_sandbox

# Give the repo a user identity.
git config user.email "test@talos.invalid"
git config user.name  "talos-test"

# Stage a .gitignore so test directories and the config file are tracked (not
# untracked), keeping git status --porcelain clean between tests.
cat > .gitignore <<'EOF'
origin.git/
origin-clone/
.home/
EOF
cat > talos.pipeline.yml <<'EOF'
base_branch: main
vcs:
  provider: github
EOF
git add .gitignore talos.pipeline.yml
git commit -q -m "root: add gitignore and config"

# Create a bare "origin" from the committed root.
ORIGIN_DIR="$SANDBOX/origin.git"
git clone -q --bare . "$ORIGIN_DIR"

# Replace the fake remote set by make_sandbox with our bare repo.
git remote remove origin
git remote add origin "$ORIGIN_DIR"
git fetch -q origin

# Track the remote branch.  Git version determines the default branch name.
BASE="$(git -C "$ORIGIN_DIR" symbolic-ref HEAD 2>/dev/null | sed 's|.*/||')"
[ -z "$BASE" ] && BASE="main"
git branch -u "origin/$BASE" "$BASE" 2>/dev/null || true

# Update config to use the detected base branch.
cat > talos.pipeline.yml <<EOF
base_branch: $BASE
vcs:
  provider: github
EOF
git add talos.pipeline.yml
git commit -q -m "update config with detected base branch"
# Push so local and origin are level.
git push -q origin "$BASE"

# ── Test 1: Clean and level — exits 0, no output ─────────────────────────────
out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T1: clean+level exits 0"
assert_eq "" "$out" "T1: clean+level produces no output"

# ── Test 2: Behind origin — exits 1, names both SHAs and gap count ───────────
# Advance origin by one commit (via a scratch clone) without pulling locally.
ORIGIN_CLONE="$SANDBOX/origin-clone"
git clone -q "$ORIGIN_DIR" "$ORIGIN_CLONE"
git -C "$ORIGIN_CLONE" config user.email "test@talos.invalid"
git -C "$ORIGIN_CLONE" config user.name  "talos-test"
git -C "$ORIGIN_CLONE" commit -q --allow-empty -m "advance origin by 1"
git -C "$ORIGIN_CLONE" push -q origin "$BASE"
# Local is now 1 commit behind origin/<BASE>; no dirty tree.

LOCAL_SHA="$(git rev-parse HEAD)"
# Fetch to update remote-tracking ref, then read origin SHA.
git fetch -q origin
ORIGIN_SHA="$(git rev-parse "origin/$BASE")"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 1 "$rc"       "T2: behind-origin exits 1"
assert_contains "$out" "ABORT" "T2: output includes ABORT"
assert_contains "$out" "behind" "T2: output mentions behind"
assert_contains "$out" "git pull --ff-only" "T2: output instructs git pull --ff-only"
assert_contains "$out" "$LOCAL_SHA"  "T2: local SHA present in output"
assert_contains "$out" "$ORIGIN_SHA" "T2: origin SHA present in output"
assert_contains "$out" "1 commit"    "T2: gap count (1 commit) present"

# ── Test 3: Dirty working tree — exits 1, names files, no fetch attempted ────
# Sync up so we are level before making the tree dirty.
git pull -q --ff-only

# Create an untracked dirty file (untracked == dirty per git status --porcelain).
echo "wip" > dirty-wip.txt

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "T3: dirty tree exits 1"
assert_contains "$out" "dirty" "T3: output mentions dirty"
assert_contains "$out" "dirty-wip.txt" "T3: names the dirty file"
assert_contains "$out" "commit or stash" "T3: tells user to commit or stash"
# The dirty check fires BEFORE the behind-check, so no "git pull" advice appears.
assert_not_contains "$out" "git pull --ff-only" "T3: behind-check did not run (stopped at dirty)"

# Clean up dirty file.
rm -f dirty-wip.txt

# ── Test 4: Diverged (ahead AND behind) — exits 1, warns against force-push ──
# Advance origin by 1 more commit without pulling locally.
git -C "$ORIGIN_CLONE" commit -q --allow-empty -m "advance origin again"
git -C "$ORIGIN_CLONE" push -q origin "$BASE"

# Add a local commit without pulling — local is ahead by 1, behind by 1.
git commit -q --allow-empty -m "local diverging commit"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 1 "$rc"           "T4: diverged exits 1"
assert_contains "$out" "ABORT"     "T4: output includes ABORT"
assert_contains "$out" "diverged"  "T4: output mentions diverged"
assert_contains "$out" "ahead"     "T4: output states ahead count"
assert_contains "$out" "behind"    "T4: output states behind count"
assert_contains "$out" "force"     "T4: output warns against force-push"

# ── Test 5: Ahead of origin only — exits 0 ───────────────────────────────────
# Ruling: being ahead-only is not the failure mode this check guards against.
# The concern is stale source (behind origin). A working tree that is ahead of
# origin has MORE commits than origin — not stale. Non-isolated stages reading
# it see a consistent, complete source (even if not yet merged). Exits 0.
#
# Setup: fast-forward local to origin/<BASE>, then add one local-only commit.
git fetch -q origin
git reset -q --hard "origin/$BASE"
git commit -q --allow-empty -m "local-only commit (ahead-only state)"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T5: ahead-only exits 0"
assert_eq "" "$out"       "T5: ahead-only produces no output"

# ── Test 6: Non-main base branch — resolves correctly ────────────────────────
# Create a 'develop' branch in origin and confirm assert-sync resolves it via
# the config key (not hardcoded to 'main').
git fetch -q origin
git reset -q --hard "origin/$BASE"

# Create 'develop' in origin.
git -C "$ORIGIN_CLONE" checkout -q -b develop
git -C "$ORIGIN_CLONE" commit -q --allow-empty -m "develop base"
git -C "$ORIGIN_CLONE" push -q origin develop

git fetch -q origin

# Point config at 'develop'.
cat > talos.pipeline.yml <<EOF
base_branch: develop
vcs:
  provider: github
EOF
git add talos.pipeline.yml
git commit -q -m "switch config to develop base"
# Push this commit to develop so local is level with origin/develop.
git push -q origin "HEAD:develop" 2>/dev/null || git -C "$ORIGIN_CLONE" push -q origin develop
# Reset local HEAD to match origin/develop exactly.
git fetch -q origin
git reset -q --hard "origin/develop"

out="$(bash "$VCS" assert-sync 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T6: non-main base branch (develop) exits 0 when level"
assert_eq "" "$out"       "T6: non-main base branch produces no output when level"

finish
