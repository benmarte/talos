#!/usr/bin/env bash
# pipeline-vcs.sh — VCS provider adapter for Talos.
#
# Provides a uniform verb interface over GitHub, GitLab, Azure DevOps, or a
# local markdown file (plan.md) so orchestrator and subagent prompts never
# contain provider-specific CLI calls.
#
# Usage: pipeline-vcs.sh [--dry-run] <verb> [args...]
#
# Verbs:
#   list-issues                               List open issues / work items
#   view-issue <n>                            View issue details
#   comment-issue <n> <body>                  Post comment on issue <n>
#   close-issue <n> <body>                    Close issue with a comment
#   label-issue <n> [--add <l>] [--remove <l>]  Add/remove labels
#   create-pr <branch> <title> <body-file>    Open a pull / merge request
#   view-pr <n|branch>                        View PR details
#   list-prs                                  List open PRs
#   diff-pr <n>                               Show PR diff
#   checkout-pr <n>                           Check out PR branch locally
#   approve-pr <n> <body>                     Approve a PR with a comment
#   label-pr <n> [--add <l>] [--remove <l>]   Add/remove labels on PR
#   pr-checks <n>                             Show CI check status
#   merge-pr <n>                              Merge the PR
#   comment-pr <n> <body>                     Post comment on PR <n>
#   find-pr <issue-n> [state]                 Find PRs for an issue (branch has
#                                             issue-<n> or title/body has #<n>).
#                                             state: open (default) | merged | all
#   check-pr-files <n>                        Exit 1 if the PR touches any
#                                             merge.forbidden_files pattern
#   rerun-ci <n>                              Re-run failed CI for the PR head SHA
#
# Config keys (from talos.pipeline.yml via pipeline-config.sh):
#   vcs.provider          github | github-api | gitlab | azure | file   (default: github)
#   vcs.token_env         env-var name for the GitHub token (github-api only;
#                         default: GITHUB_TOKEN then GH_TOKEN)
#   vcs.repo              owner/repo  (auto-detected if omitted)
#   vcs.azure.org_url     e.g. https://dev.azure.com/myorg
#   vcs.azure.project     Azure DevOps project name
#   vcs.file.source.path  path to plan.md  (default: plan.md)
#   base_branch           PR target branch
#   merge.method          squash | merge | rebase   (default: squash)
#
# --dry-run: print the underlying CLI command instead of running it.
#            For file mode: describe the edit without applying it.
#
# Exit behaviour:
#   Exits non-zero on real errors so the orchestrator can react.
#   File-not-found / missing CLI → descriptive stderr + exit 1.
#   Webhook-safe no-ops (create-pr / merge-pr in file mode) → exit 0 + message.
#
# Provider notes:
#   github      — battle-tested; requires `gh` CLI authenticated.
#   github-api  — token-only; no `gh` needed; set GITHUB_TOKEN or GH_TOKEN.
#                 Projects v2 board updates also use the token (pipeline-status.sh).
#   gitlab  — best-effort; requires `glab` CLI authenticated.
#   azure   — best-effort; requires `az` CLI + azure-devops extension:
#               az extension add --name azure-devops
#               az devops configure --defaults organization=<org_url> project=<project>
#   file    — no VCS needed; edits a markdown checklist file (plan.md).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
DRY_RUN=false
VERB=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)
      [ -z "$VERB" ] && VERB="$arg" || ARGS+=("$arg")
      ;;
  esac
done

if [ -z "$VERB" ]; then
  echo "Usage: pipeline-vcs.sh [--dry-run] <verb> [args...]" >&2
  exit 1
fi

# ── Config ────────────────────────────────────────────────────────────────────
PROVIDER="$(cfg vcs.provider "github")"
REPO="$(cfg vcs.repo "")"
BASE_BRANCH="$(cfg base_branch "")"
MERGE_METHOD="$(cfg merge.method "squash")"
AZURE_ORG="$(cfg vcs.azure.org_url "")"
AZURE_PROJECT="$(cfg vcs.azure.project "")"
FILE_PATH="$(cfg vcs.file.source.path "plan.md")"

# Auto-detect repo for github/gitlab if not set.
# github-api uses only git remote (no gh call) to avoid CLI dependency.
if [ -z "$REPO" ] && [ "$PROVIDER" != "file" ]; then
  if [ "$PROVIDER" = "github-api" ]; then
    REPO="$(git remote get-url origin 2>/dev/null \
      | sed 's|.*github\.com[:/]||; s|\.git$||' || echo "")"
  else
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
      || git remote get-url origin 2>/dev/null \
      | sed 's|.*github.com[:/]||; s|.*gitlab.com[:/]||; s|\.git$||' \
      || echo "")"
  fi
