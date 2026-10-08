#!/usr/bin/env bash
# test-setup-harness.sh -- skills/setup/SKILL.md runs under any agent (#368, part of #353).
#
# Structural checks on the playbook text (Step 6b offers every runner id,
# Step 7 records pi and antigravity, the new Step 7c drives
# pipeline-instructions.sh, both start forms are named, no Claude-only tool
# names) plus one execution check: the fenced `write` command in Step 7c runs
# in a sandbox repo, once per runner id, and leaves a pre-existing CLAUDE.md
# byte-identical. Nothing here calls install.sh; every path is under the
# make_sandbox HOME.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

SETUP_MD="$TALOS_ROOT/skills/setup/SKILL.md"
SBX="$(cd "$SANDBOX" && pwd)"

step6b="$(sed -n '/^## Step 6b/,/^## Step 6c/p' "$SETUP_MD")"
step6c="$(sed -n '/^## Step 6c/,/^## Step 7 /p' "$SETUP_MD")"
step7="$(sed -n '/^## Step 7 /,/^## Step 7b/p' "$SETUP_MD")"
step7c="$(sed -n '/^## Step 7c/,/^## Step 7d/p' "$SETUP_MD")"
step0="$(sed -n '/^## Step 0/,/^## Step 1 /p' "$SETUP_MD")"
[ -n "$step6b" ] && [ -n "$step7" ] && pass "setup skill carries Steps 6b and 7" || fail "setup skill carries Steps 6b and 7" "section not found"
[ -n "$step7c" ] && pass "setup skill carries a Step 7c" || fail "setup skill carries a Step 7c" "section not found"

# (1) Step 6b offers exactly the ids in TALOS_RUNNERS.
want="$(for e in "${TALOS_RUNNERS[@]}"; do printf '%s\n' "${e%%|*}"; done | sort)"
have="$(printf '%s\n' "$step6b" | sed -n 's/^> - \*\*\([a-z][a-z-]*\)\*\*.*/\1/p' | sort)"
assert_eq "$want" "$have" "Step 6b offers exactly the TALOS_RUNNERS ids"

# The default rule: Claude Code defaults to claude, any other agent has no default.
flat6b="$(printf '%s' "$step6b" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat6b" "If you are Claude Code" "6b: a Claude Code agent defaults to claude"
assert_contains "$flat6b" "no default" "6b: any other agent has no default"
assert_contains "$flat6b" "until" "6b: asks again until answered"

# (2) The Step 7 template (_note + bullets) and the summary line list all six ids.
flat7="$(printf '%s' "$step7" | tr '\n' ' ' | tr -s ' ')"
sum_line="$(grep '^Harness: ' "$SETUP_MD")"
grep -qF '"runner": "<HARNESS>"' "$SETUP_MD" && pass "the template writes agents.runner" || fail "the template writes agents.runner" 'no \"runner\": \"<HARNESS>\" in the playbook'
for e in "${TALOS_RUNNERS[@]}"; do
  id="${e%%|*}"
  grep -qw -- "$id" <<<"$flat7" && pass "template lists $id" || fail "template lists $id" "$flat7"
  grep -qw -- "$id" <<<"$sum_line" && pass "summary Harness: line lists $id" || fail "summary Harness: line lists $id" "$sum_line"
done

# (3) No Claude-only tool names anywhere in the playbook.
leak="$(grep -nE 'AskUserQuestion|TodoWrite|ScheduleWakeup|subagent_type' "$SETUP_MD")"
assert_eq "" "$leak" "no AskUserQuestion / TodoWrite / ScheduleWakeup / subagent_type in the playbook"

# (4) Step 7 records pi (inline mode) and antigravity.
assert_contains "$flat7" '"subagents": false' "Step 7 writes \"subagents\": false for pi"
assert_contains "$flat7" '"runner": "antigravity"' "Step 7 writes \"runner\": \"antigravity\" (json key, #526)"
assert_contains "$flat7" '"runner": "pi"' "Step 7 writes \"runner\": \"pi\" (json key, #526)"

# Step 6c: model config applies only to native claude-routed roles.
flat6c="$(printf '%s' "$step6c" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat6c" "agents.roles.<role>.runner" "6c: model applies only to roles whose runner is claude"
assert_contains "$flat6c" "runner_cmd" "6c: other runners choose the model in their own CLI or runner_cmd"

