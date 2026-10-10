#!/usr/bin/env bash
# Every skill a role profile names must exist in agent-skills (#43), checked
# statically against tests/fixtures/agent-skills.txt (#556: the old
# test-skill-names.sh cloned the upstream repo, so it needed the network and
# skipped when offline).
#
# The profiles direct roles to use skills by bare name. A typo, or a skill
# renamed upstream, produces no error at runtime -- the role simply never
# invokes it and quietly falls back to its embedded instructions.
set -u
. "$(dirname "$0")/helpers.sh"

KNOWN="$TALOS_ROOT/tests/fixtures/agent-skills.txt"
assert_file_exists "$KNOWN" "tests/fixtures/agent-skills.txt exists"

# Names Talos's own profiles and Claude Code provide; not agent-skills' job.
# verifying-agent-gate-verdicts/testing-llm-gated-pipelines (agents/adversarial.md)
# are locally installed skills the marketplace repo does not ship.
BUILTINS="code-review security-review verify run verifying-agent-gate-verdicts testing-llm-gated-pipelines"

checked=0
missing=0
for f in "$TALOS_ROOT"/agents/*.md; do
  role="$(basename "$f" .md)"
  # Backticked, hyphenated, lowercase tokens are how the profiles name skills;
  # only multi-word ones look like skills.
  for name in $(tr '\n' ' ' < "$f" | grep -oE '`[a-z][a-z-]+`' | tr -d '`' | sort -u); do
    case " $BUILTINS " in *" $name "*) continue ;; esac
    case "$name" in *-*-*) ;; *) continue ;; esac
    checked=$((checked + 1))
    if grep -qxF "$name" "$KNOWN"; then
      pass "$role: skill '$name' is in the agent-skills list"
    else
      fail "$role: skill '$name' is in the agent-skills list" \
        "not in tests/fixtures/agent-skills.txt (typo, or add it there)"
      missing=$((missing + 1))
    fi
  done
done

if [ "$checked" -gt 0 ]; then
  pass "the profiles name $checked skill reference(s), all checked"
else
  fail "the profiles name at least one agent-skills skill" "none found: the extraction regex rotted"
fi
assert_eq "0" "$missing" "no role names a skill that agent-skills does not ship"

finish