fi

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
_run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ── Label arg parser (shared by label-issue / label-pr) ──────────────────────
# Parses [--add <label>]... [--remove <label>]... from $@
# Outputs: ADD_LABELS (space-separated), REMOVE_LABELS (space-separated)
_parse_label_args() {
  ADD_LABELS=""
  REMOVE_LABELS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --add)    ADD_LABELS="$ADD_LABELS $2";    shift 2 ;;
      --remove) REMOVE_LABELS="$REMOVE_LABELS $2"; shift 2 ;;
      *)        ADD_LABELS="$ADD_LABELS $1";    shift ;;
    esac
  done
  ADD_LABELS="${ADD_LABELS# }"
  REMOVE_LABELS="${REMOVE_LABELS# }"
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB ADAPTER
# ─────────────────────────────────────────────────────────────────────────────
_github() {
  local verb="$1"; shift
  case "$verb" in
    list-issues)
      _run gh issue list --state open --json number,title,labels,body \
        --limit 100 ${REPO:+--repo "$REPO"} "$@"
      ;;
    view-issue)
      _run gh issue view "$1" --json title,body,labels,comments \
        ${REPO:+--repo "$REPO"}
      ;;
    comment-issue)
      local n="$1" body="$2"
      _run gh issue comment "$n" --body "$body" ${REPO:+--repo "$REPO"}
      ;;
    close-issue)
      local n="$1" body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh issue comment $n --body <body> && gh issue close $n"
      else
        gh issue comment "$n" --body "$body" ${REPO:+--repo "$REPO"}
        gh issue close "$n" ${REPO:+--repo "$REPO"}
      fi
      ;;
    label-issue)
      local n="$1"; shift
      _parse_label_args "$@"
      local cmd="gh issue edit $n"
      for l in $ADD_LABELS;    do cmd="$cmd --add-label '$l'";    done
      for l in $REMOVE_LABELS; do cmd="$cmd --remove-label '$l'"; done
      [ -n "$REPO" ] && cmd="$cmd --repo '$REPO'"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] $cmd"; return 0; fi
      eval "$cmd"
      ;;
    create-issue)
      local title="$1" body_file="$2"; shift 2
      local label_args=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) label_args+=("--label" "$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      _run gh issue create --title "$title" --body-file "$body_file" \
        "${label_args[@]+"${label_args[@]}"}" ${REPO:+--repo "$REPO"}
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
      _run gh pr create --base "$BASE_BRANCH" --head "$branch" \
        --title "$title" --body-file "$body_file" ${REPO:+--repo "$REPO"}
      ;;
    view-pr)
      _run gh pr view "$1" --json number,title,headRefName,labels,url \
        ${REPO:+--repo "$REPO"}
      ;;
    list-prs)
      _run gh pr list --state open --json number,title,headRefName,labels \
        ${REPO:+--repo "$REPO"}
      ;;
    diff-pr)
      _run gh pr diff "$1" ${REPO:+--repo "$REPO"}
      ;;
    checkout-pr)
      _run gh pr checkout "$1" ${REPO:+--repo "$REPO"}
      ;;
    approve-pr)
      local n="$1" body="${2:-approved}"
      _run gh pr review "$n" --approve --body "$body" ${REPO:+--repo "$REPO"}
      ;;
    label-pr)
      local n="$1"; shift
      _parse_label_args "$@"
      local cmd="gh pr edit $n"
      for l in $ADD_LABELS;    do cmd="$cmd --add-label '$l'";    done
      for l in $REMOVE_LABELS; do cmd="$cmd --remove-label '$l'"; done
      [ -n "$REPO" ] && cmd="$cmd --repo '$REPO'"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] $cmd"; return 0; fi
      eval "$cmd"
      ;;
    pr-checks)
      _run gh pr checks "$1" ${REPO:+--repo "$REPO"}
      ;;
    merge-pr)
      local flag
      case "$MERGE_METHOD" in
        squash) flag="--squash" ;; rebase) flag="--rebase" ;; *) flag="--merge" ;;
      esac
      _run gh pr merge "$1" $flag --delete-branch ${REPO:+--repo "$REPO"}
      ;;
    comment-pr)
      # PRs are issues for commenting purposes on GitHub
      local n="$1" body="$2"
      _run gh issue comment "$n" --body "$body" ${REPO:+--repo "$REPO"}
      ;;
    find-pr)
      local n="$1" state="${2:-open}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh pr list --state $state ... | filter issue-$n / #$n"
        return 0
      fi
      gh pr list --state "$state" --limit 100 \
        --json number,state,title,headRefName,body ${REPO:+--repo "$REPO"} 2>/dev/null \
        | python3 -c "
import json, sys
n = sys.argv[1]
try: prs = json.load(sys.stdin)
except Exception: prs = []
for pr in prs:
    hay = pr.get('title','') + ' ' + pr.get('body','')
    if f'issue-{n}' in pr.get('headRefName','') or f'#{n}' in hay:
        print(json.dumps({k: pr.get(k) for k in ('number','state','title','headRefName')}))
" "$n"
      ;;
    check-pr-files)
      local n="$1"
      local patterns
      patterns="$(cfg merge.forbidden_files "")"
      [ -z "$patterns" ] && patterns='.env
.env.*
*.pem
*.key
*.p12
*.pfx
*.secrets
secrets.*'
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh pr view $n --json files | match against forbidden patterns"
        return 0
      fi
      gh pr view "$n" --json files -q '.files[].path' ${REPO:+--repo "$REPO"} 2>/dev/null \
        | PATTERNS="$patterns" python3 -c "
import fnmatch, os, sys
patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
bad = []
for path in (l.strip() for l in sys.stdin if l.strip()):
    base = os.path.basename(path)
    if any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns):
        bad.append(path)
if bad:
    print('FORBIDDEN FILES in PR — human review required before merge:')
    for p in bad: print(f'  {p}')
    sys.exit(1)
print('no forbidden files')
"
      ;;
    rerun-ci)
      local n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh run rerun --failed <runs for PR #$n head SHA>"
        return 0
      fi
      local sha
      sha="$(gh pr view "$n" --json headRefOid -q .headRefOid ${REPO:+--repo "$REPO"} 2>/dev/null)"
      [ -z "$sha" ] && { echo "pipeline-vcs: could not resolve head SHA for PR #$n" >&2; exit 1; }
      gh run list --commit "$sha" --json databaseId,conclusion ${REPO:+--repo "$REPO"} 2>/dev/null \
        | python3 -c "
import json, sys
try: runs = json.load(sys.stdin)
except Exception: runs = []
for r in runs:
    if r.get('conclusion') in ('failure', 'timed_out', 'cancelled'):
        print(r['databaseId'])
