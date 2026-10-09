#!/usr/bin/env bash
# test-assignee-verbs.sh -- the assignee verbs multi-user claiming stands on
# (#560): `issue-assignees <n>`, `unassign-issue <n> <login>` and
# `list-assignees`, on github, github-api, gitlab and azure, plus the
# `identity.name` override of `assign-issue`'s `self`.
#
# The stubs keep one assignee file per issue (STUB_ASSIGNEE_DIR/<n>), so each
# assertion is on the field's VALUE after the verb ran, never on an exit code
# alone. GitHub and GitLab hold several assignees; Azure DevOps holds one.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUB_ASSIGNEE_DIR="$SANDBOX/assignees"
export GITHUB_TOKEN="test-token-560"
mkdir -p "$STUB_ASSIGNEE_DIR"

cfg_p() {  # <provider> [extra top-level JSON members]
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}%s}\n' "$1" "${2:+, $2}" > talos.pipeline.json
}
run() {  # <verb args...> : sets out / err / rc
  : > "$GH_LOG"; : > "$CURL_LOG"
  out="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}
state() { sort "$STUB_ASSIGNEE_DIR/$1" 2>/dev/null | paste -sd, -; }
setstate() {  # <n> <login>...
  local n="$1"; shift
  : > "$STUB_ASSIGNEE_DIR/$n"
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >> "$STUB_ASSIGNEE_DIR/$n"; shift; done
}
canon() { printf '%s' "$1" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null || printf 'not-json'; }

for P in github github-api gitlab azure; do
  cfg_p "$P"
  case "$P" in
    azure) A=alice@example.com; B=bob@example.com ;;
    *)     A=alice; B=bob ;;
  esac

  # ── issue-assignees ────────────────────────────────────────────────────────
  setstate 7
  run issue-assignees 7
  assert_eq "0|" "$rc|$out" "#560 $P: issue-assignees on an unassigned issue prints nothing, exit 0"
  setstate 7 "$A"
  run issue-assignees 7
  assert_eq "0|$A" "$rc|$out" "#560 $P: issue-assignees prints the assignee's login"
  if [ "$P" != azure ]; then
    setstate 7 "$B" "$A"
    run issue-assignees 7
    assert_eq "0|$A,$B" "$rc|$(printf '%s\n' "$out" | sort | paste -sd, -)" "#560 $P: issue-assignees prints every assignee, one per line"
  fi
  run issue-assignees seven
  assert_eq "1" "$rc" "#560 $P: issue-assignees refuses a non-numeric issue"
  assert_contains "$err" "integer" "#560 $P: issue-assignees says why"

  # ── unassign-issue ─────────────────────────────────────────────────────────
  if [ "$P" = azure ]; then
    setstate 7 "$A"
    run unassign-issue 7 "$A"
    assert_eq "0|" "$rc|$(state 7)" "#560 $P: unassign-issue clears the work item's assignee"
  else
    setstate 7 "$A" "$B"
    run unassign-issue 7 "$B"
    assert_eq "0|$A" "$rc|$(state 7)" "#560 $P: unassign-issue removes only the named login"
  fi
  assert_contains "$out" "unassign-issue: #7 unassigned" "#560 $P: unassign-issue reports the verified removal"

  setstate 7 "$A"
  run unassign-issue 7 "$B"
  assert_eq "0|$A" "$rc|$(state 7)" "#560 $P: unassign-issue of a login that is not assigned changes nothing"
  assert_contains "$out" "not assigned" "#560 $P: unassign-issue says the login was not assigned"
  case "$P" in
    github) assert_not_contains "$(cat "$GH_LOG")" "--remove-assignee" "#560 $P: no write when the login is not assigned" ;;
    github-api) assert_not_contains "$(cat "$CURL_LOG")" "DELETE" "#560 $P: no write when the login is not assigned" ;;
  esac

  run unassign-issue 7
  assert_eq "1" "$rc" "#560 $P: unassign-issue needs a login"
  run unassign-issue seven "$A"
  assert_eq "1" "$rc" "#560 $P: unassign-issue refuses a non-numeric issue"
