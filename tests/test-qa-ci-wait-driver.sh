#!/usr/bin/env bash
# test-qa-ci-wait-driver.sh -- QA's CI wait is B, and under verify.qa_mode: ci the
# run driver waits for CI in code before it dispatches QA (#991). AC ids are the
# spec's.
#   AC1 the rendered QA prompt says `CI wait budget: 570 seconds` and its wait
#       command uses `--wait 570` (ci_wait_s 900, timeout_ms 600000)
#   AC2 a required check that is pending and then green is waited on in code; QA
#       is dispatched only after it is green
#   AC3 a check still pending at verify.ci_wait_s ends the run with
#       `wait reason=ci-pending`, exit 0, no QA, no pipeline:blocked, no attempt
#   AC4 a red required check still dispatches QA
#   AC5 (same: under qa_mode local nothing waits on CI before QA)
# AC6 is prose (docs/reference.md and the CHANGELOG).
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=0
# TALOS_RUN_EMBED=1, as tests/test-preqa-union-sync.sh does); the run drives the
# stubbed vcs verbs, and the journal is the order pin.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

CW_HEAD="$(printf '%040d' 12)"
CW_QA='{"prs": [{"n": 12, "issue": 9, "head": "'"$CW_HEAD"'", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'
CW_DONE='{"prs": [{"n": 12, "issue": 9, "head": "'"$CW_HEAD"'", "owner": false, "stage": "human-merge"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'

# cw_fixture <qa_mode> [<ci_wait_s>]: PR 12 (issue 9) at the QA stage, CI not in parallel.
cw_fixture() {
  reset_stubs; LEASE_RESET
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "ci": {"parallel_with_qa": false}, "merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "'"$1"'", "timeout_ms": 600000, "ci_wait_s": '"${2:-900}"'}}'
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '%s' "$CW_QA" > "$STUB_DIR/collect.json"
  printf '%s' "$CW_DONE" > "$STUB_DIR/collect.after"
  printf 'PASS: criteria met\n' > "$STUB_DIR/message"
  printf 'cp "$d/collect.after" "$d/collect.json"\n' > "$STUB_DIR/hook.qa.1"
}
cw_run() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3; }
cw_count() { journal | grep -c "$1"; }
cw_order() { grep -E '^vcs pr-checks-required 12|^ci-green$|^agent qa$' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# AC1: the prompt's budget is B, the documented cap, not ci_wait_s.
cw_fixture ci
bash "$RUN" prompt qa --issue 9 --pr 12 > "$SANDBOX/prompt.out" 2> "$ERR"
_pf="$(sed -n 's/^prompt_file=//p' "$SANDBOX/prompt.out")"
if [ -n "$_pf" ]; then text="$(cat "$_pf")"; rm -f "${_pf:?}"; else text="$(cat "$SANDBOX/prompt.out")"; fi
assert_contains "$text" "CI wait budget: 570 seconds" "AC1 the rendered QA prompt says CI wait budget: 570 seconds"
assert_not_contains "$text" "CI wait budget: 900" "AC1 the prompt no longer carries ci_wait_s as the budget"
assert_contains "$text" "pr-checks-required 12 --wait 570" "AC1 the prompt's wait command uses --wait 570"
assert_not_contains "$text" "--wait <" "AC1 no placeholder is left in the wait command"

# AC2: a pending-then-green check is waited on in code; QA comes after it is green.
cw_fixture ci
cat > "$STUB_DIR/hook.pr-checks-required" <<'TALOS_hookW4nZq8Kd'
printf 'ci-pending\nci-green\n' >> "$d/journal"
TALOS_hookW4nZq8Kd
cw_run
assert_eq "0" "$RC" "AC2 the run exits 0"
assert_eq "1" "$(cw_count '^vcs pr-checks-required 12')" "AC2 the driver makes one CI wait before QA"
assert_contains "$(journal)" "vcs pr-checks-required 12 --wait 900" "AC2 the driver's wait budget is verify.ci_wait_s, not B"
assert_eq "vcs pr-checks-required 12 --wait 900>ci-green>agent qa" "$(cw_order)" "AC2 QA is dispatched only after the check is green"
assert_contains "$OUT" "wait reason=ci pr=12 issue=9" "AC2 the driver prints a wait reason=ci line while it waits"

# AC3: pending at ci_wait_s ends the run, with no QA, no blocked label, no attempt.
cw_fixture ci
printf 2 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'pr-checks-required: pending or missing: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
cw_run
assert_eq "0" "$RC" "AC3 a check pending at the budget ends the run with exit 0"
assert_contains "$OUT" "wait reason=ci-pending pr=12 issue=9" "AC3 the run ends with wait reason=ci-pending"
assert_eq "0" "$(cw_count '^agent qa$')" "AC3 no QA is dispatched"
assert_not_contains "$(journal)" "pipeline:blocked" "AC3 nothing is labelled pipeline:blocked"
assert_eq "0" "$(cw_count 'record-attempt')" "AC3 no attempt marker is recorded"
assert_eq "0" "$(cw_count 'hooks post_stage')" "AC3 no stage is completed, so no attempt counts"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=9 " "AC3 the lease is released for the next run"

# AC4: a red required check still dispatches QA, which reports it.
cw_fixture ci
printf 1 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'pr-checks-required: failed: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
cw_run
assert_eq "1" "$(cw_count '^agent qa$')" "AC4 a red required check still dispatches QA"
assert_not_contains "$OUT" "wait reason=ci-pending" "AC4 a red check is not a ci-pending wait"
assert_eq "vcs pr-checks-required 12 --wait 900>agent qa" "$(cw_order)" "AC4 the wait comes first, then QA"

# AC5 (same): under qa_mode local nothing waits on CI before QA.
cw_fixture local
cw_run
assert_eq "1" "$(cw_count '^agent qa$')" "AC5 qa_mode local dispatches QA"
assert_eq "0" "$(cw_count 'pr-checks-required')" "AC5 qa_mode local dispatches QA without a pr-checks-required call"

finish