# (5) Step 7c drives pipeline-instructions.sh, never writes into CLAUDE.md / GEMINI.md.
flat7c="$(printf '%s' "$step7c" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat7c" "pipeline-instructions.sh print" "7c shows the block with print"
assert_contains "$flat7c" "pipeline-instructions.sh write . --harness" "7c writes with write . --harness"
assert_contains "$flat7c" "--import-agents-md" "7c names --import-agents-md for the second question"
assert_contains "$flat7c" "AGENTS.md" "7c names AGENTS.md"
assert_contains "$flat7c" "commit" "7c tells the user to commit"
assert_contains "$flat7c" "never written into" "7c: the Talos block is never written into CLAUDE.md or GEMINI.md"
assert_contains "$flat7c" "left unchanged" "7c reads write's skip output (left unchanged)"
assert_contains "$flat7c" "symlink" "7c reads write's skip output (symlink)"
assert_contains "$flat7c" "not a regular file" "7c reads write's skip output (not a regular file)"
assert_contains "$flat7c" "never" "7c never passes --import-agents-md on the first run"
assert_not_contains "$flat7c" "--resolve-profile" "7c does not use --resolve-profile"
fences="$(printf '%s\n' "$step7c" | awk '/^```/{inb=!inb; next} inb')"
cmds="$(printf '%s\n' "$fences" | sed 's/<harness>//g')"
case "$cmds" in
  *'$('*|*'`'*|*'<'*|*'>'*) fail "7c fences hold nothing user-typed" "$cmds" ;;
  *) pass "7c fences hold nothing user-typed" ;;
esac
# The allow-list rule sits before the write fence: the six ids inline, "exactly one of".
pre_write="$(printf '%s\n' "$step7c" | sed '/pipeline-instructions.sh write/,$d' | tr '\n' ' ' | tr -s ' ')"
assert_contains "$pre_write" "exactly one of" "7c: <harness> must be exactly one of the listed ids, before the write command"
for e in "${TALOS_RUNNERS[@]}"; do
  assert_contains "$pre_write" "\`${e%%|*}\`" "7c allow-list names ${e%%|*} before the write command"
done
assert_contains "$pre_write" "never put any other value on a command line" "7c: no unlisted value goes on a command line"
assert_contains "$pre_write" "ask Step 6b" "7c: an unlisted value re-asks Step 6b or skips"
assert_contains "$flat6b" "not an \`install.sh --harness\` value" "6b: a runner id is not an install.sh --harness value"
assert_contains "$flat7c" "not \`install.sh\`" "7c: the import re-run uses write, not install.sh"
assert_not_contains "$fences" "--import-agents-md" "7c fences never pass --import-agents-md on the first run"

# The re-run path (Step 0) reaches Step 7c and takes the harness from config.
flat0="$(printf '%s' "$step0" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat0" "Step 7c" "re-run path reaches Step 7c"
assert_contains "$flat0" "agents.runner" "re-run path reads agents.runner from config"
# Step 7c must be its own list item: inside the status.enabled-unset item it is
# skipped on a config whose status block is already enabled.
status_item="$(printf '%s\n' "$step0" | grep '^- .*status\.enabled')"
c7_item="$(printf '%s\n' "$step0" | grep '^- .*Step 7c')"
assert_not_contains "$status_item" "Step 7c" "re-run: Step 7c is not inside the status.enabled-unset item"
assert_not_contains "$c7_item" "status.enabled" "re-run: the Step 7c item does not depend on status.enabled"
assert_contains "$c7_item" "agents.runner" "re-run: the Step 7c item reads agents.runner from config"

# (6) Both start forms, in the description, the template comment and Next steps.
OTHER_FORM='Read ~/.talos/skills/pipeline/SKILL.md and follow it'
desc="$(sed -n '2,4p' "$SETUP_MD" | grep '^description:')"
tmpl="$(grep -n '"_note": "Generated by /talos:setup' "$SETUP_MD")"
next="$(grep -E '^  2\. ' "$SETUP_MD")"
for pair in "description:$desc" "template comment:$tmpl" "Next steps item 2:$next"; do
  label="${pair%%:*}"; text="${pair#*:}"
  case "$text" in *"/talos:pipeline"*"in Claude Code"*) pass "$label gives the Claude Code start form" ;; *) fail "$label gives the Claude Code start form" "$text" ;; esac
  assert_contains "$text" "$OTHER_FORM" "$label gives the any-agent start form"
done
intro="$(sed -n '5,9p' "$SETUP_MD")"
assert_contains "$intro" "Read ~/.talos/skills/setup/SKILL.md and follow it" "opening paragraph says any agent can run the wizard"
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
