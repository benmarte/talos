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
# 10. CHANGELOG has entry under [Unreleased] for this fix
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

_stub1="$(mktemp -d)"
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

_stub2="$(mktemp -d)"
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

_stub3="$(mktemp -d)"
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

_stub4="$(mktemp -d)"
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
_stub7="$(mktemp -d)"
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
# CRITERION 10 [test]: CHANGELOG has entry under [Unreleased] for this fix
# ═════════════════════════════════════════════════════════════════════════════

_changelog="$TALOS_ROOT/CHANGELOG.md"
# Extract [Unreleased] section up to the next versioned heading (BSD-compat awk)
_unreleased_section="$(awk '
  /## \[Unreleased\]/ { found=1; next }
  found && /## \[[0-9]/ { exit }
  found { print }
' "$_changelog")"

assert_contains "$_unreleased_section" "comment-issue" \
  "CHANGELOG: [Unreleased] section mentions comment-issue fix (#69) [CRITERION 10]"
assert_contains "$_unreleased_section" "69" \
  "CHANGELOG: [Unreleased] section references issue #69 [CRITERION 10]"

finish
