#!/usr/bin/env bash
# Skill-text assertions for the reviewer human-attention report (#294):
#   1. agents/reviewer.md carries the report contract (2-5 bullets, file:line,
#      priority order, empty-list literal).
#   2. SKILL.md's reviewer prompt instructs the report and the
#      ATTENTION_REPORT placeholder in templates/comments/review-signoff.md.
#   3. templates/comments/review-signoff.md carries the ATTENTION_REPORT
#      placeholder and the human-attention section.
#   4. The orchestrator reviewer relay includes the top attention items.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
REVIEWER="$TALOS_ROOT/agents/reviewer.md"
SIGNOFF="$TALOS_ROOT/templates/comments/review-signoff.md"

assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$REVIEWER" "agents/reviewer.md exists"
assert_file_exists "$SIGNOFF" "templates/comments/review-signoff.md exists"

reviewer_text="$(cat "$REVIEWER")"
skill_text="$(cat "$SKILL")"
signoff_text="$(cat "$SIGNOFF")"

# Reviewer profile: the contract.
assert_contains "$reviewer_text" "Human-attention report" "reviewer: names the human-attention report"
assert_contains "$reviewer_text" "ATTENTION_REPORT" "reviewer: names the ATTENTION_REPORT placeholder"
assert_contains "$reviewer_text" "file:line" "reviewer: every bullet carries file:line"
assert_contains "$reviewer_text" "nothing requires human attention beyond the diff" "reviewer: empty-list literal"
assert_contains "$reviewer_text" "2-5 bullets" "reviewer: report bounded to 2-5 bullets"

# SKILL reviewer prompt: instruction present (and only in the REVIEWER block,
# not the security one — the report is a reviewer-stage artifact).
assert_contains "$skill_text" "Human-attention report (#294" "skill: reviewer prompt instructs the report"
security_block="$(awk '/You are the Security Analyst/,/^```$/' "$SKILL")"
assert_not_contains "$security_block" "human-attention" "skill: security prompt unchanged"

# Template: the section renders the placeholder.
assert_contains "$signoff_text" "Human-attention report" "template: verdict comment carries the attention section"
assert_contains "$signoff_text" '${ATTENTION_REPORT}' "template: ATTENTION_REPORT placeholder present"

# Orchestrator relay carries the top items.
assert_contains "$skill_text" "top 1-2 human-attention report items" "skill: reviewer relay includes top attention items"

finish