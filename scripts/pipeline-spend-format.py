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
"""

import math

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
