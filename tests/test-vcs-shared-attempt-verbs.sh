#!/usr/bin/env bash
# test-vcs-shared-attempt-verbs.sh -- check-attempt, read-attempt,
# check-approval-sha and record-attempt answer the same on github, gitlab and
# azure (#1013). The three provider arms of each verb share one helper each;
# this file pins what a caller sees (exit code, output) per provider so the
# refactor cannot change an answer. Uses the tests/stubs gh, glab and az stubs;
# no credentials needed. Tests are labelled with the spec's criterion id.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"
_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PROVIDERS="github gitlab azure"

# use_provider <p> -- config, remote and the current-user login for <p>.
use_provider() {
  local _bot="bot"
  case "$1" in
    azure) _bot="bot@acme.com" ;;
  esac
  case "$1" in
    github) printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "markers": {"trusted_authors": ["bot"]}, "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}' > talos.pipeline.json ;;
    gitlab) printf '%s\n' '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "markers": {"trusted_authors": ["bot"]}, "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}' > talos.pipeline.json ;;
    azure)  printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "markers": {"trusted_authors": ["bot@acme.com"]}, "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}' > talos.pipeline.json ;;
  esac
  if [ "$1" = gitlab ]; then
    git remote set-url origin git@gitlab.com:acme/widget.git 2>/dev/null || git remote add origin git@gitlab.com:acme/widget.git
  elif [ -n "$_ORIGIN" ]; then
    git remote set-url origin "$_ORIGIN"
  fi
  export STUB_CURRENT_USER="$_bot"
}

# trusted_login <p> / outsider_login <p> -- the marker author's login.
trusted_login() { [ "$1" = azure ] && echo "bot@acme.com" || echo "bot"; }
outsider_login() { [ "$1" = azure ] && echo "mallory@acme.com" || echo "mallory"; }

_att_body() {  # <count> <total> -- the attempt marker comment text
  printf 'Talos attempt record\\n<!-- talos:attempt stage=developer count=%s total=%s -->' "$1" "$2"
}
# attempt_env <p> <author:count:total>... -- export the provider stub's issue
# comments (oldest first), each carrying one attempt marker.
attempt_env() {
  local _p="$1" _i=0 _e _a _c _t _out=""; shift
  for _e in "$@"; do
    _a="${_e%%:*}"; _c="${_e#*:}"; _t="${_c#*:}"; _c="${_c%%:*}"; _i=$((_i + 1))
    case "$_p" in
      github) _out="$_out${_out:+,}{\"id\":$_i,\"user\":{\"login\":\"$_a\"},\"body\":\"$(_att_body "$_c" "$_t")\"}" ;;
      gitlab) _out="$_out${_out:+,}{\"id\":$_i,\"body\":\"$(_att_body "$_c" "$_t")\",\"system\":false,\"author\":{\"username\":\"$_a\"},\"created_at\":\"2026-10-16T00:00:0${_i}Z\"}" ;;
      azure)  _out="$_out${_out:+,}{\"id\":$_i,\"text\":\"$(_att_body "$_c" "$_t")\",\"createdBy\":{\"displayName\":\"Some One\",\"uniqueName\":\"$_a\"},\"createdDate\":\"2026-10-16T00:00:0${_i}Z\"}" ;;
    esac
  done
  unset STUB_GH_COMMENTS_RAW STUB_GITLAB_ISSUE_NOTES STUB_AZURE_WI_COMMENTS
  case "$_p" in
    github) export STUB_GH_COMMENTS_RAW="[$_out]" ;;
    gitlab) export STUB_GITLAB_ISSUE_NOTES="[$_out]" ;;
    azure)  export STUB_AZURE_WI_COMMENTS="{\"comments\":[$_out]}" ;;
  esac
}

