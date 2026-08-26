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
#                 <n> --body-file <path>      ...or read the body from a file
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
#              <n> --body-file <path>         ...or read the body from a file
#   find-pr <issue-n> [state]                 Find PRs for an issue (branch has
#                                             issue-<n> or title/body has #<n>).
#                                             state: open (default) | merged | all
#   check-pr-files <n>                        Exit 1 if the PR touches any
#                                             merge.forbidden_files pattern
#   check-closing-keyword <n|branch> <issue>  Exit 1 if the PR body has a closing
#                                             keyword for <issue> while other PRs
#                                             for that issue are still open.
#                                             Fail-open: exits 0 + stdout marker
#                                             if data cannot be fetched.
#   rerun-ci <n>                              Re-run failed CI for the PR head SHA
#   pr-head <n>                               Print the current head SHA for a PR
#   check-approval-sha <n>                    Exit 1 if any approval label was earned
#                                             against a non-current head SHA (stale
#                                             approvals); respects
#                                             merge.approval_waiver_paths config
#   record-attempt <issue-n> <stage>          Record one attempt for the given blocking
#                                             stage on the issue. Reads prior state,
#                                             computes new per-stage count and running
#                                             total, posts a <!-- talos:attempt --> marker
#                                             comment, and prints "stage=<s> count=<k>
#                                             total=<t>" on stdout. Exits non-zero when
#                                             either ceiling would be exceeded.
#   read-attempt <issue-n>                    Print stage/count/total from the most
#                                             recent attempt marker on the issue.
#                                             Exits 0 (prints "stage= count=0 total=0")
#                                             when no marker exists yet.
#   check-attempt <issue-n>                   Exit 1 (and print reason) when EITHER
#                                             ceiling is already reached for the issue;
#                                             exit 0 otherwise. Does NOT record a new
#                                             attempt — use record-attempt for that.
#   assert-sync                               Assert the working tree is clean AND level
#                                             with origin/<base_branch>. Exits 0 (no
#                                             output) on success. Exits 1 with a message
#                                             on dirty tree, behind-origin, or diverged.
#                                             Dirty-tree check runs BEFORE fetch so the
#                                             working tree is never read in a mixed state.
#                                             Used as an orchestrator precondition before
#                                             dispatching non-worktree-isolated stages.
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
#   limits.max_fix_attempts     max consecutive per-stage failures before
#                               pipeline:blocked (default: 3)
#   limits.max_total_dispatches absolute ceiling on total developer dispatches
#                               per issue — never resets (default: 8)
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
ALLOW_CLOSED=false
VERB=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --allow-closed) ALLOW_CLOSED=true ;;
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
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$ALLOW_CLOSED" = "true" ]; then
          echo "[dry-run] gh issue comment $n --body $body (--allow-closed; URL on stdout)"
        else
          echo "[dry-run] gh issue view $n --json state -q .state; gh issue comment $n --body $body (URL on stdout)"
        fi
        return 0
      fi
      local _ci_state_unverified=false
      if [ "$ALLOW_CLOSED" != "true" ]; then
        local _ci_state
        if _ci_state="$(gh issue view "$n" --json state -q .state ${REPO:+--repo "$REPO"} 2>/dev/null)"; then
          case "$_ci_state" in
            CLOSED|closed)
              echo "pipeline-vcs: comment-issue: issue #$n is ${_ci_state} (use --allow-closed to override)" >&2
              exit 1
              ;;
          esac
        else
          echo "pipeline-vcs: warning: could not determine state of issue #$n — proceeding" >&2
          _ci_state_unverified=true
        fi
      fi
      local _ci_url
      _ci_url="$(gh issue comment "$n" --body "$body" ${REPO:+--repo "$REPO"})" || exit 1
      echo "$_ci_url"
      if [ "$_ci_state_unverified" = "true" ]; then
        echo "talos:comment-state-unverified target=issue#$n reason=state-check-failed"
      fi
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
      _run gh pr view "$1" --json number,title,headRefName,labels,url,body \
        ${REPO:+--repo "$REPO"}
      ;;
    list-prs)
      # LANE SCOPING (2026-08-22): filter to PRs targeting THIS config's base_branch, and
      # return baseRefName so callers can verify. Without --base, `gh pr list` is repo-wide:
      # in a multi-lane repo (main + per-LLM experiment branches sharing one remote) a lane's
      # Step-1 reconciliation sees another lane's in-flight PR, adopts it as its own orphaned
      # work, retargets it and merges it into the wrong base. That happened: the qwen lane
      # merged the canonical lane's P0-14 PR (#203, base main) into `qwen`, leaving `main`
      # without its own work and contaminating the experiment.
      _run gh pr list --state open --json number,title,headRefName,baseRefName,labels \
        ${BASE_BRANCH:+--base "$BASE_BRANCH"} ${REPO:+--repo "$REPO"}
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
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$ALLOW_CLOSED" = "true" ]; then
          echo "[dry-run] gh issue comment $n --body $body (--allow-closed; URL on stdout)"
        else
          echo "[dry-run] gh pr view $n --json state -q .state; gh issue comment $n --body $body (URL on stdout)"
        fi
        return 0
      fi
      local _cp_state_unverified=false
      if [ "$ALLOW_CLOSED" != "true" ]; then
        local _cp_state
        if _cp_state="$(gh pr view "$n" --json state -q .state ${REPO:+--repo "$REPO"} 2>/dev/null)"; then
          case "$_cp_state" in
            CLOSED|closed)
              echo "pipeline-vcs: comment-pr: PR #$n is CLOSED (not merged) — use --allow-closed to override" >&2
              exit 1
              ;;
          esac
        else
          echo "pipeline-vcs: warning: could not determine state of PR #$n — proceeding" >&2
          _cp_state_unverified=true
        fi
      fi
      local _cp_url
      _cp_url="$(gh issue comment "$n" --body "$body" ${REPO:+--repo "$REPO"})" || exit 1
      echo "$_cp_url"
      if [ "$_cp_state_unverified" = "true" ]; then
        echo "talos:comment-state-unverified target=pr#$n reason=state-check-failed"
      fi
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
import json, re, sys
n = sys.argv[1]
try: prs = json.load(sys.stdin)
except Exception: prs = []
for pr in prs:
    ref = pr.get('headRefName','')
    hay = pr.get('title','') + ' ' + pr.get('body','')
    branch_match = bool(re.search(r'(?:^|/)issue-' + re.escape(n) + r'(?:-|$)', ref))
    body_match   = bool(re.search(r'#' + re.escape(n) + r'(?!\d)', hay))
    if branch_match or body_match:
        print(json.dumps({k: pr.get(k) for k in ('number','state','title','headRefName')}))
" "$n"
      ;;
    check-pr-files)
      local n="$1"
      # Built-in defaults — always active unless merge.forbidden_files_replace: true.
      # #61 fix: setting merge.forbidden_files now UNIONs with these defaults rather
      # than replacing them wholesale, closing the silent neutering attack surface.
      # .netrc and _netrc are LITERAL patterns (no glob chars); they generate
      # canaries as of #76 (PR #90, commit b1d3199), so wildcard allow entries
      # that match them are rejected. Deferral from issue #78 is resolved.
      local _BUILTIN_DEFAULTS='.env
.env.*
*.pem
*.key
*.p12
*.pfx
*.secrets
secrets.*
*id_rsa*
*id_ecdsa*
*id_ed25519*
*id_dsa*
*.ppk
*.jks
*.keystore
*.pkcs12
*.kdbx
*.ovpn
.netrc
_netrc'
      local patterns _defaults_active
      local _configured _replace
      _configured="$(cfg merge.forbidden_files "")"
      _replace="$(cfg merge.forbidden_files_replace "")"
      if [ -n "$_configured" ] && [ "$_replace" = "true" ]; then
        # Explicit opt-out: operator acknowledged they want replacement behaviour.
        echo "pipeline-vcs: WARNING: merge.forbidden_files_replace=true — built-in secret-protection defaults are SUPPRESSED; only configured patterns are active" >&2
        patterns="$_configured"
        _defaults_active="replaced"
      elif [ -n "$_configured" ]; then
        # Default (union): configured patterns are ADDED to the built-in defaults.
        patterns="$_BUILTIN_DEFAULTS
$_configured"
        _defaults_active="in-force"
      else
        patterns="$_BUILTIN_DEFAULTS"
        _defaults_active="in-force"
      fi
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh pr view $n --json files | match against forbidden patterns"
        return 0
      fi
      # Transparency markers — always emitted on stdout so every run record is
      # auditable.  Values are fixed literals or integers — never interpolated from
      # config text (guards against marker-injection via a crafted config value).
      local _pat_count
      _pat_count="$(printf '%s\n' "$patterns" | grep -c '[^[:space:]]')" || _pat_count=0
      printf '%s' "$_pat_count" | grep -qE '^[0-9]+$' || _pat_count=0
      printf 'talos:forbidden-files-active patterns=%d defaults=%s\n' "$_pat_count" "$_defaults_active"
      [ "$_defaults_active" = "replaced" ] && \
        printf 'talos:forbidden-files-defaults-replaced patterns=%d\n' "$_pat_count"
      # merge.forbidden_files_allow — explicit exclusions, checked BEFORE the deny
      # patterns. Added 2026-08-22: the default `.env.*` correctly guards real dotenv
      # files but over-matches a committed `.env.example` template, which is the file
      # developers copy to `.env` before `docker compose up`. Without an allow list the
      # only way to permit the template is to drop `.env.*` entirely and lose protection
      # for `.env.local`, `.env.production`, etc.
      local allow
      allow="$(cfg merge.forbidden_files_allow "")"
      # Semantic allow-list validation: reject any entry that would exempt a canary path
      # derived from the active deny patterns.  Character-stripping is whack-a-mole —
      # entries like *[!x]* or [a-z]* bypass a strip-* check; matching canaries with the
      # SAME fnmatch rule the gate uses is the only complete fix.  Fail closed: any
      # validation error or unexpected exception must exit non-zero.
      if [ -n "$allow" ]; then
        PATTERNS="$patterns" ALLOW="$allow" python3 -c "
import fnmatch, os, re, sys

patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow    = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]

def pat_to_literal(pat):
    # Replace bracket expressions ([abc], [!abc]) then remaining glob chars with 'x'
    # so the result is a plain filename that the deny pattern was written to match.
    s = re.sub(r'\\[[^\\]]*\\]', 'x', pat)
    return s.replace('*', 'x').replace('?', 'x')

# Build canary paths from the active deny patterns so the check stays correct if
# defaults change.  Three forms per pattern:
#   root      — bare filename         catches bare globs like * and [a-z]*
#   nested    — sub/dir/<name>        catches */* and **/*
#   prefixed  — config/<name>         catches config/* (path check, not basename)
# Build canaries from ALL deny patterns — wildcard and literal alike.  Three
# forms per pattern (root, sub/dir/, config/) test allow globs along all path
# dimensions.  Canaries from a LITERAL deny pattern carry a src_literal tag so
# that an allow entry which is an EXACT string match for that pattern is still
# permitted as a deliberate operator override (e.g. allowing '.env' when '.env'
# is a deny pattern).  A wildcard allow entry (e.g. '*.env' or '?env') that
# happens to match a literal-pattern canary is REJECTED — it is not an explicit
# operator decision.
canaries = []  # list of (canary_path, src_literal_or_None)
for pat in patterns:
    if not re.search(r'[*?\[\]]', pat):
        # Literal deny pattern: canary IS the pattern (no glob chars to expand).
        # Tag with src_literal so exact-match overrides remain permitted.
        canaries.append((pat, pat))
        canaries.append(('sub/dir/' + pat, pat))
        canaries.append(('config/' + pat, pat))
    else:
        lit = pat_to_literal(pat)
        if not lit:
            continue
        canaries.append((lit, None))
        canaries.append(('sub/dir/' + lit, None))
        canaries.append(('config/' + lit, None))

# #64 fix: when canary generation yields an empty set (all-literal deny list),
# fall back to built-in canaries so the validator is never vacuous.
# An empty canary set must NEVER mean every allow entry is permitted.
if not canaries:
    canaries = [('x.env', None), ('sub/dir/x.env', None), ('config/x.env', None),
                ('x.pem', None), ('sub/dir/x.pem', None), ('config/x.pem', None)]

errors = []
for entry in allow:
    for canary, src_literal in canaries:
        # Exact literal override: the operator deliberately listed the guarded filename.
        if src_literal is not None and entry == src_literal:
            continue
        base = os.path.basename(canary)
        if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
            errors.append(
                'pipeline-vcs: ERROR: merge.forbidden_files_allow entry \'' + entry +
                '\' would exempt \'' + canary + '\' — rejected'
            )
            break  # one error per entry is sufficient
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
" || exit 1  # Fail closed: validation error or unexpected exception must block, not pass
      fi
      gh pr view "$n" --json files -q '.files[].path' ${REPO:+--repo "$REPO"} 2>/dev/null \
        | PATTERNS="$patterns" ALLOW="$allow" PAT_COUNT="$_pat_count" DEFAULTS_ACTIVE="$_defaults_active" python3 -c "
import fnmatch, os, sys
patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]
pat_count = os.environ.get('PAT_COUNT', '0')
defaults_active = os.environ.get('DEFAULTS_ACTIVE', 'in-force')
bad = []
for path in (l.strip() for l in sys.stdin if l.strip()):
    base = os.path.basename(path)
    if any(fnmatch.fnmatch(base, a) or fnmatch.fnmatch(path, a) for a in allow):
        continue
    if any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns):
        bad.append(path)
if bad:
    print('FORBIDDEN FILES in PR — human review required before merge:')
    for p in bad: print(f'  {p}')
    sys.exit(1)
