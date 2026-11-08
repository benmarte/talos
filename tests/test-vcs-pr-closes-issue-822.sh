#!/usr/bin/env bash
# test-vcs-pr-closes-issue-822.sh -- the `pr-closes-issue <pr> <issue>` verb (#822):
# prints `closes` or `part-of` for a PR body and exits 0; exits 2 with nothing on
# stdout when the PR cannot be read (fail closed, like pr-is-draft).
# Uses the gh/glab/az stubs; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}' > talos.pipeline.json

# check_gh <label> <body> <expected> [issue]: the github answer for a PR with <body>.
check_gh() {
  local out rc
  out="$(STUB_PR_BODY="$2" bash "$VCS" pr-closes-issue 9 "${4:-42}" 2>/dev/null)"; rc=$?
  assert_eq "$3" "$out" "$1: prints $3"
  assert_eq "0" "$rc" "$1: exits 0"
}

# ── AC8 github ───────────────────────────────────────────────────────────────
check_gh "AC8 Closes #N" "Closes #42" closes
check_gh "AC8 fixes #N" "This fixes #42 for good" closes
check_gh "AC8 resolved #N" "resolved #42" closes
check_gh "AC8 owner/repo#N" "Fixes acme/widget#42" closes
check_gh "AC8 GH-N" "closes GH-42" closes
check_gh "AC8 issue URL" "Closes https://github.com/acme/widget/issues/42" closes
check_gh "AC8 Part of #N" "Part of #42" part-of
check_gh "AC8 closing keyword aimed at another issue" "Closes #43" part-of
check_gh "AC8 an empty body" "" part-of
check_gh "AC8 #N is not a prefix match" "Closes #421" part-of

out="$(STUB_GH_API_FAIL=pr bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC8 an unfetchable PR exits 2"
assert_eq "" "$out" "AC8 an unfetchable PR prints nothing"
out="$(STUB_GH_PR_RAW='not json at all' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC8 an unparseable PR response exits 2"
assert_eq "" "$out" "AC8 an unparseable PR response prints nothing"
out="$(bash "$VCS" pr-closes-issue abc 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC8 a non-numeric PR id exits 2"
assert_eq "" "$out" "AC8 a non-numeric PR id prints nothing"

# ── AC10 check-closing-keyword keeps its exit codes and markers ──────────────
_sib='[{"number":9,"state":"OPEN","title":"a","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":11,"state":"OPEN","title":"b","headRefName":"fix/issue-42-b","body":"Part of #42"}]'
out="$(STUB_PR_BODY="Closes #42" STUB_PR_LIST="$_sib" bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC10 github: a closing keyword with an open sibling still exits 1"
assert_contains "$out" "open sibling PR(s) still reference the same issue: #11" "AC10 github: and names the sibling"
out="$(STUB_PR_BODY="Part of #42" STUB_PR_LIST="$_sib" bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC10 github: no closing keyword still exits 0"
out="$(STUB_GH_API_FAIL=pr bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC10 github: an unreadable PR still fails open"
assert_contains "$out" "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed" "AC10 github: with its marker"

# ── AC9 gitlab ───────────────────────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
printf '%s\n' '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}' > talos.pipeline.json
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes #42"}' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "closes" "$out" "AC9 gitlab: Closes #N prints closes"
assert_eq "0" "$rc" "AC9 gitlab: closes exits 0"
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes #1, #42 and #3"}' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"
assert_eq "closes" "$out" "AC9 gitlab: a closing list that names the issue prints closes"
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Part of #42"}' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "part-of" "$out" "AC9 gitlab: Part of #N prints part-of"
assert_eq "0" "$rc" "AC9 gitlab: part-of exits 0"
out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes #43"}' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"
assert_eq "part-of" "$out" "AC9 gitlab: a keyword for another issue prints part-of"
out="$(STUB_GITLAB_MR_VIEW_FAIL=1 bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC9 gitlab: an unfetchable MR exits 2"
assert_eq "" "$out" "AC9 gitlab: an unfetchable MR prints nothing"

out="$(STUB_GITLAB_MR_VIEW_FAIL=1 bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC10 gitlab: an unreadable MR still fails open"
assert_contains "$out" "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed" "AC10 gitlab: with its marker"

# ── AC9 azure ────────────────────────────────────────────────────────────────
printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}' > talos.pipeline.json
out="$(STUB_AZURE_PR_WORKITEMS='[{"id":"42"},{"id":"7"}]' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "closes" "$out" "AC9 azure: a PR linked to the work item prints closes"
assert_eq "0" "$rc" "AC9 azure: closes exits 0"
out="$(STUB_AZURE_PR_WORKITEMS='[{"id":"7"}]' bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "part-of" "$out" "AC9 azure: a PR not linked to the work item prints part-of"
assert_eq "0" "$rc" "AC9 azure: part-of exits 0"
out="$(STUB_AZURE_PR_WORKITEMS_FAIL=1 bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC9 azure: an unreadable link list exits 2"
assert_eq "" "$out" "AC9 azure: an unreadable link list prints nothing"

out="$(STUB_AZURE_PR_WORKITEMS_FAIL=1 bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC10 azure: an unreadable link list still fails open"
assert_contains "$out" "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed" "AC10 azure: with its marker"

# ── AC9 file ─────────────────────────────────────────────────────────────────
printf '%s\n' '{"vcs": {"provider": "file"}}' > talos.pipeline.json
out="$(bash "$VCS" pr-closes-issue 9 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC9 file: exits 2"
assert_eq "" "$out" "AC9 file: prints nothing"

finish
