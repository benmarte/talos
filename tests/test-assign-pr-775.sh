#!/usr/bin/env bash
# test-assign-pr-775.sh -- Talos assigns the account user to every PR/MR it
# opens or resumes (#775): the `assign-pr <n>` verb on github, github-api,
# gitlab and azure, `create-pr` calling it, and the fix-round developer
# dispatch calling it. AC ids are the spec's.
#
# The stubs keep one assignee file per item (STUB_ASSIGNEE_DIR/<n>), so each
# assertion is on the assignees AFTER the verb ran, never on an exit code alone.
# The fix-round dispatch (AC12) runs in the `talos.sh run` fixture of
# tests/talos-run-sections.sh, which also sets up the sandbox this file uses.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=775 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUB_ASSIGNEE_DIR="$SANDBOX/assignees"
export STUB_CURRENT_USER=operator1
export GITHUB_TOKEN="test-token-775"
mkdir -p "$STUB_ASSIGNEE_DIR"
printf 'PR body\n' > "$SANDBOX/pr.body"
PR_LINE='PR #9 https://github.com/acme/widget/pull/9'
PR_JSON='{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}'
MR_URL='https://gitlab.com/acme/widget/-/merge_requests/7'

# cfg <gh|curl|gitlab|azure> [<issues.assignee JSON value> [<identity.name>]]
cfg() {
  local _extra=',"base_branch": "main"'
  [ -z "${2+x}" ] || _extra="$_extra"',"issues": {"assignee": "'"$2"'"}'
  [ -z "${3:-}" ] || _extra="$_extra"',"identity": {"name": "'"$3"'"}'
  case "$1" in
    gh | curl) github_leg "$1" "$_extra" ;;
    *) printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}%s}\n' "$1" "$_extra" > "$SANDBOX/talos.pipeline.json" ;;
  esac
}
run() {  # <verb args...> : sets out / err / rc, with fresh call logs
  : > "$GH_LOG"; : > "$CURL_LOG"
  out="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}
state() { LC_ALL=C sort "$STUB_ASSIGNEE_DIR/$1" 2>/dev/null | paste -sd, -; }
setstate() {  # <n> <login>...
  local n="$1"; shift
  : > "$STUB_ASSIGNEE_DIR/$n"
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >> "$STUB_ASSIGNEE_DIR/$n"; shift; done
}
queue_pr() { printf '%s\n' "$PR_JSON" > "$CURL_QUEUE"; }
# Every assignee-related call a github leg made: the identity read, an item
# read, an assignees write. glab and az log argv to GH_LOG.
gh_assignee_calls() { grep -cE '/assignees|/issues/[0-9]+	|/user	' "$CURL_LOG"; }
gl_assignee_calls() { grep -cE 'GLAB (mr update|mr view|api user)' "$GH_LOG"; }
# The az calls other than the adapter's own extension probe.
az_calls() { grep -v '\[extension\]' "$GH_LOG"; }

# ── AC1 / AC2: create-pr leaves the user as the PR's assignee ────────────────
for L in gh curl; do
  cfg "$L"
  setstate 9; queue_pr
  run create-pr feat/issue-775-x "A title" "$SANDBOX/pr.body"
  assert_eq "0|$PR_LINE" "$rc|$out" "$([ "$L" = gh ] && echo AC1 || echo AC2) $L: create-pr prints exactly the one PR line"
  assert_eq "operator1" "$(state 9)" "$([ "$L" = gh ] && echo AC1 || echo AC2) $L: create-pr leaves the user as the PR's assignee"
  assert_contains "$err" "assign-pr: #9 assigned to operator1" "$([ "$L" = gh ] && echo AC1 || echo AC2) $L: the assignment is reported on stderr, not stdout"
done

# ── AC3: gitlab create-pr assigns the MR with the "+" form ───────────────────
cfg gitlab
setstate 7
run create-pr feat/issue-775-x "A title" "$SANDBOX/pr.body"
assert_eq "0|$MR_URL" "$rc|$out" "AC3 gitlab: create-pr keeps glab's own stdout"
assert_contains "$(cat "$GH_LOG")" "GLAB mr update 7 --assignee +operator1" "AC3 gitlab: the MR is assigned through the + add form"
assert_eq "operator1" "$(state 7)" "AC3 gitlab: the user is the MR's assignee"

# ── AC4 / AC5: another assignee stays, the user is added next to it ──────────
for L in gh curl; do
  cfg "$L"
  setstate 9 bob
  run assign-pr 9
  assert_eq "0|bob,operator1" "$rc|$(state 9)" "AC4 $L: assign-pr on a PR assigned to bob ends with bob and the user"
  assert_contains "$out" "assign-pr: #9 assigned to operator1" "AC4 $L: assign-pr reports the verified assignment"
done
cfg gitlab
setstate 7 bob
run assign-pr 7
assert_eq "0|bob,operator1" "$rc|$(state 7)" "AC5 gitlab: assign-pr on an MR assigned to bob ends with both assigned"

# ── AC6: the user already being an assignee makes no write ───────────────────
for L in gh curl; do
  cfg "$L"
  setstate 9 Operator1 bob
  run assign-pr 9
  assert_eq "0|Operator1,bob" "$rc|$(state 9)" "AC6 $L: an assignee match ignores case and leaves the assignees alone"
  assert_eq "0" "$(grep -c '/assignees' "$CURL_LOG")" "AC6 $L: no assignees write call"
done
cfg gitlab
setstate 7 operator1
run assign-pr 7
assert_eq "operator1" "$(state 7)" "AC6 gitlab: the assignees are unchanged"
assert_not_contains "$(cat "$GH_LOG")" "mr update" "AC6 gitlab: no mr update call"

# ── AC7: azure answers a no-op and writes nothing ────────────────────────────
cfg azure
run assign-pr 5
assert_eq "0" "$rc" "AC7 azure: assign-pr exits 0"
assert_contains "$out" "azure pull requests have no assignee" "AC7 azure: assign-pr says it is a no-op"
assert_eq "" "$(az_calls)" "AC7 azure: no az call beyond the extension probe (no --assigned-to, no work-item update)"

# ── AC8: issues.assignee none or empty makes no assignee call ────────────────
for V in none ""; do
  for L in gh curl gitlab azure; do
    cfg "$L" "$V"
    setstate 9; setstate 7
    run assign-pr 9
    assert_eq "0|" "$rc|$out" "AC8 [$V] $L: assign-pr is a silent no-op on stdout"
    case "$L" in
      gh | curl) assert_eq "0" "$(gh_assignee_calls)" "AC8 [$V] $L: assign-pr makes no assignee call" ;;
      gitlab) assert_eq "0" "$(gl_assignee_calls)" "AC8 [$V] $L: assign-pr makes no assignee call" ;;
      azure) assert_eq "" "$(az_calls)" "AC8 [$V] $L: assign-pr makes no az call" ;;
    esac
    [ -n "$V" ] || assert_contains "$err" "issues.assignee is empty" "AC8 [empty] $L: a stderr notice says assignment is off"

    queue_pr
    run create-pr feat/issue-775-x "A title" "$SANDBOX/pr.body"
    assert_eq "0" "$rc" "AC8 [$V] $L: create-pr still exits 0"
    case "$L" in
      gh | curl) assert_eq "0" "$(gh_assignee_calls)" "AC8 [$V] $L: create-pr makes no assignee call"; assert_eq "$PR_LINE" "$out" "AC8 [$V] $L: create-pr prints its PR line" ;;
      gitlab) assert_eq "0" "$(gl_assignee_calls)" "AC8 [$V] $L: create-pr makes no assignee call" ;;
      azure) assert_not_contains "$(cat "$GH_LOG")" "assigned-to" "AC8 [$V] $L: create-pr makes no assignee call" ;;
    esac
    assert_eq "" "$(state 9)$(state 7)" "AC8 [$V] $L: nothing was assigned"
  done
