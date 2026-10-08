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

# _talos_state_dir -> prints the absolute path of the Talos run-state
# directory, <git-common-dir>/talos, creating it mode 0700 if absent, or
# nothing (rc 1) outside a git repository (#517).
#
# This is where every piece of per-repo run state that must never be
# committable lives: the events log (<state>/events.jsonl, default
# events.path "talos/events.jsonl" resolved against the common dir) and the
# compact stage handoff (<state>/handoff/<N>.json). The git common dir is
# shared by every linked worktree of a repo (git-common-dir(5)) and is never
# inside any worktree checkout -- unlike <repo-root>/.talos/, which IS inside
# the tree in a normal clone (that was the #517 / dogfood-finding-#4 bug: an
# agent's `git add -A` committed the run's own state). Same convention as the
# lease/done ledgers (<common>/talos-lease.ledger, talos.sh).
#
# --git-common-dir can print a path relative to the caller's cwd (e.g. ".git"
# from the main repo, "../../.git" from a linked worktree two levels down),
# so it is resolved to an absolute physical path here (pwd -P, like
# _wt_main_worktree_path_for: on macOS $TMPDIR -- test sandboxes -- is itself
# a symlink, and git's own output is always fully resolved).
_talos_state_dir() {
  local common state
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) : ;;
    *) common="$(cd "$(dirname "$common")" 2>/dev/null && pwd -P)/$(basename "$common")" ;;
  esac
  [ -n "$common" ] && [ -d "$common" ] || return 1
  state="$common/talos"
  if [ ! -d "$state" ]; then
    mkdir -m 700 -p "$state" 2>/dev/null || return 1
  fi
  printf '%s' "$state"
}

# _talos_ignore_in_tree [where] -- the guard the #517 dogfood run lacked:
# before ANY creation of the deliberately in-tree .talos/ files (the
# per-worktree .talos/env, providers.json, the evidence dir), make sure the
# git ignore file EXCLUDES .talos/ -- by appending a `.talos/` line to
# <git-common-dir>/info/exclude when absent. Never a tracked file: the
# repo's .gitignore is the user's, Talos does not edit it (and never
# commits a .gitignore change to a PR branch).
#
# <where> is a path inside the repository that is about to receive a
# .talos/ entry (a worktree toplevel; default: the caller's cwd). Idempotent
# -- a second call adds nothing; a duplicate line would be harmless per
# gitignore(5), so no lock around the append is needed.
#
# Tracked .talos/ content (a repo that committed it before #517): warn at
# most once per process invocation -- the per-VERB-process analogue of the
# warn-once stamp pattern -- and touch nothing else: tracked files stay
# tracked, nothing is unstaged or rewritten, the exit code is unaffected.
#
# Never fails: outside a git repo, or when info/exclude cannot be written,
# this is a no-op (the in-tree writes degrade to exactly their pre-#517
# committable behaviour; the relocated run state stays safe regardless).
_TALOS_IGNORE_WARNED=""
_talos_ignore_in_tree() {
  local where="${1:-.}" common excl
  common="$(git -C "$where" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  case "$common" in
    /*) : ;;
    *) common="$(cd "$where" 2>/dev/null && cd "$(dirname "$common")" 2>/dev/null && pwd -P)/$(basename "$common")" ;;
  esac
  [ -n "$common" ] && [ -d "$common" ] || return 0
  if [ -z "$_TALOS_IGNORE_WARNED" ]; then
    _TALOS_IGNORE_WARNED=1
    if [ -n "$(git -C "$where" ls-files -- .talos 2>/dev/null)" ]; then
      echo "talos: .talos/ has tracked content in this repository; Talos keeps run state under the git common dir, never writes the tracked .talos/, and leaves it alone" >&2
    fi
  fi
  excl="$common/info/exclude"
  if [ -f "$excl" ] && grep -qxF '.talos/' "$excl" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$common/info" 2>/dev/null || return 0
  printf '.talos/\n' >> "$excl" 2>/dev/null || return 0
  return 0
}
