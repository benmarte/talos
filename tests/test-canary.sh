#!/usr/bin/env bash
# Regression tests for tests/canary/run.sh (#188) -- runs the real script
# under the existing gh/curl stubs (tests/stubs/), never the real network.
#
# Covers:
#   1. Missing TALOS_CANARY_REPO/token -> skip notice, exit 0.
#   2. Happy path (both providers, github + github-api) -> exit 0, every step
#      PASS, cleanup runs for both, and the curl queue is consumed exactly
#      (a leftover or missing line means the call-count assumptions below
#      have drifted from pipeline-vcs.sh's actual github-api call sequence).
#   3. sweep_stale only closes issues/PRs whose title *starts with* the
#      canary prefix -- an unrelated old item that merely contains "canary"
#      in its title (matched by the free-text `--search`) must survive.
#   4. A failing step -> exit non-zero, AND cleanup still runs (close-pr /
#      close-issue calls land in the gh stub log).
#   5. canary.yml workflow structure.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

RUN="$TALOS_ROOT/tests/canary/run.sh"

# ── Local sandbox "GitHub" repo (bare + one commit on main) ──────────────────
# tests/canary/run.sh clones TALOS_CANARY_CLONE_URL with plain `git`, so a
# local bare repo stands in for the real sandbox repo -- no network involved,
# and branch/commit/push are exercised for real.
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$SEED" 2>/dev/null   # bare repo is still empty at this point -- expected warning
git -C "$SEED" checkout -q -b main
echo "# canary sandbox" > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" -c user.email=seed@talos.invalid -c user.name=seed commit -q -m "init"
git -C "$SEED" push -q origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
rm -rf "$SEED"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Missing repo/token -> clean skip, exit 0, no clone attempted.
# ─────────────────────────────────────────────────────────────────────────────
unset TALOS_CANARY_REPO GH_TOKEN TALOS_GITHUB_TOKEN GITHUB_TOKEN

out="$(bash "$RUN" 2>&1)"; rc=$?
assert_eq "0" "$rc" "missing repo/token: exits 0"
assert_contains "$out" "talos:canary-skipped" "missing repo/token: prints skip notice"

export TALOS_CANARY_REPO="acme/widget-canary"
out="$(bash "$RUN" 2>&1)"; rc=$?
assert_eq "0" "$rc" "repo set, token missing: still exits 0"
assert_contains "$out" "talos:canary-skipped" "repo set, token missing: prints skip notice"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Happy path -- both providers.
# ─────────────────────────────────────────────────────────────────────────────
export TALOS_CANARY_CLONE_URL="$ORIGIN"
export GH_TOKEN="test-canary-token"
export TALOS_RETRY_SLEEP_SCALE=0   # no real backoff sleeps if a retry ever fires

# github provider (gh CLI stub -- pattern-matched, not order-dependent).
export STUB_NEW_ISSUE_NUMBER=301
export STUB_NEW_PR_NUMBER=302
SHA_GH="cafebabecafebabecafebabecafebabecafebabe"
export STUB_PR_HEAD_SHA="$SHA_GH"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
export STUB_PR_COMMENTS_JSON="[{\"body\":\"<!-- talos:approval sha=${SHA_GH} role=qa -->\"}]"

# github-api provider (curl stub -- a strict FIFO; every call below must be
# queued in the exact order pipeline-vcs.sh's _github_api arms issue them:
# create-issue(1) label-issue(GET+PUT) view-issue--spec(meta+comments)
# create-pr(1) post-approval(pr-head, dup-check comments, comment-pr state
# check, comment-pr POST, label-pr GET+PUT) check-approval-sha(PR+comments)
# pr-mergeable(1) check-pr-files(1) cleanup-close-issue(comment+PATCH).
SHA_API="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
printf '%s\n' \
  '{"number":401,"html_url":"https://github.com/acme/widget-canary/issues/401"}' \
  '[]' \
  '{}' \
  '{"title":"canary","body":"canary run body","labels":[]}' \
  '[]' \
  '{"html_url":"https://github.com/acme/widget-canary/pull/402"}' \
  "{\"head\":{\"sha\":\"${SHA_API}\"}}" \
  '[]' \
  '{"state":"open","merged_at":null}' \
  '{"id":900,"html_url":"https://github.com/acme/widget-canary/pull/402#issuecomment-900"}' \
  '[]' \
  '{}' \
  "{\"number\":402,\"head\":{\"sha\":\"${SHA_API}\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"<!-- talos:approval sha=${SHA_API} role=qa -->\",\"user\":{\"login\":\"bot\"}}]" \
  '{"number":402,"mergeable":true}' \
  '[{"filename":"CANARY.md","status":"added"}]' \
  '{"html_url":"https://github.com/acme/widget-canary/issues/401#issuecomment-901"}' \
  '{"state":"closed"}' \
  > "$CURL_QUEUE"

out="$(bash "$RUN" 2>&1)"; rc=$?
assert_eq "0" "$rc" "happy path: exits 0"
assert_not_contains "$out" "FAIL " "happy path: no FAIL lines"
assert_contains "$out" "PASS create-issue[github] issue=#301" "happy path: github create-issue"
assert_contains "$out" "PASS create-pr[github] pr=#302" "happy path: github create-pr"
assert_contains "$out" "PASS check-pr-files[github]" "happy path: github check-pr-files"
assert_contains "$out" "PASS create-issue[github-api] issue=#401" "happy path: github-api create-issue"
assert_contains "$out" "PASS create-pr[github-api] pr=#402" "happy path: github-api create-pr"
assert_contains "$out" "PASS check-pr-files[github-api]" "happy path: github-api check-pr-files"

