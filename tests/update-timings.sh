#!/usr/bin/env bash
# update-timings.sh -- refresh tests/timings.txt, the per-file wall times that
# `run-tests.sh --shard i/n` balances CI shards on (#556), and that
# run-tests.sh uses to start the slowest files first.
#
# Usage: bash tests/update-timings.sh [-j N] [--check] [--shards N]
#                                     [--from-ci [<run-id>] | <run-tests.sh --timings log>]
#   With no source, runs the whole suite once (--no-cache --timings, default
#   -j 4 to mimic a 4-vCPU CI runner) and measures each file's wall time; with
#   a log, parses the "TIMINGS" block of an earlier run instead.
#   --from-ci [<run-id>]  read the shard logs of a `tests` workflow run through
#                       `gh run view <id> --log` (default: the latest successful
#                       push run on main), strip GitHub's per-line
#                       `job<TAB>step<TAB>timestamp ` prefix and merge the
#                       shards' TIMINGS blocks (#971). The 4-vCPU ubuntu runners
#                       are what the shards must balance on, not a many-core Mac.
#   --check             do not touch tests/timings.txt: write the refit to
#                       tests/timings.txt.new, print each shard's summed weight
#                       (the current `run-tests.sh --shard i/N` partition, with
#                       the newly measured times) and exit 1 when
#                       (max - min) / mean is over 0.15. The weekly
#                       .github/workflows/timings.yml runs `--from-ci --check`.
#   --shards N          shard count for --check (default 4, as in tests.yml).
#   A run without a TIMINGS block or a failed gh call exits 2 and leaves
#   tests/timings.txt as it was.
#
# tests/timings.txt: one "<secs> <basename>" line per tests/test-*.sh, sorted
# by name so a refresh diffs cleanly. A file the log does not mention keeps its
# current weight. Timings drift slowly; refresh when a shard's CI time visibly
# outgrows its siblings. A file that is missing from the table (a new test) still
# runs: it gets a fixed default weight, but
# tests/test-shard-weights.sh fails until the file has its own entry, so a new
# test file needs a line here: run this script and commit the result. The same
# test caps the heaviest shard's summed weight (SHARD_WEIGHT_BOUND): after a
# refresh, set it to the new heaviest shard rounded up by about 10%.
# A suite is too long for one foreground command (verify.timeout_ms 600000), so
# time it per shard (`run-tests.sh --no-cache --quiet --timings --shard i/n`)
# and pass the TIMINGS blocks as one log if a single run would pass the cap, or
# refit from CI with --from-ci.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS=4
SHARDS=4
CHECK=0
FROM_CI=0
RUN_ID=""
LOG=""
SPREAD_LIMIT_PCT=15   # --check fails when (max - min) / mean is over 0.15
DEFAULT_WEIGHT=8      # run-tests.sh DEFAULT_WEIGHT, for a file the table lacks

usage() { echo "usage: update-timings.sh [-j N] [--check] [--shards N] [--from-ci [<run-id>] | <log>]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -j) [ $# -ge 2 ] || usage; JOBS="$2"; shift 2 ;;
    --shards) [ $# -ge 2 ] || usage; SHARDS="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --from-ci)
      FROM_CI=1; shift
      case "${1:-}" in
        ''|-*) ;;
        *) RUN_ID="$1"; shift ;;
      esac
      ;;
    -h|--help) usage ;;
    -*) echo "update-timings: unknown option $1" >&2; usage ;;
    *) LOG="$1"; shift ;;
  esac
done
case "$SHARDS" in ''|*[!0-9]*|0) echo "update-timings: --shards needs a positive integer" >&2; exit 2 ;; esac
case "$RUN_ID" in *[!0-9]*) echo "update-timings: run id must be numeric, got '$RUN_ID'" >&2; exit 2 ;; esac
if [ "$FROM_CI" -eq 1 ] && [ -n "$LOG" ]; then
  echo "update-timings: --from-ci and a log file are two sources; pass one" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/talos-timings.XXXXXX")" || exit 1
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then echo "update-timings: no scratch dir" >&2; exit 1; fi
trap 'rm -rf "${WORK:?}"' EXIT

if [ "$FROM_CI" -eq 1 ]; then
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(cd "$ROOT" && gh run list --workflow tests.yml --branch main --event push --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')" || {
      echo "update-timings: gh run list failed; tests/timings.txt is unchanged" >&2
      exit 2
    }
    case "$RUN_ID" in
      ''|*[!0-9]*) echo "update-timings: no successful push run of tests.yml on main; tests/timings.txt is unchanged" >&2; exit 2 ;;
    esac
  fi
  (cd "$ROOT" && gh run view "$RUN_ID" --log) > "$WORK/raw.log" || {
    echo "update-timings: gh run view $RUN_ID --log failed; tests/timings.txt is unchanged" >&2
    exit 2
  }
  # `job<TAB>step<TAB>timestamp content` -> `content`; a line without the prefix stays as it is.
  sed $'s/^[^\t]*\t[^\t]*\t[^ ]* //' "$WORK/raw.log" > "$WORK/ci.log"
  LOG="$WORK/ci.log"
  SRC="CI run $RUN_ID"
