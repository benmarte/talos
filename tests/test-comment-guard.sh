#!/usr/bin/env bash
# test-comment-guard.sh — closed-target guard and comment URL return for
# comment-issue and comment-pr (issue #55).
#
# Covers all 10 [test] acceptance criteria, each once per GitHub transport (the
# gh transport and the token transport answer the same queued REST responses):
#  1. comment-issue on closed issue exits non-zero, prints state to stderr,
#     no comment posted
#  3. comment-issue --allow-closed on closed issue succeeds, prints html_url
#  5. comment-issue on open issue succeeds, prints html_url
#  6. comment-pr on closed-unmerged PR exits non-zero
#  7. comment-pr on merged PR succeeds, returns html_url
#  8. comment-pr --allow-closed on closed-unmerged PR succeeds, prints html_url
#  9. comment-pr on open PR succeeds, prints html_url — both providers
# 10. State-check failure → proceed + warning to stderr + talos:comment-state-unverified on stdout
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERIA 1-10, once per GitHub transport (github_leg gh | curl): the same
# queued REST responses drive both, so the two legs must agree.
# ═════════════════════════════════════════════════════════════════════════════
for LEG in gh curl; do
  github_leg "$LEG"

  # 1/2. comment-issue on a closed issue -> exit 1, the state on stderr, no comment POSTed
  : > "$CURL_LOG"
  printf '%s\n' '{"state":"closed","title":"issue 5"}' > "$CURL_QUEUE"
  err="$(bash "$VCS" comment-issue 5 "body" 2>&1 >/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$LEG/comment-issue: closed issue exits 1"
  assert_contains "$err" "CLOSED" "$LEG/comment-issue: state printed to stderr"
  assert_not_contains "$(cat "$CURL_LOG")" "POST" "$LEG/comment-issue: no comment POST on closed issue"

  # 3/4. --allow-closed on a closed issue succeeds and prints the html_url (and reads no state)
  : > "$CURL_LOG"
  printf '%s\n' '{"id":200,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-200"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "body" --allow-closed 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: --allow-closed exits 0"
  assert_contains "$out" "issuecomment-200" "$LEG/comment-issue: --allow-closed returns html_url"
  assert_not_contains "$out" "talos:comment-state-unverified" "$LEG/comment-issue: --allow-closed does not emit the state-unverified marker"
  assert_eq "1" "$(grep -c . "$CURL_LOG")" "$LEG/comment-issue: --allow-closed makes one request, the POST"

  # 5. open issue -> html_url, and the body is the payload
  : > "$CURL_LOG"
  printf '%s\n' '{"state":"open","title":"issue 5"}' \
    '{"id":201,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-201"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "findings body" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: open issue exits 0"
  assert_contains "$out" "issuecomment-201" "$LEG/comment-issue: open issue returns html_url on stdout"
  assert_contains "$(cat "$CURL_LOG")" '{"body": "findings body"}' "$LEG/comment-issue: the body is the JSON payload"

  # 6. comment-pr on a closed-unmerged PR
  : > "$CURL_LOG"
  printf '%s\n' '{"state":"closed","merged_at":null,"number":9}' > "$CURL_QUEUE"
  err="$(bash "$VCS" comment-pr 9 "body" 2>&1 >/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$LEG/comment-pr: closed-unmerged PR exits 1"
  assert_contains "$err" "CLOSED" "$LEG/comment-pr: closed state printed to stderr"
  assert_not_contains "$(cat "$CURL_LOG")" "POST" "$LEG/comment-pr: no comment POST on a closed PR"

  # 7. comment-pr on a merged PR succeeds
  printf '%s\n' '{"state":"closed","merged_at":"2026-08-01T12:00:00Z","number":9}' \
    '{"id":202,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-202"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-pr 9 "post-merge note" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-pr: merged PR exits 0"
  assert_contains "$out" "issuecomment-202" "$LEG/comment-pr: merged PR returns html_url"

  # 8. comment-pr --allow-closed
  printf '%s\n' '{"id":203,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-203"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-pr 9 "body" --allow-closed 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-pr: --allow-closed exits 0"
  assert_contains "$out" "issuecomment-203" "$LEG/comment-pr: --allow-closed returns html_url"

  # 9. comment-pr on an open PR
  printf '%s\n' '{"state":"open","merged_at":null,"number":9}' \
    '{"id":204,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-204"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-pr 9 "review done" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-pr: open PR exits 0"
  assert_contains "$out" "issuecomment-204" "$LEG/comment-pr: open PR returns html_url"

  # 10. the state read fails (HTTP 500): proceed, warn on stderr, flag it on stdout
  printf '%s\n' '500' \
    '{"id":205,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-205"}' > "$CURL_QUEUE"
  out="$(TALOS_RETRY_SLEEP_SCALE=0 bash "$VCS" comment-issue 5 "body" 2>"$SANDBOX/state.err")"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: state-check failure exits 0 (fail-open)"
  assert_contains "$(cat "$SANDBOX/state.err")" "warning" "$LEG/comment-issue: state-check failure prints a warning to stderr"
  assert_contains "$out" "issuecomment-205" "$LEG/comment-issue: state-check failure still returns html_url"
  assert_contains "$out" "talos:comment-state-unverified" "$LEG/comment-issue: state-check failure emits the marker on stdout"
  assert_contains "$out" "issue#5" "$LEG/comment-issue: the state-unverified marker includes the target"

  # Post-merge scenario: GitHub closed the issue via "Closes #N" at merge.
  printf '%s\n' '{"state":"closed","title":"issue 42"}' > "$CURL_QUEUE"
  bash "$VCS" comment-issue 42 "closed body" >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "$LEG/regression/post-merge: comment-issue on a CLOSED issue without --allow-closed fails"
  printf '%s\n' '{"id":206,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-206"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 42 "closed body" --allow-closed 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/regression/post-merge: comment-issue on a CLOSED issue WITH --allow-closed succeeds"
  assert_contains "$out" "issuecomment-206" "$LEG/regression/post-merge: --allow-closed on a closed issue returns the URL"
