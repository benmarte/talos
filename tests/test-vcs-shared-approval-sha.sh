#!/usr/bin/env bash
# test-vcs-shared-approval-sha.sh — direct unit tests for the approval-SHA
# waiver-rule helper shared by _github and _github_api (#177 slice 2):
#   _vcs_shared_check_approval_sha.
#
# These drive the shared function directly (not through either adapter's CLI
# verb) so a regression in the waiver logic itself is caught here even if
# both adapters happened to still agree by coincidence. Every test can fail:
# disabling/breaking the shared helper causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cfg() { bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$@"; }
_TALOS_CFG=""

# ── Load ONLY the shared-helper function definitions ──────────────────────────
# Never `source`/`.` the whole script: it has top-level arg-parsing/dispatch
# that ends in `exit`, which would terminate this test process. Extract the
# byte range from `_vcs_shared_read_attempt() {` up to (not including) the
# `_github() {` adapter that follows it -- pure function definitions, safe to
# eval into this shell. (Same anchors as test-vcs-shared-markers.sh; picks up
# every shared helper defined so far, including _vcs_shared_check_approval_sha.)
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
if [ -z "$_shared_src" ]; then
  fail "setup: extracted shared-helper source is non-empty" "extraction produced nothing -- check the awk anchors against pipeline-vcs.sh"
fi
eval "$_shared_src"
if ! declare -F _vcs_shared_check_approval_sha >/dev/null; then
  fail "setup: _vcs_shared_check_approval_sha loaded" "function not defined after eval"
fi

# ── Sandbox git setup ─────────────────────────────────────────────────────────
# make_sandbox already ran `git init` and configured user.name/email via
# $HOME/.gitconfig. Build a small commit graph that exercises every waiver
# path the shared function has to reason about.
git checkout -q -b main 2>/dev/null || git checkout -q main

# SHA_BASE — the merge-base / origin default branch tip.
printf 'initial\n' > feature.txt
git add feature.txt
git commit -q -m "initial commit"
SHA_BASE="$(git rev-parse HEAD)"
git branch -q -f origin_default HEAD  # stand-in for "origin/main" (no real remote in sandbox)
git update-ref refs/remotes/origin/main HEAD

# SHA_DOCS — docs-only delta off SHA_BASE (covered by DEFAULT_WAIVER's *.md).
printf 'readme update\n' > README.md
git add README.md
git commit -q -m "docs: update readme"
SHA_DOCS="$(git rev-parse HEAD)"

# SHA_SCRIPTS — scripts/ path changed off SHA_DOCS (hard-coded non-waivable).
mkdir -p scripts
printf '#!/bin/bash\n# stub\n' > scripts/fake.sh
git add scripts/fake.sh
git commit -q -m "scripts: add fake helper"
SHA_SCRIPTS="$(git rev-parse HEAD)"

# HEAD_SHA — current PR head, one more docs-only commit past SHA_SCRIPTS.
printf 'more readme\n' >> README.md
git add README.md
git commit -q -m "docs: more readme"
HEAD_SHA="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$SHA_BASE"

# SHA_BASE_ONLY_HEAD — a second PR head built so the delta between an old
# marker SHA and this head includes a file that arrived ONLY via a
# base-branch sync (absent from the PR's own three-dot diff against
# origin/main), proving #102's base-only filtering still holds post-refactor.
# origin/main advances to include an unrelated non-waivable file (simulating
# "someone merged a change to main while this PR was open"); the PR branch
# then merges that in without itself touching the file.
git update-ref refs/remotes/origin/main "$SHA_BASE"
git checkout -q -b sync-base "$SHA_BASE"
mkdir -p scripts
printf '#!/bin/bash\n# base-only\n' > scripts/base-only.sh
git add scripts/base-only.sh
git commit -q -m "scripts: base-only change"
SHA_SYNC_BASE="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$SHA_SYNC_BASE"

git checkout -q -b pr-branch "$SHA_DOCS"
git merge -q -m "merge base sync" "$SHA_SYNC_BASE"
SHA_BASE_ONLY_HEAD="$(git rev-parse HEAD)"

