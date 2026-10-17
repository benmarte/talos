#!/usr/bin/env bash
# test-azure-write-verbs-quiet-783.sh -- azure label-issue and close-issue print
# nothing on stdout on success, like github (#783): the az response (the whole
# work item) used to reach the stage's context. A failing PATCH still exits
# non-zero with az's error on stderr. Uses the tests/stubs/az stub; no
# credentials needed. Tests are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "board": {"azure_states": {"done": "Closed"}}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

# ── AC1: label-issue prints nothing on stdout when the PATCH succeeds ────────
: > "$GH_LOG"
out="$(bash "$VCS" label-issue 5 --add pipeline:dev 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 label-issue exits 0 when the PATCH succeeds"
assert_eq "" "$out" "AC1 label-issue writes nothing to stdout when the PATCH succeeds"

# ── AC2: label-issue still sends the json-patch with the computed tags ───────
assert_contains "$(cat "$GH_LOG")" 'AZ BODY: [{"op": "replace", "path": "/fields/System.Tags", "value": "bug; pipeline:dev; ui"}]' \
  "AC2 label-issue sends the computed System.Tags in the json-patch"

# ── AC3: a failing PATCH exits non-zero, az's error on stderr only ───────────
out="$(STUB_AZURE_WI_PATCH_FAIL=1 bash "$VCS" label-issue 5 --add pipeline:dev 2>"$SANDBOX/err")"; rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "AC3 label-issue exits non-zero when the PATCH fails"
assert_contains "$(cat "$SANDBOX/err")" "TF401232" "AC3 label-issue leaves az's error on stderr"
assert_eq "" "$out" "AC3 label-issue writes nothing to stdout when the PATCH fails"

# ── AC4: close-issue prints nothing on stdout when the update succeeds ───────
out="$(bash "$VCS" close-issue 5 "done" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC4 close-issue exits 0 when the update succeeds"
assert_eq "" "$out" "AC4 close-issue writes nothing to stdout when the update succeeds"

# ── AC5: close-issue still moves the item to board.azure_states.done ─────────
: > "$GH_LOG"
bash "$VCS" close-issue 5 "done" >/dev/null 2>&1
assert_contains "$(grep '^AZ ARGS: \[boards\] \[work-item\] \[update\]' "$GH_LOG")" "[--state] [Closed]" \
  "AC5 close-issue sends --state with the configured done state"

# ── AC6: --dry-run output of both verbs is unchanged ─────────────────────────
out="$(bash "$VCS" --dry-run label-issue 5 --add pipeline:dev 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 --dry-run label-issue exits 0"
assert_contains "$out" "[dry-run] az rest --method patch --url https://dev.azure.com/acme/_apis/wit/workitems/5?api-version=7.1" \
  "AC6 --dry-run label-issue still prints its [dry-run] line on stdout"
out="$(bash "$VCS" --dry-run close-issue 5 "done" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 --dry-run close-issue exits 0"
assert_contains "$out" "[dry-run] az boards work-item update --id 5 --state Closed" \
  "AC6 --dry-run close-issue still prints its [dry-run] line on stdout"

finish
