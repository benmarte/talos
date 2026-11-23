#!/usr/bin/env bash
# test-qa-gate-no-ci-wait.sh -- under pr.ready_gate: qa-local the driver's CI wait
# (#991) must not run before QA on a draft PR: QA runs on the draft on purpose
# and CI skips drafts, so the wait could only end `ci-pending` (#1007). AC ids
# are the spec's.
#   AC1 pr.draft + ready_gate qa-local + qa_mode ci + a draft PR: QA is
#       dispatched with no pr-checks-required call and no `wait reason=ci` line
#   AC2 in the same setup a pending CI does not end the run with `reason=ci-pending`
#   AC3 (same: without the gate the driver still waits for CI before QA)
#       ready_gate off, qa_mode ci: exactly one pr-checks-required <pr> --wait
#       call before QA
# AC4 is prose (the CHANGELOG).
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

GW_HEAD="$(printf '%040d' 12)"
GW_QA='{"prs": [{"n": 12, "issue": 9, "head": "'"$GW_HEAD"'", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'
GW_DONE='{"prs": [{"n": 12, "issue": 9, "head": "'"$GW_HEAD"'", "owner": false, "stage": "human-merge"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'

# gw_fixture <ready_gate> <pr-is-draft answer> <rc>: PR 12 (issue 9) at the QA stage.
gw_fixture() {
  local _gate="$1" _ans="$2" _rc="$3"
  reset_stubs; LEASE_RESET
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "ci": {"parallel_with_qa": false}, "merge": {"required_checks": ["test (ubuntu-latest)"]}, "pr": {"draft": true, "ready_gate": "'"$_gate"'"}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}}'
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '%s' "$GW_QA" > "$STUB_DIR/collect.json"
  printf '%s' "$GW_DONE" > "$STUB_DIR/collect.after"
  printf 'PASS: criteria met\n' > "$STUB_DIR/message"
  printf '%s' "$_ans" > "$STUB_DIR/pr-is-draft.12"
  printf '%s' "$_rc" > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'cp "$d/collect.after" "$d/collect.json"\n' > "$STUB_DIR/hook.qa.1"
}
gw_run() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3; }
gw_count() { journal | grep -c "$1"; }
gw_order() { grep -E '^vcs pr-checks-required 12|^agent qa$' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# AC1: under the gate, a draft PR goes straight to QA.
gw_fixture qa-local draft 0
gw_run
assert_eq "1" "$(gw_count '^agent qa$')" "AC1 QA is dispatched on the draft under the gate"
assert_eq "0" "$(gw_count 'pr-checks-required')" "AC1 no pr-checks-required call before QA"
assert_not_contains "$OUT" "wait reason=ci" "AC1 no wait reason=ci line"

# AC2: a pending CI does not end the run, because nothing waits on it.
gw_fixture qa-local draft 0
printf 2 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'pr-checks-required: pending or missing: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
gw_run
assert_not_contains "$OUT" "reason=ci-pending" "AC2 a pending CI does not end the run with reason=ci-pending"
assert_eq "1" "$(gw_count '^agent qa$')" "AC2 QA is dispatched although CI is pending"

# AC3 (same): without the gate the driver still waits once before QA.
gw_fixture off ready 1
gw_run
assert_eq "1" "$(gw_count '^vcs pr-checks-required 12 --wait')" "AC3 ready_gate off makes exactly one pr-checks-required --wait call"
assert_eq "vcs pr-checks-required 12 --wait 900>agent qa" "$(gw_order)" "AC3 the wait comes before QA"

finish
