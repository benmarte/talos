#!/usr/bin/env bash
# One GitHub provider, two transports (#551). Every verb runs through BOTH the
# gh transport (vcs.provider github, `gh api -i` via the gh stub) and the token
# transport (vcs.provider github-api, curl via the curl stub) with the SAME
# queued REST responses, and the two runs must agree on stdout, exit code,
# stderr and the exact requests sent (URL, payload, method). Each case also
# pins the verb's output contract, so a regression shows up as a contract
# change and not just as a disagreement between the legs.
#
# The gh stub hands `gh api -i` to the curl stub, so GH_QUEUE and CURL_QUEUE
# use one format: a line is a body, "<status>" alone is an empty answer with
# that status, "<status>:<body>" sets both.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
export GITHUB_TOKEN="parity-test-token"
export STUB_CURRENT_USER="bot"
export GH_REST_LOG="$SANDBOX/gh-rest.log"

SHA="0123456789abcdef0123456789abcdef01234567"
# pr <state> <draft> <mergeable> <labels-json> [<merged_at>]: a REST pull request.
pr() {
  printf '{"number":9,"state":"%s","merged_at":%s,"title":"fix: x","body":"Closes #42","html_url":"https://github.com/acme/widget/pull/9","node_id":"PR_9","draft":%s,"mergeable":%s,"labels":%s,"head":{"ref":"fix/issue-42-guard","sha":"%s","repo":{"full_name":"acme/widget"}},"base":{"ref":"main","repo":{"full_name":"acme/widget"}}}' \
    "$1" "${5:-null}" "$2" "$3" "$4" "$SHA"
}
PR9="$(pr open false true '[{"name":"pipeline:review"}]')"
ISSUE3='{"number":3,"state":"open","title":"Fix login bug","body":"Body text","labels":[{"name":"pipeline:dev"}],"assignees":[]}'
CMT='{"id":100,"html_url":"https://github.com/acme/widget/issues/3#issuecomment-100","body":"ok"}'

# parity <label> <verb> [args...]
#   Q   queued responses, one per line      CFG  extra JSON members for the config
#   LQ  queued Link: next URLs (optional)   ENV  extra "VAR=value" words for both legs
#   EXP_OUT / EXP_RC  the contract: stdout contains EXP_OUT, exit code is EXP_RC (default 0)
Q=""; LQ=""; CFG=""; ENV=""; EXP_OUT=""; EXP_RC=0

_leg() {  # _leg <gh|curl> <args...>
  local t="$1"; shift
  local qf="$SANDBOX/q.$t" lf="$SANDBOX/l.$t" prov=github reqlog="$GH_REST_LOG"
  [ "$t" = curl ] && { prov=github-api; reqlog="$CURL_LOG"; }
  printf '%s' "$Q" > "$qf"; printf '%s' "$LQ" > "$lf"
  : > "$GH_REST_LOG"; : > "$CURL_LOG"
  printf '{"vcs":{"provider":"%s","repo":"acme/widget"},"issues":{"assignee":"none"}%s}' "$prov" "$CFG" > talos.pipeline.json
  # shellcheck disable=SC2086
  if [ "$t" = gh ]; then
    env $ENV GH_QUEUE="$qf" GH_LINK_QUEUE="$lf" bash "$VCS" "$@" > "$SANDBOX/out.$t" 2> "$SANDBOX/err.$t"
  else
    env $ENV CURL_QUEUE="$qf" CURL_LINK_QUEUE="$lf" bash "$VCS" "$@" > "$SANDBOX/out.$t" 2> "$SANDBOX/err.$t"
  fi
  echo $? > "$SANDBOX/rc.$t"
  cut -f1,2,4 "$reqlog" > "$SANDBOX/req.$t"
}

