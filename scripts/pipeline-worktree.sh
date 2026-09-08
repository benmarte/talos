#!/usr/bin/env bash
# pipeline-worktree.sh — lifecycle for per-issue developer worktrees and
# Claude Code harness worktrees.
#
# The developer subagent runs with isolation:"worktree" and implements on a
# branch named fix/issue-<N>-<slug> (or feat/issue-<N>-<slug>). Once that
# worktree has commits it is NOT auto-removed, so it must be cleaned up
# explicitly after the PR merges. The orchestrator also runs `sweep`
# unconditionally at the END of every run (skills/pipeline/SKILL.md Step 5),
# in addition to the Step 1 startup backstop — otherwise worktrees pile up on
# disk between runs.
#
# `sweep` reclaims two categories of worktree:
#   - issue-pattern:   (fix|feat)/issue-<N>-... — created by the developer/QA
#                       stages for one issue.
#   - harness worktrees: branches named worktree-agent-<hash>, created by the
#                       Claude Code harness itself (not by Talos) for agent
#                       sessions. Talos only reclaims these after the fact —
#                       it never creates or controls them.
#
# Safety: a worktree in either category is NEVER deleted (by `sweep` or
# `remove`) while it has uncommitted changes, commits its upstream doesn't
# have yet ("unpushed"), or whose dirty state simply can't be determined
# (a broken/corrupted worktree fails `git status --porcelain` closed, not
# open). When no upstream is configured (or it can no longer be resolved,
# e.g. deleted on the remote and pruned) the ahead-check falls back to the
# repo's default branch instead of assuming "nothing to lose" — this applies
# equally to issue worktrees with real, never-pushed commits and to harness
# worktrees, which have no PR/push precedent at all. Such worktrees are
# listed in the command's output (path, branch, reason) instead of being
# silently skipped. A worktree whose directory no longer exists (prunable) is
# always reclaimed, regardless of dirty/unpushed state — there is no working
# tree left to preserve.
#
# Verbs:
#   remove <issue-number>   Remove the worktree(s) for issue <N> and delete the
#                           now-merged local branch. Idempotent: a no-op (exit 0)
#                           when no matching worktree exists.
#   sweep <keep-id>...      Remove every issue worktree whose id is NOT in the
#                           keep list, plus every reclaimable harness worktree.
#                           Leaves branches intact (they may be unmerged). Pass
#                           the ids of every issue still in the current run's
#                           queue.
#   list                    Print "id<TAB>path<TAB>branch" for each issue and
#                           harness worktree (id is "-" for harness entries).
#                           When the count of non-active worktrees (excluding
#                           lane homes and the current checkout) exceeds
#                           execution.worktree_warn_threshold (default 10),
#                           prints a final warning line.
#
# All verbs act on the repository containing the current working directory and
# run `git worktree prune` afterward — including when nothing matched for
# removal. Safe to run from the orchestrator's main checkout (worktrees are
# listed repo-wide).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
# pipeline-lock.sh (#180): `git worktree add/remove` races on the same
# repo's shared .git metadata when two stages run concurrently
# (issues.max_parallel > 1) -- serialize remove/sweep bodies below. Guarded
# like pipeline-cfg-cache.sh above: fall back to running unlocked with a
# warning rather than failing a partial install outright.
if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 2; [ "${1:-}" = "--" ] && shift; "$@"; }
  echo "pipeline: lock helper missing, worktree operations are unsynchronized" >&2
fi

# Lock is keyed on the repo's shared git dir (via --git-common-dir, which
# resolves to the SAME path from any of that repo's worktrees) so concurrent
# `remove`/`sweep` invocations from different worktree checkouts of the same
# repo still serialize against each other, and different repos never share a
# lock.
_WT_GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
_WT_LOCK_RESOURCE="$_WT_GIT_COMMON_DIR/talos-worktree"

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