done

# ── AC9: a named login is assigned instead of the authenticated user ─────────
for L in gh curl; do
  cfg "$L" carol
  setstate 9
  run assign-pr 9
  assert_eq "carol" "$(state 9)" "AC9 $L: issues.assignee carol assigns carol, not the authenticated user"
done
cfg gitlab carol
setstate 7
run assign-pr 7
assert_eq "carol" "$(state 7)" "AC9 gitlab: issues.assignee carol assigns carol, not the authenticated user"

# ── AC10: a failed assignment warns and never stops the run ──────────────────
for L in gh curl gitlab; do
  case "$L" in gitlab) N=7; WANT="$MR_URL" ;; *) N=9; WANT="$PR_LINE" ;; esac
  for F in STUB_ASSIGN_FAIL STUB_ASSIGN_DROP; do
    cfg "$L"
    setstate "$N" bob; queue_pr
    export "$F=1"
    run assign-pr "$N"
    assert_eq "0|" "$rc|$out" "AC10 $L $F: assign-pr exits 0 with nothing on stdout"
    assert_contains "$err" "WARNING" "AC10 $L $F: assign-pr warns on stderr"
    assert_eq "bob" "$(state "$N")" "AC10 $L $F: the other assignee is untouched"
    setstate "$N" bob; queue_pr
    run create-pr feat/issue-775-x "A title" "$SANDBOX/pr.body"
    assert_eq "0|$WANT" "$rc|$out" "AC10 $L $F: create-pr still prints its PR line and exits 0"
    assert_contains "$err" "WARNING" "AC10 $L $F: create-pr warns on stderr"
    unset "$F"
  done
