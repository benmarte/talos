#!/usr/bin/env bash
# test-gitlab-pr-checks-fallback.sh -- gitlab pr-checks-required judges the MR's
# head pipeline when merge.required_checks is empty, and the named jobs of that
# pipeline when it is not (#737, part 3 of #687). Before this it was a stub that
# always exited 1, so the merge gate could never pass on gitlab. Uses the
# tests/stubs/glab stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git
HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"

_config() {  # $1 = the merge.required_checks JSON list
  printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "merge": {"required_checks": %s}}\n' "$1" > talos.pipeline.json
}
# The MR read: $1 = head pipeline status ("" = head_pipeline null), $2 = the
# pipeline's sha ("-" = no sha field).
_mr() {
  local pipe="null"
  if [ -n "$1" ]; then
    pipe="{\"id\":501,\"status\":\"$1\""
    [ "$2" != "-" ] && pipe="$pipe,\"sha\":\"$2\""
    pipe="$pipe}"
  fi
  printf '{"iid":9,"sha":"%s","head_pipeline":%s}' "$HEAD_SHA" "$pipe"
}
_job() { printf '{"id":%s,"name":"%s","status":"%s"}' "$1" "$2" "$3"; }
_empty() { STUB_GITLAB_MR_API="$1" bash "$VCS" pr-checks-required 9 2>&1; }
_named() { STUB_GITLAB_MR_API="$(_mr running "$HEAD_SHA")" STUB_GITLAB_PIPELINE_JOBS="$1" bash "$VCS" pr-checks-required 9 2>&1; }

# ── empty merge.required_checks: the head pipeline stands in ─────────────────
_config '[]'
out="$(_empty "$(_mr success "$HEAD_SHA")")"; rc=$?
assert_eq "0" "$rc" "AC1 a successful head pipeline passes"
assert_contains "$out" "pr-checks-required: all required checks passed: " "AC1 prints the shared summary line"

out="$(_empty "$(_mr failed "$HEAD_SHA")")"; rc=$?
assert_eq "1" "$rc" "AC2 a failed head pipeline fails"
assert_contains "$out" "pr-checks-required: failed:" "AC2 prints the shared failed line"
assert_not_contains "$out" "merge.required_checks is empty" "AC2 is not the empty-list refusal"
out="$(_empty "$(_mr canceled "$HEAD_SHA")")"; rc=$?
assert_eq "1" "$rc" "AC2 a canceled head pipeline fails"

for st in running pending created; do
  out="$(_empty "$(_mr "$st" "$HEAD_SHA")")"; rc=$?
  assert_eq "2" "$rc" "AC3 a $st head pipeline is pending"
  assert_contains "$out" "pr-checks-required: pending or missing:" "AC3 $st prints the shared pending line"
done
for st in skipped manual; do
  out="$(_empty "$(_mr "$st" "$HEAD_SHA")")"; rc=$?
  assert_eq "2" "$rc" "AC3 a $st head pipeline is never a pass"
done
out="$(_empty "$(_mr bogus "$HEAD_SHA")")"; rc=$?
assert_eq "1" "$rc" "AC3 an unknown pipeline status fails"

out="$(_empty "$(_mr "" -)")"; rc=$?
assert_eq "2" "$rc" "AC4 an MR with a null head_pipeline is pending"
out="$(_empty "{\"iid\":9,\"sha\":\"$HEAD_SHA\"}")"; rc=$?
assert_eq "2" "$rc" "AC4 an MR with no head_pipeline field is pending"

out="$(_empty "$(_mr success "$OLD_SHA")")"; rc=$?
assert_eq "2" "$rc" "AC5 a successful pipeline for an older commit is pending"
out="$(_empty "$(_mr success -)")"; rc=$?
assert_eq "0" "$rc" "AC5 a head pipeline with no sha is judged on its status alone"

# ── named checks: the head pipeline's jobs ───────────────────────────────────
_config '["build", "test"]'
out="$(_named "[$(_job 1 build success),$(_job 2 test success),$(_job 3 lint failed)]")"; rc=$?
assert_eq "0" "$rc" "AC6 every named job successful passes, the running pipeline status is not consulted"
assert_contains "$out" "pr-checks-required: all required checks passed: build, test" "AC6 prints the shared summary line"

