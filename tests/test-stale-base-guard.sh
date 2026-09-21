#!/usr/bin/env bash
# Skill-text assertions for the stale-base guard (#288), which generalizes
# the #256 CHANGELOG serialization guard to "any stale base":
#   1. SKILL.md Step 4 names the guard "stale-base guard" and does NOT
#      special-case CHANGELOG (the old "CHANGELOG serialization guard:"
#      bold heading is gone).
#   2. The guard text drives off `conflict-files` + `merge.union_paths`
#      (same mechanical path as the Step 3c mergeability gate) and names
#      the developer merge-base fallback for non-union paths.
#   3. The CHANGELOG both-entries-newest-first rule survives the
#      generalization.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"

skill_text="$(cat "$SKILL")"

assert_contains "$skill_text" "**Stale-base guard" "skill: Step 4 names the guard stale-base guard"
assert_not_contains "$skill_text" "**CHANGELOG serialization guard:**" "skill: the CHANGELOG-only guard heading is gone (not special-cased)"
assert_contains "$skill_text" "most common instance" "skill: guard frames CHANGELOG as the common instance, not a special case"
assert_contains "$skill_text" 'conflict-files <PR>`' "skill: guard runs conflict-files first"
assert_contains "$skill_text" "merge.union_paths" "skill: guard gates the mechanical path on merge.union_paths"
assert_contains "$skill_text" "pipeline-mergebase.sh <PR>" "skill: guard dispatches the mechanical union merge"
assert_contains "$skill_text" "git merge origin/main" "skill: non-union fallback still the developer merge-base dispatch"
assert_contains "$skill_text" "keep BOTH entries" "skill: CHANGELOG union keeps both entries, newest first"
assert_contains "$skill_text" "Before EACH \`merge-pr\`" "skill: guard applies before every merge, not only CHANGELOG ones"

# The Step 3c gate reference to the mechanical path is unchanged: it must
# still be able to reach the same script.
assert_contains "$skill_text" "scripts/pipeline-mergebase.sh" "skill: mergebase script referenced by path"

finish