# Emit "path<TAB>branch" for every worktree whose checked-out branch is
# worktree-agent-<hash> — the naming the Claude Code harness uses for its own
# agent-session worktrees. Same porcelain-parsing shape as _issue_worktrees.
_harness_worktrees() {
  git worktree list --porcelain 2>/dev/null | python3 -c '
import re, sys

def emit(path, branch):
    if not (path and branch):
        return
    if re.match(r"refs/heads/worktree-agent-", branch):
        short = branch[len("refs/heads/"):]
        print("\t".join([path, short]))

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
emit(path, branch)
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

# The repo's best-effort default branch: origin/HEAD if known locally, else a
# local main/master. Used only as the "base ref" fallback for branches with no
# upstream configured. Empty (and exit 1) when neither is resolvable.
_default_branch_ref() {
  local ref b
  ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then printf '%s' "$ref"; return 0; fi
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s' "$b"
      return 0
    fi
  done
  return 1
}

# True when local branch $1 has commits ahead of its upstream/base ref --
# i.e. genuinely unpushed work. Used for BOTH issue-pattern and harness
# worktrees (issue #170 review round 2: these were two near-duplicate
# functions -- _ahead_of_upstream compared only against the upstream and
# treated "no upstream configured" as fail-open "not ahead", while
# _ahead_of_base fell back to the default branch. That divergence was itself
# a bug: an issue worktree with real, committed-but-never-pushed work (no PR
# opened yet, so no upstream at all) read as "not ahead" and was silently
# swept. There is exactly one safe rule now, applied everywhere: no upstream
# (or an unresolvable one) always falls back to comparing against the repo's
# default branch, never to "nothing to lose".
#
# `--verify --quiet` is required: a bare `rev-parse --symbolic-full-name`
# prints the literal, unresolved "$branch@{upstream}" token to stdout when the
# upstream can't be resolved (exit 128) instead of leaving it empty, so a
# careless "$(...)" capture can read that token back as if it were a real ref
# and feed it to `git rev-list --count`, which then fails silently (stderr
# redirected) and reads back as "0 commits ahead" -- exactly the bug this
# guards against, both for a deleted+pruned remote branch and for no upstream
# at all. Any unresolvable base (no upstream and no default branch), or any
# later failure to compute the ahead count, fails safe toward "ahead" so the
# worktree is preserved rather than guessed away.
#
# A branch that IS the resolved default branch itself (base == branch, e.g. a
# lane home checked out on main) is never "ahead" of itself.
_ahead_of_base() {
  local branch="$1" base ahead
  base="$(git rev-parse --verify --quiet --abbrev-ref --symbolic-full-name "$branch@{upstream}" 2>/dev/null)"
  if [ -z "$base" ]; then
    base="$(_default_branch_ref)" || return 0
    [ "$base" = "$branch" ] && return 1
  fi
  ahead="$(git rev-list --count "$base..$branch" 2>/dev/null)" || return 0
  [ -z "$ahead" ] && return 0
  [ "$ahead" -gt 0 ]
}

# Single "is this worktree safe to delete" gate, shared by remove and sweep
# for both worktree categories (issue-pattern and harness). Prints a reason
# ("status failed", "dirty", "unpushed", or "dirty,unpushed") when worktree
# $1 (branch $2) must be preserved. Prints nothing when every check succeeds
# and it is safe to remove.
#
# The status check captures `git status --porcelain`'s output and exit code
# SEPARATELY and checks the exit code first: a broken/corrupted worktree
# (bad index, permission error, etc.) also prints nothing to stdout, which is
# indistinguishable from a genuinely clean tree if only `-n "$(...)"` is
# tested -- that misread it as clean and let a worktree whose real state is
# unknown be force-removed with no trace. Any non-zero status short-circuits
# straight to "status failed" without also running the ahead check, since a
# worktree we can't even inspect can't be trusted for anything else either.
_preserve_reason() {
  local path="$1" branch="$2" status_out status_rc unpushed=""
  status_out="$(git -C "$path" status --porcelain 2>/dev/null)"
  status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    printf 'status failed'
    return
  fi
  _ahead_of_base "$branch" && unpushed="unpushed"
  if [ -n "$status_out" ] && [ -n "$unpushed" ]; then
    printf 'dirty,unpushed'
  elif [ -n "$status_out" ]; then
    printf 'dirty'
  else
    printf '%s' "$unpushed"
  fi
}

# Count non-active worktrees (issue-pattern + harness, excluding lane homes
# and the current checkout) — mirrors what `sweep` would consider removing.
# Takes the already-fetched `_issue_worktrees`/`_harness_worktrees` output as
# $1/$2 rather than calling them again itself: `list` is the only caller, and
# it already fetched both once to print them, so re-running `git worktree
# list --porcelain` (and re-parsing it) a second time per category here would
# be pure overhead.
_stale_worktree_count() {
  local issue_listing="$1" harness_listing="$2"
  local count=0 wt_path
  while IFS=$'\t' read -r wt_path _wt_branch _wt_id; do
    [ -z "$wt_path" ] && continue
    _is_lane_home "$wt_path" && continue
    _is_self "$wt_path" && continue
    count=$((count + 1))
  done <<<"$issue_listing"
  while IFS=$'\t' read -r wt_path _wt_branch; do
    [ -z "$wt_path" ] && continue
    _is_lane_home "$wt_path" && continue
    _is_self "$wt_path" && continue
    count=$((count + 1))
  done <<<"$harness_listing"
  printf '%d' "$count"
}

# _wt_remove_body <issue-number> -- the actual work of `remove`, run under
# the repo-wide lock (#180) so a concurrent `remove`/`sweep` from another
# stage can't race `git worktree remove`/`git branch -D` against this one.
_wt_remove_body() {
  n="${1:-}"
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
    if [ -d "$wt_path" ]; then
      reason="$(_preserve_reason "$wt_path" "$wt_branch")"
      if [ -n "$reason" ]; then
        echo "pipeline-worktree: preserving worktree for issue #$wt_id ($wt_path, $wt_branch) — reason: $reason"
        continue
      fi
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
}

# _wt_sweep_body <keep-id>... -- the actual work of `sweep`, run under the
# repo-wide lock (#180) for the same reason as _wt_remove_body.
_wt_sweep_body() {
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
    if [ ! -d "$wt_path" ]; then
      git worktree remove --force "$wt_path" 2>/dev/null || true
      echo "pipeline-worktree: reclaimed prunable worktree for issue #$wt_id ($wt_path)"
      continue
    fi
    reason="$(_preserve_reason "$wt_path" "$wt_branch")"
    if [ -n "$reason" ]; then
      echo "pipeline-worktree: preserving worktree for issue #$wt_id ($wt_path, $wt_branch) — reason: $reason"
      continue
    fi
    git worktree remove --force "$wt_path" 2>/dev/null || true
    echo "pipeline-worktree: swept orphaned worktree for issue #$wt_id ($wt_path)"
  done < <(_issue_worktrees)
  while IFS=$'\t' read -r wt_path wt_branch; do
    if _is_lane_home "$wt_path"; then
      echo "pipeline-worktree: refusing to sweep lane home $wt_path (.talos-lane-home present)"
      continue
    fi
    if _is_self "$wt_path"; then
      echo "pipeline-worktree: refusing to sweep the current checkout ($wt_path)"
      continue
    fi
    if [ ! -d "$wt_path" ]; then
      git worktree remove --force "$wt_path" 2>/dev/null || true
      echo "pipeline-worktree: reclaimed prunable harness worktree ($wt_path, $wt_branch)"
      continue
    fi
    reason="$(_preserve_reason "$wt_path" "$wt_branch")"
    if [ -n "$reason" ]; then
      echo "pipeline-worktree: preserving harness worktree $wt_path ($wt_branch) — reason: $reason"
      continue
    fi
    git worktree remove --force "$wt_path" 2>/dev/null || true
    echo "pipeline-worktree: swept harness worktree ($wt_path, $wt_branch)"
  done < <(_harness_worktrees)
  git worktree prune 2>/dev/null || true
  exit 0
}

case "$verb" in
  list)
    issue_listing="$(_issue_worktrees)"
    harness_listing="$(_harness_worktrees)"
    [ -n "$issue_listing" ] && printf '%s\n' "$issue_listing" | awk -F'\t' '{print $3"\t"$1"\t"$2}'
    [ -n "$harness_listing" ] && printf '%s\n' "$harness_listing" | awk -F'\t' '{print "-\t"$1"\t"$2}'
    count="$(_stale_worktree_count "$issue_listing" "$harness_listing")"
    threshold="$(cfg execution.worktree_warn_threshold 10)"
    if [ "$count" -gt "$threshold" ] 2>/dev/null; then
      echo "pipeline-worktree: WARNING: $count stale worktrees exceed threshold $threshold"
    fi
    ;;

  remove)
    if [ -z "${1:-}" ]; then
      echo "usage: pipeline-worktree.sh remove <issue-number>" >&2
      exit 2
    fi
    with_lock "$_WT_LOCK_RESOURCE" 10 -- _wt_remove_body "$@"
    ;;

  sweep)
    with_lock "$_WT_LOCK_RESOURCE" 10 -- _wt_sweep_body "$@"
    ;;

  *)
    echo "usage: pipeline-worktree.sh <remove <n> | sweep <keep-id>... | list>" >&2
    exit 2
    ;;
esac
