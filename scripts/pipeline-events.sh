#!/usr/bin/env bash
# pipeline-events.sh — reader for the local .talos/events.jsonl audit log
# that scripts/pipeline-hooks.sh's post_stage verb appends to (#183). See
# pipeline-hooks.sh for the payload schema and the events.enabled/events.path
# config keys.
#
# Usage: pipeline-events.sh path
#        pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
#        pipeline-events.sh tail [--issue N]
#        pipeline-events.sh cost [--issue N] [--pr M] [--json]
#        pipeline-events.sh cost --issue N [--pr M] --line
#
#   path   Prints the resolved absolute path to the events log (does not
#          require the file to exist).
#   list   Prints matching events, oldest first. Default output is a compact
#          one-line-per-event table (ts, event, role, issue, pr, verdict,
#          summary truncated to 80 chars); --json prints one JSON object per
#          line instead (a filtered subset of the raw log, still one line
#          per event). --issue/--role/--event filter by exact match;
#          --last K keeps only the last K matching events.
#   tail   Shorthand for `list --last 20`, optionally scoped to --issue.
#   cost   Per-issue, per-role cost summary (#202): sums tokens, tool_uses
#          and duration_s, and counts events, grouped by (issue, role).
#          A row's tokens/tool_uses/duration_s are summed treating a null
#          value as 0; the `unrecorded` column instead counts how many of that
#          group's events had a null tokens field (e.g. adapter-path runs,
#          which record duration only, per #202's proposal), so a group
#          made entirely of untracked events is visible rather than
#          silently reading as a real zero. The `restamp` column (#258)
#          counts events with verdict RESTAMP_PASS or RESTAMP_FAIL -- a
#          cheap delta re-review of a PR the same role already approved,
#          separate from that group's full-stage events/tokens totals.
#          Ends with a TOTAL row. Default output is a compact table (issue,
#          role, events, tokens, tool_uses, duration_s, unrecorded, restamp);
#          --json prints the same data as one JSON object:
#          {"rows": [...], "total": {...}}. --issue filters to
#          one issue.
#          ci_runs (#332): when at least one matched event carries a ci_runs
#          value (post_stage --ci-runs, recorded on the merged event), the
#          table gains a trailing ci_runs column and every --json row and the
#          total gain a trailing ci_runs field, summing those values. With no
#          such event the output is exactly the shape described above.
#          --pr M keeps only events whose pr is M (an event with pr null never
#          matches), in the table, --json and --line alike.
#          --line (needs --issue; wins over --json) prints one summary line
#          for the issue (#380), from the newest non-orchestrator event in
#          scope (last in file order), identically on every runner path:
#            talos: #764 security done — 56k tokens, 14 tools, 2m05s · PR total 3.41M (dev 1.57M, adv 596k, ...)
#          The reference is #<pr> with --pr (label `PR total`), else
#          #<issue> (label `issue total`). Events with role orchestrator are
#          left out of the stage, the totals and the unrecorded count. A null
#          tokens/tool_uses/duration_s is never printed as 0: the newest
#          event reads `tokens unrecorded`, a null tool count or duration is
#          dropped, `(+K unrecorded)` follows the total, and a scope with no
#          recorded tokens prints `total unrecorded`. The breakdown is sorted
#          by tokens descending and cut with `…` so the line stays <= 200
#          characters. Missing log or no matching events prints nothing.
#          A value-taking option with no value exits 2 with usage.
#
# A malformed line (not valid JSON, or not a JSON object) is skipped rather
# than aborting the read; the count of skipped lines is reported once on
# stderr, never on stdout.
#
# Never errors when the log is missing or empty -- prints nothing (list/tail)
# or an empty result, and always exits 0, except for the usage error below.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
fi

