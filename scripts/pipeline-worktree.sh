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

# True when $1 is a lane HOME checkout — a long-lived working directory for a
# pipeline lane (canonical or an LLM-experiment branch), not a disposable
# per-issue worktree. Marked by an untracked .talos-lane-home file, which never
# propagates into worktrees created from a branch.
#
# Why: all lanes share ONE git repo, so `sweep` is repo-wide. An inline runner
# (agents.runner: pi) checks out fix|feat/issue-<N>-* directly in its lane home,
# which makes that home match _issue_worktrees. Sweeping from another lane would
# delete a live lane's working directory mid-run.
_is_lane_home() {
  [ -f "$1/.talos-lane-home" ]
}

# True when $1 is the checkout we are running from (or an ancestor of it).
#
# In inline/no-subagent harnesses (agents.runner: pi) the developer stage works
# directly in the orchestrator's own checkout rather than a disposable
# worktree, so that checkout ends up with fix/issue-<N>-* checked out and
# therefore MATCHES _issue_worktrees. Removing it deletes the running session's
# working directory: every later command fails with "no such file or
# directory" and the run cannot recover in place. Never remove the checkout we
# are standing in — in subagent mode this is a no-op, because the orchestrator
# sits in the main checkout while issue worktrees live elsewhere.
_is_self() {
  local target here
  target="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  here="$(pwd -P)"
  [ "$here" = "$target" ] && return 0
  # A bare `case` with no matching pattern exits 0, so the fallthrough must be
  # an explicit `return 1` — otherwise this reports every path as self.
  case "$here" in "$target"/*) return 0 ;; esac
  return 1
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
      if _is_lane_home "$wt_path"; then
        echo "pipeline-worktree: refusing to remove lane home $wt_path (.talos-lane-home present)"
        continue
      fi
      if _is_self "$wt_path"; then
        echo "pipeline-worktree: refusing to remove the current checkout ($wt_path) — inline mode implements in place; branch $wt_branch left alone"
        continue
      fi
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
    # Multi-lane interlock: sweep is repo-wide, but per-issue worktrees belong to
    # ONE lane (their issue id is only in that lane's queue). With several lanes
    # sharing this repo, a sweep run from lane A deletes lane B's in-flight
    # developer worktree. Lane homes are protected by .talos-lane-home; the
    # disposable per-issue worktrees deliberately are not — they must stay
    # removable by their OWN lane. So when more than one lane home exists, do
    # nothing unless the operator explicitly opts in.
    _lane_home_count=0
    while IFS= read -r _p; do
      [ -f "$_p/.talos-lane-home" ] && _lane_home_count=$((_lane_home_count + 1))
    done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
    if [ "$_lane_home_count" -gt 1 ] && [ -z "${TALOS_SWEEP_ALL_LANES:-}" ]; then
      echo "pipeline-worktree: $_lane_home_count lanes share this repo — skipping sweep (it is repo-wide and would delete another lane's in-flight worktree)."
      echo "pipeline-worktree: per-issue 'remove <N>' is unaffected. To override: TALOS_SWEEP_ALL_LANES=1 pipeline-worktree.sh sweep ..."
      git worktree prune 2>/dev/null || true
      exit 0
    fi
    while IFS=$'\t' read -r wt_path wt_branch wt_id; do
      case "$keep" in *" $wt_id "*) continue ;; esac
      if _is_lane_home "$wt_path"; then
        echo "pipeline-worktree: refusing to sweep lane home $wt_path (.talos-lane-home present)"
        continue
      fi
      if _is_self "$wt_path"; then
        echo "pipeline-worktree: refusing to sweep the current checkout ($wt_path)"
        continue
      fi
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
