#!/usr/bin/env bash
# pipeline-agent.sh — run one pipeline role stage through a headless LLM CLI.
#
# Claude Code sessions spawn native subagents and never need this script.
# Harnesses without native subagents (Codex CLI, Gemini CLI, any headless
# runner) use it wherever the orchestrator playbook says "spawn a subagent".
#
# Usage: pipeline-agent.sh <role> <task-prompt>
#        pipeline-agent.sh <role> -          # read task prompt from stdin
#
# The executed prompt = role definition body (.claude/agents/<role>.md with
# its YAML frontmatter stripped — the frontmatter is Claude Code metadata)
# + a separator + the task prompt.
#
# Config keys (.claude-pipeline.yaml via pipeline-config.sh):
#   agents.runner       claude (default) | codex | gemini | custom
#   agents.runner_args  list of extra CLI args appended to claude/codex/gemini
#   agents.runner_cmd   full shell command for runner=custom;
#                       receives the prompt on stdin
#
# Runner invocations:
#   claude  claude -p --setting-sources project [args] <prompt>
#           (--setting-sources project keeps user-global CLAUDE.md
#            instructions out of pipeline workers)
#   codex   codex exec [args] <prompt>
#   gemini  gemini [args] -p <prompt>
#   custom  printf '%s' <prompt> | sh -c "$runner_cmd"
#
# The runner must be an AGENTIC CLI (able to execute shell commands and edit
# files) — a bare model endpoint can generate text but cannot run a stage.
# Local models work through any agentic CLI that supports them (e.g. a
# runner_cmd wrapping an Ollama-backed coding agent).
#
# Exit code is the runner's exit code — the orchestrator reacts to failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

ROLE="${1:-}"
TASK="${2:-}"

if [ -z "$ROLE" ] || [ -z "$TASK" ]; then
  echo "Usage: pipeline-agent.sh <role> <task-prompt|->" >&2
  exit 2
fi
[ "$TASK" = "-" ] && TASK="$(cat)"

# ── Locate the role definition ────────────────────────────────────────────────
# Installed layout: <repo>/.claude/agents/<role>.md with this script at
# <repo>/.claude/talos/scripts/. Source-repo layout: <talos>/.claude/agents/.
ROLE_FILE=""
for candidate in \
  "$PWD/.claude/agents/$ROLE.md" \
  "$SCRIPT_DIR/../../agents/$ROLE.md" \
  "$SCRIPT_DIR/../.claude/agents/$ROLE.md"; do
  if [ -f "$candidate" ]; then ROLE_FILE="$candidate"; break; fi
done
if [ -z "$ROLE_FILE" ]; then
  echo "pipeline-agent: role definition not found: $ROLE (looked in .claude/agents/)" >&2
  exit 1
fi

# Strip YAML frontmatter (--- ... --- at the top) — Claude Code metadata only.
ROLE_BODY="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$ROLE_FILE")"

PROMPT="$ROLE_BODY

---

$TASK"

# ── Runner selection ──────────────────────────────────────────────────────────
RUNNER="$(cfg agents.runner "claude")"

# agents.runner_args comes back newline-separated (list) — build an array.
RUNNER_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && RUNNER_ARGS+=("$line")
done <<EOF
$(cfg agents.runner_args "")
EOF

case "$RUNNER" in
  claude)
    exec claude -p --setting-sources project \
      ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
    ;;
  codex)
    exec codex exec ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
    ;;
  gemini)
    exec gemini ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} -p "$PROMPT"
    ;;
  custom)
    RUNNER_CMD="$(cfg agents.runner_cmd "")"
    if [ -z "$RUNNER_CMD" ]; then
      echo "pipeline-agent: agents.runner=custom requires agents.runner_cmd" >&2
      exit 1
    fi
    printf '%s' "$PROMPT" | sh -c "$RUNNER_CMD"
    ;;
  *)
    echo "pipeline-agent: unknown agents.runner '$RUNNER'. Valid: claude | codex | custom" >&2
    exit 1
    ;;
esac
