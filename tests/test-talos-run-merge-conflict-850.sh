#!/usr/bin/env bash
# test-talos-run-merge-conflict-850.sh -- `talos.sh run` turns a merge gate's
# `redispatch reason=merge-conflict` into one developer merge-base fix round
# (#850). AC ids are the spec's.
#
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=850
# TALOS_RUN_EMBED=1, as tests/test-assign-pr-775.sh does): its sandbox, stubs,
# merge_fixture and ALL_APPROVALS. The real gate runs over the stubbed vcs
# verbs, as in part 3 of it; pipeline-mergebase.sh is stubbed here too.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=850 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

printf '%s' "$STUB_BODY" > "$GS/pipeline-mergebase.sh"
mc850_fixture() {  # merge.auto_sync is off, as in the bug report
  merge_fixture "$ALL_APPROVALS" ', "merge": {"auto_sync": false}'
  printf 'CHANGELOG.md\nscripts/talos.sh\n' > "$STUB_DIR/conflict-files.out"
  draft_ready  # draft_cfg turns pr.draft on: the gate asks pr-is-draft, which says ready
  printf 3 > "$STUB_DIR/mergebase.rc"
  printf 'CONFLICTING' > "$STUB_DIR/pr-mergeable.out"
  printf 1 > "$STUB_DIR/pr-mergeable.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nmerged the base\n' > "$STUB_DIR/message.developer"
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
cp "$d/agent.stdin" "$d/developer.prompt"
HOOK
}
mc850_push() {  # the fix round pushes a new head
  cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
}
mc850_order() { grep -oE 'vcs record-attempt 9 developer --pr 12|agent developer' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }
mc850_count() { journal | grep -c "$1"; }
mc850_stop() { printf '%s\n' "$OUT" | grep '^stop '; }

# AC1, AC2: a conflict with every approval fresh dispatches the developer once,
# through gate fix-round (record-attempt) first.
mc850_fixture
mc850_push
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "AC1 a merge-conflict redispatch: the run exits 0"
assert_eq "1" "$(mc850_count '^agent developer$')" "AC1 the developer is dispatched once in the same run"
assert_not_contains "$OUT" "reason=merge-conflict" "AC1 the run does not end on stop verdict=redispatch reason=merge-conflict"
assert_not_contains "$(journal)" "merge-pr" "AC1 nothing is merged"
MC_PROMPT="$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)"
assert_contains "$MC_PROMPT" "Fix round: PR #12 is already open" "AC1 the developer got the fix-round shape of the prompt"
assert_contains "$MC_PROMPT" "conflicts with the base" "AC1 the prior stage summary says the PR conflicts with the base"
assert_contains "$MC_PROMPT" "scripts/talos.sh" "AC1 the prior stage summary names a conflicting path"
assert_eq "vcs record-attempt 9 developer --pr 12>agent developer" "$(mc850_order)" \
  "AC2 gate fix-round records the developer attempt on the PR before the dispatch"

# AC2: the attempt ceiling still applies: no developer past it.
mc850_fixture
printf 'pipeline-vcs: record-attempt: max_fix_attempts (3) reached for developer\n' > "$STUB_DIR/record-attempt.err"
printf 1 > "$STUB_DIR/record-attempt.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC2 a ceiling on the merge-conflict round ends the run clean"
assert_eq "stop verdict=block reason=max-fix-attempts" "$(mc850_stop)" "AC2 the stop names the gate's verdict and reason"
assert_eq "0" "$(mc850_count '^agent developer$')" "AC2 no developer dispatch past the ceiling"

# AC3: a round that leaves the head unchanged blocks and stops, no second dispatch.
mc850_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 9
assert_eq "0" "$RC" "AC3 the unchanged-head stop exits 0"
assert_eq "stop reason=fix-round-unchanged-head pr=12 issue=9" "$(mc850_stop)" "AC3 exactly one stop line, naming the unchanged head"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC3 pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC3 pipeline:blocked on the issue"
assert_eq "1" "$(mc850_count '^agent developer$')" "AC3 exactly one developer dispatch"

# AC4: a union-path-only conflict is synced by pipeline-mergebase.sh: no developer.
mc850_fixture
printf 0 > "$STUB_DIR/mergebase.rc"
printf 0 > "$STUB_DIR/pr-mergeable.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC4 a synced union-path conflict ends the run clean"
assert_contains "$OUT" "stop verdict=wait reason=base-synced" "AC4 the gate's wait base-synced is the stop"
assert_eq "0" "$(mc850_count '^agent developer$')" "AC4 no developer dispatch"
assert_contains "$(journal)" "mergebase 12" "AC4 pipeline-mergebase.sh ran"

# AC5: a stale-approvals redispatch is still a stop, no developer.
mc850_fixture
printf 1 > "$STUB_DIR/check-approval-sha.rc"
printf 'stale role=qa label=qa:pass\n' > "$STUB_DIR/check-approval-sha.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 5
assert_contains "$OUT" "stop verdict=redispatch reason=stale-approvals stale=qa" "AC5 a stale-approvals redispatch still ends the run"
assert_eq "0" "$(mc850_count '^agent developer$')" "AC5 no developer dispatch"

# AC6: gate merge's own output for merge-conflict is unchanged (also pinned in tests/test-talos-gate.sh).
mc850_fixture
GATE_OUT="$(bash "$RUN" gate merge 12 9 2>/dev/null)"
assert_eq "verdict=redispatch
reason=merge-conflict" "$GATE_OUT" "AC6 gate merge answers verdict=redispatch then reason=merge-conflict"
finish
