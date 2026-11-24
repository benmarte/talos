#!/usr/bin/env bash
# test-check-table-fd3-isolation.sh -- #1065: _gh_check_table_py reads the sha's
# workflow runs from fd 3 (#1054), so every call site gives it an explicit fd 3
# and none inherits the caller's. A caller's fd 3 open to a pipe that never
# closes must not hang pr-checks-required / ref-checks-required, and one open to
# a file of non-JSON text must not change their verdict. Gh stub; no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA="1111111111111111111111111111111111111111"
ERR="$SANDBOX/err.txt"
NAME="test (ubuntu-latest)"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "merge": {"required_checks": ["%s"]}}\n' "$NAME" > talos.pipeline.json
export STUB_GH_COMMIT_SHA="$SHA" STUB_PR_HEAD_SHA="$SHA"

# _wf <id> <check_suite_id> <workflow_id> <status> <conclusion|null>: one workflow run.
_wf() {
  local c="\"$5\""; [ "$5" = null ] && c=null
  printf '{"id":%s,"check_suite_id":%s,"workflow_id":%s,"head_sha":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3" "$SHA" "$4" "$c"
}
# _runs <wf run>...: one page of workflow runs.
_runs() {
  local body="" sep="" r total=$#
  for r in "$@"; do body="$body$sep$r"; sep=","; done
  printf '{"total_count":%s,"workflow_runs":[%s]}' "$total" "$body"
}
# _check <state> <check_suite_id>: the stub's check row (name state elapsed url suite).
_check() { printf '%s\t%s\t1m\thttps://ci/run\t%s' "$NAME" "$1" "$2"; }

# _verb <pr|ref> <fd3 source>: run the verb with fd 3 open to <fd3 source> (a
# path, or "none" for a closed fd 3). Sets RC and ERRS; bounded by timeout.
_verb() {
  local leg="$1" src="$2"
  if [ "$leg" = pr ]; then
    if [ "$src" = none ]; then timeout 10 bash "$VCS" pr-checks-required 42 >/dev/null 2>"$ERR"
    else timeout 10 bash "$VCS" pr-checks-required 42 >/dev/null 2>"$ERR" 3<>"$src"; fi
  else
    if [ "$src" = none ]; then timeout 10 bash "$VCS" ref-checks-required "$SHA" >/dev/null 2>"$ERR"
    else timeout 10 bash "$VCS" ref-checks-required "$SHA" >/dev/null 2>"$ERR" 3<>"$src"; fi
  fi
  RC=$?
  ERRS="$(cat "$ERR")"
}

# A fifo opened read-write never reaches EOF: reading it blocks.
FIFO="$SANDBOX/never-closes.fifo"
mkfifo "$FIFO"
JUNK="$SANDBOX/junk.txt"
printf 'this is not json at all\n' > "$JUNK"

CANCELLED="$(_wf 101 11 7 completed cancelled)"
NEWER_LIVE="$(_wf 102 12 7 in_progress null)"

for leg in pr ref; do
  # Baselines with fd 3 closed: pending with a newer live run, failed without,
  # and a pass for a green check.
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_LIVE")" _verb "$leg" none
  BASE_PENDING="$RC"
  assert_eq "2" "$BASE_PENDING" "AC4 $leg: a cancelled check with a newer run in progress is pending (exit 2)"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" none
  BASE_FAIL="$RC"
  STUB_PR_CHECKS="$(_check pass 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" none
  BASE_PASS="$RC"

  # AC1: fd 3 open to a pipe that never closes: same verdicts, within the bound.
  STUB_PR_CHECKS="$(_check pass 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" "$FIFO"
  assert_eq "$BASE_PASS" "$RC" "AC1 $leg: a never-closing fd 3 does not hang or change a pass"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_LIVE")" _verb "$leg" "$FIFO"
  assert_eq "$BASE_PENDING" "$RC" "AC1 $leg: a never-closing fd 3 does not hang or change a pending verdict"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" "$FIFO"
  assert_eq "$BASE_FAIL" "$RC" "AC1 $leg: a never-closing fd 3 does not hang or change a failed verdict"

  # AC2: fd 3 open to non-JSON text: same verdicts as with fd 3 closed.
  STUB_PR_CHECKS="$(_check pass 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" "$JUNK"
  assert_eq "$BASE_PASS" "$RC" "AC2 $leg: a non-JSON fd 3 does not change a pass"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED" "$NEWER_LIVE")" _verb "$leg" "$JUNK"
  assert_eq "$BASE_PENDING" "$RC" "AC2 $leg: a non-JSON fd 3 does not change a pending verdict"
  STUB_PR_CHECKS="$(_check cancel 11)" STUB_GH_RUNS_RAW="$(_runs "$CANCELLED")" _verb "$leg" "$JUNK"
  assert_eq "$BASE_FAIL" "$RC" "AC2 $leg: a non-JSON fd 3 does not change a failed verdict"
done

# AC3: every call of _gh_check_table_py (not its definition or comments) carries
# an explicit fd 3 redirect.
CALLS="$(grep '_gh_check_table_py' "$VCS" | grep -v '^[[:space:]]*#' | grep -v '_gh_check_table_py()' || true)"
assert_eq "3" "$(printf '%s\n' "$CALLS" | grep -c .)" "AC3 the script calls _gh_check_table_py from three places"
BARE="$(printf '%s\n' "$CALLS" | grep -v '_gh_check_table_py[[:space:]][[:space:]]*3<' || true)"
assert_eq "" "$BARE" "AC3 every _gh_check_table_py call has an explicit fd 3 redirect"

finish
