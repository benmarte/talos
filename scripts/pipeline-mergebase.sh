#!/usr/bin/env bash
# pipeline-mergebase.sh -- mechanical union merge for a CONFLICTING PR whose
# only conflicting paths are "safe to blindly union" (default: CHANGELOG.md).
#
# Lean mandate (#256): a PR conflicting only because two PRs each added a
# bullet under CHANGELOG.md's `## [Unreleased]` is a git operation, not a
# reasoning task -- it does not need a developer subagent dispatch. This
# script is the mechanical fallback the Step 3c mergeability gate reaches
# for BEFORE dispatching a developer merge-base task: `conflict-files`
# (pipeline-vcs.sh) lists what conflicts; if every path matches
# merge.union_paths, this script resolves and pushes; anything else exits 3
# and the caller falls back to the developer task as before.
#
# Usage: pipeline-mergebase.sh <PR> [--union-paths <glob,glob,...>]
#
# Exit codes:
#   0  resolved and pushed -- caller should re-check pr-mergeable.
#   1  setup/config/git error (bad PR, fetch/push failure, invalid config,
#      or a union resolution that unexpectedly still has conflict markers).
#      Nothing pushed.
#   3  at least one conflicting path does NOT match merge.union_paths --
#      not mechanically resolvable. Nothing pushed. Caller dispatches the
#      developer merge-base task.
#
# Isolation: the merge attempt runs in a throwaway DETACHED worktree created
# under ${TMPDIR:-/tmp}, never in the caller's own checkout -- no branch of
# the caller's checkout is touched, and no branch name collides with a
# developer worktree that may still hold the PR branch checked out
# elsewhere (see checkout-pr's identical rationale in pipeline-vcs.sh). The
# resolved commit is pushed straight to the PR's remote branch with
# `git push origin HEAD:refs/heads/<branch>` from the detached worktree --
# no local branch named <branch> is ever created, so this never collides
# with a checked-out developer worktree. Removed on every exit path (trap).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "pipeline-mergebase: config cache helper missing, falling back to per-call parsing" >&2
fi

if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 2; [ "${1:-}" = "--" ] && shift; "$@"; }
  echo "pipeline-mergebase: lock helper missing, worktree operations are unsynchronized" >&2
fi

# ── Args ─────────────────────────────────────────────────────────────────────
PR_N="${1:-}"
shift || true
UNION_PATHS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --union-paths)
      UNION_PATHS_OVERRIDE="${2:-}"
      shift 2
      ;;
    *)
      echo "pipeline-mergebase: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PR_N" ]; then
  echo "usage: pipeline-mergebase.sh <PR> [--union-paths <glob,glob,...>]" >&2
  exit 1
fi
case "$PR_N" in
  ''|*[!0-9]*)
    echo "pipeline-mergebase: PR number must be an integer, got '$PR_N'" >&2
    exit 1
    ;;
esac

# ── Resolve union paths (#256) ───────────────────────────────────────────────
# Same shape as merge.approval_waiver_paths: JSON array from config, comma-
# separated CLI override takes precedence, default ["CHANGELOG.md"]. Every
# entry is validated against two disjoint deny sets BEFORE it is used -- a
# union merge blindly concatenates both sides of a conflict, which is a safe
# operation for an additive changelog but would silently corrupt a source
# file or push forbidden-shaped content unreviewed:
#   1. A hard-coded non-unionable set (scripts/**, tests/**, pipeline config
#      filenames) -- structural, can never be widened by ANY config. Exit 1
#      (setup/config error) when violated.
#   2. merge.forbidden_files (+ its _allow/_replace modifiers), fetched via
#      pipeline-vcs.sh's forbidden-files-patterns verb (#262 security-review
#      follow-up) rather than hand-duplicating the built-in default list --
#      the same deny list check-pr-files enforces before a merge to base.
#      This one is operator-configurable in principle, so a violation exits
#      3 (not mechanically resolvable this time), same code as any other
#      conflicting path merge.union_paths doesn't cover -- not exit 1, since
#      nothing about the SCRIPT's own config is structurally broken.
_MB_UNION_JSON="$(cfg merge.union_paths "" 2>/dev/null)"
_MB_UNION_PATHS_RAW="$UNION_PATHS_OVERRIDE"
if [ -z "$_MB_UNION_PATHS_RAW" ] && [ -n "$_MB_UNION_JSON" ]; then
  _MB_UNION_PATHS_RAW="$_MB_UNION_JSON"
fi

