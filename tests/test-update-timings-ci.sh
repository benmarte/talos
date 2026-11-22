#!/usr/bin/env bash
# test-update-timings-ci.sh -- tests/update-timings.sh refits tests/timings.txt from CI logs
# (--from-ci) and finds drift between the shards (--check), and the weekly
# .github/workflows/timings.yml runs that check (#971).
#
# The fixture is a tiny tests/ tree (the real update-timings.sh and run-tests.sh,
# eight fake test files) with a stub `gh` on PATH, so nothing touches the network
# and the repo's own tests/timings.txt is never written.
#
# Current table of the fixture, so `run-tests.sh --shard i/4` (greedy, heaviest
# first, ties by name) puts a+e in shard 1, b+f in 2, c+g in 3, d+h in 4.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

FX="$SANDBOX/fx"
GHBIN="$SANDBOX/ghbin"
GHLOG="$SANDBOX/gh.log"
WORKFLOW="$TALOS_ROOT/.github/workflows/timings.yml"
mkdir -p "$FX/tests" "$GHBIN"
cp "$TALOS_ROOT/tests/update-timings.sh" "$TALOS_ROOT/tests/run-tests.sh" "$FX/tests/"
for n in a b c d e f g h; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/tests/test-$n.sh"
done

cat > "$GHBIN/gh" <<'TALOS_Zq3Kd8WmPv2Lx'
#!/usr/bin/env bash
# gh stub: `run list` prints $STUB_RUN_ID; `run view <id> --log` prints $STUB_LOG.
# STUB_LIST_RC / STUB_VIEW_RC make that call exit non-zero.
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
  [ "${STUB_LIST_RC:-0}" -ne 0 ] && { echo "gh: list failed" >&2; exit "$STUB_LIST_RC"; }
  printf '%s\n' "${STUB_RUN_ID:-777}"
  exit 0
fi
if [ "${1:-}" = run ] && [ "${2:-}" = view ]; then
  [ "${STUB_VIEW_RC:-0}" -ne 0 ] && { echo "gh: view failed" >&2; exit "$STUB_VIEW_RC"; }
  cat "$STUB_LOG"
  exit 0
fi
echo "gh stub: unexpected call: $*" >&2
exit 9
TALOS_Zq3Kd8WmPv2Lx
chmod +x "$GHBIN/gh"
export GH_LOG="$GHLOG"
export PATH="$GHBIN:$PATH"

# write_table <a-weight> <h-weight>: the fixture's current tests/timings.txt.
write_table() {
  printf '# fixture\n%s test-a.sh\n10 test-b.sh\n10 test-c.sh\n10 test-d.sh\n1 test-e.sh\n1 test-f.sh\n1 test-g.sh\n%s test-h.sh\n' "$1" "$2" > "$FX/tests/timings.txt"
}

# emit_job <job> <secs> <name> ...: one shard's log in GitHub's `gh run view --log`
# shape, job<TAB>step<TAB>timestamp<space>content, noise lines around a TIMINGS block.
emit_job() {
  _job="$1"; shift
  _p="$(printf '%s\tRun test shard\t2026-11-22T10:00:00.0000000Z ' "$_job")"
  printf '%sSHARD 1/4: 2 test file(s)\n' "$_p"
  printf '%sRESULT: all passed\n' "$_p"
  printf '%sTIMINGS (seconds, slowest first):\n' "$_p"
  while [ "$#" -ge 2 ]; do
    printf '%s%6s  tests/%s\n' "$_p" "$1" "$2"
    shift 2
  done
  printf '%s\xef\xbb\xbfPost job cleanup.\n' "$_p"
}

# make_log <a> <b> <c> <d>: the four shard blocks; e..h weigh 2. h is left out when HIDE_H=1.
make_log() {
  {
    emit_job "test (ubuntu-latest) shard 1/4" "$1" test-a.sh 2 test-e.sh
    emit_job "test (ubuntu-latest) shard 2/4" "$2" test-b.sh 2 test-f.sh
    emit_job "test (ubuntu-latest) shard 3/4" "$3" test-c.sh 2 test-g.sh
    if [ "${HIDE_H:-0}" = 1 ]; then
      emit_job "test (ubuntu-latest) shard 4/4" "$4" test-d.sh
    else
      emit_job "test (ubuntu-latest) shard 4/4" "$4" test-d.sh 2 test-h.sh
    fi
  } > "$SANDBOX/ci.log"
}

