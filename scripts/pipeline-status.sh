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
#   board.status_map       optional: flat object mapping pipeline status names to
#                          board column names, e.g. {Blocked: "Needs attention"}.
#                          An absent key passes through unchanged; an absent map
#                          produces zero behavioural change.
#
# Env var overrides (take priority over config file):
#   PIPELINE_PROJECT_NUMBER   overrides board.project_number
#   PIPELINE_BOARD_OWNER      overrides board.owner
#   PIPELINE_STATUS_FIELD     overrides board.status_field
#   PIPELINE_REPO             overrides repo (owner/name) for issue URL construction
#   PIPELINE_RUN_ID           when set, scopes the per-run validation sentinel to
#                             this value so multiple pipeline runs share the /tmp dir
#                             without interfering with each other.
#   TALOS_BOARD_MAX_PAGES     overrides the items() pagination page cap (default 50,
#                             i.e. 5000 items at 100/page). A non-positive-integer
#                             value falls back to the default 50 with a warning.
#                             A malformed page (hasNextPage=true with an empty
#                             endCursor) or hitting this cap bails out via
#                             talos:board-unverified instead of looping forever
#                             (#248 follow-up, Rule 11).
#
# Token path (activated when vcs.provider=github-api or gh is absent):
#   All GitHub Projects v2 GraphQL calls are made via curl + GITHUB_TOKEN (or
#   GH_TOKEN). OWNER must be resolvable from config/env when gh is absent.
#
# --dry-run: prints the gh/curl commands that WOULD run without executing them.
#            Always exits 0 — safe to use in CI previews.
#
# Always exits 0 on board-disabled, missing config, or missing status option
# (missing option emits talos:board-unverified on stdout — board failures are
# warnings by design, Rule 11). Exits non-zero only on genuine failures
# (missing project, bad field name) when not dry-run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh, so fall back
# to the old per-call cfg() instead of leaving cfg undefined.
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "pipeline: config cache helper missing, falling back to per-call parsing" >&2
fi

# ── Token-based GraphQL path ──────────────────────────────────────────────────
# Activated when vcs.provider=github-api OR when gh is not on PATH.
# Resolves OWNER from: PIPELINE_BOARD_OWNER > board.owner > first component of vcs.repo.
_USE_TOKEN_PATH=false
_STATUS_TOKEN=""
# Page cap for the items() pagination loop below (#248 follow-up): bounds a
# pathological project (or a malformed page with hasNextPage=true and an
# empty endCursor) so the loop always terminates instead of hanging the
# pipeline stage. Override via TALOS_BOARD_MAX_PAGES.
_MAX_PAGES="${TALOS_BOARD_MAX_PAGES:-50}"
# Validate the override: must be a positive integer, or fall back to the
# default (#248 second follow-up) -- otherwise a malformed value (e.g. a
# non-numeric string) makes the `-gt` cap check below error and evaluate
# false, silently disabling the cap instead of bounding it.
case "$_MAX_PAGES" in
  ''|*[!0-9]*|0) echo "pipeline-status: TALOS_BOARD_MAX_PAGES='$_MAX_PAGES' is not a positive integer; using default 50" >&2; _MAX_PAGES=50 ;;
esac

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

# _gql_error_message RAW_JSON — prints the joined GraphQL error message(s) to
# stdout when RAW_JSON carries a top-level "errors" array (e.g. GitHub's
# EXCESSIVE_PAGINATION when a connection asks for more than 100 records);
# prints nothing when there is none. Never fails the caller's shell (#248).
_gql_error_message() {
  printf '%s' "$1" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    errs = d.get('errors')
    if errs:
        msgs = [e.get('message', '') for e in errs if isinstance(e, dict)]
        msgs = [m for m in msgs if m]
        print('; '.join(msgs) if msgs else 'GraphQL request failed')
except Exception:
    pass
" 2>/dev/null
}