" | while IFS= read -r run_id; do
          [ -n "$run_id" ] && _run gh run rerun "$run_id" --failed ${REPO:+--repo "$REPO"}
        done
      echo "rerun-ci: re-ran failed runs for PR #$n ($sha)"
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB API ADAPTER  (token-only — no gh CLI required)
#   Prerequisites:
#     Set GITHUB_TOKEN or GH_TOKEN in your environment.
#     Optional: vcs.token_env config key names a custom env var to read.
#   Repo: vcs.repo config, else parsed from git remote get-url origin.
#   Pagination: single request with per_page=100; warns on truncation.
#   Output: normalises REST field names to match the gh adapter shape so
#     orchestrator prompts consume it unchanged (headRefName, etc.).
#   Token security: NEVER logged to stdout, stderr, or CURL_LOG (only
#     "Authorization: Bearer" prefix appears in stub logs).
# ─────────────────────────────────────────────────────────────────────────────
_github_api() {
  # ── Token resolution ────────────────────────────────────────────────────────
  local _TOKEN_ENV
  _TOKEN_ENV="$(cfg vcs.token_env "")"
  local _TOKEN=""
  if [ -n "$_TOKEN_ENV" ]; then
    _TOKEN="${!_TOKEN_ENV:-}"
  fi
  if [ -z "$_TOKEN" ]; then
    _TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  fi
  if [ -z "$_TOKEN" ]; then
    echo "github-api: GITHUB_TOKEN or GH_TOKEN required" >&2
    exit 1
  fi

  # ── Repo resolution (no gh call) ────────────────────────────────────────────
  local _REPO="$REPO"
  if [ -z "$_REPO" ]; then
    _REPO="$(git remote get-url origin 2>/dev/null \
      | sed 's|.*github\.com[:/]||; s|\.git$||')"
  fi
  local _OWNER="${_REPO%%/*}"
  local _NAME="${_REPO#*/}"
  local _API="https://api.github.com/repos/$_OWNER/$_NAME"

  local _VERB="$1"; shift

  # ── HTTP request helper (never logs token) ──────────────────────────────────
  # Usage: _ga_req <METHOD> <URL> [extra curl args...]
  # Outputs response body; exits 1 on non-2xx.
  _ga_req() {
    local _m="$1" _u="$2"; shift 2
    local _full _status _body _hdr_file
    _hdr_file="$(mktemp)"
    _full="$(curl -sS -w "\n%{http_code}" \
      -D "$_hdr_file" \
      -X "$_m" \
      -H "Authorization: Bearer $_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$@" "$_u")"
    _status="$(printf '%s' "$_full" | tail -1)"
    _body="$(printf '%s' "$_full" | sed '$d')"
    if [ "${_status:-0}" -ge 300 ] 2>/dev/null; then
      if [ "$_status" = "429" ]; then
        local _reset
        _reset="$(grep -i '^x-ratelimit-reset:' "$_hdr_file" 2>/dev/null \
          | sed 's/[^0-9]*//g' | tr -d '[:space:]')"
        if [ -n "$_reset" ]; then
          printf 'github-api: rate-limited; reset at %s\n' "$_reset" >&2
        else
          printf 'github-api: HTTP 429 on %s (rate-limited)\n' "$_VERB" >&2
        fi
      else
        printf 'github-api: HTTP %s on %s\n' "$_status" "$_VERB" >&2
      fi
      rm -f "$_hdr_file"
      exit 1
    fi
    rm -f "$_hdr_file"
    printf '%s' "$_body"
  }

  # ── Diff request (different Accept header) ──────────────────────────────────
  _ga_diff_req() {
    local _u="$1"
    local _full _status _body
    _full="$(curl -sS -w "\n%{http_code}" \
      -H "Authorization: Bearer $_TOKEN" \
      -H "Accept: application/vnd.github.v3.diff" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$_u")"
    _status="$(printf '%s' "$_full" | tail -1)"
    _body="$(printf '%s' "$_full" | sed '$d')"
    if [ "${_status:-0}" -ge 300 ] 2>/dev/null; then
      printf 'github-api: HTTP %s on diff-pr\n' "$_status" >&2
      exit 1
    fi
    printf '%s' "$_body"
  }

  # ── Verb dispatch ───────────────────────────────────────────────────────────
  case "$_VERB" in

    list-issues)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/issues?state=open&per_page=100"
        return 0
      fi
      local _raw
      _raw="$(_ga_req GET "$_API/issues?state=open&per_page=100")"
      printf '%s' "$_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if len(data) == 100:
    print('NOTE: github-api: results truncated at 100 items', file=sys.stderr)
result = [{'number': i['number'], 'title': i.get('title',''),
           'body': i.get('body','') or '',
           'labels': [{'name': l['name']} for l in i.get('labels',[])]}
          for i in data]
print(json.dumps(result, indent=2))
"
      ;;

    view-issue)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/issues/$_n"
        return 0
      fi
      local _issue _comments
      _issue="$(_ga_req GET "$_API/issues/$_n")"
      _comments="$(_ga_req GET "$_API/issues/$_n/comments?per_page=100")"
      printf '%s' "$_issue" | COMMENTS="$_comments" python3 -c "
import json, sys, os
data = json.load(sys.stdin)
try:
    comments = json.loads(os.environ.get('COMMENTS','[]'))
except Exception:
    comments = []
result = {
    'title': data.get('title',''),
    'body': data.get('body','') or '',
    'labels': [{'name': l['name']} for l in data.get('labels',[])],
    'comments': [{'body': c.get('body','')} for c in comments]
}
print(json.dumps(result, indent=2))
"
      ;;

    comment-issue)
      local _n="$1" _body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/issues/$_n/comments"
        return 0
      fi
      local _payload
      _payload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]}))" "$_body")"
      _ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_payload" >/dev/null
      echo "Commented on issue #$_n"
      ;;

    close-issue)
      local _n="$1" _body="${2:-resolved}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/issues/$_n/comments, then PATCH state=closed"
        return 0
      fi
      local _cpayload _spayload
      _cpayload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]}))" "$_body")"
      _ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_cpayload" >/dev/null
      _spayload='{"state":"closed"}'
      _ga_req PATCH "$_API/issues/$_n" \
        -H "Content-Type: application/json" -d "$_spayload" >/dev/null
      echo "Closed issue #$_n"
      ;;

    label-issue)
      local _n="$1"; shift
      _parse_label_args "$@"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/issues/$_n/labels, PUT updated list"
        return 0
      fi
      local _cur_labels
      _cur_labels="$(_ga_req GET "$_API/issues/$_n/labels")"
      local _new_payload
      _new_payload="$(printf '%s' "$_cur_labels" | \
        ADD_LABELS="$ADD_LABELS" REMOVE_LABELS="$REMOVE_LABELS" python3 -c "
