#!/usr/bin/env bash
# test-run-tests-parallel.sh -- tests for run-tests.sh parallel execution,
# # SERIAL marker support, --quiet, and the per-file result cache (#175).
#
# Fixture design: each case gets its own subdirectory within SANDBOX with a
# COPY (not symlink) of the real run-tests.sh, so TALOS_ROOT resolves to the
# fixture directory and its own .talos/test-cache/ stays isolated. No dedicated
# git repo is created per fixture (these tests are not about the --base-ref
# count check, which is already covered by tests/test-run-tests-count.sh) --
# run-tests.sh fails open on an unresolvable base ref and continues. They DO
# reuse the single git repo make_sandbox already initializes at $SANDBOX (a
# parent of every fixture dir), because compute_deps_hash() (#175 cache-key
# fix) now walks `git ls-files`, so tests that assert on dependency-hash
# invalidation must `track_fixture` a file before editing it for the edit to
# be visible to the hash at all.
#
# MEASUREMENT DISCIPLINE: out=$(cmd 2>&1); rc=$? throughout -- never pipe.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# build_min_fixture FD -- bare fixture: tests/run-tests.sh (copy) + empty stubs/.
build_min_fixture() {
  local FD="$1"
  mkdir -p "$FD/tests/stubs"
  cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
  track_fixture "$FD"
}

# write_stub FD NAME BODY -- writes an executable tests/<NAME> in FD.
write_stub() {
  local FD="$1" NAME="$2" BODY="$3"
  printf '#!/usr/bin/env bash\n%s\n' "$BODY" > "$FD/tests/$NAME"
}

# track_fixture FD -- stages every file currently under FD in the shared
# $SANDBOX git repo, so `git ls-files` (which compute_deps_hash() walks)
# reports them as tracked. A file only needs this once: compute_deps_hash()
# reads content straight off disk, so a later edit to an already-tracked
# file is picked up without re-tracking it.
track_fixture() {
  git -C "$SANDBOX" add -A "$1" >/dev/null 2>&1 || true
}

# order_of OUTPUT -- extracts the sequence of "-- <name>" headers, one per line.
order_of() {
  printf '%s\n' "$1" | grep '^-- ' | sed 's/^-- //'
}

make_sandbox

# ── Test A: parallel and serial (-j 1) report the same file set and RESULT ────
# Named mutation: make the parallel path drop or duplicate a file -- this
# test would then see a file-set/RESULT mismatch between the two runs.
FDA="$SANDBOX/a"
build_min_fixture "$FDA"
for f in test-a.sh test-b.sh test-c.sh test-d.sh; do
  write_stub "$FDA" "$f" "exit 0"
done

out_p="$(bash "$FDA/tests/run-tests.sh" --no-cache 2>&1)"; rc_p=$?
out_s="$(bash "$FDA/tests/run-tests.sh" --no-cache -j 1 2>&1)"; rc_s=$?

assert_exit_code 0 "$rc_p" "A: parallel run exits 0"
assert_exit_code 0 "$rc_s" "A: serial (-j 1) run exits 0"
assert_eq "all 4 test file(s) passed (count check skipped -- base ref unresolvable)" \
  "$(printf '%s\n' "$out_p" | grep '^RESULT:' | sed 's/^RESULT: //')" \
  "A: parallel RESULT line"
assert_eq "$(printf '%s\n' "$out_p" | grep '^RESULT:')" "$(printf '%s\n' "$out_s" | grep '^RESULT:')" \
  "A: parallel and serial RESULT lines match"
assert_eq "$(order_of "$out_p")" "$(order_of "$out_s")" "A: parallel and serial report the same file set/order"

# ── Test B: -j and TALOS_TEST_JOBS actually bound/enable concurrency ──────────
# Named mutation: ignore JOBS entirely and always run one file at a time.
# Both the -j flag and the env var would then take the same (slow) wall time
# as the -j 1 baseline, and this test would fail to see the expected speedup.
FDB1="$SANDBOX/b1"
build_min_fixture "$FDB1"
for f in test-1.sh test-2.sh test-3.sh test-4.sh; do
  write_stub "$FDB1" "$f" "sleep 1; exit 0"