git checkout -q main

# ── Helpers ───────────────────────────────────────────────────────────────────

# entries_json <label> <role> <sha> — one-entry MARKER_ENTRIES payload with a
# current (non-stale-at-marker-extraction) marker, i.e. reason=null.
entries_json() {
  printf '{"entries":[{"label":"%s","role":"%s","sha":"%s","reason":null}]}' "$1" "$2" "$3"
}

# run_check <head_sha> <base_ref_name> <marker_entries_json> [stale_list] --
# call the shared function directly with a minimal normalised PR payload.
# (REPO_ROOT is left unset: every test below runs with $SANDBOX as cwd, which
# is exactly what an empty REPO_ROOT falls back to -- subprocess.run(cwd=None).)
run_check() {
  local head="$1" base="$2" entries="$3" stale_list="${4:-false}"
  printf '{"headRefOid":"%s","baseRefName":"%s"}' "$head" "$base" \
    | MARKER_ENTRIES="$entries" STALE_LIST="$stale_list" _vcs_shared_check_approval_sha
}

# ═══════════════════════════════════════════════════════════════════════════
# fresh approval: marker SHA == head SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$HEAD_SHA")"
out="$(run_check "$HEAD_SHA" "" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "fresh approval: exits 0"
assert_eq "check-approval-sha: all approval labels are current" "$out" "fresh approval: reports all current"

# ═══════════════════════════════════════════════════════════════════════════
# stale by non-waivable path: scripts/fake.sh changed since the marker SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$HEAD_SHA" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "stale by non-waivable path: exits 1"
assert_contains "$out" "STALE qa:pass (qa)" "stale by non-waivable path: names label and role"
assert_contains "$out" "non-waivable files changed since $SHA_DOCS" "stale by non-waivable path: cites the marker SHA"
assert_contains "$out" "scripts/fake.sh" "stale by non-waivable path: names the offending file"

# ═══════════════════════════════════════════════════════════════════════════
# waived by *.md: only README.md changed since the marker SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_BASE")"
out="$(run_check "$SHA_DOCS" "" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "waived by *.md: exits 0 (DEFAULT_WAIVER covers docs-only delta)"
assert_eq "check-approval-sha: all approval labels are current" "$out" "waived by *.md: reports all current"

# ═══════════════════════════════════════════════════════════════════════════
# base-only change filtered (#102): the marker SHA differs from head only by
# a file that arrived purely via a base-branch sync -- excluded from
# consideration once baseRefName lets the shared function compute the PR's
# own three-dot diff.
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$SHA_BASE_ONLY_HEAD" "main" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "base-only change filtered: exits 0 (#102 excludes base-sync-only files)"
assert_eq "check-approval-sha: all approval labels are current" "$out" "base-only change filtered: reports all current"

# Sanity: WITHOUT baseRefName (so the three-dot filter cannot run), the same
# delta is correctly flagged non-waivable -- proves the #102 filter (not a
# bug in the waiver rules) is what made the case above pass.
out="$(run_check "$SHA_BASE_ONLY_HEAD" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "base-only change filtered: without baseRefName, filter is skipped and the file is flagged"
assert_contains "$out" "scripts/base-only.sh" "base-only change filtered: names the file when the filter is skipped"

# ═══════════════════════════════════════════════════════════════════════════
# --stale-list output
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$HEAD_SHA" "" "$_entries" true 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "--stale-list: still exits 1"
assert_contains "$out" "stale role=qa label=qa:pass" "--stale-list: stdout carries the greppable stale line"

err_only="$(run_check "$HEAD_SHA" "" "$_entries" true 2>&1 1>/dev/null)"
assert_contains "$err_only" "STALE qa:pass (qa)" "--stale-list: stderr prose unchanged"

# Without the flag: no stdout stale-list line.
out_noflag="$(run_check "$HEAD_SHA" "" "$_entries" 2>/dev/null)"
assert_not_contains "$out_noflag" "stale role=" "no --stale-list: no stdout stale-list line"

finish
