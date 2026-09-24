#!/usr/bin/env bash
# test-azure-gate-verbs.sh -- the azure adapter's merge-gate and sweep verbs
# (#304). Before this fix check-pr-files, check-closing-keyword, pr-files,
# rerun-ci and check-epic-acceptance were a stub that printed "not
# implemented for azure" and exited 0, so the forbidden-files gate passed a
# secret file, the sibling gate never blocked and the epic sweep closed epics
# with unticked boxes. Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
_git="https://dev.azure.com/acme/proj/_apis/git/repositories/widget"

# ── pr-files ──────────────────────────────────────────────────────────────────
_iters='{"count":3,"value":[{"id":1},{"id":3},{"id":2}]}'
: > "$GH_LOG"
out="$(STUB_AZURE_PR_ITERATIONS="$_iters" \
  STUB_AZURE_PR_CHANGES='{"changeEntries":[{"item":{"path":"/a.txt"},"changeType":"edit"},{"item":{"path":"/src","isFolder":true},"changeType":"edit"},{"item":{"path":"/new/b.sh","originalPath":"/old/b.sh"},"changeType":"rename"},{"item":{"path":"/gone.md"},"changeType":"delete"}],"nextSkip":0,"nextTop":0}' \
  bash "$VCS" pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "pr-files: exits 0 on a successful fetch"
assert_eq "$(printf 'a.txt\nnew/b.sh\ngone.md')" "$out" "pr-files: one path per line without the leading /, folders skipped"
assert_contains "$(cat "$GH_LOG")" "[$_git/pullRequests/9/iterations?api-version=7.1]" \
  "pr-files: lists the PR's iterations via the REST API"
assert_contains "$(cat "$GH_LOG")" "[$_git/pullRequests/9/iterations/3/changes?\$top=2000&\$skip=0&api-version=7.1]" \
  "pr-files: reads the changes of the last iteration"

out="$(STUB_AZURE_PR_ITERATIONS="$_iters" \
  STUB_AZURE_PR_CHANGES_SKIP_0='{"changeEntries":[{"item":{"path":"/x"}}],"nextSkip":2000,"nextTop":2000}' \
  STUB_AZURE_PR_CHANGES_SKIP_2000='{"changeEntries":[{"item":{"path":"/y"}}],"nextSkip":0,"nextTop":0}' \
  bash "$VCS" pr-files 9 2>&1)"
assert_eq "$(printf 'x\ny')" "$out" "pr-files: follows nextSkip across every page"

out="$(STUB_AZURE_PR_ITERATIONS_FAIL=1 bash "$VCS" pr-files 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "pr-files: an iterations fetch failure exits non-zero"
assert_eq "" "$out" "pr-files: an iterations fetch failure prints no paths"

out="$(STUB_AZURE_PR_ITERATIONS="$_iters" STUB_AZURE_PR_CHANGES_FAIL=1 bash "$VCS" pr-files 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "pr-files: a changes fetch failure exits non-zero"
assert_eq "" "$out" "pr-files: a changes fetch failure prints no paths"

out="$(STUB_AZURE_PR_ITERATIONS="$_iters" \
  STUB_AZURE_PR_CHANGES_SKIP_0='{"changeEntries":[{"item":{"path":"/x"}}],"nextSkip":2000,"nextTop":2000}' \
  STUB_AZURE_PR_CHANGES_SKIP_2000='{"message":"TF401180"}' \
  bash "$VCS" pr-files 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "pr-files: an unparseable later page exits non-zero"
assert_eq "" "$out" "pr-files: an unparseable later page prints no partial list"

STUB_AZURE_PR_ITERATIONS='{"count":0,"value":[]}' bash "$VCS" pr-files 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "pr-files: a PR without iterations exits non-zero, never 'no files changed'"

: > "$GH_LOG"
bash "$VCS" pr-files '9/../../x' >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "pr-files: a non-numeric PR id is rejected"
assert_not_contains "$(cat "$GH_LOG")" "pullRequests" "pr-files: a non-numeric PR id never reaches a REST path"

