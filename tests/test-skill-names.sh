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
