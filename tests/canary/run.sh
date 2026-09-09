#!/usr/bin/env bash
# tests/canary/run.sh -- nightly real-API canary (roadmap 3.3).
#
# Drives a minimal end-to-end pipeline flow against a real (or, under
# tests/test-canary.sh, a local file:// stand-in) sandbox repository, for
# each provider in TALOS_CANARY_PROVIDERS (default "github github-api"):
#   create-issue -> label-issue -> view-issue --spec -> branch+commit+push ->
#   create-pr -> post-approval qa -> check-approval-sha -> pr-mergeable ->
#   check-pr-files -> cleanup
#
# Every step is driven through scripts/pipeline-vcs.sh -- the same verbs the
# real pipeline uses -- so schema drift in GitHub's REST responses or gh CLI
# output shows up here before it shows up in production. The ONLY direct `gh`
# calls in this file are in cleanup() and sweep_stale(): no pipeline-vcs.sh
# verb closes a PR or searches issues/PRs by title+age.
#
# Env:
#   TALOS_CANARY_REPO         owner/repo of the sandbox repo (required)
#   GH_TOKEN / TALOS_GITHUB_TOKEN
#                              token with issues/pull-requests/contents write
#                              on the sandbox repo (required; either name --
#                              matches whichever _ga_req in pipeline-vcs.sh's
#                              github-api adapter reads by default)
#   TALOS_CANARY_PROVIDERS    space-separated provider list to exercise
#                              (default: "github github-api"; test-only override)
#   TALOS_CANARY_CLONE_URL    override the git clone URL (test-only; defaults
#                              to https://github.com/$TALOS_CANARY_REPO.git)
#   TALOS_CANARY_BASE_BRANCH  override the branch new PRs target (test-only;
#                              defaults to the clone's checked-out branch)
#
# Prints one "PASS <step>" or "FAIL <step>" line per step; exits non-zero if
# any step failed. Every created issue/PR/branch is cleaned up on the way
# out, success or failure, via a single `trap cleanup EXIT`.
set -u

# CANARY_TITLE_PREFIX -- every issue/PR title this script creates starts
# with this (via RUN_ID, below). sweep_stale() anchors on it: `gh ... list
# --search "canary- in:title"` is free-text and would also match an
# unrelated issue that merely contains "canary" somewhere in its title, so
# the search result is only ever a pre-filter -- the actual close decision
# requires title.startswith(CANARY_TITLE_PREFIX), checked client-side.
CANARY_TITLE_PREFIX="canary-"
RUN_ID="${CANARY_TITLE_PREFIX}$(date -u +%Y%m%d%H%M%S)-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

TOKEN="${GH_TOKEN:-${TALOS_GITHUB_TOKEN:-}}"

# ── In-script guard (in addition to the workflow's job-level `if`) ──────────
# The job-level `if: vars.TALOS_CANARY_REPO != ''` only covers the repo
# variable -- secrets cannot be read in a job-level `if`. This guard covers
# both, and is what makes the missing-token case a clean, informative no-op
# (exit 0) instead of an opaque auth failure deep inside pipeline-vcs.sh.
if [ -z "${TALOS_CANARY_REPO:-}" ] || [ -z "$TOKEN" ]; then
  echo "talos:canary-skipped reason=missing-repo-or-token"
  exit 0
fi

export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-canary.XXXXXX")"
CLONE_URL="${TALOS_CANARY_CLONE_URL:-https://github.com/${TALOS_CANARY_REPO}.git}"
PROVIDERS="${TALOS_CANARY_PROVIDERS:-github github-api}"

# Route github.com clone/push through the token via gh's own git credential
# helper (no-op for a local/file:// clone URL, which is what
# tests/test-canary.sh uses, so gh is never invoked there). Deliberately
# NOT `git config url.insteadOf "https://x-access-token:$TOKEN@..."` --
# that puts the token in the `git config` argv, which is visible to any
# other process on the runner via `ps` and often lands in CI step logs.
# `gh auth setup-git` instead points git's credential.helper at
# `gh auth git-credential`, which reads the token from GH_TOKEN (already
# exported above) only when git actually asks for credentials.
case "$CLONE_URL" in
  https://github.com/*)
    gh auth setup-git >/dev/null 2>&1 || true
    ;;
esac
git config --global user.email "talos-canary@users.noreply.github.com"
git config --global user.name "talos-canary-bot"
git config --global init.defaultBranch main

FAILED=0
CUR_ISSUE=""; CUR_PR=""; CUR_BRANCH=""; CUR_REPO_DIR=""; CUR_CFG=""

