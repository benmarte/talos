#!/usr/bin/env bash
# bootstrap-board.sh — provision/verify the board columns the pipeline relies
# on, per vcs.provider (idempotent).
#
# Usage: bash scripts/bootstrap-board.sh [owner/project_number]
#
# github / github-api: ensures the Status field (board.status_field, default
#   "Status") has every option Talos sets -- In progress, In review, Done,
#   Blocked, plus the conventional Ready -- after board.status_map
#   substitution. GitHub's updateProjectV2Field mutation REPLACES the whole
#   option list, so this script always resends every existing option's
#   name/color/description exactly as fetched, appended with any missing
#   ones, and afterwards re-fetches and verifies every pre-existing option
#   kept its id. An id change is reported loudly and exits non-zero -- that
#   is the failure mode that would otherwise silently blank every card's
#   status column.
#
# azure: never creates states (an org-level process change); reports each
#   configured board.azure_states.* value as present (=) or missing (!)
#   against the work item type's allowed states, and exits non-zero on any
#   miss, naming the config key to fix.
#
# gitlab: GitLab boards are label-driven; verifies the labels the board
#   relies on (pipeline:blocked) exist, prints a note, exits 0.
#
# file provider or board.enabled: false: prints "board disabled", exits 0.
#
# Config keys read (via pipeline-config.sh): vcs.provider, board.enabled,
# board.project_number, board.owner, board.status_field, board.status_map.*,
# vcs.token_env, vcs.repo, vcs.azure.org_url, vcs.azure.project,
# vcs.azure.work_item_type, board.azure_states.*.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "bootstrap-board: config cache helper missing, falling back to per-call parsing" >&2
fi

# The whole point of this script is the logic in pipeline-board-shared.sh
# (owner/project-id resolution, curl-GraphQL + error parsing) -- unlike
# pipeline-status.sh, which pre-dates the extraction and keeps an inline
# fallback, there is nothing useful left to do without it. Abort, same
# guarded-source pattern as bootstrap-labels.sh + pipeline-contract.sh.
if [ -f "$SCRIPT_DIR/pipeline-board-shared.sh" ]; then
  . "$SCRIPT_DIR/pipeline-board-shared.sh"
else
  echo "bootstrap-board: pipeline-board-shared.sh not found next to this script -- aborting" >&2
  exit 1
fi

# ── Positional owner/project_number override ──────────────────────────────
ARG="${1:-}"
ARG_OWNER=""
ARG_PROJECT_NUM=""
if [ -n "$ARG" ]; then
  ARG_OWNER="${ARG%/*}"
  ARG_PROJECT_NUM="${ARG##*/}"
fi

PROVIDER="$(cfg vcs.provider "github")"
BOARD_ENABLED="$(cfg board.enabled "true")"

if [ "$BOARD_ENABLED" = "false" ] || [ "$PROVIDER" = "file" ]; then
  echo "board disabled"
  exit 0
fi

# ── Azure DevOps: validate configured states exist on the work item type ────
if [ "$PROVIDER" = "azure" ]; then
  WTYPE="$(cfg vcs.azure.work_item_type "Product Backlog Item")"
  AZ_ORG="$(cfg vcs.azure.org_url "")"
  AZ_PROJECT="$(cfg vcs.azure.project "")"
  if [ -z "$AZ_ORG" ] || [ -z "$AZ_PROJECT" ]; then
    echo "bootstrap-board: vcs.azure.org_url and vcs.azure.project must be set to validate states" >&2
    exit 1
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "bootstrap-board: az CLI not found; cannot validate work item type states" >&2
    exit 1
  fi
  _WTYPE_URLENC="$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$WTYPE")"
  _AZ_URI="${AZ_ORG%/}/$AZ_PROJECT/_apis/wit/workitemtypes/${_WTYPE_URLENC}?api-version=7.1"
  _AZ_RAW="$(az rest --method get --uri "$_AZ_URI" -o json 2>/dev/null)"
  if [ -z "$_AZ_RAW" ]; then
    echo "bootstrap-board: could not query states for work item type '$WTYPE' (az rest failed -- check vcs.azure.org_url/project and az login)" >&2
    exit 1
  fi
  _AZ_STATES="$(printf '%s' "$_AZ_RAW" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for s in d.get('states', []):
        print(s.get('name', ''))
except Exception:
    pass