print(f'no forbidden files [{pat_count} patterns: defaults={defaults_active}]')
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
    check-closing-keyword)
      # check-closing-keyword <pr_branch_or_number> <issue_N>
      # Exit 0 when safe to merge; exit 1 when the PR body contains a closing
      # keyword for <issue_N> AND other PRs referencing that issue are still
      # OPEN (closing the tracker would orphan in-flight sibling work).
      #
      # Rule 6: the final PR in a multi-PR issue says "Closes #N".  By the time
      # that PR is ready to merge, all siblings are merged — no open siblings
      # exist, so the gate passes.  Only blocks when a sibling is still open.
      #
      # Known limitation: a lone PR that overclaims its deliverables cannot be
      # detected by this gate.  That requires a ledger; nothing ticks one in
      # VCS mode today.
      #
      # FAIL-OPEN: if the PR body or sibling list cannot be fetched, emit a
      # machine-readable marker on stdout and exit 0.  The reason field is a
      # fixed literal — never interpolated from an API response — so a remote
      # error string cannot inject extra output lines.
      local pr_ref="${1:-}" issue_n="${2:-}"
      [ -z "$pr_ref" ]  && { echo "pipeline-vcs: check-closing-keyword: missing PR ref"     >&2; exit 1; }
      [ -z "$issue_n" ] && { echo "pipeline-vcs: check-closing-keyword: missing issue number" >&2; exit 1; }

      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-closing-keyword $pr_ref $issue_n: fetch PR body, look for closing keyword, then find-pr $issue_n open"
        return 0
      fi

      # Repo-scope guard: if $REPO is unresolved we cannot scope the URL/owner#N
      # forms to the current repository — fail open with a fixed-literal marker.
      if [ -z "$REPO" ]; then
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=repo-unresolved"
        return 0
      fi

      # Fetch the PR to get its number and body.
      local pr_json
      pr_json="$(gh pr view "$pr_ref" --json number,body ${REPO:+--repo "$REPO"} 2>/dev/null)"
      if [ -z "$pr_json" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch PR '$pr_ref' — skipping check" >&2
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=pr-fetch-failed"
        return 0
      fi

      # Extract PR number and body via Python (safe JSON parse).
      local pr_number pr_body
      pr_number="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('number',''))")"
      pr_body="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('body',''))")"

      # Check for a closing keyword for #<issue_n> in the PR body.
      # Patterns (case-insensitive):
      #   close/closes/closed/fix/fixes/fixed/resolve/resolves/resolved
      #   followed by optional whitespace and then one of:
      #     #N              — bare, implicitly current repo (unmodified)
      #     repo#N          — single-segment, no slash (unmodified)
      #     owner/repo#N    — scoped to current repo (case-insensitive)
      #     GH-N            — case-insensitive; left-guard prevents digit-prefix collision
      #     https://github.com/<owner>/<repo>/issues/N  — scoped to current repo
      local has_closing
      has_closing="$(printf '%s' "$pr_body" | python3 -c "
import re, sys
body = sys.stdin.read()
n    = sys.argv[1]
repo = sys.argv[2]   # owner/name — already stripped of .git suffix, passed from \$REPO
# Closing keywords (case-insensitive)
kw = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
# Resolve owner and repo name for repo-scoped patterns (case-insensitive).
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
# Reference forms:
#   1. Hash forms — unified with boundary to prevent mid-token matches:
#      (?<!\w)(?<!/) ensures the engine cannot start a match in the middle of
#      a foreign owner/repo token (e.g. the 'repo' segment of 'other/repo#N').
#      Alternation (tried left-to-right):
#        a. owner/repo#N — must match current repo exactly (case-insensitive)
#        b. repo#N — single-segment (no slash), implicitly current-server; unscoped
#        c. #N — bare form (empty prefix)
#   2. GH-N  case-insensitive; left-guard prevents digit-prefix collision
#   3. URL — scoped to current repo (case-insensitive on owner/name)
ref_hash = (
    r'(?<!\w)(?<!/)(?:'
    + r'(?i:' + owner_esc + r'/' + name_esc + r')'   # 1a: owner/repo#N (scoped)
    + r'|[A-Za-z0-9_.-]+'                              # 1b: repo#N (single-segment)
    + r'|'                                              # 1c: bare #N (empty prefix)
    + r')#' + n_esc + r'(?!\d)'
)
ref_gh  = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
ref_url = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
           + r'/issues/' + n_esc + r'(?!\d)')
ref = r'(?:' + ref_hash + r'|' + ref_gh + r'|' + ref_url + r')'
pattern = kw + r'\s+' + ref
if re.search(pattern, body, re.IGNORECASE):
    print('yes')
else:
    print('no')
" "$issue_n" "$REPO" 2>/dev/null)"

      # No closing keyword → nothing to check.
      if [ "$has_closing" != "yes" ]; then
        return 0
      fi

      # Closing keyword found.  Fetch open PRs for this issue and filter out
      # the current PR by number.
      local siblings_json
      siblings_json="$(gh pr list --state open --limit 100 \
        --json number,state,title,headRefName,body ${REPO:+--repo "$REPO"} 2>/dev/null)"
      if [ -z "$siblings_json" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch open PR list — skipping sibling check" >&2
        echo "talos:closing-keyword-unverified pr=${pr_number:-$pr_ref} issue=$issue_n reason=sibling-fetch-failed"
        return 0
      fi

      # Find open siblings (any PR referencing #N in branch/title/body, excluding this PR).
      local sibling_result
      sibling_result="$(printf '%s' "$siblings_json" | python3 -c "
import json, re, sys
n    = sys.argv[1]
self = sys.argv[2]
repo = sys.argv[3]   # owner/name — passed from \$REPO, same as has_closing block
# Resolve repo components for scoped matching (case-insensitive).
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
# Four-branch pattern for sibling body matching (#113: added GH-N and URL forms):
#   Branch 1: own-repo qualified form — owner/repo#N (current repo only, case-insensitive)
#   Branch 2: bare #N — not preceded by a word char or slash
#     (?<!/) excludes foreign repo#N suffixes; (?<!\w) excludes alphanumeric prefixes
#   Branch 3: GH-N (case-insensitive) — same boundary guards as has_closing
#   Branch 4: https://github.com/<owner>/<repo>/issues/N (scoped to current repo)
own_repo_pat = r'(?<!\w)(?i:' + owner_esc + r'/' + name_esc + r')#' + n_esc + r'(?!\d)'
bare_pat      = r'(?<!\w)(?<!/)#' + n_esc + r'(?!\d)'
gh_pat        = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
url_pat       = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
                 + r'/issues/' + n_esc + r'(?!\d)')
body_pat = r'(?:' + own_repo_pat + r'|' + bare_pat + r'|' + gh_pat + r'|' + url_pat + r')'
try: prs = json.load(sys.stdin)
except Exception: prs = []
siblings = []
for pr in prs:
    if str(pr.get('number','')) == self:
        continue
    ref = pr.get('headRefName','')
    hay = pr.get('title','') + ' ' + pr.get('body','')
    branch_match = bool(re.search(r'(?:^|/)issue-' + n_esc + r'(?:-|$)', ref))
    body_match   = bool(re.search(body_pat, hay))
    if branch_match or body_match:
        siblings.append(str(pr.get('number','')))
if siblings:
    print('blocked:' + ','.join(siblings))
else:
    print('ok')
" "$issue_n" "${pr_number:-}" "$REPO" 2>/dev/null)"

      case "$sibling_result" in
        ok)
          return 0
          ;;
        blocked:*)
          local sibling_list="${sibling_result#blocked:}"
          echo "pipeline-vcs: check-closing-keyword: PR #${pr_number:-$pr_ref} carries 'Closes #${issue_n}' but open sibling PR(s) still reference the same issue: #${sibling_list/,/ #} — merge the siblings first, or change this PR body to 'Part of #${issue_n}'" >&2
          exit 1
          ;;
        *)
          # Unexpected output from python3 — fail open.
          echo "pipeline-vcs: check-closing-keyword: unexpected sibling-check output — skipping" >&2
          echo "talos:closing-keyword-unverified pr=${pr_number:-$pr_ref} issue=$issue_n reason=sibling-check-failed"
          return 0
          ;;
      esac
      ;;
    pr-head)
      # pr-head <n> — print the current head SHA for a PR (fail-closed: exits 1 if unresolvable)
      local n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] gh pr view $n --json headRefOid -q .headRefOid"
        return 0
      fi
      local sha
      sha="$(gh pr view "$n" --json headRefOid -q .headRefOid ${REPO:+--repo "$REPO"} 2>/dev/null)"
      [ -z "$sha" ] && { echo "pipeline-vcs: pr-head: could not resolve head SHA for PR #$n" >&2; exit 1; }
      printf '%s\n' "$sha"
      ;;

    # ── Attempt counting ─────────────────────────────────────────────────────
    # Shared Python helper embedded here; called by record-attempt, read-attempt,
    # check-attempt. Follows the same fail-closed pattern as check-approval-sha.

    read-attempt)
      # read-attempt <issue-n>
      # Print "stage=<s> count=<k> total=<t>" from the most-recent attempt
      # marker on the issue. Prints "stage= count=0 total=0" when no marker
      # exists (new issue). Exits 0 always (read-only query).
      local n="${1:-}"
      [ -z "$n" ] && { echo "pipeline-vcs: read-attempt: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] read-attempt $n: fetch issue comments and extract last talos:attempt marker"
        return 0
      fi
      local issue_data
      issue_data="$(gh issue view "$n" --json comments ${REPO:+--repo "$REPO"} 2>/dev/null)"
      if [ -z "$issue_data" ]; then
        echo "pipeline-vcs: read-attempt: could not fetch issue #$n data" >&2
        exit 1
      fi
      local trusted_authors
      trusted_authors="$(cfg markers.trusted_authors "")"
      printf '%s' "$issue_data" | TRUSTED_AUTHORS="$trusted_authors" python3 -c "
import json, os, re, sys

# Stage-1 permissive detector: matches any HTML comment that looks like it
# could be a talos:attempt marker.  Used to distinguish 'no marker present'
# (safe) from 'marker present but unparseable' (corrupt → fail-closed).
LOOSE_RE = re.compile(r'<!--\s*talos:attempt\b[^>]*-->')

# Stage-2 strict extractor: only matches a syntactically valid marker.
MARKER_RE = re.compile(
    r'<!--\s*talos:attempt\s+stage=(\S+)\s+count=(\d+)\s+total=(\d+)\s*-->$',
    re.MULTILINE
)
KNOWN_STAGES = {
    'developer', 'qa', 'reviewer', 'security', 'docs',
    'validator', 'pm', 'orchestrator', 'planner',
}

# Author allow-list — markers.trusted_authors config (YAML/JSON list of logins).
# When absent or empty: fail-open with a warning so existing installs are not blocked.
raw_authors = os.environ.get('TRUSTED_AUTHORS', '').strip()
if raw_authors:
    try:
        parsed_authors = json.loads(raw_authors)
        if not isinstance(parsed_authors, list):
            raise ValueError('not a list')
        trusted_authors = [str(a).strip() for a in parsed_authors if str(a).strip()]
    except Exception:
        trusted_authors = [a.strip() for a in raw_authors.splitlines() if a.strip()]
else:
    trusted_authors = []

author_check_active = bool(trusted_authors)

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'pipeline-vcs: read-attempt: could not parse issue data: {exc}', file=sys.stderr)
    sys.exit(1)

raw_comments = data.get('comments', [])

