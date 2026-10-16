#!/usr/bin/env bash
# test-gitlab-comment-verbs.sh -- pr-head, read-comments and has-spec on the
# gitlab provider (#736, part 2 of #687). Before this fix the gitlab adapter had
# no pr-head or read-comments arm ("unknown verb") and has-spec refused every
# provider but github, github-api and azure, so the code driver could not route
# a gitlab project. Uses the tests/stubs/glab stub; no credentials needed. Tests
# are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# ── AC1: pr-head ──────────────────────────────────────────────────────────────
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"sha":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","diff_refs":{"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' \
  bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 pr-head exits 0"
assert_eq "$HEAD_SHA" "$out" "AC1 pr-head prints the MR head sha lowercased"
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"diff_refs":{"head_sha":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}}' \
  bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "cccccccccccccccccccccccccccccccccccccccc" "$out" "AC1 pr-head falls back to diff_refs.head_sha"

out="$(STUB_GITLAB_MR_VIEW_FAIL=1 bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC1 pr-head exits 1 when the MR cannot be fetched"
assert_eq "" "$out" "AC1 pr-head prints nothing when the MR cannot be fetched"
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"state":"opened"}' bash "$VCS" pr-head 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC1 pr-head exits 1 when the MR has no sha"
assert_eq "" "$out" "AC1 pr-head prints nothing when the MR has no sha"
out="$(STUB_GITLAB_MR_VIEW="{\"sha\":\"$HEAD_SHA\"}" bash "$VCS" pr-head 'abc' 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC1 pr-head exits 1 for a non-numeric iid"
assert_eq "" "$out" "AC1 pr-head prints nothing for a non-numeric iid"
out="$(STUB_GITLAB_MR_VIEW="{\"sha\":\"$HEAD_SHA\"}" bash "$VCS" pr-head 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC1 pr-head exits 1 without an iid"

# ── AC2: read-comments ────────────────────────────────────────────────────────
_logins() {  # read-comments JSON on stdin -> body|login|createdAt per line
  python3 -I -c '
import json, sys
for c in json.load(sys.stdin)["comments"]:
    print("|".join([c["body"], c["author"]["login"], c["createdAt"]]))'
}
_p1='[{"id":1,"body":"first","system":false,"author":{"username":"alice","name":"Alice"},"created_at":"2026-10-16T00:00:01Z"},
 {"id":2,"body":"assigned to @bob","system":true,"author":{"username":"alice"},"created_at":"2026-10-16T00:00:02Z"}]'
_p2='[{"id":3,"body":"third","system":false,"author":{"username":"bob"},"created_at":"2026-10-16T00:00:03Z"}]'
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_NOTES="$_p1$_p2" bash "$VCS" read-comments 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2 read-comments exits 0"
assert_eq "first|alice|2026-10-16T00:00:01Z
third|bob|2026-10-16T00:00:03Z" "$(printf '%s' "$out" | _logins)" \
  "AC2 read-comments lists every page of the MR's notes (system notes dropped, author.login is the username)"
assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fwidget/merge_requests/9/notes?per_page=100&order_by=created_at&sort=asc" \
  "AC2 read-comments pages the MR notes of the URL-encoded project, oldest first"
out="$(STUB_GITLAB_MR_LIST='[{"iid":7,"title":"sibling","state":"opened"}]' bash "$VCS" read-comments 9 2>/dev/null)"
assert_eq '{"comments": []}' "$out" "AC2 the MR notes are not served from the sibling-MR list"

out="$(STUB_GITLAB_MR_NOTES_FAIL=1 bash "$VCS" read-comments 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC2 read-comments exits 1 when the API fails"
assert_eq "" "$out" "AC2 read-comments prints nothing when the API fails"
out="$(STUB_GITLAB_MR_NOTES='{"message":"404 Not Found"}' bash "$VCS" read-comments 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC2 read-comments exits 1 when the answer is not a list of notes"
assert_eq "" "$out" "AC2 read-comments prints nothing when the answer is not a list of notes"
bash "$VCS" read-comments >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC2 read-comments exits 1 without an id"
bash "$VCS" read-comments 'x;9' >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC2 read-comments exits 1 for a non-numeric id"

# ── AC3: has-spec ─────────────────────────────────────────────────────────────
_issue() {  # <description> <label>... -> raw `glab issue view --output json`
  python3 -I -c '
import json, sys
print(json.dumps({"iid": 5, "title": "t", "description": sys.argv[1], "labels": sys.argv[2:]}))
' "$@"
}
out="$(STUB_GITLAB_ISSUE_VIEW="$(_issue $'## Acceptance criteria\n- [ ] it works')" bash "$VCS" has-spec 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC3 has-spec exits 0 for a body with an acceptance-criteria checklist"
assert_not_contains "$out" "not implemented for provider" "AC3 has-spec no longer refuses gitlab"
STUB_GITLAB_ISSUE_VIEW="$(_issue 'just prose' spec:ready)" bash "$VCS" has-spec 5 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC3 has-spec exits 0 for an issue labelled spec:ready"
STUB_GITLAB_ISSUE_VIEW="$(_issue $'## Problem\nno checklist here' bug)" bash "$VCS" has-spec 5 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC3 has-spec exits 1 for an issue with neither"
out="$(STUB_GITLAB_ISSUE_VIEW_FAIL=1 bash "$VCS" has-spec 5 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC3 has-spec exits 1 when the issue read fails"
assert_contains "$out" "could not fetch issue #5" "AC3 has-spec names the failed fetch"

# ── AC11: --dry-run ───────────────────────────────────────────────────────────
for v in "pr-head 9" "read-comments 9" "has-spec 5"; do
  : > "$GH_LOG"
  out="$(bash "$VCS" --dry-run $v 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC11 --dry-run $v exits 0"
  assert_contains "$out" "[dry-run]" "AC11 --dry-run $v prints a [dry-run] line"
  assert_eq "" "$(cat "$GH_LOG")" "AC11 --dry-run $v calls no glab"
done

finish