printf '{"vcs": {"provider": "azure", "repo": "widget"}}' > talos.pipeline.json
STUB_AZURE_PR_ITERATIONS="$_iters" STUB_AZURE_PR_CHANGES='{"changeEntries":[],"nextSkip":0}' \
  bash "$VCS" pr-files 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "pr-files: an unresolved org/project exits non-zero"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF

# ── check-pr-files (forbidden-files merge gate) ──────────────────────────────
out="$(STUB_AZURE_PR_ITERATIONS="$_iters" \
  STUB_AZURE_PR_CHANGES='{"changeEntries":[{"item":{"path":"/src/app.py"}},{"item":{"path":"/config/.env"}}],"nextSkip":0}' \
  bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-pr-files: exits 1 when the PR adds a forbidden file"
assert_contains "$out" "FORBIDDEN FILES in PR" "check-pr-files: prints the shared forbidden-files diagnostic"
assert_contains "$out" "  config/.env" "check-pr-files: names the forbidden path without the leading /"

out="$(STUB_AZURE_PR_ITERATIONS="$_iters" \
  STUB_AZURE_PR_CHANGES='{"changeEntries":[{"item":{"path":"/src/app.py"}},{"item":{"path":"/README.md"}}],"nextSkip":0}' \
  bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-pr-files: exits 0 when no forbidden file is touched"
assert_contains "$out" "no forbidden files" "check-pr-files: prints the shared all-clear line"

out="$(STUB_AZURE_PR_ITERATIONS="$_iters" STUB_AZURE_PR_CHANGES_FAIL=1 bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-pr-files: a fetch failure fails closed"
assert_not_contains "$out" "no forbidden files" "check-pr-files: a fetch failure never reports all-clear"
assert_not_contains "$out" "not implemented" "check-pr-files: no longer the fail-open stub"

bash "$VCS" check-pr-files abc >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-pr-files: a non-numeric PR id fails closed"

