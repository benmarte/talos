#!/usr/bin/env bash
# test-record-attempt-stage-check.sh -- record-attempt refuses a stage that
# read-attempt would reject as unrecognised, before it reads or posts anything
# (#1046). Uses the stub gh provider; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUB_CURRENT_USER=bot
printf '%s\n' '{"limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}' > "$SANDBOX/talos.pipeline.json"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"

# ── AC1: an unknown stage is a usage error and posts nothing ──────────────
: > "$GH_LOG"
out="$(STUB_ISSUE_COMMENTS_JSON='[]' bash "$VCS" record-attempt 42 operator 2>&1 >/dev/null)"; rc=$?
assert_exit_code 2 "$rc" "AC1 record-attempt with stage operator exits 2"
assert_contains "$out" "operator" "AC1 stderr names the refused stage"
assert_contains "$out" "developer" "AC1 stderr lists a known stage (developer)"
assert_contains "$out" "qa" "AC1 stderr lists a known stage (qa)"
assert_not_contains "$(cat "$GH_LOG")" "comments payload=" "AC1 nothing was posted"
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "AC1 stderr is one line"

# ── AC2: a known stage still records ──────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_ISSUE_COMMENTS_JSON='[]' bash "$VCS" record-attempt 42 qa 2>/dev/null)"; rc=$?
assert_exit_code 0 "$rc" "AC2 record-attempt qa exits 0"
assert_contains "$out" "stage=qa count=1 total=1" "AC2 record-attempt qa prints its counts"
assert_contains "$(cat "$GH_LOG")" "issues/42/comments payload=" "AC2 record-attempt qa posts a marker"

# ── AC3: read-attempt still fails closed on an unknown stage in a thread ──
thread='[{"body":"Talos attempt record\n<!-- talos:attempt stage=operator count=1 total=1 -->"}]'
out="$(STUB_ISSUE_COMMENTS_JSON="$thread" bash "$VCS" read-attempt 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "AC3 read-attempt on a thread ending in stage=operator exits 1"
assert_contains "$out" "unrecognised stage \"operator\" in marker — fail-closed" "AC3 read-attempt keeps its fail-closed message"

# AC4 (prose: changelog) has no test.
finish
