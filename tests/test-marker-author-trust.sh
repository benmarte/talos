#!/usr/bin/env bash
# test-marker-author-trust.sh — issue #187: approval-marker author
# verification on by default, inferring the authenticated user as trusted.
#
# Covers the acceptance criteria from the validator's slice comment:
#   (a) unset config, current user resolves -> own markers accepted,
#       mallory's rejected with one aggregated stderr line
#   (b) markers.trusted_authors: [alice] -> alice AND the current user
#       (union, not replacement) accepted
#   (c) markers.verify_authors: false -> mallory accepted, no warning
#   (d) identity lookup fails + no trusted_authors -> fail-open warning,
#       unchanged from pre-#187 behaviour
#   (e) a bot login is rejected unless explicitly listed
#   (f) the identity resolver is invoked exactly once per invocation, even
#       when several markers are present
#   (g) check-approval-sha on a PR whose only marker is from an untrusted
#       author reports the approval as missing/stale
#
# Run twice, once per provider (github via the gh stub, github-api via the
# curl/REST stub) -- #187 requires both readers to agree.
# Every test can fail: disabling markers.verify_authors' default-on
# inference causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

set_cfg() { printf '%s' "$1" > talos.pipeline.json; }

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1: github provider (gh CLI stub)
# ═══════════════════════════════════════════════════════════════════════════

mk_gh_approval() {  # <sha> <role> <author>
  printf '[{"body":"approval done\\n<!-- talos:approval sha=%s role=%s -->","author":{"login":"%s"}}]' \
    "$1" "$2" "$3"
}
mk_gh_attempt() {  # <stage> <count> <total> <author>
  printf '[{"body":"Talos attempt record\\n<!-- talos:attempt stage=%s count=%s total=%s -->","author":{"login":"%s"}}]' \
    "$1" "$2" "$3" "$4"
}

gh_check() {  # <head> <labels-json> <comments-json> [VAR=VAL...]
  local head="$1" labels="$2" comments="$3"; shift 3
  env "$@" STUB_PR_HEAD_SHA="$head" STUB_PR_LABELS_JSON="$labels" STUB_PR_COMMENTS_JSON="$comments" \
    bash "$VCS" check-approval-sha 9 2>&1
}
gh_read_attempt() {  # <comments-json> [VAR=VAL...]
  local comments="$1"; shift
  env "$@" STUB_ISSUE_COMMENTS_JSON="$comments" bash "$VCS" read-attempt 42 2>&1
}

# ── (a) unset config, current user resolves ───────────────────────────────
set_cfg '{}'
_c="$(mk_gh_approval "$HEAD_SHA" qa octocat)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (a): marker by the resolved current user is accepted"
assert_not_contains "$out" "talos:marker-authors-rejected" \
  "gh (a): accepted marker -> no rejection line"

_c="$(mk_gh_approval "$HEAD_SHA" qa mallory)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "talos:marker-authors-rejected authors=mallory" \
  "gh (a): marker by mallory rejected with one aggregated stderr line"
_n="$(printf '%s' "$out" | grep -c 'talos:marker-authors-rejected')"
assert_eq "1" "$_n" "gh (a): exactly one talos:marker-authors-rejected line"

# ── (g) rejected marker is reported as missing/stale, not silently ok ─────
assert_contains "$out" "no SHA marker" \
  "gh (g): mallory-only PR falls through to the missing-marker reason"
rc="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "gh (g): check-approval-sha exits 1 (fail-closed, not fail-open)"

# ── (b) trusted_authors: [alice] -- union with the current user ───────────
set_cfg '{"markers": {"trusted_authors": ["alice"]}}'
_c="$(mk_gh_approval "$HEAD_SHA" qa alice)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (b): explicitly-listed alice is accepted"

_c="$(mk_gh_approval "$HEAD_SHA" qa octocat)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (b): current user is ALSO accepted even though only alice is listed (union)"

# ── (c) verify_authors: false -- mallory accepted, no warning ─────────────
set_cfg '{"markers": {"verify_authors": false}}'
_c="$(mk_gh_approval "$HEAD_SHA" qa mallory)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (c): verify_authors=false accepts any author (mallory)"
assert_not_contains "$out" "talos:marker-authors-unverified" \
  "gh (c): verify_authors=false emits no fail-open warning"
assert_not_contains "$out" "talos:marker-authors-rejected" \
  "gh (c): verify_authors=false emits no rejection line"

