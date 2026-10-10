#!/usr/bin/env bash
# test-run-tests-shard.sh -- run-tests.sh --shard i/n, --list, --count-only and
# the work-queue pool (#556).
#
# The CI splits the suite into shards; a file that lands in no shard (or two)
# silently stops being tested (or runs twice), so the partition is checked on
# the real suite, not only on fixtures.
#
# MEASUREMENT DISCIPLINE: out=$(cmd 2>&1); rc=$? throughout -- never pipe.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"
make_sandbox

# ── Real suite: every file is in exactly one shard, for each CI shard count ──
all="$(cd "$TALOS_ROOT/tests" && ls test-*.sh | LC_ALL=C sort)"
for n in 2 3 4 5; do
  union=""
  for i in $(seq 1 "$n"); do
    part="$(bash "$REAL_RUN_TESTS" --shard "$i/$n" --list 2>/dev/null)"
    union="$union
$part"
  done
  union="$(printf '%s\n' "$union" | grep -v '^$' | LC_ALL=C sort)"
  assert_eq "$all" "$union" "real suite: shards 1..$n/$n together run every file exactly once"
done

# deterministic: the same call twice names the same files
a="$(bash "$REAL_RUN_TESTS" --shard 2/4 --list 2>/dev/null)"
b="$(bash "$REAL_RUN_TESTS" --shard 2/4 --list 2>/dev/null)"
assert_eq "$a" "$b" "shard partition is deterministic"

# balanced: by tests/timings.txt no shard carries much more than its share
load_of() {  # $1=i $2=n
  local f w sum=0
  for f in $(bash "$REAL_RUN_TESTS" --shard "$1/$2" --list 2>/dev/null); do
    w="$(awk -v f="$f" '$2 == f {print $1}' "$TALOS_ROOT/tests/timings.txt")"
    sum=$((sum + ${w:-8}))
  done
  echo "$sum"
}
max=0; min=999999
for i in 1 2 3 4; do
  l="$(load_of "$i" 4)"
  [ "$l" -gt "$max" ] && max="$l"
  [ "$l" -lt "$min" ] && min="$l"
done
if [ $((max * 100)) -le $((min * 115)) ]; then
  pass "4 shards are balanced by timings (heaviest ${max}s vs lightest ${min}s, within 15%)"
else
  fail "4 shards are balanced by timings" "heaviest ${max}s vs lightest ${min}s; refresh tests/timings.txt (bash tests/update-timings.sh)"
fi

# a pattern composes with a shard: a subset of that shard, nothing outside it
sub="$(bash "$REAL_RUN_TESTS" --shard 1/4 --list notify 2>/dev/null)"
shard1="$(bash "$REAL_RUN_TESTS" --shard 1/4 --list 2>/dev/null)"
extra="$(printf '%s\n' "$sub" | grep -v '^$' | grep -vxF "$shard1" || true)"
assert_eq "" "$extra" "pattern + shard selects only files of that shard"

# bad specs are a usage error (rc 2), not a silent full run
for bad in 0/4 5/4 a/b 3 4/0 ""; do
  out="$(bash "$REAL_RUN_TESTS" --shard "$bad" --list 2>&1)"; rc=$?
  assert_exit_code 2 "$rc" "--shard '$bad' is rejected"
done

# ── Fixture: a file missing from timings.txt is still placed, deterministically ──
FD="$SANDBOX/fx"
mkdir -p "$FD/tests/stubs"
cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
for f in test-a.sh test-b.sh test-c.sh test-d.sh test-e.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/$f"
done
printf '# timings\n30 test-a.sh\n10 test-b.sh\n' > "$FD/tests/timings.txt"
union=""
for i in 1 2; do
  part="$(bash "$FD/tests/run-tests.sh" --shard "$i/2" --list 2>/dev/null)"
  union="$union $(echo $part)"
