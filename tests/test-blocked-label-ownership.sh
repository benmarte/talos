#!/usr/bin/env bash
# No stage role clears pipeline:blocked; only the orchestrator does (#310).
#
# Reviewer and security run in parallel (SKILL.md Step 3e, phase 2). Each
# role's profile used to remove pipeline:blocked from the PR and the issue on
# its own approval, so one role's approval erased the other role's block (PR
# #307: security's CLEAR wiped the reviewer's CHANGES block a minute later).
# This test pins the fix: no role profile carries a `--remove
# pipeline:blocked` step, and SKILL.md names the orchestrator as the one that
# clears it before a developer fix round.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"

# A `--remove` flag whose value list names pipeline:blocked, on one line.
# `--add pipeline:blocked --remove pipeline:review` (a block step) does not
# match: pipeline:blocked comes before --remove there.
REMOVE_BLOCKED_RE='--remove[^`]*pipeline:blocked'

# agents/ is the source; .claude/agents is a tracked symlink to it, checked
# too so a future split into real copies cannot reintroduce the step.
for dir in agents .claude/agents; do
  for role in reviewer security adversarial qa docs; do
    f="$TALOS_ROOT/$dir/$role.md"
    [ -f "$f" ] || continue
    if grep -Eq -- "$REMOVE_BLOCKED_RE" "$f"; then
      fail "$dir/$role.md has no --remove pipeline:blocked step" \
        "$(grep -En -- "$REMOVE_BLOCKED_RE" "$f")"
    else
      pass "$dir/$role.md has no --remove pipeline:blocked step"
    fi
  done
done

# Every role profile, not just the parallel ones: none may clear a block.
offenders="$(grep -El -- "$REMOVE_BLOCKED_RE" "$TALOS_ROOT"/agents/*.md 2>/dev/null)"
assert_eq "" "$offenders" "no agents/*.md profile removes pipeline:blocked"

# ── SKILL.md: the orchestrator owns clearing the block ─────────────────────
skill_flat="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"
assert_contains "$skill_flat" 'only the orchestrator clears `pipeline:blocked`' \
  "SKILL.md names the orchestrator as the one who clears pipeline:blocked"
assert_contains "$skill_flat" 'label-pr <PR_NUMBER> --remove pipeline:blocked' \
  "SKILL.md gives the orchestrator's PR clear command"
assert_contains "$skill_flat" 'label-issue <N> --remove pipeline:blocked' \
  "SKILL.md gives the orchestrator's issue clear command"

finish
