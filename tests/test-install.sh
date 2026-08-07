#!/usr/bin/env bash
# Regression tests for install.sh — layout, template shipping, --force semantics.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

out="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX")"

for s in pipeline-config.sh pipeline-status.sh pipeline-notify.sh pipeline-vcs.sh bootstrap-labels.sh; do
  assert_file_exists ".claude/talos/scripts/$s" "installs $s"
done
[ -x ".claude/talos/scripts/pipeline-notify.sh" ] \
  && pass "scripts are executable" || fail "scripts are executable"

# The skill must land where Claude Code actually scans. Writing it to
# .claude/talos/skills/ registered nothing, so /pipeline did not exist (#33).
assert_file_exists ".claude/skills/pipeline/SKILL.md" "installs orchestrator skill to .claude/skills/"
assert_file_absent ".claude/talos/skills/pipeline/SKILL.md" \
  "does not write the skill to the unscanned nested path"

# Templates must ship — without them notifications degrade to plain text
# (regression guard for the bug fixed in e7de0d5).
n_notif="$(ls .claude/talos/templates/notifications/*.md 2>/dev/null | wc -l | tr -d ' ')"
n_cmt="$(ls .claude/talos/templates/comments/*.md 2>/dev/null | wc -l | tr -d ' ')"
src_notif="$(ls "$TALOS_ROOT"/templates/notifications/*.md | wc -l | tr -d ' ')"
src_cmt="$(ls "$TALOS_ROOT"/templates/comments/*.md | wc -l | tr -d ' ')"
assert_eq "$src_notif" "$n_notif" "all notification templates installed ($src_notif)"
assert_eq "$src_cmt"   "$n_cmt"   "all comment templates installed ($src_cmt)"

for agent in validator pm developer qa reviewer security docs planner; do
  assert_file_exists ".claude/agents/$agent.md" "installs $agent agent"
done

# Second run without --force must not overwrite
echo "LOCAL EDIT" >> .claude/talos/scripts/pipeline-notify.sh
out2="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX")"
assert_contains "$out2" "skip (exists)" "re-install without --force skips existing files"
assert_contains "$(tail -1 .claude/talos/scripts/pipeline-notify.sh)" "LOCAL EDIT" \
  "local edit preserved without --force"

# --force overwrites
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force >/dev/null
assert_not_contains "$(tail -1 .claude/talos/scripts/pipeline-notify.sh)" "LOCAL EDIT" \
  "--force overwrites local edit"

# Legacy .claude/pipeline layout triggers a migration note (files untouched)
mkdir -p .claude/pipeline/scripts && echo "old" > .claude/pipeline/scripts/keep.sh
out3="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force)"
assert_contains "$out3" "legacy install detected" "legacy .claude/pipeline triggers migration note"
assert_file_exists ".claude/pipeline/scripts/keep.sh" "legacy dir is never deleted automatically"

# Pre-0.5.0 installs have the skill at .claude/talos/skills/. Upgrading must clear
# it — a stale playbook there is still reachable via the AGENTS.md pointer that
# older installs wrote, so leaving it means non-Claude harnesses keep reading it.
mkdir -p .claude/talos/skills/pipeline
echo "STALE PLAYBOOK" > .claude/talos/skills/pipeline/SKILL.md
out4="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force)"
assert_contains "$out4" "migrated: removed stale" "pre-0.5.0 skill location triggers a migration note"
assert_file_absent ".claude/talos/skills/pipeline/SKILL.md" "stale nested skill is removed on upgrade"
assert_file_absent ".claude/talos/skills" "emptied nested skills dir is pruned"

# ...but only the file Talos wrote. A sibling the user put there must survive,
# and its parent dirs with it.
mkdir -p .claude/talos/skills/pipeline
echo "STALE PLAYBOOK" > .claude/talos/skills/pipeline/SKILL.md
echo "mine" > .claude/talos/skills/custom-notes.md
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force >/dev/null
assert_file_absent ".claude/talos/skills/pipeline/SKILL.md" "stale skill still removed alongside user files"
assert_file_exists ".claude/talos/skills/custom-notes.md" "unrelated user files in the old dir are preserved"
rm -rf .claude/talos/skills

# Missing target errors
if bash "$TALOS_ROOT/install.sh" "$SANDBOX/does-not-exist" >/dev/null 2>&1; then
  fail "missing target dir exits non-zero"
else
  pass "missing target dir exits non-zero"
fi

# Marketplace manifest exists in Talos source root and is valid JSON with plugins[0].name == "talos"
assert_file_exists "$TALOS_ROOT/.claude-plugin/marketplace.json" \
  ".claude-plugin/marketplace.json exists in source repo"
if python3 -c "
import json, sys
with open('$TALOS_ROOT/.claude-plugin/marketplace.json') as f:
    data = json.load(f)
assert data['plugins'][0]['name'] == 'talos', 'plugins[0].name must be talos'
" 2>/dev/null; then
  pass "marketplace.json is valid JSON with plugins[0].name == talos"
else
  fail "marketplace.json is valid JSON with plugins[0].name == talos"
fi