done
t0=$(date +%s)
bash "$FDB1/tests/run-tests.sh" --no-cache -j 1 >/dev/null 2>&1
serial_elapsed=$(( $(date +%s) - t0 ))

FDB2="$SANDBOX/b2"
build_min_fixture "$FDB2"
for f in test-1.sh test-2.sh test-3.sh test-4.sh; do
  write_stub "$FDB2" "$f" "sleep 1; exit 0"
done
t0=$(date +%s)
bash "$FDB2/tests/run-tests.sh" --no-cache -j 4 >/dev/null 2>&1
jflag_elapsed=$(( $(date +%s) - t0 ))

FDB3="$SANDBOX/b3"
build_min_fixture "$FDB3"
for f in test-1.sh test-2.sh test-3.sh test-4.sh; do
  write_stub "$FDB3" "$f" "sleep 1; exit 0"
done
t0=$(date +%s)
TALOS_TEST_JOBS=4 bash "$FDB3/tests/run-tests.sh" --no-cache >/dev/null 2>&1
envvar_elapsed=$(( $(date +%s) - t0 ))

if [ "$jflag_elapsed" -lt "$serial_elapsed" ]; then pass "B: -j 4 is faster than -j 1 (${jflag_elapsed}s < ${serial_elapsed}s)"; else fail "B: -j 4 is faster than -j 1" "jflag=${jflag_elapsed}s serial=${serial_elapsed}s"; fi
if [ "$envvar_elapsed" -lt "$serial_elapsed" ]; then pass "B: TALOS_TEST_JOBS=4 is faster than -j 1 (${envvar_elapsed}s < ${serial_elapsed}s)"; else fail "B: TALOS_TEST_JOBS=4 is faster than -j 1" "envvar=${envvar_elapsed}s serial=${serial_elapsed}s"; fi

# ── Test C: output ordering is stable regardless of completion order ─────────
# Named mutation: print each file's block as soon as its job completes
# instead of buffering to original order -- test-b.sh (no sleep) would then
# print before test-a.sh (1s sleep), reordering the sequence below.
FDC="$SANDBOX/c"
build_min_fixture "$FDC"
write_stub "$FDC" "test-a.sh" "sleep 1; exit 0"
write_stub "$FDC" "test-b.sh" "exit 0"
write_stub "$FDC" "test-c.sh" "sleep 0.5; exit 0"

out_c="$(bash "$FDC/tests/run-tests.sh" --no-cache -j 3 2>&1)"; rc_c=$?
assert_exit_code 0 "$rc_c" "C: run exits 0"
assert_eq "$(printf 'test-a.sh\ntest-b.sh\ntest-c.sh')" "$(order_of "$out_c")" \
  "C: output order is original file-list order, not completion order"

# ── Test D: # SERIAL marker runs after the parallel batch ─────────────────────
# Named mutation: ignore the # SERIAL marker and run every file through the
# parallel pool -- the serial file could then start (and log its event)
# before a parallel file finishes, and its header could print out of place.
FDD="$SANDBOX/d"
build_min_fixture "$FDD"
EVENTS="$FDD/events.log"
: > "$EVENTS"
write_stub "$FDD" "test-p1.sh" "sleep 0.3; echo parallel:test-p1.sh >> '$EVENTS'; exit 0"
write_stub "$FDD" "test-p2.sh" "sleep 0.1; echo parallel:test-p2.sh >> '$EVENTS'; exit 0"
{
  printf '#!/usr/bin/env bash\n'
  printf '# SERIAL\n'
  printf 'echo serial:test-z-serial.sh >> '\''%s'\''\n' "$EVENTS"
  printf 'exit 0\n'
} > "$FDD/tests/test-z-serial.sh"

out_d="$(bash "$FDD/tests/run-tests.sh" --no-cache -j 2 2>&1)"; rc_d=$?
assert_exit_code 0 "$rc_d" "D: run exits 0"
assert_eq "$(printf 'test-p1.sh\ntest-p2.sh\ntest-z-serial.sh')" "$(order_of "$out_d")" \
  "D: serial file's header prints after both parallel headers"