_graphql_token_update() {
  # ── Token GraphQL implementation for all 5 board operations ─────────────────
  # $1=issue $2=status $3=project_num $4=owner $5=status_field $6=repo $7=dry_run $8=mapped_status
  local _issue="$1" _status="$2" _proj_num="$3" _owner="$4" _sfield="$5"
  local _repo="$6" _dry="$7" _mapped_status="${8:-$2}"

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

  # _bail_on_gql_error RAW_JSON — fail-loud convention (#248): on a GraphQL
  # "errors" array from ANY request (project id, fields, items, add, update),
  # print the message to stderr and talos:board-unverified to stdout, never
  # the "#N → status" success line, and exit 0 (Rule 11: board failures never
  # block the pipeline). Must be called directly (not inside a `$(...)`
  # command substitution / pipeline) so `exit` reaches the whole script
  # instead of just a subshell.
  _bail_on_gql_error() {
    local _err
    _err="$(_gql_error_message "$1")"
    if [ -n "$_err" ]; then
      echo "pipeline-status: GraphQL error: $_err" >&2
      echo "talos:board-unverified project=$_proj_num"
      exit 0
    fi
  }

  # 1. Resolve project ID
  local _proj_id _raw
  _raw="$(_gql "{\"query\":\"query{user(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}")"
  _bail_on_gql_error "$_raw"
  _proj_id="$(printf '%s' "$_raw" | python3 -c "
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
    _raw="$(_gql "{\"query\":\"query{organization(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}")"
    _bail_on_gql_error "$_raw"
    _proj_id="$(printf '%s' "$_raw" | python3 -c "
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

  # 2. Resolve field ID and option ID (using mapped status name)
  local _field_data _field_id _opt_id
  _raw="$(_gql "{\"query\":\"query{node(id:\\\"$_proj_id\\\"){...on ProjectV2{fields(first:50){nodes{...on ProjectV2SingleSelectField{id name options{id name}}}}}}}\"}")"
  _bail_on_gql_error "$_raw"
  _field_data="$(printf '%s' "$_raw" | SFIELD="$_sfield" SSTATUS="$_mapped_status" python3 -c "
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

  # 3. Resolve (or add) issue item in project — ALWAYS before option-ID check.
  # Paginated (#248): GitHub rejects items(first:>100) with EXCESSIVE_PAGINATION,
  # so walk pages of 100 via pageInfo{hasNextPage endCursor} until the issue is
  # found or pages run out (a 108-item project needs 2 pages at 100/page).
  # Bounded (#248 follow-up): a malformed page can report hasNextPage=true with
  # a null/empty endCursor, which would otherwise re-issue the identical query
  # forever. Guard against both that case and a pathological project by
  # capping at $_MAX_PAGES pages and bailing out via talos:board-unverified
  # (Rule 11: board failures never block the pipeline) instead of looping.
  local _issue_url="https://github.com/$_repo/issues/$_issue"
  local _item_id="" _cursor="" _has_next="true" _after_clause _page_data
  local _page_count=0
  while [ "$_has_next" = "true" ]; do
    _page_count=$((_page_count + 1))
    if [ "$_page_count" -gt "$_MAX_PAGES" ]; then
      echo "pipeline-status: items() pagination exhausted after $_MAX_PAGES pages for project #$_proj_num; giving up" >&2
      echo "talos:board-unverified project=$_proj_num"
      exit 0
    fi
    _after_clause=""
    [ -n "$_cursor" ] && _after_clause=" after:\\\"$_cursor\\\""
    _raw="$(_gql "{\"query\":\"query{node(id:\\\"$_proj_id\\\"){...on ProjectV2{items(first:100$_after_clause){nodes{id content{...on Issue{number}}} pageInfo{hasNextPage endCursor}}}}}\"}")"
    _bail_on_gql_error "$_raw"
    _page_data="$(printf '%s' "$_raw" | ISSUE_NUM="$_issue" python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    n = int(os.environ['ISSUE_NUM'])
    items = d['data']['node']['items']
    found = ''
    for item in items.get('nodes', []):
        if item and item.get('content', {}).get('number') == n:
            found = item['id']
            break
    page_info = items.get('pageInfo') or {}
    print(found)
    print('true' if page_info.get('hasNextPage') else 'false')
    print(page_info.get('endCursor') or '')
except Exception:
    print('')
    print('false')
    print('')
" 2>/dev/null)"
    _item_id="$(printf '%s' "$_page_data" | sed -n '1p')"
    _has_next="$(printf '%s' "$_page_data" | sed -n '2p')"
    _cursor="$(printf '%s' "$_page_data" | sed -n '3p')"
    [ -n "$_item_id" ] && break
    if [ "$_has_next" = "true" ] && [ -z "$_cursor" ]; then
      echo "pipeline-status: items() pageInfo.hasNextPage=true but endCursor is empty for project #$_proj_num; giving up" >&2
      echo "talos:board-unverified project=$_proj_num"
      exit 0
    fi
  done

  if [ -z "$_item_id" ]; then
    if [ "$_dry" = "true" ]; then
      echo "[dry-run] token-graphql: addProjectV2ItemByContentId for $_issue_url"
      _item_id="<item-id>"
    else
      local _node_id
      _node_id="$(curl -sS -H "Authorization: Bearer $_STATUS_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$_repo/issues/$_issue" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('node_id',''))" 2>/dev/null)"
      _raw="$(_gql "{\"query\":\"mutation{addProjectV2ItemByContentId(input:{projectId:\\\"$_proj_id\\\" contentId:\\\"$_node_id\\\"}) {item{id}}}\"}")"
      _bail_on_gql_error "$_raw"
      _item_id="$(printf '%s' "$_raw" | python3 -c "
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

  # 4. Check option ID — missing option is a warning, not fatal (Rule 11)
  if [ -z "$_opt_id" ] || [ "$_opt_id" = "$_field_id" ]; then
    if [ "$_dry" = "true" ]; then
      _opt_id="<option-id>"
    else
      echo "talos:board-unverified project=$_proj_num"
      echo "pipeline-status: option '$_mapped_status' not found in field '$_sfield' on project #$_proj_num; item added to board in default column" >&2
      exit 0
    fi
  fi

  # 5. Set the status field
  if [ "$_dry" = "true" ]; then
    echo "[dry-run] token-graphql: updateProjectV2ItemFieldValue project=$_proj_id item=$_item_id field=$_field_id option=$_opt_id"
    echo "#$_issue → $_status (dry-run via token-graphql)"
  else
    _raw="$(_gql "{\"query\":\"mutation{updateProjectV2ItemFieldValue(input:{projectId:\\\"$_proj_id\\\" itemId:\\\"$_item_id\\\" fieldId:\\\"$_field_id\\\" value:{singleSelectOptionId:\\\"$_opt_id\\\"}}){projectV2Item{id}}}\"}")"
    _bail_on_gql_error "$_raw"
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

