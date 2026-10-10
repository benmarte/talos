#!/usr/bin/env bash
# update-timings.sh -- refresh tests/timings.txt, the per-file wall times that
# `run-tests.sh --shard i/n` balances CI shards on (#556), and that
# run-tests.sh uses to start the slowest files first.
#
# Usage: bash tests/update-timings.sh [-j N] [<run-tests.sh --timings log>]
#   With no log argument, runs the whole suite once (--no-cache --timings,
#   default -j 4 to mimic a 4-vCPU CI runner) and measures each file's wall
#   time; with a log, parses the "TIMINGS" block of an earlier run instead.
#
# tests/timings.txt: one "<secs> <basename>" line per tests/test-*.sh, sorted
# by name so a refresh diffs cleanly. Timings drift slowly; refresh when a
# shard's CI time visibly outgrows its siblings. A file that is missing from
# the table (a new test) still runs: it gets a fixed default weight.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS=4
if [ "${1:-}" = "-j" ]; then JOBS="$2"; shift 2; fi
LOG="${1:-}"
if [ -z "$LOG" ]; then
  LOG="$(mktemp "${TMPDIR:-/tmp}/talos-timings.XXXXXX")" || exit 1
  trap 'rm -f "$LOG"' EXIT
  bash "$ROOT/tests/run-tests.sh" --no-cache --quiet --timings -j "$JOBS" > "$LOG" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "update-timings: the suite failed (rc=$rc); timings of a red run are not recorded" >&2
    tail -n 20 "$LOG" >&2
    exit "$rc"
  fi
fi
OUT="$ROOT/tests/timings.txt"
{
  echo "# Per-file wall seconds (run-tests.sh --no-cache --timings -j $JOBS). Refresh: bash tests/update-timings.sh"
  sed -n '/^TIMINGS/,$p' "$LOG" | awk 'NR > 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^tests\/test-/ { sub("^tests/", "", $2); print $1, $2 }' \
    | LC_ALL=C sort -k2,2
} > "$OUT.new" && mv "$OUT.new" "$OUT"
echo "update-timings: wrote $(grep -vc '^#' "$OUT") entries to tests/timings.txt"
