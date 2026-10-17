#!/usr/bin/env bash
# test-azure-record-attempt-url-765.sh -- azure record-attempt logs the posted
# work-item comment's URL instead of <unknown> (#765), and comment-issue /
# close-issue keep printing nothing on stdout. Uses the tests/stubs/az stub; no
# credentials needed. Tests are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"
export STUB_AZURE_STATE_DIR="$SANDBOX/state"; mkdir -p "$STUB_AZURE_STATE_DIR"

# ── AC1: record-attempt logs the work item's URL on stderr ───────────────────
out="$(bash "$VCS" record-attempt 5 developer 2>"$SANDBOX/err")"; rc=$?
err="$(cat "$SANDBOX/err")"
assert_eq "0" "$rc" "AC1 record-attempt exits 0"
assert_contains "$err" "marker posted at https://dev.azure.com/acme/proj/_workitems/edit/5" \
  "AC1 record-attempt logs the work item URL"
assert_not_contains "$err" "<unknown>" "AC1 record-attempt no longer logs <unknown>"
assert_eq "stage=developer count=1 total=1" "$out" "AC1 stdout stays the stage counts"

# ── AC2: the URL is opt-in; other callers keep their output ──────────────────
out="$(bash "$VCS" comment-issue 5 "hello" 2>/dev/null)"
assert_not_contains "$out" "_workitems" "AC2 comment-issue prints no URL"
out="$(bash "$VCS" close-issue 5 "done" 2>/dev/null)"
assert_not_contains "$out" "_workitems" "AC2 close-issue prints no URL"
out="$(bash "$VCS" --dry-run comment-issue 5 "hello" 2>/dev/null)"
assert_contains "$out" "[dry-run] az rest" "AC2 comment-issue --dry-run keeps the az rest line"
assert_not_contains "$out" "_workitems" "AC2 comment-issue --dry-run prints no URL"

# ── AC3: a failed post still fails record-attempt, with no URL ───────────────
out="$(STUB_AZURE_WI_POST_FAIL=1 bash "$VCS" record-attempt 6 developer 2>"$SANDBOX/err")"; rc=$?
err="$(cat "$SANDBOX/err")"
assert_eq "1" "$rc" "AC3 record-attempt exits 1 when the post fails"
assert_contains "$err" "failed to post attempt marker" "AC3 record-attempt reports the failed post"
assert_not_contains "$err" "_workitems" "AC3 no URL is logged on failure"
assert_not_contains "$out" "_workitems" "AC3 stdout carries no URL on failure"

finish
