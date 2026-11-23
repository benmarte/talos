"""pipeline-next.py -- what happens next, computed in one place (#557).

Stdlib only; always run as `python3 -I pipeline-next.py <mode> ...` (-I keeps the
caller's cwd and environment off sys.path). The callers are thin wrappers:

    collect     pipeline-status-file.sh collect: the run state as one JSON object
                (open pipeline PRs with their stage, the issue queue, blocked,
                owners, in-flight, the priority of the queued and in-flight
                issues, and the claim filter of #560). Options as
                `--name value` pairs: vcs roles me merge-auto required-checks
                pr-draft ready-gate fix-on-first-findings required-when
                talos-labels base-branch. `fix-on-first-findings` is `true`
                (roles.fix_on_first_findings, #833: on a ready PR qa is routed
                after the review roles too) or empty. `ready-gate` is
                `qa-local` (pr.ready_gate, #535: on a draft PR qa is routed last,
                after every other enabled approval) or empty/off. `required-when`
                is `yes` when roles.required_when is set (#835): each PR's review
                roles are then narrowed by `pipeline-vcs.sh required-roles`, the
                one resolver; no key (`no`), no call. `issue` (#1038) scopes the
                per-PR reads to that issue's PRs and adds `"scope": <N>`. A PR's
                head and draft state come from its list-prs item (`headRefOid`,
                `isDraft`) when it has them, else from pr-head and pr-is-draft.
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
NEEDS_OWNER_LABEL = 'pipeline:needs-owner'
# The issues a `talos.sh run` pass drives past `ready`: the label state
# machine's mid-flight stages (their next stage comes from the issue-side routing).
# A decomposed epic parent is an index no stage is dispatched onto (#524).
INFLIGHT_LABELS = frozenset((CONFIRMED_LABEL, DEV_LABEL))
BRANCH_RE = re.compile(r'^(?:fix|feat)/issue-([0-9]{1,9})(?:-|\Z)')
SHA_RE = re.compile(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})\Z')
CAP_RE = re.compile(r'result capped at')
STALE_RE = re.compile(r'^stale role=([a-z]+) label=')
EVIDENCE_LOST_RE = re.compile(r'^evidence role=([a-z]+) label=\S+ state=lost$')
UNSUPPORTED_RE = re.compile(r'not implemented for provider|unknown verb')
# The line that marks a spec the design-mode security pass has been through (#837).
# A member of a batch (#834): one line naming its lead, the number not followed by a digit.
BATCHED_RE = re.compile(r'^[ \t]*Batched into:[ \t]*#([0-9]+)(?![0-9])', re.M)
THREAT_MODEL_RE = re.compile(r'^[ \t]*## Threat model[ \t]*$', re.M)
APPROVALS = (('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'),
             ('security', 'security:approved'), ('adversarial', 'adversarial:approved'))
# The roles roles.required_when may skip (#835): qa and docs never are.
REVIEW_ROLES = frozenset(('reviewer', 'security', 'adversarial'))
REQUIRED_ROLES_RE = re.compile(r'^required-roles head=(\S+) roles=(\S+) skipped=(\S+) reason=[a-z-]+ matched=.* matched_count=[0-9]+\Z')
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


def die(msg, detail=''):
    """Fail the collect. `detail` (#1038) is `<read>:<cause>`: which read failed
    and why (`deadline`, `auth`, `failed` or `invalid`). It goes to the file
    named by TALOS_STATE_DETAIL_FILE, which talos.sh reads to say it on the stop
    line; the stderr line is the same as ever."""
    sys.stderr.write('pipeline-status-file: %s\n' % msg)
    path = os.environ.get('TALOS_STATE_DETAIL_FILE', '')
    if detail and path:
        try:
            with open(path, 'w') as f:
                f.write(detail)
        except OSError:
            pass
    sys.exit(1)


AUTH_RE = re.compile(r'\bHTTP 40[13]\b|Bad credentials|gh auth login|az login', re.I)


def read_failed(verb, err, msg):
    """A read verb exited non-zero: `auth` when its stderr says the credentials
    were refused, else `failed`. (A rate limit never gets here: it is a wait.)"""
    die(msg, '%s:%s' % (verb, 'auth' if AUTH_RE.search(err) else 'failed'))


RATE_LIMITED = 7  # pipeline-vcs.sh: the provider's rate limit is on (#1004)
RATE_LIMITED_RE = re.compile(r'^rate-limited reset=([0-9]{1,12})$', re.M)


def rate_limit_reset(err):
    """The epoch of the `rate-limited reset=<epoch>` line a verb printed, else 0."""
    m = RATE_LIMITED_RE.search(err)
    return int(m.group(1)) if m else 0


def rate_limited(err):
    """A read verb met the rate limit: not a failed read, a wait. Pass the one
    `rate-limited reset=<epoch>` line on and leave with its exit code; talos.sh
    turns it into `wait reason=rate-limited retry_after_s=<s>`."""
    sys.stderr.write('rate-limited reset=%d\n' % rate_limit_reset(err))
    sys.exit(RATE_LIMITED)


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
listed_draft = {}  # PR number -> the `isDraft` boolean its list-prs item carried (#1038)
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
        die('the GitHub read phase passed its %ds deadline' % _read_deadline(), '%s:deadline' % args[0])
    try:
        p = subprocess.Popen(['bash', opts['vcs']] + list(args), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        die('could not run the read verb %s' % args[0], '%s:failed' % args[0])
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
        die('the read verb %s timed out (read deadline %ds)' % (args[0], _read_deadline()), '%s:deadline' % args[0])
    finally:
        _running = None
    if p.returncode == RATE_LIMITED:
        rate_limited(err.decode('utf-8', 'replace'))
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def parse_array(text, what):
    try:
        d = json.loads(text)
    except ValueError:
        die('%s did not return JSON' % what, '%s:invalid' % what.split()[0])
    if not isinstance(d, list):
        die('%s did not return a JSON array' % what, '%s:invalid' % what.split()[0])
    return d


# ── the stage of a PR, and the action a stage maps to ────────────────────────

def required_enabled(n, head, enabled):
    """The enabled roles PR `n` needs under roles.required_when (#835): the one
    resolver is `pipeline-vcs.sh required-roles`. Only a review role the answer
    skips is dropped; a failed or unparsable answer, or one for another head,
    drops nothing (every enabled role is required)."""
    rc, out, _ = vcs('required-roles', str(n))
    lines = out.splitlines()
    m = REQUIRED_ROLES_RE.match(lines[0]) if rc == 0 and len(lines) == 1 else None
    if not m or m.group(1) != head:
        return enabled
    needed = set(m.group(2).split(','))
    skipped = set(m.group(3).split(','))
    return enabled - ((skipped - needed) & REVIEW_ROLES)


def next_stage(n, labels, issue_labels, enabled):
    """First match wins: blocked, then the draft or default order, counting only
    enabled roles; an approval label that is stale, or missing and not just
    lost (#521), means that role.
    A draft state the list-prs payload gave (`listed_draft`, #1038) is a boolean:
    no pr-is-draft read is made for it.
    Fails closed (die) on a failed check-approval-sha read."""
    if BLOCKED_LABEL in labels or BLOCKED_LABEL in issue_labels:
        return 'blocked'
    draft = False
    if opts.get('pr-draft') == 'true':
        if isinstance(listed_draft.get(n), bool):
            draft = listed_draft[n]
        else:
            rc, _, _ = vcs('pr-is-draft', str(n))
            if rc == 0:
                draft = True
            elif rc != 1:
                return 'unverified'
    stale = set()
    if any(label in labels for _, label in APPROVALS):
        rc, out, err = vcs('check-approval-sha', str(n), '--stale-list')
        stale = set(m.group(1) for m in map(STALE_RE.match, out.splitlines()) if m)
        # exit 1 is both "stale approvals" (stale lines on stdout) and a failed read.
        if rc not in (0, 1) or (rc == 1 and not stale):
            read_failed('check-approval-sha', err, 'check-approval-sha failed for PR #%d (rc=%d)' % (n, rc))
    # #521: a missing label whose marker still pins the current head is a lost
    # stamp, not unfinished work: the gate re-applies it (post-approval
    # --recover-only), so it is not this PR's stage. One evidence read for a
    # PR that misses an enabled role's label, whether or not it carries another
    # approval label: every stamp can be lost at once, and qa can be the only
    # approval role. A failed read dies.
    lost = set()
    if any(role in enabled and label not in labels for role, label in APPROVALS):
        rc, out, err = vcs('check-approval-sha', str(n), '--evidence-list')
        if rc != 0:
            read_failed('check-approval-sha', err, 'check-approval-sha --evidence-list failed for PR #%d (rc=%d)' % (n, rc))
        lost = set(m.group(1) for m in map(EVIDENCE_LOST_RE.match, out.splitlines()) if m)
    # #833: with roles.fix_on_first_findings qa is walked after the review roles
    # on a ready PR as it is on a draft one (below), so a review finding runs its
    # fix round before qa has spent a run.
    qa_last = opts.get('fix-on-first-findings') == 'true'
    for role, label in APPROVALS:
        if role == 'qa' and (draft or qa_last):
            continue
        if role in enabled and ((label not in labels and role not in lost) or role in stale):
            return role
    if draft:
        # The QA pre-CI gate (#535): QA is the LAST draft-window stage, so the one
        # CI run is never spent on a head QA would reject. Only here, after every
        # other enabled approval is fresh; a ready PR keeps QA first (above).
        # A lost qa:pass is not a reason to run QA again here either (#521).
        if opts.get('ready-gate') == 'qa-local' and 'qa' in enabled \
                and (('qa:pass' not in labels and 'qa' not in lost) or 'qa' in stale):
            return 'qa'
        return 'ready'
    if qa_last and 'qa' in enabled and (('qa:pass' not in labels and 'qa' not in lost) or 'qa' in stale):
        return 'qa'
    if opts.get('required-checks') == 'yes':
        rc, _, err = vcs('pr-checks-required', str(n))
        # Only pending or missing (exit 2) waits. A red check (exit 1 with the
        # `failed:` line) goes on to the merge gate, whose step 6 re-runs CI
        # (at most twice per head) and then posts ci-failed (#960). Any other
        # answer stays fail-closed on the ci wait.
        red = rc == 1 and 'pr-checks-required: failed:' in err
        if rc != 0 and not red:
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


def answered_owner_prs(data):
    """The numbers of the owner-flagged PRs whose parked question has its reply
    (#639): the owner entry of the PR says `answered` (an unverified reply
    does not count). Such a PR no longer waits for the owner."""
    owners = data.get('owners') or []
    ok = set(x.get('n') for x in owners if isinstance(x, dict) and x.get('status') == 'answered')
    return set(p['n'] for p in data.get('prs') or [] if p.get('owner') and p.get('n') in ok)


def answered_action(pr):
    """The action for an answered owner PR: the developer on the PR, which the
    run driver takes through `gate fix-round` (it continues from the reply)."""
    return action('dispatch', stage='developer', pr=pr['n'], issue=pr['issue'])


def pick_order(data, inflight, ready, overlapping=()):
    """The one order of the issue side (#601): priority, then in-flight before
    ready, then the issue number. The priority is the collect's `priority`
    object (0, 1 or 2); an issue it does not list, or lists with anything else,
    is unlabelled and comes last. Ready issues of one priority keep the order
    of `ready` (the collect's `queued`, already sorted by priority and number),
    so a state without the object still walks the queue as collected. The ready
    issues in `overlapping` (#830) follow the others of their priority."""
    prio = data.get('priority')
    prio = prio if isinstance(prio, dict) else {}
    flight = set(inflight)
    pos = dict((n, i) for i, n in enumerate(ready))

    def rank(n):
        p = prio.get(str(n))
        return p if isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 2 else 3

    return sorted(flight | set(ready),
                  key=lambda n: (rank(n), 0, 0, n) if n in flight else (rank(n), 1, n in overlapping, pos[n]))


# ── collect ──────────────────────────────────────────────────────────────────

def cache_titles(raw_issues):
    """Hand the titles `list-issues` already read to `pipeline-meta.sh cache-titles`
    (--meta, with --repo): the project map's title cache, filled with no provider
    call (#886). One process for all of them. Best effort: a failure or a timeout
    changes neither the collect's output nor its exit status."""
    meta = opts.get('meta', '')
    if not meta:
        return
    lines = ['%d %s\n' % (n, i['title']) for i in raw_issues
             for n in [_num(i)] if n and isinstance(i.get('title'), str) and not re.search(r'[\r\n]', i['title'])]
    if not lines:
        return
    try:
        subprocess.run(['bash', meta, '--repo', opts.get('repo', ''), 'cache-titles'], input=''.join(lines).encode('utf-8'),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, start_new_session=True)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass


def read_lists(talos_labels):
    """(raw PRs, raw issues, the verbs whose result was capped): the two list reads."""
    rc, out, err = vcs('list-prs')
    if rc != 0:
        read_failed('list-prs', err, 'list-prs failed (rc=%d)' % rc)
    raw_prs = parse_array(out, 'list-prs')
    capped = ['list-prs'] if CAP_RE.search(err) else []
    rc, out, err = vcs('list-issues')
    if rc != 0:
        read_failed('list-issues', err, 'list-issues failed (rc=%d)' % rc)
    raw_issues = parse_array(out, 'list-issues')
    if CAP_RE.search(err):
        capped.append('list-issues')
    return raw_prs, raw_issues, capped


class Claims:
    """Multi-user claiming (#560, #949): with `me` (the operator's login), act only
    on what is assigned to the operator. An issue is another operator's ("theirs")
    when it has assignees and the operator is not one of them; an issue with no
    assignee is nobody's: never routed and never claimed here (`talos.sh claim`
    is the explicit way), only listed in `shown` so it stays visible."""

    def __init__(self, me):
        self.me = me
        self.theirs = []         # the items of other operators: issues, then their PRs
        self.theirs_issues = {}  # issue -> the owner's login
        self.unassigned = set()
        self.shown = set()       # the unassigned issues Talos would otherwise act on

    def read_assignees(self):
        """The {issue: [logins]} map of one bulk read. Exit 2 is a provider with no
        assignees (file mode): there `me` is dropped, which keeps today's unfiltered
        state; any other failure fails the run, as a guess here would route another
        operator's work."""
        rc, out, err = vcs('list-assignees')
        if rc == 2:
            self.me = ''
            return None
        if rc != 0:
            read_failed('list-assignees', err, 'list-assignees failed (rc=%d)' % rc)
        try:
            raw_amap = json.loads(out)
        except ValueError:
            die('list-assignees did not return JSON', 'list-assignees:invalid')
        if not isinstance(raw_amap, dict):
            die('list-assignees did not return a JSON object', 'list-assignees:invalid')
        amap = {}
        for k, v in raw_amap.items():
            if re.fullmatch(r'[0-9]{1,9}', k) and isinstance(v, list):
                amap[int(k)] = [w for w in v if isinstance(w, str) and w]
        return amap

    def split(self, issues, amap, talos_labels):
        """`issues` without the theirs and the unassigned ones."""
        for n in sorted(issues):
            who = amap.get(n) or []
            if not who:
                self.unassigned.add(n)
            elif self.me.lower() not in [w.lower() for w in who]:
                self.theirs_issues[n] = min(who, key=lambda w: w.lower())
                self.theirs.append({'kind': 'issue', 'n': n, 'issue': n, 'owner': self.theirs_issues[n]})
        # Shown: the unassigned issues Talos would otherwise act on (a Talos label
        # or an open pipeline PR), not every open issue of the repo.
        self.shown = set(n for n in self.unassigned if issues[n] & talos_labels)
        return dict((n, l) for n, l in issues.items() if n not in self.theirs_issues and n not in self.unassigned)

    def keep_owners(self, owners):
        """The owner questions of the issues and PRs that are the operator's."""
        gone = set(self.theirs_issues) | self.unassigned | set(t['n'] for t in self.theirs if t['kind'] == 'PR')
        return owners if owners is None else [o for o in owners if o['n'] not in gone]


def read_owners():
    """The needs-owner entries, or None for an unsupported provider (exit 2: no Owner
    lines). Any other failure is a failed read and fails the run like list-prs does."""
    rc, out, err = vcs('list-needs-owner', '--json')
    if rc == 2:
        return None
    if rc != 0:
        read_failed('list-needs-owner', err, 'list-needs-owner failed (rc=%d)' % rc)
    owners = []
    # The trust set was not resolved: every `answered` value is unverified.
    unverified = 'talos:marker-authors-unverified' in err
    for r in parse_array(out, 'list-needs-owner --json'):
        if not _num(r, 'n') or not isinstance(r.get('question', ''), str):
            die('list-needs-owner --json returned an item that is not {n, question, ...}', 'list-needs-owner:invalid')
        # The status goes in a fixed field before the untrusted question.
        status = 'unverified' if unverified else ('answered' if r.get('answered') == 'yes' else 'unanswered')
        owners.append({'n': r['n'], 'status': status, 'question': r.get('question', '')})
    owners.sort(key=lambda o: o['n'])
    return owners


def classify_prs(raw_prs, talos_labels, claims, base):
    """(eligible (n, labels, issue) in PR order, the count of ignored PRs, the blocked
    PRs). Which PRs are the pipeline's: a pipeline-style head branch alone is not
    enough, anyone can open a PR named fix/issue-3-x from a fork. Same base, and
    either a Talos label (a maintainer applied it) or the listing says the PR
    is NOT from a fork. isCrossRepository absent means a label is required."""
    eligible, ignored, blocked = [], 0, []
    for it in sorted((i for i in raw_prs if _num(i)), key=lambda i: i['number']):
        n, labels = it['number'], _label_set(it)
        branch = it.get('headRefName')
        m = BRANCH_RE.match(branch) if isinstance(branch, str) else None
        pipeline_pr = bool(m) and it.get('baseRefName') == base \
            and bool(labels & talos_labels or it.get('isCrossRepository') is False)
        # A pipeline PR whose issue is another operator's is theirs: not routed,
        # not blocked-listed, not looked up (#560).
        if pipeline_pr and int(m.group(1)) in claims.theirs_issues:
            claims.theirs.append({'kind': 'PR', 'n': n, 'issue': int(m.group(1)),
                                  'owner': claims.theirs_issues[int(m.group(1))]})
            continue
        # ... and one whose issue nobody holds is not routed either (#949): not
        # blocked-listed, not looked up; its issue shows under `unassigned`.
        if pipeline_pr and int(m.group(1)) in claims.unassigned:
            claims.shown.add(int(m.group(1)))
            continue
        if BLOCKED_LABEL in labels:
            blocked.append(('PR', n))
        if not m or it.get('baseRefName') != base:
            continue
        if not (labels & talos_labels or it.get('isCrossRepository') is False):
            ignored += 1
            continue
        eligible.append((n, labels, int(m.group(1))))
    return eligible, ignored, blocked


def issue_lists(issues, eligible):
    """(queued, held, in flight) issue numbers."""
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
    return queued, held, inflight


def pr_lookups(eligible, issues, shown, enabled, by_diff):
    """The (n, labels, issue) PRs to look up: those the block shows, plus the
    merge-ready ones past the cap. `Next` must still see a merge-ready PR past
    the cap: any PR beyond it that carries the approval label of every enabled
    role (and no blocked or needs-owner label) is looked up as well, at most as
    many as the cap shows (with no role enabled every PR qualifies); only its
    line can be cut. With roles.required_when (#835) a review role may be
    skipped, so its label is no part of that test."""
    need = set(label for role, label in APPROVALS if role in enabled and not (by_diff and role in REVIEW_ROLES))
    pending = [e for e in eligible[shown:]
               if need <= e[1] and not ((e[1] | issues.get(e[2], set())) & {BLOCKED_LABEL, NEEDS_OWNER_LABEL})][:shown]
    return eligible[:shown] + pending


def scope_issue():
    """The issue `collect --issue <N>` is scoped to (#1038), else None."""
    v = opts.get('issue', '')
    return int(v) if re.fullmatch(r'[0-9]{1,9}', v) else None


def pr_head(n, listed):
    """The head sha of PR `n`: the one the list-prs payload carried (#1038), else
    one pr-head read. A listing sha that is not a sha is no answer: read it."""
    head = listed.get('headRefOid') if isinstance(listed.get('headRefOid'), str) else ''
    if SHA_RE.match(head):
        return head
    rc, out, err = vcs('pr-head', str(n))
    head = out.strip()
    if rc != 0 or not SHA_RE.match(head):
        read_failed('pr-head', err, 'pr-head failed for PR #%d' % n)
    return head


def read_prs(eligible, issues, ignored, capped, blocked, owners, queued, listing=None):
    """The state of each PR the block will show (lowest numbers): the line cap
    decides this BEFORE the per-PR reads, so 300 PRs cost the same as 40.
    The rest are counted by the `- +<K> more` line. Next sees rendered PRs only.
    With --issue <N> (#1038) only the PRs of issue N are looked up: the answer
    for N depends on N's own PR and on nothing the other PRs hold.
    `listing` is the list-prs items by number: their head and draft state stand
    in for the pr-head and pr-is-draft reads."""
    listing = listing or {}
    listed_draft.update((n, i['isDraft']) for n, i in listing.items() if isinstance(i.get('isDraft'), bool))
    budget = max(MAX_PR_LINES - (1 if ignored else 0) - (1 if capped else 0), MIN_BLOCK_LINES)
    others = len(blocked) + len(owners or []) + (1 if queued else 0)
    shown = len(eligible) if 2 + len(eligible) + others <= budget else budget - 3
    enabled = set(x for x in opts.get('roles', '').split(',') if x)
    # The per-PR reads are a second read phase with its own deadline.
    _start_read_phase()
    by_diff = opts.get('required-when') == 'yes'
    scope = scope_issue()
    lookups = [e for e in eligible if e[2] == scope] if scope is not None \
        else pr_lookups(eligible, issues, shown, enabled, by_diff)
    prs = []
    for n, labels, issue in lookups:
        listed = listing.get(n, {})
        head = pr_head(n, listed)
        issue_labels = issues.get(issue, set())
        pr_enabled = enabled
        if by_diff and enabled & REVIEW_ROLES and not ({BLOCKED_LABEL} & (labels | issue_labels)):
            pr_enabled = required_enabled(n, head, enabled)
        prs.append({'n': n, 'issue': issue, 'head': head,
                    'owner': NEEDS_OWNER_LABEL in labels or NEEDS_OWNER_LABEL in issue_labels,
                    'stage': next_stage(n, labels, issue_labels, pr_enabled)})
    return prs


def collect():
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _stop_on_signal)
    _start_read_phase()
    talos_labels = frozenset(x for x in opts.get('talos-labels', '').split(',') if x)
    if not talos_labels:
        die('no Talos label list (pipeline-contract.sh missing or empty)')
    raw_prs, raw_issues, capped = read_lists(talos_labels)
    issues = dict((_num(i), _label_set(i)) for i in raw_issues if _num(i))
    claims = Claims(opts.get('me', ''))
    if claims.me:
        amap = claims.read_assignees()
        if claims.me:
            issues = claims.split(issues, amap, talos_labels)
    owners = read_owners()
    eligible, ignored, blocked = classify_prs(raw_prs, talos_labels, claims, opts['base-branch'])
    if claims.me:
        owners = claims.keep_owners(owners)
    blocked += [('issue', n) for n in issues if BLOCKED_LABEL in issues[n]]
    blocked.sort(key=lambda b: (b[1], b[0]))
    queued, held, inflight = issue_lists(issues, eligible)
    prs = read_prs(eligible, issues, ignored, capped, blocked, owners, queued,
                   dict((_num(i), i) for i in raw_prs if _num(i)))
    # The priority of each queued or in-flight issue that carries a p-label
    # (#601): what `next` and `where` need to put both lists in one order.
    priority = dict((str(n), min(PRIORITY[l] for l in issues[n] if l in PRIORITY))
                    for n in queued + inflight if issues[n] & set(PRIORITY))
    state = {'prs': prs, 'pr_total': len(eligible), 'ignored': ignored,
             'blocked': blocked, 'queued': queued, 'held': held,
             'inflight': inflight, 'owners': owners, 'capped': capped,
             'priority': priority}
    if scope_issue() is not None:
        # Only the named issue's own PR was looked up: a reader that wants every
        # PR's stage must not take this state for the whole (#1038).
        state['scope'] = scope_issue()
    if claims.me:
        # Added only while claiming is on, so the unfiltered state is
        # byte-for-byte today's. `unassigned` (#949): open issues Talos would act
        # on that nobody is assigned to; they are not routed and not claimed.
        state['me'] = claims.me
        state['theirs'] = sorted(claims.theirs, key=lambda t: (t['n'], t['kind']))
        state['unassigned'] = sorted(claims.shown)
    cache_titles(raw_issues)
    sys.stdout.write(json.dumps(state))


# ── pr-side: the PR-side half of `next` ──────────────────────────────────────

def pr_side(data):
    """The lowest non-owner PR's action, else the sentinel `issue-side`. The
    PRs are already ordered by the collect; the state is trusted, no PR text is."""
    answered = answered_owner_prs(data)
    prs = sorted((p for p in data['prs'] if not p.get('owner') or p['n'] in answered), key=lambda p: p['n'])
    if prs:
        if prs[0]['n'] in answered:
            return answered_action(prs[0])
        return stage_action(prs[0]['stage'], prs[0]['n'], prs[0]['issue'])
    # No PR answered: the issue side decides (#471) -- owner waits, the queue
    # walk, the routing.
    return 'issue-side'


# ── expected files and overlap (#830) ────────────────────────────────────────
# Which issues touch the same files decides only the ORDER of the ready walk:
# an overlapping issue is demoted behind the others of its priority, never
# blocked.

FILES_HEADING_RE = re.compile(
    r'^\s*(?:#{1,6}|[*_]{2})\s*files\s+(?:touched|likely\s+to\s+change)[\s:*_]*$', re.I)
MAX_LINE = 2000  # a longer line is no heading or bullet of a files list
GENERATED_NAMES = frozenset(('querier.go', 'openapi.yaml', 'schema.ts'))
MIGRATION_DIRS = frozenset(('migrations', 'migrate'))


def _drop_note(t):
    """t without a trailing parenthesised note."""
    i = t.rfind('(')
    if t.endswith(')') and i >= 0 and ')' not in t[i + 1:-1]:
        return t[:i].rstrip()
    return t


def files_list(text):
    """The paths of the `Files touched` / `Files likely to change` list of a
    body or spec: the bullets under that heading or bold label, up to the first
    blank line (after the first bullet) or the next heading. A bullet is its
    first backticked span, else its text without a trailing parenthesised note."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if len(line) > MAX_LINE or not FILES_HEADING_RE.match(line):
            continue
        out = []
        for item in lines[i + 1:]:
            if not item.strip():
                if out:
                    break
                continue
            m = re.match(r'[-*+]\s+(.+)$', item.strip()) if len(item) <= MAX_LINE else None
            if not m:
                break
            t = _drop_note(m.group(1))
            b = re.search(r'`([^`]+)`', t)
            t = (b.group(1) if b else t).strip()
            if t.startswith('./'):
                t = t[2:]
            if t and ' ' not in t:
                out.append(t)
        if out:
            return out
    return []


def _is_generated(path):
    base = path.rsplit('/', 1)[-1]
    return base in GENERATED_NAMES or (base.startswith('generated') and base.endswith('.go'))


def _is_migration(path):
    return any(part in MIGRATION_DIRS for part in path.split('/')[:-1])


def comparable_files(paths):
    """The paths that can conflict: generated files dropped (they are
    regenerated on merge), every migration standing for one shared slot (two
    issues that each add one allocate the same number)."""
    return set('<migration>' if _is_migration(p) else p for p in paths if not _is_generated(p))


def issues_overlap(a, b):
    """a and b are (files list, area labels). Two lists overlap when they share a
    comparable path; when either has no list, when they share an `area:` label."""
    if a[0] and b[0]:
        return bool(comparable_files(a[0]) & comparable_files(b[0]))
    return bool(a[1] & b[1])


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
# The lease itself is bash's (acquired for the dispatch answer); the walk gets
# the issues other runs hold a lease of through --leased (comma-separated): its
# capacity check counts them, and an in-flight candidate among them is passed
# over (#601).

class Passed(Exception):
    """While the untargeted walk tries a candidate, a wait is not the answer yet:
    it raises Passed with the line, and the walk goes on (#601)."""


class Router:
    """The issue-side routing over one collect state. One method per decision
    stage: the owner gates (`owner_gate`, `ask_owner`), the fix-round gate, the
    per-issue stage (`route`), the named issue (`route_named`), and the walk of
    the in-flight and ready issues with its cap, overlap and dependency gates
    (`walk`). `say` and `say_line` print the one answer and exit; during the
    untargeted walk a wait raises Passed instead."""

    def __init__(self, data, o):
        self.data = data
        self.o = o
        self.prs = data.get('prs') or []
        self.queued = data.get('queued') or []
        self.qset = set(self.queued)
        self.held = set(data.get('held') or [])
        owners = data.get('owners') or []
        self.blocked = set(n for _, n in (data.get('blocked') or []))
        self.theirs = set(t['issue'] for t in (data.get('theirs') or []) if isinstance(t, dict) and isinstance(t.get('issue'), int))
        self.unassigned = set(n for n in (data.get('unassigned') or []) if isinstance(n, int) and not isinstance(n, bool))
        self.by_owner = dict((x['n'], x) for x in owners if isinstance(x, dict))
        self.answered = answered_owner_prs(data)
        roles = set(x for x in o.get('roles', '').split(',') if x)
        self.skip_labels = set(x for x in o.get('skip-labels', '').split(',') if x)
        self.label_filter = o.get('label-filter', READY_LABEL)
        self.leased = [x for x in o.get('leased', '').split(',') if x]
        self.pm_skip = o.get('pm-skip') == 'true'
        # pipeline.risk_areas (#837), one per line; an empty list switches the threat stage off.
        self.risk_areas = [a.strip().lower() for a in o.get('risk-areas', '').split('\n') if a.strip()]
        self.planner_on = 'planner' in roles
        self.validator_on = 'validator' in roles
        self.pm_on = 'pm' in roles
        self.walking = False
        self.docs = {}  # n -> the view-issue document, read once per walk
        # The walk's state: the pick, the cap and the waits a candidate answered.
        self.inflight = []
        self.flight = set()
        self.busy = set()
        self.ready = []
        self.overlapping = set()
        self.owner_wait = bool(self.blocked or owners or any(p.get('owner') for p in self.prs))
        self.cap = None
        self.dep_blocked = False
        self.batched_wait = False
        self.ready_wait = ''  # the wait a ready candidate's own routing answered: it ends the ready walk

    # ── answers and reads ────────────────────────────────────────────────────

    def say_line(self, line):
        if self.walking and line.startswith('action=wait'):
            raise Passed(line)
        print(line)
        sys.exit(0)

    def say(self, name, **kw):
        self.say_line(action(name, **kw))

    def run_vcs(self, *a):
        try:
            p = subprocess.run(['bash', self.o['vcs']] + list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError:
            raise Stop('state-unavailable')
        if p.returncode == RATE_LIMITED:
            # The answer is a wait: `stop reason=rate-limited reset=<epoch>`, which talos.sh
            # next turns into `action=wait reason=rate-limited retry_after_s=<s>` (#1004).
            raise Stop('rate-limited reset=%d' % rate_limit_reset(p.stderr.decode('utf-8', 'replace')))
        return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')

    def view_issue(self, n):
        if n not in self.docs:
            rc, out, err = self.run_vcs('view-issue', str(n))
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
            self.docs[n] = d
        body = self.docs[n].get('body')
        return _label_set(self.docs[n]), body if isinstance(body, str) else ''

    def expected_files(self, n):
        """(files list, area labels) of issue n (#830): the list of the body,
        else of the PM spec; None when the issue cannot be read (an ordering
        preference never fails the walk)."""
        try:
            labels, body = self.view_issue(n)
            files = files_list(body)
            if not files:
                rc, out, _ = self.run_vcs('view-issue', str(n), '--spec')
                if rc == 0:
                    for c in (json.loads(out).get('comments') or [])[-1:]:
                        files = files_list(c.get('body') or '')
        except (Stop, ValueError, AttributeError):
            return None
        return files, set(l for l in labels if l.startswith('area:'))

    # ── the owner ────────────────────────────────────────────────────────────

    def ask_owner(self, n):
        e = self.by_owner.get(n)
        q = e['question'] if e and isinstance(e.get('question'), str) else ''
        self.say('ask-owner', issue=n, question=q or 'the pipeline needs an owner decision on this issue')

    def owner_gate(self, n):
        """What an issue's owner state answers before any label does: another
        operator's issue (#560), one nobody holds (#949), a held or
        owner-questioned one, and its owner-flagged PR (#582, #639)."""
        if n in self.theirs:
            self.say('wait', reason='theirs')
        # An issue nobody is assigned to (#949) is never routed, nor claimed here.
        if n in self.unassigned:
            self.say('wait', reason='unassigned')
        if n in self.held or n in self.by_owner:
            self.ask_owner(n)
        # The issue's open pipeline PR is the PR side's, as in the unpinned
        # next: an owner-flagged one waits, the others are resumed at their
        # stage (#582). Only the PR of THIS issue is ever consulted.
        waiting = [p for p in self.prs if p.get('issue') == n and p.get('owner')]
        replied = [p for p in waiting if p['n'] in self.answered]
        if replied:
            self.say_line(answered_action(min(replied, key=lambda p: p['n'])))
        if waiting:
            self.say('wait', reason='owner')

    # ── the fix round and the threat stage ───────────────────────────────────

    def fix_round_gate(self, n):
        """The gate fix-round composition (#471, AC6), read-only: the budget guard
        (pipeline-budget.sh check; exit 1 = exceeded) then check-attempt (its
        ceilings), in the verb order."""
        if self.o.get('budget'):
            try:
                p = subprocess.run(['bash', self.o['budget'], 'check', '--issue', str(n)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            except OSError:
                p = None
            if p is not None and p.returncode == 1:
                raise Stop('budget-exceeded')
        rc, _, err = self.run_vcs('check-attempt', str(n))
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

    def needs_threat(self, n):
        """Does issue n still need its design-mode security pass (#837)? Its
        title, body or latest PM spec names a risk area and that spec has no
        `## Threat model` line yet. One `view-issue --spec` read, only with
        areas configured; an unreadable issue is never guessed."""
        if not self.risk_areas:
            return False
        rc, out, err = self.run_vcs('view-issue', str(n), '--spec')
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
        spec = ''
        for c in (d.get('comments') or [])[-1:]:
            b = c.get('body') if isinstance(c, dict) else None
            spec = b if isinstance(b, str) else ''
        if THREAT_MODEL_RE.search(spec):
            return False
        text = '\n'.join(x for x in (d.get('title'), d.get('body'), spec) if isinstance(x, str)).lower()
        return any(a in text for a in self.risk_areas)

    def developer_route(self, n):
        # A developer dispatch for an issue that already has an open PR is a fix
        # round: compose the gate outcome first, never dispatch past a ceiling.
        # Without a PR, a spec that touches a risk area goes through the threat
        # stage first (#837).
        if any(p.get('issue') == n for p in self.prs):
            self.fix_round_gate(n)
        elif self.needs_threat(n):
            self.say('dispatch', stage='threat', issue=n)
        self.say('dispatch', stage='developer', issue=n)

    # ── the stage of one issue ───────────────────────────────────────────────

    def route(self, n, labels, body):
        # One stage per action, first match wins (#471, AC3).
        if BLOCKED_LABEL in labels:
            self.say('wait', reason='blocked')
        if DEV_LABEL in labels:
            self.developer_route(n)
        if CONFIRMED_LABEL in labels:
            self.route_confirmed(n, labels, body)
        if READY_LABEL in labels and self.validator_on:
            self.say('dispatch', stage='validator', issue=n)
        self.say('wait', reason='none')

    def route_confirmed(self, n, labels, body):
        # Epic detection feeds routing (#471, AC4); the sub-issue creation
        # itself stays in the planner act/done path, never here.
        if self.planner_on and ('epic' in labels or len(re.findall(r'- \[ \]', body)) >= 4
                                or len(body) >= 2000):
            self.say('dispatch', stage='planner', issue=n)
        if self.pm_on:
            if self.pm_skip:
                rc, _, err = self.run_vcs('has-spec', str(n))
                if rc == 0:
                    self.developer_route(n)
                if UNSUPPORTED_RE.search(err):
                    raise Stop('unsupported-verb:has-spec')
                if rc != 1:
                    raise Stop('state-unavailable')
            self.say('dispatch', stage='pm', issue=n)
        self.developer_route(n)

    # ── the gates of a candidate ─────────────────────────────────────────────

    def is_open(self, num):
        """A `Depends on: #<N>` line whose issue is still open gates the candidate
        (#471, AC2); only with roles.planner = true. An unreadable dependency is
        treated as open (fail closed: the issue is not chosen on a failed read)."""
        rc, out, err = self.run_vcs('view-issue', num)
        if rc != 0:
            if UNSUPPORTED_RE.search(err):
                raise Stop('unsupported-verb:view-issue')
            return True
        try:
            return json.loads(out).get('state') != 'closed'
        except ValueError:
            return True

    def dep_gated(self, body):
        return any(self.is_open(d) for d in re.findall(r'Depends on:\s*#([0-9]+)', body))

    def batched(self, body):
        """A member of a batch (#834) rides its lead's branch and PR: while the lead
        is open (an unreadable lead counts as open) no stage is dispatched onto it."""
        m = BATCHED_RE.search(body)
        return bool(m) and self.is_open(m.group(1))

    def adopt(self, n):
        """Adoption (#471, AC9): a queued issue with an open pipeline PR is resumed
        at the PR blocking stage (the stage the collect already computed for it)."""
        mine = sorted((p for p in self.prs if p.get('issue') == n and not p.get('owner')), key=lambda p: p['n'])
        if mine:
            self.say_line(stage_action(mine[0]['stage'], mine[0]['n'], n))

    # ── the named issue ──────────────────────────────────────────────────────

    def route_named(self, n):
        """`next --issue <N>`, and each in-flight candidate of the untargeted walk."""
        self.owner_gate(n)
        if n in self.qset:
            self.adopt(n)
        labels, body = self.view_issue(n)
        if self.batched(body):
            self.say('wait', reason='batched')
        # The developer leaves its issue with no pipeline label once the PR is
        # open (agents/developer.md step 8): the PR owns the work. Only an
        # explicit developer label keeps the fix-round routing of route().
        if DEV_LABEL not in labels:
            self.adopt(n)
        # A not-queued issue is the collect word: still ready means the filter or
        # the cap skipped it (a wait); past ready (confirmed/dev) the labels
        # themselves are the routing (the #471 label-parity fixtures) - and a
        # queued issue routes by its own labels as today.
        if n not in self.qset and READY_LABEL in labels:
            self.say('wait', reason='none')
        self.route(n, labels, body)

    # ── the walk ─────────────────────────────────────────────────────────────

    def pick(self):
        """The candidates: the in-flight issues, and the ready ones that are
        neither held, blocked nor in flight. Held issues answer first."""
        if self.held:
            self.ask_owner(min(self.held))
        self.inflight = [n for n in self.data.get('inflight') or [] if isinstance(n, int) and not isinstance(n, bool)]
        self.flight = set(self.inflight)
        self.busy = set(int(x) for x in self.leased if x.isdigit())
        self.ready = [n for n in self.queued if n not in self.held and n not in self.blocked and n not in self.flight]

    def demote_overlapping(self):
        """The ready issues whose expected files overlap an issue in flight (held or
        leased) go behind the others of their priority (#830). Nothing is read
        unless something is in flight and there is a choice to order."""
        busy_now = self.flight | self.busy
        if busy_now and len(self.ready) > 1:
            theirs_files = [e for e in (self.expected_files(m) for m in sorted(busy_now)) if e]
            for n in self.ready:
                mine = self.expected_files(n)
                if mine and any(issues_overlap(mine, t) for t in theirs_files):
                    self.overlapping.add(n)

    def capacity(self):
        """The cap: max-parallel less the leases other runs hold; read once."""
        if self.cap is None:
            try:
                self.cap = int(self.o.get('max-parallel') or '1') - len(self.leased)
            except ValueError:
                raise Stop('state-unavailable')
        return self.cap

    def route_ready(self, n):
        """A ready candidate keeps every filter: the skip labels, the label
        filter collapse, the batch and the dependency gate."""
        labels, body = self.view_issue(n)
        if labels & self.skip_labels:
            return
        if self.label_filter != READY_LABEL and self.label_filter not in labels:
            return
        if self.batched(body):
            self.batched_wait = True
            return
        if self.planner_on and self.dep_gated(body):
            self.dep_blocked = True
            return
        self.route(n, labels, body)

    def visit(self, n):
        """An in-flight candidate is routed as `next --issue` routes it and none of
        the ready-queue filters apply to it; one that answers a wait, or that
        another run holds the lease of (the wait its dispatch would get), is
        passed over. A ready candidate is skipped once an owner wait or a ready
        wait stands, or the cap is spent."""
        try:
            if n in self.flight:
                if n in self.busy:
                    return
                self.route_named(n)  # answers and exits, or raises Passed
            if self.owner_wait or self.ready_wait:
                return
            if self.capacity() <= 0:
                return
            self.route_ready(n)
        except Passed as e:
            if n not in self.flight:
                self.ready_wait = e.args[0]

    def walk(self):
        """The pick (#471, AC1; #601): the in-flight and the ready issues in one order
        (pick_order). With no candidate left the wait is the one the ready queue
        alone gives (`finish`)."""
        self.demote_overlapping()
        self.walking = True
        for n in pick_order(self.data, self.inflight, self.ready, self.overlapping):
            self.visit(n)
        self.walking = False

    def finish(self):
        if self.owner_wait:
            self.say('wait', reason='owner')
        if not self.ready:
            self.say('wait', reason='none')
        if self.cap is not None and self.cap <= 0:
            self.say('wait', reason='cap')
        if self.ready_wait:
            self.say_line(self.ready_wait)
        if self.batched_wait:
            self.say('wait', reason='batched')
        if self.dep_blocked:
            self.say('wait', reason='dependency')
        self.say('wait', reason='none')

    def run(self):
        target = self.o.get('issue', '')
        if target:
            try:
                n = int(target)
            except ValueError:
                raise Stop('usage')
            self.route_named(n)
        self.pick()
        self.walk()
        self.finish()


def issue_side(data, o):
    """Options o (--name value): vcs budget issue roles label-filter skip-labels
    max-parallel pm-skip risk-areas leased. Read verbs only, unbounded (no deadline)."""
    Router(data, o).run()


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
    # The issue untargeted `next` works first (#601): one order over both lists.
    order = pick_order(data, inflight, [num(n) for n in data.get('queued') or [] if n not in held])
    first = next((p for p in prs if not p.get('owner')), None)
    word = lambda s: s if re.fullmatch(r'[a-z-]{1,20}', s) else '?'
    if act.startswith('action=dispatch') and first:
        nxt = 'dispatch %s on PR #%d (#%d)' % (word(a.get('stage', '')), num(first.get('n')), num(first.get('issue')))
    elif act.startswith('action=merge') and first:
        nxt = 'merge PR #%d (#%d)' % (num(first.get('n')), num(first.get('issue')))
    elif act.startswith('action=wait') and first:
        nxt = 'wait (%s) on PR #%d (#%d)' % (word(a.get('reason', '')), num(first.get('n')), num(first.get('issue')))
    elif order:
        nxt = ('continue issue #%d' if order[0] in inflight else 'start issue #%d') % order[0]
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
    # Issues nobody is assigned to (#949): not routed, kept visible on their own line.
    free = sorted(set(num(n) for n in data.get('unassigned') or [] if num(n)))
    if free:
        print('unassigned: ' + ', '.join(some(free, '#%d', 5)))


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