assert_eq "serial:test-z-serial.sh" "$(tail -n 1 "$EVENTS")" \
  "D: serial file's event is the last one recorded (started after parallel batch finished)"

# ── Test E: cache hit prints CACHED and skips re-execution ───────────────────
# Named mutation: never check/write the cache -- run 2 would show no CACHED
# line and the counter file would show 2 runs instead of 1.
FDE="$SANDBOX/e"
build_min_fixture "$FDE"
CTR_E="$FDE/counter-e"
: > "$CTR_E"
write_stub "$FDE" "test-x.sh" "echo ran >> '$CTR_E'; exit 0"

out_e1="$(bash "$FDE/tests/run-tests.sh" 2>&1)"; rc_e1=$?
assert_exit_code 0 "$rc_e1" "E: first run exits 0"
assert_not_contains "$out_e1" "CACHED" "E: first run is a cache miss (nothing cached yet)"
assert_eq 1 "$(wc -l < "$CTR_E" | tr -d ' ')" "E: first run executed the file once"

out_e2="$(bash "$FDE/tests/run-tests.sh" 2>&1)"; rc_e2=$?
assert_exit_code 0 "$rc_e2" "E: second run exits 0"
assert_contains "$out_e2" "CACHED tests/test-x.sh" "E: second run is a cache hit"
assert_eq 1 "$(wc -l < "$CTR_E" | tr -d ' ')" "E: second run did not re-execute the file"

# ── Test F: touching a dependency invalidates the key ─────────────────────────
# Named mutation: key the cache on the test file's content only, ignoring
# scripts/*.sh -- run 3 (after editing the dependency) would stay CACHED.
FDF="$SANDBOX/f"
build_min_fixture "$FDF"
mkdir -p "$FDF/scripts"
printf '#!/usr/bin/env bash\necho v1\n' > "$FDF/scripts/pipeline-config.sh"
track_fixture "$FDF"   # must be tracked for compute_deps_hash (git ls-files) to see it
CTR_F="$FDF/counter-f"
: > "$CTR_F"
write_stub "$FDF" "test-x.sh" "echo ran >> '$CTR_F'; exit 0"

bash "$FDF/tests/run-tests.sh" >/dev/null 2>&1                 # run 1: miss, populates cache
out_f2="$(bash "$FDF/tests/run-tests.sh" 2>&1)"                # run 2: unchanged deps -> hit
assert_contains "$out_f2" "CACHED tests/test-x.sh" "F: unchanged dependency stays cached"
assert_eq 1 "$(wc -l < "$CTR_F" | tr -d ' ')" "F: cached run did not re-execute"

printf '#!/usr/bin/env bash\necho v2\n' > "$FDF/scripts/pipeline-config.sh"   # touch the dependency
out_f3="$(bash "$FDF/tests/run-tests.sh" 2>&1)"                # run 3: deps changed -> miss
assert_not_contains "$out_f3" "CACHED tests/test-x.sh" "F: touching scripts/pipeline-config.sh invalidates the key"
assert_eq 2 "$(wc -l < "$CTR_F" | tr -d ' ')" "F: invalidated cache re-executed the file"

# ── Test G: a failing file is never cached ────────────────────────────────────
# Named mutation: write the cache marker unconditionally instead of only on
# success -- run 2 would show CACHED for a file that always fails.
FDG="$SANDBOX/g"
build_min_fixture "$FDG"
CTR_G="$FDG/counter-g"
: > "$CTR_G"
write_stub "$FDG" "test-fail.sh" "echo ran >> '$CTR_G'; exit 1"

out_g1="$(bash "$FDG/tests/run-tests.sh" 2>&1)"; rc_g1=$?
assert_exit_code 1 "$rc_g1" "G: first run of a failing file exits 1"
out_g2="$(bash "$FDG/tests/run-tests.sh" 2>&1)"; rc_g2=$?
assert_exit_code 1 "$rc_g2" "G: second run still exits 1"
assert_not_contains "$out_g2" "CACHED tests/test-fail.sh" "G: a failing file is never cached"
assert_eq 2 "$(wc -l < "$CTR_G" | tr -d ' ')" "G: failing file re-executed on both runs"

