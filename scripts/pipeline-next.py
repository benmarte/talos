"""pipeline-next.py -- what happens next, computed in one place (#557).

Stdlib only; always run as `python3 -I pipeline-next.py <mode> ...` (-I keeps the
caller's cwd and environment off sys.path). The callers are thin wrappers:

    collect     pipeline-status-file.sh collect: the run state as one JSON object
                (open pipeline PRs with their stage, the issue queue, blocked,
                owners, in-flight, and the claim filter of #560). Options as
                `--name value` pairs: vcs roles me merge-auto required-checks
                pr-draft talos-labels base-branch.
    pr-side     talos.sh next: the PR-side answer from a state file: an
                `action=...` line, or the sentinel `issue-side` when no PR answers.
    issue-side  talos.sh next: the issue-side answer (queue walk, routing,
                adoption of a queued issue's PR) from a state file plus options.
    where       talos.sh state --summary: the three `where` lines.

Reads go through the pipeline-vcs.sh path in opts['vcs'] (read verbs only, one
verb per call, never a write). The stage of a PR (next_stage) and the action a
stage maps to (stage_action) each exist once; collect, pr-side and adoption all
use them.

Exit status: 0 an answer; 1 a `stop reason=<enum>` line on stdout (issue-side,
pr-side) or a `pipeline-status-file: <why>` line on stderr (collect).
"""

import json
import os
import re
import signal
import subprocess
import sys
import time

BLOCKED_LABEL = 'pipeline:blocked'
READY_LABEL = 'pipeline:ready'
DEV_LABEL = 'pipeline:dev'
CONFIRMED_LABEL = 'pipeline:confirmed'
EPIC_DECOMPOSED_LABEL = 'pipeline:epic-decomposed'
NEEDS_OWNER_LABEL = 'pipeline:needs-owner'
# The issues a `talos.sh run` pass drives past `ready`: the label state
# machine's mid-flight stages (their next stage comes from the issue-side routing).
INFLIGHT_LABELS = frozenset((CONFIRMED_LABEL, DEV_LABEL, EPIC_DECOMPOSED_LABEL))
BRANCH_RE = re.compile(r'^(?:fix|feat)/issue-([0-9]{1,9})(?:-|\Z)')
SHA_RE = re.compile(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})\Z')
CAP_RE = re.compile(r'result capped at')
STALE_RE = re.compile(r'^stale role=([a-z]+) label=')
UNSUPPORTED_RE = re.compile(r'not implemented for provider|unknown verb')
APPROVALS = (('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'),
             ('security', 'security:approved'), ('adversarial', 'adversarial:approved'))
ROLE_STAGES = tuple(role for role, _ in APPROVALS)
PRIORITY = {'p0': 0, 'p1': 1, 'p2': 2}
MAX_PR_LINES = 40    # bounds the per-PR reads: only the lowest-numbered PRs are looked up
MIN_BLOCK_LINES = 3  # ... and never fewer than this
READ_DEADLINE = 120  # seconds for one read phase; CALL_TIMEOUT for one verb
CALL_TIMEOUT = 180


class Stop(Exception):
    """A `stop reason=<enum>` answer."""


def opts_from(args):
    return dict((args[i][2:], args[i + 1]) for i in range(0, len(args) - 1, 2))


def die(msg):
    sys.stderr.write('pipeline-status-file: %s\n' % msg)
    sys.exit(1)


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


# ── bounded read verbs (collect, next_stage) ─────────────────────────────────

opts = {}
_deadline = None
_running = None  # the read verb's Popen, so a signal can stop it


def _read_deadline():
    """Seconds one read phase may take (TALOS_STATUS_READ_DEADLINE, for tests)."""
    v = os.environ.get('TALOS_STATUS_READ_DEADLINE', '')
    # ASCII digits only, at most 4: str.isdigit() accepts `²`, which int() rejects.
    return int(v) if re.fullmatch(r'[0-9]{1,4}', v) and 1 <= int(v) <= 3600 else READ_DEADLINE