" 2>/dev/null)"
  echo "Validating Azure DevOps states for work item type '$WTYPE'"
  _AZ_MISSING=0
  for _entry in \
    "ready|board.azure_states.ready|New" \
    "in_progress|board.azure_states.in_progress|Committed" \
    "in_review|board.azure_states.in_review|Committed" \
    "done|board.azure_states.done|Done" \
    "blocked|board.azure_states.blocked|"
  do
    _key="${_entry%%|*}"; _rest="${_entry#*|}"; _cfgkey="${_rest%%|*}"; _default="${_rest#*|}"
    _val="$(cfg "$_cfgkey" "$_default")"
    if [ -z "$_val" ]; then
      continue
    fi
    if printf '%s\n' "$_AZ_STATES" | grep -qxF "$_val"; then
      echo "  = $_key ($_val)"
    else
      echo "  ! $_key ($_val) missing from '$WTYPE' -- fix: $_cfgkey (states are org-level; this script never creates them)" >&2
      _AZ_MISSING=1
    fi
  done
  [ "$_AZ_MISSING" -eq 1 ] && exit 1
  exit 0
fi

# ── GitLab: boards are label-driven; verify the labels exist ────────────────
if [ "$PROVIDER" = "gitlab" ]; then
  if ! command -v glab >/dev/null 2>&1; then
    echo "bootstrap-board: glab CLI not found; cannot verify board labels" >&2
    exit 1
  fi
  _GL_RAW="$(glab label list --output json 2>/dev/null)"
  _GL_NAMES="$(printf '%s' "$_GL_RAW" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for l in d:
        print(l.get('name', ''))
except Exception:
    pass
" 2>/dev/null)"
  echo "note: GitLab boards are label-driven -- no Status field to provision"
  for _lbl in "pipeline:blocked"; do
    if printf '%s\n' "$_GL_NAMES" | grep -qxF "$_lbl"; then
      echo "  = $_lbl"
    else
      echo "  ! $_lbl missing -- run: bash $SCRIPT_DIR/bootstrap-labels.sh"
    fi
  done
  exit 0
fi

# ── GitHub / github-api: provision the Status field's options ───────────────
PROJECT_NUM="${ARG_PROJECT_NUM:-$(cfg board.project_number "")}"
if [ -z "$PROJECT_NUM" ]; then
  echo "bootstrap-board: board.project_number not configured; nothing to do" >&2
  exit 0
fi

STATUS_FIELD="$(cfg board.status_field "Status")"

USE_TOKEN_PATH=false
TOKEN=""
if [ "$PROVIDER" = "github-api" ] || ! command -v gh >/dev/null 2>&1; then
  USE_TOKEN_PATH=true
  _TOKEN_ENV="$(cfg vcs.token_env "")"
  [ -n "$_TOKEN_ENV" ] && TOKEN="${!_TOKEN_ENV:-}"
  [ -z "$TOKEN" ] && TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$TOKEN" ]; then
    echo "bootstrap-board: GITHUB_TOKEN or GH_TOKEN required for github-api board bootstrap" >&2
    exit 1
  fi
fi

OWNER="$(_board_resolve_owner "$USE_TOKEN_PATH" "$ARG_OWNER" "false")"
if [ -z "$OWNER" ]; then
  echo "bootstrap-board: board.owner not set; skipping" >&2
  exit 0
fi

echo "Bootstrapping board Status options for $OWNER project #$PROJECT_NUM"

# _board_fields_query_text PROJ_ID -- GraphQL query text (not yet JSON-wrapped)
# fetching every single-select field's id/name/full option data (id, name,
# color, description) on the project, up to 50 fields (matches the existing
# 50-field cap convention in pipeline-status.sh). The caller filters for the
# matching field name client-side, same as pipeline-status.sh does.
_board_fields_query_text() {
  local _proj_id_json
  _proj_id_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1")"
  printf 'query{node(id:%s){... on ProjectV2{fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name color description}}}}}}}' \
    "$_proj_id_json"
}

# _board_query_body QUERY_TEXT -- wraps QUERY_TEXT as the {"query": ...} JSON
# body curl needs, safely escaped via Python's json.dumps.
_board_query_body() {
  python3 -c "
import json, sys
print(json.dumps({'query': sys.argv[1]}))
" "$1"
}

# _board_run_query QUERY_TEXT -- runs QUERY_TEXT over whichever transport is
# active (gh api graphql, or curl + token) and prints the raw JSON response
# on stdout. A curl response embeds GraphQL errors in a normal 200 body
# (top-level "errors" array); `gh api graphql` instead fails the process
# (non-zero exit, message on stderr) and prints no usable body. Wrap that
# failure into the same {"errors": [...]} shape so every caller can check
# for a problem the same way regardless of transport, via
# _board_gql_error_message -- critical so a failed fetch is never mistaken
# for "zero existing options" (which would re-add every option as brand new
# instead of erroring out).
_board_run_query() {
  local _qtext="$1"
  if [ "$USE_TOKEN_PATH" = "true" ]; then
    _board_gql "$TOKEN" "$(_board_query_body "$_qtext")"
  else
    local _out _errfile _rc
    _errfile="$(mktemp)"
    _out="$(gh api graphql -f query="$_qtext" 2>"$_errfile")"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      python3 -c "
import json, sys
print(json.dumps({'errors': [{'message': sys.argv[1] or 'gh api graphql failed'}]}))
" "$(cat "$_errfile" 2>/dev/null)"
    else
      printf '%s' "$_out"
    fi
    rm -f "$_errfile"
  fi
}

