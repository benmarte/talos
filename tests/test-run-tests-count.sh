#!/usr/bin/env bash
# test-run-tests-count.sh -- tests for run-tests.sh count check and base-currency warning.
#
# These tests verify that run-tests.sh (issue #131):
#   1. Detects when a checkout is missing test files that exist on origin/main
#      (default-on, no flag required).
#   2. Passes silently when the checkout is current with origin/main.
#   3. Fails open (warn + continue) when the base ref is unresolvable.
#   4. Respects --base-ref override when supplied.
#   5. Emits a base-currency WARN when HEAD is behind origin, without hard-failing.
#   6. Marks filtered runs in the RESULT line so they cannot be mistaken for full runs.
#
# Fixture design:
#   Each case gets its own subdirectory within SANDBOX, each with its own git
#   repo and bare "origin".  run-tests.sh is COPIED (not symlinked) into each
#   fixture's tests/ so TALOS_ROOT resolves to the fixture directory.
#   Test stubs are minimal: #!/usr/bin/env bash + exit 0.
#
# MEASUREMENT DISCIPLINE: out=$(cmd 2>&1); rc=$? throughout -- never pipe.
#
# Named mutations (RED-before proof):
#   T1: remove the SKIP_COUNT_CHECK=0 block entirely from run-tests.sh.
#       The old script exits 0 on a stale checkout -- this test was RED then.
#   T2: add an always-failing count check -- the current-checkout test would
#       fail, proving the check is absent from the normal path.
#   T3: remove the SKIP_COUNT_CHECK=1 path -- the no-remote test would fail.
#   T4: ignore BASE_REF_OVERRIDE -- the --base-ref test would stop working.
#   T5: turn the WARN into an exit 1 -- the currency warning hard-fails.
#   T6: emit plain "all N test file(s) passed" even when PATTERN is set --
#       the filtered-run RESULT would be indistinguishable from a full run.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# ── Fixture builder ───────────────────────────────────────────────────────────
# build_fixture FIXTURE_DIR LOCAL_STUBS ORIGIN_EXTRA_STUBS
#
#   FIXTURE_DIR: absolute path; created by caller.
#   LOCAL_STUBS: space-separated test-*.sh filenames present in local checkout.
#   ORIGIN_EXTRA_STUBS: space-separated test-*.sh filenames added ONLY to origin
#                       (simulates origin advancing after the branch was taken).
#
# Postconditions:
#   - FIXTURE_DIR is a git repo with LOCAL_STUBS committed.
#   - FIXTURE_DIR.git is a bare repo (origin).
#   - When ORIGIN_EXTRA_STUBS is non-empty:
#       * origin has those files too (one extra commit).
#       * local has fetched but NOT merged (FIXTURE_DIR/tests lacks them).
#   - FIXTURE_DIR/tests/run-tests.sh is a copy of the real run-tests.sh.
#   - FIXTURE_DIR/tests/stubs/ exists (empty).
build_fixture() {
  local FD="$1"
  local LOCAL_STUBS="$2"
  local ORIGIN_EXTRA="${3:-}"

  mkdir -p "$FD/tests/stubs"
  cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"

  # Create minimal passing stubs.
  for _f in $LOCAL_STUBS; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/$_f"
  done

  git -C "$FD" init -q
  git -C "$FD" config user.email "test@talos.invalid"
  git -C "$FD" config user.name  "talos-test"
  # Add a root file so the initial commit is not empty, and tests/ content.
  printf 'fixture\n' > "$FD/.fixture"
  git -C "$FD" add .fixture tests/
  git -C "$FD" commit -q -m "initial: local stubs"

  # Create bare origin and wire it up.
  local OD="${FD}.git"
  git -C "$FD" clone -q --bare "$FD" "$OD"
  git -C "$FD" remote add origin "$OD"
  git -C "$FD" fetch -q origin

  # Detect default branch.
  local BASE
  BASE="$(git -C "$OD" symbolic-ref HEAD 2>/dev/null | sed 's|.*/||')"
  [ -z "$BASE" ] && BASE="main"
  git -C "$FD" branch -u "origin/$BASE" "$BASE" 2>/dev/null || true

  # Push local so remote-tracking ref is level.
  git -C "$FD" push -q origin "$BASE"

  if [ -n "$ORIGIN_EXTRA" ]; then
    # Add extra files to origin via a scratch clone.
    local OC="${FD}-oc"
    git clone -q "$OD" "$OC"
    git -C "$OC" config user.email "test@talos.invalid"
    git -C "$OC" config user.name  "talos-test"
    mkdir -p "$OC/tests"
    for _f in $ORIGIN_EXTRA; do
      printf '#!/usr/bin/env bash\nexit 0\n' > "$OC/tests/$_f"
    done
    git -C "$OC" add tests/
    git -C "$OC" commit -q -m "origin: add extra stubs"
    git -C "$OC" push -q origin "$BASE"
    # Fetch into local so origin/<BASE> tracking ref is updated,
    # but do NOT merge -- local tests/ still lacks the extra files.
    git -C "$FD" fetch -q origin
  fi
}

