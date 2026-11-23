"""talos_events.py -- the one reader of Talos's events log (#1019).

The events log (`<git common dir>/talos/events.jsonl`) is one JSON object per
line. Every program that scans it -- pipeline-events.sh, pipeline-hooks.sh,
pipeline-eval.sh, talos-map.py, talos-usage.py and the transcript reader in
pipeline-spend-format.py -- reads it through this module, so a malformed line
means the same thing everywhere: it is skipped, never an abort.

A consumer puts this directory on sys.path first (`python3 -I` ignores the
script's own directory, so it is explicit):

    sys.path.insert(0, scripts_dir)
    import talos_events

Stdlib only. Nothing here writes, runs a command or touches the network.
"""

import json
import math


def parse_line(line):
    """The JSON object on one line (str or bytes), or None when the line is
    blank, not valid JSON, truncated, or JSON that is not an object."""
    try:
        rec = json.loads(line)
    except (ValueError, TypeError):
        return None
    return rec if isinstance(rec, dict) else None


def read_events(path, *, since=None, issue=None, kinds=None, stats=None):
    """Yield the records of the log at `path`, oldest first (file order).

    A missing or unreadable log yields nothing. A blank line is ignored; any
    other line that is not a JSON object is skipped and counted in
    stats["skipped"] when a `stats` dict is passed (read it once the iteration
    has finished). Lines decode as UTF-8, an undecodable byte replaced.

    Filters, all optional and applied after a line parses:
      since  keep records whose `ts` is a string at or after this ISO prefix
             (`2026-06-01` or a full timestamp);
      issue  keep records whose `issue`, as text, equals str(issue);
      kinds  keep records whose `event` is one of these names.
    """
    if stats is not None:
        stats.setdefault("skipped", 0)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                rec = parse_line(line)
                if rec is None:
                    if stats is not None:
                        stats["skipped"] += 1
                    continue
                if since is not None:
                    ts = rec.get("ts")
                    if not isinstance(ts, str) or ts < since:
                        continue
                if issue is not None and str(rec.get("issue")) != str(issue):
                    continue
                if kinds is not None and rec.get("event") not in kinds:
                    continue
                yield rec
    except OSError:
        return


def num(v):
    """v when it is an int that is not a bool, else None."""
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def digits(v):
    """The int a string of ASCII digits spells, else None."""
    return int(v) if v and isinstance(v, str) and v.isascii() and v.isdigit() else None


def number(v):
    """v when it is a finite non-negative number, else None (unrecorded): a
    string, bool, negative, Infinity or NaN is not a recorded figure. The value
    stays as recorded, an int an int and a float a float."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        return None
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return v


def as_count(v):
    """A recorded non-negative finite number as an int, or None."""
    v = number(v)
    return None if v is None else int(v)


def tokens_of(rec):
    """The record's `tokens` as a recorded number, or None."""
    return number(rec.get("tokens"))
