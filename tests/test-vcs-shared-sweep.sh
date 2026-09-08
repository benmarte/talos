#!/usr/bin/env bash
# test-vcs-shared-sweep.sh — direct unit tests for the four helpers shared by
# _github and _github_api in #177 slice 4:
#   _vcs_shared_check_closing_keyword, _vcs_shared_find_pr,
#   _vcs_shared_pr_mergeable, plus idempotency-key coverage for
#   _vcs_shared_record_attempt (already centralised in slice 1; this file
#   adds the valid/invalid key assertions the sweep called for).
#
# These drive the shared functions directly (not through either adapter's
# CLI verb) so a regression in the shared logic itself is caught here even
# if both adapters happened to still agree by coincidence. Every test can
# fail: disabling/breaking a shared helper causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SCRIPT_DIR="$TALOS_ROOT/scripts"   # _vcs_shared_record_attempt recurses via this
cfg() { bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$@"; }
_TALOS_CFG=""

# ── Load ONLY the shared-helper function definitions ──────────────────────────
# Never `source`/`.` the whole script: it has top-level arg-parsing/dispatch
# that ends in `exit`, which would terminate this test process. Extract the
# byte range from `_vcs_shared_read_attempt() {` up to (not including) the
# `_github() {` adapter that follows it -- pure function definitions, safe to
# eval into this shell. (Same anchors as test-vcs-shared-markers.sh,
# test-vcs-shared-approval-sha.sh and test-vcs-shared-pr-files.sh; picks up
# every shared helper defined so far, including this slice's four.)
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
if [ -z "$_shared_src" ]; then
  fail "setup: extracted shared-helper source is non-empty" "extraction produced nothing -- check the awk anchors against pipeline-vcs.sh"
fi
eval "$_shared_src"
for _fn in _vcs_shared_check_closing_keyword _vcs_shared_find_pr _vcs_shared_pr_mergeable _vcs_shared_record_attempt; do
  if ! declare -F "$_fn" >/dev/null; then
    fail "setup: $_fn loaded" "function not defined after eval"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_check_closing_keyword
# ═══════════════════════════════════════════════════════════════════════════

FETCH_LOG="$SANDBOX/siblings_fetch.log"
SIBLINGS_JSON='[]'
SIBLINGS_FAIL=0
_test_siblings_fetch() {
  printf 'called\n' >> "$FETCH_LOG"
  if [ "$SIBLINGS_FAIL" = "1" ]; then
    return 1
  fi
  printf '%s' "$SIBLINGS_JSON"
}

# No closing keyword in the body -> exit 0, and (lazy fetch, mirrors the
# original two adapters) the siblings-fetch callback is never invoked.
: > "$FETCH_LOG"
out="$(printf '%s' 'Part of #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "closing_keyword: no closing keyword exits 0"
assert_eq "" "$out" "closing_keyword: no closing keyword produces no output"
assert_eq "0" "$(wc -l < "$FETCH_LOG" | tr -d ' ')" "closing_keyword: no closing keyword never fetches siblings (lazy)"

# Closing keyword present, no open siblings -> exit 0 (Rule 6: siblings merged).
: > "$FETCH_LOG"
SIBLINGS_JSON='[]'
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "closing_keyword: closing keyword, no siblings exits 0"
assert_eq "1" "$(wc -l < "$FETCH_LOG" | tr -d ' ')" "closing_keyword: closing keyword fetches siblings exactly once"

# The candidate PR itself is excluded from the sibling scan even if it
# appears in the fetched (open) PR list.
SIBLINGS_JSON='[{"number":9,"state":"OPEN","title":"self","headRefName":"fix/issue-42-guard","body":"Closes #42"}]'
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "closing_keyword: self in the open-PR list is excluded, not counted as a sibling"

# Closing keyword present, one OPEN sibling referencing the same issue by
# body -> exit 1, blocked, em-dash diagnostic naming the sibling.
SIBLINGS_JSON='[{"number":10,"state":"OPEN","title":"other","headRefName":"fix/issue-42-y","body":"Part of #42"}]'
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "1" "$rc" "closing_keyword: open sibling by body exits 1"
assert_contains "$out" "open sibling PR(s) still reference the same issue: #10" "closing_keyword: diagnostic names the sibling"
assert_contains "$out" "— merge the siblings first, or change this PR body to 'Part of #42'" "closing_keyword: diagnostic uses em-dash wording (drift resolved to _github)"

# Sibling matched via branch name alone (title/body carry no reference).
SIBLINGS_JSON='[{"number":11,"state":"OPEN","title":"unrelated","headRefName":"fix/issue-42-other","body":"nothing here"}]'
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "1" "$rc" "closing_keyword: open sibling by branch name exits 1"
assert_contains "$out" "#11" "closing_keyword: branch-matched sibling named in diagnostic"

# Sibling-list fetch failure -> fail open (exit 0), machine-readable marker.
SIBLINGS_FAIL=1
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _test_siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "closing_keyword: sibling fetch failure fails open"
assert_contains "$out" "talos:closing-keyword-unverified" "closing_keyword: fetch failure emits the unverified marker"
assert_contains "$out" "reason=sibling-fetch-failed" "closing_keyword: fetch failure marker names the reason"
SIBLINGS_FAIL=0

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_find_pr
# ═══════════════════════════════════════════════════════════════════════════

# Match by branch name only (title/body do not mention the issue).
stdin='[{"number":5,"state":"OPEN","title":"unrelated title","headRefName":"fix/issue-42-x","body":"no ref here"}]'
out="$(printf '%s' "$stdin" | _vcs_shared_find_pr 42)"
assert_contains "$out" '"number": 5' "find_pr: branch-name match returns the PR"
assert_contains "$out" '"headRefName": "fix/issue-42-x"' "find_pr: branch-name match preserves headRefName"

# Match by body only (branch name carries no reference).
stdin='[{"number":6,"state":"OPEN","title":"t","headRefName":"some-other-branch","body":"Closes #42"}]'
out="$(printf '%s' "$stdin" | _vcs_shared_find_pr 42)"
assert_contains "$out" '"number": 6' "find_pr: body match returns the PR"

# No match on either signal -> not returned.
stdin='[{"number":7,"state":"OPEN","title":"unrelated","headRefName":"other-branch","body":"nothing"}]'
out="$(printf '%s' "$stdin" | _vcs_shared_find_pr 42)"
assert_eq "" "$out" "find_pr: no match on branch or body returns nothing"

# A null body (REST can return this; gh's JSON export does not) must not
# crash the matcher -- title-only match still succeeds.
stdin='[{"number":8,"state":"OPEN","title":"fix #55","headRefName":"other","body":null}]'
out="$(printf '%s' "$stdin" | _vcs_shared_find_pr 55)"; rc=$?
assert_eq "0" "$rc" "find_pr: null body does not crash the matcher"
assert_contains "$out" '"number": 8' "find_pr: null body still matches via title text"

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_pr_mergeable
# ═══════════════════════════════════════════════════════════════════════════

# UNKNOWN on the first poll, MERGEABLE on the retry (scale 0 so the test
# does not actually sleep).
MERGE_CALLS="$SANDBOX/merge_calls"
echo 0 > "$MERGE_CALLS"
_test_fetch_then_mergeable() {
  local n
  n=$(( $(cat "$MERGE_CALLS") + 1 ))
  echo "$n" > "$MERGE_CALLS"
  case "$n" in
    1) echo UNKNOWN ;;
    *) echo MERGEABLE ;;
  esac
}
out="$(TALOS_RETRY_SLEEP_SCALE=0 _vcs_shared_pr_mergeable _test_fetch_then_mergeable)"; rc=$?
assert_eq "0" "$rc" "pr_mergeable: settles to MERGEABLE exits 0"
assert_eq "MERGEABLE" "$out" "pr_mergeable: settles to MERGEABLE prints MERGEABLE"
assert_eq "2" "$(cat "$MERGE_CALLS")" "pr_mergeable: polled exactly twice (initial + one retry)"

