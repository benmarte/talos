#!/usr/bin/env bash
# test-bootstrap-board.sh — regression tests for scripts/bootstrap-board.sh (#266).
#
# Covers:
#   1. gh path: a missing option (Ready) is added; the mutation resends
#      every existing option unchanged; the post-mutation re-fetch confirms
#      no pre-existing option's id changed.
#   2. gh path: re-running when every required option is already present is
#      a no-op -- prints all "=", never issues the mutation.
#   3. gh path: id drift after the mutation (a stubbed pre/post fetch pair
#      with a changed id) is a loud, non-zero-exit failure.
#   4. token path (github-api): the same happy path over curl + GITHUB_TOKEN.
#   5. Azure: a missing configured state exits non-zero and names the exact
#      config key; all-present states exit 0.
#   6. GitLab: verifies board-relied-on labels exist; always exits 0.
#   7. board.enabled: false / vcs.provider: file: prints "board disabled",
#      exits 0.
#   8. pipeline-status.sh's missing-option warning names this script.
#
# Uses the gh/curl/az/glab stubs -- no real network calls, no real project.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

BOOTSTRAP="$TALOS_ROOT/scripts/bootstrap-board.sh"

# _default_field_options_json -- helper: builds the fields() query response
# used by several tests, one JSON blob per queue line.
_field_resp() {  # $1=options JSON array (as GraphQL-shape objects)
  printf '{"data":{"node":{"fields":{"nodes":[{"id":"FIELD_1","name":"Status","options":%s}]}}}}' "$1"
}

# ── 1. gh path: one missing option (Ready), no drift ─────────────────────────
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github"}, "board": {"enabled": true, "project_number": 7, "owner": "acme", "status_field": "Status"}}
EOF

EXISTING_4='[{"id":"O_IP","name":"In progress","color":"YELLOW","description":""},{"id":"O_IR","name":"In review","color":"PURPLE","description":""},{"id":"O_D","name":"Done","color":"GREEN","description":""},{"id":"O_B","name":"Blocked","color":"RED","description":""}]'
AFTER_5='[{"id":"O_IP","name":"In progress","color":"YELLOW","description":""},{"id":"O_IR","name":"In review","color":"PURPLE","description":""},{"id":"O_D","name":"Done","color":"GREEN","description":""},{"id":"O_B","name":"Blocked","color":"RED","description":""},{"id":"O_R","name":"Ready","color":"GRAY","description":""}]'

STUB_BOARD_FIELD_QUEUE="$SANDBOX/fields1.queue"
{ _field_resp "$EXISTING_4"; echo; _field_resp "$AFTER_5"; echo; } > "$STUB_BOARD_FIELD_QUEUE"
export STUB_BOARD_FIELD_QUEUE

out="$(bash "$BOOTSTRAP" 2>"$SANDBOX/err1.txt")"
rc=$?
log="$(cat "$GH_LOG")"

assert_eq 0 "$rc" "bootstrap-board (gh): exits 0 when the missing option is added cleanly"
assert_contains "$out" "+ Ready" "bootstrap-board (gh): reports the newly added option with a '+'"
assert_contains "$out" "= In progress" "bootstrap-board (gh): reports an already-present option with a '='"
assert_contains "$out" "= Blocked" "bootstrap-board (gh): reports Blocked as already present"
assert_contains "$out" "verified: every pre-existing option kept its id" "bootstrap-board (gh): confirms the post-mutation id-preservation check"
assert_contains "$log" "updateProjectV2Field" "bootstrap-board (gh): sends the updateProjectV2Field mutation"
assert_contains "$log" "\"In progress\",color:YELLOW" "bootstrap-board (gh): mutation resends the existing option's name/color unchanged"
assert_contains "$log" "\"Ready\",color:GRAY" "bootstrap-board (gh): mutation appends the missing option with its default color"

unset STUB_BOARD_FIELD_QUEUE

