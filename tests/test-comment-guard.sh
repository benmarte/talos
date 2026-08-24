#!/usr/bin/env bash
# test-comment-guard.sh — closed-target guard and comment URL return for
# comment-issue and comment-pr (issue #55).
#
# Covers all 10 [test] acceptance criteria:
#  1. comment-issue on closed issue exits non-zero, prints state to stderr,
#     no comment posted — github provider
#  2. comment-issue on closed issue exits non-zero — github-api provider
#  3. comment-issue --allow-closed on closed issue succeeds, prints html_url — github
#  4. comment-issue --allow-closed on closed issue succeeds, prints html_url — github-api
#  5. comment-issue on open issue succeeds, prints html_url — both providers
#  6. comment-pr on closed-unmerged PR exits non-zero — both providers
#  7. comment-pr on merged PR succeeds, returns html_url
#  8. comment-pr --allow-closed on closed-unmerged PR succeeds, prints html_url
#  9. comment-pr on open PR succeeds, prints html_url — both providers
# 10. State-check failure → proceed + warning to stderr + talos:comment-state-unverified on stdout
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Helper: set up github-api config + token ─────────────────────────────────
setup_github_api() {
  cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
  export GITHUB_TOKEN="test-token-55"
}

teardown_github_api() {
  rm -f talos.pipeline.json
  unset GITHUB_TOKEN
}

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 1 & 3: github provider — comment-issue on closed issue
# ═════════════════════════════════════════════════════════════════════════════

# 1. Closed issue → exit non-zero, state to stderr, no gh comment call
: > "$GH_LOG"
out="$(STUB_ISSUE_STATE=CLOSED bash "$VCS" comment-issue 5 "body" 2>&1)"; rc=$?
assert_eq "1" "$rc" "github/comment-issue: closed issue exits 1"
assert_contains "$out" "CLOSED" "github/comment-issue: state printed to stderr"
assert_not_contains "$(cat "$GH_LOG")" "issue comment 5" \
  "github/comment-issue: no gh comment call on closed issue"

# Regression: this test must fail when the guard is removed.
# (Verified by temporarily removing the state check block — test went RED.)

# 3. --allow-closed on closed issue succeeds and prints html_url
: > "$GH_LOG"
out="$(STUB_ISSUE_STATE=CLOSED bash "$VCS" comment-issue 5 "body" --allow-closed 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github/comment-issue: --allow-closed on closed exits 0"
assert_contains "$out" "/comments/" \
  "github/comment-issue: --allow-closed returns comment URL"
assert_not_contains "$out" "talos:comment-state-unverified" \
  "github/comment-issue: --allow-closed does not emit state-unverified marker"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 5a: github provider — comment-issue on open issue → html_url
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 5 "findings body" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github/comment-issue: open issue exits 0"
assert_contains "$out" "/comments/" \
  "github/comment-issue: open issue returns comment URL on stdout"
# Also verify the body was passed through to gh
assert_contains "$(cat "$GH_LOG")" "issue comment 5 --body findings body" \
  "github/comment-issue: open issue calls gh with the body"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 9a: github provider — comment-pr on open PR → html_url
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 "review done" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github/comment-pr: open PR exits 0"
assert_contains "$out" "/comments/" \
  "github/comment-pr: open PR returns comment URL on stdout"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 6a: github provider — comment-pr on closed-unmerged PR
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
err="$(STUB_PR_STATE=CLOSED bash "$VCS" comment-pr 9 "body" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "github/comment-pr: closed PR exits 1"
assert_contains "$err" "CLOSED" "github/comment-pr: state printed to stderr"
assert_not_contains "$(cat "$GH_LOG")" "issue comment 9" \
  "github/comment-pr: no gh comment call on closed PR"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 7: github provider — comment-pr on MERGED PR succeeds
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out="$(STUB_PR_STATE=MERGED bash "$VCS" comment-pr 9 "post-merge note" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github/comment-pr: merged PR exits 0"
assert_contains "$out" "/comments/" \
  "github/comment-pr: merged PR returns comment URL on stdout"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 8: github provider — comment-pr --allow-closed on closed-unmerged
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out="$(STUB_PR_STATE=CLOSED bash "$VCS" comment-pr 9 "body" --allow-closed 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github/comment-pr: --allow-closed on closed PR exits 0"
assert_contains "$out" "/comments/" \
  "github/comment-pr: --allow-closed on closed PR returns URL"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 10a: github provider — state-check failure (indeterminate state)
