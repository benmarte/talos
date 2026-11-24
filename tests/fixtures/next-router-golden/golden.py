"""golden.py -- the transcript of pipeline-next.py and talos-map.py on fixed
fixtures (#1021). `python3 -I golden.py <root> next|map` prints it; the test
compares it with the transcript captured from main before the refactor
(next.golden, map.golden). Stdlib only; every fixture lives in a temp dir.

next: one block per case: `## <name>`, the exit code and stdout of the script,
then the provider verbs it called, in order. map: the page, the registry and
the index of several renders, then the --missing-titles answer."""

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = sys.argv[1]
MODE = sys.argv[2]
NEXT = os.path.join(ROOT, 'scripts', 'pipeline-next.py')
MAP = os.path.join(ROOT, 'scripts', 'talos-map.py')

STUB_VCS = r'''#!/usr/bin/env bash
FX="${STUB_DIR:?}"
verb="$1"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
a1="${1:-}"; a2="${2:-}"; a2="${a2#--}"
for k in "$verb.$a1.$a2" "$verb.$a1" "$verb"; do
  if [ -f "$FX/$k.json" ] || [ -f "$FX/$k.rc" ] || [ -f "$FX/$k.err" ]; then
    [ -f "$FX/$k.json" ] && cat "$FX/$k.json"
    [ -f "$FX/$k.err" ] && cat "$FX/$k.err" >&2
    if [ -f "$FX/$k.rc" ]; then exit "$(cat "$FX/$k.rc")"; fi
    exit 0
  fi
done
echo "pipeline-vcs: $verb: unknown verb" >&2
exit 1
'''
STUB_BUDGET = '#!/usr/bin/env bash\nexit "$(cat "${STUB_DIR:?}/budget.rc" 2>/dev/null || echo 0)"\n'
STUB_META = '#!/usr/bin/env bash\necho "$*" >> "${STUB_DIR:?}/meta.args"\ncat >> "${STUB_DIR:?}/meta.in"\n'


def write(path, text):
    with open(path, 'w') as f:
        f.write(text if isinstance(text, str) else json.dumps(text))


def iss(n, labels=(), state='open', body='', comments=None):
    return dict(number=n, title='issue %d' % n, labels=[dict(name=l) for l in labels],
                state=state, body=body, comments=comments or [])


def base_state(**kw):
    d = dict(prs=[], pr_total=0, ignored=0, blocked=[], queued=[], held=[], inflight=[], owners=[], capped=[])
    d.update(kw)
    return d


def stub_dir():
    d = tempfile.mkdtemp(prefix='golden-next.')
    assert os.path.isdir(d) and d
    write(os.path.join(d, 'vcs.sh'), STUB_VCS)
    write(os.path.join(d, 'budget.sh'), STUB_BUDGET)
    write(os.path.join(d, 'meta.sh'), STUB_META)
    return d


def block(name, d, argv):
    env = dict(os.environ, STUB_DIR=d)
    p = subprocess.run(['python3', '-I', NEXT] + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)
    out = ['## ' + name, 'rc=%d' % p.returncode]
    out += ['out: ' + l for l in p.stdout.decode().splitlines()]
    out += ['err: ' + l for l in p.stderr.decode().splitlines()]
    try:
        calls = open(os.path.join(d, 'calls.log')).read().splitlines()
    except OSError:
        calls = []
    out += ['call: ' + l for l in calls]
    for extra in ('meta.args', 'meta.in'):
        try:
            out += ['%s: %s' % (extra, l) for l in open(os.path.join(d, extra)).read().splitlines()]
        except OSError:
            pass
    shutil.rmtree(d)
    return '\n'.join(out)


def issue_case(name, state=None, issues=(), files=None, issue='', roles='validator', max_parallel='4', pm_skip='false',
               label_filter='pipeline:ready', skip_labels='', risk_areas='', leased='', budget=False, budget_rc=None):
    """One `issue-side` run. files: extra stub files (name -> text)."""
    d = stub_dir()
    write(os.path.join(d, 'state.json'), state or base_state())
    for i in issues:
        write(os.path.join(d, 'view-issue.%d.json' % i['number']), i)
    for k, v in (files or {}).items():
        write(os.path.join(d, k), v)
    if budget_rc is not None:
        write(os.path.join(d, 'budget.rc'), str(budget_rc))
    argv = ['issue-side', os.path.join(d, 'state.json'), '--vcs', os.path.join(d, 'vcs.sh'), '--issue', issue,
            '--roles', roles, '--label-filter', label_filter, '--skip-labels', skip_labels,
            '--max-parallel', max_parallel, '--pm-skip', pm_skip, '--risk-areas', risk_areas, '--leased', leased]
    if budget:
        argv += ['--budget', os.path.join(d, 'budget.sh')]
    return block(name, d, argv)


def files_body(*paths):
    return 'spec\n\n## Files touched\n' + ''.join('- `%s`\n' % p for p in paths)


def pr(n, issue, stage, owner=False):
    return dict(n=n, issue=issue, head='a' * 40, owner=owner, stage=stage)


def comment(text):
    return [dict(body=text)]