# GitHub returns comments oldest-first; search newest-first for the last marker.
found = None
for c in reversed(raw_comments):
    body   = c.get('body', '')
    author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

    # Require the marker to appear as the last non-whitespace line of the comment
    # body, so a quoted/fenced occurrence cannot win.
    stripped  = body.rstrip()
    last_line = stripped.rsplit('\n', 1)[-1].strip()

    # INVARIANT (issue #79): last-line check is unconditional — MUST precede
    # author_check_active block. Reordering these two sections silently reopens
    # the quoted-marker bypass. Do not move the lines below past author_check_active.
    # Stage 1: does this line look at all like a talos:attempt marker?
    if not LOOSE_RE.search(last_line):
        continue  # not a marker line — skip to next comment

    # Author allow-list check (only when configured and non-empty).
    if author_check_active:
        if author not in trusted_authors:
            print(
                f'pipeline-vcs: read-attempt: skipping marker from untrusted author '
                f'{author!r} (not in markers.trusted_authors)',
                file=sys.stderr,
            )
            continue  # skip; keep searching older comments
    else:
        # Unconfigured allow-list — fail open but emit a machine-readable marker.
        print('talos:marker-authors-unverified reader=read-attempt')
        print(
            'pipeline-vcs: read-attempt: [warn] markers.trusted_authors not configured '
            '— author check skipped',
            file=sys.stderr,
        )

    # Stage 2: the line IS marker-like; it must parse exactly or it is corrupt.
    # Corrupt markers NEVER fall through to zero — that would grant infinite retries.
    m = MARKER_RE.match(last_line)
    if not m:
        print(
            f'pipeline-vcs: read-attempt: corrupt marker (does not parse): '
            f'{last_line!r} — fail-closed',
            file=sys.stderr,
        )
        sys.exit(1)

    stage, count_str, total_str = m.group(1), m.group(2), m.group(3)
    # Semantic validation: stage must be known, values non-negative, count <= total.
    if stage not in KNOWN_STAGES:
        print(f'pipeline-vcs: read-attempt: unrecognised stage \"{stage}\" in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    count_val = int(count_str)
    total_val = int(total_str)
    if count_val < 0 or total_val < 0:
        print('pipeline-vcs: read-attempt: negative value in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    if total_val < count_val:
        print('pipeline-vcs: read-attempt: total < count in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    found = (stage, count_val, total_val)
    break

if found:
    stage, count_val, total_val = found
    print(f'stage={stage} count={count_val} total={total_val}')
else:
    # No marker detected at all — treat as zero attempts (deliberate, not accidental).
    print('stage= count=0 total=0')
sys.exit(0)
"
      ;;

    check-attempt)
      # check-attempt <issue-n>
      # Exit 1 (with reason) when EITHER ceiling is already reached for the
      # issue.  Does NOT record a new attempt — callers do that with
      # record-attempt.  Reads limits.max_fix_attempts and
      # limits.max_total_dispatches from config.
      local n="${1:-}"
      [ -z "$n" ] && { echo "pipeline-vcs: check-attempt: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-attempt $n: compare current attempt state against configured ceilings"
        return 0
      fi
      local max_stage max_total
      max_stage="$(cfg limits.max_fix_attempts 3)"
      max_total="$(cfg limits.max_total_dispatches 8)"
      local state
      state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$n" ${REPO:+--repo "$REPO"} 2>&1)"
      local rc=$?
      if [ $rc -ne 0 ]; then
        echo "pipeline-vcs: check-attempt: read-attempt failed: $state" >&2
        exit 1
      fi
      # Pass through any machine-readable talos: markers from read-attempt to our
      # own stdout, then narrow state to only the parseable stage=...count=...total=
      # line (filters out both talos: markers and any stderr warnings captured via 2>&1).
      printf '%s\n' "$state" | grep '^talos:' || true
      state="$(printf '%s\n' "$state" | grep '^stage=')"
      # Parse the state line
      local cur_stage cur_count cur_total
      cur_stage="$(printf '%s' "$state" | sed 's/stage=\([^ ]*\).*/\1/')"
      cur_count="$(printf '%s' "$state" | sed 's/.*count=\([0-9]*\).*/\1/')"
      cur_total="$(printf '%s' "$state" | sed 's/.*total=\([0-9]*\).*/\1/')"
      # Check total ceiling first
      if [ "$cur_total" -ge "$max_total" ]; then
        echo "pipeline-vcs: check-attempt: BLOCKED — total dispatches ($cur_total) >= max_total_dispatches ($max_total)" >&2
        exit 1
      fi
      # Check per-stage ceiling
      if [ -n "$cur_stage" ] && [ "$cur_count" -ge "$max_stage" ]; then
        echo "pipeline-vcs: check-attempt: BLOCKED — $cur_stage consecutive attempts ($cur_count) >= max_fix_attempts ($max_stage)" >&2
        exit 1
      fi
      echo "pipeline-vcs: check-attempt: ok (stage=$cur_stage count=$cur_count total=$cur_total; max_stage=$max_stage max_total=$max_total)"
      exit 0
      ;;

    record-attempt)
      # record-attempt <issue-n> <blocking-stage>
      # Read prior state, compute new per-stage count and total, post the
      # marker comment, and print "stage=<s> count=<k> total=<t>".
      # Exits non-zero when EITHER ceiling is exceeded AFTER recording.
      local n="${1:-}" stage="${2:-}"
      [ -z "$n" ]     && { echo "pipeline-vcs: record-attempt: missing issue number" >&2; exit 1; }
      [ -z "$stage" ] && { echo "pipeline-vcs: record-attempt: missing stage argument" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] record-attempt $n $stage: read prior state, post <!-- talos:attempt stage=$stage ... --> marker"
        return 0
      fi
      local max_stage max_total
      max_stage="$(cfg limits.max_fix_attempts 3)"
      max_total="$(cfg limits.max_total_dispatches 8)"
      # Read current state (fail-closed on parse error)
      local state
      state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$n" ${REPO:+--repo "$REPO"} 2>&1)"
      local rc=$?
      if [ $rc -ne 0 ]; then
        echo "pipeline-vcs: record-attempt: read-attempt failed: $state" >&2
        exit 1
      fi
      # Pass through any machine-readable talos: markers from read-attempt to our
      # own stdout, then narrow state to only the parseable stage=...count=...total=
      # line (filters out both talos: markers and any stderr warnings captured via 2>&1).
      printf '%s\n' "$state" | grep '^talos:' || true
      state="$(printf '%s\n' "$state" | grep '^stage=')"
      local prev_stage prev_count prev_total
      prev_stage="$(printf '%s' "$state" | sed 's/stage=\([^ ]*\).*/\1/')"
      prev_count="$(printf '%s' "$state" | sed 's/.*count=\([0-9]*\).*/\1/')"
      prev_total="$(printf '%s' "$state" | sed 's/.*total=\([0-9]*\).*/\1/')"
      # Compute new counts
      local new_count new_total
      new_total=$(( prev_total + 1 ))
      if [ "$prev_stage" = "$stage" ]; then
        # Same stage: increment consecutive count
        new_count=$(( prev_count + 1 ))
      else
        # Different stage: reset per-stage count to 1
        new_count=1
      fi
      # Build marker body (marker MUST be the last line of the comment)
      local marker_body
      marker_body="$(printf 'Talos attempt record — stage=%s count=%d total=%d\n<!-- talos:attempt stage=%s count=%d total=%d -->' \
        "$stage" "$new_count" "$new_total" \
        "$stage" "$new_count" "$new_total")"
      # Post the comment and verify the write landed
      local comment_url
      comment_url="$(gh issue comment "$n" --body "$marker_body" ${REPO:+--repo "$REPO"} 2>/dev/null)"
      if [ -z "$comment_url" ]; then
        echo "pipeline-vcs: record-attempt: failed to post attempt marker for issue #$n" >&2
        exit 1
      fi
      echo "pipeline-vcs: record-attempt: marker posted at $comment_url" >&2
      printf 'stage=%s count=%d total=%d\n' "$stage" "$new_count" "$new_total"
      # Exit non-zero if EITHER ceiling is now reached
      local blocked=false
      if [ "$new_total" -ge "$max_total" ]; then
        echo "pipeline-vcs: record-attempt: BLOCKED — total dispatches ($new_total) >= max_total_dispatches ($max_total)" >&2
        blocked=true
      fi
      if [ "$new_count" -ge "$max_stage" ]; then
        echo "pipeline-vcs: record-attempt: BLOCKED — $stage consecutive attempts ($new_count) >= max_fix_attempts ($max_stage)" >&2
        blocked=true
      fi
      [ "$blocked" = "true" ] && exit 1
      exit 0
      ;;

    check-approval-sha)
      # check-approval-sha <n>
      # Verify that every approval label present on the PR was earned against
      # the current head SHA.  If a SHA differs, check whether all changed files
      # since the approval SHA are covered by the configured waiver list
      # (merge.approval_waiver_paths; default: *.md docs/** CHANGELOG.md).
      # Hard-coded non-waivable: scripts/**, tests/**, talos.pipeline.yml,
      # pipeline.yaml — these are enforced FIRST (before the config waiver) so
      # the config waiver can never be widened to cover them.
      # Fail-closed: unresolvable head SHA, missing marker, or git diff failure
      # all exit non-zero.
      local n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-approval-sha $n: verify all approval labels match current head SHA"
        return 0
      fi
      local pr_data
      pr_data="$(gh pr view "$n" --json headRefOid,baseRefName,labels,comments ${REPO:+--repo "$REPO"} 2>/dev/null)"
      if [ -z "$pr_data" ]; then
        echo "pipeline-vcs: check-approval-sha: could not fetch PR #$n data" >&2
        exit 1
      fi
      local waiver_paths
      waiver_paths="$(cfg merge.approval_waiver_paths "")"
      local trusted_authors_cas
      trusted_authors_cas="$(cfg markers.trusted_authors "")"
      local repo_root
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
      printf '%s' "$pr_data" \
        | WAIVER_PATHS="$waiver_paths" REPO_ROOT="${repo_root:-}" TRUSTED_AUTHORS="$trusted_authors_cas" python3 -c "
import fnmatch, json, os, re, subprocess, sys

APPROVAL_LABELS = {
    'qa:pass':           'qa',
    'review:approved':   'reviewer',
    'security:approved': 'security',
    'docs:done':         'docs',
}

# Hard-coded non-waivable: applied AFTER the config waiver check.
# The config can NEVER widen a waiver to cover these paths.
HARDCODED_NONWAIVABLE_PREFIXES = ('scripts/', 'tests/')
HARDCODED_NONWAIVABLE_EXACT    = ('talos.pipeline.yml', 'pipeline.yaml')

# Default waiver paths — used when the config key is absent or unparseable.
DEFAULT_WAIVER = ['*.md', 'docs/**', 'CHANGELOG.md']

# Validation canaries: if a waiver entry matches any of these it is too broad
# (catch-all or covers non-waivable territory) and must be rejected.
# Generated to catch both basename-level and full-path-level matches.
VALIDATION_CANARIES = [
    'scripts/core.sh',      'scripts/pipeline-vcs.sh',
    'sub/dir/scripts/x.sh',
    'tests/test-vcs.sh',    'tests/run-tests.sh',
    'sub/dir/tests/y.sh',
    'talos.pipeline.yml',   'pipeline.yaml',
    'src/arbitrary.js',     'lib/main.py', 'cmd/server.go',
    'sub/dir/arbitrary.js',
]

def is_hardcoded_nonwaivable(path):
    for prefix in HARDCODED_NONWAIVABLE_PREFIXES:
        if path == prefix.rstrip('/') or path.startswith(prefix):
            return True
    return path in HARDCODED_NONWAIVABLE_EXACT

def path_matches(path, patterns):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns)

def validate_waiver_entries(entries):
    errors = []
    for entry in entries:
        for canary in VALIDATION_CANARIES:
            base = os.path.basename(canary)
            if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
                errors.append(
                    \"pipeline-vcs: ERROR: merge.approval_waiver_paths entry '\" + entry +
                    \"' would waive '\" + canary +
                    \"' — rejected (catch-all or covers non-waivable paths)\"
                )
                break
    return errors

# Resolve waiver paths from config (safe degradation: parse error → defaults)
raw_waiver = os.environ.get('WAIVER_PATHS', '').strip()
if raw_waiver:
    try:
        parsed = json.loads(raw_waiver)
        if not isinstance(parsed, list):
            raise ValueError('not a list')
        waiver_entries = [str(e).strip() for e in parsed if str(e).strip()]
    except Exception:
        # Newline-delimited fallback (YAML scalar block)
        waiver_entries = [e.strip() for e in raw_waiver.splitlines() if e.strip()]
else:
    waiver_entries = DEFAULT_WAIVER

# Validate waiver config entries — fail closed on bad config
errors = validate_waiver_entries(waiver_entries)
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)

# Author allow-list — markers.trusted_authors config (YAML/JSON list of logins).
# When absent or empty: fail-open with a warning so existing installs are not blocked.
raw_authors = os.environ.get('TRUSTED_AUTHORS', '').strip()
if raw_authors:
    try:
        parsed_authors = json.loads(raw_authors)
        if not isinstance(parsed_authors, list):
            raise ValueError('not a list')
        trusted_authors = [str(a).strip() for a in parsed_authors if str(a).strip()]
    except Exception:
        trusted_authors = [a.strip() for a in raw_authors.splitlines() if a.strip()]
else:
    trusted_authors = []

author_check_active = bool(trusted_authors)

# Parse PR data
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'pipeline-vcs: check-approval-sha: could not parse PR data: {exc}', file=sys.stderr)
    sys.exit(1)

head_sha = data.get('headRefOid', '').strip()
if not head_sha:
    print('pipeline-vcs: check-approval-sha: could not resolve head SHA', file=sys.stderr)
    sys.exit(1)

# Three-dot diff: compute the set of files the PR itself touches relative to
# origin/<base>. Files that arrived purely from a base-branch sync are absent
# from this set (they are already in the merge base). Fail-open: if base_ref_name
# is absent or the diff fails, pr_own_files = None and the filter is skipped —
# the full changed set is used (conservative / pre-fix behavior).
# NOTE: backticks and unescaped dollar signs cannot appear in this block — it
# runs inside a double-quoted bash string and bash performs command substitution.
base_ref_name = data.get('baseRefName', '').strip()
pr_own_files = None
if base_ref_name:
    _own_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        _pr_own = subprocess.run(
            ['git', 'diff', '--name-only',
             'origin/' + base_ref_name + '...' + head_sha],
            capture_output=True, text=True,
            cwd=_own_root, timeout=30
        )
        if _pr_own.returncode == 0:
            pr_own_files = set(
                f.strip() for f in _pr_own.stdout.splitlines() if f.strip()
            )
        # else: diff failed — fail-open, pr_own_files stays None
    except Exception:
        pr_own_files = None  # fail-open

label_names  = {lb['name'] for lb in data.get('labels', [])}
raw_comments = data.get('comments', [])

# Which approval labels are present?
present = {label: role for label, role in APPROVAL_LABELS.items() if label in label_names}

if not present:
    print('check-approval-sha: no approval labels present')
    sys.exit(0)

# Strict extractor: marker must be a syntactically valid talos:approval HTML comment.
MARKER_RE = re.compile(r'<!--\s*talos:approval\s+sha=([0-9a-f]+)\s+role=(\S+?)\s*-->')

stale = []
for label, role in present.items():
    # Find the most recent marker for this role (search comments newest-first).
    # Enforce the same last-line rule as read-attempt: the marker must be the
    # last non-whitespace line of the comment body so a quoted/fenced occurrence
    # (e.g. GitHub Quote-reply) cannot satisfy the gate.
    found_sha = None
    for c in reversed(raw_comments):
        body   = c.get('body', '')
        author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

        # INVARIANT (issue #79): last-line check is unconditional — MUST precede
        # author_check_active block. Reordering these two sections silently reopens
        # the quoted-marker bypass. Do not move the lines below past author_check_active.
        # Last-line rule: strip trailing whitespace, take final newline-split segment.
        stripped  = body.rstrip()
        last_line = stripped.rsplit('\n', 1)[-1].strip()

        m = MARKER_RE.match(last_line)
        if not m or m.group(2) != role:
            continue  # marker not on last line, or wrong role

        # Author allow-list check (only when configured and non-empty).
        if author_check_active:
            if author not in trusted_authors:
                print(
                    f'pipeline-vcs: check-approval-sha: skipping marker for {label} '
                    f'from untrusted author {author!r} (not in markers.trusted_authors)',
                    file=sys.stderr,
                )
                continue  # skip; keep searching older comments
        else:
            # Unconfigured allow-list — fail open but emit a machine-readable marker.
            print('talos:marker-authors-unverified reader=check-approval-sha')
            print(
                'pipeline-vcs: check-approval-sha: [warn] markers.trusted_authors not configured '
                '— author check skipped',
                file=sys.stderr,
            )

        found_sha = m.group(1)
        break

    if not found_sha:
        # Fail-closed: missing marker means the approval predates SHA stamping —
        # treat it as stale rather than assuming it is safe.
        print(f'pipeline-vcs: check-approval-sha: {label} has no SHA marker — treating as stale', file=sys.stderr)
        stale.append((label, role, 'no SHA marker in PR comments'))
        continue

    # Reject abbreviated SHAs at parse time.  An abbreviated SHA can expand to a
    # real but wrong commit (e.g. bed2e4a expands to bed2e4ae... not bed2e4a9...).
    # NOTE: backticks and $ cannot appear here — this block runs inside a
    # double-quoted bash string and bash would perform command substitution on them.
    # Stages must post the full 40-character SHA from pipeline-vcs.sh pr-head <PR>,
    # not git rev-parse HEAD, which returns whatever commit is checked out locally.
    if not re.fullmatch(r'[0-9a-f]{40}', found_sha):
        stale.append((label, role,
            f'marker SHA {found_sha!r} is not a valid 40-character commit SHA — '
            f'the {role} stage must obtain the SHA via '
            f'pipeline-vcs.sh pr-head <PR>, not git rev-parse HEAD '
            f'(which returns whatever commit is checked out locally)' ))
        continue

    if found_sha == head_sha:
        continue  # Approval is current

    # SHA mismatch — check whether the delta is fully waivable
    repo_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        # Probe whether the marker SHA actually exists in this repository before
        # attempting git diff.  git diff exits 128 for a missing SHA, which
        # produces a confusing error about an invalid revision range.  A missing
        # SHA is a different (and more serious) condition than a stale approval.
        probe = subprocess.run(
            ['git', 'cat-file', '-e', f'{found_sha}^{{commit}}'],
            capture_output=True, cwd=repo_root, timeout=10
        )
        if probe.returncode != 0:
            stale.append((label, role,
                f'marker SHA {found_sha} does not exist in this repository — '
                f'the {role} stage posted an invalid SHA; it must re-run and '
                f're-post its marker using a SHA read from git, not reconstructed'))
            continue
        result = subprocess.run(
            ['git', 'diff', '--name-only', f'{found_sha}..{head_sha}'],
            capture_output=True, text=True,
            cwd=repo_root, timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or 'non-zero exit')
        changed = [f.strip() for f in result.stdout.splitlines() if f.strip()]
    except Exception as exc:
        # git diff failure → treat delta as non-waivable (fail-closed)
        print(f'pipeline-vcs: check-approval-sha: git diff failed: {exc}', file=sys.stderr)
        stale.append((label, role, f'git diff failed: {exc}'))
        continue

    # Intersect with the PR's own file set to exclude base-branch-only changes.
    # A file the PR itself also touches stays in pr_own_files and is evaluated
    # normally — fail-closed for same-file-touched-by-both (rule 2).
    # If pr_own_files is None (three-dot diff unavailable) the filter is skipped.
    if pr_own_files is not None:
        changed = [f for f in changed if f in pr_own_files]

    # First check hard-coded non-waivable paths (structurally enforced — config cannot override)
    blocked = [p for p in changed if is_hardcoded_nonwaivable(p)]
    if not blocked:
        # Then check config waiver list for remaining paths
        blocked = [p for p in changed if not path_matches(p, waiver_entries)]

    if blocked:
        stale.append((label, role,
            f'non-waivable files changed since {found_sha}: ' + ', '.join(blocked[:5])))
    # else every changed file is waivable — approval stands

