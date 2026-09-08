#!/usr/bin/env bash
# test-vcs-shared-markers.sh — direct unit tests for the marker-parsing
# helpers shared by _github and _github_api (#177 slice 1):
#   _vcs_shared_read_attempt, _vcs_shared_attempt_blocked,
#   _vcs_shared_record_attempt, _vcs_shared_check_approval_marker.
#
# These drive the shared functions directly (not through either adapter's
# CLI verb) so a regression in the shared logic itself is caught here even
# if both adapters happened to still agree by coincidence. Every test can
# fail: disabling/breaking the shared helpers causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SCRIPT_DIR="$TALOS_ROOT/scripts"   # _vcs_shared_record_attempt recurses via this
cfg() { bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$@"; }
_TALOS_CFG=""

# ── Load ONLY the shared-helper function definitions ──────────────────────────
# Never `source`/`.` the whole script: it has top-level arg-parsing/dispatch
# that ends in `exit`, which would terminate this test process. Extract the
# byte range from `_vcs_shared_read_attempt() {` up to (not including) the
# `_github() {` adapter that follows it -- pure function definitions, safe to
# eval into this shell.
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
if [ -z "$_shared_src" ]; then
  fail "setup: extracted shared-helper source is non-empty" "extraction produced nothing -- check the awk anchors against pipeline-vcs.sh"
fi
eval "$_shared_src"
for _fn in _vcs_shared_read_attempt _vcs_shared_attempt_blocked _vcs_shared_record_attempt _vcs_shared_check_approval_marker; do
  if ! declare -F "$_fn" >/dev/null; then
    fail "setup: $_fn loaded" "function not defined after eval"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_read_attempt
# ═══════════════════════════════════════════════════════════════════════════

# No marker present → zero state, exit 0.
out="$(printf '%s' '{"comments":[]}' | _vcs_shared_read_attempt)"; rc=$?
assert_eq "0" "$rc" "read_attempt: no marker exits 0"
assert_eq "stage= count=0 total=0" "$out" "read_attempt: no marker is zero state"

# Marker present → parses stage/count/total. TRUSTED_AUTHORS is configured
# (with the fixture's author in it) so the "unconfigured allow-list" fail-open
# passthrough line does not also land on stdout and break the exact match.
fixture='{"comments":[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=2 total=5 -->","author":{"login":"bot"}}]}'
out="$(printf '%s' "$fixture" | TRUSTED_AUTHORS='["bot"]' _vcs_shared_read_attempt)"; rc=$?
assert_eq "0" "$rc" "read_attempt: valid marker exits 0"
assert_eq "stage=qa count=2 total=5" "$out" "read_attempt: valid marker parses stage/count/total"

# Newest marker wins (search newest-first) across two stages.
fixture='{"comments":[
  {"body":"<!-- talos:attempt stage=developer count=1 total=1 -->","author":{"login":"bot"}},
  {"body":"<!-- talos:attempt stage=qa count=1 total=2 -->","author":{"login":"bot"}}
]}'
out="$(printf '%s' "$fixture" | TRUSTED_AUTHORS='["bot"]' _vcs_shared_read_attempt)"
assert_eq "stage=qa count=1 total=2" "$out" "read_attempt: last comment (newest) wins"

# key=<token> round-trips when present.
fixture='{"comments":[{"body":"<!-- talos:attempt stage=qa count=1 total=1 key=qa-abc123 -->","author":{"login":"bot"}}]}'
out="$(printf '%s' "$fixture" | TRUSTED_AUTHORS='["bot"]' _vcs_shared_read_attempt)"
assert_eq "stage=qa count=1 total=1 key=qa-abc123" "$out" "read_attempt: key=<token> round-trips"

# Corrupt marker (unparseable) → fail-closed, exit 1.
fixture='{"comments":[{"body":"<!-- talos:attempt stage=qa count=not-a-number -->"}]}'
rc="$(printf '%s' "$fixture" | _vcs_shared_read_attempt >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "read_attempt: corrupt marker fails closed"

# Unrecognised stage → fail-closed, exit 1.
fixture='{"comments":[{"body":"<!-- talos:attempt stage=not-a-real-stage count=1 total=1 -->"}]}'
rc="$(printf '%s' "$fixture" | _vcs_shared_read_attempt >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "read_attempt: unrecognised stage fails closed"

# Unparseable stdin → exit 1.
rc="$(printf 'not json' | _vcs_shared_read_attempt >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "read_attempt: unparseable stdin exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_attempt_blocked
# ═══════════════════════════════════════════════════════════════════════════

# Under both ceilings → returns 0, no BLOCKED line.
err="$(_vcs_shared_attempt_blocked "check-attempt" 1 1 3 8 "qa" 2>&1)"; rc=$?
assert_eq "0" "$rc" "attempt_blocked: under both ceilings returns 0"
assert_not_contains "$err" "BLOCKED" "attempt_blocked: no BLOCKED line when under ceiling"