def next_cases():
    out = []
    add = out.append
    R, C, D = 'pipeline:ready', 'pipeline:confirmed', 'pipeline:dev'
    B = 'pipeline:blocked'
    S = base_state
    # ready queue
    add(issue_case('ready-queue-validator', S(queued=[3]), [iss(3, [R])]))
    add(issue_case('ready-queue-empty', S()))
    add(issue_case('ready-queue-priority-order', S(queued=[4, 3], inflight=[8], priority={'3': 0, '4': 1, '8': 2}),
                   [iss(3, [R]), iss(4, [R]), iss(8, [D])]))
    add(issue_case('ready-queue-p-order-no-inflight', S(queued=[4, 3, 5], priority={'3': 2, '4': 0}),
                   [iss(3, [R]), iss(4, [R]), iss(5, [R])]))
    add(issue_case('ready-no-validator-role', S(queued=[3]), [iss(3, [R])], roles=''))
    add(issue_case('skip-labels', S(queued=[3, 4]), [iss(3, [R, 'skip-me']), iss(4, [R])], skip_labels='skip-me'))
    add(issue_case('label-filter-collapse', S(queued=[3, 4]), [iss(3, [R]), iss(4, [R, 'only'])], label_filter='only'))
    # cap
    add(issue_case('cap-reached', S(queued=[3]), [iss(3, [R])], leased='9', max_parallel='1'))
    add(issue_case('cap-reached-default-one', S(queued=[3]), [iss(3, [R])], leased='9', max_parallel=''))
    add(issue_case('cap-room', S(queued=[3]), [iss(3, [R])], leased='9', max_parallel='2'))
    add(issue_case('cap-bad-number', S(queued=[3]), [iss(3, [R])], max_parallel='x'))
    # owner
    add(issue_case('owner-wait-blocked-issue', S(queued=[3], blocked=[['issue', 7]]), [iss(3, [R])]))
    add(issue_case('owner-wait-owner-entry', S(queued=[3], owners=[dict(n=9, status='unanswered', question='q')]), [iss(3, [R])]))
    add(issue_case('owner-wait-owner-pr', S(queued=[3], prs=[pr(20, 9, 'qa', True)]), [iss(3, [R])]))
    add(issue_case('held-ask-owner', S(queued=[3], held=[3], owners=[dict(n=3, status='unanswered', question='which db?')]),
                   [iss(3, [R])]))
    add(issue_case('held-ask-owner-no-question', S(queued=[3], held=[3]), [iss(3, [R])]))
    add(issue_case('named-ask-owner', S(owners=[dict(n=3, status='unanswered', question='which db?')]),
                   [iss(3, [C])], issue='3'))
    add(issue_case('named-held', S(queued=[3], held=[3]), [iss(3, [R])], issue='3'))
    add(issue_case('named-owner-pr-waits', S(prs=[pr(20, 3, 'qa', True)]), [iss(3, [C])], issue='3'))
    add(issue_case('named-owner-pr-answered', S(prs=[pr(20, 3, 'qa', True)], owners=[dict(n=20, status='answered', question='')]),
                   [iss(3, [C])], issue='3'))
    add(issue_case('named-owner-pr-unverified', S(prs=[pr(20, 3, 'qa', True)], owners=[dict(n=20, status='unverified', question='')]),
                   [iss(3, [C])], issue='3'))
    # named
    add(issue_case('named-theirs', S(theirs=[dict(kind='issue', n=3, issue=3, owner='bob')]), [iss(3, [C])], issue='3'))
    add(issue_case('named-unassigned', S(unassigned=[3]), [iss(3, [C])], issue='3'))
    add(issue_case('named-usage', S(), [], issue='abc'))
    add(issue_case('named-blocked-label', S(), [iss(3, [D, B])], issue='3'))
    add(issue_case('named-no-labels', S(), [iss(3, [])], issue='3'))
    add(issue_case('named-ready-not-queued', S(), [iss(3, [R])], issue='3'))
    add(issue_case('named-ready-queued', S(queued=[3]), [iss(3, [R])], issue='3'))
    add(issue_case('named-dev-no-pr', S(), [iss(3, [D])], issue='3'))
    add(issue_case('named-confirmed-no-pm', S(), [iss(3, [C])], issue='3'))
    add(issue_case('named-adopt-queued', S(queued=[3], prs=[pr(20, 3, 'reviewer')]), [iss(3, [R])], issue='3'))
    add(issue_case('named-adopt-merge', S(prs=[pr(20, 3, 'merge')]), [iss(3, [C])], issue='3'))
    add(issue_case('named-adopt-ready-draft', S(prs=[pr(20, 3, 'ready')]), [iss(3, [C])], issue='3'))
    add(issue_case('named-adopt-two-prs', S(prs=[pr(22, 3, 'qa'), pr(20, 3, 'docs')]), [iss(3, [C])], issue='3'))
    add(issue_case('named-adopt-unknown-stage', S(prs=[pr(20, 3, 'bogus')]), [iss(3, [C])], issue='3'))
    add(issue_case('named-dev-label-with-pr-skips-adopt', S(prs=[pr(20, 3, 'qa')]), [iss(3, [D])], issue='3',
                   files={'check-attempt.3.rc': '0'}))
    # fix round
    gate = (
        ('ok', {'check-attempt.3.rc': '0'}, {}),
        ('max-fix', {'check-attempt.3.rc': '1', 'check-attempt.3.err': 'max_fix_attempts reached'}, {}),
        ('max-total', {'check-attempt.3.rc': '1', 'check-attempt.3.err': 'max_total_dispatches reached'}, {}),
        ('record-failed', {'check-attempt.3.rc': '1', 'check-attempt.3.err': 'other'}, {}),
        ('rc2', {'check-attempt.3.rc': '2'}, {}),
        ('unsupported', {'check-attempt.3.rc': '1', 'check-attempt.3.err': 'not implemented for provider x'}, {}),
        ('budget-exceeded', {'check-attempt.3.rc': '0'}, dict(budget=True, budget_rc=1)),
        ('budget-ok', {'check-attempt.3.rc': '0'}, dict(budget=True, budget_rc=0)),
        ('budget-other-rc', {'check-attempt.3.rc': '0'}, dict(budget=True, budget_rc=3)))
    for tag, files, kw in gate:
        add(issue_case('fix-round-' + tag, S(inflight=[3], prs=[pr(20, 3, 'qa')]), [iss(3, [D])], issue='3', files=files, **kw))
    add(issue_case('fix-round-untargeted-walk', S(inflight=[3], prs=[pr(20, 3, 'qa')]), [iss(3, [D])],
                   files={'check-attempt.3.rc': '0'}))
    add(issue_case('fix-round-untargeted-walk-ceiling', S(inflight=[3], prs=[pr(20, 3, 'qa')]), [iss(3, [D])],
                   files={'check-attempt.3.rc': '1', 'check-attempt.3.err': 'max_fix_attempts'}))
    # pm / planner / spec
    add(issue_case('confirmed-pm', S(), [iss(3, [C])], issue='3', roles='pm'))
    add(issue_case('confirmed-pm-skip-spec', S(), [iss(3, [C])], issue='3', roles='pm', pm_skip='true', files={'has-spec.3.rc': '0'}))
    add(issue_case('confirmed-pm-skip-nospec', S(), [iss(3, [C])], issue='3', roles='pm', pm_skip='true', files={'has-spec.3.rc': '1'}))
    add(issue_case('confirmed-pm-skip-unsupported', S(), [iss(3, [C])], issue='3', roles='pm', pm_skip='true',
                   files={'has-spec.3.rc': '1', 'has-spec.3.err': 'unknown verb'}))
    add(issue_case('confirmed-pm-skip-rc2', S(), [iss(3, [C])], issue='3', roles='pm', pm_skip='true', files={'has-spec.3.rc': '2'}))
    add(issue_case('confirmed-planner-epic-label', S(), [iss(3, [C, 'epic'])], issue='3', roles='planner,pm'))
    add(issue_case('confirmed-planner-checkboxes', S(), [iss(3, [C], body='- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d')], issue='3', roles='planner,pm'))
    add(issue_case('confirmed-planner-long-body', S(), [iss(3, [C], body='x' * 2000)], issue='3', roles='planner,pm'))
    add(issue_case('confirmed-planner-small', S(), [iss(3, [C], body='small')], issue='3', roles='planner,pm'))
    # threat
    add(issue_case('threat-needed', S(), [iss(3, [D], body='touches auth code', comments=comment('spec'))], issue='3', risk_areas='auth\ncrypto'))
    add(issue_case('threat-done', S(), [iss(3, [D], body='touches auth code', comments=comment('spec\n## Threat model\nok'))], issue='3', risk_areas='auth'))
    add(issue_case('threat-no-area', S(), [iss(3, [D], body='plain', comments=comment('spec'))], issue='3', risk_areas='auth'))
    add(issue_case('threat-in-spec', S(), [iss(3, [D], body='plain', comments=comment('uses CRYPTO'))], issue='3', risk_areas='crypto'))
    add(issue_case('threat-with-pr-is-fix-round', S(prs=[pr(20, 3, 'qa')]), [iss(3, [D], body='auth')], issue='3', risk_areas='auth',
                   files={'check-attempt.3.rc': '0'}))
    add(issue_case('threat-unsupported', S(), [iss(3, [D], body='auth')], issue='3', risk_areas='auth',
                   files={'view-issue.3.spec.rc': '1', 'view-issue.3.spec.err': 'not implemented for provider x'}))
    add(issue_case('threat-spec-unreadable', S(), [iss(3, [D], body='auth')], issue='3', risk_areas='auth',
                   files={'view-issue.3.spec.rc': '1'}))
    add(issue_case('threat-spec-not-json', S(), [iss(3, [D], body='auth')], issue='3', risk_areas='auth',
                   files={'view-issue.3.spec.json': 'not json'}))
    add(issue_case('threat-spec-not-object', S(), [iss(3, [D], body='auth')], issue='3', risk_areas='auth',
                   files={'view-issue.3.spec.json': '[1]'}))
    # dependency / batch
    add(issue_case('dep-open', S(queued=[3]), [iss(3, [R], body='Depends on: #8'), iss(8, [C])], roles='validator,planner'))
    add(issue_case('dep-closed', S(queued=[3]), [iss(3, [R], body='Depends on: #8'), iss(8, [], 'closed')], roles='validator,planner'))
    add(issue_case('dep-unreadable-is-open', S(queued=[3]), [iss(3, [R], body='Depends on: #8')], roles='validator,planner',
                   files={'view-issue.8.rc': '1'}))
    add(issue_case('dep-unsupported', S(queued=[3]), [iss(3, [R], body='Depends on: #8')], roles='validator,planner',
                   files={'view-issue.8.rc': '1', 'view-issue.8.err': 'unknown verb'}))
    add(issue_case('dep-not-json-is-open', S(queued=[3]), [iss(3, [R], body='Depends on: #8')], roles='validator,planner',
                   files={'view-issue.8.json': 'nope'}))
    add(issue_case('dep-ignored-without-planner', S(queued=[3]), [iss(3, [R], body='Depends on: #8'), iss(8, [C])]))
    add(issue_case('dep-then-ready-second', S(queued=[3, 4]), [iss(3, [R], body='Depends on: #8'), iss(4, [R]), iss(8, [C])],
                   roles='validator,planner'))
    add(issue_case('batched-open-lead', S(queued=[6]), [iss(6, [R], body='x\nBatched into: #5\n'), iss(5, [C])]))
    add(issue_case('batched-closed-lead', S(queued=[6]), [iss(6, [R], body='Batched into: #5'), iss(5, [], 'closed')]))
    add(issue_case('batched-named', S(queued=[6]), [iss(6, [R], body='Batched into: #5'), iss(5, [C])], issue='6'))
    add(issue_case('batched-then-dep-both', S(queued=[6, 7]),
                   [iss(6, [R], body='Batched into: #5'), iss(7, [R], body='Depends on: #5'), iss(5, [C])], roles='validator,planner'))
    # walk past a wait
    add(issue_case('walk-blocked-candidate-ends-ready-walk', S(queued=[3, 4]), [iss(3, [R, B]), iss(4, [R])]))
    add(issue_case('walk-none-candidate', S(queued=[3, 4]), [iss(3, []), iss(4, [R])], roles=''))
    add(issue_case('walk-inflight-then-ready', S(queued=[4], inflight=[6]), [iss(6, [D]), iss(4, [R])],
                   files={'check-attempt.6.rc': '0'}))
    add(issue_case('walk-inflight-busy-skipped', S(queued=[4], inflight=[6]), [iss(6, [D]), iss(4, [R])], leased='6', max_parallel='4'))
    add(issue_case('walk-inflight-waits-passed', S(queued=[4], inflight=[6]), [iss(6, [D, B]), iss(4, [R])]))
    add(issue_case('walk-inflight-theirs', S(queued=[4], inflight=[6], theirs=[dict(kind='issue', n=6, issue=6, owner='bob')]),
                   [iss(6, [D]), iss(4, [R])]))
    add(issue_case('walk-inflight-confirmed-pm', S(inflight=[6]), [iss(6, [C])], roles='pm'))
    add(issue_case('walk-inflight-adopt-pr', S(inflight=[6], prs=[pr(21, 6, 'qa')]), [iss(6, [C])]))
    add(issue_case('walk-cap-with-inflight-first', S(queued=[4], inflight=[6]), [iss(6, [C]), iss(4, [R])], leased='9', roles='pm,validator'))
    add(issue_case('walk-owner-blocks-ready-not-inflight', S(queued=[4], inflight=[6], blocked=[['PR', 30]]), [iss(6, [D]), iss(4, [R])],
                   files={'check-attempt.6.rc': '0'}))
    # overlap ordering (#830)
    add(issue_case('overlap-demoted', S(queued=[2, 3], inflight=[1]),
                   [iss(1, [D], body=files_body('scripts/a.sh')), iss(2, [R], body=files_body('scripts/a.sh')), iss(3, [R], body=files_body('scripts/b.sh'))],
                   leased='1'))
    add(issue_case('overlap-leased-only', S(queued=[2, 3]),
                   [iss(1, [D], body=files_body('scripts/a.sh')), iss(2, [R], body=files_body('scripts/a.sh')), iss(3, [R], body=files_body('scripts/b.sh'))],
                   leased='1'))
    add(issue_case('overlap-from-spec-comment', S(queued=[2, 3], inflight=[1]),
                   [iss(1, [D], comments=comment(files_body('x/y'))), iss(2, [R], comments=comment(files_body('x/y'))), iss(3, [R], body=files_body('b'))],
                   leased='1'))
    add(issue_case('overlap-area-labels', S(queued=[2, 3], inflight=[1]),
                   [iss(1, [D, 'area:ui']), iss(2, [R, 'area:ui']), iss(3, [R, 'area:api'])], leased='1'))
    add(issue_case('overlap-unreadable-ignored', S(queued=[2, 3], inflight=[1]),
                   [iss(1, [D], body=files_body('a')), iss(3, [R], body=files_body('a'))], leased='1'))
    add(issue_case('overlap-migrations-share-a-slot', S(queued=[2, 3], inflight=[1]),
                   [iss(1, [D], body=files_body('db/migrations/001_a.sql')), iss(2, [R], body=files_body('db/migrations/002_b.sql')),
                    iss(3, [R], body=files_body('c'))], leased='1'))
    # read failures
    add(issue_case('view-issue-fails', S(queued=[3]), [], files={'view-issue.3.rc': '1'}))
    add(issue_case('view-issue-unsupported', S(queued=[3]), [], files={'view-issue.3.rc': '1', 'view-issue.3.err': 'unknown verb'}))
    add(issue_case('view-issue-not-json', S(queued=[3]), [], files={'view-issue.3.json': 'nope'}))
    add(issue_case('view-issue-not-object', S(queued=[3]), [], files={'view-issue.3.json': '[]'}))
    add(issue_case('view-issue-rate-limited', S(queued=[3]), [],
                   files={'view-issue.3.rc': '7', 'view-issue.3.err': 'rate-limited reset=1790000000'}))
    add(issue_case('view-issue-rate-limited-no-reset', S(queued=[3]), [], files={'view-issue.3.rc': '7'}))
    add(issue_case('named-view-issue-fails', S(), [], issue='3', files={'view-issue.3.rc': '1'}))
    return out


