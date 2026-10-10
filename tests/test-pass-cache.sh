#!/usr/bin/env bash
# test-pass-cache.sh -- the per-pass read cache of pipeline-vcs.sh (#554).
#
# `post-approval` is five verbs in one pass (pr-head, read-comments, comment-pr,
# label-pr, check-approval-sha), and each used to re-read the same PR, its
# comments and the caller's login. A pass now owns a cache directory
# (TALOS_PASS_CACHE) that the verbs it spawns share:
#   (a) a post-approval pass reads the PR, its comments and /user once before its
#       writes and the PR + comments once after them (the guard and the self-check
#       share that second read), not once per verb
#   (b) any write through the client empties the cache: the self-check sees the
#       marker the pass just posted (a stale snapshot would fail the stamp)
#   (c) comments are cached against the head SHA of the PR object they came
#       with; a new head never reads the old head's comments
#   (d) only successes are cached: a failed read is read again, never replayed
#   (e) the cache is honoured only for a process under the pass that owns it, and
#       a standalone verb has none: two runs make two reads
# Every test runs on stubs under make_sandbox: no GitHub write.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export TALOS_RETRY_SLEEP_SCALE=0
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA=aabb1122ccdd3344eeff556677889900aabb1122
SHA2=ccdd3344eeff556677889900aabb1122aabb1122
export STUB_PR_HEAD_SHA="$SHA" STUB_CURRENT_USER=bot
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json
RESTLOG="$GH_LOG.rest"

# rest <METHOD> <path regex> -- how many REST calls of that method matched.
rest() { awk -F'\t' -v m="$1" -v re="$2" '$4 == m && $1 ~ re { n++ } END { print n + 0 }' "$RESTLOG"; }
reset() { : > "$GH_LOG"; : > "$RESTLOG"; }

# ── (a) one post-approval pass ────────────────────────────────────────────────
CSTORE="$SANDBOX/cs.json"
printf '[]' > "$CSTORE"
export STUB_COMMENT_STORE="$CSTORE"
reset
out="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "post-approval: stamps"
assert_contains "$out" "stamp ok" "post-approval: the stamp verifies"
assert_eq "2" "$(rest GET '/pulls/9$')" "post-approval: the PR is read twice (before the writes, after them)"
assert_eq "2" "$(rest GET '/issues/9/comments')" "post-approval: the comments are read twice (before the writes, after them)"
assert_eq "1" "$(rest GET '/user$')" "post-approval: the login is read once"
assert_eq "1" "$(rest POST '/issues/9/comments$')" "post-approval: one marker comment"
assert_eq "1" "$(rest POST '/issues/9/labels$')" "post-approval: one label write"

# ── (b) a write empties the cache: the self-check sees the marker just posted ──
# The store started empty, so the pre-write read had no marker; only a read made
# after the comment POST can verify the stamp. With the cache kept across the
# write, `stamp ok` could not be printed.
assert_contains "$(cat "$CSTORE")" "talos:approval sha=$SHA role=qa" "post-approval: the marker landed in the store"
unset STUB_COMMENT_STORE

# ── (c)-(e) the cache layer itself, with a pass owned by this shell ───────────
mkpass() { rm -rf "${SANDBOX:?}/pass"; mkdir -m 700 "$SANDBOX/pass"; printf '%s' "$$" > "$SANDBOX/pass/owner"; export TALOS_PASS_CACHE="$SANDBOX/pass"; }

mkpass; reset
bash "$VCS" pr-head 9 >/dev/null; bash "$VCS" pr-head 9 >/dev/null
assert_eq "1" "$(rest GET '/pulls/9$')" "pass: a second pr-head is answered from the cache"

bash "$VCS" label-pr 9 --add foo >/dev/null 2>&1
bash "$VCS" pr-head 9 >/dev/null
assert_eq "2" "$(rest GET '/pulls/9$')" "pass: a label write emptied the cache, so pr-head reads again"

# (c) comments are bound to the head they were read at.
mkpass; reset
bash "$VCS" read-comments 9 >/dev/null; bash "$VCS" read-comments 9 >/dev/null
assert_eq "2" "$(rest GET '/issues/9/comments')" "pass: comments of a PR not yet read are not cached (no head to bind them to)"
reset
bash "$VCS" pr-head 9 >/dev/null
bash "$VCS" read-comments 9 >/dev/null; bash "$VCS" read-comments 9 >/dev/null
assert_eq "1" "$(rest GET '/issues/9/comments')" "pass: with the PR read, its comments are cached"
rm -f "$SANDBOX/pass/pr-9"
reset
STUB_PR_HEAD_SHA="$SHA2" bash "$VCS" pr-head 9 >/dev/null
bash "$VCS" read-comments 9 >/dev/null
assert_eq "1" "$(rest GET '/issues/9/comments')" "pass: a new head never reads the old head's comments"

# (d) a failed read is not cached as a success.
mkpass; reset
STUB_GH_API_FAIL=comments bash "$VCS" pr-head 9 >/dev/null
STUB_GH_API_FAIL=comments bash "$VCS" read-comments 9 >/dev/null 2>&1; rc1=$?
bash "$VCS" read-comments 9 >/dev/null 2>&1; rc2=$?
assert_exit_code 1 "$rc1" "pass: a failed comment read fails"
assert_exit_code 0 "$rc2" "pass: the failure was not cached; the next read goes to GitHub"
assert_eq "2" "$(rest GET '/issues/9/comments')" "pass: both reads reached GitHub"

# (e) not our pass: an owner that is not an ancestor, or no owner, is ignored.
mkpass
printf '%s' 99999 > "$SANDBOX/pass/owner"
printf '{"head":{"sha":"ffffffffffffffffffffffffffffffffffffffff"},"state":"open"}' > "$SANDBOX/pass/pr-9"
reset
got="$(bash "$VCS" pr-head 9 2>&1)"
assert_eq "$SHA" "$got" "foreign cache: a directory whose owner is not an ancestor is ignored (live head, not the planted one)"
assert_eq "1" "$(rest GET '/pulls/9$')" "foreign cache: the read went to GitHub"
rm -f "$SANDBOX/pass/owner"
got="$(bash "$VCS" pr-head 9 2>&1)"
assert_eq "$SHA" "$got" "foreign cache: no owner file, no cache"
unset TALOS_PASS_CACHE
reset
bash "$VCS" pr-head 9 >/dev/null; bash "$VCS" pr-head 9 >/dev/null
assert_eq "2" "$(rest GET '/pulls/9$')" "standalone: no pass, two runs, two reads"

finish
