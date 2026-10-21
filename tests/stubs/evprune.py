#!/usr/bin/env python3
"""A fake `talos-evidence` branch on GitHub, Azure DevOps and GitLab (#817).

usage: evprune.py PROVIDER METHOD URL BODY-FILE

Prints the HTTP status on line 1 and the response body from line 2 on. The curl
stub (azure, and github through gh-rest-fixtures.py) and the glab stub call it
only when STUB_EVPRUNE_WORLD is set. The world is one JSON file:

  {"branch": true,                         # false: no talos-evidence branch
   "files": ["pr-1/01234567/a.png", ...],  # every path on the branch
   "prs": {"1": "merged", "2": "closed", "3": "open", "4": "error"},
   "dates": {"1": "2026-01-01T00:00:00Z"}, # the newest commit touching pr-<n>
   "truncated": false}                     # github: the recursive tree is cut

STUB_EVPRUNE_LOG gets one line per call: `CALL<tab>METHOD<tab>URL` and, for the
single write of each provider, `WRITE<tab><kind><tab><json body>` (github: tree,
commit, ref; azure: push; gitlab: commit). STUB_EVPRUNE_REFUSE=<status>:<message>
refuses that last write (github's ref update, azure's push, gitlab's commit);
a write that lands removes the paths it deletes from the world.
"""
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlsplit

provider, method, url, body_file = sys.argv[1:5]
E = os.environ.get
WORLD = E("STUB_EVPRUNE_WORLD")
LOG = E("STUB_EVPRUNE_LOG")
world = json.load(open(WORLD))
body = open(body_file).read() if body_file and os.path.isfile(body_file) else ""
parts = urlsplit(url)
query = parse_qs(parts.query)
HEAD = "c" * 40


def log(kind, text):
    if LOG:
        open(LOG, "a").write("%s\t%s\n" % (kind, text))


def save():
    json.dump(world, open(WORLD, "w"))


def out(status, payload):
    print(status)
    print(json.dumps(payload))
    sys.exit(0)


def refused():
    v = E("STUB_EVPRUNE_REFUSE", "")
    if v:
        status, _, message = v.partition(":")
        out(int(status), {"message": message})


def prs(n):
    state = world.get("prs", {}).get(n)
    if state is None:
        return None
    if state == "error":
        out(500, {"message": "Server Error"})
    return state


def newest(n):
    d = world.get("dates", {}).get(n)
    return d


def land(paths):
    gone = set(paths)
    world["files"] = [f for f in world["files"] if f not in gone]
    save()


log("CALL", "%s\t%s" % (method, url))
files = world.get("files", [])

if provider == "github":
    path = unquote(parts.path)
    rest = path.split("/repos/", 1)[1].split("/", 2)[2] if "/repos/" in path else path
    rest = "/" + rest.lstrip("/")
    if method == "GET" and rest == "/git/ref/heads/talos-evidence":
        if not world.get("branch", True):
            out(404, {"message": "Not Found"})
        out(200, {"ref": "refs/heads/talos-evidence", "object": {"sha": HEAD, "type": "commit"}})
    if method == "GET" and rest.startswith("/git/trees/"):
        tree = [{"path": f, "type": "blob", "mode": "100644", "sha": "b" * 40} for f in files]
        dirs = sorted({f.split("/")[0] for f in files})
        tree += [{"path": d, "type": "tree", "mode": "040000", "sha": "d" * 40} for d in dirs]
        out(200, {"sha": "t" * 40, "truncated": bool(world.get("truncated")), "tree": tree})
    m = re.fullmatch(r"/pulls/(\d+)", rest)
    if method == "GET" and m:
        state = prs(m.group(1))
        if state is None:
            out(404, {"message": "Not Found"})
        out(200, {"number": int(m.group(1)), "state": "open" if state == "open" else "closed",
                  "merged_at": "2026-01-01T00:00:00Z" if state == "merged" else None})
    if method == "GET" and rest == "/commits":
        n = query.get("path", [""])[0].replace("pr-", "")
        d = newest(n)
        out(200, [{"sha": "e" * 40, "commit": {"committer": {"date": d}}}] if d else [])
    if method == "POST" and rest == "/git/trees":
        log("WRITE", "tree\t" + body)
        out(201, {"sha": "u" * 40})
    if method == "POST" and rest == "/git/commits":
        log("WRITE", "commit\t" + body)
        out(201, {"sha": "k" * 40})
    if method == "PATCH" and rest == "/git/refs/heads/talos-evidence":
        log("WRITE", "ref\t" + body)
        refused()
        tree = [json.loads(l.split("\t", 2)[2]) for l in open(LOG) if l.startswith("WRITE\ttree\t")][-1]
        land([e["path"] for e in tree["tree"] if e.get("sha") is None])
        out(200, {"ref": "refs/heads/talos-evidence", "object": {"sha": "k" * 40}})
    out(404, {"message": "Not Found"})

