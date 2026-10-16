#!/usr/bin/env bash
# test-gitlab-normalised-shapes.sh -- the gitlab adapter's list-issues,
# list-prs and view-issue print the GitHub-shaped keys pipeline-next.py reads
# (number, title, state, body, labels[{name}], headRefName, baseRefName,
# isDraft, isCrossRepository) and keep the raw glab keys; view-issue honours
# --spec / --since-stage. Uses the tests/stubs/glab stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'TALOS_cfgGl735xQ'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
TALOS_cfgGl735xQ

# _field <json> <python expr over d>: print one value from a JSON document.
_field() { printf '%s' "$1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null; }

# ── AC1 list-issues ──────────────────────────────────────────────────────────
export STUB_GITLAB_ISSUE_LIST='[{"iid":5,"title":"Add login","state":"opened","description":"the body","labels":["pipeline:ready","bug"],"web_url":"https://gitlab.com/acme/widget/-/issues/5"},{"iid":6,"title":"No body","state":"opened","description":null,"labels":[]}]'
out="$(bash "$VCS" list-issues 2>/dev/null)"
assert_eq "5" "$(_field "$out" 'd[0]["number"]')" "AC1 list-issues adds number from iid"
assert_eq "Add login" "$(_field "$out" 'd[0]["title"]')" "AC1 list-issues keeps title"
assert_eq "opened" "$(_field "$out" 'd[0]["state"]')" "AC1 list-issues keeps state"
assert_eq "the body" "$(_field "$out" 'd[0]["body"]')" "AC1 list-issues adds body from description"
assert_eq "" "$(_field "$out" 'd[1]["body"]')" "AC1 list-issues gives a null description an empty body"
assert_eq "pipeline:ready,bug" "$(_field "$out" '",".join(l["name"] for l in d[0]["labels"])')" "AC1 list-issues turns string labels into [{name}]"
assert_eq "[]" "$(_field "$out" 'd[1]["labels"]')" "AC1 list-issues gives an unlabelled issue empty labels"
assert_eq "5 https://gitlab.com/acme/widget/-/issues/5" "$(_field "$out" 'str(d[0]["iid"]) + " " + d[0]["web_url"]')" "AC1 list-issues keeps the raw iid and extra keys"
export STUB_GITLAB_ISSUE_LIST='[{"iid":7,"title":"t","state":"opened","labels":[{"name":"x"}]}]'
out="$(bash "$VCS" list-issues 2>/dev/null)"
assert_eq "x" "$(_field "$out" 'd[0]["labels"][0]["name"]')" "AC1 list-issues keeps a label that is already {name}"
unset STUB_GITLAB_ISSUE_LIST

# ── AC2 list-prs ─────────────────────────────────────────────────────────────
export STUB_GITLAB_MR_LIST='[{"iid":9,"title":"fix: guard","state":"opened","draft":true,"labels":["pipeline:review"],"source_branch":"fix/issue-5-guard","target_branch":"main","source_project_id":1,"target_project_id":1},{"iid":10,"title":"other","state":"opened","source_branch":"feat/x","target_branch":"main","source_project_id":1,"target_project_id":1}]'
out="$(bash "$VCS" list-prs 2>/dev/null)"
assert_eq "9" "$(_field "$out" 'd[0]["number"]')" "AC2 list-prs adds number from iid"
assert_eq "fix: guard" "$(_field "$out" 'd[0]["title"]')" "AC2 list-prs keeps title"
assert_eq "fix/issue-5-guard" "$(_field "$out" 'd[0]["headRefName"]')" "AC2 list-prs adds headRefName from source_branch"
assert_eq "main" "$(_field "$out" 'd[0]["baseRefName"]')" "AC2 list-prs adds baseRefName from target_branch"
assert_eq "pipeline:review" "$(_field "$out" 'd[0]["labels"][0]["name"]')" "AC2 list-prs turns string labels into [{name}]"
assert_eq "True" "$(_field "$out" 'd[0]["isDraft"]')" "AC2 list-prs sets isDraft true for draft: true"
assert_eq "False" "$(_field "$out" 'd[1]["isDraft"]')" "AC2 list-prs sets isDraft false when draft is absent"
assert_eq "9 fix/issue-5-guard" "$(_field "$out" 'str(d[0]["iid"]) + " " + d[0]["source_branch"]')" "AC2 list-prs keeps the raw iid and source_branch"
export STUB_GITLAB_MR_LIST='[{"iid":11,"title":"c","state":"opened","sourceBranch":"fix/issue-6-x","targetBranch":"main"}]'
out="$(bash "$VCS" list-prs 2>/dev/null)"
assert_eq "fix/issue-6-x main" "$(_field "$out" 'd[0]["headRefName"] + " " + d[0]["baseRefName"]')" "AC2 list-prs falls back to sourceBranch / targetBranch"
unset STUB_GITLAB_MR_LIST

# ── AC3 isCrossRepository ────────────────────────────────────────────────────
export STUB_GITLAB_MR_LIST='[{"iid":1,"source_project_id":4,"target_project_id":4},{"iid":2,"source_project_id":5,"target_project_id":4},{"iid":3,"target_project_id":4},{"iid":4,"source_project_id":4},{"iid":5}]'
out="$(bash "$VCS" list-prs 2>/dev/null)"
assert_eq "False" "$(_field "$out" 'd[0]["isCrossRepository"]')" "AC3 list-prs: equal project ids are not cross-repository"
assert_eq "True" "$(_field "$out" 'd[1]["isCrossRepository"]')" "AC3 list-prs: differing project ids are cross-repository"
assert_eq "True" "$(_field "$out" 'd[2]["isCrossRepository"]')" "AC3 list-prs: a missing source_project_id fails closed"
assert_eq "True" "$(_field "$out" 'd[3]["isCrossRepository"]')" "AC3 list-prs: a missing target_project_id fails closed"
assert_eq "True" "$(_field "$out" 'd[4]["isCrossRepository"]')" "AC3 list-prs: both ids missing fails closed"
unset STUB_GITLAB_MR_LIST

# ── AC4 non-array output is an error ─────────────────────────────────────────
for _bad in 'not json at all' '{"message":"401 Unauthorized"}'; do
  export STUB_GITLAB_ISSUE_LIST="$_bad" STUB_GITLAB_MR_LIST="$_bad"
  out="$(bash "$VCS" list-issues 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "AC4 list-issues exits 1 on non-array glab output ($_bad)"
  assert_eq "" "$out" "AC4 list-issues prints nothing on non-array glab output ($_bad)"
  out="$(bash "$VCS" list-prs 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "AC4 list-prs exits 1 on non-array glab output ($_bad)"
  assert_eq "" "$out" "AC4 list-prs prints nothing on non-array glab output ($_bad)"
done
unset STUB_GITLAB_ISSUE_LIST STUB_GITLAB_MR_LIST

# ── AC5 cap warning kept ─────────────────────────────────────────────────────
_gen() { python3 -I -c "
import json, sys
n = int(sys.argv[1])
print(json.dumps([{'iid': i, 'title': 't', 'state': 'opened', 'source_branch': 'b'} for i in range(1, n + 1)]))" "$1"; }
err="$(STUB_GITLAB_ISSUE_LIST="$(_gen 100)" bash "$VCS" list-issues 2>&1 >/dev/null)"
assert_contains "$err" "WARNING result capped at 100" "AC5 list-issues warns when the result is exactly 100 items"
err="$(STUB_GITLAB_ISSUE_LIST="$(_gen 99)" bash "$VCS" list-issues 2>&1 >/dev/null)"
assert_not_contains "$err" "WARNING result capped" "AC5 list-issues does not warn under 100 items"
err="$(STUB_GITLAB_MR_LIST="$(_gen 100)" bash "$VCS" list-prs 2>&1 >/dev/null)"
assert_contains "$err" "WARNING result capped at 100" "AC5 list-prs warns when the result is exactly 100 items"
err="$(STUB_GITLAB_MR_LIST="$(_gen 99)" bash "$VCS" list-prs 2>&1 >/dev/null)"
assert_not_contains "$err" "WARNING result capped" "AC5 list-prs does not warn under 100 items"

# ── AC6 pipeline-next.py collect routes gitlab work ──────────────────────────
export STUB_GITLAB_ISSUE_LIST='[{"iid":5,"title":"Add login","state":"opened","labels":["pipeline:ready"]}]'
export STUB_GITLAB_MR_LIST='[{"iid":9,"title":"fix: guard","state":"opened","source_branch":"fix/issue-6-x","target_branch":"main","source_project_id":1,"target_project_id":1}]'
state="$(python3 -I "$TALOS_ROOT/scripts/pipeline-next.py" collect --vcs "$VCS" --roles "" --me "" \
  --merge-auto "" --required-checks "" --pr-draft "" --ready-gate "" \
  --talos-labels "pipeline:ready,pipeline:dev,pipeline:confirmed" --base-branch main </dev/null 2>&1)"
assert_eq "5" "$(_field "$state" 'd["queued"][0] if d.get("queued") else "empty"')" "AC6 collect queues the gitlab issue labelled pipeline:ready"
assert_eq "9 6" "$(_field "$state" 'str(d["prs"][0]["n"]) + " " + str(d["prs"][0]["issue"]) if d.get("prs") else "empty"')" "AC6 collect sees the open MR fix/issue-6-x into the base branch"
unset STUB_GITLAB_ISSUE_LIST STUB_GITLAB_MR_LIST

# ── AC7 view-issue ───────────────────────────────────────────────────────────
export STUB_GITLAB_ISSUE_VIEW='{"iid":42,"title":"Epic","state":"opened","description":"Body text","labels":["spec:ready","p2"],"web_url":"https://gitlab.com/acme/widget/-/issues/42"}'
# Two pages back-to-back; the second holds a system note and a later comment.
export STUB_GITLAB_ISSUE_NOTES='[{"id":1,"body":"first human","system":false,"author":{"username":"alice"},"created_at":"2026-10-01T10:00:00Z"},{"id":2,"body":"assigned to @bob","system":true,"author":{"username":"alice"},"created_at":"2026-10-01T11:00:00Z"}]
[{"id":3,"body":"**PM spec:** the spec v1","system":false,"author":{"username":"talos"},"created_at":"2026-10-02T10:00:00Z"},{"id":4,"body":"**PM spec:** the spec v2","system":false,"author":{"username":"talos"},"created_at":"2026-10-03T10:00:00Z"},{"id":5,"body":"later human","system":false,"author":{"username":"bob"},"created_at":"2026-10-04T10:00:00Z"}]'
out="$(bash "$VCS" view-issue 42 2>/dev/null)"
assert_eq "42" "$(_field "$out" 'd["number"]')" "AC7 view-issue adds number from iid"
assert_eq "Epic" "$(_field "$out" 'd["title"]')" "AC7 view-issue keeps title"
assert_eq "opened" "$(_field "$out" 'd["state"]')" "AC7 view-issue keeps state"
assert_eq "Body text" "$(_field "$out" 'd["body"]')" "AC7 view-issue adds body from description"
assert_eq "spec:ready,p2" "$(_field "$out" '",".join(l["name"] for l in d["labels"])')" "AC7 view-issue turns string labels into [{name}]"
assert_eq "42 https://gitlab.com/acme/widget/-/issues/42" "$(_field "$out" 'str(d["iid"]) + " " + d["web_url"]')" "AC7 view-issue keeps the raw keys"
assert_eq "first human,**PM spec:** the spec v1,**PM spec:** the spec v2,later human" "$(_field "$out" '",".join(c["body"] for c in d["comments"])')" "AC7 view-issue lists the comments oldest first and drops system notes"
assert_eq "alice 2026-10-01T10:00:00Z" "$(_field "$out" 'd["comments"][0]["author"]["login"] + " " + d["comments"][0]["createdAt"]')" "AC7 view-issue maps a note to {author:{login}, createdAt}"

# ── AC8 --spec ───────────────────────────────────────────────────────────────
out="$(bash "$VCS" view-issue 42 --spec 2>/dev/null)"; err="$(bash "$VCS" view-issue 42 --spec 2>&1 >/dev/null)"
assert_eq "body,comments,labels,title" "$(_field "$out" '",".join(sorted(d))')" "AC8 view-issue --spec prints title, body, labels, comments"
assert_eq "**PM spec:** the spec v2" "$(_field "$out" '",".join(c["body"] for c in d["comments"])')" "AC8 view-issue --spec keeps only the latest PM spec comment"
assert_not_contains "$err" "not implemented" "AC8 view-issue --spec prints no not-implemented note"

# ── AC9 --since-stage ────────────────────────────────────────────────────────
out="$(bash "$VCS" view-issue 42 --since-stage 2>/dev/null)"; err="$(bash "$VCS" view-issue 42 --since-stage 2>&1 >/dev/null)"
assert_eq "**PM spec:** the spec v2,later human" "$(_field "$out" '",".join(c["body"] for c in d["comments"])')" "AC9 view-issue --since-stage keeps the latest stage comment and what follows"
assert_eq "1" "$(_field "$out" 'd["earlier_comments"]')" "AC9 view-issue --since-stage counts the older human comments"
assert_not_contains "$err" "not implemented" "AC9 view-issue --since-stage prints no not-implemented note"

# ── AC10 fail closed ─────────────────────────────────────────────────────────
out="$(STUB_GITLAB_ISSUE_VIEW_FAIL=1 bash "$VCS" view-issue 42 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC10 view-issue exits 1 when the issue fetch fails"
assert_eq "" "$out" "AC10 view-issue prints nothing when the issue fetch fails"
out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" view-issue 42 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC10 view-issue exits 1 when the notes fetch fails"
assert_eq "" "$out" "AC10 view-issue prints nothing when the notes fetch fails"
out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" view-issue 42 --spec 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC10 view-issue --spec exits 1 when the notes fetch fails"
assert_eq "" "$out" "AC10 view-issue --spec prints nothing when the notes fetch fails"
out="$(bash "$VCS" view-issue 'x;1' 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC10 view-issue exits 1 for a non-numeric issue number"
assert_eq "" "$out" "AC10 view-issue prints nothing for a non-numeric issue number"
out="$(STUB_GITLAB_ISSUE_VIEW='[1,2]' bash "$VCS" view-issue 42 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC10 view-issue exits 1 when the issue is not a JSON object"
unset STUB_GITLAB_ISSUE_VIEW STUB_GITLAB_ISSUE_NOTES

# ── AC11 dry-run ─────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run list-issues 2>&1)"
assert_contains "$out" "glab issue list --state opened --per-page 100 --output json" "AC11 --dry-run list-issues prints the --output json command"
out="$(bash "$VCS" --dry-run list-prs 2>&1)"
assert_contains "$out" "glab mr list --state opened --per-page 100 --output json" "AC11 --dry-run list-prs prints the --output json command"
out="$(bash "$VCS" --dry-run view-issue 42 2>&1)"
assert_contains "$out" "glab issue view 42 --output json" "AC11 --dry-run view-issue prints the issue command"
assert_contains "$out" "issues/42/notes" "AC11 --dry-run view-issue prints the notes command"
assert_not_contains "$out" "not implemented" "AC11 --dry-run view-issue prints no not-implemented note"
assert_eq "" "$(cat "$GH_LOG")" "AC11 --dry-run calls glab for none of the three verbs"

finish
