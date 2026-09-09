#!/usr/bin/env bash
# test-pipeline-status.sh — regression tests for the token-GraphQL board path
# in pipeline-status.sh (#248).
#
# GitHub's GraphQL API rejects items(first:>100) with an EXCESSIVE_PAGINATION
# error. This file covers:
#   1. items() is paginated (first:100 + after:<cursor>) and finds an issue
#      that only shows up on page 2 of a 108-item project.
#   2. A GraphQL "errors" array on any request (project id, fields, items,
#      add, update) makes the script print talos:board-unverified plus the
#      GraphQL message on stderr, and NEVER the "#N → status" success line,
#      while still exiting 0 (Rule 11: board failures never block the
#      pipeline).
#   3. No request in the script asks for more than 100 records on any
#      connection.
#   4. A page with hasNextPage=true and an empty/null endCursor bails out via
#      talos:board-unverified instead of re-issuing the identical query
#      forever (#248 review follow-up).
#   5. The items() pagination loop is capped at TALOS_BOARD_MAX_PAGES pages
#      and bails out via talos:board-unverified once the cap is hit, instead
#      of looping past it.
#
# Uses the curl stub (CURL_LOG + CURL_QUEUE) — no real network calls.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"

export GITHUB_TOKEN="test-secret-token-12345"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"},
 "board": {"enabled": true, "project_number": 4, "owner": "acme", "status_field": "Status"}}
EOF

USER_RESP='{"data":{"user":{"projectV2":{"id":"PVT_1"}}}}'
FIELDS_RESP='{"data":{"node":{"fields":{"nodes":[{"id":"FIELD_1","name":"Status","options":[{"id":"OPT_READY","name":"Ready"},{"id":"OPT_INPROGRESS","name":"In progress"},{"id":"OPT_INREVIEW","name":"In review"},{"id":"OPT_DONE","name":"Done"},{"id":"OPT_BLOCKED","name":"Blocked"}]}]}}}}'
UPDATE_RESP='{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"ITEM_245"}}}}'

# Page 1: 100 items, none matching issue #245. hasNextPage=true, endCursor set.
PAGE1="$(python3 -c "
import json
items = [{'id': 'item-%d' % i, 'content': {'number': 1000 + i}} for i in range(100)]
print(json.dumps({'data': {'node': {'items': {
    'nodes': items,
    'pageInfo': {'hasNextPage': True, 'endCursor': 'CURSOR_1'}
}}}}))
")"

# Page 2: 8 more items, one of which is issue #245. hasNextPage=false.
PAGE2="$(python3 -c "
import json
items = [{'id': 'p2-%d' % i, 'content': {'number': 2000 + i}} for i in range(8)]
items[3] = {'id': 'ITEM_245', 'content': {'number': 245}}
print(json.dumps({'data': {'node': {'items': {
    'nodes': items,
    'pageInfo': {'hasNextPage': False, 'endCursor': None}
}}}}))
")"

# ── Test 1: pagination finds an item that only exists on page 2 ─────────────
: > "$CURL_LOG"
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$PAGE1" "$PAGE2" "$UPDATE_RESP" > "$CURL_QUEUE"

out="$(bash "$STATUS" 245 "In review" 2>"$SANDBOX/err1.txt")"
rc=$?
log="$(cat "$CURL_LOG")"

assert_eq 0 "$rc" "pipeline-status: exits 0 on a successful paginated update"
assert_contains "$out" "#245 → In review" "pipeline-status: prints the success line once the item is found on page 2"
assert_contains "$log" "ITEM_245" "pipeline-status: update mutation uses the item id resolved from page 2"
assert_contains "$log" "CURSOR_1" "pipeline-status: second items page request carries the cursor from page 1"
assert_not_contains "$log" "first:200" "pipeline-status: no items() request asks for 200 records"
assert_contains "$log" "first:100" "pipeline-status: items() requests are capped at 100 records per page"
assert_contains "$log" "first:50" "pipeline-status: fields() still requests at most 50 records"