parity() {
  local label="$1"; shift
  _leg gh "$@"; _leg curl "$@"
  assert_eq "$(cat "$SANDBOX/rc.curl")" "$(cat "$SANDBOX/rc.gh")" "$label: same exit code on both transports"
  assert_eq "$(cat "$SANDBOX/out.curl")" "$(cat "$SANDBOX/out.gh")" "$label: same stdout on both transports"
  assert_eq "$(cat "$SANDBOX/err.curl")" "$(cat "$SANDBOX/err.gh")" "$label: same stderr on both transports"
  assert_eq "$(cat "$SANDBOX/req.curl")" "$(cat "$SANDBOX/req.gh")" "$label: same requests (URL, payload, method) on both transports"
  assert_eq "$EXP_RC" "$(cat "$SANDBOX/rc.curl")" "$label: exit code $EXP_RC"
  [ -z "$EXP_OUT" ] || assert_contains "$(cat "$SANDBOX/out.curl")" "$EXP_OUT" "$label: stdout carries the contract"
  Q=""; LQ=""; CFG=""; ENV=""; EXP_OUT=""; EXP_RC=0
}
out_of() { cat "$SANDBOX/out.curl"; }
err_of() { cat "$SANDBOX/err.curl"; }
req_of() { cat "$SANDBOX/req.curl"; }
# json_is <label> <expected-json>: the curl leg's stdout is that JSON, key order ignored
json_is() {
  local want got
  want="$(printf '%s' "$2" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
  got="$(out_of | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null)"
  assert_eq "$want" "$got" "$1"
}

BASE='https://api.github.com/repos/acme/widget'

# ── issues: reads ─────────────────────────────────────────────────────────────
Q="$(printf '%s\n' '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[{"name":"pipeline:dev"}]},{"number":4,"title":"a PR","body":"","labels":[],"pull_request":{}}]')"
parity "list-issues" list-issues
json_is "list-issues: issues only (a pull request is dropped), github field set" \
  '[{"number":3,"title":"Fix login bug","labels":[{"name":"pipeline:dev"}],"body":"Body text"}]'
assert_contains "$(req_of)" "$BASE/issues?state=open&per_page=100" "list-issues: one paginated REST list"

Q="$(printf '%s\n' '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[]}]')"
parity "list-issues --no-body" list-issues --no-body
json_is "list-issues --no-body: no body key" '[{"number":3,"title":"Fix login bug","labels":[]}]'

Q="$(printf '%s\n' "$ISSUE3" '[{"id":1,"user":{"login":"alice"},"body":"hello","created_at":"2026-10-01T00:00:00Z","html_url":"https://github.com/acme/widget/issues/3#issuecomment-1"}]')"
parity "view-issue" view-issue 3
assert_eq "title,body,labels,comments" "$(out_of | python3 -I -c 'import json,sys; print(",".join(json.load(sys.stdin).keys()))')" "view-issue: {title, body, labels, comments}"
assert_contains "$(out_of)" '"login": "alice"' "view-issue: comments carry author.login"
assert_contains "$(out_of)" '"body": "hello"' "view-issue: comments carry body"

Q="$(printf '%s\n' "$ISSUE3" '[{"id":1,"user":{"login":"alice"},"body":"**PM spec:** do x","created_at":"2026-10-01T00:00:00Z"},{"id":2,"user":{"login":"bob"},"body":"chatter","created_at":"2026-10-01T00:01:00Z"}]')"
parity "view-issue --spec" view-issue 3 --spec
assert_contains "$(out_of)" "PM spec" "view-issue --spec: keeps the latest PM spec comment"
assert_not_contains "$(out_of)" "chatter" "view-issue --spec: drops other comments"

Q="$(printf '%s\n' '{"number":3,"body":"- [x] done\n- [ ] still open item\n"}')"
EXP_RC=1; EXP_OUT="still open item"
parity "check-epic-acceptance" check-epic-acceptance 3

