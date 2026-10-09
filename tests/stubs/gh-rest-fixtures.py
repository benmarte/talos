#!/usr/bin/env python3
"""A fixture GitHub REST API for the curl stub (and, through it, the gh stub).

usage: gh-rest-fixtures.py METHOD URL PAYLOAD-FILE

Prints three things: the HTTP status on line 1, the next page's URL on line 2
(empty when there is none), and the response body from line 3 on. The curl stub
calls this only when STUB_GH_FIXTURES=1 and its CURL_QUEUE is empty, so a test
that queues responses by hand never sees a fixture.

Every route is built from the STUB_* variables the gh stub has always honoured
(STUB_PR_HEAD_SHA, STUB_PR_LIST, STUB_ISSUE_COMMENTS_JSON, ...), converted from
gh's JSON shape to REST's, so a test that sets one reads the same data through
either transport. A *_RAW variable holds pre-concatenated pages (the shape
`gh api --paginate` prints); the page number in the URL picks one, and a Link
header names the next, as GitHub does.
"""
import json
import os
import re
import sys
from urllib.parse import parse_qs, urlsplit, urlunsplit

method, url, payload_file = sys.argv[1:4]
E = os.environ.get
parts = urlsplit(url)
path = parts.path
query = parse_qs(parts.query)
REPO = E("STUB_REPO", "acme/widget")
R = "/repos/" + REPO


def payload():
    try:
        return json.load(open(payload_file))
    except Exception:
        return {}


def jenv(name, default):
    raw = E(name)
    if not raw:
        return default
    return json.loads(raw)


def docs(raw):
    dec, pos, out = json.JSONDecoder(), 0, []
    while pos < len(raw):
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        if pos >= len(raw):
            break
        doc, pos = dec.raw_decode(raw, pos)
        out.append(doc)
    return out


def reply(status, body, nxt=""):
    print(status)
    print(nxt)
    print(json.dumps(body))
    sys.exit(0)


def paged(pages):
    """Serve page `page` of `pages` with a Link header to the next one."""
    n = int(query.get("page", ["1"])[0])
    nxt = ""
    if n < len(pages):
        q = {k: v[0] for k, v in query.items()}
        q["page"] = str(n + 1)
        nxt = urlunsplit((parts.scheme, parts.netloc, parts.path,
                          "&".join(k + "=" + v for k, v in q.items()), ""))
    reply(200, pages[n - 1] if pages else [], nxt)


def pull_of(p, repo=REPO):
    """gh's `pr list` / `pr view` JSON -> REST's pull object."""
    state = str(p.get("state", "OPEN")).upper()
    cross = p.get("isCrossRepository")
    out = {
        "number": p.get("number", 9),
        "state": "open" if state == "OPEN" else "closed",
        "merged_at": "2026-09-01T00:00:00Z" if state == "MERGED" else None,
        "title": p.get("title", ""),
        "body": p.get("body", ""),
        "html_url": "https://github.com/%s/pull/%s" % (repo, p.get("number", 9)),
        "node_id": "PR_node_%s" % p.get("number", 9),
        "draft": bool(p.get("isDraft", False)),
        "labels": p.get("labels", []),
        "head": {"ref": p.get("headRefName", ""), "sha": p.get("headRefOid", E("STUB_PR_HEAD_SHA", "abc123sha")),
                 "repo": {"full_name": "fork/" + repo.split("/")[1] if cross else repo}},
        "base": {"ref": p.get("baseRefName", E("STUB_PR_BASE_REF_NAME", "main")), "repo": {"full_name": repo}},
    }
    return out


def comments_rest():
    """gh-shaped comments (author.login, createdAt) -> REST (user.login, created_at)."""
    out = []
    raw = E("STUB_GH_COMMENTS_RAW")
    if raw:
        pages = docs(raw)
        return pages
    for i, c in enumerate(jenv("STUB_ISSUE_COMMENTS_JSON", None) or jenv("STUB_PR_COMMENTS_JSON", []) or []):
        d = dict(c)
        if "author" in d and "user" not in d:
            d["user"] = d.pop("author")
        if "createdAt" in d and "created_at" not in d:
            d["created_at"] = d.pop("createdAt")
        d.setdefault("id", 1000 + i)
        d.setdefault("html_url", "https://github.com/%s/issues/1#issuecomment-%d" % (REPO, d["id"]))
        out.append(d)
    return [out]


def mergeable():
    queue = E("STUB_PR_MERGEABLE_QUEUE")
    if queue and os.path.exists(queue) and os.path.getsize(queue):
        lines = open(queue).read().splitlines()
        value = lines[0]
        open(queue, "w").write("\n".join(lines[1:]) + ("\n" if lines[1:] else ""))
    else:
        value = E("STUB_PR_MERGEABLE", "MERGEABLE")
    return {"MERGEABLE": True, "CONFLICTING": False}.get(value)


def pr_checks():
    runs = []
    for line in (E("STUB_PR_CHECKS", "test\tpass\t1m2s\thttps://example/checks")).splitlines():
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        status, conclusion = {"pass": ("completed", "success"), "fail": ("completed", "failure"),
                              "pending": ("in_progress", None), "skipping": ("completed", "skipped"),
                              "cancel": ("completed", "cancelled")}.get(cols[1], ("completed", cols[1]))
        run = {"name": cols[0], "status": status, "conclusion": conclusion,
               "started_at": "2026-10-01T00:00:00Z", "completed_at": "2026-10-01T00:01:02Z" if conclusion else None}
        if len(cols) > 3:
            run["html_url"] = cols[3]
        runs.append(run)
    return runs


