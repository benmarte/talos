#!/usr/bin/env bash
# talos-status.sh -- the shared status-line renderer (#385, part of #334).
# One offline command any tool's status line can call. It reads the local
# .talos/events.jsonl audit log, makes no network or VCS call and costs no
# model tokens.
#
# Usage: talos-status.sh --line    [--format a,b,c] [--style compact|full|minimal] [--width N]
#        talos-status.sh --preview [--format a,b,c] [--width N]   (--style is ignored)
#        talos-status.sh --help
#
# --line prints ONE line and always exits 0. Bad input (unknown option, a
# missing or invalid value, no valid segment name), no log, an empty log, not a
# git repo, a missing pipeline-spend-format.py: nothing on stdout. A
# traceback never reaches stdout, and stderr is silent unless
# TALOS_STATUS_DEBUG=1 (then one short note says why nothing was printed).
#
# --preview prints the compact, full and minimal styles, each at the current
# width and at 60 columns, from the real log when it has events, otherwise
# from sample data; the heading then reads "(sample)". It works outside a
# git repo (sample data).
#
# Segments (any order; an unknown name is dropped; a segment with no data is
# left out):
#   issue         #752          the issue of the current branch
#                               (^(fix|feat)/issue-<N>), else the newest event's
#   pr            PR #764       the newest event's pr for that issue (null: none)
#   stage         sec ✓         the newest finished non-orchestrator stage of the
#                               issue: role + a mark from its verdict. The log only
#                               records FINISHED stages, so there is no "running".
#                               Mark: BLOCK* -> ⚠ ; *FAIL*, CHANGES*, FINDINGS*,
#                               REJECT* -> ✗ ; PASS, *PASS (RESTAMP_PASS), APPROVED,
#                               OPENED, CONFIRMED, POSTED, MERGED -> ✓ ; anything
#                               else or null -> "done"
#   issue_tokens  3.41M         non-orchestrator tokens of the issue
#   stage_tokens  sec 56k       the same newest stage's tokens
#   today_tokens  today 12.41M  non-orchestrator tokens of events whose ts date
#                               is today (UTC), every issue
#   budget        78% of 4M     pipeline-budget.sh check --json, shown only when
#                               limits.tokens_per_issue is set (the script prints
#                               nothing when it is off); ⚠ at warn, ⛔ at exceeded
#   model         opus          model family of the same stage (session default
#                               for null)
#   breakdown     dev 1.57M · adv 596k · sec 487k    top roles by tokens
# A total with no recorded value prints "unrecorded" (never 0); with some
# unrecorded events it ends " (+K unrecorded)", as `cost --line` does. The
# segments the epic lists but #385 does not build (run_tokens, blocked,
# cost_estimate) are not known names and are dropped.
#
# Styles: compact (default) is the table above. full adds labels ("issue #752",
# "issue 3.44M", "budget 78% of 4M", "model opus"), the whole role name
# ("security ✓") and a top-6 breakdown. minimal drops the "of <limit>" from
# the budget, shows a top-2 breakdown and keeps everything else as compact.
#
# Numbers come from pipeline-spend-format.py (fmt_num, fmt_compact, as_count,
# role_label, role_abbrev, model_family, strip_controls, parse_budget), the
# module `pipeline-events.sh cost --line` uses, so the two always agree. The
# totals use the same rules as `cost`: orchestrator rows are excluded, a token
# value that is not a finite non-negative number is unrecorded. This script
# reads the log directly (one python3 -I -B process) instead of running
# `cost`, which would cost 2-3x the time.
#
# Config (data only), later layers override earlier ones key by key:
#   ${TALOS_HOME:-$HOME/.talos}/statusline.yml
#   <main repo root>/.talos/statusline.yml   (a linked worktree reads this too)
#   <git toplevel>/.talos/statusline.yml     (not a literal ./, so a subdirectory works)
#   statusline:
#     segments: [issue, pr, stage, issue_tokens, today_tokens, budget]
#     separator: " · "      # control characters removed, at most 10 characters
#     style: compact        # compact | full | minimal
#     color: auto           # auto | always | never
#     max_width: 80         # 20..500
#     placement: prepend    # installer-side, ignored here
# Missing or malformed -> the defaults above. The file is read as DATA: at most
# 64 KB, regular files only, a built-in reader for exactly this subset (scalars,
# `[a, b]` and `- item` lists, comments; anchors, aliases and tags are refused),
# JSON also accepted, and PyYAML's safe_load (never load) only for YAML the
# built-in reader refuses, when PyYAML is importable (`python3 -I` skips the
# user site, so a `pip install --user` PyYAML is not seen). Only whitelisted
# segment/style/color values and a clamped width are taken; ANSI escapes come
# only from this script's own table, never from config or the log.
#
# Width: --width > config max_width > COLUMNS > 80. Segments are dropped from
# the END until the line (measured in characters, without colour escapes)
# fits; it never wraps. If not even the first fits, nothing is printed.
#
# Colour: always (config), or auto when stdout is a TTY and NO_COLOR is unset
# or empty. Only the stage mark and the budget segment are coloured.
#
# Log: <main repo root>/.talos/events.jsonl, found through `git rev-parse
# --git-common-dir` (so a linked worktree and a subdirectory both work). A
# custom `events.path` is NOT honoured: reading it would need a config process
# per call. Install: `install.sh --global` copies this file and
# pipeline-spend-format.py into ${TALOS_HOME:-$HOME/.talos}/scripts.