# ── check-closing-keyword (link-based sibling merge gate) ────────────────────
# PR 9 is linked to work item 42; the work item links PRs 9 and 11.
_rel() { printf '[%s]' "$(for _p in "$@"; do printf '{"rel":"ArtifactLink","url":"vstfs:///Git/PullRequestId/p1%%2Fr1%%2F%s"},' "$_p"; done | sed 's/,$//')"; }
_active9='[{"pullRequestId":9,"status":"active","sourceRefName":"refs/heads/fix/issue-42-a"}]'
out="$(STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9 11)" \
  STUB_AZURE_PR_11='{"pullRequestId":11,"status":"active"}' STUB_AZURE_PR_LIST="$_active9" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-closing-keyword: exits 1 when another active PR is linked to the work item"
assert_contains "$out" "open sibling PR(s) still reference the same issue: #11" \
  "check-closing-keyword: prints the github-shaped sibling diagnostic"

out="$(STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9 11)" \
  STUB_AZURE_PR_11='{"pullRequestId":11,"status":"completed"}' STUB_AZURE_PR_LIST="$_active9" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: a completed linked PR is not a sibling"
assert_not_contains "$out" "unverified" "check-closing-keyword: a verified pass prints no marker"

out="$(STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9)" \
  STUB_AZURE_PR_LIST='[{"pullRequestId":9,"status":"active","sourceRefName":"refs/heads/fix/issue-42-a"},{"pullRequestId":12,"status":"active","sourceRefName":"refs/heads/fix/issue-42-b"},{"pullRequestId":13,"status":"active","sourceRefName":"refs/heads/fix/issue-420-c"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-closing-keyword: exits 1 when an active PR sits on an issue-N branch"
assert_contains "$out" "reference the same issue: #12 —" "check-closing-keyword: names the branch sibling, not issue-420"

out="$(STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9 11)" \
  STUB_AZURE_PR_11='{"pullRequestId":11,"status":"active"}' \
  STUB_AZURE_PR_LIST='[{"pullRequestId":12,"status":"active","sourceRefName":"refs/heads/issue-42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_contains "$out" "reference the same issue: #11 #12" "check-closing-keyword: lists every sibling"

out="$(STUB_AZURE_PR_WORKITEMS='[{"id":7}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9 11)" \
  STUB_AZURE_PR_11='{"pullRequestId":11,"status":"active"}' STUB_AZURE_PR_LIST="$_active9" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: a PR not linked to the work item does not close it"
assert_not_contains "$out" "unverified" "check-closing-keyword: an unlinked PR prints no marker"

out="$(STUB_AZURE_PR_WORKITEMS_FAIL=1 bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: a PR work-item fetch failure fails open (github parity)"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed" "$out" \
  "check-closing-keyword: a PR work-item fetch failure prints the unverified marker"

for _fail in STUB_AZURE_WORKITEM_RELATIONS_FAIL STUB_AZURE_PR_SHOW_FAIL STUB_AZURE_PR_LIST_FAIL; do
  out="$(env "$_fail=1" STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9 11)" \
    STUB_AZURE_PR_11='{"pullRequestId":11,"status":"active"}' STUB_AZURE_PR_LIST="$_active9" \
    bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "check-closing-keyword: $_fail fails open (github parity)"
  assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" "$out" \
    "check-closing-keyword: $_fail prints the unverified marker"
done

for _args in "9 abc" "x9 42" "9"; do
  bash "$VCS" check-closing-keyword $_args >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "check-closing-keyword: rejects bad arguments '$_args'"
done

# ── check-epic-acceptance ─────────────────────────────────────────────────────
_epic() { STUB_AZURE_WORKITEM_DESCRIPTION="$1" bash "$VCS" check-epic-acceptance 42 2>&1; }
out="$(_epic '<div>Epic.</div><ul><li><input type="checkbox" checked="">Write the README</li><li><input type="checkbox">Ship the adapter</li></ul>')"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: an unchecked HTML checkbox keeps the epic open"
assert_eq "Ship the adapter" "$out" "check-epic-acceptance: prints only the unchecked HTML item"

out="$(_epic '<ul><li>☑ Write the README</li><li>☐ Ship the adapter</li><li>&#9744; Tag the release</li></ul>')"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a ☐ item keeps the epic open"
assert_eq "$(printf 'Ship the adapter\nTag the release')" "$out" "check-epic-acceptance: ☐ and &#9744; are unticked, ☑ is ticked"

out="$(_epic '<ul><li>[ ] From python-markdown</li><li>[x] Done</li></ul><p>- [ ] In a paragraph</p>')"; rc=$?
assert_eq "$(printf 'From python-markdown\nIn a paragraph')" "$out" "check-epic-acceptance: [ ] text inside HTML is unticked"

out="$(_epic '- [ ] Markdown item
- [x] Markdown done')"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a markdown description is scanned too"
assert_eq "Markdown item" "$out" "check-epic-acceptance: prints the unticked markdown item"

out="$(_epic '<ul><li><input checked type=checkbox>A</li><li>☒ B</li></ul>- [X] C')"; rc=$?
assert_eq "0" "$rc" "check-epic-acceptance: exits 0 when every box is ticked"
assert_eq "" "$out" "check-epic-acceptance: prints nothing when every box is ticked"

# Only a `checked` ATTRIBUTE ticks a box, never an attribute value (#304 review).
out="$(_epic '<ul><li><input type="checkbox" value="checked">By value</li><li><input type=checkbox data-checked="true" aria-checked="true">By data</li><li><input type="checkbox" checked="">Empty</li><li><input type="checkbox" checked>Bare</li><li><input type="checkbox" CHECKED=checked>Upper</li><li><input checked=true type="checkbox">First</li></ul>')"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: value=\"checked\" does not tick a box"
assert_eq "$(printf 'By value\nBy data')" "$out" "check-epic-acceptance: only the checked attribute ticks; values and data-checked do not"

# The item text is the checkbox's own line or list item, on either side (#304 review).
out="$(_epic '<ul><li>Box after <input type="checkbox"></li><li>Done after <input type="checkbox" checked></li></ul><p>Trailing ☐</p><p>Tasks: ☐ a ☐ b</p><p>c ☐ d ☐</p>')"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a checkbox after its text still counts"
assert_eq "$(printf 'Box after\nTrailing\na\nb\nc\nd')" "$out" \
  "check-epic-acceptance: reports the text beside the box, whichever side it is on"

STUB_AZURE_WORKITEM_SHOW_FAIL=1 bash "$VCS" check-epic-acceptance 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a fetch failure fails closed so the epic stays open"

STUB_AZURE_WORKITEM_JSON='{"message":"TF401232: Work item 42 does not exist"}' \
  bash "$VCS" check-epic-acceptance 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a response without fields fails closed"

bash "$VCS" check-epic-acceptance 4x2 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a non-numeric id fails closed"

python3 -c "print('<p>- [x] done</p>' + 'a' * 70000)" > "$SANDBOX/long.html"
out="$(STUB_AZURE_WORKITEM_DESCRIPTION_FILE="$SANDBOX/long.html" bash "$VCS" check-epic-acceptance 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a description over the 65536-character scan cap fails closed"
out="$(STUB_AZURE_WORKITEM_DESCRIPTION_FILE="$SANDBOX/long.html" bash "$VCS" check-epic-acceptance 42 2>/dev/null)"
assert_eq "(description exceeds 65536 characters; not scanned — review manually)" "$out" \
  "check-epic-acceptance: an oversize description prints one pending item, never an empty list"

# ── rerun-ci ──────────────────────────────────────────────────────────────────
_build='"configuration":{"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"Build"}}'
_review='"configuration":{"type":{"id":"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd","displayName":"Minimum number of reviewers"}}'
_e() { printf '%08d-0000-0000-0000-000000000000' "$1"; }
: > "$GH_LOG"
out="$(STUB_AZURE_PR_POLICIES="[{$_build,\"status\":\"rejected\",\"evaluationId\":\"$(_e 1)\"},{$_build,\"status\":\"approved\",\"evaluationId\":\"$(_e 2)\"},{$_review,\"status\":\"rejected\",\"evaluationId\":\"$(_e 3)\"},{$_build,\"status\":\"broken\",\"evaluationId\":\"$(_e 4)\"}]" \
  bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "rerun-ci: exits 0 once the failed build policies are re-queued"
assert_contains "$(cat "$GH_LOG")" "[repos] [pr] [policy] [queue] [--id] [9] [--evaluation-id] [$(_e 1)]" "rerun-ci: re-queues the rejected build policy"
assert_contains "$(cat "$GH_LOG")" "[--evaluation-id] [$(_e 4)]" "rerun-ci: re-queues the broken build policy"
assert_not_contains "$(cat "$GH_LOG")" "[--evaluation-id] [$(_e 2)]" "rerun-ci: leaves a passing build policy alone"
assert_not_contains "$(cat "$GH_LOG")" "[--evaluation-id] [$(_e 3)]" "rerun-ci: leaves a non-build policy alone"
assert_contains "$out" "re-queued 2 failed build policy evaluation(s) for PR #9" "rerun-ci: reports what it re-queued"

out="$(STUB_AZURE_PR_POLICIES="[{$_build,\"status\":\"approved\",\"evaluationId\":\"$(_e 2)\"}]" bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "rerun-ci: exits 0 when no build policy has failed"
assert_contains "$out" "no failed build policies" "rerun-ci: says there was nothing to re-queue"

STUB_AZURE_PR_POLICIES="[{$_review,\"status\":\"rejected\",\"evaluationId\":\"$(_e 3)\"}]" bash "$VCS" rerun-ci 9 >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "rerun-ci: a PR without a build policy exits 2 (wait for a human), never 0"

STUB_AZURE_PR_POLICIES_FAIL=1 bash "$VCS" rerun-ci 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "rerun-ci: a policy-list failure exits non-zero"

STUB_AZURE_PR_POLICIES="[{$_build,\"status\":\"rejected\",\"evaluationId\":\"$(_e 1)\"}]" STUB_AZURE_POLICY_QUEUE_FAIL=1 \
  bash "$VCS" rerun-ci 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "rerun-ci: a re-queue failure exits non-zero"

bash "$VCS" rerun-ci 9x >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "rerun-ci: a non-numeric PR id exits non-zero"

# ── no azure verb is left on the fail-open stub ───────────────────────────────
assert_not_contains "$(sed -n '/^_azure() {/,/^}/p' "$VCS")" "not implemented for azure — verify manually" \
  "the azure adapter no longer has the fail-open stub arm"

# ── the HTML scan stays linear on adversarial descriptions ───────────────────
# Each body is at the 65536-character cap (the 1 MB one exceeds it and must
# fail closed fast); a 30 s watchdog turns a regression into a failure.
python3 - "$SANDBOX" <<'EOF'
import sys
d, cap = sys.argv[1], 65536
bodies = {
    "lt": "<" * cap,
    "lta": "<a" * (cap // 2),
    "tagname": "<" + "a" * (cap - 1),
    "input": ('<input type' + ' ' * 50) * (cap // 61),
    "attrs": "<input " + "type=" * (cap // 5 - 2),
    "newlines": "\n" * cap,
    "dashes": "- " * (cap // 2),
    "boxes": "☐" * cap,
    "entities": "&#" * (cap // 2),
    # closed tags reach the attribute parser and the in-line box split
    "attrquote": '<input type=checkbox a="' + "b " * ((cap - 30) // 2) + ">",
    "attreq": "<input " + "a= " * ((cap - 10) // 3) + ">",
    "attrsq": "<input type=checkbox " + "a='" * ((cap - 30) // 3) + ">",
    "inputs": "<input type=checkbox>" * (cap // 21),
    "boxline": "☐ a " * (cap // 4),
    "big": "<li>" * (1048576 // 4),
}
for k, v in bodies.items():
    open(d + "/adv-" + k + ".html", "w").write(v)
EOF
_timed() {  # prints "<rc> <seconds>" for "$@"; rc 124 when its process group is killed after 30 s
  python3 -c '
import os, signal, subprocess, sys, time
t = time.time()
p = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
try: rc = p.wait(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); rc = 124
print("%d %.2f" % (rc, time.time() - t))' "$@"
}
for _case in lt:0 lta:0 tagname:0 input:0 attrs:0 newlines:0 dashes:0 boxes:1 entities:0 \
    attrquote:1 attreq:0 attrsq:1 inputs:1 boxline:1 big:1; do
  read -r rc _secs <<<"$(STUB_AZURE_WORKITEM_DESCRIPTION_FILE="$SANDBOX/adv-${_case%%:*}.html" \
    _timed bash "$VCS" check-epic-acceptance 42)"
  assert_eq "${_case#*:}" "$rc" "linear scan: check-epic-acceptance on the '${_case%%:*}' body exits ${_case#*:}"
  awk -v s="$_secs" 'BEGIN { exit !(s < 5) }'; assert_eq "0" "$?" "linear scan: the '${_case%%:*}' body took ${_secs}s (< 5 s)"
done

# The branch scan is capped and linear too: a 1 MB issue-4 branch name.
python3 -c "
import json
print(json.dumps([{'pullRequestId': 12, 'status': 'active', 'sourceRefName': 'refs/heads/' + '/issue-4' * 131072}]))
" > "$SANDBOX/big-list.json"
mkdir -p "$SANDBOX/bigaz"
cat > "$SANDBOX/bigaz/az" <<EOF
#!/bin/sh
case "\$1 \$2 \$3" in
  "repos pr list") cat "\$BIG_LIST"; exit 0 ;;
esac
exec "$STUBS_DIR/az" "\$@"
EOF
chmod +x "$SANDBOX/bigaz/az"
read -r rc _secs <<<"$(PATH="$SANDBOX/bigaz:$PATH" BIG_LIST="$SANDBOX/big-list.json" \
  STUB_AZURE_PR_WORKITEMS='[{"id":42}]' STUB_AZURE_WORKITEM_RELATIONS="$(_rel 9)" \
  _timed bash "$VCS" check-closing-keyword 9 42)"
assert_eq "0" "$rc" "linear scan: check-closing-keyword on a 1 MB branch name exits 0 (no sibling)"
awk -v s="$_secs" 'BEGIN { exit !(s < 5) }'; assert_eq "0" "$?" "linear scan: the 1 MB branch name took ${_secs}s (< 5 s)"

finish
