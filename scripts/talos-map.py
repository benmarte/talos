"""talos-map.py -- the project map (#614): one self-contained HTML page per
repository, rendered by code from Talos's local records, plus an index.

    git remote get-url origin | python3 -I talos-map.py --events <events.jsonl>
        --state <state.json> --home <TALOS_HOME> --provider <vcs.provider>
        --repo <vcs.repo> --azure-org <vcs.azure.org_url>
        --azure-project <vcs.azure.project> --scripts <scripts dir> [--titles <dir>]

The origin URL is read from stdin, never argv: it may carry a credential.

Reads only local files: the events log, the state snapshot `talos.sh run`
writes from the collect it already fetched, and the title cache
pipeline-meta.sh keeps. No network, no provider call, no LLM. Writes
<home>/maps/<owner>-<name>.html, <home>/maps/index.json (the registry) and
<home>/maps/index.html, and prints `map=<path>` and `index=<path>`.

Every value from a record is HTML-escaped; the page has no script and no
external asset, and reloads itself with a meta refresh (#877). Stdlib only.
"""

import argparse
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import urllib.parse

STEPS = ("validator", "pm", "dev", "review", "qa", "docs", "merge")
STEP_OF = {"validator": "validator", "pm": "pm", "developer": "dev", "reviewer": "review", "security": "review",
           "adversarial": "review", "qa": "qa", "docs": "docs"}
# The stage bar's segment class per state, and its one-line colour key.
STEP_CLASS = {"done": " d", "running": " r", "failed": " f", "redone": " x", "notreached": ""}
KEY = (("done", "done"), ("run", "running now"), ("fail", "failed"), ("redo", "redone after a failure"), ("todo", "not reached"))
ISO_TS = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
FAILING = {"FAIL", "CHANGES", "FINDINGS", "BLOCKED", "RESTAMP_FAIL"}
PASSING = {"PASS", "APPROVED", "CLEAR", "CONFIRMED"}
# Why an issue waits on a person: the tag, a fallback reason and the one step to take.
STOP_TAG = {"owner": "owner question", "epic": "epic · split proposed", "merge": "merge failed", "blocked": "blocked"}
STOP_WHY = {"merge": "every stage passed, but the merge did not complete"}
STOP_DO = {"owner": "answer on the issue", "epic": "approve or edit the split",
           "merge": "rerun the issue. Talos merges main in a fix round.",
           "blocked": "read the issue's latest comment, resolve what it names, then run again."}
RELOAD_S = 30
MERGED_SHOWN = 8
ACTIVITY_SHOWN = 7
ACTIVITY_MAX = 60
TOP_SPEND = 5
RECENT_DAYS = 7
# A run entry the snapshot has not touched for this long is an ended run: a live
# run writes the snapshot at every pass and stage, and no stage takes this long.
RUN_STALE_AFTER = datetime.timedelta(hours=6)