def where_cases():
    out = []
    S = base_state
    states = {
        'where-empty': S(),
        'where-busy': S(prs=[pr(20, 3, 'qa'), pr(21, 4, 'merge'), pr(22, 5, 'ci', True)], inflight=[6, 7], queued=[8, 9],
                        blocked=[['PR', 30], ['issue', 31]], held=[9], owners=[dict(n=5)],
                        theirs=[dict(kind='issue', n=40, issue=40, owner='bob')], unassigned=[41, 42], priority={'8': 0, '6': 1}),
        'where-wait-pr': S(prs=[pr(20, 3, 'ready')]),
        'where-queued-only': S(queued=[8, 9], inflight=[7], priority={'9': 0}),
        'where-owner-only': S(held=[9], queued=[9]),
        'where-many': S(prs=[pr(n, n + 100, 'qa') for n in range(1, 9)], inflight=list(range(50, 58))),
        'where-answered-owner-pr': S(prs=[pr(20, 3, 'qa', True)], owners=[dict(n=20, status='answered', question='')]),
    }
    for name, st in states.items():
        d = tempfile.mkdtemp(prefix='golden-where.')
        assert os.path.isdir(d) and d
        path = os.path.join(d, 'state.json')
        write(path, st)
        for mode, label in (('where', name), ('pr-side', 'pr-side ' + name)):
            p = subprocess.run(['python3', '-I', NEXT, mode, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            out.append('## %s\nrc=%d\n%s%s' % (label, p.returncode, p.stdout.decode(), p.stderr.decode()))
        shutil.rmtree(d)
    return out


LABELS = ('pipeline:ready,pipeline:confirmed,pipeline:dev,pipeline:blocked,pipeline:needs-owner,pipeline:review,'
          'qa:pass,review:approved,p0,p1,p2')


def collect_case(name, prs, issues, me='', roles='qa,reviewer', files=None, argv=()):
    d = stub_dir()
    write(os.path.join(d, 'list-prs.json'), prs)
    write(os.path.join(d, 'list-issues.json'), issues)
    write(os.path.join(d, 'list-needs-owner.rc'), '2')
    write(os.path.join(d, 'pr-head.json'), 'a' * 40 + '\n')
    write(os.path.join(d, 'pr-is-draft.rc'), '1')
    write(os.path.join(d, 'check-approval-sha.rc'), '0')
    write(os.path.join(d, 'pr-checks-required.rc'), '0')
    for k, v in (files or {}).items():
        write(os.path.join(d, k), v)
    a = ['collect', '--vcs', os.path.join(d, 'vcs.sh'), '--roles', roles, '--me', me, '--merge-auto', 'true',
         '--talos-labels', LABELS, '--branch-prefixes', 'fix,feat', '--base-branch', 'main'] + list(argv)
    a = [os.path.join(d, 'meta.sh') if x == '@meta' else x for x in a]
    return block(name, d, a)


def lbls(*names):
    return [dict(name=n) for n in names]


def prow(n, branch, labels=(), base='main', cross=None):
    r = dict(number=n, headRefName=branch, baseRefName=base, labels=lbls(*labels), title='pr %d' % n)
    if cross is not None:
        r['isCrossRepository'] = cross
    return r


def irow(n, labels=(), title=None):
    return dict(number=n, title=title if title is not None else 'issue %d' % n, labels=lbls(*labels))


def collect_cases():
    out = []
    add = out.append
    prs = [prow(10, 'fix/issue-3-x', ['qa:pass']), prow(11, 'feat/issue-4-y', ['pipeline:blocked']), prow(12, 'fix/issue-5-z'),
           prow(13, 'fix/issue-6-w', [], cross=False), prow(14, 'fix/issue-7-v', ['qa:pass'], base='dev'), prow(15, 'feature/other', ['qa:pass']),
           prow(16, 'fix/issue-8-u', ['qa:pass', 'review:approved'])]
    issues = [irow(3, ['pipeline:dev']), irow(4, ['pipeline:blocked']), irow(5), irow(6, ['pipeline:ready', 'p1']), irow(8, ['pipeline:ready', 'p0']),
              irow(9, ['pipeline:ready', 'pipeline:needs-owner']), irow(20, ['pipeline:confirmed', 'p2']), irow(21, ['pipeline:dev', 'pipeline:blocked']),
              irow(22, ['pipeline:confirmed', 'pipeline:needs-owner']), irow(23, ['pipeline:ready'])]
    add(collect_case('collect-basic', prs, issues, argv=['--meta', '@meta', '--repo', 'a/b']))
    add(collect_case('collect-basic-no-roles', prs, issues, roles=''))
    add(collect_case('collect-capped', prs, issues, files={'list-prs.err': 'result capped at 100', 'list-issues.err': 'result capped at 100'}))
    add(collect_case('collect-draft-gate-checks', prs, issues,
                     argv=['--pr-draft', 'true', '--ready-gate', 'qa-local', '--required-checks', 'yes', '--fix-on-first-findings', 'true']))
    add(collect_case('collect-draft-unverified', prs, issues, argv=['--pr-draft', 'true'], files={'pr-is-draft.rc': '3'}))
    add(collect_case('collect-ci-red', prs, issues, argv=['--required-checks', 'yes'],
                     files={'pr-checks-required.rc': '1', 'pr-checks-required.err': 'pr-checks-required: failed: x'}))
    add(collect_case('collect-ci-pending', prs, issues, argv=['--required-checks', 'yes'], files={'pr-checks-required.rc': '2'}))
    add(collect_case('collect-stale-approval', prs, issues,
                     files={'check-approval-sha.10.stale-list.rc': '1',
                            'check-approval-sha.10.stale-list.json': 'stale role=qa label=qa:pass\n',
                            'check-approval-sha.10.evidence-list.json': 'evidence role=reviewer label=review:approved state=lost\n'}))
    add(collect_case('collect-stale-read-fails', prs, issues, files={'check-approval-sha.10.stale-list.rc': '3'}))
    add(collect_case('collect-evidence-read-fails', prs, issues, files={'check-approval-sha.10.evidence-list.rc': '3'}))
    rr = 'required-roles head=%s roles=%s skipped=%s reason=docs matched=x matched_count=1\n'
    add(collect_case('collect-required-when', prs, issues, argv=['--required-when', 'yes'], roles='qa,reviewer,security',
                     files={'required-roles.10.json': rr % ('a' * 40, 'qa,reviewer', 'security')}))
    add(collect_case('collect-required-when-other-head', prs, issues, argv=['--required-when', 'yes'], roles='qa,reviewer,security',
                     files={'required-roles.10.json': rr % ('b' * 40, 'qa', 'reviewer,security')}))
    add(collect_case('collect-bad-pr-head', prs, issues, files={'pr-head.rc': '1'}))
    add(collect_case('collect-bad-pr-head-sha', prs, issues, files={'pr-head.json': 'nothex'}))
    add(collect_case('collect-list-prs-fails', prs, issues, files={'list-prs.rc': '1'}))
    add(collect_case('collect-list-prs-not-array', prs, issues, files={'list-prs.json': '{}'}))
    add(collect_case('collect-list-issues-fails', prs, issues, files={'list-issues.rc': '1'}))
    add(collect_case('collect-list-issues-not-json', prs, issues, files={'list-issues.json': 'x'}))
    # owners
    add(collect_case('collect-owners', prs, issues, files={'list-needs-owner.rc': '0', 'list-needs-owner.json': [
        dict(n=22, question='which?', answered='no'), dict(n=5, question='again', answered='yes')]}))
    add(collect_case('collect-owners-unverified', prs, issues,
                     files={'list-needs-owner.rc': '0', 'list-needs-owner.err': 'talos:marker-authors-unverified',
                            'list-needs-owner.json': [dict(n=5, question='again', answered='yes')]}))
    add(collect_case('collect-owners-bad-item', prs, issues, files={'list-needs-owner.rc': '0', 'list-needs-owner.json': [dict(q=1)]}))
    add(collect_case('collect-owners-fails', prs, issues, files={'list-needs-owner.rc': '1'}))
    # claiming
    amap = {'3': ['Me'], '4': ['bob'], '5': [], '6': ['bob', 'alice'], '8': ['me', 'bob'], '9': ['me'], '20': ['me'], '21': ['me'], '22': ['me']}
    add(collect_case('collect-me', prs, issues, me='me',
                     files={'list-assignees.json': amap, 'list-needs-owner.rc': '0',
                            'list-needs-owner.json': [dict(n=22, question='q', answered='no'), dict(n=6, question='x', answered='no')]}))
    add(collect_case('collect-me-file-mode', prs, issues, me='me', files={'list-assignees.rc': '2'}))
    add(collect_case('collect-me-fails', prs, issues, me='me', files={'list-assignees.rc': '1'}))
    add(collect_case('collect-me-not-json', prs, issues, me='me', files={'list-assignees.json': 'nope'}))
    add(collect_case('collect-me-not-object', prs, issues, me='me', files={'list-assignees.json': '[]'}))
    # the cap: many PRs, the merge-ready ones past it are still read
    many = [prow(100 + i, 'fix/issue-%d-x' % (100 + i), ['qa:pass']) for i in range(60)] + [prow(300, 'fix/issue-300-x', ['qa:pass', 'review:approved'])]
    add(collect_case('collect-past-the-cap', many, [irow(100 + i) for i in range(60)] + [irow(300)]))
    add(collect_case('collect-past-the-cap-capped-ignored', many + [prow(301, 'fix/issue-301-x', ['pipeline:ready'], base='dev'), prow(302, 'fix/issue-302-x')],
                     [irow(100 + i) for i in range(60)], roles='qa', files={'list-prs.err': 'result capped at 100'}))
    add(collect_case('collect-many-owners-queued', many[:30], [irow(100 + i, ['pipeline:ready']) for i in range(30)], roles='',
                     files={'list-needs-owner.rc': '0',
                            'list-needs-owner.json': [dict(n=100 + i, question='q', answered='no') for i in range(20)]}))
    return out


# -- talos-map ------------------------------------------------------------------

NOW = 1781524800  # 2026-06-15T12:00:00Z


def ago(s):
    return (datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc) - datetime.timedelta(seconds=s)).strftime('%Y-%m-%dT%H:%M:%SZ')


def ev(event, role, issue, pr=None, verdict=None, tokens=None, summary='', age=0, stage=None):
    e = dict(event=event, role=role, issue=issue, pr=pr, verdict=verdict, tokens=tokens, summary=summary, ts=ago(age))
    if stage:
        e['stage'] = stage
    return e


def map_events():
    E = []
    a = E.append
    a(ev('validator', 'validator', 21, verdict='CONFIRMED', age=3000))
    a(ev('pm', 'pm', 21, age=2900))
    a(ev('developer', 'developer', 21, 31, 'PR_OPENED', 5000, age=2000))
    a(ev('reviewer', 'reviewer', 21, 31, 'APPROVED', 800, '<b>reviewed</b> and fine', age=1000))
    a(ev('stage_start', 'orchestrator', 21, 31, summary='', age=420, stage='qa'))
    a(ev('validator', 'validator', 22, verdict='CONFIRMED', age=3000))
    a(ev('developer', 'developer', 22, 32, 'PR_OPENED', age=2500))
    a(ev('qa', 'qa', 22, 32, 'FAIL', summary='QA FAIL: wrong', age=2000))
    a(ev('reviewer', 'reviewer', 22, 32, 'CHANGES', summary='needs work', age=1500))
    a(ev('stage_start', 'orchestrator', 22, 32, age=300, stage='developer'))
    a(ev('developer', 'developer', 23, 33, 'PR_OPENED', age=6000))
    a(ev('qa', 'qa', 23, 33, 'FAIL', summary='QA FAIL', age=5500))
    a(ev('developer', 'developer', 23, 33, 'PR_OPENED', age=5000))
    a(ev('stage_start', 'orchestrator', 23, 33, age=450, stage='qa'))
    a(ev('validator', 'validator', 30, verdict='CONFIRMED', age=3000))
    a(ev('validator', 'validator', 25, verdict='CONFIRMED', age=3000))
    a(ev('pm', 'pm', 25, verdict='BLOCKED', summary='PM proposed 4 sub-issues', age=1800))
    a(ev('validator', 'validator', 26, verdict='CONFIRMED', age=3000))
    a(ev('pm', 'pm', 26, age=2900))
    a(ev('developer', 'developer', 26, 36, 'PR_OPENED', age=2000))
    a(ev('reviewer', 'reviewer', 26, 36, 'APPROVED', age=1500))
    a(ev('qa', 'qa', 26, 36, 'PASS', age=1200))
    a(ev('docs', 'docs', 26, 36, age=540))
    a(ev('developer', 'developer', 27, age=900))
    a(ev('blocked', 'orchestrator', 27, summary='need <i>credentials</i>', age=600))
    # a stage open for longer than its timeout: stalled
    a(ev('stage_start', 'orchestrator', 28, age=30000, stage='developer'))
    a(ev('developer', 'developer', 29, 39, 'PR_OPENED', 700, age=900))
    for i in range(60, 70):
        a(ev('developer', 'developer', i, i + 100, 'PR_OPENED', (i - 59) * 1000, age=20000))
        a(ev('merged', 'orchestrator', i, i + 100, 'merged', age=20000 - (i - 59) * 100))
    a(ev('merged', 'orchestrator', 70, 170, 'merged', age=9 * 86400))
    a(ev('usage', 'developer', 71, tokens=1234, age=500))
    a(dict(event='run_end', ts=ago(40000)))
    return E


def map_state():
    col = dict(prs=[dict(n=31, issue=21, stage='qa'), dict(n=32, issue=22, stage='developer'), dict(n=33, issue=23, stage='qa'),
                    dict(n=39, issue=29, stage='merge')],
               queued=[40, 41, 42], held=[42], inflight=[28], blocked=[['issue', 27], ['PR', 36], ['issue', 26], ['issue', 25]],
               owners=[dict(n=30, status='unanswered', question='Which database?\nSecond line'), dict(n=50, status='answered', question='x')],
               capped=[], ignored=0, pr_total=4)
    merged = [dict(number=200, title='elsewhere <b>one</b>', issue=80, mergedAt=ago(3600)),
              dict(number=201, title='no issue', mergedAt=ago(7200)),
              dict(number=163, title='local dup', issue=63, mergedAt=ago(100)),
              dict(number=202, title='old', issue=81, mergedAt=ago(20 * 86400))]
    return dict(ts=ago(0), collect_ts=ago(60), priority={'40': 0, '41': 2, '28': 1, '21': 0},
                run=dict(active=True, started=ago(30000)), collect=col, merged_remote=merged)


def run_map(args, remote):
    env = dict(os.environ, TALOS_NOW=str(NOW))
    return subprocess.run(['python3', '-I', MAP] + args, input=remote.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)


def map_transcript():
    out = []
    work = tempfile.mkdtemp(prefix='golden-map.')
    assert os.path.isdir(work) and work
    home = os.path.join(work, 'home')
    state_dir = os.path.join(work, 'state')
    titles = os.path.join(work, 'titles')
    os.makedirs(os.path.join(state_dir, 'lanes'))
    os.makedirs(titles)
    os.makedirs(home)
    for n, t in ((21, 'Add the <thing>'), (22, 'Fix é the other'), (30, 'Owner question issue'), (40, 'Queued one'), (26, 'Merge failed one')):
        write(os.path.join(titles, 'acme_widget.issue.%d' % n), t + '\n')
    with open(os.path.join(state_dir, 'events.jsonl'), 'w') as f:
        f.write('not json\n')
        for e in map_events():
            f.write(json.dumps(e) + '\n')
    write(os.path.join(state_dir, 'state.json'), map_state())
    lane = lambda issue, wt, role, pid, start: dict(issue=issue, worktree=wt, role=role, pid=pid, ts=ago(5), stage_start=start)
    write(os.path.join(state_dir, 'lanes', 'a.json'), lane(21, '/w/lane-2', 'qa', os.getpid(), ago(420)))
    write(os.path.join(state_dir, 'lanes', 'b.json'), lane(22, '/w/lane-1', 'developer', os.getpid(), ago(300)))
    write(os.path.join(state_dir, 'lanes', 'dead.json'), lane(99, '/w/lane-3', 'developer', 2 ** 22 + 7, ago(5)))
    cfg = os.path.join(work, 'talos.pipeline.json')
    write(cfg, {})
    base = ['--events', os.path.join(state_dir, 'events.jsonl'), '--state', os.path.join(state_dir, 'state.json'), '--home', home,
            '--provider', 'github', '--repo', 'acme/widget', '--scripts', os.path.join(ROOT, 'scripts'), '--titles', titles,
            '--stage-timeouts', 'developer=3600,default=7200', '--root', work, '--config', cfg]

    def dump(label, p):
        o = p.stdout.decode().replace(work, '<WORK>')
        out.append('## %s rc=%d\n%s%s' % (label, p.returncode, o, p.stderr.decode().replace(work, '<WORK>')))

    def files():
        for name in sorted(os.listdir(os.path.join(home, 'maps'))):
            if name.endswith('.lock'):
                continue
            out.append('### maps/%s\n%s' % (name, open(os.path.join(home, 'maps', name)).read().replace(work, '<WORK>')))

    def swap(args, key, val):
        a = args[:]
        a[a.index(key) + 1] = val
        return a

    dump('render rich', run_map(base, 'https://github.com/acme/widget.git\n'))
    files()
    # a second repo shares the registry; a third collides on the file name
    dump('render other repo', run_map(swap(base, '--repo', 'a-b/c'), 'https://github.com/a-b/c.git\n'))
    dump('render colliding name', run_map(swap(base, '--repo', 'a/b-c'), 'https://github.com/a/b-c.git\n'))
    files()
    # no state at all
    empty = swap(swap(base, '--state', os.path.join(work, 'nostate.json')), '--events', os.path.join(work, 'noevents.jsonl'))
    dump('render empty', run_map(empty, 'https://github.com/acme/widget.git\n'))
    files()
    # azure, an ended run, a collect that lists nothing, no live lane
    st = map_state()
    st['run'] = dict(active=False, started=ago(30000), end='stop at x <b>done</b>')
    st['collect'] = dict(prs=[], queued=[], held=[], inflight=[], blocked=[], owners=[])
    write(os.path.join(state_dir, 'state.json'), st)
    shutil.rmtree(os.path.join(state_dir, 'lanes'))
    az = swap(base, '--provider', 'azure') + ['--azure-org', 'https://dev.azure.com/org', '--azure-project', 'proj']
    dump('render azure ended run', run_map(az, 'https://dev.azure.com/org/proj/_git/widget\n'))
    files()
    write(os.path.join(state_dir, 'state.json'), map_state())
    dump('missing titles', run_map(base + ['--missing-titles'], 'https://github.com/acme/widget.git\n'))
    dump('forget', run_map(['--home', home, '--forget', 'a-b/c'], ''))
    dump('forget unknown', run_map(['--home', home, '--forget', 'no/such'], ''))
    dump('no slug', run_map(base, 'garbage\n'))
    files()
    shutil.rmtree(work)
    return out


def emit(text):
    """Print the transcript, or write it to the file named by the third argument."""
    if len(sys.argv) > 3:
        with open(sys.argv[3], 'w') as f:
            f.write(text + '\n')
    else:
        print(text)


if MODE == 'next':
    emit('\n'.join(next_cases() + where_cases() + collect_cases()))
elif MODE == 'map':
    emit('\n'.join(map_transcript()))
else:
    sys.exit('usage: golden.py <root> next|map [<out file>]')
