#!/usr/bin/env bash
# QA runs targeted tests only; reviewer/security run none; orchestrator never
# pushes to base mid-run (#257).
#
# #195 established that `verify:` runs once per PR (by the developer) and QA
# trusts CI for the full run. On 2026-09-09 every QA dispatch nevertheless ran
# the full suite because the orchestrator's Step 3d stage prompt asked for it
# generically instead of stating the targeted-only rule explicitly. This test
# pins that rule (and its reviewer/security/Rules-section counterparts) in
# place so a future edit cannot regress the QA block back to a bare
# full-suite instruction without failing here.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
QA_MD="$TALOS_ROOT/agents/qa.md"

# The stage prompts moved out of SKILL.md into templates/prompts/<role>.md (#468): the
# block of a role is its whole template.
qa_block="$(cat "$TALOS_ROOT/templates/prompts/qa.md")"
reviewer_block="$(cat "$TALOS_ROOT/templates/prompts/reviewer.md")"
security_block="$(cat "$TALOS_ROOT/templates/prompts/security.md")"

# Flatten line wraps to spaces: prose wraps at ~80 cols, so a phrase can
# straddle a newline and miss a literal substring match otherwise. Squeeze
# repeated spaces too -- a wrapped continuation line's leading indent would
# otherwise leave "word1    word2" (newline-as-space plus the indent itself)
# instead of the single space a literal match needs.
qa_block_flat="$(printf '%s' "$qa_block" | tr '\n' ' ' | tr -s ' ')"
reviewer_block_flat="$(printf '%s' "$reviewer_block" | tr '\n' ' ' | tr -s ' ')"
security_block_flat="$(printf '%s' "$security_block" | tr '\n' ' ' | tr -s ' ')"

# ── QA: the Step 3d prompt template must state the targeted-only rule (#257) ───
assert_contains "$qa_block_flat" "--for" \
  "QA prompt template mentions --for (targeted tests)"
assert_contains "$qa_block_flat" "Never run the full suite" \
  "QA prompt template forbids the full suite"

# A plain --for/--changed still falls back to the full suite on an unmapped
# path (e.g. CHANGELOG.md) -- --strict is required so QA never hits that
# fallback (#263 review follow-up).
assert_contains "$qa_block_flat" "--strict" \
  "QA prompt template uses --strict"
assert_contains "$qa_block_flat" "Exit 3" \
  "QA prompt template explains exit 3 (no targeted tests map)"

# A regression back to a bare "run-tests.sh" instruction (no --for/--changed
# scoping) is exactly the bug #257 fixes -- fail if that pattern reappears.
if grep -Eq 'run-tests\.sh( --quiet)?\s*($|`)' <<<"$qa_block"; then
  fail "QA prompt template never instructs a bare run-tests.sh (no --for/--changed)" \
    "found a bare run-tests.sh invocation"
else
  pass "QA prompt template never instructs a bare run-tests.sh (no --for/--changed)"
fi

# ── QA: agents/qa.md mirrors the same rule (#257, #263) ─────────────────────
# Flatten line wraps to spaces first (and squeeze repeated spaces from
# wrapped continuation lines' leading indent -- see the comment above).
qa_md_flat="$(tr '\n' ' ' < "$QA_MD" | tr -s ' ')"
assert_contains "$qa_md_flat" "--for" \
  "agents/qa.md mentions --for (targeted tests)"
assert_contains "$qa_md_flat" "Never run the full suite" \
  "agents/qa.md forbids the full suite"
assert_contains "$qa_md_flat" "--strict" \
  "agents/qa.md uses --strict"
assert_contains "$qa_md_flat" "Exit 3" \
  "agents/qa.md explains exit 3 (no targeted tests map)"

# ── Reviewer/security: the Step 3e prompt templates say not to run tests (#257) ─
assert_contains "$reviewer_block_flat" "Do not run tests" \
  "reviewer prompt template says not to run tests"
