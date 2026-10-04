#!/usr/bin/env bash
# tests/test-commands-manifest.sh -- the command manifest (#363, part of #353).
#
# scripts/pipeline-contract.sh holds TALOS_COMMANDS, the single list of Talos
# commands (the playbooks under skills/). install.sh --global loops over it
# instead of naming the three skill directories. This test pins the list to
# the skills/ tree so a new playbook cannot be added without a manifest entry
# (or the reverse). skills/pipeline-setup/ is the one extra directory: the
# deprecated /talos:pipeline-setup alias (#335), not a command.
set -u
. "$(dirname "$0")/helpers.sh"

. "$TALOS_ROOT/scripts/pipeline-contract.sh"

if ! declare -p TALOS_COMMANDS >/dev/null 2>&1; then
  fail "TALOS_COMMANDS is defined by scripts/pipeline-contract.sh"
  finish
  exit 1
fi

assert_eq "pipeline setup resume" "${TALOS_COMMANDS[*]}" \
  "TALOS_COMMANDS lists the three commands in order"

# The set of skills/*/ directories holding a SKILL.md equals TALOS_COMMANDS plus
# the alias directory, and the alias is not a command.
DIRS="$(for f in "$TALOS_ROOT"/skills/*/SKILL.md; do [ -f "$f" ] && basename "$(dirname "$f")"; done | sort)"
MANIFEST="$(printf '%s\n' "${TALOS_COMMANDS[@]}" pipeline-setup | sort)"
assert_eq "$MANIFEST" "$DIRS" "skills/*/SKILL.md directories equal TALOS_COMMANDS plus the pipeline-setup alias"
case " ${TALOS_COMMANDS[*]} " in
  *" pipeline-setup "*) fail "pipeline-setup is an alias, not a command" ;;
  *) pass "pipeline-setup is an alias, not a command" ;;
esac

# talos_claude_skill_name was the provisional bare-name mapping; /talos:<command>
# from the plugin replaced it (#335).
if declare -F talos_claude_skill_name >/dev/null 2>&1; then
  fail "talos_claude_skill_name is gone (#335)"
else
  pass "talos_claude_skill_name is gone (#335)"
fi

# The manifest is not part of talos_contract_json.
# Structural, not a substring grep: no object key anywhere in the contract JSON
# is "commands" (a label description may legitimately say the word).
has_commands_key="$(talos_contract_json | python3 -I -c '
import json, sys
def walk(o):
    if isinstance(o, dict):
        return "commands" in o or any(walk(v) for v in o.values())
    if isinstance(o, list):
        return any(walk(v) for v in o)
    return False
print("yes" if walk(json.load(sys.stdin)) else "no")
')"
assert_eq "no" "$has_commands_key" "talos_contract_json does not carry the command manifest"

finish