done
unset GITHUB_TOKEN GH_QUEUE GH_LINK_QUEUE GH_REST_LOG

# ═════════════════════════════════════════════════════════════════════════════
# #449: a positional body of exactly "-" is refused before provider dispatch.
# "-" is not stdin for a positional (only `--body-file -` is); it used to post a
# one-character comment and exit 0, losing the hand-off text (#349).
# ═════════════════════════════════════════════════════════════════════════════
printf '# plan\n\n- [ ] Item one <!-- id: 1 -->\n' > plan.md
for _449_p in github github-api gitlab azure file; do
  case "$_449_p" in
    github-api) printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}\n' > talos.pipeline.json ;;
    azure)      printf '{"vcs": {"provider": "azure", "repo": "myrepo"}}\n' > talos.pipeline.json ;;
    file)       printf '{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}\n' > talos.pipeline.json ;;
    *)          printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}}\n' "$_449_p" > talos.pipeline.json ;;
  esac
  export GITHUB_TOKEN="test-token-449"
  for _449_v in comment-issue comment-pr; do
    : > "$GH_LOG"; : > "$CURL_LOG"; _449_plan="$(cat plan.md)"
    out="$(bash "$VCS" "$_449_v" 7 - 2>&1)"; rc=$?
    assert_eq "1" "$rc" "#449 $_449_p/$_449_v: a positional '-' body exits 1"
    assert_contains "$out" "--body-file -" "#449 $_449_p/$_449_v: the hint names the stdin form"
    assert_eq "" "$(cat "$GH_LOG")$(cat "$CURL_LOG")" "#449 $_449_p/$_449_v: nothing reached the provider"
    assert_eq "$_449_plan" "$(cat plan.md)" "#449 $_449_p/$_449_v: nothing was written to the plan file"
    out="$(bash "$VCS" "$_449_v" 7 --body - 2>&1)"; rc=$?
    assert_eq "1" "$rc" "#449 $_449_p/$_449_v: '--body -' is refused the same way"
  done
done
unset GITHUB_TOKEN
# The stdin form is untouched, even when the text on stdin is itself "-".
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json
out="$(printf 'from stdin\n' | bash "$VCS" --dry-run comment-issue 7 --body-file - 2>&1)"; rc=$?
assert_eq "0" "$rc" "#449 control: --body-file - still reads stdin"
assert_contains "$out" "body=from stdin" "#449 control: the stdin text is the body"
out="$(printf -- '-\n' | bash "$VCS" --dry-run comment-pr 7 --body-file - 2>&1)"; rc=$?
assert_eq "0" "$rc" "#449 control: a stdin body that is exactly '-' is not refused"
rm -f talos.pipeline.json plan.md

finish
