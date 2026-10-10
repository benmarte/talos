#!/usr/bin/env bash
# talos-status.sh -- the harness status line (#385, simplified by #550).
#
#   talos #7 qa ●●●●◐○ 3.41M
#
# Usage: talos-status.sh [--line]
#
# One offline command: it reads the local events log and, for a running stage,
# the harness transcript. No network or VCS call, no model tokens, no resident
# process. It prints ONE line and always exits 0; with no active issue, no log,
# not a git repo or any bad input it prints nothing (a traceback never reaches
# stdout; stderr is silent unless TALOS_STATUS_DEBUG=1).
#
# The dots: validator, pm, developer, review (reviewer + security + adversarial),
# qa, merge. ● done, ◐ running, ○ pending. A role switched off in the config
# (roles.<role>: false; adversarial is off by default) has no dot, and neither
# have validator or pm when they never ran and a later stage already has.
#   done     the role's last finishing event (event == role) has a passing
#            verdict; a review/qa verdict that is not passing sends the work back:
#            developer shows pending until it finishes again, and the gates after
#            a new developer finish are pending too. merge is the `merged` event.
#   running  a `stage_start` event (talos.sh prompt writes it, pipeline-hooks.sh
#            stage_start) newer than the role's last finishing event and not
#            older than 6 hours (a crashed run's marker must not stay running).
# The label is the newest running stage, else the first pending one.
#
# Tokens: the issue's non-orchestrator total from the events log (the figure
# `pipeline-events.sh cost` reports, formatted by pipeline-spend-format.py), plus,
# while a stage runs and the harness passed a transcript, the usage since that
# stage started (input + output + cache-creation tokens, the measure the events
# record; cache reads are not counted) from the transcript and from its
# subagent transcripts (<transcript minus .jsonl>/subagents/agent-*.jsonl), each
# message id counted once. Claude Code runs a statusLine command and passes it
# JSON on stdin with `transcript_path` (docs: code.claude.com/docs/en/statusline).
# A harness that passes nothing gets the recorded total, updated at each stage end.
#
# Which issue: the current branch (^(fix|feat)/issue-<N>), else the newest event's.
# An issue with a `merged` event is no longer active: nothing is printed.
#
# Config (data only, JSON): roles.* and events.path from the project's
# talos.pipeline.json (git toplevel) over ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.json.
# Log: <git common dir>/<events.path>, default talos/events.jsonl (#517). A path
# that is absolute, leaves the common dir, or is a symlink means no log. The file
# is opened O_NOFOLLOW|O_NONBLOCK, must be regular, and only its last 16 MB is
# read; the whole run is cut off after 3 s (TALOS_STATUS_TIMEOUT_S, 1..10).
#
# Other harnesses: call `talos-status.sh --line` from their status or footer hook.
# install.sh wires Claude Code's statusLine; one that is already there is chained
# (scripts/talos-statusline.sh, #585), never replaced.

[ "${TALOS_STATUS_DEBUG:-}" = "1" ] || exec 2>/dev/null
command -v python3 >/dev/null 2>&1 || exit 0
case "${1:-}" in
  '' | --line) ;;
  -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) exit 0 ;;
esac

# The scripts directory, through any symlink the script was linked onto PATH by.
_src="$0"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"

_common="" _top="" _branch=""
_git="$(git rev-parse --git-common-dir --show-toplevel 2>/dev/null)" || _git=""
if [ -n "$_git" ]; then
  _common="${_git%%