assert_contains "$security_block_flat" "Do not run tests" \
  "security prompt template says not to run tests"

# ── Rules section: no push to base mid-run (#257) ───────────────────────────
rules_section="$(sed -n '/^## Rules$/,$p' "$SKILL_MD")"
assert_contains "$rules_section" "never commits or pushes to the base branch" \
  "SKILL.md Rules section forbids pushing to base mid-run"

# ── #518 AC1: the verdict-first final message in every verdict-word profile ───
# `talos.sh run` derives a stage's verdict with `_run_verdict` (scripts/talos.sh):
# the first line whose first word is `<WORD>:`, WORD on that role's own verdict
# list. A profile that says only "verdict + key findings" lets a weak local model
# answer with labels/comments narration and no parseable line -- the dogfood
# `verdict-unreadable` failure of #518. So every verdict-word role states the
# contract on its own line: verdict word first, findings after, nothing before.
# Pinned per file because each file owns its line (no shared snippet), and the
# rule must appear exactly once.
final_rule_of() {  # FILE: the "^Final message:" paragraph, line wraps flattened
  awk '/^Final message:/ { found = 1 } found { print }' "$1" | tr '\n' ' ' | tr -s ' '
}

for _role in validator qa reviewer security adversarial; do
  _profile="$TALOS_ROOT/agents/$_role.md"
  _rule="$(final_rule_of "$_profile")"
  case "$_role" in
    validator)              _example='`CONFIRMED: ...`' ;;
    qa)                     _example='`PASS: ...` or `FAIL: ...`' ;;
    reviewer)               _example='`APPROVED: ...` or `CHANGES:' ;;
    security | adversarial) _example='`CLEAR: ...` or `FINDINGS:' ;;
  esac
  assert_contains "$_rule" "FIRST LINE is your verdict word" \
    "AC1 $_role profile puts the verdict word on the first line"
  assert_contains "$_rule" "$_example" \
    "AC1 $_role profile examples its own verdict words"
  assert_contains "$_rule" "1-3 lines of findings" \
    "AC1 $_role profile keeps findings after the verdict line"
  assert_contains "$_rule" "NOTHING before" \
    "AC1 $_role profile forbids anything before the verdict line"
  assert_eq "1" "$(grep -c '^Final message:' "$_profile" || true)" \
    "AC1 $_role profile states the rule once (no second copy)"
done

# ── #518 AC2: the one prompt-template restatement (qa) ───────────────────────
# templates/prompts/qa.md is the only stage template that restates the final
# message, so it carries the same first-line contract -- and the rendered
# `tests/fixtures/talos-prompt/qa.golden` is regenerated from it (golden suite:
# tests/test-talos-prompt.sh). No other verdict-word template restates it: the
# developer template's PR-URL shape is parsed separately by `_run_verdict`.
_qa_tpl="$(final_rule_of "$TALOS_ROOT/templates/prompts/qa.md")"
assert_contains "$_qa_tpl" "FIRST LINE is your verdict word" \
  "AC2 qa prompt template restates the verdict-first first line"
assert_contains "$_qa_tpl" '`PASS: ...` or `FAIL: ...`' \
  "AC2 qa prompt template examples its own verdict words"
assert_contains "$_qa_tpl" "1-3 lines of findings" \
  "AC2 qa prompt template keeps findings after the verdict line"
assert_contains "$_qa_tpl" "NOTHING before" \
  "AC2 qa prompt template forbids anything before the verdict line"
assert_eq "1" "$(grep -c '^Final message:' "$TALOS_ROOT/templates/prompts/qa.md" || true)" \
  "AC2 qa prompt template states the rule once"
for _t in validator reviewer security adversarial restamp; do
  assert_eq "0" "$(grep -c '^Final message:' "$TALOS_ROOT/templates/prompts/$_t.md" || true)" \
    "AC2 no verdict-first restatement in the $_t prompt template"
done

finish
