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
#             stage comes from pipeline-next-stage.py, first match wins.
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

# pipeline-next-stage.py (#470): the stage of an open pipeline PR, the one
# implementation this script and `talos.sh next` share. Loaded by prepending its
# source to the python below (one process, -I: no cwd on sys.path). A missing
# module fails closed: no stage is ever guessed, the run stops.
if [ -r "$SCRIPT_DIR/pipeline-next-stage.py" ]; then
  IFS= read -r -d '' SF_NEXT_PY < "$SCRIPT_DIR/pipeline-next-stage.py" || true
else
  echo "talos: pipeline-next-stage.py missing; reinstall Talos" >&2
  exit 1
fi

IFS= read -r -d '' SF_PY <<'PYEOF' || true

import json, os, re, signal, subprocess, sys, time

opts = {}
_args = sys.argv[1:]
for _i in range(0, len(_args), 2):
    opts[_args[_i][2:]] = _args[_i + 1]


def die(msg):
    sys.stderr.write('pipeline-status-file: %s\n' % msg)
    sys.exit(1)


BLOCKED_LABEL = 'pipeline:blocked'
READY_LABEL = 'pipeline:ready'
DEV_LABEL = 'pipeline:dev'
CONFIRMED_LABEL = 'pipeline:confirmed'
EPIC_DECOMPOSED_LABEL = 'pipeline:epic-decomposed'
# The issues a `talos.sh run` pass drives past `ready`: the label state
# machine's mid-flight stages (their next stage comes from `next`'s routing).
INFLIGHT_LABELS = frozenset((CONFIRMED_LABEL, DEV_LABEL, EPIC_DECOMPOSED_LABEL))
BRANCH_RE = re.compile(r'^(?:fix|feat)/issue-([0-9]{1,9})(?:-|\Z)')
SHA_RE = re.compile(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})\Z')
CAP_RE = re.compile(r'result capped at')
APPROVALS = (('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'),
             ('security', 'security:approved'), ('adversarial', 'adversarial:approved'))
PRIORITY = {'p0': 0, 'p1': 1, 'p2': 2}
MAX_PR_LINES = 40    # bounds the per-PR reads: only the lowest-numbered PRs are looked up
MIN_BLOCK_LINES = 3  # ... and never fewer than this
READ_DEADLINE = 120  # seconds for the whole read phase; CALL_TIMEOUT for one verb
CALL_TIMEOUT = 180
NEEDS_OWNER_LABEL = 'pipeline:needs-owner'


def _num(item, key='number'):
    n = item.get(key) if isinstance(item, dict) else None
    return n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else None


def _label_set(item):
    out = set()
    for l in item.get('labels') or []:
        name = l.get('name') if isinstance(l, dict) else l
        if isinstance(name, str):
            out.add(name)
    return out


def _read_deadline():
    """Seconds the whole read phase may take (TALOS_STATUS_READ_DEADLINE, for tests)."""
    v = os.environ.get('TALOS_STATUS_READ_DEADLINE', '')
    # ASCII digits only, at most 4: str.isdigit() accepts `²`, which int() rejects.
    return int(v) if re.fullmatch(r'[0-9]{1,4}', v) and 1 <= int(v) <= 3600 else READ_DEADLINE


_deadline = time.monotonic() + _read_deadline()
_running = None  # the read verb's Popen, so a signal can stop it


def _stop_on_signal(signum, _frame):
    """INT, TERM or HUP during the read phase: kill the running verb's process
    group (it runs in its own session, so the terminal's signal never reaches it)
    and exit 128+signum, instead of leaving it to outlive this script. Covers
    this script's own reads and next_stage's (pipeline-next-stage.py)."""
    p = _running
    if p is not None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    ns_kill_running()
    sys.exit(128 + signum)


