#!/usr/bin/env bash
# pipeline-status.sh — set an issue's Status field on a GitHub Project.
#
# Usage: pipeline-status.sh [--dry-run] <issue-number> <status-display-name>
#
# Examples:
#   pipeline-status.sh 42 "In progress"
#   pipeline-status.sh --dry-run 42 "Done"
#
# Status names must match the configured display names in talos.pipeline.yml
# (e.g. "Ready", "In progress", "In review", "Done", "Blocked").
#
# Config keys read (via pipeline-config.sh):
#   board.enabled          default: true
#   board.project_number   required when board is enabled
#   board.owner            default: repo owner detected from gh (or from vcs.repo
#                          when provider=github-api and gh is absent)
#   board.status_field     default: Status
#
# Env var overrides (take priority over config file):
#   PIPELINE_PROJECT_NUMBER   overrides board.project_number
#   PIPELINE_BOARD_OWNER      overrides board.owner
#   PIPELINE_STATUS_FIELD     overrides board.status_field
#   PIPELINE_REPO             overrides repo (owner/name) for issue URL construction
#
# Token path (activated when vcs.provider=github-api or gh is absent):
#   All GitHub Projects v2 GraphQL calls are made via curl + GITHUB_TOKEN (or
#   GH_TOKEN). OWNER must be resolvable from config/env when gh is absent.
#
# --dry-run: prints the gh/curl commands that WOULD run without executing them.
#            Always exits 0 — safe to use in CI previews.
#
# Always exits 0 on board-disabled or missing config; exits non-zero only on
# genuine failures (missing project, bad field name, etc.) when not dry-run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

# ── Token-based GraphQL path ──────────────────────────────────────────────────
# Activated when vcs.provider=github-api OR when gh is not on PATH.
# Resolves OWNER from: PIPELINE_BOARD_OWNER > board.owner > first component of vcs.repo.
_USE_TOKEN_PATH=false
_STATUS_TOKEN=""

_resolve_token_path() {
  local provider
  provider="$(cfg vcs.provider "github")"
  if [ "$provider" = "github-api" ] || ! command -v gh >/dev/null 2>&1; then
    _USE_TOKEN_PATH=true
    local token_env
    token_env="$(cfg vcs.token_env "")"
    if [ -n "$token_env" ]; then
      _STATUS_TOKEN="${!token_env:-}"
    fi
    if [ -z "$_STATUS_TOKEN" ]; then
      _STATUS_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    fi
  fi
}

