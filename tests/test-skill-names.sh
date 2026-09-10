#!/usr/bin/env bash
# Every skill named in a role profile must actually exist in agent-skills (#43).
#
# The profiles direct roles to use skills by bare name. A typo, or a skill
# renamed upstream, produces no error at runtime — the role simply never invokes
# it and quietly falls back to its embedded instructions. Nothing else in the
# suite would catch that.
#
# This is the one test that needs the network. It SKIPS rather than fails when
# the clone does not work, so offline runs and forks without network stay green.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

# ── Quiet-verify guidance in prompts and example configs (#198) ────────────
# A green verify run is hundreds of lines that every developer/QA stage pays
# for in context, for information nobody reads when the run is green. The
# developer and QA prompts should steer stage agents toward summary verify
# output (e.g. `--quiet`) and toward quoting only failures. Offline, no
# network required -- runs before the agent-skills clone below so it still
# executes on the skip paths.

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"

# Extract the fenced (```` ``` ````) block whose opening line contains $2,
# by anchoring directly on that line and scanning forward for its own
# closing "```" -- a ```bash/```yaml snippet nested in the surrounding prose
# (e.g. the assert-sync precondition ahead of the developer prompt) would
# desync a naive every-```-toggles approach, so this anchors on the prompt's
# own first line instead of counting fences from the top of the file.
extract_window() {  # $1=file $2=anchor substring
  local file="$1" anchor="$2" start end
  start="$(grep -n -F "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  end="$(awk -v s="$start" 'NR > s && /^```$/ { print NR; exit }' "$file")"
  [ -z "$end" ] && end=$((start + 60))
  sed -n "${start},$((end - 1))p" "$file"
}

dev_blocks="$(extract_window "$SKILL_MD" "You are the Developer. Implement")"
qa_block="$(extract_window "$SKILL_MD" "You are QA. A developer opened a PR for issue")"

# quiet-verify guidance is role methodology (#179): it now lives once in each
# role's agent profile rather than being restated in the SKILL.md task prompt.
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "quiet" \
  "agents/developer.md mentions quiet verify output"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "quiet" \
  "agents/qa.md mentions quiet verify output"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.yml.example")" "quiet" \
  "talos.pipeline.yml.example mentions --quiet"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" "quiet" \
  "talos.pipeline.json.example mentions --quiet"

# ── Per-role runner dispatch rule (#167) ────────────────────────────────────
# The native-vs-adapter decision is made per role, not once for the whole
# pipeline: a role whose effective runner (agents.roles.<role>.runner, else
# agents.runner) is not claude must be dispatched via pipeline-agent.sh even
# while the rest of the pipeline runs native subagents. Assert the rule text
# and the shared --resolve helper are actually in SKILL.md's harness-
# compatibility section, not just implemented in the scripts.
harness_section="$(extract_window "$SKILL_MD" "Harness compatibility")"
assert_contains "$harness_section" "resolved per role" \
  "SKILL.md harness-compatibility section states the runner is resolved per role"
assert_contains "$harness_section" "agents.roles.<role>.runner" \
  "SKILL.md harness-compatibility section names the per-role runner key"
assert_contains "$harness_section" "pipeline-agent.sh --resolve" \
  "SKILL.md harness-compatibility section points at the shared --resolve helper"
assert_contains "$harness_section" "even while the rest of the pipeline stays native" \
  "SKILL.md harness-compatibility section states a non-claude role dispatches via pipeline-agent.sh even in native mode"

# ── Verify identity is mechanical, not instruction-based (#186) ────────────
# Every verify instruction in the developer/QA prompts must route through
# pipeline-verify.sh, which exports TALOS_ISSUE_NUMBER/TALOS_WORKTREE_PATH
# itself, instead of asking the agent to `export` them by hand -- a stage
# that ignored a hand-export instruction silently ran verify without the
# identity vars.
assert_contains "$dev_blocks" "pipeline-verify.sh" \
  "skills/pipeline/SKILL.md developer prompt block(s) run verify through pipeline-verify.sh"
assert_contains "$qa_block" "pipeline-verify.sh" \
  "skills/pipeline/SKILL.md QA prompt block runs verify through pipeline-verify.sh"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "pipeline-verify.sh" \
  "agents/developer.md runs verify through pipeline-verify.sh"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "pipeline-verify.sh" \
  "agents/qa.md runs verify through pipeline-verify.sh"
