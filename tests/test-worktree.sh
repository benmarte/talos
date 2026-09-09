#!/usr/bin/env bash
# test-worktree.sh — pipeline-worktree.sh lifecycle against real git worktrees.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs   # puts the gh stub on PATH -- sweep's branch cleanup (#240) queries
            # `pipeline-vcs.sh list-prs`, which shells out to `gh`.

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"

# make_sandbox git-inits and cds into $SANDBOX. Give it an identity + a commit
# so we can branch worktrees off HEAD.
git config user.email "test@talos"
git config user.name "talos test"
git commit -q --allow-empty -m "root"

# .talos/ is gitignored in the real Talos repo (production usage); mirror
# that here, BEFORE any worktree exists, so every worktree `git worktree add`
# branches off HEAD from this point on -- including ones created by `tag`,
# not just `create` -- and none of them read as "dirty" for the
# _preserve_reason safety check just because `tag` wrote a per-worktree
# .talos/env file into an untracked directory.
printf '.talos/\n' > "$SANDBOX/.gitignore"
git add .gitignore >/dev/null
git commit -q -m "gitignore .talos/"

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

# ── #240: sweep no longer preserves dirty/unpushed worktrees on their own ───
#
# Policy change (issue #240): the ONLY thing that keeps a worktree alive
# across `sweep` is being identified (developer pattern, or the `tag <N>`
# file) with an id in the keep list the caller passes -- i.e. an issue the
# orchestrator says is still open. Dirty scratch and unpushed commits no
# longer preserve a worktree by themselves; that safety net stays in place
# for `remove <N>` only (tested further below via `tag` + `remove`), which
# targets exactly one issue instead of repo-wide sweeping everything not in
# the queue.
#
# $SANDBOX and wt/101 are both lane homes at this point, so every sweep below
# needs TALOS_SWEEP_ALL_LANES=1 to actually run (matches the interlock tested
# above -- it is not being re-tested here).

# A harness (Claude Code agent-*) worktree that was never tagged is removed
# by sweep regardless of whether it is clean, dirty, or has commits ahead of
# its base -- there is no id to check against the (empty) keep list, so it
# counts as "not open".
git worktree add -q -b agent-h1-clean "$SANDBOX/wt/h1" >/dev/null 2>&1
git worktree add -q -b agent-h2-dirty "$SANDBOX/wt/h2" >/dev/null 2>&1
echo "scratch" > "$SANDBOX/wt/h2/scratch.txt"
git worktree add -q -b agent-h3-ahead "$SANDBOX/wt/h3" >/dev/null 2>&1
git -C "$SANDBOX/wt/h3" commit -q --allow-empty -m "agent work, never pushed"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with untagged harness worktrees (clean/dirty/ahead) exits 0"
assert_contains "$out" "swept unidentified worktree" "sweep reports sweeping an untagged harness worktree"
assert_file_absent "$SANDBOX/wt/h1" "sweep removes a clean untagged harness worktree"
assert_file_absent "$SANDBOX/wt/h2" "sweep removes a DIRTY untagged harness worktree (no longer preserved)"
assert_file_absent "$SANDBOX/wt/h3" "sweep removes an untagged harness worktree with unpushed commits (no longer preserved)"
assert_not_contains "$(git worktree list)" "wt/h1" "sweep drops the clean harness worktree from git"
assert_not_contains "$(git worktree list)" "wt/h2" "sweep drops the dirty harness worktree from git"
assert_not_contains "$(git worktree list)" "wt/h3" "sweep drops the ahead harness worktree from git"

# A harness worktree TAGGED to an id in the keep list is preserved by sweep
# regardless of dirty/unpushed state -- the new fail-safe is narrower
# (tagged-and-open only) but absolute for that case.
git worktree add -q -b agent-h4-tagged "$SANDBOX/wt/h4" >/dev/null 2>&1
(cd "$SANDBOX/wt/h4" && bash "$WT" tag 77 >/dev/null)
echo "scratch" > "$SANDBOX/wt/h4/scratch.txt"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep 77)"; rc=$?
assert_eq "0" "$rc" "sweep with a tagged-and-open harness worktree exits 0"
assert_contains "$out" "keeping worktree for issue #77" "sweep reports keeping the tagged-and-open harness worktree"
assert_file_exists "$SANDBOX/wt/h4/scratch.txt" "sweep leaves the tagged-and-open harness worktree's scratch file intact"
assert_contains "$(git worktree list)" "wt/h4" "sweep does not remove a tagged-and-open harness worktree"
# ...but the same worktree is removed once 77 is no longer in the keep list.
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_contains "$out" "swept worktree for issue #77" "sweep removes a tagged harness worktree once its id leaves the keep list"
assert_file_absent "$SANDBOX/wt/h4" "sweep drops the now-unkept tagged harness worktree's directory"