# ── Test H: --no-cache bypasses even when the cache would otherwise hit ──────
# Named mutation: --no-cache only skips the read, not the check -- the
# second run below would still show CACHED.
FDH="$SANDBOX/h"
build_min_fixture "$FDH"
CTR_H="$FDH/counter-h"
: > "$CTR_H"
write_stub "$FDH" "test-x.sh" "echo ran >> '$CTR_H'; exit 0"

bash "$FDH/tests/run-tests.sh" >/dev/null 2>&1                 # run 1: populates cache
out_h2="$(bash "$FDH/tests/run-tests.sh" --no-cache 2>&1)"     # run 2: --no-cache bypasses it
assert_not_contains "$out_h2" "CACHED" "H: --no-cache bypasses an existing cache hit"
assert_eq 2 "$(wc -l < "$CTR_H" | tr -d ' ')" "H: --no-cache re-executed the file"

# ── Test I: a failing file's full output is shown under --quiet and normal ───
# Named mutation: --quiet suppresses output for failing files too -- the
# marker string would be missing from the quiet-mode run's output.
FDI="$SANDBOX/i"
build_min_fixture "$FDI"
write_stub "$FDI" "test-loud-fail.sh" "echo DISTINCTIVE_FAILURE_MARKER_XYZ; exit 1"

out_i_normal="$(bash "$FDI/tests/run-tests.sh" --no-cache 2>&1)"; rc_i_normal=$?
assert_exit_code 1 "$rc_i_normal" "I: normal mode exits 1 on failure"
assert_contains "$out_i_normal" "DISTINCTIVE_FAILURE_MARKER_XYZ" "I: normal mode shows the failing file's full output"
assert_contains "$out_i_normal" "RESULT: 1 of 1 test file(s) FAILED" "I: normal mode RESULT line"

out_i_quiet="$(bash "$FDI/tests/run-tests.sh" --no-cache --quiet 2>&1)"; rc_i_quiet=$?
assert_exit_code 1 "$rc_i_quiet" "I: quiet mode exits 1 on failure"
assert_contains "$out_i_quiet" "FAIL  tests/test-loud-fail.sh" "I: quiet mode names the failing file"
assert_contains "$out_i_quiet" "DISTINCTIVE_FAILURE_MARKER_XYZ" "I: quiet mode still shows the failing file's full output"
assert_contains "$out_i_quiet" "RESULT: 1 of 1 test file(s) FAILED" "I: quiet mode RESULT line"

# ── #175 review/security follow-up: compute_deps_hash() completeness ─────────
# PR #203 was blocked twice on the same class of finding: the cache key
# (compute_deps_hash) did not cover every input a test's outcome can depend
# on. It now hashes every git-tracked file except a small, proven-unread
# exclusion list (see the comment on compute_deps_hash() in run-tests.sh).
# Tests J-M each name a file OUTSIDE the old allow-list (the runner script
# itself, plus agents/, skills/, and repo-root README.md) that must now
# invalidate the cache; test N proves an excluded path does NOT.
#
# assert_dep_invalidates LABEL FD RELPATH -- RELPATH must already be tracked
# (track_fixture) under FD. Populates the cache for a throwaway test-x.sh,
# confirms an unchanged second run hits, edits RELPATH, and confirms the
# third run misses (re-executes) because the dependency hash changed.
assert_dep_invalidates() {
  local label="$1" FD="$2" relpath="$3" ctr out2 out3
  ctr="$FD/counter"
  : > "$ctr"
  write_stub "$FD" "test-x.sh" "echo ran >> '$ctr'; exit 0"
  bash "$FD/tests/run-tests.sh" >/dev/null 2>&1                # run 1: miss, populates cache
  out2="$(bash "$FD/tests/run-tests.sh" 2>&1)"                 # run 2: unchanged -> hit
  assert_contains "$out2" "CACHED tests/test-x.sh" "$label: unchanged $relpath stays cached"
  printf '\n# edited for %s\n' "$label" >> "$FD/$relpath"
  out3="$(bash "$FD/tests/run-tests.sh" 2>&1)"                 # run 3: edited -> miss
  assert_not_contains "$out3" "CACHED tests/test-x.sh" "$label: editing $relpath invalidates the key"
  assert_eq 2 "$(wc -l < "$ctr" | tr -d ' ')" "$label: invalidated cache re-executed the file"
}

