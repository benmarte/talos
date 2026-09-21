#!/usr/bin/env bash
# Skill-text assertions for the CHANGELOG MODE trigger wiring (#296):
#   1. SKILL.md's docs dispatch carries the <CHANGELOG_MODE_LINE> placeholder
#      in the docs prompt and defines the fragment/direct substitution rule.
#   2. The auto-stamp body mentions fragments when the flag is on.
#   3. agents/docs.md treats the fragments line as the trigger and an
#      absent/direct line as normal CHANGELOG editing.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
DOCS="$TALOS_ROOT/agents/docs.md"

assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$DOCS" "agents/docs.md exists"

skill_text="$(cat "$SKILL")"
docs_text="$(cat "$DOCS")"

# The prompt placeholder exists.
assert_contains "$skill_text" "Changelog mode: <CHANGELOG_MODE_LINE>" "skill: docs prompt carries the CHANGELOG_MODE_LINE placeholder"

# The substitution rule exists and explains activation.
assert_contains "$skill_text" "Changelog mode line (#296" "skill: the fragment rule block exists"
assert_contains "$skill_text" 'prompt MUST include the literal line' "skill: flag-on mandates the literal fragments line"
assert_contains "$skill_text" 'silently degrades to direct' "skill: rule names the silent-degradation failure"

# Both dispatch paths reference the line.
assert_contains "$skill_text" "per the fragment rule below" "skill: docs_mode always path references the rule"

# Auto-stamp body records the fragment convention.
assert_contains "$skill_text" "CHANGELOG handled via fragments" "skill: auto-stamp mentions fragment handling"

# Docs profile: absent line = direct mode (explicit fallback).
assert_contains "$docs_text" "or carries no changelog-mode line at all, edit \`CHANGELOG.md\` normally" "docs profile: absent line means direct mode"

finish