# ── (d) identity lookup fails + no trusted_authors -> fail-open, unchanged ─
set_cfg '{}'
_c="$(mk_gh_approval "$HEAD_SHA" qa mallory)"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c")"  # no STUB_CURRENT_USER -> unresolved
assert_contains "$out" "talos:marker-authors-unverified reader=check-approval-sha" \
  "gh (d): unresolved identity + unconfigured list -> fail-open warning (unchanged)"
assert_contains "$out" "author check skipped" \
  "gh (d): fail-open warning text unchanged"
assert_contains "$out" "all approval labels are current" \
  "gh (d): fail-open still accepts the marker"

# ── (e) bot login rejected unless explicitly listed ────────────────────────
set_cfg '{}'
_c="$(mk_gh_approval "$HEAD_SHA" qa "ci[bot]")"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "talos:marker-authors-rejected authors=ci[bot]" \
  "gh (e): an unlisted bot login is rejected like any other untrusted author"

set_cfg '{"markers": {"trusted_authors": ["ci[bot]"]}}'
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (e): the same bot login is accepted once explicitly listed"

# ── (f) identity resolved exactly once per invocation, even with 5 markers ─
set_cfg '{}'
_c='[
  {"body":"<!-- talos:approval sha=1111111111111111111111111111111111111a role=qa -->","author":{"login":"mallory"}},
  {"body":"<!-- talos:approval sha=2222222222222222222222222222222222222a role=qa -->","author":{"login":"eve"}},
  {"body":"<!-- talos:approval sha=3333333333333333333333333333333333333a role=qa -->","author":{"login":"trent"}},
  {"body":"<!-- talos:approval sha=4444444444444444444444444444444444444a role=qa -->","author":{"login":"carol"}},
  {"body":"<!-- talos:approval sha='"$HEAD_SHA"' role=qa -->","author":{"login":"octocat"}}
]'
: > "$GH_LOG"
out="$(gh_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "gh (f): the trusted marker (5th, newest) still wins the scan"
_calls="$(grep -c 'api user --jq .login' "$GH_LOG")"
assert_eq "1" "$_calls" "gh (f): identity resolver invoked exactly once despite 5 markers"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2: github-api provider (REST / curl stub)
# ═══════════════════════════════════════════════════════════════════════════

TEST_TOKEN="test-secret-token-12345"
export GITHUB_TOKEN="$TEST_TOKEN"
export TALOS_RETRY_SLEEP_SCALE=0

set_cfg_api() {  # <markers-json-fragment, e.g. {"trusted_authors":["alice"]} or {}>
  printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "markers": %s}' "$1" > talos.pipeline.json
}

mk_rest_approval() {  # <sha> <role> <author>
  printf '[{"body":"<!-- talos:approval sha=%s role=%s -->","user":{"login":"%s"}}]' "$1" "$2" "$3"
}
mk_rest_attempt() {  # <stage> <count> <total> <author>
  printf '[{"body":"<!-- talos:attempt stage=%s count=%s total=%s -->","user":{"login":"%s"}}]' \
    "$1" "$2" "$3" "$4"
}

api_check() {  # <head> <labels-json> <comments-json> [VAR=VAL...]
  local head="$1" labels="$2" comments="$3"; shift 3
  : > "$CURL_QUEUE"
  printf '%s\n' \
    "{\"number\":9,\"head\":{\"sha\":\"$head\"},\"base\":{\"ref\":\"main\"},\"labels\":$labels}" \
    "$comments" \
    > "$CURL_QUEUE"
  env "$@" bash "$VCS" check-approval-sha 9 2>&1
}
api_read_attempt() {  # <comments-json> [VAR=VAL...]
  local comments="$1"; shift
  : > "$CURL_QUEUE"
  printf '%s\n' "$comments" > "$CURL_QUEUE"
  env "$@" bash "$VCS" read-attempt 42 2>&1
}

# ── (a) unset config, current user resolves ───────────────────────────────
set_cfg_api '{}'
_c="$(mk_rest_approval "$HEAD_SHA" qa octocat)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (a): marker by the resolved current user is accepted"

_c="$(mk_rest_approval "$HEAD_SHA" qa mallory)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "talos:marker-authors-rejected authors=mallory" \
  "github-api (a): marker by mallory rejected with one aggregated stderr line"

# ── (g) rejected marker is reported as missing/stale ───────────────────────
assert_contains "$out" "no SHA marker" \
  "github-api (g): mallory-only PR falls through to the missing-marker reason"
rc="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat >/dev/null 2>&1; echo $?)"
assert_eq "1" "$rc" "github-api (g): check-approval-sha exits 1 (fail-closed, not fail-open)"