done
assert_eq "test-a.sh test-b.sh test-c.sh test-d.sh test-e.sh" "$(printf '%s\n' $union | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
  "fixture: files absent from timings.txt (c, d, e) are assigned too"
assert_eq "test-a.sh" "$(bash "$FD/tests/run-tests.sh" --shard 1/2 --list 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
  "fixture: the heaviest file sits alone against the lighter rest"

# without a timings file every file weighs the same and the split still covers all
rm "$FD/tests/timings.txt"
union=""
for i in 1 2 3; do
  union="$union $(bash "$FD/tests/run-tests.sh" --shard "$i/3" --list 2>/dev/null | tr '\n' ' ')"
done
assert_eq "5" "$(printf '%s\n' $union | grep -c .)" "fixture: no timings.txt, 3 shards still cover 5 files once"

# a sharded run executes its files, reports the shard, and skips the count check
out="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet --shard 1/2 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "fixture: a sharded run passes"
assert_contains "$out" "SHARD 1/2" "fixture: the RESULT line names the shard"

# ── --count-only ─────────────────────────────────────────────────────────────
CD="$SANDBOX/cnt"
mkdir -p "$CD/tests"
cp "$REAL_RUN_TESTS" "$CD/tests/run-tests.sh"
for f in test-a.sh test-b.sh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$CD/tests/$f"; done
git -C "$CD" init -q
git -C "$CD" config user.email t@talos.invalid
git -C "$CD" config user.name talos-test
git -C "$CD" add -A
git -C "$CD" commit -q -m base
git -C "$CD" branch -q basebr
git -C "$CD" rm -q tests/test-b.sh
git -C "$CD" commit -q -m "drop b"

out="$(bash "$CD/tests/run-tests.sh" --count-only --base-ref basebr 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "count-only: a file on the base ref but gone here fails"
assert_contains "$out" "test-b.sh" "count-only: names the missing file"

printf 'test-b.sh\n' > "$CD/tests/retired-tests.txt"
out="$(bash "$CD/tests/run-tests.sh" --count-only --base-ref basebr 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "count-only: retired-tests.txt excuses the missing file"

out="$(bash "$CD/tests/run-tests.sh" --count-only --base-ref no-such-ref 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "count-only: an unresolvable base ref is an error, not a skip"

# ── Work-queue pool: all files run, never more than -j at once, and a slot is
#    handed on as soon as it frees (no waiting for the slowest of a batch) ──
PD="$SANDBOX/pool"
mkdir -p "$PD/tests" "$PD/state"
cp "$REAL_RUN_TESTS" "$PD/tests/run-tests.sh"
# t1 is slow, t2..t5 are instant. With -j 2 and a batch barrier t3/t4 would wait
# for t1; in a work queue t2..t5 all finish while t1 is still running.
cat > "$PD/tests/test-t1.sh" <<EOF
#!/usr/bin/env bash
echo start >> "$PD/state/running"
for _i in \$(seq 1 100); do [ -f "$PD/state/quick-done" ] && break; sleep 0.1; done
[ -f "$PD/state/quick-done" ] || exit 1
EOF
for n in 2 3 4 5; do
  cat > "$PD/tests/test-t$n.sh" <<EOF
#!/usr/bin/env bash
echo t$n >> "$PD/state/quick"
[ "\$(wc -l < "$PD/state/quick" | tr -d ' ')" -ge 4 ] && : > "$PD/state/quick-done"
exit 0
EOF
done
printf '60 test-t1.sh\n' > "$PD/tests/timings.txt"
out="$(bash "$PD/tests/run-tests.sh" --no-cache --quiet -j 2 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "pool: -j 2 over a slow file and four quick ones passes (quick ones overtook the slow one)"
assert_contains "$out" "all 5 test file(s) passed" "pool: every file ran"
assert_eq "4" "$(wc -l < "$PD/state/quick" | tr -d ' ')" "pool: each quick file ran once"

finish
