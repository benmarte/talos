#!/usr/bin/env bash
# pipeline-status.sh — set an issue's Status field on a GitHub Project.
#
# Usage: pipeline-status.sh [--dry-run] <issue-number> <status-display-name>
#
# Examples:
#   pipeline-status.sh 42 "In progress"
#   pipeline-status.sh --dry-run 42 "Done"
#
# Status names must match the configured display names in .claude-pipeline.yaml
# (e.g. "Ready", "In progress", "In review", "Done", "Blocked").
#
# Config keys read (via pipeline-config.sh):
#   board.enabled          default: true
#   board.project_number   required when board is enabled
#   board.owner            default: repo owner detected from gh
#   board.status_field     default: Status
#
# Env var overrides (take priority over config file):
#   PIPELINE_PROJECT_NUMBER   overrides board.project_number
#   PIPELINE_BOARD_OWNER      overrides board.owner
#   PIPELINE_STATUS_FIELD     overrides board.status_field
#   PIPELINE_REPO             overrides repo (owner/name) for issue URL construction
#
# --dry-run: prints the gh commands that WOULD run without executing them.
#            Always exits 0 — safe to use in CI previews.
#
# Always exits 0 on board-disabled or missing config; exits non-zero only on
# genuine gh failures (missing project, bad field name, etc.) when not dry-run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }

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

# Owner: env var > config > detected from gh
DEFAULT_OWNER=""
if [ "$DRY_RUN" = "false" ]; then
  DEFAULT_OWNER="$(gh repo view --json owner -q .owner.login 2>/dev/null || echo "")"
fi
OWNER="${PIPELINE_BOARD_OWNER:-$(cfg board.owner "$DEFAULT_OWNER")}"

STATUS_FIELD="${PIPELINE_STATUS_FIELD:-$(cfg board.status_field "Status")}"

REPO="${PIPELINE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "OWNER/REPO")}"

if [ -z "$OWNER" ]; then
  echo "pipeline-status: board.owner not set; skipping" >&2
  exit 0
fi

# ── Discover project / field / option IDs ────────────────────────────────────
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
