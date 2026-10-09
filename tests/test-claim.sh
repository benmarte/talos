#!/usr/bin/env bash
# test-claim.sh -- `talos.sh claim <n>` (#560): the VCS assignee is the shared
# lock between operators. Two operators A and B run Talos on one repo (the
# stubs' STUB_CURRENT_USER is the operator; STUB_ASSIGNEE_DIR is the repo's one
# set of assignees), on github, gitlab and azure.
#
#   claim=taken owner=<me>       the issue was unassigned, now it is ours
#   claim=owned owner=<me>       it was already ours (or ours and lowest)
#   claim=lost owner=<login>     another operator keeps it; if we were assigned
#                                too, we have unassigned ourselves
#   claim=unclaimed reason=not-assignable   the assignment did not land and
#                                nobody else holds it: the work goes on
#   claim=off reason=<disabled|assignee-none|identity-unresolved>   no claiming
#
# A simultaneous claim is STUB_ASSIGNEE_RACER: the other operator's write
# lands at the same moment as ours, so both are on the issue at the read-back.
# GitHub and GitLab hold several assignees (the lexicographically lowest login
# keeps the issue); Azure DevOps holds one (the last write wins). Either way
# exactly one operator ends up owning the issue.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export STUB_ASSIGNEE_DIR="$SANDBOX/assignees"
export GITHUB_TOKEN="test-token-560"
mkdir -p "$STUB_ASSIGNEE_DIR"

