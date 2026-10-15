#!/usr/bin/env bash
# test-azure-attempt-verbs.sh -- read-comments --work-item, read-attempt,
# record-attempt and check-attempt on the azure provider (#685), and the login
# rule behind them: an author with no uniqueName is never trusted. Uses the
# tests/stubs/az stub; no credentials needed. Tests are named by the spec's
# criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "markers": {"trusted_authors": ["bot@acme.com"]},
 "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"
export STUB_CURRENT_USER="bot@acme.com"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# _wi <author-unique-name> <count> <total> -- a work-item comment REST body
# whose comment carries a developer attempt marker.
_wi() {
  printf '{"comments":[{"id":1,"text":"Talos attempt record\\n<!-- talos:attempt stage=developer count=%s total=%s -->","createdBy":{"displayName":"Some One","uniqueName":"%s"},"createdDate":"2026-10-15T00:00:00Z"}]}' \
    "$2" "$3" "$1"
}
_logins() {  # read-comments JSON on stdin -> body|login|createdAt per line
  python3 -I -c '
import json, sys
for c in json.load(sys.stdin)["comments"]:
    print("|".join([c["body"], c["author"]["login"], c["createdAt"]]))'
}

# ── AC1: record-attempt then read-attempt round trip ─────────────────────────
export STUB_AZURE_STATE_DIR="$SANDBOX/state1"; mkdir -p "$STUB_AZURE_STATE_DIR"
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
out="$(bash "$VCS" record-attempt 5 developer 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 record-attempt exits 0 under the ceilings"
assert_eq "stage=developer count=1 total=1" "$out" "AC1 record-attempt prints the new counts"
assert_eq "<!-- talos:attempt stage=developer count=1 total=1 -->" \
  "$(python3 -I -c 'import json,sys;print(json.loads(sys.stdin.readline())["text"].rstrip().splitlines()[-1])' < "$STUB_AZURE_STATE_DIR/wi_posts")" \
  "AC1 the marker is the last line of the posted comment, unconverted"
out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 read-attempt exits 0"
assert_eq "stage=developer count=1 total=1" "$out" "AC1 read-attempt reads back the recorded marker"
out="$(bash "$VCS" record-attempt 5 developer 2>/dev/null)"
assert_eq "stage=developer count=2 total=2" "$out" "AC1 a second record-attempt increments from the newest marker"
unset STUB_AZURE_STATE_DIR STUB_AZURE_POST_AUTHOR

# ── AC2: no marker ────────────────────────────────────────────────────────────
out="$(STUB_AZURE_WI_COMMENTS='{"comments":[]}' bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2 read-attempt exits 0 with no marker"
assert_eq "stage= count=0 total=0" "$out" "AC2 read-attempt prints zero counts with no marker"

# ── AC3: read-comments --work-item ────────────────────────────────────────────
_p1='{"comments":[
 {"id":1,"text":"first","createdBy":{"displayName":"A","uniqueName":"a@acme.com"},"createdDate":"2026-10-15T00:00:01Z"},
 {"id":2,"text":"gone","isDeleted":true,"createdBy":{"displayName":"D","uniqueName":"d@acme.com"},"createdDate":"2026-10-15T00:00:02Z"}],
 "continuationToken":"tok2"}'
_p2='{"comments":[
 {"id":3,"text":"third","createdBy":{"displayName":"C","uniqueName":"c@acme.com"},"createdDate":"2026-10-15T00:00:03Z"}]}'
out="$(STUB_AZURE_WI_COMMENTS_PAGE_first="$_p1" STUB_AZURE_WI_COMMENTS_PAGE_tok2="$_p2" \
  bash "$VCS" read-comments 5 --work-item 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC3 read-comments --work-item exits 0"
assert_eq "first|a@acme.com|2026-10-15T00:00:01Z
third|c@acme.com|2026-10-15T00:00:03Z" "$(printf '%s' "$out" | _logins)" \
  "AC3 read-comments --work-item follows the continuation token and skips deleted comments"
out="$(STUB_AZURE_WI_COMMENTS_PAGE_first="$_p1" STUB_AZURE_WI_COMMENTS_PAGE_tok2="$_p2" STUB_AZURE_WI_FAIL_TOKEN=tok2 \
  bash "$VCS" read-comments 5 --work-item 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC3 read-comments --work-item exits 1 when a later page fails"
assert_eq "" "$out" "AC3 read-comments --work-item prints nothing when a later page fails"
out="$(STUB_AZURE_PR_THREADS='{"value":[{"id":1,"comments":[{"id":1,"content":"pr thread","commentType":"text","author":{"displayName":"A","uniqueName":"a@acme.com"},"publishedDate":"2026-10-15T00:00:01Z"}]}]}' \
  STUB_AZURE_WI_COMMENTS="$_p2" bash "$VCS" read-comments 9 2>/dev/null)"
assert_eq "pr thread|a@acme.com|2026-10-15T00:00:01Z" "$(printf '%s' "$out" | _logins)" \
  "AC3 read-comments without the flag still reads PR threads"

