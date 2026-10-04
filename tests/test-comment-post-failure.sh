#!/usr/bin/env bash
# test-comment-post-failure.sh — gh-provider comment POST failure propagation (issue #69).
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

# ── Temp-stub factory ─────────────────────────────────────────────────────────
# Creates a stub gh that fails (exit 1) on "issue comment" while succeeding
# for all other calls (state lookups etc.).
make_failing_post_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
REPO="${STUB_REPO:-acme/widget}"
args="$*"
case "$args" in
  "issue view "*"--json state -q .state"*)
    [ "${STUB_ISSUE_STATE_FAIL:-}" = "true" ] && exit 1
    printf '%s\n' "${STUB_ISSUE_STATE:-OPEN}" ;;
  "pr view "*"--json state -q .state"*)
    printf '%s\n' "${STUB_PR_STATE:-OPEN}" ;;
  "issue comment "*)
    # Simulate a POST failure — print error to stderr, exit non-zero
    printf 'gh: failed to post comment: HTTP 503\n' >&2
    exit 1 ;;
  *)
    exit 0 ;;
esac
GHSTUB
  chmod +x "$dir/gh"
}

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 1: gh POST fails → comment-issue exits non-zero
# (This is the acceptance criterion the current code fails before the fix.)
# ═════════════════════════════════════════════════════════════════════════════

_stub1="$(safe_mktemp_dir)" || exit 1
make_failing_post_stub "$_stub1"

: > "$GH_LOG"
_old_path="$PATH"; export PATH="$_stub1:$PATH"
out1="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc1=$?
export PATH="$_old_path"; rm -rf "$_stub1"

assert_eq "1" "$rc1" \
  "gh/comment-issue: failed POST exits non-zero [CRITERION 1]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 2: gh POST fails → comment-pr exits non-zero
# ═════════════════════════════════════════════════════════════════════════════

_stub2="$(safe_mktemp_dir)" || exit 1
make_failing_post_stub "$_stub2"

: > "$GH_LOG"
_old_path="$PATH"; export PATH="$_stub2:$PATH"
out2="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 "body" 2>/dev/null)"; rc2=$?
export PATH="$_old_path"; rm -rf "$_stub2"

assert_eq "1" "$rc2" \
  "gh/comment-pr: failed POST exits non-zero [CRITERION 2]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 3: gh POST fails → talos:comment-state-unverified NOT emitted
# ═════════════════════════════════════════════════════════════════════════════

_stub3="$(safe_mktemp_dir)" || exit 1
make_failing_post_stub "$_stub3"

: > "$GH_LOG"
_old_path="$PATH"; export PATH="$_stub3:$PATH"
out3="$(STUB_ISSUE_STATE_FAIL=true bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc3=$?
export PATH="$_old_path"; rm -rf "$_stub3"

# State check fails → _ci_state_unverified=true; POST fails → || exit 1 fires
# BEFORE the marker line. Without the || exit 1 guard, the marker WOULD be emitted
# (discriminating: remove the guard and this assertion goes red).
assert_not_contains "$out3" "talos:comment-state-unverified" \
  "gh/comment-issue: failed POST does not emit state-unverified marker [CRITERION 3]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 4: gh POST fails → no stdout output (no URL, no empty line)
# ═════════════════════════════════════════════════════════════════════════════

_stub4="$(safe_mktemp_dir)" || exit 1
make_failing_post_stub "$_stub4"

: > "$GH_LOG"
_old_path="$PATH"; export PATH="$_stub4:$PATH"
out4="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc4=$?
export PATH="$_old_path"; rm -rf "$_stub4"

assert_eq "" "$out4" \
  "gh/comment-issue: failed POST produces no stdout output [CRITERION 4]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 5: gh POST succeeds → comment-issue exits 0 and emits URL
# (PR #68 regression guard)
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out5="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 5 "findings body" 2>/dev/null)"; rc5=$?

assert_eq "0" "$rc5" \
  "gh/comment-issue: successful POST exits 0 [CRITERION 5]"
assert_contains "$out5" "/comments/" \
  "gh/comment-issue: successful POST emits comment URL on stdout [CRITERION 5]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 6: gh POST succeeds → comment-pr exits 0 and emits URL
# (PR #68 regression guard)
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out6="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 "review done" 2>/dev/null)"; rc6=$?

assert_eq "0" "$rc6" \
  "gh/comment-pr: successful POST exits 0 [CRITERION 6]"
assert_contains "$out6" "/comments/" \
  "gh/comment-pr: successful POST emits comment URL on stdout [CRITERION 6]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 7: state-check failed + POST succeeds → marker emitted, exits 0
# (PR #79 marker must NOT regress)
# ═════════════════════════════════════════════════════════════════════════════

# Stub: state check fails (exit 1), but comment POST succeeds.
_stub7="$(safe_mktemp_dir)" || exit 1
mkdir -p "$_stub7"
cat > "$_stub7/gh" <<'GHSTUB7'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
REPO="${STUB_REPO:-acme/widget}"
args="$*"
case "$args" in
  "issue view "*"--json state -q .state"*)
    exit 1 ;;   # state check fails — triggers fail-open
  "issue comment "*)
    printf 'https://github.com/%s/issues/comments/777\n' "$REPO" ;;
  *)
    exit 0 ;;
esac
GHSTUB7
chmod +x "$_stub7/gh"

: > "$GH_LOG"
_old_path="$PATH"; export PATH="$_stub7:$PATH"
out7="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc7=$?
export PATH="$_old_path"; rm -rf "$_stub7"

