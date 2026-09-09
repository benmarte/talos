#!/usr/bin/env bash
# test-adapter-body-parity.sh — feed the SAME normalised fixture (a comments
# array, a PR object, a PR list, a mergeable value) to BOTH the gh-based
# adapter (_github, via tests/stubs/gh) and the REST-based adapter
# (_github_api, via tests/stubs/curl -- the same stub test-github-api.sh
# uses) for every verb whose provider-independent logic now lives in a
# _vcs_shared_* helper (#177 slices 1-4), and asserts byte-identical stdout
# and exit code.
#
# This is a stronger guarantee than tests/test-verb-parity.sh's checks:
#   - "same verb names"        proves the two adapters expose the same API.
#   - "string defined once"    proves a marker/rule isn't hand-duplicated.
#   - this file                proves that, given the same input, the two
#                               adapters actually PRODUCE the same output --
#                               the drift #177 was filed over (see its
#                               em-dash-vs-hyphen example) is exactly the
#                               class of bug a byte-diff like this catches
#                               and a name-only or count-only check cannot.
#
# Fixture shape note: both stubs are fed the SAME logical values (a head
# SHA, a login, a comment body, ...) -- only the wire shape differs, because
# that IS the adapter boundary: `tests/stubs/gh` answers `gh`-CLI-shaped
# invocations (STUB_* env vars matched against the exact `gh` args), while
# `tests/stubs/curl` answers REST-shaped HTTP calls (one JSON response per
# CURL_QUEUE line, in call order). Where a verb's REST fixture path did not
# already exist in tests/test-github-api.sh (pr-mergeable, view-issue
# --spec), the fixture is expressed directly with CURL_QUEUE below --
# tests/stubs/curl needed no code changes since CURL_QUEUE already accepts
# arbitrary REST JSON; only tests/stubs/gh's existing STUB_PR_MERGEABLE /
# STUB_ISSUE_* variables were reused on the gh side.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
REPO_SLUG="acme/widget"
TEST_TOKEN="test-secret-token-parity"
export TALOS_RETRY_SLEEP_SCALE=0

use_github() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "github", "repo": "$REPO_SLUG"}}
CFG
  unset GITHUB_TOKEN GH_TOKEN
}

use_github_api() {
  cat > talos.pipeline.json <<CFG
{"vcs": {"provider": "github-api", "repo": "$REPO_SLUG"}}
CFG
  export GITHUB_TOKEN="$TEST_TOKEN"
}

# reset_stubs — clear logs/queues and every STUB_* override this file sets,
# so one case's fixture can never leak into the next.
reset_stubs() {
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  unset STUB_ISSUE_COMMENTS_JSON STUB_PR_HEAD_SHA STUB_PR_BASE_REF_NAME \
        STUB_PR_LABELS_JSON STUB_PR_COMMENTS_JSON STUB_PR_LIST STUB_PR_FILES \
        STUB_PR_NUMBER STUB_PR_BODY STUB_PR_MERGEABLE STUB_ISSUE_TITLE \
        STUB_ISSUE_BODY STUB_ISSUE_LABELS_JSON
}

# assert_parity <label> <out_gh> <rc_gh> <out_api> <rc_api>
assert_parity() {
  local label="$1" out_gh="$2" rc_gh="$3" out_api="$4" rc_api="$5"
  assert_eq "$out_gh" "$out_api" "$label: stdout identical across adapters"
  assert_eq "$rc_gh" "$rc_api"   "$label: exit code identical across adapters"
}

# ── read-attempt ───────────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_ISSUE_COMMENTS_JSON='[{"user":{"login":"talos-bot"},"body":"<!-- talos:attempt stage=developer count=1 total=1 -->"}]'
out_gh="$(bash "$VCS" read-attempt 9 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '[{"user":{"login":"talos-bot"},"body":"<!-- talos:attempt stage=developer count=1 total=1 -->"}]' > "$CURL_QUEUE"
out_api="$(bash "$VCS" read-attempt 9 2>/dev/null)"; rc_api=$?