[ "${TALOS_STATUS_DEBUG:-}" = "1" ] || exec 2>/dev/null
command -v python3 >/dev/null 2>&1 || exit 0

# The scripts directory, through any symlink the script was linked onto PATH by.
_src="$0"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"

# Repo facts for the renderer: the common git dir (absolute), the work tree
# top and the branch. Outside a repo all three stay empty.
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

python3 -I -B - "$SCRIPT_DIR" "$_common" "$_top" "$_branch" "$@" <<'PYEOF'
import json
import os
import re
import stat
import sys

scripts_dir, common_dir, toplevel, branch = sys.argv[1:5]
args = sys.argv[5:]
DEBUG = os.environ.get("TALOS_STATUS_DEBUG") == "1"

SEGMENTS = ("issue", "pr", "stage", "issue_tokens", "stage_tokens", "today_tokens",
            "budget", "model", "breakdown")
DEFAULT_SEGMENTS = ["issue", "pr", "stage", "issue_tokens", "today_tokens", "budget"]
STYLES = ("compact", "full", "minimal")
COLORS = ("auto", "always", "never")
DEFAULT_SEP = " · "
MAX_SEP = 10
MAX_CFG_BYTES = 64 * 1024
WIDTH_MIN, WIDTH_MAX, DEFAULT_WIDTH, PREVIEW_NARROW = 20, 500, 80, 60
TOP_N = {"compact": 3, "full": 6, "minimal": 2}
ANSI = {"green": "32", "yellow": "33", "red": "31"}
MAX_ISSUE_DIGITS = 9


def dbg(msg):
    if DEBUG:
        print("talos-status: " + msg, file=sys.stderr)


def regular_file(path):
    try:
        return stat.S_ISREG(os.stat(path).st_mode)
    except OSError:
        return False


# ── arguments ────────────────────────────────────────────────────────────

def parse_args(argv):
    """The options as a dict, or None for anything unrecognised or invalid."""
    opts = {"mode": None, "format": None, "style": None, "width": None}
    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        if arg in ("--line", "--preview"):
            opts["mode"] = arg[2:]
        elif arg in ("-h", "--help"):
            opts["mode"] = "help"
        elif arg.split("=", 1)[0] in ("--format", "--style", "--width"):
            name, eq, val = arg.partition("=")
            if not eq:
                if i >= len(argv):
                    return None
                val = argv[i]
                i += 1
            opts[name[2:]] = val
        else:
            return None
    if opts["format"] is not None:
        names = []
        for n in opts["format"].split(","):
            n = n.strip()
            if n in SEGMENTS and n not in names:
                names.append(n)
        if not names:
            return None
        opts["format"] = names
    if opts["style"] is not None and opts["style"] not in STYLES:
        return None
    if opts["width"] is not None:
        if not re.fullmatch(r"[0-9]{1,4}", opts["width"]) or int(opts["width"]) < 1:
            return None
        opts["width"] = int(opts["width"])
    return opts