*}"
  _top="${_git#*
}"
  case "$_common" in
    /*) ;;
    *) _common="$(cd "$(dirname "$_common")" 2>/dev/null && pwd)/$(basename "$_common")" ;;
  esac
  _branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || _branch=""
fi
[ -n "$_common" ] || exit 0

exec 3<&0 || exec 3</dev/null
python3 -I -B - "$SCRIPT_DIR" "$_common" "$_top" "$_branch" <<'PYEOF'
import calendar, glob, importlib, json, os, re, select, signal, stat, sys, time

scripts_dir, common, top, branch = sys.argv[1:5]
DEBUG = os.environ.get("TALOS_STATUS_DEBUG") == "1"
LOG_TAIL = 16 * 1024 * 1024
LOG_MAX = 64 * 1024 * 1024
TRANSCRIPT_TAIL = 8 * 1024 * 1024
STALE_S = 6 * 3600
ORDER = ("validator", "pm", "developer", "review", "qa", "merge")
GROUPS = {"validator": ("validator",), "pm": ("pm",), "developer": ("developer",),
          "review": ("reviewer", "security", "adversarial"), "qa": ("qa",), "merge": ()}
DEFAULT_ON = {"validator": True, "pm": True, "developer": True, "reviewer": True, "security": True,
              "adversarial": False, "qa": True}
FAILING = re.compile(r"FAIL|CHANGES|FINDINGS|BLOCK|REJECT")
GATES = ("reviewer", "security", "adversarial", "qa")


def dbg(msg):
    if DEBUG:
        print("talos-status: " + msg, file=sys.stderr)


def bye(msg=""):
    dbg(msg or "nothing to print")
    sys.exit(0)


def on_alarm(*_):
    bye("time limit")


try:
    limit = int(os.environ.get("TALOS_STATUS_TIMEOUT_S", "3"))
except ValueError:
    limit = 3
signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(limit if 1 <= limit <= 10 else 3)

try:
    sys.path.insert(0, scripts_dir)
    fmt = importlib.import_module("pipeline-spend-format")
except Exception as e:
    bye("pipeline-spend-format.py unavailable: %s" % type(e).__name__)


def read_json(path):
    try:
        st = os.stat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size > 256 * 1024:
            return {}
        with open(path, "rb") as f:
            d = json.loads(f.read().decode("utf-8", "replace"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


# ── config: roles and events.path, the project file over the global one ──────
cfg = {}
for path in (os.path.join(os.environ.get("TALOS_HOME") or os.path.expanduser("~/.talos"), "talos.pipeline.json"),
             os.path.join(top, "talos.pipeline.json") if top else ""):
    d = read_json(path) if path else {}
    for key in ("roles", "events"):
        if isinstance(d.get(key), dict):
            cfg.setdefault(key, {}).update(d[key])


def role_on(role):
    v = cfg.get("roles", {}).get(role)
    return v if isinstance(v, bool) else DEFAULT_ON[role]


# ── the events log ────────────────────────────────────────────────────────
rel = cfg.get("events", {}).get("path")
rel = rel if isinstance(rel, str) and rel else "talos/events.jsonl"
if os.path.isabs(rel):
    bye("events.path must be relative to the git common dir")
log = os.path.normpath(os.path.join(common, rel))
if log != common and not log.startswith(common.rstrip("/") + "/"):
    bye("events.path leaves the git common dir")
if not os.path.realpath(os.path.dirname(log)).startswith(os.path.realpath(common)):
    bye("events.path resolves outside the git common dir")
try:
    fd = os.open(log, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    bye("no log")
with os.fdopen(fd, "rb") as f:
    st = os.fstat(f.fileno())
    if not stat.S_ISREG(st.st_mode) or st.st_size > LOG_MAX:
        bye("log is not a regular file within the size cap")
    if st.st_size > LOG_TAIL:
        f.seek(st.st_size - LOG_TAIL)
        f.readline()
    raw = f.read()

recs = []
for line in raw.split(b"\n"):
    if line.startswith(b"{"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict):
            recs.append(d)


def issue_of(rec):
    n = rec.get("issue")
    return n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else None


m = re.match(r"(?:fix|feat)/issue-([0-9]{1,9})(?:-|$)", branch)
issue = int(m.group(1)) if m else next((issue_of(r) for r in reversed(recs) if issue_of(r)), None)
if issue is None:
    bye("no active issue")
evs = [r for r in recs if issue_of(r) == issue]
if any(r.get("event") == "merged" for r in evs):
    bye("issue is merged")


# ── stage state ───────────────────────────────────────────────────────────
def ts_epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return 0


last_done, starts = {}, []   # role -> (index, passing); (index, stage, ts) of fresh stage_starts
for i, r in enumerate(evs):
    ev, role = r.get("event"), r.get("role")
    if ev == "stage_start" and isinstance(r.get("stage"), str):
        if time.time() - ts_epoch(r.get("ts")) <= STALE_S:
            starts.append((i, r["stage"], r.get("ts")))
    elif ev == role and role != "orchestrator":
        verdict = r.get("verdict")
        last_done[role] = (i, not (isinstance(verdict, str) and FAILING.search(verdict.upper())))

dev_i = last_done.get("developer", (-1, False))[0]
running = {}   # stage -> (index, ts) of its newest start after its last finish
for i, stage, ts in starts:
    if i > last_done.get(stage, (-1, 0))[0]:
        running[stage] = (i, ts)


def finished(role):
    d = last_done.get(role)
    if not d or not d[1]:
        return False
    if role in GATES:
        return d[0] > dev_i
    if role == "developer":
        return not any(last_done[g][0] > d[0] and not last_done[g][1] for g in GATES if g in last_done)
    return True


touched = set(last_done) | set(running)


def state(name):
    """done, running or pending; None when the stage has no dot."""
    if name == "merge":
        return "pending"
    members = [r for r in GROUPS[name] if role_on(r)]
    if not members:
        return None
    if any(r in running for r in members):
        return "running"
    if all(finished(r) for r in members):
        return "done"
    later = [r for s in ORDER[ORDER.index(name) + 1:] for r in GROUPS[s]]
    if name in ("validator", "pm") and not touched & set(members) and touched & set(later):
        return None   # never ran, and a later stage has begun: skipped
    return "pending"


dots, first_pending = "", None
for name in ORDER:
    s = state(name)
    if s is None:
        continue
    dots += {"done": "●", "running": "◐", "pending": "○"}[s]
    if s == "pending" and first_pending is None:
        first_pending = next((r for r in GROUPS[name] if role_on(r) and not finished(r)), name)

label = "".join(c for c in (max(running, key=lambda k: running[k][0]) if running else first_pending or "done")
                if c.isalnum() or c in "-_")

# ── tokens: recorded, plus the transcript usage while a stage runs ─────────────
total = 0
for r in evs:
    if r.get("role") != "orchestrator":
        total += fmt.as_count(r.get("tokens")) or 0


def read_stdin_json():
    # fd 3 is the harness's stdin (the bash above saved it; python's own stdin
    # is this program). A terminal or a pipe that stays silent gives {}.
    buf, end = b"", time.time() + 0.3
    try:
        if os.isatty(3):
            return {}
        while len(buf) < 1 << 20 and time.time() < end:
            if not select.select([3], [], [], max(end - time.time(), 0))[0]:
                break
            chunk = os.read(3, 65536)
            if not chunk:
                break
            buf += chunk
        d = json.loads(buf.decode("utf-8", "replace"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def transcript_usage(path, since, seen):
    """Add the usage of the messages stamped at or after `since` to `seen`
    (message id -> tokens; a repeated id keeps its last, complete, figure)."""
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size > TRANSCRIPT_TAIL:
                f.seek(size - TRANSCRIPT_TAIL)
                f.readline()
            data = f.read()
    except OSError:
        return
    for n, line in enumerate(data.split(b"\n")):
        if b'"usage"' not in line:
            continue
        try:
            d = json.loads(line)
            msg = d["message"]
            u = msg["usage"]
            if str(d.get("timestamp", ""))[:19] < since[:19]:
                continue
            toks = sum(fmt.as_count(u.get(k, 0)) or 0
                       for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens"))
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        seen[msg.get("id") or "%s:%d" % (path, n)] = toks


if running:
    tpath = read_stdin_json().get("transcript_path")
    since = min(ts for _, ts in running.values())
    if isinstance(tpath, str) and os.path.isabs(tpath) and tpath.endswith(".jsonl"):
        seen = {}
        transcript_usage(tpath, since, seen)
        floor = ts_epoch(since) - 1
        for sub in sorted(glob.glob(glob.escape(tpath[:-6]) + "/subagents/agent-*.jsonl"))[:64]:
            try:
                if os.path.getmtime(sub) >= floor:
                    transcript_usage(sub, since, seen)
            except OSError:
                continue
        total += sum(seen.values())

line = "talos #%d %s %s" % (issue, label, dots)
if total > 0:
    line += " " + fmt.fmt_num(total)
sys.stdout.reconfigure(encoding="utf-8")
print(line)
PYEOF
exit 0
