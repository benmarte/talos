#!/usr/bin/env bash
# pipeline-verify.sh — run verify: commands with the stage identity exported
# mechanically (#186).
#
# The adapter path (pipeline-agent.sh) already exports TALOS_ISSUE_NUMBER /
# TALOS_WORKTREE_PATH as real shell variables before invoking the runner
# CLI. Native Claude Code subagents have no such adapter in front of them —
# the developer/QA prompts used to just ask the agent to `export` the two
# vars by hand before running verify:, which a stage could silently ignore.
# This wrapper closes that gap: it resolves the identity itself and exports
# it before running anything, so a stage only has to remember one command.
#
# Usage:
#   pipeline-verify.sh [--issue N] [--worktree PATH] [--role ROLE] [-- <cmd...>]
#
# Identity resolution (per variable, first match wins):
#   1. --issue / --worktree flags
#   2. <toplevel>/.talos/env, where <toplevel> is `git rev-parse
#      --show-toplevel` for the current worktree (falls back to $PWD if not
#      inside a git repo, or from a subdirectory of the worktree this still
#      finds the file at the worktree's own root) — two plain `KEY=value`
#      lines written by `pipeline-worktree.sh create`:
#        TALOS_ISSUE_NUMBER=<digits>
#        TALOS_WORKTREE_PATH=<absolute path, raw, no quoting>
#      This file is PARSED line-by-line (never `source`d / dot-sourced): it
#      is worktree-local and agent-writable, so treating it as executable
#      shell would let a corrupted or adversarial file run arbitrary code in
#      this trusted wrapper's process. Any line that isn't one of the two
#      expected `KEY=value` forms, an issue number that isn't all digits, or
#      a worktree path that isn't an existing absolute directory is a fatal
#      error (diagnostic to stderr naming the file, exit 2) rather than a
#      silently-ignored or partially-trusted value. NOTE: this is a
#      *per-worktree* file at this worktree's own root, not the shared
#      main-repo .talos/ that pipeline-events.sh's events.jsonl lives under
#      (that one resolves via `git rev-parse --git-common-dir`, one path
#      shared by every worktree of a repo). Same ".talos/" name, deliberately
#      different resolution.
#   3. TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH already in the calling
#      environment (e.g. the adapter path, which exports both before this
#      script would ever run — re-exporting the same value is a no-op).
# --role sets TALOS_ROLE; there is no fallback chain for it, it is exported
# only when --role is passed.
#
# With a command after `--`, that command is exec'd in the foreground (no
# backgrounding) with the identity exported. Without one, every `verify:`
# command from config is run in order, stopping at the first failure and
# propagating its exit code.
#
# Always prints one line to stderr — "talos:verify issue=<N> worktree=<path>"
# — so a transcript or log shows which identity a verify run actually used.
#
# Portable bash 3.2 (macOS default /bin/bash).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  # shellcheck source=pipeline-cfg-cache.sh
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
fi

_issue=""
_worktree=""
_role=""
_cmd=()

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] || { echo "pipeline-verify: --issue requires a value" >&2; exit 2; }
      _issue="$2"; shift 2 ;;
    --worktree)
      [ $# -ge 2 ] || { echo "pipeline-verify: --worktree requires a value" >&2; exit 2; }
      _worktree="$2"; shift 2 ;;
    --role)
      [ $# -ge 2 ] || { echo "pipeline-verify: --role requires a value" >&2; exit 2; }
      _role="$2"; shift 2 ;;
    --)
      shift
      _cmd=("$@")
      break
      ;;
    *)
      echo "pipeline-verify: unknown argument: $1" >&2
      echo "usage: pipeline-verify.sh [--issue N] [--worktree PATH] [--role ROLE] [-- <cmd...>]" >&2
      exit 2
      ;;
  esac
done

# _parse_talos_env FILE -- parse a .talos/env file line-by-line (never
# executed as shell — see the header comment). Sets _envfile_issue /
# _envfile_worktree, or prints a diagnostic naming FILE and exits 2 if any
# line doesn't match one of the two expected KEY=value forms, the issue
# isn't all-digits, or the worktree path isn't an existing absolute
# directory.
_parse_talos_env() {
  local f="$1" line val bad=0
  _envfile_issue=""
  _envfile_worktree=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      TALOS_ISSUE_NUMBER=*)
        val="${line#TALOS_ISSUE_NUMBER=}"
        case "$val" in
          ''|*[!0-9]*) bad=1 ;;
          *) _envfile_issue="$val" ;;
        esac
        ;;
      TALOS_WORKTREE_PATH=*)
        val="${line#TALOS_WORKTREE_PATH=}"
        case "$val" in
          /*) [ -d "$val" ] && _envfile_worktree="$val" || bad=1 ;;
          *) bad=1 ;;
        esac
        ;;
      *)
        bad=1
        ;;
    esac
  done < "$f"
  if [ "$bad" -ne 0 ]; then
    echo "pipeline-verify: malformed $f: expected only lines matching TALOS_ISSUE_NUMBER=<digits> or TALOS_WORKTREE_PATH=<existing absolute dir>" >&2
    exit 2
  fi
}

# Fallback 2: <toplevel>/.talos/env (toplevel of the current worktree, or
# $PWD if not inside a git repo), parsed (never sourced) and only consulted
# for whichever of issue/worktree the flags above left unset.
if { [ -z "$_issue" ] || [ -z "$_worktree" ]; }; then
  _env_toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_env_toplevel" ] || _env_toplevel="$PWD"
  _envfile="$_env_toplevel/.talos/env"
  if [ -f "$_envfile" ]; then
    _parse_talos_env "$_envfile"
    [ -z "$_issue" ] && _issue="$_envfile_issue"
    [ -z "$_worktree" ] && _worktree="$_envfile_worktree"
  fi
fi

# Fallback 3: whatever the calling environment already set (adapter path).
[ -z "$_issue" ] && _issue="${TALOS_ISSUE_NUMBER:-}"
[ -z "$_worktree" ] && _worktree="${TALOS_WORKTREE_PATH:-}"

export TALOS_ISSUE_NUMBER="$_issue"
export TALOS_WORKTREE_PATH="$_worktree"
[ -n "$_role" ] && export TALOS_ROLE="$_role"

echo "talos:verify issue=$_issue worktree=$_worktree" >&2

if [ "${#_cmd[@]}" -gt 0 ]; then
  "${_cmd[@]}"
  exit $?
fi

# No command given — run every verify: command from config, in order,
# stopping at the first failure and propagating its exit code.
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  bash -c "$_line"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    exit "$_rc"
  fi
done <<EOF
$(cfg verify "")
EOF

exit 0