_MB_FORBIDDEN_PATTERNS="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" forbidden-files-patterns 2>/dev/null)"
if [ -z "$_MB_FORBIDDEN_PATTERNS" ]; then
  echo "pipeline-mergebase: could not resolve the effective merge.forbidden_files patterns" >&2
  exit 1
fi

_MB_UNION_PATHS="$(FORBIDDEN_PATTERNS="$_MB_FORBIDDEN_PATTERNS" python3 -c "
import fnmatch, json, os, sys

HARDCODED_NONUNIONABLE_PREFIXES = ('scripts/', 'tests/')
HARDCODED_NONUNIONABLE_EXACT = (
    'talos.pipeline.yml', 'talos.pipeline.yaml', 'talos.pipeline.json',
    '.claude-pipeline.yaml', '.claude-pipeline.json',
    'pipeline.yaml', 'pipeline.json',
)
VALIDATION_CANARIES = [
    'scripts/core.sh', 'scripts/pipeline-vcs.sh', 'sub/dir/scripts/x.sh',
    'tests/test-vcs.sh', 'tests/run-tests.sh', 'sub/dir/tests/y.sh',
    'talos.pipeline.yml', 'talos.pipeline.yaml', 'talos.pipeline.json',
    '.claude-pipeline.yaml', '.claude-pipeline.json',
    'pipeline.yaml', 'pipeline.json',
]

def is_hardcoded_nonunionable(path):
    for prefix in HARDCODED_NONUNIONABLE_PREFIXES:
        if path == prefix.rstrip('/') or path.startswith(prefix):
            return True
    return path in HARDCODED_NONUNIONABLE_EXACT

def pat_to_literal(pat):
    # Same canary technique check-pr-files's forbidden_files_allow validator
    # uses: turn a glob pattern into the plain literal filename it was
    # written to match, so it can be re-checked with fnmatch as a concrete
    # path -- bracket expressions then remaining glob chars become 'x'.
    import re
    s = re.sub(r'\\[[^\\]]*\\]', 'x', pat)
    return s.replace('*', 'x').replace('?', 'x')

forbidden_patterns = [p.strip() for p in os.environ.get('FORBIDDEN_PATTERNS', '').splitlines() if p.strip()]
forbidden_canaries = []  # three forms per pattern, same shape as check-pr-files
for pat in forbidden_patterns:
    lit = pat if not any(c in pat for c in '*?[]') else pat_to_literal(pat)
    if not lit:
        continue
    forbidden_canaries.append(lit)
    forbidden_canaries.append('sub/dir/' + lit)
    forbidden_canaries.append('config/' + lit)

def matches_forbidden(entry):
    # No exact-literal-override exception here (unlike forbidden_files_allow)
    # -- widening union_paths onto forbidden-shaped content is never a
    # legitimate operator override; it is always rejected.
    for canary in forbidden_canaries:
        base = canary.rsplit('/', 1)[-1]
        if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
            return canary
    return None

raw = sys.argv[1].strip()
if raw:
    try:
        parsed = json.loads(raw)
        if not isinstance(parsed, list):
            raise ValueError('not a list')
        entries = [str(e).strip() for e in parsed if str(e).strip()]
    except Exception:
        # comma-separated CLI override, or a newline-delimited YAML scalar
        sep = ',' if ',' in raw else '\n'
        entries = [e.strip() for e in raw.split(sep) if e.strip()]
else:
    entries = ['CHANGELOG.md']