_graphql_token_update() {
  # ── Token GraphQL implementation for all 5 board operations ─────────────────
  # $1=issue $2=status $3=project_num $4=owner $5=status_field $6=repo $7=dry_run
  local _issue="$1" _status="$2" _proj_num="$3" _owner="$4" _sfield="$5"
  local _repo="$6" _dry="$7"

  if [ -z "$_STATUS_TOKEN" ]; then
    echo "pipeline-status: GITHUB_TOKEN or GH_TOKEN required for github-api board updates" >&2
    exit 1
  fi

  # Helper: run a GraphQL query
  _gql() {
    local _query="$1"
    local _result
    _result="$(curl -sS \
      -H "Authorization: Bearer $_STATUS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$_query" \
      "https://api.github.com/graphql")"
    printf '%s' "$_result"
  }

  # 1. Resolve project ID
  local _proj_id
  _proj_id="$(_gql "{\"query\":\"query{user(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}" \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['data']['user']['projectV2']['id'])
except Exception:
    try:
        print(d['data']['organization']['projectV2']['id'])
    except Exception:
        pass
" 2>/dev/null)"

  # Try organization if user lookup failed
  if [ -z "$_proj_id" ]; then
    _proj_id="$(_gql "{\"query\":\"query{organization(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}" \
      | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['data']['organization']['projectV2']['id'])
except Exception:
    pass
" 2>/dev/null)"
  fi

  if [ -z "$_proj_id" ]; then
    if [ "$_dry" = "true" ]; then
      _proj_id="<project-id>"
    else
      echo "pipeline-status: could not resolve project #$_proj_num for owner '$_owner'" >&2
      exit 1
    fi
  fi

  # 2. Resolve field ID and option ID
  local _field_data _field_id _opt_id
  _field_data="$(_gql "{\"query\":\"query{node(id:\\\"$_proj_id\\\"){...on ProjectV2{fields(first:50){nodes{...on ProjectV2SingleSelectField{id name options{id name}}}}}}}\"}" \
    | SFIELD="$_sfield" SSTATUS="$_status" python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    nodes = d['data']['node']['fields']['nodes']
    sfield = os.environ['SFIELD']
    sstatus = os.environ['SSTATUS']
    for f in nodes:
        if f and f.get('name') == sfield:
            fid = f.get('id','')
            oid = ''
            for opt in f.get('options',[]):
                if opt.get('name') == sstatus:
                    oid = opt.get('id','')
                    break
            print(fid)
            print(oid)
            break
except Exception:
    pass
" 2>/dev/null)"

  _field_id="$(printf '%s' "$_field_data" | head -1)"
  _opt_id="$(printf '%s' "$_field_data" | tail -1)"

  if [ -z "$_field_id" ]; then
    if [ "$_dry" = "true" ]; then _field_id="<field-id>"; else
      echo "pipeline-status: status field '$_sfield' not found in project #$_proj_num" >&2; exit 1
    fi
  fi
  if [ -z "$_opt_id" ] || [ "$_opt_id" = "$_field_id" ]; then
    if [ "$_dry" = "true" ]; then _opt_id="<option-id>"; else
      echo "pipeline-status: option '$_status' not found in field '$_sfield'" >&2; exit 1
    fi
  fi

  # 3. Resolve (or add) issue item in project
  local _issue_url="https://github.com/$_repo/issues/$_issue"
  local _item_id
  _item_id="$(_gql "{\"query\":\"query{node(id:\\\"$_proj_id\\\"){...on ProjectV2{items(first:200){nodes{id content{...on Issue{number}}}}}}}\"}" \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    n = int('$_issue')
    items = d['data']['node']['items']['nodes']
    for item in items:
        if item and item.get('content',{}).get('number') == n:
            print(item['id'])
            break
except Exception:
    pass
" 2>/dev/null)"

  if [ -z "$_item_id" ]; then
    if [ "$_dry" = "true" ]; then
      echo "[dry-run] token-graphql: addProjectV2ItemByContentId for $_issue_url"
      _item_id="<item-id>"
    else
      _item_id="$(_gql "{\"query\":\"mutation{addProjectV2ItemByContentId(input:{projectId:\\\"$_proj_id\\\" contentId:\\\"$(curl -sS -H "Authorization: Bearer $_STATUS_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$_repo/issues/$_issue" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('node_id',''))")\\\"}) {item{id}}}\"}\"" \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['data']['addProjectV2ItemByContentId']['item']['id'])
except Exception:
    pass
" 2>/dev/null)"
      [ -z "$_item_id" ] && { echo "pipeline-status: could not add #$_issue to project" >&2; exit 1; }
    fi
  fi

  # 4. Set the status field
  if [ "$_dry" = "true" ]; then
    echo "[dry-run] token-graphql: updateProjectV2ItemFieldValue project=$_proj_id item=$_item_id field=$_field_id option=$_opt_id"
    echo "#$_issue → $_status (dry-run via token-graphql)"
  else
    _gql "{\"query\":\"mutation{updateProjectV2ItemFieldValue(input:{projectId:\\\"$_proj_id\\\" itemId:\\\"$_item_id\\\" fieldId:\\\"$_field_id\\\" value:{singleSelectOptionId:\\\"$_opt_id\\\"}}){projectV2Item{id}}}\"}" >/dev/null
    echo "#$_issue → $_status"
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

ISSUE="${POSITIONAL[0]:-}"
STATUS="${POSITIONAL[1]:-}"

if [ -z "$ISSUE" ] || [ -z "$STATUS" ]; then
  echo "Usage: pipeline-status.sh [--dry-run] <issue-number> <status>" >&2
  exit 2
fi

# ── Board enabled? ────────────────────────────────────────────────────────────
BOARD_ENABLED="$(cfg board.enabled "true")"
if [ "$BOARD_ENABLED" = "false" ]; then
  echo "board disabled; skipping status update for #$ISSUE" >&2
  exit 0
fi

# ── Read config with env var overrides ───────────────────────────────────────
PROJECT_NUM="${PIPELINE_PROJECT_NUMBER:-$(cfg board.project_number "")}"
if [ -z "$PROJECT_NUM" ]; then
  echo "pipeline-status: board.project_number not configured; skipping" >&2
  exit 0
fi

STATUS_FIELD="${PIPELINE_STATUS_FIELD:-$(cfg board.status_field "Status")}"

# ── Detect whether to use token-based GraphQL path ────────────────────────────
_resolve_token_path

# Owner: env var > config > gh (if available) > first component of vcs.repo
DEFAULT_OWNER=""
if [ "$_USE_TOKEN_PATH" = "false" ] && [ "$DRY_RUN" = "false" ]; then
  DEFAULT_OWNER="$(gh repo view --json owner -q .owner.login 2>/dev/null || echo "")"
fi
if [ -z "$DEFAULT_OWNER" ]; then
  # Fall back to first component of vcs.repo config
  _VCS_REPO="$(cfg vcs.repo "")"
  [ -n "$_VCS_REPO" ] && DEFAULT_OWNER="${_VCS_REPO%%/*}"
fi
OWNER="${PIPELINE_BOARD_OWNER:-$(cfg board.owner "$DEFAULT_OWNER")}"

if [ -z "$OWNER" ]; then
  echo "pipeline-status: board.owner not set; skipping" >&2
  exit 0
fi

# Repo: for issue URL construction
if [ "$_USE_TOKEN_PATH" = "true" ]; then
  REPO="${PIPELINE_REPO:-$(cfg vcs.repo "")}"
  if [ -z "$REPO" ]; then
    REPO="$(git remote get-url origin 2>/dev/null \
      | sed 's|.*github\.com[:/]||; s|\.git$||' || echo "$OWNER/REPO")"
  fi
else
  REPO="${PIPELINE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "OWNER/REPO")}"
fi

# ── Token path: delegate to GraphQL helper ────────────────────────────────────
if [ "$_USE_TOKEN_PATH" = "true" ]; then
  _graphql_token_update "$ISSUE" "$STATUS" "$PROJECT_NUM" "$OWNER" \
    "$STATUS_FIELD" "$REPO" "$DRY_RUN"
  exit $?
fi

# ── gh CLI path (original) ────────────────────────────────────────────────────
# All discovery calls are wrapped to never abort in dry-run mode.
_gh_safe() { "$@" 2>/dev/null || echo ""; }

PROJ_ID="$(_gh_safe gh project list --owner "$OWNER" --format json --limit 50 \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    n = int('$PROJECT_NUM')
    for p in d.get('projects', []):
        if p.get('number') == n:
            print(p.get('id',''))
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null)"

if [ -z "$PROJ_ID" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    PROJ_ID="<project-id>"
  else
    echo "pipeline-status: could not resolve project #$PROJECT_NUM for owner '$OWNER'" >&2
    exit 1
  fi
fi

FIELD_DATA="$(_gh_safe gh project field-list "$PROJECT_NUM" --owner "$OWNER" --format json)"

FIELD_ID="$(printf '%s' "$FIELD_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for f in d.get('fields', []):
        if f.get('name') == '$STATUS_FIELD':
            print(f.get('id',''))
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null)"

if [ -z "$FIELD_ID" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    FIELD_ID="<field-id>"
  else
    echo "pipeline-status: status field '$STATUS_FIELD' not found in project #$PROJECT_NUM" >&2
    exit 1
  fi
fi

OPT_ID="$(printf '%s' "$FIELD_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for f in d.get('fields', []):
        if f.get('name') == '$STATUS_FIELD':
            for opt in f.get('options', []):
                if opt.get('name') == '$STATUS':
                    print(opt.get('id',''))
                    sys.exit(0)
except Exception:
    pass
" 2>/dev/null)"

if [ -z "$OPT_ID" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    OPT_ID="<option-id>"
  else
    echo "pipeline-status: option '$STATUS' not found in field '$STATUS_FIELD'" >&2
    exit 1
  fi
fi

# ── Resolve (or create) the project item for this issue ──────────────────────
ITEM="$(_gh_safe gh project item-list "$PROJECT_NUM" --owner "$OWNER" --limit 400 --format json \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(next((i['id'] for i in d.get('items',[])
                if i.get('content',{}).get('number') == int('$ISSUE')), ''))
except Exception:
    pass
" 2>/dev/null)"

if [ -z "$ITEM" ]; then
  ISSUE_URL="https://github.com/$REPO/issues/$ISSUE"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] gh project item-add $PROJECT_NUM --owner $OWNER --url $ISSUE_URL"
    ITEM="<item-id>"
  else
    ITEM="$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" \
      --url "$ISSUE_URL" --format json 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")"
    [ -z "$ITEM" ] && { echo "pipeline-status: could not add #$ISSUE to project" >&2; exit 1; }
  fi
fi

# ── Set the status field ──────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] gh project item-edit --id $ITEM --project-id $PROJ_ID --field-id $FIELD_ID --single-select-option-id $OPT_ID"
  echo "#$ISSUE → $STATUS (dry-run)"
else
  gh project item-edit \
    --id "$ITEM" \
    --project-id "$PROJ_ID" \
    --field-id "$FIELD_ID" \
    --single-select-option-id "$OPT_ID" >/dev/null
  echo "#$ISSUE → $STATUS"
fi