assert_not_contains "$dev_blocks" "export TALOS_ISSUE_NUMBER=" \
  "skills/pipeline/SKILL.md developer prompt block(s) no longer instruct a hand-written export"
assert_not_contains "$qa_block" "export TALOS_ISSUE_NUMBER=" \
  "skills/pipeline/SKILL.md QA prompt block no longer instructs a hand-written export"

# ── Foreground rule adjacent to every verify instruction (#205) ────────────
# Rule 17 already forbade backgrounding verify, but as prose ~400 lines away
# from the actual verify instruction developers missed it three separate
# times (#166, #173, #196) and QA missed the equivalent CI-wait poll once
# (#206). The rule must sit within N lines *before* the instruction it
# governs so it is unmissable at the decision point.
assert_rule_before_all() {  # $1=file $2=anchor-regex $3=label-prefix $4=max-lines-before
  local file="$1" anchor="$2" label_prefix="$3" maxd="${4:-5}"
  local anchor_lines
  anchor_lines="$(grep -n -E "$anchor" "$file" | cut -d: -f1)"
  if [ -z "$anchor_lines" ]; then
    fail "$label_prefix" "anchor not found: $anchor"
    return
  fi
  local idx=0 line start window
  for line in $anchor_lines; do
    idx=$((idx + 1))
    start=$((line - maxd))
    [ "$start" -lt 1 ] && start=1
    window="$(sed -n "${start},$((line - 1))p" "$file")"
    case "$window" in
      *"Foreground rule:"*) pass "$label_prefix (occurrence $idx, line $line)" ;;
      *) fail "$label_prefix (occurrence $idx, line $line)" \
           "no 'Foreground rule:' within $maxd lines before line $line" ;;
    esac
  done
}

# The full workflow (including the foreground-rule / verify-mode narrative)
# now lives once in each role's agent profile (#179) -- SKILL.md's task
# prompts only carry per-issue values and a pointer to the profile. So the
# proximity check runs against the profiles, which is where a stage agent
# actually reads its verify instructions from.
assert_rule_before_all "$TALOS_ROOT/agents/developer.md" \
  'Verify commands — two mutually exclusive' \
  "agents/developer.md: foreground rule precedes verify instruction"
assert_rule_before_all "$TALOS_ROOT/agents/qa.md" 'Check `verify.qa_mode`' \
  "agents/qa.md: foreground rule precedes verify/CI-wait instruction"

# The QA prompt's CI-wait poll must be a literal, single foreground command
# (an `until ... do sleep N; done` loop with a deadline) -- not left for the
# agent to improvise, per the #205 scope addition after PR #206 stalled.
# This procedure lives in agents/qa.md (#179); SKILL.md's QA task prompt no
# longer restates it.
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "until" \
  "agents/qa.md writes the CI-wait loop out literally"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "sleep 30" \
  "agents/qa.md CI-wait loop has a literal sleep interval"

# ── Mergeability pre-CI check before QA waits on CI (#214) ─────────────────
# A CONFLICTING PR gets no `pull_request` CI run scheduled; QA must check
# pr-mergeable BEFORE its CI wait, not discover a hung wait the hard way.
# This procedure lives in agents/qa.md (#179).
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "pr-mergeable" \
  "agents/qa.md mentions the pr-mergeable pre-CI check"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "CONFLICTING" \
  "agents/qa.md handles a CONFLICTING result"

# ── Developer worktree/branch variants merged into one block (#179) ────────
# SKILL.md used to carry two near-identical developer prompt blocks (one per
# isolation mode); they are now a single block with a two-line isolation
# note as the only difference the orchestrator substitutes. Guard against
# the duplication creeping back.
_dev_block_count="$(grep -c 'You are the Developer\. Implement' "$SKILL_MD")"
assert_eq "1" "$_dev_block_count" \
  "skills/pipeline/SKILL.md carries exactly one developer prompt block (worktree/branch merged)"
assert_contains "$dev_blocks" "ISOLATION_NOTE" \
  "skills/pipeline/SKILL.md developer prompt block carries the isolation-note placeholder"

