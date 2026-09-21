#!/usr/bin/env bash
# test-mergesync.sh -- update-branch verb tests (#289).
#
# Contract (scripts/pipeline-vcs.sh `update-branch <n>`):
#   github / github-api  exit 0 on success; exit 1 on HTTP 409 (head moved /
#                        server-side conflicts) or any other failure.
#   azure / file mode    exit 2 (unsupported), with a stderr note.
#   dry-run              prints the wire shape, exit 0, no network call.
#
# Adapter parity: the SAME logical fixture (head SHA + a PUT response or a
# 409) must produce identical stdout and exit code on the gh-based adapter
# (_github) and the REST-based adapter (_github_api), per the
# test-adapter-body-parity.sh contract (#177).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
REPO_SLUG="acme/widget"
TEST_TOKEN="test-secret-token-mergesync"
export TALOS_RETRY_SLEEP_SCALE=0

use_github() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "github", "repo": "$REPO_SLUG"}}
CFG
  unset GITHUB_TOKEN GH_TOKEN
}

use_github_api() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "github-api", "repo": "$REPO_SLUG"}}
CFG
  export GITHUB_TOKEN="$TEST_TOKEN"
}

use_azure() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "azure", "repo": "$REPO_SLUG"}, "vcs.azure": {"org_url": "https://dev.azure.com/acme", "project": "widget", "work_item_type": "Work.Item"}}
CFG
}

use_file() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "file", "repo": "$REPO_SLUG"}, "vcs.file": {"source": {"path": "plan.md"}}}
CFG
}

reset_stubs() {
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  unset STUB_UPDATE_BRANCH_FAIL
}

# ── (a) gh adapter: success → exit 0, PUT hit the update-branch endpoint ────
reset_stubs
use_github
out="$(bash "$VCS" update-branch 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "mergesync: gh update-branch exits 0 on success"
assert_contains "$out" "updated with its base" "mergesync: gh reports success"
# The gh stub logs the invocation; the PUT endpoint must have been hit.
assert_contains "$(cat "$GH_LOG")" "update-branch" "mergesync: gh PUT reached the update-branch endpoint"
assert_contains "$(cat "$GH_LOG")" "expected_head_sha" "mergesync: gh PUT carries expected_head_sha"

# ── (b) gh adapter: 409 → exit 1 ────────────────────────────────────────────
reset_stubs
use_github
export STUB_UPDATE_BRANCH_FAIL=1
out="$(bash "$VCS" update-branch 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "mergesync: gh update-branch exits 1 on 409"
assert_contains "$out" "refused" "mergesync: gh names the refusal"

# ── (c) github-api adapter: success, byte-identical behavior ────────────────
reset_stubs
use_github_api
# REST path: GET pulls/9 (head sha) then PUT pulls/9/update-branch.
printf '%s\n' '{"number":9,"head":{"sha":"abc123sha"}}' > "$CURL_QUEUE"
out_api="$(bash "$VCS" update-branch 9 2>&1)"; rc_api=$?
curl_log_api="$(cat "$CURL_LOG")"
reset_stubs
use_github
out_gh="$(bash "$VCS" update-branch 9 2>&1)"; rc_gh=$?
# Direct parity assertion (stdout + rc).
assert_eq "$out_gh" "$out_api" "mergesync: success stdout identical across adapters"
assert_eq "$rc_gh" "$rc_api" "mergesync: success exit code identical across adapters"
# And the REST call actually PUT the endpoint with the sha from the GET.
assert_contains "$curl_log_api" "pulls/9/update-branch" "mergesync: REST PUT hit update-branch"
assert_contains "$curl_log_api" "abc123sha" "mergesync: REST PUT carried expected_head_sha"

# ── (d) github-api adapter: 409 → exit 1, parity with gh ────────────────────
reset_stubs
use_github_api
printf '%s\n' '{"number":9,"head":{"sha":"abc123sha"}}' > "$CURL_QUEUE"
printf '%s\n' '409' > "$CURL_QUEUE"
out_api="$(bash "$VCS" update-branch 9 2>/dev/null)"; rc_api=$?
reset_stubs
use_github
export STUB_UPDATE_BRANCH_FAIL=1
out_gh="$(bash "$VCS" update-branch 9 2>/dev/null)"; rc_gh=$?
assert_eq "$rc_gh" "$rc_api" "mergesync: 409 exit code identical across adapters"

# ── (e) azure: exit 2, stderr note ──────────────────────────────────────────
reset_stubs
use_azure
out="$(bash "$VCS" update-branch 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "mergesync: azure update-branch exits 2 (unsupported)"
assert_contains "$out" "not implemented for azure" "mergesync: azure names the gap"

# ── (f) file mode: exit 2 ───────────────────────────────────────────────────
reset_stubs
use_file
out="$(bash "$VCS" update-branch 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "mergesync: file mode update-branch exits 2"

# ── (g) dry-run: prints the wire shape, no side effects ─────────────────────
reset_stubs
use_github
out="$(bash "$VCS" --dry-run update-branch 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "mergesync: dry-run exits 0"
assert_contains "$out" "[dry-run]" "mergesync: dry-run is labeled"
assert_not_contains "$(cat "$GH_LOG")" "update-branch" "mergesync: dry-run makes no real call"

finish