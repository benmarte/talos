#!/usr/bin/env bash
# Regression tests for install.sh -- layout, --global mode, --force semantics,
# per-repo config-only behavior, back-compat, and probe-site sync (#164).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

# ── Per-repo mode: config only (no scripts, no templates, no agents) ──────────
# Per-repo install writes ONLY talos.pipeline.* and harness glue.
# Scripts, templates, and agents are NOT copied into the repo; they live in
# the global install at ~/.talos/ (position 2 in the probe order).
out="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills 2>&1)"

assert_file_absent ".claude/talos/scripts" \
  "per-repo install does not write scripts directory"
assert_file_absent ".claude/talos/templates" \
  "per-repo install does not write templates directory"
assert_file_absent ".claude/agents/validator.md" \
  "per-repo install does not copy agents into repo"
assert_file_absent ".claude/skills/pipeline/SKILL.md" \
  "per-repo install does not write skill to repo (goes to ~/.claude/skills/ via --global)"
assert_contains "$out" "talos.pipeline" \
  "per-repo install mentions config"

# Legacy .claude/pipeline layout triggers a migration note (files untouched)
mkdir -p .claude/pipeline/scripts && echo "old" > .claude/pipeline/scripts/keep.sh
out3="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills 2>&1)"
assert_contains "$out3" "legacy install detected" "legacy .claude/pipeline triggers migration note"
assert_file_exists ".claude/pipeline/scripts/keep.sh" "legacy dir is never deleted automatically"

# Missing target errors
if bash "$TALOS_ROOT/install.sh" "$SANDBOX/does-not-exist" >/dev/null 2>&1; then
  fail "missing target dir exits non-zero"
else
  pass "missing target dir exits non-zero"
fi

# ── Global install mode ───────────────────────────────────────────────────────
# --global writes scripts, agents, templates to ~/.talos/ and skills to ~/.claude/skills/.
GLOBAL_HOME="$SANDBOX/.global-home"
FAKE_CLAUDE_HOME="$SANDBOX/.fake-claude"
mkdir -p "$GLOBAL_HOME" "$FAKE_CLAUDE_HOME"

gout="$(HOME="$GLOBAL_HOME" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills 2>&1)"

# pipeline-paths.sh must be in the global scripts dir
assert_file_exists "$GLOBAL_HOME/.talos/scripts/pipeline-paths.sh" \
  "--global installs pipeline-paths.sh to ~/.talos/scripts/"

for script in pipeline-config.sh pipeline-status.sh pipeline-notify.sh pipeline-vcs.sh \
              pipeline-agent.sh pipeline-worktree.sh bootstrap-labels.sh; do
  assert_file_exists "$GLOBAL_HOME/.talos/scripts/$script" "--global installs $script"
done

[ -x "$GLOBAL_HOME/.talos/scripts/pipeline-notify.sh" ] \
  && pass "--global scripts are executable" || fail "--global scripts are executable"

for agent in validator pm developer qa reviewer security docs planner; do
  assert_file_exists "$GLOBAL_HOME/.talos/agents/$agent.md" "--global installs $agent agent"
done

n_notif="$(ls "$GLOBAL_HOME/.talos/templates/notifications/"*.md 2>/dev/null | wc -l | tr -d ' ')"
src_notif="$(ls "$TALOS_ROOT/templates/notifications/"*.md | wc -l | tr -d ' ')"
assert_eq "$src_notif" "$n_notif" "--global installs all notification templates ($src_notif)"

assert_file_exists "$FAKE_CLAUDE_HOME/skills/pipeline/SKILL.md" \
  "--global installs skill to ~/.claude/skills/pipeline/SKILL.md"
assert_file_exists "$FAKE_CLAUDE_HOME/skills/pipeline-setup/SKILL.md" \
  "--global installs pipeline-setup skill to ~/.claude/skills/"

assert_contains "$gout" "Installing Talos globally" "--global output says 'Installing Talos globally'"

# --global re-run overwrites by default (no --force needed)
echo "MODIFIED" >> "$GLOBAL_HOME/.talos/scripts/pipeline-vcs.sh"
gout2="$(HOME="$GLOBAL_HOME" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills 2>&1)"
assert_not_contains "$(tail -1 "$GLOBAL_HOME/.talos/scripts/pipeline-vcs.sh")" "MODIFIED" \
  "--global re-run overwrites scripts by default"

# --no-overwrite prevents overwrite in global mode
echo "MODIFIED" >> "$GLOBAL_HOME/.talos/scripts/pipeline-vcs.sh"
HOME="$GLOBAL_HOME" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
  bash "$TALOS_ROOT/install.sh" --global --no-overwrite --no-agent-skills >/dev/null
assert_contains "$(tail -1 "$GLOBAL_HOME/.talos/scripts/pipeline-vcs.sh")" "MODIFIED" \
  "--no-overwrite skips existing files in global mode"

# talos.pipeline.* config is NEVER overwritten by any install mode
touch "$SANDBOX/talos.pipeline.yml"
echo "CUSTOM_CONFIG" >> "$SANDBOX/talos.pipeline.yml"
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills >/dev/null
assert_contains "$(tail -1 "$SANDBOX/talos.pipeline.yml")" "CUSTOM_CONFIG" \
  "talos.pipeline.yml is never overwritten by per-repo install"
HOME="$GLOBAL_HOME" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills >/dev/null
assert_contains "$(tail -1 "$SANDBOX/talos.pipeline.yml")" "CUSTOM_CONFIG" \
  "talos.pipeline.yml is never overwritten by global install either"
rm -f "$SANDBOX/talos.pipeline.yml"