assert_eq "0" "$rc7" \
  "gh/comment-issue: state-check-failed + POST success exits 0 [CRITERION 7]"
assert_contains "$out7" "talos:comment-state-unverified" \
  "gh/comment-issue: state-check-failed + POST success emits marker [CRITERION 7]"
assert_contains "$out7" "/comments/" \
  "gh/comment-issue: state-check-failed + POST success emits URL [CRITERION 7]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 8: --allow-closed still works (PR #68 regression guard)
# ═════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out8="$(STUB_ISSUE_STATE=CLOSED bash "$VCS" comment-issue 5 "body" --allow-closed 2>/dev/null)"; rc8=$?

assert_eq "0" "$rc8" \
  "gh/comment-issue: --allow-closed on closed issue exits 0 [CRITERION 8]"
assert_contains "$out8" "/comments/" \
  "gh/comment-issue: --allow-closed on closed issue returns URL [CRITERION 8]"

# ═════════════════════════════════════════════════════════════════════════════
# CRITERION 9: github-api provider — failed POST exits non-zero (real fix)
# ═════════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-69"

# 9a: comment-issue — failed POST (403) exits non-zero
: > "$CURL_LOG"; : > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","title":"issue 5"}' \
  '403' \
  > "$CURL_QUEUE"

out9a="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc9a=$?

assert_eq "1" "$rc9a" \
  "github-api/comment-issue: failed POST (403) exits non-zero [CRITERION 9a]"
assert_eq "" "$out9a" \
  "github-api/comment-issue: failed POST produces no stdout [CRITERION 9a]"

# 9b: comment-pr — failed POST (503) exits non-zero
: > "$CURL_LOG"; : > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","merged_at":null,"number":9}' \
  '503' \
  > "$CURL_QUEUE"

out9b="$(bash "$VCS" comment-pr 9 "body" 2>/dev/null)"; rc9b=$?

assert_eq "1" "$rc9b" \
  "github-api/comment-pr: failed POST (503) exits non-zero [CRITERION 9b]"
assert_eq "" "$out9b" \
  "github-api/comment-pr: failed POST produces no stdout [CRITERION 9b]"

# 9c: comment-issue — successful POST still exits 0 and emits URL (PR #68 guard)
: > "$CURL_LOG"; : > "$CURL_QUEUE"
printf '%s\n' \
  '{"state":"open","title":"issue 5"}' \
  '{"id":999,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-999"}' \
  > "$CURL_QUEUE"

out9c="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc9c=$?

assert_eq "0" "$rc9c" \
  "github-api/comment-issue: successful POST exits 0 [CRITERION 9c]"
assert_contains "$out9c" "issuecomment-999" \
  "github-api/comment-issue: successful POST emits html_url [CRITERION 9c]"
assert_not_contains "$out9c" "talos:comment-state-unverified" \
  "github-api/comment-issue: successful POST does not emit marker [CRITERION 9c]"

# 9d: state-check-failed + POST succeeds → marker still emitted, exits 0
: > "$CURL_LOG"; : > "$CURL_QUEUE"
printf '%s\n' \
  '500' \
  '{"id":888,"html_url":"https://github.com/acme/widget/issues/5#issuecomment-888"}' \
  > "$CURL_QUEUE"

out9d="$(bash "$VCS" comment-issue 5 "body" 2>/dev/null)"; rc9d=$?

assert_eq "0" "$rc9d" \
  "github-api/comment-issue: state-check-fail + POST success exits 0 [CRITERION 9d]"
assert_contains "$out9d" "talos:comment-state-unverified" \
  "github-api/comment-issue: state-check-fail + POST success emits marker [CRITERION 9d]"
assert_contains "$out9d" "issuecomment-888" \
  "github-api/comment-issue: state-check-fail + POST success emits URL [CRITERION 9d]"

rm -f "$SANDBOX/talos.pipeline.json"
unset GITHUB_TOKEN

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

# label-issue: the label GET fails
_reset451
export STUB_CURL_FAIL_RC=7
out11="$(bash "$VCS" label-issue 5 --add x 2>"$SANDBOX/err11")"; rc11=$?
assert_eq "1" "$rc11" "github-api/label-issue: transport failure exits 1 [#451]"
assert_not_contains "$out11" "Labels updated" \
  "github-api/label-issue: no success line after a transport failure [#451]"
assert_not_contains "$(cat "$SANDBOX/err11")" "Traceback" \
  "github-api/label-issue: transport failure leaves no python traceback [#451]"

# label-issue / label-pr: only the label read fails -> nothing is written back
# (an empty payload would otherwise be PUT over the issue's labels).
for _verb451 in label-issue label-pr; do
  _reset451
  export STUB_CURL_FAIL_RC=7 STUB_CURL_FAIL_METHOD=GET
  out11="$(bash "$VCS" "$_verb451" 5 --add x 2>"$SANDBOX/err11")"; rc11=$?
  assert_eq "1" "$rc11" "github-api/$_verb451: a failed label read exits 1 [#451]"
  assert_eq "0" "$(_calls451 PUT)" "github-api/$_verb451: nothing is PUT after a failed label read [#451]"
  assert_not_contains "$(cat "$SANDBOX/err11")" "Traceback" \
    "github-api/$_verb451: a failed label read leaves no python traceback [#451]"
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
  "github-api/post-approval: no label PUT after a failed marker POST [#451]"

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