if stale:
    for label, role, reason in stale:
        print(f'pipeline-vcs: check-approval-sha: STALE {label} ({role}): {reason}', file=sys.stderr)
    sys.exit(1)

print('check-approval-sha: all approval labels are current')
sys.exit(0)
"
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

  # _ga_fetch_all_comments <issue-n>
  # Fetches every page of issue comments by following Link: rel="next" headers.
  # Prints a JSON array of all comment objects. Exits 1 on any HTTP error.
  # Uses the same auth headers as _ga_req; does not use _ga_req itself because
  # _ga_req discards the Link header after each request.
  _ga_fetch_all_comments() {
    local _gafc_n="$1"
    local _gafc_url="$_API/issues/$_gafc_n/comments?per_page=100"
    local _gafc_all _gafc_hdr _gafc_full _gafc_status _gafc_body _gafc_next
    _gafc_all="[]"
    while [ -n "$_gafc_url" ]; do
      _gafc_hdr="$(mktemp)"
      _gafc_full="$(curl -sS -w "\n%{http_code}" \
        -D "$_gafc_hdr" -X GET \
        -H "Authorization: Bearer $_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$_gafc_url")"
      _gafc_status="$(printf '%s' "$_gafc_full" | tail -1)"
      _gafc_body="$(printf '%s' "$_gafc_full" | sed '$d')"
      _gafc_next="$(grep -i '^link:' "$_gafc_hdr" \
        | grep -o '<[^>]*>; rel="next"' \
        | sed 's/<\([^>]*\)>; rel="next"/\1/')"
      rm -f "$_gafc_hdr"
      if [ "${_gafc_status:-0}" -ge 300 ] 2>/dev/null; then
        printf 'github-api: HTTP %s fetching comments page\n' "$_gafc_status" >&2
        return 1
      fi
      _gafc_all="$(PREV="$_gafc_all" PAGE="$_gafc_body" python3 -c "
import json, os, sys
prev = json.loads(os.environ.get('PREV', '[]'))
try:
    page = json.loads(os.environ.get('PAGE', '[]'))
    if not isinstance(page, list):
        page = []
except Exception:
    page = []
prev.extend(page)
json.dump(prev, sys.stdout)
")"
      _gafc_url="$_gafc_next"
    done
    printf '%s' "$_gafc_all"
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
import json, re, sys, os
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
        echo "[dry-run] github-api: GET $_API/issues/$_n (state check); POST $_API/issues/$_n/comments"
        return 0
      fi
      local _gaci_state_unverified=false
      if [ "$ALLOW_CLOSED" != "true" ]; then
        local _gaci_state_raw _gaci_state
        if _gaci_state_raw="$(_ga_req GET "$_API/issues/$_n" 2>/dev/null)"; then
          _gaci_state="$(printf '%s' "$_gaci_state_raw" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('state', ''))
" 2>/dev/null)"
          if [ "$_gaci_state" = "closed" ]; then
            echo "pipeline-vcs: comment-issue: issue #$_n is closed (use --allow-closed to override)" >&2
            exit 1
          fi
        else
          echo "pipeline-vcs: warning: could not determine state of issue #$_n — proceeding" >&2
          _gaci_state_unverified=true
        fi
      fi
      local _payload
      _payload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]}))" "$_body")"
      local _gaci_resp
      _gaci_resp="$(_ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_payload")" || exit 1
      printf '%s' "$_gaci_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('html_url', ''))
"
      if [ "$_gaci_state_unverified" = "true" ]; then
        echo "talos:comment-state-unverified target=issue#$_n reason=state-check-failed"
      fi
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
        -H "Content-Type: application/json" -d "$_ci_payload")" || exit 1
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
        -H "Content-Type: application/json" -d "$_pr_payload")" || exit 1
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
        echo "[dry-run] github-api: GET $_API/pulls/$_n (state check); POST $_API/issues/$_n/comments (PR comment)"
        return 0
      fi
      local _gacp_state_unverified=false
      if [ "$ALLOW_CLOSED" != "true" ]; then
        local _gacp_state_raw _gacp_state _gacp_merged_at
        if _gacp_state_raw="$(_ga_req GET "$_API/pulls/$_n" 2>/dev/null)"; then
          _gacp_state="$(printf '%s' "$_gacp_state_raw" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('state', ''))
" 2>/dev/null)"
          _gacp_merged_at="$(printf '%s' "$_gacp_state_raw" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('merged_at') or '')
" 2>/dev/null)"
          if [ "$_gacp_state" = "closed" ] && [ -z "$_gacp_merged_at" ]; then
            echo "pipeline-vcs: comment-pr: PR #$_n is closed (not merged) — use --allow-closed to override" >&2
            exit 1
          fi
        else
          echo "pipeline-vcs: warning: could not determine state of PR #$_n — proceeding" >&2
          _gacp_state_unverified=true
        fi
      fi
      local _payload
      _payload="$(python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]}))" "$_body")"
      local _gacp_resp
      _gacp_resp="$(_ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_payload")" || exit 1
      printf '%s' "$_gacp_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('html_url', ''))
"
      if [ "$_gacp_state_unverified" = "true" ]; then
        echo "talos:comment-state-unverified target=pr#$_n reason=state-check-failed"
      fi
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
import json, re, sys, os
n = sys.argv[1]
state_filter = os.environ.get('STATE_FILTER','open')
try: prs = json.load(sys.stdin)
except Exception: prs = []
for pr in prs:
    hay = pr.get('title','') + ' ' + (pr.get('body','') or '')
    ref = pr.get('head',{}).get('ref','')
    if not (re.search(r'(?:^|/)issue-' + re.escape(n) + r'(?:-|$)', ref) or re.search(r'#' + re.escape(n) + r'(?!\d)', hay)):
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
      # Built-in defaults — always active unless merge.forbidden_files_replace: true.
      # #61 fix: union semantics match the github provider; both providers are identical.
      # .netrc and _netrc are LITERAL patterns (no glob chars); they generate
      # canaries as of #76 (PR #90, commit b1d3199), so wildcard allow entries
      # that match them are rejected. Deferral from issue #78 is resolved.
      local _BUILTIN_DEFAULTS='.env
.env.*
*.pem
*.key
*.p12
*.pfx
*.secrets
secrets.*
*id_rsa*
*id_ecdsa*
*id_ed25519*
*id_dsa*
*.ppk
*.jks
*.keystore
*.pkcs12
*.kdbx
*.ovpn
.netrc
_netrc'
      local _patterns _defaults_active
      local _ga_configured _ga_replace
      _ga_configured="$(cfg merge.forbidden_files "")"
      _ga_replace="$(cfg merge.forbidden_files_replace "")"
      if [ -n "$_ga_configured" ] && [ "$_ga_replace" = "true" ]; then
        echo "pipeline-vcs: WARNING: merge.forbidden_files_replace=true — built-in secret-protection defaults are SUPPRESSED; only configured patterns are active" >&2
        _patterns="$_ga_configured"
        _defaults_active="replaced"
      elif [ -n "$_ga_configured" ]; then
        _patterns="$_BUILTIN_DEFAULTS
$_ga_configured"
        _defaults_active="in-force"
      else
        _patterns="$_BUILTIN_DEFAULTS"
        _defaults_active="in-force"
      fi
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls/$_n/files | match against forbidden patterns"
        return 0
      fi
      # Transparency markers — identical to github provider.
      local _ga_pat_count
      _ga_pat_count="$(printf '%s\n' "$_patterns" | grep -c '[^[:space:]]')" || _ga_pat_count=0
      printf '%s' "$_ga_pat_count" | grep -qE '^[0-9]+$' || _ga_pat_count=0
      printf 'talos:forbidden-files-active patterns=%d defaults=%s\n' "$_ga_pat_count" "$_defaults_active"
      [ "$_defaults_active" = "replaced" ] && \
        printf 'talos:forbidden-files-defaults-replaced patterns=%d\n' "$_ga_pat_count"
      # merge.forbidden_files_allow — allow-list validation (identical to github provider).
      local _ga_allow
      _ga_allow="$(cfg merge.forbidden_files_allow "")"
      if [ -n "$_ga_allow" ]; then
        PATTERNS="$_patterns" ALLOW="$_ga_allow" python3 -c "
import fnmatch, os, re, sys

patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow    = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]

def pat_to_literal(pat):
    s = re.sub(r'\\[[^\\]]*\\]', 'x', pat)
    return s.replace('*', 'x').replace('?', 'x')

canaries = []  # list of (canary_path, src_literal_or_None)
for pat in patterns:
    if not re.search(r'[*?\[\]]', pat):
        # Literal deny pattern: canary IS the pattern (no glob chars to expand).
        # Tag with src_literal so exact-match overrides remain permitted.
        canaries.append((pat, pat))
        canaries.append(('sub/dir/' + pat, pat))
        canaries.append(('config/' + pat, pat))
    else:
        lit = pat_to_literal(pat)
        if not lit:
            continue
        canaries.append((lit, None))
        canaries.append(('sub/dir/' + lit, None))
        canaries.append(('config/' + lit, None))

# #64 fix: fall back to built-in canaries when deny list is all-literal.
if not canaries:
    canaries = [('x.env', None), ('sub/dir/x.env', None), ('config/x.env', None),
                ('x.pem', None), ('sub/dir/x.pem', None), ('config/x.pem', None)]

errors = []
for entry in allow:
    for canary, src_literal in canaries:
        # Exact literal override: the operator deliberately listed the guarded filename.
        if src_literal is not None and entry == src_literal:
            continue
        base = os.path.basename(canary)
        if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
            errors.append(
                'pipeline-vcs: ERROR: merge.forbidden_files_allow entry \'' + entry +
                '\' would exempt \'' + canary + '\' — rejected'
            )
            break
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
" || exit 1
      fi
      local _files_raw
      _files_raw="$(_ga_req GET "$_API/pulls/$_n/files?per_page=100")"
      printf '%s' "$_files_raw" | PATTERNS="$_patterns" ALLOW="$_ga_allow" PAT_COUNT="$_ga_pat_count" DEFAULTS_ACTIVE="$_defaults_active" python3 -c "
import fnmatch, os, sys, json
patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]
pat_count = os.environ.get('PAT_COUNT', '0')
defaults_active = os.environ.get('DEFAULTS_ACTIVE', 'in-force')
bad = []
try:
    files = json.load(sys.stdin)
except Exception:
    files = []
for f in files:
    path = f.get('filename','')
    base = os.path.basename(path)
    if any(fnmatch.fnmatch(base, a) or fnmatch.fnmatch(path, a) for a in allow):
        continue
    if any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns):
        bad.append(path)
if bad:
    print('FORBIDDEN FILES in PR — human review required before merge:')
    for p in bad: print(f'  {p}')
    sys.exit(1)
