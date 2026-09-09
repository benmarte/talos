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
#   remove <issue-number>   Remove EVERY worktree for issue <N> -- the
#                           developer worktree AND any Claude Code harness
#                           (`agent-*`) worktree tagged to <N> (#240) -- and
#                           delete their now-merged local branches. Idempotent:
#                           a no-op (exit 0) when no matching worktree exists.
#   sweep [<open-id>...]    Remove every non-main worktree whose issue is NOT
#                           in the open-id list -- developer AND harness
#                           worktrees alike, regardless of dirty/unpushed
#                           state (#240): an untagged or otherwise
#                           unidentifiable worktree counts as "not open".
#                           Preserves ONLY worktrees tagged/identified with an
#                           open id (plus lane homes and the current
#                           checkout, as always). Also deletes local branches
#                           that are not main/master/the configured base, do
#                           not track a live remote branch, and are not the
#                           head of an open PR (queries `pipeline-vcs.sh
#                           list-prs` once, not per branch; on failure,
#                           branch cleanup is skipped entirely -- fail safe).
#                           Runs `git worktree prune` afterward. Prints one
#                           line per removal/deletion and a summary line
#                           `talos:worktree-sweep removed=<n> kept=<n>
#                           freed=<size>`.
#   tag <issue-number>      Write <current worktree toplevel>/.talos/env
#                           (the #186 KEY=value format) so `remove`/`sweep`
#                           can identify this worktree even when it isn't a
#                           developer worktree (QA/reviewer/security/docs
#                           harness worktrees, #240). Idempotent (overwrites).
#                           Refuses -- with a clear error, exit 1 -- to run in
#                           the main worktree (the one whose toplevel is the
#                           parent directory of the repo's shared
#                           `git-common-dir`), so the orchestrator's own
#                           checkout can never be mistaken for a disposable
#                           issue worktree.
#   status                  Print worktree/dirty/branch counts and the total
#                           size of .claude/worktrees.
#   list                    Print "id<TAB>path<TAB>branch" for each issue and
#                           harness worktree (id is "-" for harness entries).
#                           When the count of non-active worktrees (excluding
#                           lane homes and the current checkout) exceeds
#                           execution.worktree_warn_threshold (default 10),
#                           prints a final warning line.
#   create <n> <branch>     Create a worktree for issue <n> on a new local
#                           <branch> off origin/<default-branch> (best-effort
#                           default: origin/HEAD, else local main/master), at
#                           .claude/worktrees/<branch, "/" -> "-">. Prints
#                           the absolute worktree
#                           path on stdout. After creating it, writes
#                           <worktree>/.talos/env with two plain `KEY=value`
#                           lines (TALOS_ISSUE_NUMBER, TALOS_WORKTREE_PATH;
#                           raw values, no quoting) so `pipeline-verify.sh`
#                           can resolve stage identity with zero arguments
#                           from inside that worktree (#186). This file is
#                           PARSED line-by-line by the reader, never
#                           `source`d, so no shell quoting is needed even
#                           when the worktree path contains spaces. This is
#                           a PER-WORKTREE file at that worktree's own root
#                           -- not the shared main-repo .talos/ that
#                           pipeline-events.sh's events.jsonl lives under
#                           (that one resolves via `git rev-parse
#                           --git-common-dir`, one path shared by every
#                           worktree of this repo). Same ".talos/" name,
#                           deliberately different resolution; both are
#                           gitignored. `create` acquires the same
#                           repo-wide lock as `remove`/`sweep` (#180) since
#                           `git worktree add` races their mutation of the
#                           shared git-common-dir metadata. `tag` (#240)
#                           writes the very same per-worktree file from
#                           inside an already-created worktree instead.
#

# `remove` and `sweep` act on the repository containing the current working
# directory and run `git worktree prune` afterward — including when nothing
# matched for removal. `create` does not prune (it only adds). Safe to run
# from the orchestrator's main checkout (worktrees are listed repo-wide).
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

