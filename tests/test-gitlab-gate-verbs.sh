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
# A gitlab project's origin remote: its host pins same-project issue URLs.
git remote set-url origin git@gitlab.com:acme/widget.git
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

# GitLab's default issue_closing_pattern keywords and same-project /-/issues/N
# URLs close the issue too; another project's URL must not.
for _body in 'Implements #42' 'Closing #42' 'Closes https://gitlab.com/acme/widget/-/issues/42'; do
  STUB_GITLAB_MR_VIEW="{\"iid\":9,\"description\":\"$_body\"}" STUB_GITLAB_MR_LIST="$_sibling" \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "check-closing-keyword: '$_body' is a gitlab closing reference"
done
STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes https://gitlab.com/other/proj/-/issues/42"}' STUB_GITLAB_MR_LIST="$_sibling" \
  bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: another project's /-/issues/N URL does not close the issue"

# find-pr merged (#298 strict match) accepts the same gitlab forms.
_merged='[{"iid":12,"title":"feat: x","state":"merged","source_branch":"feature/x","description":"Implements #50. Resolving https://gitlab.com/acme/widget/-/issues/51. Closes https://gitlab.com/other/proj/-/issues/52"}]'
for _n in 50 51; do
  out="$(STUB_GITLAB_MR_LIST="$_merged" bash "$VCS" find-pr "$_n" merged 2>&1)"
  assert_contains "$out" '"number": 12' "find-pr merged: gitlab closing reference to #$_n matches"
done
out="$(STUB_GITLAB_MR_LIST="$_merged" bash "$VCS" find-pr 52 merged 2>&1)"
assert_eq "" "$out" "find-pr merged: another project's /-/issues/N URL does not match"

# GitLab closes every reference in a list after one keyword (#303 review):
# `Closes #1, #2 and #3` closes #3 too. A list never spans a line break.
for _body in 'Closes #40, #41 and #42' 'Fixes #40 #42' 'Closes issues #40, acme/widget#41, #42' \
    'Implements #40,#42' 'Closes #40 and https://gitlab.com/acme/widget/-/issues/42'; do
  STUB_GITLAB_MR_VIEW="{\"iid\":9,\"description\":\"$_body\"}" STUB_GITLAB_MR_LIST="$_sibling" \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "check-closing-keyword: '$_body' closes #42 (gitlab list)"
done
for _body in 'Closes #40 and see #42' 'Closes #40\n#42'; do
  STUB_GITLAB_MR_VIEW="{\"iid\":9,\"description\":\"$_body\"}" STUB_GITLAB_MR_LIST="$_sibling" \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "0" "$rc" "check-closing-keyword: '$_body' does not close #42"
done
# The sibling scan reads lists too: MR 11 closes #42 as the second item.
STUB_GITLAB_MR_VIEW="$_mr_closes" \
  STUB_GITLAB_MR_LIST='[{"iid":9,"title":"a","state":"opened","source_branch":"a","description":"Closes #42"},{"iid":11,"title":"b","state":"opened","source_branch":"b","description":"Closes #7, #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-closing-keyword: a sibling closing #42 later in a list blocks"

_list_merged='[{"iid":14,"title":"feat: y","state":"merged","source_branch":"feature/y","description":"Closes #60, #61 and issue #62. Depends on #63"}]'
for _n in 60 61 62; do
  out="$(STUB_GITLAB_MR_LIST="$_list_merged" bash "$VCS" find-pr "$_n" merged 2>&1)"
  assert_contains "$out" '"number": 14' "find-pr merged: #$_n in a gitlab closing list matches"
done
out="$(STUB_GITLAB_MR_LIST="$_list_merged" bash "$VCS" find-pr 63 merged 2>&1)"
assert_eq "" "$out" "find-pr merged: a mention after the list does not match"

# A same-project URL counts only on the project's host (#303 review).
STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes https://gitlab.evil.example/acme/widget/-/issues/42"}' STUB_GITLAB_MR_LIST="$_sibling" \
  bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "check-closing-keyword: a same-path URL on another host does not close the issue"
out="$(STUB_GITLAB_MR_LIST='[{"iid":12,"title":"x","state":"merged","source_branch":"x","description":"Closes https://gitlab.evil.example/acme/widget/-/issues/53"}]' \
  bash "$VCS" find-pr 53 merged 2>&1)"
assert_eq "" "$out" "find-pr merged: a same-path URL on another host does not match"

# An ssh alias host (no dot, from ~/.ssh/config) is not the URL host: treat
# it as unknown and accept the project's URL on any host (#303 review).
git remote set-url origin git@gitlab-work:acme/widget.git
STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes https://gitlab.com/acme/widget/-/issues/42"}' STUB_GITLAB_MR_LIST="$_sibling" \
  bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "check-closing-keyword: an ssh-alias origin host does not reject the project's https URL"
out="$(STUB_GITLAB_MR_LIST='[{"iid":12,"title":"x","state":"merged","source_branch":"x","description":"Closes https://gitlab.com/acme/widget/-/issues/53"}]' \
  bash "$VCS" find-pr 53 merged 2>&1)"
assert_contains "$out" '"number": 12' "find-pr merged: an ssh-alias origin host does not reject the project's https URL"
git remote set-url origin git@gitlab.com:acme/widget.git