# ── Azure DevOps: the Kanban column follows the work item State ───────────────
# ADO has no separate board "status field" like GitHub Projects — a work item's
# System.State drives its board column. Map the pipeline's status name to an ADO
# state. States are process-specific (Scrum defaults shown); override any of them
# via board.azure_states.{ready,in_progress,in_review,done,blocked} in the config.
PROVIDER="$(cfg vcs.provider "github")"
if [ "$PROVIDER" = "azure" ]; then
  case "$(printf '%s' "$STATUS" | tr '[:upper:]' '[:lower:]')" in
    ready|"to do")   AZ_STATE="$(cfg board.azure_states.ready "New")" ;;
    "in progress")   AZ_STATE="$(cfg board.azure_states.in_progress "Committed")" ;;
    "in review")     AZ_STATE="$(cfg board.azure_states.in_review "Committed")" ;;
    done)            AZ_STATE="$(cfg board.azure_states.done "Done")" ;;
    blocked)         AZ_STATE="$(cfg board.azure_states.blocked "")" ;;
    *)               AZ_STATE="" ;;
  esac
  if [ -z "$AZ_STATE" ]; then
    echo "#$ISSUE → $STATUS (no ADO state mapping; leaving work-item state unchanged)" >&2
    exit 0
  fi
  AZ_ORG="$(cfg vcs.azure.org_url "")"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] az boards work-item update --id $ISSUE --state $AZ_STATE${AZ_ORG:+ --org $AZ_ORG}"
    echo "#$ISSUE → $STATUS (ADO state: $AZ_STATE, dry-run)"
    exit 0
  fi
  if az boards work-item update --id "$ISSUE" --state "$AZ_STATE" ${AZ_ORG:+--org "$AZ_ORG"} -o none 2>/dev/null; then
    echo "#$ISSUE → $STATUS (ADO state: $AZ_STATE)"
  else
    echo "pipeline-status: could not set #$ISSUE to state '$AZ_STATE' (invalid for this work item type?)" >&2
  fi
  exit 0
fi