# ── (b) trusted_authors: [alice] -- union with the current user ───────────
set_cfg_api '{"trusted_authors": ["alice"]}'
_c="$(mk_rest_approval "$HEAD_SHA" qa alice)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (b): explicitly-listed alice is accepted"

_c="$(mk_rest_approval "$HEAD_SHA" qa octocat)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (b): current user is ALSO accepted even though only alice is listed (union)"

# ── (c) verify_authors: false -- mallory accepted, no warning ─────────────
set_cfg_api '{"verify_authors": false}'
_c="$(mk_rest_approval "$HEAD_SHA" qa mallory)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (c): verify_authors=false accepts any author (mallory)"
assert_not_contains "$out" "talos:marker-authors-unverified" \
  "github-api (c): verify_authors=false emits no fail-open warning"
assert_not_contains "$out" "talos:marker-authors-rejected" \
  "github-api (c): verify_authors=false emits no rejection line"

# ── (d) identity lookup fails + no trusted_authors -> fail-open, unchanged ─
set_cfg_api '{}'
_c="$(mk_rest_approval "$HEAD_SHA" qa mallory)"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c")"  # no STUB_CURRENT_USER -> unresolved
assert_contains "$out" "talos:marker-authors-unverified reader=check-approval-sha" \
  "github-api (d): unresolved identity + unconfigured list -> fail-open warning (unchanged)"
assert_contains "$out" "author check skipped" \
  "github-api (d): fail-open warning text unchanged"
assert_contains "$out" "all approval labels are current" \
  "github-api (d): fail-open still accepts the marker"

# ── (e) bot login rejected unless explicitly listed ────────────────────────
set_cfg_api '{}'
_c="$(mk_rest_approval "$HEAD_SHA" qa "ci[bot]")"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "talos:marker-authors-rejected authors=ci[bot]" \
  "github-api (e): an unlisted bot login is rejected like any other untrusted author"

set_cfg_api '{"trusted_authors": ["ci[bot]"]}'
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (e): the same bot login is accepted once explicitly listed"

# ── (f) identity resolved exactly once per invocation, even with 5 markers ─
# NOTE: must stay a single line -- CURL_QUEUE treats each newline as a
# separate queued response, so an embedded newline here would desync the
# PR-object/comments-array queue pairing api_check relies on.
set_cfg_api '{}'
_c="[$(mk_rest_approval 1111111111111111111111111111111111111a qa mallory | sed 's/^\[//;s/\]$//'),$(mk_rest_approval 2222222222222222222222222222222222222a qa eve | sed 's/^\[//;s/\]$//'),$(mk_rest_approval 3333333333333333333333333333333333333a qa trent | sed 's/^\[//;s/\]$//'),$(mk_rest_approval 4444444444444444444444444444444444444a qa carol | sed 's/^\[//;s/\]$//'),$(mk_rest_approval "$HEAD_SHA" qa octocat | sed 's/^\[//;s/\]$//')]"
: > "$CURL_LOG"
out="$(api_check "$HEAD_SHA" '[{"name":"qa:pass"}]' "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "all approval labels are current" \
  "github-api (f): the trusted marker (5th, newest) still wins the scan"
_calls="$(grep -c 'https://api.github.com/user' "$CURL_LOG")"
assert_eq "1" "$_calls" "github-api (f): identity resolver invoked exactly once despite 5 markers"

# ── read-attempt filters authors too (not just check-approval-sha) ────────
set_cfg '{}'
_c="$(mk_gh_attempt developer 1 1 octocat)"
out="$(gh_read_attempt "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "stage=developer count=1 total=1" \
  "gh read-attempt: marker by the resolved current user is accepted"

_c="$(mk_gh_attempt developer 1 1 mallory)"
out="$(gh_read_attempt "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "stage= count=0 total=0" \
  "gh read-attempt: marker by mallory is rejected -> zero state"
assert_contains "$out" "talos:marker-authors-rejected authors=mallory" \
  "gh read-attempt: rejection reported on stderr"

set_cfg_api '{}'
_c="$(mk_rest_attempt developer 1 1 mallory)"
out="$(api_read_attempt "$_c" STUB_CURRENT_USER=octocat)"
assert_contains "$out" "stage= count=0 total=0" \
  "github-api read-attempt: marker by mallory is rejected -> zero state"
assert_contains "$out" "talos:marker-authors-rejected authors=mallory" \
  "github-api read-attempt: rejection reported on stderr"

finish
