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

# ── End-of-run sweep: harness (worktree-agent-*) worktrees ──────────────────
#
# $SANDBOX and wt/101 are both lane homes at this point, so every sweep below
# needs TALOS_SWEEP_ALL_LANES=1 to actually run (matches the interlock tested
# above -- it is not being re-tested here).

# A harness worktree with zero commits ahead of its base and no uncommitted
# changes is swept.
git worktree add -q -b worktree-agent-h1 "$SANDBOX/wt/h1" >/dev/null 2>&1
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a clean harness worktree exits 0"
assert_contains "$out" "swept harness worktree" "sweep reports the swept harness worktree"
assert_file_absent "$SANDBOX/wt/h1" "sweep removes a clean harness worktree"

# A harness worktree with uncommitted changes is preserved and listed.
git worktree add -q -b worktree-agent-h2 "$SANDBOX/wt/h2" >/dev/null 2>&1
echo "scratch" > "$SANDBOX/wt/h2/scratch.txt"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a dirty harness worktree exits 0"
assert_contains "$out" "preserving harness worktree" "sweep preserves a dirty harness worktree"
assert_contains "$out" "wt/h2" "sweep lists the preserved dirty harness worktree's path"
assert_file_exists "$SANDBOX/wt/h2/scratch.txt" "sweep leaves the dirty harness worktree's file intact"
assert_contains "$(git worktree list)" "wt/h2" "sweep does not remove the dirty harness worktree"
# Clean up directly (bypassing the tool under test) so later count-based
# assertions start from a known baseline.
rm -f "$SANDBOX/wt/h2/scratch.txt"
git worktree remove --force "$SANDBOX/wt/h2" 2>/dev/null
git branch -D worktree-agent-h2 >/dev/null 2>&1

# A harness worktree with commits ahead of its base (no upstream configured,
# so the base falls back to the repo's default branch) is preserved and
# listed -- this is the "unpushed work" case.
git worktree add -q -b worktree-agent-h3 "$SANDBOX/wt/h3" >/dev/null 2>&1
git -C "$SANDBOX/wt/h3" commit -q --allow-empty -m "agent work"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with an ahead harness worktree exits 0"
assert_contains "$out" "preserving harness worktree" "sweep preserves a harness worktree with unpushed commits"
assert_contains "$out" "wt/h3" "sweep lists the preserved ahead harness worktree's path"
assert_contains "$(git worktree list)" "wt/h3" "sweep does not remove the ahead harness worktree"
git worktree remove --force "$SANDBOX/wt/h3" 2>/dev/null
git branch -D worktree-agent-h3 >/dev/null 2>&1

# A harness worktree whose directory no longer exists (prunable) is reclaimed
# regardless of ahead/dirty state, and no longer appears in `git worktree list`.
git worktree add -q -b worktree-agent-h4 "$SANDBOX/wt/h4" >/dev/null 2>&1
rm -rf "$SANDBOX/wt/h4"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a prunable harness worktree exits 0"
assert_contains "$out" "reclaimed prunable harness worktree" "sweep reports reclaiming the prunable harness worktree"
assert_not_contains "$(git worktree list)" "wt/h4" "sweep drops the prunable harness worktree from git"

# ── QA regression (#170): deleted+pruned upstream must not read as "not ahead"
#
# The buggy `_ahead_of_base` compared `[ -z "$base" ]` against the output of a
# bare `git rev-parse --symbolic-full-name "$branch@{upstream}"`. Without
# --verify, that command prints the literal, unresolved "$branch@{upstream}"
# token to stdout on failure (exit 128) instead of leaving it empty, so the
# fallback-to-default-branch check never fired. The bogus token was then fed
# to `git rev-list --count` as a ref, which failed silently (stderr
# redirected), and the empty result read back as "0 commits ahead" -- sweeping
# a worktree with a real, unpushed commit. This reproduces that exact
# scenario: upstream configured, then the remote branch deleted and pruned
# (the tracking ref is gone; `branch.<name>.merge`/`.remote` config is left
# stale, exactly as a real `git remote prune` leaves it).
git worktree add -q -b worktree-agent-h5 "$SANDBOX/wt/h5" >/dev/null 2>&1
base_sha="$(git -C "$SANDBOX/wt/h5" rev-parse HEAD)"
git update-ref refs/remotes/origin/worktree-agent-h5 "$base_sha"
git branch --set-upstream-to=origin/worktree-agent-h5 worktree-agent-h5 >/dev/null 2>&1
git -C "$SANDBOX/wt/h5" commit -q --allow-empty -m "agent work"
git update-ref -d refs/remotes/origin/worktree-agent-h5
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a harness worktree whose upstream was deleted+pruned exits 0"
assert_contains "$out" "preserving harness worktree" "sweep preserves a harness worktree whose upstream was deleted and pruned"
assert_contains "$out" "wt/h5" "sweep lists the path of the worktree with a deleted+pruned upstream"
assert_contains "$(git worktree list)" "wt/h5" "sweep does not remove the worktree with a deleted+pruned upstream"
git worktree remove --force "$SANDBOX/wt/h5" 2>/dev/null
git branch -D worktree-agent-h5 >/dev/null 2>&1