# A prunable harness worktree (directory already gone) is always reclaimed.
git worktree add -q -b agent-h5-prunable "$SANDBOX/wt/h5" >/dev/null 2>&1
rm -rf "$SANDBOX/wt/h5"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with a prunable harness worktree exits 0"
assert_contains "$out" "reclaimed prunable worktree" "sweep reports reclaiming the prunable harness worktree"
assert_not_contains "$(git worktree list)" "wt/h5" "sweep drops the prunable harness worktree from git"

# The developer pattern is identified the same way and follows the same
# rule: not in the keep list -> removed even when dirty/never pushed; in the
# keep list -> kept regardless.
git worktree add -q -b fix/issue-501-dirty "$SANDBOX/wt/501" >/dev/null 2>&1
echo "wip" > "$SANDBOX/wt/501/wip.txt"
git worktree add -q -b fix/issue-502-kept "$SANDBOX/wt/502" >/dev/null 2>&1
git -C "$SANDBOX/wt/502" commit -q --allow-empty -m "never pushed, but issue is open"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep 502)"; rc=$?
assert_eq "0" "$rc" "sweep with a mix of open/closed developer worktrees exits 0"
assert_file_absent "$SANDBOX/wt/501" "sweep removes a dirty developer worktree whose id is not in the keep list"
assert_contains "$(git worktree list)" "wt/502" "sweep keeps a developer worktree (with unpushed commits) whose id IS in the keep list"
git worktree remove --force "$SANDBOX/wt/502" 2>/dev/null
git branch -D fix/issue-502-kept >/dev/null 2>&1

# ── `remove <N>` keeps the old dirty/unpushed fail-safe (#170/#170-round-2) ──
#
# #240 narrows `sweep`'s safety net to "tagged and open"; `remove <N>` is
# unaffected and still refuses to delete a worktree it can't prove is safe --
# now reachable for HARNESS worktrees too, via `tag`, since `remove` matches
# on _wt_issue_of exactly like `sweep` does.

# Dirty: preserved.
git worktree add -q -b agent-r1-dirty "$SANDBOX/wt/r1" >/dev/null 2>&1
(cd "$SANDBOX/wt/r1" && bash "$WT" tag 601 >/dev/null)
echo "scratch" > "$SANDBOX/wt/r1/scratch.txt"
out="$(bash "$WT" remove 601)"; rc=$?
assert_eq "0" "$rc" "remove on a dirty tagged harness worktree exits 0"
assert_contains "$out" "preserving worktree for issue #601" "remove preserves a dirty tagged harness worktree"
assert_contains "$out" "dirty" "remove names the dirty reason"
assert_file_exists "$SANDBOX/wt/r1/scratch.txt" "remove leaves the dirty tagged harness worktree's file intact"
rm -f "$SANDBOX/wt/r1/scratch.txt" "$SANDBOX/wt/r1/.talos/env"
git worktree remove --force "$SANDBOX/wt/r1" 2>/dev/null
git branch -D agent-r1-dirty >/dev/null 2>&1

# Ahead of base (no upstream configured): preserved. Regression coverage for
# the #170 bug where "no upstream" used to read as "not ahead" (fail-open)
# instead of falling back to the default branch.
git worktree add -q -b agent-r2-ahead "$SANDBOX/wt/r2" >/dev/null 2>&1
(cd "$SANDBOX/wt/r2" && bash "$WT" tag 602 >/dev/null)
git -C "$SANDBOX/wt/r2" commit -q --allow-empty -m "agent work"
out="$(bash "$WT" remove 602)"; rc=$?
assert_eq "0" "$rc" "remove on an ahead-of-base tagged harness worktree exits 0"
assert_contains "$out" "preserving worktree for issue #602" "remove preserves a tagged harness worktree with unpushed commits"
assert_contains "$(git worktree list)" "wt/r2" "remove does not remove the ahead-of-base tagged harness worktree"
git worktree remove --force "$SANDBOX/wt/r2" 2>/dev/null
git branch -D agent-r2-ahead >/dev/null 2>&1

