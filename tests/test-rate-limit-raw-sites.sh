#!/usr/bin/env bash
# test-rate-limit-raw-sites.sh -- a GitHub rate limit (pipeline-vcs.sh /
# pipeline-status-file.sh exit 7) at the call sites that run a verb raw is a
# wait, not a failure (#1009). AC ids are the spec's.
#   AC1  merge-pr exiting 7 after the gate ends the run `wait reason=rate-limited`,
#        exit 0, with no merge-failed and no pipeline:blocked
#   AC2  the QA draft guard's collect exiting 7 ends the run `wait reason=rate-limited`,
#        not `stop reason=state-unavailable`
#   AC3  _talos_run_presync's second pr-mergeable exiting 7 ends the run
#        `wait reason=rate-limited` and does not emit base-synced
#   AC4  (same) a real merge failure (merge-pr exit 1) still stops merge-failed
# AC5 is prose (the CHANGELOG).
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=0
# TALOS_RUN_EMBED=1, as tests/test-preqa-union-sync.sh does): the real run and
# gate drive the stubbed vcs verbs.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

printf '%s' "$STUB_BODY" > "$GS/pipeline-mergebase.sh"
# The collect stub of the fixture, plus the stderr a rate-limited collect prints.
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusRl9Xq4Vt'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
if [ -f "$d/collect.err" ]; then cat "$d/collect.err" >&2; fi
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
if [ -f "$d/collect.rc" ]; then exit "$(cat "$d/collect.rc")"; fi
exit 0
TALOS_stubstatusRl9Xq4Vt

RL_LINE='rate-limited reset=12300'
rl_count() { journal | grep -c "$1"; }
rl_wait_line() { printf '%s\n' "$OUT" | grep -c '^stop action=wait reason=rate-limited retry_after_s=[0-9][0-9]*$'; }

# merge_rl_fixture: the merge arm with every approval fresh; the gate says merge.
merge_rl_fixture() {
  merge_fixture "$ALL_APPROVALS"
  draft_ready  # draft_cfg turns pr.draft on: the gate asks pr-is-draft, which says ready
}

# Control: a merge that works merges (the fixture reaches merge-pr).
merge_rl_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "1" "$(rl_count 'vcs merge-pr 12')" "control: the fixture reaches merge-pr"

# AC1: merge-pr exits 7 after the gate: a wait, never merge-failed or blocked.
merge_rl_fixture
printf '7' > "$STUB_DIR/merge-pr.rc"
printf '%s\n' "$RL_LINE" > "$STUB_DIR/merge-pr.err"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC1 merge-pr exit 7 ends the run with exit 0"
assert_eq "1" "$(rl_wait_line)" "AC1 the run ends on wait reason=rate-limited retry_after_s=<n>"
assert_eq "action=wait reason=rate-limited retry_after_s=300" "$(printf '%s\n' "$OUT" | grep '^stop ' | sed 's/^stop //')" "AC1 retry_after_s is the reset minus now"
assert_not_contains "$OUT$(cat "$ERR")" "merge-failed" "AC1 no merge-failed"
assert_not_contains "$OUT" "merged" "AC1 nothing is reported merged"
assert_not_contains "$(journal)" "pipeline:blocked" "AC1 no pipeline:blocked label"

# AC4 (same): a real merge failure still stops merge-failed.
merge_rl_fixture
printf '1' > "$STUB_DIR/merge-pr.rc"
printf 'pipeline-vcs: merge-pr: head moved\n' > "$STUB_DIR/merge-pr.err"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "1" "$RC" "AC4 merge-pr exit 1 still exits 1"
assert_eq "stop reason=merge-failed" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC4 merge-pr exit 1 still stops merge-failed"

# AC2: the draft guard's collect exits 7: a wait, not state-unavailable.
guard_fixture() {
  reset_stubs; LEASE_RESET
  draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
  draft_collect qa
  printf draft > "$STUB_DIR/pr-is-draft.12"
  printf 0 > "$STUB_DIR/pr-is-draft.12.rc"
  # The guard's pr-is-draft is the call right before its collect.
  printf 'printf 7 > "$d/collect.rc"; printf "%%s\\n" "%s" > "$d/collect.err"\n' "$RL_LINE" > "$STUB_DIR/hook.pr-is-draft"
}
guard_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC2 a rate-limited guard collect ends the run with exit 0"
assert_eq "1" "$(rl_wait_line)" "AC2 the run ends on wait reason=rate-limited retry_after_s=<n>"
assert_not_contains "$OUT" "state-unavailable" "AC2 not stop reason=state-unavailable"
assert_not_contains "$(journal)" "agent qa" "AC2 QA is not dispatched"

# AC3: presync's second pr-mergeable exits 7: a wait, never base-synced.
presync_fixture() {
  reset_stubs; LEASE_RESET
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '{"prs": [{"n": 12, "issue": 9, "head": "%040d", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' 12 > "$STUB_DIR/collect.json"
  printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"
  printf 1 > "$STUB_DIR/pr-mergeable.rc"
  printf 0 > "$STUB_DIR/mergebase.rc"
  # The mechanical sync pushes; the read after it meets the rate limit.
  printf 'printf 7 > "$d/pr-mergeable.rc"; printf "%%s\\n" "%s" > "$d/pr-mergeable.err"\n' "$RL_LINE" > "$STUB_DIR/hook.mergebase"
  printf 'PASS: criteria met\n' > "$STUB_DIR/message"
}
presync_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC3 a rate-limited presync read ends the run with exit 0"
assert_eq "1" "$(rl_wait_line)" "AC3 the run ends on wait reason=rate-limited retry_after_s=<n>"
assert_not_contains "$OUT" "base-synced" "AC3 base-synced is not emitted"
assert_eq "1" "$(rl_count '^mergebase 12$')" "AC3 the sync ran before the second read"
assert_not_contains "$(journal)" "agent qa" "AC3 QA is not dispatched"

# AC3 (same): the merge.auto_sync fallback, update-branch exiting 7, is a wait too,
# never a merge-conflict redispatch.
merge_rl_fixture
printf 'scripts/a.sh\n' > "$STUB_DIR/conflict-files.out"
printf 1 > "$STUB_DIR/mergebase.rc"
printf 7 > "$STUB_DIR/update-branch.rc"
printf '%s\n' "$RL_LINE" > "$STUB_DIR/update-branch.err"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC3 a rate-limited update-branch ends the run with exit 0"
assert_eq "stop verdict=wait reason=rate-limited retry_after_s=300" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC3 update-branch: the gate ends on verdict=wait reason=rate-limited"
assert_eq "1" "$(rl_count 'vcs update-branch 12')" "AC3 update-branch was tried"
assert_not_contains "$OUT" "merge-conflict" "AC3 update-branch: no merge-conflict redispatch"

finish