# ── ahead-count computation failure always fails safe (preserve) ────────────
#
# Whatever the cause, a failed `git rev-list --count` must never be read back
# as "0 commits ahead" -- an uncomputable count is preserved, not swept. Force
# the failure deterministically with a `git` shim that fails only `rev-list`
# calls (opted into via an env var), leaving every other git call (worktree
# list, status, symbolic-ref, ...) untouched.
REAL_GIT="$(command -v git)"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "rev-list" ] && [ -n "\${TALOS_TEST_FORCE_REV_LIST_FAIL:-}" ]; then
  exit 1
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$SANDBOX/bin/git"
git worktree add -q -b worktree-agent-h6 "$SANDBOX/wt/h6" >/dev/null 2>&1
out="$(PATH="$SANDBOX/bin:$PATH" TALOS_TEST_FORCE_REV_LIST_FAIL=1 TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a forced ahead-count failure exits 0"
assert_contains "$out" "preserving harness worktree" "sweep preserves a worktree when the ahead-count computation itself fails"
assert_contains "$out" "wt/h6" "sweep lists the path of the worktree whose ahead-count computation failed"
assert_contains "$(git worktree list)" "wt/h6" "sweep does not remove the worktree when the ahead-count computation fails"
git worktree remove --force "$SANDBOX/wt/h6" 2>/dev/null
git branch -D worktree-agent-h6 >/dev/null 2>&1

# ── reviewer finding 1 (#170 round 2): broken worktree fails safe ──────────
#
# `_preserve_reason`'s old dirty check was `[ -n "$(git status --porcelain)" ]`
# -- it looked only at stdout and ignored `git status`'s exit code. A worktree
# whose `git status --porcelain` itself fails (corrupted worktree metadata,
# permission error, etc.) also prints nothing to stdout, which read back
# identical to a genuinely clean tree and let it be force-removed with no
# trace. Simulate a broken worktree by truncating its `.git` file (for a
# linked worktree this is a file pointing at the real repo's metadata, not a
# directory) -- `git -C <path> status` then fails outright.
git worktree add -q -b worktree-agent-broken "$SANDBOX/wt/broken" >/dev/null 2>&1
: > "$SANDBOX/wt/broken/.git"
assert_eq "" "$(git -C "$SANDBOX/wt/broken" status --porcelain 2>/dev/null)" "sanity: the broken worktree's git status prints nothing to stdout"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a broken worktree exits 0"
assert_contains "$out" "preserving harness worktree" "sweep preserves a worktree whose git status itself fails"
assert_contains "$out" "status failed" "sweep names the reason as a status failure, not a guessed clean tree"
assert_contains "$out" "wt/broken" "sweep lists the path of the broken worktree"
assert_contains "$(git worktree list)" "wt/broken" "sweep does not remove the broken worktree"
# cleanup: the corrupted .git file makes `worktree remove` itself unreliable,
# so drop the directory directly and let `git worktree prune` reconcile it.
rm -rf "$SANDBOX/wt/broken"
git worktree prune 2>/dev/null || true
git branch -D worktree-agent-broken >/dev/null 2>&1

# ── End-of-run sweep: issue-pattern worktrees with uncommitted changes ──────
#
# Extends the earlier "sweep with no keep list reclaims everything" case,
# which assumed no dirty state: an issue-pattern worktree with uncommitted
# changes must survive `sweep` even when its id is not in the keep list.
git worktree add -q -b fix/issue-201-dirty "$SANDBOX/wt/201" >/dev/null 2>&1
echo "wip" > "$SANDBOX/wt/201/wip.txt"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a dirty issue worktree (no keep list) exits 0"
assert_contains "$out" "preserving worktree for issue #201" "sweep preserves a dirty issue worktree not in the keep list"
assert_file_exists "$SANDBOX/wt/201/wip.txt" "sweep leaves the dirty issue worktree's file intact"
assert_contains "$(git worktree list)" "wt/201" "sweep does not remove the dirty issue worktree"
rm -f "$SANDBOX/wt/201/wip.txt"
git worktree remove --force "$SANDBOX/wt/201" 2>/dev/null
git branch -D fix/issue-201-dirty >/dev/null 2>&1