# approval_env <p> <label|-> <author> <sha> -- export a PR (head HEAD_SHA)
# carrying <label> (or none for "-") and one qa approval marker at <sha>
# from <author> ("-" for no marker).
approval_env() {
  local _p="$1" _label="$2" _author="$3" _sha="$4" _lbl="" _mk=""
  unset STUB_GH_COMMENTS_RAW STUB_PR_HEAD_SHA STUB_PR_LABELS_JSON STUB_PR_COMMENTS_JSON \
    STUB_GITLAB_MR_VIEW STUB_GITLAB_MR_NOTES STUB_AZURE_PR_9 STUB_AZURE_PR_LABELS STUB_AZURE_PR_THREADS
  case "$_p" in
    github)
      [ "$_label" = "-" ] || _lbl="{\"name\":\"$_label\"}"
      [ "$_author" = "-" ] || _mk="{\"body\":\"approved\\n<!-- talos:approval sha=$_sha role=qa -->\",\"author\":{\"login\":\"$_author\"}}"
      export STUB_PR_HEAD_SHA="$HEAD_SHA" STUB_PR_LABELS_JSON="[$_lbl]" STUB_PR_COMMENTS_JSON="[$_mk]" ;;
    gitlab)
      [ "$_label" = "-" ] || _lbl="\"$_label\""
      [ "$_author" = "-" ] || _mk="{\"id\":1,\"body\":\"approved\\n<!-- talos:approval sha=$_sha role=qa -->\",\"system\":false,\"author\":{\"username\":\"$_author\"},\"created_at\":\"2026-10-16T00:00:00Z\"}"
      export STUB_GITLAB_MR_VIEW="{\"iid\":9,\"state\":\"opened\",\"sha\":\"$HEAD_SHA\",\"target_branch\":\"main\",\"labels\":[$_lbl]}" \
        STUB_GITLAB_MR_NOTES="[$_mk]" ;;
    azure)
      [ "$_label" = "-" ] || _lbl="{\"id\":\"1\",\"name\":\"$_label\"}"
      [ "$_author" = "-" ] || _mk="{\"id\":1,\"comments\":[{\"id\":1,\"content\":\"approved\\n<!-- talos:approval sha=$_sha role=qa -->\",\"commentType\":\"text\",\"author\":{\"displayName\":\"Some One\",\"uniqueName\":\"$_author\"},\"publishedDate\":\"2026-10-15T00:00:00Z\"}]}"
      export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"status\":\"active\",\"targetRefName\":\"refs/heads/main\",\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD_SHA\"},\"labels\":null}" \
        STUB_AZURE_PR_LABELS="{\"count\":1,\"value\":[$_lbl]}" STUB_AZURE_PR_THREADS="{\"value\":[$_mk]}" ;;
  esac
}