run_ut() {  # run the fixture's update-timings.sh; sets OUT and RC
  OUT="$(cd "$FX" && STUB_LOG="$SANDBOX/ci.log" bash tests/update-timings.sh "$@" 2>&1)"
  RC=$?
}

table_body() { grep -v '^#' "$FX/tests/timings.txt"; }

# ── AC1: --from-ci merges the prefixed shard blocks, sorted by name ──────────
write_table 10 7
make_log 20 18 17 17
HIDE_H=0
run_ut --from-ci 123
assert_exit_code 0 "$RC" "AC1 --from-ci with a run id exits 0 ($OUT)"
expected="20 test-a.sh
18 test-b.sh
17 test-c.sh
17 test-d.sh
2 test-e.sh
2 test-f.sh
2 test-g.sh
2 test-h.sh"
assert_eq "$expected" "$(table_body)" "AC1 tests/timings.txt holds the merged TIMINGS weights of all four shards, sorted by name"
assert_contains "$(cat "$GHLOG")" "run view 123" "AC1 --from-ci <id> reads that run's log through gh run view"
assert_contains "$(cat "$GHLOG")" "--log" "AC1 the log comes from gh run view --log"

: > "$GHLOG"
write_table 10 7
run_ut --from-ci
assert_exit_code 0 "$RC" "AC1 --from-ci without an id exits 0 ($OUT)"
assert_contains "$(cat "$GHLOG")" "run list" "AC1 without an id the run is looked up with gh run list"
assert_contains "$(cat "$GHLOG")" "main" "AC1 the lookup is for the main branch"
assert_contains "$(cat "$GHLOG")" "success" "AC1 the lookup is for a successful run"
assert_contains "$(cat "$GHLOG")" "run view 777" "AC1 the log read is that of the run gh run list returned"

# ── AC2: a file missing from every block keeps its current weight ────────────
write_table 10 7
HIDE_H=1 make_log 20 18 17 17
run_ut --from-ci 123
assert_exit_code 0 "$RC" "AC2 a log without test-h exits 0 ($OUT)"
assert_contains "$(table_body)" "7 test-h.sh" "AC2 test-h.sh, in no TIMINGS block, keeps its current weight 7"
assert_contains "$(table_body)" "20 test-a.sh" "AC2 a measured file still takes the new weight"
assert_eq "8" "$(table_body | wc -l | tr -d ' ')" "AC2 one line per tests/test-*.sh"

# ── AC3: no TIMINGS block, or a gh failure, leaves the table byte-identical ──
write_table 10 7
cp "$FX/tests/timings.txt" "$SANDBOX/before.txt"
printf 'job\tstep\t2026-11-22T10:00:00.0000000Z nothing to see\n' > "$SANDBOX/ci.log"
run_ut --from-ci 123
assert_eq "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "AC3 a log with no TIMINGS block exits non-zero (rc=$RC)"
assert_eq "same" "$(cmp -s "$SANDBOX/before.txt" "$FX/tests/timings.txt" && echo same || echo changed)" "AC3 no TIMINGS block leaves tests/timings.txt byte-identical"

make_log 20 18 17 17
STUB_VIEW_RC=1 run_ut --from-ci 123
assert_eq "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "AC3 a failed gh run view exits non-zero (rc=$RC)"
assert_eq "same" "$(cmp -s "$SANDBOX/before.txt" "$FX/tests/timings.txt" && echo same || echo changed)" "AC3 a failed gh run view leaves tests/timings.txt byte-identical"

STUB_LIST_RC=1 run_ut --from-ci
assert_eq "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "AC3 a failed gh run list exits non-zero (rc=$RC)"
assert_eq "same" "$(cmp -s "$SANDBOX/before.txt" "$FX/tests/timings.txt" && echo same || echo changed)" "AC3 a failed gh run list leaves tests/timings.txt byte-identical"

