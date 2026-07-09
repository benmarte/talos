#!/usr/bin/env bash
# install.sh — copy Talos scripts and skills into a target repo.
#
# Usage: bash install.sh [target-repo-path] [--force] [--harness claude|codex|antigravity]
#   target-repo-path defaults to the current directory.
#   --harness codex or --harness antigravity additionally writes a Talos section
#   into <target>/AGENTS.md so the harness can orchestrate the pipeline, running
#   role stages via scripts/pipeline-agent.sh. Antigravity reads AGENTS.md
#   natively since v1.20.3; no separate config file is needed.
#
# What it installs:
#   <target>/.claude/talos/scripts/   — pipeline-config, pipeline-status, pipeline-notify, bootstrap-labels
#   <target>/.claude/talos/skills/    — orchestrator skill (SKILL.md)
#   <target>/.claude/talos/templates/ — notification + comment templates (rich messages)
#   <target>/.claude/agents/             — subagent definitions (validator, pm, developer, qa, reviewer, security, docs)
#
# It does NOT overwrite files that already exist unless --force is passed.
# It does NOT modify git history or commit anything.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
FORCE=false
HARNESS="claude"

expect_harness=false
for arg in "$@"; do
  if [ "$expect_harness" = "true" ]; then
    HARNESS="$arg"; expect_harness=false; continue
  fi
  case "$arg" in
    --force)     FORCE=true ;;
    --harness)   expect_harness=true ;;
    --harness=*) HARNESS="${arg#*=}" ;;
    *)           [ -z "$TARGET" ] && TARGET="$arg" ;;
  esac
done
[ -z "$TARGET" ] && TARGET="$(pwd)"

case "$HARNESS" in
  claude|codex|antigravity) ;;
  *) echo "error: unknown --harness '$HARNESS'. Valid: claude | codex | antigravity" >&2; exit 1 ;;
esac

# Ensure target looks like a repo
if [ ! -d "$TARGET" ]; then
  echo "error: target directory not found: $TARGET" >&2
  exit 1
fi

# Legacy layout: Talos used to install into .claude/pipeline/
if [ -d "$TARGET/.claude/pipeline" ]; then
  echo "NOTE: legacy install detected at $TARGET/.claude/pipeline — Talos now lives in .claude/talos/."
  echo "      Move any customized templates or .env out of the old directory, then remove it:"
  echo "        rm -rf $TARGET/.claude/pipeline"
  echo ""
fi

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

echo "Installing Talos into: $TARGET"
echo ""

# Scripts
echo "Scripts:"
for script in pipeline-config.sh pipeline-status.sh pipeline-notify.sh pipeline-vcs.sh pipeline-agent.sh bootstrap-labels.sh; do
  install_file "$SRC/scripts/$script" "$TARGET/.claude/talos/scripts/$script"
  chmod +x "$TARGET/.claude/talos/scripts/$script"
done

# Skill
echo ""
echo "Orchestrator skill:"
install_file "$SRC/skills/pipeline/SKILL.md" "$TARGET/.claude/talos/skills/pipeline/SKILL.md"

# Templates — pipeline-notify.sh falls back to <script-dir>/../templates/notifications,
# i.e. .claude/talos/templates/. Without these, notifications degrade to plain text.
echo ""
echo "Templates:"
for dir in notifications comments; do
  for tmpl in "$SRC/templates/$dir"/*.md; do
    [ -f "$tmpl" ] || continue
    install_file "$tmpl" "$TARGET/.claude/talos/templates/$dir/$(basename "$tmpl")"
  done
done

# Subagent definitions
echo ""
echo "Subagents:"
for agent in validator pm developer qa reviewer security docs planner; do
  src_agent="$SRC/.claude/agents/$agent.md"
  if [ -f "$src_agent" ]; then
    install_file "$src_agent" "$TARGET/.claude/agents/$agent.md"
  fi
done

# Codex / Antigravity / AGENTS.md harness: add a marker-fenced Talos section so
# the harness knows the pipeline exists and how to run stages without native
# subagents. Antigravity reads AGENTS.md natively since v1.20.3 — the same
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

This repo has the Talos issue→PR pipeline installed under `.claude/talos/`.
When asked to run the pipeline, act as the orchestrator: follow the playbook in
`.claude/talos/skills/pipeline/SKILL.md` exactly.

This harness has no native subagents. Wherever the playbook says "spawn a
subagent with this prompt", instead run the stage headlessly:

    bash .claude/talos/scripts/pipeline-agent.sh <role> - <<'PROMPT'
    <the stage prompt from the playbook>
    PROMPT

Role definitions live in `.claude/agents/*.md`. Set the runner in
`talos.pipeline.yml` (`agents.runner: codex`). All VCS operations go through
`.claude/talos/scripts/pipeline-vcs.sh` — never call `gh` directly.
<!-- talos:end -->
AGENTSEOF
    echo "  installed: talos section in $AGENTS_MD"
    if [ "$HARNESS" = "antigravity" ]; then
      echo "  NOTE: Antigravity reads AGENTS.md natively (v1.20.3+); no separate config file needed."
    fi
  fi
fi

# Offer to copy config example
echo ""
if [ ! -f "$TARGET/talos.pipeline.yml" ]; then
  echo "Config template:"
  echo "  Copy talos.pipeline.yml.example to talos.pipeline.yml and edit it:"
  echo "    cp $SRC/talos.pipeline.yml.example $TARGET/talos.pipeline.yml"
else
  echo "Config: talos.pipeline.yml already exists — not overwriting."
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit $TARGET/talos.pipeline.yml for your project"
echo "  2. Run: bash $TARGET/.claude/talos/scripts/bootstrap-labels.sh"
echo "  3. Add 'pipeline:ready' to a GitHub issue"
echo "  4. Open a Claude Code session in $TARGET and run: /pipeline"