# ── Read config with env var overrides ───────────────────────────────────────
PROJECT_NUM="${PIPELINE_PROJECT_NUMBER:-$(cfg board.project_number "")}"
if [ -z "$PROJECT_NUM" ]; then
  echo "pipeline-status: board.project_number not configured; skipping" >&2
  exit 0
fi

STATUS_FIELD="${PIPELINE_STATUS_FIELD:-$(cfg board.status_field "Status")}"

# ── Apply board.status_map ────────────────────────────────────────────────────
# Map the pipeline status name to the operator's board column name.
# An absent key passes through unchanged; an absent map changes nothing.
MAPPED_STATUS="$(cfg "board.status_map.$STATUS" "$STATUS")"

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
    "$STATUS_FIELD" "$REPO" "$DRY_RUN" "$MAPPED_STATUS"
  exit $?
fi

# ── gh CLI path (original) ────────────────────────────────────────────────────
# All discovery calls are wrapped to never abort in dry-run mode.
_gh_safe() { "$@" 2>/dev/null || echo ""; }

# Set when any talos:board-unverified marker fires during this invocation, so
# the "#N → status" success line is never printed alongside it (#252).
_BOARD_UNVERIFIED=false

# _gh_fail_board MESSAGE — fail-loud convention for the gh CLI path (Rule 11),
# mirroring _bail_on_gql_error in the token path (#248): on a non-zero exit
# from `gh project item-add`/`item-edit`, print MESSAGE to stderr and
# talos:board-unverified to stdout, never the "#N → status" success line,
# delete the sentinel so the next call re-validates instead of retrying
# forever with the same (possibly stale) cached ids, and exit 0.
_gh_fail_board() {
  local _msg="$1"
  [ -n "$_msg" ] && echo "pipeline-status: $_msg" >&2
  echo "talos:board-unverified project=$PROJECT_NUM"
  rm -f "$_BOARD_SENTINEL" 2>/dev/null || true
  exit 0
}

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

# ── Fetch field data (with per-run sentinel caching) ─────────────────────────
# The sentinel file caches the field-list JSON for the duration of a pipeline
# run, ensuring project field-list is called at most once per run (not once per
# status update). It also gates the startup validation so the warning fires once.
# Sentinel key: owner + project number + optional PIPELINE_RUN_ID for multi-run
# isolation (#252: the key MUST include the owner -- a project number alone is
# not globally unique, so two owners with the same project number used to
# silently share (and poison) each other's cached field ids).
#
# Security: the cache lives in a user-private directory (not world-writable /tmp)
# and is validated before use: regular file, owned by current user, not
# group/world-writable, and contains valid JSON with the expected shape, and
# (#252) tagged with the project node id it was fetched for -- a cached file
# whose project id no longer matches the freshly resolved PROJ_ID is treated
# as a miss (see _read_sentinel below) so a stale/foreign cache never leaks
# field ids across projects.
_CACHE_DIR="${XDG_RUNTIME_DIR:-${HOME}/.cache}/talos"
_SAFE_OWNER="$(printf '%s' "$OWNER" | tr -c 'A-Za-z0-9_-' '_')"
_BOARD_SENTINEL="${_CACHE_DIR}/board-validated-${_SAFE_OWNER}-${PROJECT_NUM}${PIPELINE_RUN_ID:+-${PIPELINE_RUN_ID}}"

# Create the cache directory with restrictive permissions (user-only).
# Handle existing directory with potentially wrong permissions gracefully.
if ! install -d -m 700 "$_CACHE_DIR" 2>/dev/null; then
  mkdir -p "$_CACHE_DIR" 2>/dev/null || true
  chmod 700 "$_CACHE_DIR" 2>/dev/null || true
fi

# _read_sentinel — read and validate the sentinel cache file.
# $1=path $2=expected project node id (freshly resolved PROJ_ID). Returns the
# cached FIELD_DATA on stdout if the file passes all checks; exits with code 1
# if any check fails (caller falls back to fresh lookup).
_read_sentinel() {
  local _f="$1" _expected_proj_id="$2"
  # Must be a regular file
  [ -f "$_f" ] || return 1

  # Must be owned by the current user.
  # Use python3 for portability (stat flags differ between BSD and GNU).
  _owner_uid="$(python3 -c "import os,sys; st=os.stat(sys.argv[1]); print(st.st_uid)" "$_f" 2>/dev/null)" || return 1
  _my_uid="$(id -u)" || return 1
  [ "$_owner_uid" = "$_my_uid" ] || return 1

  # Must not be group- or world-writable (mode bits 0g22 → 0022 mask)
  _file_mode="$(python3 -c "import os,sys,stat; st=os.stat(sys.argv[1]); print(oct(stat.S_IMODE(st.st_mode)))" "$_f" 2>/dev/null)" || return 1
  case "$_file_mode" in
    *[2367])   # group- or world-writable bit set
      return 1 ;;
  esac
  # More thorough: check write bits using python
  python3 -c "
