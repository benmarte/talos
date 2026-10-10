#!/usr/bin/env bash
# The first-line verdict contract (#518): every verdict-word role profile states
# that its final message starts with the verdict word. `talos.sh run` derives a
# stage's verdict from that line, so the contract is script-enforced. (The QA /
# reviewer / security "targeted tests only" prose pins of #257 were dropped as
# prose-only, #556.)
set -u
. "$(dirname "$0")/helpers.sh"

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

finish