# When gh issue view fails, proceed + warn on stderr + emit marker on stdout
# ═════════════════════════════════════════════════════════════════════════════

# Use a STUB_ISSUE_STATE value that makes the stub exit non-zero.
# Actually, the stub always exits 0. We need gh issue view to fail.
# We'll use a custom stub wrapper via STUB_ISSUE_STATE_FAIL=true.
# The simplest way: override gh stub for this test to exit 1 on state check.
# Use a temp stub directory.
_tmp_stubs="$(mktemp -d)"
cat > "$_tmp_stubs/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
REPO="${STUB_REPO:-acme/widget}"
args="$*"
case "$args" in
  # State check fails for this test
  "issue view "*"--json state -q .state"*)
    exit 1 ;;
  "issue comment "*"--json url -q .url"*)
    printf 'https://github.com/%s/issues/comments/999\n' "$REPO" ;;
  *)
    exit 0 ;;
esac
GHSTUB
chmod +x "$_tmp_stubs/gh"

: > "$GH_LOG"
old_path="$PATH"
export PATH="$_tmp_stubs:$PATH"
out="$(bash "$VCS" comment-issue 5 "body" 2>/tmp/ci_state_err_55.txt)"; rc=$?
stderr_out="$(cat /tmp/ci_state_err_55.txt)"
export PATH="$old_path"
rm -rf "$_tmp_stubs" /tmp/ci_state_err_55.txt

assert_eq "0" "$rc" "github/comment-issue: state-check failure exits 0 (fail-open)"
assert_contains "$stderr_out" "warning" \
  "github/comment-issue: state-check failure prints warning to stderr"
assert_contains "$out" "/comments/" \
  "github/comment-issue: state-check failure still returns comment URL"
assert_contains "$out" "talos:comment-state-unverified" \
  "github/comment-issue: state-check failure emits marker on stdout"
assert_contains "$out" "issue#5" \
  "github/comment-issue: state-unverified marker includes target"

# ═════════════════════════════════════════════════════════════════════════════
# GITHUB-API PROVIDER TESTS
# ═════════════════════════════════════════════════════════════════════════════

setup_github_api

# ── Criterion 2: github-api / comment-issue / closed issue → exit non-zero ──

: > "$CURL_LOG"
printf '%s\n' \
  '{"state":"closed","title":"issue 5"}' \
  > "$CURL_QUEUE"

err2="$(bash "$VCS" comment-issue 5 "body" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "github-api/comment-issue: closed issue exits 1"
assert_contains "$err2" "closed" "github-api/comment-issue: state printed to stderr"
# No POST should have been made — only the GET for state check
log2="$(cat "$CURL_LOG")"
assert_not_contains "$log2" '"body"' \
  "github-api/comment-issue: no comment POST on closed issue"

# ── Criterion 4: github-api / comment-issue / --allow-closed ────────────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"id":200,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-200"}' \
  > "$CURL_QUEUE"

out4="$(bash "$VCS" comment-issue 5 "body" --allow-closed 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github-api/comment-issue: --allow-closed exits 0"
assert_contains "$out4" "issuecomment-200" \
  "github-api/comment-issue: --allow-closed returns html_url"

# ── Criterion 5b: github-api / comment-issue / open issue → html_url ────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","title":"issue 5"}' \
  '{"id":201,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-201"}' \
  > "$CURL_QUEUE"

