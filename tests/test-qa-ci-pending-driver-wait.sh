#!/usr/bin/env bash
# test-qa-ci-pending-driver-wait.sh -- under ci.parallel_with_qa a QA FAIL whose
# only reason is a required check still pending at QA's capped wait is a wait,
# not a defect (#1028). The marker is structural: the verdict line is
# `FAIL: ci-pending ...`. AC ids are the spec's.
#   AC1 a ci-pending QA FAIL: the driver waits on pr-checks-required (the
#       driver's budget, verify.ci_wait_s) and re-dispatches QA; no developer
#   AC2 the wait ends red (exit 1): QA is re-dispatched, reports the red check,
#       and the run routes to the developer fix round
#   AC3 the wait still pending at its budget (exit 2): stop
#       `action=wait reason=ci-pending`, the lease released
#   AC4 a QA FAIL without the marker (even one that mentions ci-pending in
#       prose) routes to the developer as today
#   AC5 (same: a QA FAIL for a failed acceptance criterion still dispatches the
#       developer)
#   AC7 a ci-pending QA FAIL records no attempt (no record-attempt, no
#       draft conversion, no qa:pass drop)
# AC6 is prose (docs/reference.md, agents/qa.md, the CHANGELOG).
# The fixture is tests/talos-run-sections.sh, as tests/test-qa-ci-wait-driver.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

CP_COLLECT='{"prs": [{"n": 12, "issue": 9, "head": "a4f9", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'
CP_PENDING='FAIL: ci-pending required check test (ubuntu-latest) was still pending at the 570 s CI wait budget'

# cp_fixture: PR 12 (issue 9) at the QA stage, ci.parallel_with_qa on, PR ready.
cp_fixture() {
  reset_stubs; LEASE_RESET
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "ci": {"parallel_with_qa": true}, "merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}}'
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "- [ ] AC1 the suite is green (prose: fixture)", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '%s' "$CP_COLLECT" > "$STUB_DIR/collect.json"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'https://github.com/acme/widget/pull/12\nfixed it\n' > "$STUB_DIR/message.developer"
  printf 'PASS: criteria met\n' > "$STUB_DIR/message.qa.2"
}
cp_run() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1; }
cp_count() { journal | grep -c "$1"; }
cp_order() { grep -E '^vcs pr-checks-required 12 --wait|^agent qa$|^agent developer$' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# AC1: a ci-pending QA FAIL is a wait: the driver waits, then QA runs again.
cp_fixture
printf '%s\n' "$CP_PENDING" > "$STUB_DIR/message.qa.1"
cp_run
assert_eq "0" "$RC" "AC1 the run exits 0"
assert_eq "agent qa>vcs pr-checks-required 12 --wait 900>agent qa" "$(cp_order)" "AC1 QA, the driver's wait on pr-checks-required, then QA again"
assert_eq "0" "$(cp_count '^agent developer$')" "AC1 no developer stage is dispatched"
assert_contains "$OUT" "wait reason=ci pr=12 issue=9" "AC1 the driver prints a wait reason=ci line while it waits"

# AC7: nothing of a defect is recorded for the ci-pending FAIL.
assert_eq "0" "$(cp_count 'record-attempt')" "AC7 a ci-pending QA FAIL records no QA attempt"
assert_not_contains "$(journal)" "vcs draft-pr 12" "AC7 the PR is not converted back to a draft"
assert_not_contains "$(journal)" "label-pr 12 --remove qa:pass" "AC7 qa:pass is not dropped"

# AC2: the wait ends red; QA reports it and the run goes the normal route.
cp_fixture
printf '%s\n' "$CP_PENDING" > "$STUB_DIR/message.qa.1"
printf 1 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'pr-checks-required: failed: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
printf 'FAIL: required check test (ubuntu-latest) failed\n' > "$STUB_DIR/message.qa.2"
cp_run
assert_eq "0" "$RC" "AC2 the run exits 0"
assert_eq "agent qa>vcs pr-checks-required 12 --wait 900>agent qa>agent developer" "$(cp_order)" "AC2 a red wait: QA reports it, then the developer fix round"
assert_contains "$(journal)" "vcs record-attempt 9 qa --pr 12" "AC2 the red QA FAIL counts as an attempt, as for any QA FAIL"

# AC3: still pending at the driver's budget: a wait, the lease released.
cp_fixture
printf '%s\n' "$CP_PENDING" > "$STUB_DIR/message.qa.1"
printf 2 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'pr-checks-required: pending or missing: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
cp_run
assert_eq "0" "$RC" "AC3 the run exits 0"
assert_contains "$OUT" "wait reason=ci-pending pr=12 issue=9" "AC3 the run ends with wait reason=ci-pending"
assert_eq "agent qa>vcs pr-checks-required 12 --wait 900" "$(cp_order)" "AC3 no second QA and no developer"
assert_not_contains "$(journal)" "pipeline:blocked" "AC3 nothing is labelled pipeline:blocked"
assert_eq "0" "$(cp_count 'record-attempt')" "AC3 no attempt is recorded"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=9 " "AC3 the lease is released for the next run"

# AC4: a QA FAIL without the marker routes to the developer as today, even when
# its prose says ci-pending.
cp_fixture
printf 'FAIL: the ci-pending wording in docs/reference.md is wrong\n' > "$STUB_DIR/message.qa.1"
cp_run
assert_eq "agent qa>agent developer" "$(cp_order)" "AC4 an unmarked QA FAIL dispatches the developer, no CI wait"
assert_contains "$(journal)" "vcs record-attempt 9 qa --pr 12" "AC4 the unmarked FAIL records its attempt"
assert_contains "$(journal)" "vcs draft-pr 12" "AC4 the unmarked FAIL converts the PR back as today"

# AC5 (same): QA verdicts that are not ci-pending are unchanged.
cp_fixture
printf 'FAIL: AC1 the suite is not green\n' > "$STUB_DIR/message.qa.1"
cp_run
assert_eq "1" "$(cp_count '^agent developer$')" "AC5 a QA FAIL for a failed acceptance criterion still dispatches the developer"
assert_eq "0" "$(cp_count 'pr-checks-required 12 --wait')" "AC5 and no driver CI wait runs for it"

finish