import json, sys, os
labels = [l['name'] for l in json.load(sys.stdin)]
add = os.environ.get('ADD_LABELS','').split()
rem = os.environ.get('REMOVE_LABELS','').split()
for l in add:
    if l not in labels:
        labels.append(l)
labels = [l for l in labels if l not in rem]
print(json.dumps({'labels': labels}))
")"
      _ga_req PUT "$_API/issues/$_n/labels" \
        -H "Content-Type: application/json" -d "$_new_payload" >/dev/null
      echo "Labels updated on issue #$_n"
      ;;

    create-issue)
      local _ci_title="$1" _ci_body_file="$2"; shift 2
      local _ci_labels=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) _ci_labels+=("$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/issues (title=$_ci_title)"
        return 0
      fi
      local _ci_body_content
      _ci_body_content="$(cat "$_ci_body_file")"
      local _ci_labels_json
      if [ ${#_ci_labels[@]} -gt 0 ]; then
        _ci_labels_json="$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${_ci_labels[@]}")"
      else
        _ci_labels_json="[]"
      fi
      local _ci_payload
      _ci_payload="$(CI_TITLE="$_ci_title" CI_BODY="$_ci_body_content" CI_LABELS="$_ci_labels_json" python3 -c "
import json, os
print(json.dumps({
    'title':  os.environ['CI_TITLE'],
    'body':   os.environ['CI_BODY'],
    'labels': json.loads(os.environ['CI_LABELS']),
}))
")"
      local _ci_resp
      _ci_resp="$(_ga_req POST "$_API/issues" \
        -H "Content-Type: application/json" -d "$_ci_payload")"
      printf '%s' "$_ci_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
url = d.get('html_url', d.get('url', ''))
n = d.get('number', '')
if url:
    print(url)
else:
    print(n)
"
      ;;

    create-pr)
      local _branch="$1" _title="$2" _body_file="$3"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/pulls (head=$_branch)"
        return 0
      fi
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
      local _body_content
      _body_content="$(cat "$_body_file")"
      local _pr_payload
      _pr_payload="$(BASE="$BASE_BRANCH" HEAD="$_branch" TITLE="$_title" \
        BODY="$_body_content" python3 -c "
import json, os
print(json.dumps({
    'title': os.environ['TITLE'],
    'head':  os.environ['HEAD'],
    'base':  os.environ['BASE'],
    'body':  os.environ['BODY'],
}))
")"
      local _pr_resp
      _pr_resp="$(_ga_req POST "$_API/pulls" \
        -H "Content-Type: application/json" -d "$_pr_payload")"
      printf '%s' "$_pr_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('html_url', d.get('url', '')))
"
      ;;

    view-pr)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls/$_n"
        return 0
      fi
      local _pr
      _pr="$(_ga_req GET "$_API/pulls/$_n")"
      printf '%s' "$_pr" | python3 -c "
import json, sys
d = json.load(sys.stdin)
result = {
    'number': d.get('number'),
    'title':  d.get('title',''),
    'headRefName': d.get('head',{}).get('ref',''),
    'labels': [{'name': l['name']} for l in d.get('labels',[])],
    'url':    d.get('html_url',''),
}
print(json.dumps(result, indent=2))
"
      ;;

    list-prs)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls?state=open&per_page=100"
        return 0
      fi
      local _raw
      _raw="$(_ga_req GET "$_API/pulls?state=open&per_page=100")"
      printf '%s' "$_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if len(data) == 100:
    print('NOTE: github-api: results truncated at 100 items', file=sys.stderr)
result = [{'number': i['number'], 'title': i.get('title',''),
           'headRefName': i.get('head',{}).get('ref',''),
           'labels': [{'name': l['name']} for l in i.get('labels',[])]}
          for i in data]
print(json.dumps(result, indent=2))
"
      ;;

    diff-pr)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls/$_n (Accept: vnd.github.v3.diff)"
        return 0
      fi
      _ga_diff_req "$_API/pulls/$_n"
      ;;

    checkout-pr)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET head.ref for PR #$_n, then git fetch + checkout"
        return 0
      fi
      local _pr_data _branch
      _pr_data="$(_ga_req GET "$_API/pulls/$_n")"
      _branch="$(printf '%s' "$_pr_data" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('head',{}).get('ref',''))
")"
      [ -z "$_branch" ] && { echo "github-api: could not resolve head ref for PR #$_n" >&2; exit 1; }
      git fetch origin "refs/pull/$_n/head:$_branch"
      git checkout "$_branch"
      ;;

    approve-pr)
      local _n="$1" _rbody="${2:-approved}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/pulls/$_n/reviews (APPROVE)"
        return 0
      fi
      local _rev_payload
      _rev_payload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1],'event':'APPROVE'}))" "$_rbody")"
      _ga_req POST "$_API/pulls/$_n/reviews" \
        -H "Content-Type: application/json" -d "$_rev_payload" >/dev/null
      echo "Approved PR #$_n"
      ;;

    label-pr)
      # PRs share label API with issues on GitHub
      local _n="$1"; shift
      _parse_label_args "$@"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/issues/$_n/labels, PUT updated list (PR)"
        return 0
      fi
      local _cur_labels
      _cur_labels="$(_ga_req GET "$_API/issues/$_n/labels")"
      local _new_payload
      _new_payload="$(printf '%s' "$_cur_labels" | \
        ADD_LABELS="$ADD_LABELS" REMOVE_LABELS="$REMOVE_LABELS" python3 -c "
import json, sys, os
labels = [l['name'] for l in json.load(sys.stdin)]
add = os.environ.get('ADD_LABELS','').split()
rem = os.environ.get('REMOVE_LABELS','').split()
for l in add:
    if l not in labels:
        labels.append(l)