def pid_alive(pid):
    """Whether a process of that pid exists (a pid we may not signal does)."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def run_going(run, snap_ts, now):
    """A run entry says `active`; it is going only while its pid is alive (when
    the snapshot recorded one) and the snapshot is fresh."""
    if not run.get("active"):
        return False
    if "pid" in run and run["pid"] is not None and not pid_alive(run["pid"]):
        return False
    return not (snap_ts and now - snap_ts > RUN_STALE_AFTER)


def read_lanes(lanes_dir, now):
    """(live lanes, whether any record was readable). Each `talos.sh run` keeps
    one record in <state dir>/lanes/, keyed by its worktree (#878). A lane is
    live by the `run_going` rule: its pid is alive and the record is fresh. An
    unreadable record is ignored. Each live lane gains `n`: the digits ending
    its worktree's directory name, else its 1-based place by worktree path."""
    try:
        names = sorted(os.listdir(lanes_dir))
    except OSError:
        return [], False
    live, seen = [], False
    for name in names:
        rec = read_state(os.path.join(lanes_dir, name)) if name.endswith(".json") else None
        if not rec or not num(rec.get("issue")) or not isinstance(rec.get("worktree"), str):
            continue
        seen = True
        ts = parse_ts(rec.get("ts"))
        if ts and now - ts <= RUN_STALE_AFTER and pid_alive(rec.get("pid")):
            live.append(rec)
    live.sort(key=lambda r: r["worktree"])
    for i, rec in enumerate(live, 1):
        digits = re.search(r"(\d+)$", os.path.basename(rec["worktree"].rstrip("/")))
        rec["n"] = int(digits.group(1)) if digits else i
    return live, seen


def esc(v):
    return html.escape("" if v is None else str(v), quote=True)


def num(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def read_events(path):
    out = []
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict) and num(d.get("issue")):
                    out.append(d)
    except OSError:
        pass
    return out


def read_state(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def parse_ts(ts):
    try:
        return datetime.datetime.strptime(str(ts)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


class Links:
    """The provider's link shapes. `issues` and `prs` are web bases: one URL for
    GitHub and GitLab; Azure DevOps keeps work items at the project and pull
    requests at the repository."""

    def __init__(self, provider, issues, prs):
        self.p = provider
        self.issues, self.prs = (b.rstrip("/") if re.match(r"https://[^\s\"'<>]+$", b or "") else "" for b in (issues, prs))

    def issue(self, n):
        if not self.issues:
            return ""
        if self.p == "gitlab":
            return "%s/-/issues/%d" % (self.issues, n)
        if self.p == "azure":
            return "%s/_workitems/edit/%d" % (self.issues, n)
        return "%s/issues/%d" % (self.issues, n)

    def pr(self, n):
        if not self.prs:
            return ""
        if self.p == "gitlab":
            return "%s/-/merge_requests/%d" % (self.prs, n)
        if self.p == "azure":
            return "%s/pullrequest/%d" % (self.prs, n)
        return "%s/pull/%d" % (self.prs, n)


def remote_parts(url):
    """(web host, path segments) of a git remote, https or ssh, with the
    credentials and a trailing .git dropped. An https port is the web host's;
    an ssh port is not."""
    url = re.sub(r"(\.git)?/*$", "", (url or "").strip())
    m = re.match(r"([A-Za-z][A-Za-z0-9+.-]*)://(?:[^/]*@)?([^/:@]+)(:\d+)?/(.+)$", url)
    if m:
        port = (m.group(3) or "") if m.group(1).lower() in ("http", "https") else ""
        return m.group(2) + port, [s for s in m.group(4).split("/") if s]
    m = re.match(r"(?:[^/@]*@)?([^/:@]+):(.+)$", url)
    return (m.group(1), [s for s in m.group(2).split("/") if s]) if m else ("", [])


def enc(s):
    return urllib.parse.quote(urllib.parse.unquote(s), safe="")


def locate(provider, repo, remote, az_org, az_project):
    """(slug, title key, Links). The slug names the page and its index entry;
    the title key is owner/name, as pipeline-meta.sh keys its cache."""
    host, segs = remote_parts(remote)
    named = [s for s in (repo or "").split("/") if s]
    key = "/".join(named if len(named) == 2 else segs[-2:])
    if provider == "azure":
        # <org URL>/<project>/_git/<repository>: the configuration's keys, else
        # the remote (https://<host>/<org>/<project>/_git/<repository>, or
        # ssh's v3/<org>/<project>/<repository>).
        org = project = name = ""
        if segs[:1] == ["v3"] and len(segs) == 4:
            org, project, name = "https://dev.azure.com/" + segs[1], segs[2], segs[3]
        elif "_git" in segs[1:-1]:
            i = segs.index("_git", 1)
            org, project, name = "/".join(["https://" + host] + segs[:i - 1]), segs[i - 1], segs[i + 1]
        org, project, name = (az_org or org).rstrip("/"), az_project or project, named[-1] if named else name
        if org and project and name:
            root = "%s/%s" % (org, enc(project))
            slug = "/".join(re.sub(r"[^A-Za-z0-9._-]", "-", urllib.parse.unquote(s))
                            for s in (re.sub(r"^https?://(dev\.azure\.com/)?", "", org), project, name))
            return slug, key, Links(provider, root, "%s/_git/%s" % (root, enc(name)))
    if provider in ("github", "github-api"):
        # The remote's host (GitHub Enterprise), as pipeline-meta.sh repo-url.
        base = "https://%s/%s" % (host or "github.com", key) if key else ""
        return key, key, Links(provider, base, base)
    # GitLab and the rest: the remote's whole path, subgroups included. An Azure
    # remote in no known shape gets a page with no links, never a guessed one.
    base = "https://%s/%s" % (host, "/".join(segs)) if host and segs and provider != "azure" else ""
    return "/".join(named if len(named) > 1 else segs), key, Links(provider, base, base)


def link(url, text):
    return '<a href="%s">%s</a>' % (esc(url), esc(text)) if url else esc(text)


def title_of(titles_dir, slug, n):
    if not titles_dir:
        return ""
    key = re.sub(r"[^A-Za-z0-9_-]", "_", slug or "cwd")
    path = os.path.join(titles_dir, "%s.issue.%d" % (key, n))
    try:
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, errors="replace") as f:
                return f.read(300).splitlines()[0] if os.path.getsize(path) else ""
    except (OSError, IndexError):
        pass
    return ""


def fmt_ts(ts):
    return ts.strftime("%Y-%m-%d %H:%M UTC")


def ago(ts, now):
    s = int((now - ts).total_seconds())
    if s < 60:
        return "just now"
    return "%d min ago" % (s // 60) if s < 3600 else ("%d h ago" % (s // 3600) if s < 86400 else "%d d ago" % (s // 86400))


def dur(seconds):
    m = max(0, int(seconds)) // 60
    return "<1 min" if m < 1 else ("%d min" % m if m < 60 else "%d h %d min" % (m // 60, m % 60))


def when(ts, now):
    """A moment on the page: the one timestamp format, then its relative age."""
    return "%s (%s)" % (fmt_ts(ts), ago(ts, now))


def scrub(text):
    """Any ISO timestamp left in a record's own text (an end line, a summary)
    is shown in the page's one format."""
    return ISO_TS.sub(lambda m: fmt_ts(parse_ts(m.group(0))) if parse_ts(m.group(0)) else m.group(0), text)


def open_starts(evs):
    """stage -> (index, ts) of the stage's latest `stage_start` that has no later
    event of its own with `event` equal to that stage: the stage running now.
    The rule talos-status.sh uses for its running stage."""
    start, fin = {}, {}
    for i, e in enumerate(evs):
        ev, role = e.get("event"), e.get("role")
        if ev == "stage_start" and isinstance(e.get("stage"), str):
            start[e["stage"]] = (i, e.get("ts"))
        elif ev and ev == role and role != "orchestrator":
            fin[role] = i
    return {s: v for s, v in start.items() if v[0] > fin.get(s, -1)}


def steps(evs, opens):
    """(step, state) for the seven stages, from the issue's finishing events in
    order. A stage is done unless its verdict is a failing one (pm finishes with
    none). A failing review or QA verdict sends the work back: developer and the
    gates after it are no longer done. States: running (an open start), failed
    (its latest finishing event fails), redone (done now, after an earlier
    failure of its own or a reset by a gate), done, notreached."""
    done, failed, had = (dict.fromkeys(STEPS, False) for _ in range(3))
    for e in evs:
        role, v, ev = e.get("role"), e.get("verdict"), e.get("event")
        if ev == "merged":
            done["merge"] = True
            continue
        stage = STEP_OF.get(role) if ev == role else None
        if not stage:
            continue
        if v not in FAILING:
            done[stage], failed[stage] = True, False
            continue
        failed[stage] = had[stage] = True
        if stage in ("review", "qa"):
            for s in ("dev", "review", "qa"):
                had[s] = had[s] or done[s]
                done[s] = False
    running = {STEP_OF[r] for r in opens if r in STEP_OF}
    out = []
    for s in STEPS:
        st = "running" if s in running else "failed" if failed[s] else (("redone" if had[s] else "done") if done[s] else "notreached")
        out.append((s, st))
    return out


def steps_html(evs, opens, merge_failed=False):
    """The stage bar: seven segments, each with its state class and its name. A
    merge that failed after every gate passed has no event of its own, so the
    caller says so."""
    sts = steps(evs, opens)
    if merge_failed:
        sts[-1] = ("merge", "failed")
    return '<ol class="steps">%s</ol>' % "".join('<li class="s%s">%s</li>' % (STEP_CLASS[st], s) for s, st in sts)


def bar(tok, widest, px):
    """A token count with a small bar scaled to the widest count shown."""
    if tok is None:
        return "—"
    return '<span class="tok"><i style="width:%dpx"></i>%s</span>' % (
        max(1 if tok else 0, int(px * tok / widest)) if widest else 0, esc(fmt_tok(tok)))


def fmt_tok(t):
    return "%.2fM" % (t / 1e6) if t >= 1_000_000 else ("%dk" % round(t / 1000) if t >= 1000 else str(t))


def main(argv):
    ap = argparse.ArgumentParser()
    for k in ("events", "state", "home", "provider", "repo", "azure-org", "azure-project", "scripts", "titles"):
        ap.add_argument("--" + k, default="")
    a = ap.parse_args(argv)
    remote = "" if sys.stdin.isatty() else sys.stdin.readline()
    slug, title_key, links = locate((a.provider or "github").lower(), a.repo, remote, a.azure_org, a.azure_project)
    if not re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+", slug):
        sys.stderr.write("talos-map: no repository slug\n")
        return 1
    now = datetime.datetime.now(datetime.timezone.utc)
    events = read_events(a.events)
    snap = read_state(a.state) or {}
    # The queue view: the collect of the run's last state read. An empty one (no
    # snapshot, or a run that ended before it read the state) is no queue view,
    # never an empty queue.
    col = snap.get("collect") if isinstance(snap.get("collect"), dict) else {}
    run = snap.get("run") if isinstance(snap.get("run"), dict) else {}
    col_ts = parse_ts(snap.get("collect_ts")) if col else None
    lanes, lanes_seen = read_lanes(os.path.join(os.path.dirname(a.state), "lanes"), now)

    by_issue = {}
    for e in events:
        by_issue.setdefault(e["issue"], []).append(e)
    merged = {n for n, evs in by_issue.items() if any(e.get("event") == "merged" for e in evs)}
    pr_of = {}
    for n, evs in by_issue.items():
        for e in evs:
            if num(e.get("pr")):
                pr_of[n] = e["pr"]
    for p in col.get("prs") or []:
        if isinstance(p, dict) and num(p.get("issue")) and num(p.get("n")):
            pr_of[p["issue"]] = p["n"]
    queued = [n for n in col.get("queued") or [] if num(n)]
    inflight = [n for n in col.get("inflight") or [] if num(n)]
    pr_issues = [p.get("issue") for p in col.get("prs") or [] if isinstance(p, dict) and num(p.get("issue"))]
    blocked = set()
    for item in col.get("blocked") or []:
        if isinstance(item, list) and len(item) == 2 and num(item[1]):
            blocked.add(item[1] if item[0] != "PR" else next(
                (p.get("issue") for p in col.get("prs") or [] if isinstance(p, dict) and p.get("n") == item[1]), item[1]))
    # The collect is a read at col_ts and the log goes on after it (`done` writes
    # a stage's events after the pass read the state): an issue is judged by its
    # events since then, all of them when there is no collect. Stuck means
    # waiting on a person: a stage that ended BLOCKED:, or what the collect says
    # (a gate's block, the attempt ceiling), or an unanswered owner question.
    # A failing review or QA verdict only sends the work back to the developer:
    # that is a fix round, In progress, and so is a stage that started after the
    # last failing verdict.
    moved, running, rounds = set(), set(), {}
    for n, evs in by_issue.items():
        last_fail = last_start = -1
        for i, e in enumerate(evs):
            if e.get("event") == "stage_start":
                last_start = i
            elif e.get("event") == "blocked" or e.get("verdict") in FAILING:
                last_fail = i
        rounds[n] = sum(1 for e in evs if e.get("event") == e.get("role") and e.get("verdict") in FAILING
                        and e.get("verdict") != "BLOCKED")
        if n in merged:
            continue
        if last_start > last_fail:
            running.add(n)
            blocked.discard(n)
        late = [e for e in evs if not col or (col_ts and (parse_ts(e.get("ts")) or col_ts) >= col_ts)]
        if not late:
            continue
        moved.add(n)
        said = [e for e in late if e.get("event") not in ("stage_start", "stage_complete", "run_end", "hand_note", "finding_outcome")]
        if n in running:
            continue
        if said and said[-1].get("verdict") == "BLOCKED":
            blocked.add(n)
        elif said:
            blocked.discard(n)
    asks = {o["n"]: str(o.get("question") or "(question not readable)") for o in col.get("owners") or []
            if isinstance(o, dict) and num(o.get("n")) and o.get("status") == "unanswered"}
    blocked |= set(asks) - merged
    # With a collect, the log alone no longer keeps an issue in flight (#878): an
    # issue a run closed or abandoned has events after an old collect and no
    # live label. It stays only while the collect lists it (the lists that name
    # an issue: `capped` names verbs), a live lane works it, or a stage runs.
    if col:
        listed = set(queued) | set(inflight) | set(pr_issues) | blocked | set(asks) | {n for n in col.get("held") or [] if num(n)}
        moved &= listed | running | {ln["issue"] for ln in lanes}

    def state(n):
        if n in merged:
            return "Done"
        if n in blocked:
            return "Stuck"
        if n in inflight or n in pr_issues or n in moved or n in running:
            return "In progress"
        return "Not started"

    recent = set()
    for n in merged:
        ts = parse_ts(next((e.get("ts") for e in reversed(by_issue[n]) if e.get("event") == "merged"), ""))
        if ts and (now - ts).days < RECENT_DAYS:
            recent.add(n)
    shown = sorted(set(queued) | set(inflight) | set(pr_issues) | blocked | recent | moved | running)

    def tokens(n):
        """The issue's recorded tokens, or None when no stage event carried a number."""
        vals = [num(e.get("tokens")) for e in by_issue.get(n, []) if e.get("role") != "orchestrator"]
        vals = [v for v in vals if v is not None]
        return sum(vals) if vals else None

    def stuck_reason(n):
        if n in asks:
            return asks[n].strip().splitlines()[0][:200] if asks[n].strip() else ""
        for e in reversed(by_issue.get(n, [])):
            if e.get("event") == "blocked" or e.get("verdict") in FAILING:
                return str(e.get("summary") or e.get("verdict") or "").splitlines()[0][:200] if (e.get("summary") or e.get("verdict")) else ""
        return ""

    # The run state: the pill and the page header.
    name = slug
    counts = {"Done": 0, "In progress": 0, "Stuck": 0, "Not started": 0}
    for n in shown:
        counts[state(n)] += 1
    # A lane record is the word of a `talos.sh run` (#878); with none at all (a
    # session driven by `talos.sh next` writes none) the snapshot's run entry decides.
    if bool(lanes) if lanes_seen else run_going(run, parse_ts(snap.get("ts")), now):
        began = parse_ts(run.get("started"))
        pill = '<span class="pill live"><span class="dot"></span>Run going%s%s</span>' % (
            " · %d lanes" % len(lanes) if len(lanes) >= 2 else "",
            " · started %s ago" % dur((now - began).total_seconds()) if began else "")
    else:
        if run.get("end"):
            why = "last run ended: <code>%s</code>" % esc(str(run.get("end"))[:300])
        elif run.get("active"):
            why = "last run ended (no end line: it stopped without one)"
        else:
            why = "no run recorded"
        pill = '<span class="pill idle"><span class="dot"></span>Idle · %s</span>' % why
    header = '<header><h1>%s</h1>%s<span class="meta">updated %s · reloads every %d s</span></header>' % (
        esc(name), pill, esc(when(now, now)), RELOAD_S)
    note = "" if col else ('<p class="note">No run state yet: the queue, the next step and the owner questions '
                           'appear after a <code>talos.sh run</code>. This page shows what the events log knows.</p>')

    # Priority tiers, from the snapshot's own map. The collect's covers the
    # queued and in-flight issues only: a merged issue is no longer in it.
    prio = snap.get("priority") if isinstance(snap.get("priority"), dict) else {}
    tiers = []
    for label, val in (("p0", 0), ("p1", 1), ("p2", 2), ("unlabelled", None)):
        ns = [n for n in shown if (prio.get(str(n)) == val if val is not None else str(n) not in prio)]
        tiers.append((label, sum(1 for n in ns if state(n) == "Done"), len(ns)))
    current = next((label for label, done, total in tiers if done < total), None)

    def tier_html(label, done, total):
        here = label == current
        return ('<div class="tier">%s<span class="muted">%d of %d merged</span></div><div class="meter"><i style="width:%d%%"></i></div>'
                % ('<span><b>%s</b><span class="here">you are here</span></span>' % esc(label) if here else "<b>%s</b>" % esc(label),
                   done, total, done * 100 // total))
    track = "".join(tier_html(*t) for t in tiers if t[2])

    # Parts: needs you, in flight, queued, merged. Each issue is in one of them.
    pr_stage = {p["issue"]: p.get("stage") for p in col.get("prs") or []
                if isinstance(p, dict) and num(p.get("issue")) and isinstance(p.get("stage"), str)}
    held = {n for n in col.get("held") or [] if num(n)}

    def title_html(n):
        return esc(title_of(a.titles, title_key, n)) or "(title not cached)"

    def head(n):
        return '<div class="t">%s %s</div>' % (link(links.issue(n), "#%d" % n), title_html(n))

    def tok_text(n):
        t = tokens(n)
        return "tokens —" if t is None else "%s tokens" % fmt_tok(t)

    def pr_text(n):
        pr = pr_of.get(n)
        if not pr:
            return ""
        return "PR " + link(links.pr(pr), "#%d" % pr) + (" · stage " + esc(pr_stage[n]) if pr_stage.get(n) else "")

    def sub(n, tag, *bits):
        return '<div class="sub">%s%s</div>' % (tag, " · ".join(b for b in bits if b))

    def last_line(n):
        for e in reversed(by_issue.get(n, [])):
            s = str(e.get("summary") or "").strip()
            if s:
                s = s.splitlines()[0]
                return s if len(s) <= 120 else s[:119] + "…"
        return ""

    def stop_kind(n):
        """Why a stuck issue waits, from what the map already reads. First match wins."""
        evs = by_issue.get(n, [])
        if n in asks:
            return "owner"
        stop = next((e for e in reversed(evs) if e.get("event") == "blocked" or e.get("verdict") == "BLOCKED"), None)
        if stop and stop.get("role") in ("pm", "planner"):
            return "epic"
        sts = dict(steps(evs, open_starts(evs)))
        if all(sts[s] in ("done", "redone") for s in STEPS[:-1]) and sts["merge"] == "notreached":
            return "merge"
        return "blocked"

    def needs_row(n):
        evs = by_issue.get(n, [])
        kind = stop_kind(n)
        at = (parse_ts(evs[-1].get("ts")) if evs else None) or col_ts
        tag = '<span class="tag stuck">%s</span>' % esc(STOP_TAG[kind] + (" · " + ago(at, now) if at else ""))
        body = head(n) + sub(n, tag, pr_text(n), esc(tok_text(n)))
        if kind == "owner":
            body += '<div class="ask"><b>Question:</b> %s</div>' % esc(asks[n])
        else:
            body += '<div class="why">%s</div>' % esc(stuck_reason(n) or STOP_WHY.get(kind) or "waiting on a person")
        step = link(links.issue(n), STOP_DO[kind]) + "." if kind in ("owner", "epic") else STOP_DO[kind]
        return '<div class="row"><div>%s<div class="do">To continue: %s</div></div>%s</div>' % (
            body, step, steps_html(evs, open_starts(evs), kind == "merge"))

    def flight_row(n):
        evs = by_issue.get(n, [])
        op = open_starts(evs)
        tag = ""
        if op:
            stage, (_, ts) = max(op.items(), key=lambda kv: kv[1][0])
            began = parse_ts(ts)
            tag = '<span class="tag run">%s</span>' % esc(("QA" if stage == "qa" else stage)
                                                          + (" · running " + dur((now - began).total_seconds()) if began else ""))
        last = last_line(n)
        return '<div class="row"><div>%s%s%s</div>%s</div>' % (
            head(n), sub(n, tag, "fix round %d" % rounds[n] if rounds.get(n) else "", pr_text(n), esc(tok_text(n))),
            '<div class="why">Last: %s</div>' % esc(last) if last else "", steps_html(evs, op))

    by_state = {s: [n for n in shown if state(n) == s] for s in counts}
    main = []
    if by_state["Stuck"]:
        main.append('<section class="needs" id="needs"><h2>Needs you <span class="n">%d</span></h2>%s</section>'
                    % (len(by_state["Stuck"]), "".join(needs_row(n) for n in by_state["Stuck"])))
    key = "".join('<span><i style="background:var(--%s)"></i>%s</span>' % (c, w) for c, w in KEY)
    main.append('<section id="flight"><h2>In flight <span class="n">%d</span></h2><div class="key">%s</div>%s</section>'
                % (len(by_state["In progress"]), key,
                   "".join(flight_row(n) for n in by_state["In progress"]) or '<p class="muted">nothing in flight</p>'))
    waiting = []
    for n in queued:
        if state(n) == "Not started" and n not in waiting:
            waiting.append(n)
    if waiting:
        def queue_row(i, n):
            p = prio.get(str(n))
            chip = '<span class="pri p%d">p%d</span>' % (p, p) if num(p) is not None and p >= 0 else '<span class="pri">—</span>'
            return ('<tr><td class="nw muted">%d</td><td class="nw">%s</td><td>%s</td><td class="nw">%s</td><td class="hide-sm muted">%s</td></tr>'
                    % (i, link(links.issue(n), "#%d" % n), title_html(n), chip,
                       "waiting on you · pipeline:needs-owner" if n in held else "next free lane"))
        main.append('<section id="queue"><h2>Queued <span class="n">%d</span></h2><table><tr><th>#</th><th>issue</th><th>title</th>'
                    '<th>priority</th><th class="hide-sm">why it waits</th></tr>%s</table></section>'
                    % (len(waiting), "".join(queue_row(i, n) for i, n in enumerate(waiting, 1))))
    if by_state["Done"]:
        def merged_at(n):
            return parse_ts(next((e.get("ts") for e in reversed(by_issue[n]) if e.get("event") == "merged"), ""))
        done = sorted(by_state["Done"], key=lambda n: merged_at(n) or now, reverse=True)
        widest = max([tokens(n) or 0 for n in done] + [1])

        def merged_row(n):
            pr, t, m = pr_of.get(n), tokens(n), merged_at(n)
            return ('<tr><td class="nw">%s</td><td>%s</td><td class="nw hide-sm">%s</td><td class="nw hide-sm muted">%s</td><td class="nw num">%s</td></tr>'
                    % (link(links.issue(n), "#%d" % n), title_html(n), link(links.pr(pr), "#%d" % pr) if pr else "—",
                       esc(ago(m, now)) if m else "—", bar(t, widest, 60)))
        rows = [merged_row(n) for n in done]
        more = ('<details><summary>Show %d more</summary><table>%s</table></details>' % (len(rows) - MERGED_SHOWN, "".join(rows[MERGED_SHOWN:]))
                if len(rows) > MERGED_SHOWN else "")
        main.append('<section><h2>Merged · last %d days <span class="n">%d</span></h2><table><tr><th>issue</th><th>title</th>'
                    '<th class="hide-sm">PR</th><th class="hide-sm">merged</th><th class="num">tokens</th></tr>%s</table>%s</section>'
                    % (RECENT_DAYS, len(rows), "".join(rows[:MERGED_SHOWN]), more))

    # Next step.
    nxt_bar = ""
    if col:
        nxt = ""
        tmp = "%s.collect.%d.json" % (a.state, os.getpid())
        try:
            with open(tmp, "w") as f:
                json.dump(col, f)
            p = subprocess.run([sys.executable, "-I", os.path.join(a.scripts, "pipeline-next.py"), "where", tmp],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
            for ln in p.stdout.decode("utf-8", "replace").splitlines():
                if ln.startswith("next: "):
                    nxt = ln[6:]
        except Exception:
            pass
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        nxt_bar = '<div class="next"><b>Next step</b> · %s%s</div>' % (
            esc(nxt or "unknown"), ' <span class="muted">(queue as of %s)</span>' % esc(when(col_ts, now)) if col_ts else "")

    # Activity: what changed since the last run started, newest first.
    since = parse_ts(run.get("started") or "")
    feed = []
    for e in events:
        ts = parse_ts(e.get("ts"))
        if since and (not ts or ts < since):
            continue
        ev, v = e.get("event"), e.get("verdict")
        if ev == "merged":
            what = esc("merged" + (" PR #%d" % e["pr"] if num(e.get("pr")) else ""))
        elif ev == "blocked":
            what = '<span class="v-bad">blocked</span>: ' + esc(str(e.get("summary") or "")[:160])
        elif ev == e.get("role") and v:
            what = "%s %s" % (esc(e.get("role")), '<span class="%s">%s</span>' % (
                "v-bad" if v in FAILING else "v-ok", esc(v)) if v in FAILING or v in PASSING else esc(v))
        else:
            continue
        feed.append('<li><time>%s</time><span>%s %s</span></li>' % (
            ts.strftime("%H:%M") if ts else "—", link(links.issue(e["issue"]), "#%d" % e["issue"]), what))
    feed = feed[-ACTIVITY_MAX:][::-1]
    aside = []
    if lanes:
        def lane_row(ln):
            began = parse_ts(ln.get("stage_start"))
            what = " · ".join(b for b in (esc(ln.get("role") or ""), dur((now - began).total_seconds()) if began else "") if b)
            return '<li><span>lane %d · %s</span><span class="muted">%s</span></li>' % (
                ln["n"], link(links.issue(ln["issue"]), "#%d" % ln["issue"]), what)
        aside.append('<section id="lanes"><h2>Lanes <span class="n">%d</span></h2><ul class="lanes">%s</ul></section>'
                     % (len(lanes), "".join(lane_row(ln) for ln in lanes)))
    if feed:
        later = ('<details><summary>Show %d earlier</summary><ul class="feed">%s</ul></details>'
                 % (len(feed) - ACTIVITY_SHOWN, "".join(feed[ACTIVITY_SHOWN:])) if len(feed) > ACTIVITY_SHOWN else "")
        aside.append('<section><h2>Activity · this run</h2><ul class="feed">%s</ul>%s</section>' % ("".join(feed[:ACTIVITY_SHOWN]), later))
    if track:
        aside.append('<section><h2>Priority track</h2>%s</section>' % track)

    # Spend: every issue the page shows, the five with the most tokens listed.
    spent = [(n, tokens(n)) for n in shown if tokens(n)]
    total = sum(t for _, t in spent)
    top = sorted(spent, key=lambda r: (-r[1], r[0]))[:TOP_SPEND]
    if top:
        aside.append('<section><h2>Top spend · %d days</h2><table>%s<tr class="total"><td class="muted">total</td>'
                     '<td class="num"><b>%s</b></td></tr></table></section>' % (
                         RECENT_DAYS, "".join('<tr><td>%s</td><td class="num">%s</td></tr>'
                                              % (link(links.issue(n), "#%d" % n), bar(t, top[0][1], 120)) for n, t in top),
                         esc(fmt_tok(total))))

    tiles = '<div class="kpis">%s</div>' % "".join((
        '<a class="kpi%s" href="#needs"><b>%d</b><span>needs you</span></a>' % (" alert" if by_state["Stuck"] else "", len(by_state["Stuck"])),
        '<a class="kpi" href="#flight"><b>%d</b><span>in flight</span></a>' % len(by_state["In progress"]),
        '<a class="kpi" href="#queue"><b>%d</b><span>queued</span></a>' % len(waiting),
        '<div class="kpi"><b>%d</b><span>merged · %d days</span></div>' % (len(by_state["Done"]), RECENT_DAYS),
        '<div class="kpi"><b>%s</b><span>tokens · %d days</span></div>' % (esc(fmt_tok(total)), RECENT_DAYS)))
    parts = [header, note, tiles, nxt_bar, '<div class="grid"><main>', "".join(main), "</main><aside>", "".join(aside), "</aside></div>"]

    maps = os.path.join(a.home, "maps")
    os.makedirs(maps, exist_ok=True)
    # The index: a registry of every repository rendered under this home.
    reg_path = os.path.join(maps, "index.json")
    reg = read_state(reg_path) or {}
    # A page keeps the name it has. A new one is named by the slug with "/" as
    # "-", plus a hash of the slug when another repository already has that
    # name (a-b/c and a/b-c).
    fname = (reg.get(slug) or {}).get("file") if isinstance(reg.get(slug), dict) else None
    if not isinstance(fname, str) or not re.fullmatch(r"[A-Za-z0-9._-]+\.html", fname):
        fname = slug.replace("/", "-") + ".html"
        if any(isinstance(v, dict) and v.get("file") == fname for k, v in reg.items() if k != slug):
            fname = "%s-%s.html" % (fname[:-5], hashlib.sha1(slug.encode("utf-8")).hexdigest()[:8])
    page = os.path.join(maps, fname)
    write(page, doc("Talos map: " + name, scrub("".join(parts)), refresh=True))
    reg[slug] = {"file": fname, "updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "line": "%d merged · %d in flight · %d stuck · %d not started"
                         % (counts["Done"], counts["In progress"], counts["Stuck"], counts["Not started"])}
    write(reg_path, json.dumps(reg, indent=1, sort_keys=True))
    items = "".join('<li><a href="%s">%s</a> <span class="sub">%s · updated %s</span></li>'
                    % (esc(v.get("file", "")), esc(k), esc(v.get("line", "")), esc(v.get("updated", "")))
                    for k, v in sorted(reg.items()) if isinstance(v, dict))
    index = os.path.join(maps, "index.html")
    write(index, doc("Talos projects", "<header><h1>Talos projects</h1></header><ul class=\"index\">%s</ul>" % items))
    print("map=" + page)
    print("index=" + index)
    return 0


def write(path, text):
    # A name of this render's own: two at once never share a half-written file.
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


CSS = """
:root{--bg:#f7f6f2;--panel:#fff;--ink:#1d1d1b;--muted:#6b6a65;--line:#e4e2db;
--done:#2f7d4f;--done-bg:#e3f1e8;--run:#1f5fbf;--run-bg:#e2ecfb;--fail:#b3261e;--fail-bg:#fbe4e2;
--redo:#9a6200;--redo-bg:#fbf0d9;--todo:#c9c6bd;--todo-bg:#f0eee8;--bar:#cfd8e6}
@media (prefers-color-scheme:dark){:root{--bg:#151513;--panel:#1e1e1b;--ink:#ecebe6;--muted:#9c9a92;--line:#2f2e2a;
--done:#6cc28f;--done-bg:#1d3326;--run:#7aa7ef;--run-bg:#1b2840;--fail:#f08a80;--fail-bg:#3a1d1a;
--redo:#e2b252;--redo-bg:#3a2e14;--todo:#4a4842;--todo-bg:#262521;--bar:#33415a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
a{color:var(--run)}code{font-size:.9em;overflow-wrap:anywhere}
.wrap{max-width:1360px;margin:0 auto;padding:20px 16px 48px}
header{display:flex;flex-wrap:wrap;align-items:center;gap:8px 16px;margin-bottom:16px}
h1{font-size:20px;margin:0;overflow-wrap:anywhere}
.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12.5px;font-weight:600;max-width:100%;overflow-wrap:anywhere}
.pill.live{background:var(--run-bg);color:var(--run)}.pill.idle{background:var(--todo-bg);color:var(--muted)}
.dot{flex:none;width:8px;height:8px;border-radius:50%;background:currentColor}
.meta{color:var(--muted);font-size:12.5px;margin-left:auto}.note{color:var(--muted)}
.kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin-bottom:16px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 14px;text-decoration:none;color:inherit}
.kpi b{display:block;font-size:24px;line-height:1.2}.kpi span{color:var(--muted);font-size:12px}
.kpi.alert{border-color:var(--fail);background:var(--fail-bg)}.kpi.alert b,.kpi.alert span{color:var(--fail)}
.next{background:var(--run-bg);border:1px solid var(--line);border-left:4px solid var(--run);border-radius:10px;padding:10px 14px;margin-bottom:16px;overflow-wrap:anywhere}
.next b{color:var(--run)}
.grid{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:16px;align-items:start}
main,aside{min-width:0}
section{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin-bottom:16px}
section.needs{border-color:var(--fail);border-left:4px solid var(--fail)}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 10px;display:flex;align-items:center;gap:8px}
section.needs h2{color:var(--fail)}
h2 .n{background:var(--todo-bg);color:var(--ink);border-radius:999px;padding:0 8px;font-size:12px;letter-spacing:0}
section.needs h2 .n{background:var(--fail-bg);color:var(--fail)}
.key{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:11.5px;color:var(--muted);margin:-4px 0 10px}
.key i{display:inline-block;width:14px;height:6px;border-radius:3px;margin-right:4px;vertical-align:middle}
.row{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:6px 18px;padding:10px 0;border-top:1px solid var(--line)}
h2+.row,.key+.row{border-top:0}
.t,.sub,.why,.ask,.do{overflow-wrap:anywhere}
.t{font-weight:600}.t a{font-weight:700;text-decoration:none}
.sub{color:var(--muted);font-size:12.5px;margin-top:2px}
.why{font-size:12.5px;margin-top:4px;opacity:.85}
.ask{margin-top:6px;padding:8px 10px;background:var(--fail-bg);border-radius:6px;font-size:13px;white-space:pre-wrap}
.ask b{color:var(--fail)}
.do{margin-top:6px;font-size:12.5px}.do a{font-weight:600}
.tag{display:inline-block;font-size:11px;font-weight:700;padding:1px 7px;border-radius:4px;margin-right:6px;vertical-align:1px}
.tag.run{background:var(--run-bg);color:var(--run)}.tag.stuck{background:var(--fail-bg);color:var(--fail)}
.steps{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px;align-self:center;list-style:none;margin:0;padding:0}
.s{margin:0;font-size:9.5px;text-align:center;color:var(--muted);overflow-wrap:anywhere}
.s::before{content:"";display:block;height:7px;border-radius:4px;margin-bottom:3px;background:var(--todo)}
.s.d::before{background:var(--done)}.s.r::before{background:var(--run)}.s.f::before{background:var(--fail)}.s.x::before{background:var(--redo)}
.s.r{color:var(--run);font-weight:700}.s.f{color:var(--fail);font-weight:700}
table{width:100%;border-collapse:collapse}
td,th{text-align:left;padding:6px 8px;border-top:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}
th{font-size:11.5px;color:var(--muted);font-weight:600;border-top:0}
td.num,th.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.tok{display:flex;align-items:center;gap:8px;justify-content:flex-end}
.tok i{display:block;height:6px;border-radius:3px;background:var(--bar)}
.muted{color:var(--muted)}.nw{white-space:nowrap}
.lanes{list-style:none;margin:0;padding:0}
.lanes li{display:flex;justify-content:space-between;gap:8px;padding:5px 0;border-top:1px solid var(--line);font-size:12.5px}
.lanes li:first-child{border-top:0}
.pri{display:inline-block;font-size:11px;font-weight:700;padding:0 6px;border-radius:4px;background:var(--todo-bg)}
.pri.p0{background:var(--fail-bg);color:var(--fail)}.pri.p1{background:var(--redo-bg);color:var(--redo)}
tr.total td{font-weight:600}
details summary{cursor:pointer;color:var(--muted);font-size:12.5px;margin-top:8px}
.feed{list-style:none;margin:0;padding:0}
.feed li{display:grid;grid-template-columns:44px minmax(0,1fr);gap:8px;padding:5px 0;border-top:1px solid var(--line);font-size:12.5px;overflow-wrap:anywhere}
.feed li:first-child{border-top:0}.feed time{color:var(--muted)}
.v-ok{color:var(--done);font-weight:600}.v-bad{color:var(--fail);font-weight:600}
.tier{display:flex;justify-content:space-between;gap:8px;font-size:12.5px;padding:4px 0}
.tier .here{font-size:11px;color:var(--run);font-weight:700;margin-left:6px}
.meter{height:6px;border-radius:3px;background:var(--todo-bg);overflow:hidden;margin-bottom:6px}
.meter i{display:block;height:100%;background:var(--done)}
.index{padding-left:1.2em}.index li{margin:.15em 0;overflow-wrap:anywhere}
@media (max-width:980px){.grid{grid-template-columns:1fr}.row{grid-template-columns:1fr}}
@media (max-width:640px){.kpis{grid-template-columns:repeat(2,minmax(0,1fr))}.meta{margin-left:0;width:100%}.hide-sm{display:none}.wrap{padding:12px 10px 32px}.s{font-size:8.5px}}
"""


def doc(title, body, refresh=False):
    """One page. A map page reloads itself: a meta refresh is no script, so the
    policy below still holds."""
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            + ('<meta http-equiv="refresh" content="%d">' % RELOAD_S if refresh else "") +
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>%s</title><style>%s</style></head><body><div class="wrap">%s</div></body></html>\n' % (esc(title), CSS, body))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # never a traceback on the driver's output
        sys.stderr.write("talos-map: %s\n" % type(e).__name__)
        sys.exit(1)
