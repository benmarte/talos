#!/usr/bin/env bash
# test-run-id-740.sh -- `talos.sh run` exports one PIPELINE_RUN_ID per run (#740),
# so the per-run board caches in pipeline-status.sh apply in a real run:
#   AC1 an unset id becomes <TALOS_RUN_PID>-<TALOS_RUN_STARTED>, seen by every status move
#   AC2 two status moves in one run: one board-columns REST call, one collide warn
#   AC3 a caller-set id is kept unchanged
#   AC4 a continued run (the exec after a merge) sees the same id as the pass before
# The fixture is the run-sections one (stubbed vcs/agent/collect, a copied scripts
# dir); pipeline-status.sh is a recorder stub except in AC2, which uses the real one
# on the az stub.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0
# The sections file ends on `finish`; keep the real one for this file's own end.
eval "_real_finish() $(declare -f finish | tail -n +2)"
finish() { :; }
. "$(dirname "$0")/talos-run-sections.sh"
unset -f finish
eval "finish() $(declare -f _real_finish | tail -n +2)"
nonempty() {  # nonempty <value> <label>
  if [ -n "$1" ]; then pass "$2"; else fail "$2" "the value is empty"; fi
}
unset PIPELINE_RUN_ID XDG_RUNTIME_DIR
export TALOS_LEASE_TTL_S=1800 TALOS_NOW=21000

REAL_STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"
# The recorder: one line per move, with the id the move saw and the run's own.
cat > "$GS/pipeline-status.sh" <<'TALOS_stubstatusRid4Qm8Zt'
#!/usr/bin/env bash
printf 'move=%s id=%s pid=%s started=%s\n' "$*" "${PIPELINE_RUN_ID-<unset>}" "${TALOS_RUN_PID-}" "${TALOS_RUN_STARTED-}" >> "${STUB_DIR:?}/status.log"
TALOS_stubstatusRid4Qm8Zt
chmod +x "$GS/pipeline-status.sh"
slog() { cat "$STUB_DIR/status.log" 2>/dev/null; }
field() {  # field <key> <line>
  printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
reset_stubs
LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
rn --issue 9 --max-iterations 1
_l="$(slog | head -n 1)"
_id="$(field id "$_l")"
assert_contains "$_l" "move=9 In progress" "AC1 the validator's board move reached pipeline-status.sh"
assert_eq "$(field pid "$_l")-$(field started "$_l" | tr -dc '0-9A-Za-z')" "$_id" \
  "AC1 an unset PIPELINE_RUN_ID is exported as <TALOS_RUN_PID>-<TALOS_RUN_STARTED>, without the timestamp's separators"
nonempty "$(field pid "$_l")" "AC1 the id is built from a non-empty run pid"

# ── AC3 ──────────────────────────────────────────────────────────────────────
reset_stubs
LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
PIPELINE_RUN_ID=caller-run-7 rn --issue 9 --max-iterations 1
assert_eq "caller-run-7" "$(field id "$(slog | head -n 1)")" "AC3 a caller-set PIPELINE_RUN_ID is kept unchanged"

# ── AC4 ──────────────────────────────────────────────────────────────────────
# PR 12 merges (its board move is Done), the run execs itself for the next pass,
# which dispatches the validator on issue 21 (its board move is In progress).
printf '%s' "$STUB_BODY" > "$GS/pipeline-worktree.sh"
export GS_DIR="$GS" LEASE_FILE="$LEASE"
merge_fixture "$ALL_APPROVALS"
draft_ready
rm -f "$SANDBOX/.git/talos/run.stop"
printf 'talos:checkout state=returned\n' > "$STUB_DIR/worktree.out"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message.validator"
printf '{"number": 21, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.21"
printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"merge"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[21],"held":[],"inflight":[],"owners":[],"capped":[],"priority":{}}' > "$STUB_DIR/collect.json"
printf '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[21],"held":[],"inflight":[],"owners":[],"capped":[],"priority":{}}' > "$STUB_DIR/collect.merged"
printf '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[],"held":[],"inflight":[],"owners":[],"capped":[],"priority":{}}' > "$STUB_DIR/collect.drained"
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
printf 'cp "$d/collect.drained" "$d/collect.json"\n' > "$STUB_DIR/hook.validator.1"
rn --max-iterations 6
_first="$(slog | sed -n 1p)"
_second="$(slog | sed -n 2p)"
assert_contains "$_first" "move=9 Done" "AC4 the merge pass moved the card to Done"
assert_contains "$_second" "move=21 In progress" "AC4 the continued pass moved the next issue"
assert_not_contains "$_first" "id=<unset>" "AC4 the first pass saw a PIPELINE_RUN_ID"
assert_eq "$(field id "$_first")" "$(field id "$_second")" "AC4 the continued run keeps the PIPELINE_RUN_ID of the pass before it"

# ── AC2 ──────────────────────────────────────────────────────────────────────
# The real pipeline-status.sh on the az stub, two moves in one run (validator
# CONFIRMED -> In progress, developer PR_OPENED -> In review). Both statuses map
# to one state, so the board collides.
cp "$REAL_STATUS" "$GS/pipeline-status-real.sh"
# The run does not relay a successful move's stderr, so the wrapper keeps it.
cat > "$GS/pipeline-status.sh" <<'TALOS_stubstatusWrp7Hn3Vc'
#!/usr/bin/env bash
exec bash "$(dirname "$0")/pipeline-status-real.sh" "$@" 2>> "${STUB_DIR:?}/status.err"
TALOS_stubstatusWrp7Hn3Vc
export STUB_AZURE_TEAMS='{"value": [{"id": "t-agents", "name": "Agents Work Items"}]}'
export STUB_AZURE_TEAMFIELDS_t_agents='{"defaultValue": "Proj\\Agents"}'
export STUB_AZURE_BACKLOGS='{"value": [{"name": "Backlog items", "type": "requirement"}]}'
export STUB_AZURE_BOARD_COLUMNS='{"value": [
 {"name": "In Progress", "stateMappings": {"Product Backlog Item": "Approved"}},
 {"name": "In Review", "stateMappings": {"Product Backlog Item": "Approved"}}]}'
reset_stubs
LEASE_RESET
printf '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "Proj", "area_path": "Proj\\\\Agents"}}, "issues": {"max_parallel": 1, "assignee": "none"}, "comments": {"enabled": false}, "roles": {"validator": true, "developer": true}, "board": {"enabled": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' > "$SANDBOX/talos.pipeline.json"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message.validator"
printf 'https://github.com/acme/widget/pull/12\nimplemented\n' > "$STUB_DIR/message.developer"
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9.dev"
printf 'cp "$d/view-issue.9.dev" "$d/view-issue.9"\n' > "$STUB_DIR/hook.validator.1"
: > "$GH_LOG"
rn --issue 9 --max-iterations 2
_az="$(cat "$GH_LOG")"
assert_contains "$(journal)" "agent developer" "AC2 the run made its second pass"
assert_eq "2" "$(printf '%s\n' "$_az" | grep -c -F -- "[work-item] [update]" || true)" "AC2 the run made two status moves"
assert_eq "1" "$(printf '%s\n' "$_az" | grep -c -F -- "/columns" || true)" "AC2 two status moves in one run make one board-columns REST call"
assert_eq "1" "$(grep -c -F -- "warn reason=board-states-collide" "$STUB_DIR/status.err" || true)" "AC2 two status moves in one run print one board-states-collide warn"

finish
