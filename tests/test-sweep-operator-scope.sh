#!/usr/bin/env bash
# test-sweep-operator-scope.sh -- `talos.sh sweep` with multi-user claiming on
# acts only on the operator's own issues (#1075, part of #1041): another
# operator's issue is never healed, unblocked, counted as blocked or given an
# epic label change, and an unassigned issue is nobody's. With claiming off, or
# a provider without assignees, sweep is unchanged.
#
# Verb-level provider stub (a copy of scripts/, every script a verb calls is one
# journaling stub; the harness of test-talos-postmerge.sh). The operator is `bot`.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
unset TALOS_CLAIM_STATE
ERR="$SANDBOX/stderr"
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
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -n "$key" ]; then
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
PM="$GS/talos.sh"

CFG_ON='{"vcs": {"provider": "github"}, "roles": {"planner": true}}'
CFG_OFF='{"vcs": {"provider": "github"}, "roles": {"planner": true}, "issues": {"claim": false}}'
set_stub() {  # <key> <rc> [out] [err]
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^vcs $1\( \|\$\)"; }
sw() { OUT="$(bash "$PM" sweep "$@" 2>"$ERR")"; RC=$?; }
issue_json() {  # number "labels,..." [body] -> one list-issues item
  local n="$1" out="" l body="${3:-}"
  local IFS=,
  for l in $2; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"title":"t","labels":[%s],"author":{"login":"bot"},"body":%s}' "$n" "$out" "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$body")"
}

# The repo: 10 other's and 11 mine, each pipeline:ready with a merged PR; 20
# unassigned and 21 mine, each with a closed dependency (#99); 30 other's and 31
# my blocked issue; 40 other's and 41 my decomposed epic with no open child.
reset() {  # <config json>
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  unset TALOS_CLAIM_STATE
  printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"
  set_stub current-user 0 "bot"
  set_stub list-prs 0 "[]"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub pr-closes-issue 0 "closes"
  set_stub worktree.to-base 0 "talos:checkout state=kept"
  set_stub list-issues 0 "[$(issue_json 10 pipeline:ready),$(issue_json 11 pipeline:ready),$(issue_json 20 bug 'Depends on: #99'),$(issue_json 21 bug 'Depends on: #99'),$(issue_json 22 bug 'Depends on: #10'),$(issue_json 30 pipeline:blocked),$(issue_json 31 pipeline:blocked),$(issue_json 40 pipeline:epic-decomposed),$(issue_json 41 pipeline:epic-decomposed)]"
  set_stub list-assignees 0 '{"10":["alice"],"11":["bot"],"21":["bot"],"22":["bot"],"30":["alice"],"31":["bot"],"40":["alice"],"41":["bot"]}'
  set_stub find-pr 0 ""
  set_stub find-pr.10 0 '{"number":77,"state":"MERGED","title":"t","headRefName":"fix/issue-1-x"}'
  set_stub find-pr.11 0 '{"number":77,"state":"MERGED","title":"t","headRefName":"fix/issue-1-x"}'
  set_stub check-epic-acceptance 0 ""
}

# ── claiming on ──────────────────────────────────────────────────────────────
reset "$CFG_ON"
sw 1
assert_eq "0" "$RC" "sweep with claiming on exits 0"
assert_not_contains "$OUT" "heal=10 " "AC1 another operator's merged-ready issue is not healed"
assert_eq "0" "$(journal | grep -c '^vcs find-pr 10 \|close-issue 10 \|post_stage merged orchestrator 10 ')" "AC1 no post-merge call for another operator's issue"
assert_contains "$OUT" "heal=11 pr=77" "AC1 the operator's own issue in the same state is healed"

assert_not_contains "$(journal)" "label-issue 20 " "AC2 an unassigned issue with closed dependencies is not unblocked"
assert_contains "$(journal)" "label-issue 21 --add pipeline:ready" "AC2 the operator's own issue with closed dependencies is unblocked"

assert_not_contains "$(journal)" "label-issue 22 " "AC2 an own issue depending on another operator's open issue still waits"
assert_contains "$OUT" "blocked_issues=1" "AC3 another operator's blocked issue is not counted"
assert_contains "$(journal)" "#31" "AC3 the operator's own blocked issue is in the notice"
assert_not_contains "$(journal)" "#30" "AC3 another operator's blocked issue is not in the notice"
assert_eq "0" "$(journal | grep -c 'check-epic-acceptance 40\|close-issue 40\|label-issue 40')" "AC3 another operator's epic gets no acceptance check or label change"
assert_contains "$OUT" "epic=41 action=closed" "AC3 the operator's own epic is closed"
assert_eq "1" "$(called list-assignees)" "one bulk read of the assignees"

# ── a failed assignee read ───────────────────────────────────────────────────
reset "$CFG_ON"
set_stub list-assignees 1 "" "gh failed"
sw 1
assert_eq "0" "$RC" "AC4 a failed list-assignees: sweep still exits 0"
assert_contains "$OUT" "warn reason=assignees-unlisted" "AC4 a failed list-assignees warns assignees-unlisted"
assert_eq "0" "$(called find-pr)" "AC4 nothing is healed"
assert_eq "0" "$(called close-issue)" "AC4 nothing is closed"
assert_eq "0" "$(called label-issue)" "AC4 nothing is unblocked or labeled"
assert_eq "0" "$(called check-epic-acceptance)" "AC4 no epic is touched"

# ── claiming off, or no assignees: today's sweep ─────────────────────────────
reset "$CFG_OFF"
sw 1
assert_contains "$OUT" "heal=10 pr=77" "AC5 claiming off: another operator's issue is healed as on main"
assert_contains "$OUT" "heal=11 pr=77" "AC5 claiming off: the operator's issue is healed"
assert_contains "$(journal)" "label-issue 20 --add pipeline:ready" "AC5 claiming off: an unassigned issue is unblocked"
assert_contains "$(journal)" "label-issue 21 --add pipeline:ready" "AC5 claiming off: any assignee's issue is unblocked"
assert_contains "$OUT" "blocked_issues=2" "AC5 claiming off: every blocked issue is counted"
assert_contains "$OUT" "epic=40 action=closed" "AC5 claiming off: any epic is closed"
assert_eq "0" "$(called list-assignees)" "AC5 claiming off: no assignee is read"

reset "$CFG_ON"
set_stub list-assignees 2 "" "not implemented"
sw 1
assert_contains "$OUT" "heal=10 pr=77" "AC5 no assignees on the provider (exit 2): sweep is unfiltered"
assert_contains "$OUT" "blocked_issues=2" "AC5 exit 2: every blocked issue is counted"
assert_not_contains "$OUT" "assignees-unlisted" "AC5 exit 2 is not a failed read"

finish
