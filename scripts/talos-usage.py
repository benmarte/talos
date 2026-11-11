"""talos-usage.py -- token usage of hand-driven stage subagents (#911).

A repository driven by hand from a Claude Code coordinator session dispatches
Talos's stage agents as subagents, so `talos.sh run` never records their tokens.
Claude Code keeps each subagent's transcript (`<session>/subagents/agent-<id>.jsonl`
with a sibling `agent-<id>.meta.json`). This module turns those into one `usage`
event per subagent in the events log of the repository the subagent worked on.

    python3 -I -B talos-usage.py import-usage [--transcript F]... [--session-dir D]...
                                              [--projects-dir D]... [--since DATE]
                                              [--repo owner/name] [--dry-run]
    python3 -I -B talos-usage.py hook          # the SubagentStop payload on stdin

`pipeline-events.sh import-usage` and the plugin hook `talos-usage-hook.sh` call
it. Stdlib only. Transcripts and meta files are read-only input parsed as JSON;
nothing in a brief is run, put in a command or used as a path. The only things
written are events logs, one appended line per event, under an exclusive flock.
The message-id sums come from pipeline-spend-format.py's `transcript_usage`.
"""

import argparse
import datetime
import fcntl
import glob
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROLES = ("validator", "pm", "planner", "developer", "qa", "reviewer", "security", "docs", "adversarial")
NAME = re.compile(r"agent-([A-Za-z0-9_-]+)\.jsonl")
SLUG = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+")
ISSUE_FORMS = re.compile(r"\(#(\d{1,9})\)|\bissue\s+#(\d{1,9})|\bcloses\s+#(\d{1,9})", re.I)
BRIEF_CAP = 256 * 1024
BRIEF_HEAD = 600
HOOK_BUDGET_S = 1.5
LOCK_WAIT_S = 1.0