labels = [l for l in labels if l not in rem]
print(json.dumps({'labels': labels}))
")"
      _ga_req PUT "$_API/issues/$_n/labels" \
        -H "Content-Type: application/json" -d "$_new_payload" >/dev/null
      echo "Labels updated on PR #$_n"
      ;;

    pr-checks)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/commits/<sha>/check-runs for PR #$_n"
        return 0
      fi
      local _pr_data _sha
      _pr_data="$(_ga_req GET "$_API/pulls/$_n")"
      _sha="$(printf '%s' "$_pr_data" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('head',{}).get('sha',''))
")"
      [ -z "$_sha" ] && { echo "github-api: could not resolve head SHA for PR #$_n" >&2; exit 1; }
      _ga_req GET "$_API/commits/$_sha/check-runs"
      ;;

    merge-pr)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: PUT $_API/pulls/$_n/merge (method=$MERGE_METHOD)"
        return 0
      fi
      local _mm
      case "$MERGE_METHOD" in
        squash) _mm="squash" ;; rebase) _mm="rebase" ;; *) _mm="merge" ;;
      esac
      local _merge_payload
      _merge_payload="$(python3 -c "import json,sys; print(json.dumps({'merge_method':sys.argv[1],'delete_branch':True}))" "$_mm")"
      _ga_req PUT "$_API/pulls/$_n/merge" \
        -H "Content-Type: application/json" -d "$_merge_payload" >/dev/null
      echo "Merged PR #$_n"
      ;;

    comment-pr)
      # PRs share the issues comment API on GitHub
      local _n="$1" _body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: POST $_API/issues/$_n/comments (PR comment)"
        return 0
      fi
      local _payload
      _payload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]}))" "$_body")"
      _ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_payload" >/dev/null
      echo "Commented on PR #$_n"
      ;;

    find-pr)
      local _n="$1" _state="${2:-open}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls?state=<mapped>&per_page=100 | filter issue-$_n / #$_n"
        return 0
      fi
      # GitHub REST only accepts state=open|closed|all.
      # "merged" PRs are closed with merged_at set; "all" covers both open and closed.
      local _api_state
      case "$_state" in
        merged) _api_state="closed" ;;
        open)   _api_state="open" ;;
        all)    _api_state="all" ;;
        *)      _api_state="$_state" ;;
      esac
      local _raw
      _raw="$(_ga_req GET "$_API/pulls?state=$_api_state&per_page=100")"
      printf '%s' "$_raw" | STATE_FILTER="$_state" python3 -c "
import json, sys, os
n = sys.argv[1]
state_filter = os.environ.get('STATE_FILTER','open')
try: prs = json.load(sys.stdin)
except Exception: prs = []
for pr in prs:
    hay = pr.get('title','') + ' ' + (pr.get('body','') or '')
    ref = pr.get('head',{}).get('ref','')
    if not (f'issue-{n}' in ref or f'#{n}' in hay):
        continue
    # For merged filter: only PRs with merged_at set
    if state_filter == 'merged' and not pr.get('merged_at'):
        continue
    # Normalise state to gh-compatible values: OPEN, CLOSED, MERGED
    raw_state = pr.get('state','').upper()
    if pr.get('merged_at'):
        out_state = 'MERGED'
    elif raw_state == 'OPEN':
        out_state = 'OPEN'
    else:
        out_state = 'CLOSED'
    print(json.dumps({'number': pr.get('number'),
                      'state':  out_state,
                      'title':  pr.get('title',''),
                      'headRefName': ref}))
" "$_n"
      ;;

    check-pr-files)
      local _n="$1"
      local _patterns
      _patterns="$(cfg merge.forbidden_files "")"
      [ -z "$_patterns" ] && _patterns='.env
.env.*
*.pem
*.key
*.p12
*.pfx
*.secrets
secrets.*'
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls/$_n/files | match against forbidden patterns"
        return 0
      fi
      local _files_raw
      _files_raw="$(_ga_req GET "$_API/pulls/$_n/files?per_page=100")"
      printf '%s' "$_files_raw" | PATTERNS="$_patterns" python3 -c "
import fnmatch, os, sys, json
patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
bad = []
try:
    files = json.load(sys.stdin)
except Exception:
    files = []
for f in files:
    path = f.get('filename','')
    base = os.path.basename(path)
    if any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns):
        bad.append(path)
if bad:
    print('FORBIDDEN FILES in PR — human review required before merge:')
    for p in bad: print(f'  {p}')
    sys.exit(1)
print('no forbidden files')
"
      ;;

    rerun-ci)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET PR head SHA, list runs, POST rerun-failed-jobs for failed runs"
        return 0
      fi
      local _pr_data _sha
      _pr_data="$(_ga_req GET "$_API/pulls/$_n")"
      _sha="$(printf '%s' "$_pr_data" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('head',{}).get('sha',''))
")"
      [ -z "$_sha" ] && { echo "github-api: could not resolve head SHA for PR #$_n" >&2; exit 1; }
      local _runs_raw
      _runs_raw="$(_ga_req GET "$_API/actions/runs?head_sha=$_sha")"
      local _failed_ids
      _failed_ids="$(printf '%s' "$_runs_raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    runs = d.get('workflow_runs', d) if isinstance(d, dict) else d
    for r in runs:
        if r.get('conclusion') in ('failure','timed_out','cancelled'):
            print(r['id'])
except Exception:
    pass
")"
      if [ -z "$_failed_ids" ]; then
        echo "rerun-ci: no failed runs found for PR #$_n ($_sha)"
        return 0
      fi
      while IFS= read -r _run_id; do
        [ -n "$_run_id" ] && \
          _ga_req POST "$_API/actions/runs/$_run_id/rerun-failed-jobs" \
            -H "Content-Type: application/json" -d '{}' >/dev/null
      done <<< "$_failed_ids"
      echo "rerun-ci: re-ran failed runs for PR #$_n ($_sha)"
      ;;

    *) echo "pipeline-vcs: unknown verb: $_VERB" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# GITLAB ADAPTER  (best-effort — requires glab authenticated)
