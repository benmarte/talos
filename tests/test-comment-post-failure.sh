#!/usr/bin/env bash
# test-comment-post-failure.sh — comment POST failure propagation (issue #69), on both GitHub transports.
#
# Covers 6 [test] acceptance criteria:
#  1. gh comment POST fails  → comment-issue exits non-zero          (core regression)
#  2. gh comment POST fails  → comment-pr exits non-zero             (core regression)
#  3. gh comment POST fails  → no talos:comment-state-unverified marker emitted
#  4. gh comment POST fails  → no stdout output (no empty/partial URL)
#  5. gh comment POST succeeds → comment-issue exits 0 and emits URL (PR #68 guard)
#  6. gh comment POST succeeds → comment-pr exits 0 and emits URL    (PR #68 guard)
#  7. state-check-failed + POST succeeds → marker still emitted, exits 0
#  8. --allow-closed still works after the fix
#  9. github-api provider still fails hard on a failed POST
# 10. CHANGELOG has entry for this fix (released in [0.14.0])
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# Every case runs once per GitHub transport (github_leg gh | curl) against the
# same queued REST responses: the state read first, then the comment POST.
URL5='{"id":999,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-999"}'
OPEN_ISSUE='{"state":"open","title":"issue 5"}'
OPEN_PR='{"state":"open","merged_at":null,"number":9}'

for LEG in gh curl; do
  github_leg "$LEG"

  # CRITERIA 1, 4: a failed POST (HTTP 503) -> comment-issue exits non-zero, nothing on stdout
  printf '%s\n' "$OPEN_ISSUE" '503' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$LEG/comment-issue: failed POST exits non-zero [CRITERION 1]"
  assert_eq "" "$out" "$LEG/comment-issue: failed POST produces no stdout output [CRITERION 4]"

  # CRITERION 2: ... and so does comment-pr
  printf '%s\n' "$OPEN_PR" '503' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-pr 9 "body" 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$LEG/comment-pr: failed POST exits non-zero [CRITERION 2]"
  assert_eq "" "$out" "$LEG/comment-pr: failed POST produces no stdout output [CRITERION 9b]"

  # CRITERION 3: state read failed AND the POST failed -> the unverified marker is NOT emitted
  # (without the exit-on-failed-POST guard the marker WOULD be emitted: discriminating)
  printf '%s\n' '500' '503' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$LEG/comment-issue: state-check-failed + failed POST exits non-zero"
  assert_not_contains "$out" "talos:comment-state-unverified" \
    "$LEG/comment-issue: failed POST does not emit state-unverified marker [CRITERION 3]"

  # CRITERIA 5, 6: a successful POST exits 0 and prints the URL (PR #68 guard)
  printf '%s\n' "$OPEN_ISSUE" "$URL5" > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "findings body" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: successful POST exits 0 [CRITERION 5]"
  assert_contains "$out" "issuecomment-999" "$LEG/comment-issue: successful POST emits html_url [CRITERION 5]"
  assert_not_contains "$out" "talos:comment-state-unverified" "$LEG/comment-issue: successful POST does not emit the marker"
  printf '%s\n' "$OPEN_PR" '{"id":998,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-998"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-pr 9 "review done" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-pr: successful POST exits 0 [CRITERION 6]"
  assert_contains "$out" "issuecomment-998" "$LEG/comment-pr: successful POST emits html_url [CRITERION 6]"

  # CRITERION 7: state read failed + POST succeeded -> marker emitted, exit 0 (PR #79 must not regress)
  printf '%s\n' '500' '{"id":888,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-888"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: state-check-fail + POST success exits 0 [CRITERION 7]"
  assert_contains "$out" "talos:comment-state-unverified" "$LEG/comment-issue: state-check-fail + POST success emits marker [CRITERION 7]"
  assert_contains "$out" "issuecomment-888" "$LEG/comment-issue: state-check-fail + POST success emits URL [CRITERION 7]"

  # CRITERION 8: --allow-closed still works (PR #68 guard)
  printf '%s\n' "$URL5" > "$CURL_QUEUE"
  out="$(bash "$VCS" comment-issue 5 "body" --allow-closed 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$LEG/comment-issue: --allow-closed on a closed issue exits 0 [CRITERION 8]"
  assert_contains "$out" "issuecomment-999" "$LEG/comment-issue: --allow-closed returns the URL [CRITERION 8]"
done
unset GH_QUEUE GH_LINK_QUEUE GH_REST_LOG GITHUB_TOKEN