assert_parity "read-attempt" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── check-attempt ──────────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_ISSUE_COMMENTS_JSON='[{"user":{"login":"talos-bot"},"body":"<!-- talos:attempt stage=qa count=1 total=2 -->"}]'
out_gh="$(bash "$VCS" check-attempt 9 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '[{"user":{"login":"talos-bot"},"body":"<!-- talos:attempt stage=qa count=1 total=2 -->"}]' > "$CURL_QUEUE"
out_api="$(bash "$VCS" check-attempt 9 2>/dev/null)"; rc_api=$?

assert_parity "check-attempt" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── record-attempt --dry-run ───────────────────────────────────────────────
# The dry-run message text is a literal string both adapters must match
# exactly (unlike most other verbs' [dry-run] lines, which legitimately
# describe adapter-specific mechanics -- gh args vs. a REST URL -- this one
# names the marker format itself, so it belongs in the parity net).
reset_stubs
use_github
out_gh="$(bash "$VCS" record-attempt 9 developer --dry-run 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
out_api="$(bash "$VCS" record-attempt 9 developer --dry-run 2>/dev/null)"; rc_api=$?

assert_parity "record-attempt --dry-run" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── check-approval-sha ─────────────────────────────────────────────────────
# Marker SHA == head SHA (the "current" happy path): both adapters resolve
# it without needing a git diff, so the fixture stays hermetic.
_HEAD="aabbccddeeff001122334455667788990011aabb"
reset_stubs
use_github
export STUB_PR_HEAD_SHA="$_HEAD"
export STUB_PR_BASE_REF_NAME="main"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
export STUB_PR_COMMENTS_JSON="[{\"user\":{\"login\":\"talos-bot\"},\"body\":\"<!-- talos:approval sha=${_HEAD} role=qa -->\"}]"
out_gh="$(bash "$VCS" check-approval-sha 7 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"user\":{\"login\":\"talos-bot\"},\"body\":\"<!-- talos:approval sha=${_HEAD} role=qa -->\"}]" \
  > "$CURL_QUEUE"
out_api="$(bash "$VCS" check-approval-sha 7 2>/dev/null)"; rc_api=$?

assert_parity "check-approval-sha" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── check-pr-files ─────────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_PR_FILES="src/auth.js
tests/auth.test.js"
out_gh="$(bash "$VCS" check-pr-files 9 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '[{"filename":"src/auth.js"},{"filename":"tests/auth.test.js"}]' > "$CURL_QUEUE"
out_api="$(bash "$VCS" check-pr-files 9 2>/dev/null)"; rc_api=$?

assert_parity "check-pr-files" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── pr-files ────────────────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_PR_FILES="src/auth.js
tests/auth.test.js"
out_gh="$(bash "$VCS" pr-files 9 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '[{"filename":"src/auth.js"},{"filename":"tests/auth.test.js"}]' > "$CURL_QUEUE"
out_api="$(bash "$VCS" pr-files 9 2>/dev/null)"; rc_api=$?

assert_parity "pr-files" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── find-pr ─────────────────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: guard null session","headRefName":"fix/issue-42-guard","body":"Closes #42"}]'
out_gh="$(bash "$VCS" find-pr 42 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '[{"number":9,"state":"open","title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"base":{"ref":"main"},"body":"Closes #42"}]' > "$CURL_QUEUE"
out_api="$(bash "$VCS" find-pr 42 2>/dev/null)"; rc_api=$?

assert_parity "find-pr" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── check-closing-keyword: no closing keyword (pass, single fetch) ────────
reset_stubs
use_github
export STUB_PR_NUMBER="7"
export STUB_PR_BODY="Part of #9"
out_gh="$(bash "$VCS" check-closing-keyword 7 9 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '{"number":7,"body":"Part of #9","head":{"ref":"fix/branch"},"base":{"ref":"main"}}' > "$CURL_QUEUE"
out_api="$(bash "$VCS" check-closing-keyword 7 9 2>/dev/null)"; rc_api=$?

