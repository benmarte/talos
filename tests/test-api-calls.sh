#!/usr/bin/env bash
# test-api-calls.sh -- GitHub API calls per issue (#554, lean epic #558).
#
# Drives ONE issue through its GitHub-visible lifecycle with the real talos.sh,
# pipeline-vcs.sh, pipeline-status.sh, pipeline-meta.sh and pipeline-notify.sh over
# the stubbed gh and curl, and COUNTS the API calls the stubs saw, GraphQL and
# REST apart:
#   a run's start (the in-flight list read, then the first `next`) -> validator
#   CONFIRMED (board "In progress") -> developer PR_OPENED (board "In review") ->
#   post-approval + `done` for qa, reviewer, security, docs -> `gate merge` ->
#   merge-pr -> `post-merge` (board "Done"). Every step is the real verb, with a
#   stage's notification, relay and bookkeeping; only GitHub and the LLM are stubs.
#
# A call is GraphQL when it goes through a gh subcommand that GitHub serves from
# its GraphQL API (`gh project ...`, `gh repo|issue|pr view`, `gh pr list`,
# `gh api graphql`) and REST for `gh api -i` (the one REST client) and the
# `gh api repos/...` title reads. BEFORE is what this same script measured on main
# at 611de56, before #554 (run it there to see it); the checks below hold the AFTER
# to the savings #554 promised, and to a ceiling so a new call cannot creep back.
#
#                         GraphQL        REST
#   before (611de56)         49           86
#   after                     6           68
#   by area (before -> after):
#     board, 3 moves          16 -> 6      0 -> 0
#     notifications           33 -> 0      0 -> 2   (titles read once, then kept)
#     post-approval x4         0 -> 0     40 -> 28  (10 -> 7 each)
#     run start: 2nd next      0 -> 0     10 -> 2   (the collect is cached)
# Run it with TALOS_API_CALLS_STEPS=1 for the per-step counts, TALOS_API_CALLS_DUMP=<file>
# for the gh log, TALOS_API_CALLS_ONLY=1 to skip the assertions (to measure another tree).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

BEFORE_GRAPHQL=49 BEFORE_REST=86
CEIL_GRAPHQL=6 CEIL_REST=68

export CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
N=42 PR=9
SHA=aabb1122ccdd3344eeff556677889900aabb1122
export STUB_PR_HEAD_SHA="$SHA" STUB_CURRENT_USER=bot STUB_REPO=acme/widget
export STUB_ISSUE_TITLE="Fix login crash" STUB_PR_TITLE="fix: guard null session"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"}]'
# The comments live in a store the stub appends to, so each marker post-approval
# writes is what the next read sees (a static fixture would answer "already
# stamped" and skip the write path).
printf '[]' > "$SANDBOX/comments.json"
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
export SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
# A run exports this for its own verbs (#554); on main nothing reads it.
export TALOS_COLLECT_CACHE="$SANDBOX/collect.cache"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"enabled": true, "project_number": 7, "owner": "acme"}, "merge": {"required_checks": ["test"]}, "comments": {"enabled": false}}\n' \
  > talos.pipeline.json
printf 'one\n' > f.txt && git add f.txt && git commit -q -m init
# The merge gate's conflict check fetches the base and the PR head from origin:
# a local bare repo stands in, with main and the PR's head (refs/pull/9/head).
git branch -M main
git init -q --bare "$SANDBOX/origin.git"
git remote set-url origin "$SANDBOX/origin.git"
git push -q origin main
git checkout -q -b pr-branch
printf 'two\n' > g.txt && git add g.txt && git commit -q -m "the PR"
git push -q origin "HEAD:refs/pull/$PR/head"
git checkout -q main

# mark <label> -- (TALOS_API_CALLS_STEPS=1) the calls made since the last mark, per step.
_last=0
mark() {
  [ -z "${TALOS_API_CALLS_STEPS:-}" ] && return 0
  local _g _r
  _g="$(grep -cE '^(project |repo view|issue view|pr view|pr list|issue list|api graphql|search )' "$GH_LOG")"
  _r="$(grep -cE '^api (-i |repos/)' "$GH_LOG")"
  printf '# step %-12s graphql %2s rest %2s\n' "$1" "$((_g - _lg))" "$((_r - _lr))"
  _lg=$_g; _lr=$_r
}
_lg=0 _lr=0
step() {  # step <label> <talos.sh args...>: one lifecycle step; its output and status kept for a failure
  local _l="$1"; shift
  printf 'ok -- %s\n' "$_l" > "$SANDBOX/summary"
  bash "$TALOS" "$@" < "$SANDBOX/summary" > "$SANDBOX/out.$_l" 2>&1
  printf '%s rc=%s\n' "$_l" "$?" >> "$SANDBOX/rcs"
  mark "$_l"
}