# ── the shared formatter module ──────────────────────────────────────────

def load_format():
    """pipeline-spend-format.py by explicit path (-I ignores PYTHONPATH and the
    script directory), or None. The path is dropped again so nothing else can
    be imported from the scripts directory."""
    import importlib
    sys.path.insert(0, scripts_dir)
    try:
        return importlib.import_module("pipeline-spend-format")
    except Exception as e:
        dbg("pipeline-spend-format.py unavailable (%s)" % type(e).__name__)
        return None
    finally:
        try:
            sys.path.remove(scripts_dir)
        except ValueError:
            pass


# ── config, as data ──────────────────────────────────────────────────────

def _strip_comment(s):
    out, quote = [], None
    for i, c in enumerate(s):
        if quote:
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            break
        out.append(c)
    return "".join(out).rstrip()


def _scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    if s[:1] in ("&", "*", "!", "|", ">", "{", "[", "@", "`", "%"):
        raise ValueError("unsupported YAML")
    if re.fullmatch(r"-?[0-9]+", s):
        return int(s)
    return s


def mini_yaml(text):
    """The documented subset: one top-level `name:` section of `key: scalar`,
    `key: [a, b]` and `key:` + `- item` lines. Anything else is None."""
    root, section, key = {}, None, None
    try:
        for raw in text.splitlines():
            line = _strip_comment(raw)
            if not line.strip():
                continue
            body = line.strip()
            if not line.startswith(" "):
                if not body.endswith(":") or body.startswith("-"):
                    return None
                section, key = root.setdefault(body[:-1].strip(), {}), None
                continue
            if section is None:
                return None
            if body.startswith("- "):
                if key is None or not isinstance(section.get(key), list):
                    return None
                section[key].append(_scalar(body[2:]))
                continue
            k, sep, v = body.partition(":")
            if not sep:
                return None
            key, v = k.strip(), v.strip()
            if v == "":
                section[key] = []
            elif v.startswith("[") and v.endswith("]"):
                section[key] = [_scalar(x) for x in v[1:-1].split(",") if x.strip()]
            else:
                section[key] = _scalar(v)
    except ValueError:
        return None
    return root


def parse_text(text):
    """A JSON object first, then the documented subset, then PyYAML's
    safe_load when it is importable; None when none of them reads it."""
    try:
        return json.loads(text)
    except ValueError:
        pass
    data = mini_yaml(text)
    if data is not None:
        return data
    try:
        import yaml
    except Exception:
        return None
    return yaml.safe_load(text)


def read_config_file(path):
    """The `statusline` mapping of a config file, or None. Never raises."""
    try:
        if not regular_file(path):
            return None
        with open(path, "rb") as f:
            raw = f.read(MAX_CFG_BYTES + 1)
        if len(raw) > MAX_CFG_BYTES:
            return None
        data = parse_text(raw.decode("utf-8"))
        section = data.get("statusline") if isinstance(data, dict) else None
        return section if isinstance(section, dict) else None
    except Exception:  # includes RecursionError and MemoryError
        return None


def clean_config(section, fmt):
    """Only valid, whitelisted values of a config mapping."""
    out = {}
    segs = section.get("segments")
    if isinstance(segs, list):
        names = []
        for s in segs:
            if isinstance(s, str) and s in SEGMENTS and s not in names:
                names.append(s)
        if names:
            out["segments"] = names
    sep = section.get("separator")
    if isinstance(sep, str):
        sep = fmt.strip_controls(sep)[:MAX_SEP]
        if sep:
            out["separator"] = sep
    style, color = section.get("style"), section.get("color")
    if isinstance(style, str) and style in STYLES:
        out["style"] = style
    if isinstance(color, str) and color in COLORS:
        out["color"] = color
    width = section.get("max_width")
    if isinstance(width, int) and not isinstance(width, bool):
        out["max_width"] = max(WIDTH_MIN, min(WIDTH_MAX, width))
    return out


