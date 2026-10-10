#!/usr/bin/env bash
# test-setup-harness.sh -- skills/setup/SKILL.md runs under any agent (#368, part of #353).
#
# The playbook's wording is not pinned (prose, #556). Checked here: the Step 7c
# fences hold no user-typed text, the frontmatter name, and an execution check:
# the fenced `write` command in Step 7c runs in a sandbox repo, once per runner
# id, and leaves a pre-existing CLAUDE.md byte-identical. Nothing here calls
# install.sh; every path is under the make_sandbox HOME.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

SETUP_MD="$TALOS_ROOT/skills/setup/SKILL.md"
SBX="$(cd "$SANDBOX" && pwd)"

step7c="$(sed -n '/^## Step 7c/,/^## Step 7d/p' "$SETUP_MD")"
[ -n "$step7c" ] && pass "setup skill carries a Step 7c" || fail "setup skill carries a Step 7c" "section not found"

# The fenced commands in Step 7c hold nothing user-typed: the only variable part
# is the <harness> placeholder (an allow-listed runner id), so no user text
# reaches a shell command line.
fences="$(printf '%s\n' "$step7c" | awk '/^```/{inb=!inb; next} inb')"
cmds="$(printf '%s\n' "$fences" | sed 's/<harness>//g')"
case "$cmds" in
  *'$('*|*'`'*|*'<'*|*'>'*) fail "7c fences hold nothing user-typed" "$cmds" ;;
  *) pass "7c fences hold nothing user-typed" ;;
esac
assert_not_contains "$fences" "--import-agents-md" "7c fences never pass --import-agents-md on the first run"

# The harness reads the frontmatter name (/talos:setup, #335).
assert_eq "setup" "$(sed -n '2p' "$SETUP_MD" | sed 's/^name: //')" "frontmatter name is setup (/talos:setup, #335)"

# (7) Execute the fenced write command: one Talos block, CLAUDE.md untouched.
# Guard: every write under $HOME must stay inside the sandbox.
case "$HOME" in "$SANDBOX"/*) ;; *) echo "test-setup-harness: HOME is outside the sandbox; aborting" >&2; exit 1 ;; esac
mkdir -p "$HOME/.talos/skills/pipeline" && : > "$HOME/.talos/skills/pipeline/SKILL.md"
awk '/^```bash$/{buf=""; inb=1; next} /^```$/{ if (inb && buf ~ /pipeline-instructions\.sh write/) printf "%s", buf; inb=0; buf=""; next} inb{buf = buf $0 "\n"}' "$SETUP_MD" > "$SBX/write.tpl"
assert_eq "1" "$([ -s "$SBX/write.tpl" ] && echo 1 || echo 0)" "the setup skill has a write block"
assert_eq "1" "$(wc -l < "$SBX/write.tpl" | tr -d ' ')" "the write block is a single command"
for e in "${TALOS_RUNNERS[@]}"; do
  id="${e%%|*}"
  R="$SBX/run-$id"; mkdir -p "$R"; git -C "$R" init -q -b main
  printf '# project rules\n' > "$R/CLAUDE.md"
  sum_before="$(cksum < "$R/CLAUDE.md")"
  sed -e "s|scripts/|$TALOS_ROOT/scripts/|g" -e "s|<harness>|$id|g" "$SBX/write.tpl" > "$SBX/write-$id.sh"
  (cd "$R" && bash "$SBX/write-$id.sh" >/dev/null 2>&1); rc1=$?
  (cd "$R" && bash "$SBX/write-$id.sh" >/dev/null 2>&1); rc2=$?
  assert_eq "00" "$rc1$rc2" "write ($id) exits 0 twice"
  assert_eq "1" "$(grep -c -x -F '<!-- talos:begin -->' "$R/AGENTS.md")" "write ($id): AGENTS.md has exactly one Talos block after two runs"
  assert_eq "$sum_before" "$(cksum < "$R/CLAUDE.md")" "write ($id): CLAUDE.md is byte-identical"
done

finish
