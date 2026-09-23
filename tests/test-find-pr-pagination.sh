#!/usr/bin/env bash
# Regression tests for #302: the find-pr merged lookup (the Step 1 heal's
# source) must not silently truncate. github-api paginates via Link headers
# up to a page cap and warns when the cap is hit; github warns when
# `gh pr list` returns exactly --limit results.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0

# _302_prs <first> <last> [merged] -- REST-shaped closed PRs, none closing #500.
_302_prs() {
  FIRST="$1" LAST="$2" MERGED="${3:-}" python3 -c "
import json, os
m = os.environ['MERGED'] or None
print(json.dumps([{'number': i, 'state': 'closed', 'merged_at': m, 'title': 't%d' % i,
                   'head': {'ref': 'b%d' % i}, 'body': 'unrelated'}
                  for i in range(int(os.environ['FIRST']), int(os.environ['LAST']) + 1)]))
"
}

# ── github-api ────────────────────────────────────────────────────────────────
export GITHUB_TOKEN=t
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}' > talos.pipeline.json
_302_next="https://api.github.com/repos/acme/widget/pulls?state=closed&per_page=100&page=2"

# The merged PR closing #500 sits on page 2, behind 100 closed-unmerged PRs.
_302_hit='[{"number":7,"state":"closed","merged_at":"2026-09-01T00:00:00Z","title":"fix: old","head":{"ref":"chore/x"},"body":"Closes #500"}]'
printf '%s\n' "$_302_next" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$(_302_prs 101 200)" "$_302_hit" > "$CURL_QUEUE"
out="$(bash "$VCS" find-pr 500 merged 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "#302 github-api: find-pr merged exits 0 across pages"
assert_contains "$out" '"number": 7' "#302 github-api: a merged PR only on page 2 is found"
assert_eq "2" "$(grep -c '/pulls?state=closed' "$CURL_LOG")" "#302 github-api: find-pr follows the Link header to page 2"
assert_not_contains "$(cat "$SANDBOX/err")" "WARNING" "#302 github-api: no cap warning when the list is exhausted"

# Every page advertises a next page: stop at the cap and say so.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf '%s&n=%s\n' "$_302_next" "$_i" >> "$CURL_LINK_QUEUE"
  _302_prs "$_i" "$_i" >> "$CURL_QUEUE"
done
out="$(bash "$VCS" find-pr 500 merged 2>"$SANDBOX/err")"; rc=$?
err="$(cat "$SANDBOX/err")"
assert_eq "0" "$rc" "#302 github-api: find-pr still exits 0 at the page cap"
assert_eq "10" "$(grep -c '/pulls?state=closed' "$CURL_LOG")" "#302 github-api: find-pr stops at the 10-page cap"
assert_contains "$err" "find-pr: WARNING result capped at 10 pages" "#302 github-api: the cap warning names the cap"

# A failed page must fail find-pr, not read as "no merged PR" (#302 review).
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' "$_302_next" > "$CURL_LINK_QUEUE"
printf '%s\n' "$(_302_prs 101 200)" '401:{"message":"Bad credentials"}' > "$CURL_QUEUE"
out="$(bash "$VCS" find-pr 500 merged 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "#302 github-api: a failed page makes find-pr exit non-zero"
assert_eq "" "$out" "#302 github-api: a failed page prints no partial result"

out="$(bash "$VCS" --dry-run find-pr 500 merged)"
assert_contains "$out" "pulls?state=closed&per_page=100 (paginated via Link headers, up to 10 pages)" \
  "#302 github-api: --dry-run describes the paginated request"

# ── github ────────────────────────────────────────────────────────────────────
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}' > talos.pipeline.json
_302_gh() {
  COUNT="$1" python3 -c "
import json, os
print(json.dumps([{'number': i, 'state': 'MERGED', 'title': 't', 'headRefName': 'b%d' % i, 'body': ''}
                  for i in range(1, int(os.environ['COUNT']) + 1)]))
"
}
STUB_PR_LIST="$(_302_gh 100)" bash "$VCS" find-pr 500 merged >/dev/null 2>"$SANDBOX/err"
assert_contains "$(cat "$SANDBOX/err")" "find-pr: WARNING result capped at 100 (gh pr list --limit ceiling)" \
  "#302 github: a result count equal to --limit warns"
STUB_PR_LIST="$(_302_gh 99)" bash "$VCS" find-pr 500 merged >/dev/null 2>"$SANDBOX/err"
assert_not_contains "$(cat "$SANDBOX/err")" "WARNING" "#302 github: a result under --limit does not warn"

GH_FAIL_STDERR="HTTP 401: Bad credentials" bash "$VCS" find-pr 500 merged >"$SANDBOX/out" 2>"$SANDBOX/err"; rc=$?
assert_eq "1" "$rc" "#302 github: a failed gh pr list makes find-pr exit non-zero"
assert_eq "" "$(cat "$SANDBOX/out")" "#302 github: a failed gh pr list prints no result"
assert_contains "$(cat "$SANDBOX/err")" "Bad credentials" "#302 github: gh's own error reaches stderr"

rm -f talos.pipeline.json
finish
