#!/usr/bin/env bash
# Every stage carries exactly one "Done when: ..." stopping condition (#270).
# Without one, agents decide for themselves when they are finished, which is
# where scope creep and over-testing come from (a developer "just adding
# coverage", a reviewer re-reading the whole PR). This test pins:
#   1. Each agents/<role>.md has exactly one "Done when:" line.
#   2. The matching templates/prompts/<role>.md dispatch prompt does NOT repeat
#      it (#548: stated once, in the profile, which every dispatch loads), and
#      carries the shared stop rule through the {{STOP_RULE}} partial instead.
#      The re-stamp prompt is the exception: its job (re-stamp the delta) is not
#      the profile's, so it states its own single "Done when:".
#   3. README documents the convention so a future edit keeps it.
set -u
. "$(dirname "$0")/helpers.sh"

PROMPTS="$TALOS_ROOT/templates/prompts"

# The nine roles that have a dispatch prompt template.
roles="validator planner pm developer qa reviewer security docs adversarial"

for role in $roles; do
  agent_md="$TALOS_ROOT/agents/$role.md"
  assert_file_exists "$agent_md" "agents/$role.md exists"
  [ -f "$agent_md" ] || continue

  # ── (1) exactly one "Done when:" line per role profile ────────────────────
  assert_eq "1" "$(grep -c '^Done when:' "$agent_md")" "agents/$role.md has exactly one 'Done when:' line"

  # ── (2) the dispatch prompt does not repeat it, and carries the stop rule ──
  tmpl="$PROMPTS/$role.md"
  assert_file_exists "$tmpl" "templates/prompts/$role.md exists"
  [ -f "$tmpl" ] || continue
  assert_eq "0" "$(grep -c '^Done when:' "$tmpl")" "templates/prompts/$role.md does not repeat 'Done when:' (the profile owns it)"
  assert_contains "$(cat "$tmpl")" "{{STOP_RULE}}" "templates/prompts/$role.md carries the stop rule"
  assert_eq "0" "$(grep -c 'If you stop, block, or ask' "$agent_md")" "agents/$role.md does not repeat the stop rule (the prompt owns it)"
done

assert_eq "1" "$(grep -c '^Done when:' "$PROMPTS/restamp.md")" "templates/prompts/restamp.md states its own single 'Done when:'"

# ── (3) README documents the convention ────────────────────────────────────
README="$TALOS_ROOT/README.md"
readme_content="$(cat "$README")"
assert_contains "$readme_content" "Done when:" \
  "README documents the 'Done when:' convention"
assert_contains "$readme_content" "agents/<role>.md" \
  "README's convention note references agents/<role>.md"

finish
