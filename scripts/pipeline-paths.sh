#!/usr/bin/env bash
# pipeline-paths.sh -- canonical probe for the Talos scripts directory.
#
# Source this file to import _resolve_talos_dir().
#
# _resolve_talos_dir [probe_file]
#   Prints the resolved Talos scripts directory to stdout.
#   Probe order (first directory containing probe_file wins):
#     1. $TALOS_HOME/scripts        -- explicit override (skipped when unset)
#     2. ~/.talos/scripts           -- global install
#     3. $CLAUDE_PLUGIN_ROOT/scripts -- Claude Code plugin
#     4. .claude/talos/scripts      -- legacy vendored, back-compat
#     5. scripts                    -- Talos source repo
#   Returns 0 on success, 1 if nothing resolves.
#   probe_file defaults to pipeline-vcs.sh.
_resolve_talos_dir() {
  local _probe="${1:-pipeline-vcs.sh}"
  local _d
  for _d in \
    "${TALOS_HOME:+$TALOS_HOME/scripts}" \
    "$HOME/.talos/scripts" \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
    ".claude/talos/scripts" \
    "scripts"; do
    [ -n "$_d" ] || continue
    [ -f "$_d/$_probe" ] || continue
    printf '%s\n' "$_d"
    return 0
  done
  return 1
}