# ── reviewer finding 2 (#170 round 2): committed-but-never-pushed issue work ─
#
# `_ahead_of_upstream` used to `return 1` ("not ahead") whenever no upstream
# was configured at all -- a fail-OPEN default the code comment justified only
# for the just-merged `remove <N>` case. But `sweep`'s issue-pattern loop
# reused it unmodified for every orphaned worktree, including one that was
# interrupted (crash, or simply no PR opened yet) after making real local
# commits and before ever pushing. Such a worktree is not dirty (already
# committed) and, under the old logic, not "ahead" either (no upstream to
# diff against) -- both guards passed and `sweep` deleted it, losing the only
# copy of that work. The fix folds `_ahead_of_upstream` into `_ahead_of_base`:
# no upstream now falls back to comparing against the repo's default branch,
# exactly like harness worktrees already did.

# No upstream configured, with a real commit ahead of the default branch:
# preserved and listed.
git worktree add -q -b fix/issue-401-neverpushed "$SANDBOX/wt/401" >/dev/null 2>&1
git -C "$SANDBOX/wt/401" commit -q --allow-empty -m "never pushed work"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a never-pushed issue worktree (ahead of base) exits 0"
assert_contains "$out" "preserving worktree for issue #401" "sweep preserves a committed-but-never-pushed issue worktree"
assert_contains "$out" "wt/401" "sweep lists the path of the never-pushed issue worktree"
assert_contains "$(git worktree list)" "wt/401" "sweep does not remove the never-pushed issue worktree"
git worktree remove --force "$SANDBOX/wt/401" 2>/dev/null
git branch -D fix/issue-401-neverpushed >/dev/null 2>&1

# No upstream configured, but level with the default branch (no local
# commits beyond it): safe to remove -- this is the ordinary "worktree
# created, nothing done yet" case, not lost work.
git worktree add -q -b fix/issue-402-neverpushed-clean "$SANDBOX/wt/402" >/dev/null 2>&1
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a never-pushed, level-with-base issue worktree exits 0"
assert_contains "$out" "swept orphaned worktree for issue #402" "sweep removes a never-pushed issue worktree that is level with the default branch"
assert_file_absent "$SANDBOX/wt/402" "sweep drops the level-with-base issue worktree's directory"

# ── remove <N>: the just-merged path still works (unaffected by the round-2
# unification of _ahead_of_upstream/_ahead_of_base) ─────────────────────────
#
# The ordinary case remove <N> depends on: pushed, upstream still resolvable,
# local branch level with it (0 commits ahead) -> removed, not preserved.
git worktree add -q -b fix/issue-403-merged "$SANDBOX/wt/403" >/dev/null 2>&1
merged_sha="$(git -C "$SANDBOX/wt/403" rev-parse HEAD)"
git update-ref refs/remotes/origin/fix/issue-403-merged "$merged_sha"
git branch --set-upstream-to=origin/fix/issue-403-merged fix/issue-403-merged >/dev/null 2>&1
out="$(bash "$WT" remove 403)"; rc=$?
assert_eq "0" "$rc" "remove 403 exits 0"
assert_contains "$out" "removed worktree for issue #403" "remove still removes a merged, upstream-level branch after the round-2 unification"
assert_file_absent "$SANDBOX/wt/403" "remove deletes the merged worktree directory"
git update-ref -d refs/remotes/origin/fix/issue-403-merged 2>/dev/null || true

# ── git worktree prune always runs, even when nothing matches for removal ───
#
# Only wt/101 (lane home) remains at this point besides $SANDBOX itself, so
# neither of sweep's own loops has anything to act on. A worktree on a branch
# that matches NEITHER pattern is invisible to those loops -- if it still gets
# dropped, that can only be the trailing, unconditional `git worktree prune`.
git worktree add -q -b scratch/not-managed "$SANDBOX/wt/scratch1" >/dev/null 2>&1
rm -rf "$SANDBOX/wt/scratch1"
assert_contains "$(git worktree list --porcelain)" "prunable" "the unmanaged worktree is prunable before sweep"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with only lane-home/self worktrees present exits 0"
assert_not_contains "$(git worktree list)" "wt/scratch1" "sweep's trailing git worktree prune reclaims an unrelated prunable worktree"
git branch -D scratch/not-managed >/dev/null 2>&1

# ── list: threshold warning ───────────────────────────────────────────────────

# Default threshold is 10. 11 stale worktrees (301..311) trips the warning.
for i in $(seq 301 311); do
  git worktree add -q -b "fix/issue-$i-stale" "$SANDBOX/wt/$i" >/dev/null 2>&1
done
out="$(bash "$WT" list)"
assert_contains "$out" "WARNING" "list warns when stale worktree count (11) exceeds the default threshold (10)"
assert_contains "$out" "exceed threshold 10" "list's warning names the default threshold"

