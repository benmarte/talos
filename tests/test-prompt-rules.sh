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

# Same fenced-block extraction convention as test-skill-names.sh: anchor on
# the prompt's own first line and scan forward for its closing fence, so a
# ```bash/```yaml snippet nested in the surrounding prose can't desync a
# naive every-``` -toggles count.
extract_window() {  # $1=file $2=anchor substring
  local file="$1" anchor="$2" start end
  start="$(grep -n -F "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  end="$(awk -v s="$start" 'NR > s && /^```$/ { print NR; exit }' "$file")"
  [ -z "$end" ] && end=$((start + 60))
  sed -n "${start},$((end - 1))p" "$file"
}

qa_block="$(extract_window "$SKILL_MD" "You are QA. A developer opened a PR for issue")"
reviewer_block="$(extract_window "$SKILL_MD" "You are the Reviewer. QA passed")"
security_block="$(extract_window "$SKILL_MD" "You are the Security Analyst. QA passed")"

# Flatten line wraps to spaces: prose wraps at ~80 cols, so a phrase can
# straddle a newline and miss a literal substring match otherwise. Squeeze
# repeated spaces too -- a wrapped continuation line's leading indent would
# otherwise leave "word1    word2" (newline-as-space plus the indent itself)
# instead of the single space a literal match needs.
qa_block_flat="$(printf '%s' "$qa_block" | tr '\n' ' ' | tr -s ' ')"
reviewer_block_flat="$(printf '%s' "$reviewer_block" | tr '\n' ' ' | tr -s ' ')"
security_block_flat="$(printf '%s' "$security_block" | tr '\n' ' ' | tr -s ' ')"

# ── QA: SKILL.md Step 3d prompt must state the targeted-only rule (#257) ───
assert_contains "$qa_block_flat" "--for" \
  "SKILL.md QA prompt block mentions --for (targeted tests)"
assert_contains "$qa_block_flat" "Never run the full suite" \
  "SKILL.md QA prompt block forbids the full suite"

# A plain --for/--changed still falls back to the full suite on an unmapped
# path (e.g. CHANGELOG.md) -- --strict is required so QA never hits that
# fallback (#263 review follow-up).
assert_contains "$qa_block_flat" "--strict" \
  "SKILL.md QA prompt block uses --strict"
assert_contains "$qa_block_flat" "Exit 3" \
  "SKILL.md QA prompt block explains exit 3 (no targeted tests map)"

# A regression back to a bare "run-tests.sh" instruction (no --for/--changed
# scoping) is exactly the bug #257 fixes -- fail if that pattern reappears.
if printf '%s' "$qa_block" | grep -Eq 'run-tests\.sh( --quiet)?\s*($|`)'; then
  fail "SKILL.md QA prompt block never instructs a bare run-tests.sh (no --for/--changed)" \
    "found a bare run-tests.sh invocation"
else
  pass "SKILL.md QA prompt block never instructs a bare run-tests.sh (no --for/--changed)"
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

# ── Reviewer/security: SKILL.md Step 3e prompts say not to run tests (#257) ─
assert_contains "$reviewer_block_flat" "Do not run tests" \
  "SKILL.md reviewer prompt block says not to run tests"
assert_contains "$security_block_flat" "Do not run tests" \
  "SKILL.md security prompt block says not to run tests"

# ── Rules section: no push to base mid-run (#257) ───────────────────────────
rules_section="$(sed -n '/^## Rules$/,$p' "$SKILL_MD")"
assert_contains "$rules_section" "never commits or pushes to the base branch" \
  "SKILL.md Rules section forbids pushing to base mid-run"

finish