def load_config(fmt):
    paths = []
    home = os.environ.get("TALOS_HOME")
    if not home:
        try:
            home = os.path.join(os.path.expanduser("~"), ".talos")
        except Exception:
            home = ""
    if home:
        paths.append(os.path.join(home, "statusline.yml"))
    if common_dir:
        paths.append(os.path.join(os.path.dirname(common_dir), ".talos", "statusline.yml"))
    if toplevel:
        paths.append(os.path.join(toplevel, ".talos", "statusline.yml"))
    cfg, seen = {}, set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        section = read_config_file(path)
        if section:
            cfg.update(clean_config(section, fmt))
    return cfg


# ── events ───────────────────────────────────────────────────────────────
# One tuple per well-formed log line: (issue, role, pr, verdict, tokens, model,
# day), tokens already through as_count (int, or None for unrecorded).

def load_events(path, fmt):
    events = []
    if not path or not regular_file(path):
        return events
    as_count = fmt.as_count
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(rec, dict):
                continue
            ts = rec.get("ts")
            events.append((str(rec.get("issue")), rec.get("role"), rec.get("pr"),
                           rec.get("verdict"), as_count(rec.get("tokens")), rec.get("model"),
                           ts[:10] if isinstance(ts, str) else None))
    return events


def is_issue(text):
    return bool(re.fullmatch(r"[0-9]{1,%d}" % MAX_ISSUE_DIGITS, text))


def resolve_issue(events):
    """The issue of the current branch, else the newest event's issue."""
    m = re.match(r"(?:fix|feat)/issue-([0-9]{1,%d})(?![0-9])" % MAX_ISSUE_DIGITS, branch or "")
    if m:
        return str(int(m.group(1)))
    for ev in reversed(events):
        if is_issue(ev[0]):
            return ev[0]
    return None


def clean_pr(pr):
    if isinstance(pr, bool):
        return None
    if isinstance(pr, int) and 0 <= pr < 10 ** MAX_ISSUE_DIGITS:
        return str(pr)
    if isinstance(pr, str) and is_issue(pr):
        return str(int(pr))
    return None


class Total:
    """Tokens of a set of events: the recorded sum and how many events were
    recorded or unrecorded (falsy when the set is empty)."""
    def __init__(self):
        self.tokens = 0
        self.recorded = 0
        self.unrecorded = 0

    def add(self, n):
        if n is None:
            self.unrecorded += 1
        else:
            self.tokens += n
            self.recorded += 1

    def __bool__(self):
        return bool(self.recorded or self.unrecorded)


def gather(events, issue, today, fmt):
    """Everything the segments show, from the events: orchestrator rows are
    excluded from the totals, the stage and the breakdown, exactly as `cost
    --line` does."""
    d = {"issue": issue, "pr": None, "stage": None, "issue_total": Total(),
         "today_total": Total(), "breakdown": [], "budget": None}
    roles = {}  # role label -> [recorded tokens]; a role with no recorded value never gets an entry
    for ik, role, pr, verdict, n, model, day in events:
        mine = ik == issue
        if mine:
            d["pr"] = clean_pr(pr)
        if role == "orchestrator":
            continue
        if day == today:
            d["today_total"].add(n)
        if mine:
            d["issue_total"].add(n)
            d["stage"] = (role, verdict, n, model)
            if n is not None:
                roles.setdefault(fmt.role_label(role), [0])[0] += n
    # tokens descending, ties in first-seen order, as in `cost --line`
    d["breakdown"] = sorted(((r, acc[0]) for r, acc in roles.items()), key=lambda kv: -kv[1])
    return d


# ── segments ─────────────────────────────────────────────────────────────

def verdict_mark(verdict):
    """(mark, colour) for a verdict, ('', None) when it says nothing."""
    text = verdict.upper() if isinstance(verdict, str) else ""
    if "BLOCK" in text:
        return "⚠", "yellow"
    if any(w in text for w in ("FAIL", "CHANGES", "FINDINGS", "REJECT")):
        return "✗", "red"
    if text.endswith("PASS") or text in ("APPROVED", "OPENED", "CONFIRMED", "POSTED", "MERGED"):
        return "✓", "green"
    return "", None


def token_text(total, fmt):
    if not total:
        return None
    if not total.recorded:
        return "unrecorded"
    text = fmt.fmt_num(total.tokens)
    if total.unrecorded:
        text += " (+%d unrecorded)" % total.unrecorded
    return text