# ── Compact stage handoff: every role's first view-issue call uses --spec,
# reviewer/security read diff-pr --stat first (#201) ────────────────────────
# Busy issue threads accumulate a verdict/marker/attempt comment per stage;
# `view-issue --spec` trims that down to the issue body plus the latest PM
# spec comment. A role prompt's FIRST `view-issue` invocation (the one used
# to establish initial context) must use `--spec` -- a later, explicit full
# `view-issue` (no `--spec`) or `read-comments` call, used only when a prior
# verdict is referenced (fix rounds), is fine and expected.

# Checks that the first `view-issue` occurrence in $1 (if any) is paired
# with `--spec` on the same or the following line (prompt text sometimes
# wraps across lines). A prompt with no `view-issue` call at all passes
# vacuously -- reviewer/security/docs read the diff, not the issue, and
# nothing in this check requires them to.
assert_first_view_issue_uses_spec() {  # $1=text $2=label
  local text="$1" label="$2"
  local lineno
  lineno="$(printf '%s\n' "$text" | grep -n 'view-issue' | head -1 | cut -d: -f1)"
  if [ -z "$lineno" ]; then
    pass "$label (no view-issue call present)"
    return
  fi
  local window
  window="$(printf '%s\n' "$text" | sed -n "${lineno},$((lineno + 1))p")"
  case "$window" in
    *"view-issue"*"--spec"*) pass "$label" ;;
    *) fail "$label" "first view-issue call has no --spec: $(printf '%s' "$window" | head -c 200)" ;;
  esac
}

reviewer_block="$(extract_window "$SKILL_MD" "You are the Reviewer. QA passed PR")"
security_block="$(extract_window "$SKILL_MD" "You are the Security Analyst. QA passed PR")"
docs_block="$(extract_window "$SKILL_MD" "You are Documentation. QA passed for PR")"

assert_first_view_issue_uses_spec "$dev_blocks" \
  "skills/pipeline/SKILL.md developer prompt block(s): first view-issue call uses --spec"
assert_first_view_issue_uses_spec "$qa_block" \
  "skills/pipeline/SKILL.md QA prompt block: first view-issue call uses --spec"
assert_first_view_issue_uses_spec "$reviewer_block" \
  "skills/pipeline/SKILL.md reviewer prompt block: first view-issue call uses --spec"
assert_first_view_issue_uses_spec "$security_block" \
  "skills/pipeline/SKILL.md security prompt block: first view-issue call uses --spec"
assert_first_view_issue_uses_spec "$docs_block" \
  "skills/pipeline/SKILL.md docs prompt block: first view-issue call uses --spec"

for _role in developer qa reviewer security docs; do
  assert_first_view_issue_uses_spec "$(cat "$TALOS_ROOT/agents/$_role.md")" \
    "agents/$_role.md: first view-issue call uses --spec"
done

# Reviewer and security prompts read the cheap per-file summary before the
# full diff. This procedure lives in the agent profiles (#179); SKILL.md's
# reviewer/security task prompts point at the profile instead of restating it.
assert_contains "$(cat "$TALOS_ROOT/agents/reviewer.md")" "diff-pr <pr> --stat" \
  "agents/reviewer.md reads diff-pr --stat before the full diff"
assert_contains "$(cat "$TALOS_ROOT/agents/security.md")" "diff-pr <pr> --stat" \
  "agents/security.md reads diff-pr --stat before the full diff"

# ── SKILL.md role blocks stay task prompts, not restated methodology (#179) ─
# Each role's SKILL.md block is now per-issue values + a pointer to the role
# profile, not a full workflow. Cap each block's line count so the
# duplication this issue removed cannot silently creep back in.
validator_block="$(extract_window "$SKILL_MD" "You are the Validator. Issue")"
pm_block="$(extract_window "$SKILL_MD" "You are the Project Manager. Issue")"

_assert_block_max_lines() {  # $1=block-text $2=label $3=max-lines (default 40)
  local text="$1" label="$2" max="${3:-40}" n
  n="$(printf '%s\n' "$text" | grep -c '')"
  if [ "$n" -le "$max" ]; then
    pass "$label ($n <= $max lines)"
  else
    fail "$label" "$n lines, expected <= $max"
  fi
}

