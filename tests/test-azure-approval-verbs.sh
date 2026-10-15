#!/usr/bin/env bash
# test-azure-approval-verbs.sh -- pr-head, read-comments, check-approval-sha and
# post-approval on the azure provider (#684). Before this fix post-approval
# refused every provider but github, and the azure adapter had no pr-head,
# read-comments or check-approval-sha, so `docs-gate` could not stamp docs:done.
# Uses the tests/stubs/az stub; no credentials needed. Tests are named by the
# spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "markers": {"trusted_authors": ["bot@acme.com"]}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# _pr [<label>...] -- the az PR object at HEAD_SHA carrying the given labels.
_pr() {
  local _l _labels=""
  for _l in "$@"; do _labels="$_labels${_labels:+,}{\"id\":\"1\",\"name\":\"$_l\"}"; done
  printf '{"pullRequestId":9,"status":"active","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"%s"},"labels":[%s]}' \
    "$HEAD_SHA" "$_labels"
}
# _threads <author> <sha> <role> -- one thread whose comment carries the marker.
_threads() {
  printf '{"value":[{"id":1,"comments":[{"id":1,"content":"approved\\n<!-- talos:approval sha=%s role=%s -->","commentType":"text","author":{"displayName":"Some One","uniqueName":"%s"},"publishedDate":"2026-10-15T00:00:00Z"}]}]}' \
    "$2" "$3" "$1"
}

# ── AC1 / AC2: pr-head ────────────────────────────────────────────────────────
out="$(STUB_AZURE_PR_9="$(_pr)" bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 pr-head exits 0"
assert_eq "$HEAD_SHA" "$out" "AC1 pr-head prints the PR's source commit sha"

out="$(STUB_AZURE_PR_SHOW_FAIL=1 bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC2 pr-head exits 1 when the PR cannot be fetched"
assert_eq "" "$out" "AC2 pr-head prints nothing when the PR cannot be fetched"
out="$(STUB_AZURE_PR_9='{"pullRequestId":9,"status":"active"}' bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC2 pr-head exits 1 when the PR has no source commit"
assert_eq "" "$out" "AC2 pr-head prints nothing when the PR has no source commit"

# ── AC3: read-comments ────────────────────────────────────────────────────────
_two='{"value":[
 {"id":1,"comments":[
   {"id":1,"content":"first","commentType":"text","author":{"displayName":"A","uniqueName":"a@acme.com"},"publishedDate":"2026-10-15T00:00:01Z"},
   {"id":2,"content":"sys","commentType":"system","author":{"displayName":"S","uniqueName":"s@acme.com"},"publishedDate":"2026-10-15T00:00:02Z"},
   {"id":3,"content":"gone","commentType":"text","isDeleted":true,"author":{"displayName":"D","uniqueName":"d@acme.com"},"publishedDate":"2026-10-15T00:00:03Z"}]},
 {"id":2,"comments":[
   {"id":1,"content":"second","commentType":"text","author":{"displayName":"No Upn"},"publishedDate":"2026-10-15T00:00:04Z"}]}]}'