print(f'no forbidden files [{pat_count} patterns: defaults={defaults_active}]')
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

    # ── Parity verbs (matching _github capability) ────────────────────────────

    pr-head)
      # pr-head <n> — print the current head SHA for a PR (fail-closed: exits 1 if unresolvable)
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/pulls/$_n .head.sha"
        return 0
      fi
      local _pr_data
      _pr_data="$(_ga_req GET "$_API/pulls/$_n")"
      if [ -z "$_pr_data" ]; then
        echo "pipeline-vcs: pr-head: could not resolve head SHA for PR #$_n" >&2; exit 1
      fi
      local _sha
      _sha="$(printf '%s' "$_pr_data" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('head',{}).get('sha',''))")"
      [ -z "$_sha" ] && { echo "pipeline-vcs: pr-head: could not resolve head SHA for PR #$_n" >&2; exit 1; }
      printf '%s\n' "$_sha"
      ;;

    read-attempt)
      # read-attempt <n>
      # Print "stage=<s> count=<k> total=<t>" from the most-recent attempt
      # marker on the issue. Prints "stage= count=0 total=0" when no marker
      # exists. Exits 0 always (read-only query).
      local _n="${1:-}"
      [ -z "$_n" ] && { echo "pipeline-vcs: read-attempt: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: GET $_API/issues/$_n/comments (read-attempt)"
        return 0
      fi
      local _raw_comments
      # Paginate: follow Link: rel="next" headers so markers beyond comment #100
      # are never missed (fix for #126 -- single per_page=100 fetch fails open).
      _raw_comments="$(_ga_fetch_all_comments "$_n")"
      if [ $? -ne 0 ] || [ -z "$_raw_comments" ]; then
        echo "pipeline-vcs: read-attempt: could not fetch issue #$_n data" >&2
        exit 1
      fi
      # Normalize REST response (array with user.login) to gh-compatible shape
      # (object with comments array where author.login replaces user.login).
      # Guard: (c.get('user') or {}) handles "user": null (deleted account).
      local _normalized
      _normalized="$(printf '%s' "$_raw_comments" | python3 -c "
import json, sys
raw = json.load(sys.stdin)
if not isinstance(raw, list):
    raw = []
comments = [dict(c, author={'login': (c.get('user') or {}).get('login', '')}) for c in raw]
json.dump({'comments': comments}, sys.stdout)
")"
      local _trusted_authors
      _trusted_authors="$(cfg markers.trusted_authors "")"
      printf '%s' "$_normalized" | TRUSTED_AUTHORS="$_trusted_authors" python3 -c "
import json, os, re, sys

# Stage-1 permissive detector: matches any HTML comment that looks like it
# could be a talos:attempt marker.  Used to distinguish 'no marker present'
# (safe) from 'marker present but unparseable' (corrupt -> fail-closed).
LOOSE_RE = re.compile(r'<!--\s*talos:attempt\b[^>]*-->')

# Stage-2 strict extractor: only matches a syntactically valid marker.
MARKER_RE = re.compile(
    r'<!--\s*talos:attempt\s+stage=(\S+)\s+count=(\d+)\s+total=(\d+)\s*-->$',
    re.MULTILINE
)
KNOWN_STAGES = {
    'developer', 'qa', 'reviewer', 'security', 'docs',
    'validator', 'pm', 'orchestrator', 'planner',
}

# Author allow-list
raw_authors = os.environ.get('TRUSTED_AUTHORS', '').strip()
if raw_authors:
    try:
        parsed_authors = json.loads(raw_authors)
        if not isinstance(parsed_authors, list):
            raise ValueError('not a list')
        trusted_authors = [str(a).strip() for a in parsed_authors if str(a).strip()]
    except Exception:
        trusted_authors = [a.strip() for a in raw_authors.splitlines() if a.strip()]
else:
    trusted_authors = []

author_check_active = bool(trusted_authors)

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print('pipeline-vcs: read-attempt: could not parse issue data: ' + str(exc), file=sys.stderr)
    sys.exit(1)

raw_comments = data.get('comments', [])

found = None
for c in reversed(raw_comments):
    body   = c.get('body', '')
    author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

    # INVARIANT (issue #79): last-line check is unconditional -- MUST precede
    # author_check_active block. Reordering these two sections silently reopens
    # the quoted-marker bypass. Do not move the lines below past author_check_active.
    stripped  = body.rstrip()
    last_line = stripped.rsplit('\n', 1)[-1].strip()

    if not LOOSE_RE.search(last_line):
        continue

    if author_check_active:
        if author not in trusted_authors:
            print(
                'pipeline-vcs: read-attempt: skipping marker from untrusted author '
                + repr(author) + ' (not in markers.trusted_authors)',
                file=sys.stderr,
            )
            continue
    else:
        print('talos:marker-authors-unverified reader=read-attempt')
        print(
            'pipeline-vcs: read-attempt: [warn] markers.trusted_authors not configured '
            '-- author check skipped',
            file=sys.stderr,
        )

    m = MARKER_RE.match(last_line)
    if not m:
        print(
            'pipeline-vcs: read-attempt: corrupt marker (does not parse): '
            + repr(last_line) + ' -- fail-closed',
            file=sys.stderr,
        )
        sys.exit(1)

    stage, count_str, total_str = m.group(1), m.group(2), m.group(3)
    if stage not in KNOWN_STAGES:
        print('pipeline-vcs: read-attempt: unrecognised stage ' + repr(stage) + ' in marker -- fail-closed', file=sys.stderr)
        sys.exit(1)
    count_val = int(count_str)
    total_val = int(total_str)
    if count_val < 0 or total_val < 0:
        print('pipeline-vcs: read-attempt: negative value in marker -- fail-closed', file=sys.stderr)
        sys.exit(1)
    if total_val < count_val:
        print('pipeline-vcs: read-attempt: total < count in marker -- fail-closed', file=sys.stderr)
        sys.exit(1)
    found = (stage, count_val, total_val)
    break

if found:
    stage, count_val, total_val = found
    print('stage=' + stage + ' count=' + str(count_val) + ' total=' + str(total_val))
else:
    print('stage= count=0 total=0')
sys.exit(0)
"
      ;;

    check-attempt)
      # check-attempt <n>
      # Exit 1 when either ceiling is already reached. Read-only.
      local _n="${1:-}"
      [ -z "$_n" ] && { echo "pipeline-vcs: check-attempt: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-attempt $_n: compare current attempt state against configured ceilings"
        return 0
      fi
      local _max_stage _max_total
      _max_stage="$(cfg limits.max_fix_attempts 3)"
      _max_total="$(cfg limits.max_total_dispatches 8)"
      local _state
      _state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$_n" ${REPO:+--repo "$REPO"} 2>&1)"
      local _rc=$?
      if [ $_rc -ne 0 ]; then
        echo "pipeline-vcs: check-attempt: read-attempt failed: $_state" >&2
        exit 1
      fi
      printf '%s\n' "$_state" | grep '^talos:' || true
      _state="$(printf '%s\n' "$_state" | grep '^stage=')"
      local _cur_stage _cur_count _cur_total
      _cur_stage="$(printf '%s' "$_state" | sed 's/stage=\([^ ]*\).*/\1/')"
      _cur_count="$(printf '%s' "$_state" | sed 's/.*count=\([0-9]*\).*/\1/')"
      _cur_total="$(printf '%s' "$_state" | sed 's/.*total=\([0-9]*\).*/\1/')"
      if [ "$_cur_total" -ge "$_max_total" ]; then
        echo "pipeline-vcs: check-attempt: BLOCKED -- total dispatches ($_cur_total) >= max_total_dispatches ($_max_total)" >&2
        exit 1
      fi
      if [ -n "$_cur_stage" ] && [ "$_cur_count" -ge "$_max_stage" ]; then
        echo "pipeline-vcs: check-attempt: BLOCKED -- $_cur_stage consecutive attempts ($_cur_count) >= max_fix_attempts ($_max_stage)" >&2
        exit 1
      fi
      echo "pipeline-vcs: check-attempt: ok (stage=$_cur_stage count=$_cur_count total=$_cur_total; max_stage=$_max_stage max_total=$_max_total)"
      exit 0
      ;;

    record-attempt)
      # record-attempt <n> <stage>
      local _n="${1:-}" _stage="${2:-}"
      [ -z "$_n" ]     && { echo "pipeline-vcs: record-attempt: missing issue number" >&2; exit 1; }
      [ -z "$_stage" ] && { echo "pipeline-vcs: record-attempt: missing stage argument" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] record-attempt $_n $_stage: read prior state, post <!-- talos:attempt stage=$_stage ... --> marker"
        return 0
      fi
      local _max_stage _max_total
      _max_stage="$(cfg limits.max_fix_attempts 3)"
      _max_total="$(cfg limits.max_total_dispatches 8)"
      local _state
      _state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$_n" ${REPO:+--repo "$REPO"} 2>&1)"
      local _rc=$?
      if [ $_rc -ne 0 ]; then
        echo "pipeline-vcs: record-attempt: read-attempt failed: $_state" >&2
        exit 1
      fi
      printf '%s\n' "$_state" | grep '^talos:' || true
      _state="$(printf '%s\n' "$_state" | grep '^stage=')"
      local _prev_stage _prev_count _prev_total
      _prev_stage="$(printf '%s' "$_state" | sed 's/stage=\([^ ]*\).*/\1/')"
      _prev_count="$(printf '%s' "$_state" | sed 's/.*count=\([0-9]*\).*/\1/')"
      _prev_total="$(printf '%s' "$_state" | sed 's/.*total=\([0-9]*\).*/\1/')"
      local _new_count _new_total
      _new_total=$(( _prev_total + 1 ))
      if [ "$_prev_stage" = "$_stage" ]; then
        _new_count=$(( _prev_count + 1 ))
      else
        _new_count=1
      fi
      local _marker_body
      _marker_body="$(printf 'Talos attempt record -- stage=%s count=%d total=%d\n<!-- talos:attempt stage=%s count=%d total=%d -->' \
        "$_stage" "$_new_count" "$_new_total" \
        "$_stage" "$_new_count" "$_new_total")"
      # Use Python to produce valid JSON for the POST body (avoids unsafe interpolation)
      local _json_body
      _json_body="$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$_marker_body")"
      local _comment_resp
      _comment_resp="$(_ga_req POST "$_API/issues/$_n/comments" \
        -H "Content-Type: application/json" -d "$_json_body")"
      if [ -z "$_comment_resp" ]; then
        echo "pipeline-vcs: record-attempt: failed to post attempt marker for issue #$_n" >&2
        exit 1
      fi
      local _comment_url
      _comment_url="$(printf '%s' "$_comment_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))" 2>/dev/null)"
      echo "pipeline-vcs: record-attempt: marker posted at ${_comment_url:-<unknown>}" >&2
      printf 'stage=%s count=%d total=%d\n' "$_stage" "$_new_count" "$_new_total"
      local _blocked=false
      if [ "$_new_total" -ge "$_max_total" ]; then
        echo "pipeline-vcs: record-attempt: BLOCKED -- total dispatches ($_new_total) >= max_total_dispatches ($_max_total)" >&2
        _blocked=true
      fi
      if [ "$_new_count" -ge "$_max_stage" ]; then
        echo "pipeline-vcs: record-attempt: BLOCKED -- $_stage consecutive attempts ($_new_count) >= max_fix_attempts ($_max_stage)" >&2
        _blocked=true
      fi
      [ "$_blocked" = "true" ] && exit 1
      exit 0
      ;;

    check-approval-sha)
      # check-approval-sha <n>
      # Verify every approval label on the PR was earned against the current head SHA.
      local _n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: check-approval-sha $_n: verify all approval labels match current head SHA"
        return 0
      fi
      local _pr_raw _comments_raw
      _pr_raw="$(_ga_req GET "$_API/pulls/$_n")"
      if [ -z "$_pr_raw" ]; then
        echo "pipeline-vcs: check-approval-sha: could not fetch PR #$_n data" >&2; exit 1
      fi
      # Paginate comments: follow Link: rel="next" so approvals beyond #100 are
      # found (fix for #126 -- single per_page=100 fetch fails closed here but
      # forces unnecessary re-stamp; paginating avoids the stale false-positive).
      _comments_raw="$(_ga_fetch_all_comments "$_n")"
      if [ $? -ne 0 ] || [ -z "$_comments_raw" ]; then
        echo "pipeline-vcs: check-approval-sha: could not fetch PR #$_n data" >&2; exit 1
      fi
      # Assemble gh-compatible JSON: headRefOid, baseRefName, labels, comments
      local _pr_data
      _pr_data="$(printf '%s\n%s' "$_pr_raw" "$_comments_raw" | python3 -c "
import json, sys
lines = sys.stdin.read().split('\n', 1)
pr   = json.loads(lines[0]) if lines else {}
craw = json.loads(lines[1]) if len(lines) > 1 else []
if not isinstance(craw, list):
    craw = []
comments = [dict(c, author={'login': (c.get('user') or {}).get('login', '')}) for c in craw]
labels = [{'name': lb.get('name', '')} for lb in pr.get('labels', [])]
out = {
    'headRefOid':  pr.get('head', {}).get('sha', ''),
    'baseRefName': pr.get('base', {}).get('ref', ''),
    'labels':      labels,
    'comments':    comments,
}
json.dump(out, sys.stdout)
")"
      local _waiver_paths _trusted_authors_cas _repo_root
      _waiver_paths="$(cfg merge.approval_waiver_paths "")"
      _trusted_authors_cas="$(cfg markers.trusted_authors "")"
      _repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
      printf '%s' "$_pr_data" \
        | WAIVER_PATHS="$_waiver_paths" REPO_ROOT="${_repo_root:-}" TRUSTED_AUTHORS="$_trusted_authors_cas" python3 -c "
import fnmatch, json, os, re, subprocess, sys

APPROVAL_LABELS = {
    'qa:pass':           'qa',
    'review:approved':   'reviewer',
    'security:approved': 'security',
    'docs:done':         'docs',
}

HARDCODED_NONWAIVABLE_PREFIXES = ('scripts/', 'tests/')
HARDCODED_NONWAIVABLE_EXACT    = ('talos.pipeline.yml', 'pipeline.yaml')

DEFAULT_WAIVER = ['*.md', 'docs/**', 'CHANGELOG.md']

VALIDATION_CANARIES = [
    'scripts/core.sh',      'scripts/pipeline-vcs.sh',
    'sub/dir/scripts/x.sh',
    'tests/test-vcs.sh',    'tests/run-tests.sh',
    'sub/dir/tests/y.sh',
    'talos.pipeline.yml',   'pipeline.yaml',
    'src/arbitrary.js',     'lib/main.py', 'cmd/server.go',
    'sub/dir/arbitrary.js',
]

def is_hardcoded_nonwaivable(path):
    for prefix in HARDCODED_NONWAIVABLE_PREFIXES:
        if path == prefix.rstrip('/') or path.startswith(prefix):
            return True
    return path in HARDCODED_NONWAIVABLE_EXACT

def path_matches(path, patterns):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns)

def validate_waiver_entries(entries):
    errors = []
    for entry in entries:
        for canary in VALIDATION_CANARIES:
            base = os.path.basename(canary)
            if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
                errors.append(
                    \"pipeline-vcs: ERROR: merge.approval_waiver_paths entry '\" + entry +
                    \"' would waive '\" + canary +
                    \"' -- rejected (catch-all or covers non-waivable paths)\"
                )
                break
    return errors

raw_waiver = os.environ.get('WAIVER_PATHS', '').strip()
if raw_waiver:
    try:
        parsed = json.loads(raw_waiver)
        if not isinstance(parsed, list):
            raise ValueError('not a list')
        waiver_entries = [str(e).strip() for e in parsed if str(e).strip()]
    except Exception:
        waiver_entries = [e.strip() for e in raw_waiver.splitlines() if e.strip()]
else:
    waiver_entries = DEFAULT_WAIVER

errors = validate_waiver_entries(waiver_entries)
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)

raw_authors = os.environ.get('TRUSTED_AUTHORS', '').strip()
if raw_authors:
    try:
        parsed_authors = json.loads(raw_authors)
        if not isinstance(parsed_authors, list):
            raise ValueError('not a list')
        trusted_authors = [str(a).strip() for a in parsed_authors if str(a).strip()]
    except Exception:
        trusted_authors = [a.strip() for a in raw_authors.splitlines() if a.strip()]
else:
    trusted_authors = []

author_check_active = bool(trusted_authors)

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print('pipeline-vcs: check-approval-sha: could not parse PR data: ' + str(exc), file=sys.stderr)
    sys.exit(1)

