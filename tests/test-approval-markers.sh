#!/usr/bin/env bash
# test-approval-markers.sh — enforcement of approval markers at the point of
# action (issue #94). Covers:
#
# Cause 2 — bare path detection guard (comment-pr / comment-issue):
#   1. Normal string body             → exits 0, URL on stdout (github)
#   2. --body-file <valid>            → exits 0, file content posted (github)
#   3. --body-file <missing>          → exits 1, error on stderr (github)
#   4. Bare readable absolute path    → exits 1, --body-file hint on stderr (github)
#   5. Body with special chars via --body-file → exits 0, content intact (github)
#   5b-9b same tests for github-api provider
#
# Cause 1 — label-pr approval-marker coupling:
#  10. label-pr --add qa:pass, no marker at head → exits 0, WARNING on stderr
#  11. label-pr --add qa:pass --require-marker, no marker → exits 1
#  12. label-pr --add qa:pass --require-marker, marker present → exits 0, label applied
#
# All Cause 2 tests cover BOTH providers (github, github-api).
# Cause 1 tests cover github provider (check-approval-sha is github-only).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Helper ─────────────────────────────────────────────────────────────────
setup_github_api() {
  cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
  export GITHUB_TOKEN="test-token-94"
}

teardown_github_api() {
  rm -f talos.pipeline.json
  unset GITHUB_TOKEN
}

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 1: Normal string body — github provider
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out1="$(bash "$VCS" comment-pr 9 "This is the verdict body" 2>/dev/null)"; rc1=$?
assert_eq "0" "$rc1" "github/comment-pr: normal string body exits 0"
assert_contains "$out1" "/comments/" \
  "github/comment-pr: normal string body returns URL on stdout"
assert_contains "$(cat "$GH_LOG")" "issue comment 9 --body This is the verdict body" \
  "github/comment-pr: normal string body reaches gh"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 2: --body-file valid file — github provider
# ═════════════════════════════════════════════════════════════════════════════

echo "verdict: PASS" > "$SANDBOX/body.md"
: > "$GH_LOG"
out2="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/body.md" 2>/dev/null)"; rc2=$?
assert_eq "0" "$rc2" "github/comment-pr: --body-file valid exits 0"
assert_contains "$out2" "/comments/" \
  "github/comment-pr: --body-file returns URL on stdout"
assert_contains "$(cat "$GH_LOG")" "verdict: PASS" \
  "github/comment-pr: --body-file content reaches gh"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 3: --body-file missing file — exits 1
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
err3="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/missing.md" 2>&1 >/dev/null)"; rc3=$?
assert_eq "1" "$rc3" "github/comment-pr: --body-file missing exits 1"
assert_contains "$err3" "cannot read" \
  "github/comment-pr: --body-file missing prints error to stderr"
assert_not_contains "$(cat "$GH_LOG")" "issue comment" \
  "github/comment-pr: --body-file missing makes no gh call"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 4: Bare readable absolute path as body — exits 1 (github)
# ═════════════════════════════════════════════════════════════════════════════

echo "verdict: PASS" > "$SANDBOX/verdict.md"
: > "$GH_LOG"
err4="$(bash "$VCS" comment-pr 9 "$SANDBOX/verdict.md" 2>&1 >/dev/null)"; rc4=$?
assert_eq "1" "$rc4" "github/comment-pr: bare path exits 1"
assert_contains "$err4" "--body-file" \
  "github/comment-pr: bare path error names --body-file"
assert_contains "$err4" "$SANDBOX/verdict.md" \
  "github/comment-pr: bare path error contains the path"
assert_not_contains "$(cat "$GH_LOG")" "issue comment" \
  "github/comment-pr: bare path makes no gh call"

# Same for comment-issue
: > "$GH_LOG"
err4b="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 5 "$SANDBOX/verdict.md" 2>&1 >/dev/null)"; rc4b=$?
assert_eq "1" "$rc4b" "github/comment-issue: bare path exits 1"
assert_contains "$err4b" "--body-file" \
  "github/comment-issue: bare path error names --body-file"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 4c: Path that looks path-like but is NOT a readable file → posts
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out4c="$(bash "$VCS" comment-pr 9 "/this/file/does/not/exist.txt" 2>/dev/null)"; rc4c=$?
assert_eq "0" "$rc4c" "github/comment-pr: non-existent path-like body exits 0"
assert_contains "$out4c" "/comments/" \
  "github/comment-pr: non-existent path-like body returns URL"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 5: --body-file with special chars (backslash, backticks, newlines)
# ═════════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/special.md" <<'SPECIALEOF'
Line one with a backslash: \
Line two with backtick content: code example
Line three: $variable reference
SPECIALEOF

: > "$GH_LOG"
out5="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/special.md" 2>/dev/null)"; rc5=$?
assert_eq "0" "$rc5" "github/comment-pr: special-char --body-file exits 0"
assert_contains "$out5" "/comments/" \
  "github/comment-pr: special-char --body-file returns URL"
assert_contains "$(cat "$GH_LOG")" "backslash" \
  "github/comment-pr: special-char content reaches gh intact"

# ═════════════════════════════════════════════════════════════════════════════
# GITHUB-API PROVIDER: same criteria 1-5
# ═════════════════════════════════════════════════════════════════════════════

setup_github_api

# Criterion 1b: normal string body — github-api
: > "$CURL_LOG"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '{"id":501,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-501"}' \
  > "$CURL_QUEUE"
out1b="$(bash "$VCS" comment-pr 9 "This is the verdict body" 2>/dev/null)"; rc1b=$?
assert_eq "0" "$rc1b" "github-api/comment-pr: normal string body exits 0"
assert_contains "$out1b" "issuecomment-501" \
  "github-api/comment-pr: normal string body returns URL"