# CONFLICTING on the very first poll -> exit 1, no retry needed.
_test_fetch_conflicting() { echo CONFLICTING; }
out="$(TALOS_RETRY_SLEEP_SCALE=0 _vcs_shared_pr_mergeable _test_fetch_conflicting)"; rc=$?
assert_eq "1" "$rc" "pr_mergeable: CONFLICTING exits 1"
assert_eq "CONFLICTING" "$out" "pr_mergeable: CONFLICTING prints CONFLICTING"

# Never settles -> exhausts retries, exits 2 with UNKNOWN, exactly 5 polls
# (the initial attempt plus 4 retries).
echo 0 > "$MERGE_CALLS"
_test_fetch_always_unknown() {
  local n
  n=$(( $(cat "$MERGE_CALLS") + 1 ))
  echo "$n" > "$MERGE_CALLS"
  echo UNKNOWN
}
out="$(TALOS_RETRY_SLEEP_SCALE=0 _vcs_shared_pr_mergeable _test_fetch_always_unknown)"; rc=$?
assert_eq "2" "$rc" "pr_mergeable: exhausted retries exits 2"
assert_eq "UNKNOWN" "$out" "pr_mergeable: exhausted retries prints UNKNOWN"
assert_eq "5" "$(cat "$MERGE_CALLS")" "pr_mergeable: polled exactly 5 times before giving up"

# ═══════════════════════════════════════════════════════════════════════════
# Idempotency-key validation/derivation (#172), already centralised in
# _vcs_shared_record_attempt since slice 1 -- coverage added here per the
# slice 4 sweep (nothing left to move: grep confirms record-attempt's
# --idempotency-key/--pr handling has exactly one definition on both sides).
# ═══════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}
EOF
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"

POST_LOG="$SANDBOX/post_fn.log"
_stub_post_ok() {
  printf '%s\t%s\n' "$1" "$2" > "$POST_LOG"
  printf 'https://example.invalid/comment/1'
  return 0
}

# A well-formed key ([A-Za-z0-9._-]+) is accepted and posts normally.
: > "$POST_LOG"
out="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok --idempotency-key valid.Token-123_ok 2>&1)"; rc=$?
assert_eq "0" "$rc" "idempotency_key: well-formed key is accepted"
assert_contains "$out" "stage=qa count=1 total=1" "idempotency_key: well-formed key still records the attempt"
assert_contains "$(cat "$POST_LOG")" "key=valid.Token-123_ok" "idempotency_key: accepted key is embedded in the marker"

# A key containing a disallowed character (space) is rejected before any
# write is attempted.
: > "$POST_LOG"
err="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok --idempotency-key 'bad key' 2>&1 1>/dev/null)"
rc="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok --idempotency-key 'bad key' >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "idempotency_key: malformed key is rejected"
assert_contains "$err" "must match [A-Za-z0-9._-]+, got 'bad key'" "idempotency_key: rejection message names the offending value"
assert_eq "" "$(cat "$POST_LOG")" "idempotency_key: malformed key never reaches the post-fn"

finish