hardcoded_errors = []
forbidden_errors = []
for entry in entries:
    if is_hardcoded_nonunionable(entry):
        hardcoded_errors.append(f\"merge.union_paths entry '{entry}' is a hard-coded non-unionable path\")
        continue
    canary_hit = None
    for canary in VALIDATION_CANARIES:
        base = canary.rsplit('/', 1)[-1]
        if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
            canary_hit = canary
            break
    if canary_hit:
        hardcoded_errors.append(f\"merge.union_paths entry '{entry}' would union '{canary_hit}' -- rejected (catch-all or covers non-unionable paths)\")
        continue
    forbidden_hit = matches_forbidden(entry)
    if forbidden_hit:
        forbidden_errors.append(f\"merge.union_paths entry '{entry}' would union forbidden-files-shaped content ('{forbidden_hit}' matches merge.forbidden_files) -- rejected\")

if hardcoded_errors or forbidden_errors:
    for e in hardcoded_errors + forbidden_errors:
        print('pipeline-mergebase: ERROR: ' + e, file=sys.stderr)
    sys.exit(1 if hardcoded_errors else 3)

print(json.dumps(entries))
" "$_MB_UNION_PATHS_RAW")"
_MB_UNION_RC=$?
if [ "$_MB_UNION_RC" -ne 0 ]; then
  exit "$_MB_UNION_RC"
fi

# ── Resolve base branch (same fallback chain as assert-sync) ────────────────
BASE_BRANCH="$(cfg base_branch "" 2>/dev/null)"
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
fi
[ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"

# ── Resolve the PR's head branch name ───────────────────────────────────────
# view-pr is provider-agnostic across github/github-api and returns
# headRefName in both shapes.
_MB_VIEW_JSON="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" view-pr "$PR_N" 2>/dev/null)"
if [ -z "$_MB_VIEW_JSON" ]; then
  echo "pipeline-mergebase: could not fetch PR #$PR_N" >&2
  exit 1
fi
HEAD_REF="$(printf '%s' "$_MB_VIEW_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('headRefName', ''))
except Exception:
    print('')
" 2>/dev/null)"
if [ -z "$HEAD_REF" ]; then
  echo "pipeline-mergebase: could not resolve head branch for PR #$PR_N" >&2
  exit 1
fi

# ── Fetch both refs into THIS repo's remote-tracking refs ───────────────────
# A fetch never touches the working tree or HEAD -- safe from any checkout.
if ! git fetch -q origin "$HEAD_REF" "$BASE_BRANCH" 2>/dev/null; then
  echo "pipeline-mergebase: git fetch origin $HEAD_REF $BASE_BRANCH failed" >&2
  exit 1
fi
if ! git rev-parse -q --verify "origin/$HEAD_REF" >/dev/null 2>&1; then
  echo "pipeline-mergebase: origin/$HEAD_REF does not resolve after fetch" >&2
  exit 1
fi
if ! git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  echo "pipeline-mergebase: origin/$BASE_BRANCH does not resolve after fetch" >&2
  exit 1
fi

# ── Disposable worktree (#256): created OUTSIDE any repo checkout, removed
# on every exit path via trap -- this is a standalone process (not a
# sourced function inside another script), so an EXIT trap is the right
# cleanup primitive here (contrast pipeline-vcs.sh's
# _vcs_shared_conflict_files, which falls through to a single explicit
# cleanup call instead, since it runs inside the caller's own process).
# Both `git worktree add` and the cleanup `git worktree remove` are
# serialized with `with_lock` on the same resource key pipeline-worktree.sh's
# create/remove/sweep use (#180/#262 review follow-up) -- they mutate the
# same shared git-common-dir metadata a concurrent stage may be touching.
_MB_LOCK_RESOURCE="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"
_MB_TMPDIR=""
_mb_cleanup() {
  [ -n "$_MB_TMPDIR" ] || return 0
  with_lock "$_MB_LOCK_RESOURCE" 10 -- git worktree remove --force "$_MB_TMPDIR" >/dev/null 2>&1
  rm -rf "$_MB_TMPDIR" 2>/dev/null
}
trap _mb_cleanup EXIT INT TERM

_MB_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-mergebase.XXXXXX" 2>/dev/null)"
if [ -z "$_MB_TMPDIR" ]; then
  echo "pipeline-mergebase: mktemp failed" >&2
  exit 1
fi

if ! with_lock "$_MB_LOCK_RESOURCE" 10 -- \
    git worktree add -q --detach "$_MB_TMPDIR" "origin/$HEAD_REF" >/dev/null 2>&1; then
  echo "pipeline-mergebase: could not create temp worktree for origin/$HEAD_REF" >&2
  exit 1
fi

git -C "$_MB_TMPDIR" -c user.email=talos@local -c user.name=talos-mergebase \
  merge --no-commit --no-ff "origin/$BASE_BRANCH" >/dev/null 2>&1
_MB_MERGE_RC=$?

if [ "$_MB_MERGE_RC" -gt 1 ]; then
  echo "pipeline-mergebase: merge attempt exited $_MB_MERGE_RC (unrelated histories or other error)" >&2
  exit 1
fi

if [ "$_MB_MERGE_RC" -eq 1 ]; then
  _MB_CONFLICTS="$(git -C "$_MB_TMPDIR" diff --name-only --diff-filter=U 2>/dev/null)"

  # Every conflicting path must (a) match a union glob AND (b) NOT match a
  # merge.forbidden_files pattern -- belt and braces (#262 security-review
  # follow-up): a path that matches a forbidden pattern is refused even if
  # merge.union_paths would otherwise have allowed it, so a gap in the
  # validation-time cross-check above (or a config change between
  # validation and this point) can never let forbidden-shaped content
  # actually get union-merged. Caps the loop at the actual conflict count
  # (no unbounded input; comes straight from git).
  _MB_NONUNION="$(CONFLICTS="$_MB_CONFLICTS" UNION_JSON="$_MB_UNION_PATHS" FORBIDDEN_PATTERNS="$_MB_FORBIDDEN_PATTERNS" python3 -c "
import fnmatch, json, os
conflicts = [c for c in os.environ.get('CONFLICTS', '').splitlines() if c.strip()]
patterns = json.loads(os.environ.get('UNION_JSON', '[]'))
forbidden = [p.strip() for p in os.environ.get('FORBIDDEN_PATTERNS', '').splitlines() if p.strip()]
def matches_any(path, pats):
    base = path.rsplit('/', 1)[-1]
    return any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in pats)
for c in conflicts:
    if not matches_any(c, patterns):
        print(c)
    elif matches_any(c, forbidden):
        print(c)
")"
  if [ -n "$_MB_NONUNION" ]; then
    echo "pipeline-mergebase: conflicting path(s) not covered by merge.union_paths (or blocked by merge.forbidden_files), not mechanically resolvable:" >&2
    printf '%s\n' "$_MB_NONUNION" >&2
    exit 3
  fi

  # Resolve each conflicting path with `git merge-file --union` -- ours (the
  # PR branch, since the worktree is checked out at origin/$HEAD_REF) first,
  # so the union keeps the PR's own entry ahead of the base's.
  _MB_RESOLVE_TMP="$(mktemp -d)"
  while IFS= read -r _mb_path; do
    [ -z "$_mb_path" ] && continue
    git -C "$_MB_TMPDIR" show ":1:$_mb_path" > "$_MB_RESOLVE_TMP/base" 2>/dev/null || : > "$_MB_RESOLVE_TMP/base"
    git -C "$_MB_TMPDIR" show ":2:$_mb_path" > "$_MB_RESOLVE_TMP/ours" 2>/dev/null || : > "$_MB_RESOLVE_TMP/ours"
    git -C "$_MB_TMPDIR" show ":3:$_mb_path" > "$_MB_RESOLVE_TMP/theirs" 2>/dev/null || : > "$_MB_RESOLVE_TMP/theirs"
    if ! git merge-file --union -p "$_MB_RESOLVE_TMP/ours" "$_MB_RESOLVE_TMP/base" "$_MB_RESOLVE_TMP/theirs" \
        > "$_MB_TMPDIR/$_mb_path" 2>/dev/null; then
      echo "pipeline-mergebase: git merge-file --union failed for $_mb_path" >&2
      rm -rf "$_MB_RESOLVE_TMP"
      exit 1
    fi
    if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$_MB_TMPDIR/$_mb_path" 2>/dev/null; then
      echo "pipeline-mergebase: $_mb_path still has conflict markers after union resolution -- aborting" >&2
      rm -rf "$_MB_RESOLVE_TMP"
      exit 1
    fi
    git -C "$_MB_TMPDIR" add -- "$_mb_path"
  done <<< "$_MB_CONFLICTS"
  rm -rf "$_MB_RESOLVE_TMP"
fi

# Nothing left unmerged -- either the merge was clean (rc 0) or every
# conflicting path was resolved and staged above.
if [ -n "$(git -C "$_MB_TMPDIR" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
  echo "pipeline-mergebase: unresolved conflicts remain after union resolution -- aborting" >&2
  exit 1
fi

_MB_MSG_PATHS="$(printf '%s' "$_MB_UNION_PATHS" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin)))")"
if ! git -C "$_MB_TMPDIR" -c user.email=talos@local -c user.name=talos-mergebase \
    commit -q -m "chore: merge $BASE_BRANCH into $HEAD_REF (mechanical union: $_MB_MSG_PATHS)"; then
  echo "pipeline-mergebase: commit failed" >&2
  exit 1
fi

if ! git -C "$_MB_TMPDIR" push -q origin "HEAD:refs/heads/$HEAD_REF"; then
  echo "pipeline-mergebase: push to $HEAD_REF failed" >&2
  exit 1
fi

echo "pipeline-mergebase: merged $BASE_BRANCH into $HEAD_REF (mechanical union: $_MB_MSG_PATHS) and pushed"
exit 0