def _start_read_phase():
    """Start a read phase's clock. collect's list reads and the per-PR reads are
    two phases, so one phase's deadline never uses up the other's."""
    global _deadline
    _deadline = time.monotonic() + _read_deadline()


def _stop_on_signal(signum, _frame):
    """INT, TERM or HUP during a read phase: kill the running verb's process
    group (it runs in its own session, so the terminal's signal never reaches it)
    and exit 128+signum, instead of leaving it to outlive this script."""
    p = _running
    if p is not None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
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


# ── the stage of a PR, and the action a stage maps to ────────────────────────

def next_stage(n, labels, issue_labels, enabled):
    """First match wins: blocked, then the draft or default order, counting only
    enabled roles; an approval label that is missing or stale means that role.
    Fails closed (die) on a failed check-approval-sha read."""
    if BLOCKED_LABEL in labels or BLOCKED_LABEL in issue_labels:
        return 'blocked'
    draft = False
    if opts.get('pr-draft') == 'true':
        rc, _, _ = vcs('pr-is-draft', str(n))
        if rc == 0:
            draft = True
        elif rc != 1:
            return 'unverified'
    stale = set()
    if any(label in labels for _, label in APPROVALS):
        rc, out, _ = vcs('check-approval-sha', str(n), '--stale-list')
        stale = set(m.group(1) for m in map(STALE_RE.match, out.splitlines()) if m)
        # exit 1 is both "stale approvals" (stale lines on stdout) and a failed read.
        if rc not in (0, 1) or (rc == 1 and not stale):
            die('check-approval-sha failed for PR #%d (rc=%d)' % (n, rc))
    for role, label in APPROVALS:
        if draft and role == 'qa':
            continue
        if role in enabled and (label not in labels or role in stale):
            return role
    if draft:
        return 'ready'
    if opts.get('required-checks') == 'yes':
        rc, _, _ = vcs('pr-checks-required', str(n))
        if rc != 0:
            return 'ci'
    return 'merge' if opts.get('merge-auto') == 'true' else 'human-merge'


def action(name, **kw):
    out = 'action=' + name
    for k in ('stage', 'reason', 'pr', 'issue', 'retry_after_s', 'question'):
        if k in kw:
            out += ' %s=%s' % (k, kw[k])
    return out


def stage_action(st, pr, issue):
    """The action for PR `pr` of `issue` at stage `st`; Stop on a stage this
    version does not know (never a guess)."""
    if st in ROLE_STAGES:
        return action('dispatch', stage=st, pr=pr, issue=issue)
    if st == 'merge':
        return action('merge', pr=pr, issue=issue)
    if st == 'ready':
        # The draft wait is key-carrying (#516): it names the PR and the issue
        # so the run loop can continue the Draft stage order from it.
        return action('wait', reason='draft', pr=pr, issue=issue)
    if st == 'ci':
        return action('wait', reason='ci')
    if st == 'human-merge':
        return action('wait', reason='human-merge')
    if st in ('blocked', 'unverified'):
        return action('wait', reason='blocked')
    raise Stop('unsupported-verb:' + st)


# ── collect ──────────────────────────────────────────────────────────────────