# ── #240: unified worktree identification, used by remove/sweep/tag/status ──
#
# Prior to #240, `remove`/`sweep` only ever recognized two hard-coded
# patterns: developer worktrees (fix|feat/issue-<N>-...) and the Claude Code
# harness's own worktree-agent-<hash> branches. Neither pattern covers a
# harness worktree the ORCHESTRATOR spawned for QA/reviewer/security/docs
# (branch/dir named "agent-*" by the harness, no issue number anywhere in
# it) -- those only ever got reclaimed when the harness itself judged them
# "unchanged", which QA's scratch files (.bak, temp configs) defeat forever.
# `tag <N>` (below) lets any stage record its own issue number in a
# per-worktree file; `_wt_issue_of` is the single place that now resolves
# "which issue does this worktree belong to" for every verb, checking (in
# order) the developer path/branch pattern, then the tag file.

# Emit "path" for EVERY worktree in the repo (main and linked alike) --
# generalizes _issue_worktrees/_harness_worktrees's pattern-scoped listings
# for callers (remove/sweep/status) that must consider every worktree, not
# just the two legacy patterns.
_wt_all_worktrees() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}'
}

# Absolute path of the MAIN worktree, resolved from worktree $1 (default:
# cwd). Every worktree of a repo -- main or linked -- resolves the SAME
# `git rev-parse --git-common-dir`; git always creates the shared `.git` as
# a plain directory directly under the main worktree's own toplevel, so that
# common dir's parent directory IS the main worktree's path, from anywhere.
_wt_main_worktree_path_for() {
  local path="${1:-.}" common_dir common_abs
  common_dir="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_dir" in
    # -P (physical, symlinks resolved) so this matches `git rev-parse
    # --show-toplevel`'s own resolution -- git always resolves symlinks in
    # its output, and on macOS $TMPDIR (what test sandboxes live under) is
    # itself a symlink, so a plain `pwd` here would silently never equal
    # `--show-toplevel` for the very worktree it IS the main one of (#240
    # review: _wt_is_main_worktree fails to recognize the main worktree).
    /*) common_abs="$common_dir" ;;
    *) common_abs="$(cd "$path" && cd "$(dirname "$common_dir")" 2>/dev/null && pwd -P)/$(basename "$common_dir")" ;;
  esac
  [ -z "$common_abs" ] && return 1
  dirname "$common_abs"
}

# True when worktree $1 (default: cwd) IS the main worktree -- see
# _wt_main_worktree_path_for above for why this comparison is reliable from
# any worktree of the repo.
_wt_is_main_worktree() {
  local path="${1:-.}" toplevel main_path
  toplevel="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
  main_path="$(_wt_main_worktree_path_for "$path")" || return 1
  [ "$toplevel" = "$main_path" ]
}

# Read a validated TALOS_ISSUE_NUMBER from <path>/.talos/env (the file `tag`
# and `create` write, #186/#240 format). PARSES the file line-by-line --
# never `source`s it, matching the format's own no-shell-quoting contract --
# and only accepts an all-digits value; anything else (missing file, missing
# key, non-numeric value) yields nothing.
_wt_tag_issue() {
  local path="$1" envfile="$1/.talos/env" line val
  [ -f "$envfile" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      TALOS_ISSUE_NUMBER=*)
        val="${line#TALOS_ISSUE_NUMBER=}"
        case "$val" in
          ''|*[!0-9]*) ;;
          *) printf '%s' "$val"; return 0 ;;
        esac
        ;;
    esac
  done < "$envfile"
}

# Resolve the issue number worktree $1 belongs to, or print nothing when it
# can't be identified. Checked in order: (1) the worktree directory's own
# basename contains "issue-<N>" (what `create` and QA's convention both
# produce), (2) the checked-out branch matches
# (fix|feat|refactor|docs|ci)/issue-<N>-..., (3) the #186/#240 tag file.
_wt_issue_of() {
  local path="$1" base branch id
  base="${path##*/}"
  if [[ "$base" =~ issue-([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  branch="$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null)"
  if [[ "$branch" =~ ^(fix|feat|refactor|docs|ci)/issue-([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  id="$(_wt_tag_issue "$path")"
  [ -n "$id" ] && printf '%s' "$id"
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
#
# #240: matches EVERY worktree whose issue (per _wt_issue_of) is <N> -- the
# developer worktree AND any harness (agent-*) worktree QA/reviewer/security/
# docs tagged to <N> -- not just the fix|feat/issue-<N>-... pattern.
_wt_remove_body() {
  n="${1:-}"
  removed=0
  while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    _wt_is_main_worktree "$wt_path" && continue
    wt_id="$(_wt_issue_of "$wt_path")"
    [ "$wt_id" = "$n" ] || continue
    wt_branch="$(git -C "$wt_path" symbolic-ref -q --short HEAD 2>/dev/null)"
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
    [ -n "$wt_branch" ] && git branch -D "$wt_branch" 2>/dev/null
    removed=$((removed + 1))
    echo "pipeline-worktree: removed worktree for issue #$n ($wt_path, $wt_branch)"
  done < <(_wt_all_worktrees)
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
  # #240: the ONLY thing that preserves a worktree here is being identified
  # (_wt_issue_of: developer pattern, then tag file) with an id in the keep
  # list -- i.e. an issue the orchestrator says is still open (still in the
  # run's queue, or the id of an issue with an open PR, per SKILL.md Step 5).
  # Dirty working trees and unpushed commits no longer preserve a worktree on
  # their own: real work lives on a pushed PR branch, and this is a repo-wide
  # sweep, not a per-issue `remove` -- scratch left behind by a QA/reviewer/
  # security/docs harness worktree (agent-*, never tagged, or tagged to an
  # issue whose PR already closed) is garbage, not work in progress.
  # `remove <N>` (above) is unaffected and still honors _preserve_reason for
  # the one issue it targets.
  local removed=0 kept=0 freed_kb=0 wt_id wt_kb is_open
  while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    _wt_is_main_worktree "$wt_path" && continue
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
      echo "pipeline-worktree: reclaimed prunable worktree ($wt_path)"
      removed=$((removed + 1))
      continue
    fi
    wt_id="$(_wt_issue_of "$wt_path")"
    is_open=false
    if [ -n "$wt_id" ]; then
      case "$keep" in *" $wt_id "*) is_open=true ;; esac
    fi
    if [ "$is_open" = true ]; then
      echo "pipeline-worktree: keeping worktree for issue #$wt_id ($wt_path) — open"
      kept=$((kept + 1))
      continue
    fi
    wt_kb="$(_wt_dir_size_kb "$wt_path")"
    git worktree remove --force "$wt_path" 2>/dev/null || true
    freed_kb=$((freed_kb + wt_kb))
    removed=$((removed + 1))
    if [ -n "$wt_id" ]; then
      echo "pipeline-worktree: swept worktree for issue #$wt_id ($wt_path)"
    else
      echo "pipeline-worktree: swept unidentified worktree ($wt_path)"
    fi
  done < <(_wt_all_worktrees)

  _wt_sweep_branches "$keep"

  git worktree prune 2>/dev/null || true
  echo "talos:worktree-sweep removed=$removed kept=$kept freed=$(_wt_format_kb "$freed_kb")"
  exit 0
}

# Delete stale local branches: every ref under refs/heads/ that is NOT
# main/master/the configured base branch, does NOT track a still-existing
# remote branch, and is NOT the head of a currently open PR. `pipeline-vcs.sh
# list-prs` is queried exactly once for the open-PR head-branch set (not per
# branch) via _wt_open_pr_heads. A branch still checked out by a worktree
# `sweep` decided to keep is naturally protected too -- `git branch -D`
# refuses to delete a checked-out branch regardless of these checks.
#
# Fails SAFE: if the open-PR lookup itself fails, an unknown open-PR set must
# never be treated as an empty one (that would delete a live PR's branch), so
# branch cleanup is skipped entirely for this sweep rather than guessed.
_wt_sweep_branches() {
  local base_branch open_heads rc=0 br
  base_branch="$(_wt_configured_base_branch)"
  open_heads="$(_wt_open_pr_heads)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "pipeline-worktree: sweep: could not list open PRs -- skipping stale local-branch cleanup"
    return 0
  fi
  open_heads=" $(printf '%s' "$open_heads" | tr '\n' ' ') "
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    case "$br" in main|master) continue ;; esac
    [ -n "$base_branch" ] && [ "$br" = "$base_branch" ] && continue
    git show-ref --verify --quiet "refs/remotes/origin/$br" && continue
    case "$open_heads" in *" $br "*) continue ;; esac
    git branch -D "$br" >/dev/null 2>&1 \
      && echo "pipeline-worktree: deleted stale local branch $br"
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
}

# The repo's `base_branch` config, falling back to the resolved default
# branch (stripped of its "origin/" prefix) when unconfigured.
_wt_configured_base_branch() {
  local b
  b="$(cfg base_branch '' 2>/dev/null)"
  if [ -z "$b" ]; then
    b="$(_default_branch_ref 2>/dev/null)"
    b="${b#origin/}"
  fi
  printf '%s' "$b"
}

# Print one headRefName per line for every currently open PR (queried once
# via `pipeline-vcs.sh list-prs`), or return non-zero if that call fails --
# callers must treat a non-zero return as "unknown", never as "no open PRs".
_wt_open_pr_heads() {
  local raw
  raw="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" list-prs 2>/dev/null)" || return 1
  [ -z "$raw" ] && return 0
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for i in items:
    ref = (i or {}).get("headRefName")
    if ref:
        print(ref)
' 2>/dev/null
}

# KB used on disk by path $1 (0 if it does not exist or du is unavailable) --
# used to compute sweep's "freed=" summary. `du -sk` is available on both
# GNU and BSD du, unlike `du -sh`'s unit-suffixed, unsummable output.
_wt_dir_size_kb() {
  local kb
  kb="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"
  printf '%d' "${kb:-0}"
}

# Human-readable size for a KB count (e.g. "512K", "3.4M", "1.2G").
_wt_format_kb() {
  python3 -c "
kb = $1
units = ['K', 'M', 'G', 'T']
f = float(kb)
i = 0
while f >= 1024 and i < len(units) - 1:
    f /= 1024
    i += 1
print(f'{int(f)}{units[i]}' if f == int(f) else f'{f:.1f}{units[i]}')
"
}

# _wt_tag_body <issue-number> -- the actual work of `tag` (#240), run under
# the same lock as remove/sweep/create for consistency (it only touches this
# worktree's own .talos/env, so it can't race their git-common-dir mutations,
# but a mutating verb should not be the one exception to #180's lock rule).
#
# Refuses to run in the MAIN worktree: tagging it would make the
# orchestrator's own checkout indistinguishable from a disposable issue
# worktree to `remove`/`sweep`, which would then delete it out from under
# the running session.
_wt_tag_body() {
  local n="${1:-}" toplevel
  case "$n" in
    ''|*[!0-9]*)
      echo "usage: pipeline-worktree.sh tag <issue-number>" >&2
      exit 2
      ;;
  esac
  if _wt_is_main_worktree "."; then
    echo "pipeline-worktree: tag: refusing to tag the main worktree -- this would make the orchestrator's own checkout look like a disposable issue worktree to remove/sweep" >&2
    exit 1
  fi
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "pipeline-worktree: tag: not inside a git worktree" >&2
    exit 1
  }
  mkdir -p "$toplevel/.talos"
  # Same plain KEY=value format as `create` writes (#186) -- parsed by the
  # reader, never `source`d. Overwriting on every call is what makes this
  # idempotent.
  {
    printf 'TALOS_ISSUE_NUMBER=%s\n' "$n"
    printf 'TALOS_WORKTREE_PATH=%s\n' "$toplevel"
  } > "$toplevel/.talos/env"
  echo "pipeline-worktree: tagged $toplevel for issue #$n"
  exit 0
}

# _wt_status_body -- counts of worktrees/dirty-worktrees/local-branches, plus
# the total on-disk size of the main worktree's .claude/worktrees directory.
# Read-only; does not need the #180 lock.
_wt_status_body() {
  local total=0 dirty=0 branches main_path size_kb=0
  while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    _wt_is_main_worktree "$wt_path" && continue
    total=$((total + 1))
    if [ -d "$wt_path" ] && [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
      dirty=$((dirty + 1))
    fi
  done < <(_wt_all_worktrees)
  branches="$(git for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null | wc -l | tr -d ' ')"
  main_path="$(_wt_main_worktree_path_for '.')"
  if [ -n "$main_path" ] && [ -d "$main_path/.claude/worktrees" ]; then
    size_kb="$(_wt_dir_size_kb "$main_path/.claude/worktrees")"
  fi
  echo "pipeline-worktree: status worktrees=$total dirty=$dirty branches=$branches size=$(_wt_format_kb "$size_kb")"
  exit 0
}

# _wt_create_body <issue-number> <branch> -- create a worktree for issue
# <n> off the repo's default branch, on a new local <branch>, and write its
# per-worktree .talos/env (#186). Run under the worktree lock (dispatched via
# with_lock below) since `git worktree add` mutates the same shared
# git-common-dir metadata that `remove`/`sweep` race on (#180).
_wt_create_body() {
  local n="$1" branch="$2" base slug wt_path
  base="$(_default_branch_ref)" || {
    echo "pipeline-worktree: create: could not resolve a default branch (no origin/HEAD, no local main/master)" >&2
    exit 1
  }
  slug="$(printf '%s' "$branch" | tr '/' '-')"
  wt_path="$PWD/.claude/worktrees/$slug"
  if [ -e "$wt_path" ]; then
    echo "pipeline-worktree: create: $wt_path already exists" >&2
    exit 1
  fi
  git fetch origin "${base#origin/}" -q 2>/dev/null || true
  if ! git worktree add -q -b "$branch" "$wt_path" "$base"; then
    echo "pipeline-worktree: create: git worktree add failed for branch $branch off $base" >&2
    exit 1
  fi
  mkdir -p "$wt_path/.talos"
  # Plain KEY=value lines, raw value, no shell quoting. This file is PARSED
  # by pipeline-verify.sh's reader, never `source`d, so it is safe even when
  # $wt_path contains spaces or shell metacharacters -- see the format note
  # in that script's header comment. Keep both scripts' notion of this
  # format in sync if it ever changes.
  {
    printf 'TALOS_ISSUE_NUMBER=%s\n' "$n"
    printf 'TALOS_WORKTREE_PATH=%s\n' "$wt_path"
  } > "$wt_path/.talos/env"
  printf '%s\n' "$wt_path"
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

  create)
    if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
      echo "usage: pipeline-worktree.sh create <issue-number> <branch>" >&2
      exit 2
    fi
    with_lock "$_WT_LOCK_RESOURCE" 10 -- _wt_create_body "$1" "$2"
    ;;

  tag)
    if [ -z "${1:-}" ]; then
      echo "usage: pipeline-worktree.sh tag <issue-number>" >&2
      exit 2
    fi
    with_lock "$_WT_LOCK_RESOURCE" 10 -- _wt_tag_body "$1"
    ;;

  status)
    _wt_status_body
    ;;

  *)
    echo "usage: pipeline-worktree.sh <remove <n> | sweep [<open-id>...] | list | create <n> <branch> | tag <n> | status>" >&2
    exit 2
    ;;
esac