assert_parity "check-closing-keyword (no keyword)" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── check-closing-keyword: closing keyword + an open sibling (fails, and
# the sibling diagnostic message is exactly the string #177 found drifted
# on -- an em-dash on one adapter, a plain hyphen on the other) ────────────
reset_stubs
use_github
export STUB_PR_NUMBER="7"
export STUB_PR_BODY="Closes #9"
export STUB_PR_LIST='[{"number":7,"state":"OPEN","title":"PR 7","headRefName":"fix/branch","body":"Closes #9"},{"number":8,"state":"OPEN","title":"PR 8","headRefName":"fix/issue-9-other","body":"Part of #9"}]'
out_gh="$(bash "$VCS" check-closing-keyword 7 9 2>"$SANDBOX/stderr-gh.txt")"; rc_gh=$?
err_gh="$(cat "$SANDBOX/stderr-gh.txt")"

reset_stubs
use_github_api
printf '%s\n' \
  '{"number":7,"body":"Closes #9","head":{"ref":"fix/branch"},"base":{"ref":"main"}}' \
  '[{"number":7,"head":{"ref":"fix/branch"},"title":"PR 7","body":"Closes #9","state":"open"},{"number":8,"head":{"ref":"fix/issue-9-other"},"title":"PR 8","body":"Part of #9","state":"open"}]' \
  > "$CURL_QUEUE"
out_api="$(bash "$VCS" check-closing-keyword 7 9 2>"$SANDBOX/stderr-api.txt")"; rc_api=$?
err_api="$(cat "$SANDBOX/stderr-api.txt")"

assert_parity "check-closing-keyword (open sibling)" "$out_gh" "$rc_gh" "$out_api" "$rc_api"
assert_eq "$err_gh" "$err_api" "check-closing-keyword (open sibling): stderr diagnostic identical (em-dash/hyphen drift, #177)"

# ── pr-mergeable: MERGEABLE and CONFLICTING (single fetch each; UNKNOWN
# would retry 5x and is exercised elsewhere -- not worth a real sleep here) ─
reset_stubs
use_github
export STUB_PR_MERGEABLE="MERGEABLE"
out_gh="$(bash "$VCS" pr-mergeable 42 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '{"mergeable":true}' > "$CURL_QUEUE"
out_api="$(bash "$VCS" pr-mergeable 42 2>/dev/null)"; rc_api=$?

assert_parity "pr-mergeable (MERGEABLE)" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

reset_stubs
use_github
export STUB_PR_MERGEABLE="CONFLICTING"
out_gh="$(bash "$VCS" pr-mergeable 42 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' '{"mergeable":false}' > "$CURL_QUEUE"
out_api="$(bash "$VCS" pr-mergeable 42 2>/dev/null)"; rc_api=$?

assert_parity "pr-mergeable (CONFLICTING)" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── view-issue --spec ───────────────────────────────────────────────────────
reset_stubs
use_github
export STUB_ISSUE_TITLE="Fix login crash"
export STUB_ISSUE_BODY="stub body"
export STUB_ISSUE_LABELS_JSON='[{"name":"pipeline:dev"}]'
export STUB_ISSUE_COMMENTS_JSON='[{"user":{"login":"talos-pm"},"body":"**PM spec:** do the thing"}]'
out_gh="$(bash "$VCS" view-issue 5 --spec 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' \
  '{"title":"Fix login crash","body":"stub body","labels":[{"name":"pipeline:dev"}]}' \
  '[{"user":{"login":"talos-pm"},"body":"**PM spec:** do the thing"}]' \
  > "$CURL_QUEUE"
out_api="$(bash "$VCS" view-issue 5 --spec 2>/dev/null)"; rc_api=$?

assert_parity "view-issue --spec" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

# ── has-spec (composes on top of view-issue; #199) ─────────────────────────
reset_stubs
use_github
export STUB_ISSUE_TITLE="Fix login crash"
export STUB_ISSUE_BODY=$'## Acceptance criteria\n- [ ] does the thing'
export STUB_ISSUE_LABELS_JSON='[]'
export STUB_ISSUE_COMMENTS_JSON='[]'
out_gh="$(bash "$VCS" has-spec 5 2>/dev/null)"; rc_gh=$?

reset_stubs
use_github_api
printf '%s\n' \
  '{"title":"Fix login crash","body":"## Acceptance criteria\n- [ ] does the thing","labels":[]}' \
  '[]' \
  > "$CURL_QUEUE"
out_api="$(bash "$VCS" has-spec 5 2>/dev/null)"; rc_api=$?

assert_parity "has-spec" "$out_gh" "$rc_gh" "$out_api" "$rc_api"

finish