# assert_dep_excluded LABEL FD RELPATH -- same setup, but RELPATH falls under
# the exclusion list: editing it must NOT invalidate the cache.
assert_dep_excluded() {
  local label="$1" FD="$2" relpath="$3" ctr out3
  ctr="$FD/counter"
  : > "$ctr"
  write_stub "$FD" "test-x.sh" "echo ran >> '$ctr'; exit 0"
  bash "$FD/tests/run-tests.sh" >/dev/null 2>&1                # run 1: miss, populates cache
  printf '\n# edited for %s\n' "$label" >> "$FD/$relpath"
  out3="$(bash "$FD/tests/run-tests.sh" 2>&1)"                 # run 2: excluded path edited -> still hit
  assert_contains "$out3" "CACHED tests/test-x.sh" "$label: editing excluded $relpath does NOT invalidate the key"
  assert_eq 1 "$(wc -l < "$ctr" | tr -d ' ')" "$label: excluded-file edit did not re-execute the file"
}

# ── Test J: editing tests/run-tests.sh itself invalidates the key ────────────
# Named mutation: leave tests/run-tests.sh out of the hashed set (the exact
# bug the #203 reviewer round found) -- this test would then see a stale
# CACHED result after the runner script changed.
FDJ="$SANDBOX/j"
build_min_fixture "$FDJ"   # already tracks tests/run-tests.sh via track_fixture
assert_dep_invalidates "J" "$FDJ" "tests/run-tests.sh"

# ── Test K: editing a file under agents/ invalidates the key ─────────────────
# Named mutation: omit agents/** from the hashed set (the #203 security
# finding) -- a regression in agents/*.md that a test asserts against would
# then hide behind a stale CACHED pass.
FDK="$SANDBOX/k"
build_min_fixture "$FDK"
mkdir -p "$FDK/agents"
printf '# developer\n' > "$FDK/agents/developer.md"
track_fixture "$FDK"
assert_dep_invalidates "K" "$FDK" "agents/developer.md"

# ── Test L: editing a file under skills/ invalidates the key ─────────────────
# Same mutation shape as K, for skills/**.
FDL="$SANDBOX/l"
build_min_fixture "$FDL"
mkdir -p "$FDL/skills/pipeline"
printf '# SKILL\n' > "$FDL/skills/pipeline/SKILL.md"
track_fixture "$FDL"
assert_dep_invalidates "L" "$FDL" "skills/pipeline/SKILL.md"

# ── Test M: editing README.md invalidates the key ─────────────────────────────
# Same mutation shape, for repo-root docs that never lived in the old
# allow-list (scripts/*.sh, tests/helpers.sh, tests/stubs/*, templates/**).
FDM="$SANDBOX/m"
build_min_fixture "$FDM"
printf '# fixture readme\n' > "$FDM/README.md"
track_fixture "$FDM"
assert_dep_invalidates "M" "$FDM" "README.md"

# ── Test N: editing an excluded path does NOT invalidate the key ─────────────
# Named mutation: hash literally everything under $TALOS_ROOT with no
# exclusion list at all -- editing tasks/** (proven unread by any test; see
# compute_deps_hash()'s comment) would then also invalidate, and this test
# would see an unexpected cache miss.
FDN="$SANDBOX/n"
build_min_fixture "$FDN"
mkdir -p "$FDN/tasks"
printf '# scratch notes\n' > "$FDN/tasks/scratch.md"
track_fixture "$FDN"
assert_dep_excluded "N" "$FDN" "tasks/scratch.md"

finish