gh_log="$(cat "$GH_LOG")"
assert_contains "$gh_log" "pr close 302" "happy path: github cleanup closes the PR"
assert_contains "$gh_log" "issue close 301" "happy path: github cleanup closes the issue"

curl_leftover="$(cat "$CURL_QUEUE")"
assert_eq "" "$curl_leftover" "happy path: curl queue consumed exactly (github-api call count matches)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. sweep_stale anchors on the canary title prefix (#188 review finding):
#    `gh ... list --search "canary- in:title"` is free-text, so an unrelated
#    old issue/PR that merely *contains* "canary" in its title must survive
#    the sweep -- only a title that *starts with* "canary-" may be closed.
# ─────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
export TALOS_CANARY_PROVIDERS="github"
export STUB_NEW_ISSUE_NUMBER=601
export STUB_NEW_PR_NUMBER=602
OLD_CREATED="2000-01-01T00:00:00Z"
export STUB_CANARY_ISSUE_LIST_STALE="[{\"number\":9001,\"title\":\"my canary bird\",\"createdAt\":\"$OLD_CREATED\",\"author\":{\"login\":\"someone-else\"}},{\"number\":9002,\"title\":\"canary-19990101000000-1 github: canary smoke test\",\"createdAt\":\"$OLD_CREATED\",\"author\":{\"login\":\"someone-else\"}}]"
export STUB_CANARY_PR_LIST_STALE="[{\"number\":9101,\"title\":\"my canary bird PR\",\"createdAt\":\"$OLD_CREATED\",\"author\":{\"login\":\"someone-else\"}},{\"number\":9102,\"title\":\"canary-19990101000000-1 github: trivial canary change\",\"createdAt\":\"$OLD_CREATED\",\"author\":{\"login\":\"someone-else\"}}]"

out="$(bash "$RUN" 2>&1)"; rc=$?
assert_eq "0" "$rc" "stale sweep: run still exits 0"
assert_contains "$out" "PASS sweep-stale-leftovers" "stale sweep: step passes"

gh_log="$(cat "$GH_LOG")"
assert_contains "$gh_log" "issue close 9002" "stale sweep: closes the anchored 'canary-...' issue"
assert_not_contains "$gh_log" "issue close 9001" "stale sweep: leaves the unrelated 'my canary bird' issue alone"
assert_contains "$gh_log" "pr close 9102 --repo acme/widget-canary --delete-branch" "stale sweep: closes the anchored 'canary-...' PR"
assert_not_contains "$gh_log" "pr close 9101" "stale sweep: leaves the unrelated 'my canary bird' PR alone"

unset STUB_CANARY_ISSUE_LIST_STALE STUB_CANARY_PR_LIST_STALE TALOS_CANARY_PROVIDERS

# ─────────────────────────────────────────────────────────────────────────────
# 4. A failing step still runs cleanup, and the run exits non-zero.
# ─────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
export TALOS_CANARY_PROVIDERS="github"
export STUB_NEW_ISSUE_NUMBER=501
export STUB_NEW_PR_NUMBER=502
export STUB_GH_API_FAIL="pr-files"   # check-pr-files is the only step that hits this endpoint

out="$(bash "$RUN" 2>&1)"; rc=$?
assert_eq "1" "$rc" "failing step: exits non-zero"
assert_contains "$out" "FAIL check-pr-files[github]" "failing step: names the failed step"
assert_not_contains "$out" "PASS check-pr-files[github]" "failing step: check-pr-files did not report PASS"

gh_log="$(cat "$GH_LOG")"
assert_contains "$gh_log" "pr close 502" "failing step: cleanup still closes the PR"
assert_contains "$gh_log" "issue close 501" "failing step: cleanup still closes the issue"

unset STUB_GH_API_FAIL TALOS_CANARY_PROVIDERS

# ─────────────────────────────────────────────────────────────────────────────
# 5. Workflow YAML structure -- never calls the real API, PyYAML optional.
# ─────────────────────────────────────────────────────────────────────────────
CANARY_YML="$TALOS_ROOT/.github/workflows/canary.yml"
assert_file_exists "$CANARY_YML" "canary.yml exists"

if python3 -c "import yaml" 2>/dev/null; then
  yaml_out="$(python3 -c "
import yaml
with open('$CANARY_YML') as f:
    doc = yaml.safe_load(f)
# PyYAML 1.1 parses the bare 'on:' key as the boolean True -- handle both.
triggers = doc.get('on', doc.get(True, {})) or {}
jobs = doc.get('jobs', {}) or {}
ok = (
    'schedule' in triggers
    and 'workflow_dispatch' in triggers
    and 'base-currency' in jobs
    and 'real-api' in jobs
    and 'run-tests.sh' in str(jobs['base-currency'])
    and 'tests/canary/run.sh' in str(jobs['real-api'])
)
print('OK' if ok else 'STRUCTURE_MISMATCH')
" 2>&1)"
  assert_eq "OK" "$yaml_out" "canary.yml: PyYAML structural check (schedule + workflow_dispatch triggers, both jobs present)"
else
  echo "  skip: PyYAML not installed -- falling back to a structural grep"
  yml_content="$(cat "$CANARY_YML")"
  assert_contains "$yml_content" "schedule:"          "canary.yml: has a schedule trigger"
  assert_contains "$yml_content" "workflow_dispatch:" "canary.yml: has a workflow_dispatch trigger"
  assert_contains "$yml_content" "base-currency:"     "canary.yml: has a base-currency job"
  assert_contains "$yml_content" "real-api:"           "canary.yml: has a real-api job"
  assert_contains "$yml_content" "tests/canary/run.sh" "canary.yml: real-api job runs tests/canary/run.sh"
fi

finish