import os, sys, stat
st = os.stat(sys.argv[1])
mode = stat.S_IMODE(st.st_mode)
if mode & (stat.S_IWGRP | stat.S_IWOTH):
    sys.exit(1)
sys.exit(0)
" "$_f" 2>/dev/null || return 1

  # Must contain valid JSON with expected shape: {fields: [{name, id, options:[]}],
  # project_id: "..."}, and (#252) the embedded project_id must match the
  # freshly resolved project -- otherwise this is a stale/foreign cache (e.g.
  # left over from a different owner's identically-numbered project) and must
  # be discarded rather than silently reused.
  _cached="$(cat "$_f")"
  EXPECTED_PROJ_ID="$_expected_proj_id" python3 -c "
import sys, json, os
try:
    d = json.loads(sys.argv[1])
    if not isinstance(d, dict):
        sys.exit(1)
    fields = d.get('fields')
    if not isinstance(fields, list):
        sys.exit(1)
    for f in fields:
        if not isinstance(f, dict):
            sys.exit(1)
        if 'name' not in f or 'id' not in f:
            sys.exit(1)
        if not isinstance(f.get('options', []), list):
            sys.exit(1)
    expected = os.environ.get('EXPECTED_PROJ_ID', '')
    if not expected or d.get('project_id') != expected:
        sys.exit(1)
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$_cached" 2>/dev/null || return 1

  printf '%s' "$_cached"
}

_CACHED_FIELD_DATA="$(_read_sentinel "$_BOARD_SENTINEL" "$PROJ_ID" 2>/dev/null)"
if [ -n "$_CACHED_FIELD_DATA" ]; then
  # Reuse validated cached field data from earlier in this pipeline run
  FIELD_DATA="$_CACHED_FIELD_DATA"
else
  _RAW_FIELD_LIST="$(_gh_safe gh project field-list "$PROJECT_NUM" --owner "$OWNER" --format json)"
  # Tag the field data with the project node id it was fetched for (#252),
  # so a future read can detect and discard a stale/foreign cache instead of
  # trusting a cache keyed only by (owner, project number).
  FIELD_DATA="$(PROJ_ID_TAG="$PROJ_ID" python3 -c "
import sys, json, os
try:
    d = json.loads(sys.argv[1])
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
d['project_id'] = os.environ.get('PROJ_ID_TAG', '')
print(json.dumps(d))
" "$_RAW_FIELD_LIST")"

  # ── Startup validation: check all four required statuses ──────────────────
  # Fires exactly once per run (sentinel written below). Each status is checked
  # after board.status_map substitution so mapped names are validated.
  _MISSING_OPTIONS=""
  for _req_status in "In progress" "In review" "Done" "Blocked"; do
    _req_mapped="$(cfg "board.status_map.$_req_status" "$_req_status")"
    if ! SF="$STATUS_FIELD" SM="$_req_mapped" python3 -c "
import sys, json, os
try:
    import sys
    data = sys.stdin.read()
    d = json.loads(data)
    sf = os.environ['SF']
    sm = os.environ['SM']
    for f in d.get('fields', []):
        if f.get('name') == sf:
            if any(o.get('name') == sm for o in f.get('options', [])):
                sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" <<< "$FIELD_DATA" 2>/dev/null; then
      _MISSING_OPTIONS="${_MISSING_OPTIONS:+$_MISSING_OPTIONS,}$_req_mapped"
    fi
  done

  # Write sentinel with cached field data into the user-private cache directory.
  # Write with mode 0600 so only the current user can read or modify it.
  if [ "$DRY_RUN" = "false" ]; then
    (umask 177 && printf '%s' "$FIELD_DATA" > "$_BOARD_SENTINEL") 2>/dev/null || true
  fi

  if [ -n "$_MISSING_OPTIONS" ]; then
    # Marker: project number is a validated integer — safe to embed in stdout marker.
    # Missing option names go to stderr only (not in the machine-readable marker).
    echo "talos:board-unverified project=$PROJECT_NUM"
    echo "pipeline-status: board status options missing from project #$PROJECT_NUM: $_MISSING_OPTIONS" >&2
    # #252: this startup validation checks all four required statuses, not just
    # the one requested in this call -- so it can fire (e.g. "Blocked" missing)
    # even when the current call's own status resolves and updates fine. Track
    # that so the "#N → status" success line further down is suppressed rather
    # than printing alongside talos:board-unverified.
    _BOARD_UNVERIFIED=true
  fi
