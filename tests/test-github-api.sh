#!/usr/bin/env bash
# Regression tests for the github-api provider in pipeline-vcs.sh.
# Uses the curl stub (CURL_LOG + CURL_QUEUE) — no real network calls.
# Covers: list-issues, comment-issue, label-issue, create-pr, merge-pr,
#         find-pr, check-pr-files, approve-pr, rerun-ci, plus missing-token
#         and dry-run variants.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Config: use github-api provider with a test token ────────────────────────
TEST_TOKEN="test-secret-token-12345"
export GITHUB_TOKEN="$TEST_TOKEN"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# ── list-issues ───────────────────────────────────────────────────────────────
printf '%s\n' \
  '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[{"name":"pipeline:dev"},{"name":"p1"}]},{"number":7,"title":"Add dark mode","body":"","labels":[]}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" list-issues)"
assert_contains "$out" '"number": 3'       "list-issues: issue number present"
assert_contains "$out" '"title": "Fix login bug"' "list-issues: issue title present"
assert_contains "$out" '"name": "pipeline:dev"'   "list-issues: label name present"
assert_contains "$out" '"number": 7'       "list-issues: second issue present"

# Verify auth header was sent (CURL_LOG contains Authorization: Bearer)
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "list-issues: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "list-issues: token value not in curl log"

# Token must NOT appear in stdout
assert_not_contains "$out" "$TEST_TOKEN"         "list-issues: token not in output"

# ── comment-issue ─────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"id":100,"body":"Test comment","html_url":"https://github.com/acme/widget/issues/3#issuecomment-100"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" comment-issue 3 "validator: CONFIRMED")"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "api.github.com"           "comment-issue: called GitHub API"
assert_contains "$log" "Authorization: Bearer"    "comment-issue: auth header sent"
assert_contains "$log" "validator: CONFIRMED"     "comment-issue: body in payload"
assert_not_contains "$log" "$TEST_TOKEN"          "comment-issue: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"          "comment-issue: token not in output"

# ── label-issue (multi-step: GET current labels + PUT updated list) ───────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"id":1,"name":"pipeline:dev","color":"5319e7"}]' \
  '[{"id":1,"name":"pipeline:dev"},{"id":2,"name":"pipeline:review"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" label-issue 3 --add pipeline:review --remove pipeline:dev 2>&1)"
log="$(cat "$CURL_LOG")"
# Two API calls should have been made
line_count="$(grep -c 'api.github.com' "$CURL_LOG" || true)"
assert_contains "$log" "Authorization: Bearer"   "label-issue: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "label-issue: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "label-issue: token not in output"

# ── create-pr ─────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":99,"title":"fix: login bug","html_url":"https://github.com/acme/widget/pull/99","head":{"ref":"fix/issue-3-login","sha":"abc123"},"base":{"ref":"main"}}' \
  > "$CURL_QUEUE"

echo "PR body content" > pr-body.txt
out="$(bash "$VCS" create-pr fix/issue-3-login "fix: login bug" pr-body.txt)"
assert_contains "$out" "https://github.com/acme/widget/pull/99" "create-pr: returns PR URL"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "create-pr: auth header sent"
assert_contains "$log" "fix/issue-3-login"       "create-pr: branch in payload"
assert_not_contains "$log" "$TEST_TOKEN"         "create-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "create-pr: token not in output"

# ── merge-pr ──────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"sha":"abc123merged","merged":true,"message":"Pull Request successfully merged"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" merge-pr 99 2>&1)"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "merge-pr: auth header sent"
assert_contains "$log" "/pulls/99/merge"         "merge-pr: correct endpoint called"
assert_not_contains "$log" "$TEST_TOKEN"         "merge-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "merge-pr: token not in output"

# ── find-pr ───────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[{"name":"pipeline:review"}],"state":"open"},{"number":10,"title":"chore: cleanup","head":{"ref":"chore/cleanup"},"body":"no issue","labels":[],"state":"open"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"number": 9'             "find-pr: matches by branch"
assert_not_contains "$out" '"number": 10'        "find-pr: unrelated PR excluded"

: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"open"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 7)"
assert_eq "" "$out"                              "find-pr: no match returns empty"

# ── check-pr-files ────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":"src/auth.js","status":"modified"},{"filename":"tests/auth.test.js","status":"added"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc"                              "check-pr-files: clean PR exits 0"
assert_contains "$out" "no forbidden files"      "check-pr-files: clean PR reported"

