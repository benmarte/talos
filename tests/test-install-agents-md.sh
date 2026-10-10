#!/usr/bin/env bash
# Tests for the per-repo AGENTS.md block written by install.sh (#364): every
# harness gets it, --no-agents-md opts out, --import-agents-md passes through,
# and the paths the block names exist after the documented install. Every
# install runs in the make_sandbox HOME (TALOS_HOME / CLAUDE_CONFIG_DIR unset).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"

new_repo() {
  mkdir -p "$SANDBOX/$1"
  git -C "$SANDBOX/$1" init -q -b main
  printf '%s' "$SANDBOX/$1"
}

bash "$INSTALL" --global --no-agent-skills >/dev/null 2>&1

# ── every harness value, including the default, gets the block ───────────────
for h in default claude codex antigravity; do
  R="$(new_repo "h-$h")"
  if [ "$h" = default ]; then
    out="$(bash "$INSTALL" "$R" --no-agent-skills 2>&1)"
  else
    out="$(bash "$INSTALL" "$R" --no-agent-skills --harness "$h" 2>&1)"
  fi
  assert_file_exists "$R/AGENTS.md" "install.sh writes AGENTS.md for harness: $h"
  agents="$(cat "$R/AGENTS.md")"
  assert_contains "$agents" "<!-- talos:begin -->" "$h: AGENTS.md block is marker-fenced"
  assert_contains "$agents" "~/.talos/skills/pipeline/SKILL.md" "$h: block names the ~/.talos playbook"
  assert_not_contains "$agents" ".claude/skills/pipeline/SKILL.md" "$h: block has no .claude/skills path"
  assert_contains "$out" "commit AGENTS.md" "$h: install output tells the user to commit AGENTS.md"
done

# Re-install: no duplicate block, existing content survives, nothing changes.
R="$SANDBOX/h-codex"
printf '# My notes\n' | cat - "$R/AGENTS.md" > "$R/AGENTS.new" && mv "$R/AGENTS.new" "$R/AGENTS.md"
before="$(cksum < "$R/AGENTS.md")"
out="$(bash "$INSTALL" "$R" --no-agent-skills --harness codex 2>&1)"
assert_eq "1" "$(grep -c 'talos:begin' "$R/AGENTS.md")" "re-install does not duplicate the block"
assert_contains "$(cat "$R/AGENTS.md")" "# My notes" "re-install keeps existing AGENTS.md content"
assert_eq "$before" "$(cksum < "$R/AGENTS.md")" "re-install leaves AGENTS.md byte-identical"
assert_contains "$out" "up to date" "re-install says the block is up to date"

# The block written by main (codex/antigravity) is repaired in place.
R="$(new_repo old-block)"
cat > "$R/AGENTS.md" <<'TALOS_OLDBLOCK_q8m2v6c4jt0z'
# Mine

<!-- talos:begin -->
## Talos pipeline
follow the playbook in .claude/skills/pipeline/SKILL.md exactly.
This harness has no native subagents.
<!-- talos:end -->
TALOS_OLDBLOCK_q8m2v6c4jt0z
bash "$INSTALL" "$R" --no-agent-skills --harness codex >/dev/null 2>&1
agents="$(cat "$R/AGENTS.md")"
assert_eq "1" "$(grep -c 'talos:begin' "$R/AGENTS.md")" "old block is replaced, not duplicated"
assert_contains "$agents" "~/.talos/skills/pipeline/SKILL.md" "repaired block names the ~/.talos playbook"
assert_not_contains "$agents" "no native subagents" "repaired block drops the old claim"
assert_contains "$agents" "# Mine" "repair keeps the text outside the block"

# ── --no-agents-md ───────────────────────────────────────────────────────────
R="$(new_repo optout)"
out="$(bash "$INSTALL" "$R" --no-agent-skills --no-agents-md 2>&1)"; rc=$?
assert_eq "0" "$rc" "--no-agents-md exits 0"
assert_file_absent "$R/AGENTS.md" "--no-agents-md writes no AGENTS.md"
R="$(new_repo optout-codex)"
bash "$INSTALL" "$R" --no-agent-skills --harness codex --no-agents-md >/dev/null 2>&1
assert_file_absent "$R/AGENTS.md" "--no-agents-md also wins for --harness codex"

# ── --import-agents-md passes through ────────────────────────────────────────
R="$(new_repo import)"
printf '# claude\n' > "$R/CLAUDE.md"
before="$(cksum < "$R/CLAUDE.md")"
bash "$INSTALL" "$R" --no-agent-skills >/dev/null 2>&1
assert_eq "$before" "$(cksum < "$R/CLAUDE.md")" "install.sh without --import-agents-md leaves CLAUDE.md byte-identical"
bash "$INSTALL" "$R" --no-agent-skills --import-agents-md >/dev/null 2>&1
assert_contains "$(cat "$R/CLAUDE.md")" "@AGENTS.md" "install.sh --import-agents-md adds the import to CLAUDE.md"
assert_eq "0" "$(grep -c 'talos:begin' "$R/CLAUDE.md")" "the block is never written into CLAUDE.md"
assert_file_absent "$R/GEMINI.md" "install.sh never creates GEMINI.md"

# ── epic bullet: sandbox HOME starts empty; global install, then per-repo ───
# with no --harness. Every ~/.talos/skills path the block names must exist.
case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing: HOME=$HOME is not the sandbox" >&2; exit 1 ;; esac
rm -rf "${HOME:?}/.talos" "${HOME:?}/.claude"
# --harness codex: the outcome must not depend on whether the ambient PATH has
# `claude` (#365), so the global call never creates ~/.claude.
bash "$INSTALL" --global --no-agent-skills --harness codex >/dev/null 2>&1
assert_file_absent "$HOME/.claude" "no ~/.claude is created by --global --harness codex"
R="$(new_repo epic)"
bash "$INSTALL" "$R" --no-agent-skills >/dev/null 2>&1
paths="$(grep -o '~/\.talos/skills/[A-Za-z0-9_-]*/SKILL\.md' "$R/AGENTS.md")"
. "$TALOS_ROOT/scripts/pipeline-contract.sh"
assert_eq "${#TALOS_COMMANDS[@]}" "$(printf '%s\n' "$paths" | grep -c .)" "the block names one playbook path per TALOS_COMMANDS entry"
for p in $paths; do
  assert_file_exists "$HOME/${p#\~/}" "named playbook exists after the documented install: $p"
done
assert_file_exists "$HOME/.talos/skills/pipeline/SKILL.md" "the block path exists although no ~/.claude was created"

finish