head_sha = data.get('headRefOid', '').strip()
if not head_sha:
    print('pipeline-vcs: check-approval-sha: could not resolve head SHA', file=sys.stderr)
    sys.exit(1)

base_ref_name = data.get('baseRefName', '').strip()
pr_own_files = None
if base_ref_name:
    _own_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        _pr_own = subprocess.run(
            ['git', 'diff', '--name-only',
             'origin/' + base_ref_name + '...' + head_sha],
            capture_output=True, text=True,
            cwd=_own_root, timeout=30
        )
        if _pr_own.returncode == 0:
            pr_own_files = set(
                f.strip() for f in _pr_own.stdout.splitlines() if f.strip()
            )
    except Exception:
        pr_own_files = None

label_names  = {lb['name'] for lb in data.get('labels', [])}
raw_comments = data.get('comments', [])

present = {label: role for label, role in APPROVAL_LABELS.items() if label in label_names}

if not present:
    print('check-approval-sha: no approval labels present')
    sys.exit(0)

MARKER_RE = re.compile(r'<!--\s*talos:approval\s+sha=([0-9a-f]+)\s+role=(\S+?)\s*-->')

stale = []
for label, role in present.items():
    found_sha = None
    for c in reversed(raw_comments):
        body   = c.get('body', '')
        author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

        # INVARIANT (issue #79): last-line check is unconditional -- MUST precede
        # author_check_active block. Reordering these two sections silently reopens
        # the quoted-marker bypass. Do not move the lines below past author_check_active.
        stripped  = body.rstrip()
        last_line = stripped.rsplit('\n', 1)[-1].strip()

        m = MARKER_RE.match(last_line)
        if not m or m.group(2) != role:
            continue

        if author_check_active:
            if author not in trusted_authors:
                print(
                    'pipeline-vcs: check-approval-sha: skipping marker for ' + label +
                    ' from untrusted author ' + repr(author) + ' (not in markers.trusted_authors)',
                    file=sys.stderr,
                )
                continue
        else:
            print('talos:marker-authors-unverified reader=check-approval-sha')
            print(
                'pipeline-vcs: check-approval-sha: [warn] markers.trusted_authors not configured '
                '-- author check skipped',
                file=sys.stderr,
            )

        found_sha = m.group(1)
        break

    if not found_sha:
        print('pipeline-vcs: check-approval-sha: ' + label + ' has no SHA marker -- treating as stale', file=sys.stderr)
        stale.append((label, role, 'no SHA marker in PR comments'))
        continue

    if not re.fullmatch(r'[0-9a-f]{40}', found_sha):
        stale.append((label, role,
            'marker SHA ' + repr(found_sha) + ' is not a valid 40-character commit SHA -- '
            'the ' + role + ' stage must obtain the SHA via '
            'pipeline-vcs.sh pr-head <PR>, not git rev-parse HEAD '
            '(which returns whatever commit is checked out locally)'))
        continue

    if found_sha == head_sha:
        continue

    repo_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        probe = subprocess.run(
            ['git', 'cat-file', '-e', found_sha + '^{commit}'],
            capture_output=True, cwd=repo_root, timeout=10
        )
        if probe.returncode != 0:
            stale.append((label, role,
                'marker SHA ' + found_sha + ' does not exist in this repository -- '
                'the ' + role + ' stage posted an invalid SHA; it must re-run and '
                're-post its marker using a SHA read from git, not reconstructed'))
            continue
        result = subprocess.run(
            ['git', 'diff', '--name-only', found_sha + '..' + head_sha],
            capture_output=True, text=True,
            cwd=repo_root, timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or 'non-zero exit')
        changed = [f.strip() for f in result.stdout.splitlines() if f.strip()]
    except Exception as exc:
        print('pipeline-vcs: check-approval-sha: git diff failed: ' + str(exc), file=sys.stderr)
        stale.append((label, role, 'git diff failed: ' + str(exc)))
        continue

    if pr_own_files is not None:
        changed = [f for f in changed if f in pr_own_files]

    blocked = [p for p in changed if is_hardcoded_nonwaivable(p)]
    if not blocked:
        blocked = [p for p in changed if not path_matches(p, waiver_entries)]

    if blocked:
        stale.append((label, role,
            'non-waivable files changed since ' + found_sha + ': ' + ', '.join(blocked[:5])))

if stale:
    for label, role, reason in stale:
        print('pipeline-vcs: check-approval-sha: STALE ' + label + ' (' + role + '): ' + reason, file=sys.stderr)
    sys.exit(1)

print('check-approval-sha: all approval labels are current')
sys.exit(0)
"
      ;;

    check-closing-keyword)
      # check-closing-keyword <pr_ref> <issue_n>
      # Fail-open. Exit 1 only when a closing keyword is present AND open
      # sibling PRs still reference the same issue.
      local _pr_ref="${1:-}" _issue_n="${2:-}"
      [ -z "$_pr_ref" ]  && { echo "pipeline-vcs: check-closing-keyword: missing PR ref"     >&2; exit 1; }
      [ -z "$_issue_n" ] && { echo "pipeline-vcs: check-closing-keyword: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] github-api: check-closing-keyword $_pr_ref $_issue_n: fetch PR body, look for closing keyword, then fetch open PRs"
        return 0
      fi
      # Repo-scope guard
      if [ -z "$_REPO" ]; then
        echo "talos:closing-keyword-unverified pr=$_pr_ref issue=$_issue_n reason=repo-unresolved"
        return 0
      fi
      # Resolve PR number if not numeric
      local _pr_num
      if printf '%s' "$_pr_ref" | grep -qE '^[0-9]+$'; then
        _pr_num="$_pr_ref"
      else
        local _found_pr
        _found_pr="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" find-pr "$_pr_ref" open ${REPO:+--repo "$REPO"} 2>/dev/null)"
        _pr_num="$(printf '%s' "$_found_pr" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('number',''))" 2>/dev/null)"
        if [ -z "$_pr_num" ]; then
          echo "pipeline-vcs: check-closing-keyword: could not fetch PR '$_pr_ref' -- skipping check" >&2
          echo "talos:closing-keyword-unverified pr=$_pr_ref issue=$_issue_n reason=pr-fetch-failed"
          return 0
        fi
      fi
      local _pr_raw
      _pr_raw="$(_ga_req GET "$_API/pulls/$_pr_num")"
      if [ -z "$_pr_raw" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch PR '$_pr_ref' -- skipping check" >&2
        echo "talos:closing-keyword-unverified pr=$_pr_ref issue=$_issue_n reason=pr-fetch-failed"
        return 0
      fi
      local _pr_body
      _pr_body="$(printf '%s' "$_pr_raw" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('body',''))")"
      # Check for closing keyword
      local _has_closing
      _has_closing="$(printf '%s' "$_pr_body" | python3 -c "
import re, sys
body = sys.stdin.read()
n    = sys.argv[1]
repo = sys.argv[2]
kw = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
ref_hash = (
    r'(?<!\w)(?<!/)(?:'
    + r'(?i:' + owner_esc + r'/' + name_esc + r')'
    + r'|[A-Za-z0-9_.-]+'
    + r'|'
    + r')#' + n_esc + r'(?!\d)'
)
ref_gh  = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
ref_url = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
           + r'/issues/' + n_esc + r'(?!\d)')
ref = r'(?:' + ref_hash + r'|' + ref_gh + r'|' + ref_url + r')'
pattern = kw + r'\s+' + ref
if re.search(pattern, body, re.IGNORECASE):
    print('yes')
else:
    print('no')
" "$_issue_n" "$_REPO" 2>/dev/null)"
      if [ "$_has_closing" != "yes" ]; then
        return 0
      fi
      # Closing keyword found — check for open siblings
      local _open_prs_raw
      _open_prs_raw="$(_ga_req GET "$_API/pulls?state=open&per_page=100")"
      if [ -z "$_open_prs_raw" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch open PR list -- skipping sibling check" >&2
        echo "talos:closing-keyword-unverified pr=$_pr_num issue=$_issue_n reason=sibling-fetch-failed"
        return 0
      fi
      # Normalize open PRs: add headRefName from head.ref
      local _siblings_json
      _siblings_json="$(printf '%s' "$_open_prs_raw" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
if not isinstance(prs, list):
    prs = []
normalized = []
for pr in prs:
    p = dict(pr)
    p['headRefName'] = pr.get('head', {}).get('ref', '')
    normalized.append(p)
json.dump(normalized, sys.stdout)
")"
      local _sibling_result
      _sibling_result="$(printf '%s' "$_siblings_json" | python3 -c "
import json, re, sys
n    = sys.argv[1]
self = sys.argv[2]
repo = sys.argv[3]
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
own_repo_pat = r'(?<!\w)(?i:' + owner_esc + r'/' + name_esc + r')#' + n_esc + r'(?!\d)'
bare_pat      = r'(?<!\w)(?<!/)#' + n_esc + r'(?!\d)'
gh_pat        = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
url_pat       = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
                 + r'/issues/' + n_esc + r'(?!\d)')
body_pat = r'(?:' + own_repo_pat + r'|' + bare_pat + r'|' + gh_pat + r'|' + url_pat + r')'
try: prs = json.load(sys.stdin)
except Exception: prs = []
siblings = []
for pr in prs:
    if str(pr.get('number','')) == self:
        continue
    ref = pr.get('headRefName','')
    hay = pr.get('title','') + ' ' + pr.get('body','')
    branch_match = bool(re.search(r'(?:^|/)issue-' + n_esc + r'(?:-|$)', ref))
    body_match   = bool(re.search(body_pat, hay))
    if branch_match or body_match:
        siblings.append(str(pr.get('number','')))
if siblings:
    print('blocked:' + ','.join(siblings))
else:
    print('ok')
" "$_issue_n" "$_pr_num" "$_REPO" 2>/dev/null)"
      case "$_sibling_result" in
        ok)
          return 0
          ;;
        blocked:*)
          local _sibling_list="${_sibling_result#blocked:}"
          echo "pipeline-vcs: check-closing-keyword: PR #${_pr_num} carries 'Closes #${_issue_n}' but open sibling PR(s) still reference the same issue: #${_sibling_list/,/ #} -- merge the siblings first, or change this PR body to 'Part of #${_issue_n}'" >&2
          exit 1
          ;;
        *)
          echo "talos:closing-keyword-unverified pr=$_pr_num issue=$_issue_n reason=unexpected-sibling-result"
          return 0
          ;;
      esac
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
    find-pr|check-pr-files|rerun-ci|check-closing-keyword)
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
# Post a comment to an Azure DevOps work item. `az boards work-item comment add`
# does not exist in the azure-devops extension, so use the REST comments endpoint
# via `az rest` (needs an absolute org URL + project name).
_azure_post_comment() {
  local n="$1" body="$2"
  # Work-item comments render HTML (unlike PR threads) — convert markdown bodies.
  body="$(_md_to_html "$body")"
  local base_org="$AZURE_ORG" proj="$AZURE_PROJECT"
  [ -z "$base_org" ] && base_org="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
  [ -z "$proj" ]     && proj="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^project/{print $2}' | tr -d '[:space:]')"
  if [ -z "$base_org" ] || [ -z "$proj" ]; then
    echo "pipeline-vcs: azure comment needs an org URL + project — set vcs.azure.org_url and vcs.azure.project" >&2
    return 1
  fi
  base_org="${base_org%/}"
  local url="$base_org/$proj/_apis/wit/workItems/$n/comments?api-version=7.1-preview.3"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] az rest --method post --url $url --body {\"text\":$body}"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"text": sys.argv[2]}))' "$tmp" "$body"
  az rest --method post --url "$url" \
    --resource "499b84ac-1321-427f-aa17-267ca6975798" \
    --headers "Content-Type=application/json" --body "@$tmp" >/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Echo the ADO Git REST base URL ({org}/{project}/_apis/git/repositories/{repo}).
# Returns non-zero if org/project/repo can't be resolved. Used by the PR verbs
# that az has no command for (labels, comment threads) — reached via `az rest`.
_azure_git_base() {
  local base_org="$AZURE_ORG" proj="$AZURE_PROJECT" repo="$REPO"
  [ -z "$base_org" ] && base_org="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
  [ -z "$proj" ]     && proj="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^project/{print $2}' | tr -d '[:space:]')"
  [ -z "$repo" ] && return 1
  [ -z "$base_org" ] || [ -z "$proj" ] && return 1
  echo "${base_org%/}/$proj/_apis/git/repositories/$repo"
}
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"  # Azure DevOps AAD app id (az rest --resource)

# Convert a markdown string to HTML for Azure DevOps HTML-rendered fields.
# ADO work-item Description and work-item comments render HTML, NOT markdown, so
# GitHub-flavored markdown bodies (e.g. planner-generated sub-issues) would
# otherwise show raw '#', '**', '- [ ]' text. PR comment threads DO render
# markdown, so this is applied only to work-item Description + comments, never PR
# threads. Passes the body through unchanged when it already looks like HTML.
# Prefers pandoc, then the python `markdown` lib, then a self-contained fallback
# (python3 is already a hard dependency of this adapter).
_md_to_html() {
  local md="$1"
  [ -z "$md" ] && { printf ''; return 0; }
  # Already HTML? (first non-space char is '<') — pass through untouched.
  case "$(printf '%s' "$md" | sed -e 's/^[[:space:]]*//')" in
    '<'*) printf '%s' "$md"; return 0 ;;
  esac
  if command -v pandoc >/dev/null 2>&1; then
    printf '%s' "$md" | pandoc -f gfm -t html 2>/dev/null && return 0
  fi
  python3 - "$md" <<'PYEOF'
import sys, html, re
src = sys.argv[1]
try:
    import markdown  # best fidelity when the lib is installed
    sys.stdout.write(markdown.markdown(src, extensions=['tables', 'fenced_code', 'sane_lists']))
    sys.exit(0)
except Exception:
    pass

def inline(text):
    text = html.escape(text, quote=False)
    codes = []
    def stash(m):
        codes.append(m.group(1)); return "\x00%d\x00" % (len(codes) - 1)
    text = re.sub(r'`([^`]+)`', stash, text)
    text = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', text)
    text = re.sub(r'(?<!\w)_([^_]+)_(?!\w)', r'<em>\1</em>', text)
    text = re.sub(r'\x00(\d+)\x00', lambda m: "<code>%s</code>" % codes[int(m.group(1))], text)
    return text

def cells(s):
    s = re.sub(r'^\|', '', s.strip()); s = re.sub(r'\|$', '', s)
    return [c.strip() for c in s.split('|')]

