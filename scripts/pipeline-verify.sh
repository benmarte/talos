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
#   pipeline-verify.sh [--issue N] [--worktree PATH] [--role ROLE] [--all] [-- <cmd...>]
#   pipeline-verify.sh --guards [--worktree PATH]
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
#      *per-worktree* file at this worktree's own root (deliberately in-tree
#      and self-ignored via `info/exclude`, #517), not the events.jsonl that
#      pipeline-events.sh reads: the run state lives at
#      <git common dir>/talos/, outside every git tree -- one path resolved
#      via `git rev-parse --git-common-dir`, shared by every worktree of a repo.
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
# The QA stage (role `qa`: --role qa, or TALOS_ROLE=qa from pipeline-agent.sh)
# may not make that bare call: the `verify:` list is the full suite, which
# cannot finish inside verify.timeout_ms (#778). It exits 2 with a hint naming
# the targeted form instead. `--all` is the explicit opt-in to run the
# `verify:` list (the pre-CI gate uses it); with a command it is a usage error.
#
# `--guards` (#832) prints the repo-wide guard tests of the checkout (--worktree
# PATH, else the current directory), one path per line, sorted, at most 50, and
# changes nothing: git-tracked test files whose content walks the repo or parses
# source. The developer prompt names them next to `verify.dev_tests`.
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
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

_issue=""
_worktree=""
_role=""
_all=0
_guards=0
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
    --all)
      _all=1; shift ;;
    --guards)
      _guards=1; shift ;;
    --)
      shift
      _cmd=("$@")
      break
      ;;
    *)
      echo "pipeline-verify: unknown argument: $1" >&2
      echo "usage: pipeline-verify.sh [--issue N] [--worktree PATH] [--role ROLE] [--all | --guards] [-- <cmd...>]" >&2
      exit 2
      ;;
  esac
done

# --guards (#832): the repo-wide guard tests, discovered from the checkout. A
# guard is a git-tracked test file whose content walks the repo or parses
# source, so a run scoped to the touched package cannot miss it. Read-only: one
# repo-relative path per line, sorted, at most 50; empty output when none match.
if [ "$_guards" -eq 1 ]; then
  if [ "$_all" -eq 1 ] || [ "${#_cmd[@]}" -gt 0 ]; then
    echo "pipeline-verify: --guards lists the guard tests and takes no --all or -- <cmd>" >&2
    exit 2
  fi
  _groot="${_worktree:-.}"
  _gre='filepath\.(Walk|WalkDir)|go/parser|go/ast|packages\.Load|os\.walk\(|os\.Walk\(|rglob\(|glob\.glob\(|ast\.parse\(|ts\.createProgram|readdirSync\(.*recursive|git ls-files'
  {
    while IFS= read -r -d '' _gf; do
      case "${_gf##*/}" in
        *_test.go|test_*.py|*_test.py|*.test.js|*.test.jsx|*.test.ts|*.test.tsx|\
        *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*Test.java|*_spec.rb|test-*.sh) ;;
        *) continue ;;
      esac
      [ -f "$_groot/$_gf" ] || continue
      grep -Eq -- "$_gre" "$_groot/$_gf" 2>/dev/null && printf '%s\n' "$_gf"
    done < <(git -C "$_groot" ls-files -z 2>/dev/null)
  } | LC_ALL=C sort -u | head -n 50
  exit 0
fi

if [ "$_all" -eq 1 ] && [ "${#_cmd[@]}" -gt 0 ]; then
  echo "pipeline-verify: --all runs the verify: list and takes no -- <cmd>" >&2
  exit 2
fi

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

# The QA stage's bare call would run the full suite and time out; --all opts in.
if [ "$_all" -eq 0 ] && [ "${TALOS_ROLE:-}" = "qa" ]; then
  echo "pipeline-verify: the qa stage needs a command: pipeline-verify.sh ... -- bash tests/run-tests.sh --changed origin/<base> --strict (--all runs the full verify: list)" >&2
  exit 2
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
$(cfg verify)
EOF

exit 0