# Upstream configured, then deleted+pruned (#170 regression): still preserved
# -- the stale tracking config must not silently read back as "not ahead".
git worktree add -q -b agent-r3-stale-upstream "$SANDBOX/wt/r3" >/dev/null 2>&1
(cd "$SANDBOX/wt/r3" && bash "$WT" tag 603 >/dev/null)
base_sha="$(git -C "$SANDBOX/wt/r3" rev-parse HEAD)"
git update-ref refs/remotes/origin/agent-r3-stale-upstream "$base_sha"
git branch --set-upstream-to=origin/agent-r3-stale-upstream agent-r3-stale-upstream >/dev/null 2>&1
git -C "$SANDBOX/wt/r3" commit -q --allow-empty -m "agent work"
git update-ref -d refs/remotes/origin/agent-r3-stale-upstream
out="$(bash "$WT" remove 603)"; rc=$?
assert_eq "0" "$rc" "remove on a tagged harness worktree with a deleted+pruned upstream exits 0"
assert_contains "$out" "preserving worktree for issue #603" "remove preserves a tagged harness worktree whose upstream was deleted and pruned"
assert_contains "$(git worktree list)" "wt/r3" "remove does not remove the deleted+pruned-upstream tagged harness worktree"
git worktree remove --force "$SANDBOX/wt/r3" 2>/dev/null
git branch -D agent-r3-stale-upstream >/dev/null 2>&1
git update-ref -d refs/remotes/origin/agent-r3-stale-upstream 2>/dev/null || true

# The ahead-count computation itself failing (not just an unresolvable
# upstream) must also fail safe -- preserved, never read back as "0 commits
# ahead". Force it deterministically with a `git` shim that fails only
# `rev-list` calls (opted into via an env var), leaving every other git call
# (worktree list, status, symbolic-ref, ...) untouched.
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
git worktree add -q -b agent-r5-revlistfail "$SANDBOX/wt/r5" >/dev/null 2>&1
(cd "$SANDBOX/wt/r5" && bash "$WT" tag 605 >/dev/null)
out="$(PATH="$SANDBOX/bin:$PATH" TALOS_TEST_FORCE_REV_LIST_FAIL=1 bash "$WT" remove 605)"; rc=$?
assert_eq "0" "$rc" "remove with a forced ahead-count failure exits 0"
assert_contains "$out" "preserving worktree for issue #605" "remove preserves a tagged harness worktree when the ahead-count computation itself fails"
assert_contains "$(git worktree list)" "wt/r5" "remove does not remove the worktree when the ahead-count computation fails"
git worktree remove --force "$SANDBOX/wt/r5" 2>/dev/null
git branch -D agent-r5-revlistfail >/dev/null 2>&1

# A broken worktree (git status itself fails) fails safe -- preserved, named
# "status failed", not guessed clean.
git worktree add -q -b agent-r4-broken "$SANDBOX/wt/r4" >/dev/null 2>&1
(cd "$SANDBOX/wt/r4" && bash "$WT" tag 604 >/dev/null)
: > "$SANDBOX/wt/r4/.git"
out="$(bash "$WT" remove 604)"; rc=$?
assert_eq "0" "$rc" "remove on a broken tagged harness worktree exits 0"
assert_contains "$out" "preserving worktree for issue #604" "remove preserves a tagged harness worktree whose git status itself fails"
assert_contains "$out" "status failed" "remove names the reason as a status failure, not a guessed clean tree"
rm -rf "$SANDBOX/wt/r4"
git worktree prune 2>/dev/null || true
git branch -D agent-r4-broken >/dev/null 2>&1

# ── `remove <N>` still works for the ordinary just-merged path ─────────────
git worktree add -q -b fix/issue-403-merged "$SANDBOX/wt/403" >/dev/null 2>&1
merged_sha="$(git -C "$SANDBOX/wt/403" rev-parse HEAD)"
git update-ref refs/remotes/origin/fix/issue-403-merged "$merged_sha"
git branch --set-upstream-to=origin/fix/issue-403-merged fix/issue-403-merged >/dev/null 2>&1
out="$(bash "$WT" remove 403)"; rc=$?
assert_eq "0" "$rc" "remove 403 exits 0"
assert_contains "$out" "removed worktree for issue #403" "remove still removes a merged, upstream-level branch"
assert_file_absent "$SANDBOX/wt/403" "remove deletes the merged worktree directory"
git update-ref -d refs/remotes/origin/fix/issue-403-merged 2>/dev/null || true

