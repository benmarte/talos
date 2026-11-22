#!/usr/bin/env bash
# test-preqa-union-sync.sh -- before a QA dispatch, `talos.sh run` runs the
# mechanical merge-base sync on a PR that conflicts with its base (#983). AC ids
# are the spec's.
#   AC1 a PR whose only conflict is a union path is synced before QA: the run
#       stops `wait reason=base-synced`, and no QA or developer is dispatched
#   AC2 that sync records no QA attempt (record-attempt, done)
#   AC3 a sync that exits 3 (or fails, or leaves the PR conflicting) keeps
#       today's path: QA is dispatched after the attempt
#   AC4 under merge.queue talos the sibling update-branch sync still does not run
#   AC5 `gate merge` on an approved PR with a stale base still runs
#       pipeline-mergebase.sh and answers `wait reason=base-synced`
# AC6 is prose (docs/reference.md and the CHANGELOG).
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=0
# TALOS_RUN_EMBED=1, as tests/test-talos-run-merge-conflict-850.sh does); the real
# run and gate drive the stubbed vcs verbs, and pipeline-mergebase.sh is a stub.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

printf '%s' "$STUB_BODY" > "$GS/pipeline-mergebase.sh"

PQ_HEAD="$(printf '%040d' 12)"
PQ_QA='{"prs": [{"n": 12, "issue": 9, "head": "'"$PQ_HEAD"'", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'
PQ_DONE='{"prs": [{"n": 12, "issue": 9, "head": "'"$PQ_HEAD"'", "owner": false, "stage": "human-merge"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'

# pq_fixture: PR 12 (issue 9) at the QA stage, CONFLICTING; $1 = extra config members.
pq_fixture() {
  reset_stubs; LEASE_RESET
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}'"${1:-}"'}'
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '%s' "$PQ_QA" > "$STUB_DIR/collect.json"
  printf '%s' "$PQ_DONE" > "$STUB_DIR/collect.after"
  printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"
  printf 1 > "$STUB_DIR/pr-mergeable.rc"
  printf 'CHANGELOG.md\n' > "$STUB_DIR/conflict-files.out"
  printf 'PASS: criteria met\n' > "$STUB_DIR/message"
  # QA's pass moves the collected state on, as in the #582 section.
  printf 'cp "$d/collect.after" "$d/collect.json"\n' > "$STUB_DIR/hook.qa.1"
}
pq_synced() {  # the mechanical sync pushes: the PR is mergeable afterwards
  printf '0' > "$STUB_DIR/mergebase.rc"
  cat > "$STUB_DIR/hook.mergebase" <<'TALOS_hookQ7mXv2Lp'
printf 0 > "$d/pr-mergeable.rc"; printf MERGEABLE > "$d/pr-mergeable.out"
TALOS_hookQ7mXv2Lp
}
pq_count() { journal | grep -c "$1"; }
pq_run() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 3; }

# AC1: a union-path-only conflict is synced before QA.
pq_fixture
pq_synced
pq_run
assert_eq "0" "$RC" "AC1 a pre-QA sync ends the run clean"
assert_contains "$OUT" "stop action=wait reason=base-synced pr=12 issue=9" "AC1 the run answers wait reason=base-synced"
assert_eq "1" "$(pq_count '^mergebase 12$')" "AC1 pipeline-mergebase.sh ran once on PR 12"
assert_eq "0" "$(pq_count '^agent qa$')" "AC1 no QA is dispatched"
assert_eq "0" "$(pq_count '^agent developer$')" "AC1 no developer is dispatched"

# AC2: no QA attempt is counted for the sync.
assert_eq "0" "$(pq_count 'record-attempt')" "AC2 the sync records no attempt"
assert_eq "0" "$(pq_count 'hooks post_stage')" "AC2 no stage is completed (no QA verdict, so nothing counts toward max_fix_attempts)"

