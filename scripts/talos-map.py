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
external asset. Stdlib only.
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
STATE_WORD = {"done": "done", "running": "running now", "failed": "failed", "redone": "redone", "notreached": "not reached"}
ISO_TS = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
FAILING = {"FAIL", "CHANGES", "FINDINGS", "BLOCKED", "RESTAMP_FAIL"}
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


def steps_html(evs, opens):
    return '<ol class="steps">%s</ol>' % "".join(
        '<li class="step %s"><b>%s</b> %s</li>' % (st, s, STATE_WORD[st]) for s, st in steps(evs, opens))


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

    def fmt_tok(t):
        return "%.2fM" % (t / 1e6) if t >= 1_000_000 else ("%dk" % round(t / 1000) if t >= 1000 else str(t))

    # Header.
    name = slug
    counts = {"Done": 0, "In progress": 0, "Stuck": 0, "Not started": 0}
    for n in shown:
        counts[state(n)] += 1
    n_fly, n_stuck = counts["In progress"], counts["Stuck"]
    if run_going(run, parse_ts(snap.get("ts")), now):
        began = parse_ts(run.get("started"))
        run_line = "Run going%s, %d issue%s in flight, %d stuck" % (
            " for " + dur((now - began).total_seconds()) if began else "", n_fly, "" if n_fly == 1 else "s", n_stuck)
    else:
        if run.get("end"):
            why = "last run ended: <code>%s</code>" % esc(str(run.get("end"))[:300])
        elif run.get("active"):
            why = "last run ended (no end line: it stopped without one)"
        else:
            why = "no run recorded"
        run_line = "No run going · " + why
    if col_ts:
        run_line += " · queue as of %s" % esc(when(col_ts, now))
    parts = []
    parts.append('<header><h1>%s</h1><p class="sub">updated %s</p><p class="runline">%s</p>'
                 '<p class="counts"><span class="c done">%d merged</span> <span class="c prog">%d in flight</span> '
                 '<span class="c stuck">%d stuck</span> <span class="c todo">%d not started</span></p></header>'
                 % (esc(name), esc(fmt_ts(now)), run_line,
                    counts["Done"], counts["In progress"], counts["Stuck"], counts["Not started"]))
    if not col:
        parts.append('<p class="note">No run state yet: the queue, the next step and the owner questions '
                     'appear after a <code>talos.sh run</code>. This page shows what the events log knows.</p>')

    # Track: priority tiers, from the snapshot's own map. The collect's covers
    # the queued and in-flight issues only: a merged issue is no longer in it.
    prio = snap.get("priority") if isinstance(snap.get("priority"), dict) else {}
    tiers = []
    for label, val in (("p0", 0), ("p1", 1), ("p2", 2), ("unlabelled", None)):
        ns = [n for n in shown if (prio.get(str(n)) == val if val is not None else str(n) not in prio)]
        c = {s: sum(1 for n in ns if state(n) == s) for s in counts}
        tiers.append((label, c, len(ns)))
    current = next((t[0] for t in tiers if t[1]["In progress"] + t[1]["Not started"] + t[1]["Stuck"]), None)
    track = ('<section><h2>Track</h2><ol class="track">%s</ol></section>' % "".join(
        '<li class="%s"><b>%s</b> %d merged · %d in flight · %d queued%s</li>'
        % ("here" if label == current else "", esc(label), c["Done"], c["In progress"] + c["Stuck"], c["Not started"],
           ' <span class="you">you are here</span>' if label == current else "")
        for label, c, total in tiers if total))

    # Parts: needs you, in flight, queued, done. Each issue is in one of them.
    pr_stage = {p["issue"]: p.get("stage") for p in col.get("prs") or []
                if isinstance(p, dict) and num(p.get("issue")) and isinstance(p.get("stage"), str)}

    def title_html(n):
        return esc(title_of(a.titles, title_key, n)) or "(title not cached)"

    def head(n):
        return "<h3>%s %s</h3>" % (link(links.issue(n), "#%d" % n), title_html(n))

    def tok_text(n):
        t = tokens(n)
        return "tokens —" if t is None else "%s tokens" % fmt_tok(t)

    def info(n, st):
        pr = pr_of.get(n)
        bits = [esc(st)]
        if pr:
            bits.append("PR " + link(links.pr(pr), "#%d" % pr) + (" · stage " + esc(pr_stage[n]) if pr_stage.get(n) else ""))
        bits.append(esc(tok_text(n)))
        return "<p>%s</p>" % " · ".join(bits)

    def stage_line(n):
        op = open_starts(by_issue.get(n, []))
        if not op:
            return "no stage running"
        stage, (_, ts) = max(op.items(), key=lambda kv: kv[1][0])
        word = "QA" if stage == "qa" else stage
        if stage == "developer" and rounds.get(n):
            word += ", fix round %d" % rounds[n]
        began = parse_ts(ts)
        return esc(word) + (" · running " + dur((now - began).total_seconds()) if began else "")

    def last_line(n):
        for e in reversed(by_issue.get(n, [])):
            s = str(e.get("summary") or "").strip()
            if s:
                s = s.splitlines()[0]
                return s if len(s) <= 120 else s[:119] + "…"
        return ""

    def card(n, st):
        evs = by_issue.get(n, [])
        stuck = st == "Stuck"
        tail = ('<p class="why">%s</p>' % esc(stuck_reason(n) or "waiting on a person")) if stuck else (
            '<p class="last">%s</p>' % esc(last_line(n)) if last_line(n) else "")
        return '<article class="card %s%s">%s%s%s%s%s</article>' % (
            re.sub(r"[^a-z]", "", st.lower()), "" if stuck else " wide", head(n),
            "" if stuck else '<p class="stage">%s</p>' % stage_line(n),
            steps_html(evs, open_starts(evs)), info(n, st), tail)

    by_state = {s: [n for n in shown if state(n) == s] for s in counts}
    needs = "".join(card(n, "Stuck") for n in by_state["Stuck"])
    qs = [o for o in col.get("owners") or [] if isinstance(o, dict) and num(o.get("n"))]
    asked = "".join('<blockquote>%s<footer>%s</footer></blockquote>'
                    % (esc(str(o.get("question") or "(question not readable)")[:1000]), link(links.issue(o["n"]), "#%d" % o["n"]))
                    for o in qs)
    if needs or asked:
        parts.append('<section class="needs"><h2>Needs you</h2>%s%s</section>'
                     % ('<div class="grid">%s</div>' % needs if needs else "", asked))
    if by_state["In progress"]:
        parts.append('<section class="inflight"><h2>In flight</h2><div class="rows">%s</div></section>'
                     % "".join(card(n, "In progress") for n in by_state["In progress"]))
    if by_state["Not started"]:
        parts.append('<section class="queued"><h2>Queued</h2><ul class="queued">%s</ul></section>'
                     % "".join("<li>%s %s</li>" % (link(links.issue(n), "#%d" % n), title_html(n)) for n in by_state["Not started"]))
    if by_state["Done"]:
        def merged_at(n):
            return parse_ts(next((e.get("ts") for e in reversed(by_issue[n]) if e.get("event") == "merged"), ""))
        rows = []
        for n in sorted(by_state["Done"], key=lambda n: merged_at(n) or now, reverse=True):
            pr, t, m = pr_of.get(n), tokens(n), merged_at(n)
            rows.append('<tr class="done"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>'
                        % (link(links.issue(n), "#%d" % n), title_html(n), link(links.pr(pr), "#%d" % pr) if pr else "—",
                           "—" if t is None else esc(fmt_tok(t)), esc(when(m, now)) if m else "—"))
        parts.append('<section><h2>Done</h2><details class="done"><summary>%d merged in the last %d days</summary>'
                     '<div class="scroll"><table><tr><th>issue</th><th>title</th><th>PR</th><th>tokens</th><th>merged</th></tr>%s</table></div>'
                     '</details></section>' % (len(rows), RECENT_DAYS, "".join(rows)))
    if not shown:
        parts.append('<p class="note">Nothing in flight, queued or recently merged.</p>')
    parts.append('<section class="legend"><h2>Legend</h2><p>Each card shows the stages in order: '
                 + " › ".join("<b>%s</b>" % s for s in STEPS) + '.</p><ul>'
                 '<li><b>done</b>: the stage finished.</li><li><b>running now</b>: the stage is running.</li>'
                 '<li><b>failed</b>: its latest result was a failure.</li><li><b>redone</b>: done again after a failure.</li>'
                 '<li><b>not reached</b>: it has not started, or a failing review or QA sent it back.</li></ul>'
                 '<p>A failed or redone step means a gate sent the work back to the developer.</p></section>')
    parts.append(track)

    # Next step.
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
        parts.append('<section><h2>Next step</h2><p>%s</p></section>' % esc(nxt or "unknown"))

    # Changed since the last run started.
    since = parse_ts(run.get("started") or "")
    changed = []
    for e in events:
        ts = parse_ts(e.get("ts"))
        if since and (not ts or ts < since):
            continue
        ev, v = e.get("event"), e.get("verdict")
        if ev == "merged":
            what = "merged" + (" PR #%d" % e["pr"] if num(e.get("pr")) else "")
        elif ev == "blocked":
            what = "blocked: " + str(e.get("summary") or "")[:160]
        elif ev == e.get("role") and v:
            what = "%s %s" % (e.get("role"), v)
        else:
            continue
        changed.append('<li><time>%s</time> %s %s</li>' % (esc(when(ts, now)) if ts else "unknown time",
                                                          link(links.issue(e["issue"]), "#%d" % e["issue"]), esc(what)))
    parts.append('<section><h2>Changed since the last run started</h2>%s</section>'
                 % ("<ol>%s</ol>" % "".join(changed[-60:]) if changed else "<p>Nothing yet.</p>"))

    # Spend.
    rows = [(n, tokens(n)) for n in shown if tokens(n)]
    parts.append('<section><h2>Spend</h2><table><tr><th>issue</th><th>tokens</th></tr>%s'
                 '<tr class="total"><td>total</td><td>%s</td></tr></table></section>'
                 % ("".join("<tr><td>%s</td><td>%s</td></tr>" % (link(links.issue(n), "#%d" % n), esc(fmt_tok(t))) for n, t in rows),
                    esc(fmt_tok(sum(t for _, t in rows)))))

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
    write(page, doc("Talos map: " + name, scrub("".join(parts))))
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
:root{--bg:#fbfaf7;--fg:#1d1d1b;--mut:#6b6a66;--card:#fff;--line:#e3e1db;--done:#2f7d4f;--prog:#2f5f9e;--stuck:#b23b2e;--todo:#8a877f}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecebe6;--mut:#a3a19a;--card:#21211f;--line:#34332f;--done:#5cbf84;--prog:#78a6e6;--stuck:#ee7a6b;--todo:#a3a19a}}
*{box-sizing:border-box}body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;max-width:1100px;margin:auto}
h1{font-size:1.5em;margin:.2em 0}h2{font-size:1.1em;margin:1.6em 0 .5em;border-bottom:1px solid var(--line);padding-bottom:.2em}
h3{font-size:1em;margin:0 0 .3em}a{color:var(--prog)}.sub,.note,time{color:var(--mut)}code{font-size:.9em;overflow-wrap:anywhere}
.counts .c{margin-right:.8em;font-weight:600}.c.done,.step.done{color:var(--done)}.prog{color:var(--prog)}.stuck{color:var(--stuck)}.todo{color:var(--todo)}
.track{padding-left:1.2em}.track .here{font-weight:600}.you{color:var(--prog);font-size:.85em}
.grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--todo);border-radius:6px;padding:10px;overflow-wrap:anywhere}
.card.done{border-left-color:var(--done)}.card.inprogress{border-left-color:var(--prog)}.card.stuck{border-left-color:var(--stuck)}
.card p{margin:.2em 0}.why{color:var(--stuck)}
.runline{font-size:1.05em;font-weight:600;margin:.3em 0;overflow-wrap:anywhere}
.rows{display:grid;gap:10px;grid-template-columns:minmax(0,1fr)}.card.wide .stage{font-weight:600}.last{color:var(--mut);font-size:.9em}
.steps{display:flex;flex-wrap:wrap;gap:4px;list-style:none;padding:0;margin:.4em 0}
.step{margin:0;padding:1px 6px;border:1px solid var(--line);border-radius:4px;font-size:.8em}
.step.running{border-color:var(--prog);color:var(--prog);font-weight:600}.step.failed{border-color:var(--stuck);color:var(--stuck);font-weight:600}
.step.redone{border-style:double;border-color:var(--done)}.step.notreached{border-style:dashed;color:var(--mut)}
.scroll{overflow-x:auto}summary{cursor:pointer}.legend li{margin:.1em 0}.queued{overflow-wrap:anywhere}
blockquote{margin:.5em 0;padding:.5em .8em;border-left:3px solid var(--prog);background:var(--card);white-space:pre-wrap;overflow-wrap:anywhere}
blockquote footer{color:var(--mut);margin-top:.3em}
table{border-collapse:collapse}td,th{padding:.2em .8em .2em 0;text-align:left}tr.total td{font-weight:600;border-top:1px solid var(--line)}
ol,ul{padding-left:1.2em}li{margin:.15em 0;overflow-wrap:anywhere}
"""


def doc(title, body):
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>%s</title><style>%s</style></head><body>%s</body></html>\n' % (esc(title), CSS, body))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # never a traceback on the driver's output
        sys.stderr.write("talos-map: %s\n" % type(e).__name__)
        sys.exit(1)
