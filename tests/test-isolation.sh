#!/usr/bin/env bash
# test-isolation.sh — execution.isolation startup validation (#98)
#
# Tests:
#   1. Absent key defaults to worktree (byte-identical to today).
#   2. validate exits 0 for worktree (no config).
#   3. branch + max_parallel:1 → exit 0.
#   4. branch + max_parallel:2 → exit 1, message contains "max_parallel" and "1".
#   5. checkout → exit 1, message contains "not yet implemented".
#   6. Unknown mode → exit 1, message lists valid values.
#   7. Worktree remove in non-worktree mode is a no-op (exits 0, "already clean").
#   8. Absent config treated as worktree — validate exits 0.
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

# ── 1. Absent key defaults to worktree ───────────────────────────────────────
out="$(bash "$CFG" execution.isolation worktree)"
assert_eq "worktree" "$out" "absent execution.isolation defaults to worktree"

# ── 2. validate exits 0 with no config (defaults to worktree) ────────────────
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "validate exits 0 with no config (defaults to worktree)"

# ── 3. branch + max_parallel:1 → exit 0 ─────────────────────────────────────
# JSON config: no PyYAML required (stdlib json module parses it).
printf '{"execution":{"isolation":"branch"},"issues":{"max_parallel":1}}' > talos.pipeline.json
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "branch + max_parallel:1 exits 0"
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

# ── 7. Worktree remove in non-worktree mode is a no-op ───────────────────────
# No worktree for issue 98 exists — remove must exit 0 and say "already clean".
out="$(bash "$WT" remove 98 2>&1)"; rc=$?
assert_eq "0" "$rc" "worktree remove (no matching worktree) exits 0 in non-worktree mode"
assert_contains "$out" "already clean" "worktree remove says 'already clean' when no worktree"

# ── 8. Absent config: validate treats no config as worktree → exit 0 ─────────
# Ensure no config file is present.
rm -f talos.pipeline.json talos.pipeline.yml talos.pipeline.yaml
out="$(bash "$ISO" validate 2>&1)"; rc=$?
assert_eq "0" "$rc" "absent config treated as worktree, exits 0"

finish
