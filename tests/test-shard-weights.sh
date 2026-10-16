#!/usr/bin/env bash
# test-shard-weights.sh -- tests/timings.txt keeps the verify shards balanced by
# real durations (#690).
#
# `run-tests.sh --shard i/n` splits the suite on tests/timings.txt weights. A
# test file with no entry there falls back to DEFAULT_WEIGHT, so the partition
# can look balanced while one shard runs for minutes longer than its siblings
# (and passes the 600 s foreground cap on verify.timeout_ms). Two guards:
#   AC1 every tests/test-*.sh has a numeric entry in tests/timings.txt;
#   AC2 the heaviest shard, by summed weight, stays under SHARD_WEIGHT_BOUND for
#       the shard count that talos.pipeline.json verify.commands uses.
# Refresh the table with `bash tests/update-timings.sh`; then set the bound to
# the new heaviest shard rounded up by about 10%.
#
# It reads the table and the file list; it does not run the suite.
set -u
. "$(dirname "$0")/helpers.sh"

# Summed table seconds (per-file times, not shard wall time). About 10% over the
# heaviest shard (1354) of the table refreshed in #690.
SHARD_WEIGHT_BOUND=1500

TIMINGS="$TALOS_ROOT/tests/timings.txt"
REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# ── AC1: every test file has a numeric entry ─────────────────────────────────
missing=""
count=0
for f in "$TALOS_ROOT"/tests/test-*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  count=$((count + 1))
  if ! awk -v n="$name" '$1 ~ /^[0-9]+$/ && $2 == n { found = 1 } END { exit !found }' "$TIMINGS"; then
    missing="$missing $name"
  fi
done
if [ -z "$missing" ]; then
  pass "AC1 every one of the $count tests/test-*.sh has a numeric entry in tests/timings.txt"
else
  fail "AC1 every tests/test-*.sh has a numeric entry in tests/timings.txt" \
    "missing (run bash tests/update-timings.sh):$(printf '%s' "$missing" | cut -c1-400)"
fi

# ── AC2: the heaviest shard stays under the bound ────────────────────────────
n="$(grep -o -e '--shard [0-9]*/[0-9]*' "$TALOS_ROOT/talos.pipeline.json" | sed 's|.*/||' | sort -u)"
case "$n" in
  ''|*[!0-9]*) fail "AC2 talos.pipeline.json verify.commands names one shard count" "got: '$n'" ;;
  *)
    max=0
    i=1
    while [ "$i" -le "$n" ]; do
      sum=0
      list="$(bash "$REAL_RUN_TESTS" --shard "$i/$n" --list 2>/dev/null)"
      for f in $list; do
        w="$(awk -v f="$f" '$1 ~ /^[0-9]+$/ && $2 == f { print $1; exit }' "$TIMINGS")"
        w="${w:-8}"            # DEFAULT_WEIGHT of run-tests.sh
        [ "$w" -lt 1 ] && w=1  # its weight floor
        sum=$((sum + w))
      done
      [ "$sum" -gt "$max" ] && max="$sum"
      i=$((i + 1))
    done
    if [ "$max" -lt "$SHARD_WEIGHT_BOUND" ]; then
      pass "AC2 the heaviest of $n shards weighs ${max}s, under the ${SHARD_WEIGHT_BOUND}s bound"
    else
      fail "AC2 the heaviest of $n shards stays under ${SHARD_WEIGHT_BOUND}s" \
        "heaviest shard weighs ${max}s; refresh tests/timings.txt (bash tests/update-timings.sh) or raise the bound with the new table"
    fi
    ;;
esac

finish
