#!/usr/bin/env bash
# test-gitlab-gate-verbs.sh -- the gitlab adapter's merge-gate and sweep verbs
# (#303). Before this fix check-pr-files, check-closing-keyword, pr-files,
# rerun-ci and check-epic-acceptance were a stub that printed "not
# implemented for gitlab" and exited 0, so the forbidden-files gate passed a
# secret file, the sibling gate never blocked and the epic sweep closed epics
# with unticked boxes. Uses the tests/stubs/glab stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF

# ── pr-files ──────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_DIFFS='[{"old_path":"a.txt","new_path":"a.txt"},{"old_path":"old/b.sh","new_path":"new/b.sh","renamed_file":true},{"old_path":"c.md","new_path":"c.md","new_file":true}]' \
  bash "$VCS" pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "pr-files: exits 0 on a successful fetch"
assert_eq "$(printf 'a.txt\nnew/b.sh\nc.md')" "$out" "pr-files: prints one path per line, renamed files by their new path"
assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fwidget/merge_requests/9/diffs?per_page=100" \
  "pr-files: reads the paginated MR diffs API for the URL-encoded project"

out="$(STUB_GITLAB_MR_DIFFS='[{"new_path":"x"}][{"new_path":"y"}]' bash "$VCS" pr-files 9 2>&1)"
assert_eq "$(printf 'x\ny')" "$out" "pr-files: merges every page of a paginated response"

out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" pr-files 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "pr-files: an API failure exits non-zero"
assert_eq "" "$out" "pr-files: an API failure prints no paths"

bash "$VCS" pr-files 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "pr-files: an empty API response exits non-zero, never 'no files changed'"

# ── check-pr-files (forbidden-files merge gate) ──────────────────────────────
out="$(STUB_GITLAB_MR_DIFFS='[{"new_path":"src/app.py"},{"new_path":"config/.env"}]' \
  bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-pr-files: exits 1 when the MR adds a forbidden file"
assert_contains "$out" "FORBIDDEN FILES in PR" "check-pr-files: prints the shared forbidden-files diagnostic"
assert_contains "$out" "config/.env" "check-pr-files: names the forbidden path"

out="$(STUB_GITLAB_MR_DIFFS='[{"new_path":"src/app.py"},{"new_path":"README.md"}]' \
  bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-pr-files: exits 0 when no forbidden file is touched"
assert_contains "$out" "no forbidden files" "check-pr-files: prints the shared all-clear line"

out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-pr-files: a fetch failure fails closed"
assert_not_contains "$out" "no forbidden files" "check-pr-files: a fetch failure never reports all-clear"
assert_not_contains "$out" "not implemented" "check-pr-files: no longer the fail-open stub"

# ── check-closing-keyword (sibling merge gate) ───────────────────────────────
_mr_closes='{"iid":9,"description":"Closes #42"}'
_sibling='[{"iid":9,"title":"fix: a","state":"opened","source_branch":"fix/issue-42-a","description":"Closes #42"},{"iid":11,"title":"fix: b","state":"opened","source_branch":"fix/issue-42-b","description":"Part of #42"}]'
out="$(STUB_GITLAB_MR_VIEW="$_mr_closes" STUB_GITLAB_MR_LIST="$_sibling" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-closing-keyword: exits 1 when an opened sibling MR references the issue"
assert_contains "$out" "open sibling PR(s) still reference the same issue: #11" \
  "check-closing-keyword: prints the shared sibling diagnostic"

out="$(STUB_GITLAB_MR_VIEW="$_mr_closes" \
  STUB_GITLAB_MR_LIST='[{"iid":9,"title":"fix: a","state":"opened","source_branch":"fix/issue-42-a","description":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: exits 0 when the MR is the only one for the issue"
assert_not_contains "$out" "unverified" "check-closing-keyword: a verified pass prints no marker"

out="$(STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Part of #42"}' STUB_GITLAB_MR_LIST="$_sibling" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: exits 0 when the MR has no closing keyword"

out="$(STUB_GITLAB_MR_VIEW_FAIL=1 bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: an MR fetch failure fails open (github parity)"
assert_contains "$out" "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed" \
  "check-closing-keyword: an MR fetch failure prints the unverified marker"

out="$(STUB_GITLAB_MR_VIEW="$_mr_closes" STUB_GITLAB_MR_LIST_FAIL=1 \
  bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: a sibling-list failure fails open (github parity)"
assert_contains "$out" "talos:closing-keyword-unverified pr=9 issue=42 reason=sibling-fetch-failed" \
  "check-closing-keyword: a sibling-list failure prints the unverified marker"

# ── check-epic-acceptance ─────────────────────────────────────────────────────
out="$(STUB_GITLAB_ISSUE_DESCRIPTION='Epic.

- [ ] Ship the adapter
- [x] Write the README' bash "$VCS" check-epic-acceptance 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: exits 1 when unticked boxes remain"
assert_eq "Ship the adapter" "$out" "check-epic-acceptance: prints only the unticked item"

out="$(STUB_GITLAB_ISSUE_DESCRIPTION='- [x] Ship the adapter
- [X] Write the README' bash "$VCS" check-epic-acceptance 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "check-epic-acceptance: exits 0 when every box is ticked"
assert_eq "" "$out" "check-epic-acceptance: prints nothing when every box is ticked"

bash "$VCS" check-epic-acceptance 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a response without a description fails closed"

STUB_GITLAB_ISSUE_VIEW_FAIL=1 bash "$VCS" check-epic-acceptance 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-epic-acceptance: a fetch failure fails closed so the epic stays open"

# ── rerun-ci ──────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_API='{"iid":9,"head_pipeline":{"id":555,"status":"failed"}}' \
  bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "rerun-ci: exits 0 once the head pipeline retry is posted"
assert_contains "$(cat "$GH_LOG")" "api --method POST projects/acme%2Fwidget/pipelines/555/retry" \
  "rerun-ci: retries the MR's head pipeline via the pipelines API"

out="$(STUB_GITLAB_MR_API='{"iid":9,"head_pipeline":null}' bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "rerun-ci: an MR without a head pipeline exits non-zero"

STUB_GITLAB_MR_API='{"iid":9,"head_pipeline":{"id":555}}' STUB_GITLAB_API_FAIL=1 \
  bash "$VCS" rerun-ci 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "rerun-ci: an API failure exits non-zero, never a silent 0"

finish