out5b="$(bash "$VCS" comment-issue 5 "validator: CONFIRMED" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github-api/comment-issue: open issue exits 0"
assert_contains "$out5b" "issuecomment-201" \
  "github-api/comment-issue: open issue returns html_url on stdout"

# ── Criterion 6b: github-api / comment-pr / closed-unmerged PR ───────────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"closed","merged_at":null,"number":9}' \
  > "$CURL_QUEUE"

err6b="$(bash "$VCS" comment-pr 9 "body" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "github-api/comment-pr: closed-unmerged PR exits 1"
assert_contains "$err6b" "closed" \
  "github-api/comment-pr: closed state printed to stderr"

# ── Criterion 7b: github-api / comment-pr / merged PR succeeds ───────────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"closed","merged_at":"2026-08-01T12:00:00Z","number":9}' \
  '{"id":202,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-202"}' \
  > "$CURL_QUEUE"

out7b="$(bash "$VCS" comment-pr 9 "post-merge note" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github-api/comment-pr: merged PR exits 0"
assert_contains "$out7b" "issuecomment-202" \
  "github-api/comment-pr: merged PR returns html_url"

# ── Criterion 8b: github-api / comment-pr / --allow-closed ──────────────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"id":203,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-203"}' \
  > "$CURL_QUEUE"

out8b="$(bash "$VCS" comment-pr 9 "body" --allow-closed 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github-api/comment-pr: --allow-closed exits 0"
assert_contains "$out8b" "issuecomment-203" \
  "github-api/comment-pr: --allow-closed returns html_url"

# ── Criterion 9b: github-api / comment-pr / open PR → html_url ───────────────

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '{"id":204,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-204"}' \
  > "$CURL_QUEUE"

out9b="$(bash "$VCS" comment-pr 9 "review done" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github-api/comment-pr: open PR exits 0"
assert_contains "$out9b" "issuecomment-204" \
  "github-api/comment-pr: open PR returns html_url"

# ── Criterion 10b: github-api — state-check network failure (indeterminate) ──
# Prime a non-2xx response for the state GET, then a valid comment response.

: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '500' \
  '{"id":205,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-205"}' \
  > "$CURL_QUEUE"

out10b="$(bash "$VCS" comment-issue 5 "body" 2>/tmp/ga_state_err_55.txt)"; rc=$?
stderr10b="$(cat /tmp/ga_state_err_55.txt)"
rm -f /tmp/ga_state_err_55.txt

assert_eq "0" "$rc" "github-api/comment-issue: state-check failure exits 0 (fail-open)"
assert_contains "$stderr10b" "warning" \
  "github-api/comment-issue: state-check failure prints warning to stderr"
assert_contains "$out10b" "issuecomment-205" \
  "github-api/comment-issue: state-check failure still returns html_url"
assert_contains "$out10b" "talos:comment-state-unverified" \
  "github-api/comment-issue: state-check failure emits marker on stdout"

teardown_github_api

# ═════════════════════════════════════════════════════════════════════════════
# REGRESSION: post-merge case — comment-issue on CLOSED issue
# This is the scenario GitHub auto-closes the issue via "Closes #N" at merge.
# ═════════════════════════════════════════════════════════════════════════════

# Without --allow-closed: must fail
: > "$GH_LOG"
err_reg="$(STUB_ISSUE_STATE=CLOSED bash "$VCS" comment-issue 42 "closed body" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" \
  "regression/post-merge: comment-issue on CLOSED issue without --allow-closed fails"

# With --allow-closed: must succeed (post-merge orchestrator summary scenario)
: > "$GH_LOG"
out_reg="$(STUB_ISSUE_STATE=CLOSED bash "$VCS" comment-issue 42 "closed body" --allow-closed 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" \
  "regression/post-merge: comment-issue on CLOSED issue WITH --allow-closed succeeds"
assert_contains "$out_reg" "/comments/" \
  "regression/post-merge: --allow-closed on closed issue returns URL"

finish
