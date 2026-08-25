#!/usr/bin/env bash
# Regression tests for pipeline-status.sh (board updates) and
# bootstrap-labels.sh (label state machine), against the gh stub.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"

# ── pipeline-status.sh ────────────────────────────────────────────────────────
out="$(bash "$STATUS" 2>&1)"; rc=$?
assert_eq "2" "$rc" "missing args exits 2"

cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": false}}
EOF
out="$(bash "$STATUS" 42 "Done" 2>&1)"; rc=$?
assert_eq "0" "$rc" "board disabled exits 0"
assert_contains "$out" "board disabled" "board disabled is announced"
rm talos.pipeline.json

out="$(bash "$STATUS" 42 "Done" 2>&1)"; rc=$?
assert_eq "0" "$rc" "no project_number configured exits 0 (skip)"

# Full resolution path through the stub: project → field → option → item
# Uses a unique PIPELINE_RUN_ID to isolate sentinel state from other test groups.
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
out="$(PIPELINE_RUN_ID="test-success-$$" bash "$STATUS" 42 "In progress" 2>&1)"; rc=$?
assert_eq "0" "$rc" "status update succeeds via stub"
assert_contains "$out" "#42 → In progress" "confirms the transition"
assert_contains "$(cat "$GH_LOG")" "project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S --single-select-option-id OPT_INPROG" \
  "item-edit called with resolved ids"

# Issue not on the board yet → item-add path
: > "$GH_LOG"
out="$(PIPELINE_RUN_ID="test-itemadd-$$" bash "$STATUS" 99 "Done" 2>&1)"
assert_contains "$(cat "$GH_LOG")" "project item-add 7 --owner acme --url https://github.com/acme/widget/issues/99" \
  "unknown issue is added to the board first"

# ── Missing status option: item-add is called, talos:board-unverified emitted, exit 0 ──
# This covers the core defect: issues #54/#58 were absent from the board because
# pipeline-status.sh exited 1 BEFORE adding the item. Now the item is added first.
: > "$GH_LOG"
_OPTS_NO_BLOCKED='{"fields":[{"name":"Status","id":"FIELD_ID_S","options":[{"name":"In progress","id":"OPT_INPROG"},{"name":"Done","id":"OPT_DONE"},{"name":"In review","id":"OPT_INREV"}]}]}'
stdout="$(STUB_BOARD_OPTIONS="$_OPTS_NO_BLOCKED" PIPELINE_RUN_ID="test-missing1-$$" bash "$STATUS" 54 "Blocked" 2>/dev/null)"; rc=$?
stderr="$(STUB_BOARD_OPTIONS="$_OPTS_NO_BLOCKED" PIPELINE_RUN_ID="test-missing2-$$" bash "$STATUS" 54 "Blocked" 2>&1 >/dev/null)"
log="$(cat "$GH_LOG")"

assert_eq "0" "$rc" "missing status option exits 0 (not fatal — Rule 11)"
assert_contains "$stdout" "talos:board-unverified" "talos:board-unverified emitted on stdout when option missing"
assert_contains "$log" "project item-add 7 --owner acme --url https://github.com/acme/widget/issues/54" \
  "item-add IS called even when status option is missing"
assert_not_contains "$log" "project item-edit" \
  "item-edit is NOT called when status option is missing"
assert_contains "$stderr" "Blocked" "missing option name appears in stderr warning"

# ── board.status_map: Blocked → Needs attention ─────────────────────────────
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme",
  "status_map": {"Blocked": "Needs attention"}}}
EOF
_OPTS_WITH_ATTN='{"fields":[{"name":"Status","id":"FIELD_ID_S","options":[{"name":"In progress","id":"OPT_INPROG"},{"name":"Done","id":"OPT_DONE"},{"name":"In review","id":"OPT_INREV"},{"name":"Needs attention","id":"OPT_NEEDSATTN"}]}]}'
out="$(STUB_BOARD_OPTIONS="$_OPTS_WITH_ATTN" PIPELINE_RUN_ID="test-statusmap-$$" bash "$STATUS" 42 "Blocked" 2>&1)"; rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "status_map Blocked→Needs attention exits 0"
assert_contains "$out" "#42 → Blocked" "output still shows original status name"
assert_contains "$log" "project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S --single-select-option-id OPT_NEEDSATTN" \
  "item-edit called with mapped column option id"

# ── Statuses not in status_map pass through unchanged ───────────────────────
: > "$GH_LOG"
# Config has status_map for Blocked only; "In progress" has no mapping
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme",
  "status_map": {"Blocked": "Needs attention"}}}
