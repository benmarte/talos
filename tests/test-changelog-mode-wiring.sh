#!/usr/bin/env bash
# Skill-text assertions for the CHANGELOG MODE trigger wiring (#296):
#   1. The docs prompt template carries the <CHANGELOG_MODE_LINE> placeholder
#      and the rendered prompt substitutes the fragment/direct line.
#   2. The full-diff and filtered-paths dispatches go through the one prompt.
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

# The prompt line is a marker of the docs template (the dispatch block moved out of
# the playbook into templates/prompts/docs.md, #468) and the rule is the verb's.
tmpl_text="$(cat "$TALOS_ROOT/templates/prompts/docs.md")"
assert_contains "$tmpl_text" "{{CHANGELOG_MODE_LINE}}" "template: docs prompt carries the CHANGELOG_MODE_LINE marker"

# Rendered: flag on mandates the literal fragments line (without it fragment mode would
# silently degrade to direct CHANGELOG.md edits); flag off gives the direct line.
make_sandbox || exit 1
printf '{"roles": {"changelog_fragments": true}}' > "$SANDBOX/talos.pipeline.json"
assert_contains "$(talos_prompt_text docs --issue 7 --pr 9)" $'\nCHANGELOG MODE: fragments\n' "docs prompt: flag on carries the literal CHANGELOG MODE: fragments line"
printf '{"roles": {"changelog_fragments": false}}' > "$SANDBOX/talos.pipeline.json"
assert_contains "$(talos_prompt_text docs --issue 7 --pr 9)" $'\nCHANGELOG MODE: direct\n' "docs prompt: flag off carries CHANGELOG MODE: direct"

# Both dispatch paths (docs_mode always: the full diff; auto: the filtered one) go through the one prompt.
assert_contains "$(talos_prompt_text docs --issue 7 --pr 9)" 'pipeline-vcs.sh diff-pr 9' "docs prompt: no paths file means the full diff"
printf 'README.md\n' > "$SANDBOX/paths.txt"
assert_not_contains "$(talos_prompt_text docs --issue 7 --pr 9 --docs-paths-file "$SANDBOX/paths.txt")" 'diff-pr 9' "docs prompt: a paths file replaces the full diff"

# Docs profile: absent line = direct mode (explicit fallback).
assert_contains "$docs_text" "or carries no changelog-mode line at all, edit \`CHANGELOG.md\` normally" "docs profile: absent line means direct mode"

finish