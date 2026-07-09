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

cat > .claude-pipeline.json <<'EOF'
{"board": {"enabled": false}}
EOF
out="$(bash "$STATUS" 42 "Done" 2>&1)"; rc=$?
assert_eq "0" "$rc" "board disabled exits 0"
assert_contains "$out" "board disabled" "board disabled is announced"
rm .claude-pipeline.json

out="$(bash "$STATUS" 42 "Done" 2>&1)"; rc=$?
assert_eq "0" "$rc" "no project_number configured exits 0 (skip)"

# Full resolution path through the stub: project → field → option → item
cat > .claude-pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF
out="$(bash "$STATUS" 42 "In progress" 2>&1)"; rc=$?
assert_eq "0" "$rc" "status update succeeds via stub"
assert_contains "$out" "#42 → In progress" "confirms the transition"
assert_contains "$(cat "$GH_LOG")" "project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S --single-select-option-id OPT_INPROG" \
  "item-edit called with resolved ids"

# Issue not on the board yet → item-add path
: > "$GH_LOG"
out="$(bash "$STATUS" 99 "Done" 2>&1)"
assert_contains "$(cat "$GH_LOG")" "project item-add 7 --owner acme --url https://github.com/acme/widget/issues/99" \
  "unknown issue is added to the board first"

# Bad status option name → non-zero with clear error
out="$(bash "$STATUS" 42 "No Such Column" 2>&1)"; rc=$?
assert_eq "1" "$rc" "unknown status option exits 1"
assert_contains "$out" "not found" "unknown status option names the problem"

# ── bootstrap-labels.sh ──────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(bash "$TALOS_ROOT/scripts/bootstrap-labels.sh" acme/widget)"
log="$(cat "$GH_LOG")"
for label in pipeline:ready pipeline:confirmed pipeline:dev pipeline:review \
             pipeline:approved pipeline:blocked skip-qa p0 p1 p2 \
             qa:pass review:approved security:approved docs:done; do
  assert_contains "$log" "label create $label" "creates $label"
done
# Regression: names contain ':' — pipe-delimited parsing must keep colors intact
assert_contains "$log" "label create pipeline:ready --color 0e8a16" \
  "color survives ':' in label name"
assert_contains "$log" "Queued for the pipeline" "description passed through"

finish