# ── agent-skills vendoring (#43) ─────────────────────────────────────────────
# The plugin gets agent-skills via a declared dependency; install.sh has to
# fetch it. Tested against a local fixture repo rather than the network, so the
# suite stays hermetic — git clone accepts a filesystem path.
as_fix="$SANDBOX/fixture-agent-skills"
mkdir -p "$as_fix/skills/test-driven-development" "$as_fix/skills/code-review-and-quality"
printf -- '---\nname: test-driven-development\n---\nfixture\n' \
  > "$as_fix/skills/test-driven-development/SKILL.md"
printf -- '---\nname: code-review-and-quality\n---\nfixture\n' \
  > "$as_fix/skills/code-review-and-quality/SKILL.md"
printf 'MIT fixture licence\n' > "$as_fix/LICENSE"
(cd "$as_fix" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)

as_target="$SANDBOX/as-target"
mkdir -p "$as_target"
as_out="$(TALOS_AGENT_SKILLS_REPO="$as_fix" bash "$TALOS_ROOT/install.sh" "$as_target" 2>&1)"
assert_file_exists "$as_target/.claude/skills/test-driven-development/SKILL.md" \
  "install.sh vendors agent-skills skills"
assert_file_exists "$as_target/.claude/skills/code-review-and-quality/SKILL.md" \
  "install.sh vendors every skill in the pack"
assert_file_exists "$as_target/.claude/skills/AGENT-SKILLS-LICENSE" \
  "third-party licence ships alongside the copy"
assert_contains "$as_out" "Talos installs it for you" \
  "installer tells the user it is installing agent-skills"

# Opt-out must work, and must say what the user gives up.
as_target2="$SANDBOX/as-target-optout"
mkdir -p "$as_target2"
as_out2="$(TALOS_AGENT_SKILLS_REPO="$as_fix" bash "$TALOS_ROOT/install.sh" "$as_target2" --no-agent-skills 2>&1)"
assert_file_absent "$as_target2/.claude/skills/test-driven-development" \
  "--no-agent-skills skips the vendoring"
assert_contains "$as_out2" "embedded instructions" \
  "--no-agent-skills explains the degraded behaviour"
assert_file_exists "$as_target2/.claude/skills/pipeline/SKILL.md" \
  "--no-agent-skills still installs Talos itself"

# An unreachable source must degrade, never abort — the pipeline runs without it.
as_target3="$SANDBOX/as-target-offline"
mkdir -p "$as_target3"
as_out3="$(TALOS_AGENT_SKILLS_REPO="$SANDBOX/does-not-exist" bash "$TALOS_ROOT/install.sh" "$as_target3" 2>&1)"
assert_contains "$as_out3" "SKIPPED: could not fetch" "unreachable pack is reported"
assert_file_exists "$as_target3/.claude/skills/pipeline/SKILL.md" \
  "unreachable pack does not abort the install"

# The shipped manifests must pass the real schema check. 0.5.0's plugin.json
# listed individual skill dirs in `skills` — that field names directories to
# SCAN for <name>/SKILL.md, so the manifest failed validation as published.
# This file does not use_stubs, so `claude` here is the real CLI.
if command -v claude >/dev/null 2>&1; then
  val_out="$(cd "$TALOS_ROOT" && claude plugin validate . 2>&1)"
  assert_contains "$val_out" "Validation passed" \
    "claude plugin validate passes on the shipped manifests"
  assert_not_contains "$val_out" "Invalid input" \
    "no schema errors in the shipped manifests"
else
  echo "  -- skipped: claude CLI not on PATH (manifest validation)"
fi

# ── /pipeline availability guidance (#33, supersedes #31) ────────────────────
# install.sh now registers the command itself, so the guidance must NOT depend on
# whether the marketplace plugin happens to be installed. #31's fuzzy-match trap
# survives in exactly one form — a session that was already open when install.sh
# ran has a stale skill list — so restarting is the instruction that must appear.

# No plugin anywhere: /pipeline still works, and nothing may claim otherwise.
fake_cfg_dir="$SANDBOX/cfg-without"
mkdir -p "$fake_cfg_dir"
echo '{"enabledPlugins":{"sentry@claude-plugins-official":true}}' > "$fake_cfg_dir/settings.json"
out_without="$(CLAUDE_CONFIG_DIR="$fake_cfg_dir" bash "$TALOS_ROOT/install.sh" "$PWD" --force 2>&1)"
assert_contains "$out_without" "run: /pipeline" \
  "no plugin installed: still tells the user to run /pipeline"
assert_not_contains "$out_without" "/plugin marketplace add" \
  "no plugin installed: does not demand the marketplace for /pipeline"
assert_contains "$out_without" "restart it" \
  "no plugin installed: tells the user to restart an already-open session"
assert_contains "$out_without" ".claude/skills/pipeline/SKILL.md" \
  "names the path the command was registered at"

# Plugin installed: identical guidance — the plugin is no longer load-bearing.
fake_cfg_with="$SANDBOX/cfg-with"
mkdir -p "$fake_cfg_with"
echo '{"enabledPlugins":{"talos@talos":true}}' > "$fake_cfg_with/settings.json"
out_with="$(CLAUDE_CONFIG_DIR="$fake_cfg_with" bash "$TALOS_ROOT/install.sh" "$PWD" --force 2>&1)"
assert_contains "$out_with" "run: /pipeline" \
  "plugin installed: tells the user to run /pipeline"
assert_not_contains "$out_with" "no talos plugin entry found" \
  "plugin installed: no stale plugin warning"

finish
