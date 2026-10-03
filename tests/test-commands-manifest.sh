#!/usr/bin/env bash
# tests/test-commands-manifest.sh -- the command manifest (#363, part of #353).
#
# scripts/pipeline-contract.sh holds TALOS_COMMANDS, the single list of Talos
# commands (the playbooks under skills/). install.sh --global loops over it
# instead of naming the three skill directories. This test pins the list to
# the skills/ tree so a new playbook cannot be added without a manifest entry
# (or the reverse), and checks talos_claude_skill_name, the Claude-name mapping.
set -u
. "$(dirname "$0")/helpers.sh"

. "$TALOS_ROOT/scripts/pipeline-contract.sh"

if ! declare -p TALOS_COMMANDS >/dev/null 2>&1; then
  fail "TALOS_COMMANDS is defined by scripts/pipeline-contract.sh"
  finish
  exit 1
fi

assert_eq "pipeline pipeline-setup resume" "${TALOS_COMMANDS[*]}" \
  "TALOS_COMMANDS lists the three commands in order"

# The set of skills/*/ directories holding a SKILL.md equals TALOS_COMMANDS.
DIRS="$(for f in "$TALOS_ROOT"/skills/*/SKILL.md; do [ -f "$f" ] && basename "$(dirname "$f")"; done | sort)"
MANIFEST="$(printf '%s\n' "${TALOS_COMMANDS[@]}" | sort)"
assert_eq "$MANIFEST" "$DIRS" "skills/*/SKILL.md directories equal TALOS_COMMANDS"

# talos_claude_skill_name: resume is installed as talos-resume (Claude Code has
# a built-in /resume); every other command keeps its own name.
assert_eq "talos-resume" "$(talos_claude_skill_name resume)" "talos_claude_skill_name resume -> talos-resume"
assert_eq "pipeline" "$(talos_claude_skill_name pipeline)" "talos_claude_skill_name pipeline -> pipeline"
assert_eq "pipeline-setup" "$(talos_claude_skill_name pipeline-setup)" "talos_claude_skill_name pipeline-setup -> pipeline-setup"
assert_eq "newcmd" "$(talos_claude_skill_name newcmd)" "talos_claude_skill_name is the identity for any other command"

# The manifest is not part of talos_contract_json.
assert_not_contains "$(talos_contract_json)" "commands" "talos_contract_json does not carry the command manifest"

finish
