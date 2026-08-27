#!/usr/bin/env bash
# install.sh -- copy Talos scripts and skills into a target repo, or install globally.
#
# Global install (recommended for new setups):
#   bash install.sh --global
#   Writes scripts, agents, and templates to ~/.talos/ and skills to ~/.claude/skills/.
#   A single update (git pull + install.sh --global) reaches every repo and harness.
#   Re-runs overwrite existing ~/.talos/ files by default. Pass --no-overwrite to skip.
#
# Per-repo config (after global install):
#   bash install.sh [target-repo-path] [--harness claude|codex|antigravity]
#   Writes only talos.pipeline.* config and, for non-Claude harnesses, AGENTS.md glue.
#   No scripts are copied into the repo. Relies on the global install at ~/.talos/.
#   --harness codex or --harness antigravity additionally writes a Talos section
#   into <target>/AGENTS.md so the harness can orchestrate the pipeline, running
#   role stages via ~/.talos/scripts/pipeline-agent.sh.
#
# Vendored (legacy, back-compat):
#   Existing .claude/talos/ installs keep working with zero user action.
#   The scripts probe order includes .claude/talos/scripts at position 4, so old
#   vendored copies are still found. Only run install.sh --global first if you
#   want a fresh install to benefit from the new centralized location.
#
# Probe order (used by SKILL.md and all scripts):
#   1. $TALOS_HOME/scripts        -- explicit override (skipped when unset)
#   2. ~/.talos/scripts           -- global install (NEW)
#   3. $CLAUDE_PLUGIN_ROOT/scripts -- Claude Code plugin
#   4. .claude/talos/scripts      -- legacy vendored, back-compat
#   5. scripts                    -- Talos source repo
#
# Notes:
#   talos.pipeline.* config files are NEVER overwritten by any install mode.
#   Git history is never modified. Nothing is committed.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
FORCE_MODE=""       # "overwrite" | "no-overwrite" | "" (default varies by mode)
HARNESS="claude"
WITH_SKILLS=true
GLOBAL=false
AGENT_SKILLS_REPO="${TALOS_AGENT_SKILLS_REPO:-https://github.com/addyosmani/agent-skills}"

expect_harness=false
for arg in "$@"; do
  if [ "$expect_harness" = "true" ]; then
    HARNESS="$arg"; expect_harness=false; continue
  fi
  case "$arg" in
    --global)          GLOBAL=true ;;
    --force)           FORCE_MODE="overwrite" ;;
    --no-overwrite)    FORCE_MODE="no-overwrite" ;;
    --no-agent-skills) WITH_SKILLS=false ;;
    --harness)         expect_harness=true ;;
    --harness=*)       HARNESS="${arg#*=}" ;;
    *)                 [ -z "$TARGET" ] && TARGET="$arg" ;;
  esac
done

# Default overwrite semantics:
#   --global:   overwrite by default (re-run = update); --no-overwrite opts out.
#   per-repo:   skip-if-exists by default; --force opts in.
if [ "$GLOBAL" = "true" ]; then
  [ -z "$FORCE_MODE" ] && FORCE_MODE="overwrite"
else
  [ -z "$FORCE_MODE" ] && FORCE_MODE="no-overwrite"
fi
FORCE=false
[ "$FORCE_MODE" = "overwrite" ] && FORCE=true

case "$HARNESS" in
  claude|codex|antigravity) ;;
  *) echo "error: unknown --harness '$HARNESS'. Valid: claude | codex | antigravity" >&2; exit 1 ;;
esac

# ── install_file helper ───────────────────────────────────────────────────────
install_file() {
  local src="$1" dest="$2"
  if [ -f "$dest" ] && [ "$FORCE" = "false" ]; then
    echo "  skip (exists): $dest  (pass --force to overwrite)"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "  installed: $dest"
}

