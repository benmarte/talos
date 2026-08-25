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
