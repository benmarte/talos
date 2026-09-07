#!/usr/bin/env bash
# Regression tests for check-epic-acceptance (issue #168).
#
# Bug: the Step 1.6 epic auto-close sweep closed an epic once all its
# sub-issues closed, WITHOUT ever checking the epic's own `- [ ]` acceptance
# checkboxes. This is a RED-on-main / GREEN-after-fix suite: check-epic-
# acceptance did not exist on main, so every assertion below fails against
# unpatched pipeline-vcs.sh and passes once the verb is implemented.
#
# Covers: exit code + printed output for a body with unticked boxes, a body
# with all boxes ticked, and a body with no checkboxes at all (must exit 0 --
# the gate only fires on checkboxes that exist). Both providers. Dry-run.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── github provider ───────────────────────────────────────────────────────────

# (a) unticked boxes remain -> exit non-zero, prints each unticked item
export STUB_EPIC_BODY='Some epic description.

- [ ] Bring the full stack up and prove it communicates
- [x] Write the README
- [ ] Add a healthcheck'
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "1" "$rc" "github: check-epic-acceptance exits non-zero when unticked boxes remain"
assert_contains "$out" "Bring the full stack up and prove it communicates" \
  "github: check-epic-acceptance prints first unticked item"
assert_contains "$out" "Add a healthcheck" \
  "github: check-epic-acceptance prints second unticked item"
assert_not_contains "$out" "Write the README" \
  "github: check-epic-acceptance does not print ticked items"

# (b) all boxes ticked -> exit 0
export STUB_EPIC_BODY='Some epic description.

- [x] Bring the full stack up and prove it communicates
- [X] Add a healthcheck'
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github: check-epic-acceptance exits 0 when all boxes ticked"
assert_eq "" "$out" "github: check-epic-acceptance prints nothing when all boxes ticked"

# (c) no checkboxes at all -> exit 0 (gate only fires on checkboxes that exist)
export STUB_EPIC_BODY='Some epic description with no checklist at all.'
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github: check-epic-acceptance exits 0 when body has no checkboxes"
assert_eq "" "$out" "github: check-epic-acceptance prints nothing when body has no checkboxes"

unset STUB_EPIC_BODY

# (d) dry-run: no gh call, prints [dry-run] marker
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github: check-epic-acceptance --dry-run exits 0"
assert_contains "$out" "[dry-run]" "github: check-epic-acceptance --dry-run prints marker"
log="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_not_contains "$log" "issue view" "github: check-epic-acceptance --dry-run does not fetch the issue body"

# (e) missing issue number -> exit non-zero
bash "$VCS" check-epic-acceptance >/dev/null 2>&1
assert_exit_code "1" "$?" "github: check-epic-acceptance with no argument exits non-zero"

# ── github-api provider ───────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-epic"

# (f) unticked boxes remain -> exit non-zero, prints each unticked item
: > "$CURL_QUEUE"
printf '%s\n' '{"number":168,"body":"Epic body.\n\n- [ ] First unticked item\n- [x] Done item\n- [ ] Second unticked item"}' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "1" "$rc" "github-api: check-epic-acceptance exits non-zero when unticked boxes remain"
assert_contains "$out" "First unticked item" "github-api: prints first unticked item"
assert_contains "$out" "Second unticked item" "github-api: prints second unticked item"
assert_not_contains "$out" "Done item" "github-api: does not print ticked items"

# (g) all boxes ticked -> exit 0
: > "$CURL_QUEUE"
printf '%s\n' '{"number":168,"body":"Epic body.\n\n- [x] First item\n- [X] Second item"}' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github-api: check-epic-acceptance exits 0 when all boxes ticked"
assert_eq "" "$out" "github-api: check-epic-acceptance prints nothing when all boxes ticked"

# (h) no checkboxes at all -> exit 0
: > "$CURL_QUEUE"
printf '%s\n' '{"number":168,"body":"Epic body with no checklist."}' > "$CURL_QUEUE"
out="$(bash "$VCS" check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github-api: check-epic-acceptance exits 0 when body has no checkboxes"
assert_eq "" "$out" "github-api: check-epic-acceptance prints nothing when body has no checkboxes"

# (i) dry-run: no curl call, prints [dry-run] marker
: > "$CURL_LOG"
out="$(bash "$VCS" --dry-run check-epic-acceptance 168 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github-api: check-epic-acceptance --dry-run exits 0"
assert_contains "$out" "[dry-run]" "github-api: check-epic-acceptance --dry-run prints marker"
log="$(cat "$CURL_LOG" 2>/dev/null || true)"
assert_eq "" "$log" "github-api: check-epic-acceptance --dry-run makes no curl call"

unset GITHUB_TOKEN
rm -f talos.pipeline.json

finish