def vcs(*args):
    """Run one read verb in its own session. The overall deadline and the
    per-call timeout both END the run: a verb that timed out has no answer, and
    must never read as `ready` (pr-is-draft exit 1) or `ci` (exit 1)."""
    left = _deadline - time.monotonic()
    if left <= 0:
        die('the GitHub read phase passed its %ds deadline' % _read_deadline())
    try:
        p = subprocess.Popen(['bash', opts['vcs']] + list(args), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        die('could not run the read verb %s' % args[0])
    global _running
    _running = p
    try:
        out, err = p.communicate(timeout=min(CALL_TIMEOUT, left))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        die('the read verb %s timed out (read deadline %ds)' % (args[0], _read_deadline()))
    finally:
        _running = None
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def parse_array(text, what):
    try:
        d = json.loads(text)
    except ValueError:
        die('%s did not return JSON' % what)
    if not isinstance(d, list):
        die('%s did not return a JSON array' % what)
    return d


# The stage of an open pipeline PR lives in pipeline-next-stage.py (#470), the
# one implementation both this script and `talos.sh next` call. next_stage()
# keeps its own read deadline, signal handler and vcs runner (it reads
# pr-is-draft, check-approval-sha --stale-list and pr-checks-required), which
# is what next_stage_init() binds from this script's opts; collect() keeps its
# own deadline and handler for its own reads (list-prs, list-issues,
# list-needs-owner), so one phase's deadline never resets the other's.


def collect():
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _stop_on_signal)
    talos_labels = frozenset(x for x in opts.get('talos-labels', '').split(',') if x)
    if not talos_labels:
        die('no Talos label list (pipeline-contract.sh missing or empty)')
    rc, out, err = vcs('list-prs')
    if rc != 0:
        die('list-prs failed (rc=%d)' % rc)
    raw_prs = parse_array(out, 'list-prs')
    capped = ['list-prs'] if CAP_RE.search(err) else []
    rc, out, err = vcs('list-issues')
    if rc != 0:
        die('list-issues failed (rc=%d)' % rc)
    raw_issues = parse_array(out, 'list-issues')
    if CAP_RE.search(err):
        capped.append('list-issues')
    issues = dict((_num(i), _label_set(i)) for i in raw_issues if _num(i))

    # list-needs-owner: exit 2 is an unsupported provider (no Owner lines); any
    # other failure is a failed read and fails the run like list-prs does.
    owners = None
    rc, out, err = vcs('list-needs-owner', '--json')
    if rc != 2:
        if rc != 0:
            die('list-needs-owner failed (rc=%d)' % rc)
        owners = []
        # The trust set was not resolved: every `answered` value is unverified.
        unverified = 'talos:marker-authors-unverified' in err
        for r in parse_array(out, 'list-needs-owner --json'):
            if not _num(r, 'n') or not isinstance(r.get('question', ''), str):
                die('list-needs-owner --json returned an item that is not {n, question, ...}')
            # The status goes in a fixed field before the untrusted question.
            status = 'unverified' if unverified else ('answered' if r.get('answered') == 'yes' else 'unanswered')
            owners.append({'n': r['n'], 'status': status, 'question': r.get('question', '')})
        owners.sort(key=lambda o: o['n'])

    # Which PRs are the pipeline's: a pipeline-style head branch alone is not
    # enough, anyone can open a PR named fix/issue-3-x from a fork. Same base, and
    # either a Talos label (a maintainer applied it) or the listing says the PR
    # is NOT from a fork. isCrossRepository absent means a label is required.
    base = opts['base-branch']
    eligible, ignored, blocked = [], 0, []
    for it in sorted((i for i in raw_prs if _num(i)), key=lambda i: i['number']):
        n, labels = it['number'], _label_set(it)
        if BLOCKED_LABEL in labels:
            blocked.append(('PR', n))
        branch = it.get('headRefName')
        m = BRANCH_RE.match(branch) if isinstance(branch, str) else None
        if not m or it.get('baseRefName') != base:
            continue
        if not (labels & talos_labels or it.get('isCrossRepository') is False):
            ignored += 1
            continue
        eligible.append((n, labels, int(m.group(1))))
    blocked += [('issue', n) for n in issues if BLOCKED_LABEL in issues[n]]
    blocked.sort(key=lambda b: (b[1], b[0]))
    queued = sorted((n for n in issues if READY_LABEL in issues[n]),
                    key=lambda n: (min([PRIORITY[l] for l in issues[n] if l in PRIORITY] or [3]), n))
    # Ready AND waiting on the owner: listed as queued, never offered as `start`.
    held = [n for n in queued if NEEDS_OWNER_LABEL in issues[n]]
    # In-flight: mid-flight label states a `talos.sh run` pass resumes via
    # `next --issue <N>` (the issue-side routing, #471). Not in `queued`:
    # their next stage never comes from the ready filter. And never an issue
    # that already has an open pipeline PR (`pr_issues`, the same `eligible`
    # listing adoption consults): that work is implemented and the PR side
    # owns it -- a stale pipeline:dev beside an open PR would put every
    # drained run through `next --issue`, which skips adoption for a
    # not-queued issue and answers a developer fix round, re-dispatching an
    # implementer onto finished work until max_fix_attempts tripped the run
    # to exit 1 (#519 review, finding 1).
    pr_issues = set(issue for (_, _, issue) in eligible)
    inflight = sorted(n for n in issues
                      if n not in queued and n not in pr_issues
                      and not (issues[n] & {BLOCKED_LABEL, NEEDS_OWNER_LABEL})
                      and (issues[n] & INFLIGHT_LABELS))

    # Look up only the PRs the block will show (lowest numbers): the line cap
    # decides this BEFORE the per-PR reads, so 300 PRs cost the same as 40.
    # The rest are counted by the `- +<K> more` line. Next sees rendered PRs only.
    budget = max(MAX_PR_LINES - (1 if ignored else 0) - (1 if capped else 0), MIN_BLOCK_LINES)
    others = len(blocked) + len(owners or []) + (1 if queued else 0)
    shown = len(eligible) if 2 + len(eligible) + others <= budget else budget - 3
    enabled = set(x for x in opts.get('roles', '').split(',') if x)
    # next_stage() runs its own reads with its own deadline and signal handler
    # (pipeline-next-stage.py): bind them to this mode's opts once, before the
    # first call, so the handler of collect()'s own reads stays untouched.
    next_stage_init(opts)
    # `Next` must still see a merge-ready PR past the cap: any PR beyond it that
    # carries the approval label of every enabled role (and no blocked or
    # needs-owner label) is looked up as well, at most as many as the cap shows (with
    # no role enabled every PR qualifies); only its line can be cut.
    need = set(label for role, label in APPROVALS if role in enabled)
    pending = [e for e in eligible[shown:]
               if need <= e[1] and not ((e[1] | issues.get(e[2], set())) & {BLOCKED_LABEL, NEEDS_OWNER_LABEL})][:shown]
    prs = []
    for n, labels, issue in eligible[:shown] + pending:
        rc, out, _ = vcs('pr-head', str(n))
        head = out.strip()
        if rc != 0 or not SHA_RE.match(head):
            die('pr-head failed for PR #%d' % n)
        issue_labels = issues.get(issue, set())
        prs.append({'n': n, 'issue': issue, 'head': head,
                    'owner': NEEDS_OWNER_LABEL in labels or NEEDS_OWNER_LABEL in issue_labels,
                    'stage': next_stage(n, labels, issue_labels, enabled)})
    sys.stdout.write(json.dumps({'prs': prs, 'pr_total': len(eligible), 'ignored': ignored,
                                        'blocked': blocked, 'queued': queued, 'held': held,
                                        'inflight': inflight,
                                        'owners': owners, 'capped': capped}))

collect()
PYEOF

# One process runs the next-stage module and this program (the module first, so its
# own dispatch never triggers).
SF_PYS="$SF_NEXT_PY
$SF_PY"

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
# that reaches python3 stops the running read verb first (the handler above).
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

python3 -I -c "$SF_PYS" \
  --vcs "$SCRIPT_DIR/pipeline-vcs.sh" --roles "$roles" \
  --merge-auto "$auto" --required-checks "$checks" --pr-draft "$draft" \
  --talos-labels "$talos_labels" --base-branch "$BASE_BRANCH" </dev/null
