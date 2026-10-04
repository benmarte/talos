#!/usr/bin/env bash
# pipeline-draft-check.sh -- the draft-PR default (#435): the one resolver for
# `pr.draft` and the check that the repo's CI pairs with it.
#
# Usage: pipeline-draft-check.sh [check [<workflows-dir>]]
#        pipeline-draft-check.sh resolve
#
#   check     Scan <workflows-dir> (default .github/workflows) for *.yml and
#             *.yaml and print ONE status on stdout. Always exit 0 (fail open:
#             a check problem never blocks a run).
#               ok                a workflow has a `pull_request` trigger that
#                                 lists `ready_for_review` in `types`, and a
#                                 job- (or workflow-) level `if:` that reads
#                                 github.event.pull_request.draft
#               no-skip           PR-triggered workflows exist, none skips drafts
#               no-ready-trigger  a draft skip exists but `ready_for_review` is
#                                 not in `types`: `ready-pr` fires no event, no
#                                 run starts, and QA waits for one for nothing
#               none              no workflow has a `pull_request` trigger
#               unknown           parse error, `pull_request_target`, a reusable
#                                 workflow, anything doubtful
#             It parses with PyYAML when importable, else a conservative grep
#             of the same three signals. Setting TALOS_DRAFT_CHECK_NO_YAML=1
#             forces the grep path (the tests use it). Never edits a file.
#   resolve   The effective PR_DRAFT on stdout, `true` or `false`, from
#             `pr.draft` and `vcs.provider`; at most one warning line on stderr.
#               explicit false                         false
#               github-api, file                       false (they cannot open
#                                                      draft PRs); warns when a
#                                                      `true` was asked for or
#                                                      defaulted (file: only an
#                                                      explicit true; no PRs
#                                                      exist there)
#               gitlab, azure                          true unless explicit false
#               github, unset or true                  true, after the CI check:
#                 no-skip / unknown                    warn, stay true (only the
#                                                      saving is lost)
#                 no-ready-trigger                     key unset: warn and
#                                                      false (the ready flow, so
#                                                      QA cannot hang); explicit
#                                                      true: warn, stay true
#             Used by /pipeline Step 0 and pipeline-status-file.sh, so both
#             read the same value.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── check ─────────────────────────────────────────────────────────────────────
# Per file, four 0/1 flags: trigger skip ready unknown.
_dc_flags_yaml() {
  python3 -I - "$1" 2>/dev/null <<'TALOS_k3v9XqLm2Wd7'
import sys
import yaml

DRAFT = "github.event.pull_request.draft"

def names(on):
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(x) for x in on}
    if isinstance(on, dict):
        return {str(k) for k in on}
    return set()

def has_draft(v):
    return isinstance(v, str) and DRAFT in v

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        raise ValueError("not a mapping")
    # PyYAML reads the bare key `on` as the boolean True.
    on = doc.get(True, doc.get("on"))
    trig = names(on)
    if "pull_request" not in trig:
        unknown = 1 if (trig & {"pull_request_target", "workflow_call"} or not trig) else 0
        print(0, 0, 0, unknown)
        sys.exit(0)
    pr = on.get("pull_request") if isinstance(on, dict) else None
    types = pr.get("types") if isinstance(pr, dict) else None
    if isinstance(types, str):
        types = [types]
    ready = int(isinstance(types, list) and "ready_for_review" in types)
    jobs = doc.get("jobs")
    jobs = jobs if isinstance(jobs, dict) else {}
    skip = int(has_draft(doc.get("if")) or any(
        isinstance(j, dict) and has_draft(j.get("if")) for j in jobs.values()))
    # A job that calls a reusable workflow may skip drafts where this file
    # cannot see: doubtful, not "no-skip".
    unknown = int(not skip and any(
        isinstance(j, dict) and "uses" in j for j in jobs.values()))
    print(1, skip, ready, unknown)
except Exception:
    print(0, 0, 0, 1)
TALOS_k3v9XqLm2Wd7
}

