#!/usr/bin/env bash
# test-merge-queue-932.sh -- merge queue 5/5 (#932): under `merge.queue: github`
# a PR that passes every merge gate goes into GitHub's merge queue through the
# `enqueue-pr` adapter verb and is never merged directly; a base branch with no
# queue, or a provider other than GitHub, stops with a named reason. Tests are
# named by the spec's criterion id.
#   AC1, AC5, AC6, AC8, AC10, AC11  gate merge over the journaling stubs of
#             tests/talos-run-sections.sh (enqueue-pr answered by set_stub)
#   AC9       `run` over the same fixture
#   AC12      post-merge, with the merge-base/worktree/status scripts stubbed
#   AC2-AC4   the real pipeline-vcs.sh on the gh and curl stubs (both GitHub
#             transports); gh-rest-fixtures.py answers GraphQL by query content
#   AC7       the real pipeline-vcs.sh with gitlab, azure and file
# No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=932 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0

set_stub() {  # <key> <rc> [out] [err]
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
jc() { journal | grep -c -E "$1"; }
# mq <merge.queue or -> [merge.auto]: PR 12 (issue 9) at the merge stage, every gate green.
mq() {
  local _m=""
  [ "$1" = "-" ] || _m="\"queue\": \"$1\""
  [ -z "${2:-}" ] || _m="${_m:+$_m, }\"auto\": $2"
  merge_fixture "$ALL_APPROVALS" ", \"merge\": {$_m}"
  draft_ready
}
gm() { rm -f "$STUB_DIR/journal"; OUT="$(bash "$RUN" gate merge 12 9 </dev/null 2>"$ERR")"; RC=$?; }

# ── AC1: an eligible PR is enqueued through the provider, never merged ───────
mq github; set_stub enqueue-pr 0 "Queued PR #12"; gm
assert_eq "0" "$RC" "AC1 gate merge exits 0"
assert_eq "verdict=wait
reason=provider-queued" "$OUT" "AC1 an eligible PR waits with reason=provider-queued"
assert_eq "1" "$(jc '^vcs enqueue-pr 12$')" "AC1 the journal holds one enqueue-pr 12"
assert_eq "0" "$(jc '^vcs merge-pr')" "AC1 the journal holds no merge-pr"

# ── AC5 / AC6 / AC8: the enqueue's exit code names the outcome, never a merge ─
eq_case() {  # <enqueue-pr rc> <verdict> <reason> <label prefix>
  mq github; set_stub enqueue-pr "$1" "" "pipeline-vcs: enqueue-pr: refused"; gm
  assert_eq "0|verdict=$2
reason=$3" "$RC|$OUT" "$4 enqueue-pr exit $1: verdict=$2 reason=$3"
  assert_eq "0" "$(jc '^vcs merge-pr')" "$4 enqueue-pr exit $1: no merge-pr"
}
eq_case 3 block merge-queue-disabled "AC5 no queue on the base"
eq_case 2 block merge-queue-unsupported "AC6 a non-GitHub provider"
eq_case 1 wait enqueue-failed "AC8 a failed enqueue"

# ── AC10 (same): unset or off merges as today, no enqueue-pr ─────────────────
for q in - off; do
  mq "$q"; gm
  assert_eq "verdict=merge" "$(printf '%s\n' "$OUT" | head -n 1)" "AC10 merge.queue=$q: every gate green is verdict=merge"
  assert_eq "0" "$(jc '^vcs enqueue-pr')" "AC10 merge.queue=$q: enqueue-pr is never called"
done

# ── AC11 (same): merge.auto false hands off before the queue step ────────────
mq github false; gm
assert_eq "verdict=handoff" "$OUT" "AC11 merge.queue: github with merge.auto: false hands off"
assert_eq "0" "$(jc '^vcs enqueue-pr')" "AC11 enqueue-pr is never called on a hand-off"

# ── AC9: run relays a provider-queued wait: no merge, no queue run ───────────
mq github; set_stub enqueue-pr 0 "Queued PR #12"
export LIST_PRS="[]"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC9 run exits 0"
assert_eq "stop verdict=wait reason=provider-queued" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC9 run ends with a stop naming reason=provider-queued"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(jc '^vcs ref-checks-required')" "AC9 no merge-pr and no ref-checks-required"
assert_not_contains "$OUT" "stop queue" "AC9 no queue run pass"

# ── AC12 (same): post-merge skips the sibling sync under merge.queue: github ──
GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-mergebase.sh pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done
pm() {  # <merge.queue>
  mq "$1"
  export LIST_PRS='[{"number":13,"baseRefName":"main","headRefName":"feat/issue-43-x","isCrossRepository":false}]'
  export LIST_ISSUES='[{"number":9}]'
  printf 'CHANGELOG.md\n' > "$STUB_DIR/conflict-files.out"
  printf 'closes' > "$STUB_DIR/pr-closes-issue.out"
  rm -f "$STUB_DIR/journal"
  OUT="$(bash "$GQ/talos.sh" post-merge 12 9 </dev/null 2>"$ERR")"; RC=$?
}
pm off
assert_contains "$OUT" "sibling=13 action=" "AC12 control: merge.queue=off syncs the conflicting sibling"
pm github
assert_eq "0" "$RC" "AC12 merge.queue=github: post-merge exits 0"
assert_not_contains "$OUT" "sibling=" "AC12 merge.queue=github: no sibling sync"
assert_eq "0" "$(jc '^vcs list-prs')" "AC12 merge.queue=github: no sibling listing"
export LIST_PRS="[]" LIST_ISSUES="[]"

# ── AC2-AC4: the real enqueue-pr on both GitHub transports ───────────────────
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
EQ_SHA="0123456789abcdef0123456789abcdef01234567"
eq() {  # <STUB_GH_MERGE_QUEUE>
  : > "$CURL_LOG"
  OUT="$(STUB_GH_FIXTURES=1 STUB_GH_MERGE_QUEUE="$1" STUB_PR_HEAD_SHA="$EQ_SHA" bash "$VCS" enqueue-pr 9 </dev/null 2>"$ERR")"; RC=$?
}
gql() { grep '^https://api.github.com/graphql	' "$CURL_LOG" | grep -c -- "$1"; }
merges() { grep -c 'pulls/9/merge' "$CURL_LOG"; }
for leg in gh curl; do
  github_leg "$leg"
  eq on
  assert_eq "0|Queued PR #9" "$RC|$OUT" "AC2 $leg: a queue-enabled base enqueues: exit 0, Queued PR #9"
  assert_eq "1" "$(gql enqueuePullRequest)" "AC2 $leg: one GraphQL request carries enqueuePullRequest"
  _mut="$(grep '^https://api.github.com/graphql	' "$CURL_LOG" | grep -- enqueuePullRequest)"
  assert_contains "$_mut" "PR_node_9" "AC2 $leg: the mutation names the PR's node id"
  assert_contains "$_mut" "$EQ_SHA" "AC2 $leg: the mutation names the PR's head sha"
  assert_eq "0" "$(merges)" "AC2 $leg: no PUT .../pulls/9/merge"

  eq off
  assert_eq "3" "$RC" "AC3 $leg: a queue-less base exits 3"
  assert_contains "$(cat "$ERR")" "has no merge queue" "AC3 $leg: stderr names has no merge queue"
  assert_eq "0|0" "$(gql enqueuePullRequest)|$(merges)" "AC3 $leg: no enqueuePullRequest, no PUT .../merge"

  eq queued
  assert_eq "0|PR #9 already queued" "$RC|$OUT" "AC4 $leg: an already-queued PR: exit 0, PR #9 already queued"
  assert_eq "0|0" "$(gql enqueuePullRequest)|$(merges)" "AC4 $leg: no enqueuePullRequest, no PUT .../merge"
done

# ── AC7: gitlab, azure and file are not implemented (exit 2, no provider call) ─
for p in gitlab azure file; do
  case "$p" in
    gitlab) git remote set-url origin git@gitlab.com:acme/widget.git
            printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG" ;;
    azure)  git remote set-url origin git@github.com:acme/widget.git
            printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}\n' > "$PIPELINE_CONFIG" ;;
    file)   printf '{"vcs": {"provider": "file"}}\n' > "$PIPELINE_CONFIG" ;;
  esac
  : > "$GH_LOG"
  OUT="$(bash "$VCS" enqueue-pr 7 </dev/null 2>"$ERR")"; RC=$?
  assert_eq "2" "$RC" "AC7 $p: enqueue-pr exits 2"
  assert_contains "$(cat "$ERR")" "not implemented for provider" "AC7 $p: stderr says not implemented for provider"
  assert_eq "0" "$(grep -c -E '^(GLAB|AZ )' "$GH_LOG")" "AC7 $p: the glab/az stub logs show no call"
done

finish
