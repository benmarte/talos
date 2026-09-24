#!/usr/bin/env bash
# test-closing-keyword-siblings-cap.sh -- check-closing-keyword's sibling
# fetch on every provider (#319). Before this fix each provider read one
# capped page of open PRs (github --limit 100 with stderr discarded,
# github-api one per_page=100 request, gitlab --per-page 100, azure --top
# 1000), so a sibling past the cap was never seen and a `Closes #N` PR
# merged while sibling work was still open. Now github and gitlab read every
# page; github-api and azure read up to a page cap and, when a probe past it
# finds more PRs, print the reason=siblings-capped marker. A failed or
# unparseable fetch still fails open with the marker, and its error reaches
# stderr. Uses the tests/stubs; no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0

# _prs <count> <key-style> -- a JSON array of <count> open PRs on unrelated
# branches, numbered from 1000. key-style: rest | glab | az.
_prs() {
  python3 -c '
import json, sys
n, style = int(sys.argv[1]), sys.argv[2]
out = []
for i in range(n):
    num, ref = 1000 + i, "feature/other-%d" % i
    if style == "rest":
        out.append({"number": num, "state": "open", "title": "t", "head": {"ref": ref}, "body": "x"})
    elif style == "glab":
        out.append({"iid": num, "state": "opened", "title": "t", "source_branch": ref, "description": "x"})
    else:
        out.append({"pullRequestId": num, "status": "active", "sourceRefName": "refs/heads/" + ref})
print(json.dumps(out))
' "$1" "$2"
}
# _with <json-array> <json-object> <index> -- insert the object at <index>.
_with() {
  python3 -c '
import json, sys
a = json.loads(sys.argv[1]); a.insert(int(sys.argv[3]), json.loads(sys.argv[2])); print(json.dumps(a))
' "$1" "$2" "$3"
}

# ── github (gh api --paginate, every page) ──────────────────────────────────
_self='{"number":9,"state":"open","title":"fix: final","head":{"ref":"fix/issue-42-final"},"body":"Closes #42"}'
_sib='{"number":8,"state":"open","title":"fix: part","head":{"ref":"fix/issue-42-part1"},"body":"Part of #42"}'

# A sibling only on page 2 (past the old --limit 100) is found: the gate blocks.
: > "$GH_LOG"
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 STUB_GH_PRS_RAW="$(_with "$(_prs 99 rest)" "$_self" 0)[$_sib]" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "github: a sibling only on page 2 blocks the merge"
assert_contains "$out" "reference the same issue: #8" "github: names the page-2 sibling"
assert_contains "$(cat "$GH_LOG")" "api --paginate repos/acme/widget/pulls?state=open&per_page=100" \
  "github: reads every page of the open-PR API"

# Exactly 1000 open PRs and no sibling: verified, no false siblings-capped.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 STUB_GH_PRS_RAW="$(_with "$(_prs 999 rest)" "$_self" 0)" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "github: a complete 1000-PR list with no sibling exits 0"
assert_not_contains "$out" "unverified" "github: a complete 1000-PR list prints no marker"

# A failed fetch fails open with the marker, and its error reaches stderr.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 STUB_GH_API_FAIL=prs \
  bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "github: a sibling fetch failure exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "github: a sibling fetch failure prints the marker"
assert_contains "$(cat "$SANDBOX/err")" "HTTP 502" "github: the fetch error is no longer discarded"

# An unparseable page fails open with the marker, never "no siblings".
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 STUB_GH_PRS_RAW="[$_self][{\"number\":8,\"head\":" \
  bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github: an unparseable page exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "github: an unparseable page prints the marker"

# ── github-api (every page via Link headers) ─────────────────────────────────
export GITHUB_TOKEN="test-token"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
_pr='{"number":9,"body":"Closes #42","head":{"ref":"fix/issue-42-final"},"base":{"ref":"main"}}'
_rest_self='{"number":9,"state":"open","title":"fix: final","head":{"ref":"fix/issue-42-final"},"body":"Closes #42"}'
_rest_sib='{"number":8,"state":"open","title":"fix: part","head":{"ref":"fix/issue-42-part1"},"body":"Part of #42"}'
_page2="https://api.github.com/repos/acme/widget/pulls?state=open&per_page=100&page=2"

