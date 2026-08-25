#!/usr/bin/env bash
# pipeline-agent.sh — run one pipeline role stage through a headless LLM CLI.
#
# Claude Code sessions spawn native subagents and never need this script.
# Harnesses without native subagents (Codex CLI, Gemini CLI, Antigravity CLI,
# any headless runner) use it wherever the orchestrator playbook says "spawn a
# subagent".
#
# Usage: pipeline-agent.sh <role> <task-prompt>
#        pipeline-agent.sh <role> -          # read task prompt from stdin
#
# The executed prompt = role definition body (.claude/agents/<role>.md with
# its YAML frontmatter stripped — the frontmatter is Claude Code metadata)
# + a separator + the task prompt.
#
# Config keys (talos.pipeline.yml via pipeline-config.sh):
#   agents.runner       claude (default) | pi | codex | gemini | antigravity | custom
#   agents.runner_args  list of extra CLI args appended to claude/pi/codex/gemini/agy
#   agents.runner_cmd   full shell command for runner=custom;
#                       receives the prompt on stdin
#
# runner_cmd environment: TALOS_ROLE, TALOS_ISSUE_NUMBER, and TALOS_WORKTREE_PATH
# are exported and visible to runner_cmd. TALOS_ROLE lets you route by role:
#   e.g. case "$TALOS_ROLE" in
#          developer|qa) exec pi -p --provider ds4 --model deepseek-v4-flash "$(cat)" ;;
#          *)            exec claude -p "$(cat)" ;;
#        esac
# TALOS_ISSUE_NUMBER is the issue number passed via TALOS_ISSUE=<N> in the caller's
# environment; empty string when the caller does not set TALOS_ISSUE.
# TALOS_WORKTREE_PATH is the $PWD at the time pipeline-agent.sh was invoked.
# Verify scripts can assert they are running in the correct worktree:
#   if [ "${TALOS_ISSUE_NUMBER:-}" != "$EXPECTED" ]; then exit 1; fi
#
# Runner invocations:
#   claude       claude -p --setting-sources project [args] <prompt>
#                (--setting-sources project keeps user-global CLAUDE.md
#                 instructions out of pipeline workers)
#   pi           pi -p [args] <prompt>     # pi print mode, one-shot headless stage
#   codex        codex exec [args] <prompt>
#   gemini       gemini [args] -p <prompt>
#   antigravity  agy [args] -p <prompt>
#                # invocation per Antigravity CLI docs (2026-03)
#   custom       printf '%s' <prompt> | sh -c "$runner_cmd"
#
# NOTE: the pi orchestrator playbook uses INLINE mode (agents.subagents: false,
# agents.runner: pi) and does NOT call this script — pi acts as each stage role
# itself, one role per turn. This pi case only covers running a single stage
# headlessly when explicitly requested.
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
# Export TALOS_ROLE so runner_cmd (runner=custom) can route by role.
# ROLE is kept as the local variable used for role-file lookup below.
TALOS_ROLE="$ROLE"
export TALOS_ROLE

# Export per-agent identity so verify: commands can self-check their environment.
# TALOS_ISSUE is set by the caller (e.g. TALOS_ISSUE=54 pipeline-agent.sh qa "<prompt>").
# Two-arg callers that do not set TALOS_ISSUE are unaffected: TALOS_ISSUE_NUMBER is
# exported as the empty string, which is distinct from an unset variable and lets
# verify scripts distinguish "Talos did not set this" from any real issue number.
# TALOS_WORKTREE_PATH is the working directory at invocation time — the worktree root.
TALOS_ISSUE_NUMBER="${TALOS_ISSUE:-}"
TALOS_WORKTREE_PATH="$PWD"
export TALOS_ISSUE_NUMBER TALOS_WORKTREE_PATH

if [ -z "$ROLE" ] || [ -z "$TASK" ]; then
  echo "Usage: pipeline-agent.sh <role> <task-prompt|->" >&2
  exit 2
fi
[ "$TASK" = "-" ] && TASK="$(cat)"

# ── Locate the role definition ────────────────────────────────────────────────
# Priority order, matching what the orchestrator playbook does for native
# subagents so both harnesses pick the same profile:
#   1. Repo override     — <repo>/.claude/agents/<role>.md. Always wins, so a
#                          project can replace one role without forking Talos.
#                          This is also the vendored-install layout, where the
#                          repo copy IS the install.
#   2. Plugin cache      — $CLAUDE_PLUGIN_ROOT/agents/, set when Talos was
#                          installed from the marketplace.
#   3. Plugin, no env    — this script at <plugin>/scripts/, agents at
#                          <plugin>/agents/. Covers harnesses that run the
#                          script without exporting CLAUDE_PLUGIN_ROOT, and the
#                          Talos source repo, which shares this layout.
#   4. Legacy layouts    — pre-0.6.0, before the agents moved to the plugin
#                          root. Kept so an old checkout still runs.
ROLE_FILE=""
for candidate in \
  "$PWD/.claude/agents/$ROLE.md" \
  "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/agents/$ROLE.md}" \
  "$SCRIPT_DIR/../agents/$ROLE.md" \
  "$SCRIPT_DIR/../../agents/$ROLE.md" \
  "$SCRIPT_DIR/../.claude/agents/$ROLE.md"; do
  [ -n "$candidate" ] || continue
  if [ -f "$candidate" ]; then ROLE_FILE="$candidate"; break; fi
done
if [ -z "$ROLE_FILE" ]; then
  echo "pipeline-agent: role definition not found: $ROLE" >&2
  echo "  looked in: \$CLAUDE_PLUGIN_ROOT/agents/, $SCRIPT_DIR/../agents/, $PWD/.claude/agents/" >&2
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
  antigravity)
    # invocation per Antigravity CLI docs (2026-03)
    exec agy ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} -p "$PROMPT"
    ;;
  pi)
    # pi print mode — one-shot headless stage (inline mode is the pi default;
    # this case exists for callers that want a single headless stage).
    exec pi -p ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
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
    echo "pipeline-agent: unknown agents.runner '$RUNNER'. Valid: claude | pi | codex | gemini | antigravity | custom" >&2
    exit 1
    ;;
esac
