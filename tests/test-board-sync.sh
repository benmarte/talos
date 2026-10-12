#!/usr/bin/env bash
# test-board-sync.sh -- the GitHub project board follows the pipeline (#523):
#   AC1 create-issue puts a new pipeline issue on the board with a status from its labels
#   AC3 a failed board step is one warn line; create-issue still succeeds
#   AC4 a board read that returns exactly its cap says so on stderr
#   AC5 a failing review verdict moves the card to Blocked (done)
#   AC6 the fix-round redispatch moves it back to In progress (gate fix-round)
# Everything runs on stubs: the gh stub for GitHub, and a logging stand-in for
# pipeline-status.sh where the board step itself is what is asserted.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_RETRY_SLEEP_SCALE=0 STUB_REPO=acme/widget
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
BOARD_CFG='"board": {"enabled": true, "project_number": 7, "owner": "acme"}'

# ── AC1, AC3: create-issue ───────────────────────────────────────────────────
# The real pipeline-vcs.sh beside a pipeline-status.sh that logs its arguments
# and exits $STATUS_RC.
CS="$SANDBOX/cs"
mkdir -p "$CS"
cp "$TALOS_ROOT"/scripts/* "$CS/"
cat > "$CS/pipeline-status.sh" <<'TALOS_bsStatusQm4Wx8Kp'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STATUS_LOG:?}"
[ "${STATUS_RC:-0}" -eq 0 ] || echo "pipeline-status: could not resolve project #7 for owner 'acme'" >&2
exit "${STATUS_RC:-0}"
TALOS_bsStatusQm4Wx8Kp
export STATUS_LOG="$SANDBOX/status.log"
printf 'body\n' > "$SANDBOX/body.md"
ci() {  # create-issue with the given labels; sets OUT, ERRS, RC
  : > "$STATUS_LOG"
  local _a=() _l
  for _l in "$@"; do _a+=(--label "$_l"); done
  OUT="$(STUB_NEW_ISSUE_NUMBER=42 bash "$CS/pipeline-vcs.sh" create-issue "Fix the crash" "$SANDBOX/body.md" "${_a[@]}" 2>"$SANDBOX/ci.err")"; RC=$?
  ERRS="$(cat "$SANDBOX/ci.err")"
}
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"assignee": "none"}, %s}\n' "$BOARD_CFG" > "$PIPELINE_CONFIG"
ci pipeline:ready
assert_eq "0" "$RC" "AC1 create-issue exits 0 with the board on"
assert_eq "https://github.com/acme/widget/issues/42" "$OUT" "AC1 stdout is the issue URL alone"
assert_eq "42 Ready" "$(cat "$STATUS_LOG")" "AC1 a pipeline:ready issue goes on the board as Ready"
ci pipeline:dev
assert_eq "42 In progress" "$(cat "$STATUS_LOG")" "AC1 a pipeline:dev issue goes on the board as In progress"
ci pipeline:ready pipeline:blocked
assert_eq "42 Blocked" "$(cat "$STATUS_LOG")" "AC1 pipeline:blocked wins over another pipeline label"

STATUS_RC=1 ci pipeline:ready
assert_eq "0" "$RC" "AC3 a failed board step leaves create-issue at exit 0"
assert_eq "https://github.com/acme/widget/issues/42" "$OUT" "AC3 stdout is still the URL alone"
assert_eq "1" "$(printf '%s\n' "$ERRS" | grep -c '^warn reason=board-add-failed issue=42$')" \
  "AC3 exactly one warn reason=board-add-failed line" "$ERRS"

# ── AC4: capped board reads ──────────────────────────────────────────────────
# A gh in front of the stub: `project list` answers 50 other projects, and the
# projectItems read answers 50 items of other projects, when asked to.
mkdir -p "$SANDBOX/capbin"
cat > "$SANDBOX/capbin/gh" <<'TALOS_bsCapGhRt6Vn2Lq'
#!/usr/bin/env bash
case "$*" in
  "project list"*)
    if [ -n "${CAP_PROJECTS:-}" ]; then
      python3 -I -c 'import json; print(json.dumps({"projects": [{"number": 100 + i, "id": "P%d" % i} for i in range(50)]}))'
      exit 0
    fi ;;
  "api graphql "*projectItems*)
    if [ -n "${CAP_ITEMS:-}" ]; then
      python3 -I -c 'import json; print(json.dumps({"data": {"repository": {"issue": {"projectItems": {"nodes": [{"id": "I%d" % i, "project": {"id": "OTHER%d" % i}} for i in range(50)]}}}}}))'
      exit 0
    fi ;;
esac
exec "${STUBS_DIR:?}/gh" "$@"
TALOS_bsCapGhRt6Vn2Lq
chmod +x "$SANDBOX/capbin/gh"
export STUBS_DIR
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"assignee": "none"}, %s}\n' "$BOARD_CFG" > "$PIPELINE_CONFIG"
OUT="$(PATH="$SANDBOX/capbin:$PATH" CAP_PROJECTS=1 TALOS_BOARD_NO_CACHE=1 bash "$TALOS_ROOT/scripts/pipeline-status.sh" 42 "In review" 2>&1)"
assert_contains "$OUT" "board=list-capped n=50 read=projects" "AC4 a project list of exactly 50 without the target says it is capped"
OUT="$(PATH="$SANDBOX/capbin:$PATH" CAP_ITEMS=1 TALOS_BOARD_NO_CACHE=1 bash "$TALOS_ROOT/scripts/pipeline-status.sh" 42 "In review" 2>&1)"
assert_contains "$OUT" "board=list-capped n=50 read=items" "AC4 an issue with exactly 50 project items says the read is capped"
# The fields read is the token path's (curl stub): the project id, then 50
# fields with no status field among them.
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}, %s}\n' "$BOARD_CFG" > "$PIPELINE_CONFIG"
python3 -I -c '
import json
print(json.dumps({"data": {"user": {"projectV2": {"id": "PVT_1"}}}}))
print(json.dumps({"data": {"node": {"fields": {"nodes": [{} for _ in range(50)]}}}}))
' > "$CURL_QUEUE"
OUT="$(GITHUB_TOKEN=stub TALOS_BOARD_NO_CACHE=1 bash "$TALOS_ROOT/scripts/pipeline-status.sh" 42 "In review" 2>&1)"
assert_contains "$OUT" "board=list-capped n=50 read=fields" "AC4 a fields read of exactly 50 without the status field says it is capped"

# ── AC5, AC6: done and gate fix-round ────────────────────────────────────────
# talos.sh on a scripts dir whose vcs, notify, hooks, status and events are
# logging stubs (test-talos-done.sh's shape).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-} ${1:-}"; else cands="$n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
[ "$n" != notify ] || [ "${3:-}" != "-" ] || cat > /dev/null
if [ -n "$key" ]; then
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
printf '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, %s}\n' "$BOARD_CFG" > "$PIPELINE_CONFIG"
reset() { rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"; printf 'spend: 1 token' > "$STUB_DIR/events.cost.out"; }
statuses() { grep '^status ' "$STUB_DIR/journal" 2>/dev/null; }
SUM="$SANDBOX/summary.txt"
printf 'one line\n' > "$SUM"
for rv in qa:FAIL reviewer:CHANGES security:FINDINGS adversarial:FINDINGS; do
  reset
  bash "$GS/talos.sh" done "${rv%%:*}" --issue 42 --pr 57 --verdict "${rv#*:}" --summary-file "$SUM" > "$SANDBOX/out" 2>&1
  assert_eq "status 42 Blocked" "$(statuses)" "AC5 ${rv%%:*} ${rv#*:} moves the card to Blocked"
done

reset
printf 'stage=reviewer count=1 total=1\n' > "$STUB_DIR/vcs.record-attempt.out"
OUT="$(bash "$GS/talos.sh" gate fix-round 42 reviewer --pr 57 2>/dev/null)"
assert_contains "$OUT" "verdict=redispatch" "AC6 the fix round is a redispatch"
assert_eq "status 42 In progress" "$(statuses)" "AC6 the redispatch moves the card back to In progress"
reset
printf 'stage=reviewer count=1 total=1\n' > "$STUB_DIR/vcs.record-attempt.out"
printf '1\n' > "$STUB_DIR/status.rc"
OUT="$(bash "$GS/talos.sh" gate fix-round 42 reviewer --pr 57 2>/dev/null)"
assert_contains "$OUT" "verdict=redispatch" "AC6 a failed board write leaves the verdict a redispatch"
assert_contains "$OUT" "warn reason=board-failed issue=42" "AC6 a failed board write is one warn line"
# A board with no project number (Azure work-item states): pipeline-status.sh
# decides whether there is a board, as it does for done's Blocked write.
printf '{"vcs": {"provider": "azure"}, "comments": {"enabled": false}, "board": {"azure_states": {"blocked": "Blocked"}}}\n' > "$PIPELINE_CONFIG"
reset
printf 'stage=reviewer count=1 total=1\n' > "$STUB_DIR/vcs.record-attempt.out"
OUT="$(bash "$GS/talos.sh" gate fix-round 42 reviewer --pr 57 2>/dev/null)"
assert_eq "status 42 In progress" "$(statuses)" "AC6 the redispatch writes In progress with no board.project_number set"

finish