for _p in $PROVIDERS; do
  use_provider "$_p"
  _bot="$(trusted_login "$_p")"; _out_login="$(outsider_login "$_p")"

  # ── AC1: check-attempt ─────────────────────────────────────────────────────
  attempt_env "$_p" "$_bot:1:2"
  out="$(bash "$VCS" check-attempt 5 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC1 $_p check-attempt under the limits exits 0"
  assert_eq "pipeline-vcs: check-attempt: ok (stage=developer count=1 total=2; max_stage=3 max_total=10)" "$out" \
    "AC1 $_p check-attempt under the limits reports the counts"

  attempt_env "$_p" "$_bot:3:4"
  out="$(bash "$VCS" check-attempt 5 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC1 $_p check-attempt at the per-stage limit exits 1"
  assert_eq "pipeline-vcs: check-attempt: BLOCKED — developer consecutive attempts (3) >= max_fix_attempts (3)" "$out" \
    "AC1 $_p check-attempt at the per-stage limit says BLOCKED"

  attempt_env "$_p" "$_bot:1:10"
  out="$(bash "$VCS" check-attempt 5 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC1 $_p check-attempt at the total limit exits 1"
  assert_eq "pipeline-vcs: check-attempt: BLOCKED — total dispatches (10) >= max_total_dispatches (10)" "$out" \
    "AC1 $_p check-attempt at the total limit says BLOCKED"

  attempt_env "$_p" "$_out_login:3:10"
  out="$(bash "$VCS" check-attempt 5 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC1 $_p check-attempt ignores an untrusted author's marker (exit 0)"
  assert_contains "$out" "check-attempt: ok (stage= count=0 total=0;" "AC1 $_p check-attempt counts none of an untrusted author's attempts"

  bash "$VCS" check-attempt abc >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC1 $_p check-attempt with a non-numeric id exits 1"
  bash "$VCS" check-attempt >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC1 $_p check-attempt with no id exits 1"
  out="$(bash "$VCS" --dry-run check-attempt 5 2>&1)"; rc=$?
  assert_eq "0 [dry-run] check-attempt 5: compare current attempt state against configured ceilings" "$rc $out" \
    "AC1 $_p check-attempt --dry-run reads nothing"

  # ── AC2: read-attempt ──────────────────────────────────────────────────────
  attempt_env "$_p" "$_bot:1:2" "$_bot:2:5"
  out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
  assert_eq "0 stage=developer count=2 total=5" "$rc $out" "AC2 $_p read-attempt reads the newest trusted marker"
  attempt_env "$_p" "$_bot:1:2" "$_out_login:3:9"
  out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
  assert_eq "0 stage=developer count=1 total=2" "$rc $out" "AC2 $_p read-attempt ignores a newer untrusted author's marker"
  err="$(bash "$VCS" read-attempt 5 2>&1 >/dev/null)"
  assert_contains "$err" "talos:marker-authors-rejected authors=$_out_login" "AC2 $_p read-attempt names the rejected author"
  attempt_env "$_p" "$_out_login:3:9"
  out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
  assert_eq "0 stage= count=0 total=0" "$rc $out" "AC2 $_p read-attempt counts nothing from an untrusted author alone"
  attempt_env "$_p"
  out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
  assert_eq "0 stage= count=0 total=0" "$rc $out" "AC2 $_p read-attempt with no marker reads zero"
  bash "$VCS" read-attempt abc >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC2 $_p read-attempt with a non-numeric id exits 1"
  bash "$VCS" read-attempt >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC2 $_p read-attempt with no id exits 1"

  # ── AC3: check-approval-sha ────────────────────────────────────────────────
  approval_env "$_p" qa:pass "$_bot" "$HEAD_SHA"
  out="$(bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC3 $_p a fresh approval exits 0"
  assert_contains "$out" "check-approval-sha: all approval labels are current" "AC3 $_p a fresh approval reports current"
  approval_env "$_p" qa:pass "$_bot" "$OLD_SHA"
  out="$(bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC3 $_p a stale approval exits 1"
  assert_contains "$out" "stale role=qa label=qa:pass" "AC3 $_p a stale approval names the role and label"
  approval_env "$_p" qa:pass - "$HEAD_SHA"
  out="$(bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC3 $_p a missing approval marker exits 1"
  assert_contains "$out" "stale role=qa label=qa:pass" "AC3 $_p a missing approval marker names the role and label"
  approval_env "$_p" qa:pass "$_out_login" "$HEAD_SHA"
  bash "$VCS" check-approval-sha 9 --stale-list >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC3 $_p an untrusted author's approval marker does not count"
  approval_env "$_p" - - "$HEAD_SHA"
  out="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC3 $_p no approval label exits 0"
  assert_contains "$out" "no approval labels" "AC3 $_p no approval label says so"
  approval_env "$_p" - "$_bot" "$HEAD_SHA"
  out="$(bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC3 $_p --evidence-list exits 0"
  assert_contains "$out" "evidence role=qa label=qa:pass state=lost" "AC3 $_p --evidence-list reports a lost label"
  approval_env "$_p" qa:pass "$_bot" "$HEAD_SHA"
  bash "$VCS" check-approval-sha abc >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "AC3 $_p check-approval-sha with a non-numeric id exits 1"
  out="$(bash "$VCS" --dry-run check-approval-sha 9 2>&1)"; rc=$?
  assert_eq "0 [dry-run] check-approval-sha 9: verify all approval labels match current head SHA" "$rc $out" \
    "AC3 $_p check-approval-sha --dry-run reads nothing"
  # A fetch that fails is an exit 1 naming the fetch, not an answer.
  case "$_p" in
    github) _failenv="STUB_PR_VIEW_FAIL=1" ;;
    gitlab) _failenv="STUB_GITLAB_MR_VIEW_FAIL=1" ;;
    azure)  _failenv="STUB_AZURE_PR_SHOW_FAIL=1" ;;
  esac
  if [ "$_p" != github ]; then
    out="$(env "$_failenv" bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
    assert_eq "1" "$rc" "AC3 $_p an unreadable PR exits 1"
    assert_contains "$out" "could not fetch PR #9 data" "AC3 $_p an unreadable PR names the fetch"
  fi

  # ── AC4: record-attempt refusals ───────────────────────────────────────────
  out="$(bash "$VCS" record-attempt 5 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC4 $_p record-attempt with no stage exits 1"
  assert_eq "pipeline-vcs: record-attempt: missing stage argument" "$out" "AC4 $_p record-attempt with no stage says so"
  out="$(bash "$VCS" record-attempt 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC4 $_p record-attempt with no number exits 1"
  assert_eq "pipeline-vcs: record-attempt: missing issue number" "$out" "AC4 $_p record-attempt with no number says so"
  out="$(bash "$VCS" record-attempt 5 'bad/stage' 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC4 $_p record-attempt with a bad stage name exits 1"
  assert_eq "pipeline-vcs: record-attempt: stage may only use letters, digits, '.', '_' and '-', got 'bad/stage'" "$out" \
    "AC4 $_p record-attempt with a bad stage name names the rule"
done

use_provider gitlab
bash "$VCS" record-attempt abc developer >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC4 gitlab record-attempt with a non-numeric id exits 1"
use_provider azure
bash "$VCS" record-attempt abc developer >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC4 azure record-attempt with a non-numeric id exits 1"

finish