# ── AC4: check-attempt ────────────────────────────────────────────────────────
out="$(STUB_AZURE_WI_COMMENTS="$(_wi bot@acme.com 3 4)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 check-attempt exits 1 at max_fix_attempts"
assert_contains "$out" "check-attempt: BLOCKED — developer consecutive attempts (3) >= max_fix_attempts (3)" "AC4 names the per-stage ceiling"
out="$(STUB_AZURE_WI_COMMENTS="$(_wi bot@acme.com 1 10)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 check-attempt exits 1 at max_total_dispatches"
assert_contains "$out" "check-attempt: BLOCKED — total dispatches (10) >= max_total_dispatches (10)" "AC4 names the total ceiling"
out="$(STUB_AZURE_WI_COMMENTS="$(_wi bot@acme.com 1 2)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC4 check-attempt exits 0 below the ceilings"
assert_contains "$out" "check-attempt: ok (stage=developer count=1 total=2" "AC4 reports ok with the counts"

# ── AC5: untrusted author ─────────────────────────────────────────────────────
out="$(STUB_AZURE_WI_COMMENTS="$(_wi mallory@evil.com 2 2)" bash "$VCS" read-attempt 5 2>/dev/null)"
assert_eq "stage= count=0 total=0" "$out" "AC5 read-attempt ignores a marker from an untrusted author"
out="$(STUB_AZURE_WI_COMMENTS="$(_wi mallory@evil.com 3 10)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC5 check-attempt ignores a marker from an untrusted author"

# ── AC6: empty uniqueName never trusted ───────────────────────────────────────
_noupn='{"comments":[{"id":1,"text":"Talos attempt record\n<!-- talos:attempt stage=developer count=2 total=2 -->","createdBy":{"displayName":"bot@acme.com"},"createdDate":"2026-10-15T00:00:00Z"}]}'
out="$(STUB_AZURE_WI_COMMENTS="$_noupn" bash "$VCS" read-attempt 5 2>/dev/null)"
assert_eq "stage= count=0 total=0" "$out" "AC6 a displayName equal to a trusted login does not trust a work-item marker"
out="$(STUB_AZURE_WI_COMMENTS="$_noupn" bash "$VCS" read-comments 5 --work-item 2>/dev/null)"
assert_eq "Talos attempt record
<!-- talos:attempt stage=developer count=2 total=2 -->||2026-10-15T00:00:00Z" "$(printf '%s' "$out" | _logins)" \
  "AC6 work-item comments leave the login empty without a uniqueName"
out="$(STUB_AZURE_PR_THREADS='{"value":[{"id":1,"comments":[{"id":1,"content":"x","commentType":"text","author":{"displayName":"bot@acme.com"},"publishedDate":"2026-10-15T00:00:01Z"}]}]}' \
  bash "$VCS" read-comments 9 2>/dev/null)"
assert_eq "x||2026-10-15T00:00:01Z" "$(printf '%s' "$out" | _logins)" \
  "AC6 PR-thread comments leave the login empty without a uniqueName"

# ── AC7: --pr / --idempotency-key / --dry-run ─────────────────────────────────
export STUB_AZURE_STATE_DIR="$SANDBOX/state2"; mkdir -p "$STUB_AZURE_STATE_DIR"
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"status\":\"active\",\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD_SHA\"}}"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC7 record-attempt --pr exits 0"
assert_eq "stage=developer count=1 total=1" "$out" "AC7 record-attempt --pr prints the new counts"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 2>&1)"
assert_contains "$out" "duplicate --idempotency-key 'developer-$HEAD_SHA'" "AC7 --pr replays on the same head sha"
assert_eq "1" "$(wc -l < "$STUB_AZURE_STATE_DIR/wi_posts" | tr -d ' ')" "AC7 the replay posts nothing"
assert_contains "$(bash "$VCS" read-attempt 5 2>/dev/null)" "key=developer-$HEAD_SHA" "AC7 the key is stored in the marker"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 --idempotency-key abc 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 --pr with --idempotency-key is refused"
assert_contains "$out" "mutually exclusive" "AC7 names the conflict"
bash "$VCS" record-attempt 5 qa --idempotency-key abc.1 >/dev/null 2>&1
out="$(bash "$VCS" record-attempt 5 qa --idempotency-key abc.1 2>&1)"
assert_contains "$out" "duplicate --idempotency-key 'abc.1'" "AC7 --idempotency-key replays"
unset STUB_AZURE_STATE_DIR STUB_AZURE_POST_AUTHOR STUB_AZURE_PR_9

export STUB_AZURE_STATE_DIR="$SANDBOX/state3"; mkdir -p "$STUB_AZURE_STATE_DIR"
for v in "read-comments 5 --work-item" "read-attempt 5" "check-attempt 5" "record-attempt 5 developer"; do
  out="$(bash "$VCS" --dry-run $v 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC7 --dry-run $v exits 0"
  assert_contains "$out" "[dry-run]" "AC7 --dry-run $v prints a [dry-run] line"
done
assert_file_absent "$STUB_AZURE_STATE_DIR/wi_posts" "AC7 --dry-run writes nothing"

finish
