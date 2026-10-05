"""pipeline-next-stage.py -- the one implementation of a PR's stage (#470, AC2).

Stdlib only. Extracted byte-for-byte from the python embedded in
scripts/pipeline-status-file.sh (its `def next_stage(...)`, the
first-match-wins stage of an open pipeline PR), where it was defined at the
cost of every other caller: `talos.sh next` needs the same answer and must
never carry a second copy of the logic.

Both callers load this module by prepending its source to the program of one
`python3 -I` process (the same trick scripts/pipeline-config.sh uses for
pipeline-secret-shapes.py: no second spawn, and -I keeps the caller's cwd off
sys.path), then drive it through two plain functions:

    next_stage_init(opts)   -- once, with the mode's named options dict:
                               vcs (path), pr-draft ('true'/'false'),
                               required-checks ('yes'/'no'), merge-auto
                               ('true'/'false'); anything else the mode's
                               caller needs may ride along, this module
                               ignores it.
    next_stage(n, labels, issue_labels, enabled)
                            -- the stage of PR #n: 'blocked', 'unverified',
                               a role name, 'ready', 'ci', 'merge' or
                               'human-merge'. Byte-identical to the embedded
                               original, including the fail-closed `die()` on
                               a failed check-approval-sha read.

The GitHub reads (pr-is-draft, check-approval-sha, pr-checks-required) go
through the pipeline-vcs.sh path in opts['vcs'], one verb per call, never a
GitHub write.
"""

import os
import re
import signal
import subprocess
import sys
import time

BLOCKED_LABEL = 'pipeline:blocked'
STALE_RE = re.compile(r'^stale role=([a-z]+) label=')
APPROVALS = (('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'),
             ('security', 'security:approved'), ('adversarial', 'adversarial:approved'))
READ_DEADLINE = 120  # seconds for the whole read phase; CALL_TIMEOUT for one verb
CALL_TIMEOUT = 180

_ns_opts = {}
_ns_deadline = None
_ns_running = None


def _ns_die(msg):
    sys.stderr.write('pipeline-status-file: %s\n' % msg)
    sys.exit(1)


def _ns_read_deadline():
    """Seconds the whole read phase may take (TALOS_STATUS_READ_DEADLINE, for tests)."""
    v = os.environ.get('TALOS_STATUS_READ_DEADLINE', '')
    # ASCII digits only, at most 4: str.isdigit() accepts `²`, which int() rejects.
    return int(v) if re.fullmatch(r'[0-9]{1,4}', v) and 1 <= int(v) <= 3600 else READ_DEADLINE


def ns_kill_running():
    """Kill the running read verb's process group (INT/TERM/HUP during the
    read phase): it runs in its own session, so the terminal's signal never
    reaches it. Called by the embedding program's own signal handler."""
    p = _ns_running
    if p is not None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass


def _ns_vcs(*args):
    """Run one read verb in its own session. The overall deadline and the
    per-call timeout both END the run: a verb that timed out has no answer, and
    must never read as `ready` (pr-is-draft exit 1) or `ci` (exit 1)."""
    left = _ns_deadline - time.monotonic()
    if left <= 0:
        _ns_die('the GitHub read phase passed its %ds deadline' % _ns_read_deadline())
    try:
        p = subprocess.Popen(['bash', _ns_opts['vcs']] + list(args), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        _ns_die('could not run the read verb %s' % args[0])
    global _ns_running
    _ns_running = p
    try:
        out, err = p.communicate(timeout=min(CALL_TIMEOUT, left))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        _ns_die('the read verb %s timed out (read deadline %ds)' % (args[0], _ns_read_deadline()))
    finally:
        _ns_running = None
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def next_stage_init(opts):
    """Bind this process's mode: the options next_stage reads. Call once,
    before the first next_stage call. Signal handling stays with the
    embedding program (the status file installs its own handler over the
    whole read phase); this module only tracks the running Popen so the
    embedder's handler can reach it through next_stage_running()."""
    global _ns_opts, _ns_deadline
    _ns_opts = dict(opts)
    _ns_deadline = time.monotonic() + _ns_read_deadline()


def next_stage_running():
    """The read verb's Popen while next_stage reads, else None."""
    return _ns_running


def next_stage(n, labels, issue_labels, enabled):
    """First match wins: blocked, then the draft or default order, counting only
    enabled roles; an approval label that is missing or stale means that role."""
    if BLOCKED_LABEL in labels or BLOCKED_LABEL in issue_labels:
        return 'blocked'
    draft = False
    if _ns_opts.get('pr-draft') == 'true':
        rc, _, _ = _ns_vcs('pr-is-draft', str(n))
        if rc == 0:
            draft = True
        elif rc != 1:
            return 'unverified'
    stale = set()
    if any(label in labels for _, label in APPROVALS):
        rc, out, _ = _ns_vcs('check-approval-sha', str(n), '--stale-list')
        stale = set(m.group(1) for m in map(STALE_RE.match, out.splitlines()) if m)
        # exit 1 is both "stale approvals" (stale lines on stdout) and a failed read.
        if rc not in (0, 1) or (rc == 1 and not stale):
            _ns_die('check-approval-sha failed for PR #%d (rc=%d)' % (n, rc))
    for role, label in APPROVALS:
        if draft and role == 'qa':
            continue
        if role in enabled and (label not in labels or role in stale):
            return role
    if draft:
        return 'ready'
    if _ns_opts.get('required-checks') == 'yes':
        rc, _, _ = _ns_vcs('pr-checks-required', str(n))
        if rc != 0:
            return 'ci'
    return 'merge' if _ns_opts.get('merge-auto') == 'true' else 'human-merge'