# ── `remove <N>` also removes a HARNESS worktree tagged to N (#240 core) ────
git worktree add -q -b agent-405-tagged "$SANDBOX/wt/405" >/dev/null 2>&1
(cd "$SANDBOX/wt/405" && bash "$WT" tag 405 >/dev/null)
out="$(bash "$WT" remove 405)"; rc=$?
assert_eq "0" "$rc" "remove 405 (harness worktree tagged to 405) exits 0"
assert_contains "$out" "removed worktree for issue #405" "remove removes a tagged harness worktree by issue number"
assert_file_absent "$SANDBOX/wt/405" "remove deletes the tagged harness worktree's directory"
assert_eq "" "$(git branch --list agent-405-tagged)" "remove deletes the tagged harness worktree's local branch"

# ── git worktree prune always runs, even when nothing matches for removal ───
#
# Only wt/101 (lane home) remains at this point besides $SANDBOX itself, so
# the sweep loop has nothing left to act on. A worktree on a branch that
# matches no pattern and was never tagged is still identified (as
# "unidentified") and swept by the main loop now -- the trailing,
# unconditional `git worktree prune` remains as a backstop for anything that
# slips past it (e.g. a worktree git itself already considers prunable).
git worktree add -q -b scratch/not-managed "$SANDBOX/wt/scratch1" >/dev/null 2>&1
rm -rf "$SANDBOX/wt/scratch1"
assert_contains "$(git worktree list --porcelain)" "prunable" "the unmanaged worktree is prunable before sweep"
out="$(TALOS_SWEEP_ALL_LANES=1 bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep with only lane-home/self worktrees present exits 0"
assert_not_contains "$(git worktree list)" "wt/scratch1" "sweep reclaims an unrelated prunable worktree"
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
# .talos/ was gitignored at the very top of this file (before any worktree
# was created), so `create`'s new worktree (branched off HEAD) already sees
# it -- its .talos/env doesn't read as "dirty" for the safety check in
# `remove`/`sweep`, same as production.
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

# ── tag <n>: writes .talos/env, refuses in the main worktree (#240) ─────────

out="$(bash "$WT" tag 900 2>&1)"; rc=$?
assert_eq "1" "$rc" "tag exits 1 in the main worktree"
assert_contains "$out" "refusing to tag the main worktree" "tag names why it refused"
assert_file_absent "$SANDBOX/.talos/env" "tag does not write .talos/env into the main worktree"

git worktree add -q -b agent-tag-test "$SANDBOX/wt/tagtest" >/dev/null 2>&1
out="$(cd "$SANDBOX/wt/tagtest" && bash "$WT" tag 901)"; rc=$?
assert_eq "0" "$rc" "tag exits 0 in a linked worktree"
assert_contains "$out" "tagged" "tag reports what it tagged"
assert_file_exists "$SANDBOX/wt/tagtest/.talos/env" "tag writes <worktree>/.talos/env"
env_contents="$(cat "$SANDBOX/wt/tagtest/.talos/env")"
assert_contains "$env_contents" "TALOS_ISSUE_NUMBER=901" "tag writes TALOS_ISSUE_NUMBER=<n>"
# Compare against git's own (symlink-resolved) toplevel rather than raw
# $SANDBOX -- on macOS $TMPDIR is itself a symlink, so a literal $SANDBOX
# prefix does not byte-for-byte match the physical path `tag` resolves via
# `git rev-parse --show-toplevel` and writes to the file.
resolved_tagtest="$(git -C "$SANDBOX/wt/tagtest" rev-parse --show-toplevel)"
assert_contains "$env_contents" "TALOS_WORKTREE_PATH=$resolved_tagtest" "tag writes TALOS_WORKTREE_PATH=<path>"
assert_not_contains "$env_contents" "export " "tag writes plain KEY=value, not shell 'export' lines"

