#!/usr/bin/env bash
# pipeline-worktree.sh — lifecycle for per-issue developer worktrees.
#
# The developer subagent runs with isolation:"worktree" and implements on a
# branch named fix/issue-<N>-<slug> (or feat/issue-<N>-<slug>). Once that
# worktree has commits it is NOT auto-removed, so it must be cleaned up
# explicitly after the PR merges — otherwise worktrees pile up on disk and the
# next run only reclaims them via a best-effort startup sweep.
#
# Verbs:
#   remove <issue-number>   Remove the worktree(s) for issue <N> and delete the
#                           now-merged local branch. Idempotent: a no-op (exit 0)
#                           when no matching worktree exists.
#   sweep <keep-id>...      Remove every issue worktree whose id is NOT in the
#                           keep list. Leaves branches intact (they may be
#                           unmerged). Pass the ids of every issue still in the
#                           current run's queue.
#   list                    Print "id<TAB>path<TAB>branch" for each issue worktree.
#
# All verbs act on the repository containing the current working directory and
# run `git worktree prune` afterward. Safe to run from the orchestrator's main
# checkout (worktrees are listed repo-wide).
set -uo pipefail

verb="${1:-}"; shift || true

# Emit "path<TAB>branch<TAB>id" for every worktree whose checked-out branch is
# (fix|feat)/issue-<id>-...  Parses `git worktree list --porcelain`.
_issue_worktrees() {
  git worktree list --porcelain 2>/dev/null | python3 -c '
import re, sys

def emit(path, branch):
    if not (path and branch):
        return
    m = re.search(r"refs/heads/(?:fix|feat)/issue-(\d+)-", branch)
    if m:
        short = branch[len("refs/heads/"):]
        print("\t".join([path, short, m.group(1)]))

path = branch = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        path, branch = line[len("worktree "):], None
    elif line.startswith("branch "):
        branch = line[len("branch "):]
    elif line == "":
        emit(path, branch)
        path = branch = None
emit(path, branch)  # final block may have no trailing blank line
'
}

case "$verb" in
  list)
    _issue_worktrees | awk -F'\t' '{print $3"\t"$1"\t"$2}'
    ;;

  remove)
    n="${1:-}"
    if [ -z "$n" ]; then
      echo "usage: pipeline-worktree.sh remove <issue-number>" >&2
      exit 2
    fi
    removed=0
    while IFS=$'\t' read -r wt_path wt_branch wt_id; do
      [ "$wt_id" = "$n" ] || continue
      git worktree remove --force "$wt_path" 2>/dev/null || true
      # Branch is merged (PR completed) — force-delete; squash merges are not
      # ancestors, so `-d` would refuse.
      git branch -D "$wt_branch" 2>/dev/null || true
      removed=$((removed + 1))
      echo "pipeline-worktree: removed worktree for issue #$n ($wt_path, $wt_branch)"
    done < <(_issue_worktrees)
    git worktree prune 2>/dev/null || true
    [ "$removed" -eq 0 ] && echo "pipeline-worktree: no worktree for issue #$n (already clean)"
    exit 0
    ;;

  sweep)
    keep=" $* "   # space-delimited so we can match " <id> " exactly
    while IFS=$'\t' read -r wt_path wt_branch wt_id; do
      case "$keep" in *" $wt_id "*) continue ;; esac
      git worktree remove --force "$wt_path" 2>/dev/null || true
      echo "pipeline-worktree: swept orphaned worktree for issue #$wt_id ($wt_path)"
    done < <(_issue_worktrees)
    git worktree prune 2>/dev/null || true
    exit 0
    ;;

  *)
    echo "usage: pipeline-worktree.sh <remove <n> | sweep <keep-id>... | list>" >&2
    exit 2
    ;;
esac
