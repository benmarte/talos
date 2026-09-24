#!/usr/bin/env bash
# test-azure-pr-checks.sh -- the azure adapter's pr-checks-required (#318,
# #328). Before #318 it was a stub that always exited 1, so Step 4 saw CI as
# failing on every pass (and called rerun-ci), and QA under qa_mode: ci never
# saw green. It reads the PR's policy evaluations and maps each
# merge.required_checks name to one by display name. Since #328 it reads them
# through the REST endpoint with includeNotApplicable=true (`az repos pr
# policy list` omits policies that do not apply to the PR, so a path-filtered
# required check read as missing), and an approved evaluation that is
# expired or names an older source commit is pending, never passed.
# Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "merge": {"required_checks": ["CI build", "Minimum number of reviewers"]}}
EOF

PROJ="6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c"
HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"
# PR #9 as `az repos pr show` returns it: the project id for the artifact id,
# and the PR's current source commit.
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"status\":\"active\",\"repository\":{\"id\":\"r1\",\"project\":{\"id\":\"$PROJ\"}},\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD_SHA\"}}"

# One policy evaluation record: $1 = settings.displayName ("" = none),
# $2 = type.displayName, $3 = status, $4 = context JSON (optional).
_rec() {
  local settings='{}' ctx=""
  [ -n "$1" ] && settings="{\"displayName\":\"$1\"}"
  [ -n "${4:-}" ] && ctx=",\"context\":$4"
  printf '{"configuration":{"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"%s"},"settings":%s},"status":"%s","evaluationId":"00000001-0000-0000-0000-000000000000"%s}' \
    "$2" "$settings" "$3" "$ctx"
}
_reviewers() { printf '{"configuration":{"type":{"displayName":"Minimum number of reviewers"}},"status":"%s"}' "$1"; }
# The REST response body: {"count": n, "value": [records...]}.
_evals() { printf '{"count":0,"value":[%s]}' "$1"; }

# ── approved ──────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "ci BUILD" Build approved),$(_reviewers approved),$(_rec "lint" Build rejected)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "approved: exits 0 when every required evaluation is approved, ignoring a non-required rejection"
assert_contains "$out" "pr-checks-required: all required checks passed: CI build, Minimum number of reviewers" \
  "approved: prints github's summary line"
assert_contains "$(cat "$GH_LOG")" "[repos] [pr] [show] [--id] [9]" \
  "approved: reads the PR for its project id"
assert_contains "$(cat "$GH_LOG")" "[--url] [https://dev.azure.com/acme/$PROJ/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2F$PROJ%2F9&includeNotApplicable=true&\$top=1000&api-version=7.1-preview.1]" \
  "approved: reads the PR's policy evaluations over REST, including not-applicable ones"
assert_not_contains "$(cat "$GH_LOG")" "[policy] [list]" "approved: no longer uses az repos pr policy list"

out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "" "CI Build" approved),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "approved: falls back to type.displayName when settings.displayName is absent"

# ── notApplicable (#328) ──────────────────────────────────────────────────────
# A path-filtered build policy that does not apply to this PR only appears
# with includeNotApplicable=true; it passes.
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build notApplicable),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "notApplicable: a required check whose policy does not apply to the PR passes"
assert_contains "$out" "all required checks passed: CI build, Minimum number of reviewers" \
  "notApplicable: counts it among the passed checks"

# ── expired or stale approvals are pending (#328) ─────────────────────────────
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved '{"isExpired":true}'),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "expired: an approved evaluation with context.isExpired is pending, never passed"
assert_contains "$out" "pending or missing: CI build" "expired: names the expired check"

# Context strings are built outside the nested $(...): an escaped quote in
# there does not survive, and bash brace-expands the unquoted JSON.
_ctx_old="{\"isExpired\":false,\"lastMergeSourceCommitId\":\"$OLD_SHA\"}"
_ctx_head="{\"isExpired\":false,\"lastMergeSourceCommitId\":\"$HEAD_SHA\"}"
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved "$_ctx_old"),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "stale: an approved evaluation for an older source commit is pending, never passed"
assert_contains "$out" "pending or missing: CI build" "stale: names the stale check"

out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved "$_ctx_head"),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "current: an approved evaluation for the PR's current source commit passes"

out="$(STUB_AZURE_PR_9='{"pullRequestId":9,"repository":{"project":{"id":"'"$PROJ"'"}}}' \
  STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved "$_ctx_head"),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "stale: an approval naming a source commit is pending when the PR's own source commit is unknown"

out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build rejected '{"isExpired":true}'),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "expired: an expired rejection still fails"

# ── rejected / broken ─────────────────────────────────────────────────────────
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build rejected),$(_reviewers running)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "rejected: exits 1 when a required evaluation is rejected, even while another runs"
assert_contains "$out" "pr-checks-required: failed: CI build" "rejected: names the failed check"

STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved),$(_reviewers broken)")" \
  bash "$VCS" pr-checks-required 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "broken: exits 1 when a required evaluation is broken"

# ── running / queued ──────────────────────────────────────────────────────────
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build running),$(_reviewers queued)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "running: exits 2 while a required evaluation is running or queued"
assert_contains "$out" "pr-checks-required: pending or missing: CI build, Minimum number of reviewers" \
  "running: names the pending checks"

# ── a required name that matches nothing ──────────────────────────────────────
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "missing: exits 2 when a required name matches no evaluation"
assert_contains "$out" "pending or missing: Minimum number of reviewers" "missing: names the absent check"

out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build notApplicable),$(_rec "lint" Build notApplicable)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "missing: a name with no evaluation is never passed, even when every other policy is notApplicable"

# ── fetch and parse failures fail closed ──────────────────────────────────────
out="$(STUB_AZURE_PR_EVALUATIONS_FAIL=1 bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "fetch failure: exits 1, never 0"
assert_contains "$out" "could not list the policies of PR #9" "fetch failure: says why"

out="$(STUB_AZURE_PR_EVALUATIONS='{"message":"TF401180"}' bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "parse failure: a response without a value list exits 1"
assert_contains "$out" "could not parse the policies of PR #9" "parse failure: says why"

out="$(STUB_AZURE_PR_EVALUATIONS='[]' bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "parse failure: a bare list (not the REST envelope) exits 1"

_full="$(python3 -c 'import json; print(json.dumps({"count": 1000, "value": [{"status": "approved"}] * 1000}))')"
out="$(STUB_AZURE_PR_EVALUATIONS="$_full" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "truncation: a full \$top=1000 page may be truncated and exits 1"

: > "$GH_LOG"
out="$(STUB_AZURE_PR_SHOW_FAIL=1 STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "PR read failure: exits 1, never 0"
assert_not_contains "$(cat "$GH_LOG")" "policy/evaluations" "PR read failure: never builds the REST path"

: > "$GH_LOG"
out="$(STUB_AZURE_PR_9='{"pullRequestId":9,"repository":{"project":{"id":"../../x"}}}' \
  STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved),$(_reviewers approved)")" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "bad project id: a project id that is not a GUID exits 1"
assert_not_contains "$(cat "$GH_LOG")" "policy/evaluations" "bad project id: never builds the REST path"

# ── invalid PR id ─────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" pr-checks-required '9/../x' 2>&1)"; rc=$?
assert_eq "1" "$rc" "invalid id: a non-numeric PR id exits 1"
assert_not_contains "$(cat "$GH_LOG")" "policy" "invalid id: never reaches az"
assert_not_contains "$(cat "$GH_LOG")" "[show]" "invalid id: never reads the PR"

# ── rerun-ci is unchanged (#328) ──────────────────────────────────────────────
# rerun-ci keeps `az repos pr policy list`: the new REST fetch (and its
# notApplicable records) never changes the set it re-queues.
_e() { printf '%08d-0000-0000-0000-000000000000' "$1"; }
_b() { printf '{"configuration":{"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"Build"}},"status":"%s","evaluationId":"%s"}' "$1" "$(_e "$2")"; }
: > "$GH_LOG"
out="$(STUB_AZURE_PR_POLICIES="[$(_b rejected 1),$(_b approved 2)]" \
  STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_b rejected 1),$(_b approved 2),$(_b notApplicable 3),$(_b broken 4)")" \
  bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "rerun-ci: still exits 0 after re-queuing"
assert_contains "$(cat "$GH_LOG")" "[repos] [pr] [policy] [list] [--id] [9]" "rerun-ci: still reads az repos pr policy list"
assert_not_contains "$(cat "$GH_LOG")" "policy/evaluations" "rerun-ci: never uses the REST evaluations fetch"
assert_contains "$(cat "$GH_LOG")" "[--evaluation-id] [$(_e 1)]" "rerun-ci: re-queues the rejected build from policy list"
assert_not_contains "$(cat "$GH_LOG")" "[--evaluation-id] [$(_e 4)]" "rerun-ci: ignores records only the REST fetch returns"
assert_contains "$out" "re-queued 1 failed build policy evaluation(s) for PR #9" "rerun-ci: same re-queued count as on main"

# ── empty merge.required_checks: same as github ───────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
: > "$GH_LOG"
out="$(STUB_AZURE_PR_EVALUATIONS="$(_evals "$(_rec "CI build" Build approved)")" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "empty required_checks: exits 1, never a vacuous pass"
assert_contains "$out" "merge.required_checks is empty" "empty required_checks: prints github's message"
assert_not_contains "$(cat "$GH_LOG")" "policy" "empty required_checks: needs no policy fetch"

finish
