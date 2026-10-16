#!/usr/bin/env bash
# test-azure-board-team-default.sh -- the board calls of pipeline-status.sh need a
# team (the live backlogs API 404s without one), so with no board.azure_team the
# project's default team is used (#743):
#   AC1 no team and no area path: defaultTeam.id of the project carries the calls
#   AC2 an area path that equals no team's default area: default team + one warn
#   AC3 board-columns-unavailable names the failed step (teams/backlogs/columns)
#   AC4 board.azure_team set: that team, no default-team lookup
#   AC5 an area path matching a team's default area: that team, no lookup, no warn
# Everything runs on the az stub (tests/stubs/az, STUB_AZURE_* answers); the stub
# answers the team-less backlogs URL with the live 404.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

STATUS_SH="$TALOS_ROOT/scripts/pipeline-status.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset PIPELINE_RUN_ID XDG_RUNTIME_DIR

export STUB_AZURE_PROJECT='{"id": "p-1", "name": "Proj", "defaultTeam": {"id": "t-default", "name": "Proj Team"}}'
export STUB_AZURE_TEAMS='{"value": [{"id": "t-other", "name": "Other"}, {"id": "t-agents", "name": "Agents Work Items"}]}'
export STUB_AZURE_TEAMFIELDS_t_other='{"defaultValue": "Proj\\Other"}'
export STUB_AZURE_TEAMFIELDS_t_agents='{"defaultValue": "Proj\\Agents"}'
export STUB_AZURE_BACKLOGS='{"value": [{"name": "Epics", "type": "portfolio"}, {"name": "Backlog items", "type": "requirement"}]}'
export STUB_AZURE_BOARD_COLUMNS='{"value": [
 {"name": "New", "stateMappings": {"Product Backlog Item": "New"}},
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "In Review", "stateMappings": {"Product Backlog Item": "Committed"}},
 {"name": "Done", "stateMappings": {"Product Backlog Item": "Done"}}]}'

cfg_json() {  # cfg_json <vcs.azure extra members, JSON text starting with a comma, or empty> <board extra members, same>
  printf '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "Proj"%s}}, "issues": {"assignee": "none"}, "comments": {"enabled": false}, "board": {"enabled": true%s}}\n' "$1" "$2" > "$PIPELINE_CONFIG"
}
move() {  # move <status>: sets OUT (stdout), ERR (stderr), RC, LOG (az calls)
  : > "$GH_LOG"
  OUT="$(bash "$STATUS_SH" 5 "$1" 2>"$SANDBOX/move.err")"; RC=$?
  ERR="$(cat "$SANDBOX/move.err")"
  LOG="$(cat "$GH_LOG")"
}
count() {  # count <needle> <haystack>: lines containing the needle
  printf '%s\n' "$2" | grep -c -F -- "$1" || true
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
cfg_json "" ""
move "In progress"
assert_contains "$LOG" "https://dev.azure.com/acme/_apis/projects/Proj?api-version=7.1" "AC1 the default team is read from the project"
assert_contains "$LOG" "https://dev.azure.com/acme/Proj/t-default/_apis/work/backlogs" "AC1 the backlogs call carries the default team id"
assert_contains "$LOG" "https://dev.azure.com/acme/Proj/t-default/_apis/work/boards/Backlog%20items/columns" "AC1 the columns call carries the default team id"
assert_contains "$LOG" "[work-item] [update] [--id] [5] [--state] [Approved]" "AC1 the work item moves to the state of the In Progress column (Approved)"
assert_not_contains "$ERR" "board-columns-unavailable" "AC1 no board-columns-unavailable warn"

# ── AC2 ──────────────────────────────────────────────────────────────────────
cfg_json ', "area_path": "Proj\\Nowhere"' ""
move "In progress"
assert_eq "1" "$(count "warn reason=board-team-unmatched area=Proj\\Nowhere" "$ERR")" "AC2 exactly one board-team-unmatched warn naming the area path"
assert_contains "$LOG" "https://dev.azure.com/acme/Proj/t-default/_apis/work/boards/Backlog%20items/columns" "AC2 the columns come from the default team's board"
assert_contains "$LOG" "[--state] [Approved]" "AC2 the work item moves to the state of the column"
assert_not_contains "$ERR" "board-columns-unavailable" "AC2 no board-columns-unavailable warn"

# ── AC3 ──────────────────────────────────────────────────────────────────────
cfg_json "" ""
STUB_AZURE_PROJECT_FAIL=1 move "In progress"
assert_contains "$ERR" "warn reason=board-columns-unavailable step=teams" "AC3 a failed project lookup is step=teams"
assert_contains "$ERR" "board.azure_team" "AC3 the warn suggests setting board.azure_team"
assert_contains "$LOG" "[--state] [Committed]" "AC3 the table default is still used"
assert_eq "0" "$RC" "AC3 the exit code stays 0"
STUB_AZURE_PROJECT='{"id": "p-1", "name": "Proj"}' move "In progress"
assert_contains "$ERR" "step=teams" "AC3 a project with no defaultTeam.id is step=teams"
STUB_AZURE_BACKLOGS_FAIL=1 move "In progress"
assert_contains "$ERR" "warn reason=board-columns-unavailable step=backlogs" "AC3 a failed backlogs call is step=backlogs"
STUB_AZURE_BACKLOGS='{"value": [{"name": "Epics", "type": "portfolio"}]}' move "In progress"
assert_contains "$ERR" "step=backlogs" "AC3 no requirement backlog is step=backlogs"
STUB_AZURE_BOARD_COLUMNS_FAIL=1 move "In progress"
assert_contains "$ERR" "warn reason=board-columns-unavailable step=columns" "AC3 a failed columns call is step=columns"
assert_contains "$LOG" "[--state] [Committed]" "AC3 the table default is used after a columns failure"
assert_eq "0" "$RC" "AC3 the exit code stays 0 after a columns failure"

# ── AC4 ──────────────────────────────────────────────────────────────────────
cfg_json "" ', "azure_team": "Agents Work Items"'
move "In progress"
assert_contains "$LOG" "https://dev.azure.com/acme/Proj/Agents%20Work%20Items/_apis/work/backlogs" "AC4 board.azure_team is the team in the base URL"
assert_not_contains "$LOG" "_apis/projects/Proj?" "AC4 no default-team lookup is made"
assert_contains "$LOG" "[--state] [Approved]" "AC4 the columns still decide the state"

# ── AC5 ──────────────────────────────────────────────────────────────────────
cfg_json ', "area_path": "Proj\\Agents"' ""
move "In progress"
assert_contains "$LOG" "https://dev.azure.com/acme/Proj/t-agents/_apis/work/backlogs" "AC5 the team whose default area matches is used"
assert_not_contains "$LOG" "_apis/projects/Proj?" "AC5 no default-team lookup is made"
assert_not_contains "$ERR" "board-team-unmatched" "AC5 no board-team-unmatched warn"
assert_contains "$LOG" "[--state] [Approved]" "AC5 the columns still decide the state"

finish