def collect():
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _stop_on_signal)
    _start_read_phase()
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

    # Multi-user claiming (#560): with --me (the operator's login), act only on
    # what is assigned to the operator or to nobody. The assignees come from one
    # bulk read; exit 2 is a provider with no assignees (file mode), which keeps
    # today's unfiltered state, and any other failure fails the run: a guess
    # here would route another operator's work. An issue is another operator's
    # ("theirs") when it has assignees and the operator is not one of them.
    me = opts.get('me', '')
    amap, theirs, theirs_issues = {}, [], {}
    if me:
        rc, out, err = vcs('list-assignees')
        if rc == 2:
            me = ''
        elif rc != 0:
            die('list-assignees failed (rc=%d)' % rc)
        else:
            try:
                raw_amap = json.loads(out)
            except ValueError:
                die('list-assignees did not return JSON')
            if not isinstance(raw_amap, dict):
                die('list-assignees did not return a JSON object')
            for k, v in raw_amap.items():
                if re.fullmatch(r'[0-9]{1,9}', k) and isinstance(v, list):
                    amap[int(k)] = [w for w in v if isinstance(w, str) and w]
    if me:
        for n in sorted(issues):
            who = amap.get(n) or []
            if who and me.lower() not in [w.lower() for w in who]:
                theirs_issues[n] = min(who, key=lambda w: w.lower())
                theirs.append({'kind': 'issue', 'n': n, 'issue': n, 'owner': theirs_issues[n]})
        issues = dict((n, l) for n, l in issues.items() if n not in theirs_issues)

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
        branch = it.get('headRefName')
        m = BRANCH_RE.match(branch) if isinstance(branch, str) else None
        pipeline_pr = bool(m) and it.get('baseRefName') == base \
            and bool(labels & talos_labels or it.get('isCrossRepository') is False)
        # A pipeline PR whose issue is another operator's is theirs: not routed,
        # not blocked-listed, not looked up (#560).
        if pipeline_pr and int(m.group(1)) in theirs_issues:
            theirs.append({'kind': 'PR', 'n': n, 'issue': int(m.group(1)),
                           'owner': theirs_issues[int(m.group(1))]})
            continue
        if BLOCKED_LABEL in labels:
            blocked.append(('PR', n))
        if not m or it.get('baseRefName') != base:
            continue
        if not (labels & talos_labels or it.get('isCrossRepository') is False):
            ignored += 1
            continue
        eligible.append((n, labels, int(m.group(1))))
    if me:
        gone = set(theirs_issues) | set(t['n'] for t in theirs if t['kind'] == 'PR')
        if owners is not None:
            owners = [o for o in owners if o['n'] not in gone]
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
    # developer-labelled issue and answers a developer fix round, re-dispatching an
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
    # The per-PR reads are a second read phase with its own deadline.
    _start_read_phase()
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
    state = {'prs': prs, 'pr_total': len(eligible), 'ignored': ignored,
             'blocked': blocked, 'queued': queued, 'held': held,
             'inflight': inflight, 'owners': owners, 'capped': capped}
    if me:
        # The items `talos.sh next` must claim before it dispatches: open
        # issues of the operator's queue, in flight or behind a PR that no one
        # has been assigned to (#560). Added only while claiming is on, so the
        # unfiltered state is byte-for-byte today's.
        pending = set(queued) | set(inflight) | set(e[2] for e in eligible)
        state['me'] = me
        state['theirs'] = sorted(theirs, key=lambda t: (t['n'], t['kind']))
        state['unclaimed'] = sorted(n for n in pending if n in issues and not amap.get(n))
    sys.stdout.write(json.dumps(state))


# ── pr-side: the PR-side half of `next` ──────────────────────────────────────

def pr_side(data):
    """The lowest non-owner PR's action, else the sentinel `issue-side`. The
    PRs are already ordered by the collect; the state is trusted, no PR text is."""
    prs = sorted((p for p in data['prs'] if not p.get('owner')), key=lambda p: p['n'])
    if prs:
        return stage_action(prs[0]['stage'], prs[0]['n'], prs[0]['issue'])
    # No PR answered: the issue side decides (#471) -- owner waits, the queue
    # walk, the routing.
    return 'issue-side'


# ── issue-side: the issue-side half of `next` (#471) ─────────────────────────
# Prints exactly one line:
#   action=dispatch stage=<role> issue=<N>          the issue's one stage
#   action=dispatch stage=<role> pr=<M> issue=<N>   adoption: a queued issue's
#                                                   open PR, resumed at its
#                                                   blocking stage
#   action=merge pr=<M> issue=<N>                   an adopted PR at merge
#   action=ask-owner issue=<N> question=<text>      a needs-owner queued issue
#   action=wait reason=<enum> [retry_after_s=<s>]   nothing to dispatch
#   stop reason=<enum>                              a ceiling or a missing
#                                                   provider verb (exit 1)
# The lease itself is bash's (acquired for the dispatch answer); the walk's
# capacity check gets the live-lease count through --in-flight.