# ═════════════════════════════════════════════════════════════════════════════
# #451: github-api writes fail loudly on a transport failure and keep bodies
# off argv. The curl stub's STUB_CURL_FAIL_RC exits like a refused connection
# (nothing on stdout); its argv guard (STUB_CURL_ARGV_MAX, default 128 KiB)
# fails like Linux's E2BIG, so the large-body cases mean something on macOS.
# ═════════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-451"
export TALOS_RETRY_SLEEP_SCALE=0
export CURL_BIGARG_LOG="$SANDBOX/curl.bigarg.log"

# _reset451 -- clear the curl logs and any failure mode.
_reset451() {
  : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_BIGARG_LOG"
  unset STUB_CURL_FAIL_RC STUB_CURL_FAIL_METHOD
}
# _calls451 <method> -- how many logged curl calls used that HTTP method.
_calls451() { awk -F'\t' -v m="$1" '$4 == m { n++ } END { print n + 0 }' "$CURL_LOG"; }

# 11a: a POST that hits a transport failure (curl exit 7) is an error, and the
# verb makes no follow-up call.
_reset451
export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=POST
out11="$(bash "$VCS" close-issue 5 "done" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "1" "$rc11" "github-api/close-issue: transport failure on the comment exits 1 [#451]"
assert_not_contains "$out11" "Closed issue" \
  "github-api/close-issue: no success line after a transport failure [#451]"
assert_eq "0" "$(_calls451 PATCH)" \
  "github-api/close-issue: the issue is not closed when its comment failed [#451]"
assert_contains "$(cat "$SANDBOX/err11")" "curl failed (exit 7)" \
  "github-api/close-issue: stderr names the curl exit status [#451]"

_reset451
export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=POST
out11="$(bash "$VCS" approve-pr 9 "lgtm" 2>/dev/null)"; rc11=$?
assert_eq "1" "$rc11" "github-api/approve-pr: transport failure exits 1 [#451]"
assert_not_contains "$out11" "Approved PR" \
  "github-api/approve-pr: no 'Approved PR' after a transport failure [#451]"

# comment-issue (state GET fails too -> fail-open warning, then the POST fails)
_reset451
export STUB_CURL_FAIL_RC=7
out11="$(bash "$VCS" comment-issue 5 "body" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "1" "$rc11" "github-api/comment-issue: transport failure exits 1 [#451]"
assert_eq "" "$out11" "github-api/comment-issue: transport failure prints nothing on stdout [#451]"
assert_not_contains "$(cat "$SANDBOX/err11")" "Traceback" \
  "github-api/comment-issue: transport failure leaves no python traceback [#451]"

# label-issue: the add POST fails -> nothing else is sent
_reset451
export STUB_CURL_FAIL_RC=7
out11="$(bash "$VCS" label-issue 5 --add x --remove y 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "1" "$rc11" "github-api/label-issue: transport failure exits 1 [#451]"
assert_not_contains "$out11" "Labels updated" \
  "github-api/label-issue: no success line after a transport failure [#451]"
assert_not_contains "$(cat "$SANDBOX/err11")" "Traceback" \
  "github-api/label-issue: transport failure leaves no python traceback [#451]"
assert_eq "0" "$(_calls451 DELETE)" "github-api/label-issue: no removal follows a failed addition [#451]"

# label-issue / label-pr: a failed removal is an error, never a success line.
for _verb451 in label-issue label-pr; do
  _reset451
  export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=DELETE
  out11="$(bash "$VCS" "$_verb451" 5 --remove x 2>"$SANDBOX/err11")"; rc11=$?
  assert_eq "1" "$rc11" "github-api/$_verb451: a failed removal exits 1 [#451]"
  assert_not_contains "$out11" "Labels updated" "github-api/$_verb451: no success line after a failed removal [#451]"
  assert_not_contains "$(cat "$SANDBOX/err11")" "Traceback" \
    "github-api/$_verb451: a failed removal leaves no python traceback [#451]"
done

# mark-needs-owner: the comments read succeeds, the POST fails -> not "posted",
# and the label call is never made.
_reset451
printf '%s\n' '[]' > "$CURL_QUEUE"
export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=POST
out11="$(bash "$VCS" mark-needs-owner 7 "Which option?" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "1" "$rc11" "github-api/mark-needs-owner: transport failure exits 1 [#451]"
assert_not_contains "$out11" "comment=posted" \
  "github-api/mark-needs-owner: never reports comment=posted after a transport failure [#451]"
assert_eq "1" "$(_calls451 POST)" \
  "github-api/mark-needs-owner: no label call follows the failed comment POST [#451]"

# post-approval: pr-head and the duplicate check succeed, the marker POST fails
# -> exit 1 and no label call.
_reset451
_sha451="$(printf 'a%.0s' $(seq 1 40))"
printf '%s\n%s\n%s\n' \
  "{\"head\":{\"sha\":\"$_sha451\"}}" '[]' '{"state":"open","merged_at":null}' > "$CURL_QUEUE"
export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=POST
out11="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc11=$?
assert_eq "1" "$rc11" "github-api/post-approval: transport failure on the marker POST exits 1 [#451]"
assert_not_contains "$out11" "marker posted" \
  "github-api/post-approval: no success line after a transport failure [#451]"
assert_eq "1" "$(_calls451 POST)" \
  "github-api/post-approval: the label is not applied after a failed marker POST [#451]"
assert_eq "0" "$(_calls451 PUT)" \
  "github-api/post-approval: no label write follows a failed marker POST [#451]"

# 11b: a body that escapes to over 128 KiB (21,900 non-ASCII characters = 43,800
# raw bytes, under the 120,000-byte cap, but json.dumps escapes each to 6 bytes
# = 131,400) is posted, with nothing on argv.
_reset451
_big451="$SANDBOX/big451.txt"
python3 -I -c "import sys; sys.stdout.buffer.write(('é' * 21900).encode('utf-8'))" > "$_big451"
printf '%s\n%s\n' '{"state":"open"}' \
  '{"id":1,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-1"}' > "$CURL_QUEUE"
out11="$(bash "$VCS" comment-issue 5 --body-file "$_big451" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "0" "$rc11" "github-api/comment-issue: a body over 128 KiB once escaped is posted [#451]"
assert_contains "$out11" "issuecomment-1" \
  "github-api/comment-issue: the large post prints the comment URL [#451]"
assert_eq "" "$(cat "$CURL_BIGARG_LOG")" \
  "github-api/comment-issue: no curl argv element exceeds 128 KiB [#451]"
_sent451="$(awk -F'\t' '$4 == "POST" { print length($2) }' "$CURL_LOG" | head -1)"
[ "${_sent451:-0}" -gt 131072 ] && pass "github-api/comment-issue: the whole escaped body reached curl [#451]" \
  || fail "github-api/comment-issue: the whole escaped body reached curl [#451]" "payload bytes: ${_sent451:-none}"

# close-issue: both the comment and the close go through.
_reset451
printf '%s\n%s\n' \
  '{"id":1,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-1"}' '{"state":"closed"}' > "$CURL_QUEUE"
_bigtext451="$(cat "$_big451")"
out11="$(bash "$VCS" close-issue 5 "$_bigtext451" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "0" "$rc11" "github-api/close-issue: a body over 128 KiB once escaped is posted [#451]"
assert_contains "$out11" "Closed issue #5" "github-api/close-issue: closes after the large comment [#451]"
assert_eq "" "$(cat "$CURL_BIGARG_LOG")" "github-api/close-issue: no curl argv element exceeds 128 KiB [#451]"
assert_eq "1" "$(_calls451 PATCH)" "github-api/close-issue: the close PATCH was made [#451]"

# comment-pr and the needs-owner comment share the path.
_reset451
printf '%s\n%s\n' '{"state":"open","merged_at":null}' \
  '{"id":2,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-2"}' > "$CURL_QUEUE"
out11="$(bash "$VCS" comment-pr 9 --body-file "$_big451" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "0" "$rc11" "github-api/comment-pr: a body over 128 KiB once escaped is posted [#451]"
assert_eq "" "$(cat "$CURL_BIGARG_LOG")" "github-api/comment-pr: no curl argv element exceeds 128 KiB [#451]"

_reset451
printf '%s\n' '[]' > "$CURL_QUEUE"
out11="$(bash "$VCS" mark-needs-owner 7 --body-file "$_big451" 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "0" "$rc11" "github-api/mark-needs-owner: a large question is posted [#451]"
assert_eq "" "$(cat "$CURL_BIGARG_LOG")" "github-api/mark-needs-owner: no curl argv element exceeds 128 KiB [#451]"

_reset451
rm -f "$SANDBOX/talos.pipeline.json"
unset GITHUB_TOKEN CURL_BIGARG_LOG

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 10 [test]: CHANGELOG has entry for this fix (released in [0.14.0])
# ═════════════════════════════════════════════════════════════════════════════

_changelog="$TALOS_ROOT/CHANGELOG.md"
# Extract [0.14.0] section up to the next versioned heading (BSD-compat awk)
_release_section="$(awk '
  /## \[0\.14\.0\]/ { found=1; next }
  found && /## \[[0-9]/ { exit }
  found { print }
' "$_changelog")"

assert_contains "$_release_section" "comment-issue" \
  "CHANGELOG: [0.14.0] section mentions comment-issue fix (#69) [CRITERION 10]"
assert_contains "$_release_section" "69" \
  "CHANGELOG: [0.14.0] section references issue #69 [CRITERION 10]"

finish
