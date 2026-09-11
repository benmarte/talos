#!/usr/bin/env bash
# pipeline-board-shared.sh — GitHub Projects v2 helpers shared by
# pipeline-status.sh (sets an issue's Status column) and bootstrap-board.sh
# (provisions the Status field's options). Extracted (#266) so the two
# scripts share one implementation of "resolve the board owner" and
# "resolve a project's GraphQL node id" instead of each carrying its own
# copy of the same lookup logic.
#
# Source this file (after SCRIPT_DIR is set); every function requires
# cfg() to already be defined in the caller's scope for _board_resolve_owner.
# Guarded like every other pipeline-*.sh's cfg-cache source (a partial
# install/sync may not yet ship this file) — callers must fall back
# gracefully if sourcing this fails, same pattern as pipeline-cfg-cache.sh.

# _board_gql TOKEN QUERY_JSON — POST a GraphQL request to the GitHub API via
# curl using TOKEN for auth. Prints the raw JSON response body on stdout.
_board_gql() {
  local _token="$1" _query="$2"
  curl -sS \
    -H "Authorization: Bearer $_token" \
    -H "Content-Type: application/json" \
    -d "$_query" \
    "https://api.github.com/graphql"
}

# _board_gql_error_message RAW_JSON — prints the joined GraphQL error
# message(s) on stdout when RAW_JSON carries a top-level "errors" array
# (e.g. GitHub's EXCESSIVE_PAGINATION when a connection asks for more than
# 100 records); prints nothing when there is none. Never fails the caller's
# shell.
_board_gql_error_message() {
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

# _board_resolve_owner USE_TOKEN_PATH ENV_OVERRIDE DRY_RUN — resolves the
# project owner: ENV_OVERRIDE > board.owner config > (gh repo view, only
# when gh is the active transport and this isn't a dry run) > first path
# component of vcs.repo. Requires cfg() to already be defined in the
# caller's scope. Prints the resolved owner (possibly empty) on stdout.
_board_resolve_owner() {
  local _use_token_path="$1" _env_override="$2" _dry_run="${3:-false}"
  local _default_owner=""
  if [ "$_use_token_path" = "false" ] && [ "$_dry_run" = "false" ]; then
    _default_owner="$(gh repo view --json owner -q .owner.login 2>/dev/null || echo "")"
  fi
  if [ -z "$_default_owner" ]; then
    local _vcs_repo
    _vcs_repo="$(cfg vcs.repo "")"
    [ -n "$_vcs_repo" ] && _default_owner="${_vcs_repo%%/*}"
  fi
  printf '%s' "${_env_override:-$(cfg board.owner "$_default_owner")}"
}

# _board_resolve_project_id_gh PROJECT_NUM OWNER — gh CLI path. Prints the
# project's GraphQL node id on stdout, or nothing if not found.
_board_resolve_project_id_gh() {
  local _proj_num="$1" _owner="$2"
  gh project list --owner "$_owner" --format json --limit 50 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    n = int('$_proj_num')
    for p in d.get('projects', []):
        if p.get('number') == n:
            print(p.get('id',''))
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null
}

# _board_resolve_project_id_token PROJECT_NUM OWNER TOKEN — token
# (curl + GraphQL) path. Tries the owner as a user, then (only when the
# user attempt came back clean, i.e. no top-level GraphQL "errors" array —
# an actual error, e.g. a rate limit or a bad token, is not retried as an
# organization lookup) as an organization. Prints the project's GraphQL
# node id on stdout, or nothing if not found. Sets _BOARD_LAST_GQL_RAW to
# the raw response of whichever attempt ran last, so the caller can extract
# an error message (via _board_gql_error_message) when the id comes back
# empty.
_BOARD_LAST_GQL_RAW=""
_board_resolve_project_id_token() {
  local _proj_num="$1" _owner="$2" _token="$3"
  local _raw _id
  _raw="$(_board_gql "$_token" "{\"query\":\"query{user(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}")"
  _BOARD_LAST_GQL_RAW="$_raw"
  if [ -n "$(_board_gql_error_message "$_raw")" ]; then
    printf ''
    return 0
  fi
  _id="$(printf '%s' "$_raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['data']['user']['projectV2']['id'])
except Exception:
    pass
" 2>/dev/null)"
  if [ -z "$_id" ]; then
    _raw="$(_board_gql "$_token" "{\"query\":\"query{organization(login:\\\"$_owner\\\"){projectV2(number:$_proj_num){id}}}\"}")"
    _BOARD_LAST_GQL_RAW="$_raw"
    _id="$(printf '%s' "$_raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['data']['organization']['projectV2']['id'])
except Exception:
    pass
" 2>/dev/null)"
  fi
  printf '%s' "$_id"
}