_dc_flags_grep() {
  local f="$1" t s r u txt
  txt="$(sed 's/[[:space:]]*#.*//' "$f" 2>/dev/null)" || { echo "0 0 0 1"; return; }
  t=0; s=0; r=0; u=0
  if printf '%s\n' "$txt" | grep -Eq '^[[:space:]]*(-[[:space:]]*)?pull_request[[:space:]]*:?[[:space:]]*$|^[[:space:]]*(on|"on"|true)[[:space:]]*:[[:space:]]*(pull_request[[:space:]]*$|\[([^]]*[[:space:],])?pull_request[],[:space:]])'; then
    t=1
    printf '%s\n' "$txt" | grep -q 'ready_for_review' && r=1
    printf '%s\n' "$txt" | grep -Eq 'github\.event\.pull_request\.draft' && s=1
    [ "$s" = 0 ] && printf '%s\n' "$txt" | grep -Eq '^[[:space:]]*uses:' && u=1
  elif printf '%s\n' "$txt" | grep -Eq 'pull_request_target|workflow_call'; then
    u=1
  fi
  echo "$t $s $r $u"
}

_dc_check() {
  local dir="${1:-.github/workflows}" f flags t s r u
  local ok=0 noready=0 unk=0 prs=0 have_yaml=0
  if [ "${TALOS_DRAFT_CHECK_NO_YAML:-}" != 1 ] && python3 -I -c 'import yaml' 2>/dev/null; then
    have_yaml=1
  fi
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue   # an unmatched glob stays literal: skip it
    if [ "$have_yaml" = 1 ]; then flags="$(_dc_flags_yaml "$f")"; else flags="$(_dc_flags_grep "$f")"; fi
    # shellcheck disable=SC2034
    read -r t s r u <<EOF
$flags
EOF
    case "${t:-x}${s:-x}${r:-x}${u:-x}" in
      [01][01][01][01]) ;;
      *) unk=1; continue ;;
    esac
    [ "$u" = 1 ] && unk=1
    [ "$t" = 1 ] || continue
    prs=1
    if [ "$s" = 1 ] && [ "$r" = 1 ]; then ok=1
    elif [ "$s" = 1 ]; then noready=1
    fi
  done
  if [ "$ok" = 1 ]; then echo ok
  elif [ "$noready" = 1 ]; then echo no-ready-trigger
  elif [ "$unk" = 1 ]; then echo unknown
  elif [ "$prs" = 1 ]; then echo no-skip
  else echo none
  fi
}

# ── resolve ───────────────────────────────────────────────────────────────────
_dc_cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$1" "" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

_dc_resolve() {
  local key provider status
  key="$(_dc_cfg pr.draft)"
  case "$key" in true|false) ;; *) key="" ;; esac
  provider="$(_dc_cfg vcs.provider)"
  [ -n "$provider" ] || provider="github"
  [ "$key" = false ] && { echo false; return; }
  case "$provider" in
    github-api|file)
      if [ "$provider" = github-api ] || [ "$key" = true ]; then
        echo "pipeline: pr.draft ignored: provider $provider cannot open draft PRs" >&2
      fi
      echo false; return ;;
    github) ;;
    *) echo true; return ;;
  esac
  status="$(_dc_check)"
  case "$status" in
    no-skip)
      echo "pipeline: CI does not skip draft PRs; CI will still run on every push. See templates/ci/github-tests.yml" >&2 ;;
    no-ready-trigger)
      if [ -z "$key" ]; then
        echo "pipeline: CI skips draft PRs but has no ready_for_review trigger, so QA would wait for a run that never starts; using the ready PR flow for this run. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml) or set pr.draft: false" >&2
        echo false; return
      fi
      echo "pipeline: pr.draft is true but CI skips draft PRs without a ready_for_review trigger; QA will wait for a run that never starts. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml)" >&2 ;;
    unknown)
      echo "pipeline: could not verify that CI skips draft PRs; see templates/ci/github-tests.yml" >&2 ;;
  esac
  echo true
}

case "${1:-check}" in
  check)   _dc_check "${2:-}" ;;
  resolve) _dc_resolve ;;
  *) echo "usage: pipeline-draft-check.sh [check [<workflows-dir>] | resolve]" >&2; echo unknown ;;
esac
exit 0