# ── issues: writes ────────────────────────────────────────────────────────────
Q="$(printf '%s\n' '{"state":"open"}' "$CMT")"
EXP_OUT="https://github.com/acme/widget/issues/3#issuecomment-100"
parity "comment-issue" comment-issue 3 "validator: CONFIRMED"
assert_contains "$(req_of)" "POST" "comment-issue: POST"
assert_contains "$(req_of)" "validator: CONFIRMED" "comment-issue: the body is in the payload"
assert_contains "$(req_of)" "$BASE/issues/3/comments" "comment-issue: issues/<n>/comments"

Q="$(printf '%s\n' '{"state":"closed"}')"
EXP_RC=1
parity "comment-issue on a closed issue" comment-issue 3 "late"
assert_contains "$(err_of)" "issue #3 is CLOSED (use --allow-closed to override)" "comment-issue: refuses a closed issue"

Q="$(printf '%s\n' "$CMT")"
EXP_OUT="issuecomment-100"
parity "comment-issue --allow-closed" --allow-closed comment-issue 3 "late"
assert_eq "1" "$(req_of | grep -c .)" "comment-issue --allow-closed: no state read"

Q="$(printf '%s\n' '500:{"message":"boom"}' "$CMT")"
EXP_OUT="talos:comment-state-unverified target=issue#3 reason=state-check-failed"
ENV="TALOS_RETRY_SLEEP_SCALE=0"
parity "comment-issue with an unreadable state" comment-issue 3 "x"

Q="$(printf '%s\n' "$CMT" '{"state":"closed"}')"
EXP_OUT="Closed issue #3"
parity "close-issue" close-issue 3 "resolved"
assert_contains "$(req_of)" "PATCH" "close-issue: PATCH state closed"

Q="$(printf '%s\n' '[{"name":"a"}]' '204')"
EXP_OUT="Labels updated on issue #3"
parity "label-issue" label-issue 3 --add a --remove b
assert_contains "$(req_of)" "$BASE/issues/3/labels" "label-issue: adds go to issues/<n>/labels"
assert_contains "$(req_of)" "DELETE" "label-issue: a removal is a DELETE of that one label"
assert_not_contains "$(req_of)" "PUT" "label-issue: never replaces the whole label set"

Q="$(printf '%s\n' '404:{"message":"Label does not exist"}')"
EXP_OUT="Labels updated on issue #3"
parity "label-issue --remove of an absent label" label-issue 3 --remove gone

printf 'the body' > "$SANDBOX/body.md"
Q="$(printf '%s\n' '{"number":55,"html_url":"https://github.com/acme/widget/issues/55"}')"
EXP_OUT="https://github.com/acme/widget/issues/55"
parity "create-issue" create-issue "feat: x" "$SANDBOX/body.md" --label pipeline:ready
assert_contains "$(req_of)" '"labels": ["pipeline:ready"]' "create-issue: labels in the payload"

# ── pull requests: reads ──────────────────────────────────────────────────────
Q="$(printf '%s\n' "$PR9")"
parity "view-pr" view-pr 9
json_is "view-pr: number, title, headRefName, labels, url, body" \
  '{"number":9,"title":"fix: x","headRefName":"fix/issue-42-guard","labels":[{"name":"pipeline:review"}],"url":"https://github.com/acme/widget/pull/9","body":"Closes #42"}'

Q="$(printf '%s\n' '[{"number":9}]' "$PR9")"
parity "view-pr by branch" view-pr fix/issue-42-guard
assert_contains "$(out_of)" '"number": 9' "view-pr <branch>: resolves the branch to its PR"
assert_contains "$(req_of)" "pulls?state=open&head=acme:fix/issue-42-guard" "view-pr <branch>: head filter on the owner's branch"

Q="$(printf '%s\n' "[$PR9]")"
parity "list-prs" list-prs
json_is "list-prs: lane fields" \
  '[{"number":9,"title":"fix: x","headRefName":"fix/issue-42-guard","baseRefName":"main","labels":[{"name":"pipeline:review"}],"isCrossRepository":false}]'