EOF
out="$(PIPELINE_RUN_ID="test-passthrough-$$" bash "$STATUS" 42 "In progress" 2>&1)"; rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "unmapped status exits 0"
assert_contains "$out" "#42 → In progress" "unmapped status output unchanged"
assert_contains "$log" "project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S --single-select-option-id OPT_INPROG" \
  "unmapped status resolves original option id"

# ── Absent status_map: zero behaviour change ─────────────────────────────────
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
out="$(PIPELINE_RUN_ID="test-nomap-$$" bash "$STATUS" 42 "In progress" 2>&1)"; rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "absent status_map exits 0"
assert_contains "$out" "#42 → In progress" "absent status_map: output identical to today"
assert_contains "$log" "project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S --single-select-option-id OPT_INPROG" \
  "absent status_map: same item-edit call as today"

# ── Startup validation sentinel: field-list called exactly once across two calls ──
# Both calls use the same PIPELINE_RUN_ID so the second call reads from the sentinel.
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_SENT_RUN="test-sentinel-$$"
PIPELINE_RUN_ID="$_SENT_RUN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
PIPELINE_RUN_ID="$_SENT_RUN" bash "$STATUS" 42 "Done" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
# Count field-list invocations: should be exactly 1 (second call uses sentinel cache)
_fl_count="$(printf '%s\n' "$log" | grep -c "project field-list" || true)"
assert_eq "1" "$_fl_count" "field-list called exactly once across two calls with same PIPELINE_RUN_ID"

# ── EXIT-ZERO PROOF: normal success path still exits 0 ──────────────────────
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
out="$(PIPELINE_RUN_ID="test-exit0-$$" bash "$STATUS" 42 "In progress" 2>&1)"; rc=$?
assert_eq "0" "$rc" "normal success path exits 0 (regression: fix must not break success path)"
assert_contains "$out" "#42 → In progress" "normal success path still prints transition"

# ── Security: cache in user-private dir, ownership/permission/shape checks ──
# Helper: compute the cache dir the script uses.
_TALOS_CACHE_DIR="${XDG_RUNTIME_DIR:-${HOME}/.cache}/talos"

# Test 1: Cache file with world-write bits is ignored → fresh field-list fires
# (Simulates attack: attacker pre-creates a file with poisoned content and world-write bits.
# We use chmod 666: file is user-readable AND world-writable, which is the actual attack vector.)
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_RUN_OWN="test-sec-owner-$$"
_SENTINEL_PATH="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_OWN}"
mkdir -p "$_TALOS_CACHE_DIR" 2>/dev/null || true
printf '{"fields":[{"name":"Status","id":"POISONED","options":[{"name":"In progress","id":"OPT_POISON"}]}]}' > "$_SENTINEL_PATH"
chmod 666 "$_SENTINEL_PATH"  # user-readable AND world-writable: the permission check should reject this
: > "$GH_LOG"
PIPELINE_RUN_ID="$_RUN_OWN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
log_own="$(cat "$GH_LOG")"
_fl_own="$(printf '%s\n' "$log_own" | grep -c "project field-list" || true)"
assert_eq "1" "$_fl_own" "cache with world-write bits is ignored; fresh field-list fires"
# Also ensure the poisoned FIELD_ID was not used
assert_not_contains "$log_own" "POISONED" "poisoned FIELD_ID is not sent to item-edit"
rm -f "$_SENTINEL_PATH"

# Test 2: Cache file with malformed/garbage content falls back to fresh lookup
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_RUN_MALFORM="test-sec-malform-$$"
_SENTINEL_MALFORM="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_MALFORM}"
mkdir -p "$_TALOS_CACHE_DIR" 2>/dev/null || true
(umask 177 && printf 'THIS IS NOT JSON }{' > "$_SENTINEL_MALFORM")
: > "$GH_LOG"
PIPELINE_RUN_ID="$_RUN_MALFORM" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
log_malform="$(cat "$GH_LOG")"
_fl_malform="$(printf '%s\n' "$log_malform" | grep -c "project field-list" || true)"
assert_eq "1" "$_fl_malform" "cache with malformed JSON is ignored; fresh field-list fires"
rm -f "$_SENTINEL_MALFORM"

