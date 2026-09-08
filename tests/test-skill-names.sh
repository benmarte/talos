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

# Extract a fenced (```` ``` ````) block whose first content line contains $2.
extract_block() {  # $1=file $2=anchor substring
  awk -v anchor="$2" '
    /^```$/ { if (in_block) { in_block = 0; next }; in_block = 1; first = 1; next }
    in_block {
      if (first) { first = 0; match_block = (index($0, anchor) > 0) }
      if (match_block) print
    }
  ' "$1"
}

dev_blocks="$(extract_block "$SKILL_MD" "You are the Developer. Implement the PM spec for issue")"
qa_block="$(extract_block "$SKILL_MD" "You are QA. A developer opened a PR for issue")"

assert_contains "$dev_blocks" "quiet" \
  "skills/pipeline/SKILL.md developer prompt block(s) mention quiet verify output"
assert_contains "$qa_block" "quiet" \
  "skills/pipeline/SKILL.md QA prompt block mentions quiet verify output"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "quiet" \
  "agents/developer.md mentions quiet verify output"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "quiet" \
  "agents/qa.md mentions quiet verify output"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.yml.example")" "quiet" \
  "talos.pipeline.yml.example mentions --quiet"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" "quiet" \
  "talos.pipeline.json.example mentions --quiet"

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

# Both developer prompt profiles (worktree and branch isolation) in SKILL.md.
assert_rule_before_all "$SKILL_MD" '^5\. Verify commands' \
  "skills/pipeline/SKILL.md developer prompt: foreground rule precedes step 5"
# The QA prompt in SKILL.md -- rule sits directly beside the QA-mode /
# CI-wait decision (both the ci poll and the local verify branch hang off it).
assert_rule_before_all "$SKILL_MD" 'QA mode above is already resolved' \
  "skills/pipeline/SKILL.md QA prompt: foreground rule precedes verify/CI-wait instruction"
assert_rule_before_all "$TALOS_ROOT/agents/developer.md" \
  'Verify commands — two mutually exclusive' \
  "agents/developer.md: foreground rule precedes verify instruction"
assert_rule_before_all "$TALOS_ROOT/agents/qa.md" 'Check `verify.qa_mode`' \
  "agents/qa.md: foreground rule precedes verify/CI-wait instruction"

# The QA prompt's CI-wait poll must be a literal, single foreground command
# (an `until ... do sleep N; done` loop with a deadline) -- not left for the
# agent to improvise, per the #205 scope addition after PR #206 stalled.
assert_contains "$qa_block" "until" \
  "skills/pipeline/SKILL.md QA prompt writes the CI-wait loop out literally"
assert_contains "$qa_block" "sleep 30" \
  "skills/pipeline/SKILL.md QA prompt CI-wait loop has a literal sleep interval"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "until" \
  "agents/qa.md writes the CI-wait loop out literally"

# ── Mergeability pre-CI check before QA waits on CI (#214) ─────────────────
# A CONFLICTING PR gets no `pull_request` CI run scheduled; QA must check
# pr-mergeable BEFORE its CI wait, not discover a hung wait the hard way.
assert_contains "$qa_block" "pr-mergeable" \
  "skills/pipeline/SKILL.md QA prompt block calls pr-mergeable before the CI wait"
assert_contains "$qa_block" "CONFLICTING" \
  "skills/pipeline/SKILL.md QA prompt block handles a CONFLICTING result"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "pr-mergeable" \
  "agents/qa.md mentions the pr-mergeable pre-CI check"

# The "5. Verify commands" step -- the shared verify-mode + quiet-output
# guidance -- must stay byte-identical between the worktree-isolation and
# branch-isolation developer prompt variants (the surrounding blocks differ,
# e.g. the "Worktree path:" line, so only this step is compared).
find_step_end() {  # $1=file $2=start_line -> line number of "6. `git commit" after start
  awk -v start="$2" 'NR > start && /^6\. `git commit/ { print NR; exit }' "$1"
}
step5_start1=$(grep -n '^5\. Verify commands' "$SKILL_MD" | sed -n '1p' | cut -d: -f1)
step5_start2=$(grep -n '^5\. Verify commands' "$SKILL_MD" | sed -n '2p' | cut -d: -f1)
if [ -n "$step5_start1" ] && [ -n "$step5_start2" ]; then
  step5_end1=$(find_step_end "$SKILL_MD" "$step5_start1")
  step5_end2=$(find_step_end "$SKILL_MD" "$step5_start2")
  step1="$(sed -n "${step5_start1},$((step5_end1 - 1))p" "$SKILL_MD")"
  step2="$(sed -n "${step5_start2},$((step5_end2 - 1))p" "$SKILL_MD")"
  assert_eq "$step1" "$step2" \
    "the two developer prompt blocks' step-5 verify guidance is byte-identical"
else
  fail "the two developer prompt blocks' step-5 verify guidance is byte-identical" \
    "could not locate both step-5 sections"
fi

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

# extract_block above scans every fenced block in the file for the FIRST one
# whose first content line matches the anchor, toggling on every literal
# "```" line -- a ```bash/```yaml opener paired with a plain ``` closer
# elsewhere in the file desyncs that toggle by the time it reaches the
# reviewer/security/docs blocks further down. extract_window instead anchors
# directly on the prompt's own opening line and scans forward for its own
# closing "```", so it can't inherit drift from earlier blocks.
extract_window() {  # $1=file $2=anchor substring
  local file="$1" anchor="$2" start end
  start="$(grep -n -F "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  end="$(awk -v s="$start" 'NR > s && /^```$/ { print NR; exit }' "$file")"
  [ -z "$end" ] && end=$((start + 60))
  sed -n "${start},$((end - 1))p" "$file"
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
# full diff.
assert_contains "$reviewer_block" "diff-pr <PR_NUMBER> --stat" \
  "skills/pipeline/SKILL.md reviewer prompt block reads diff-pr --stat before the full diff"
assert_contains "$security_block" "diff-pr <PR_NUMBER> --stat" \
  "skills/pipeline/SKILL.md security prompt block reads diff-pr --stat before the full diff"
assert_contains "$(cat "$TALOS_ROOT/agents/reviewer.md")" "diff-pr <pr> --stat" \
  "agents/reviewer.md reads diff-pr --stat before the full diff"
assert_contains "$(cat "$TALOS_ROOT/agents/security.md")" "diff-pr <pr> --stat" \
  "agents/security.md reads diff-pr --stat before the full diff"

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
BUILTINS="code-review security-review verify run"

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
