#!/usr/bin/env bash
# test-post-approval.sh — tests for the post-approval verb (#146).
#
# Acceptance criteria:
#  1. Gate acceptance -- RED from wrong behaviour, not absence:
#     a. Hand-built unwrapped marker (no <!-- -->) is NOT accepted by check-approval-sha.
#     b. Marker from post-approval IS accepted by check-approval-sha.
#  2. Invalid role is refused, naming the valid set (ASCII only).
#  3. SHA comes from the PR head, not the local worktree (verify marker SHA
#     matches STUB_PR_HEAD_SHA even when local HEAD differs).
#  4. Existing hand-posted wrapped markers keep working (regression guard).
#  5. Same-SHA duplicate warns and exits 0.
#  6. comment-pr warning fires on a last-line hand-built marker.
#  7. comment-pr warning does NOT fire on prose mentioning the format.
#  8. Inverse diagnostic in check-approval-sha:
#     a. No labels + markers in comments -> suffix message with count.
#     b. No labels + no markers -> plain message.
#  9. Non-GitHub provider exits 1.
# 10. Dry-run outputs a diagnostic line and exits 0.
# 11. Missing PR number exits 1.
# 12. Missing role exits 1.
# 13. Non-integer PR number exits 1.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

# Make a local commit so local HEAD differs from the stub PR head SHA.
printf 'initial\n' > feature.txt
git add feature.txt
git commit -q -m "initial"
LOCAL_HEAD="$(git rev-parse HEAD)"

# Stub PR head SHA is different from local HEAD -- verifies SHA comes from PR.
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 1a: Hand-built unwrapped marker is NOT accepted by gate (RED guard).
# The gate's MARKER_RE requires <!-- --> delimiters; a bare marker is invisible.
# ─────────────────────────────────────────────────────────────────────────────

# Stub: qa:pass label present, comment has bare (unwrapped) marker.
BARE_MARKER_BODY="talos:approval sha=${STUB_SHA} role=qa"
_cas_labels='[{"name":"qa:pass"}]'
_cas_comments="$(python3 -c "import json; print(json.dumps([{'body': '${BARE_MARKER_BODY}', 'author': {'login': 'bot'}}]))")"

out1a="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
         STUB_PR_BASE_REF_NAME="main" \
         STUB_PR_LABELS_JSON="$_cas_labels" \
         STUB_PR_COMMENTS_JSON="$_cas_comments" \
         bash "$VCS" check-approval-sha 9 2>&1)"; rc1a=$?
assert_exit_code 1 "$rc1a" "gate: unwrapped marker exits 1 (RED guard -- gate rejects bare marker)"
assert_contains "$out1a" "no valid marker" \
  "gate: unwrapped marker produces near-miss diagnostic"
assert_not_contains "$out1a" "all approval labels are current" \
  "gate: unwrapped marker does not pass the gate"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 1b: Marker from post-approval IS accepted by gate.
# post-approval wraps the marker; check-approval-sha must pass.
# ─────────────────────────────────────────────────────────────────────────────

WRAPPED_MARKER="<!-- talos:approval sha=${STUB_SHA} role=qa -->"
_cas_comments2="$(python3 -c "import json; print(json.dumps([{'body': '${WRAPPED_MARKER}', 'author': {'login': 'bot'}}]))")"

out1b="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
          STUB_PR_BASE_REF_NAME="main" \
          STUB_PR_LABELS_JSON="$_cas_labels" \
          STUB_PR_COMMENTS_JSON="$_cas_comments2" \
          bash "$VCS" check-approval-sha 9 2>&1)"; rc1b=$?
assert_exit_code 0 "$rc1b" "gate: wrapped marker exits 0 (gate accepts post-approval output)"
assert_contains "$out1b" "all approval labels are current" \
  "gate: wrapped marker passes the gate"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 2: Invalid role is refused, naming the valid set. ASCII only.
# ─────────────────────────────────────────────────────────────────────────────

out2="$(STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" post-approval 9 badrole 2>&1)"; rc2=$?
assert_exit_code 1 "$rc2" "invalid role: exits 1"
assert_contains "$out2" "unknown role 'badrole'" \
  "invalid role: names the invalid role"
