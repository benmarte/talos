#!/usr/bin/env bash
# #862: check-approval-sha skips a file both the PR and the base touched when the
# only change to it since the marker came from merging the base (shared append
# points: tests/timings.txt, CHANGELOG.md). Fail closed when the patch comparison
# cannot run.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"
printf '{}' > cfg.json
export PIPELINE_CONFIG="$SANDBOX/cfg.json"

mkdir -p tests
printf 'a 1\nb 2\nc 3\nd 4\ne 5\n' > tests/timings.txt
git add tests/timings.txt
git commit -q -m base
BASE0="$(git rev-parse HEAD)"

# PR branch: adds its own line at the top of the shared file.
git checkout -q -b pr "$BASE0"
printf 'pr-own 9\na 1\nb 2\nc 3\nd 4\ne 5\n' > tests/timings.txt
git commit -q -am "pr: own timings line"
MARKER="$(git rev-parse HEAD)"

# Base advances: a sibling PR appends a line at the end of the same file.
git checkout -q -b basebr "$BASE0"
printf 'a 1\nb 2\nc 3\nd 4\ne 5\nsibling 7\n' > tests/timings.txt
git commit -q -am "sibling: timings line"
BASE1="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$BASE1"

# The PR merges the base: the only change since the marker.
git checkout -q pr
git merge -q --no-edit "$BASE1" >/dev/null 2>&1
MERGED="$(git rev-parse HEAD)"

mk_comment() { printf '[{"body":"ok\\n<!-- talos:approval sha=%s role=qa -->"}]' "$1"; }
check() { # <head> <marker>
  STUB_PR_HEAD_SHA="$1" STUB_PR_BASE_REF_NAME="main" \
  STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
  STUB_PR_COMMENTS_JSON="$(mk_comment "$2")" \
  PIPELINE_CONFIG="$PIPELINE_CONFIG" \
  bash "$VCS" check-approval-sha 9 2>&1
}

# AC1: only a base merge touched the shared file since the marker: fresh.
out="$(check "$MERGED" "$MARKER")"; rc=$?
assert_exit_code 0 "$rc" "AC1 base merge adding a line to a shared file keeps approval fresh"
assert_not_contains "$out" "STALE" "AC1 no STALE line"

# AC2: the PR changes its own line after the marker: stale, file named.
printf 'pr-own 10\na 1\nb 2\nc 3\nd 4\ne 5\nsibling 7\n' > tests/timings.txt
git commit -q -am "pr: edit own line"
EDITED="$(git rev-parse HEAD)"
out="$(check "$EDITED" "$MARKER")"; rc=$?
assert_exit_code 1 "$rc" "AC2 PR edit of its own line after the marker is stale"
assert_contains "$out" "tests/timings.txt" "AC2 stale names the file"

# AC3: the comparison cannot run: fail closed. A git wrapper fails one
# subcommand (TEST_GIT_FAIL=merge-base or merge-tree) and passes the rest.
mkdir -p "$SANDBOX/fakebin"
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\n' > "$SANDBOX/fakebin/git"
cat >> "$SANDBOX/fakebin/git" <<'TALOS_k3vQ8xZ2mPaR'
case "${TEST_GIT_FAIL:-}" in
  merge-base) [ "${1:-}" = "merge-base" ] && exit 1 ;;
  merge-tree) [ "${1:-}" = "merge-tree" ] && exit 1 ;;
esac
TALOS_k3vQ8xZ2mPaR
printf 'exec "%s" "$@"\n' "$REAL_GIT" >> "$SANDBOX/fakebin/git"
chmod +x "$SANDBOX/fakebin/git"

out="$(PATH="$SANDBOX/fakebin:$PATH" TEST_GIT_FAIL=merge-base check "$MERGED" "$MARKER")"; rc=$?
assert_exit_code 1 "$rc" "AC3 merge-base failure keeps the file changed: stale"
assert_contains "$out" "tests/timings.txt" "AC3 merge-base failure names the file"
out="$(PATH="$SANDBOX/fakebin:$PATH" TEST_GIT_FAIL=merge-tree check "$MERGED" "$MARKER")"; rc=$?
assert_exit_code 1 "$rc" "AC3 merge-tree failure keeps the file changed: stale"
assert_contains "$out" "tests/timings.txt" "AC3 merge-tree failure names the file"

# AC4: a base-only file is still dropped; a PR-only change after the marker is stale.
git checkout -q -b basefile "$BASE1"
printf 'x\n' > base_only.js
git add base_only.js
git commit -q -m "base only file"
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
git checkout -q -b pr2 "$BASE1"
printf 'own\n' > own.md
git add own.md
git commit -q -m "pr2 own"
M2="$(git rev-parse HEAD)"
git merge -q --no-edit basefile >/dev/null 2>&1
H2="$(git rev-parse HEAD)"
out="$(check "$H2" "$M2")"; rc=$?
assert_exit_code 0 "$rc" "AC4 base-only file is still dropped"
printf 'changed\n' > own_src.js
git add own_src.js
git commit -q -m "pr2 more"
out="$(check "$(git rev-parse HEAD)" "$M2")"; rc=$?
assert_exit_code 1 "$rc" "AC4 PR-only change after the marker is still stale"
assert_contains "$out" "own_src.js" "AC4 stale names the PR-only file"

# AC5/AC6: after the marker the PR changes a shared file in a way the -U0 patch
# (without @@ and index lines) cannot tell apart: it moves its own added line
# to another function, or swaps a binary file it already touches. Both stale.
git checkout -q -b base5 "$BASE1"
printf 'fa() {\n  :\n}\nfb() {\n  :\n}\n' > moved.sh
printf 'bin0\0one' > bin.dat
git add moved.sh bin.dat
git commit -q -m "base5 files"
B5="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$B5"
git checkout -q -b pr5 "$B5"
printf 'fa() {\n  return 0\n}\nfb() {\n  :\n}\n' > moved.sh
printf 'bin0\0pr-A' > bin.dat
git commit -q -am "pr5 own changes"
M5="$(git rev-parse HEAD)"
git checkout -q -b base5b "$B5"
printf 'sibling\n' > sibling5.txt
git add sibling5.txt
git commit -q -m "base5b sibling"
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
git checkout -q pr5
git merge -q --no-edit base5b >/dev/null 2>&1
out="$(check "$(git rev-parse HEAD)" "$M5")"; rc=$?
assert_exit_code 0 "$rc" "AC5 control: a base merge alone keeps the shared files fresh"
printf 'fa() {\n  :\n}\nfb() {\n  return 0\n}\n' > moved.sh
git commit -q -am "pr5 moves its line"
out="$(check "$(git rev-parse HEAD)" "$M5")"; rc=$?
assert_exit_code 1 "$rc" "AC5 moving the PR's own added line is stale"
assert_contains "$out" "moved.sh" "AC5 stale names the moved-line file"
printf 'bin0\0pr-B' > bin.dat
git commit -q -am "pr5 swaps binary"
out="$(check "$(git rev-parse HEAD)" "$M5")"; rc=$?
assert_exit_code 1 "$rc" "AC6 swapping a binary file the PR already touches is stale"
assert_contains "$out" "bin.dat" "AC6 stale names the binary file"

finish