# Drop to exactly the threshold: no warning.
git worktree remove --force "$SANDBOX/wt/311" >/dev/null 2>&1
git branch -D fix/issue-311-stale >/dev/null 2>&1
out="$(bash "$WT" list)"
assert_not_contains "$out" "WARNING" "list does not warn at exactly the default threshold (10)"

# A configured override (execution.worktree_warn_threshold) replaces the
# default. Count is still 10 (301..310); threshold 9 -> warns.
cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"execution": {"worktree_warn_threshold": 9}}
EOF
out="$(bash "$WT" list)"
assert_contains "$out" "WARNING" "list warns above a configured threshold override (9, count 10)"
assert_contains "$out" "exceed threshold 9" "list's warning names the configured threshold"

# Drop to exactly the configured threshold: no warning.
git worktree remove --force "$SANDBOX/wt/310" >/dev/null 2>&1
git branch -D fix/issue-310-stale >/dev/null 2>&1
out="$(bash "$WT" list)"
assert_not_contains "$out" "WARNING" "list does not warn at exactly a configured threshold override (9, count 9)"
rm -f "$SANDBOX/talos.pipeline.json"

# ── create <n> <branch>: creates a worktree and writes .talos/env (#186) ────
# .talos/ is gitignored in the real Talos repo (production usage); mirror
# that here — committed to HEAD so `create`'s new worktree (branched off
# HEAD) sees it too — so the created worktree's .talos/env doesn't read as
# "dirty" for the safety check in `remove`/`sweep` below, same as production.
printf '.talos/\n' >> "$SANDBOX/.gitignore"
git add .gitignore >/dev/null
git commit -q -m "gitignore .talos/"
out="$(bash "$WT" create 555 fix/issue-555-mechanical-env)"; rc=$?
assert_eq "0" "$rc" "create exits 0"
new_wt="$out"
assert_contains "$(git worktree list)" "$new_wt" "create adds a real git worktree at the printed path"
assert_contains "$(git -C "$new_wt" branch --show-current)" "fix/issue-555-mechanical-env" "create checks out the requested new branch"
assert_file_exists "$new_wt/.talos/env" "create writes <worktree>/.talos/env"
env_contents="$(cat "$new_wt/.talos/env")"
assert_contains "$env_contents" "TALOS_ISSUE_NUMBER=555" ".talos/env has a TALOS_ISSUE_NUMBER=<n> line"
assert_contains "$env_contents" "TALOS_WORKTREE_PATH=$new_wt" ".talos/env has a TALOS_WORKTREE_PATH=<path> line matching the worktree's own path"
assert_not_contains "$env_contents" "export " ".talos/env is written as plain KEY=value, not shell 'export' lines (#186 security fix -- the reader parses, never sources, this file)"

# .talos/env is per-worktree, not the shared main-repo .talos/ (distinct
# from events.jsonl's git-common-dir resolution) -- the main checkout must
# not have gained one as a side effect of creating an issue worktree.
assert_file_absent "$SANDBOX/.talos/env" "create does not write .talos/env into the main checkout"

# create is cleaned up normally by remove/sweep like any other issue worktree.
out2="$(bash "$WT" remove 555)"
assert_contains "$out2" "removed worktree for issue #555" "remove cleans up a worktree created by create"

# ── create acquires the repo lock like remove/sweep (#180 review) ──────────
# Structural guard: the dispatch line itself wraps _wt_create_body in with_lock.
if grep -q 'with_lock "\$_WT_LOCK_RESOURCE" 10 -- _wt_create_body' "$WT"; then
  pass "create dispatches through with_lock like remove/sweep"
else
  fail "create dispatches through with_lock like remove/sweep" \
       "no with_lock wrapping found for _wt_create_body in $WT"
fi

# Functional guard: hold the same lock resource from a background holder,
# then run create and confirm it waits for the lock to free instead of
# racing git worktree add against it (the #180 race this closes).
LOCK_SH="$TALOS_ROOT/scripts/pipeline-lock.sh"
LOCK_RESOURCE="$(git rev-parse --git-common-dir)/talos-worktree"
(
  . "$LOCK_SH"
  _lock_acquire "$LOCK_RESOURCE" 5 >/dev/null 2>&1
  sleep 1.5
) &
holder_pid=$!
sleep 0.3   # let the holder actually acquire before create starts waiting
start_ts=$(date +%s)
out3="$(bash "$WT" create 556 fix/issue-556-lock-wait)"; rc3=$?
end_ts=$(date +%s)
wait "$holder_pid" 2>/dev/null
assert_eq "0" "$rc3" "create still succeeds after the held lock is released"
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -ge 1 ]; then
  pass "create waited for the held lock instead of racing it (elapsed ${elapsed}s)"
else
  fail "create waited for the held lock instead of racing it" "elapsed only ${elapsed}s"
fi
bash "$WT" remove 556 >/dev/null 2>&1

finish
