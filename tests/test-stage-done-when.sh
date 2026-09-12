#!/usr/bin/env bash
# Every stage prompt carries exactly one "Done when: ..." stopping condition
# (#270). Without one, agents decide for themselves when they are finished,
# which is where scope creep and over-testing come from (a developer "just
# adding coverage", a reviewer re-reading the whole PR). This test pins:
#   1. Each agents/<role>.md has exactly one "Done when:" line.
#   2. The matching SKILL.md dispatch block for that role carries the
#      identical line (not just any "Done when:" text).
#   3. README documents the convention so a future edit keeps it.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"

# Same fenced-block extraction convention as test-skill-names.sh /
# test-prompt-rules.sh: anchor on the prompt's own first line and scan
# forward for its closing fence, so a nested ```bash/```yaml snippet can't
# desync a naive every-``` -toggles count.
extract_window() {  # $1=file $2=anchor substring
  local file="$1" anchor="$2" start end
  start="$(grep -n -F "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  end="$(awk -v s="$start" 'NR > s && /^```$/ { print NR; exit }' "$file")"
  [ -z "$end" ] && end=$((start + 80))
  sed -n "${start},$((end - 1))p" "$file"
}

# extract_done_when FILE -- the "Done when: ..." sentence (may wrap onto a
# second line), flattened to a single space-joined line with no trailing
# whitespace, stopping at the first blank line after it.
extract_done_when() {
  awk '/^Done when:/{flag=1} flag{print} flag && /^$/{exit}' "$1" \
    | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

flatten() { tr '\n' ' ' <<<"$1" | tr -s ' '; }

# role -> SKILL.md dispatch-prompt anchor (its own opening line, verbatim).
roles="validator planner pm developer qa reviewer security docs adversarial"

anchor_for() {
  case "$1" in
    validator) echo "You are the Validator. Issue #<N> is assigned to you." ;;
    planner) echo "You are the Planner. Issue #<N> is an epic that needs decomposition." ;;
    pm) echo "You are the Project Manager. Issue #<N> has been CONFIRMED." ;;
    developer) echo "You are the Developer. Implement <SPEC_SOURCE> for issue #<N>." ;;
    qa) echo "You are QA. A developer opened a PR for issue #<N>." ;;
    reviewer) echo "You are the Reviewer. QA passed PR #<PR_NUMBER> for issue #<N>." ;;
    security) echo "You are the Security Analyst. QA passed PR #<PR_NUMBER> for issue #<N>." ;;
    docs) echo "You are Documentation. QA passed for PR #<PR_NUMBER>." ;;
    adversarial) echo "You are the Adversarial Reviewer. QA, review, and security passed PR #<PR_NUMBER> for issue #<N>." ;;
  esac
}

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

  # ── (2) the SKILL.md dispatch block for this role carries the same line ──
  anchor="$(anchor_for "$role")"
  block="$(extract_window "$SKILL_MD" "$anchor")"
  if [ -z "$block" ]; then
    fail "skills/pipeline/SKILL.md has a dispatch block for $role" \
      "no block found for anchor: $anchor"
    continue
  fi
  block_flat="$(flatten "$block")"
  assert_contains "$block_flat" "$done_when" \
    "skills/pipeline/SKILL.md $role dispatch block carries the identical Done when line"
done

# ── (3) README documents the convention ────────────────────────────────────
README="$TALOS_ROOT/README.md"
readme_content="$(cat "$README")"
assert_contains "$readme_content" "Done when:" \
  "README documents the 'Done when:' convention"
assert_contains "$readme_content" "agents/<role>.md" \
  "README's convention note references agents/<role>.md"

finish