assert_contains "$out2" "valid: docs, qa, reviewer, security" \
  "invalid role: names the valid set"
# ASCII only: no non-ASCII bytes in the error message
if printf '%s' "$out2" | LC_ALL=C grep -qP '[^\x00-\x7F]' 2>/dev/null; then
  fail "invalid role: error message contains non-ASCII bytes"
else
  pass "invalid role: error message is ASCII-only"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 3: SHA comes from PR head, not local worktree.
# Local HEAD ($LOCAL_HEAD) differs from STUB_PR_HEAD_SHA ($STUB_SHA).
# Verify the marker in the posted comment body contains STUB_SHA, not LOCAL_HEAD.
# ─────────────────────────────────────────────────────────────────────────────

: > "$GH_LOG"
STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" post-approval 9 qa >/dev/null 2>/dev/null
_gh_log_content="$(cat "$GH_LOG")"
assert_contains "$_gh_log_content" "talos:approval sha=${STUB_SHA} role=qa" \
  "SHA from PR: marker contains PR head SHA (not local HEAD)"
assert_not_contains "$_gh_log_content" "sha=${LOCAL_HEAD}" \
  "SHA from PR: marker does not contain local worktree HEAD"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 4: Existing hand-posted wrapped markers keep working (regression).
# check-approval-sha must still pass for hand-constructed wrapped markers.
# ─────────────────────────────────────────────────────────────────────────────

HAND_WRAPPED="<!-- talos:approval sha=${STUB_SHA} role=reviewer -->"
_hand_labels='[{"name":"review:approved"}]'
_hand_comments="$(python3 -c "import json; print(json.dumps([{'body': '${HAND_WRAPPED}', 'author': {'login': 'bot'}}]))")"

out4="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
         STUB_PR_BASE_REF_NAME="main" \
         STUB_PR_LABELS_JSON="$_hand_labels" \
         STUB_PR_COMMENTS_JSON="$_hand_comments" \
         bash "$VCS" check-approval-sha 9 2>&1)"; rc4=$?
assert_exit_code 0 "$rc4" "regression: hand-posted wrapped marker still exits 0"
assert_contains "$out4" "all approval labels are current" \
  "regression: hand-posted wrapped marker still passes the gate"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 5: Same-SHA duplicate warns and exits 0.
# Simulate existing marker by injecting it into STUB_PR_COMMENTS_JSON before
# the post-approval call. The stub returns that marker when post-approval
# fetches headRefOid,comments for the duplicate check.
# ─────────────────────────────────────────────────────────────────────────────

_dup_marker="<!-- talos:approval sha=${STUB_SHA} role=qa -->"
_dup_comments="$(python3 -c "import json; print(json.dumps([{'body': '${_dup_marker}', 'author': {'login': 'bot'}}]))")"

: > "$GH_LOG"
err5="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
         STUB_PR_COMMENTS_JSON="$_dup_comments" \
         bash "$VCS" post-approval 9 qa 2>&1 >/dev/null)"; rc5=$?
assert_exit_code 0 "$rc5" "duplicate: same-SHA duplicate exits 0"
assert_contains "$err5" "warning" \
  "duplicate: same-SHA duplicate prints a warning"
assert_contains "$err5" "already exists" \
  "duplicate: warning mentions the duplicate"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 6: comment-pr warning fires on a last-line hand-built marker.
# ─────────────────────────────────────────────────────────────────────────────

HAND_MARKER_BODY="<!-- talos:approval sha=${STUB_SHA} role=security -->"

: > "$GH_LOG"
err6="$(bash "$VCS" comment-pr 9 "$HAND_MARKER_BODY" 2>&1 >/dev/null)"; rc6=$?
assert_exit_code 0 "$rc6" "comment-pr warning: exits 0 (non-fatal)"
assert_contains "$err6" "hand-built talos:approval marker" \
  "comment-pr warning: fires on last-line hand-built marker"
assert_contains "$err6" "post-approval" \
  "comment-pr warning: mentions post-approval verb"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 7: comment-pr warning does NOT fire on prose mentioning the format.