def load_format():
    spec = importlib.util.spec_from_file_location("pipeline_spend_format", os.path.join(HERE, "pipeline-spend-format.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_ts(s):
    """An ISO time (with or without a fraction, Z or an offset) as an aware UTC datetime, or None."""
    if not isinstance(s, str):
        return None
    s = re.sub(r"\.\d+", "", s.strip())
    try:
        d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b["text"] for b in content if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def read_transcript(path, fmt):
    """What one subagent transcript says: brief (first user message), cwd, first and
    last message time, model, tool_use count and the per-message-id usage. None when
    the file is not a readable regular file."""
    try:
        st = os.stat(path)
        if not os.path.isfile(path):
            return None
        f = open(path, "rb")
    except OSError:
        return None
    out = {"brief": None, "cwd": None, "first": None, "last": None, "model": None, "tools": set(), "mtime": st.st_mtime}
    anon = 0
    with f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            ts = parse_ts(d.get("timestamp"))
            if ts:
                out["first"] = min(out["first"], ts) if out["first"] else ts
                out["last"] = max(out["last"], ts) if out["last"] else ts
            if out["cwd"] is None and isinstance(d.get("cwd"), str) and d["cwd"]:
                out["cwd"] = d["cwd"]
            msg = d.get("message")
            if not isinstance(msg, dict):
                continue
            if out["brief"] is None and d.get("type") == "user" and msg.get("role") == "user":
                t = text_of(msg.get("content"))
                if t.strip():
                    out["brief"] = t[:BRIEF_CAP]
            if msg.get("role") == "assistant":
                if isinstance(msg.get("model"), str) and msg["model"] and not msg["model"].startswith("<"):
                    out["model"] = msg["model"]
                if isinstance(msg.get("content"), list):
                    for b in msg["content"]:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            anon += 1
                            out["tools"].add(b["id"] if isinstance(b.get("id"), str) and b["id"] else "anon%d" % anon)
        f.seek(0)
        seen = {}
        fmt.transcript_usage(f, seen, "", name=path)
    out["usage"] = seen
    if out["last"] is None:
        out["last"] = datetime.datetime.fromtimestamp(st.st_mtime, datetime.timezone.utc)
        out["first"] = out["last"]
    return out


def common_dir(path):
    """The git common dir of the checkout containing `path`, from the files alone
    (no git is run: the path came from a transcript). None when there is none."""
    p = os.path.realpath(path)
    while True:
        g = os.path.join(p, ".git")
        if os.path.isdir(g):
            return os.path.realpath(g)
        if os.path.isfile(g):
            try:
                with open(g, "r", errors="replace") as f:
                    first = f.readline().strip()
            except OSError:
                return None
            if not first.startswith("gitdir:"):
                return None
            gd = os.path.realpath(os.path.join(p, first[7:].strip()))
            try:
                with open(os.path.join(gd, "commondir"), "r", errors="replace") as f:
                    return os.path.realpath(os.path.join(gd, f.readline().strip()))
            except OSError:
                return gd
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def within(root, path):
    real = os.path.realpath(path)
    if real == root or real.startswith(root.rstrip(os.sep) + os.sep):
        return True
    cd = common_dir(real)
    return cd is not None and cd == common_dir(root)


def home_registry():
    home = os.environ.get("TALOS_HOME") or os.path.join(os.path.expanduser("~"), ".talos")
    reg = read_json(os.path.join(home, "maps", "index.json")) or {}
    out = {}
    for slug, v in reg.items():
        if isinstance(v, dict) and SLUG.fullmatch(slug) and isinstance(v.get("root"), str) and os.path.isabs(v["root"]):
            cfg = v.get("config") if isinstance(v.get("config"), str) else None
            out[slug] = {"root": os.path.realpath(v["root"]), "config": cfg}
    return out


def cwd_top():
    p = os.path.realpath(os.getcwd())
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


class Log:
    """One repository's events log: where it is, and what it already says."""

    def __init__(self, path):
        self.path = path
        self.issues, self.prs, self.agents = set(), {}, set()
        try:
            with open(path, "rb") as f:
                for line in f:
                    self.note(line)
        except OSError:
            pass

    def note(self, line):
        try:
            e = json.loads(line)
        except ValueError:
            return
        if not isinstance(e, dict):
            return
        n, pr = e.get("issue"), e.get("pr")
        if isinstance(n, int) and not isinstance(n, bool):
            self.issues.add(n)
            if isinstance(pr, int) and not isinstance(pr, bool):
                self.prs[pr] = n
        if e.get("event") == "usage" and isinstance(e.get("agent_id"), str):
            self.agents.add(e["agent_id"])

    def append(self, event):
        """Append `event` as one line unless the log already has a usage event for its
        agent_id; the check and the write are one step under an exclusive flock.
        True when written, False when seen, None when the log could not be written."""
        raw = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            fd = os.open(self.path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o666)
        except OSError:
            return None
        try:
            end = time.monotonic() + LOCK_WAIT_S
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= end:
                        return None
                    time.sleep(0.02)
            os.lseek(fd, 0, os.SEEK_SET)
            chunks = []
            while True:
                b = os.read(fd, 1 << 20)
                if not b:
                    break
                chunks.append(b)
            data = b"".join(chunks)
            for line in data.splitlines():
                if b'"agent_id"' in line and b'"usage"' in line:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(e, dict) and e.get("event") == "usage" and e.get("agent_id") == event["agent_id"]:
                        self.agents.add(event["agent_id"])
                        return False
            if data and not data.endswith(b"\n"):
                raw = b"\n" + raw
            os.write(fd, raw)
            return True
        finally:
            os.close(fd)


class Importer:
    def __init__(self, repos, since, dry, deadline=None):
        self.fmt = load_format()
        self.dry, self.since, self.deadline = dry, since, deadline
        self.cands = home_registry()
        for slug in repos:
            if slug not in self.cands:
                top = cwd_top()
                if top:
                    self.cands[slug] = {"root": top, "config": None}
        self.rx = {s: re.compile(r"(?<![A-Za-z0-9._-])" + re.escape(s) + r"(?![A-Za-z0-9_-]|\.[A-Za-z0-9])") for s in self.cands}
        self.logs = {}
        self.n = {"imported": 0, "skipped": 0, "no-repo": 0, "no-issue": 0, "seen": 0, "not-subagent": 0}
        self.tokens = 0

    def skip(self, why=None):
        self.n["skipped"] += 1
        if why:
            self.n[why] += 1

    def log_for(self, slug):
        """The Log of a candidate slug, or None when events are off or the path cannot be resolved."""
        if slug in self.logs:
            return self.logs[slug]
        c = self.cands[slug]
        env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "PIPELINE_CONFIG")}
        if c["config"] and os.path.isfile(c["config"]):
            env["PIPELINE_CONFIG"] = c["config"]
        left = None if self.deadline is None else max(self.deadline - time.monotonic(), 0.1)
        log = None
        try:
            p = subprocess.run(["bash", os.path.join(HERE, "pipeline-events.sh"), "usage-target"], cwd=c["root"], env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=left)
            lines = p.stdout.decode("utf-8", "replace").splitlines()
            if p.returncode == 0 and lines and os.path.isabs(lines[0]):
                log = Log(lines[0])
        except (OSError, subprocess.SubprocessError):
            pass
        self.logs[slug] = log
        return log

    def repo_of(self, brief, cwd):
        hits = [s for s in self.cands if self.rx[s].search(brief or "")]
        if len(hits) > 1:
            return None
        if hits:
            return hits[0]
        if cwd:
            near = [s for s in self.cands if within(self.cands[s]["root"], cwd)]
            if len(near) == 1:
                return near[0]
        return None

    def role_of(self, meta, brief):
        at = meta.get("agentType") if isinstance(meta.get("agentType"), str) else ""
        at = at[len("talos:"):] if at.startswith("talos:") else at
        if at in ROLES:
            return at
        m = re.match(r"\s*You are the\s+([A-Za-z]+)", brief or "", re.I)
        if m and m.group(1).lower() in ROLES:
            return m.group(1).lower()
        return "other"

    def issue_of(self, meta, brief, log):
        """(issue, pr): the brief's own `(#N)` / `issue #N` / `closes #N`, else a `#N`
        of the description or the brief's head that is an issue of the log, else one
        that is a PR of the log, mapped to its issue."""
        m = ISSUE_FORMS.search(brief or "")
        if m:
            return int(next(g for g in m.groups() if g)), None
        desc = meta.get("description") if isinstance(meta.get("description"), str) else ""
        nums = []
        for g in re.findall(r"#(\d{1,9})", desc + "\n" + (brief or "")[:BRIEF_HEAD]):
            if int(g) not in nums:
                nums.append(int(g))
        for n in nums:
            if n in log.issues:
                return n, None
        for n in nums:
            if n in log.prs:
                return log.prs[n], n
        return None, None

    def one(self, path):
        m = NAME.fullmatch(os.path.basename(path))
        if not m:
            return self.skip("not-subagent")
        aid = m.group(1)
        t = read_transcript(path, self.fmt)
        if t is None or not t["usage"]:
            return self.skip()
        if self.since and t["last"] < self.since:
            return self.skip()
        meta = read_json(path[:-len(".jsonl")] + ".meta.json") or {}
        slug = self.repo_of(t["brief"], t["cwd"])
        if slug is None:
            return self.skip("no-repo")
        log = self.log_for(slug)
        if log is None:
            return self.skip()
        if aid in log.agents:
            return self.skip("seen")
        issue, pr = self.issue_of(meta, t["brief"], log)
        if issue is None:
            return self.skip("no-issue")
        sums = {}
        for key in ("input", "output", "cache_write", "cache_read"):
            vals = [u[key] for u in t["usage"].values() if u[key] is not None]
            sums[key] = sum(vals) if vals else None
        billed = [sums[k] for k in ("input", "output", "cache_write") if sums[k] is not None]
        tokens = sum(billed) if billed else None
        event = {
            "event": "usage", "role": self.role_of(meta, t["brief"]), "issue": issue, "pr": pr, "repo": slug,
            "model": t["model"], "runner": "claude", "duration_s": int((t["last"] - t["first"]).total_seconds()),
            "tokens": tokens, "tool_uses": len(t["tools"]),
            "input_tokens": sums["input"], "output_tokens": sums["output"],
            "cache_write_tokens": sums["cache_write"], "cache_read_tokens": sums["cache_read"],
            "agent_id": aid, "source": "transcript", "ts": t["last"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        if not self.dry:
            wrote = log.append(event)
            if wrote is None:
                return self.skip()
            if wrote is False:
                return self.skip("seen")
        log.agents.add(aid)
        log.issues.add(issue)
        if pr is not None:
            log.prs[pr] = issue
        self.n["imported"] += 1
        self.tokens += tokens or 0
        return None

    def line(self):
        n = self.n
        return "imported=%d skipped=%d (no-repo=%d no-issue=%d seen=%d not-subagent=%d) tokens=%d" % (
            n["imported"], n["skipped"], n["no-repo"], n["no-issue"], n["seen"], n["not-subagent"], self.tokens)


def session_files(d):
    return sorted(glob.glob(os.path.join(glob.escape(d), "subagents", "agent-*.jsonl")))


def projects_files(d):
    g = glob.escape(d)
    return sorted(glob.glob(os.path.join(g, "*", "subagents", "agent-*.jsonl")) +
                  glob.glob(os.path.join(g, "*", "*", "subagents", "agent-*.jsonl")))


def cmd_import(argv):
    ap = argparse.ArgumentParser(prog="talos-usage.py import-usage")
    ap.add_argument("--transcript", action="append", default=[])
    ap.add_argument("--session-dir", action="append", default=[])
    ap.add_argument("--projects-dir", action="append", default=[])
    ap.add_argument("--since", default="")
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if not (a.transcript or a.session_dir or a.projects_dir):
        ap.error("one of --transcript, --session-dir, --projects-dir is needed")
    since = None
    if a.since:
        since = parse_ts(a.since if "T" in a.since else a.since + "T00:00:00Z")
        if since is None:
            ap.error("--since must be an ISO date")
    for r in a.repo:
        if not SLUG.fullmatch(r):
            ap.error("--repo must be owner/name")
    files = list(a.transcript)
    for d in a.session_dir:
        files += session_files(d)
    for d in a.projects_dir:
        files += projects_files(d)
    imp = Importer(a.repo, since, a.dry_run)
    seen_paths = set()
    for f in files:
        if f in seen_paths:
            continue
        seen_paths.add(f)
        imp.one(f)
    print(imp.line())
    return 0


def hook_transcript(payload):
    p = payload.get("agent_transcript_path")
    if isinstance(p, str) and p:
        return os.path.expanduser(p)
    parent = payload.get("transcript_path")
    if not (isinstance(parent, str) and parent.endswith(".jsonl")):
        return None
    files = session_files(os.path.expanduser(parent)[:-len(".jsonl")])
    aid = payload.get("agent_id")
    if isinstance(aid, str) and re.fullmatch(r"[A-Za-z0-9_-]+", aid):
        for f in files:
            if os.path.basename(f) == "agent-%s.jsonl" % aid:
                return f
    files = [f for f in files if os.path.isfile(f)]
    return max(files, key=lambda f: (os.path.getmtime(f), f)) if files else None


def cmd_hook():
    """The SubagentStop hook: one subagent of a Talos role, imported. Never writes
    stdout, at most one stderr line, always 0, and gives up after HOOK_BUDGET_S."""
    def late(*_):
        sys.stderr.write("talos-usage-hook: gave up after %.1f s\n" % HOOK_BUDGET_S)
        os._exit(0)
    signal.signal(signal.SIGALRM, late)
    signal.setitimer(signal.ITIMER_REAL, HOOK_BUDGET_S)
    if os.environ.get("TALOS_USAGE_HOOK") == "0":
        return 0
    try:
        payload = json.loads(sys.stdin.buffer.read(1 << 20).decode("utf-8", "replace"))
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    at = payload.get("agent_type")
    if not isinstance(at, str):
        return 0
    at = at[len("talos:"):] if at.startswith("talos:") else at
    if at not in ROLES:
        return 0
    path = hook_transcript(payload)
    if not path:
        return 0
    imp = Importer([], None, False, deadline=time.monotonic() + HOOK_BUDGET_S - 0.2)
    imp.one(path)
    return 0


def main(argv):
    try:
        if argv[:1] == ["import-usage"]:
            return cmd_import(argv[1:])
        if argv[:1] == ["hook"]:
            try:
                return cmd_hook()
            except Exception as e:  # never fail a session
                sys.stderr.write("talos-usage-hook: %s\n" % type(e).__name__)
                return 0
    except BrokenPipeError:
        return 0
    sys.stderr.write("usage: talos-usage.py import-usage ... | hook\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