if provider == "azure":
    rest = parts.path.split("/repositories/", 1)[1].partition("/")[2]
    if method == "GET" and rest == "refs":
        vals = [{"name": "refs/heads/talos-evidence", "objectId": HEAD}] if world.get("branch", True) else []
        out(200, {"value": vals})
    if method == "GET" and rest == "items":
        value = [{"path": "/", "isFolder": True}]
        value += [{"path": "/" + d, "isFolder": True} for d in sorted({f.split("/")[0] for f in files})]
        value += [{"path": "/" + f, "objectId": "b" * 40} for f in files]
        out(200, {"count": len(value), "value": value})
    m = re.fullmatch(r"pullRequests/(\d+)", rest)
    if method == "GET" and m:
        state = prs(m.group(1))
        if state is None:
            out(404, {"message": "TF401180: The requested pull request was not found."})
        out(200, {"pullRequestId": int(m.group(1)),
                  "status": {"merged": "completed", "closed": "abandoned", "open": "active"}[state]})
    if method == "GET" and rest == "commits":
        n = query.get("searchCriteria.itemPath", [""])[0].replace("/pr-", "")
        d = newest(n)
        out(200, {"count": 1 if d else 0, "value": [{"commitId": "e" * 40, "committer": {"date": d}}] if d else []})
    if method == "POST" and rest == "pushes":
        log("WRITE", "push\t" + body)
        refused()
        push = json.loads(body)
        if push["refUpdates"][0]["oldObjectId"] != HEAD:
            out(409, {"message": "TF401028: the push is based on an old head of the branch"})
        land([c["item"]["path"].lstrip("/") for c in push["commits"][0]["changes"] if c["changeType"] == "delete"])
        out(201, {"pushId": 1})
    out(404, {"message": "TF401174: The item could not be found"})

if provider == "gitlab":
    rest = unquote(parts.path.split("/projects/", 1)[1].partition("/")[2])
    if method == "GET" and rest == "repository/branches/talos-evidence":
        if not world.get("branch", True):
            out(404, {"message": "404 Branch Not Found"})
        out(200, {"name": "talos-evidence", "commit": {"id": HEAD}})
    if method == "GET" and rest == "repository/tree":
        out(200, [{"name": f.split("/")[-1], "type": "blob", "path": f} for f in files])
    m = re.fullmatch(r"merge_requests/(\d+)", rest)
    if method == "GET" and m:
        state = prs(m.group(1))
        if state is None:
            out(404, {"message": "404 Not found"})
        out(200, {"iid": int(m.group(1)), "state": {"merged": "merged", "closed": "closed", "open": "opened"}[state]})
    if method == "GET" and rest == "repository/commits":
        n = query.get("path", [""])[0].replace("pr-", "")
        d = newest(n)
        out(200, [{"id": "e" * 40, "committed_date": d}] if d else [])
    if method == "POST" and rest == "repository/commits":
        log("WRITE", "commit\t" + body)
        refused()
        land([a["file_path"] for a in json.loads(body)["actions"] if a["action"] == "delete"])
        out(201, {"id": "k" * 40})
    out(404, {"message": "404 Not Found"})

out(404, {"message": "unknown provider"})
