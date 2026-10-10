#!/usr/bin/env bash
# pipeline-status-file.sh -- `collect`: the normalised run state as JSON.
#
# Usage: pipeline-status-file.sh collect
#
# The GitHub (or other provider) state as one JSON object on stdout, from read
# verbs of pipeline-vcs.sh only: no worktree, commit, push, label or comment.
# `talos.sh state` and `talos.sh next` consume it (#470), and `talos.sh run`
# reads its `inflight` list. (Until #550 this script also maintained the tracked
# status file and its Resume block; that is gone -- a new session resumes from
# `talos.sh state`, and the name stays only because callers know it.)
#
# Output: {"prs": [...], "pr_total": n, "ignored": n, "blocked": [...],
# "queued": [...], "held": [...], "inflight": [...], "owners": [...],
# "capped": [...]}
#   prs       the open pipeline PRs, ascending, each {n, issue, head, owner, stage}.
#             A pipeline PR has a head branch matching ^(fix|feat)/issue-<digits>
#             (-|$), baseRefName equal to the base branch, and either a Talos label
#             (exactly a name in the stage or approval lists of pipeline-contract.sh)
#             or a listing that says isCrossRepository is false: a fork PR cannot
#             claim a pipeline slot by its branch name. Only the lowest-numbered PRs
#             are looked up (pr-head, check-approval-sha, pr-is-draft,
#             pr-checks-required), plus every higher one that carries the approval
#             label of every enabled role (and neither pipeline:blocked nor
#             pipeline:needs-owner), so 300 PRs cost the same reads as 40.
#             stage comes from pipeline-next.py, first match wins.
#   ignored   open PRs with a pipeline-style branch and no Talos label, from a fork
#   blocked   [["PR"|"issue", n], ...] carrying pipeline:blocked
#   queued    open issues labelled pipeline:ready, p0 p1 p2 unlabelled, then number
#   held      the queued ones that also carry pipeline:needs-owner
#   inflight  (#519) the issues `talos.sh run` resumes mid-state-machine: labelled
#             pipeline:confirmed, pipeline:dev or pipeline:epic-decomposed, not in
#             `queued`, not blocked or needs-owner, and with no open pipeline PR
#             (the PR side owns that work; a stale pipeline:dev beside an open PR
#             must never re-dispatch a developer)
#   owners    list-needs-owner --json items {n, status, question}, or null when the
#             provider has no such verb; status is answered|unanswered|unverified
#   capped    the list verbs whose result was capped
#   me, theirs, unclaimed   (#560) only while multi-user claiming is on
#             (issues.claim, an issues.assignee other than none, and a
#             resolvable identity; see talos_claim_resolve): `me` is the
#             operator's login, `theirs` the other operators' items, each
#             {kind: "issue"|"PR", n, issue, owner} -- an open issue assigned
#             to someone else, or a pipeline PR whose issue is -- and
#             `unclaimed` the issues of the queue, the in-flight list and the
#             open PRs with no assignee, which `talos.sh next` claims before it
#             dispatches. Everything above is then the operator's own: the
#             theirs items are left out of prs, blocked, queued, held,
#             inflight and owners, and their PRs cost no per-PR read. One bulk
#             `list-assignees` read; exit 2 (file mode) keeps the unfiltered
#             state, any other failure fails the run.
#
# Fail closed: list-prs, list-issues, pr-head, check-approval-sha or
# list-needs-owner exiting non-zero (list-needs-owner exit 2, an unsupported
# provider, excepted) exits 1 with no JSON. The whole read phase has a deadline
# (120 s; TALOS_STATUS_READ_DEADLINE overrides it, 1..3600): a read verb still
# running when it passes is killed and the run fails. INT, TERM or HUP kills the
# running read verb's process group before the script exits. Every python is
# `python3 -I`.
#
# Exit codes: 0 done; 1 usage, config or read failure (nothing on stdout).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  # cfg() (#169): config lookups from a per-invocation cache.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  # No per-call fallback (#440): it ran pipeline-config.sh under 2>/dev/null
  # inside $(...), so a broken defaults table (exit 3) would read as "role off".
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