# ── AC4: --check exits 1 over a 0.15 spread, 0 at or under it ────────────────
# Shard sums are the new weights over the current partition: a+e, b+f, c+g, d+h.
check_case() {  # <label> <expected rc> <a> <b> <c> <d>
  write_table 10 1
  cp "$FX/tests/timings.txt" "$SANDBOX/before.txt"
  make_log "$3" "$4" "$5" "$6"
  run_ut --from-ci 123 --check
  assert_exit_code "$2" "$RC" "AC4 $1 exits $2 ($OUT)"
  assert_eq "same" "$(cmp -s "$SANDBOX/before.txt" "$FX/tests/timings.txt" && echo same || echo changed)" "AC4 $1 does not modify tests/timings.txt"
}

check_case "a spread of 0 (12,12,12,12)" 0 10 10 10 10
assert_contains "$OUT" "12" "AC4 --check prints each shard's sum"
check_case "a spread of 3/20 = 0.15 exactly (22,20,19,19)" 0 20 18 17 17
assert_contains "$OUT" "22" "AC4 --check prints shard 1's sum 22"
assert_contains "$OUT" "20" "AC4 --check prints shard 2's sum 20"
assert_contains "$OUT" "19" "AC4 --check prints shards 3 and 4's sum 19"
assert_contains "$OUT" "1/4" "AC4 --check labels each shard"
assert_contains "$OUT" "4/4" "AC4 --check labels shard 4/4"
check_case "a spread of 4/20.25 = 0.198 (23,20,19,19)" 1 21 18 17 17
assert_contains "$OUT" "23" "AC4 --check prints the heaviest shard's sum on drift too"
assert_file_exists "$FX/tests/timings.txt.new" "AC4 --check writes the refit to tests/timings.txt.new"
assert_contains "$(cat "$FX/tests/timings.txt.new")" "21 test-a.sh" "AC4 tests/timings.txt.new holds the newly measured weights"

# ── AC5: the weekly workflow ─────────────────────────────────────────────────
# workflow_perms_ok <file>: 0 when its permissions are exactly contents: read and actions: read.
workflow_perms_ok() {
  awk '
    /^[[:space:]]*permissions:[[:space:]]*$/ { inperm = 1; indent = match($0, /[^ ]/); np++; next }
    inperm {
      cur = match($0, /[^ ]/)
      if ($0 ~ /^[[:space:]]*$/) next
      if (cur <= indent) { inperm = 0 }
      else { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); seen[$0] = 1; n++; next }
    }
    END { exit !(np >= 1 && n == 2 * np && seen["contents: read"] && seen["actions: read"] && length(seen) == 2) }
  ' "$1"
}
assert_file_exists "$WORKFLOW" "AC5 .github/workflows/timings.yml exists"
if [ -f "$WORKFLOW" ]; then
  wf="$(cat "$WORKFLOW")"
  assert_contains "$wf" "schedule:" "AC5 the workflow has a schedule trigger"
  assert_contains "$wf" "cron:" "AC5 the schedule is a cron"
  assert_contains "$wf" "workflow_dispatch" "AC5 the workflow runs on workflow_dispatch"
  assert_contains "$wf" "update-timings.sh --from-ci --check" "AC5 the workflow runs update-timings.sh --from-ci --check"
  assert_contains "$wf" "upload-artifact" "AC5 on drift the refit is uploaded as an artifact"
  assert_not_contains "$wf" "pull-requests: write" "AC5 the workflow opens no PR"
  if workflow_perms_ok "$WORKFLOW"; then
    pass "AC5 permissions are exactly contents: read and actions: read"
  else
    fail "AC5 permissions are exactly contents: read and actions: read" "see $WORKFLOW"
  fi
  # Positive control: the permission check can fail.
  sed 's/actions: read/actions: write/' "$WORKFLOW" > "$SANDBOX/wf-widened.yml"
  if workflow_perms_ok "$SANDBOX/wf-widened.yml"; then
    fail "AC5 positive control: a widened permission is refused" "actions: write passed"
  else
    pass "AC5 positive control: a widened permission is refused"
  fi
fi

finish