# Total ceiling met → returns 1, message names total dispatches.
err="$(_vcs_shared_attempt_blocked "check-attempt" 1 8 3 8 "qa" 2>&1)"; rc=$?
assert_eq "1" "$rc" "attempt_blocked: total ceiling met returns 1"
assert_contains "$err" "BLOCKED" "attempt_blocked: BLOCKED present for total ceiling"
assert_contains "$err" "total dispatches (8) >= max_total_dispatches (8)" "attempt_blocked: total ceiling message"

# Per-stage ceiling met → returns 1, message names the stage.
err="$(_vcs_shared_attempt_blocked "record-attempt" 3 3 3 8 "qa" 2>&1)"; rc=$?
assert_eq "1" "$rc" "attempt_blocked: per-stage ceiling met returns 1"
assert_contains "$err" "qa consecutive attempts (3) >= max_fix_attempts (3)" "attempt_blocked: per-stage ceiling message"
assert_contains "$err" "pipeline-vcs: record-attempt: BLOCKED" "attempt_blocked: verb label is used verbatim"

# Empty stage (check-attempt with no prior marker) never emits a per-stage
# BLOCKED line even if count happens to equal max_count (guard: stage must
# be non-empty).
err="$(_vcs_shared_attempt_blocked "check-attempt" 0 0 0 8 "" 2>&1)"; rc=$?
assert_eq "0" "$rc" "attempt_blocked: empty stage with count=max_count=0 is not blocked"

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_record_attempt (via a stub post-fn; real read-attempt
# recursion through the gh stub, exactly as each adapter's record-attempt
# verb does)
# ═══════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}
EOF
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"

# post-fn stubs record what they were called with via a file, not a plain
# variable: `"$post_fn" "$n" "$marker_body"` runs inside a command
# substitution inside _vcs_shared_record_attempt, i.e. a subshell, so a
# plain variable assignment made there would not be visible out here.
POST_LOG="$SANDBOX/post_fn.log"
_stub_post_ok() {
  printf '%s\t%s\n' "$1" "$2" > "$POST_LOG"
  printf 'https://example.invalid/comment/1'
  return 0
}
_stub_post_fail() {
  printf 'called\n' > "$POST_LOG"
  return 1
}

# First attempt for an issue with no prior marker → count=1 total=1, exits 0.
: > "$POST_LOG"
out="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "record_attempt: first attempt exits 0 (under ceiling)"
assert_eq "stage=qa count=1 total=1" "$out" "record_attempt: first attempt is count=1 total=1"
assert_contains "$(cat "$POST_LOG")" "talos:attempt stage=qa count=1 total=1" "record_attempt: posted marker body carries the new counts"

# Same-stage retry (prior marker present) → count increments, total increments.
# (assert_contains, not assert_eq: record-attempt relays any machine-readable
# `talos:...` passthrough line from its internal read-attempt call onto its
# own stdout too -- by design, see read-attempt's own trusted_authors test.)
prior='[{"body":"<!-- talos:attempt stage=qa count=1 total=1 -->"}]'
out="$(STUB_ISSUE_COMMENTS_JSON="$prior" _vcs_shared_record_attempt 42 qa _stub_post_ok 2>/dev/null)"
assert_contains "$out" "stage=qa count=2 total=2" "record_attempt: same-stage retry increments count and total"

# Stage change → per-stage count resets to 1, total still increments.
prior='[{"body":"<!-- talos:attempt stage=qa count=2 total=2 -->"}]'
out="$(STUB_ISSUE_COMMENTS_JSON="$prior" _vcs_shared_record_attempt 42 developer _stub_post_ok 2>/dev/null)"
assert_contains "$out" "stage=developer count=1 total=3" "record_attempt: stage change resets per-stage count, total keeps climbing"

# Idempotency: an immediate retry with the same key does not call post-fn again.
: > "$POST_LOG"
prior_keyed='[{"body":"<!-- talos:attempt stage=qa count=1 total=1 key=qa-tok -->"}]'
out="$(STUB_ISSUE_COMMENTS_JSON="$prior_keyed" _vcs_shared_record_attempt 42 qa _stub_post_ok --idempotency-key qa-tok 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "record_attempt: idempotent replay (under ceiling) exits 0"
assert_contains "$out" "stage=qa count=1 total=1" "record_attempt: idempotent replay reprints unincremented counts"
assert_eq "" "$(cat "$POST_LOG")" "record_attempt: idempotent replay does not call post-fn"

# Ceiling breach after recording → exits 1, BLOCKED message on stderr.
cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"limits": {"max_fix_attempts": 1, "max_total_dispatches": 8}}
EOF
err="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok 2>&1 1>/dev/null)"
rc="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_ok >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "record_attempt: exits 1 once the per-stage ceiling is reached"
assert_contains "$err" "BLOCKED" "record_attempt: BLOCKED reported on stderr"
cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}
EOF