def issue_side(data, o):
    """Options o (--name value): vcs budget issue roles label-filter skip-labels
    max-parallel pm-skip in-flight. Read verbs only, unbounded (no deadline)."""
    prs = data.get('prs') or []
    queued = data.get('queued') or []
    qset = set(queued)
    held = set(data.get('held') or [])
    owners = data.get('owners') or []
    blocked = set(n for _, n in (data.get('blocked') or []))
    theirs = set(t['issue'] for t in (data.get('theirs') or []) if isinstance(t, dict) and isinstance(t.get('issue'), int))
    by_owner = dict((x['n'], x) for x in owners if isinstance(x, dict))
    roles = set(x for x in o.get('roles', '').split(',') if x)
    skip_labels = set(x for x in o.get('skip-labels', '').split(',') if x)
    label_filter = o.get('label-filter', READY_LABEL)
    target = o.get('issue', '')
    pm_skip = o.get('pm-skip') == 'true'
    planner_on = 'planner' in roles
    validator_on = 'validator' in roles
    pm_on = 'pm' in roles

    def say(name, **kw):
        print(action(name, **kw))
        sys.exit(0)

    def run_vcs(*a):
        try:
            p = subprocess.run(['bash', o['vcs']] + list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError:
            raise Stop('state-unavailable')
        return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')

    def view_issue(n):
        rc, out, err = run_vcs('view-issue', str(n))
        if rc != 0:
            if UNSUPPORTED_RE.search(err):
                raise Stop('unsupported-verb:view-issue')
            raise Stop('state-unavailable')
        try:
            d = json.loads(out)
        except ValueError:
            raise Stop('state-unavailable')
        if not isinstance(d, dict):
            raise Stop('state-unavailable')
        body = d.get('body')
        return _label_set(d), body if isinstance(body, str) else ''

    def ask_owner(n):
        e = by_owner.get(n)
        q = e['question'] if e and isinstance(e.get('question'), str) else ''
        say('ask-owner', issue=n, question=q or 'the pipeline needs an owner decision on this issue')

    # The gate fix-round composition (#471, AC6), read-only: the budget guard
    # (pipeline-budget.sh check; exit 1 = exceeded) then check-attempt (its
    # ceilings), in the verb order.
    def fix_round_gate(n):
        if o.get('budget'):
            try:
                p = subprocess.run(['bash', o['budget'], 'check', '--issue', str(n)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            except OSError:
                p = None
            if p is not None and p.returncode == 1:
                raise Stop('budget-exceeded')
        rc, _, err = run_vcs('check-attempt', str(n))
        if rc == 0:
            return
        if UNSUPPORTED_RE.search(err):
            raise Stop('unsupported-verb:check-attempt')
        if rc != 1:
            raise Stop('state-unavailable')
        if 'max_total_dispatches' in err:
            raise Stop('max-total-dispatches')
        if 'max_fix_attempts' in err:
            raise Stop('max-fix-attempts')
        raise Stop('record-failed')

    def developer_route(n):
        # A developer dispatch for an issue that already has an open PR is a fix
        # round: compose the gate outcome first, never dispatch past a ceiling.
        if any(p.get('issue') == n for p in prs):
            fix_round_gate(n)
        say('dispatch', stage='developer', issue=n)

    def route(n, labels, body):
        # One stage per action, first match wins (#471, AC3).
        if BLOCKED_LABEL in labels:
            say('wait', reason='blocked')
        if EPIC_DECOMPOSED_LABEL in labels or DEV_LABEL in labels:
            developer_route(n)
        if CONFIRMED_LABEL in labels:
            # Epic detection feeds routing (#471, AC4); the sub-issue creation
            # itself stays in the planner act/done path, never here.
            if planner_on and ('epic' in labels or len(re.findall(r'- \[ \]', body)) >= 4
                               or len(body) >= 2000):
                say('dispatch', stage='planner', issue=n)
            if pm_on:
                if pm_skip:
                    rc, _, err = run_vcs('has-spec', str(n))
                    if rc == 0:
                        developer_route(n)
                    if UNSUPPORTED_RE.search(err):
                        raise Stop('unsupported-verb:has-spec')
                    if rc != 1:
                        raise Stop('state-unavailable')
                say('dispatch', stage='pm', issue=n)
            developer_route(n)
        if READY_LABEL in labels and validator_on:
            say('dispatch', stage='validator', issue=n)
        say('wait', reason='none')

    # A `Depends on: #<N>` line whose issue is still open gates the candidate
    # (#471, AC2); only with roles.planner = true. An unreadable dependency is
    # treated as open (fail closed: the issue is not chosen on a failed read).
    def dep_gated(body):
        for d in re.findall(r'Depends on:\s*#([0-9]+)', body):
            rc, out, err = run_vcs('view-issue', d)
            if rc != 0:
                if UNSUPPORTED_RE.search(err):
                    raise Stop('unsupported-verb:view-issue')
                return True
            try:
                st = json.loads(out).get('state')
            except ValueError:
                return True
            if st != 'closed':
                return True
        return False

    # Adoption (#471, AC9): a queued issue with an open pipeline PR is resumed
    # at the PR blocking stage (the stage the collect already computed for it).
    def adopt(n):
        mine = sorted((p for p in prs if p.get('issue') == n and not p.get('owner')), key=lambda p: p['n'])
        if mine:
            say_line(stage_action(mine[0]['stage'], mine[0]['n'], n))

    def say_line(line):
        print(line)
        sys.exit(0)

    if target:
        try:
            n = int(target)
        except ValueError:
            raise Stop('usage')
        # An issue of another operator (#560): never routed, whatever its labels say.
        if n in theirs:
            say('wait', reason='theirs')
        if n in held or n in by_owner:
            ask_owner(n)
        # The issue's open pipeline PR is the PR side's, as in the unpinned
        # next: an owner-flagged one waits, the others are resumed at their
        # stage (#582). Only the PR of THIS issue is ever consulted.
        if any(p.get('issue') == n and p.get('owner') for p in prs):
            say('wait', reason='owner')
        if n in queued:
            adopt(n)
        labels, body = view_issue(n)
        # The developer leaves its issue with no pipeline label once the PR is
        # open (agents/developer.md step 8): the PR owns the work. Only an
        # explicit developer label keeps the fix-round routing of route().
        if not (labels & {DEV_LABEL, EPIC_DECOMPOSED_LABEL}):
            adopt(n)
        # A not-queued issue is the collect word: still ready means the filter or
        # the cap skipped it (a wait); past ready (confirmed/dev/epic) the labels
        # themselves are the routing (the #471 label-parity fixtures) - and a
        # queued issue routes by its own labels as today.
        if n not in qset and READY_LABEL in labels:
            say('wait', reason='none')
        route(n, labels, body)

    # The queue pick (#471, AC1): the collect queued list is already sorted
    # (p0 < p1 < p2 < unlabeled, then ID ascending); label_filter collapse,
    # skip_labels, the dependency gate and the max_parallel cap are applied here.
    if held:
        ask_owner(min(held))
    if blocked or owners or any(p.get('owner') for p in prs):
        say('wait', reason='owner')
    cands = [n for n in queued if n not in held and n not in blocked]
    if not cands:
        say('wait', reason='none')
    try:
        cap = int(o.get('max-parallel') or '1') - int(o.get('in-flight') or '0')
    except ValueError:
        raise Stop('state-unavailable')
    if cap <= 0:
        say('wait', reason='cap')
    dep_blocked = False
    for n in cands:
        labels, body = view_issue(n)
        if labels & skip_labels:
            continue
        if label_filter != READY_LABEL and label_filter not in labels:
            continue
        if planner_on and dep_gated(body):
            dep_blocked = True
            continue
        route(n, labels, body)
    if dep_blocked:
        say('wait', reason='dependency')
    say('wait', reason='none')


# ── where: `state --summary` ─────────────────────────────────────────────────

def where(data):
    """Exactly three lines (in flight, waiting, next), plus `theirs` while
    claiming shows other operators' items. Only integers and fixed words are
    printed (a stage name is checked against [a-z-])."""
    try:
        act = pr_side(data).split('\n')[0]
    except Exception:
        act = 'unknown'

    def num(x):
        return x if isinstance(x, int) and not isinstance(x, bool) else 0

    def some(items, fmt, cap=4):
        out = [fmt % i for i in items[:cap]]
        return out + (['+%d more' % (len(items) - cap)] if len(items) > cap else [])

    prs = sorted((p for p in data.get('prs') or [] if isinstance(p, dict)), key=lambda p: num(p.get('n')))

    def stage(p):
        st = str(p.get('stage'))
        return st if re.fullmatch(r'[a-z-]{1,20}', st) else 'unknown'

    inflight = [num(n) for n in data.get('inflight') or []]
    pr_part = ', '.join(some([(num(p.get('n')), num(p.get('issue')), stage(p)) for p in prs], 'PR #%d (#%d) at %s'))
    issue_part = ('issue%s ' % ('s' if len(inflight) > 1 else '') + ', '.join(some(inflight, '#%d', 5))) if inflight else ''
    print('in flight: ' + ('; '.join(x for x in (pr_part, issue_part) if x) or 'nothing'))
    blocked = ['%s #%d' % ('PR' if k == 'PR' else 'issue', num(n)) for k, n in (data.get('blocked') or []) if isinstance(k, str)]
    held = [num(n) for n in data.get('held') or []]
    owners = sorted(set(held + [num(o.get('n')) for o in data.get('owners') or [] if isinstance(o, dict)]))
    waiting = (['blocked ' + ', '.join(some(blocked, '%s', 5))] if blocked else []) + (['owner ' + ', '.join(some(owners, '#%d', 5))] if owners else [])
    print('waiting: ' + ('; '.join(waiting) if waiting else 'nothing'))
    a = dict(w.split('=', 1) for w in act.split()[1:] if '=' in w)
    free = [n for n in data.get('queued') or [] if n not in held]
    first = next((p for p in prs if not p.get('owner')), None)
    word = lambda s: s if re.fullmatch(r'[a-z-]{1,20}', s) else '?'
    if act.startswith('action=dispatch') and first:
        nxt = 'dispatch %s on PR #%d (#%d)' % (word(a.get('stage', '')), num(first.get('n')), num(first.get('issue')))
    elif act.startswith('action=merge') and first:
        nxt = 'merge PR #%d (#%d)' % (num(first.get('n')), num(first.get('issue')))
    elif act.startswith('action=wait') and first:
        nxt = 'wait (%s) on PR #%d (#%d)' % (word(a.get('reason', '')), num(first.get('n')), num(first.get('issue')))
    elif free:
        nxt = 'start issue #%d' % num(free[0])
    elif inflight:
        nxt = 'continue issue #%d' % inflight[0]
    elif held or owners:
        nxt = 'waiting on the owner'
    else:
        nxt = 'nothing queued'
    print('next: ' + nxt)
    # Items of other operators (#560), only while claiming is on and there are any:
    # one entry per issue with the login of its owner (a PR counts as its issue).
    mine = {}
    for t in data.get('theirs') or []:
        if isinstance(t, dict) and num(t.get('issue')):
            o = t.get('owner')
            mine.setdefault(num(t.get('issue')), o if isinstance(o, str) and re.fullmatch(r'[A-Za-z0-9._@+\[\]-]{1,64}', o) else '?')
    if mine:
        print('theirs: ' + ', '.join(some(sorted(mine.items()), '#%d (@%s)', 5)))


# ── entry point ──────────────────────────────────────────────────────────────

def main(argv):
    global opts
    mode = argv[0] if argv else ''
    if mode == 'collect':
        opts = opts_from(argv[1:])
        collect()
        return 0
    if mode in ('pr-side', 'issue-side', 'where') and len(argv) >= 2:
        with open(argv[1]) as f:
            data = json.load(f)
        try:
            if mode == 'pr-side':
                print(pr_side(data))
            elif mode == 'issue-side':
                issue_side(data, opts_from(argv[2:]))
            else:
                where(data)
        except Stop as e:
            print('stop reason=' + str(e))
            return 1
        return 0
    sys.stderr.write('usage: pipeline-next.py collect|pr-side|issue-side|where ...\n')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
