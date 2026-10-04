#!/usr/bin/env bash
# pipeline-changelog.sh -- assemble CHANGELOG.md from per-issue fragment files
# (roles.changelog_fragments, #290, part of #287).
#
# When `roles.changelog_fragments: true`, the docs stage writes ONE fragment
# per issue under docs/CHANGELOG.d/<issue>.md instead of editing
# CHANGELOG.md, so parallel PRs never touch the same file and CHANGELOG
# merge conflicts between concurrent pipeline PRs disappear structurally.
# The fragments are folded into CHANGELOG.md's `## [Unreleased]` section ON
# THE BASE BRANCH -- not on a PR branch -- by this script's `assemble` verb,
# which the orchestrator runs after each merge that consumed fragments.
#
# Usage: pipeline-changelog.sh assemble
#
# Behavior:
#   1. Reads docs/CHANGELOG.d/*.md from origin/<base_branch>. No fragments
#      (or no CHANGELOG.md on the base) -> exit 0, "nothing to assemble".
#   2. In a throwaway DETACHED worktree off origin/<base_branch> (same
#      isolation shape as pipeline-mergebase.sh -- the caller's own checkout
#      is never touched), inserts every fragment's body, newest fragment
#      first (highest issue number first), right under the `## [Unreleased]`
#      heading, and deletes the consumed fragment files in the same commit.
#   3. Pushes the result to origin/<base_branch>. Failure is NON-FATAL by
#      design: fragments remain on the base and the next assemble retries.
#
# Exit codes:
#   0  assembled and pushed, or nothing to do.
#   1  setup/config/git error (no CHANGELOG.md heading, push/fetch failure,
#      or an unresolvable base branch). Nothing pushed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  # cfg() (#169): config lookups from a per-invocation cache.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  # with_lock (#180): serialize git worktree mutations across stages.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 3 2>/dev/null; "$@"; }  # unlocked fallback
fi

verb="${1:-}"
case "$verb" in
  assemble) ;;
  *)
    echo "usage: pipeline-changelog.sh assemble" >&2
    exit 1
    ;;
esac

# ── Base branch (same fallback chain as pipeline-mergebase.sh) ───────────────
BASE_BRANCH="$(cfg base_branch 2>/dev/null)"
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
fi
[ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"

# The value comes from config and reaches git as an argument (#457): a name
# starting with `-` would be read as an option (`--upload-pack=...` runs a
# command during fetch). Same plain-ref rule as pipeline-status-file.sh:
# starts with an alphanumeric, then letters, digits and . _ / - only; no `..`,
# `//`, trailing `/` or `.lock`. Checked before any git call.
case "$BASE_BRANCH" in
  [!A-Za-z0-9]*|*[!A-Za-z0-9._/-]*|*..*|*//*|*/|*.lock)
    echo "pipeline-changelog: base branch is not an accepted branch name: $BASE_BRANCH" >&2
    exit 1
    ;;
esac
if ! git check-ref-format "refs/heads/$BASE_BRANCH" 2>/dev/null; then
  echo "pipeline-changelog: base branch is not a valid branch name: $BASE_BRANCH" >&2
  exit 1
fi

if ! git fetch -q -- origin "$BASE_BRANCH" 2>/dev/null; then
  echo "pipeline-changelog: git fetch origin $BASE_BRANCH failed" >&2
  exit 1
fi
if ! git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  echo "pipeline-changelog: origin/$BASE_BRANCH does not resolve after fetch" >&2
  exit 1
fi

# ── Read fragments from origin/<base> WITHOUT any worktree: git ls-tree is a
#    read-only object lookup, safe from any checkout. ──────────────────────────
# A fragment that is a symlink (mode 120000) or any other non-regular entry is
# never read: the checkout would follow it to a file outside the repo. It is
# skipped with one stderr line and left in place.
LISTING="$(git ls-tree "origin/$BASE_BRANCH:docs/CHANGELOG.d" 2>/dev/null || true)"
FRAGMENTS=""
while IFS=$'\t' read -r _cl_meta _cl_name; do
  [ -n "$_cl_name" ] || continue
  case "$_cl_meta" in
    "100644 blob "*|"100755 blob "*) FRAGMENTS="${FRAGMENTS}${_cl_name}"$'\n' ;;
    *)
      if grep -qE '^[0-9]+\.md$' <<< "$_cl_name"; then
        echo "pipeline-changelog: docs/CHANGELOG.d/$_cl_name is not a regular file (mode ${_cl_meta%% *}); skipped" >&2
      fi
      ;;
  esac
done <<< "$LISTING"
if [ -z "$FRAGMENTS" ]; then
  echo "pipeline-changelog: no fragments under docs/CHANGELOG.d on origin/$BASE_BRANCH — nothing to assemble"
  exit 0
fi
# Fragment names must be <digits>.md (one per issue, docs-stage convention).
# Anything else is not a fragment and is left alone.
FRAGMENT_FILES="$(printf '%s\n' "$FRAGMENTS" | grep -E '^[0-9]+\.md$' | sort -t. -k1 -n -r || true)"
if [ -z "$FRAGMENT_FILES" ]; then
  echo "pipeline-changelog: no <issue>.md fragments under docs/CHANGELOG.d on origin/$BASE_BRANCH — nothing to assemble"
  exit 0
fi