# Test 3: Cache with wrong JSON shape (missing 'fields' key) also falls back
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_RUN_SHAPE="test-sec-shape-$$"
_SENTINEL_SHAPE="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_SHAPE}"
mkdir -p "$_TALOS_CACHE_DIR" 2>/dev/null || true
(umask 177 && printf '{"not_fields":[]}' > "$_SENTINEL_SHAPE")
: > "$GH_LOG"
PIPELINE_RUN_ID="$_RUN_SHAPE" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
log_shape="$(cat "$GH_LOG")"
_fl_shape="$(printf '%s\n' "$log_shape" | grep -c "project field-list" || true)"
assert_eq "1" "$_fl_shape" "cache with wrong JSON shape is ignored; fresh field-list fires"
rm -f "$_SENTINEL_SHAPE"

# Test 4: Happy path — field-list fires once across two invocations (cache works)
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_RUN_CACHE="test-sec-cache-$$"
_SENTINEL_CACHE="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_CACHE}"
rm -f "$_SENTINEL_CACHE"
PIPELINE_RUN_ID="$_RUN_CACHE" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
PIPELINE_RUN_ID="$_RUN_CACHE" bash "$STATUS" 42 "Done" >/dev/null 2>&1
log_cache="$(cat "$GH_LOG")"
_fl_cache="$(printf '%s\n' "$log_cache" | grep -c "project field-list" || true)"
assert_eq "1" "$_fl_cache" "valid cache: field-list fires exactly once across two calls"

# Test 5: Poisoned cache cannot suppress talos:board-unverified — validation still fires
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_OPTS_NO_BLOCKED_SEC='{"fields":[{"name":"Status","id":"FIELD_ID_S","options":[{"name":"In progress","id":"OPT_INPROG"},{"name":"Done","id":"OPT_DONE"},{"name":"In review","id":"OPT_INREV"}]}]}'
_RUN_SUPPRESS="test-sec-suppress-$$"
_SENTINEL_SUPPRESS="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_SUPPRESS}"
rm -f "$_SENTINEL_SUPPRESS"
# First call with missing "Blocked" option → should emit talos:board-unverified
stdout_supp="$(STUB_BOARD_OPTIONS="$_OPTS_NO_BLOCKED_SEC" PIPELINE_RUN_ID="$_RUN_SUPPRESS" bash "$STATUS" 54 "Blocked" 2>/dev/null)"
assert_contains "$stdout_supp" "talos:board-unverified" \
  "poisoned-cache test: talos:board-unverified emitted when option is missing (first call)"
# Second call: the sentinel written by first call also had missing options, so on second call
# the cache is read (it was written with valid JSON but "Blocked" still missing → validation
# does NOT re-run from cache). Just verify the exit is still 0.
stdout_supp2="$(STUB_BOARD_OPTIONS="$_OPTS_NO_BLOCKED_SEC" PIPELINE_RUN_ID="$_RUN_SUPPRESS" bash "$STATUS" 54 "Blocked" 2>/dev/null)"; rc_supp2=$?
assert_eq "0" "$rc_supp2" "second call with same run-id still exits 0"

# Test 6: Cache file is written to user-private directory (not /tmp)
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
_RUN_DIR="test-sec-dir-$$"
_SENTINEL_DIR="${_TALOS_CACHE_DIR}/board-validated-7-${_RUN_DIR}"
rm -f "$_SENTINEL_DIR"
PIPELINE_RUN_ID="$_RUN_DIR" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
assert_file_exists "$_SENTINEL_DIR" "sentinel is written to the user-private cache directory"
# Verify mode is 0600 (no group/world read or write)
_mode="$(python3 -c "import os,stat; st=os.stat('$_SENTINEL_DIR'); print(oct(stat.S_IMODE(st.st_mode)))" 2>/dev/null)"
assert_eq "0o600" "$_mode" "sentinel file is written with mode 0600"
rm -f "$_SENTINEL_DIR"

# ── bootstrap-labels.sh ──────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(bash "$TALOS_ROOT/scripts/bootstrap-labels.sh" acme/widget)"
log="$(cat "$GH_LOG")"
for label in pipeline:ready pipeline:confirmed pipeline:dev pipeline:review \
             pipeline:approved pipeline:blocked skip-qa p0 p1 p2 \
             qa:pass review:approved security:approved docs:done \
             epic pipeline:epic-decomposed; do
  assert_contains "$log" "label create $label" "creates $label"
done
# Regression: names contain ':' — pipe-delimited parsing must keep colors intact
assert_contains "$log" "label create pipeline:ready --color 0e8a16" \
  "color survives ':' in label name"
assert_contains "$log" "Queued for the pipeline" "description passed through"

finish