def build_segments(names, d, style, paint, fmt):
    """[(plain, shown)] for the segments that have data, in order. `paint`
    wraps text in a colour (or returns it unchanged)."""
    full, minimal = style == "full", style == "minimal"
    out = []
    stage = d["stage"]
    for name in names:
        plain = shown = None
        if name == "issue" and d["issue"]:
            plain = ("issue #%s" if full else "#%s") % d["issue"]
        elif name == "pr" and d["pr"]:
            plain = "PR #%s" % d["pr"]
        elif name == "stage" and stage:
            role = fmt.role_label(stage[0]) if full else fmt.role_abbrev(stage[0])
            mark, colour = verdict_mark(stage[1])
            plain = "%s %s" % (role, mark or "done")
            shown = "%s %s" % (role, paint(colour, mark)) if mark else plain
        elif name == "issue_tokens":
            text = token_text(d["issue_total"], fmt)
            if text:
                plain = ("issue " + text) if full else text
        elif name == "stage_tokens" and stage:
            role = fmt.role_label(stage[0]) if full else fmt.role_abbrev(stage[0])
            plain = "%s %s" % (role, "unrecorded" if stage[2] is None else fmt.fmt_num(stage[2]))
        elif name == "today_tokens":
            text = token_text(d["today_total"], fmt)
            if text:
                plain = "today " + text
        elif name == "budget" and d["budget"]:
            b = d["budget"]
            body = "%d%%" % b["pct"] if minimal else "%d%% of %s" % (b["pct"], fmt.fmt_compact(b["effective"]))
            plain = {"warn": "⚠ ", "exceeded": "⛔ "}.get(b["status"], "") + ("budget " if full else "") + body
            shown = paint({"warn": "yellow", "exceeded": "red"}.get(b["status"]), plain)
        elif name == "model" and stage:
            family = fmt.model_family(stage[3])
            plain = ("model " + family) if full else family
        elif name == "breakdown" and d["breakdown"]:
            plain = " · ".join("%s %s" % (fmt.role_abbrev(r), fmt.fmt_num(n))
                                    for r, n in d["breakdown"][:TOP_N[style]])
        if plain:
            out.append((plain, shown or plain))
    return out


def render(d, names, style, sep, width, color_on, fmt):
    def paint(colour, text):
        if color_on and colour:
            return "\x1b[%sm%s\x1b[0m" % (ANSI[colour], text)
        return text

    parts = build_segments(names, d, style, paint, fmt)
    while parts:
        if sum(len(p) for p, _ in parts) + len(sep) * (len(parts) - 1) <= width:
            break
        parts.pop()
    return sep.join(shown for _, shown in parts)


# ── budget ───────────────────────────────────────────────────────────────

PROJECT_CONFIG_NAMES = ("talos.pipeline.yml", "talos.pipeline.yaml", "talos.pipeline.json",
                        ".claude-pipeline.yaml", "pipeline.yaml", ".claude-pipeline.json",
                        "pipeline.json")  # the names pipeline-config.sh tries


def guard_may_be_on(base):
    """False only when no project config file in `base` mentions
    limits.tokens_per_issue, so the common guard-off case skips the ~30 ms
    budget process. A pre-filter, never the decision: any doubt (an unreadable
    file) says True and pipeline-budget.sh answers."""
    override = os.environ.get("PIPELINE_CONFIG")
    for name in ([override] if override else PROJECT_CONFIG_NAMES):
        path = os.path.join(base, name)
        if not os.path.exists(path):
            continue
        try:
            if not regular_file(path):
                return True
            with open(path, "rb") as f:
                if b"tokens_per_issue" in f.read(1 << 20):
                    return True
        except OSError:
            return True
    return False