cfg_p() {  # <provider> [extra top-level JSON members]
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}%s}\n' "$1" "${2:+, $2}" > talos.pipeline.json
}
claim() {  # <operator> <n> : sets out / err / rc ; operator "" = no identity
  : > "$GH_LOG"
  out="$(STUB_CURRENT_USER="$1" bash "$TALOS" claim "$2" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}
state() { sort "$STUB_ASSIGNEE_DIR/$1" 2>/dev/null | paste -sd, -; }
setstate() {  # <n> <login>...
  local n="$1"; shift
  : > "$STUB_ASSIGNEE_DIR/$n"
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >> "$STUB_ASSIGNEE_DIR/$n"; shift; done
}
writes() { grep -c -e '--add-assignee' -e '--remove-assignee' -e '--assignee' -e 'assigned-to' -e '/assignees' "$GH_LOG"; }

for P in github gitlab azure; do
  cfg_p "$P"
  case "$P" in
    azure) A=alice@example.com; B=bob@example.com; Z=zed@example.com; M=amy@example.com ;;
    *)     A=alice; B=bob; Z=zed; M=amy ;;
  esac
  rm -f "$STUB_ASSIGNEE_DIR"/*

  # Two operators, two ready issues: each claims a different one.
  claim "$A" 7
  assert_eq "0|claim=taken owner=$A" "$rc|$out" "#560 $P: A claims the unassigned issue #7"
  assert_eq "$A" "$(state 7)" "#560 $P: #7 is assigned to A"
  claim "$B" 8
  assert_eq "0|claim=taken owner=$B" "$rc|$out" "#560 $P: B claims the unassigned issue #8"
  assert_eq "$B" "$(state 8)" "#560 $P: #8 is assigned to B"

  # A claim of what is already ours is a read, never a write.
  claim "$A" 7
  assert_eq "0|claim=owned owner=$A" "$rc|$out" "#560 $P: A's second claim of #7 is owned"
  assert_eq "0" "$(writes)" "#560 $P: an owned claim writes nothing"

  # B never takes A's issue and never touches it.
  claim "$B" 7
  assert_eq "0|claim=lost owner=$A" "$rc|$out" "#560 $P: B's claim of A's #7 is lost to A"
  assert_eq "$A" "$(state 7)" "#560 $P: #7 stays A's"
  assert_eq "0" "$(writes)" "#560 $P: a lost claim on someone else's issue writes nothing"

  # A simultaneous claim of the same issue: both writes land. alice < bob.
  setstate 9
  STUB_ASSIGNEE_RACER="$B" claim "$A" 9
  case "$P" in
    azure)  # one assignee: B's write replaced A's, so A sees B
      assert_eq "0|claim=lost owner=$B" "$rc|$out" "#560 $P: A's simultaneous claim of #9 loses to the write that replaced it"
      assert_eq "$B" "$(state 9)" "#560 $P: #9 is B's alone" ;;
    *)      # several assignees: the lowest login (A) keeps it
      assert_eq "0|claim=taken owner=$A" "$rc|$out" "#560 $P: A (lowest) keeps #9 after the simultaneous claim"
      claim "$B" 9
      assert_eq "0|claim=lost owner=$A" "$rc|$out" "#560 $P: B unassigns itself from #9 and moves on"
      assert_eq "$A" "$(state 9)" "#560 $P: exactly one owner of #9, the lowest login" ;;
  esac

  # The same race with the other order: the lowest login is the racer's.
  setstate 10
  STUB_ASSIGNEE_RACER="$M" claim "$Z" 10
  assert_eq "0|claim=lost owner=$M" "$rc|$out" "#560 $P: Z loses #10 to the lower login that claimed at the same moment"
  assert_eq "$M" "$(state 10)" "#560 $P: Z unassigned itself, exactly one owner of #10"

  # The lowest-login rule is case-insensitive; our own login too.
  setstate 11 "$(printf '%s' "$A" | tr '[:lower:]' '[:upper:]')"
  claim "$A" 11
  assert_eq "0|claim=owned owner=$(printf '%s' "$A" | tr '[:lower:]' '[:upper:]')" "$rc|$out" "#560 $P: logins compare case-insensitively"

  # Assignment that does not land and nobody else holds the issue: go on.
  setstate 12
  STUB_ASSIGN_DROP=1 claim "$A" 12
  assert_eq "0|claim=unclaimed reason=not-assignable" "$rc|$out" "#560 $P: an assignment that does not land is reported, not fatal"
  assert_eq "" "$(state 12)" "#560 $P: nothing was assigned"
done

# Co-assignees: a human added to an issue we hold does not take it from us.
cfg_p github; setstate 13 alice
claim alice 13
assert_eq "0|claim=owned owner=alice" "$rc|$out" "#560 github: owning an issue we already hold needs no tie-break"

# ── identity ────────────────────────────────────────────────────────────────
cfg_p github '"identity": {"name": "carol"}'; setstate 14
claim alice 14
assert_eq "0|claim=taken owner=carol" "$rc|$out" "#560 identity.name is the login the operator claims under"
assert_eq "carol" "$(state 14)" "#560 identity.name is what gets assigned"

cfg_p github '"issues": {"assignee": "dave"}'; setstate 15
claim alice 15
assert_eq "0|claim=taken owner=dave" "$rc|$out" "#560 an explicit issues.assignee is the operator's identity"

cfg_p github; setstate 16
claim "" 16
assert_eq "0|claim=off reason=identity-unresolved" "$rc|$out" "#560 no resolvable identity: claiming is off, not an error"
assert_eq "" "$(state 16)" "#560 no resolvable identity: nothing assigned"

# ── off switches ────────────────────────────────────────────────────────────
cfg_p github '"issues": {"claim": false}'; setstate 17
claim alice 17
assert_eq "0|claim=off reason=disabled" "$rc|$out" "#560 issues.claim: false turns claiming off"
assert_eq "" "$(state 17)" "#560 issues.claim: false assigns nothing"
assert_eq "0" "$(grep -c 'issue ' "$GH_LOG")" "#560 issues.claim: false makes no provider call"

cfg_p github '"issues": {"assignee": "none"}'; setstate 18
claim alice 18
assert_eq "0|claim=off reason=assignee-none" "$rc|$out" "#560 issues.assignee: none implies no claiming (a claim needs an assignment)"
assert_eq "" "$(state 18)" "#560 issues.assignee: none assigns nothing"

cfg_p github '"issues": {"assignee": ""}'; setstate 18
claim alice 18
assert_eq "0|claim=off reason=assignee-none" "$rc|$out" "#560 an empty issues.assignee also means no claiming"

cfg_p github '"issues": {"claim": false, "assignee": "self"}'; setstate 19 bob
claim alice 19
assert_eq "claim=off reason=disabled" "$out" "#560 with claiming off another operator's issue is left to the old behaviour"

# ── fail closed ─────────────────────────────────────────────────────────────
cfg_p github '"identity": {"name": "alice"}'; setstate 20
GH_FAIL_STDERR="HTTP 502" claim alice 20
assert_eq "1|stop reason=claim-unreadable" "$rc|$out" "#560 an unreadable assignee list stops the claim, never reads as unassigned"

cfg_p github; setstate 21 alice bob
STUB_UNASSIGN_FAIL=1 claim bob 21
assert_eq "1|stop reason=claim-release-failed" "$rc|$out" "#560 a tie we lose but cannot release is a stop, not a silent double owner"

claim
assert_eq "2|stop reason=usage" "$rc|$out" "#560 claim needs an issue number"
claim alice abc
assert_eq "2|stop reason=usage" "$rc|$out" "#560 claim refuses a non-numeric issue"

finish