# ─────────────────────────────────────────────────────────────────────────────
_gitlab() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "pipeline-vcs: 'glab' not found. Install from https://gitlab.com/gitlab-org/cli" >&2
    exit 1
  fi
  local verb="$1"; shift
  local RARG=""
  [ -n "$REPO" ] && RARG="-R $REPO"
  case "$verb" in
    list-issues)
      _run glab issue list --state opened $RARG "$@"
      ;;
    view-issue)
      _run glab issue view "$1" $RARG
      ;;
    comment-issue)
      local n="$1" body="$2"
      _run glab issue note "$n" --message "$body" $RARG
      ;;
    close-issue)
      local n="$1" body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab issue note $n --message <body> && glab issue close $n $RARG"
      else
        glab issue note "$n" --message "$body" $RARG
        glab issue close "$n" $RARG
      fi
      ;;
    label-issue)
      local n="$1"; shift
      _parse_label_args "$@"
      local cmd="glab issue update $n"
      for l in $ADD_LABELS;    do cmd="$cmd --label '$l'";   done
      for l in $REMOVE_LABELS; do cmd="$cmd --unlabel '$l'"; done
      [ -n "$RARG" ] && cmd="$cmd $RARG"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] $cmd"; return 0; fi
      eval "$cmd"
      ;;
    create-issue)
      local title="$1" body_file="$2"; shift 2
      local label_args=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) label_args+=("--label" "$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      _run glab issue create --title "$title" \
        --description "$(cat "$body_file")" \
        "${label_args[@]+"${label_args[@]}"}" $RARG
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$(glab repo view --format='%{default_branch}' 2>/dev/null || echo main)"
      _run glab mr create --head "$branch" --target-branch "$BASE_BRANCH" \
        --title "$title" --description "$(cat "$body_file")" $RARG
      ;;
    view-pr)
      _run glab mr view "$1" $RARG
      ;;
    list-prs)
      _run glab mr list --state opened $RARG
      ;;
    diff-pr)
      _run glab mr diff "$1" $RARG
      ;;
    checkout-pr)
      _run glab mr checkout "$1" $RARG
      ;;
    approve-pr)
      local n="$1" body="${2:-}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab mr approve $n $RARG  # note: body not posted separately on approve"
      else
        glab mr approve "$n" $RARG
        # glab mr approve has no --body; post comment separately if body given
        [ -n "$body" ] && glab mr note "$n" --message "$body" $RARG
      fi
      ;;
    label-pr)
      local n="$1"; shift
      _parse_label_args "$@"
      local cmd="glab mr update $n"
      for l in $ADD_LABELS;    do cmd="$cmd --label '$l'";   done
      for l in $REMOVE_LABELS; do cmd="$cmd --unlabel '$l'"; done
      [ -n "$RARG" ] && cmd="$cmd $RARG"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] $cmd"; return 0; fi
      eval "$cmd"
      ;;
    pr-checks)
      _run glab mr ci status "$1" $RARG
      ;;
    merge-pr)
      _run glab mr merge "$1" $RARG
      ;;
    comment-pr)
      local n="$1" body="$2"
      _run glab mr note "$n" --message "$body" $RARG
      ;;
    find-pr|check-pr-files|rerun-ci)
      # Best-effort providers: not implemented — fail open with a warning so
      # the orchestrator falls back to its manual instructions.
      echo "pipeline-vcs: $verb not implemented for gitlab — verify manually" >&2
      return 0
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# AZURE DEVOPS ADAPTER  (best-effort)
#   Prerequisites:
#     az extension add --name azure-devops
#     az devops configure --defaults organization=<org_url> project=<project>
#   Or set vcs.azure.org_url + vcs.azure.project in talos.pipeline.yml
# ─────────────────────────────────────────────────────────────────────────────
_azure() {
  if ! command -v az >/dev/null 2>&1; then
    echo "pipeline-vcs: 'az' (Azure CLI) not found. Install from https://aka.ms/installazurecli" >&2
    exit 1
  fi

  # Check for azure-devops extension
  if ! az extension list --query "[?name=='azure-devops']" -o tsv 2>/dev/null | grep -q azure-devops; then
    echo "pipeline-vcs: azure-devops extension missing. Run: az extension add --name azure-devops" >&2
    exit 1
  fi

  local ORG_ARG="" PROJ_ARG=""
  [ -n "$AZURE_ORG" ]     && ORG_ARG="--org $AZURE_ORG"
  [ -n "$AZURE_PROJECT" ] && PROJ_ARG="--project $AZURE_PROJECT"

  local verb="$1"; shift
  case "$verb" in
    list-issues)
      _run az boards work-item list $ORG_ARG $PROJ_ARG \
        --query "[?state!='Closed']" --output json "$@"
      ;;
    view-issue)
      _run az boards work-item show --id "$1" $ORG_ARG --output json
      ;;
    comment-issue)
      local n="$1" body="$2"
      _run az boards work-item comment add --id "$n" --text "$body" $ORG_ARG
      ;;
    close-issue)
      local n="$1" body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards work-item comment add --id $n --text <body> $ORG_ARG"
        echo "[dry-run] az boards work-item update --id $n --state Done $ORG_ARG"
      else
        az boards work-item comment add --id "$n" --text "$body" $ORG_ARG
        az boards work-item update --id "$n" --state Done $ORG_ARG
      fi
      ;;
    label-issue)
      # Azure uses tags, not labels. Manage as semicolon-separated tags.
      local n="$1"; shift
      _parse_label_args "$@"
      # Fetch current tags
      local current_tags
      current_tags="$(az boards work-item show --id "$n" $ORG_ARG \
        --query fields.\"System.Tags\" -o tsv 2>/dev/null || echo "")"
      python3 - "$n" "$current_tags" "$ADD_LABELS" "$REMOVE_LABELS" \
        "$DRY_RUN" "$ORG_ARG" <<'PYEOF'
