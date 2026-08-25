#!/usr/bin/env bash
# test-isolation.sh — execution.isolation startup validation (#98)
#
# Tests:
#   1. pipeline-config.sh: absent key returns "worktree" as default value.
#   2. validate with no config resolves to worktree (mode reported + exit 0).
#   3. branch + max_parallel:1 → resolved: branch, exit 0.
#   4. branch + max_parallel:2 → exit 1, message contains "max_parallel" and "1".
#   5. checkout → exit 1, message contains "not yet implemented".
#   6. Unknown mode → exit 1, message lists valid values.
#   7. pipeline-worktree.sh: remove with no matching worktree exits 0 ("already clean").
#   8. Absent config: validate resolves to worktree (mode reported + exit 0).
#
# Mutation-3 guard: tests 2 and 8 assert the stdout text "resolved: worktree".
# Changing the default to "branch" causes both to FAIL with:
#   missing: resolved: worktree | in: resolved: branch
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

ISO="$TALOS_ROOT/scripts/pipeline-isolation.sh"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"

# Sandbox has no config file — set up a minimal git identity for commits later.
git config user.email "test@talos"
git config user.name "talos test"
git commit -q --allow-empty -m "root"

# ── 1. pipeline-config.sh: absent key returns "worktree" ─────────────────────
# Scope: pipeline-config.sh only. Confirms the fallback argument works.
out="$(bash "$CFG" execution.isolation worktree)"
assert_eq "worktree" "$out" "[pipeline-config.sh] absent execution.isolation key returns default worktree"

# ── 2. validate with no config resolves to worktree ──────────────────────────
# Scope: pipeline-isolation.sh. Must emit "resolved: worktree" on stdout.
# Mutation-3 guard: if default becomes "branch", this assertion fires.
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "validate exits 0 with no config (defaults to worktree)"
assert_contains "$out" "resolved: worktree" "validate reports resolved mode as worktree when key absent"

# ── 3. branch + max_parallel:1 → resolved: branch, exit 0 ───────────────────
# JSON config: no PyYAML required (stdlib json module parses it).
printf '{"execution":{"isolation":"branch"},"issues":{"max_parallel":1}}' > talos.pipeline.json
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "branch + max_parallel:1 exits 0"
assert_contains "$out" "resolved: branch" "branch + max_parallel:1 reports resolved mode as branch"
rm -f talos.pipeline.json

# ── 4. branch + max_parallel:2 → exit 1, message mentions max_parallel ───────
printf '{"execution":{"isolation":"branch"},"issues":{"max_parallel":2}}' > talos.pipeline.json
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "1" "$rc" "branch + max_parallel:2 exits 1"
assert_contains "$out" "max_parallel" "branch+max_parallel>1 error mentions max_parallel"
assert_contains "$out" "1" "branch+max_parallel>1 error mentions the required value (1)"
rm -f talos.pipeline.json

# ── 5. checkout → exit 1, message contains "not yet implemented" ─────────────
printf '{"execution":{"isolation":"checkout"}}' > talos.pipeline.json
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "1" "$rc" "checkout exits 1"
assert_contains "$out" "not yet implemented" "checkout error says 'not yet implemented'"
rm -f talos.pipeline.json

# ── 6. Unknown mode → exit 1, valid values listed in message ─────────────────
printf '{"execution":{"isolation":"bogus"}}' > talos.pipeline.json
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "1" "$rc" "unknown mode 'bogus' exits 1"
assert_contains "$out" "worktree" "unknown-mode error lists worktree as valid"
assert_contains "$out" "branch" "unknown-mode error lists branch as valid"
rm -f talos.pipeline.json

# ── 7. pipeline-worktree.sh: remove with no matching worktree exits 0 ────────
# Scope: pipeline-worktree.sh. No worktree for issue 98 exists — remove must
# exit 0 and report "already clean". This is a worktree-script integration
# check, not a pipeline-isolation.sh test.
out="$(bash "$WT" remove 98 2>&1)"; rc=$?
assert_eq "0" "$rc" "[pipeline-worktree.sh] remove (no matching worktree) exits 0"
assert_contains "$out" "already clean" "[pipeline-worktree.sh] remove says 'already clean' when no worktree exists"

# ── 8. Absent config: validate resolves to worktree ──────────────────────────
# Mutation-3 guard: if default becomes "branch", this assertion fires.
# Ensure no config file is present.
rm -f talos.pipeline.json talos.pipeline.yml talos.pipeline.yaml
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "absent config treated as worktree, exits 0"
assert_contains "$out" "resolved: worktree" "absent config: validate reports resolved mode as worktree"

finish
