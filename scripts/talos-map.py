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

ROLES = ("validator", "pm", "developer", "review", "qa", "merge")
REVIEW = ("reviewer", "security", "adversarial")
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


def dots(evs):
    """The status line's six stages: done (●) or pending (○), from the issue's
    finishing events in order. A stage is done unless its verdict is a failing
    one (pm finishes with none). A failing review or QA verdict sends the work
    back: developer and the gates after it are pending again."""
    done = dict.fromkeys(ROLES, False)
    for e in evs:
        role, v, ev = e.get("role"), e.get("verdict"), e.get("event")
        if ev == "merged":
            done["merge"] = True
            continue
        if ev != role or role is None:
            continue
        stage = "review" if role in REVIEW else role
        if stage not in done:
            continue
        if v not in FAILING:
            done[stage] = True
        elif stage in ("review", "qa"):
            done["developer"] = done["review"] = done["qa"] = False
    return "".join("●" if done[r] else "○" for r in ROLES)


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
        said = [e for e in late if e.get("event") not in ("stage_start", "stage_complete", "run_end")]
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
        return sum(num(e.get("tokens")) or 0 for e in by_issue.get(n, []) if e.get("role") != "orchestrator")

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
    if run_going(run, parse_ts(snap.get("ts")), now):
        run_line = "a run is going" + (" (started %s)" % esc(run.get("started")) if run.get("started") else "")
    elif run.get("end"):
        run_line = "last run ended: <code>%s</code>" % esc(str(run.get("end"))[:300])
    elif run.get("active"):
        run_line = "last run ended (no end line: it stopped without one)"
    else:
        run_line = "no run recorded"
    if col_ts:
        run_line += " · queue as of %s" % esc(col_ts.strftime("%Y-%m-%d %H:%M UTC"))
    parts = []
    parts.append('<header><h1>%s</h1><p class="sub">updated %s · %s</p>'
                 '<p class="counts"><span class="c done">%d merged</span> <span class="c prog">%d in flight</span> '
                 '<span class="c stuck">%d stuck</span> <span class="c todo">%d not started</span></p></header>'
                 % (esc(name), esc(now.strftime("%Y-%m-%d %H:%M UTC")), run_line,
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
    parts.append('<section><h2>Track</h2><ol class="track">%s</ol></section>' % "".join(
        '<li class="%s"><b>%s</b> %d merged · %d in flight · %d queued%s</li>'
        % ("here" if label == current else "", esc(label), c["Done"], c["In progress"] + c["Stuck"], c["Not started"],
           ' <span class="you">you are here</span>' if label == current else "")
        for label, c, total in tiers if total))

    # Parts.
    cards = []
    for n in shown:
        st = state(n)
        t = title_of(a.titles, title_key, n)
        pr = pr_of.get(n)
        line = ""
        if st == "Stuck":
            r = stuck_reason(n)
            line = '<p class="why">%s</p>' % esc(r or "waiting on a person")
        elif n in running and rounds.get(n):
            line = '<p class="round">fix round %d</p>' % rounds[n]
        cards.append('<article class="card %s"><h3>%s %s</h3><p class="dots" title="validator pm developer review qa merge">%s</p>'
                     '<p>%s%s · %s tokens</p>%s</article>'
                     % (re.sub(r"[^a-z]", "", st.lower()), link(links.issue(n), "#%d" % n), esc(t),
                        dots(by_issue.get(n, [])), esc(st),
                        (" · PR " + link(links.pr(pr), "#%d" % pr)) if pr else "", esc(fmt_tok(tokens(n))), line))
    parts.append('<section><h2>Parts</h2><div class="grid">%s</div></section>'
                 % ("".join(cards) or '<p class="note">Nothing in flight, queued or recently merged.</p>'))

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

        # Needs your call.
        qs = [o for o in col.get("owners") or [] if isinstance(o, dict) and num(o.get("n"))]
        parts.append('<section><h2>Needs your call</h2>%s</section>' % (
            "".join('<blockquote>%s<footer>%s</footer></blockquote>'
                    % (esc(str(o.get("question") or "(question not readable)")[:1000]), link(links.issue(o["n"]), "#%d" % o["n"]))
                    for o in qs) or "<p>Nothing waits on you.</p>"))

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
        changed.append('<li><time>%s</time> %s %s</li>' % (esc(str(e.get("ts") or "")[:16].replace("T", " ")),
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
    write(page, doc("Talos map: " + name, "".join(parts)))
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
.counts .c{margin-right:.8em;font-weight:600}.done{color:var(--done)}.prog{color:var(--prog)}.stuck{color:var(--stuck)}.todo{color:var(--todo)}
.track{padding-left:1.2em}.track .here{font-weight:600}.you{color:var(--prog);font-size:.85em}
.grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--todo);border-radius:6px;padding:10px;overflow-wrap:anywhere}
.card.done{border-left-color:var(--done)}.card.inprogress{border-left-color:var(--prog)}.card.stuck{border-left-color:var(--stuck)}
.card p{margin:.2em 0}.dots{letter-spacing:.15em}.why{color:var(--stuck)}
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