# ── Marketplace manifest ──────────────────────────────────────────────────────
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
# Per-repo install still vendors agent-skills skills into .claude/skills/ so
# role profiles can find them locally, even when no global install exists.
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
# Per-repo no longer writes the talos skill; it belongs in ~/.claude/skills/ via --global
assert_file_absent "$as_target2/.claude/skills/pipeline" \
  "--no-agent-skills: per-repo install does not write talos skill to repo (use --global)"

# An unreachable source must degrade, never abort -- the pipeline runs without it.
as_target3="$SANDBOX/as-target-offline"
mkdir -p "$as_target3"
as_out3="$(TALOS_AGENT_SKILLS_REPO="$SANDBOX/does-not-exist" bash "$TALOS_ROOT/install.sh" "$as_target3" 2>&1)"
assert_contains "$as_out3" "SKIPPED: could not fetch" "unreachable pack is reported"
rc3=$?
if bash "$TALOS_ROOT/install.sh" "$as_target3" >/dev/null 2>&1; then
  pass "unreachable agent-skills does not abort the install (exit 0)"
else
  fail "unreachable agent-skills does not abort the install (exit 0)"
fi

# The shipped manifests must pass the real schema check.
if command -v claude >/dev/null 2>&1; then
  val_out="$(cd "$TALOS_ROOT" && claude plugin validate . 2>&1)"
  assert_contains "$val_out" "Validation passed" \
    "claude plugin validate passes on the shipped manifests"
  assert_not_contains "$val_out" "Invalid input" \
    "no schema errors in the shipped manifests"
else
  echo "  -- skipped: claude CLI not on PATH (manifest validation)"
fi

# ── /pipeline availability guidance ──────────────────────────────────────────
# Per-repo install tells users to run --global or install the plugin.
fake_cfg_dir="$SANDBOX/cfg-without"
mkdir -p "$fake_cfg_dir"
echo '{"enabledPlugins":{"sentry@claude-plugins-official":true}}' > "$fake_cfg_dir/settings.json"
out_without="$(CLAUDE_CONFIG_DIR="$fake_cfg_dir" bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills 2>&1)"
assert_contains "$out_without" "/pipeline" \
  "per-repo install: tells the user to run /pipeline"
assert_contains "$out_without" "install.sh --global" \
  "per-repo install: tells user to run --global to register the skill"

fake_cfg_with="$SANDBOX/cfg-with"
mkdir -p "$fake_cfg_with"
echo '{"enabledPlugins":{"talos@talos":true}}' > "$fake_cfg_with/settings.json"
out_with="$(CLAUDE_CONFIG_DIR="$fake_cfg_with" bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills 2>&1)"
assert_contains "$out_with" "/pipeline" \
  "plugin installed: tells the user to run /pipeline"

# ── Probe-site sync / divergence test (#164) ─────────────────────────────────
# Design: pipeline-paths.sh is the single source of truth for the 5-location
# probe order. Bash scripts that can source shell delegate to _resolve_talos_dir().
# Sites that cannot source shell (the two SKILL.md files) and sites that ship an
# executable probe loop to third-party harnesses (install.sh AGENTS.md heredoc)
# must match pipeline-paths.sh literally.
#
# Tree-wide grep (grep -rn TALOS_HOME --include=*.sh --include=*.md, excl tests/.git)
# confirmed four literal-probe sites and two delegation sites -- no others exist.
# Docs files (README.md, user-guide.md, CHANGELOG.md) mention probe strings but
# do not execute them; they are not probe sites.
#
# Two checks:
#   A. Delegation sites call _resolve_talos_dir (no duplication):
#        scripts/pipeline-agent.sh, scripts/pipeline-notify.sh
#   B. Literal sites contain each canonical probe string:
#        scripts/pipeline-paths.sh (canonical definition)
#        skills/pipeline/SKILL.md
#        skills/pipeline-setup/SKILL.md
#        install.sh (AGENTS.md heredoc -- executed as shell by codex/antigravity)
#
# RED when any site drifts: A catches dropped delegation; B catches literal divergence.

# A. Delegation sites must CALL _resolve_talos_dir.
for sh_file in \
  "$TALOS_ROOT/scripts/pipeline-agent.sh" \
  "$TALOS_ROOT/scripts/pipeline-notify.sh"; do
  if grep -q "_resolve_talos_dir" "$sh_file"; then
    pass "$(basename "$sh_file") calls _resolve_talos_dir (delegates to pipeline-paths.sh)"
  else
    fail "$(basename "$sh_file") does NOT call _resolve_talos_dir -- probe order no longer enforced"
  fi
done

# B. Literal sites must contain each probe string.
# install.sh is included because its AGENTS.md heredoc is executed as shell by
# codex and antigravity harnesses -- a drift here means those harnesses resolve
# to the wrong install, the exact failure #164 exists to eliminate.
#
# Probe strings use the conditional expansion form (${VAR:+...}) so they are
# specific to probe loops rather than general variable uses. "TALOS_HOME" alone
# appears in install.sh many times via TALOS_HOME_DIR; "${TALOS_HOME:+" only
# appears in the probe loop, making the check falsifiable.
for probe_str in '${TALOS_HOME:+' ".talos/scripts" '${CLAUDE_PLUGIN_ROOT:+' ".claude/talos/scripts"; do
  for pf in \
    "$TALOS_ROOT/scripts/pipeline-paths.sh" \
    "$TALOS_ROOT/skills/pipeline/SKILL.md" \
    "$TALOS_ROOT/skills/pipeline-setup/SKILL.md" \
    "$TALOS_ROOT/install.sh"; do
    if grep -qF "$probe_str" "$pf"; then
      pass "$(basename "$pf") contains probe string: $probe_str"
    else
      fail "$(basename "$pf") is MISSING probe string: $probe_str -- probe sites have drifted"
    fi
  done
done

finish