# CHANGELOG.md must exist, as a regular file (a symlink would be read and
# rewritten through), with the [Unreleased] heading.
if ! git cat-file -e "origin/$BASE_BRANCH:CHANGELOG.md" 2>/dev/null; then
  echo "pipeline-changelog: CHANGELOG.md missing on origin/$BASE_BRANCH" >&2
  exit 1
fi
case "$(git ls-tree "origin/$BASE_BRANCH" -- CHANGELOG.md 2>/dev/null)" in
  "100644 blob "*|"100755 blob "*) ;;
  *)
    echo "pipeline-changelog: CHANGELOG.md on origin/$BASE_BRANCH is not a regular file (a symlink?); refusing" >&2
    exit 1
    ;;
esac

# ── Disposable worktree (same shape as pipeline-mergebase.sh #256): created
# OUTSIDE any repo checkout, removed on every exit path via trap, and both
# `git worktree add` and the cleanup `git worktree remove` are serialized with
# with_lock on the same resource key pipeline-worktree.sh's create/remove/sweep
# use (#180/#262). ─────────────────────────────────────────────────────────────
_CL_LOCK_RESOURCE="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"
_CL_TMPDIR=""
_cl_cleanup() {
  [ -n "$_CL_TMPDIR" ] || return 0
  with_lock "$_CL_LOCK_RESOURCE" 10 -- git worktree remove --force "$_CL_TMPDIR" >/dev/null 2>&1
  rm -rf "$_CL_TMPDIR" 2>/dev/null
}
trap _cl_cleanup EXIT INT TERM

_CL_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-changelog.XXXXXX" 2>/dev/null)"
if [ -z "$_CL_TMPDIR" ]; then
  echo "pipeline-changelog: mktemp failed" >&2
  exit 1
fi

if ! with_lock "$_CL_LOCK_RESOURCE" 10 -- \
    git worktree add -q --detach "$_CL_TMPDIR" "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  echo "pipeline-changelog: could not create temp worktree for origin/$BASE_BRANCH" >&2
  exit 1
fi

# ── Assemble: insert fragments under [Unreleased], newest first ──────────────
python3 -I - "$_CL_TMPDIR" "$FRAGMENT_FILES" <<'EOF'
import os, sys

wt = sys.argv[1]
fragment_files = sys.argv[2].splitlines()

changelog_path = os.path.join(wt, 'CHANGELOG.md')
with open(changelog_path) as f:
    lines = f.read().splitlines(keepends=False)

# Find the ## [Unreleased] heading.
marker = '## [Unreleased]'
try:
    idx = next(i for i, l in enumerate(lines) if l.strip() == marker)
except StopIteration:
    print('pipeline-changelog: no "## [Unreleased]" heading in CHANGELOG.md', file=sys.stderr)
    sys.exit(1)

# Fragment insertion point: directly under the heading, keeping one blank line
# between the heading and the first entry (insert fragments, then the blank
# line that separated the heading from the rest).
insert_at = idx + 1
while insert_at < len(lines) and lines[insert_at].strip() == '':
    insert_at += 1

# Newest fragment (highest issue number) first: FRAGMENT_FILES is already
# sorted descending. Each fragment becomes its own bullet block, separated
# from the next by one blank line.
blocks = []
for fname in fragment_files:
    fpath = os.path.join(wt, 'docs', 'CHANGELOG.d', fname)
    with open(fpath) as f:
        body = f.read().strip()
    if body:
        blocks.append(body)

if not blocks:
    print('pipeline-changelog: every fragment is empty — nothing to assemble')
    sys.exit(0)

new_lines = (
    lines[:insert_at]
    + ['\n'.join(blocks)]
    + lines[insert_at:]
)
with open(changelog_path, 'w') as f:
    f.write('\n'.join(new_lines))

# Delete the consumed fragments so the next assemble cannot double-insert.
for fname in fragment_files:
    fpath = os.path.join(wt, 'docs', 'CHANGELOG.d', fname)
    if os.path.exists(fpath):
        os.remove(fpath)

# Keep the (now possibly empty) directory tracked: git ignores empty dirs, so
# an empty docs/CHANGELOG.d simply vanishes from the tree -- correct.
print('assembled %d fragment(s)' % len(blocks))
EOF
_CL_RC=$?
if [ "$_CL_RC" -ne 0 ]; then
  # Non-fatal by design: fragments remain; the next assemble retries.
  echo "pipeline-changelog: assembly failed (rc=$_CL_RC) — fragments left in place" >&2
  exit "$_CL_RC"
fi

if git -C "$_CL_TMPDIR" diff --quiet && git -C "$_CL_TMPDIR" diff --cached --quiet 2>/dev/null; then
  echo "pipeline-changelog: nothing to assemble"
  exit 0
fi

if ! git -C "$_CL_TMPDIR" add -A CHANGELOG.md docs/CHANGELOG.d; then
  echo "pipeline-changelog: git add failed" >&2
  exit 1
fi

if ! git -C "$_CL_TMPDIR" -c user.email=talos@local -c user.name=talos-changelog \
    commit -q -m "docs: assemble CHANGELOG from fragments (docs/CHANGELOG.d)"; then
  echo "pipeline-changelog: commit failed" >&2
  exit 1
fi

if ! git -C "$_CL_TMPDIR" push -q origin "HEAD:refs/heads/$BASE_BRANCH"; then
  echo "pipeline-changelog: push to $BASE_BRANCH failed — fragments remain, next assemble retries" >&2
  exit 1
fi

echo "pipeline-changelog: assembled docs/CHANGELOG.d fragments into CHANGELOG.md on $BASE_BRANCH and pushed"
exit 0