done

# ── AC11: a non-numeric PR number warns without a provider call ──────────────
for L in gh gitlab; do
  cfg "$L"
  run assign-pr seven
  assert_eq "0" "$rc" "AC11 $L: a non-numeric PR number exits 0"
  assert_contains "$err" "WARNING" "AC11 $L: a non-numeric PR number warns"
  assert_eq "" "$(cat "$GH_LOG")$(cat "$CURL_LOG")" "AC11 $L: no provider call"
done

# ── AC13: the verb is an arm of every adapter, and the parity suites know it ─
arms() { sed -n "/^$1() {/,/^}/p" "$VCS" | grep -cE '^    assign-pr\)'; }
for A in _github _gitlab _azure; do
  assert_eq "1" "$(arms "$A")" "AC13 $A has an assign-pr case arm"
done
assert_contains "$(sed -n '/^_file() {/,/^}/p' "$VCS" | grep -E '^    assign-pr\)')" "PARITY-EXCEPTION:" \
  "AC13 _file has an assign-pr arm marked PARITY-EXCEPTION"
assert_contains "$(cat "$TALOS_ROOT/tests/test-verb-parity.sh")" "assign-issue assign-pr check-approval-sha" "AC13 EXPECTED_VERBS lists assign-pr"
assert_contains "$(cat "$TALOS_ROOT/tests/test-vcs-provider-parity.sh")" "file assign-pr PARITY-EXCEPTION: local-only by design" "AC13 the parity table records the file exception"
bash "$TALOS_ROOT/tests/test-verb-parity.sh" > "$SANDBOX/verb-parity.out" 2>&1; rc=$?
assert_eq "0" "$rc" "AC13 tests/test-verb-parity.sh passes"
bash "$TALOS_ROOT/tests/test-vcs-provider-parity.sh" > "$SANDBOX/provider-parity.out" 2>&1; rc=$?
assert_eq "0" "$rc" "AC13 tests/test-vcs-provider-parity.sh passes with no stale line"

# ── AC14: create-issue still assigns the new issue ───────────────────────────
for L in gh curl; do
  cfg "$L"
  printf 'issue body\n' > "$SANDBOX/issue.body"
  setstate 42
  printf '%s\n' '{"number":42,"html_url":"https://github.com/acme/widget/issues/42"}' > "$CURL_QUEUE"
  run create-issue "A sub-issue" "$SANDBOX/issue.body"
  assert_eq "operator1" "$(state 42)" "AC14 $L: create-issue assigns the new issue to the user"
done
cfg gitlab
setstate 42
run create-issue "A sub-issue" "$SANDBOX/issue.body"
assert_eq "operator1" "$(state 42)" "AC14 gitlab: create-issue assigns the new issue to the user"
cfg azure
export STUB_CURRENT_USER=operator1@example.com
setstate 1
run create-issue "A sub-issue" "$SANDBOX/issue.body"
assert_eq "operator1@example.com" "$(state 1)" "AC14 azure: create-issue assigns the new work item to the user"
export STUB_CURRENT_USER=operator1

finish
