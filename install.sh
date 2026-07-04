#!/usr/bin/env bash
# install.sh — copy claude-pipeline scripts and skills into a target repo.
#
# Usage: bash install.sh [target-repo-path]
#   target-repo-path defaults to the current directory.
#
# What it installs:
#   <target>/.claude/pipeline/scripts/   — pipeline-config, pipeline-status, pipeline-notify, bootstrap-labels
#   <target>/.claude/pipeline/skills/    — orchestrator skill (SKILL.md)
#   <target>/.claude/agents/             — subagent definitions (validator, pm, developer, qa, reviewer, security, docs)
#
# It does NOT overwrite files that already exist unless --force is passed.
# It does NOT modify git history or commit anything.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$(pwd)}"
FORCE=false

for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
done

# Ensure target looks like a repo
if [ ! -d "$TARGET" ]; then
  echo "error: target directory not found: $TARGET" >&2
  exit 1
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

echo "Installing claude-pipeline into: $TARGET"
echo ""

# Scripts
echo "Scripts:"
for script in pipeline-config.sh pipeline-status.sh pipeline-notify.sh pipeline-vcs.sh bootstrap-labels.sh; do
  install_file "$SRC/scripts/$script" "$TARGET/.claude/pipeline/scripts/$script"
  chmod +x "$TARGET/.claude/pipeline/scripts/$script"
done

# Skill
echo ""
echo "Orchestrator skill:"
install_file "$SRC/skills/pipeline/SKILL.md" "$TARGET/.claude/pipeline/skills/pipeline/SKILL.md"

# Subagent definitions
echo ""
echo "Subagents:"
for agent in validator pm developer qa reviewer security docs; do
  src_agent="$SRC/.claude/agents/$agent.md"
  if [ -f "$src_agent" ]; then
    install_file "$src_agent" "$TARGET/.claude/agents/$agent.md"
  fi
done

# Offer to copy config example
echo ""
if [ ! -f "$TARGET/.claude-pipeline.yaml" ]; then
  echo "Config template:"
  echo "  Copy pipeline.yaml.example to .claude-pipeline.yaml and edit it:"
  echo "    cp $SRC/pipeline.yaml.example $TARGET/.claude-pipeline.yaml"
else
  echo "Config: .claude-pipeline.yaml already exists — not overwriting."
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit $TARGET/.claude-pipeline.yaml for your project"
echo "  2. Run: bash $TARGET/.claude/pipeline/scripts/bootstrap-labels.sh"
echo "  3. Add 'pipeline:ready' to a GitHub issue"
echo "  4. Open a Claude Code session in $TARGET and run: /pipeline"