_assert_block_max_lines "$validator_block" "skills/pipeline/SKILL.md validator prompt block is <= 40 lines"
_assert_block_max_lines "$pm_block" "skills/pipeline/SKILL.md PM prompt block is <= 40 lines"
_assert_block_max_lines "$dev_blocks" "skills/pipeline/SKILL.md developer prompt block is <= 40 lines"
_assert_block_max_lines "$qa_block" "skills/pipeline/SKILL.md QA prompt block is <= 40 lines"
_assert_block_max_lines "$reviewer_block" "skills/pipeline/SKILL.md reviewer prompt block is <= 40 lines"
_assert_block_max_lines "$security_block" "skills/pipeline/SKILL.md security prompt block is <= 40 lines"
_assert_block_max_lines "$docs_block" "skills/pipeline/SKILL.md docs prompt block is <= 40 lines"

# ── Adversarial pre-merge stage (#237) ──────────────────────────────────────
# Optional stage: Step 3e Phase 3 (after security) and Step 4's merge gate
# must both know about it, and the profile must carry its whole method
# inline -- a harness with no skill mechanism has nothing else to go on.
assert_contains "$(cat "$SKILL_MD")" \
  "Phase 3 — Adversarial (if \`roles.adversarial = true\`" \
  "skills/pipeline/SKILL.md has the Phase 3 adversarial dispatch section"
assert_contains "$(cat "$SKILL_MD")" \
  "\`adversarial:approved\` present (if roles.adversarial = true" \
  "skills/pipeline/SKILL.md Step 4 gate list requires adversarial:approved when enabled"

ADVERSARIAL_MD="$TALOS_ROOT/agents/adversarial.md"
assert_file_exists "$ADVERSARIAL_MD" "agents/adversarial.md exists"
adv_flat="$(tr '\n' ' ' < "$ADVERSARIAL_MD" | tr -s ' ')"

# Self-contained: every embedded method step (from the issue #237 addendum)
# must actually be present in the profile body, in plain text a small local
# model can follow -- not just referenced via a skill name that may not
# exist on that harness.
for phrase in \
  "diff-pr <pr> --stat" \
  "revert-in-mind" \
  "3 inputs that should match" \
  "secret-shaped strings" \
  "Check every claim" \
  "CLEAR or FINDINGS"; do
  assert_contains "$adv_flat" "$phrase" \
    "agents/adversarial.md embeds method step: '$phrase'"
done

# Skill list: the six #237 skills, named explicitly.
for skill in \
  "agent-skills:doubt-driven-development" \
  "agent-skills:security-and-hardening" \
  "agent-skills:code-review-and-quality" \
  "superpowers:verification-before-completion" \
  "verifying-agent-gate-verdicts" \
  "testing-llm-gated-pipelines"; do
  assert_contains "$adv_flat" "$skill" \
    "agents/adversarial.md names skill: $skill"
done

# The agent-skills-plugin sentence must reuse the exact tail every other
# profile shares verbatim (qa.md's version is the one #237's spec addendum
# points at), not a bespoke "if available" phrasing invented for this
# profile. Extracted from a flattened (newline-collapsed) copy of qa.md so
# wrapping differences between profiles don't affect the comparison -- the
# anchor phrase can sit mid-line in either file.
qa_flat="$(tr '\n' ' ' < "$TALOS_ROOT/agents/qa.md" | tr -s ' ')"
qa_tail_flat="${qa_flat#*If your harness has no skill mechanism}"
qa_tail_flat="If your harness has no skill mechanism${qa_tail_flat%%as well as Claude Code.*}as well as Claude Code."
assert_contains "$adv_flat" "$qa_tail_flat" \
  "agents/adversarial.md's agent-skills sentence matches qa.md's verbatim (harness-portability tail)"

# ── hooks.post_stage: Rule 3 in the conversation-stream section (#182) ─────
assert_contains "$(cat "$SKILL_MD")" \
  "Rule 3 — Post-stage hook" \
  "skills/pipeline/SKILL.md has the Rule 3 (post-stage hook) orchestrator rule"
assert_contains "$(cat "$SKILL_MD")" \
  "bash scripts/pipeline-hooks.sh post_stage <event> <role> <N>" \
  "skills/pipeline/SKILL.md Rule 3 gives the literal post_stage invocation"