# ── Test 2: a GraphQL errors array on the items query fails loud ────────────
: > "$CURL_LOG"
ERROR_RESP='{"data":{"node":null},"errors":[{"type":"EXCESSIVE_PAGINATION","message":"Requesting 200 records on the connection exceeds the first limit of 100 records."}]}'
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$ERROR_RESP" > "$CURL_QUEUE"

out="$(bash "$STATUS" 246 "In review" 2>"$SANDBOX/err2.txt")"
rc=$?
err2="$(cat "$SANDBOX/err2.txt")"

assert_eq 0 "$rc" "pipeline-status: exits 0 even when the items query returns a GraphQL error (Rule 11)"
assert_contains "$out" "talos:board-unverified project=4" "pipeline-status: prints the board-unverified marker on a GraphQL errors array"
assert_not_contains "$out" "#246 → In review" "pipeline-status: never prints the success line when the update never happened"
assert_contains "$err2" "Requesting 200 records" "pipeline-status: GraphQL error message is surfaced on stderr"

# ── Test 3: hasNextPage=true with an empty endCursor bails, doesn't loop ────
: > "$CURL_LOG"
BAD_CURSOR_PAGE='{"data":{"node":{"items":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}'
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$BAD_CURSOR_PAGE" > "$CURL_QUEUE"

out="$(bash "$STATUS" 247 "In review" 2>"$SANDBOX/err3.txt")"
rc=$?
err3="$(cat "$SANDBOX/err3.txt")"
items_calls="$(grep -c 'graphql' "$CURL_LOG")"

assert_eq 0 "$rc" "pipeline-status: exits 0 when a page has hasNextPage=true but an empty endCursor"
assert_contains "$out" "talos:board-unverified project=4" "pipeline-status: prints the board-unverified marker on an empty endCursor"
assert_not_contains "$out" "#247 → In review" "pipeline-status: never prints the success line when pagination bails on empty endCursor"
assert_contains "$err3" "endCursor" "pipeline-status: empty-endCursor bail explains itself on stderr"
assert_eq 3 "$items_calls" "pipeline-status: the identical items() query is NOT re-issued after an empty endCursor (user + fields + one items call only)"

# ── Test 4: the page cap stops pagination instead of looping past it ───────
: > "$CURL_LOG"
CAP_PAGE1='{"data":{"node":{"items":{"nodes":[{"id":"cap-1","content":{"number":9001}}],"pageInfo":{"hasNextPage":true,"endCursor":"CAP_CURSOR_1"}}}}}'
CAP_PAGE2='{"data":{"node":{"items":{"nodes":[{"id":"cap-2","content":{"number":9002}}],"pageInfo":{"hasNextPage":true,"endCursor":"CAP_CURSOR_2"}}}}}'
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$CAP_PAGE1" "$CAP_PAGE2" > "$CURL_QUEUE"

out="$(TALOS_BOARD_MAX_PAGES=2 bash "$STATUS" 248 "In review" 2>"$SANDBOX/err4.txt")"
rc=$?
err4="$(cat "$SANDBOX/err4.txt")"
items_calls="$(grep -c 'graphql' "$CURL_LOG")"

assert_eq 0 "$rc" "pipeline-status: exits 0 once the page cap is reached"
assert_contains "$out" "talos:board-unverified project=4" "pipeline-status: prints the board-unverified marker once the page cap is reached"
assert_not_contains "$out" "#248 → In review" "pipeline-status: never prints the success line when pagination bails on the page cap"
assert_contains "$err4" "pagination exhausted after 2 pages" "pipeline-status: page-cap bail explains itself on stderr"
assert_eq 4 "$items_calls" "pipeline-status: pagination stops at the cap (user + fields + exactly 2 items calls, no 3rd)"

finish
