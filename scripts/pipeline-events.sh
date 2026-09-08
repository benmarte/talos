#!/usr/bin/env bash
# pipeline-events.sh — reader for the local .talos/events.jsonl audit log
# that scripts/pipeline-hooks.sh's post_stage verb appends to (#183). See
# pipeline-hooks.sh for the payload schema and the events.enabled/events.path
# config keys.
#
# Usage: pipeline-events.sh path
#        pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
#        pipeline-events.sh tail [--issue N]
#        pipeline-events.sh cost [--issue N] [--json]
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
#          value as 0; the `n/a` column instead counts how many of that
#          group's events had a null tokens field (e.g. adapter-path runs,
#          which record duration only, per #202's proposal), so a group
#          made entirely of untracked events is visible rather than
#          silently reading as a real zero. Ends with a TOTAL row. Default
#          output is a compact table (issue, role, events, tokens,
#          tool_uses, duration_s, n/a); --json prints the same data as one
#          JSON object: {"rows": [...], "total": {...}}. --issue filters to
#          one issue.
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

# cmd_cost ISSUE JSON_MODE -- per-(issue, role) cost summary (#202): sums
# tokens, tool_uses, duration_s and counts events, treating a null numeric
# field as 0 for the sum but tallying it separately in the n/a column (a
# group where every event is n/a is still visible as "no data", not a real
# zero -- e.g. adapter-path runs that record duration only, per #202).
cmd_cost() {
  local issue="$1" json_mode="$2"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  python3 - "$log_path" "$issue" "$json_mode" <<'PYEOF'
import json
import sys

log_path, issue, json_mode = sys.argv[1:4]

def matches(rec):
    if issue and str(rec.get("issue")) != issue:
        return False
    return True

groups = {}
order = []
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
        if not matches(rec):
            continue
        key = (rec.get("issue"), rec.get("role"))
        if key not in groups:
            groups[key] = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "n_a": 0}
            order.append(key)
        g = groups[key]
        g["events"] += 1
        g["tokens"] += rec.get("tokens") or 0
        g["tool_uses"] += rec.get("tool_uses") or 0
        g["duration_s"] += rec.get("duration_s") or 0
        if rec.get("tokens") is None:
            g["n_a"] += 1

order.sort(key=lambda k: (str(k[0]), str(k[1])))

rows = []
total = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "n_a": 0}
for key in order:
    g = groups[key]
    rows.append({"issue": key[0], "role": key[1], **g})
    for field in total:
        total[field] += g[field]

if json_mode == "1":
    print(json.dumps({"rows": rows, "total": total}))
else:
    def _s(v):
        return "" if v is None else str(v)

    print("	".join(["issue", "role", "events", "tokens", "tool_uses", "duration_s", "n/a"]))
    for row in rows:
        print("	".join(_s(x) for x in [
            row["issue"], row["role"], row["events"], row["tokens"],
            row["tool_uses"], row["duration_s"], row["n_a"],
        ]))
    print("	".join(_s(x) for x in [
        "TOTAL", "", total["events"], total["tokens"],
        total["tool_uses"], total["duration_s"], total["n_a"],
    ]))

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
PYEOF
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
    issue="" json_mode="0"
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) issue="${2:-}"; shift 2 ;;
        --json) json_mode="1"; shift ;;
        *) shift ;;
      esac
    done
    cmd_cost "$issue" "$json_mode"
    ;;
  *)
    echo "Usage: pipeline-events.sh path" >&2
    echo "       pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]" >&2
    echo "       pipeline-events.sh tail [--issue N]" >&2
    echo "       pipeline-events.sh cost [--issue N] [--json]" >&2
    exit 2
    ;;
esac
