#!/usr/bin/env bash
# Skill-text/config assertions for CHANGELOG fragments (#290):
#   1. agents/docs.md carries the CHANGELOG MODE: fragments instructions.
#   2. SKILL.md reads roles.changelog_fragments, defaults it false, wires the
#      docs prompt line, the docs_mode auto gate note, and the Step 4
#      assemble hook.
#   3. pipeline-config.sh knows the key; example configs document it.
#   4. scripts/pipeline-changelog.sh exists with the assemble contract.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
DOCS_AGENT="$TALOS_ROOT/agents/docs.md"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
CL="$TALOS_ROOT/scripts/pipeline-changelog.sh"

assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$DOCS_AGENT" "agents/docs.md exists"
assert_file_exists "$CL" "scripts/pipeline-changelog.sh exists"

skill_text="$(cat "$SKILL")"
docs_text="$(cat "$DOCS_AGENT")"

# Step 0 wires the flag.
assert_contains "$skill_text" "roles.changelog_fragments" "skill: Step 0 reads roles.changelog_fragments"
assert_contains "$skill_text" 'ROLE_CHANGELOG_FRAGMENTS (`roles.changelog_fragments`, default `false`)' "skill: flag documented default false"

# Docs prompt carries the fragment mode.
assert_contains "$docs_text" "CHANGELOG MODE: fragments" "docs profile: names the CHANGELOG MODE: fragments trigger"

# SKILL docs prompt carries the fragment instructions too.
assert_contains "$skill_text" "CHANGELOG MODE: fragments" "skill: docs prompt carries the fragment trigger"
assert_contains "$skill_text" "docs/CHANGELOG.d/<issue-number>.md" "skill: docs prompt names the fragment path"

# Step 4 hook + waiver note + gate note.
assert_contains "$skill_text" "Assemble changelog fragments" "skill: Step 4 has the assemble hook"
assert_contains "$skill_text" "pipeline-changelog.sh assemble" "skill: hook calls the assemble verb"
assert_contains "$skill_text" "never invalidates an approval" "skill: waiver note covers fragment paths"

# Config + examples.
assert_contains "$(cat "$CFG")" "roles.changelog_fragments" "config: key in known keys"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.yml.example")" "changelog_fragments" "example: yml documents the flag"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" '"changelog_fragments"' "example: json documents the flag"

# The script's own contract.
cl_text="$(cat "$CL")"
assert_contains "$cl_text" "assemble" "script: assemble verb exists"
assert_contains "$cl_text" "nothing to assemble" "script: idempotent no-op path"
assert_contains "$cl_text" "with_lock" "script: worktree mutations serialized"

finish