Q="$(printf '%s\n' "[$PR9]")"
CFG=',"base_branch":"lane"'
parity "list-prs scoped to base_branch" list-prs
assert_contains "$(req_of)" "&base=lane" "list-prs: the base filter is a REST query parameter"

Q="$(printf 'diff --git a/x b/x\001+new line')"
EXP_OUT="+new line"
parity "diff-pr" diff-pr 9

Q="$(printf '%s\n' '[{"filename":"scripts/x.sh","additions":3,"deletions":1}]')"
EXP_OUT="scripts/x.sh"
parity "diff-pr --stat" diff-pr 9 --stat

Q="$(printf '%s\n' '[{"filename":"src/a.js"},{"filename":"b.md"}]')"
EXP_OUT="src/a.js"
parity "pr-files" pr-files 9
assert_eq "src/a.js
b.md" "$(out_of)" "pr-files: one path per line"

Q="$(printf '%s\n' '[{"filename":"src/a.js"}]' '[{"filename":"b.md"}]')"
LQ="$(printf '%s\n\n' "$BASE/pulls/9/files?per_page=100&page=2")"
parity "pr-files across two pages" pr-files 9
assert_eq "src/a.js
b.md" "$(out_of)" "pr-files: follows Link: rel=next"

Q="$(printf '%s\n' '[{"filename":"src/a.js"}]' '500:{"message":"boom"}')"
LQ="$(printf '%s\n\n' "$BASE/pulls/9/files?per_page=100&page=2")"
EXP_RC=1
parity "pr-files with a failing page" pr-files 9
assert_eq "" "$(out_of)" "pr-files: a failed page prints no partial list"

Q="$(printf '%s\n' '[{"filename":"src/a.js"}]')"
LQ="$(printf '%s\n' "https://evil.example/repos/x?page=2")"
EXP_RC=1
parity "pagination refuses a foreign next link" pr-files 9
assert_contains "$(err_of)" "refusing to follow pagination link to https://evil.example:443" "pagination: foreign origin refused before a token is sent"

Q="$(printf '%s\n' '[{"filename":"src/a.js"}]')"
EXP_OUT="no forbidden files"
parity "check-pr-files" check-pr-files 9

Q="$(printf '%s\n' '[{"filename":"deploy/prod.pem"}]')"
EXP_RC=1; EXP_OUT="deploy/prod.pem"
parity "check-pr-files with a forbidden file" check-pr-files 9

Q="$(printf '%s\n' "$PR9")"
EXP_OUT="$SHA"
parity "pr-head" pr-head 9
assert_eq "$SHA" "$(out_of)" "pr-head: the head SHA alone"

Q="$(printf '%s\n' '404:{"message":"Not Found"}')"
EXP_RC=1
parity "pr-head on a missing PR" pr-head 9
assert_eq "" "$(out_of)" "pr-head: fail closed, nothing on stdout"
assert_contains "$(err_of)" "HTTP 404" "pr-head: the status reaches stderr"

Q="$(printf '%s\n' "$PR9")"
EXP_OUT="MERGEABLE"
parity "pr-mergeable (mergeable)" pr-mergeable 9

Q="$(printf '%s\n' "$(pr open false false '[]')")"
EXP_RC=1; EXP_OUT="CONFLICTING"
parity "pr-mergeable (conflicting)" pr-mergeable 9

U="$(pr open false null '[]')"
Q="$(printf '%s\n' "$U" "$U" "$U" "$U" "$U")"
EXP_RC=2; EXP_OUT="UNKNOWN"
parity "pr-mergeable (never computed)" pr-mergeable 9

Q="$(printf '%s\n' '429:{"message":"API rate limit exceeded"}' "$PR9")"
parity "a rate limit is retried" pr-head 9
assert_contains "$(err_of)" "rate-limited, retry 1/5" "rate limit: retried with backoff on both transports"
assert_eq "$SHA" "$(out_of)" "rate limit: the retry's answer is the output"