def is_sep(s):
    return bool(re.match(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$', s))

lines = src.replace('\r\n', '\n').split('\n')
out = []; i = 0; n = len(lines)
while i < n:
    line = lines[i]
    if re.match(r'^\s*```', line):
        i += 1; buf = []
        while i < n and not re.match(r'^\s*```\s*$', lines[i]):
            buf.append(html.escape(lines[i], quote=False)); i += 1
        i += 1
        out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>'); continue
    m = re.match(r'^(#{1,6})\s+(.*)$', line)
    if m:
        lv = len(m.group(1))
        out.append('<h%d>%s</h%d>' % (lv, inline(m.group(2).strip()), lv)); i += 1; continue
    if '|' in line and i + 1 < n and is_sep(lines[i + 1]):
        header = cells(line); i += 2; rows = []
        while i < n and '|' in lines[i] and lines[i].strip():
            rows.append(cells(lines[i])); i += 1
        t = ['<table border="1" cellpadding="6" cellspacing="0">']
        t.append('<tr>' + ''.join('<th>%s</th>' % inline(c) for c in header) + '</tr>')
        for r in rows:
            t.append('<tr>' + ''.join('<td>%s</td>' % inline(c) for c in r) + '</tr>')
        t.append('</table>'); out.append('\n'.join(t)); continue
    if re.match(r'^\s*[-*+]\s+', line):
        items = []
        while i < n and re.match(r'^\s*[-*+]\s+', lines[i]):
            it = re.sub(r'^\s*[-*+]\s+', '', lines[i])
            it = re.sub(r'^\[( |x|X)\]\s*', lambda mm: '☐ ' if mm.group(1) == ' ' else '☑ ', it)
            items.append('<li>%s</li>' % inline(it)); i += 1
        out.append('<ul>' + ''.join(items) + '</ul>'); continue
    if re.match(r'^\s*\d+\.\s+', line):
        items = []
        while i < n and re.match(r'^\s*\d+\.\s+', lines[i]):
            it = re.sub(r'^\s*\d+\.\s+', '', lines[i]); items.append('<li>%s</li>' % inline(it)); i += 1
        out.append('<ol>' + ''.join(items) + '</ol>'); continue
    if line.strip() == '':
        i += 1; continue
    buf = [line]; i += 1
    while i < n and lines[i].strip() != '' and not re.match(r'^\s*(#{1,6}\s|```|[-*+]\s|\d+\.\s)', lines[i]):
        buf.append(lines[i]); i += 1
    out.append('<p>' + inline(' '.join(b.strip() for b in buf)) + '</p>')
sys.stdout.write('\n'.join(out))
PYEOF
}

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
      # ADO has no `az boards work-item list`. Discover work items with a WIQL
      # query instead. The GitHub adapter's "open issues only" maps to ADO's
      # non-terminal states — which are Done/Removed/Closed, not just Closed —
      # so exclude all three.
      _run az boards query $ORG_ARG $PROJ_ARG \
        --wiql "SELECT [System.Id], [System.Title], [System.State], [System.Tags] FROM WorkItems WHERE [System.State] NOT IN ('Closed', 'Done', 'Removed') ORDER BY [System.ChangedDate] DESC" \
        --output json
      ;;
    view-issue)
      _run az boards work-item show --id "$1" $ORG_ARG --output json
      ;;
    comment-issue)
      _azure_post_comment "$1" "$2"
      ;;
    close-issue)
      local n="$1" body="$2"
      _azure_post_comment "$n" "$body"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards work-item update --id $n --state Done $ORG_ARG"
      else
        az boards work-item update --id "$n" --state Done $ORG_ARG
      fi
      ;;
    label-issue)
      # Azure uses tags, not labels. Manage the whole System.Tags string.
      # `az boards work-item update` has no --tags flag, and its
      # `--fields System.Tags=...` path APPENDS (it issues a json-patch "add",
      # which ADO merges for tags) — so it can never REMOVE a tag. The only
      # reliable way to set the exact tag set is a json-patch "replace" via the
      # REST API. `az devops invoke` mishandles json-patch bodies, so use
      # `az rest`, which needs an absolute org URL (az devops defaults don't
      # apply to it).
      local n="$1"; shift
      _parse_label_args "$@"
      local base_org="$AZURE_ORG"
      if [ -z "$base_org" ]; then
        base_org="$(az devops configure --list 2>/dev/null \
          | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
      fi
      if [ -z "$base_org" ]; then
        echo "pipeline-vcs: azure label-issue needs an org URL — set vcs.azure.org_url or run 'az devops configure --defaults organization=<url>'" >&2
        exit 1
      fi
      # Fetch current tags
      local current_tags
      current_tags="$(az boards work-item show --id "$n" $ORG_ARG \
        --query fields.\"System.Tags\" -o tsv 2>/dev/null || echo "")"
      python3 - "$n" "$current_tags" "$ADD_LABELS" "$REMOVE_LABELS" \
        "$DRY_RUN" "$base_org" <<'PYEOF'
import json, os, subprocess, sys, tempfile
n, cur, add_s, rem_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dry_run = sys.argv[5] == 'true'
base_org = sys.argv[6].rstrip('/')
tags = {t.strip() for t in cur.split(';') if t.strip()}
for t in add_s.split(): tags.add(t)
for t in rem_s.split(): tags.discard(t)
new_tags = '; '.join(sorted(tags))
url = f'{base_org}/_apis/wit/workitems/{n}?api-version=7.1'
ADO_RESOURCE = '499b84ac-1321-427f-aa17-267ca6975798'  # Azure DevOps AAD app id
# "replace" needs the field to exist; use "add" when the item has no tags yet.
op = 'replace' if cur.strip() else 'add'
patch = [{'op': op, 'path': '/fields/System.Tags', 'value': new_tags}]
if dry_run:
    print(f'[dry-run] az rest --method patch --url {url} --body {json.dumps(patch)}')
    sys.exit(0)
with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
    json.dump(patch, f)
    body_path = f.name
try:
    subprocess.run(['az', 'rest', '--method', 'patch', '--url', url,
                    '--resource', ADO_RESOURCE,
                    '--headers', 'Content-Type=application/json-patch+json',
                    '--body', f'@{body_path}'], check=True)
finally:
    os.unlink(body_path)
PYEOF
      ;;
    create-issue)
      # Signature mirrors github: create-issue <title> <body-file> [--label L]...
      # Labels map to ADO Tags. Work-item type + area path come from config so new
      # items land on the right board (vcs.azure.work_item_type / vcs.azure.area_path).
      local title="$1" body_file="$2"; shift 2
      local ci_tags=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) ci_tags="${ci_tags:+$ci_tags; }$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      local wtype ci_area ci_desc
      wtype="$(cfg vcs.azure.work_item_type 'Product Backlog Item')"
      ci_area="$(cfg vcs.azure.area_path '')"
      ci_desc=""; [ -f "$body_file" ] && ci_desc="$(cat "$body_file")"
      # ADO's Description is an HTML field — convert the markdown body so it
      # renders instead of showing raw '#'/'**'/'- [ ]' text.
      [ -n "$ci_desc" ] && ci_desc="$(_md_to_html "$ci_desc")"
      local ci_args=(boards work-item create --title "$title" --type "$wtype")
      [ -n "$AZURE_ORG" ]     && ci_args+=(--org "$AZURE_ORG")
      [ -n "$AZURE_PROJECT" ] && ci_args+=(--project "$AZURE_PROJECT")
      [ -n "$ci_area" ]       && ci_args+=(--area "$ci_area")
      [ -n "$ci_desc" ]       && ci_args+=(--description "$ci_desc")
      [ -n "$ci_tags" ]       && ci_args+=(--fields "System.Tags=$ci_tags")
      ci_args+=(--output json)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az ${ci_args[*]}"
      else
        az "${ci_args[@]}"
      fi
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
      # `az repos pr create` requires --repository. REPO comes from vcs.repo
      # (or git-remote auto-detect); pass it only when set so az emits its own
      # clear error rather than us fabricating a repo name.
      local repo_arg=""; [ -n "$REPO" ] && repo_arg="--repository $REPO"
      _run az repos pr create \
        --source-branch "$branch" --target-branch "$BASE_BRANCH" \
        --title "$title" --description "$(cat "$body_file")" \
        $ORG_ARG $PROJ_ARG $repo_arg --output json
      ;;
    view-pr)
      _run az repos pr show --id "$1" $ORG_ARG --output json
      ;;
    list-prs)
      _run az repos pr list --status active $ORG_ARG $PROJ_ARG --output json
      ;;
    diff-pr)
      # az has no PR-diff command. Fetch both refs and diff them — this reads the
      # change without touching the working tree, so reviewer/security stay safe.
      local n="$1" src tgt
      src="$(az repos pr show --id "$n" $ORG_ARG --query sourceRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      tgt="$(az repos pr show --id "$n" $ORG_ARG --query targetRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      [ -z "$tgt" ] && tgt="${BASE_BRANCH:-main}"
      if [ -z "$src" ]; then echo "pipeline-vcs: could not resolve PR #$n source branch" >&2; return 1; fi
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] git fetch origin $tgt $src && git diff origin/$tgt...origin/$src"; return 0
      fi
      git fetch -q origin "$tgt" "$src" 2>/dev/null
      git diff "origin/$tgt...origin/$src"
      ;;
    checkout-pr)
      # Detached checkout of the fetched head — a named `git checkout <branch>`
      # fails with "already checked out" while the developer worktree still holds
      # the branch. Detaching sidesteps that and lets QA run in its own worktree.
      local n="$1" src
      src="$(az repos pr show --id "$n" $ORG_ARG --query sourceRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      if [ -z "$src" ]; then echo "pipeline-vcs: could not resolve PR #$n source branch" >&2; return 1; fi
      _run git fetch origin "$src"
      _run git checkout --detach FETCH_HEAD
      ;;
    approve-pr)
      local n="$1" body="${2:-}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr set-vote --id $n --vote approve $ORG_ARG"
        [ -n "$body" ] && echo "[dry-run] (comment via PR thread REST)"
      else
        # set-vote may fail with "cannot approve your own pull request" in
        # single-account setups — expected and ignorable; the review:approved
        # label is the gate. Post the body as a PR thread (az has no comment cmd).
        az repos pr set-vote --id "$n" --vote approve $ORG_ARG 2>/dev/null || true
        if [ -n "$body" ]; then
          local gitbase; if gitbase="$(_azure_git_base)"; then
            local tf; tf="$(mktemp)"
            python3 -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"comments":[{"parentCommentId":0,"content":sys.argv[2],"commentType":1}],"status":1}))' "$tf" "$body"
            az rest --method post --url "$gitbase/pullRequests/$n/threads?api-version=7.1-preview.1" \
              --resource "$ADO_RESOURCE" --headers "Content-Type=application/json" --body "@$tf" >/dev/null 2>&1 || true
            rm -f "$tf"
          fi
        fi
      fi
      ;;
    label-pr)
      # ADO PRs DO support labels via the REST API (az has no command for it).
      local n="$1"; shift
      _parse_label_args "$@"
      local gitbase; gitbase="$(_azure_git_base)" || { echo "pipeline-vcs: azure label-pr needs org/project/repo (vcs.azure.org_url, vcs.azure.project, vcs.repo)" >&2; return 0; }
      local l tf
      for l in $ADD_LABELS; do
        if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] az rest POST $gitbase/pullRequests/$n/labels {\"name\":\"$l\"}"; continue; fi
        tf="$(mktemp)"; python3 -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"name":sys.argv[2]}))' "$tf" "$l"
        az rest --method post --url "$gitbase/pullRequests/$n/labels?api-version=7.1-preview.1" \
          --resource "$ADO_RESOURCE" --headers "Content-Type=application/json" --body "@$tf" >/dev/null 2>&1 \
          || echo "pipeline-vcs: label-pr add '$l' failed on PR #$n" >&2
        rm -f "$tf"
      done
      # ADO rejects ':' in a URL path, and every Talos label has one, so DELETE
      # by label id (not name). Resolve names→ids from one GET.
      if [ -n "$REMOVE_LABELS" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          for l in $REMOVE_LABELS; do echo "[dry-run] az rest DELETE (resolve id for '$l') $gitbase/pullRequests/$n/labels/<id>"; done
        else
          local labels_json; labels_json="$(az rest --method get \
            --url "$gitbase/pullRequests/$n/labels?api-version=7.1-preview.1" \
            --resource "$ADO_RESOURCE" 2>/dev/null)"
          for l in $REMOVE_LABELS; do
            local lid; lid="$(printf '%s' "$labels_json" | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((x['id'] for x in d.get('value',[]) if x.get('name')==sys.argv[1]),''))" "$l" 2>/dev/null)"
            [ -z "$lid" ] && continue
            az rest --method delete --url "$gitbase/pullRequests/$n/labels/$lid?api-version=7.1-preview.1" \
              --resource "$ADO_RESOURCE" >/dev/null 2>&1 || true
          done
        fi
      fi
      ;;
    pr-checks)
      _run az repos pr show --id "$1" $ORG_ARG \
        --query "{status:status,mergeStatus:mergeStatus}" --output json
      ;;
    merge-pr)
      _run az repos pr update --id "$1" --status completed $ORG_ARG --output json
      ;;
    comment-pr)
      # az has no PR-comment command; post a thread via REST.
      local n="$1" body="$2"
      local gitbase; gitbase="$(_azure_git_base)" || { echo "pipeline-vcs: azure comment-pr needs org/project/repo" >&2; return 0; }
      local url="$gitbase/pullRequests/$n/threads?api-version=7.1-preview.1"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] az rest POST $url {\"comments\":[{\"content\":<body>}]}"; return 0; fi
      local tf; tf="$(mktemp)"
      python3 -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"comments":[{"parentCommentId":0,"content":sys.argv[2],"commentType":1}],"status":1}))' "$tf" "$body"
      az rest --method post --url "$url" --resource "$ADO_RESOURCE" \
        --headers "Content-Type=application/json" --body "@$tf" >/dev/null
      local rc=$?; rm -f "$tf"; return $rc
      ;;
    find-pr|check-pr-files|rerun-ci|check-closing-keyword)
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
    diff-pr|pr-checks|list-prs|view-pr|find-pr|check-pr-files|rerun-ci|check-closing-keyword)
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

