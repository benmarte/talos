#!/usr/bin/env bash
# test-azure-board-columns.sh -- on Azure DevOps pipeline-status.sh takes each
# status's work-item State from the team board's column-to-state mapping (#732):
#   AC1 the columns decide the State when azure_states is not set
#   AC2 an explicit board.azure_states.<status> wins over the columns
#   AC3 board.azure_columns.<status> replaces the default column names
#   AC4 two statuses on one state: one board-states-collide warn per run
#   AC5 a status with no column: board-column-unresolved, no update
#   AC6 columns unreadable: one board-columns-unavailable, explicit/table state
#   AC7 the success line carries the System.BoardColumn read back
#   AC8 --dry-run prints the resolved state and updates nothing
# Everything runs on the az stub (tests/stubs/az, STUB_AZURE_* answers).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

STATUS_SH="$TALOS_ROOT/scripts/pipeline-status.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset PIPELINE_RUN_ID XDG_RUNTIME_DIR

# The board of terrasow's "Agents Work Items" team: In Progress is Approved,
# In Review is Committed.
export STUB_AZURE_TEAMS='{"value": [{"id": "t-other", "name": "Other"}, {"id": "t-agents", "name": "Agents Work Items"}]}'
export STUB_AZURE_TEAMFIELDS_t_other='{"defaultValue": "Proj\\Other"}'
export STUB_AZURE_TEAMFIELDS_t_agents='{"defaultValue": "Proj\\Agents"}'
export STUB_AZURE_BACKLOGS='{"value": [{"name": "Epics", "type": "portfolio"}, {"name": "Backlog items", "type": "requirement"}, {"name": "Tasks", "type": "task"}]}'
BOARD_NEW='{"value": [
 {"name": "New", "stateMappings": {"Product Backlog Item": "New"}},
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "In Review", "stateMappings": {"Product Backlog Item": "Committed"}},
 {"name": "Done", "stateMappings": {"Product Backlog Item": "Done"}}]}'
export STUB_AZURE_BOARD_COLUMNS="$BOARD_NEW"

cfg_json() {  # cfg_json <extra board members, JSON text starting with a comma, or empty>
  printf '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "Proj", "area_path": "Proj\\\\Agents"}}, "issues": {"assignee": "none"}, "comments": {"enabled": false}, "board": {"enabled": true%s}}\n' "$1" > "$PIPELINE_CONFIG"
}
move() {  # move <status> [flags...]: sets OUT (stdout), ERR (stderr), RC, LOG (az calls)
  : > "$GH_LOG"
  OUT="$(bash "$STATUS_SH" "${@:2}" 5 "$1" 2>"$SANDBOX/move.err")"; RC=$?
  ERR="$(cat "$SANDBOX/move.err")"
  LOG="$(cat "$GH_LOG")"
}
count() {  # count <needle> <haystack>: lines containing the needle
  printf '%s\n' "$2" | grep -c -F -- "$1" || true
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
cfg_json ""
move "In progress"
assert_contains "$LOG" "[work-item] [update] [--id] [5] [--state] [Approved]" "AC1 In progress updates the work item to the state of the In Progress column (Approved)"
move "In review"
assert_contains "$LOG" "[work-item] [update] [--id] [5] [--state] [Committed]" "AC1 In review updates the work item to the state of the In Review column (Committed)"

# ── AC2 ──────────────────────────────────────────────────────────────────────
cfg_json ', "azure_states": {"in_progress": "Active"}'
move "In progress"
assert_contains "$LOG" "[--state] [Active]" "AC2 an explicit board.azure_states.in_progress wins over the column"
move "In review"
assert_contains "$LOG" "[--state] [Committed]" "AC2 the other statuses still resolve from the columns"

# ── AC3 ──────────────────────────────────────────────────────────────────────
export STUB_AZURE_BOARD_COLUMNS='{"value": [
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "Doing Now", "stateMappings": {"Product Backlog Item": "Active"}}]}'
cfg_json ', "azure_columns": {"in_progress": "doing now"}'
move "In progress"
assert_contains "$LOG" "[--state] [Active]" "AC3 board.azure_columns.in_progress resolves that column's state (case-insensitive)"
assert_not_contains "$LOG" "[--state] [Approved]" "AC3 the default name list is not used for a status with a configured column"
export STUB_AZURE_BOARD_COLUMNS="$BOARD_NEW"