Q="$(printf '%s\n' '[{"number":9,"state":"open","title":"fix: x","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42"}]')"
EXP_OUT='"number": 9'
parity "find-pr" find-pr 42

# ── pull requests: draft state ────────────────────────────────────────────────
Q="$(printf '%s\n' "$(pr open true true '[]')")"
EXP_OUT="draft"
parity "pr-is-draft (draft)" pr-is-draft 9
assert_eq "draft" "$(out_of)" "pr-is-draft: prints draft, exit 0"

Q="$(printf '%s\n' "$PR9")"
EXP_RC=1
parity "pr-is-draft (ready)" pr-is-draft 9
assert_eq "ready" "$(out_of)" "pr-is-draft: prints ready, exit 1"

Q="$(printf '%s\n' '404:{"message":"Not Found"}')"
EXP_RC=2
parity "pr-is-draft (unverified)" pr-is-draft 9
assert_eq "" "$(out_of)" "pr-is-draft: exit 2 prints nothing"

Q="$(printf '%s\n' "$PR9" '{"data":{"markPullRequestReadyForReview":{"pullRequest":{"isDraft":false}}}}')"
parity "ready-pr" ready-pr 9
assert_contains "$(req_of)" "graphql" "ready-pr: the mutation goes to /graphql"
assert_contains "$(req_of)" "PR_9" "ready-pr: the PR's node id is the mutation input"

Q="$(printf '%s\n' "$PR9" '{"data":{"convertPullRequestToDraft":{"pullRequest":{"isDraft":true}}}}')"
parity "draft-pr" draft-pr 9

Q="$(printf '%s\n' "$PR9" '{"errors":[{"message":"not allowed"}],"data":null}')"
EXP_RC=2
parity "ready-pr with a GraphQL error" ready-pr 9

RUNS='{"total_count":3,"workflow_runs":[{"id":1,"conclusion":"success","pull_requests":[{"number":9}]},{"id":2,"conclusion":"skipped","pull_requests":[{"number":9}]},{"id":3,"conclusion":"failure","pull_requests":[{"number":7}]}]}'
Q="$(printf '%s\n' "$PR9" "$RUNS")"
EXP_OUT="1"
parity "pr-ci-runs" pr-ci-runs 9
assert_eq "1" "$(out_of)" "pr-ci-runs: runs of this PR, skipped ones dropped"
assert_contains "$(req_of)" "actions/runs?event=pull_request&branch=fix%2Fissue-42-guard&per_page=100" "pr-ci-runs: REST run listing for the head branch"

Q="$(printf '%s\n' "$PR9" '{"total_count":1,"workflow_runs":[{"id":1,"conclusion":"success","pull_requests":[]}]}')"
EXP_RC=2
parity "pr-ci-runs with an unattributable run" pr-ci-runs 9

Q="$(printf '%s\n' '{"html_url":"https://github.com/acme/widget/pull/9"}')"
CFG=',"base_branch":"main"'
EXP_OUT="https://github.com/acme/widget/pull/9"
parity "create-pr" create-pr fix/issue-42-guard "fix: x" "$SANDBOX/body.md"
assert_contains "$(req_of)" '"draft": false' "create-pr: a ready PR"

Q="$(printf '%s\n' '{"html_url":"https://github.com/acme/widget/pull/9"}')"
CFG=',"base_branch":"main"'
EXP_OUT="https://github.com/acme/widget/pull/9"
parity "create-pr --draft" create-pr fix/issue-42-guard "fix: x" "$SANDBOX/body.md" --draft
assert_contains "$(req_of)" '"draft": true' "create-pr --draft: opened as a draft"

