#!/usr/bin/env bash
# Per-stage fixed overhead (#548, epic #558). Every stage pays for its role
# profile, its rendered prompt and the agent-skills it is told to load before any
# real work starts. This pins the shape that keeps that cost down:
#   1. each profile names ONE required skill; the rest are "only if the task
#      needs it"; no profile mandates doubt-driven-development (it does not
#      resolve outside the talos plugin cache)
#   2. boilerplate is stated once: no "agent-skills plugin" paragraph, the
#      heredoc-as-data rule once per profile, and one approval sentence shared
#      by the five post-approval profiles
#   3. the load-bearing rules of epic #558 survive the trim
#   4. a size budget per role (profile + prompt template bytes) so the overhead
#      cannot creep back unnoticed; raise a ceiling only with a reason in the PR
set -u
. "$(dirname "$0")/helpers.sh"

AGENTS="$TALOS_ROOT/agents"
PROMPTS="$TALOS_ROOT/templates/prompts"
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# ── 1. one required skill per role ───────────────────────────────────────────
for pair in developer:test-driven-development qa:test-driven-development \
  reviewer:code-review-and-quality security:security-and-hardening \
  pm:spec-driven-development docs:documentation-and-adrs \
  validator:debugging-and-error-recovery adversarial:code-review-and-quality \
  planner:planning-and-task-breakdown; do
  role="${pair%%:*}"; skill="${pair#*:}"
  assert_eq "1" "$(grep -c '^\*\*Skill:\*\* load `' "$AGENTS/$role.md")" "$role: exactly one '**Skill:** load' line"
  assert_contains "$(grep -m1 '^\*\*Skill:\*\* load `' "$AGENTS/$role.md")" "**Skill:** load \`$skill\`" "$role: the required skill is $skill"
done
all_profiles="$(cat "$AGENTS"/*.md)"
assert_not_contains "$all_profiles" "doubt-driven-development" "no profile names doubt-driven-development"
assert_not_contains "$all_profiles" "Skills — use these" "no profile carries the old multi-skill mandate"

# ── 2. boilerplate once ──────────────────────────────────────────────────────
assert_not_contains "$all_profiles" "Talos requires the agent-skills plugin" "no profile carries the agent-skills plugin paragraph"
assert_not_contains "$all_profiles" "Vendored installs" "no profile carries the vendored-install note"
for role in developer validator pm qa reviewer security docs adversarial; do
  assert_eq "1" "$(grep -c '12+ random' "$AGENTS/$role.md")" "$role: the heredoc-as-data rule is stated once"
done
for role in qa reviewer security docs adversarial; do
  text="$(flat "$AGENTS/$role.md")"
  assert_contains "$text" "post-approval <PR> $role " "$role: post-approval names its role"
  assert_contains "$text" "reads the PR head SHA itself (never \`git rev-parse HEAD\`: your local HEAD can differ after a push), appends the marker as the last line and applies" \
    "$role: the shared approval sentence (head SHA from the API, marker last)"
  assert_contains "$text" "It then runs check-approval-sha itself and prints one line ending \`stamp ok\`" "$role: the shared approval self-check"
done

# ── 3. load-bearing rules survive ────────────────────────────────────────────
for role in reviewer security adversarial; do
  text="$(flat "$AGENTS/$role.md")"
  assert_contains "$text" "never run \`git checkout\`, \`git switch\`, or \`git pull\`" "$role: never switches branches"
  assert_contains "$text" "only the orchestrator clears it" "$role: only the orchestrator clears pipeline:blocked"
  assert_contains "$text" "FIRST LINE is your verdict word" "$role: first-line verdict contract"
done
assert_contains "$(flat "$AGENTS/qa.md")" "FIRST LINE is your verdict word" "qa: first-line verdict contract"
assert_contains "$(flat "$AGENTS/validator.md")" "FIRST LINE is your verdict word" "validator: first-line verdict contract"
assert_contains "$(flat "$AGENTS/developer.md")" "Do not include a self-reported test count" "developer: no self-reported test counts"
assert_contains "$(flat "$AGENTS/developer.md")" "never use background execution" "developer: foreground-only verify"
assert_contains "$(flat "$AGENTS/qa.md")" "never use background execution" "qa: foreground-only verify"
assert_contains "$(flat "$AGENTS/qa.md")" "a value off the path or name-filter charset is refused and nothing from the spec runs" "qa: spec test paths are validated (by qa-run)"
for role in validator pm planner developer qa reviewer security docs adversarial; do
  assert_contains "$(cat "$PROMPTS/$role.md")" "{{STOP_RULE}}" "$role prompt: the stop rule is rendered from the one partial"
done

# ── 4. size budget (bytes of profile + prompt template) ──────────────────────
budget() {  # role ceiling
  local size
  size=$(( $(wc -c < "$AGENTS/$1.md") + $(wc -c < "$PROMPTS/$1.md") ))
  if [ "$size" -le "$2" ]; then pass "$1: profile + prompt template is $size bytes (budget $2)"
  else fail "$1: profile + prompt template is $size bytes (budget $2)" "over by $((size - $2))"; fi
}
budget developer 11800
budget qa 8200
budget reviewer 4700
budget security 3700
budget pm 4300
budget validator 4300
budget docs 4600
budget adversarial 5100
budget planner 3300

finish