def get_budget(issue, fmt):
    """parse_budget of `pipeline-budget.sh check --issue N --json` or None. The
    script prints nothing when limits.tokens_per_issue is off; exit 1 means
    exceeded, a signal and never a failure of the line. It runs in the git
    toplevel, where it finds talos.pipeline.* even when the status line was
    started from a subdirectory."""
    script = os.path.join(scripts_dir, "pipeline-budget.sh")
    base = toplevel or os.getcwd()
    if not issue or not regular_file(script) or not guard_may_be_on(base):
        return None
    try:
        import subprocess
        r = subprocess.run(["bash", script, "check", "--issue", issue, "--json"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, cwd=base,
                           stderr=subprocess.DEVNULL, timeout=15, check=False)
        return fmt.parse_budget(r.stdout.decode("utf-8", "replace"))
    except Exception as e:
        dbg("budget unavailable (%s)" % type(e).__name__)
        return None


# ── sample data for --preview ────────────────────────────────────────────

def sample(today):
    """Events shaped like the epic's example: issue 752, PR 764, 3.41M."""
    rows = [("751", "developer", 700, "PASS", 9000000, None)]
    for role, n, verdict, model in (
            ("developer", 1000000, "PASS", None), ("developer", 566000, "PASS", None),
            ("adversarial", 595600, "PASS", None), ("security", 430600, "PASS", None),
            ("reviewer", 373600, "PASS", None), ("docs", 244600, "PASS", None),
            ("qa", 144600, "PASS", None), ("security", 56000, "PASS", "claude-opus-4-1")):
        rows.append(("752", role, 764, verdict, n, model))
    events = [(ik, role, pr, verdict, n, model, today) for ik, role, pr, verdict, n, model in rows]
    return events, {"status": "ok", "pct": 78, "effective": 4000000}


# ── main ─────────────────────────────────────────────────────────────────

def emit(text):
    sys.stdout.flush()
    sys.stdout.buffer.write(text.encode("utf-8", "replace"))
    sys.stdout.buffer.flush()


def main():
    opts = parse_args(args)
    if opts is None:
        dbg("unrecognised or invalid arguments; try --help")
        return
    if opts["mode"] is None:
        dbg("nothing to do; use --line or --preview")
        return
    if opts["mode"] == "help":
        emit("Usage: talos-status.sh --line [--format a,b,c] [--style compact|full|minimal] [--width N]\n"
             "       talos-status.sh --preview [--format a,b,c] [--width N]\n"
             "Segments: " + ", ".join(SEGMENTS) + "\n")
        return
    fmt = load_format()
    if fmt is None:
        return
    import datetime
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    cfg = load_config(fmt)
    names = opts["format"] or cfg.get("segments") or DEFAULT_SEGMENTS
    sep = cfg.get("separator", DEFAULT_SEP)
    color_mode = cfg.get("color", "auto")
    color_on = color_mode == "always" or (
        color_mode == "auto" and sys.stdout.isatty() and not os.environ.get("NO_COLOR"))
    width = opts["width"] or cfg.get("max_width")
    if not width:
        cols = os.environ.get("COLUMNS", "")
        width = int(cols) if re.fullmatch(r"[0-9]{1,4}", cols) and int(cols) >= 1 else DEFAULT_WIDTH
    events = []
    if common_dir:
        events = load_events(os.path.join(os.path.dirname(common_dir), ".talos", "events.jsonl"), fmt)

    if opts["mode"] == "line":
        if not events:
            dbg("no events")
            return
        issue = resolve_issue(events)
        d = gather(events, issue, today, fmt)
        if "budget" in names:
            d["budget"] = get_budget(issue, fmt)
        line = render(d, names, opts["style"] or cfg.get("style", "compact"), sep, width, color_on, fmt)
        if line:
            emit(line + "\n")
        return

    real = bool(events)
    budget = None
    if real:
        issue = resolve_issue(events)
        d = gather(events, issue, today, fmt)
        if "budget" in names:
            d["budget"] = get_budget(issue, fmt)
    else:
        events, budget = sample(today)
        d = gather(events, "752", today, fmt)
        d["budget"] = budget
    lines = ["Talos status line preview" + ("" if real else " (sample)")]
    for style in STYLES:
        for w in (width, PREVIEW_NARROW):
            lines.append("%s, %d columns:" % (style, w))
            lines.append("  " + (render(d, names, style, sep, w, color_on, fmt) or "(empty)"))
    emit("\n".join(lines) + "\n")


try:
    main()
except BaseException as e:  # nothing but a line, or nothing, ever reaches stdout
    dbg("failed (%s: %s)" % (type(e).__name__, e))
PYEOF
exit 0