# ── pull requests: writes ─────────────────────────────────────────────────────
Q="$(printf '%s\n' '{"id":9}')"
EXP_OUT="Approved PR #9"
parity "approve-pr" approve-pr 9 "looks good"
assert_contains "$(req_of)" "$BASE/pulls/9/reviews" "approve-pr: pulls/<n>/reviews"
assert_contains "$(req_of)" '"event": "APPROVE"' "approve-pr: APPROVE"

Q="$(printf '%s\n' '[{"name":"pipeline:review"}]')"
EXP_OUT="Labels updated on PR #9"
parity "label-pr" label-pr 9 --add pipeline:review

Q="$(printf '%s\n' "$PR9" '{"sha":"deadbeef","merged":true}' '204')"
EXP_OUT="Merged PR #9"
parity "merge-pr" merge-pr 9
assert_contains "$(req_of)" '"merge_method": "squash"' "merge-pr: squash by default"
assert_contains "$(req_of)" "DELETE" "merge-pr: the head branch is deleted after the merge"
assert_contains "$(req_of)" "git/refs/heads/fix/issue-42-guard" "merge-pr: that branch"

Q="$(printf '%s\n' "$PR9" '{"sha":"deadbeef","merged":true}')"
CFG=',"merge":{"method":"rebase"}'
parity "merge-pr (rebase)" merge-pr 9
assert_contains "$(req_of)" '"merge_method": "rebase"' "merge-pr: merge.method"

Q="$(printf '%s\n' "$PR9" '405:{"message":"Pull Request is not mergeable"}')"
EXP_RC=1
parity "merge-pr refused" merge-pr 9
assert_not_contains "$(req_of)" "DELETE" "merge-pr: nothing is deleted when the merge failed"

Q="$(printf '%s\n' "$PR9" "$CMT")"
EXP_OUT="issuecomment-100"
parity "comment-pr" comment-pr 9 "review done"

Q="$(printf '%s\n' "$(pr closed false null '[]')")"
EXP_RC=1
parity "comment-pr on a closed, unmerged PR" comment-pr 9 "late"
assert_contains "$(err_of)" "PR #9 is CLOSED (not merged)" "comment-pr: refuses a closed unmerged PR"

Q="$(printf '%s\n' "$(pr closed false null '[]' '"2026-09-01T00:00:00Z"')" "$CMT")"
EXP_OUT="issuecomment-100"
parity "comment-pr on a merged PR" comment-pr 9 "post-merge note"

Q="$(printf '%s\n' '{"number":9}')"
EXP_OUT="edited pr=9 body"
parity "edit-pr-body" edit-pr-body 9 --body-file "$SANDBOX/body.md"
assert_contains "$(req_of)" "PATCH" "edit-pr-body: PATCH"
assert_contains "$(req_of)" '"body": "the body"' "edit-pr-body: the body"

Q="$(printf '%s\n' "$PR9" '{}')"
EXP_OUT="update-branch: PR #9 branch updated with its base"
parity "update-branch" update-branch 9
assert_contains "$(req_of)" "expected_head_sha" "update-branch: pinned to the head SHA read"

Q="$(printf '%s\n' "$PR9" '409:{"message":"Head branch was modified"}')"
EXP_RC=1
parity "update-branch refused" update-branch 9
assert_contains "$(err_of)" "GitHub refused the branch update for PR #9" "update-branch: the reason line"

RUNS2='{"total_count":2,"workflow_runs":[{"id":11,"conclusion":"failure"},{"id":12,"conclusion":"success"}]}'
Q="$(printf '%s\n' "$PR9" "$RUNS2" '201:{}')"
EXP_OUT="rerun-ci: re-ran failed runs for PR #9"
parity "rerun-ci" rerun-ci 9
assert_contains "$(req_of)" "actions/runs/11/rerun-failed-jobs" "rerun-ci: only the failed run is re-run"
assert_not_contains "$(req_of)" "actions/runs/12/" "rerun-ci: a green run is left alone"

