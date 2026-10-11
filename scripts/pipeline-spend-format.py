"""pipeline-spend-format.py -- the one source for spend-figure formatting (#393).

Stdlib only. `pipeline-events.sh cost --line` (#380) imports this lazily by
explicit path; later commands that print a spend figure import the same file,
so a number reads the same everywhere:

    import importlib, sys
    sys.path.insert(0, "<scripts dir>")
    fmt = importlib.import_module("pipeline-spend-format")

The file name has a hyphen, so a plain `import` statement cannot name it, and
`python3 -I` ignores PYTHONPATH and the script directory, so the path is
always inserted explicitly. Integer arithmetic only: round half up, never
round() (banker's) or '%.2f' (float artefacts).

It also holds the one harness-transcript reader (#604): `transcript_usage`,
used by the status line (talos-status.sh) and by the `Orchestrator session`
line of `cost --summary` (`fmt_session`).
"""

import json
import math
import os
import stat
import unicodedata
from decimal import Decimal

_ABBREV = {
    "developer": "dev", "adversarial": "adv", "security": "sec",
    "reviewer": "rev", "validator": "val", "planner": "plan",
}


def fmt_num(n):
    """999 -> '999', 1499 -> '1k', 999500 -> '1.00M', 3411000 -> '3.41M'."""
    n = int(n)
    if n < 1000:
        return str(n)
    k = (n + 500) // 1000
    if k < 1000:
        return "%dk" % k
    hundredths = (n + 5000) // 10000
    return "%d.%02dM" % (hundredths // 100, hundredths % 100)


def fmt_dur(secs):
    """45 -> '45s', 125 -> '2m05s', 3720 -> '1h02m'."""
    secs = int(secs)
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm%02ds" % (secs // 60, secs % 60)
    return "%dh%02dm" % (secs // 3600, (secs % 3600) // 60)


def role_label(role):
    """The role as one safe token ([A-Za-z0-9_-] only), so a role name from
    the log cannot add a line break or a talos:<word> marker."""
    text = "".join(c if (c.isascii() and (c.isalnum() or c in "-_")) else "_" for c in str(role))
    return text or "unknown"


def role_abbrev(role):
    label = role_label(role)
    return _ABBREV.get(label, label)


def as_count(v):
    """A recorded non-negative finite number as an int, or None (null, bool,
    string, negative, Infinity and NaN are all unrecorded)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        return None
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return int(v)


def fmt_compact(n):
    """fmt_num with the zero decimals trimmed, for a limit: 4000000 -> '4M',
    4500000 -> '4.5M', 250000 -> '250k'. Same rounding as fmt_num (a limit of
    1500 reads '2k'); above 999.5M it stays in M."""
    text = fmt_num(n)
    if text.endswith("M"):
        text = text[:-1].rstrip("0").rstrip(".") + "M"
    return text


_FAMILIES = ("opus", "sonnet", "haiku")


def strip_controls(text):
    """text without control, format (bidi overrides, zero-width) and line or
    paragraph separator characters."""
    return "".join(c for c in str(text) if unicodedata.category(c) not in ("Cc", "Cf", "Zl", "Zp"))


def model_family(model):
    """opus / sonnet / haiku for any model id naming one (case-insensitive,
    the one named first wins), else the value with control characters removed
    and cut at 30 characters; null or nothing left is 'session default'."""
    if model is None:
        return "session default"
    text = strip_controls(model).strip()
    if not text:
        return "session default"
    low = text.lower()
    named = [(low.find(f), f) for f in _FAMILIES if f in low]
    return min(named)[1] if named else text[:30]


_MAX_MODELS = 3


def model_summary(models):
    """One label for a run list: 'sonnet' when every run is one family,
    'sonnet \u00d73, opus \u00d71' when mixed (count descending, ties in the
    order first seen), '' for no runs. Past 3 distinct models the rest fold
    into '+K more'."""
    counts = {}
    for model in models:
        key = model_family(model)
        counts[key] = counts.get(key, 0) + 1
    if len(counts) <= 1:
        return next(iter(counts), "")
    ordered = sorted(counts.items(), key=lambda kv: -kv[1])  # stable
    parts = ["%s \u00d7%d" % kv for kv in ordered[:_MAX_MODELS]]
    if len(ordered) > _MAX_MODELS:
        parts.append("+%d more" % (len(ordered) - _MAX_MODELS))
    return ", ".join(parts)


def md_code(text):
    """text as one inert markdown table cell: a code span, so a value from the
    log (`@octocat`, `[x](http://e)`, `![i](http://e/p.png)`, `<!-- talos:spend
    -->`) is shown, never rendered. Newlines become a space, control characters
    are stripped, a backslash becomes '/' (a code span has no escapes, and a
    backslash before a pipe would unescape it), a pipe is escaped for the table,
    and the span's fence is one backtick longer than any run inside the value.
    Nothing left gives ''."""
    flat = str(text).replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    flat = strip_controls(flat).strip().replace("\\", "/").replace("|", "\\|")
    if not flat:
        return ""
    longest = run = 0
    for c in flat:
        run = run + 1 if c == "`" else 0
        longest = max(longest, run)
    fence = "`" * (longest + 1)
    pad = " " if flat.startswith("`") or flat.endswith("`") else ""
    return fence + pad + flat + pad + fence


def warn_percent(text):
    """limits.warn_at as a percentage string, exactly: '0.8' -> '80', '1.0' ->
    '100', '1e-05' -> '0.001'. Parsed as a number (config prints floats);
    outside 0 < x <= 1 it is 0.8, the same fallback pipeline-budget.sh uses."""
    try:
        x = float(text)
        if not 0 < x <= 1:
            raise ValueError
    except (TypeError, ValueError):
        x = 0.8
    out = format(Decimal(repr(x)) * 100, "f")
    return out.rstrip("0").rstrip(".") if "." in out else out


def _int_field(obj, key):
    v = obj.get(key)
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def parse_budget(text):
    """The `pipeline-budget.sh check --json` object as {'status', 'pct',
    'effective'} when it is an ok / warn / exceeded verdict with sane numbers,
    else None: empty, unparseable, `status: unknown` (any reason) and
    anything malformed all mean 'no budget to show'."""
    try:
        obj = json.loads(text) if text and text.strip() else None
    except (TypeError, ValueError):
        return None
    if not isinstance(obj, dict) or obj.get("status") not in ("ok", "warn", "exceeded"):
        return None
    pct, effective = _int_field(obj, "pct"), _int_field(obj, "effective")
    if pct is None or not effective:
        return None
    return {"status": obj["status"], "pct": pct, "effective": effective}


def fmt_budget(budget, warn_at):
    """The comment's budget line: 'Budget: 82% of 4M (warn at 80%)', with a
    warning mark first at warn and the pause notice after at exceeded. ''
    when budget is None."""
    if budget is None:
        return ""
    line = "Budget: %d%% of %s (warn at %s%%)" % (
        budget["pct"], fmt_compact(budget["effective"]), warn_percent(warn_at))
    if budget["status"] == "warn":
        return "\u26a0 " + line
    if budget["status"] == "exceeded":
        return line + " \u00b7 \u26d4 fix rounds paused for owner OK"
    return line


def fmt_budget_suffix(budget):
    """' \u00b7 budget 82% of 4M' for the one-line summary, only at warn or
    exceeded; '' otherwise."""
    if budget is None or budget["status"] == "ok":
        return ""
    return " \u00b7 budget %d%% of %s" % (budget["pct"], fmt_compact(budget["effective"]))


# \u2500\u2500 cache reads and cache writes (#604) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# `tokens` is fresh input + output + cache write; cache reads are never in it.
# A sum here is None when no event in scope carries the figure, and
# `unrecorded` counts the events with no cache read: neither is ever shown as 0.

def fmt_cache(read, write, unrecorded=0, totals=False):
    """The cache part of a spend line: 'cache read 48.2M, cache write 1.20M',
    with '(+K unrecorded)' after the read figure when K events have none, or
    'cache reads unrecorded' when no event has one. totals=True is the one-line
    form, which says where each figure stands against the total next to it:
    'cache read 48.2M (not in total, +K unrecorded), cache write 1.20M (in total)'."""
    if read is None:
        return "cache reads unrecorded"
    more = "+%d unrecorded" % unrecorded if unrecorded else ""
    if totals:
        read_text = "%s (%s)" % (fmt_num(read), ", ".join(p for p in ("not in total", more) if p))
        write_text = "unrecorded" if write is None else fmt_num(write) + " (in total)"
    else:
        read_text = fmt_num(read) + (" (%s)" % more if more else "")
        write_text = "unrecorded" if write is None else fmt_num(write)
    return "cache read %s, cache write %s" % (read_text, write_text)


def fmt_cache_cell(total, unrecorded, runs):
    """One cache cell of a spend table: the compact sum, '<sum> (+K
    unrecorded)' when K of the row's runs have no cache read, 'unrecorded' when
    none has (or no run carries this figure)."""
    if total is None or unrecorded >= runs:
        return "unrecorded"
    return fmt_num(total) + (" (+%d unrecorded)" % unrecorded if unrecorded else "")


TRANSCRIPT_CAP = 64 * 1024 * 1024
_USAGE_KEYS = (("input", "input_tokens"), ("output", "output_tokens"),
               ("cache_write", "cache_creation_input_tokens"), ("cache_read", "cache_read_input_tokens"))


def transcript_usage(f, seen, since="", cap=TRANSCRIPT_CAP, name=""):
    """Read a harness transcript (f: opened in binary mode) into `seen`:
    message id -> {'input', 'output', 'cache_write', 'cache_read'}, each a count
    or None when missing or not a count, for every message with a `usage`
    record stamped at or after `since`. A repeated id (a streamed message)
    keeps its last, complete figures; a record with no id is keyed by `name`
    and its line number. Only the last `cap` bytes are read: returns True when
    the file is larger than that."""
    size = os.fstat(f.fileno()).st_size
    partial = size > cap
    if partial:
        f.seek(size - cap)
        f.readline()
    for n, line in enumerate(f):
        if b'"usage"' not in line:
            continue
        try:
            d = json.loads(line)
            msg = d["message"]
            u = msg["usage"]
            if str(d.get("timestamp", ""))[:19] < since[:19]:
                continue
            figures = {key: as_count(u.get(src)) for key, src in _USAGE_KEYS}
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        seen[msg.get("id") or "%s:%d" % (name, n)] = figures
    return partial


def session_usage(path):
    """One session transcript as {'calls', 'cache_read', 'cache_write',
    'output', 'partial'}: a call is one message id, counted once with its last
    figures. None when `path` is not a usable transcript (an absolute path
    ending .jsonl that is a regular file, not a symlink) or cannot be read.
    This file only: no subagent transcripts."""
    if not isinstance(path, str) or not os.path.isabs(path) or not path.endswith(".jsonl"):
        return None
    seen = {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            partial = transcript_usage(f, seen, name=path)
    except OSError:
        return None
    out = {"calls": len(seen), "partial": partial}
    for key in ("cache_read", "cache_write", "output"):
        out[key] = sum(m[key] or 0 for m in seen.values())
    return out


def fmt_session(path):
    """The last line of the end-of-run report: the orchestrating session's own
    usage, or 'Orchestrator session: not available'."""
    usage = session_usage(path)
    if usage is None:
        return "Orchestrator session: not available"
    line = "Orchestrator session: %d calls, cache read %s, cache write %s, output %s" % (
        usage["calls"], fmt_num(usage["cache_read"]), fmt_num(usage["cache_write"]), fmt_num(usage["output"]))
    return line + (" (partial: transcript over 64 MB)" if usage["partial"] else "")