m = re.fullmatch(r"/repos/([^/]+/[^/]+)(/.*)?", path)
if not m:
    reply(404, {"message": "Not Found"})
repo, rest = m.group(1), m.group(2) or ""

# ── reads ────────────────────────────────────────────────────────────────────
if method == "GET":
    if rest == "":
        reply(200, {"full_name": repo, "default_branch": "main", "owner": {"login": repo.split("/")[0]}})
    mm = re.fullmatch(r"/pulls/(\d+)", rest)
    if mm:
        n = int(mm.group(1))
        state = E("STUB_PR_STATE", "OPEN")
        pr = pull_of({"number": int(E("STUB_PR_NUMBER", str(n))), "state": state,
                      "title": E("STUB_PR_TITLE", "fix: guard null session"),
                      "body": E("STUB_PR_BODY", "Closes #42"),
                      "headRefName": E("STUB_PR_HEAD_REF_NAME", "pr-branch"),
                      "labels": jenv("STUB_PR_LABELS_JSON", []),
                      "isDraft": E("STUB_PR_DRAFT") == "true"}, repo)
        pr["mergeable"] = mergeable()
        reply(200, pr)
    if rest == "/pulls":
        if E("STUB_GH_API_FAIL") == "prs":
            reply(502, {"message": "Bad Gateway"})
        if E("STUB_GH_PRS_RAW"):
            paged(docs(E("STUB_GH_PRS_RAW")))
        listed = jenv("STUB_PR_LIST", None)
        if listed is None:
            listed = [{"number": 9, "state": "OPEN", "title": "fix: guard null session",
                       "headRefName": "fix/issue-42-guard", "body": "Closes #42"}]
        paged([[pull_of(p, repo) for p in listed]])
    mm = re.fullmatch(r"/pulls/(\d+)/files", rest)
    if mm:
        if E("STUB_GH_API_FAIL") == "pr-files":
            reply(500, {"message": "Server Error"})
        if E("STUB_GH_PR_FILES_RAW"):
            paged(docs(E("STUB_GH_PR_FILES_RAW")))
        files = E("STUB_PR_FILES", "src/auth.js\ntests/auth.test.js").splitlines()
        paged([[{"filename": f, "additions": 0, "deletions": 0} for f in files if f]])
    if rest == "/issues":
        if E("STUB_GH_API_FAIL") == "issues":
            reply(500, {"message": "Server Error"})
        if E("STUB_GH_ISSUES_RAW"):
            paged(docs(E("STUB_GH_ISSUES_RAW")))
        listed = jenv("STUB_ISSUE_LIST", None)
        if listed is None:
            listed = [{"number": 3, "title": "Fix login bug", "labels": [{"name": "pipeline:dev"}], "body": "Body text"}]
        paged([listed])
    mm = re.fullmatch(r"/issues/(\d+)", rest)
    if mm:
        reply(200, {"number": int(mm.group(1)), "state": E("STUB_ISSUE_STATE", "OPEN").lower(),
                    "title": E("STUB_ISSUE_TITLE", "Fix login crash"),
                    "body": E("STUB_EPIC_BODY") or E("STUB_ISSUE_BODY", "stub body"),
                    "labels": jenv("STUB_ISSUE_LABELS_JSON", []), "assignees": [],
                    "html_url": "https://github.com/%s/issues/%s" % (repo, mm.group(1))})
    if re.fullmatch(r"/issues/\d+/comments", rest):
        if E("STUB_GH_API_FAIL") == "comments":
            reply(500, {"message": "Server Error"})
        paged(comments_rest())
    mm = re.fullmatch(r"/issues/(\d+)/labels", rest)
    if mm:
        reply(200, jenv("STUB_PR_LABELS_JSON", None) or jenv("STUB_ISSUE_LABELS_JSON", []))
    if re.fullmatch(r"/commits/[^/]+/check-runs", rest):
        paged([{"total_count": len(pr_checks()), "check_runs": pr_checks()}])
    if re.fullmatch(r"/commits/[^/]+/status", rest):
        reply(200, {"state": "success", "statuses": []})
    if rest == "/actions/runs":
        paged([{"total_count": 2, "workflow_runs": [{"id": 111, "conclusion": "failure"},
                                                      {"id": 112, "conclusion": "success"}]}])
    reply(404, {"message": "Not Found"})

# ── writes ───────────────────────────────────────────────────────────────────
body = payload()
mm = re.fullmatch(r"/issues/(\d+)/comments", rest)
if method == "POST" and mm:
    cid = E("STUB_COMMENT_ID", "100")
    reply(201, {"id": int(cid), "body": body.get("body", ""),
                "html_url": "https://github.com/%s/issues/%s#issuecomment-%s" % (repo, mm.group(1), cid)})
if method == "POST" and rest == "/issues":
    n = E("STUB_NEW_ISSUE_NUMBER", "42")
    reply(201, {"number": int(n), "html_url": "https://github.com/%s/issues/%s" % (repo, n)})
if method == "POST" and rest == "/pulls":
    n = E("STUB_NEW_PR_NUMBER", "9")
    reply(201, {"number": int(n), "html_url": "https://github.com/%s/pull/%s" % (repo, n)})
if method == "PUT" and re.fullmatch(r"/pulls/\d+/update-branch", rest):
    if E("STUB_UPDATE_BRANCH_FAIL") == "1":
        reply(409, {"message": "Head branch was modified out of order"})
    reply(202, {"message": "Updating pull request branch"})
if method == "PUT" and re.fullmatch(r"/pulls/\d+/merge", rest):
    reply(200, {"merged": True, "message": "Pull Request successfully merged"})
if method == "DELETE":
    reply(204, {})
reply(200, {})