: > "$CURL_LOG"
printf '%s\n' "$_pr" "$(_with "$(_prs 99 rest)" "$_rest_self" 0)" "[$_rest_sib]" > "$CURL_QUEUE"
printf '\n%s\n\n' "$_page2" > "$CURL_LINK_QUEUE"
out="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "github-api: a sibling only on page 2 blocks the merge"
assert_contains "$out" "reference the same issue: #8" "github-api: names the page-2 sibling"
assert_contains "$(cat "$CURL_LOG")" "$_page2" "github-api: follows the Link header to page 2"

: > "$CURL_LINK_QUEUE"
printf '%s\n' "$_pr" "$(_with "$(_prs 99 rest)" "$_rest_self" 0)" "404" > "$CURL_QUEUE"
printf '\n%s\n\n' "$_page2" > "$CURL_LINK_QUEUE"
out="$(bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "github-api: a failed page exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "github-api: a failed page prints the marker, never 'no siblings'"
assert_contains "$(cat "$SANDBOX/err")" "HTTP 404" "github-api: the page error reaches stderr"

# A malformed (truncated) page 2 that holds a real sibling is a failed page,
# never an empty one: the gate prints the marker instead of passing silently.
printf '%s\n' "$_pr" "$(_with "$(_prs 99 rest)" "$_rest_self" 0)" "[${_rest_sib%\}}" > "$CURL_QUEUE"
printf '\n%s\n\n' "$_page2" > "$CURL_LINK_QUEUE"
out="$(bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "github-api: a malformed page exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "github-api: a malformed page with a sibling prints the marker, never a silent pass"
assert_contains "$(cat "$SANDBOX/err")" "not a JSON array" "github-api: a malformed page is named on stderr"

# _ga_pages <has-next-after-page-100> <probe-body>: queue the PR, 100 full
# pages of unrelated PRs, then the probe of page 101.
_ga_pages() {
  python3 - "$CURL_QUEUE" "$CURL_LINK_QUEUE" "$_pr" "$1" "$2" <<'PY'
import json, sys
queue, links, pr, more, probe = sys.argv[1:]
url = "https://api.github.com/repos/acme/widget/pulls?state=open&per_page=100&page=%d"
with open(queue, "w") as q, open(links, "w") as l:
    q.write(pr + "\n"); l.write("\n")
    for p in range(1, 101):
        q.write(json.dumps([{"number": 10000 + p * 100 + i, "state": "open", "title": "t",
                             "head": {"ref": "o"}, "body": "x"} for i in range(100)]) + "\n")
        l.write((url % (p + 1) if p < 100 or more == "1" else "") + "\n")
    q.write(probe + "\n"); l.write("\n")
PY
}
_ga_pages 1 "[$_rest_sib]"
out="$(bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "github-api: a list past the 100-page cap with no sibling seen exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped" "$out" \
  "github-api: a list past the 100-page cap prints the siblings-capped marker"
assert_contains "$(cat "$SANDBOX/err")" "check the open PRs by hand" "github-api: a capped list warns on stderr"

_ga_pages 0 "[]"
out="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "github-api: exactly 100 full pages and an empty probe exits 0"
assert_not_contains "$out" "unverified" "github-api: exactly 100 full pages is complete, not capped"
: > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
unset GITHUB_TOKEN

# ── gitlab (glab api --paginate) ─────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
_mr='{"iid":9,"description":"Closes #42"}'
_gl_self='{"iid":9,"state":"opened","title":"a","source_branch":"fix/issue-42-final","description":"Closes #42"}'
_gl_sib='{"iid":11,"state":"opened","title":"b","source_branch":"fix/issue-42-part1","description":"Part of #42"}'

: > "$GH_LOG"
out="$(STUB_GITLAB_MR_VIEW="$_mr" STUB_GITLAB_MR_PAGES="$(_with "$(_prs 99 glab)" "$_gl_self" 0)[$_gl_sib]" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "gitlab: a sibling only on page 2 blocks the merge"
assert_contains "$out" "reference the same issue: #11" "gitlab: names the page-2 sibling"
assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fwidget/merge_requests?state=opened&per_page=100" \
  "gitlab: reads every page of the opened-MR API"