# Post-fn failure → exits 1, "failed to post" on stderr.
err="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_fail 2>&1 1>/dev/null)"
rc="$(STUB_ISSUE_COMMENTS_JSON='[]' _vcs_shared_record_attempt 42 qa _stub_post_fail >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "record_attempt: post-fn failure exits 1"
assert_contains "$err" "failed to post attempt marker" "record_attempt: post-fn failure message"

# ═══════════════════════════════════════════════════════════════════════════
# _vcs_shared_check_approval_marker
# ═══════════════════════════════════════════════════════════════════════════

HEAD_SHA="aabbccddeeff001122334455667788990011aabb"

# No approval labels present, and no near-miss marker text → plain diagnostic,
# exit 3 (the shared "no labels present" short-circuit).
pr_data='{"labels":[],"comments":[]}'
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker)"; rc=$?
assert_eq "3" "$rc" "check_approval_marker: no labels present exits 3"
assert_eq "check-approval-sha: no approval labels present" "$out" "check_approval_marker: no-labels diagnostic text"

# No approval labels present, but near-miss marker text exists → count noted.
pr_data='{"labels":[],"comments":[{"body":"<!-- talos:approval sha=abc role=qa -->"}]}'
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker)"; rc=$?
assert_eq "3" "$rc" "check_approval_marker: no labels + near-miss text still exits 3"
assert_contains "$out" "1 approval marker(s) found in comments" "check_approval_marker: near-miss count in diagnostic"

# Label present with a valid, current-role marker → one entry with sha set.
pr_data="{\"labels\":[{\"name\":\"qa:pass\"}],\"comments\":[{\"body\":\"<!-- talos:approval sha=${HEAD_SHA} role=qa -->\",\"author\":{\"login\":\"bot\"}}]}"
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "check_approval_marker: present label with valid marker exits 0"
assert_contains "$out" "\"label\": \"qa:pass\"" "check_approval_marker: entry names the label"
assert_contains "$out" "\"sha\": \"${HEAD_SHA}\"" "check_approval_marker: entry carries the marker SHA"
assert_contains "$out" "\"reason\": null" "check_approval_marker: entry has no stale reason"

# Label present, no marker at all → entry has sha=null and a "no SHA marker" reason.
pr_data='{"labels":[{"name":"qa:pass"}],"comments":[]}'
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "check_approval_marker: present label, no marker: exits 0 (extraction, not a fail)"
assert_contains "$out" "\"sha\": null" "check_approval_marker: no marker -> sha is null"
assert_contains "$out" "no SHA marker in PR comments" "check_approval_marker: no marker -> reason names the cause"

# Marker SHA too short (not 40 hex chars) → entry has sha=null and a
# "not a valid 40-character commit SHA" reason.
pr_data='{"labels":[{"name":"qa:pass"}],"comments":[{"body":"<!-- talos:approval sha=abc123 role=qa -->","author":{"login":"bot"}}]}'
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker 2>/dev/null)"
assert_contains "$out" "\"sha\": null" "check_approval_marker: short SHA -> sha is null"
assert_contains "$out" "not a valid 40-character commit SHA" "check_approval_marker: short SHA -> reason names the cause"

# Untrusted author (trusted_authors configured, marker author not listed) →
# marker is skipped, falls through to the same "no SHA marker" reason.
pr_data="{\"labels\":[{\"name\":\"qa:pass\"}],\"comments\":[{\"body\":\"<!-- talos:approval sha=${HEAD_SHA} role=qa -->\",\"author\":{\"login\":\"evil-bot\"}}]}"
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS='["trusted-bot"]' TALOS_CFG="" _vcs_shared_check_approval_marker 2>/dev/null)"
assert_contains "$out" "\"sha\": null" "check_approval_marker: untrusted author -> sha is null"
assert_contains "$out" "found talos:approval text but no valid marker" \
  "check_approval_marker: untrusted author -> skipped marker falls through to the near-miss reason"

# Unconfigured trusted_authors → fail-open AND a machine-readable
# talos:marker-authors-unverified line on stdout (relayed by callers exactly
# as read-attempt's equivalent line is).
pr_data="{\"labels\":[{\"name\":\"qa:pass\"}],\"comments\":[{\"body\":\"<!-- talos:approval sha=${HEAD_SHA} role=qa -->\",\"author\":{\"login\":\"bot\"}}]}"
out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="" TALOS_CFG="" _vcs_shared_check_approval_marker 2>/dev/null)"
assert_contains "$out" "talos:marker-authors-unverified reader=check-approval-sha" \
  "check_approval_marker: unconfigured trusted_authors emits the unverified marker"

# Unparseable stdin → exit 1.
rc="$(printf 'not json' | _vcs_shared_check_approval_marker >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "check_approval_marker: unparseable stdin exits 1"

finish