# 1. Resolve project id
if [ "$USE_TOKEN_PATH" = "true" ]; then
  PROJ_ID="$(_board_resolve_project_id_token "$PROJECT_NUM" "$OWNER" "$TOKEN")"
  if [ -z "$PROJ_ID" ]; then
    _ERR="$(_board_gql_error_message "$_BOARD_LAST_GQL_RAW")"
    echo "bootstrap-board: could not resolve project #$PROJECT_NUM for owner '$OWNER'${_ERR:+: $_ERR}" >&2
    exit 1
  fi
else
  PROJ_ID="$(_board_resolve_project_id_gh "$PROJECT_NUM" "$OWNER")"
  if [ -z "$PROJ_ID" ]; then
    echo "bootstrap-board: could not resolve project #$PROJECT_NUM for owner '$OWNER'" >&2
    exit 1
  fi
fi

# _board_parse_field RAW_JSON FIELD_NAME -- prints "field_id\n<options JSON array>"
# on success (options JSON array element: {id,name,color,description}), or
# nothing if the field isn't present.
_board_parse_field() {
  FNAME="$2" python3 -c "
import json, sys, os
try:
    d = json.loads(sys.argv[1])
    fname = os.environ['FNAME']
    for f in d['data']['node']['fields']['nodes']:
        if f and f.get('name') == fname:
            print(f.get('id', ''))
            print(json.dumps(f.get('options', [])))
            sys.exit(0)
except Exception:
    pass
" "$1"
}

# 2. Fetch the Status field (id + full option fidelity)
_RAW="$(_board_run_query "$(_board_fields_query_text "$PROJ_ID")")"
_ERR="$(_board_gql_error_message "$_RAW")"
if [ -n "$_ERR" ]; then
  echo "bootstrap-board: GraphQL error fetching fields: $_ERR" >&2
  exit 1
fi
_FIELD_DATA="$(_board_parse_field "$_RAW" "$STATUS_FIELD")"
FIELD_ID="$(printf '%s' "$_FIELD_DATA" | sed -n '1p')"
EXISTING_OPTIONS_JSON="$(printf '%s' "$_FIELD_DATA" | sed -n '2p')"

if [ -z "$FIELD_ID" ]; then
  echo "bootstrap-board: status field '$STATUS_FIELD' not found on project #$PROJECT_NUM -- create the field first (this script only manages its options)" >&2
  exit 1
fi

# 3. Compute the desired option list: every existing option (unchanged) plus
# any of Talos's required statuses (after board.status_map substitution)
# that aren't present yet. Default colors are this script's own choice for
# newly-created options only -- existing options are never recolored.
declare -a REQUIRED_MAPPED=()
declare -a REQUIRED_COLORS=("GRAY" "YELLOW" "PURPLE" "GREEN" "RED")
for _base in "Ready" "In progress" "In review" "Done" "Blocked"; do
  REQUIRED_MAPPED+=("$(cfg "board.status_map.$_base" "$_base")")
done

_MISSING_JSON="$(EXISTING_JSON="$EXISTING_OPTIONS_JSON" \
  REQUIRED_NAMES="$(printf '%s\n' "${REQUIRED_MAPPED[@]}")" \
  REQUIRED_COLORS="$(printf '%s\n' "${REQUIRED_COLORS[@]}")" python3 -c "
import json, os
existing = json.loads(os.environ['EXISTING_JSON'] or '[]')
existing_names = {o.get('name') for o in existing}
names = os.environ['REQUIRED_NAMES'].splitlines()
colors = os.environ['REQUIRED_COLORS'].splitlines()
missing = [{'name': n, 'color': c, 'description': ''}
           for n, c in zip(names, colors) if n not in existing_names]
print(json.dumps(missing))
")"
_MISSING_NAMES="$(printf '%s' "$_MISSING_JSON" | python3 -c "
import json, sys
for o in json.load(sys.stdin):
    print(o['name'])
" 2>/dev/null)"

if [ "$_MISSING_JSON" = "[]" ]; then
  for _m in "${REQUIRED_MAPPED[@]}"; do
    echo "  = $_m"
  done
  echo "Done. Status field already has every required option."
  exit 0