# The check is scoped to the last non-whitespace line only (#140).
# ─────────────────────────────────────────────────────────────────────────────

PROSE_BODY="The marker format is <!-- talos:approval sha=<sha> role=<role> -->.
Here is my verdict:

PASS: all criteria met."

: > "$GH_LOG"
err7="$(bash "$VCS" comment-pr 9 "$PROSE_BODY" 2>&1 >/dev/null)"; rc7=$?
assert_exit_code 0 "$rc7" "comment-pr no-warn on prose: exits 0"
assert_not_contains "$err7" "hand-built talos:approval marker" \
  "comment-pr no-warn on prose: warning does NOT fire when marker is in middle of body"

# Also: body ending with non-marker text
VERDICT_BODY="Some findings here.
<!-- talos:approval sha=${STUB_SHA} role=security -->
PASS: verified."

: > "$GH_LOG"
err7b="$(bash "$VCS" comment-pr 9 "$VERDICT_BODY" 2>&1 >/dev/null)"; rc7b=$?
assert_exit_code 0 "$rc7b" "comment-pr no-warn: exits 0 when marker is not last line"
assert_not_contains "$err7b" "hand-built talos:approval marker" \
  "comment-pr no-warn: warning does NOT fire when marker is not the last non-whitespace line"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 8a: check-approval-sha inverse diagnostic:
# No approval labels present + markers in comments -> prints count suffix.
# ─────────────────────────────────────────────────────────────────────────────

MARKER_IN_COMMENT="<!-- talos:approval sha=${STUB_SHA} role=qa -->"
_inv_comments="$(python3 -c "import json; print(json.dumps([{'body': '${MARKER_IN_COMMENT}', 'author': {'login': 'bot'}}]))")"

out8a="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
          STUB_PR_BASE_REF_NAME="main" \
          STUB_PR_LABELS_JSON='[]' \
          STUB_PR_COMMENTS_JSON="$_inv_comments" \
          bash "$VCS" check-approval-sha 9 2>&1)"; rc8a=$?
assert_exit_code 0 "$rc8a" "inverse diagnostic: no labels exits 0"
assert_contains "$out8a" "approval marker(s) found in comments" \
  "inverse diagnostic: suffix printed when markers found but no labels"
assert_contains "$out8a" "did a stage post a marker without applying its label" \
  "inverse diagnostic: suffix mentions missing label application"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 8b: No labels + no markers -> plain message (unchanged behavior).
# ─────────────────────────────────────────────────────────────────────────────

out8b="$(STUB_PR_HEAD_SHA="$STUB_SHA" \
          STUB_PR_BASE_REF_NAME="main" \
          STUB_PR_LABELS_JSON='[]' \
          STUB_PR_COMMENTS_JSON='[]' \
          bash "$VCS" check-approval-sha 9 2>&1)"; rc8b=$?
assert_exit_code 0 "$rc8b" "plain no-labels: exits 0"
assert_contains "$out8b" "no approval labels present" \
  "plain no-labels: still prints no-labels message"
assert_not_contains "$out8b" "approval marker(s) found" \
  "plain no-labels: does NOT print marker-found suffix when no markers"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 9: Non-GitHub provider exits 1.
# ─────────────────────────────────────────────────────────────────────────────

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}}
EOF
out9="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc9=$?
assert_exit_code 1 "$rc9" "non-github provider: exits 1"
assert_contains "$out9" "not implemented for provider 'gitlab'" \
  "non-github provider: error names the provider"
rm -f talos.pipeline.json

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 10: Dry-run outputs a diagnostic and exits 0.
# ─────────────────────────────────────────────────────────────────────────────

out10="$(STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" --dry-run post-approval 9 qa 2>&1)"; rc10=$?
assert_exit_code 0 "$rc10" "dry-run: exits 0"
assert_contains "$out10" "dry-run" \
  "dry-run: prints dry-run indicator"
assert_contains "$out10" "post-approval" \
  "dry-run: mentions post-approval in output"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 11: Missing PR number exits 1.
# ─────────────────────────────────────────────────────────────────────────────

