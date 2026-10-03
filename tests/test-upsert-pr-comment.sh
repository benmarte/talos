#!/usr/bin/env bash
# test-upsert-pr-comment.sh -- `upsert-pr-comment <pr> --marker <name> --body-file
# <path|->` (#381, epic #334): edit ONE marker comment in place instead of
# posting a new one per stage. Offline: the gh and curl stubs only, with their
# stateful comment store (STUB_COMMENT_STORE), stdin log (GH_STDIN_LOG) and argv
# log (CURL_ARGV_LOG). Every case runs for both providers (github, github-api).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
export GITHUB_TOKEN="test-token-381"
export STUB_COMMENT_STORE="$SANDBOX/store.json"
export GH_STDIN_LOG="$SANDBOX/gh.stdin.log"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
export STUB_CURRENT_USER="owner"
FIX="$SANDBOX/fix"
mkdir -p "$FIX"

NL=$'\n'
MARK='<!-- talos:spend -->'

setp() {  # $1 = provider
  P="$1"
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}}\n' "$P" > talos.pipeline.json
}

reset() {
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  : > "$GH_STDIN_LOG"; : > "$CURL_ARGV_LOG"
  rm -f "$GH_LOG.w429" "$CURL_LOG.w429"
  printf '[]' > "$STUB_COMMENT_STORE"
  export STUB_CURRENT_USER="owner"
  unset STUB_GH_API_FAIL STUB_GH_COMMENTS_RAW STUB_COMMENT_READ_FAIL STUB_COMMENT_WRITE_FAIL \
        STUB_COMMENT_WRITE_429 STUB_CURRENT_USER_STATUS
}

# seed 'login|body' ... -> the stub's comment store (REST shape; \n = newline).
seed() {
  python3 - "$STUB_COMMENT_STORE" "$@" <<'TALOS_PY_Zk3nQ8vWb2Lx'
import json, sys
out = []
for i, a in enumerate(sys.argv[2:]):
    login, body = a.split("|", 1)
    out.append({"id": 100 + i, "user": {"login": login},
                "created_at": "2026-01-01T00:00:%02dZ" % i,
                "html_url": "https://github.com/acme/widget/pull/7#issuecomment-%d" % (100 + i),
                "body": body.replace("\\n", "\n")})
json.dump(out, open(sys.argv[1], "w"))
TALOS_PY_Zk3nQ8vWb2Lx
}

# run <verb args...>: OUT, ERR, RC. stdin is /dev/null (a read of it sees EOF).
run() {
  OUT="$(bash "$VCS" "$@" </dev/null 2>"$SANDBOX/err")"; RC=$?
  ERR="$(cat "$SANDBOX/err")"
}

# upsert <body-file> [extra args]: the verb for PR 7, marker spend.
upsert() { local f="$1"; shift; run upsert-pr-comment 7 --marker spend --body-file "$f" "$@"; }

# writes: one "METHOD issues/..." line per write call, in order.
writes() {
  if [ "$P" = "github" ]; then
    grep -E '^api --method (POST|PATCH) ' "$GH_LOG" \
      | sed -E 's#^api --method ([A-Z]+) repos/[^/]+/[^/]+/(issues/[^ ]+).*#\1 \2#'
  else
    awk -F'\t' '$4=="POST" || $4=="PATCH" {print $4 " " $1}' "$CURL_LOG" \
      | sed 's#https://api.github.com/repos/acme/widget/##'
  fi
}
wcount() { writes | grep -c . || true; }
# any call at all to a stub
calls() { cat "$GH_LOG" "$CURL_LOG" | grep -c . || true; }

store_count() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$STUB_COMMENT_STORE"; }
store_body() {  # $1 = comment id
  python3 -c "
import json, sys
print(next(c for c in json.load(open(sys.argv[1])) if c['id'] == int(sys.argv[2]))['body'], end='')
" "$STUB_COMMENT_STORE" "$1"
}
store_ids() { python3 -c "import json,sys; print(' '.join(str(c['id']) for c in json.load(open(sys.argv[1]))))" "$STUB_COMMENT_STORE"; }

mkbody() { printf '%s' "$2" > "$FIX/$1"; printf '%s' "$FIX/$1"; }

HDR="$(sed -n '1,/^set -/p' "$VCS")"
assert_contains "$HDR" "upsert-pr-comment <pr> --marker <name> --body-file <path|->" "usage header documents upsert-pr-comment"