fi

# 4. Send the updateProjectV2Field mutation with the FULL option list
#    (existing, unchanged, exactly as fetched -- first -- then the missing
#    ones). This is the step GitHub's API treats as a wholesale replace.
#    ProjectV2SingleSelectFieldOptionInput accepts an optional `id`, which is
#    what actually preserves identity: verified against a real (throwaway)
#    project that omitting it reassigns a fresh id to EVERY option, including
#    ones resent with byte-identical name/color/description -- so every
#    pre-existing option's id is included here, and only the newly-added
#    ones are left for GitHub to assign. The re-fetch + compare below (step
#    5) is the safety net for this working as intended, not a substitute for
#    it.
_DESIRED_OPTIONS_JSON="$(EXISTING_JSON="$EXISTING_OPTIONS_JSON" MISSING_JSON="$_MISSING_JSON" python3 -c "
import json, os
existing = json.loads(os.environ['EXISTING_JSON'] or '[]')
missing = json.loads(os.environ['MISSING_JSON'] or '[]')
desired = [{'id': o.get('id', ''), 'name': o.get('name', ''), 'color': o.get('color', 'GRAY'),
            'description': o.get('description') or ''} for o in existing]
desired += missing
print(json.dumps(desired))
")"

_OPTIONS_LITERAL="$(printf '%s' "$_DESIRED_OPTIONS_JSON" | python3 -c "
import json, sys
opts = json.load(sys.stdin)
parts = []
for o in opts:
    name = json.dumps(o.get('name', ''))
    desc = json.dumps(o.get('description') or '')
    color = o.get('color', 'GRAY')
    oid = o.get('id')
    id_part = ('id:%s,' % json.dumps(oid)) if oid else ''
    parts.append('{%sname:%s,color:%s,description:%s}' % (id_part, name, color, desc))
print('[' + ','.join(parts) + ']')
")"

_FIELD_ID_JSON="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$FIELD_ID")"
_MUTATION="mutation{updateProjectV2Field(input:{fieldId:$_FIELD_ID_JSON singleSelectOptions:$_OPTIONS_LITERAL}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}"

_MUT_RAW="$(_board_run_query "$_MUTATION")"
_MUT_ERR="$(_board_gql_error_message "$_MUT_RAW")"
if [ -n "$_MUT_ERR" ]; then
  echo "bootstrap-board: GraphQL error updating field options: $_MUT_ERR" >&2
  exit 1
fi

# 5. Verify: re-fetch and confirm every pre-existing option kept its id.
# GitHub's singleSelectOptions replace does not accept an id to request
# identity preservation -- resending identical name/color/description is
# the only lever this script has, so the safety net is this check, not
# trust in the request.
_VERIFY_RAW="$(_board_run_query "$(_board_fields_query_text "$PROJ_ID")")"
_VERIFY_ERR="$(_board_gql_error_message "$_VERIFY_RAW")"
if [ -n "$_VERIFY_ERR" ]; then
  echo "bootstrap-board: GraphQL error verifying field options after update: $_VERIFY_ERR" >&2
  exit 1
fi
_VERIFY_DATA="$(_board_parse_field "$_VERIFY_RAW" "$STATUS_FIELD")"
_VERIFY_OPTIONS_JSON="$(printf '%s' "$_VERIFY_DATA" | sed -n '2p')"

_DRIFT="$(BEFORE_JSON="$EXISTING_OPTIONS_JSON" AFTER_JSON="$_VERIFY_OPTIONS_JSON" python3 -c "
import json, os
before = json.loads(os.environ['BEFORE_JSON'] or '[]')
after = json.loads(os.environ['AFTER_JSON'] or '[]')
after_by_name = {o.get('name'): o.get('id') for o in after}
drifted = []
for o in before:
    name = o.get('name')
    old_id = o.get('id')
    new_id = after_by_name.get(name)
    if new_id != old_id:
        drifted.append('%s (%s -> %s)' % (name, old_id, new_id))
print('\n'.join(drifted))
")"

if [ -n "$_DRIFT" ]; then
  echo "bootstrap-board: FATAL -- one or more pre-existing options changed id after the update (this would silently blank every card's status):" >&2
  printf '%s\n' "$_DRIFT" >&2
  exit 1
fi

# Report only now that the mutation is confirmed safe -- printing "+ name"
# before verification would misleadingly claim success ahead of the id-drift
# check above.
for _m in "${REQUIRED_MAPPED[@]}"; do
  if printf '%s\n' "$_MISSING_NAMES" | grep -qxF "$_m"; then
    echo "  + $_m"
  else
    echo "  = $_m"
  fi
done
echo "Done. Status field verified: every pre-existing option kept its id."
