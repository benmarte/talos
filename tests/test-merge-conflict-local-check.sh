#!/usr/bin/env bash
# test-merge-conflict-local-check.sh -- a developer merge-conflict round is dispatched
# only after a local trial merge confirms the conflict (#1056). AC ids are the spec's.
#   AC1 GitHub says CONFLICTING but the head merges cleanly into the fetched base:
#       no developer, `wait reason=base-synced`, no attempt (merge gate and pre-QA)
#   AC2 the only conflict is CHANGELOG.md: pipeline-mergebase.sh syncs it at the merge
#       gate and the run answers `wait reason=base-synced`, no developer
#   AC3 a real conflict outside the union paths still gets the developer round
#   AC4 a MERGEABLE PR goes through the merge gate as before
# AC5 is prose (docs/reference.md and the CHANGELOG).
# The fixture is tests/talos-run-sections.sh (as tests/test-talos-run-merge-conflict-850.sh):
# the real run and gate drive stubbed vcs verbs; pipeline-mergebase.sh is a stub.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=1056 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

printf '%s' "$STUB_BODY" > "$GS/pipeline-mergebase.sh"
lc_fixture() {  # a PR at the merge gate, CONFLICTING as GitHub reads it, auto_sync off
  merge_fixture "$ALL_APPROVALS" ', "merge": {"auto_sync": false}'
  draft_ready
  printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"
  printf 1 > "$STUB_DIR/pr-mergeable.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nmerged the base\n' > "$STUB_DIR/message.developer"
}
lc_run() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations "${1:-3}"; }
lc_count() { journal | grep -c "$1"; }

# AC1 (merge gate): CONFLICTING by GitHub's field, clean by the local trial merge.
lc_fixture
: > "$STUB_DIR/conflict-files.out"
lc_run
assert_eq "0" "$RC" "AC1 a lazily CONFLICTING PR ends the run clean"
assert_contains "$OUT" "stop verdict=wait reason=base-synced" "AC1 the merge gate answers wait reason=base-synced"
assert_eq "0" "$(lc_count '^agent developer$')" "AC1 no developer dispatch"
assert_eq "0" "$(lc_count 'record-attempt')" "AC1 no attempt is recorded"
assert_eq "0" "$(lc_count '^mergebase ')" "AC1 a clean trial merge pushes nothing (mergebase not run)"
assert_not_contains "$(journal)" "merge-pr" "AC1 nothing is merged"

# AC1 (pre-QA): the same PR at the QA stage reaches neither QA nor the developer.
lc_head="$(printf '%040d' 12)"
reset_stubs; LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
printf '{"prs": [{"n": 12, "issue": 9, "head": "%s", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' "$lc_head" > "$STUB_DIR/collect.json"
printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"; printf 1 > "$STUB_DIR/pr-mergeable.rc"
: > "$STUB_DIR/conflict-files.out"
printf 'PASS: criteria met\n' > "$STUB_DIR/message"
lc_run
assert_contains "$OUT" "stop action=wait reason=base-synced pr=12 issue=9" "AC1 pre-QA: a clean trial merge answers wait reason=base-synced"
assert_eq "0" "$(lc_count '^agent ')" "AC1 pre-QA: no QA and no developer is dispatched"
assert_eq "0" "$(lc_count '^mergebase ')" "AC1 pre-QA: pipeline-mergebase.sh does not run on a clean merge"
assert_eq "0" "$(lc_count 'record-attempt')" "AC1 pre-QA: no attempt is recorded"

# AC2: a CHANGELOG.md-only conflict is synced mechanically at the merge gate.
lc_fixture
printf 'CHANGELOG.md\n' > "$STUB_DIR/conflict-files.out"
printf 0 > "$STUB_DIR/mergebase.rc"
lc_run
assert_contains "$OUT" "stop verdict=wait reason=base-synced" "AC2 a synced CHANGELOG.md conflict answers wait reason=base-synced"
assert_eq "1" "$(lc_count '^mergebase 12$')" "AC2 pipeline-mergebase.sh ran on PR 12"
assert_eq "0" "$(lc_count '^agent developer$')" "AC2 no developer dispatch"
assert_eq "0" "$(lc_count 'record-attempt')" "AC2 no attempt is recorded"

# AC3: a real conflict (a path outside the union paths) still gets the developer round.
lc_fixture
printf 'CHANGELOG.md\nscripts/talos.sh\n' > "$STUB_DIR/conflict-files.out"
printf 3 > "$STUB_DIR/mergebase.rc"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$STUB_DIR/pr-head.12.after"
printf 'cp "$d/pr-head.12.after" "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
lc_run 1
assert_eq "1" "$(lc_count '^agent developer$')" "AC3 a real conflict dispatches the developer once"
assert_eq "1" "$(lc_count 'record-attempt 9 developer --pr 12')" "AC3 the developer round records its attempt as today"

# AC4: a MERGEABLE PR goes through the merge gate as before.
lc_fixture
: > "$STUB_DIR/conflict-files.out"
printf 'MERGEABLE' > "$STUB_DIR/pr-mergeable.out"; printf 0 > "$STUB_DIR/pr-mergeable.rc"
lc_run
assert_contains "$(journal)" "merge-pr 12" "AC4 a MERGEABLE PR is merged"
assert_not_contains "$OUT" "base-synced" "AC4 no base-synced wait for a MERGEABLE PR"
assert_eq "0" "$(lc_count '^agent developer$')" "AC4 no developer dispatch"
finish