elif [ -z "$LOG" ]; then
  LOG="$WORK/suite.log"
  bash "$ROOT/tests/run-tests.sh" --no-cache --quiet --timings -j "$JOBS" > "$LOG" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "update-timings: the suite failed (rc=$rc); timings of a red run are not recorded" >&2
    tail -n 20 "$LOG" >&2
    exit "$rc"
  fi
  SRC="a suite run"
else
  SRC="$LOG"
fi
if [ ! -r "$LOG" ]; then echo "update-timings: cannot read $LOG" >&2; exit 2; fi

# "<secs> <basename>" for each row of a TIMINGS block (blocks of several shards
# merge; a file in two blocks takes the last one; a "cached" row has no time).
awk '
  /^TIMINGS/ { inb = 1; next }
  inb && $1 ~ /^[0-9]+$/ && $2 ~ /^tests\/test-.*\.sh$/ { n = $2; sub("^tests/", "", n); print $1, n; next }
  inb && $1 == "cached" && $2 ~ /^tests\// { next }
  { inb = 0 }
' "$LOG" > "$WORK/rows.txt"
if [ ! -s "$WORK/rows.txt" ]; then
  echo "update-timings: no TIMINGS block in $SRC; tests/timings.txt is unchanged" >&2
  exit 2
fi

OUT="$ROOT/tests/timings.txt"
if [ "$FROM_CI" -eq 1 ]; then
  HEADER="# Per-file wall seconds (CI shard logs, run-tests.sh --no-cache --timings). Refresh: bash tests/update-timings.sh --from-ci"
else
  HEADER="# Per-file wall seconds (run-tests.sh --no-cache --timings -j $JOBS). Refresh: bash tests/update-timings.sh"
fi
{
  echo "$HEADER"
  for f in "$ROOT"/tests/test-*.sh; do
    [ -f "$f" ] && basename "$f"
  done | LC_ALL=C awk -v rows="$WORK/rows.txt" -v cur="$OUT" '
    BEGIN {
      while ((getline l < rows) > 0) { split(l, p, " "); m[p[2]] = p[1] }
      while ((getline l < cur) > 0) {
        if (l ~ /^[[:space:]]*#/ || l ~ /^[[:space:]]*$/) continue
        split(l, p, " ")
        if (p[1] ~ /^[0-9]+$/) c[p[2]] = p[1]
      }
    }
    { if ($0 in m) print m[$0], $0; else if ($0 in c) print c[$0], $0 }' \
    | LC_ALL=C sort -k2,2
} > "$OUT.new" || { rm -f "$OUT.new"; echo "update-timings: could not write $OUT.new" >&2; exit 1; }

if [ "$CHECK" -eq 0 ]; then
  mv "$OUT.new" "$OUT"
  echo "update-timings: wrote $(grep -vc '^#' "$OUT") entries to tests/timings.txt from $SRC"
  exit 0
fi

# --check: tests/timings.txt stays; the refit is left in tests/timings.txt.new.
# Each shard's members come from the current partition, its sum from the new weights.
echo "update-timings: refit from $SRC written to tests/timings.txt.new ($(grep -vc '^#' "$OUT.new") entries); tests/timings.txt is unchanged"
max=0
min=-1
total=0
i=1
while [ "$i" -le "$SHARDS" ]; do
  members="$(bash "$ROOT/tests/run-tests.sh" --shard "$i/$SHARDS" --list 2>/dev/null)" || {
    echo "update-timings: run-tests.sh --shard $i/$SHARDS --list failed" >&2
    exit 2
  }
  sum="$(awk -v tf="$OUT.new" -v dflt="$DEFAULT_WEIGHT" '
    BEGIN {
      while ((getline l < tf) > 0) {
        if (l ~ /^[[:space:]]*#/) continue
        split(l, p, " ")
        if (p[1] ~ /^[0-9]+$/) w[p[2]] = p[1] + 0
      }
    }
    NF { v = ($1 in w) ? w[$1] : dflt; if (v < 1) v = 1; s += v }
    END { print s + 0 }' <<<"$members")"
  echo "shard $i/$SHARDS: ${sum}s"
  [ "$sum" -gt "$max" ] && max="$sum"
  if [ "$min" -lt 0 ] || [ "$sum" -lt "$min" ]; then min="$sum"; fi
  total=$((total + sum))
  i=$((i + 1))
done
spread="$(awk -v mx="$max" -v mn="$min" -v t="$total" -v n="$SHARDS" 'BEGIN { if (t == 0) print "0.000"; else printf "%.3f", (mx - mn) * n / t }')"
# (max - min) / (total / n) > limit%, in integers so the 0.15 boundary is exact.
if [ $(( (max - min) * SHARDS * 100 )) -gt $(( SPREAD_LIMIT_PCT * total )) ]; then
  echo "update-timings: DRIFT: shard spread (max-min)/mean = $spread, over 0.15; refit with tests/timings.txt.new"
  exit 1
fi
echo "update-timings: shard spread (max-min)/mean = $spread, within 0.15"
exit 0