fi

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

# Look up option ID using the mapped status name
OPT_ID="$(printf '%s' "$FIELD_DATA" | SM="$MAPPED_STATUS" python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
    sm = os.environ['SM']
    for f in d.get('fields', []):
        if f.get('name') == '$STATUS_FIELD':
            for opt in f.get('options', []):
                if opt.get('name') == sm:
                    print(opt.get('id',''))
                    sys.exit(0)
except Exception:
    pass
" 2>/dev/null)"

# ── Resolve (or create) the project item for this issue ──────────────────────
# Item-add happens BEFORE the option-ID check so the issue always lands on the
# board even when the status option is missing (a wrong column is far more useful
# than an absent item).
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
    # #252: capture gh's own exit status and stderr instead of only checking
    # whether the parsed item id came out empty, so a failed item-add is
    # reported the same way a failed item-edit is (talos:board-unverified,
    # sentinel cleared, exit 0 -- Rule 11) rather than silently falling
    # through to whatever happened to be on stdout.
    _ITEM_ADD_ERR="$(mktemp)"
    ITEM_JSON="$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" \
      --url "$ISSUE_URL" --format json 2>"$_ITEM_ADD_ERR")"
    _ITEM_ADD_RC=$?
    _ITEM_ADD_STDERR="$(cat "$_ITEM_ADD_ERR" 2>/dev/null)"
    rm -f "$_ITEM_ADD_ERR"
    if [ "$_ITEM_ADD_RC" -ne 0 ]; then
      _gh_fail_board "gh project item-add failed: $_ITEM_ADD_STDERR"
    fi
    ITEM="$(printf '%s' "$ITEM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
    [ -z "$ITEM" ] && { echo "pipeline-status: could not add #$ISSUE to project" >&2; exit 1; }
  fi
fi

# ── Check option ID — missing option is a warning, not fatal (Rule 11) ───────
if [ -z "$OPT_ID" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    OPT_ID="<option-id>"
  else
    # Marker: project number is a validated integer — safe to embed in stdout marker.
    # Missing option name goes to stderr only.
    echo "talos:board-unverified project=$PROJECT_NUM"
    echo "pipeline-status: option '$MAPPED_STATUS' not found in field '$STATUS_FIELD' on project #$PROJECT_NUM; item added to board in default column" >&2
    exit 0
  fi
fi

# ── Set the status field ──────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] gh project item-edit --id $ITEM --project-id $PROJ_ID --field-id $FIELD_ID --single-select-option-id $OPT_ID"
  [ "$_BOARD_UNVERIFIED" = "true" ] || echo "#$ISSUE → $STATUS (dry-run)"
else
  # #252: capture gh's exit status instead of discarding it -- a failed
  # item-edit (e.g. a stale/foreign field id from a poisoned cache) used to
  # print the success line regardless. Mirror the token-path fix from #248.
  _ITEM_EDIT_STDERR="$(gh project item-edit \
    --id "$ITEM" \
    --project-id "$PROJ_ID" \
    --field-id "$FIELD_ID" \
    --single-select-option-id "$OPT_ID" 2>&1 >/dev/null)"
  _ITEM_EDIT_RC=$?
  if [ "$_ITEM_EDIT_RC" -ne 0 ]; then
    _gh_fail_board "gh project item-edit failed: $_ITEM_EDIT_STDERR"
  fi
  # #252: the success line must never print alongside a talos:board-unverified
  # marker emitted earlier in this run (e.g. the startup validation found a
  # different status option missing).
  [ "$_BOARD_UNVERIFIED" = "true" ] || echo "#$ISSUE → $STATUS"
fi
