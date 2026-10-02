#!/usr/bin/env bash
# AC7 (#336): the Talos config is the only place a role's model is set, so no
# shipped agent definition may carry a `model:` frontmatter line. Claude Code
# applies that line whenever the config resolves empty, which silently
# re-introduces a second source (the repo shipped Opus x8 + Haiku for docs).
# `effort:` stays: the Agent tool has no per-spawn effort parameter.
set -u
. "$(dirname "$0")/helpers.sh"

ROLES="validator pm developer qa reviewer security adversarial docs planner"
for role in $ROLES; do
  f="$TALOS_ROOT/agents/$role.md"
  assert_file_exists "$f" "AC7: agents/$role.md exists"
  fm="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$f")"
  assert_contains "$fm" "name: $role" "AC7: agents/$role.md still has its name: frontmatter line"
  assert_contains "$fm" "tools:" "AC7: agents/$role.md still has its tools: frontmatter line"
  if printf '%s\n' "$fm" | grep -q '^[[:space:]]*model:'; then
    fail "AC7: agents/$role.md has no model: frontmatter line" "found a model: line in the frontmatter"
  else
    pass "AC7: agents/$role.md has no model: frontmatter line"
  fi
done
assert_eq "9" "$(ls "$TALOS_ROOT"/agents/*.md | wc -l | tr -d ' ')" "AC7: exactly the nine shipped agents are checked"

# .claude/agents is a symlink to agents/, so it is covered by the loop above.
if [ -L "$TALOS_ROOT/.claude/agents" ]; then
  pass "AC7: .claude/agents is a symlink to agents/ (covered)"
else
  for f in "$TALOS_ROOT"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    if grep -q '^model:' "$f"; then fail "AC7: .claude/agents/$(basename "$f") has no model: line"; fi
  done
  pass "AC7: .claude/agents carries no model: line"
fi

finish