# ── 2. gh path: re-running is a no-op (all '=') -- no mutation issued ────────
: > "$GH_LOG"
ALL_5='[{"id":"O_R","name":"Ready","color":"GRAY","description":""},{"id":"O_IP","name":"In progress","color":"YELLOW","description":""},{"id":"O_IR","name":"In review","color":"PURPLE","description":""},{"id":"O_D","name":"Done","color":"GREEN","description":""},{"id":"O_B","name":"Blocked","color":"RED","description":""}]'
STUB_BOARD_FIELD_QUEUE="$SANDBOX/fields2.queue"
printf '%s\n' "$(_field_resp "$ALL_5")" > "$STUB_BOARD_FIELD_QUEUE"
export STUB_BOARD_FIELD_QUEUE

out="$(bash "$BOOTSTRAP")"
rc=$?
log="$(cat "$GH_LOG")"
mut_calls="$(printf '%s' "$log" | grep -c "updateProjectV2Field" || true)"

assert_eq 0 "$rc" "bootstrap-board (gh): re-run with every option present exits 0"
assert_contains "$out" "= Ready" "bootstrap-board (gh): no-op run reports Ready as already present"
assert_not_contains "$out" "+ " "bootstrap-board (gh): no-op run never reports a '+' addition"
assert_eq 0 "$mut_calls" "bootstrap-board (gh): no-op run never issues the mutation"

unset STUB_BOARD_FIELD_QUEUE

# ── 3. gh path: id drift after the mutation is a loud, non-zero-exit failure ─
: > "$GH_LOG"
BEFORE_DRIFT='[{"id":"O_IP","name":"In progress","color":"YELLOW","description":""},{"id":"O_D","name":"Done","color":"GREEN","description":""}]'
AFTER_DRIFT='[{"id":"O_IP_NEW","name":"In progress","color":"YELLOW","description":""},{"id":"O_D","name":"Done","color":"GREEN","description":""},{"id":"O_R","name":"Ready","color":"GRAY","description":""},{"id":"O_IR","name":"In review","color":"PURPLE","description":""},{"id":"O_B","name":"Blocked","color":"RED","description":""}]'
STUB_BOARD_FIELD_QUEUE="$SANDBOX/fields3.queue"
{ _field_resp "$BEFORE_DRIFT"; echo; _field_resp "$AFTER_DRIFT"; echo; } > "$STUB_BOARD_FIELD_QUEUE"
export STUB_BOARD_FIELD_QUEUE

out="$(bash "$BOOTSTRAP" 2>&1)"
rc=$?

assert_eq 1 "$rc" "bootstrap-board (gh): id drift after the update exits non-zero"
assert_contains "$out" "FATAL" "bootstrap-board (gh): id drift is reported loudly"
assert_contains "$out" "In progress (O_IP -> O_IP_NEW)" "bootstrap-board (gh): id drift names the exact option and both ids"

unset STUB_BOARD_FIELD_QUEUE

# ── 3b. gh path: the mutation itself failing is a loud, non-zero-exit failure ─
: > "$GH_LOG"
STUB_BOARD_FIELD_QUEUE="$SANDBOX/fields3b.queue"
printf '%s\n' "$(_field_resp "$EXISTING_4")" > "$STUB_BOARD_FIELD_QUEUE"
export STUB_BOARD_FIELD_QUEUE STUB_BOARD_MUTATION_FAIL=1

out="$(bash "$BOOTSTRAP" 2>&1)"
rc=$?

assert_eq 1 "$rc" "bootstrap-board (gh): a failed mutation exits non-zero"
assert_contains "$out" "GraphQL error updating field options" "bootstrap-board (gh): a failed mutation is reported on the way out"

unset STUB_BOARD_FIELD_QUEUE STUB_BOARD_MUTATION_FAIL

# ── 4. token path (github-api): same happy path over curl ────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "board": {"enabled": true, "project_number": 7, "owner": "acme", "status_field": "Status"}}
EOF
export GITHUB_TOKEN="test-secret-token"

USER_RESP='{"data":{"user":{"projectV2":{"id":"PVT_1"}}}}'
FIELDS_RESP="$(_field_resp "$EXISTING_4")"
MUT_RESP='{"data":{"updateProjectV2Field":{"projectV2Field":{"id":"FIELD_1"}}}}'
VERIFY_RESP="$(_field_resp "$AFTER_5")"
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$MUT_RESP" "$VERIFY_RESP" > "$CURL_QUEUE"