suite() {
  setp "$1"
  local L="$P"

  # ── create, then unchanged, then update: one comment throughout ───────────
  reset
  B="$(mkbody b1 'Spend so far: 10')"
  upsert "$B"
  assert_eq "0" "$RC" "$L: first call exits 0"
  assert_contains "$OUT" "upserted pr=7 comment=created" "$L: first call reports comment=created"
  assert_eq "POST issues/7/comments" "$(writes)" "$L: first call is one POST to the PR's comments"
  assert_eq "Spend so far: 10${NL}${NL}${MARK}" "$(store_body 5001)" "$L: body is the text, a blank line, then the marker as the last line"
  assert_contains "$OUT" "https://github.com/acme/widget/pull/7#issuecomment-5001" "$L: prints the comment URL"

  upsert "$B"
  assert_eq "0" "$RC" "$L: identical second call exits 0"
  assert_contains "$OUT" "upserted pr=7 comment=unchanged" "$L: identical body reports comment=unchanged"
  assert_eq "1" "$(wcount)" "$L: identical body makes no write call (still one POST)"
  assert_contains "$OUT" "issuecomment-5001" "$L: unchanged still prints the comment URL"

  B2="$(mkbody b2 'Spend so far: 20')"
  upsert "$B2"
  assert_eq "0" "$RC" "$L: changed body exits 0"
  assert_contains "$OUT" "upserted pr=7 comment=updated" "$L: changed body reports comment=updated"
  assert_contains "$OUT" "issuecomment-5001" "$L: updated prints the existing comment URL"
  assert_eq "$(printf 'POST issues/7/comments\nPATCH issues/comments/5001')" "$(writes)" "$L: POST, then one PATCH to the comment id (no PR number in the path)"
  assert_eq "1" "$(store_count)" "$L: two upserts leave exactly one comment"
  assert_eq "Spend so far: 20${NL}${NL}${MARK}" "$(store_body 5001)" "$L: the comment was edited in place"

  # CRLF in the stored copy (GitHub's web editor) and trailing whitespace do not make a body "different".
  reset
  seed "owner|Same text\r\n\r\n$MARK\r\n"
  python3 - "$STUB_COMMENT_STORE" <<'TALOS_PY_Gp4tR7mX1Ca'
import json, sys
d = json.load(open(sys.argv[1])); d[0]["body"] = d[0]["body"].replace("\\r", "\r"); json.dump(d, open(sys.argv[1], "w"))
TALOS_PY_Gp4tR7mX1Ca
  upsert "$(mkbody b3 'Same text')"
  assert_contains "$OUT" "comment=unchanged" "$L: a CRLF copy of the same body is unchanged"
  assert_eq "0" "$(wcount)" "$L: ...and writes nothing"

  # ── ownership and matching ────────────────────────────────────────────────
  reset
  seed "someone-else|Their spend\n\n$MARK"
  upsert "$B"
  assert_contains "$OUT" "comment=created" "$L: a marker comment by anyone else does not prevent the POST"
  assert_eq "POST issues/7/comments" "$(writes)" "$L: another author's marker comment is never edited"
  assert_eq "Their spend${NL}${NL}${MARK}" "$(store_body 100)" "$L: their comment is untouched"
  assert_eq "2" "$(store_count)" "$L: ours was added next to theirs"

  reset
  seed "owner|old one\n\n$MARK" "someone-else|noise" "owner|newest one\n\n$MARK" "someone-else|Their spend\n\n$MARK"
  upsert "$B"
  assert_contains "$OUT" "comment=updated" "$L: edits an existing own comment"
  assert_eq "PATCH issues/comments/102" "$(writes)" "$L: the NEWEST own marker comment is the one patched"
  assert_eq "old one${NL}${NL}${MARK}" "$(store_body 100)" "$L: the older own comment is untouched"

  reset
  seed "owner|quoting $MARK in the middle\nand more text"
  upsert "$B"
  assert_contains "$OUT" "comment=created" "$L: a comment that only mentions the marker mid-body is not a match"

  reset
  export STUB_CURRENT_USER="Owner"
  seed "owner|old\n\n$MARK"
  upsert "$B"
  assert_contains "$OUT" "comment=updated" "$L: the login compare is case-insensitive"
  export STUB_CURRENT_USER="owner"

  reset
  seed "owner|a budget note\n\n<!-- talos:budget -->"
  upsert "$B"
  assert_contains "$OUT" "comment=created" "$L: an own comment with a different marker is not a match"

  # budget is a TALOS_MARKERS member too
  reset
  run upsert-pr-comment 7 --marker budget --body-file "$B"
  assert_eq "0" "$RC" "$L: --marker budget is accepted"
  assert_eq "Spend so far: 10${NL}${NL}<!-- talos:budget -->" "$(store_body 5001)" "$L: the budget marker is appended"

  # ── pagination: the match is on a later page ──────────────────────────────
  reset
  if [ "$P" = "github" ]; then
    export STUB_GH_COMMENTS_RAW
    STUB_GH_COMMENTS_RAW="$(python3 -c "
import json
p1 = [{'id': i, 'user': {'login': 'x'}, 'body': 'n'} for i in range(1, 101)]
p2 = [{'id': 900, 'user': {'login': 'owner'}, 'body': 'old\n\n$MARK', 'html_url': 'u'}]
print(json.dumps(p1) + json.dumps(p2), end='')
")"
    rm -f "$STUB_COMMENT_STORE"
  else
    python3 -c "
import json
p1 = [{'id': i, 'user': {'login': 'x'}, 'body': 'n'} for i in range(1, 101)]
p2 = [{'id': 900, 'user': {'login': 'owner'}, 'body': 'old\n\n$MARK', 'html_url': 'u'}]
print(json.dumps(p1)); print(json.dumps(p2)); print(json.dumps({'id': 900, 'html_url': 'u'}))
" > "$CURL_QUEUE"
    # The first (empty) line is for GET /user, which pops a Link line too.
    printf '\n%s\n\n' 'https://api.github.com/repos/acme/widget/issues/7/comments?per_page=100&page=2' > "$CURL_LINK_QUEUE"
    rm -f "$STUB_COMMENT_STORE"
  fi
  upsert "$B"
  assert_eq "0" "$RC" "$L: a match on page 2 exits 0 (err: $ERR)"
  assert_eq "PATCH issues/comments/900" "$(writes)" "$L: finds the own marker comment past the first 100"
  printf '[]' > "$STUB_COMMENT_STORE"

  # ── argument checks: exit 2, no call ──────────────────────────────────────
  reset
  B="$(mkbody b1 'Spend so far: 10')"
  for bad in bogus 'talos:spend' '' 'spend -->' 'SPEND'; do
    run upsert-pr-comment 7 --marker "$bad" --body-file "$B"
    assert_eq "2" "$RC" "$L: --marker '$bad' exits 2"
  done
  run upsert-pr-comment 7 --body-file "$B"
  assert_eq "2" "$RC" "$L: a missing --marker exits 2"
  run upsert-pr-comment 7 --marker spend
  assert_eq "2" "$RC" "$L: a missing --body-file exits 2"
  run upsert-pr-comment 7 --marker spend -
  assert_eq "2" "$RC" "$L: a bare positional - exits 2"
  run upsert-pr-comment 7 --marker spend --body-file "$B" -
  assert_eq "2" "$RC" "$L: a trailing bare - exits 2"
  run upsert-pr-comment 7 --marker spend --body-file "$B" extra
  assert_eq "2" "$RC" "$L: an extra argument exits 2"
  run upsert-pr-comment abc --marker spend --body-file "$B"
  assert_eq "2" "$RC" "$L: a non-numeric <pr> exits 2"
  run upsert-pr-comment --marker spend --body-file "$B"
  assert_eq "2" "$RC" "$L: a missing <pr> exits 2"
  run upsert-pr-comment 7 --marker spend --body-file "$FIX/nope"
  assert_eq "1" "$RC" "$L: an unreadable body file exits 1"
  assert_eq "0" "$(calls)" "$L: none of the above made a call"

  # ── empty body: non-zero, nothing posted, nothing read ────────────────────
  reset
  upsert "$(mkbody empty '')"
  [ "$RC" -ne 0 ] && pass "$L: an empty body exits non-zero" || fail "$L: an empty body exits non-zero" "rc=$RC"
  upsert "$(mkbody blank $'  \n\n  \n')"
  [ "$RC" -ne 0 ] && pass "$L: a whitespace-only body exits non-zero" || fail "$L: a whitespace-only body exits non-zero" "rc=$RC"
  assert_eq "0" "$(calls)" "$L: an empty body makes no call"

  # ── stdin: --body-file - ──────────────────────────────────────────────────
  reset
  OUT="$(printf 'From stdin\n' | bash "$VCS" upsert-pr-comment 7 --marker spend --body-file - 2>"$SANDBOX/err")"; RC=$?
  assert_eq "0" "$RC" "$L: --body-file - reads the body from stdin"
  assert_eq "From stdin${NL}${NL}${MARK}" "$(store_body 5001)" "$L: the stdin body is posted with the marker"
  reset
  OUT="$(bash "$VCS" upsert-pr-comment 7 --marker spend --body-file - <&- 2>"$SANDBOX/err")"; RC=$?
  assert_eq "1" "$RC" "$L: --body-file - with a closed stdin exits 1"
  assert_eq "0" "$(calls)" "$L: ...and makes no call"

  # ── caps: same as approve-pr, and on the FINAL body ───────────────────────
  reset
  python3 -c "import sys; sys.stdout.write('a' * 65537)" > "$FIX/chars"
  upsert "$FIX/chars"
  assert_eq "1" "$RC" "$L: a body over 65536 characters exits 1"
  python3 -c "import sys; sys.stdout.write('a' * 65536)" > "$FIX/exact"
  upsert "$FIX/exact"
  assert_eq "1" "$RC" "$L: a body that only exceeds 65536 characters once the marker is appended exits 1"
  python3 -c "import sys; sys.stdout.write('€' * 40001)" > "$FIX/bytes"
  upsert "$FIX/bytes"
  assert_eq "1" "$RC" "$L: a body under 65536 characters but over 120000 bytes exits 1"
  assert_eq "0" "$(calls)" "$L: an oversized body makes no call"

  # ── 100 KB body (34000 x 3-byte characters): stdin, never argv ────────────
  reset
  python3 -c "import sys; sys.stdout.write('€' * 34000)" > "$FIX/big"
  upsert "$FIX/big"
  assert_eq "0" "$RC" "$L: a 102000-byte multibyte body exits 0 (err: ${ERR:0:200})"
  assert_contains "$OUT" "comment=created" "$L: the 100 KB body is created"
  python3 - "$STUB_COMMENT_STORE" <<'TALOS_PY_Vb6sT2nQe9Dy' && pass "$L: the API received the whole body, byte for byte" || fail "$L: the API received the whole body, byte for byte" "stored body differs"
import json, sys
body = json.load(open(sys.argv[1]))[0]["body"]
sys.exit(0 if body == "€" * 34000 + "\n\n<!-- talos:spend -->" else 1)
TALOS_PY_Vb6sT2nQe9Dy
  if [ "$P" = "github" ]; then ARGV="$GH_LOG"; else ARGV="$CURL_ARGV_LOG"; fi
  _max="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$ARGV")"
  [ "$_max" -lt 2000 ] && pass "$L: no call's argv is larger than 2000 bytes (max $_max)" || fail "$L: no call's argv is larger than 2000 bytes" "max $_max"
  assert_not_contains "$(cat "$ARGV")" "€" "$L: the body text is never on a command line"
  if [ "$P" = "github" ]; then
    assert_contains "$(grep -- '--method POST' "$GH_LOG")" "--input -" "$L: the write passes --input -"
  else
    assert_contains "$(grep -- 'issues/7/comments' "$CURL_ARGV_LOG" | grep -- '-X POST')" "--data-binary @-" "$L: the write passes --data-binary @-"
  fi

  # ── a retry re-sends the whole body (stdin is read once per attempt) ──────
  reset
  export STUB_COMMENT_WRITE_429=1
  upsert "$B"
  assert_eq "0" "$RC" "$L: a rate-limited write is retried and succeeds (err: ${ERR:0:200})"
  assert_eq "Spend so far: 10${NL}${NL}${MARK}" "$(store_body 5001)" "$L: the retried write carried the full body, not an empty one"
  assert_eq "2" "$(wcount)" "$L: the write was attempted twice"
  if [ "$P" = "github" ]; then
    assert_eq "2" "$(grep -c . "$GH_STDIN_LOG")" "$L: both attempts' stdin were non-empty"
  else
    assert_eq "2" "$(awk -F'\t' '$4=="POST" && $2 != "" {n++} END {print n+0}' "$CURL_LOG")" "$L: both attempts' payloads were non-empty"
  fi
  unset STUB_COMMENT_WRITE_429

  # ── failures: exit 1, nothing (more) posted ───────────────────────────────
  reset
  if [ "$P" = "github" ]; then export STUB_GH_API_FAIL=comments; else export STUB_COMMENT_READ_FAIL=1; fi
  upsert "$B"
  assert_eq "1" "$RC" "$L: a failed comment read exits 1"
  assert_eq "0" "$(wcount)" "$L: a failed read posts nothing (no blind duplicate)"
  unset STUB_GH_API_FAIL STUB_COMMENT_READ_FAIL

  reset
  export STUB_CURRENT_USER=""
  upsert "$B"
  assert_eq "1" "$RC" "$L: an unresolved login exits 1"
  assert_contains "$ERR" "could not resolve" "$L: ...and says why"
  assert_eq "0" "$(wcount)" "$L: an unresolved login writes nothing"
  export STUB_CURRENT_USER="owner"

  if [ "$P" = "github-api" ]; then
    reset
    export STUB_CURRENT_USER_STATUS=403
    upsert "$B"
    assert_eq "1" "$RC" "$L: GET /user answering 403 (Actions GITHUB_TOKEN) exits 1"
    assert_eq "0" "$(wcount)" "$L: ...and writes nothing"
    unset STUB_CURRENT_USER_STATUS
  fi

  reset
  export STUB_COMMENT_WRITE_FAIL=1
  upsert "$B"
  assert_eq "1" "$RC" "$L: a failed POST exits 1"
  assert_not_contains "$OUT" "upserted" "$L: a failed POST does not claim success"
  reset
  seed "owner|old\n\n$MARK"
  export STUB_COMMENT_WRITE_FAIL=1
  upsert "$B"
  assert_eq "1" "$RC" "$L: a failed PATCH exits 1"
  assert_not_contains "$OUT" "upserted" "$L: a failed PATCH does not claim success"
  unset STUB_COMMENT_WRITE_FAIL

  # ── dry-run ───────────────────────────────────────────────────────────────
  reset
  run --dry-run upsert-pr-comment 7 --marker spend --body-file "$B"
  assert_eq "0" "$RC" "$L: --dry-run exits 0"
  assert_contains "$OUT" "[dry-run]" "$L: --dry-run prints the planned calls"
  assert_contains "$OUT" "issues/7/comments" "$L: --dry-run names the comments endpoint"
  assert_contains "$OUT" "issues/comments/<id>" "$L: --dry-run names the PATCH endpoint"
  assert_eq "0" "$(calls)" "$L: --dry-run makes no call"

  # ── a merged PR: no PR-state check, only the comments endpoints ───────────
  reset
  upsert "$B"
  assert_eq "0" "$RC" "$L: works whatever the PR state (exit 0)"
  assert_not_contains "$(cat "$GH_LOG" "$CURL_LOG")" "/pulls/" "$L: never reads the PR (no CLOSED/MERGED refusal)"
  assert_not_contains "$(cat "$GH_LOG")" "pr view" "$L: never runs gh pr view"

  # ── the spend comment is hidden from view-issue --spec, kept in read-comments
  reset
  upsert "$(mkbody b4 'Spend line for the thread')"
  run view-issue 7 --spec
  assert_eq "0" "$RC" "$L: view-issue 7 --spec exits 0 (err: ${ERR:0:200})"
  assert_not_contains "$OUT" "Spend line for the thread" "$L: view-issue --spec drops the spend comment"
  assert_not_contains "$OUT" "talos:spend" "$L: view-issue --spec carries no talos:spend marker"
  run read-comments 7
  assert_contains "$OUT" "Spend line for the thread" "$L: read-comments still returns it"
}

suite github
suite github-api

# ── providers without an implementation: exit 2, no call, before any read ────
for prov in gitlab azure file; do
  setp "$prov"
  reset
  OUT="$(bash "$VCS" upsert-pr-comment 7 --marker spend --body-file "$FIX/nope-$prov" <&- 2>"$SANDBOX/err")"; RC=$?
  ERR="$(cat "$SANDBOX/err")"
  assert_eq "2" "$RC" "$prov: upsert-pr-comment exits 2"
  assert_contains "$ERR" "not implemented for provider '$prov'" "$prov: says it is not implemented for this provider"
  assert_eq "0" "$(calls)" "$prov: makes no call"
done

finish
