#!/usr/bin/env bash
# pipeline-vcs.sh — VCS provider adapter for claude-pipeline.
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
#
# Config keys (from .claude-pipeline.yaml via pipeline-config.sh):
#   vcs.provider          github | gitlab | azure | file   (default: github)
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
#   github  — battle-tested; requires `gh` CLI authenticated.
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

# Auto-detect repo for github/gitlab if not set
if [ -z "$REPO" ] && [ "$PROVIDER" != "file" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
    || git remote get-url origin 2>/dev/null \
    | sed 's|.*github.com[:/]||; s|.*gitlab.com[:/]||; s|\.git$||' \
    || echo "")"
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
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
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
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# AZURE DEVOPS ADAPTER  (best-effort)
#   Prerequisites:
#     az extension add --name azure-devops
#     az devops configure --defaults organization=<org_url> project=<project>
#   Or set vcs.azure.org_url + vcs.azure.project in .claude-pipeline.yaml
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
      ([org_arg] if org_arg else [])
if dry_run:
    print(f'[dry-run] {" ".join(cmd)}')
else:
    subprocess.run(cmd, check=True)
PYEOF
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
    diff-pr|pr-checks|list-prs|view-pr)
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
  github) _github "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  gitlab) _gitlab "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  azure)  _azure  "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  file)   _file   "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
  *)
    echo "pipeline-vcs: unknown provider '$PROVIDER'. Valid: github | gitlab | azure | file" >&2
    exit 1
    ;;
esac