# idempotent: re-tagging overwrites, does not append.
out2="$(cd "$SANDBOX/wt/tagtest" && bash "$WT" tag 902)"; rc2=$?
assert_eq "0" "$rc2" "re-tagging the same worktree exits 0"
env_contents2="$(cat "$SANDBOX/wt/tagtest/.talos/env")"
assert_contains "$env_contents2" "TALOS_ISSUE_NUMBER=902" "re-tagging overwrites with the new issue number"
assert_not_contains "$env_contents2" "901" "re-tagging does not leave the old issue number behind"

# invalid (non-numeric) issue number is rejected.
out3="$(cd "$SANDBOX/wt/tagtest" && bash "$WT" tag abc)"; rc3=$?
assert_eq "2" "$rc3" "tag rejects a non-numeric issue number"

git worktree remove --force "$SANDBOX/wt/tagtest" 2>/dev/null
git branch -D agent-tag-test >/dev/null 2>&1

# ── status: counts and total .claude/worktrees size (#240) ──────────────────
# Differential, not absolute -- other sections in this file leave worktrees
# and branches behind at various points, so only the DELTA this section
# itself introduces is asserted.

_status_field() { printf '%s' "$2" | grep -o "$1=[^ ]*" | cut -d= -f2; }

before="$(bash "$WT" status)"
before_wt="$(_status_field worktrees "$before")"
before_dirty="$(_status_field dirty "$before")"
before_br="$(_status_field branches "$before")"

git worktree add -q -b fix/issue-910-status-a "$SANDBOX/wt/910" >/dev/null 2>&1
git worktree add -q -b fix/issue-911-status-b "$SANDBOX/wt/911" >/dev/null 2>&1
echo "wip" > "$SANDBOX/wt/911/wip.txt"

after="$(bash "$WT" status)"
after_wt="$(_status_field worktrees "$after")"
after_dirty="$(_status_field dirty "$after")"
after_br="$(_status_field branches "$after")"

assert_eq "$((before_wt + 2))" "$after_wt" "status counts two newly added worktrees"
assert_eq "$((before_dirty + 1))" "$after_dirty" "status counts exactly one newly-dirty worktree"
assert_eq "$((before_br + 2))" "$after_br" "status counts two newly added local branches"
assert_contains "$after" "size=" "status prints a size= field"

mkdir -p "$SANDBOX/.claude/worktrees"
dd if=/dev/zero of="$SANDBOX/.claude/worktrees/dummy.bin" bs=1024 count=100 >/dev/null 2>&1
size_out="$(bash "$WT" status)"
assert_not_contains "$size_out" "size=0K" "status reports a non-zero size once .claude/worktrees has content"
rm -rf "$SANDBOX/.claude/worktrees"

git worktree remove --force "$SANDBOX/wt/911" 2>/dev/null
git worktree remove --force "$SANDBOX/wt/910" 2>/dev/null
git branch -D fix/issue-910-status-a fix/issue-911-status-b >/dev/null 2>&1

# ── #240 acceptance scenario: full lifecycle in one pass ────────────────────
#
# Fake agent-* harness worktrees: tagged to 1, tagged to 2, untagged+dirty,
# untagged+unpushed. Developer worktrees: issue 1 (open) and issue 3
# (closed). A stale local scratch branch with no worktree at all, plus one
# that happens to be the head of a currently open PR (stubbed via list-prs).

git worktree add -q -b agent-scn-1 "$SANDBOX/wt/scn-agent-1" >/dev/null 2>&1
(cd "$SANDBOX/wt/scn-agent-1" && bash "$WT" tag 1 >/dev/null)

git worktree add -q -b agent-scn-2 "$SANDBOX/wt/scn-agent-2" >/dev/null 2>&1
(cd "$SANDBOX/wt/scn-agent-2" && bash "$WT" tag 2 >/dev/null)

git worktree add -q -b agent-scn-dirty "$SANDBOX/wt/scn-agent-dirty" >/dev/null 2>&1
echo scratch > "$SANDBOX/wt/scn-agent-dirty/leftover.bak"

git worktree add -q -b agent-scn-unpushed "$SANDBOX/wt/scn-agent-unpushed" >/dev/null 2>&1
git -C "$SANDBOX/wt/scn-agent-unpushed" commit -q --allow-empty -m "scratch work, never pushed"

git worktree add -q -b fix/issue-1-scn-dev "$SANDBOX/wt/scn-dev-1" >/dev/null 2>&1
git worktree add -q -b fix/issue-3-scn-dev "$SANDBOX/wt/scn-dev-3" >/dev/null 2>&1