make_sandbox

# ── Test 1 (REGRESSION): stale fixture -- exit 1, names missing file ──────────
# Named mutation: remove the count-check block from run-tests.sh.
# Old behaviour (before this fix): exits 0, missing file undetected.
# New behaviour: exits 1, names test-gamma.sh in output.
FD1="$SANDBOX/t1"
mkdir -p "$FD1"
build_fixture "$FD1" "test-alpha.sh test-beta.sh" "test-gamma.sh"

out="$(bash "$FD1/tests/run-tests.sh" 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "T1: stale fixture exits 1"
assert_contains "$out" "SHORT" "T1: output contains SHORT"
assert_contains "$out" "test-gamma.sh" "T1: names the missing file"
assert_not_contains "$out" "all 2 test file(s) passed" "T1: does not claim success"

# ── Test 2: current checkout -- exits 0, byte-compatible with old behaviour ───
# Named mutation: add an always-failing count check.
# This test ensures the new code does not fire on a clean, current checkout.
FD2="$SANDBOX/t2"
mkdir -p "$FD2"
build_fixture "$FD2" "test-alpha.sh test-beta.sh" ""

out="$(bash "$FD2/tests/run-tests.sh" 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T2: current checkout exits 0"
assert_contains "$out" "all 2 test file(s) passed" "T2: success message present"
assert_not_contains "$out" "SHORT" "T2: no SHORT on current checkout"

# ── Test 3: no remote -- WARNING emitted, suite continues, exit 0 ─────────────
# Named mutation: remove the SKIP_COUNT_CHECK=1 path (fail-closed instead of open).
# A checkout with no remote must not block -- local development without a remote
# is a legitimate workflow, not a configuration error.
FD3="$SANDBOX/t3"
mkdir -p "$FD3/tests/stubs"
cp "$REAL_RUN_TESTS" "$FD3/tests/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FD3/tests/test-alpha.sh"
printf 'fixture\n' > "$FD3/.fixture"
git -C "$FD3" init -q
git -C "$FD3" config user.email "test@talos.invalid"
git -C "$FD3" config user.name  "talos-test"
git -C "$FD3" add .fixture tests/
git -C "$FD3" commit -q -m "no-remote fixture"
# No remote added -- origin/HEAD is unresolvable, origin/main does not exist.

out="$(bash "$FD3/tests/run-tests.sh" 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T3: no-remote exits 0 (fail-open)"
assert_contains "$out" "WARNING" "T3: WARNING printed when ref unresolvable"
assert_contains "$out" "skipping count check" "T3: mentions skipping count check"
assert_contains "$out" "all 1 test file(s) passed" "T3: suite result still reported"

# ── Test 4: --base-ref override takes precedence ──────────────────────────────
# Named mutation: ignore BASE_REF_OVERRIDE in run-tests.sh.
# The stale fixture (FD1) would normally fail the count check because origin/main
# has test-gamma.sh.  Passing --base-ref HEAD (local HEAD, which lacks gamma)
# should suppress the failure, proving the override is honoured.
out="$(bash "$FD1/tests/run-tests.sh" --base-ref HEAD 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T4: --base-ref HEAD overrides, exits 0"
assert_not_contains "$out" "SHORT" "T4: no SHORT when --base-ref is local HEAD"