# _events_log_path -> prints the absolute path to the events log, or nothing
# (rc 1) if it can't be resolved. Mirrors pipeline-hooks.sh's
# _events_log_path exactly (same resolution, same events.path default) --
# see that copy's comment for why --git-common-dir (not --git-dir) is used.
_events_log_path() {
  local common_dir root path_cfg
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common_dir" ] || return 1
  case "$common_dir" in
    /*) : ;;
    *) common_dir="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)/$(basename "$common_dir")" ;;
  esac
  [ -n "$common_dir" ] || return 1
  root="$(dirname "$common_dir")"

  path_cfg="$(cfg events.path ".talos/events.jsonl")"
  case "$path_cfg" in
    /*) printf '%s' "$path_cfg" ;;
    *) printf '%s/%s' "$root" "$path_cfg" ;;
  esac
}

cmd_path() {
  local log_path
  log_path="$(_events_log_path)"
  if [ -z "$log_path" ]; then
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  fi
  printf '%s\n' "$log_path"
}

# cmd_list ISSUE ROLE EVENT LAST JSON_MODE
cmd_list() {
  local issue="$1" role="$2" event="$3" last="$4" json_mode="$5"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  python3 - "$log_path" "$issue" "$role" "$event" "$last" "$json_mode" <<'PYEOF'
import json
import sys

log_path, issue, role, event, last, json_mode = sys.argv[1:7]

def matches(rec):
    if issue and str(rec.get("issue")) != issue:
        return False
    if role and rec.get("role") != role:
        return False
    if event and rec.get("event") != event:
        return False
    return True

records = []
skipped = 0
with open(log_path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        if matches(rec):
            records.append(rec)

if last:
    try:
        n = int(last)
        if n > 0:
            records = records[-n:]
    except ValueError:
        pass

for rec in records:
    if json_mode == "1":
        print(json.dumps(rec))
    else:
        summary = (rec.get("summary") or "")[:80]

        def _s(v):
            return "" if v is None else str(v)

        print("\t".join(_s(x) for x in [
            rec.get("ts"),
            rec.get("event"),
            rec.get("role"),
            rec.get("issue"),
            rec.get("pr"),
            rec.get("verdict"),
            summary,
        ]))

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
PYEOF
}

# cmd_cost ISSUE JSON_MODE -- per-(issue, role) cost summary (#202, #258,
# #259): sums tokens, tool_uses, duration_s and counts events, treating a
# null numeric field as 0 for the sum but tallying it separately in the
# unrecorded column (a group where every event is unrecorded is still
# visible as "no data", not a real zero -- e.g. adapter-path runs that
# record duration only, per #202, or a non-worktree-spawned stage whose
# harness never reports usage, per #259). The "restamp" column (#258)
# separately counts events whose verdict is RESTAMP_PASS or RESTAMP_FAIL --
# a cheap delta re-review of a PR the same role already approved (see
# skills/pipeline/SKILL.md's re-stamp dispatch) -- so a group's re-stamp
# cost is visible next to its full-stage cost instead of being folded into
# the same "events"/"tokens" totals with no way to tell them apart.
# PR (#380) keeps only events whose pr matches; "" means every event.
cmd_cost() {
  local issue="$1" json_mode="$2" pr="${3:-}"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  python3 - "$log_path" "$issue" "$json_mode" "$pr" <<'PYEOF'
import json
import sys

log_path, issue, json_mode, pr = sys.argv[1:5]

def matches(rec):
    if issue and str(rec.get("issue")) != issue:
        return False
    if pr and (rec.get("pr") is None or str(rec.get("pr")) != pr):
        return False
    return True

groups = {}
order = []
skipped = 0
have_ci_runs = False
with open(log_path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        if not matches(rec):
            continue
        key = (rec.get("issue"), rec.get("role"))
        if key not in groups:
            groups[key] = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "ci_runs": 0}
            order.append(key)
        g = groups[key]
        g["events"] += 1
        g["tokens"] += rec.get("tokens") or 0
        g["tool_uses"] += rec.get("tool_uses") or 0
        g["duration_s"] += rec.get("duration_s") or 0
        if rec.get("tokens") is None:
            g["unrecorded"] += 1
        if rec.get("verdict") in ("RESTAMP_PASS", "RESTAMP_FAIL"):
            g["restamp"] += 1
        ci_runs = rec.get("ci_runs")
        if type(ci_runs) is int and ci_runs >= 0:
            have_ci_runs = True
            g["ci_runs"] += ci_runs

order.sort(key=lambda k: (str(k[0]), str(k[1])))

rows = []
total = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "ci_runs": 0}
for key in order:
    g = groups[key]
    if not have_ci_runs:
        g.pop("ci_runs")
    rows.append({"issue": key[0], "role": key[1], **g})
    for field in g:
        total[field] += g[field]

if not have_ci_runs:
    total.pop("ci_runs")

if json_mode == "1":
    print(json.dumps({"rows": rows, "total": total}))
else:
    def _s(v):
        return "" if v is None else str(v)

    extra = ["ci_runs"] if have_ci_runs else []
    print("	".join(["issue", "role", "events", "tokens", "tool_uses", "duration_s", "unrecorded", "restamp"] + extra))
    for row in rows:
        print("	".join(_s(x) for x in [
            row["issue"], row["role"], row["events"], row["tokens"],
            row["tool_uses"], row["duration_s"], row["unrecorded"], row["restamp"],
        ] + [row[f] for f in extra]))
    print("	".join(_s(x) for x in [
        "TOTAL", "", total["events"], total["tokens"],
        total["tool_uses"], total["duration_s"], total["unrecorded"], total["restamp"],
    ] + [total[f] for f in extra]))

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
PYEOF
}

# Python formatters for the one-line spend summary (#380), kept as one source
# so a later command that prints a spend figure can prepend it to its own
# python block instead of copying it: fmt_num (tokens), fmt_dur (seconds),
# role_label / role_abbrev (head word and breakdown), as_count (null-safe
# number). Integer arithmetic only: round half up, never round() (banker's)
# or '%.2f' (float artefacts).
IFS= read -r -d '' _EVENTS_PY_FORMAT <<'PYEOF' || true
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
    """A recorded non-negative number, or None (null and junk are unrecorded)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        return None
    return int(v)
PYEOF

# cmd_cost_line ISSUE PR -- one summary line (#380): the newest
# non-orchestrator event in scope (last in file order, since ts has only
# second resolution) plus the scope's total and per-role breakdown. See the
# file header for the exact shape. Prints nothing when the log is missing or
# no event is in scope.
cmd_cost_line() {
  local issue="$1" pr="$2"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  local src
  IFS= read -r -d '' src <<'PYEOF' || true

MAX_LEN = 200

log_path, issue, pr = sys.argv[1:4]
sys.stdout.reconfigure(encoding="utf-8")

newest = None
recorded = {}
unrecorded = 0
total = 0
skipped = 0
with open(log_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        if str(rec.get("issue")) != issue:
            continue
        if pr and (rec.get("pr") is None or str(rec.get("pr")) != pr):
            continue
        if rec.get("role") == "orchestrator":
            continue
        newest = rec
        tokens = as_count(rec.get("tokens"))
        if tokens is None:
            unrecorded += 1
        else:
            total += tokens
            label = role_label(rec.get("role"))
            recorded[label] = recorded.get(label, 0) + tokens

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
if newest is None:
    sys.exit(0)

parts = []
tokens = as_count(newest.get("tokens"))
parts.append("tokens unrecorded" if tokens is None else "%s tokens" % fmt_num(tokens))
tools = as_count(newest.get("tool_uses"))
if tools is not None:
    parts.append("%d tools" % tools)
dur = as_count(newest.get("duration_s"))
if dur is not None:
    parts.append(fmt_dur(dur))

head = "talos: #%s %s done — %s · %s total" % (
    pr or issue, role_label(newest.get("role")), ", ".join(parts),
    "PR" if pr else "issue")

if not recorded:
    print(head + " unrecorded")
    sys.exit(0)

head += " " + fmt_num(total)
if unrecorded:
    head += " (+%d unrecorded)" % unrecorded
ordered = sorted(recorded.items(), key=lambda kv: -kv[1])  # stable: ties keep first-seen order
entries = ["%s %s" % (role_abbrev(r), fmt_num(n)) for r, n in ordered]
out = head + " (" + ", ".join(entries) + ")"
if len(out) > MAX_LEN:
    keep = len(entries)
    while keep > 0 and len(head + " (" + ", ".join(entries[:keep]) + ", …)") > MAX_LEN:
        keep -= 1
    out = head + " (" + "".join(e + ", " for e in entries[:keep]) + "…)"
    if len(out) > MAX_LEN:  # only a pathological role name gets here
        out = out[:MAX_LEN - 1] + "…"
print(out)
PYEOF

  python3 -c "import json, sys
$_EVENTS_PY_FORMAT
$src" "$log_path" "$issue" "$pr"
}

# _usage -- the usage text, shared by the unknown-verb and bad-option exits.
_usage() {
  echo "Usage: pipeline-events.sh path" >&2
  echo "       pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]" >&2
  echo "       pipeline-events.sh tail [--issue N]" >&2
  echo "       pipeline-events.sh cost [--issue N] [--pr M] [--json]" >&2
  echo "       pipeline-events.sh cost --issue N [--pr M] --line" >&2
}

# _need_value OPTION ARGC -- exit 2 with usage when a value-taking option is
# the last argument (`shift 2` with one argument left shifts nothing, which
# used to loop forever).
_need_value() {
  if [ "$2" -lt 2 ]; then
    echo "pipeline-events: $1 needs a value" >&2
    _usage
    exit 2
  fi
}

VERB="${1:-}"
case "$VERB" in
  path)
    cmd_path
    ;;
  list)
    shift
    issue="" role="" event="" last="" json_mode="0"
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) issue="${2:-}"; shift 2 ;;
        --role) role="${2:-}"; shift 2 ;;
        --event) event="${2:-}"; shift 2 ;;
        --last) last="${2:-}"; shift 2 ;;
        --json) json_mode="1"; shift ;;
        *) shift ;;
      esac
    done
    cmd_list "$issue" "$role" "$event" "$last" "$json_mode"
    ;;
  tail)
    shift
    issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) issue="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    cmd_list "$issue" "" "" "20" "0"
    ;;
  cost)
    shift
    issue="" pr="" json_mode="0" line_mode="0"
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) _need_value "$1" $#; issue="$2"; shift 2 ;;
        --pr) _need_value "$1" $#; pr="$2"; shift 2 ;;
        --json) json_mode="1"; shift ;;
        --line) line_mode="1"; shift ;;
        *) shift ;;
      esac
    done
    if [ "$line_mode" = "1" ]; then
      if [ -z "$issue" ]; then
        echo "pipeline-events: --line needs --issue" >&2
        _usage
        exit 2
      fi
      cmd_cost_line "$issue" "$pr"
    else
      cmd_cost "$issue" "$json_mode" "$pr"
    fi
    ;;
  *)
    _usage
    exit 2
    ;;
esac