# ── Per-stage cost accounting (#202): Rule 3 usage-passthrough sentence and
# the Step 5 cost mention ───────────────────────────────────────────────────
assert_contains "$(cat "$SKILL_MD")" \
  "When the harness completion notification carries usage (subagent_tokens, tool_uses, duration_ms), pass them as \`--tokens\`, \`--tool-uses\`, \`--duration-s\` (ms/1000, integer)" \
  "skills/pipeline/SKILL.md Rule 3 tells the orchestrator to pass harness usage through to post_stage"
assert_contains "$(cat "$SKILL_MD")" \
  "pipeline-events.sh cost" \
  "skills/pipeline/SKILL.md Step 5 mentions the cost summary"

# ── Usage-reporting spawn form (#259): every role names the same spawn
# form ───────────────────────────────────────────────────────────────────
# reviewer/security/validator/docs events logged null tokens while
# developer/QA logged real numbers -- not a post_stage bug, but a spawn-form
# gap (worktree isolation + Agent-tool spawn yields a usage-bearing
# completion notification; a named non-isolated agent spawn reports via a
# no-usage mailbox message instead). The Harness compatibility section must
# name every role and require them all to use the one spawn form that
# reports usage, and Rule 3 must call out a usage-less completion as a
# playbook bug rather than something to shrug off as --tokens 0.
spawn_rule_line="$(grep -n "Usage-reporting spawn form" "$SKILL_MD" | head -1 | cut -d: -f1)"
if [ -z "$spawn_rule_line" ]; then
  fail "skills/pipeline/SKILL.md has a Usage-reporting spawn form rule" "not found"
else
  spawn_rule_text="$(sed -n "${spawn_rule_line}p" "$SKILL_MD")"
  for role in developer QA reviewer security validator docs adversarial planner; do
    assert_contains "$spawn_rule_text" "$role" \
      "Usage-reporting spawn form rule names role: $role"
  done
  assert_contains "$spawn_rule_text" "background/async" \
    "Usage-reporting spawn form rule names the background/async spawn form"
  assert_contains "$spawn_rule_text" "subagent_tokens" \
    "Usage-reporting spawn form rule names the usage fields the notification must carry"
fi

assert_contains "$(cat "$SKILL_MD")" \
  "a stage completion without usage is a playbook bug" \
  "skills/pipeline/SKILL.md Rule 3 flags a usage-less completion as a playbook bug, not a real zero"

REPO="${TALOS_AGENT_SKILLS_REPO:-https://github.com/addyosmani/agent-skills}"

if ! command -v git >/dev/null 2>&1; then
  echo "  -- skipped: git not on PATH"
  finish
  exit $?
fi

if ! git clone --depth 1 --quiet "$REPO" "$SANDBOX/pack" 2>/dev/null; then
  echo "  -- skipped: could not reach $REPO (offline?)"
  finish
  exit $?
fi

# Names Talos's own profiles and Claude Code provide; not agent-skills' job.
# verifying-agent-gate-verdicts/testing-llm-gated-pipelines (#237, agents/
# adversarial.md) are locally-installed skills, not shipped by the
# addyosmani/agent-skills marketplace repo this loop clones -- excluded for
# the same reason code-review/security-review/verify/run are.
BUILTINS="code-review security-review verify run verifying-agent-gate-verdicts testing-llm-gated-pipelines"

available="$(ls "$SANDBOX/pack/skills" 2>/dev/null)"
if [ -z "$available" ]; then
  fail "agent-skills clone contains a skills/ directory"
  finish
  exit $?
fi
pass "agent-skills clone contains a skills/ directory"

missing=0
for f in "$TALOS_ROOT"/agents/*.md; do
  role="$(basename "$f" .md)"
  # Backticked, hyphenated, lowercase tokens are how the profiles name skills.
  for name in $(tr '\n' ' ' < "$f" | grep -oE '`[a-z][a-z-]+`' | tr -d '`' | sort -u); do
    case " $BUILTINS " in *" $name "*) continue ;; esac
    # Only consider names that look like skills (multi-word, hyphenated).
    case "$name" in *-*-*) ;; *) continue ;; esac
    if printf '%s\n' "$available" | grep -qx "$name"; then
      pass "$role: skill '$name' exists upstream"
    else
      fail "$role: skill '$name' exists upstream" "not found in agent-skills/skills/"
      missing=$((missing + 1))
    fi
  done
done

assert_eq "0" "$missing" "no role names a skill that agent-skills does not ship"

finish