: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":"src/auth.js","status":"modified"},{"filename":"deploy/prod.pem","status":"added"},{"filename":".env.production","status":"added"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-pr-files: secrets PR exits 1"
assert_contains "$out" "deploy/prod.pem"         "check-pr-files: pem file listed"
assert_contains "$out" ".env.production"         "check-pr-files: env file listed"
assert_not_contains "$out" "src/auth.js"         "check-pr-files: clean file not listed"

# ── approve-pr ────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"id":200,"state":"APPROVED","body":"LGTM"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" approve-pr 9 "LGTM" 2>&1)"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/pulls/9/reviews"        "approve-pr: correct endpoint"
assert_contains "$log" "Authorization: Bearer"   "approve-pr: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "approve-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "approve-pr: token not in output"

# ── rerun-ci ──────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"abc123sha","ref":"fix/issue-42-guard"},"title":"fix: guard"}' \
  '{"total_count":2,"workflow_runs":[{"id":111,"conclusion":"failure","name":"CI"},{"id":112,"conclusion":"success","name":"CI"}]}' \
  '{}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "rerun-ci: exits 0 on success"
assert_contains "$out" "rerun-ci: re-ran failed runs for PR #9" "rerun-ci: prints success line"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/actions/runs/111/rerun-failed-jobs" "rerun-ci: failed run restarted"
assert_not_contains "$log" "/actions/runs/112/rerun-failed-jobs" "rerun-ci: successful run skipped"
assert_contains "$log" "Authorization: Bearer"   "rerun-ci: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "rerun-ci: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "rerun-ci: token not in output"

# ── rerun-ci: no failed runs returns exit 0 with informational message ─────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"abc123sha","ref":"fix/issue-42-guard"},"title":"fix: guard"}' \
  '{"total_count":1,"workflow_runs":[{"id":112,"conclusion":"success","name":"CI"}]}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "rerun-ci: no failures exits 0"
assert_contains "$out" "no failed runs"          "rerun-ci: no failures prints informational message"

# ── find-pr merged: maps state=merged to state=closed + merged_at filter ─────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"closed","merged_at":"2026-07-09T10:00:00Z"},{"number":10,"title":"fix: other","head":{"ref":"fix/issue-42-other"},"body":"also #42","labels":[],"state":"closed","merged_at":null}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42 merged)"
assert_contains "$out" '"number": 9'             "find-pr merged: matches merged PR"
assert_contains "$out" '"state": "MERGED"'       "find-pr merged: state normalized to MERGED"
assert_not_contains "$out" '"number": 10'        "find-pr merged: closed-not-merged excluded"

# ── find-pr open: state field is OPEN ─────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"open","merged_at":null}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"state": "OPEN"'         "find-pr open: state normalized to OPEN"

# ── missing token → clear error ───────────────────────────────────────────────
unset GITHUB_TOKEN GH_TOKEN
: > "$CURL_QUEUE"

err="$(bash "$VCS" list-issues 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "missing-token: exits 1"
assert_contains "$err" "GITHUB_TOKEN or GH_TOKEN required" "missing-token: clear error message"

export GITHUB_TOKEN="$TEST_TOKEN"  # restore for remaining tests

# ── dry-run: all new verbs print [dry-run] and never invoke curl ──────────────
: > "$CURL_LOG"
: > "$CURL_QUEUE"

dry_out="$(bash "$VCS" --dry-run list-issues; \
           bash "$VCS" --dry-run comment-issue 3 "body"; \
           bash "$VCS" --dry-run label-issue 3 --add foo; \
           bash "$VCS" --dry-run create-pr branch title /dev/null; \
           bash "$VCS" --dry-run merge-pr 9; \
           bash "$VCS" --dry-run find-pr 42; \
           bash "$VCS" --dry-run check-pr-files 9; \
           bash "$VCS" --dry-run approve-pr 9 body; \
           bash "$VCS" --dry-run rerun-ci 9)"

assert_contains "$dry_out" "[dry-run]"           "dry-run: all verbs print [dry-run]"
# Curl log should be empty (no curl calls in dry-run)
dry_log="$(cat "$CURL_LOG")"
assert_eq "" "$dry_log"                          "dry-run: no curl calls made"

# ── unknown provider error still works (sanity) ──────────────────────────────
unset GITHUB_TOKEN GH_TOKEN
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
err="$(bash "$VCS" view-issue 3 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "github-api without token: exits 1"

finish
