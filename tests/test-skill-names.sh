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