out="$(STUB_GITLAB_MR_VIEW="$_mr" STUB_GITLAB_API_FAIL=1 \
  bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "gitlab: a sibling fetch failure exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "gitlab: a sibling fetch failure prints the marker"
assert_contains "$(cat "$SANDBOX/err")" "500 Internal Server Error" "gitlab: the fetch error is no longer discarded"

out="$(STUB_GITLAB_MR_VIEW="$_mr" STUB_GITLAB_MR_PAGES='[{"iid":9}]{"message":' \
  bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "gitlab: an unparseable page exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "gitlab: an unparseable page prints the marker, never 'no siblings'"
git remote set-url origin git@github.com:acme/widget.git

# ── azure (--top/--skip pages, capped at 10) ─────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
_rel9='[{"rel":"ArtifactLink","url":"vstfs:///Git/PullRequestId/p1%2Fr1%2F9"}]'
_rel911='[{"rel":"ArtifactLink","url":"vstfs:///Git/PullRequestId/p1%2Fr1%2F9"},{"rel":"ArtifactLink","url":"vstfs:///Git/PullRequestId/p1%2Fr1%2F11"}]'
export STUB_AZURE_PR_WORKITEMS='[{"id":42}]'

: > "$GH_LOG"
out="$(STUB_AZURE_WORKITEM_RELATIONS="$_rel9" STUB_AZURE_PR_LIST_SKIP_0="$(_prs 1000 az)" \
  STUB_AZURE_PR_LIST_SKIP_1000='[{"pullRequestId":12,"status":"active","sourceRefName":"refs/heads/fix/issue-42-b"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "azure: a sibling only on page 2 blocks the merge"
assert_contains "$out" "reference the same issue: #12" "azure: names the page-2 sibling"
assert_contains "$(cat "$GH_LOG")" "[--skip] [1000]" "azure: asks for the page after the first 1000"

: > "$GH_LOG"
out="$(STUB_AZURE_WORKITEM_RELATIONS="$_rel9" STUB_AZURE_PR_LIST_FULL=1 \
  bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "azure: a list still full after the page cap exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped" "$out" \
  "azure: a capped list prints the siblings-capped marker"
assert_contains "$(cat "$SANDBOX/err")" "check the open PRs by hand" "azure: a capped list warns on stderr"
assert_eq "10" "$(grep -c 'repos\] \[pr\] \[list\] .*\[--top\] \[1000\]' "$GH_LOG")" "azure: stops after 10 pages"
assert_contains "$(cat "$GH_LOG")" "[--top] [1] [--skip] [10000]" "azure: probes once past the page cap"

# Exactly 10000 active PRs: the probe past the cap is empty, so the list is
# complete, not capped.
out="$(STUB_AZURE_WORKITEM_RELATIONS="$_rel9" STUB_AZURE_PR_LIST_FULL=1 STUB_AZURE_PR_LIST_SKIP_10000='[]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "azure: exactly 10 full pages and an empty probe exits 0"
assert_not_contains "$out" "unverified" "azure: exactly 10000 active PRs is complete, not capped"

out="$(STUB_AZURE_WORKITEM_RELATIONS="$_rel911" STUB_AZURE_PR_11='{"pullRequestId":11,"status":"active"}' \
  STUB_AZURE_PR_LIST_FULL=1 bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "azure: a capped list still blocks on a linked sibling"
assert_not_contains "$out" "unverified" "azure: a blocked capped list prints no marker"

out="$(STUB_AZURE_WORKITEM_RELATIONS="$_rel9" STUB_AZURE_PR_LIST_FAIL=1 \
  bash "$VCS" check-closing-keyword 9 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "azure: a sibling fetch failure exits 0 (fail open)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
  "azure: a sibling fetch failure prints the marker"
assert_contains "$(cat "$SANDBOX/err")" "TF400813" "azure: the fetch error is no longer discarded"

# ── SKILL.md Step 4: siblings-capped blocks the merge ────────────────────────
assert_contains "$(cat "$TALOS_ROOT/skills/pipeline/SKILL.md")" \
  'Exception: on `reason=siblings-capped`' "SKILL.md: Step 4 does not merge on siblings-capped"

finish
