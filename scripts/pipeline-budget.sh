#!/usr/bin/env bash
# pipeline-budget.sh — the opt-in per-issue token guard (#382, part of #334).
# Answers "may Talos start another fix round on issue N?" from the local
# .talos/events.jsonl audit log and the limits.* config keys.
#
# Usage: pipeline-budget.sh check --issue N [--json]
#
#   check  Prints one line and exits:
#            talos:budget <ok|warn|exceeded> issue=N used=<int> limit=<L> \
#                         effective=<E> pct=<int> unrecorded=<K>
#          or, when there is nothing to judge,
#            talos:budget unknown issue=N reason=<no-events|events-unavailable>
#          --json prints the same fields as one object ({"status": ..., "issue":
#          ..., "used": ..., "limit": ..., "effective": ..., "pct": ...,
#          "unrecorded": ...}; unknown carries "status", "issue", "reason").
#
# Exit codes: 0 ok / warn / unknown (and the guard being off), 1 exceeded,
# 2 usage. Exit 1 IS the signal, so a `set -e` caller must capture it
# (`out=$(... check --issue N) || rc=$?`, or use if/case) and never run the
# call bare. This script itself uses `set -u` only, not `set -e`.
#
# Guard off: with limits.tokens_per_issue unset, 0 or invalid the script prints
# nothing and exits 0 BEFORE touching the events log -- a complete no-op. A
# value above 10^15 is out of range and treated as off, with one warning
# (the arithmetic below is Python's, but a sane cap keeps the line readable and
# the value meaningful as a token count).
#
# Numbers:
#   used       tokens recorded for N, summed from `pipeline-events.sh cost
#              --issue N --json` (a null token field counts as nothing).
#   grants     the number of `budget-blocked` events for N (`pipeline-events.sh
#              list --issue N --event budget-blocked --json`): the owner gives
#              OK by removing pipeline:blocked and each earlier block grants one
#              more full limit.
#   effective  limit * (1 + grants).
#   warn       used >= warn_at * effective (limits.warn_at, default 0.8,
#              parsed numerically: it prints as 1.0 or 1e-05; outside
#              0 < x <= 1 falls back to 0.8). exceeded: used >= effective.
#   pct        floor(used * 100 / effective), an integer.
#   unrecorded events for N whose tokens field is null, counted from the
#              `cost` rows with role `orchestrator` excluded: the
#              `budget-blocked` marker (role orchestrator, tokens null) is not a
#              stage run, so it is neither an event nor unrecorded here.
#
# Missing data never blocks: no log, no events for N (a lone budget-blocked
# marker is no events), or a failing/empty events tool all give `unknown` and
# exit 0. Read-only: never writes the log, never calls pipeline-vcs.sh. The
# log location is resolved by pipeline-events.sh, never here.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
fi

usage() {
  echo "Usage: pipeline-budget.sh check --issue N [--json]" >&2
  exit 2
}

[ "${1:-}" = "check" ] || usage
shift
issue="" json_mode="0" have_issue=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] || usage
      issue="$2"; have_issue=1; shift 2 ;;
    --json) json_mode="1"; shift ;;
    *) usage ;;
  esac
done
[ "$have_issue" = 1 ] || usage
# An empty or non-numeric N would make `cost` match every issue (or swallow the
# next flag), so reject it before anything else runs.
case "$issue" in
  ''|*[!0-9]*) echo "pipeline-budget: --issue must be a number -- got: '$issue'" >&2; exit 2 ;;
esac
# pipeline-events.sh compares str(issue), so 007 must become 7.
issue="$(printf '%s' "$issue" | sed 's/^0*//')"
[ -n "$issue" ] || issue="0"

# ── Guard off? Decide from config alone, before reading any log ─────────────
limit="$(cfg limits.tokens_per_issue "")"
case "$limit" in
  ''|*[!0-9]*) exit 0 ;;   # unset, 0 -> unset, or invalid (config already warned)
esac
limit="$(printf '%s' "$limit" | sed 's/^0*//')"
[ -n "$limit" ] || exit 0
# Cap at 10^15: 15 digits or fewer, or exactly 10^15.
if [ "${#limit}" -gt 16 ] || { [ "${#limit}" -eq 16 ] && [ "$limit" != "1000000000000000" ]; }; then
  echo "pipeline-budget: limits.tokens_per_issue is out of range (above 10^15 tokens) -- treating the guard as off" >&2
  exit 0
fi
warn_at="$(cfg limits.warn_at "0.8")"

# ── Read the events (read-only, through pipeline-events.sh) ─────────────────
cost_out="" blocked_out="" tool_ok=1
cost_out="$(bash "$SCRIPT_DIR/pipeline-events.sh" cost --issue "$issue" --json 2>/dev/null)" || tool_ok=0
blocked_out="$(bash "$SCRIPT_DIR/pipeline-events.sh" list --issue "$issue" --event budget-blocked --json 2>/dev/null)" || tool_ok=0

python3 -I - "$issue" "$limit" "$warn_at" "$json_mode" "$tool_ok" "$cost_out" "$blocked_out" <<'PYEOF'
import json
import sys
from fractions import Fraction

issue, limit, warn_at, json_mode, tool_ok, cost_out, blocked_out = sys.argv[1:8]
issue = int(issue)
limit = int(limit)


def emit(status, fields, rc):
    if json_mode == "1":
        print(json.dumps(dict([("status", status), ("issue", issue)] + fields)))
    else:
        print("talos:budget %s issue=%d%s" % (
            status, issue, "".join(" %s=%s" % kv for kv in fields)))
    sys.exit(rc)


def unknown(reason):
    emit("unknown", [("reason", reason)], 0)


if tool_ok != "1":
    unknown("events-unavailable")

try:
    cost = json.loads(cost_out) if cost_out.strip() else None
except ValueError:
    cost = None
rows = cost.get("rows") if isinstance(cost, dict) else None
if not isinstance(rows, list):
    unknown("no-events")

used = 0
events = 0
unrecorded = 0
for row in rows:
    if not isinstance(row, dict):
        continue
    tokens = row.get("tokens")
    if isinstance(tokens, int) and not isinstance(tokens, bool):
        used += tokens
    if row.get("role") == "orchestrator":
        continue  # budget-blocked markers are not stage runs
    events += int(row.get("events") or 0)
    unrecorded += int(row.get("unrecorded") or 0)
if events == 0:
    unknown("no-events")

grants = 0
for line in blocked_out.splitlines():
    if line.strip():
        grants += 1
effective = limit * (1 + grants)

try:
    threshold = float(warn_at)
    if not (0 < threshold <= 1):
        raise ValueError
except ValueError:
    threshold = 0.8
# Fraction(repr(float)) keeps an exact threshold exact (0.8 -> 4/5).
warn_line = Fraction(repr(threshold)) * effective

if used >= effective:
    status, rc = "exceeded", 1
elif used >= warn_line:
    status, rc = "warn", 0
else:
    status, rc = "ok", 0
emit(status, [("used", used), ("limit", limit), ("effective", effective),
              ("pct", used * 100 // effective), ("unrecorded", unrecorded)], rc)
PYEOF
rc=$?
# Exit 1 (exceeded) passes through; anything else unexpected (a Python crash)
# must not block -- missing data never blocks.
[ "$rc" -eq 1 ] && exit 1
exit 0
