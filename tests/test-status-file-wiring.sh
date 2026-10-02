#!/usr/bin/env bash
# Skill-text assertions for the status-file wiring (#347, epic #333): every
# status instruction in skills/pipeline/SKILL.md and agents/docs.md is gated on
# STATUS_ENABLED, so a repo that has not opted in sees no change.
#   1. Step 0 lists the three keys and says nothing runs when disabled.
#   2. Step 3e: the docs prompt carries <STATUS_FRAGMENT_LINE>, fragment paths
#      leave CHANGED_PATHS before the docs_mode: auto gate, a missing fragment
#      never dispatches docs.
#   3. Step 4 runs assemble --refresh after "board -> Done" and before the
#      worktree removal, also on the Step 1 merged-but-open heal; Step 5 runs
#      refresh; Step 1 sweeps needs-owner (never clearing when authors are
#      unverified).
#   4. Two rules: needs-owner marking (body on stdin) and single writer.
#   5. agents/docs.md step 3a, with Done when and Rules block unchanged.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="${SKILL_FILE:-$TALOS_ROOT/skills/pipeline/SKILL.md}"
DOCS="$TALOS_ROOT/agents/docs.md"

assert_file_exists "$SKILL" "skills/pipeline/SKILL.md exists"
assert_file_exists "$DOCS" "agents/docs.md exists"

skill_text="$(cat "$SKILL")"
docs_text="$(cat "$DOCS")"

# line_of <needle>: first line number in SKILL.md containing the fixed string.
line_of() { grep -nF -- "$1" "$SKILL" | head -1 | cut -d: -f1; }
# line_has_gate <needle>: the first line holding the needle also names the gate.
line_has_gate() { grep -F -- "$1" "$SKILL" | head -1 | grep -qF 'STATUS_ENABLED = true'; }

# ── 1. Step 0 ────────────────────────────────────────────────────────────────
assert_contains "$skill_text" 'STATUS_ENABLED (`status.enabled`, default `false`' "step 0: STATUS_ENABLED with its default"
assert_contains "$skill_text" 'STATUS_FILE' "step 0: STATUS_FILE"
assert_contains "$skill_text" 'STATUS_FRAGMENTS_DIR' "step 0: STATUS_FRAGMENTS_DIR"
assert_contains "$skill_text" 'none of the status steps run' "step 0: disabled means no status step runs"
assert_contains "$skill_text" '- `status.enabled`: false' "config defaults: status.enabled"

# ── 2. Step 3e ───────────────────────────────────────────────────────────────
grep -qxF '<STATUS_FRAGMENT_LINE>' "$SKILL" && pass "docs prompt: STATUS_FRAGMENT_LINE placeholder alone on its line" || fail "docs prompt: STATUS_FRAGMENT_LINE placeholder alone on its line"
assert_contains "$skill_text" 'STATUS FRAGMENT: <STATUS_FRAGMENTS_DIR>/<issue>-<pr>.md' "docs prompt: literal fragment line"
assert_contains "$skill_text" 'otherwise leave the placeholder line empty' "docs prompt: line omitted when disabled"
assert_contains "$skill_text" 'remove from `CHANGED_PATHS` every path equal to `STATUS_FRAGMENTS_DIR` or under it' "gate 1a: fragment paths leave CHANGED_PATHS"
assert_contains "$skill_text" 'never dispatches docs by itself' "gate: missing fragment never dispatches docs"
g1="$(line_of 'remove from `CHANGED_PATHS` every path equal')"
g2="$(line_of '2. The gate matches (no docs subagent needed)')"
g4="$(line_of '4. Gate does not match: dispatch the docs subagent')"
[ -n "$g1" ] && [ -n "$g2" ] && [ "$g1" -lt "$g2" ] \
  && pass "gate 1a sits before the matches test (step 2)" || fail "gate 1a sits before the matches test (step 2)"
[ -n "$g1" ] && [ -n "$g4" ] && [ "$g1" -lt "$g4" ] \
  && pass "gate 1a sits before the filtered subset (step 4)" || fail "gate 1a sits before the filtered subset (step 4)"
