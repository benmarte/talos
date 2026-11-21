#!/usr/bin/env bash
# test-sweep-unblock-code-driver.sh -- #961: the sweep's dependency unblock runs
# in every sweep (not only with roles.planner), and skips an issue that is
# blocked, in flight (any other pipeline:* label) or has an open pipeline PR.
#   AC1 roles.planner unset: an open issue whose `Depends on:` issues are all closed gets pipeline:ready
#   AC2 an in-flight pipeline label on it: no ready label
#   AC3 pipeline:blocked on it: no ready label
#   AC4 an open dependency keeps the issue waiting
#   AC6 an open pipeline PR for the issue: no ready label
#   AC7 epic auto-close stays behind roles.planner
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
# One journaling stub for every script the sweep calls: `vcs <verb>` answers
# from $STUB_DIR/<verb>.out (rc 0 unless <verb>.rc exists).
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
printf "%s %s\n" "$n" "$*" >> "$d/journal"
cat > /dev/null 2>&1 < /dev/null
if [ "$n" = "vcs" ]; then
  [ -f "$d/$1.out" ] && cat "$d/$1.out"
  [ -f "$d/$1.rc" ] && exit "$(cat "$d/$1.rc")"
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
PM="$GS/talos.sh"
ERR="$SANDBOX/stderr"

issue_json() {  # number "labels,..." [body]
  local n="$1" out="" l body="${3:-}"
  local IFS=,
  for l in $2; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"title":"t","labels":[%s],"body":%s}' "$n" "$out" "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$body")"
}
# fresh <issues-json> [list-prs json]: a GitHub provider, no planner key.
fresh() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '%s' '{"vcs": {"provider": "github"}}' > "$SANDBOX/talos.pipeline.json"
  printf '%s' "$1" > "$STUB_DIR/list-issues.out"
  printf '%s' "${2:-[]}" > "$STUB_DIR/list-prs.out"
  printf '%s' "bot" > "$STUB_DIR/current-user.out"
}
sw() { OUT="$(bash "$PM" sweep 2>"$ERR")"; RC=$?; }
readied() { grep -c "^vcs label-issue $1 --add pipeline:ready" "$STUB_DIR/journal" 2>/dev/null; }

DEP='Depends on: #29'

fresh "[$(issue_json 30 bug "$DEP")]"
sw
assert_eq "1" "$(readied 30)" "AC1 roles.planner unset: an issue whose dependencies are all closed gets pipeline:ready"
assert_contains "$OUT" "unblocked=30" "AC1 the sweep reports the unblock"

for L in pipeline:confirmed pipeline:dev pipeline:review pipeline:approved pipeline:needs-owner; do
  fresh "[$(issue_json 30 "bug,$L" "$DEP")]"
  sw
  assert_eq "0" "$(readied 30)" "AC2 an issue carrying $L is not re-queued"
done

fresh "[$(issue_json 30 "bug,pipeline:blocked" "$DEP")]"
sw
assert_eq "0" "$(readied 30)" "AC3 a pipeline:blocked issue is not re-queued"

fresh "[$(issue_json 30 bug "$DEP"),$(issue_json 28 pipeline:dev),$(issue_json 31 bug 'Depends on: #28')]"
sw
assert_eq "1" "$(readied 30)" "AC4 the other issue is unblocked"
assert_eq "0" "$(readied 31)" "AC4 an issue with an open dependency still gets no ready label"

fresh "[$(issue_json 30 bug "$DEP")]" '[{"number":77,"headRefName":"fix/issue-30-x","baseRefName":"main","labels":[{"name":"pipeline:review"}],"isCrossRepository":false}]'
sw
assert_eq "0" "$(readied 30)" "AC6 an issue with an open pipeline PR is not re-queued"

fresh "[$(issue_json 30 bug "$DEP")]"
printf '%s' 1 > "$STUB_DIR/list-prs.rc"
sw
assert_eq "0" "$(readied 30)" "AC6 an unreadable PR list unblocks nothing"

fresh "[$(issue_json 100 pipeline:epic-decomposed)]"
sw
assert_eq "0" "$(grep -c '^vcs check-epic-acceptance' "$STUB_DIR/journal" 2>/dev/null)" "AC7 epic auto-close stays behind roles.planner"

finish
