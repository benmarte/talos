#!/usr/bin/env bash
# Every stage prompt carries exactly one "Done when: ..." stopping condition
# (#270). Without one, agents decide for themselves when they are finished,
# which is where scope creep and over-testing come from (a developer "just
# adding coverage", a reviewer re-reading the whole PR). This test pins:
#   1. Each agents/<role>.md has exactly one "Done when:" line.
#   2. The matching templates/prompts/<role>.md dispatch prompt for that role
#      (the fences moved there from SKILL.md, #468) carries exactly one
#      "Done when:" line, identical to the profile's (not just any text).
#   3. README documents the convention so a future edit keeps it.
set -u
. "$(dirname "$0")/helpers.sh"

PROMPTS="$TALOS_ROOT/templates/prompts"

# extract_done_when FILE -- the "Done when: ..." sentence (may wrap onto a
# second line), flattened to a single space-joined line with no trailing
# whitespace, stopping at the first blank line after it.
extract_done_when() {
  awk '/^Done when:/{flag=1} flag{print} flag && /^$/{exit}' "$1" \
    | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

flatten() { tr '\n' ' ' <<<"$1" | tr -s ' '; }

# The nine roles that have a dispatch prompt template.
roles="validator planner pm developer qa reviewer security docs adversarial"

for role in $roles; do
  agent_md="$TALOS_ROOT/agents/$role.md"
  assert_file_exists "$agent_md" "agents/$role.md exists"
  [ -f "$agent_md" ] || continue

  # ── (1) exactly one "Done when:" line per role profile ────────────────────
  count="$(grep -c '^Done when:' "$agent_md")"
  assert_eq "1" "$count" "agents/$role.md has exactly one 'Done when:' line"

  done_when="$(extract_done_when "$agent_md")"
  assert_contains "$done_when" "Done when:" \
    "agents/$role.md's Done when line is extractable"

  # ── (2) the dispatch prompt template for this role carries the same line, once ──
  tmpl="$PROMPTS/$role.md"
  assert_file_exists "$tmpl" "templates/prompts/$role.md exists"
  [ -f "$tmpl" ] || continue
  assert_eq "1" "$(grep -c '^Done when:' "$tmpl")" "templates/prompts/$role.md has exactly one 'Done when:' line"
  block_flat="$(flatten "$(cat "$tmpl")")"
  assert_contains "$block_flat" "$done_when" \
    "templates/prompts/$role.md carries the identical Done when line"
done

# ── (3) README documents the convention ────────────────────────────────────
README="$TALOS_ROOT/README.md"
readme_content="$(cat "$README")"
assert_contains "$readme_content" "Done when:" \
  "README documents the 'Done when:' convention"
assert_contains "$readme_content" "agents/<role>.md" \
  "README's convention note references agents/<role>.md"

finish