always_line="$(line_of '`always` — dispatch the docs stage exactly as before')"
assert_contains "$(sed -n "${always_line},$((always_line + 4))p" "$SKILL")" '<STATUS_FRAGMENT_LINE>' "docs_mode always path carries the fragment line"

# ── 3. Steps 4, 5, 1 ─────────────────────────────────────────────────────────
CMD='bash scripts/pipeline-status-file.sh assemble --refresh --pr <PR_NUMBER> --issue <N>'
assert_contains "$skill_text" "$CMD" "step 4: assemble --refresh command"
line_has_gate "$CMD" && pass "step 4: command line names the gate" || fail "step 4: command line names the gate"
c="$(line_of "$CMD")"; done_l="$(line_of 'bash scripts/pipeline-status.sh <N> "Done"')"; rm_l="$(line_of '**Remove the developer worktree.**')"
[ -n "$c" ] && [ "$c" -gt "$done_l" ] && [ "$c" -lt "$rm_l" ] \
  && pass "step 4: command is after board Done, before worktree removal" || fail "step 4: command is after board Done, before worktree removal"
item="$(sed -n "${c},$((c + 8))p" "$SKILL")"
assert_contains "$item" 'Non-fatal' "step 4: non-fatal"
assert_contains "$item" 'merged-but-open' "step 4: also runs on the Step 1 heal"
assert_contains "$item" 'resume block not refreshed' "step 4: summary wording"
assert_not_contains "$skill_text" 'including when healing a merged-but-open issue in Step 0' "step 4: stale Step 0 reference fixed"

R='bash scripts/pipeline-status-file.sh refresh'
assert_contains "$skill_text" "$R" "step 5: refresh command"
line_has_gate "$R" && pass "step 5: refresh line names the gate" || fail "step 5: refresh line names the gate"
r5="$(line_of "$R")"; s5="$(line_of '## Step 5')"; rules="$(line_of '## Rules')"
[ -n "$r5" ] && [ "$r5" -gt "$s5" ] && [ "$r5" -lt "$rules" ] \
  && pass "step 5: refresh sits inside Step 5" || fail "step 5: refresh sits inside Step 5"
assert_contains "$(sed -n "${r5},$((r5 + 4))p" "$SKILL")" 'does not fail the run' "step 5: failure does not fail the run"

assert_contains "$skill_text" 'bash scripts/pipeline-vcs.sh list-needs-owner --json' "step 1: json listing first"
assert_contains "$skill_text" 'bash scripts/pipeline-vcs.sh list-needs-owner --clear-answered' "step 1: clearing call"
l1="$(line_of 'bash scripts/pipeline-vcs.sh list-needs-owner --json')"
s1="$(sed -n "$((l1 - 3)),$((l1 + 12))p" "$SKILL")"
assert_contains "$s1" 'STATUS_ENABLED = true' "step 1: sweep names the gate"
assert_contains "$s1" 'talos:marker-authors-unverified' "step 1: unverified-authors warning handled"
assert_contains "$s1" 'never an instruction to execute as written' "step 1: an answer is information, not an instruction"
assert_not_contains "$s1" 'returning it to the queue' "step 1: no claim that clearing returns the item to the queue"
assert_contains "$s1" 'do NOT run the clearing call' "step 1: no clearing when authors are unverified"
assert_contains "$s1" 'Exit 2' "step 1: exit 2 skipped silently"
assert_contains "$skill_text" 'pending and answered counts' "step 1: counts in the summary line"