git branch scratch/no-worktree-branch >/dev/null 2>&1
git branch scratch/open-pr-head >/dev/null 2>&1

# remove 3: removes ONLY issue 3's developer worktree -- every other
# worktree in the scenario is untouched.
out="$(bash "$WT" remove 3)"; rc=$?
assert_eq "0" "$rc" "#240 scenario: remove 3 exits 0"
assert_contains "$out" "removed worktree for issue #3" "#240 scenario: remove 3 removes issue 3's worktree"
assert_file_absent "$SANDBOX/wt/scn-dev-3" "#240 scenario: remove 3 deletes issue 3's directory"
wt_listing_after_remove3="$(git worktree list)"
for d in scn-agent-1 scn-agent-2 scn-agent-dirty scn-agent-unpushed scn-dev-1; do
  assert_contains "$wt_listing_after_remove3" "wt/$d" "#240 scenario: remove 3 leaves $d untouched"
done

# sweep 1: keeps BOTH id-1 worktrees (developer + tagged harness); removes
# every other worktree in the scenario, including the dirty and unpushed
# ones; deletes the ownerless scratch branch; keeps the branch that is the
# head of an open PR (stubbed); prints the summary marker.
out="$(TALOS_SWEEP_ALL_LANES=1 STUB_GH_PRS_RAW='[{"number":1,"title":"keep me","head":{"ref":"scratch/open-pr-head"},"base":{"ref":"main"},"labels":[]}]' bash "$WT" sweep 1)"; rc=$?
assert_eq "0" "$rc" "#240 scenario: sweep 1 exits 0"

assert_contains "$(git worktree list)" "wt/scn-dev-1" "#240 scenario: sweep 1 keeps the open developer worktree"
assert_contains "$(git worktree list)" "wt/scn-agent-1" "#240 scenario: sweep 1 keeps the harness worktree tagged to the open id"
assert_file_absent "$SANDBOX/wt/scn-agent-2" "#240 scenario: sweep 1 removes the harness worktree tagged to a closed/unlisted id"
assert_file_absent "$SANDBOX/wt/scn-agent-dirty" "#240 scenario: sweep 1 removes the untagged DIRTY harness worktree"
assert_file_absent "$SANDBOX/wt/scn-agent-unpushed" "#240 scenario: sweep 1 removes the untagged UNPUSHED harness worktree"

assert_eq "" "$(git branch --list scratch/no-worktree-branch)" "#240 scenario: sweep deletes the ownerless scratch branch"
assert_eq "" "$(git branch --list agent-scn-2)" "#240 scenario: sweep deletes the removed worktree's local branch"
assert_eq "scratch/open-pr-head" "$(git branch --list scratch/open-pr-head | tr -d ' *+')" "#240 scenario: sweep keeps the branch that is the head of an open PR"

assert_contains "$out" "talos:worktree-sweep removed=" "#240 scenario: sweep prints the summary marker"
assert_contains "$out" "kept=" "#240 scenario: summary marker includes a kept count"
assert_contains "$out" "freed=" "#240 scenario: summary marker includes a freed size"

git worktree remove --force "$SANDBOX/wt/scn-dev-1" 2>/dev/null
git worktree remove --force "$SANDBOX/wt/scn-agent-1" 2>/dev/null
git branch -D fix/issue-1-scn-dev agent-scn-1 scratch/open-pr-head >/dev/null 2>&1

# ── sweep: a failed list-prs lookup skips branch cleanup entirely (fail safe)
git branch scratch/should-survive-a-failed-lookup >/dev/null 2>&1
out="$(TALOS_SWEEP_ALL_LANES=1 GH_FAIL_STDERR='gh: some transient error' bash "$WT" sweep)"; rc=$?
assert_eq "0" "$rc" "sweep still exits 0 when list-prs fails"
assert_contains "$out" "could not list open PRs" "sweep reports skipping branch cleanup when list-prs fails"
assert_eq "scratch/should-survive-a-failed-lookup" "$(git branch --list scratch/should-survive-a-failed-lookup | tr -d ' *+')" "sweep preserves local branches when the open-PR lookup itself fails"
git branch -D scratch/should-survive-a-failed-lookup >/dev/null 2>&1

finish