# The Talos label list (#454): a PR counts as the pipeline's when it carries a
# label named in the contract, not one that merely starts `pipeline:`. A missing
# file leaves the arrays unset; collect then fails the read.
if [ -f "$SCRIPT_DIR/pipeline-contract.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-contract.sh"
fi

_sf_err() { echo "pipeline-status-file: $*" >&2; }

if [ "${1:-}" != "collect" ] || [ "$#" -ne 1 ]; then
  echo "usage: pipeline-status-file.sh collect" >&2
  exit 1
fi

# pipeline-next.py (#557) does the reading: the PR list, the issue queue, the
# stage of every open pipeline PR. A missing module fails closed: no stage is
# ever guessed, the run stops.
if [ ! -r "$SCRIPT_DIR/pipeline-next.py" ]; then
  echo "talos: pipeline-next.py missing; reinstall Talos" >&2
  exit 1
fi

# _sf_role_on KEY: the table default decides: enabled when not false (default
# true) / true (default false).
_sf_role_on() {
  local v
  v="$(cfg "$1" | tr '[:upper:]' '[:lower:]')"
  if [ "$(_talos_default "$1")" = "true" ]; then [ "$v" != "false" ]; else [ "$v" = "true" ]; fi
}

BASE_BRANCH="$(cfg base_branch 2>/dev/null)"
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
fi
[ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"

roles="" auto="true" checks="no" draft="false" talos_labels=""
# Names only (entries are name|color|description), comma-joined; no name has a comma.
for e in ${TALOS_STAGE_LABELS[@]+"${TALOS_STAGE_LABELS[@]}"} ${TALOS_APPROVAL_LABELS[@]+"${TALOS_APPROVAL_LABELS[@]}"}; do
  talos_labels="${talos_labels}${e%%|*},"
done
if [ -z "$talos_labels" ]; then
  _sf_err "pipeline-contract.sh is missing or lists no labels; reinstall Talos"
  exit 1
fi
_sf_role_on roles.qa && roles="${roles}qa,"
_sf_role_on roles.docs && roles="${roles}docs,"
_sf_role_on roles.reviewer && roles="${roles}reviewer,"
_sf_role_on roles.security && roles="${roles}security,"
_sf_role_on roles.adversarial && roles="${roles}adversarial,"
[ "$(cfg merge.auto | tr '[:upper:]' '[:lower:]')" = "false" ] && auto="false"
[ -n "$(cfg merge.required_checks | tr -d '[:space:]')" ] && checks="yes"
# The same effective value Step 0 uses (#435): default true, false on github-api/file.
[ "$(bash "$SCRIPT_DIR/pipeline-draft-check.sh" resolve 2>/dev/null)" = "true" ] && draft="true"

# A signal that reaches only this bash waits for the read phase to finish (bash
# runs its trap after the foreground command), bounded by the read deadline; one
# that reaches python3 stops the running read verb first (pipeline-next.py's handler).
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

# The operator (#560): with claiming on, collect keeps to the operator's issues.
# Empty when issues.claim is false, issues.assignee is none or no identity
# resolves, and collect then reads no assignee at all.
me=""
talos_claim_resolve
case "${TALOS_CLAIM_STATE:-}" in on:?*) me="${TALOS_CLAIM_STATE#on:}" ;; esac

python3 -I "$SCRIPT_DIR/pipeline-next.py" collect \
  --vcs "$SCRIPT_DIR/pipeline-vcs.sh" --roles "$roles" --me "$me" \
  --merge-auto "$auto" --required-checks "$checks" --pr-draft "$draft" \
  --talos-labels "$talos_labels" --base-branch "$BASE_BRANCH" </dev/null