# ── Comment-body normalisation ────────────────────────────────────────────────
# `comment-issue` / `comment-pr` take the body POSITIONALLY, but four lines above
# in the verb list `create-issue` / `create-pr` take a body *file*. That
# inconsistency is a trap: an agent composing a multi-KB markdown verdict
# reaches for `--body-file` by analogy — with this script's own siblings, and
# with `gh` — and the provider branches took "$2" as the body verbatim. The
# result was `gh issue comment N --body "--body-file"`: a comment whose entire
# content is the literal flag, the real verdict discarded, and exit 0.
#
# Silent, so it survives until someone audits comment content. Three verdicts
# were lost in a single pipeline run before it was noticed. Wanting a file is
# also legitimate rather than lazy — long markdown is hostile as a shell
# argument, and a body containing raw URLs can be refused outright by a
# permission rule, leaving a file as the only route.
#
# So accept both spellings, and refuse a body that is still a bare flag instead
# of posting it. Applied before dispatch, so every provider inherits it.
case "$VERB" in
  comment-issue|comment-pr)
    if [ "${#ARGS[@]}" -ge 3 ]; then
      case "${ARGS[1]}" in
        --body-file)
          if [ -r "${ARGS[2]}" ]; then
            ARGS=("${ARGS[0]}" "$(cat "${ARGS[2]}")")
          else
            echo "pipeline-vcs: $VERB --body-file: cannot read '${ARGS[2]}'" >&2
            exit 1
          fi
          ;;
        --body)
          ARGS=("${ARGS[0]}" "${ARGS[2]}")
          ;;
      esac
    fi
    case "${ARGS[1]-}" in
      --*)
        echo "pipeline-vcs: $VERB: body looks like a flag ('${ARGS[1]}'), not comment text." >&2
        echo "              Usage: $VERB <number> <body>            # body is POSITIONAL" >&2
        echo "              or:    $VERB <number> --body-file <path>" >&2
        exit 1
        ;;
    esac
    # Bare readable absolute path guard (#94): an agent that writes a verdict to
    # a file and passes the path positionally gets a one-line path as the comment,
    # exits 0, and never notices. Detect and reject so --body-file is used instead.
    # Tie the check to [ -r ] so a body that merely looks path-like but does not
    # exist on this machine is posted as literal text (no over-rejection).
    case "${ARGS[1]-}" in
      /*)
        if [ -r "${ARGS[1]}" ]; then
          echo "pipeline-vcs: $VERB: body looks like a file path ('${ARGS[1]}'), not comment text." >&2
          echo "pipeline-vcs:   Use --body-file to post a file:" >&2
          printf 'pipeline-vcs:     bash scripts/pipeline-vcs.sh %s %s --body-file %s\n' \
            "$VERB" "${ARGS[0]}" "${ARGS[1]}" >&2
          exit 1
        fi
        ;;
    esac
    ;;
esac

# ── assert-sync: working-tree precondition (provider-agnostic) ───────────────
# Called by the orchestrator before dispatching non-worktree-isolated stages.
# Provider-agnostic: exits before the provider dispatch so it works regardless
# of which VCS provider is configured.
if [ "$VERB" = "assert-sync" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] assert-sync: would check dirty tree, fetch origin, compare HEAD to origin/<base_branch>"
    exit 0
  fi

  # Step 1: Dirty tree — refuse BEFORE fetching.
  # Do not stash, do not pull over uncommitted work. Pulling over a dirty tree
  # risks mixing in-progress work into what a non-isolated stage reads, or
  # silently discarding it on conflict.
  _as_dirty="$(git status --porcelain 2>/dev/null)"
  if [ -n "$_as_dirty" ]; then
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree is dirty; commit or stash before running the pipeline.
Dirty files:
%s
' "$_as_dirty" >&2
    exit 1
  fi

  # Step 2: Resolve base branch (same logic as SKILL.md config defaults:
  # configured value first, then symbolic-ref, then fall back to 'main').
  _as_base="$BASE_BRANCH"
  if [ -z "$_as_base" ]; then
    _as_base="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  fi
  [ -z "$_as_base" ] && _as_base="main"

  # Step 3: Fetch — network failure is itself a reason to abort, not continue.
  if ! git fetch origin 2>/dev/null; then
    echo "pipeline-vcs: assert-sync: ABORT -- git fetch origin failed; check network connectivity." >&2
    exit 1
  fi

  # Step 4: Compare HEAD to origin/<base>.
  # Note: git rev-parse HEAD here answers "what commit is my working tree at?" —
  # a different question from "what commit does the PR point at?" (use pr-head for that).
  # The pr-head verb is for agents writing approval markers; this is a shell comparison
  # of two git refs to verify the working tree is current.
  _as_local="$(git rev-parse HEAD 2>/dev/null)"
  _as_origin="$(git rev-parse "origin/$_as_base" 2>/dev/null)"

  if [ -z "$_as_local" ] || [ -z "$_as_origin" ]; then
    echo "pipeline-vcs: assert-sync: ABORT -- could not resolve HEAD or origin/$_as_base" >&2
    exit 1
  fi

  if [ "$_as_local" = "$_as_origin" ]; then
    # Clean and level — exit 0, no output (safe to embed as a precondition
    # without cluttering orchestrator logs).
    exit 0
  fi

  _as_behind="$(git rev-list --count "HEAD..origin/$_as_base" 2>/dev/null || echo 0)"
  _as_ahead="$(git rev-list --count "origin/$_as_base..HEAD" 2>/dev/null || echo 0)"

  if [ "$_as_behind" -gt 0 ] && [ "$_as_ahead" -gt 0 ]; then
    # Diverged — both ahead and behind. Manual resolution required.
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree has diverged from origin/%s (ahead %s, behind %s commits). Manual resolution required -- do NOT force-push; this may represent legitimate concurrent work.
  local:          %s
  origin/%s: %s
' \
      "$_as_base" "$_as_ahead" "$_as_behind" \
      "$_as_local" "$_as_base" "$_as_origin" >&2
    exit 1
  elif [ "$_as_behind" -gt 0 ]; then
    # Behind — stale checkout. Abort so non-isolated stages read current source.
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree is behind origin/%s by %s commit(s). Run: git pull --ff-only
  local:          %s
  origin/%s: %s
' \
      "$_as_base" "$_as_behind" \
      "$_as_local" "$_as_base" "$_as_origin" >&2
    exit 1
  else
    # Ahead only — local has commits not yet pushed to origin/<base>.
    # The working tree is not stale; it is ahead of the remote.
    # Non-isolated stages reading this tree see a consistent, complete source
    # (even if not yet merged). Exits 0: ahead is not the failure mode this
    # check guards against. A warning is printed so a human with in-flight
    # local commits is aware — in normal automated use the orchestrator never
    # commits to the base branch, making this state unreachable automatically.
    printf 'pipeline-vcs: assert-sync: WARNING -- working tree is ahead of origin/%s by %s commit(s); non-isolated stages will read unpushed commits.\n'       "$_as_base" "$_as_ahead" >&2
    exit 0
  fi
fi

# ── label-pr: approval-marker guard (#94) ────────────────────────────────────
# Recognised approval labels and their role names (same set as check-approval-sha).
# Two modes:
#   Default (no flag): after the label is applied, call check-approval-sha; if it
#     reports no current-head marker, print a loud WARNING to stderr and exit 0.
#     Non-fatal: profiles document label-then-stamp order; a fatal here deadlocks.
#   --require-marker: pre-apply check — fetch PR data directly, verify a marker
#     comment exists for the role being labelled; exit 1 if absent (label not applied).
#
# --require-marker is stripped from ARGS so provider functions never see it.
# _ADDING_APPROVAL_LABELS and _REQUIRE_MARKER are consumed by the post-dispatch block.
_REQUIRE_MARKER=false
_ADDING_APPROVAL_LABELS=""
_LABEL_PR_N=""
if [ "$VERB" = "label-pr" ] && [ "${#ARGS[@]}" -ge 1 ]; then
  _LABEL_PR_N="${ARGS[0]}"
  _lp_filtered=("${ARGS[0]}")
  _lp_i=1
  while [ "$_lp_i" -lt "${#ARGS[@]}" ]; do
    _lp_arg="${ARGS[$_lp_i]}"
    case "$_lp_arg" in
      --require-marker)
        _REQUIRE_MARKER=true ;;
      --add)
        _lp_ni=$((_lp_i + 1))
        _lp_lbl="${ARGS[$_lp_ni]:-}"
        _lp_filtered+=("$_lp_arg" "$_lp_lbl")
        case "$_lp_lbl" in
          qa:pass|review:approved|security:approved|docs:done)
            _ADDING_APPROVAL_LABELS="$_ADDING_APPROVAL_LABELS $_lp_lbl" ;;
        esac
        _lp_i=$((_lp_ni + 1))
        continue ;;
      *)
        _lp_filtered+=("$_lp_arg") ;;
    esac
    _lp_i=$((_lp_i + 1))
  done
  ARGS=("${_lp_filtered[@]}")
  _ADDING_APPROVAL_LABELS="${_ADDING_APPROVAL_LABELS# }"

  # --require-marker: pre-apply check.  Fetch PR data and verify a marker comment
  # exists for each approval label being added.  Exit 1 (fatal) if absent.
  # Only implemented for the github provider (check-approval-sha is github-only).
  if [ "$_REQUIRE_MARKER" = "true" ] && [ -n "$_ADDING_APPROVAL_LABELS" ] \
      && [ "$DRY_RUN" != "true" ] && [ "$PROVIDER" = "github" ]; then
    _lp_pr_data=""
    _lp_pr_data="$(gh pr view "$_LABEL_PR_N" --json headRefOid,baseRefName,labels,comments \
      ${REPO:+--repo "$REPO"} 2>/dev/null)" || true
    _lp_head_sha=""
    _lp_comments=""
    if [ -n "$_lp_pr_data" ]; then
      _lp_head_sha="$(printf '%s' "$_lp_pr_data" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('headRefOid',''))" \
        2>/dev/null)" || true
      _lp_comments="$(printf '%s' "$_lp_pr_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('comments', []):
    print(c.get('body', ''))
" 2>/dev/null)" || true
    fi
    _lp_marker_found=false
    if [ -n "$_lp_head_sha" ]; then
      for _lp_lbl in $_ADDING_APPROVAL_LABELS; do
        case "$_lp_lbl" in
          qa:pass)           _lp_role=qa ;;
          review:approved)   _lp_role=reviewer ;;
          security:approved) _lp_role=security ;;
          docs:done)         _lp_role=docs ;;
          *)                 continue ;;
        esac
        if printf '%s
' "$_lp_comments" \
            | grep -qF "talos:approval sha=$_lp_head_sha role=$_lp_role"; then
          _lp_marker_found=true
          break
        fi
      done
    fi
    if [ "$_lp_marker_found" = "false" ]; then
      echo "pipeline-vcs: label-pr: ERROR — --require-marker: no approval marker found at current head." >&2
      echo "pipeline-vcs: label-pr: The gate will reject this PR. Post the marker first, then label:" >&2
      printf 'pipeline-vcs:   HEAD_SHA=$(bash scripts/pipeline-vcs.sh pr-head %s)
' \
        "$_LABEL_PR_N" >&2
      printf 'pipeline-vcs:   bash scripts/pipeline-vcs.sh comment-pr %s "<!-- talos:approval sha=$HEAD_SHA role=<role> -->"
' \
        "$_LABEL_PR_N" >&2
      exit 1
    fi
  fi
fi

# ── Main dispatch ─────────────────────────────────────────────────────────────
_DISPATCH_RC=0
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
_DISPATCH_RC=$?

# ── Post-dispatch: label-pr approval-marker warning (#94, #115) ──────────────
# After label-pr successfully adds a recognised approval label, verify that a
# matching marker comment exists at the current head.  Fetches headRefOid and
# comments directly — no label re-read, no race window (#115).  Exit remains 0
# (profiles label before stamping; the merge gate is the hard enforcement).
# Only runs for the github provider.
#
# Invariant: _ADDING_APPROVAL_LABELS is known locally; no remote label fetch is
# needed.  The only remote reads are headRefOid (cheap) and comments (already
# present in the PR object).  The race that plagued check-approval-sha cannot
# occur here because we never re-read the labels we just applied.
if [ "$VERB" = "label-pr" ] && [ -n "${_ADDING_APPROVAL_LABELS:-}" ] \
    && [ "${_REQUIRE_MARKER:-false}" = "false" ] && [ "$DRY_RUN" != "true" ] \
    && [ "$PROVIDER" = "github" ] && [ "$_DISPATCH_RC" -eq 0 ]; then
  _pd_pr_data=""
  _pd_pr_data="$(gh pr view "$_LABEL_PR_N" --json headRefOid,comments \
    ${REPO:+--repo "$REPO"} 2>/dev/null)" || true
  _pd_head_sha=""
  _pd_comments=""
  if [ -n "$_pd_pr_data" ]; then
    _pd_head_sha="$(printf '%s' "$_pd_pr_data" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('headRefOid',''))" \
      2>/dev/null)" || true
    _pd_comments="$(printf '%s' "$_pd_pr_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('comments', []):
    print(c.get('body', ''))
" 2>/dev/null)" || true
  fi
  _pd_missing=false
  if [ -n "$_pd_head_sha" ]; then
    for _pd_lbl in $_ADDING_APPROVAL_LABELS; do
      case "$_pd_lbl" in
        qa:pass)           _pd_role=qa ;;
        review:approved)   _pd_role=reviewer ;;
        security:approved) _pd_role=security ;;
        docs:done)         _pd_role=docs ;;
        *) continue ;;
      esac
      if ! printf '%s\n' "$_pd_comments" \
          | grep -qF "talos:approval sha=$_pd_head_sha role=$_pd_role"; then
        _pd_missing=true
        break
      fi
    done
  fi
  if [ "$_pd_missing" = "true" ]; then
    echo "pipeline-vcs: label-pr: WARNING — added approval label(s) but no approval marker found at current head." >&2
    echo "pipeline-vcs: label-pr: If you have not already posted your verdict reasoning, do so first." >&2
    echo "pipeline-vcs: label-pr: The gate will reject this PR. Post the marker:" >&2
    for _lp_wl in $_ADDING_APPROVAL_LABELS; do
      case "$_lp_wl" in
        qa:pass)           _lp_wr=qa ;;
        review:approved)   _lp_wr=reviewer ;;
        security:approved) _lp_wr=security ;;
        docs:done)         _lp_wr=docs ;;
        *) continue ;;
      esac
      printf 'pipeline-vcs:   HEAD_SHA=$(bash scripts/pipeline-vcs.sh pr-head %s)\n' \
        "$_LABEL_PR_N" >&2
      printf 'pipeline-vcs:   bash scripts/pipeline-vcs.sh comment-pr %s "<!-- talos:approval sha=$HEAD_SHA role=%s -->"\n' \
        "$_LABEL_PR_N" "$_lp_wr" >&2
    done
  fi
fi
exit "$_DISPATCH_RC"