# ── checks ────────────────────────────────────────────────────────────────────
RUNSC='{"total_count":2,"check_runs":[{"name":"test","status":"completed","conclusion":"success","started_at":"2026-10-01T00:00:00Z","completed_at":"2026-10-01T00:01:02Z","html_url":"https://github.com/acme/widget/actions/runs/5/job/6"},{"name":"lint","status":"completed","conclusion":"failure","started_at":"2026-10-01T00:00:00Z","completed_at":"2026-10-01T00:00:10Z","html_url":"https://github.com/acme/widget/actions/runs/5/job/7"}]}'
Q="$(printf '%s\n' "$PR9" "$RUNSC" '{"state":"failure","statuses":[{"context":"ci/legacy","state":"success","target_url":"https://ci.example/1"}]}')"
EXP_RC=1; EXP_OUT="test	pass	1m2s	https://github.com/acme/widget/actions/runs/5/job/6"
parity "pr-checks" pr-checks 9
assert_contains "$(out_of)" "lint	fail	10s	" "pr-checks: a failing check, tab separated"
assert_contains "$(out_of)" "ci/legacy	pass	" "pr-checks: legacy commit statuses are listed too"

Q="$(printf '%s\n' "$PR9" "$RUNSC")"
CFG=',"merge":{"required_checks":["test"]}'
EXP_OUT=""
parity "pr-checks-required (passing)" pr-checks-required 9
assert_contains "$(err_of)" "all required checks passed: test" "pr-checks-required: summary line"
assert_eq "2" "$(req_of | grep -c .)" "pr-checks-required: needs no status call when every required check is a check run"

Q="$(printf '%s\n' "$PR9" "$RUNSC")"
CFG=',"merge":{"required_checks":["test","lint"]}'
EXP_RC=1
parity "pr-checks-required (failing)" pr-checks-required 9
assert_contains "$(err_of)" "failed: lint" "pr-checks-required: names the failing check"

Q="$(printf '%s\n' "$PR9" "$RUNSC" '{"state":"pending","statuses":[]}')"
CFG=',"merge":{"required_checks":["test","ci/legacy"]}'
EXP_RC=2
parity "pr-checks-required (missing check)" pr-checks-required 9
assert_contains "$(err_of)" "pending or missing: ci/legacy" "pr-checks-required: a required check nobody reported is pending"

EXP_RC=1
parity "pr-checks-required (nothing configured)" pr-checks-required 9
assert_eq "" "$(req_of)" "pr-checks-required: an empty list needs no call"

# ── closing keyword / siblings ────────────────────────────────────────────────
Q="$(printf '%s\n' "$PR9" '[{"number":9,"state":"open","title":"x","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42"},{"number":12,"state":"open","title":"y","head":{"ref":"feat/issue-42-more"},"body":"Part of #42"}]')"
EXP_RC=1
parity "check-closing-keyword (open sibling)" check-closing-keyword 9 42
assert_contains "$(err_of)" "#12" "check-closing-keyword: names the open sibling"

Q="$(printf '%s\n' "$PR9" '[{"number":9,"state":"open","title":"x","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42"}]')"
parity "check-closing-keyword (no sibling)" check-closing-keyword 9 42

Q="$(printf '%s\n' '500:{"message":"boom"}')"
EXP_OUT="talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed"
parity "check-closing-keyword (PR unreadable)" check-closing-keyword 9 42

# ── comments, attempts, approvals ─────────────────────────────────────────────
Q="$(printf '%s\n' '[{"id":1,"user":{"login":"bot"},"body":"hi","created_at":"2026-10-01T00:00:00Z"}]')"
parity "read-comments" read-comments 9
assert_contains "$(out_of)" '"login": "bot"' "read-comments: {comments:[{author:{login}}]}"

Q="$(printf '%s\n' '[{"id":1,"user":{"login":"bot"},"body":"<!-- talos:attempt stage=qa count=2 total=3 -->","created_at":"2026-10-01T00:00:00Z"}]')"
EXP_OUT="stage=qa count=2 total=3"
parity "read-attempt" read-attempt 9

