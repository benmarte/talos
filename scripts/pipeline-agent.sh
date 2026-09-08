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
#   hooks.pre_dispatch  command run before the prompt is built (#181); its
#                       stdout, if non-empty, is prepended to the prompt
#                       under a "## Context" heading. Default "" (disabled).
#                       See pipeline-hooks.sh for the full contract.
#   hooks.timeout_s     seconds hooks.pre_dispatch may run before being
#                       killed. Default 30.
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
#   custom       prompt written to a temp file, then
#                sh -c "$runner_cmd" < <prompt-file>   (not a pipe -- #208)
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
# shellcheck source=pipeline-paths.sh
. "$SCRIPT_DIR/pipeline-paths.sh"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh, so fall back
# to the old per-call cfg() instead of leaving cfg undefined.
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "pipeline: config cache helper missing, falling back to per-call parsing" >&2
fi

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
#
# Validate TALOS_ISSUE: must be empty or a plain non-negative integer.
# Empty is allowed — two-arg callers never set TALOS_ISSUE and must keep working.
# Anything else (shell metacharacters, whitespace, non-digits) is rejected with exit 2.
_raw_issue="${TALOS_ISSUE:-}"
if [ -n "$_raw_issue" ]; then
  case "$_raw_issue" in
    *[!0-9]*)
      echo "pipeline-agent: TALOS_ISSUE must be a plain integer (got: $_raw_issue)" >&2
      exit 2
      ;;
  esac
fi
TALOS_ISSUE_NUMBER="$_raw_issue"
TALOS_WORKTREE_PATH="$PWD"
export TALOS_ISSUE_NUMBER TALOS_WORKTREE_PATH

if [ -z "$ROLE" ] || [ -z "$TASK" ]; then
  echo "Usage: pipeline-agent.sh <role> <task-prompt|->" >&2
  exit 2
fi
[ "$TASK" = "-" ] && TASK="$(cat)"

# ── Locate the role definition ────────────────────────────────────────────────
# Priority order:
#   0. Repo override — $PWD/.claude/agents/<role>.md. Always wins. Also covers
#      vendored-install back-compat: install.sh has always written agents to
#      .claude/agents/, so the repo override position is the vendored position.
#      Cannot be replaced by _resolve_talos_dir because that returns a scripts
#      directory; the repo override is a CWD-relative agents path that is
#      structurally different from all install-location paths.
#   1. Canonical install — resolved by _resolve_talos_dir() (sourced from
#      pipeline-paths.sh): implements the 5-location probe ($TALOS_HOME,
#      ~/.talos, $CLAUDE_PLUGIN_ROOT, .claude/talos, scripts) and returns the
#      matching scripts dir. Agents live at <scripts>/../agents/.
#   2-N. Self-relative fallbacks — cover harnesses that run this script without
#      exporting CLAUDE_PLUGIN_ROOT, and legacy layouts (pre-0.6.0).
_talos_scripts="$(_resolve_talos_dir pipeline-vcs.sh 2>/dev/null || true)"
_talos_agents="${_talos_scripts:+$(cd "$_talos_scripts/.." && pwd)/agents}"

ROLE_FILE=""
for candidate in \
  "$PWD/.claude/agents/$ROLE.md" \
  "${_talos_agents:+$_talos_agents/$ROLE.md}" \
  "$SCRIPT_DIR/../agents/$ROLE.md" \
  "$SCRIPT_DIR/../../agents/$ROLE.md" \
  "$SCRIPT_DIR/../.claude/agents/$ROLE.md"; do
  [ -n "$candidate" ] || continue
  if [ -f "$candidate" ]; then ROLE_FILE="$candidate"; break; fi
done
if [ -z "$ROLE_FILE" ]; then
  echo "pipeline-agent: role definition not found: $ROLE" >&2
  echo "  looked in: \$CLAUDE_PLUGIN_ROOT/agents/ (via _resolve_talos_dir), $SCRIPT_DIR/../agents/, $PWD/.claude/agents/" >&2
  exit 1