# step <name> <cmd...> -- run a command, print PASS/FAIL, set FAILED on failure.
step() {
  local name="$1"; shift
  # Redirect only the wrapped command's stdout -- NOT this function's own
  # PASS/FAIL line -- so a call site like `step "x" bash foo.sh >/dev/null`
  # only ever silences foo.sh's output, never the progress line itself.
  if "$@" >/dev/null; then
    printf 'PASS %s\n' "$name"
    return 0
  fi
  printf 'FAIL %s\n' "$name"
  FAILED=1
  return 1
}

# cleanup -- close whatever CUR_* resources are currently set, best-effort,
# then clear them so a later invocation (the EXIT trap firing after a
# provider iteration already cleaned up successfully) is a no-op. Idempotent
# by construction: nothing to do once CUR_REPO_DIR is empty.
cleanup() {
  local dir="$CUR_REPO_DIR" pr="$CUR_PR" issue="$CUR_ISSUE" branch="$CUR_BRANCH" cfg="$CUR_CFG"
  CUR_REPO_DIR=""; CUR_PR=""; CUR_ISSUE=""; CUR_BRANCH=""; CUR_CFG=""
  [ -z "$dir" ] && return 0
  (
    cd "$dir" 2>/dev/null || exit 0
    if [ -n "$pr" ]; then
      # No close-pr verb exists in pipeline-vcs.sh -- this is the one
      # sanctioned direct `gh` call outside sweep_stale (see file header).
      gh pr close "$pr" --repo "$TALOS_CANARY_REPO" --delete-branch >/dev/null 2>&1 || true
    elif [ -n "$branch" ]; then
      git push --quiet origin --delete "$branch" >/dev/null 2>&1 || true
    fi
    if [ -n "$issue" ] && [ -n "$cfg" ]; then
      PIPELINE_CONFIG="$cfg" bash "$VCS" close-issue "$issue" \
        "canary: automated cleanup ($RUN_ID)" >/dev/null 2>&1 || true
    fi
  )
}
trap cleanup EXIT

# sweep_stale -- best-effort: close any canary-* issue/PR left over from an
# aborted run more than a day old. No pipeline-vcs.sh verb searches by title
# pattern + age, so this is direct `gh` (the other sanctioned exception).
# Never fails the run: every call is best-effort.
sweep_stale() {
  local cutoff
  cutoff="$(python3 -c 'import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null)" || return 0

  # Best-effort: also restrict closes to items authored by this token's own
  # login, when that's cheaply available (one extra `gh api user` call,
  # reused for both list calls below). Never fatal -- an unresolved login
  # (empty) just means the login check is skipped, same fail-open posture
  # as _vcs_shared_current_user in pipeline-vcs.sh; the anchored-title check
  # in _stale_numbers is what actually guards against closing anything that
  # isn't ours.
  local login
  login="$(gh api user --jq .login 2>/dev/null)" || login=""

  # _stale_numbers -- reads a `gh ... list --json number,title,createdAt,author`
  # array on stdin, prints the number of every item that is ALL of:
  #   - older than $cutoff
  #   - title starts with $CANARY_TITLE_PREFIX (anchored -- the --search
  #     "canary- in:title" above is free-text and only a pre-filter; an
  #     unrelated issue titled e.g. "my canary bird" would also match it)
  #   - authored by $login, when $login resolved to a non-empty value
  _stale_numbers() {
    CUTOFF="$cutoff" PREFIX="$CANARY_TITLE_PREFIX" LOGIN="$login" python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
prefix = os.environ['PREFIX']
login = os.environ.get('LOGIN', '')
for i in items:
    if not i.get('title', '').startswith(prefix):
        continue
    if i.get('createdAt', '') >= os.environ['CUTOFF']:
        continue
    if login and i.get('author', {}).get('login', '') != login:
        continue
    print(i['number'])
" 2>/dev/null
  }

  local raw
  raw="$(gh issue list --repo "$TALOS_CANARY_REPO" --search "canary- in:title" --state open \
    --json number,title,createdAt,author --limit 100 2>/dev/null)"
  printf '%s' "${raw:-[]}" | _stale_numbers | while IFS= read -r n; do
    [ -n "$n" ] && gh issue close "$n" --repo "$TALOS_CANARY_REPO" >/dev/null 2>&1
  done

  raw="$(gh pr list --repo "$TALOS_CANARY_REPO" --search "canary- in:title" --state open \
    --json number,title,createdAt,author --limit 100 2>/dev/null)"
  printf '%s' "${raw:-[]}" | _stale_numbers | while IFS= read -r n; do
    [ -n "$n" ] && gh pr close "$n" --repo "$TALOS_CANARY_REPO" --delete-branch >/dev/null 2>&1
  done
  return 0
}
step "sweep-stale-leftovers" sweep_stale