out="$(bash "$BOOTSTRAP")"
rc=$?
clog="$(cat "$CURL_LOG")"

assert_eq 0 "$rc" "bootstrap-board (token): exits 0 on a successful update"
assert_contains "$out" "+ Ready" "bootstrap-board (token): reports the newly added option"
assert_contains "$clog" "Authorization: Bearer" "bootstrap-board (token): every GraphQL call is authenticated"

unset GITHUB_TOKEN

# ── 5. Azure: missing state exits non-zero and names the config key ─────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acmeorg", "project": "widget", "work_item_type": "Product Backlog Item"}},
 "board": {"enabled": true, "azure_states": {"blocked": "Needs attention"}}}
EOF
out="$(bash "$BOOTSTRAP" 2>&1)"
rc=$?

assert_eq 1 "$rc" "bootstrap-board (azure): a missing configured state exits non-zero"
assert_contains "$out" "board.azure_states.blocked" "bootstrap-board (azure): names the exact config key to fix"
assert_contains "$out" "= ready (New)" "bootstrap-board (azure): reports a present default state with '='"

# Azure: every configured state present -> exit 0
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acmeorg", "project": "widget", "work_item_type": "Product Backlog Item"}},
 "board": {"enabled": true}}
EOF
out="$(bash "$BOOTSTRAP" 2>&1)"
rc=$?
assert_eq 0 "$rc" "bootstrap-board (azure): default states (no blocked mapping configured) all present -> exits 0"
assert_not_contains "$out" "!" "bootstrap-board (azure): no missing-state marker when everything resolves"

# ── 6. GitLab: verifies labels, always exits 0 ────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}, "board": {"enabled": true}}
EOF
out="$(bash "$BOOTSTRAP" 2>&1)"
rc=$?
assert_eq 0 "$rc" "bootstrap-board (gitlab): exits 0"
assert_contains "$out" "label-driven" "bootstrap-board (gitlab): notes boards are label-driven"
assert_contains "$out" "= pipeline:blocked" "bootstrap-board (gitlab): reports the relied-on label as present"

out="$(STUB_GITLAB_LABEL_LIST='[]' bash "$BOOTSTRAP" 2>&1)"
rc=$?
assert_eq 0 "$rc" "bootstrap-board (gitlab): still exits 0 even when a relied-on label is missing"
assert_contains "$out" "! pipeline:blocked" "bootstrap-board (gitlab): flags the missing label"

# ── 7. board disabled / file provider -> "board disabled", exit 0 ────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github"}, "board": {"enabled": false}}
EOF
out="$(bash "$BOOTSTRAP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "bootstrap-board: board.enabled=false exits 0"
assert_eq "board disabled" "$out" "bootstrap-board: board.enabled=false prints exactly 'board disabled'"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file"}, "board": {"enabled": true}}
EOF
out="$(bash "$BOOTSTRAP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "bootstrap-board: file provider exits 0"
assert_eq "board disabled" "$out" "bootstrap-board: file provider prints exactly 'board disabled'"

# ── 8. pipeline-status.sh's missing-option warning names this script ─────────
STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github"}, "board": {"enabled": true, "project_number": 7, "owner": "acme", "status_field": "Status"}}
EOF
GH_STATUS_ERR="$SANDBOX/status-err.txt"
STUB_BOARD_OPTIONS='{"fields":[{"name":"Status","id":"FIELD_ID_S","options":[{"name":"In progress","id":"OPT_INPROG"}]}]}' \
  bash "$STATUS" 42 "In progress" >/dev/null 2>"$GH_STATUS_ERR"
err="$(cat "$GH_STATUS_ERR")"
assert_contains "$err" "board status options missing from project #7" \
  "pipeline-status.sh: still emits the missing-option warning"
assert_contains "$err" "bootstrap-board.sh" \
  "pipeline-status.sh: missing-option warning now names bootstrap-board.sh"

finish
