#!/usr/bin/env bash
# Skill-text assertions for the post-merge sibling sync (#289):
#   1. SKILL.md Step 0 reads merge.auto_sync (MERGE_AUTO_SYNC) and documents
#      the default (true).
#   2. Step 4 carries the "Post-merge sibling sync" block naming the
#      conflict-files -> union/update-branch -> developer-dispatch ladder.
#   3. The update-branch verb exists in pipeline-vcs.sh with the documented
#      exit-code contract, and pipeline-config.sh accepts merge.auto_sync.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CFG="$TALOS_ROOT/scripts/pipeline-defaults.sh"  # the known-keys list is the table's key column (#439)
assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$VCS" "scripts/pipeline-vcs.sh exists"

skill_text="$(cat "$SKILL")"

# Step 0 reads the new config key.
# Step 0 is `talos.sh env` (#465): the variable and its default live in its table.
assert_eq "merge.auto_sync" "$(talos_env_key MERGE_AUTO_SYNC)" "skill: Step 0 reads merge.auto_sync"
assert_eq "true" "$(talos_env_default MERGE_AUTO_SYNC)" "skill: merge.auto_sync defaults to true"
assert_contains "$skill_text" "merge.auto_sync" "skill: the sibling sync block names merge.auto_sync"

# Step 4's post-merge block names the full ladder.
#
# The ladder moved from the prose into `talos.sh post-merge` (#467): the verb runs
# conflict-files -> mergebase -> update-branch and reports `action=developer`
# (tests/test-talos-postmerge.sh runs every rung); the playbook keeps the
# developer dispatch it cannot script.
verb_text="$(cat "$TALOS_ROOT/scripts/talos.sh")"
assert_contains "$skill_text" "Sibling sync (#289" "skill: Step 4 has the sibling sync block"
assert_contains "$verb_text" '_vcs conflict-files "$_s"' "verb: the sync drives off conflict-files"
assert_contains "$verb_text" 'pipeline-mergebase.sh" "$_s"' "verb: the sync tries the mechanical union first"
assert_contains "$verb_text" '_vcs update-branch "$_s"' "verb: the sync falls back to update-branch"
assert_contains "$verb_text" '[ "$(cfg merge.auto_sync)" = "true" ] || return 0' "verb: the sync is gated on merge.auto_sync"
assert_contains "$skill_text" "developer merge-base task" "skill: block falls back to the developer dispatch"
assert_contains "$skill_text" "never more than one per merge" "skill: one sibling sync developer task per merge"

# The verb contract in the script.
vcs_text="$(cat "$VCS")"
grep -q "update-branch)" "$VCS"
assert_eq "0" "$?" "vcs: update-branch verb arm exists"
assert_contains "$vcs_text" "expected_head_sha" "vcs: GitHub PUT carries expected_head_sha"
assert_contains "$vcs_text" "glab mr rebase" "vcs: gitlab adapter implements update-branch"
assert_contains "$vcs_text" "not implemented for azure" "vcs: azure arm names the gap"

# The config key is known to pipeline-config.sh (no unknown-key warning).
cfg_keys="$(grep -c "merge.auto_sync" "$CFG")"
assert_eq "1" "$cfg_keys" "config: merge.auto_sync in known keys"

# Example configs document the key.
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" "auto_sync" "example: json documents auto_sync"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" '"auto_sync"' "example: json documents auto_sync"

finish