# run_provider <provider> -- the full sequence for one provider. Returns 1
# (and leaves CUR_* pointing at whatever was created) the moment any step
# fails; the caller exits, and the EXIT trap cleans up via those CUR_* vars.
run_provider() {
  local PROVIDER="$1"
  local REPO_DIR="$WORKDIR/$PROVIDER"

  if ! git clone --quiet "$CLONE_URL" "$REPO_DIR" 2>/dev/null; then
    printf 'FAIL clone[%s]\n' "$PROVIDER"
    FAILED=1
    return 1
  fi
  CUR_REPO_DIR="$REPO_DIR"
  cd "$REPO_DIR" || { printf 'FAIL clone[%s] (cd failed)\n' "$PROVIDER"; FAILED=1; return 1; }
  printf 'PASS clone[%s]\n' "$PROVIDER"

  local BASE_BRANCH
  BASE_BRANCH="${TALOS_CANARY_BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

  local CFG="$WORKDIR/$PROVIDER.config.json"
  PROVIDER="$PROVIDER" REPO="$TALOS_CANARY_REPO" BASE="$BASE_BRANCH" CFG_PATH="$CFG" python3 -c "
import json, os
json.dump({'vcs': {'provider': os.environ['PROVIDER'], 'repo': os.environ['REPO']},
           'base_branch': os.environ['BASE'],
           'merge': {'method': 'squash'}}, open(os.environ['CFG_PATH'], 'w'))
"
  CUR_CFG="$CFG"
  export PIPELINE_CONFIG="$CFG"

  # ── create-issue ────────────────────────────────────────────────────────
  local TITLE="$RUN_ID $PROVIDER: canary smoke test"
  printf '%s\n\ncanary run %s (%s)\n' "$TITLE" "$RUN_ID" "$PROVIDER" > issue-body.md
  local ISSUE_URL ISSUE_N
  ISSUE_URL="$(bash "$VCS" create-issue "$TITLE" issue-body.md)"
  ISSUE_N="$(printf '%s' "$ISSUE_URL" | grep -oE '[0-9]+$')"
  if [ -z "$ISSUE_N" ]; then
    printf 'FAIL create-issue[%s]\n' "$PROVIDER"
    FAILED=1
    return 1
  fi
  printf 'PASS create-issue[%s] issue=#%s\n' "$PROVIDER" "$ISSUE_N"
  CUR_ISSUE="$ISSUE_N"

  step "label-issue[$PROVIDER]" bash "$VCS" label-issue "$ISSUE_N" --add pipeline:ready || return 1
  step "view-issue-spec[$PROVIDER]" bash "$VCS" view-issue "$ISSUE_N" --spec || return 1

  # ── branch + trivial commit + push ─────────────────────────────────────
  local BRANCH="canary/$RUN_ID-$PROVIDER"
  if ! git checkout -b "$BRANCH" >/dev/null 2>&1; then
    printf 'FAIL create-branch[%s]\n' "$PROVIDER"
    FAILED=1
    return 1
  fi
  CUR_BRANCH="$BRANCH"
  printf 'canary run %s (%s) at %s\n' "$RUN_ID" "$PROVIDER" "$(date -u +%FT%TZ)" >> CANARY.md
  git add CANARY.md
  if ! git commit --quiet -m "chore: canary run $RUN_ID ($PROVIDER)" \
      || ! git push --quiet origin "$BRANCH" 2>/dev/null; then
    printf 'FAIL create-branch[%s] (commit/push failed)\n' "$PROVIDER"
    FAILED=1
    return 1
  fi
  printf 'PASS create-branch[%s] branch=%s\n' "$PROVIDER" "$BRANCH"

  # ── create-pr ────────────────────────────────────────────────────────────
  local PR_TITLE="$RUN_ID $PROVIDER: trivial canary change"
  printf 'Closes #%s\n\ncanary run %s (%s)\n' "$ISSUE_N" "$RUN_ID" "$PROVIDER" > pr-body.md
  local PR_URL PR_N
  PR_URL="$(bash "$VCS" create-pr "$BRANCH" "$PR_TITLE" pr-body.md)"
  PR_N="$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$')"
  if [ -z "$PR_N" ]; then
    printf 'FAIL create-pr[%s]\n' "$PROVIDER"
    FAILED=1
    return 1
  fi
  printf 'PASS create-pr[%s] pr=#%s\n' "$PROVIDER" "$PR_N"
  CUR_PR="$PR_N"

  step "post-approval[$PROVIDER]"      bash "$VCS" post-approval "$PR_N" qa || return 1
  step "check-approval-sha[$PROVIDER]" bash "$VCS" check-approval-sha "$PR_N" || return 1
  step "pr-mergeable[$PROVIDER]"       bash "$VCS" pr-mergeable "$PR_N" || return 1
  step "check-pr-files[$PROVIDER]"     bash "$VCS" check-pr-files "$PR_N" || return 1

  cleanup
  return 0
}

for PROVIDER in $PROVIDERS; do
  run_provider "$PROVIDER" || exit 1
done

exit 0
