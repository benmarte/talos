#!/usr/bin/env bash
# test-sandbox-cwd.sh — covers issue #121: make_sandbox CWD-stranding behaviour.
#
# Tests:
#   T1. Sandbox is removed after the subprocess exits (leak guard).
#   T2. Sandbox is removed even when the test fails (cleanup-on-failure guard).
#   T3. make_sandbox refuses when called from a sourced context (the actual fix).
#   T4. run-tests.sh rejects being sourced (secondary defence).
#
# Mutations that make each test RED:
#   T1/T2: remove 'rm -rf "$SANDBOX"' from the EXIT trap in make_sandbox.
#   T3:    remove the BASH_SOURCE guard from make_sandbox in helpers.sh.
#   T4:    remove the BASH_SOURCE guard from run-tests.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

# ═════════════════════════════════════════════════════════════════════════════
# T1: Sandbox is removed after the subprocess exits
# ═════════════════════════════════════════════════════════════════════════════
before_t1="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
(
  # subshell: BASH_SOURCE[-1]=test-sandbox-cwd.sh = $0 → guard does not fire
  . "$TALOS_ROOT/tests/helpers.sh"
  make_sandbox
  # subshell exits here; EXIT trap fires; rm -rf "$SANDBOX" runs
)
after_t1="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_t1" "$after_t1" \
  "T1: make_sandbox: sandbox dir removed when subprocess exits (mutation: omit rm -rf from trap)"

# ═════════════════════════════════════════════════════════════════════════════
# T2: Sandbox is removed even when the test fails
# ═════════════════════════════════════════════════════════════════════════════
before_t2="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
(
  . "$TALOS_ROOT/tests/helpers.sh"
  make_sandbox
  exit 1   # deliberate failure — EXIT trap must still fire
) || true  # allow non-zero from the subshell
after_t2="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_t2" "$after_t2" \
  "T2: make_sandbox: sandbox removed on deliberate failure (mutation: omit rm -rf from trap)"

# ═════════════════════════════════════════════════════════════════════════════
# T3: make_sandbox refuses when called from a sourced context (the real fix)
# ═════════════════════════════════════════════════════════════════════════════
# When helpers.sh is sourced into an interactive shell (. tests/helpers.sh &&
# make_sandbox), BASH_SOURCE[-1] differs from $0 — the guard in make_sandbox
# detects this and returns 1, printing an error.
#
# Here we simulate the dangerous case via "bash -c" (where $0 = "bash") to
# verify the guard fires.  This test is RED on the pre-fix code (no guard).
_t3_out="$(bash -c ". '$TALOS_ROOT/tests/helpers.sh' && make_sandbox; echo rc=\$?" 2>&1)"
assert_not_contains "$_t3_out" "rc=0" \
  "T3: make_sandbox from sourced context returns non-zero (mutation: remove guard from make_sandbox)"
assert_contains "$_t3_out" "do not source" \
  "T3: make_sandbox error message says 'do not source'"

# ═════════════════════════════════════════════════════════════════════════════
# T4: run-tests.sh rejects being sourced (secondary defence)
# ═════════════════════════════════════════════════════════════════════════════
out_t4="$(bash -c ". '$TALOS_ROOT/tests/run-tests.sh'" 2>&1 || true)"
assert_contains "$out_t4" "ERROR" \
  "T4: run-tests.sh rejects being sourced (mutation: remove BASH_SOURCE guard)"
assert_contains "$out_t4" "run-tests.sh" \
  "T4: error message names the script to invoke correctly"

finish