# ── GLOBAL INSTALL ────────────────────────────────────────────────────────────
if [ "$GLOBAL" = "true" ]; then
  TALOS_HOME_DIR="${TALOS_HOME:-$HOME/.talos}"
  CLAUDE_SKILLS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
  echo "Installing Talos globally into: $TALOS_HOME_DIR"
  echo "(Skills -> $CLAUDE_SKILLS_DIR)"
  echo ""

  # Scripts
  echo "Scripts:"
  mkdir -p "$TALOS_HOME_DIR/scripts"
  for script in pipeline-config.sh pipeline-status.sh pipeline-notify.sh \
                pipeline-vcs.sh pipeline-agent.sh pipeline-worktree.sh \
                bootstrap-labels.sh pipeline-paths.sh; do
    install_file "$SRC/scripts/$script" "$TALOS_HOME_DIR/scripts/$script"
    chmod +x "$TALOS_HOME_DIR/scripts/$script"
  done

  # Agents
  echo ""
  echo "Agents:"
  for agent in validator pm developer qa reviewer security docs planner; do
    for src_agent in "$SRC/agents/$agent.md" "$SRC/.claude/agents/$agent.md"; do
      if [ -f "$src_agent" ]; then
        install_file "$src_agent" "$TALOS_HOME_DIR/agents/$agent.md"
        break
      fi
    done
  done

  # Templates
  echo ""
  echo "Templates:"
  for dir in notifications comments; do
    for tmpl in "$SRC/templates/$dir"/*.md; do
      [ -f "$tmpl" ] || continue
      install_file "$tmpl" "$TALOS_HOME_DIR/templates/$dir/$(basename "$tmpl")"
    done
  done

  # Skills -> ~/.claude/skills/ (user-scoped; Claude Code scans this path)
  echo ""
  echo "Orchestrator skills (user-scoped):"
  install_file "$SRC/skills/pipeline/SKILL.md" "$CLAUDE_SKILLS_DIR/pipeline/SKILL.md"
  install_file "$SRC/skills/pipeline-setup/SKILL.md" "$CLAUDE_SKILLS_DIR/pipeline-setup/SKILL.md"

  echo ""
  echo "Done. Global Talos install at $TALOS_HOME_DIR"
  echo ""
  echo "Next: run per-repo config in each repository:"
  echo "  bash $SRC/install.sh /path/to/your-repo"
  echo ""
  echo "  NOTE: skills are discovered when a session starts. Restart any open"
  echo "        Claude Code session to pick up the newly installed skills."
  echo "        Registered at: $CLAUDE_SKILLS_DIR/pipeline/SKILL.md"
  exit 0
fi

# ── PER-REPO CONFIG INSTALL ───────────────────────────────────────────────────
[ -z "$TARGET" ] && TARGET="$(pwd)"

# Ensure target looks like a repo
if [ ! -d "$TARGET" ]; then
  echo "error: target directory not found: $TARGET" >&2
  exit 1
fi

# Legacy layout: Talos used to install into .claude/pipeline/
if [ -d "$TARGET/.claude/pipeline" ]; then
  echo "NOTE: legacy install detected at $TARGET/.claude/pipeline -- Talos now lives in .claude/talos/."
  echo "      Move any customized templates or .env out of the old directory, then remove it:"
  echo "        rm -rf $TARGET/.claude/pipeline"
  echo ""
fi

echo "Configuring Talos for repo: $TARGET"
echo "(scripts are NOT copied into repos -- run 'bash install.sh --global' once per machine)"
echo ""

# ── agent-skills ─────────────────────────────────────────────────────────────
# The role profiles delegate their methodology to these skills instead of
# restating it, so a vendored install without them runs every stage from a
# paragraph rather than a rubric. The PLUGIN gets them via a declared dependency;
# install.sh has to fetch them itself. For per-repo installs, agent-skills still
# goes into the repo's .claude/skills/ so role profiles can find them locally.
#
# Only skills/ is vendored. The roles invoke skills, never agents -- they have no
# Task tool -- so agent-skills' own agents would be dead weight in the target repo.
#
# Never fatal: a failure here degrades the install, it does not break it.
if [ "$WITH_SKILLS" = "true" ]; then
  echo "agent-skills (required by the role profiles -- Talos installs it for you):"
  if ! command -v git >/dev/null 2>&1; then
    echo "  SKIPPED: git not found. Install agent-skills manually:"
    echo "    $AGENT_SKILLS_REPO"
  else
    as_tmp="$(mktemp -d)"
    if git clone --depth 1 --quiet "$AGENT_SKILLS_REPO" "$as_tmp/agent-skills" 2>/dev/null \
       && [ -d "$as_tmp/agent-skills/skills" ]; then
      as_n=0
      for skill_dir in "$as_tmp/agent-skills/skills"/*/; do
        [ -f "$skill_dir/SKILL.md" ] || continue
        name="$(basename "$skill_dir")"
        dest="$TARGET/.claude/skills/$name/SKILL.md"
        if [ -f "$dest" ] && [ "$FORCE" = "false" ]; then
          echo "  skip (exists): $dest"
        else
          mkdir -p "$(dirname "$dest")"
          cp "$skill_dir/SKILL.md" "$dest"
          as_n=$((as_n + 1))
        fi
      done
      # Ship the licence alongside the copy -- this is third-party MIT content.
      for lic in LICENSE LICENSE.md; do
        if [ -f "$as_tmp/agent-skills/$lic" ]; then
          mkdir -p "$TARGET/.claude/skills"
          cp "$as_tmp/agent-skills/$lic" "$TARGET/.claude/skills/AGENT-SKILLS-LICENSE"
          break
        fi
      done
      echo "  installed: $as_n skill(s) into $TARGET/.claude/skills/"
      echo "  source:    $AGENT_SKILLS_REPO (MIT, unmodified)"
      echo "  skip with: --no-agent-skills"
    else
      echo "  SKIPPED: could not fetch $AGENT_SKILLS_REPO (offline?)."
      echo "           The pipeline still runs; roles fall back to their embedded"
      echo "           instructions. Re-run this installer when you have network."
    fi
    rm -rf "$as_tmp"
  fi
