#!/usr/bin/env bash
# Regression test for #324/#329: _ga_fetch_all_pages (scripts/pipeline-vcs.sh)
# passes the merged list and each page to python on stdin, not environment
# variables, because a single env string is capped at 128 KB on Linux
# (E2BIG). A busy repo's page can exceed that easily. This test serves one
# valid JSON-array page of well over 256 KB and asserts list-prs still
# succeeds, parses, and returns every item -- if a future edit reintroduces
# passing the page through an env var, this fails with E2BIG on Linux CI.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export GITHUB_TOKEN=t
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}' > talos.pipeline.json

# One page, 1500 PRs, each with a long body -- comfortably over 256 KB and
# well past Linux's 128 KB single-env-string limit.
PR_COUNT=1500
_large_page() {
  COUNT="$1" python3 -c "
import json, os
body = 'x' * 400
print(json.dumps([{'number': i, 'title': 't%d' % i, 'head': {'ref': 'b%d' % i},
                    'labels': [], 'body': body}
                   for i in range(1, int(os.environ['COUNT']) + 1)]))
"
}
_page="$(_large_page "$PR_COUNT")"
_page_bytes=${#_page}
[ "$_page_bytes" -gt 262144 ] || { echo "test setup error: page only $_page_bytes bytes" >&2; exit 1; }

printf '%s\n' "$_page" > "$CURL_QUEUE"
printf '\n' > "$CURL_LINK_QUEUE"   # no next page

out="$(bash "$VCS" list-prs 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "#329 github-api: list-prs succeeds on a page over 256 KB (E2BIG guard)"
count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)"
assert_eq "$PR_COUNT" "$count" "#329 github-api: every item on the large page is returned"

finish