# Criterion 2b: --body-file valid file — github-api
: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '{"id":502,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-502"}' \
  > "$CURL_QUEUE"
echo "verdict: PASS" > "$SANDBOX/body-ga.md"
out2b="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/body-ga.md" 2>/dev/null)"; rc2b=$?
assert_eq "0" "$rc2b" "github-api/comment-pr: --body-file valid exits 0"
assert_contains "$out2b" "issuecomment-502" \
  "github-api/comment-pr: --body-file returns URL"
assert_contains "$(cat "$CURL_LOG")" "verdict: PASS" \
  "github-api/comment-pr: --body-file content reaches curl"

# Criterion 3b: --body-file missing — github-api
: > "$CURL_LOG"
: > "$CURL_QUEUE"
err3b="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/missing.md" 2>&1 >/dev/null)"; rc3b=$?
assert_eq "1" "$rc3b" "github-api/comment-pr: --body-file missing exits 1"
assert_contains "$err3b" "cannot read" \
  "github-api/comment-pr: --body-file missing prints error to stderr"

# Criterion 4b: bare readable absolute path — github-api
: > "$CURL_LOG"
: > "$CURL_QUEUE"
echo "verdict: PASS" > "$SANDBOX/verdict-ga.md"
err4b2="$(bash "$VCS" comment-pr 9 "$SANDBOX/verdict-ga.md" 2>&1 >/dev/null)"; rc4b2=$?
assert_eq "1" "$rc4b2" "github-api/comment-pr: bare path exits 1"
assert_contains "$err4b2" "--body-file" \
  "github-api/comment-pr: bare path error names --body-file"

# Criterion 4c-b: non-existent path-like body — github-api
: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '{"id":503,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-503"}' \
  > "$CURL_QUEUE"
out4cb="$(bash "$VCS" comment-pr 9 "/this/file/does/not/exist.txt" 2>/dev/null)"; rc4cb=$?
assert_eq "0" "$rc4cb" "github-api/comment-pr: non-existent path-like body exits 0"
assert_contains "$out4cb" "issuecomment-503" \
  "github-api/comment-pr: non-existent path-like body returns URL"

# Criterion 5b: special chars via --body-file — github-api
: > "$CURL_LOG"
: > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '{"id":504,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-504"}' \
  > "$CURL_QUEUE"
out5b="$(bash "$VCS" comment-pr 9 --body-file "$SANDBOX/special.md" 2>/dev/null)"; rc5b=$?
assert_eq "0" "$rc5b" "github-api/comment-pr: special-char --body-file exits 0"
assert_contains "$out5b" "issuecomment-504" \
  "github-api/comment-pr: special-char --body-file returns URL"
assert_contains "$(cat "$CURL_LOG")" "backslash" \
  "github-api/comment-pr: special-char content reaches curl"

teardown_github_api

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 10: label-pr --add qa:pass, no marker → exits 0, WARNING on stderr
# ═════════════════════════════════════════════════════════════════════════════
# Stub state: label qa:pass is present (post-apply), no marker comments.
# check-approval-sha will find qa:pass label and no marker → exits 1 → we warn.

: > "$GH_LOG"
err10="$(STUB_PR_STATE=OPEN \
         STUB_PR_HEAD_SHA="abc123sha000000000000000000000000000000" \
         STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
         STUB_PR_COMMENTS_JSON='[]' \
         bash "$VCS" label-pr 9 --add qa:pass 2>&1 >/dev/null)"; rc10=$?
assert_eq "0" "$rc10" "github/label-pr: approval label without marker exits 0"
assert_contains "$err10" "WARNING" \
  "github/label-pr: WARNING printed to stderr when no marker"
assert_contains "$err10" "comment-pr" \
  "github/label-pr: warning contains comment-pr command hint"
assert_contains "$err10" "verdict reasoning" \
  "github/label-pr: warning reminds stage to post verdict reasoning first"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 11: label-pr --add qa:pass --require-marker, no marker → exits 1
# ═════════════════════════════════════════════════════════════════════════════
# Stub state: no marker in comments. Label NOT yet applied (pre-check).

: > "$GH_LOG"
err11="$(STUB_PR_STATE=OPEN \
          STUB_PR_HEAD_SHA="abc123sha000000000000000000000000000000" \
          STUB_PR_LABELS_JSON='[]' \
          STUB_PR_COMMENTS_JSON='[]' \
          bash "$VCS" label-pr 9 --add qa:pass --require-marker 2>&1 >/dev/null)"; rc11=$?
assert_eq "1" "$rc11" "github/label-pr: --require-marker without marker exits 1"
assert_contains "$err11" "ERROR" \
  "github/label-pr: --require-marker failure prints ERROR to stderr"
assert_not_contains "$(cat "$GH_LOG")" "pr edit" \
  "github/label-pr: --require-marker failure does not apply label"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 12: label-pr --add qa:pass --require-marker, marker present → exits 0
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out12="$(STUB_PR_STATE=OPEN \
           STUB_PR_HEAD_SHA="abc123sha000000000000000000000000000000" \
           STUB_PR_LABELS_JSON='[]' \
           STUB_PR_COMMENTS_JSON='[{"body":"<!-- talos:approval sha=abc123sha000000000000000000000000000000 role=qa -->"}]' \
           bash "$VCS" label-pr 9 --add qa:pass --require-marker 2>/dev/null)"; rc12=$?
assert_eq "0" "$rc12" "github/label-pr: --require-marker with marker exits 0"
assert_contains "$(cat "$GH_LOG")" "pr edit" \
  "github/label-pr: --require-marker with marker applies label"

finish