out11="$(bash "$VCS" post-approval 2>&1)"; rc11=$?
assert_exit_code 1 "$rc11" "missing PR: exits 1"
assert_contains "$out11" "missing PR number" \
  "missing PR: error names the missing argument"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 12: Missing role exits 1.
# ─────────────────────────────────────────────────────────────────────────────

out12="$(bash "$VCS" post-approval 9 2>&1)"; rc12=$?
assert_exit_code 1 "$rc12" "missing role: exits 1"
assert_contains "$out12" "missing role" \
  "missing role: error names the missing argument"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 13: Non-integer PR number exits 1.
# ─────────────────────────────────────────────────────────────────────────────

out13="$(bash "$VCS" post-approval abc qa 2>&1)"; rc13=$?
assert_exit_code 1 "$rc13" "non-integer PR: exits 1"
assert_contains "$out13" "integer" \
  "non-integer PR: error mentions integer requirement"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 14: post-approval with --body-file prepends the prose body.
# ─────────────────────────────────────────────────────────────────────────────

printf 'QA PASS: all criteria verified.\n\nDetails here.\n' > "$SANDBOX/verdict.md"

: > "$GH_LOG"
STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" post-approval 9 qa \
  --body-file "$SANDBOX/verdict.md" >/dev/null 2>/dev/null
_gh_log14="$(cat "$GH_LOG")"
assert_contains "$_gh_log14" "QA PASS" \
  "body-file: prose body content reaches gh"
assert_contains "$_gh_log14" "talos:approval sha=${STUB_SHA} role=qa" \
  "body-file: marker appended after prose body"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 15: github-api provider also supported.
# ─────────────────────────────────────────────────────────────────────────────

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-146"

: > "$CURL_LOG"
: > "$CURL_QUEUE"
# post-approval calls pr-head, comment-pr, label-pr -- each needs a curl response.
# pr-head: {"head": {"sha": "<sha>"}}
# comment-pr: state check + post
# label-pr: get labels + put
printf '%s\n%s\n%s\n%s\n%s\n' \
  "{\"head\":{\"sha\":\"${STUB_SHA}\"}}" \
  "{\"state\":\"open\",\"merged_at\":null}" \
  "{\"id\":900,\"html_url\":\"https://github.com/acme/widget/pull/9#issuecomment-900\"}" \
  "[]" \
  "{\"labels\":[{\"name\":\"qa:pass\"}]}" \
  > "$CURL_QUEUE"

out15="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc15=$?
assert_exit_code 0 "$rc15" "github-api: post-approval exits 0"
assert_contains "$out15" "marker posted" \
  "github-api: post-approval reports success"
rm -f talos.pipeline.json
unset GITHUB_TOKEN

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 16: Exit 0 on normal path (end-to-end via github provider).
# ─────────────────────────────────────────────────────────────────────────────

: > "$GH_LOG"
out16="$(STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" post-approval 9 reviewer 2>&1)"; rc16=$?
assert_exit_code 0 "$rc16" "normal path: post-approval exits 0"
assert_contains "$out16" "marker posted" \
  "normal path: success message on stdout"
assert_contains "$(cat "$GH_LOG")" "talos:approval sha=${STUB_SHA} role=reviewer" \
  "normal path: marker reached gh with correct SHA and role"
assert_contains "$(cat "$GH_LOG")" "review:approved" \
  "normal path: review:approved label applied via gh pr edit"

# ─────────────────────────────────────────────────────────────────────────────
# CRITERION 17: comment-pr warning suppressed when called from post-approval.
# post-approval posts a comment ending in a marker, but the warning must NOT
# fire because _TALOS_POST_APPROVAL_INTERNAL=1 is set.
# ─────────────────────────────────────────────────────────────────────────────

: > "$GH_LOG"
warn17="$(STUB_PR_HEAD_SHA="$STUB_SHA" bash "$VCS" post-approval 9 docs 2>&1 >/dev/null)"
assert_not_contains "$warn17" "hand-built talos:approval marker" \
  "internal suppress: comment-pr warning does NOT fire when called from post-approval"

finish