Q="$(printf '%s\n' '[]')"
EXP_OUT="check-attempt: ok"
parity "check-attempt" check-attempt 9

Q="$(printf '%s\n' '[]' '{"html_url":"https://github.com/acme/widget/issues/9#issuecomment-1"}')"
EXP_OUT="stage=qa count=1 total=1"
parity "record-attempt" record-attempt 9 qa
assert_contains "$(req_of)" "talos:attempt stage=qa" "record-attempt: the marker is the comment body"

Q="$(printf '%s\n' "$(pr open false true '[{"name":"qa:pass"}]')" "[{\"id\":1,\"user\":{\"login\":\"bot\"},\"body\":\"verdict\\n<!-- talos:approval sha=$SHA role=qa -->\",\"created_at\":\"2026-10-01T00:00:00Z\"}]")"
parity "check-approval-sha" check-approval-sha 9

Q="$(printf '%s\n' "$(pr open false true '[{"name":"qa:pass"}]')" '[]')"
EXP_RC=1
parity "check-approval-sha without a marker" check-approval-sha 9

Q="$(printf '%s\n' '{"number":3,"title":"t","body":"## Acceptance criteria\n- [ ] one\n","labels":[]}' '[]')"
parity "has-spec (a usable spec)" has-spec 3
Q="$(printf '%s\n' '{"number":3,"title":"t","body":"no criteria here","labels":[]}' '[]')"
EXP_RC=1
parity "has-spec (no spec)" has-spec 3

# ── identity ──────────────────────────────────────────────────────────────────
EXP_OUT="bot"
parity "current-user" current-user

# ── transport selection ───────────────────────────────────────────────────────
# github + a gh that is not authenticated falls back to the token transport; with
# no token either it stops, saying what is missing. github-api never asks gh.
printf '{"vcs":{"provider":"github","repo":"acme/widget"}}' > talos.pipeline.json
: > "$GH_REST_LOG"; : > "$CURL_LOG"
printf '%s\n' "$PR9" > "$SANDBOX/q.sel"
out="$(STUB_GH_AUTH=0 CURL_QUEUE="$SANDBOX/q.sel" bash "$VCS" pr-head 9 2>&1)"; rc=$?
assert_eq "0 $SHA" "$rc $out" "github, gh not authenticated: pr-head answers through the token"
assert_contains "$(cat "$CURL_LOG")" "$BASE/pulls/9" "github, gh not authenticated: curl carried the request"
assert_eq "" "$(cat "$GH_REST_LOG")" "github, gh not authenticated: gh carried nothing"

out="$(STUB_GH_AUTH=0 env -u GITHUB_TOKEN -u GH_TOKEN bash "$VCS" pr-head 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "github, no gh login and no token: exit 1"
assert_contains "$out" "GITHUB_TOKEN or GH_TOKEN required" "github, no gh login and no token: says what is missing"

printf '{"vcs":{"provider":"github-api","repo":"acme/widget"}}' > talos.pipeline.json
: > "$GH_REST_LOG"; : > "$CURL_LOG"; printf '%s\n' "$PR9" > "$SANDBOX/q.sel"
out="$(CURL_QUEUE="$SANDBOX/q.sel" bash "$VCS" pr-head 9 2>&1)"
assert_contains "$(cat "$CURL_LOG")" "$BASE/pulls/9" "github-api with gh available: still the token transport"
assert_eq "" "$(cat "$GH_REST_LOG")" "github-api with gh available: gh carried nothing"

# --dry-run needs no credential at all.
out="$(env -u GITHUB_TOKEN -u GH_TOKEN STUB_GH_AUTH=0 bash "$VCS" --dry-run pr-head 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "--dry-run: no credential needed"
assert_contains "$out" "[dry-run]" "--dry-run: prints the planned call"

finish