# ── Test 5: base-currency WARN fires when behind, does not hard-fail ──────────
# Named mutation: turn the WARN into exit 1 (hard-fail).
#
# Build a fixture where local is 1 commit behind origin BUT the commit does not
# add new test files (an empty commit), so the count check passes.  This isolates
# the WARN path: WARN fires because HEAD is behind, but exit is 0, proving the
# WARN never hard-fails even when it fires.
FD5="$SANDBOX/t5"
mkdir -p "$FD5/tests/stubs"
cp "$REAL_RUN_TESTS" "$FD5/tests/run-tests.sh"
for _f in test-alpha.sh test-beta.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FD5/tests/$_f"
done
printf 'fixture\n' > "$FD5/.fixture"
git -C "$FD5" init -q
git -C "$FD5" config user.email "test@talos.invalid"
git -C "$FD5" config user.name  "talos-test"
git -C "$FD5" add .fixture tests/
git -C "$FD5" commit -q -m "initial: two stubs"
git -C "$FD5" clone -q --bare "$FD5" "${FD5}.git"
git -C "$FD5" remote add origin "${FD5}.git"
git -C "$FD5" fetch -q origin
FD5_BASE="$(git -C "${FD5}.git" symbolic-ref HEAD 2>/dev/null | sed 's|.*/||')"
[ -z "$FD5_BASE" ] && FD5_BASE="main"
git -C "$FD5" branch -u "origin/$FD5_BASE" "$FD5_BASE" 2>/dev/null || true
git -C "$FD5" push -q origin "$FD5_BASE"
# Advance origin with an empty commit (no new test files).
FD5_OC="${FD5}-oc"
git clone -q "${FD5}.git" "$FD5_OC"
git -C "$FD5_OC" config user.email "test@talos.invalid"
git -C "$FD5_OC" config user.name  "talos-test"
git -C "$FD5_OC" commit -q --allow-empty -m "origin: advance without new test files"
git -C "$FD5_OC" push -q origin "$FD5_BASE"
git -C "$FD5" fetch -q origin
# Local is now 1 commit behind origin; no new test files were added.

out="$(bash "$FD5/tests/run-tests.sh" 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "T5: WARN does not hard-fail (exit 0 despite being behind)"
assert_contains "$out" "WARN" "T5: WARN fires when HEAD is behind origin"
assert_not_contains "$out" "SHORT" "T5: no count shortfall (same test files on both)"

# Also verify: a stale fixture with missing test files shows BOTH WARN and SHORT.
out_both="$(bash "$FD1/tests/run-tests.sh" 2>&1)"; rc_both=$?
assert_exit_code 1 "$rc_both" "T5: count SHORT causes exit 1"
assert_contains "$out_both" "WARN" "T5: WARN present alongside count failure"

# ── Test 6: filtered run RESULT is distinguishable from a full run ────────────
# Named mutation: emit plain "all N test file(s) passed" even when PATTERN is set.
# A filtered run's RESULT must be impossible to mistake for a complete run when
# quoted or pasted -- it must name the pattern and state the count check was skipped.
# Uses FD2 (current checkout, two stubs: test-alpha.sh and test-beta.sh).

# Filtered run (matches "alpha") -- only 1 file runs.
out_f="$(bash "$FD2/tests/run-tests.sh" alpha 2>&1)"; rc_f=$?
assert_exit_code 0 "$rc_f" "T6: filtered run exits 0"
assert_contains "$out_f" "FILTERED" "T6: RESULT contains FILTERED"
assert_contains "$out_f" "alpha" "T6: RESULT names the pattern"
assert_contains "$out_f" "count check skipped" "T6: RESULT states count check was skipped"

# Full run (no pattern) -- plain RESULT line, no FILTERED marker.
out_full="$(bash "$FD2/tests/run-tests.sh" 2>&1)"; rc_full=$?
assert_exit_code 0 "$rc_full" "T6: full run exits 0"
assert_not_contains "$out_full" "FILTERED" "T6: full-run RESULT does not say FILTERED"
assert_not_contains "$out_f" "all 2 test file(s) passed" "T6: filtered RESULT differs from full-run wording"

finish