out="$(STUB_AZURE_PR_THREADS="$_two" bash "$VCS" read-comments 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC3 read-comments exits 0"
assert_eq "first|a@acme.com|2026-10-15T00:00:01Z
second|No Upn|2026-10-15T00:00:04Z" \
  "$(printf '%s' "$out" | python3 -I -c '
import json, sys
for c in json.load(sys.stdin)["comments"]:
    print("|".join([c["body"], c["author"]["login"], c["createdAt"]]))')" \
  "AC3 read-comments lists every thread comment (system and deleted skipped, displayName fallback)"
out="$(STUB_AZURE_PR_THREADS_FAIL=1 bash "$VCS" read-comments 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC3 read-comments exits 1 when the fetch fails"
assert_eq "" "$out" "AC3 read-comments prints nothing when the fetch fails"

# ── AC4 - AC6: check-approval-sha --stale-list ────────────────────────────────
out="$(STUB_AZURE_PR_9="$(_pr qa:pass)" STUB_AZURE_PR_THREADS="$(_threads bot@acme.com "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC4 a trusted marker at the head sha is current (exit 0)"
assert_contains "$out" "check-approval-sha: all approval labels are current" "AC4 reports all approval labels current"

out="$(STUB_AZURE_PR_9="$(_pr qa:pass)" STUB_AZURE_PR_THREADS="$(_threads bot@acme.com "$OLD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC5 a marker at an older sha is stale (exit 1)"
assert_contains "$out" "stale role=qa label=qa:pass" "AC5 names the stale role and label"

out="$(STUB_AZURE_PR_9="$(_pr qa:pass)" STUB_AZURE_PR_THREADS="$(_threads evil@acme.com "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 a marker from an untrusted author does not count (exit 1)"
assert_contains "$out" "stale role=qa label=qa:pass" "AC6 the label is stale without a trusted marker"

# ── AC7: --evidence-list ──────────────────────────────────────────────────────
cur="$(STUB_AZURE_PR_9="$(_pr qa:pass)" STUB_AZURE_PR_THREADS="$(_threads bot@acme.com "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 --evidence-list exits 0"
miss="$(STUB_AZURE_PR_9="$(_pr qa:pass)" STUB_AZURE_PR_THREADS="$(_threads bot@acme.com "$OLD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"
assert_contains "$cur" "qa" "AC7 evidence names the role"
assert_contains "$cur" "current" "AC7 evidence is current at the head"
assert_contains "$miss" "missing" "AC7 evidence is missing without a marker at the head"

# ── AC8: plain check-approval-sha ─────────────────────────────────────────────
out="$(STUB_AZURE_PR_9="$(_pr)" STUB_AZURE_PR_THREADS='{"value":[]}' bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC8 no approval label on the PR exits 0"
assert_contains "$out" "no approval labels" "AC8 prints the no-approval-labels message"
STUB_AZURE_PR_SHOW_FAIL=1 bash "$VCS" check-approval-sha 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC8 an unreadable PR exits 1"

# ── AC9 - AC11: post-approval ─────────────────────────────────────────────────
_posts() { grep -c '^AZ ARGS: \[rest\] \[--method\] \[post\].*'"$1" "$GH_LOG"; }
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="$(_pr)"

export STUB_AZURE_STATE_DIR="$SANDBOX/state1"; mkdir -p "$STUB_AZURE_STATE_DIR"
: > "$GH_LOG"
out="$(bash "$VCS" post-approval 9 qa --issue 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC9 post-approval exits 0"
assert_contains "$out" "stamp ok" "AC9 prints stamp ok"
assert_eq "1" "$(_posts '/pullRequests/9/threads')" "AC9 posts one thread comment"
assert_eq "<!-- talos:approval sha=$HEAD_SHA role=qa -->" \
  "$(python3 -I -c 'import json,sys;print(json.loads(sys.stdin.readline())["comments"][0]["content"].rstrip().splitlines()[-1])' < "$STUB_AZURE_STATE_DIR/threads")" \
  "AC9 the comment's last line is the marker at the PR's head sha"
assert_eq "qa:pass" "$(cat "$STUB_AZURE_STATE_DIR/labels")" "AC9 adds the qa:pass label"

: > "$GH_LOG"
out="$(bash "$VCS" post-approval 9 qa --issue 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC10 a second post-approval at the same head exits 0"
assert_eq "0" "$(_posts '/pullRequests/9/threads')" "AC10 posts no second comment"
assert_eq "1" "$(_posts '/pullRequests/9/labels')" "AC10 still ensures the label"
assert_contains "$out" "stamp ok" "AC10 still prints stamp ok"

export STUB_AZURE_STATE_DIR="$SANDBOX/state2"; mkdir -p "$STUB_AZURE_STATE_DIR"
printf 'All checks pass.\nSecond line.\n' > body.md
out="$(bash "$VCS" post-approval 9 docs --body-file body.md --issue 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC11 post-approval with --body-file exits 0"
assert_eq "All checks pass.|Second line.||<!-- talos:approval sha=$HEAD_SHA role=docs -->" \
  "$(python3 -I -c 'import json,sys;print("|".join(json.loads(sys.stdin.readline())["comments"][0]["content"].rstrip("\n").split("\n")))' < "$STUB_AZURE_STATE_DIR/threads")" \
  "AC11 the body stays above the marker line"
out="$(bash "$VCS" post-approval 9 reviewer 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC11 reviewer without a body file is refused"
assert_contains "$out" "requires --body-file" "AC11 names the missing body file"
out="$(bash "$VCS" post-approval 9 security 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC11 security without a body file is refused"

finish