: > "$GH_LOG"; : > "$SANDBOX/rcs"
step next1 next --issue "$N"
step next2 next --issue "$N"
step validator done validator --issue "$N" --verdict CONFIRMED --summary-file -
step developer done developer --issue "$N" --pr "$PR" --verdict PR_OPENED --summary-file -
for r in qa reviewer security docs; do
  bash "$VCS" post-approval "$PR" "$r" --issue "$N" > "$SANDBOX/out.pa.$r" 2>&1
  printf 'pa-%s rc=%s\n' "$r" "$?" >> "$SANDBOX/rcs"
  mark "pa-$r"
  case "$r" in qa) v=PASS ;; reviewer) v=APPROVED ;; security) v=CLEAR ;; *) v="" ;; esac
  step "$r" done "$r" --issue "$N" --pr "$PR" ${v:+--verdict "$v"} --summary-file -
done
step gate gate merge "$PR" "$N"
bash "$VCS" merge-pr "$PR" > "$SANDBOX/out.merge" 2>&1
printf 'merge rc=%s\n' "$?" >> "$SANDBOX/rcs"
mark merge-pr
step postmerge post-merge "$PR" "$N"

# ── the lifecycle really ran ──────────────────────────────────────────────────
assert_eq "0" "$(grep -vc ' rc=0$' "$SANDBOX/rcs")" "lifecycle: every step exited 0" "$(cat "$SANDBOX/rcs")"
for r in qa reviewer security docs; do
  assert_contains "$(cat "$SANDBOX/out.pa.$r")" "stamp ok" "lifecycle: post-approval $r stamps"
done
assert_contains "$(cat "$SANDBOX/out.gate")" "verdict=merge" "lifecycle: the merge gate passes"
assert_eq "3" "$(grep -c '^project item-edit' "$GH_LOG")" "lifecycle: three board moves (In progress, In review, Done)"
assert_contains "$(cat "$GH_LOG")" "--single-select-option-id OPT_INPROG" "lifecycle: the confirmed move"
assert_contains "$(cat "$GH_LOG")" "--single-select-option-id OPT_INREV" "lifecycle: the PR-opened move"
assert_contains "$(cat "$GH_LOG")" "--single-select-option-id OPT_DONE" "lifecycle: the merged move"

# ── the counts ────────────────────────────────────────────────────────────────
GQL="$(grep -cE '^(project |repo view|issue view|pr view|pr list|issue list|api graphql|search )' "$GH_LOG")"
REST="$(grep -cE '^api (-i |repos/)' "$GH_LOG")"
printf '# api calls per issue: GraphQL %s (was %s), REST %s (was %s)\n' "$GQL" "$BEFORE_GRAPHQL" "$REST" "$BEFORE_REST"
[ -z "${TALOS_API_CALLS_DUMP:-}" ] || cp "$GH_LOG" "$TALOS_API_CALLS_DUMP"
[ -z "${TALOS_API_CALLS_ONLY:-}" ] || exit 0

assert_eq "1" "$([ $((GQL * 2)) -le "$BEFORE_GRAPHQL" ] && echo 1 || echo 0)" \
  "GraphQL: at least 50% fewer calls than before ($GQL vs $BEFORE_GRAPHQL)"
assert_eq "1" "$([ "$GQL" -le "$CEIL_GRAPHQL" ] && echo 1 || echo 0)" "GraphQL: within the ceiling of $CEIL_GRAPHQL (got $GQL)"
assert_eq "1" "$([ "$REST" -lt "$BEFORE_REST" ] && echo 1 || echo 0)" "REST: fewer calls than before ($REST vs $BEFORE_REST)"
assert_eq "1" "$([ "$REST" -le "$CEIL_REST" ] && echo 1 || echo 0)" "REST: within the ceiling of $CEIL_REST (got $REST)"

# By area: what each of the four changes bought.
assert_eq "0" "$(grep -cE '^(repo view|issue view|pr view|project item-list)' "$GH_LOG")" "no GraphQL view/list of the repo, an issue, a PR or the board"
assert_eq "1" "$(grep -c '^project list' "$GH_LOG")" "board: the project is resolved once for three moves"
assert_eq "1" "$(grep -c '^project field-list' "$GH_LOG")" "board: the fields are read once for three moves"
assert_eq "1" "$(grep -c 'projectItems' "$GH_LOG")" "board: the item is found by issue, once"
assert_eq "2" "$(grep -c '^api repos/' "$GH_LOG")" "notifications: the issue and PR titles are each read once, then kept"

finish