else
  echo "agent-skills: skipped (--no-agent-skills)."
  echo "  The role profiles delegate their methodology to these skills; without"
  echo "  them each stage falls back to its embedded instructions."
fi

# Codex / Antigravity / AGENTS.md harness: add a marker-fenced Talos section so
# the harness knows the pipeline exists and how to run stages without native
# subagents. Antigravity reads AGENTS.md natively since v1.20.3 -- the same
# section written for Codex works for Antigravity without modification.
if [ "$HARNESS" = "codex" ] || [ "$HARNESS" = "antigravity" ]; then
  echo ""
  echo "$HARNESS harness (AGENTS.md):"
  AGENTS_MD="$TARGET/AGENTS.md"
  if [ -f "$AGENTS_MD" ] && grep -q "<!-- talos:begin -->" "$AGENTS_MD"; then
    echo "  skip (talos section already present): $AGENTS_MD"
  else
    cat >> "$AGENTS_MD" <<'AGENTSEOF'

<!-- talos:begin -->
## Talos pipeline

This repo uses the Talos issue->PR pipeline. When asked to run the pipeline, act
as the orchestrator: follow the playbook in .claude/skills/pipeline/SKILL.md exactly.

This harness has no native subagents. Wherever the playbook says "spawn a
subagent with this prompt", instead run the stage headlessly using the script
resolved via the pipeline's probe order (global install at ~/.talos/scripts/ wins
over vendored at .claude/talos/scripts/):

    # Resolve the scripts directory first:
    for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" \
              "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
              ".claude/talos/scripts" "scripts"; do
      [ -n "$d" ] && [ -f "$d/pipeline-agent.sh" ] && { SCRIPTS="$d"; break; }
    done

    bash "$SCRIPTS/pipeline-agent.sh" <role> - <<'PROMPT'
    <the stage prompt from the playbook>
    PROMPT

Role definitions live in .claude/agents/*.md (or ~/.talos/agents/ for a global
install). Set the runner in talos.pipeline.yml (agents.runner: codex). All VCS
operations go through the resolved scripts/pipeline-vcs.sh -- never call gh
directly.
<!-- talos:end -->
AGENTSEOF
    echo "  installed: talos section in $AGENTS_MD"
    if [ "$HARNESS" = "antigravity" ]; then
      echo "  NOTE: Antigravity reads AGENTS.md natively (v1.20.3+); no separate config file needed."
    fi
  fi
fi

# Offer to copy config example. talos.pipeline.* is NEVER overwritten.
echo ""
if [ ! -f "$TARGET/talos.pipeline.yml" ] && [ ! -f "$TARGET/talos.pipeline.json" ]; then
  echo "Config template:"
  echo "  Copy talos.pipeline.yml.example to talos.pipeline.yml and edit it:"
  echo "    cp $SRC/talos.pipeline.yml.example $TARGET/talos.pipeline.yml"
else
  echo "Config: talos.pipeline.* already exists -- not overwriting."
fi

# ── /pipeline availability ────────────────────────────────────────────────────
# The skill is discovered via the global install (~/.claude/skills/pipeline/SKILL.md
# from install.sh --global) or the marketplace plugin. Per-repo installs no longer
# write scripts into the repo; run 'bash install.sh --global' first to register
# /pipeline for all sessions on this machine.
#
# Skills are enumerated at session start, so a session already open in $TARGET
# will not see the skill until it restarts.
echo ""
echo "Done. Next steps:"
echo "  1. Edit $TARGET/talos.pipeline.yml for your project"
echo "  2. Bootstrap labels (if using GitHub/GitLab/Azure):"

TALOS_HOME_DIR="${TALOS_HOME:-$HOME/.talos}"
if [ -f "$TALOS_HOME_DIR/scripts/bootstrap-labels.sh" ]; then
  echo "     bash $TALOS_HOME_DIR/scripts/bootstrap-labels.sh"
else
  echo "     bash <talos-scripts>/bootstrap-labels.sh"
  echo "     (run 'bash $SRC/install.sh --global' first to install scripts globally)"
fi
echo "  3. Add 'pipeline:ready' to a GitHub issue"
echo "  4. Open a Claude Code session in $TARGET and run: /pipeline"
echo ""
echo "  NOTE: /pipeline requires the skill to be installed. If you have not run"
echo "        'bash install.sh --global' yet, do so now -- or install the plugin:"
echo "        /plugin marketplace add benmarte/talos"
echo "        Skills are discovered at session start; restart any open session."
