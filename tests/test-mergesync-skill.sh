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
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$VCS" "scripts/pipeline-vcs.sh exists"

skill_text="$(cat "$SKILL")"

# Step 0 reads the new config key.
assert_contains "$skill_text" "merge.auto_sync" "skill: Step 0 reads merge.auto_sync"
assert_contains "$skill_text" "MERGE_AUTO_SYNC" "skill: config variable named MERGE_AUTO_SYNC"

# Step 4's post-merge block names the full ladder.
assert_contains "$skill_text" "Post-merge sibling sync (#289" "skill: Step 4 has the post-merge sibling sync block"
assert_contains "$skill_text" 'conflict-files <PR>`:' "skill: block drives off conflict-files"
assert_contains "$skill_text" "pipeline-mergebase.sh <PR>" "skill: block dispatches the mechanical union first"
assert_contains "$skill_text" "update-branch" "skill: block falls back to update-branch"
assert_contains "$skill_text" "developer merge-base task" "skill: block falls back to the developer dispatch"
assert_contains "$skill_text" 'When `merge.auto_sync` is `false`' "skill: block is gated on merge.auto_sync"

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
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.yml.example")" "auto_sync" "example: yml documents auto_sync"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" '"auto_sync"' "example: json documents auto_sync"

finish