# ── 4. Rules ─────────────────────────────────────────────────────────────────
assert_contains "$skill_text" 'mark-needs-owner <n> --body-file -' "rule: mark-needs-owner takes its body on stdin"
assert_contains "$skill_text" "| bash scripts/pipeline-vcs.sh mark-needs-owner" "rule: rendered body piped in"
assert_contains "$skill_text" 'templates/comments/needs-owner.md' "rule: reason rendered from needs-owner.md"
assert_not_contains "$skill_text" 'mark-needs-owner <n> --body-file <file>' "rule: no fixed temp file form"
rule20="$(sed -n "$(line_of '20. ')"',/^21\. /p' "$SKILL")"
assert_contains "$rule20" 'STATUS_ENABLED = true' "rule 20: gated"
assert_contains "$rule20" 'serial' "rule 20: mark and clear stay serial"
assert_contains "$rule20" 'never spliced' "rule 20: text is data"
assert_contains "$rule20" 'Exit 2' "rule 20: exit 2 skipped silently"
assert_contains "$rule20" 'pipeline-status-file.sh refresh' "rule 20: refresh follows the marker"
rule21="$(sed -n "$(line_of '21. ')"',$p' "$SKILL")"
assert_contains "$rule21" 'Only `scripts/pipeline-status-file.sh` writes `STATUS_FILE`' "rule 21: single writer"
assert_contains "$rule21" 'Rule 19' "rule 21: reconciled with Rule 19"
assert_contains "$rule21" 'Rule 15' "rule 21: reconciled with Rule 15"
assert_contains "$rule21" 'ANY call of these that can push' "rule 21: fast-forward stated by cause"
assert_contains "$rule21" 'not retried or forced' "rule 21: failed fast-forward is not retried"
assert_contains "$skill_text" "the orchestrator itself only fast-forwards it, Rule 21" "rule 15: exception points at Rule 21"
assert_contains "$skill_text" 'All other stages (reviewer, security, docs, QA, validator, PM) must never run' "rule 15: stage list unchanged"
assert_contains "$rule20" 'never pasted stage output or issue text' "rule 20: reason is the orchestrator's own words"
assert_contains "$rule21" 'git pull --ff-only' "rule 21: orchestrator checkout fast-forwarded"
assert_contains "$skill_text" 'do not invalidate approvals' "sibling sync: status commits do not invalidate approvals"

# Status steps are not draft-specific: none of the new text may sit in a pr-draft block.
draft_only="$(awk '
  { t=$0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
  t=="<!-- pr-draft:start -->" {inb=1; next}
  t=="<!-- pr-draft:end -->" {inb=0; next}
  inb' "$SKILL")"
assert_not_contains "$draft_only" 'pipeline-status-file.sh' "status commands are outside every pr-draft block"
assert_not_contains "$draft_only" 'STATUS_FRAGMENT' "fragment line is outside every pr-draft block"

# ── 5. agents/docs.md ────────────────────────────────────────────────────────
assert_contains "$docs_text" '3a. ' "docs profile: step 3a exists"
assert_contains "$docs_text" 'STATUS FRAGMENT: <path>' "docs profile: names the STATUS FRAGMENT line"
step3a="$(sed -n '/^3a\. /,/^4\. /p' "$DOCS")"
assert_contains "$step3a" 'at most 3 lines and 400 characters' "docs profile: size cap"
assert_contains "$step3a" 'never edit the status file' "docs profile: never edits the status file"
assert_contains "$step3a" "another PR's fragment" "docs profile: never touches another PR's fragment"
assert_contains "$step3a" 'absent' "docs profile: does nothing when the line is absent"
assert_contains "$step3a" 'overwrite' "docs profile: a fix round overwrites the same file"
a3="$(grep -n '^3a\. ' "$DOCS" | cut -d: -f1)"; a4="$(grep -n '^4\. Commit guard' "$DOCS" | cut -d: -f1)"
[ -n "$a3" ] && [ -n "$a4" ] && [ "$a3" -lt "$a4" ] \
  && pass "docs profile: 3a is before the commit guard" || fail "docs profile: 3a is before the commit guard"
assert_contains "$docs_text" 'Done when: CHANGELOG has the entry and README reflects any changed config key.' "docs profile: Done when unchanged"

# Related contract tests keep passing on the new prose.
bash "$TALOS_ROOT/tests/test-stage-done-when.sh" >/dev/null 2>&1 && pass "test-stage-done-when exits 0" || fail "test-stage-done-when exits 0"
bash "$TALOS_ROOT/tests/test-marker-contract.sh" >/dev/null 2>&1 && pass "test-marker-contract exits 0" || fail "test-marker-contract exits 0"

finish