done

# A removal the provider rejects is a failed verb, never a silent success.
cfg_p github
setstate 7 alice bob
STUB_UNASSIGN_FAIL=1 run unassign-issue 7 bob
assert_eq "1|alice,bob" "$rc|$(state 7)" "#560 github: a rejected removal exits 1 and leaves the assignees"
assert_contains "$err" "WARNING" "#560 github: a rejected removal warns on stderr"
assert_not_contains "$out" "unassigned" "#560 github: a rejected removal is not reported as success"

# ── list-assignees: one request, {issue: [logins]}, pull requests left out ───
cfg_p github
export STUB_GH_ISSUES_RAW='[{"number":7,"assignees":[{"login":"bob"}]},{"number":8,"assignees":[]},{"number":9,"assignees":[{"login":"alice"},{"login":"carol"}]},{"number":10,"pull_request":{},"assignees":[{"login":"zed"}]}]'
run list-assignees
assert_eq '0|{"7": ["bob"], "9": ["alice", "carol"]}' "$rc|$(canon "$out")" "#560 github: list-assignees maps assigned issues to their logins, skipping unassigned issues and PRs"
assert_eq "1" "$(grep -c 'api --paginate' "$GH_LOG")" "#560 github: list-assignees is one paginated request"
unset STUB_GH_ISSUES_RAW

cfg_p github-api
printf '%s\n' '[{"number":7,"assignees":[{"login":"bob"}]},{"number":8,"assignees":[]},{"number":10,"pull_request":{},"assignees":[{"login":"zed"}]}]' > "$CURL_QUEUE"
run list-assignees
assert_eq '0|{"7": ["bob"]}' "$rc|$(canon "$out")" "#560 github-api: list-assignees maps assigned issues to their logins"

cfg_p gitlab
export STUB_GITLAB_ISSUE_LIST='[{"iid":7,"assignees":[{"username":"bob"}]},{"iid":8,"assignees":[]},{"iid":9,"assignees":[{"username":"alice"},{"username":"carol"}]}]'
run list-assignees
assert_eq '0|{"7": ["bob"], "9": ["alice", "carol"]}' "$rc|$(canon "$out")" "#560 gitlab: list-assignees maps assigned issues to their logins"
unset STUB_GITLAB_ISSUE_LIST

cfg_p azure
export STUB_AZURE_WORKITEM_LIST='[{"id":7,"fields":{"System.AssignedTo":{"uniqueName":"bob@example.com","displayName":"Bob B"}}},{"id":8,"fields":{"System.Title":"x"}}]'
run list-assignees
assert_eq '0|{"7": ["bob@example.com"]}' "$rc|$(canon "$out")" "#560 azure: list-assignees maps assigned work items to their unique names"
unset STUB_AZURE_WORKITEM_LIST

# A failed read is a failed verb (collect must fail closed on it).
cfg_p github
STUB_GH_API_FAIL=issues run list-assignees
assert_eq "1|" "$rc|$out" "#560 github: a failed list-assignees read exits 1 with no output"

# ── identity.name overrides what `self` resolves to (assign-issue) ───────────
for P in github github-api gitlab azure; do
  export STUB_CURRENT_USER=operator1
  cfg_p "$P"; setstate 7
  run assign-issue 7
  assert_eq "operator1" "$(state 7)" "#560 $P: assign-issue self is the authenticated login by default"
  cfg_p "$P" '"identity": {"name": "carol"}'; setstate 7
  run assign-issue 7
  assert_eq "carol" "$(state 7)" "#560 $P: identity.name replaces the login that self resolves to"
  cfg_p "$P" '"identity": {"name": "carol"}, "issues": {"assignee": "dave"}'; setstate 7
  run assign-issue 7
  assert_eq "dave" "$(state 7)" "#560 $P: an explicit issues.assignee still wins over identity.name"
done
unset STUB_CURRENT_USER

finish