# AC3: a non-union conflict (the sync exits 3) keeps today's path: QA is dispatched.
pq_fixture
printf 3 > "$STUB_DIR/mergebase.rc"
pq_run
assert_eq "1" "$(pq_count '^mergebase 12$')" "AC3 the sync is tried first"
assert_eq "1" "$(pq_count '^agent qa$')" "AC3 a sync that exits 3 still dispatches QA, as today"
assert_not_contains "$OUT" "reason=base-synced" "AC3 no base-synced answer"
assert_eq "mergebase 12>agent qa" "$(grep -E '^mergebase 12$|^agent qa$' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//')" "AC3 the sync comes before the QA dispatch"
# ... and so does a sync that fails, or one that leaves the PR conflicting.
pq_fixture
printf 1 > "$STUB_DIR/mergebase.rc"
pq_run
assert_eq "1" "$(pq_count '^agent qa$')" "AC3 a failed sync (exit 1) still dispatches QA"
pq_fixture
printf 0 > "$STUB_DIR/mergebase.rc"
pq_run
assert_eq "1" "$(pq_count '^agent qa$')" "AC3 a sync after which the PR still conflicts still dispatches QA"
assert_not_contains "$OUT" "reason=base-synced" "AC3 and does not answer base-synced"
# A mergeable PR is never synced.
pq_fixture
printf 0 > "$STUB_DIR/pr-mergeable.rc"; printf MERGEABLE > "$STUB_DIR/pr-mergeable.out"
pq_run
assert_eq "0" "$(pq_count '^mergebase ')" "AC3 control: a mergeable PR runs no sync"
assert_eq "1" "$(pq_count '^agent qa$')" "AC3 control: a mergeable PR dispatches QA"

# AC1/AC2 apply under every merge.queue value.
for q in talos github off; do
  pq_fixture ', "merge": {"queue": "'"$q"'"}'
  pq_synced
  pq_run
  assert_contains "$OUT" "reason=base-synced pr=12 issue=9" "AC1 merge.queue $q: the pre-QA sync answers base-synced"
  assert_eq "0" "$(pq_count '^agent qa$')" "AC1 merge.queue $q: no QA is dispatched"
done

# AC4: under merge.queue talos no sibling update-branch sync runs after a merge.
sib() {  # $1 = extra config members
  pq_fixture "${1:-}"
  export LIST_PRS='[{"number":10,"headRefName":"fix/issue-10-c","baseRefName":"main","labels":[{"name":"pipeline:review"}],"isCrossRepository":false}]'
  printf 'src/b.sh\n' > "$STUB_DIR/conflict-files.10.out"
  printf 3 > "$STUB_DIR/mergebase.rc"
  printf 0 > "$STUB_DIR/pr-mergeable.rc"; printf MERGEABLE > "$STUB_DIR/pr-mergeable.out"
  OUT="$(bash "$RUN" post-merge 12 9 2>"$ERR")"; RC=$?
  unset LIST_PRS
}
sib ', "merge": {"queue": "off"}'
assert_contains "$(journal)" "update-branch 10" "AC4 control: with no merge queue the sibling is synced by update-branch"
sib ', "merge": {"queue": "talos"}'
assert_not_contains "$(journal)" "update-branch" "AC4 merge.queue talos: no update-branch after a merge"
assert_not_contains "$(journal)" "mergebase 10" "AC4 merge.queue talos: no sibling mergebase either"

# AC5 (same: the merge gate's stale-base step is unchanged): gate merge syncs a stale base.
merge_fixture "$ALL_APPROVALS" ', "merge": {"auto_sync": false}'
draft_ready
printf 'CHANGELOG.md\n' > "$STUB_DIR/conflict-files.out"
printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"
printf 1 > "$STUB_DIR/pr-mergeable.rc"
pq_synced
GATE_OUT="$(bash "$RUN" gate merge 12 9 2>/dev/null)"
assert_contains "$GATE_OUT" "reason=base-synced" "AC5 gate merge on an approved PR with a stale base answers wait reason=base-synced"
assert_contains "$GATE_OUT" "verdict=wait" "AC5 gate merge answers a wait verdict"
assert_contains "$(journal)" "mergebase 12" "AC5 gate merge still runs pipeline-mergebase.sh"
finish