fi

# Strip YAML frontmatter (--- ... --- at the top) — Claude Code metadata only.
ROLE_BODY="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$ROLE_FILE")"

PROMPT="$ROLE_BODY

---

$TASK"

# hooks.pre_dispatch (#181): run the configured command (if any) and prepend
# its output to the prompt under a "## Context" heading. Delegated to
# pipeline-hooks.sh, which owns the disabled/failure/timeout/empty-output
# no-op contract -- this call site only prepends non-empty output, never
# branches on failure. Guarded the same way pipeline-cfg-cache.sh is above:
# a partial install/sync may not yet ship pipeline-hooks.sh.
if [ -f "$SCRIPT_DIR/pipeline-hooks.sh" ]; then
  # files_hint (#181 review): populated only when the caller provides it --
  # today that means TALOS_FILES_HINT, newline-separated paths, if set.
  _HOOK_FILES_HINT=()
  if [ -n "${TALOS_FILES_HINT:-}" ]; then
    while IFS= read -r _hook_file; do
      [ -n "$_hook_file" ] && _HOOK_FILES_HINT+=("$_hook_file")
    done <<<"$TALOS_FILES_HINT"
  fi
  _HOOK_CONTEXT="$(bash "$SCRIPT_DIR/pipeline-hooks.sh" pre_dispatch \
    "$ROLE" "$TALOS_ISSUE_NUMBER" "" "$TALOS_WORKTREE_PATH" \
    ${_HOOK_FILES_HINT[@]+"${_HOOK_FILES_HINT[@]}"})"
  if [ -n "$_HOOK_CONTEXT" ]; then
    PROMPT="$_HOOK_CONTEXT
$PROMPT"
  fi
fi

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
    # Feed the prompt via a temp file, not a pipe (#208): piping through
    # `printf | sh -c` puts printf on the writer end, and a runner_cmd that
    # exits without reading all of stdin (or simply loses the race on a
    # loaded host) sends printf a SIGPIPE/EPIPE. Under `set -o pipefail`
    # that turns into a spurious pipeline-agent.sh exit 1 even though the
    # runner itself exited 0. Writing to a file first removes the writer
    # process entirely, so there is nothing to receive EPIPE.
    # Fail closed if mktemp -d fails (#215 review): an empty _PROMPT_DIR
    # would otherwise make _PROMPT_FILE the literal path "/prompt", writing
    # the prompt (which may contain issue-thread text) to a fixed path on a
    # root CI container, with the EXIT trap's `rm -rf "$_PROMPT_DIR"` a
    # no-op since _PROMPT_DIR was never set. Mirrors the guard pattern in
    # pipeline-cfg-cache.sh: `mktemp -d ... || VAR=""` gated by `[ -n "$VAR" ]`.
    _PROMPT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-prompt.XXXXXX" 2>/dev/null)" || _PROMPT_DIR=""
    if [ -z "$_PROMPT_DIR" ]; then
      echo "pipeline-agent: custom runner: failed to create a temp directory for the prompt (mktemp -d)" >&2
      exit 1
    fi
    _PROMPT_FILE="$_PROMPT_DIR/prompt"
    (umask 077 && printf '%s' "$PROMPT" >"$_PROMPT_FILE")
    if command -v _talos_on_exit >/dev/null 2>&1; then
      _talos_on_exit 'rm -rf "$_PROMPT_DIR"'
    else
      trap 'rm -rf "$_PROMPT_DIR"' EXIT
    fi
    sh -c "$RUNNER_CMD" <"$_PROMPT_FILE"
    ;;
  *)
    echo "pipeline-agent: unknown agents.runner '$RUNNER'. Valid: claude | pi | codex | gemini | antigravity | custom" >&2
    exit 1
    ;;
esac