import subprocess, sys
n, cur, add_s, rem_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dry_run = sys.argv[5] == 'true'
org_arg = sys.argv[6]
tags = {t.strip() for t in cur.split(';') if t.strip()}
for t in add_s.split(): tags.add(t)
for t in rem_s.split(): tags.discard(t)
new_tags = '; '.join(sorted(tags))
cmd = ['az', 'boards', 'work-item', 'update', '--id', n, '--tags', new_tags] + \
      (org_arg.split() if org_arg else [])  # split into ['--org', '<url>'] so az receives two argv elements
if dry_run:
    print(f'[dry-run] {" ".join(cmd)}')
else:
    subprocess.run(cmd, check=True)
PYEOF
      ;;
    create-issue)
      echo "pipeline-vcs: create-issue is not implemented for azure — use the Azure DevOps web UI or 'az boards work-item create' manually" >&2
      exit 1
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
      _run az repos pr create \
        --source-branch "$branch" --target-branch "$BASE_BRANCH" \
        --title "$title" --description "$(cat "$body_file")" \
        $ORG_ARG $PROJ_ARG --output json
      ;;
    view-pr)
      _run az repos pr show --id "$1" $ORG_ARG --output json
      ;;
    list-prs)
      _run az repos pr list --status active $ORG_ARG $PROJ_ARG --output json
      ;;
    diff-pr)
      echo "pipeline-vcs: diff-pr not supported by 'az' CLI; use az repos pr show --id $1" >&2
      exit 1
      ;;
    checkout-pr)
      # az CLI does not support checkout; use git fetch + checkout
      local pr_id="$1"
      local source_branch
      source_branch="$(az repos pr show --id "$pr_id" $ORG_ARG \
        --query sourceRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      _run git fetch origin "$source_branch"
      _run git checkout "$source_branch"
      ;;
    approve-pr)
      local n="$1" body="${2:-}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr set-vote --id $n --vote approve $ORG_ARG"
        [ -n "$body" ] && echo "[dry-run] az repos pr comment add --id $n --comment <body> $ORG_ARG"
      else
        az repos pr set-vote --id "$n" --vote approve $ORG_ARG
        [ -n "$body" ] && az repos pr comment add --id "$n" --comment "$body" $ORG_ARG
      fi
      ;;
    label-pr)
      # Azure PRs don't have labels/tags in the same sense; map to work item links
      echo "pipeline-vcs: label-pr not applicable for Azure DevOps (no PR labels)" >&2
      return 0
      ;;
    pr-checks)
      _run az repos pr show --id "$1" $ORG_ARG \
        --query "{status:status,mergeStatus:mergeStatus}" --output json
      ;;
    merge-pr)
      _run az repos pr update --id "$1" --status completed $ORG_ARG --output json
      ;;
    comment-pr)
      local n="$1" body="$2"
      _run az repos pr comment add --id "$n" --comment "$body" $ORG_ARG
      ;;
    find-pr|check-pr-files|rerun-ci)
      echo "pipeline-vcs: $verb not implemented for azure — verify manually" >&2
      return 0
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE MODE ADAPTER
#   Work items are markdown checklist items in a local file.
#   Format:  - [ ] Title text <!-- id: N -->
#            (indented lines are the detail block)
#   IDs are auto-assigned on first list-issues call.
# ─────────────────────────────────────────────────────────────────────────────
_file() {
  local verb="$1"; shift

  # Resolve the plan file path relative to the caller's working directory
  case "$FILE_PATH" in
    /*) : ;;                                       # already absolute
    *)  FILE_PATH="$(pwd)/$FILE_PATH" ;;
  esac

  # Delegate all file operations to an inline Python script
  DRY_RUN_FLAG=""
  [ "$DRY_RUN" = "true" ] && DRY_RUN_FLAG="--dry-run"

  case "$verb" in
    create-pr)
      echo "file mode: no PR created — developer should commit to branch and record it via comment-issue" >&2
      return 0
      ;;
    merge-pr)
      echo "file mode: no PR to merge — orchestrator should close-issue directly after verifying the branch" >&2
      return 0
      ;;
    diff-pr|pr-checks|list-prs|view-pr|find-pr|check-pr-files|rerun-ci)
      echo "file mode: $verb not applicable in file mode" >&2
      return 0
      ;;
    checkout-pr)
      echo "file mode: checkout-pr not applicable — use 'git checkout <branch>'" >&2
      return 0
      ;;
    approve-pr)
      echo "file mode: approve-pr not applicable — no PR review in file mode" >&2
      return 0
      ;;
    label-issue|label-pr)
      # Labels are not tracked in file mode — pipeline state is the checkbox
      echo "file mode: label tracking not applicable (pipeline state = checkbox)" >&2
      return 0
      ;;
    create-issue)
      local ci_title="$1"
      # --label args are ignored in file mode (state = checkbox)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] file: would append '- [ ] ${ci_title}' to ${FILE_PATH}"
        return 0
      fi
      touch "$FILE_PATH"
      FILE_PATH="$FILE_PATH" python3 - "$ci_title" <<'PYEOF'
import sys, re, os

title = sys.argv[1]
plan_path = os.environ['FILE_PATH']

try:
    with open(plan_path) as f:
        content = f.read()
except FileNotFoundError:
    content = ''

ids = [int(m.group(1)) for m in re.finditer(r'<!-- id: (\d+) -->', content)]
new_id = (max(ids) if ids else 0) + 1

line = f'\n- [ ] {title} <!-- id: {new_id} -->\n'
with open(plan_path, 'a') as f:
    f.write(line)

print(new_id)
PYEOF
      ;;
    *)
      # Delegate to Python for all file-mutation verbs
      FILE_PATH="$FILE_PATH" python3 - "$verb" $DRY_RUN_FLAG "$@" <<'PYEOF'
import sys, re, os, json

verb = sys.argv[1]
dry_run = '--dry-run' in sys.argv
args = [a for a in sys.argv[2:] if a != '--dry-run']

plan_path = os.environ['FILE_PATH']

# ── Helpers ──────────────────────────────────────────────────────────────────

_ITEM_RE = re.compile(
    r'^(?P<indent>\s*)- \[(?P<check>[ x])\] (?P<title>[^<\n]+?)(?:\s*<!-- id: (?P<id>\d+) -->)?\s*$'
)

def load_file():
    try:
        with open(plan_path) as f:
            return f.read()
    except FileNotFoundError:
        print(f"pipeline-vcs: file not found: {plan_path}", file=sys.stderr)
        sys.exit(1)

def save_file(content):
    if dry_run:
        print(f"[dry-run] would write {plan_path}:")
        for i, line in enumerate(content.splitlines()[:10], 1):
            print(f"  {i}: {line}")
    else:
        with open(plan_path, 'w') as f:
            f.write(content)

def parse_items(content):
    """Return list of dicts: {id, title, checked, line_idx, detail_lines: [(idx, text)]}"""
    lines = content.split('\n')
    items = []
    i = 0
    while i < len(lines):
        m = _ITEM_RE.match(lines[i])
        if m:
            item_indent = m.group('indent')
            item = {
                'id':       m.group('id'),
                'title':    m.group('title').strip(),
                'checked':  m.group('check') == 'x',
                'line_idx': i,
                'detail_lines': [],
            }
            j = i + 1
            while j < len(lines):
                detail = lines[j]
                # Detail block: indented more than the item, or blank line with more content after
                if detail == '' or (detail.startswith(item_indent + '  ') and not _ITEM_RE.match(detail)):
                    item['detail_lines'].append((j, detail))
                    j += 1
                else:
                    break
            items.append(item)
            i = j
        else:
            i += 1
    return items

def ensure_ids(content):
    """Assign <!-- id: N --> to any item that lacks one. Returns updated content."""
    lines = content.split('\n')
    items = parse_items(content)
    # Find highest existing id
    max_id = max((int(it['id']) for it in items if it['id']), default=0)
    changed = False
    for item in items:
        if not item['id']:
            max_id += 1
            # Insert id comment into the line
            lines[item['line_idx']] = lines[item['line_idx']].rstrip() + f' <!-- id: {max_id} -->'
            changed = True
    return '\n'.join(lines) if changed else content, changed

def find_item(items, id_str):
    for it in items:
        if it['id'] == id_str:
            return it
    print(f"pipeline-vcs: no item with id {id_str} in {plan_path}", file=sys.stderr)
    sys.exit(1)

# ── Verb dispatch ─────────────────────────────────────────────────────────────

if verb == 'list-issues':
    content = load_file()
    content, changed = ensure_ids(content)
    if changed:
        save_file(content)
    items = parse_items(content)
    open_items = [it for it in items if not it['checked']]
    # Output as JSON array
    print(json.dumps([{'id': it['id'], 'title': it['title']} for it in open_items], indent=2))

elif verb == 'view-issue':
    n = args[0]
    content = load_file()
    content, changed = ensure_ids(content)
    if changed:
        save_file(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    print(f"id: {item['id']}")
    print(f"title: {item['title']}")
    print(f"status: {'closed' if item['checked'] else 'open'}")
    if item['detail_lines']:
        print("detail:")
        for _, dl in item['detail_lines']:
            print(f"  {dl}")

elif verb == 'comment-issue':
    n, body = args[0], '\n'.join(args[1:]) if len(args) > 1 else (args[1] if len(args) > 1 else '')
    # Handle body as single arg or joined args
    body = args[1] if len(args) >= 2 else ''
    content = load_file()
    content, _ = ensure_ids(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    # Determine indent (2 spaces more than item indent)
    item_line = lines[item['line_idx']]
    item_indent = len(item_line) - len(item_line.lstrip())
    detail_indent = ' ' * (item_indent + 2)
    # Insert comment lines after the last detail line (or right after item)
    insert_after = item['detail_lines'][-1][0] if item['detail_lines'] else item['line_idx']
    # Format body lines with detail indent
    comment_lines = [detail_indent + line for line in body.split('\n')]
    for offset, cl in enumerate(comment_lines):
        lines.insert(insert_after + 1 + offset, cl)
    if dry_run:
        print(f"[dry-run] would append to item #{n} in {plan_path}:")
        for cl in comment_lines[:5]:
            print(f"  {cl}")
    else:
        save_file('\n'.join(lines))
        print(f"Commented on item #{n}")

elif verb == 'close-issue':
    n = args[0]
    body = args[1] if len(args) >= 2 else 'resolved'
    content = load_file()
    content, _ = ensure_ids(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    # Check the box
    lines[item['line_idx']] = lines[item['line_idx']].replace('- [ ]', '- [x]', 1)
    # Append resolution note
    item_indent = len(lines[item['line_idx']]) - len(lines[item['line_idx']].lstrip())
    note_line = ' ' * (item_indent + 2) + f'resolved: {body}'
    insert_after = item['detail_lines'][-1][0] if item['detail_lines'] else item['line_idx']
    lines.insert(insert_after + 1, note_line)
    if dry_run:
        print(f"[dry-run] would close item #{n} in {plan_path} and append: {note_line}")
    else:
        save_file('\n'.join(lines))
        print(f"Closed item #{n}")

else:
    print(f"pipeline-vcs: unknown verb in file mode: {verb}", file=sys.stderr)
    sys.exit(1)
PYEOF
      ;;
  esac
}

# ── Main dispatch ─────────────────────────────────────────────────────────────
case "$PROVIDER" in
  github)     _github     "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  github-api) _github_api "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  gitlab)     _gitlab     "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  azure)      _azure      "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  file)       _file       "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  *)
    echo "pipeline-vcs: unknown provider '$PROVIDER'. Valid: github | github-api | gitlab | azure | file" >&2
    exit 1
    ;;
esac