# The closing-list scan stays linear (#303 review): `fix#1 ` is both a
# keyword and a list item, which made every keyword re-walk the rest of the
# list (2.9 s at 24 KB). A 1 MB description must finish well inside 5 s.
# The body is too big for an env var, so a glab wrapper serves it from a
# file; a 30 s watchdog turns a regression into a failure, not a hang.
mkdir -p "$SANDBOX/bigglab"
cat > "$SANDBOX/bigglab/glab" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "mr view") cat "\$BIG_VIEW" ;;
  "mr list"|"api --paginate") cat "\$BIG_LIST" ;;
  *) exec "$STUBS_DIR/glab" "\$@" ;;
esac
EOF
chmod +x "$SANDBOX/bigglab/glab"
python3 - "$SANDBOX" <<'EOF'
import json, sys
d, big = sys.argv[1], ('fix#1 ' * 174763)[:1048576]
mr = lambda iid, state, desc: {"iid": iid, "title": "t", "state": state, "source_branch": "b%d" % iid, "description": desc}
json.dump(mr(9, "opened", big), open(d + "/big-view.json", "w"))
json.dump(mr(9, "opened", "Closes #42"), open(d + "/closes-view.json", "w"))
json.dump([mr(9, "opened", "Closes #42"), mr(11, "opened", big)], open(d + "/big-open.json", "w"))
json.dump([mr(12, "merged", big)], open(d + "/big-merged.json", "w"))
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
for _case in "big-view|big-open|check-closing-keyword 9 42|the MR body" \
    "closes-view|big-open|check-closing-keyword 9 42|a sibling body" \
    "closes-view|big-merged|find-pr 42 merged|a merged MR body"; do
  IFS='|' read -r _view _list _verb _what <<<"$_case"
  read -r rc _secs <<<"$(PATH="$SANDBOX/bigglab:$PATH" BIG_VIEW="$SANDBOX/$_view.json" BIG_LIST="$SANDBOX/$_list.json" \
    _timed bash "$VCS" $_verb)"
  assert_eq "0" "$rc" "linear scan: $_verb on a 1 MB 'fix#1 ' $_what exits 0 (no match)"
  awk -v s="$_secs" 'BEGIN { exit !(s < 5) }'; assert_eq "0" "$?" "linear scan: $_verb on a 1 MB $_what took ${_secs}s (< 5 s)"
done

# github keeps its narrower keyword set: Implements is not a closing keyword,
# and only the first reference after a keyword counts (no GitLab lists).
rm talos.pipeline.json
_gh_siblings() { printf '[{"number":9,"state":"OPEN","title":"a","headRefName":"a","body":"%s"},{"number":7,"state":"OPEN","title":"b","headRefName":"fix/issue-42-b","body":"Part of #42"}]' "$1"; }
for _case in '1|Closes #42' '0|Implements #42' '0|Closes #40, #42'; do
  _body="${_case#*|}"
  STUB_PR_BODY="$_body" STUB_PR_NUMBER=9 STUB_PR_LIST="$(_gh_siblings "$_body")" \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "${_case%%|*}" "$rc" "github: check-closing-keyword on '$_body'"
done
# ── self-hosted GitLab, vcs.repo unset (#303 review) ─────────────────────────
# The auto-detect leaves REPO as the whole self-hosted remote. REST paths
# must use the bare, URL-encoded group/sub/project, and the remote's host
# pins same-project issue URLs. `gh repo view` fails outside GitHub.
mkdir -p "$SANDBOX/nogh"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nogh/gh"
chmod +x "$SANDBOX/nogh/gh"
printf '{"vcs": {"provider": "gitlab"}}' > talos.pipeline.json
for _remote in https://gitlab.example.com/acme/sub/widget.git \
    ssh://git@gitlab.example.com:2222/acme/sub/widget.git \
    git@gitlab.example.com:acme/sub/widget.git; do
  git remote set-url origin "$_remote"
  : > "$GH_LOG"
  out="$(PATH="$SANDBOX/nogh:$PATH" STUB_GITLAB_MR_DIFFS='[{"new_path":"a.txt"}]' bash "$VCS" pr-files 9 2>&1)"; rc=$?
  assert_eq "0" "$rc" "self-hosted $_remote: pr-files exits 0"
  assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fsub%2Fwidget/merge_requests/9/diffs" \
    "self-hosted $_remote: REST paths use the bare group/sub/project"
  PATH="$SANDBOX/nogh:$PATH" STUB_GITLAB_MR_LIST="$_sibling" \
    STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes https://gitlab.example.com/acme/sub/widget/-/issues/42"}' \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "self-hosted $_remote: a same-project URL on the instance's host closes the issue"
  PATH="$SANDBOX/nogh:$PATH" STUB_GITLAB_MR_LIST="$_sibling" \
    STUB_GITLAB_MR_VIEW='{"iid":9,"description":"Closes https://gitlab.com/acme/sub/widget/-/issues/42"}' \
    bash "$VCS" check-closing-keyword 9 42 >/dev/null 2>&1; rc=$?
  assert_eq "0" "$rc" "self-hosted $_remote: the same path on another host does not"
done
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF

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