# ── AC4 ──────────────────────────────────────────────────────────────────────
export STUB_AZURE_BOARD_COLUMNS='{"value": [
 {"name": "New", "stateMappings": {"Product Backlog Item": "New"}},
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "In Review", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "Done", "stateMappings": {"Product Backlog Item": "Done"}}]}'
cfg_json ""
export PIPELINE_RUN_ID="ac4-run"
move "In progress"
_err1="$ERR"
move "In review"
_calls2="$(count "/columns" "$LOG")"
assert_eq "1" "$(count "warn reason=board-states-collide" "$_err1
$ERR")" "AC4 exactly one board-states-collide line across two calls of one run"
assert_eq "0" "$_calls2" "AC4 the second call of the run makes no board-columns REST call"
unset PIPELINE_RUN_ID
export STUB_AZURE_BOARD_COLUMNS="$BOARD_NEW"

# ── AC5 ──────────────────────────────────────────────────────────────────────
export STUB_AZURE_BOARD_COLUMNS='{"value": [
 {"name": "New", "stateMappings": {"Product Backlog Item": "New"}},
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "Done", "stateMappings": {"Product Backlog Item": "Done"}}]}'
cfg_json ""
move "In review"
assert_contains "$ERR" "warn reason=board-column-unresolved" "AC5 a status matching no column warns board-column-unresolved"
assert_not_contains "$LOG" "work-item] [update]" "AC5 no work-item update runs for it"
assert_eq "0" "$RC" "AC5 the exit code is 0"
export STUB_AZURE_BOARD_COLUMNS="$BOARD_NEW"

# ── AC6 ──────────────────────────────────────────────────────────────────────
export STUB_AZURE_BOARD_COLUMNS_FAIL=1
cfg_json ""
move "In progress"
assert_eq "1" "$(count "warn reason=board-columns-unavailable" "$ERR")" "AC6 an unreadable board is one board-columns-unavailable warn"
assert_contains "$LOG" "[--state] [Committed]" "AC6 the table default is used and the update still runs"
assert_eq "0" "$RC" "AC6 the exit code is 0"
cfg_json ', "azure_states": {"in_progress": "Active"}'
move "In progress"
assert_contains "$LOG" "[--state] [Active]" "AC6 an explicit state is used when the board is unreadable"
unset STUB_AZURE_BOARD_COLUMNS_FAIL

# ── AC7 ──────────────────────────────────────────────────────────────────────
cfg_json ""
export STUB_AZURE_BOARDCOLUMN="In Progress"
move "In progress"
assert_eq "#5 → In progress (ADO state: Approved, column: In Progress)" "$(printf '%s\n' "$OUT" | tail -n1)" "AC7 the success line names the column read back"
export STUB_AZURE_BOARDCOLUMN_FAIL=1
move "In progress"
assert_eq "#5 → In progress (ADO state: Approved)" "$(printf '%s\n' "$OUT" | tail -n1)" "AC7 the state-only line when the read-back fails"
unset STUB_AZURE_BOARDCOLUMN STUB_AZURE_BOARDCOLUMN_FAIL

# ── AC8 ──────────────────────────────────────────────────────────────────────
cfg_json ""
move "In progress" --dry-run
assert_contains "$OUT" "--state Approved" "AC8 --dry-run prints the resolved state"
assert_not_contains "$LOG" "work-item] [update]" "AC8 --dry-run issues no work-item update"

finish