out="$(_named "[$(_job 1 build failed),$(_job 2 test running)]")"; rc=$?
assert_eq "1" "$rc" "AC7 a failed named job fails even beside a running one"
assert_contains "$out" "pr-checks-required: failed: build" "AC7 names the failed job"
out="$(_named "[$(_job 1 build success),$(_job 2 test pending)]")"; rc=$?
assert_eq "2" "$rc" "AC7 a pending named job is pending"
out="$(_named "[$(_job 1 build success)]")"; rc=$?
assert_eq "2" "$rc" "AC7 a named job absent from the pipeline is pending"
assert_contains "$out" "pr-checks-required: pending or missing: test" "AC7 names the absent job"
out="$(_named "[$(_job 1 build success),$(_job 2 test success),$(_job 3 deploy failed)]")"; rc=$?
assert_eq "0" "$rc" "AC7 a failed job that is not named is ignored"

out="$(_named "[$(_job 1 build failed),$(_job 4 build success),$(_job 2 test success)]")"; rc=$?
assert_eq "0" "$rc" "AC8 a retried job is decided by its highest id (passed retry)"
out="$(_named "[$(_job 7 build success),$(_job 4 build failed),$(_job 2 test success)]")"; rc=$?
assert_eq "0" "$rc" "AC8 the highest id decides whatever the list order"
out="$(_named "[$(_job 9 build failed),$(_job 4 build success),$(_job 2 test success)]")"; rc=$?
assert_eq "1" "$rc" "AC8 a failed latest retry fails"
out="$(_named "[$(_job 1 Build success),$(_job 2 build-all success),$(_job 3 test success)]")"; rc=$?
assert_eq "2" "$rc" "AC8 names match exactly"

out="$(STUB_GITLAB_MR_API="$(_mr "" -)" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "AC9 named checks and no head pipeline is pending"
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_API="$(_mr running "$HEAD_SHA")" STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success)][$(_job 2 test success)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC9 the jobs of every page count"
assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fwidget/pipelines/501/jobs" "AC9 reads the jobs with --paginate"

# ── failures read or parse ───────────────────────────────────────────────────
for cfgs in '[]' '["build"]'; do
  _config "$cfgs"
  out="$(STUB_GITLAB_API_FAIL=1 STUB_GITLAB_MR_API="$(_mr success "$HEAD_SHA")" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC10 a failed MR read exits 1 ($cfgs)"
  assert_contains "$out" "pipeline-vcs: pr-checks-required:" "AC10 a failed MR read says so ($cfgs)"
  out="$(STUB_GITLAB_MR_API='not json' bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC10 unparseable MR JSON exits 1 ($cfgs)"
  assert_contains "$out" "pipeline-vcs: pr-checks-required:" "AC10 unparseable MR JSON says so ($cfgs)"
done
_config '["build"]'
out="$(STUB_GITLAB_JOBS_FAIL=1 STUB_GITLAB_MR_API="$(_mr running "$HEAD_SHA")" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC10 a failed jobs read exits 1"
assert_contains "$out" "pipeline-vcs: pr-checks-required:" "AC10 a failed jobs read says so"
out="$(_named 'not json')"; rc=$?
assert_eq "1" "$rc" "AC10 unparseable jobs JSON exits 1"
assert_contains "$out" "pipeline-vcs: pr-checks-required:" "AC10 unparseable jobs JSON says so"

out="$(bash "$VCS" pr-checks-required 'x;1' 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC10 a non-numeric MR iid exits 1"
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC10 --dry-run exits 0"
assert_contains "$out" "[dry-run]" "AC10 --dry-run prints a [dry-run] line"
assert_eq "0" "$(grep -c '^GLAB' "$GH_LOG")" "AC10 --dry-run makes no glab call"

# ── an unresolvable pipeline still fails closed (test-vcs.sh keeps the same) ──
_config '[]'
out="$(bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC12 an MR read that resolves no pipeline still exits 1"

# ── --wait answers once on gitlab ────────────────────────────────────────────
_config '[]'
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_API="$(_mr running "$HEAD_SHA")" bash "$VCS" pr-checks-required 9 --wait 60 2>&1)"; rc=$?
assert_eq "1" "$(grep -c 'merge_requests/9$' "$GH_LOG" | awk '{print ($1 <= 1) ? 1 : 0}')" "AC11 --wait on gitlab reads the MR at most once (no polling)"

finish
